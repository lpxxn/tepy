#include "protocol.hpp"
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QMap>
#include <QtEndian>

namespace tepy::desktop {
void FrameDecoder::reset() {
    line_.fill('\0');
    line_.clear();
    dropping_ = false;
}
void FrameDecoder::feed(const QByteArray &bytes,
                        const std::function<void(const QJsonObject &)> &receive) {
    for (char c : bytes) {
        if (c == '\n') {
            if (!dropping_) {
                if (line_.endsWith('\r'))
                    line_.chop(1);
                if (line_.startsWith("@tepy:") && line_.size() <= maxFrameBytes + 6) {
                    const auto doc = QJsonDocument::fromJson(line_.mid(6));
                    if (doc.isObject())
                        receive(doc.object());
                }
            }
            reset();
        } else if (!dropping_) {
            if (line_.size() >= maxFrameBytes + 7) {
                reset();
                dropping_ = true;
            } else
                line_ += c;
        }
    }
}
Route routeFor(const QString &method) {
    static const QMap<QString, Route> routes{
        {QStringLiteral("status.get"), {"GET", QStringLiteral("/api/v1/status")}},
        {QStringLiteral("config.get"), {"GET", QStringLiteral("/api/v1/config")}},
        {QStringLiteral("config.patch"), {"PATCH", QStringLiteral("/api/v1/config")}},
        {QStringLiteral("wifi.scan"), {"GET", QStringLiteral("/api/v1/wifi/scan")}},
        {QStringLiteral("ble.pair"), {"POST", QStringLiteral("/api/v1/ble/pair")}},
        {QStringLiteral("ble.passkey"), {"POST", QStringLiteral("/api/v1/ble/passkey")}},
        {QStringLiteral("ble.clear"), {"POST", QStringLiteral("/api/v1/ble/clear")}},
        {QStringLiteral("reboot"), {"POST", QStringLiteral("/api/v1/reboot")}}};
    return routes.value(method);
}
QUrl deviceUrl(const QString &input, QString &error) {
    auto value = input.trimmed();
    if (!value.contains(QStringLiteral("://")))
        value.prepend(QStringLiteral("http://"));
    const QUrl url(value, QUrl::StrictMode);
    if (!url.isValid() || url.host().isEmpty() || !url.userInfo().isEmpty() || url.hasQuery() ||
        url.hasFragment() || (!url.path().isEmpty() && url.path() != QStringLiteral("/")) ||
        (url.scheme() != QStringLiteral("http") && url.scheme() != QStringLiteral("https"))) {
        error =
            QStringLiteral("请输入设备 IP 或主机名，例如 http://192.168.4.1；不要填写 MQTT 地址。");
        return {};
    }
    error.clear();
    return url;
}
QByteArray serialRequest(const QString &id, const QString &method, const QString &token,
                         const QJsonObject &params) {
    const QJsonObject obj{{QStringLiteral("v"), 1},
                          {QStringLiteral("id"), id},
                          {QStringLiteral("method"), method},
                          {QStringLiteral("token"), token},
                          {QStringLiteral("params"), params}};
    return QByteArray("@tepy:") + QJsonDocument(obj).toJson(QJsonDocument::Compact) + '\n';
}
QString describeError(const QString &code) {
    static const QMap<QString, QString> messages{
        {QStringLiteral("unauthorized"),
         QStringLiteral("管理口令不正确；可在设备运行时长按 BOOT 三秒，从串口获取。")},
        {QStringLiteral("busy"), QStringLiteral("设备正在输入或升级，请稍后再操作。")},
        {QStringLiteral("already_bonded"),
         QStringLiteral("已有蓝牙绑定。更换 Mac 前请先显式清除绑定。")},
        {QStringLiteral("invalid_passkey"),
         QStringLiteral("配对码无效，或当前没有等待配对码的请求。")},
        {QStringLiteral("timeout"),
         QStringLiteral("设备未及时回复，结果尚未确认。请刷新状态，不会自动重试操作。")},
        {QStringLiteral("invalid_response"),
         QStringLiteral("设备回复格式不正确，请检查固件版本与连接地址。")},
        {QStringLiteral("redirect"),
         QStringLiteral("设备地址返回了重定向，请直接填写目标设备地址。")},
        {QStringLiteral("unsupported_version"),
         QStringLiteral("设备不支持此协议版本，请升级固件。")}};
    return messages.value(code, QStringLiteral("操作失败：%1").arg(code));
}
namespace {
QString imageString(const QByteArray &header, qsizetype offset) {
    const auto bytes = header.mid(offset, 32);
    const auto end = bytes.indexOf('\0');
    return QString::fromUtf8(end < 0 ? bytes : bytes.left(end));
}
} // namespace
bool inspectApplication(const QString &path, ImageInfo &info, QString &error) {
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly)) {
        error = QStringLiteral("无法读取应用镜像。");
        return false;
    }
    const auto header = file.read(288);
    if (file.size() <= 288 || file.size() > 4 * 1024 * 1024 || header.size() < 288 ||
        static_cast<quint8>(header[0]) != 0xe9 ||
        qFromLittleEndian<quint16>(header.constData() + 12) != 9 ||
        qFromLittleEndian<quint32>(header.constData() + 32) != 0xabcd5432) {
        error = QStringLiteral(
            "请选择 ESP32-S3 的应用镜像 tepy.bin（不超过 4 MiB），不要选择合并镜像或 bootloader。");
        return false;
    }
    info = {imageString(header, 48), imageString(header, 80)};
    if (info.project != QStringLiteral("tepy")) {
        error = QStringLiteral("镜像项目名不是 tepy。");
        return false;
    }
    error.clear();
    return true;
}
bool flashArguments(const QString &manifest, const QString &port, QStringList &args,
                    QString &error) {
    args.clear();
    QFile file(manifest);
    if (!file.open(QIODevice::ReadOnly) || file.size() > 65536) {
        error = QStringLiteral("无法读取 IDF flasher_args.json。");
        return false;
    }
    const auto doc = QJsonDocument::fromJson(file.readAll());
    const auto root = doc.object();
    if (root.value(QStringLiteral("extra_esptool_args"))
            .toObject()
            .value(QStringLiteral("chip"))
            .toString() != QStringLiteral("esp32s3")) {
        error = QStringLiteral("烧录清单的目标必须为 esp32s3。");
        return false;
    }
    const auto files = root.value(QStringLiteral("flash_files")).toObject();
    const QStringList offsets{QStringLiteral("0x0"), QStringLiteral("0x8000"),
                              QStringLiteral("0x19000"), QStringLiteral("0x20000")};
    if (files.size() != offsets.size() || port.isEmpty()) {
        error = QStringLiteral("烧录清单与 Tepy v1 分区布局不符。");
        return false;
    }
    const QDir dir(QFileInfo(manifest).absolutePath());
    QStringList paths;
    const QList<qint64> limits{0x8000, 0x1000, 0x2000, 4 * 1024 * 1024};
    for (int i = 0; i < offsets.size(); ++i) {
        const auto relative = files.value(offsets[i]).toString();
        const QFileInfo item(dir.filePath(relative));
        const auto canonical = item.canonicalFilePath();
        const auto inside = QDir(dir.canonicalPath()).relativeFilePath(canonical);
        if (relative.isEmpty() || canonical.isEmpty() || !item.isFile() ||
            inside == QStringLiteral("..") || inside.startsWith(QStringLiteral("../")) ||
            QDir::isAbsolutePath(inside) || item.size() <= 0 || item.size() > limits[i]) {
            error = QStringLiteral("烧录文件不存在、越过构建目录或超过分区大小。");
            return false;
        }
        paths << canonical;
    }
    ImageInfo image;
    if (!inspectApplication(paths[3], image, error))
        return false;
    const auto settings = root.value(QStringLiteral("flash_settings")).toObject();
    const auto mode = settings.value(QStringLiteral("flash_mode")).toString();
    const auto freq = settings.value(QStringLiteral("flash_freq")).toString();
    if ((mode != QStringLiteral("dio") && mode != QStringLiteral("qio")) ||
        freq != QStringLiteral("80m") ||
        settings.value(QStringLiteral("flash_size")).toString() != QStringLiteral("16MB")) {
        error = QStringLiteral("烧录清单与 N16R8 Flash 配置不符。");
        return false;
    }
    // Write separate segments: a padded merged BIN would erase NVS in the gaps.
    args = {QStringLiteral("-m"),
            QStringLiteral("esptool"),
            QStringLiteral("--chip"),
            QStringLiteral("esp32s3"),
            QStringLiteral("--port"),
            port,
            QStringLiteral("--baud"),
            QStringLiteral("460800"),
            QStringLiteral("write-flash"),
            QStringLiteral("--flash-mode"),
            mode,
            QStringLiteral("--flash-freq"),
            freq,
            QStringLiteral("--flash-size"),
            QStringLiteral("16MB")};
    for (int i = 0; i < offsets.size(); ++i)
        args << offsets[i] << paths[i];
    error.clear();
    return true;
}
} // namespace tepy::desktop
