#include "agent_client.hpp"
#include "protocol.hpp"
#include <QDateTime>
#include <QJsonArray>
#include <QJsonDocument>
#include <QNetworkProxy>
#include <QRegularExpression>
#include <cmath>

namespace tepy::desktop {
namespace {
bool integer(const QJsonValue &v) {
    return v.isDouble() && std::isfinite(v.toDouble()) && v.toDouble() >= 0 &&
           v.toDouble() <= 9007199254740991.0 && std::floor(v.toDouble()) == v.toDouble();
}
bool optionalBool(const QJsonValue &v) {
    return v.isBool() || v.isNull();
}
} // namespace
bool validateAgentState(const QJsonObject &s, qint64 now, QString &error) {
    const auto fail = [&] {
        error = QStringLiteral("Mac 服务回复格式不正确或版本不受支持。");
        return false;
    };
    if (s.value(QStringLiteral("v")) != QJsonValue(1) ||
        s.value(QStringLiteral("platform")).toString() != QStringLiteral("darwin") ||
        !QRegularExpression(QStringLiteral("^[A-Za-z0-9_.-]{1,64}$"))
             .match(s.value(QStringLiteral("agent_id")).toString())
             .hasMatch() ||
        !QRegularExpression(QStringLiteral("^[a-f0-9]{32}$"))
             .match(s.value(QStringLiteral("session")).toString())
             .hasMatch() ||
        !s.value(QStringLiteral("agent_version")).isString() ||
        s.value(QStringLiteral("agent_version")).toString().isEmpty() ||
        s.value(QStringLiteral("agent_version")).toString().size() > 64 ||
        !s.value(QStringLiteral("name")).isString() ||
        s.value(QStringLiteral("name")).toString().isEmpty() ||
        s.value(QStringLiteral("name")).toString().size() > 128)
        return fail();
    for (const auto *key : {"observed_at", "valid_until", "sequence", "uptime_seconds"})
        if (!integer(s.value(QString::fromLatin1(key))))
            return fail();
    const auto observed = s.value(QStringLiteral("observed_at")).toInteger(),
               expires = s.value(QStringLiteral("valid_until")).toInteger();
    if (expires <= observed || expires - observed > 180000)
        return fail();
    if (observed > now + 5000 || expires <= now) {
        error = QStringLiteral("Mac 状态已过期或两台电脑时间不同步，请检查系统时间。");
        return false;
    }
    const auto session = s.value(QStringLiteral("user_session")).toObject(),
               hid = s.value(QStringLiteral("hid")).toObject(),
               power = s.value(QStringLiteral("power")).toObject(),
               mqtt = s.value(QStringLiteral("mqtt")).toObject();
    if (!session.value(QStringLiteral("available")).isBool() ||
        !optionalBool(session.value(QStringLiteral("on_console"))) ||
        !optionalBool(session.value(QStringLiteral("login_done"))) ||
        !QStringList{QStringLiteral("locked"), QStringLiteral("unlocked"),
                     QStringLiteral("unknown")}
             .contains(session.value(QStringLiteral("lock_state")).toString()) ||
        !QStringList{QStringLiteral("cg_session_property"), QStringLiteral("io_console_property"),
                     QStringLiteral("screen_notification"), QStringLiteral("unavailable")}
             .contains(session.value(QStringLiteral("lock_source")).toString()))
        return fail();
    const auto hidState = hid.value(QStringLiteral("state")).toString();
    if (!hid.value(QStringLiteral("available")).isBool() ||
        !QStringList{QStringLiteral("registered"), QStringLiteral("absent"),
                     QStringLiteral("unknown")}
             .contains(hidState) ||
        !hid.value(QStringLiteral("target_device_id")).isString() ||
        !QRegularExpression(QStringLiteral("^([a-f0-9]{12})?$"))
             .match(hid.value(QStringLiteral("target_device_id")).toString())
             .hasMatch() ||
        !hid.value(QStringLiteral("devices")).isArray() ||
        hid.value(QStringLiteral("devices")).toArray().size() > 8)
        return fail();
    const auto devices = hid.value(QStringLiteral("devices")).toArray();
    if ((hidState == QStringLiteral("registered") &&
         (devices.isEmpty() || !hid.value(QStringLiteral("available")).toBool())) ||
        (hidState == QStringLiteral("absent") &&
         (!devices.isEmpty() || !hid.value(QStringLiteral("available")).toBool())))
        return fail();
    for (const auto &item : devices) {
        const auto device = item.toObject();
        if (!device.value(QStringLiteral("product")).isString() ||
            !device.value(QStringLiteral("transport")).isString() ||
            !QRegularExpression(QStringLiteral("^0x[0-9A-Fa-f]+$"))
                 .match(device.value(QStringLiteral("registry_id")).toString())
                 .hasMatch())
            return fail();
    }
    if (!power.value(QStringLiteral("monitoring")).isBool() ||
        !QStringList{QStringLiteral("awake"), QStringLiteral("sleeping"), QStringLiteral("unknown")}
             .contains(power.value(QStringLiteral("state")).toString()) ||
        !QStringList{QStringLiteral("none"), QStringLiteral("will_sleep"),
                     QStringLiteral("did_wake")}
             .contains(power.value(QStringLiteral("last_event")).toString()) ||
        !integer(power.value(QStringLiteral("last_event_at"))) ||
        !integer(power.value(QStringLiteral("wake_count"))) ||
        !mqtt.value(QStringLiteral("configured")).isBool() ||
        !mqtt.value(QStringLiteral("connected")).isBool() ||
        !s.value(QStringLiteral("diagnostics")).isArray())
        return fail();
    error.clear();
    return true;
}
AgentClient::AgentClient(QObject *parent) : QObject(parent) {
    network_.setProxy(QNetworkProxy::NoProxy);
    poll_.setInterval(5000);
    timeout_.setSingleShot(true);
    connect(&poll_, &QTimer::timeout, this, &AgentClient::refresh);
    connect(&timeout_, &QTimer::timeout, this, [this] {
        if (reply_) {
            reply_->disconnect(this);
            reply_->abort();
            reply_->deleteLater();
            reply_ = nullptr;
        }
        reject(QStringLiteral("Mac 暂时无法访问；将继续等待恢复连接。"));
        if (active_ && !poll_.isActive())
            poll_.start();
    });
}
AgentClient::~AgentClient() {
    blockSignals(true);
    stop();
}
void AgentClient::stop() {
    poll_.stop();
    timeout_.stop();
    if (reply_) {
        reply_->disconnect(this);
        reply_->abort();
        reply_->deleteLater();
        reply_ = nullptr;
    }
    active_ = false;
    token_.clear();
    agentID_.clear();
    base_ = QUrl();
    emit activeChanged(false);
}
bool AgentClient::start(const QString &address, const QString &token) {
    QString error;
    const auto url = deviceUrl(address, error);
    if (url.isEmpty()) {
        emit failed(QStringLiteral("请输入 Mac 服务地址，例如 http://192.168.50.246:18765。"));
        return false;
    }
    if (token.toUtf8().size() < 32 || token.toUtf8().size() > 128 ||
        !QRegularExpression(QStringLiteral("^[!-~]+$")).match(token).hasMatch()) {
        emit failed(QStringLiteral("请填写 Go 服务 TOML 中的 http.token，长度须为 32–128。"));
        return false;
    }
    stop();
    base_ = url;
    token_ = token;
    active_ = true;
    emit activeChanged(true);
    refresh();
    return true;
}
void AgentClient::reject(const QString &message, bool stopPolling) {
    if (stopPolling)
        stop();
    emit failed(message);
}
void AgentClient::refresh() {
    if (!active_ || reply_)
        return;
    auto url = base_;
    url.setPath(QStringLiteral("/api/v1/agent/status"));
    QNetworkRequest request(url);
    request.setRawHeader("Authorization", QByteArray("Bearer ") + token_.toUtf8());
    request.setAttribute(QNetworkRequest::RedirectPolicyAttribute,
                         QNetworkRequest::ManualRedirectPolicy);
    auto *reply = network_.get(request);
    reply_ = reply;
    timeout_.start(4000);
    connect(reply, &QNetworkReply::readyRead, this, [this, reply] {
        if (reply_ == reply && reply->bytesAvailable() > 32768) {
            reply->disconnect(this);
            reply->abort();
            reply->deleteLater();
            reply_ = nullptr;
            timeout_.stop();
            reject(QStringLiteral("Mac 服务回复过大。"), true);
        }
    });
    connect(reply, &QNetworkReply::finished, this, [this, reply] {
        if (reply_ != reply)
            return;
        reply_ = nullptr;
        timeout_.stop();
        const auto code = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        const auto bytes = reply->read(32769);
        const auto document = QJsonDocument::fromJson(bytes);
        const auto networkError = reply->error();
        reply->deleteLater();
        if (code == 401 || code == 403) {
            reject(QStringLiteral("Mac 服务口令不正确；请使用 TOML 的 http.token。"), true);
            return;
        }
        if ((code >= 300 && code < 400) || code == 404) {
            reject(QStringLiteral("Mac 服务地址不正确或发生重定向。"), true);
            return;
        }
        if (networkError != QNetworkReply::NoError || code != 200) {
            reject(QStringLiteral("Mac 暂时离线或状态不可用；正在等待恢复。"));
            if (!poll_.isActive())
                poll_.start();
            return;
        }
        QString error;
        if (!document.isObject() || bytes.size() > 32768 ||
            !validateAgentState(document.object(), QDateTime::currentMSecsSinceEpoch(), error)) {
            reject(error.isEmpty() ? QStringLiteral("Mac 服务回复格式不正确。") : error, true);
            return;
        }
        const auto id = document.object().value(QStringLiteral("agent_id")).toString();
        if (!agentID_.isEmpty() && agentID_ != id) {
            reject(QStringLiteral("目标 Mac 服务身份发生变化，请核对地址后重新连接。"), true);
            return;
        }
        agentID_ = id;
        if (!poll_.isActive())
            poll_.start();
        emit updated(document.object());
    });
}
} // namespace tepy::desktop
