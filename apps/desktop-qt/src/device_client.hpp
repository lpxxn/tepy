#pragma once
#include "protocol.hpp"
#include "serial_port.hpp"
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QPointer>
#include <QTimer>

namespace tepy::desktop {
enum class RequestMode { Foreground, Background };
class DeviceClient final : public QObject {
    Q_OBJECT
  public:
    explicit DeviceClient(QObject *parent = nullptr);
    ~DeviceClient() override;
    bool connectHttp(const QString &address, const QString &token);
    void connectSerial(const QString &port, const QString &token);
    void disconnectDevice();
    bool request(const QString &method, const QJsonObject &params = {},
                 RequestMode mode = RequestMode::Foreground);
    bool upload(const QString &path);
    bool busy() const { return !method_.isEmpty(); }
    bool exclusiveBusy() const { return busy() && mode_ == RequestMode::Foreground; }
    bool isConnected() const { return connected_; }
    bool isHttp() const { return !base_.isEmpty(); }
    void setToken(const QString &token) { token_ = token; }
  signals:
    void connected();
    void disconnected();
    void succeeded(QString method, QJsonObject result);
    void failed(QString method, QString message);
    void uploadProgress(qint64 sent, qint64 total);

  private:
    bool begin(const QString &method, int timeoutMs, RequestMode mode = RequestMode::Foreground);
    void cancelBackground();
    void finish(QJsonObject result, QString error = {});
    void receive(const QJsonObject &frame);
    void watch(QNetworkReply *reply);
    QNetworkAccessManager network_;
    QPointer<QNetworkReply> reply_;
    SerialPort *serial_{};
    FrameDecoder decoder_;
    QTimer timeout_;
    QUrl base_;
    QString token_, method_, requestId_;
    bool connected_{};
    RequestMode mode_{RequestMode::Foreground};
    quint64 generation_{};
};
} // namespace tepy::desktop
