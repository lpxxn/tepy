#include "connection_store.hpp"
#include "keyboard_job.hpp"
#include "main_window.hpp"
#include <QApplication>
#include <QDateTime>
#include <QFontDatabase>
#include <QJsonArray>
#include <QJsonDocument>
#include <QLineEdit>
#include <QPushButton>
#include <QScopeGuard>
#include <QSettings>
#include <QSignalSpy>
#include <QSslSocket>
#include <QTabWidget>
#include <QTcpServer>
#include <QTcpSocket>
#include <QTest>
#include <QUuid>
#include <memory>

using namespace tepy::desktop;
namespace {
const auto deviceID = QStringLiteral("aabbccddeeff"), agentID = QStringLiteral("mac-test");
QString deviceTopic(const QString &suffix) {
    return QStringLiteral("tepy/") + deviceID + QChar(u'/') + suffix;
}
QJsonObject deviceState(const QString &session = QString(32, QChar(u'a'))) {
    return {{QStringLiteral("v"), 1},
            {QStringLiteral("device_id"), deviceID},
            {QStringLiteral("session"), session},
            {QStringLiteral("online"), true},
            {QStringLiteral("time_ready"), true},
            {QStringLiteral("busy"), false},
            {QStringLiteral("now"), QDateTime::currentMSecsSinceEpoch()},
            {QStringLiteral("ble"), QJsonObject{{QStringLiteral("ready"), true}}},
            {QStringLiteral("mqtt"), QJsonObject{{QStringLiteral("connected"), true}}}};
}
QJsonObject macState(const QString &lock, int sequence = 1) {
    const auto now = QDateTime::currentMSecsSinceEpoch();
    return {{QStringLiteral("v"), 1},
            {QStringLiteral("agent_id"), agentID},
            {QStringLiteral("agent_version"), QStringLiteral("0.1.0")},
            {QStringLiteral("name"), QStringLiteral("Test Mac")},
            {QStringLiteral("platform"), QStringLiteral("darwin")},
            {QStringLiteral("session"), QString(32, QChar(u'b'))},
            {QStringLiteral("sequence"), sequence},
            {QStringLiteral("observed_at"), now},
            {QStringLiteral("valid_until"), now + 30000},
            {QStringLiteral("uptime_seconds"), 10},
            {QStringLiteral("mqtt"), QJsonObject{{QStringLiteral("configured"), true},
                                                 {QStringLiteral("connected"), true}}},
            {QStringLiteral("user_session"),
             QJsonObject{{QStringLiteral("available"), true},
                         {QStringLiteral("on_console"), true},
                         {QStringLiteral("login_done"), true},
                         {QStringLiteral("lock_state"), lock},
                         {QStringLiteral("lock_source"), QStringLiteral("screen_notification")}}},
            {QStringLiteral("hid"),
             QJsonObject{{QStringLiteral("available"), true},
                         {QStringLiteral("state"), QStringLiteral("registered")},
                         {QStringLiteral("target_device_id"), deviceID},
                         {QStringLiteral("devices"),
                          QJsonArray{QJsonObject{
                              {QStringLiteral("product"), QStringLiteral("Tepy-ddeeff")},
                              {QStringLiteral("transport"), QStringLiteral("Bluetooth Low Energy")},
                              {QStringLiteral("registry_id"), QStringLiteral("0x1234")}}}}}},
            {QStringLiteral("power"),
             QJsonObject{{QStringLiteral("monitoring"), true},
                         {QStringLiteral("state"), QStringLiteral("awake")},
                         {QStringLiteral("last_event"), QStringLiteral("none")},
                         {QStringLiteral("last_event_at"), 0},
                         {QStringLiteral("wake_count"), 0}}},
            {QStringLiteral("diagnostics"), QJsonArray()}};
}
QByteArray frame(unsigned char header, const QByteArray &body) {
    QByteArray result(1, static_cast<char>(header));
    auto length = body.size();
    do {
        auto byte = length % 128;
        length /= 128;
        result.append(static_cast<char>(byte | (length ? 128 : 0)));
    } while (length);
    return result + body;
}
QByteArray mqttString(const QByteArray &text) {
    QByteArray result;
    result.append(static_cast<char>(text.size() >> 8));
    result.append(static_cast<char>(text.size()));
    return result + text;
}
struct Publish {
    QJsonObject object;
    unsigned char header;
};
class Broker {
  public:
    QTcpServer server;
    QList<QTcpSocket *> sockets;
    QList<Publish> commands;
    QByteArray connectPacket;
    unsigned connections{};
    bool autoState = true, autoReply = false, autoUnlock = false;
    bool autoAck = true;
    QString initialLock = QStringLiteral("locked");
    Broker() {
        server.listen(QHostAddress::LocalHost, 0);
        QObject::connect(&server, &QTcpServer::newConnection, &server, [this] {
            auto *socket = server.nextPendingConnection();
            sockets << socket;
            ++connections;
            auto bytes = std::make_shared<QByteArray>();
            auto subscriptions = std::make_shared<unsigned>(0);
            QObject::connect(socket, &QTcpSocket::disconnected, &server, [this, socket] {
                sockets.removeAll(socket);
                socket->deleteLater();
            });
            QObject::connect(
                socket, &QTcpSocket::readyRead, &server, [this, socket, bytes, subscriptions] {
                    *bytes += socket->readAll();
                    while (bytes->size() >= 2) {
                        const auto header = static_cast<unsigned char>((*bytes)[0]);
                        qsizetype length = 0, offset = 1, multiplier = 1;
                        bool complete = false;
                        for (int i = 0; i < 4 && offset < bytes->size(); ++i) {
                            const auto c = static_cast<unsigned char>((*bytes)[offset++]);
                            length += (c & 127) * multiplier;
                            multiplier *= 128;
                            if (!(c & 128)) {
                                complete = true;
                                break;
                            }
                        }
                        if (!complete || bytes->size() < offset + length)
                            return;
                        auto body = bytes->mid(offset, length);
                        bytes->remove(0, offset + length);
                        if ((header >> 4) == 1) {
                            connectPacket = body;
                            socket->write(QByteArray::fromHex("20020000"));
                        } else if ((header >> 4) == 8) {
                            socket->write(frame(0x90, body.left(2) + QByteArray(1, '\1')));
                            if (++*subscriptions == 4 && autoState)
                                QTimer::singleShot(0, &server, [this] {
                                    publish(deviceTopic(QStringLiteral("state")), deviceState());
                                    publish(QStringLiteral("tepy/macos/mac-test/state"),
                                            macState(initialLock));
                                });
                        } else if ((header >> 4) == 3 && body.size() >= 2) {
                            const auto topicLength = (static_cast<unsigned char>(body[0]) << 8) |
                                                     static_cast<unsigned char>(body[1]);
                            auto position = 2 + topicLength;
                            if (((header >> 1) & 3) == 1) {
                                if (autoAck)
                                    socket->write(frame(0x40, body.mid(position, 2)));
                                position += 2;
                            }
                            const auto object =
                                QJsonDocument::fromJson(body.mid(position)).object();
                            commands << Publish{object, header};
                            if (autoReply)
                                reply(object.value(QStringLiteral("id")).toString());
                            if (autoUnlock && object.value(QStringLiteral("type")) ==
                                                  QJsonValue(QStringLiteral("wake")))
                                QTimer::singleShot(10, &server, [this] {
                                    publish(QStringLiteral("tepy/macos/mac-test/state"),
                                            macState(QStringLiteral("locked"), 2));
                                });
                            if (autoUnlock && object.value(QStringLiteral("type")) ==
                                                  QJsonValue(QStringLiteral("type_text")))
                                publish(QStringLiteral("tepy/macos/mac-test/state"),
                                        macState(QStringLiteral("unlocked"), 3));
                        } else if ((header >> 4) == 12)
                            socket->write(QByteArray::fromHex("d000"));
                        else if ((header >> 4) == 14)
                            socket->disconnectFromHost();
                    }
                });
        });
    }
    BrokerSettings settings() const {
        BrokerSettings s;
        s.url = QStringLiteral("mqtt://127.0.0.1:%1").arg(server.serverPort());
        s.deviceID = deviceID;
        s.agentID = agentID;
        return s;
    }
    void publish(const QString &topic, const QJsonObject &object, bool retained = false) {
        const auto packet =
            frame(retained ? 0x31 : 0x30, mqttString(topic.toUtf8()) +
                                              QJsonDocument(object).toJson(QJsonDocument::Compact));
        for (auto *socket : sockets)
            socket->write(packet);
    }
    void reply(const QString &id, bool retained = false) {
        publish(deviceTopic(QStringLiteral("reply")),
                {{QStringLiteral("v"), 1},
                 {QStringLiteral("id"), id},
                 {QStringLiteral("status"), QStringLiteral("sent")},
                 {QStringLiteral("error"), QString()}},
                retained);
    }
};
} // namespace
class MqttTests : public QObject {
    Q_OBJECT
  private slots:
    void initTestCase() {
        ConnectionStore::setEnabled(false);
#ifdef Q_OS_WIN
        const auto id =
            QFontDatabase::addApplicationFont(QStringLiteral("C:/Windows/Fonts/msyh.ttc"));
        if (id >= 0)
            QApplication::setFont(QFont(QFontDatabase::applicationFontFamilies(id).first(), 10));
#endif
    }
    void configuration() {
        Broker broker;
        auto s = broker.settings();
        QUrl url;
        QSslConfiguration tls;
        QString error;
        QVERIFY(brokerConfiguration(s, url, tls, error));
        s.url = QStringLiteral("mqtts://broker.example.com");
        QVERIFY(brokerConfiguration(s, url, tls, error));
        QCOMPARE(tls.peerVerifyMode(), QSslSocket::VerifyPeer);
        QCOMPARE(tls.protocol(), QSsl::TlsV1_2OrLater);
        for (const auto &address :
             {QStringLiteral("http://broker"), QStringLiteral("mqtt://name:secret@broker"),
              QStringLiteral("mqtt://broker/path"), QStringLiteral("mqtt://broker:0")}) {
            s.url = address;
            QVERIFY(!brokerConfiguration(s, url, tls, error));
            QVERIFY(!error.contains(QStringLiteral("secret")));
        }
        s = broker.settings();
        s.clientCertFile = QStringLiteral("missing.pem");
        QVERIFY(!brokerConfiguration(s, url, tls, error));
        s = broker.settings();
        s.caFile = QStringLiteral("missing.pem");
        QVERIFY(!brokerConfiguration(s, url, tls, error));
    }
    void textAndKeys() {
        QByteArray ascii;
        for (int c = 32; c <= 126; ++c)
            ascii.append(static_cast<char>(c));
        QVERIFY(validText(ascii));
        QVERIFY(validText(QByteArray(512, 'a')));
        QVERIFY(!validText(QByteArray(513, 'a')));
        QVERIFY(!validText("abc\n"));
        QVERIFY(!validText(QStringLiteral("中文").toUtf8()));
        QVERIFY(!validText({}));
        QVERIFY(validKey(QStringLiteral("+"), {QStringLiteral("GUI")}));
        QVERIFY(validKey(QStringLiteral("F12"), {}));
        QVERIFY(!validKey(QStringLiteral("F13"), {}));
        QVERIFY(!validKey(QStringLiteral("z"), {QStringLiteral("GUI"), QStringLiteral("GUI")}));
        clearSecret(ascii);
        QVERIFY(ascii.isEmpty());
    }
    void qosRetainAndReplies() {
        Broker broker;
        MqttControl client;
        auto s = broker.settings();
        s.username = QStringLiteral("test-user");
        s.password = QStringLiteral("test-password");
        QVERIFY(client.start(s));
        QTRY_VERIFY(client.deviceReady());
        QVERIFY(client.macFresh());
        QVERIFY(broker.connectPacket.size() > 8);
        QCOMPARE(static_cast<unsigned char>(broker.connectPacket[6]), 4);
        QVERIFY(static_cast<unsigned char>(broker.connectPacket[7]) & 2);
        QVERIFY(broker.connectPacket.contains("test-user"));
        QSignalSpy replies(&client, &MqttControl::actionReply);
        const auto id = client.send(QStringLiteral("type_text"),
                                    {{QStringLiteral("text"), QStringLiteral("Hello! +=")},
                                     {QStringLiteral("press_enter"), false}});
        QVERIFY(!id.isEmpty());
        QTRY_COMPARE(broker.commands.size(), 1);
        QCOMPARE(broker.commands[0].header & 7, 2); // QoS 1, retain=false.
        QCOMPARE(broker.commands[0].object.value(QStringLiteral("session")).toString(),
                 QString(32, QChar(u'a')));
        const auto expiry =
            broker.commands[0].object.value(QStringLiteral("expires_at")).toInteger();
        QVERIFY(expiry > QDateTime::currentMSecsSinceEpoch());
        QVERIFY(expiry <= QDateTime::currentMSecsSinceEpoch() + 10000);
        broker.reply(QStringLiteral("wrong-id"));
        broker.reply(id, true);
        QTest::qWait(30);
        QCOMPARE(replies.size(), 0);
        broker.reply(id);
        QTRY_COMPARE(replies.size(), 1);
        broker.reply(id);
        QTest::qWait(20);
        QCOMPARE(replies.size(), 1);
    }
    void staleAndWrongStates() {
        Broker broker;
        broker.autoState = false;
        MqttControl client;
        QVERIFY(client.start(broker.settings()));
        QTRY_VERIFY(client.connected());
        auto state = deviceState();
        state.insert(QStringLiteral("now"), QDateTime::currentMSecsSinceEpoch() - 60000);
        broker.publish(deviceTopic(QStringLiteral("state")), state);
        QTest::qWait(20);
        QVERIFY(!client.deviceReady());
        state = deviceState();
        state.insert(QStringLiteral("device_id"), QStringLiteral("000000000000"));
        broker.publish(deviceTopic(QStringLiteral("state")), state);
        QTest::qWait(20);
        QVERIFY(!client.deviceReady());
        QVERIFY(client.send(QStringLiteral("wake"), {}).isEmpty());
        QCOMPARE(broker.commands.size(), 0);
        auto mac = macState(QStringLiteral("unlocked"));
        mac.insert(QStringLiteral("agent_id"), QStringLiteral("other-mac"));
        broker.publish(QStringLiteral("tepy/macos/mac-test/state"), mac);
        QTest::qWait(20);
        QVERIFY(!client.macFresh());
    }
    void unlockOnce() {
        Broker broker;
        broker.autoReply = broker.autoUnlock = true;
        MqttControl client;
        KeyboardJob job(client);
        QVERIFY(client.start(broker.settings()));
        QTRY_VERIFY(client.deviceReady());
        QTRY_VERIFY(client.macFresh());
        QSignalSpy hid(&job, &KeyboardJob::hidResult), mac(&job, &KeyboardJob::macResult);
        QVERIFY(job.unlock(QByteArray("ExampleOnly!"), 0, true));
        QTRY_VERIFY(!job.busy());
        QCOMPARE(broker.commands.size(), 2);
        QCOMPARE(broker.commands[0].object.value(QStringLiteral("type")).toString(),
                 QStringLiteral("wake"));
        QCOMPARE(broker.commands[1].object.value(QStringLiteral("type")).toString(),
                 QStringLiteral("type_text"));
        QVERIFY(broker.commands[1]
                    .object.value(QStringLiteral("payload"))
                    .toObject()
                    .value(QStringLiteral("press_enter"))
                    .toBool());
        QVERIFY(mac.last()[0].toString().contains(QStringLiteral("已解锁")));
        QVERIFY(!hid.isEmpty());
    }
    void unknownMacNeverTypes() {
        Broker broker;
        broker.autoReply = true;
        broker.initialLock = QStringLiteral("unknown");
        MqttControl client;
        KeyboardJob job(client);
        QVERIFY(client.start(broker.settings()));
        QTRY_VERIFY(client.deviceReady());
        QVERIFY(job.unlock(QByteArray("ExampleOnly!"), 0, false));
        QTRY_COMPARE(broker.commands.size(), 1);
        QTest::qWait(150);
        QCOMPARE(broker.commands.size(), 1);
        QVERIFY(job.busy());
        job.cancel();
        QVERIFY(!job.busy());
        QTest::qWait(150);
        QCOMPARE(broker.commands.size(), 1);
    }
    void unlockedMacNeverSends() {
        Broker broker;
        broker.initialLock = QStringLiteral("unlocked");
        MqttControl client;
        KeyboardJob job(client);
        QVERIFY(client.start(broker.settings()));
        QTRY_VERIFY(client.deviceReady());
        QTRY_VERIFY(client.macFresh());
        QVERIFY(!job.unlock(QByteArray("ExampleOnly!"), 0, true));
        QVERIFY(!job.busy());
        QCOMPARE(broker.commands.size(), 0);
        QVERIFY(!job.unlock(QStringLiteral("中文").toUtf8(), 0, true));
        QCOMPARE(broker.commands.size(), 0);
    }
    void sessionChangeCancels() {
        Broker broker;
        broker.autoReply = true;
        MqttControl client;
        KeyboardJob job(client);
        QVERIFY(client.start(broker.settings()));
        QTRY_VERIFY(client.deviceReady());
        QVERIFY(job.unlock(QByteArray("ExampleOnly!"), 1000, false));
        QTRY_COMPARE(broker.commands.size(), 1);
        broker.publish(deviceTopic(QStringLiteral("state")), deviceState(QString(32, QChar(u'c'))));
        QTRY_VERIFY(!job.busy());
        QTest::qWait(1100);
        QCOMPARE(broker.commands.size(), 1);
    }
    void reconnectNeverReplays() {
        Broker broker;
        MqttControl client;
        KeyboardJob job(client);
        QVERIFY(client.start(broker.settings()));
        QTRY_VERIFY(client.deviceReady());
        QVERIFY(job.type(QByteArray("ExampleOnly!"), false));
        QTRY_COMPARE(broker.commands.size(), 1);
        QVERIFY(!job.type(QByteArray("NeverSend"), false));
        broker.sockets.first()->abort();
        QTRY_VERIFY(!job.busy());
        QTRY_VERIFY_WITH_TIMEOUT(broker.connections >= 2, 5000);
        QTRY_VERIFY(client.deviceReady());
        QTest::qWait(50);
        QCOMPARE(broker.commands.size(), 1);
    }
    void pageFlow() {
        Broker broker;
        broker.autoReply = true;
        MainWindow window;
        window.findChild<QTabWidget *>()->setCurrentIndex(5);
        window.show();
        window.findChild<QLineEdit *>(QStringLiteral("mqttBroker"))->setText(broker.settings().url);
        window.findChild<QLineEdit *>(QStringLiteral("mqttDeviceID"))->setText(deviceID);
        window.findChild<QLineEdit *>(QStringLiteral("mqttAgentID"))->setText(agentID);
        window.findChild<QPushButton *>(QStringLiteral("connectMQTT"))->click();
        auto *send = window.findChild<QPushButton *>(QStringLiteral("executeKeyboard"));
        QTRY_VERIFY(send->isEnabled());
        auto *action = window.findChild<QComboBox *>(QStringLiteral("keyboardAction"));
        action->setCurrentIndex(1);
        auto *input = window.findChild<QLineEdit *>(QStringLiteral("keyboardInput"));
        input->setText(QStringLiteral("ExampleOnly!"));
        send->click();
        QVERIFY(input->text().isEmpty());
        QTRY_COMPARE(broker.commands.size(), 1);
        QTRY_VERIFY(send->isEnabled());
        const auto preview = qEnvironmentVariable("TEPY_TEST_PREVIEW");
        if (!preview.isEmpty()) {
            QTest::qWait(40);
            QVERIFY(window.grab().save(preview + QStringLiteral("-keyboard.png")));
        }
    }
    void cancelWithoutPubackDropsLink() {
        Broker broker;
        broker.autoAck = false;
        MqttControl client;
        KeyboardJob job(client);
        QVERIFY(client.start(broker.settings()));
        QTRY_VERIFY(client.deviceReady());
        QVERIFY(job.type(QByteArray("ExampleOnly!"), false));
        QTRY_COMPARE(broker.commands.size(), 1);
        job.cancel();
        QVERIFY(!job.busy());
        QVERIFY(client.send(QStringLiteral("wake"), {}).isEmpty());
        QTRY_VERIFY_WITH_TIMEOUT(!client.connected(), 7000);
        QTRY_VERIFY_WITH_TIMEOUT(client.deviceReady(), 5000);
        QCOMPARE(broker.commands.size(), 1);
    }
    void credentialRoundTrip() {
#if defined(Q_OS_WIN) || defined(Q_OS_MACOS)
        const auto profile = QStringLiteral("test-") + QUuid::createUuid().toString(QUuid::Id128);
        const auto cleanup = qScopeGuard([profile] {
            QString ignored;
            ConnectionStore::forget(profile, ignored);
            ConnectionStore::setEnabled(false);
        });
        ConnectionStore::setEnabled(true);
        const auto token = QUuid::createUuid().toString(QUuid::Id128);
        QString error;
        QVERIFY2(ConnectionStore::save(profile,
                                       {{ QStringLiteral("address"),
                                          QStringLiteral("http://192.0.2.1:18765") }},
                                       token, error),
                 qPrintable(error));
        const auto loaded = ConnectionStore::load(profile);
        QCOMPARE(loaded.fields.value(QStringLiteral("address")).toString(),
                 QStringLiteral("http://192.0.2.1:18765"));
        QVERIFY(loaded.secret == token);
        QSettings settings(QSettings::NativeFormat, QSettings::UserScope, QStringLiteral("Tepy"),
                           QStringLiteral("Desktop"));
        QVERIFY(!settings.value(QStringLiteral("connections/") + profile)
                     .toMap()
                     .contains(QStringLiteral("token")));
        QVERIFY(!ConnectionStore::save(profile,
                                       {{ QStringLiteral("address"),
                                          QStringLiteral("http://user:secret@192.0.2.1") }},
                                       token, error));
        QVERIFY(!error.contains(QStringLiteral("secret")));
        QVERIFY(ConnectionStore::forget(profile, error));
        QVERIFY(ConnectionStore::load(profile).secret.isEmpty());
#else
        QSKIP("Native credential store supported on Windows/macOS.");
#endif
    }
    void realBrokerReadOnlyOptional() {
        const auto url = qEnvironmentVariable("TEPY_TEST_MQTT_URL");
        if (url.isEmpty())
            QSKIP("Set TEPY_TEST_MQTT_URL / DEVICE / AGENT for read-only broker observation.");
        BrokerSettings s;
        s.url = url;
        s.deviceID = qEnvironmentVariable("TEPY_TEST_MQTT_DEVICE");
        s.agentID = qEnvironmentVariable("TEPY_TEST_MQTT_AGENT");
        s.username = qEnvironmentVariable("TEPY_TEST_MQTT_USERNAME");
        s.password = qEnvironmentVariable("TEPY_TEST_MQTT_PASSWORD");
        MqttControl client;
        QVERIFY(client.start(s));
        QTRY_VERIFY_WITH_TIMEOUT(client.deviceReady(), 12000);
        QTRY_VERIFY_WITH_TIMEOUT(client.macFresh(), 12000);
        QVERIFY(client.deviceState().value(QStringLiteral("device_id")).toString() == s.deviceID);
        QVERIFY(client.macState().value(QStringLiteral("agent_id")).toString() == s.agentID);
        // This test never publishes an action or enters any text on the real Mac.
    }
};
QTEST_MAIN(MqttTests)
#include "mqtt_tests.moc"
