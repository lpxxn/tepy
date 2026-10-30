#pragma once
#include <QByteArray>
#include <QJsonObject>
#include <QStringList>
#include <QUrl>
#include <functional>

namespace tepy::desktop {
inline constexpr qsizetype maxFrameBytes = 20000;
class FrameDecoder {
  public:
    void feed(const QByteArray &bytes, const std::function<void(const QJsonObject &)> &receive);
    void reset();

  private:
    QByteArray line_;
    bool dropping_{};
};
struct Route {
    QByteArray verb;
    QString path;
};
Route routeFor(const QString &method);
QUrl deviceUrl(const QString &input, QString &error);
QByteArray serialRequest(const QString &id, const QString &method, const QString &token,
                         const QJsonObject &params);
QString describeError(const QString &code);
struct ImageInfo {
    QString version;
    QString project;
};
bool inspectApplication(const QString &path, ImageInfo &info, QString &error);
bool flashArguments(const QString &manifest, const QString &port, QStringList &args,
                    QString &error);
} // namespace tepy::desktop
