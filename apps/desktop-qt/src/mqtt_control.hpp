#pragma once
#include <QElapsedTimer>
#include <QJsonObject>
#include <QMqttClient>
#include <QPointer>
#include <QSslConfiguration>
#include <QStringList>
#include <QTimer>
#include <QUrl>

namespace tepy::desktop {
struct BrokerSettings {
    QString url, username, password, caFile, clientCertFile, clientKeyFile, deviceID, agentID;
};
bool brokerConfiguration(const BrokerSettings &settings, QUrl &url, QSslConfiguration &tls,
                         QString &error);
bool validText(const QByteArray &text);
bool validKey(const QString &key, const QStringList &modifiers);
void clearSecret(QByteArray &bytes);

class MqttControl final : public QObject {
    Q_OBJECT
  public:
    explicit MqttControl(QObject *parent = nullptr);
    ~MqttControl() override;
    bool start(const BrokerSettings &settings);
    void stop();
    bool active() const { return active_; }
    bool connected() const { return subscribed_; }
    bool deviceFresh() const;
    bool deviceReady() const;
    bool macFresh() const;
    QJsonObject deviceState() const { return device_; }
    QJsonObject macState() const { return mac_; }
    const BrokerSettings &settings() const { return settings_; }
    QString send(const QString &kind, const QJsonObject &payload);
    void abandon(); // Stops waiting; already submitted device actions cannot be recalled.
  signals:
    void changed();
    void activeChanged(bool active);
    void notice(QString text, bool error);
    void actionReply(QString id, QString status, QString error);
    void actionUncertain(QString id);

  private:
    void connectBroker();
    void lost();
    void receive(const QString &topic, const QByteArray &bytes, bool retained);
    QString topic(const QString &suffix) const;
    BrokerSettings settings_;
    QUrl url_;
    QSslConfiguration tls_;
    QPointer<QMqttClient> client_;
    QTimer reconnect_, connectTimeout_, freshness_, replyTimeout_, ackTimeout_;
    QElapsedTimer deviceAge_, macAge_;
    QJsonObject device_, mac_;
    QString pending_;
    qint32 packetID_ = -1;
    bool active_{}, subscribed_{};
    unsigned subscriptions_{}, backoff_ = 1000;
};
} // namespace tepy::desktop
