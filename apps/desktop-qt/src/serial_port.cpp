#include "serial_port.hpp"
#include <QElapsedTimer>
#include <QMutexLocker>
#include <QSerialPort>
#include <QSerialPortInfo>

namespace tepy::desktop {
SerialPort::SerialPort(QString port, QObject *parent) : QThread(parent), port_(std::move(port)) {}
SerialPort::~SerialPort() {
    stop();
    wait();
}
void SerialPort::stop() {
    stop_ = true;
}
void SerialPort::send(QByteArray bytes) {
    QMutexLocker lock(&mutex_);
    if (outgoing_.size() < 2)
        outgoing_.enqueue(std::move(bytes));
}
QStringList SerialPort::availablePorts() {
    QStringList ports;
    for (const auto &port : QSerialPortInfo::availablePorts())
        ports << port.portName();
    ports.removeDuplicates();
    ports.sort(Qt::CaseInsensitive);
    return ports;
}
void SerialPort::run() {
    QSerialPort port;
    port.setPortName(port_);
    port.setBaudRate(QSerialPort::Baud115200);
    port.setDataBits(QSerialPort::Data8);
    port.setParity(QSerialPort::NoParity);
    port.setStopBits(QSerialPort::OneStop);
    port.setFlowControl(QSerialPort::NoFlowControl);
    port.setReadBufferSize(65536);
    if (port_.isEmpty() || !port.open(QIODevice::ReadWrite)) {
        emit failed(
            QStringLiteral("无法打开 %1：%2。请先退出 idf.py monitor 或其他占用串口的程序。")
                .arg(port_, port.errorString()));
        return;
    }
    port.setDataTerminalReady(false);
    port.setRequestToSend(false);
    port.clearError();
    emit opened();
    while (!stop_) {
        QByteArray outgoing;
        {
            QMutexLocker lock(&mutex_);
            if (!outgoing_.isEmpty())
                outgoing = outgoing_.dequeue();
        }
        if (!outgoing.isEmpty()) {
            const auto size = outgoing.size();
            const auto queued = port.write(outgoing);
            outgoing.fill('\0');
            if (queued != size) {
                emit failed(QStringLiteral("串口写入失败，操作结果尚未确认。"));
                break;
            }
            QElapsedTimer deadline;
            deadline.start();
            bool writeFailed = false;
            while (port.bytesToWrite() > 0 && !stop_) {
                if (!port.waitForBytesWritten(100) && port.error() != QSerialPort::TimeoutError) {
                    writeFailed = true;
                    break;
                }
                if (deadline.elapsed() > 5000) {
                    writeFailed = true;
                    break;
                }
                port.clearError();
            }
            if (writeFailed) {
                emit failed(QStringLiteral("串口发送未完成，操作结果尚未确认。"));
                break;
            }
        }
        if (port.bytesAvailable() > 0 || port.waitForReadyRead(20))
            emit received(port.readAll());
        else if (port.error() != QSerialPort::NoError &&
                 port.error() != QSerialPort::TimeoutError) {
            emit failed(QStringLiteral("串口连接中断：%1").arg(port.errorString()));
            break;
        }
        port.clearError();
    }
    port.close();
    QMutexLocker lock(&mutex_);
    while (!outgoing_.isEmpty()) {
        auto bytes = outgoing_.dequeue();
        bytes.fill('\0');
    }
}
} // namespace tepy::desktop
