#include "device_client.hpp"
#include <QFile>
#include <QJsonDocument>
#include <QNetworkProxy>
#include <QNetworkRequest>
#include <QUuid>

namespace tepy::desktop {
DeviceClient::DeviceClient(QObject *parent) : QObject(parent) {
    network_.setProxy(QNetworkProxy::NoProxy);
    timeout_.setSingleShot(true);
    connect(&timeout_, &QTimer::timeout, this, [this] {
        auto reply = reply_;
        reply_ = nullptr;
        auto message = describeError(QStringLiteral("timeout"));
        if (serial_)
            message += QStringLiteral(" USB 管理需要固件 0.2.0 以上和原生 USB 接口。");
        finish({}, message);
        if (reply) {
            reply->disconnect(this);
            reply->abort();
            reply->deleteLater();
        }
    });
}
DeviceClient::~DeviceClient() {
    blockSignals(true);
    disconnectDevice();
}
void DeviceClient::disconnectDevice() {
    ++generation_;
    timeout_.stop();
    if (reply_) {
        reply_->disconnect(this);
        reply_->abort();
        reply_->deleteLater();
        reply_ = nullptr;
    }
    if (serial_) {
        serial_->disconnect(this);
        serial_->stop();
        serial_->wait();
        delete serial_;
        serial_ = nullptr;
    }
    decoder_.reset();
    method_.clear();
    requestId_.clear();
    mode_ = RequestMode::Foreground;
    token_.clear();
    base_ = QUrl();
    connected_ = false;
    emit disconnected();
}
bool DeviceClient::connectHttp(const QString &address, const QString &token) {
    QString error;
    const auto url = deviceUrl(address, error);
    if (url.isEmpty()) {
        emit failed({}, error);
        return false;
    }
    disconnectDevice();
    base_ = url;
    token_ = token;
    connected_ = true;
    emit connected();
    return true;
}
void DeviceClient::connectSerial(const QString &port, const QString &token) {
    disconnectDevice();
    token_ = token;
    serial_ = new SerialPort(port, this);
    const auto generation = generation_;
    connect(serial_, &SerialPort::opened, this, [this, generation] {
        if (generation != generation_)
            return;
        connected_ = true;
        emit connected();
    });
    connect(serial_, &SerialPort::received, this, [this, generation](const QByteArray &bytes) {
        if (generation != generation_)
            return;
        // Boot logs and setup credentials are deliberately discarded, never displayed.
        decoder_.feed(bytes, [this](const QJsonObject &frame) { receive(frame); });
    });
    connect(serial_, &SerialPort::failed, this, [this, generation](const QString &message) {
        if (generation != generation_)
            return;
        const auto method = method_;
        disconnectDevice();
        emit failed(method, message);
    });
    serial_->start();
}
void DeviceClient::cancelBackground() {
    if (!busy() || mode_ != RequestMode::Background)
        return;
    timeout_.stop();
    const auto reply = reply_;
    reply_ = nullptr;
    method_.clear();
    requestId_.clear(); // A late serial reply can no longer match an active request.
    mode_ = RequestMode::Foreground;
    if (reply) {
        reply->disconnect(this); // abort() may immediately emit finished().
        reply->abort();
        reply->deleteLater();
    }
}
bool DeviceClient::begin(const QString &method, int timeoutMs, RequestMode mode) {
    if (!connected_ || (busy() && (exclusiveBusy() || mode == RequestMode::Background)))
        return false;
    if (token_.isEmpty()) {
        emit failed(method, QStringLiteral("请填写设备管理口令。"));
        return false;
    }
    cancelBackground();
    method_ = method;
    mode_ = mode;
    timeout_.start(timeoutMs);
    return true;
}
bool DeviceClient::request(const QString &method, const QJsonObject &params, RequestMode mode) {
    const auto route = routeFor(method);
    if (route.path.isEmpty()) {
        emit failed(method, QStringLiteral("未知管理操作。"));
        return false;
    }
    if (mode == RequestMode::Background && method != QStringLiteral("status.get") &&
        method != QStringLiteral("wifi.scan")) {
        emit failed(method, QStringLiteral("此操作不能作为后台刷新。"));
        return false;
    }
    if (!begin(method, 15000, mode))
        return false;
    if (serial_) {
        requestId_ = QUuid::createUuid().toString(QUuid::Id128);
        auto bytes = serialRequest(requestId_, method, token_, params);
        if (bytes.size() > maxFrameBytes + 7) {
            finish({}, QStringLiteral("配置内容过长。"));
            return false;
        }
        serial_->send(std::move(bytes));
    } else {
        auto url = base_;
        url.setPath(route.path);
        QNetworkRequest req(url);
        req.setAttribute(QNetworkRequest::RedirectPolicyAttribute,
                         QNetworkRequest::ManualRedirectPolicy);
        req.setRawHeader("Authorization", QByteArray("Bearer ") + token_.toUtf8());
        req.setHeader(QNetworkRequest::ContentTypeHeader, QStringLiteral("application/json"));
        const auto body =
            (method == QStringLiteral("config.patch") || method == QStringLiteral("ble.passkey"))
                ? QJsonDocument(params).toJson(QJsonDocument::Compact)
                : QByteArray();
        watch(network_.sendCustomRequest(req, route.verb, body));
    }
    return true;
}
void DeviceClient::watch(QNetworkReply *reply) {
    reply_ = reply;
    connect(reply, &QNetworkReply::uploadProgress, this, &DeviceClient::uploadProgress);
    connect(reply, &QNetworkReply::readyRead, this, [this, reply] {
        if (reply->bytesAvailable() > maxFrameBytes) {
            reply->disconnect(this);
            reply->abort();
            reply->deleteLater();
            reply_ = nullptr;
            finish({}, describeError(QStringLiteral("invalid_response")));
        }
    });
    connect(reply, &QNetworkReply::finished, this, [this, reply] {
        if (reply_ != reply)
            return;
        reply_ = nullptr;
        const auto code = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        const auto bytes = reply->read(maxFrameBytes + 1);
        const auto doc = QJsonDocument::fromJson(bytes);
        QString error;
        if (code >= 300 && code < 400)
            error = describeError(QStringLiteral("redirect"));
        else if (doc.isObject() && doc.object().contains(QStringLiteral("error")))
            error = describeError(doc.object().value(QStringLiteral("error")).toString());
        else if (reply->error() != QNetworkReply::NoError)
            error = reply->errorString();
        else if (code < 200 || code >= 300 || !doc.isObject() || bytes.size() > maxFrameBytes)
            error = describeError(QStringLiteral("invalid_response"));
        reply->deleteLater();
        finish(doc.object(), error);
    });
}
void DeviceClient::receive(const QJsonObject &frame) {
    if (!busy() || frame.value(QStringLiteral("id")).toString() != requestId_)
        return;
    if (frame.value(QStringLiteral("v")).toInt() != 1 ||
        !frame.value(QStringLiteral("ok")).isBool()) {
        finish({}, describeError(QStringLiteral("invalid_response")));
        return;
    }
    if (!frame.value(QStringLiteral("ok")).toBool()) {
        finish({}, describeError(frame.value(QStringLiteral("error")).toString()));
        return;
    }
    if (!frame.value(QStringLiteral("result")).isObject()) {
        finish({}, describeError(QStringLiteral("invalid_response")));
        return;
    }
    finish(frame.value(QStringLiteral("result")).toObject());
}
void DeviceClient::finish(QJsonObject result, QString error) {
    if (method_.isEmpty())
        return;
    timeout_.stop();
    const auto method = method_;
    method_.clear();
    requestId_.clear();
    mode_ = RequestMode::Foreground;
    if (error.isEmpty())
        emit succeeded(method, result);
    else
        emit failed(method, error);
}
bool DeviceClient::upload(const QString &path) {
    if (!isHttp()) {
        emit failed(QStringLiteral("ota"),
                    QStringLiteral("OTA 需要 HTTP 连接；USB 连接请使用串口刷机。"));
        return false;
    }
    ImageInfo info;
    QString error;
    if (!inspectApplication(path, info, error)) {
        emit failed(QStringLiteral("ota"), error);
        return false;
    }
    if (!begin(QStringLiteral("ota"), 120000))
        return false;
    auto *file = new QFile(path);
    if (!file->open(QIODevice::ReadOnly)) {
        delete file;
        finish({}, QStringLiteral("无法读取应用镜像。"));
        return false;
    }
    auto url = base_;
    url.setPath(QStringLiteral("/api/v1/ota"));
    QNetworkRequest req(url);
    req.setAttribute(QNetworkRequest::RedirectPolicyAttribute,
                     QNetworkRequest::ManualRedirectPolicy);
    req.setRawHeader("Authorization", QByteArray("Bearer ") + token_.toUtf8());
    req.setHeader(QNetworkRequest::ContentTypeHeader, QStringLiteral("application/octet-stream"));
    req.setHeader(QNetworkRequest::ContentLengthHeader, file->size());
    auto *reply = network_.post(req, file);
    file->setParent(reply);
    watch(reply);
    return true;
}
} // namespace tepy::desktop
