#pragma once
#include "mqtt_control.hpp"

namespace tepy::desktop {
class KeyboardJob final : public QObject {
    Q_OBJECT
  public:
    explicit KeyboardJob(MqttControl &mqtt, QObject *parent = nullptr);
    ~KeyboardJob() override;
    bool busy() const { return stage_ != Idle; }
    bool wake();
    bool type(QByteArray text, bool enter);
    bool key(const QString &key, const QStringList &modifiers);
    bool unlock(QByteArray password, int waitMs, bool enter);
    void cancel();
  signals:
    void busyChanged(bool busy);
    void progress(QString message, QString kind);
    void hidResult(QString message);
    void macResult(QString message);

  private:
    enum Stage { Idle, Simple, Wake, Waiting, Typing, Observing };
    bool begin(Stage stage);
    void submit(const QString &kind, const QJsonObject &payload);
    void check();
    void finish(const QString &message, const QString &kind);
    MqttControl &mqtt_;
    QTimer timer_;
    QElapsedTimer wait_;
    Stage stage_ = Idle;
    QString session_, request_;
    QByteArray password_;
    int delayMs_{};
    bool enter_{};
    qint64 inputAt_{};
    qint64 wakeAt_{};
};
} // namespace tepy::desktop
