#pragma once
#include <QObject>
#include <QProcess>

namespace tepy::desktop {
class FlashJob final : public QObject {
    Q_OBJECT
  public:
    explicit FlashJob(QObject *parent = nullptr);
    bool start(const QString &python, const QString &manifest, const QString &port);
    bool running() const { return process_.state() != QProcess::NotRunning; }
  signals:
    void output(QString text);
    void finished(bool success, QString message);

  private:
    QProcess process_;
    bool completed_{};
    void complete(bool success, const QString &message);
};
} // namespace tepy::desktop
