#include "flash_job.hpp"
#include "protocol.hpp"
#include <QFileInfo>

namespace tepy::desktop {
FlashJob::FlashJob(QObject *parent) : QObject(parent) {
    process_.setProcessChannelMode(QProcess::MergedChannels);
    connect(&process_, &QProcess::readyReadStandardOutput, this,
            [this] { emit output(QString::fromUtf8(process_.readAllStandardOutput())); });
    connect(&process_, &QProcess::errorOccurred, this, [this](QProcess::ProcessError error) {
        if (error == QProcess::FailedToStart)
            complete(false, QStringLiteral("无法启动 Python，请选择已安装 esptool 的解释器。"));
    });
    connect(&process_, qOverload<int, QProcess::ExitStatus>(&QProcess::finished), this,
            [this](int code, QProcess::ExitStatus status) {
                emit output(QString::fromUtf8(process_.readAllStandardOutput()));
                const bool success = status == QProcess::NormalExit && code == 0;
                complete(
                    success,
                    success
                        ? QStringLiteral("烧录与校验成功。等待设备启动后，重新连接管理接口。")
                        : QStringLiteral(
                              "烧录未完成。请检查 esptool 输出及串口占用；恢复步骤见 OTA 文档。"));
            });
}
void FlashJob::complete(bool success, const QString &message) {
    if (completed_)
        return;
    completed_ = true;
    emit finished(success, message);
}
bool FlashJob::start(const QString &python, const QString &manifest, const QString &port) {
    if (running())
        return false;
    QStringList args;
    QString error;
    if (!flashArguments(manifest, port, args, error)) {
        emit finished(false, error);
        return false;
    }
    if (python.trimmed().isEmpty()) {
        emit finished(false, QStringLiteral("请选择已安装 esptool 的 Python。"));
        return false;
    }
    completed_ = false;
    process_.setWorkingDirectory(QFileInfo(manifest).absolutePath());
    process_.start(python, args);
    return true;
}
} // namespace tepy::desktop
