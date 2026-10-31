#pragma once
#include <QString>
#include <QVariantMap>

namespace tepy::desktop {
struct SavedConnection {
    QVariantMap fields;
    QString secret;
};
// Public fields live in QSettings; secrets live only in the OS credential vault.
class ConnectionStore {
  public:
    static SavedConnection load(const QString &profile);
    static bool save(const QString &profile, const QVariantMap &fields, const QString &secret,
                     QString &error);
    static bool forgetAll(QString &error);
    static bool forget(const QString &profile, QString &error);
    static void setEnabled(bool enabled); // Tests disable access to the user's preferences/vault.
};
} // namespace tepy::desktop
