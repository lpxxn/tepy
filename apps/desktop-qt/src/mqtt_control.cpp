#include "mqtt_control.hpp"
#include "agent_client.hpp"
#include <QDateTime>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QMqttSubscription>
#include <QNetworkProxy>
#include <QRegularExpression>
#include <QSslCertificate>
#include <QSslKey>
#include <QSslSocket>
#include <QUuid>
#include <algorithm>
#include <cmath>

namespace tepy::desktop {
void clearSecret(QByteArray &bytes) {
    // Detach before wiping our owned buffer; Qt/network internals may hold their own copies.
    volatile char *p = bytes.data();
    for (qsizetype i = 0; i < bytes.size(); ++i)
        p[i] = 0;
    bytes.clear();
}
bool validText(const QByteArray &text) {
    return !text.isEmpty() && text.size() <= 512 &&
           std::all_of(text.cbegin(), text.cend(),
                       [](unsigned char c) { return c >= 32 && c <= 126; });
}
bool validKey(const QString &key, const QStringList &modifiers) {
    const QStringList names{
        QStringLiteral("ENTER"),     QStringLiteral("TAB"),      QStringLiteral("ESC"),
        QStringLiteral("BACKSPACE"), QStringLiteral("DELETE"),   QStringLiteral("SPACE"),
        QStringLiteral("LEFT"),      QStringLiteral("RIGHT"),    QStringLiteral("UP"),
        QStringLiteral("DOWN"),      QStringLiteral("HOME"),     QStringLiteral("END"),
        QStringLiteral("PAGEUP"),    QStringLiteral("PAGEDOWN"), QStringLiteral("CAPSLOCK")};
    if (!(key.size() == 1 && key[0].unicode() >= 32 && key[0].unicode() <= 126) &&
        !names.contains(key) &&
        !QRegularExpression(QStringLiteral("^F([1-9]|1[0-2])$")).match(key).hasMatch())
        return false;
    QStringList seen;
    for (const auto &modifier : modifiers) {
        if (!QStringList{QStringLiteral("CTRL"), QStringLiteral("SHIFT"), QStringLiteral("ALT"),
                         QStringLiteral("GUI")}
                 .contains(modifier) ||
            seen.contains(modifier))
            return false;
        seen << modifier;
    }
    return true;
}
bool brokerConfiguration(const BrokerSettings &s, QUrl &url, QSslConfiguration &tls,
                         QString &error) {
    url = QUrl(s.url.trimmed(), QUrl::StrictMode);
    const bool encrypted = url.scheme() == QStringLiteral("mqtts");
    if (!url.isValid() || (!encrypted && url.scheme() != QStringLiteral("mqtt")) ||
        url.host().isEmpty() || !url.userInfo().isEmpty() || !url.path().isEmpty() ||
        url.hasQuery() || url.hasFragment() || url.port(encrypted ? 8883 : 1883) < 1 ||
        url.port(encrypted ? 8883 : 1883) > 65535 ||
        !QRegularExpression(QStringLiteral("^[a-f0-9]{12}$")).match(s.deviceID).hasMatch() ||
        (!s.agentID.isEmpty() && !QRegularExpression(QStringLiteral("^[A-Za-z0-9_.-]{1,64}$"))
                                      .match(s.agentID)
                                      .hasMatch())) {
        error = QStringLiteral(
            "检查 MQTT 地址、12 位设备 ID 和 Mac 代理 ID；地址内不要填写用户名密码。");
        return false;
    }
    if (s.username.toUtf8().size() > 256 || s.password.toUtf8().size() > 4096 ||
        s.clientCertFile.isEmpty() != s.clientKeyFile.isEmpty() ||
        (!encrypted && (!s.caFile.isEmpty() || !s.clientCertFile.isEmpty()))) {
        error = QStringLiteral("证书与私钥须成对配置，证书仅用于 mqtts://；凭据长度超限。");
        return false;
    }
    tls = QSslConfiguration::defaultConfiguration();
    tls.setProtocol(QSsl::TlsV1_2OrLater);
    tls.setPeerVerifyMode(QSslSocket::VerifyPeer);
    const auto read = [](const QString &path) {
        QFile file(path);
        return file.open(QIODevice::ReadOnly) && file.size() <= 65536 ? file.readAll()
                                                                      : QByteArray();
    };
    if (!s.caFile.isEmpty()) {
        const auto certs = QSslCertificate::fromData(read(s.caFile));
        if (certs.isEmpty()) {
            error = QStringLiteral("无法读取有效的 CA PEM 证书。");
            return false;
        }
        tls.setCaCertificates(tls.caCertificates() + certs);
    }
    if (!s.clientCertFile.isEmpty()) {
        const auto chain = QSslCertificate::fromData(read(s.clientCertFile));
        auto bytes = read(s.clientKeyFile);
        auto key = QSslKey(bytes, QSsl::Rsa);
        if (key.isNull())
            key = QSslKey(bytes, QSsl::Ec);
        clearSecret(bytes);
        if (chain.isEmpty() || key.isNull()) {
            error = QStringLiteral("客户端证书或未加密 PEM 私钥无效。");
            return false;
        }
        tls.setLocalCertificateChain(chain);
        tls.setPrivateKey(key);
    }
    error.clear();
    return true;
}
MqttControl::MqttControl(QObject *parent) : QObject(parent) {
    reconnect_.setSingleShot(true);
    connectTimeout_.setSingleShot(true);
    replyTimeout_.setSingleShot(true);
    ackTimeout_.setSingleShot(true);
    connect(&reconnect_, &QTimer::timeout, this, &MqttControl::connectBroker);
    connect(&connectTimeout_, &QTimer::timeout, this, &MqttControl::lost);
    const auto uncertain = [this] {
        const auto id = pending_;
        abandon();
        if (!id.isEmpty())
            emit actionUncertain(id);
    };
    connect(&replyTimeout_, &QTimer::timeout, this, uncertain);
    connect(&ackTimeout_, &QTimer::timeout, this, &MqttControl::lost);
    connect(&freshness_, &QTimer::timeout, this, [this] {
        bool changed = false;
        if (!device_.isEmpty() && !deviceFresh()) {
            device_ = {};
            changed = true;
        }
        if (!mac_.isEmpty() && !macFresh()) {
            mac_ = {};
            changed = true;
        }
        if (changed)
            emit this->changed();
    });
    freshness_.start(1000);
}
MqttControl::~MqttControl() {
    blockSignals(true);
    stop();
}
QString MqttControl::topic(const QString &suffix) const {
    return QStringLiteral("tepy/") + settings_.deviceID + QChar(u'/') + suffix;
}
bool MqttControl::start(const BrokerSettings &settings) {
    QUrl url;
    QSslConfiguration tls;
    QString error;
    if (!brokerConfiguration(settings, url, tls, error)) {
        emit notice(error, true);
        return false;
    }
    stop();
    settings_ = settings;
    url_ = url;
    tls_ = tls;
    active_ = true;
    backoff_ = 1000;
    emit activeChanged(true);
    connectBroker();
    return true;
}
void MqttControl::abandon() {
    pending_.clear();
    // Cancellation cannot recall a submitted packet. Keep its short PUBACK
    // deadline so Qt's in-flight payload cannot remain on an unresponsive link.
    if (!ackTimeout_.isActive())
        packetID_ = -1;
    replyTimeout_.stop();
}
void MqttControl::stop() {
    active_ = subscribed_ = false;
    reconnect_.stop();
    connectTimeout_.stop();
    const auto id = pending_;
    ackTimeout_.stop();
    packetID_ = -1;
    abandon();
    if (client_) {
        auto *old = client_.data();
        client_ = nullptr;
        old->disconnect(this);
        if (old->state() == QMqttClient::Connected && old->transport() &&
            old->transport()->isOpen())
            old->disconnectFromHost();
        old->deleteLater();
    }
    settings_.password.clear();
    tls_ = {};
    device_ = {};
    mac_ = {};
    if (!id.isEmpty())
        emit actionUncertain(id);
    emit activeChanged(false);
    emit changed();
}
void MqttControl::lost() {
    if (!active_)
        return;
    subscribed_ = false;
    connectTimeout_.stop();
    const auto id = pending_;
    ackTimeout_.stop();
    packetID_ = -1;
    abandon();
    if (client_) {
        auto *old = client_.data();
        client_ = nullptr;
        old->disconnect(this);
        old->deleteLater();
    }
    device_ = {};
    mac_ = {};
    if (!id.isEmpty())
        emit actionUncertain(id);
    emit changed();
    emit notice(QStringLiteral("MQTT 连接已断开，等待重连；动作不会自动重发。"), true);
    reconnect_.start(static_cast<int>(backoff_));
    backoff_ = std::min(backoff_ * 2, 30000u);
}
void MqttControl::connectBroker() {
    if (!active_)
        return;
    auto *client = new QMqttClient(this);
    client_ = client;
    client->setClientId(QStringLiteral("tepy-qt-") + QUuid::createUuid().toString(QUuid::Id128));
    client->setProtocolVersion(QMqttClient::MQTT_3_1_1);
    client->setCleanSession(true);
    client->setKeepAlive(15);
    client->setHostname(url_.host());
    client->setPort(
        static_cast<quint16>(url_.port(url_.scheme() == QStringLiteral("mqtts") ? 8883 : 1883)));
    client->setUsername(settings_.username);
    client->setPassword(settings_.password);
    // A fresh client on every connection prevents old QoS packets being replayed after reconnect.
    connect(client, &QMqttClient::disconnected, this, &MqttControl::lost);
    connect(client, &QMqttClient::errorChanged, this, [this](QMqttClient::ClientError error) {
        if (error == QMqttClient::BadUsernameOrPassword || error == QMqttClient::NotAuthorized) {
            stop();
            emit notice(QStringLiteral("MQTT 认证或权限被拒绝，请核对凭据和 Broker ACL。"), true);
        } else if (error != QMqttClient::NoError)
            lost();
    });
    connect(client, &QMqttClient::messageSent, this, [this](qint32 id) {
        if (id == packetID_)
            ackTimeout_.stop();
    });
    connect(client, &QMqttClient::connected, this, [this, client] {
        if (client_ != client)
            return;
        QStringList topics{topic(QStringLiteral("state")), topic(QStringLiteral("reply"))};
        if (!settings_.agentID.isEmpty()) {
            const auto prefix = QStringLiteral("tepy/macos/") + settings_.agentID;
            topics << prefix + QStringLiteral("/state") << prefix + QStringLiteral("/availability");
        }
        subscriptions_ = 0;
        const auto expected = static_cast<unsigned>(topics.size());
        for (const auto &name : topics) {
            auto *sub = client->subscribe(QMqttTopicFilter(name), 1);
            if (!sub) {
                lost();
                return;
            }
            connect(sub, &QMqttSubscription::messageReceived, this,
                    [this](const QMqttMessage &message) {
                        receive(message.topic().name(), message.payload(), message.retain());
                    });
            connect(sub, &QMqttSubscription::stateChanged, this,
                    [this, expected](QMqttSubscription::SubscriptionState state) {
                        if (state == QMqttSubscription::Error) {
                            stop();
                            emit notice(QStringLiteral("MQTT 订阅被拒绝。"), true);
                        } else if (state == QMqttSubscription::Subscribed &&
                                   ++subscriptions_ == expected) {
                            subscribed_ = true;
                            backoff_ = 1000;
                            connectTimeout_.stop();
                            emit changed();
                            emit notice(QStringLiteral("MQTT 已连接，正在接收设备与 Mac 状态。"),
                                        false);
                        }
                    });
        }
    });
    connectTimeout_.start(12000);
    const auto openTransport = [this, client](QTcpSocket *socket) {
        if (client_ != client)
            return;
        // setTransport() expects an already-open IODevice. Own socket startup/TLS
        // so system proxy settings are never applied to the explicit broker URL.
        client->setTransport(socket, QMqttClient::IODevice);
        client->connectToHost();
    };
    if (url_.scheme() == QStringLiteral("mqtts")) {
        auto *socket = new QSslSocket(client);
        socket->setProxy(QNetworkProxy::NoProxy);
        socket->setSslConfiguration(tls_);
        connect(socket, &QSslSocket::encrypted, this,
                [openTransport, socket] { openTransport(socket); });
        connect(socket, &QAbstractSocket::disconnected, this, [this, client] {
            if (client_ == client)
                lost();
        });
        connect(socket, &QAbstractSocket::errorOccurred, this,
                [this, client](QAbstractSocket::SocketError) {
                    if (client_ == client)
                        lost();
                });
        socket->connectToHostEncrypted(url_.host(), client->port());
    } else {
        auto *socket = new QTcpSocket(client);
        socket->setProxy(QNetworkProxy::NoProxy);
        connect(socket, &QTcpSocket::connected, this,
                [openTransport, socket] { openTransport(socket); });
        connect(socket, &QAbstractSocket::disconnected, this, [this, client] {
            if (client_ == client)
                lost();
        });
        connect(socket, &QAbstractSocket::errorOccurred, this,
                [this, client](QAbstractSocket::SocketError) {
                    if (client_ == client)
                        lost();
                });
        socket->connectToHost(url_.host(), client->port());
    }
}
bool MqttControl::deviceFresh() const {
    if (!subscribed_ || device_.isEmpty() || !deviceAge_.isValid() || deviceAge_.elapsed() > 15000)
        return false;
    const auto now = QDateTime::currentMSecsSinceEpoch(),
               sampled = device_.value(QStringLiteral("now")).toInteger();
    return sampled <= now + 5000 && sampled > now - 15000;
}
bool MqttControl::deviceReady() const {
    return deviceFresh() && device_.value(QStringLiteral("online")).toBool() &&
           device_.value(QStringLiteral("time_ready")).toBool() &&
           device_.value(QStringLiteral("ble"))
               .toObject()
               .value(QStringLiteral("ready"))
               .toBool() &&
           device_.value(QStringLiteral("mqtt"))
               .toObject()
               .value(QStringLiteral("connected"))
               .toBool();
}
bool MqttControl::macFresh() const {
    return subscribed_ && !mac_.isEmpty() && macAge_.isValid() && macAge_.elapsed() <= 180000 &&
           mac_.value(QStringLiteral("valid_until")).toInteger() >
               QDateTime::currentMSecsSinceEpoch();
}
void MqttControl::receive(const QString &name, const QByteArray &bytes, bool retained) {
    if (bytes.size() > 16384)
        return;
    if (!settings_.agentID.isEmpty() && name == QStringLiteral("tepy/macos/") + settings_.agentID +
                                                    QStringLiteral("/availability")) {
        if (bytes == "offline") {
            mac_ = {};
            emit changed();
        }
        return;
    }
    const auto document = QJsonDocument::fromJson(bytes);
    if (!document.isObject())
        return;
    const auto value = document.object();
    if (value.value(QStringLiteral("v")) != QJsonValue(1))
        return;
    if (name == topic(QStringLiteral("reply"))) {
        if (retained || pending_.isEmpty() ||
            value.value(QStringLiteral("id")).toString() != pending_)
            return;
        const auto status = value.value(QStringLiteral("status")).toString(),
                   error = value.value(QStringLiteral("error")).toString();
        if (!QStringList{QStringLiteral("sent"), QStringLiteral("failed"),
                         QStringLiteral("rejected")}
                 .contains(status) ||
            !QRegularExpression(QStringLiteral("^[a-z_]{0,64}$")).match(error).hasMatch())
            return;
        const auto id = pending_;
        abandon();
        emit actionReply(id, status, error);
    } else if (name == topic(QStringLiteral("state"))) {
        if (value.value(QStringLiteral("device_id")).toString() != settings_.deviceID)
            return;
        if (!value.value(QStringLiteral("online")).toBool()) {
            device_ = {};
            emit changed();
            return;
        }
        const auto nowValue = value.value(QStringLiteral("now"));
        if (!value.value(QStringLiteral("time_ready")).isBool() ||
            !value.value(QStringLiteral("busy")).isBool() || !nowValue.isDouble() ||
            !std::isfinite(nowValue.toDouble()) ||
            std::floor(nowValue.toDouble()) != nowValue.toDouble() ||
            !value.value(QStringLiteral("ble"))
                 .toObject()
                 .value(QStringLiteral("ready"))
                 .isBool() ||
            !value.value(QStringLiteral("mqtt"))
                 .toObject()
                 .value(QStringLiteral("connected"))
                 .isBool() ||
            !QRegularExpression(QStringLiteral("^[a-f0-9]{32}$"))
                 .match(value.value(QStringLiteral("session")).toString())
                 .hasMatch())
            return;
        const auto now = QDateTime::currentMSecsSinceEpoch();
        if (nowValue.toDouble() > now + 5000 || nowValue.toDouble() <= now - 15000)
            return;
        device_ = value;
        deviceAge_.restart();
        emit changed();
    } else if (!settings_.agentID.isEmpty() && name == QStringLiteral("tepy/macos/") +
                                                           settings_.agentID +
                                                           QStringLiteral("/state")) {
        QString error;
        if (value.value(QStringLiteral("agent_id")).toString() != settings_.agentID ||
            !validateAgentState(value, QDateTime::currentMSecsSinceEpoch(), error))
            return;
        if (!mac_.isEmpty() &&
            value.value(QStringLiteral("session")) == mac_.value(QStringLiteral("session")) &&
            value.value(QStringLiteral("sequence")).toInteger() <=
                mac_.value(QStringLiteral("sequence")).toInteger())
            return;
        mac_ = value;
        macAge_.restart();
        emit changed();
    }
}
QString MqttControl::send(const QString &kind, const QJsonObject &payload) {
    if (!client_ || !deviceReady() || !pending_.isEmpty() || ackTimeout_.isActive() ||
        device_.value(QStringLiteral("busy")).toBool())
        return {};
    auto text = payload.value(QStringLiteral("text")).toString().toUtf8();
    QStringList modifiers;
    for (const auto &m : payload.value(QStringLiteral("modifiers")).toArray())
        modifiers << m.toString();
    const bool valid = (kind == QStringLiteral("wake") && payload.isEmpty()) ||
                       (kind == QStringLiteral("type_text") && validText(text) &&
                        payload.value(QStringLiteral("press_enter")).isBool()) ||
                       (kind == QStringLiteral("key") &&
                        validKey(payload.value(QStringLiteral("key")).toString(), modifiers));
    const auto strokes = kind == QStringLiteral("type_text")
                             ? text.size() + payload.value(QStringLiteral("press_enter")).toBool()
                             : 1;
    clearSecret(text);
    if (!valid)
        return {};
    pending_ = QUuid::createUuid().toString(QUuid::Id128);
    const auto id = pending_;
    QJsonObject command{{QStringLiteral("v"), 1},
                        {QStringLiteral("id"), id},
                        {QStringLiteral("session"), device_.value(QStringLiteral("session"))},
                        {QStringLiteral("expires_at"), QDateTime::currentMSecsSinceEpoch() + 10000},
                        {QStringLiteral("type"), kind},
                        {QStringLiteral("payload"), payload}};
    auto wire = QJsonDocument(command).toJson(QJsonDocument::Compact);
    packetID_ = client_->publish(QMqttTopicName(topic(QStringLiteral("cmd"))), wire, 1, false);
    clearSecret(wire);
    if (packetID_ < 0) {
        abandon();
        return {};
    }
    ackTimeout_.start(6000);
    replyTimeout_.start(static_cast<int>(std::max<qsizetype>(30000, strokes * 400 + 20000)));
    return id;
}
} // namespace tepy::desktop
