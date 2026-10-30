#pragma once
#include <QJsonObject>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QObject>
#include <QPointer>
#include <QTimer>
#include <QUrl>

namespace tepy::desktop {
bool validateAgentState(const QJsonObject &state, qint64 now, QString &error);
class AgentClient final : public QObject {
    Q_OBJECT
  public:
    explicit AgentClient(QObject *parent = nullptr);
    ~AgentClient() override;
    bool start(const QString &address, const QString &token);
    void stop();
    bool active() const { return active_; }
    void refresh();
  signals:
    void updated(QJsonObject state);
    void failed(QString message);
    void activeChanged(bool active);

  private:
    void reject(const QString &message, bool stopPolling = false);
    QNetworkAccessManager network_;
    QTimer poll_, timeout_;
    QPointer<QNetworkReply> reply_;
    QUrl base_;
    QString token_, agentID_;
    bool active_{};
};
} // namespace tepy::desktop
