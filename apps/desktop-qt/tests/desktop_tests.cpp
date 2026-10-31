#include "agent_client.hpp"
#include "agent_page.hpp"
#include "config_form.hpp"
#include "connection_store.hpp"
#include "device_client.hpp"
#include "main_window.hpp"
#include "protocol.hpp"
#include "ui.hpp"
#include <QDateTime>
#include <QEvent>
#include <QFile>
#include <QFontDatabase>
#include <QJsonArray>
#include <QJsonDocument>
#include <QProxyStyle>
#include <QSignalSpy>
#include <QStyleFactory>
#include <QTabWidget>
#include <QTcpServer>
#include <QTcpSocket>
#include <QTemporaryDir>
#include <QTest>
#include <QTextDocument>
#include <QTimer>
#include <QtEndian>
#include <memory>

using namespace tepy::desktop;
namespace {
QByteArray appImage() {
    QByteArray bytes(320, '\0');
    bytes[0] = static_cast<char>(0xe9);
    qToLittleEndian<quint16>(9, bytes.data() + 12);
    qToLittleEndian<quint32>(0xabcd5432, bytes.data() + 32);
    bytes.replace(48, 5, "0.2.0");
    bytes.replace(80, 4, "tepy");
    return bytes;
}
bool write(const QString &path, const QByteArray &bytes) {
    QFile file(path);
    return file.open(QIODevice::WriteOnly) && file.write(bytes) == bytes.size();
}
QJsonObject config() {
    return {
        {QStringLiteral("v"), 1},
        {QStringLiteral("wifi"), QJsonObject{{QStringLiteral("ssid"), QStringLiteral("Example")},
                                             {QStringLiteral("password_set"), true}}},
        {QStringLiteral("mqtt"),
         QJsonObject{{QStringLiteral("uri"), QStringLiteral("mqtt://broker.example:1883")},
                     {QStringLiteral("password_set"), true}}},
        {QStringLiteral("ntp_server"), QStringLiteral("pool.ntp.org")},
        {QStringLiteral("key_delay_ms"), 20}};
}
QJsonObject agentState(qint64 now) {
    return {{QStringLiteral("v"), 1},
            {QStringLiteral("agent_id"), QStringLiteral("mac-example")},
            {QStringLiteral("agent_version"), QStringLiteral("0.1.0")},
            {QStringLiteral("name"), QStringLiteral("Tepy Mac")},
            {QStringLiteral("platform"), QStringLiteral("darwin")},
            {QStringLiteral("session"), QString(32, QChar(u'a'))},
            {QStringLiteral("sequence"), 1},
            {QStringLiteral("observed_at"), now},
            {QStringLiteral("valid_until"), now + 30000},
            {QStringLiteral("uptime_seconds"), 1},
            {QStringLiteral("mqtt"), QJsonObject{{QStringLiteral("configured"), true},
                                                 {QStringLiteral("connected"), true}}},
            {QStringLiteral("user_session"),
             QJsonObject{{QStringLiteral("available"), true},
                         {QStringLiteral("on_console"), true},
                         {QStringLiteral("login_done"), true},
                         {QStringLiteral("lock_state"), QStringLiteral("unknown")},
                         {QStringLiteral("lock_source"), QStringLiteral("unavailable")}}},
            {QStringLiteral("hid"), QJsonObject{{QStringLiteral("available"), true},
                                                {QStringLiteral("state"), QStringLiteral("absent")},
                                                {QStringLiteral("target_device_id"), QString()},
                                                {QStringLiteral("devices"), QJsonArray()}}},
            {QStringLiteral("power"),
             QJsonObject{{QStringLiteral("monitoring"), true},
                         {QStringLiteral("state"), QStringLiteral("awake")},
                         {QStringLiteral("last_event"), QStringLiteral("none")},
                         {QStringLiteral("last_event_at"), 0},
                         {QStringLiteral("wake_count"), 0}}},
            {QStringLiteral("diagnostics"), QJsonArray()}};
}
QByteArray jsonResponse(const QJsonObject &result) {
    const auto bytes = QJsonDocument(result).toJson(QJsonDocument::Compact);
    return QByteArray("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ") +
           QByteArray::number(bytes.size()) + "\r\nConnection: close\r\n\r\n" + bytes;
}
QJsonObject windowResult(const QByteArray &request, unsigned now) {
    if (request.startsWith("GET /api/v1/status "))
        return {{QStringLiteral("v"), 1},
                {QStringLiteral("device_id"), QStringLiteral("aabbccddeeff")},
                {QStringLiteral("firmware"), QStringLiteral("0.2.0")},
                {QStringLiteral("now"), static_cast<int>(now)},
                {QStringLiteral("wifi"),
                 QJsonObject{{QStringLiteral("connected"), true},
                             {QStringLiteral("ip"), QStringLiteral("192.0.2.1")}}}};
    if (request.startsWith("GET /api/v1/config "))
        return config();
    return {{QStringLiteral("ok"), true}, {QStringLiteral("reboot_required"), true}};
}
class EnabledEvents final : public QObject {
  public:
    unsigned changes{};
    bool eventFilter(QObject *, QEvent *event) override {
        if (event->type() == QEvent::EnabledChange)
            ++changes;
        return false;
    }
};
class CountingStyle final : public QProxyStyle {
  public:
    CountingStyle() : QProxyStyle(QStyleFactory::create(QStringLiteral("Fusion"))) {}
    unsigned polishes{};
    void polish(QWidget *widget) override {
        ++polishes;
        QProxyStyle::polish(widget);
    }
};
class HttpFixture {
  public:
    QTcpServer server;
    QByteArray received;
    QByteArray response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: "
                          "11\r\nConnection: close\r\n\r\n{\"ok\":true}";
    unsigned hits{};
    unsigned sentResponses{};
    int delayMs{};
    std::function<QByteArray(const QByteArray &)> responder;
    HttpFixture() {
        server.listen(QHostAddress::LocalHost, 0);
        QObject::connect(&server, &QTcpServer::newConnection, &server, [this] {
            auto *socket = server.nextPendingConnection();
            auto data = std::make_shared<QByteArray>();
            QObject::connect(socket, &QTcpSocket::readyRead, socket, [this, socket, data] {
                *data += socket->readAll();
                const auto split = data->indexOf("\r\n\r\n");
                if (split < 0)
                    return;
                qint64 length = 0;
                for (auto line : data->left(split).split('\n'))
                    if (line.toLower().startsWith("content-length:"))
                        length = line.mid(15).trimmed().toLongLong();
                if (data->size() < split + 4 + length)
                    return;
                received = *data;
                ++hits;
                socket->disconnect(&server);
                const auto bytes = responder ? responder(*data) : response;
                QTimer::singleShot(delayMs, socket, [this, socket, bytes] {
                    ++sentResponses;
                    socket->write(bytes);
                    socket->disconnectFromHost();
                });
            });
            QObject::connect(socket, &QTcpSocket::disconnected, socket, &QObject::deleteLater);
        });
    }
    QString address() const {
        return QStringLiteral("http://127.0.0.1:%1").arg(server.serverPort());
    }
};
} // namespace
class DesktopTests : public QObject {
    Q_OBJECT
  private slots:
    void initTestCase() {
        tepy::desktop::ConnectionStore::setEnabled(false);
#ifdef Q_OS_WIN
        // The offscreen platform does not enumerate Windows system fonts.
        const auto fontId =
            QFontDatabase::addApplicationFont(QStringLiteral("C:/Windows/Fonts/msyh.ttc"));
        if (fontId >= 0)
            QApplication::setFont(
                QFont(QFontDatabase::applicationFontFamilies(fontId).first(), 10));
#endif
    }
    void framing() {
        FrameDecoder decoder;
        QList<QJsonObject> frames;
        const auto receive = [&](auto frame) { frames << frame; };
        decoder.feed("boot log\nAdmin token: never-display-this\n@tep", receive);
        decoder.feed("y:{\"v\":1,\"ok\":true}\r\n@tepy:bad\n", receive);
        QCOMPARE(frames.size(), 1);
        QVERIFY(frames[0].value(QStringLiteral("ok")).toBool());
        decoder.feed(QByteArray("@tepy:") + QByteArray(maxFrameBytes + 10, 'x') +
                         "@tepy:{}\n@tepy:{}\n",
                     receive);
        QCOMPARE(frames.size(), 2);
        const auto request = serialRequest(QStringLiteral("test-1"), QStringLiteral("status.get"),
                                           QStringLiteral("ExampleAdminTokenOnly0000"), {});
        const auto obj = QJsonDocument::fromJson(request.mid(6)).object();
        QCOMPARE(obj.value(QStringLiteral("v")).toInt(), 1);
        QCOMPARE(obj.value(QStringLiteral("method")).toString(), QStringLiteral("status.get"));
    }
    void urls() {
        QString error;
        QVERIFY(deviceUrl(QStringLiteral("192.168.4.1"), error).isValid());
        QVERIFY(error.isEmpty());
        QVERIFY(deviceUrl(QStringLiteral("http://user:pass@host"), error).isEmpty());
        QVERIFY(deviceUrl(QStringLiteral("mqtt://broker"), error).isEmpty());
        QVERIFY(deviceUrl(QStringLiteral("http://host/path"), error).isEmpty());
        QVERIFY(deviceUrl(QStringLiteral("http://host?secret=value"), error).isEmpty());
        QCOMPARE(routeFor(QStringLiteral("config.patch")).verb, QByteArray("PATCH"));
    }
    void secretHandling() {
        ConfigForm form;
        QVERIFY(form.load(config()));
        QString error;
        auto patch = form.patch(error);
        QVERIFY(error.isEmpty());
        QVERIFY(
            !patch.value(QStringLiteral("wifi")).toObject().contains(QStringLiteral("password")));
        QVERIFY(
            !patch.value(QStringLiteral("mqtt")).toObject().contains(QStringLiteral("password")));
        QVERIFY(!patch.contains(QStringLiteral("admin_password")));
        auto *secret = form.findChild<SecretField *>(QStringLiteral("wifiPassword"));
        QVERIFY(secret);
        secret->mode()->setCurrentIndex(1);
        secret->editor()->setText(QStringLiteral("1234567"));
        form.patch(error);
        QVERIFY(!error.isEmpty());
        secret->editor()->setText(QStringLiteral("example123"));
        patch = form.patch(error);
        QVERIFY(error.isEmpty());
        QCOMPARE(patch.value(QStringLiteral("wifi"))
                     .toObject()
                     .value(QStringLiteral("password"))
                     .toString(),
                 QStringLiteral("example123"));
        secret->mode()->setCurrentIndex(2);
        patch = form.patch(error);
        QVERIFY(
            patch.value(QStringLiteral("wifi")).toObject().contains(QStringLiteral("password")));
        QCOMPARE(patch.value(QStringLiteral("wifi"))
                     .toObject()
                     .value(QStringLiteral("password"))
                     .toString(),
                 QString());
        form.setSsid(QString(12, QChar(0x4e2d)));
        form.patch(error);
        QVERIFY(!error.isEmpty());
        form.clearSecrets();
        QVERIFY(secret->editor()->text().isEmpty());
        QCOMPARE(secret->mode()->currentIndex(), 0);
    }
    void imageValidation() {
        QTemporaryDir dir;
        const auto path = dir.filePath(QStringLiteral("app.bin"));
        ImageInfo info;
        QString error;
        QVERIFY(write(path, appImage()));
        QVERIFY(inspectApplication(path, info, error));
        QCOMPARE(info.version, QStringLiteral("0.2.0"));
        auto bytes = appImage();
        bytes[12] = 0;
        QVERIFY(write(path, bytes));
        QVERIFY(!inspectApplication(path, info, error));
        bytes = appImage();
        bytes.replace(80, 4, "evil");
        QVERIFY(write(path, bytes));
        QVERIFY(!inspectApplication(path, info, error));
        QVERIFY(write(path, QByteArray(100, '\0')));
        QVERIFY(!inspectApplication(path, info, error));
    }
    void flashPreservesNvs() {
        QTemporaryDir dir;
        QVERIFY(write(dir.filePath(QStringLiteral("boot.bin")), QByteArray(4096, 'b')));
        QVERIFY(write(dir.filePath(QStringLiteral("part.bin")), QByteArray(4096, 'p')));
        QVERIFY(write(dir.filePath(QStringLiteral("ota.bin")), QByteArray(8192, 'o')));
        QVERIFY(write(dir.filePath(QStringLiteral("app.bin")), appImage()));
        QJsonObject files{{QStringLiteral("0x0"), QStringLiteral("boot.bin")},
                          {QStringLiteral("0x8000"), QStringLiteral("part.bin")},
                          {QStringLiteral("0x19000"), QStringLiteral("ota.bin")},
                          {QStringLiteral("0x20000"), QStringLiteral("app.bin")}};
        QJsonObject manifest{{QStringLiteral("flash_files"), files},
                             {QStringLiteral("extra_esptool_args"),
                              QJsonObject{{QStringLiteral("chip"), QStringLiteral("esp32s3")}}},
                             {QStringLiteral("flash_settings"),
                              QJsonObject{{QStringLiteral("flash_mode"), QStringLiteral("dio")},
                                          {QStringLiteral("flash_freq"), QStringLiteral("80m")},
                                          {QStringLiteral("flash_size"), QStringLiteral("16MB")}}}};
        const auto path = dir.filePath(QStringLiteral("flasher_args.json"));
        QVERIFY(write(path, QJsonDocument(manifest).toJson()));
        QStringList args;
        QString error;
        QVERIFY(flashArguments(path, QStringLiteral("COM7"), args, error));
        QVERIFY(!args.contains(QStringLiteral("erase-flash")));
        QVERIFY(!args.contains(QStringLiteral("--erase-all")));
        QVERIFY(args.contains(QStringLiteral("0x20000")));
        QVERIFY(!args.contains(QStringLiteral("0x9000")));
        files.insert(QStringLiteral("0x9000"), QStringLiteral("boot.bin"));
        manifest.insert(QStringLiteral("flash_files"), files);
        QVERIFY(write(path, QJsonDocument(manifest).toJson()));
        QVERIFY(!flashArguments(path, QStringLiteral("COM7"), args, error));
        files.remove(QStringLiteral("0x9000"));
        files.insert(QStringLiteral("0x0"), QStringLiteral("../elsewhere.bin"));
        manifest.insert(QStringLiteral("flash_files"), files);
        QVERIFY(write(path, QJsonDocument(manifest).toJson()));
        QVERIFY(!flashArguments(path, QStringLiteral("COM7"), args, error));
    }
    void httpRoundTrip() {
        HttpFixture fixture;
        DeviceClient client;
        QSignalSpy success(&client, &DeviceClient::succeeded);
        QVERIFY(client.connectHttp(fixture.address(), QStringLiteral("ExampleAdminTokenOnly0000")));
        const QJsonObject patch{{QStringLiteral("v"), 1},
                                {QStringLiteral("wifi"),
                                 QJsonObject{{QStringLiteral("ssid"), QStringLiteral("Example")}}}};
        QVERIFY(client.request(QStringLiteral("config.patch"), patch));
        QVERIFY(!client.request(QStringLiteral("reboot")));
        QTRY_COMPARE(success.size(), 1);
        QVERIFY(fixture.received.startsWith("PATCH /api/v1/config HTTP/1.1\r\n"));
        QVERIFY(fixture.received.contains("Authorization: Bearer ExampleAdminTokenOnly0000"));
        const auto split = fixture.received.indexOf("\r\n\r\n");
        QCOMPARE(QJsonDocument::fromJson(fixture.received.mid(split + 4)).object(), patch);
        QCOMPARE(fixture.hits, 1u);
        QVERIFY(!client.busy());
    }
    void foregroundPreemptsBackgroundRead() {
        HttpFixture fixture;
        fixture.delayMs = 300;
        DeviceClient client;
        QSignalSpy success(&client, &DeviceClient::succeeded),
            failed(&client, &DeviceClient::failed);
        QVERIFY(client.connectHttp(fixture.address(), QStringLiteral("ExampleAdminTokenOnly0000")));
        QVERIFY(client.request(QStringLiteral("status.get"), {}, RequestMode::Background));
        QVERIFY(client.busy());
        QVERIFY(!client.exclusiveBusy());
        QTRY_COMPARE(fixture.hits, 1u);
        const QJsonObject patch{
            {QStringLiteral("v"), 1},
            {QStringLiteral("wifi"),
             QJsonObject{{QStringLiteral("ssid"), QStringLiteral("EditedWhilePolling")}}}};
        QVERIFY(client.request(QStringLiteral("config.patch"), patch));
        QVERIFY(client.exclusiveBusy());
        QVERIFY(!client.request(QStringLiteral("status.get"), {}, RequestMode::Background));
        QVERIFY(!client.request(QStringLiteral("reboot")));
        QTRY_COMPARE(fixture.hits, 2u);
        QTRY_COMPARE(success.size(), 1);
        QCOMPARE(success[0][0].toString(), QStringLiteral("config.patch"));
        QVERIFY(failed.isEmpty());
        QVERIFY(!client.busy());
        QVERIFY(fixture.received.startsWith("PATCH /api/v1/config HTTP/1.1\r\n"));
        const auto split = fixture.received.indexOf("\r\n\r\n");
        QCOMPARE(QJsonDocument::fromJson(fixture.received.mid(split + 4)).object(), patch);
        QCOMPARE(fixture.hits, 2u);
    }
    void backgroundCannotSendMutations() {
        HttpFixture fixture;
        DeviceClient client;
        QSignalSpy failed(&client, &DeviceClient::failed);
        QVERIFY(client.connectHttp(fixture.address(), QStringLiteral("ExampleAdminTokenOnly0000")));
        QVERIFY(!client.request(QStringLiteral("config.patch"), {{QStringLiteral("v"), 1}},
                                RequestMode::Background));
        QVERIFY(!client.request(QStringLiteral("reboot"), {}, RequestMode::Background));
        QCOMPARE(failed.size(), 2);
        QCOMPARE(fixture.hits, 0u);
        QVERIFY(!client.busy());
    }
    void unchangedStyleIsNotReapplied() {
        CountingStyle style;
        QWidget widget;
        widget.setStyle(&style);
        widget.ensurePolished();
        ui::property(&widget, "state", QStringLiteral("connected"));
        const auto polishes = style.polishes;
        ui::property(&widget, "state", QStringLiteral("connected"));
        QCOMPARE(style.polishes, polishes);
        ui::property(&widget, "state", QStringLiteral("disconnected"));
        QVERIFY(style.polishes > polishes);
    }
    void httpFailures_data() {
        QTest::addColumn<QByteArray>("response");
        QTest::addColumn<QString>("message");
        QTest::newRow("auth") << QByteArray(
                                     "HTTP/1.1 401 Unauthorized\r\nContent-Length: "
                                     "24\r\nConnection: close\r\n\r\n{\"error\":\"unauthorized\"}")
                              << QStringLiteral("管理口令");
        QTest::newRow("redirect")
            << QByteArray("HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:9/\r\nContent-Length: "
                          "0\r\nConnection: close\r\n\r\n")
            << QStringLiteral("重定向");
        QTest::newRow("invalid-json")
            << QByteArray("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n[]")
            << QStringLiteral("回复格式");
    }
    void switchingTransportIgnoresOldSerialEvents() {
        HttpFixture fixture;
        DeviceClient client;
        QSignalSpy success(&client, &DeviceClient::succeeded),
            failed(&client, &DeviceClient::failed);
        client.connectSerial({}, QStringLiteral("ExampleAdminTokenOnly0000"));
        QTest::qSleep(30); // Let the worker enqueue its failure without processing GUI events.
        QVERIFY(client.connectHttp(fixture.address(), QStringLiteral("ExampleAdminTokenOnly0000")));
        QVERIFY(client.request(QStringLiteral("reboot")));
        QTRY_COMPARE(success.size(), 1);
        QVERIFY(failed.isEmpty());
        QVERIFY(client.isConnected());
    }
    void httpFailures() {
        QFETCH(QByteArray, response);
        QFETCH(QString, message);
        HttpFixture fixture;
        fixture.response = response;
        DeviceClient client;
        QSignalSpy failed(&client, &DeviceClient::failed);
        QVERIFY(client.connectHttp(fixture.address(), QStringLiteral("ExampleAdminTokenOnly0000")));
        QVERIFY(client.request(QStringLiteral("status.get")));
        QTRY_COMPARE(failed.size(), 1);
        QVERIFY(failed[0][1].toString().contains(message));
        QCOMPARE(fixture.hits, 1u);
        QVERIFY(!client.busy());
    }
    void httpUpload() {
        QTemporaryDir dir;
        const auto path = dir.filePath(QStringLiteral("app.bin"));
        const auto image = appImage();
        QVERIFY(write(path, image));
        HttpFixture fixture;
        DeviceClient client;
        QSignalSpy success(&client, &DeviceClient::succeeded);
        QVERIFY(client.connectHttp(fixture.address(), QStringLiteral("ExampleAdminTokenOnly0000")));
        QVERIFY(client.upload(path));
        QTRY_COMPARE(success.size(), 1);
        QVERIFY(fixture.received.startsWith("POST /api/v1/ota HTTP/1.1\r\n"));
        QVERIFY(fixture.received.contains("Content-Type: application/octet-stream"));
        const auto split = fixture.received.indexOf("\r\n\r\n");
        QCOMPARE(fixture.received.mid(split + 4), image);
        QCOMPARE(fixture.hits, 1u);
    }
    void timeoutNoRetry() {
        QTcpServer server;
        QVERIFY(server.listen(QHostAddress::LocalHost, 0));
        unsigned hits = 0;
        connect(&server, &QTcpServer::newConnection, &server, [&] {
            ++hits;
            auto *socket = server.nextPendingConnection();
            socket->setParent(&server);
            connect(socket, &QTcpSocket::readyRead, socket, [socket] { socket->readAll(); });
        });
        DeviceClient client;
        QSignalSpy failure(&client, &DeviceClient::failed);
        QVERIFY(client.connectHttp(QStringLiteral("http://127.0.0.1:%1").arg(server.serverPort()),
                                   QStringLiteral("ExampleAdminTokenOnly0000")));
        QVERIFY(client.request(QStringLiteral("config.patch"), {{QStringLiteral("v"), 1}}));
        QTRY_COMPARE_WITH_TIMEOUT(failure.size(), 1, 17000);
        QCOMPARE(hits, 1u);
        QVERIFY(failure[0][1].toString().contains(QStringLiteral("不会自动重试")));
        QVERIFY(!client.busy());
    }
    void builtApplicationOptional() {
        const auto path = qEnvironmentVariable("TEPY_TEST_APPLICATION");
        if (path.isEmpty())
            QSKIP("Set TEPY_TEST_APPLICATION to check the actual firmware image.");
        ImageInfo info;
        QString error;
        QVERIFY2(inspectApplication(path, info, error), qPrintable(error));
        QCOMPARE(info.project, QStringLiteral("tepy"));
    }
    void windowSmoke() {
        MainWindow window;
        QVERIFY(window.windowTitle().contains(QStringLiteral("Tepy")));
        const auto preview = qEnvironmentVariable("TEPY_TEST_PREVIEW");
        if (!preview.isEmpty()) {
            window.show();
            QTest::qWait(100);
            auto *tabs = window.findChild<QTabWidget *>();
            for (int i = 0; i < tabs->count(); ++i) {
                tabs->setCurrentIndex(i);
                QApplication::processEvents();
                QVERIFY(window.grab().save(preview + QString::number(i) + QStringLiteral(".png")));
            }
        }
    }
    void windowConnectFlow() {
        HttpFixture fixture;
        fixture.responder = [](const QByteArray &request) {
            QJsonObject result;
            if (request.startsWith("GET /api/v1/status ")) {
                result = {{QStringLiteral("v"), 1},
                          {QStringLiteral("device_id"), QStringLiteral("aabbccddeeff")},
                          {QStringLiteral("firmware"), QStringLiteral("0.2.0")},
                          {QStringLiteral("wifi"),
                           QJsonObject{{QStringLiteral("connected"), true},
                                       {QStringLiteral("ip"), QStringLiteral("192.0.2.1")}}}};
            } else
                result = config();
            const auto bytes = QJsonDocument(result).toJson(QJsonDocument::Compact);
            return QByteArray(
                       "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ") +
                   QByteArray::number(bytes.size()) + "\r\nConnection: close\r\n\r\n" + bytes;
        };
        MainWindow window;
        auto *address = window.findChild<QLineEdit *>(QStringLiteral("deviceAddress"));
        auto *token = window.findChild<QLineEdit *>(QStringLiteral("managementToken"));
        auto *button = window.findChild<QPushButton *>(QStringLiteral("connectDevice"));
        auto *save = window.findChild<QPushButton *>(QStringLiteral("saveConfiguration"));
        QVERIFY(address && token && button && save);
        QVERIFY(!save->isEnabled());
        address->setText(fixture.address());
        token->setText(QStringLiteral("ExampleAdminTokenOnly0000"));
        QCOMPARE(token->echoMode(), QLineEdit::Password);
        button->click();
        QTRY_VERIFY(save->isEnabled());
        QVERIFY(!token->isEnabled());
        QCOMPARE(fixture.hits, 2u);
        const auto preview = qEnvironmentVariable("TEPY_TEST_PREVIEW");
        if (!preview.isEmpty()) {
            window.show();
            QTest::qWait(80);
            auto *tabs = window.findChild<QTabWidget *>();
            for (int i = 0; i < tabs->count(); ++i) {
                tabs->setCurrentIndex(i);
                QApplication::processEvents();
                QVERIFY(window.grab().save(preview + QStringLiteral("-connected-") +
                                           QString::number(i) + QStringLiteral(".png")));
            }
            window.resize(1040, 760);
            tabs->setCurrentIndex(1);
            QApplication::processEvents();
            QVERIFY(window.grab().save(preview + QStringLiteral("-compact.png")));
        }
    }
    void pollingKeepsEditorAndButtonsStable() {
        HttpFixture fixture;
        fixture.responder = [&](const QByteArray &request) {
            return jsonResponse(windowResult(request, fixture.hits));
        };
        MainWindow window;
        window.show();
        auto *address = window.findChild<QLineEdit *>(QStringLiteral("deviceAddress"));
        auto *token = window.findChild<QLineEdit *>(QStringLiteral("managementToken"));
        auto *connectButton = window.findChild<QPushButton *>(QStringLiteral("connectDevice"));
        auto *save = window.findChild<QPushButton *>(QStringLiteral("saveConfiguration"));
        auto *form = window.findChild<ConfigForm *>();
        auto *ssid = window.findChild<QLineEdit *>(QStringLiteral("wifiSsid"));
        auto *details = window.findChild<QPlainTextEdit *>(QStringLiteral("stateCode"));
        auto *showDetails = window.findChild<QToolButton *>(QStringLiteral("toggleStateDetails"));
        auto *tabs = window.findChild<QTabWidget *>();
        QVERIFY(address && token && connectButton && save && form && ssid && details &&
                showDetails && tabs);
        address->setText(fixture.address());
        token->setText(QStringLiteral("ExampleAdminTokenOnly0000"));
        connectButton->click();
        QTRY_VERIFY(save->isEnabled());
        QCOMPARE(fixture.hits, 2u);
        tabs->setCurrentIndex(1);
        ssid->setText(QStringLiteral("Draft network"));
        ssid->setFocus();
        ssid->setSelection(0, 5);
        QTRY_VERIFY(ssid->hasFocus());
        EnabledEvents events;
        form->installEventFilter(&events);
        save->installEventFilter(&events);
        ssid->installEventFilter(&events);
        QSignalSpy documentChanges(details->document(), &QTextDocument::contentsChanged);
        fixture.delayMs = 400;
        // Exercise the real three-second timer, including the entire request in flight.
        QTRY_COMPARE_WITH_TIMEOUT(fixture.hits, 3u, 5000);
        QVERIFY(save->isEnabled());
        QVERIFY(form->isEnabled());
        QVERIFY(ssid->hasFocus());
        QTRY_COMPARE_WITH_TIMEOUT(fixture.sentResponses, 3u, 2000);
        QCOMPARE(events.changes, 0u);
        QCOMPARE(ssid->text(), QStringLiteral("Draft network"));
        QCOMPARE(ssid->selectedText(), QStringLiteral("Draft"));
        QVERIFY(ssid->hasFocus());
        QCOMPARE(documentChanges.size(), 0);
        tabs->setCurrentIndex(0);
        showDetails->click();
        QTRY_VERIFY(details->isVisible());
        QTRY_COMPARE(QJsonDocument::fromJson(details->toPlainText().toUtf8())
                         .object()
                         .value(QStringLiteral("now"))
                         .toInt(),
                     3);
        auto cursor = details->textCursor();
        cursor.setPosition(0);
        cursor.setPosition(20, QTextCursor::KeepAnchor);
        details->setTextCursor(cursor);
        const auto selected = details->textCursor().selectedText();
        const auto contents = details->toPlainText();
        QTRY_COMPARE_WITH_TIMEOUT(fixture.sentResponses, 4u, 4500);
        QCOMPARE(details->toPlainText(), contents);
        QCOMPARE(details->textCursor().selectedText(), selected);
    }
    void hardwareSerialOptional() {
        const auto port = qEnvironmentVariable("TEPY_TEST_SERIAL");
        if (port.isEmpty())
            QSKIP("Set TEPY_TEST_SERIAL to run the read-only hardware authentication check.");
        DeviceClient client;
        QSignalSpy opened(&client, &DeviceClient::connected),
            failed(&client, &DeviceClient::failed);
        client.connectSerial(port, QStringLiteral("DeliberatelyWrongToken0000"));
        QTRY_COMPARE_WITH_TIMEOUT(opened.size(), 1, 5000);
        QVERIFY(client.request(QStringLiteral("status.get")));
        QTRY_COMPARE_WITH_TIMEOUT(failed.size(), 1, 17000);
        QVERIFY2(failed[0][1].toString().contains(QStringLiteral("管理口令")),
                 qPrintable(failed[0][1].toString()));
    }
    void agentStateValidation() {
        QString error;
        const qint64 now = 1800000000000;
        auto state = agentState(now);
        QVERIFY(validateAgentState(state, now, error));
        auto stale = state;
        stale.insert(QStringLiteral("valid_until"), now);
        QVERIFY(!validateAgentState(stale, now, error));
        auto malformed = state;
        malformed.insert(QStringLiteral("session"), QStringLiteral("bad"));
        QVERIFY(!validateAgentState(malformed, now, error));
        malformed = state;
        auto user = malformed.value(QStringLiteral("user_session")).toObject();
        user.insert(QStringLiteral("lock_state"), QJsonValue());
        malformed.insert(QStringLiteral("user_session"), user);
        QVERIFY(!validateAgentState(malformed, now, error));
        malformed = state;
        auto hid = malformed.value(QStringLiteral("hid")).toObject();
        hid.insert(QStringLiteral("state"), QStringLiteral("registered"));
        malformed.insert(QStringLiteral("hid"), hid);
        QVERIFY(!validateAgentState(malformed, now, error));
    }
    void agentHTTPReadOnly() {
        HttpFixture fixture;
        fixture.responder = [](const QByteArray &) {
            return jsonResponse(agentState(QDateTime::currentMSecsSinceEpoch()));
        };
        AgentClient client;
        QSignalSpy updated(&client, &AgentClient::updated), failed(&client, &AgentClient::failed);
        QVERIFY(client.start(fixture.address(), QString(64, QChar(u'a'))));
        QTRY_COMPARE(updated.size(), 1);
        QVERIFY(failed.isEmpty());
        QVERIFY(client.active());
        QVERIFY(fixture.received.startsWith("GET /api/v1/agent/status HTTP/1.1\r\n"));
        QVERIFY(fixture.received.contains("Authorization: Bearer aaaaa"));
        client.stop();
        QVERIFY(!client.active());
    }
    void agentRejectsWrongIdentity() {
        HttpFixture fixture;
        unsigned responseCount = 0;
        fixture.responder = [&](const QByteArray &) {
            auto state = agentState(QDateTime::currentMSecsSinceEpoch());
            if (++responseCount > 1)
                state.insert(QStringLiteral("agent_id"), QStringLiteral("another-mac"));
            return jsonResponse(state);
        };
        AgentClient client;
        QSignalSpy updated(&client, &AgentClient::updated), failed(&client, &AgentClient::failed);
        QVERIFY(client.start(fixture.address(), QString(64, QChar(u'a'))));
        QTRY_COMPARE(updated.size(), 1);
        client.refresh();
        QTRY_COMPARE(failed.size(), 1);
        QVERIFY(!client.active());
        QVERIFY(failed[0][0].toString().contains(QStringLiteral("身份")));
    }
    void agentPageConnectFlow() {
        HttpFixture fixture;
        fixture.responder = [](const QByteArray &) {
            return jsonResponse(agentState(QDateTime::currentMSecsSinceEpoch()));
        };
        MainWindow window;
        auto *tabs = window.findChild<QTabWidget *>();
        QCOMPARE(tabs->count(), 6);
        tabs->setCurrentIndex(4);
        window.show();
        auto *address = window.findChild<QLineEdit *>(QStringLiteral("macAgentAddress"));
        auto *token = window.findChild<QLineEdit *>(QStringLiteral("macAgentToken"));
        auto *connect = window.findChild<QPushButton *>(QStringLiteral("connectMacAgent"));
        QVERIFY(address && token && connect);
        address->setText(fixture.address());
        token->setText(QString(64, QChar(u'a')));
        connect->click();
        QTRY_COMPARE(fixture.hits, 1u);
        QTRY_VERIFY(!connect->isEnabled());
        QCOMPARE(token->echoMode(), QLineEdit::Password);
        const auto preview = qEnvironmentVariable("TEPY_TEST_PREVIEW");
        if (!preview.isEmpty()) {
            QTest::qWait(60);
            QVERIFY(window.grab().save(preview + QStringLiteral("-mac-agent.png")));
        }
    }
    void realMacAgentOptional() {
        const auto address = qEnvironmentVariable("TEPY_TEST_AGENT_URL"),
                   token = qEnvironmentVariable("TEPY_TEST_AGENT_TOKEN");
        if (address.isEmpty() || token.isEmpty())
            QSKIP("Set TEPY_TEST_AGENT_URL / TOKEN for a read-only real Mac check.");
        AgentClient client;
        QSignalSpy updated(&client, &AgentClient::updated), failed(&client, &AgentClient::failed);
        QVERIFY(client.start(address, token));
        QTRY_VERIFY_WITH_TIMEOUT(!updated.isEmpty() || !failed.isEmpty(), 7000);
        QVERIFY2(failed.isEmpty(), failed.isEmpty() ? "" : qPrintable(failed[0][0].toString()));
        QCOMPARE(updated.size(), 1);
        const auto preview = qEnvironmentVariable("TEPY_TEST_PREVIEW");
        if (!preview.isEmpty()) {
            MainWindow window;
            window.findChild<QTabWidget *>()->setCurrentIndex(4);
            window.show();
            auto *pageClient = window.findChild<AgentClient *>();
            QVERIFY(pageClient);
            QSignalSpy pageUpdated(pageClient, &AgentClient::updated);
            window.findChild<QLineEdit *>(QStringLiteral("macAgentAddress"))->setText(address);
            window.findChild<QLineEdit *>(QStringLiteral("macAgentToken"))->setText(token);
            window.findChild<QPushButton *>(QStringLiteral("connectMacAgent"))->click();
            QTRY_COMPARE_WITH_TIMEOUT(pageUpdated.size(), 1, 7000);
            QTest::qWait(60);
            QVERIFY(window.grab().save(preview + QStringLiteral("-mac-live.png")));
        }
    }
};
QTEST_MAIN(DesktopTests)
#include "desktop_tests.moc"
