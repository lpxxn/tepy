#pragma once
#include <QByteArray>
#include <QMutex>
#include <QObject>
#include <QQueue>
#include <QStringList>
#include <QThread>
#include <atomic>

namespace tepy::desktop {
// QSerialPort lives entirely in the worker thread; the UI never blocks on I/O.
class SerialPort final : public QThread {
    Q_OBJECT
  public:
    explicit SerialPort(QString port, QObject *parent = nullptr);
    ~SerialPort() override;
    static QStringList availablePorts();
    void send(QByteArray bytes);
    void stop();
  signals:
    void opened();
    void received(QByteArray bytes);
    void failed(QString message);

  protected:
    void run() override;

  private:
    QString port_;
    QMutex mutex_;
    QQueue<QByteArray> outgoing_;
    std::atomic_bool stop_{false};
};
} // namespace tepy::desktop
