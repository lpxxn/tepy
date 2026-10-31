#include "connection_store.hpp"
#include <QSettings>
#include <QUrl>
#ifdef Q_OS_WIN
#include <QtCore/qt_windows.h>
#include <wincred.h>
#elif defined(Q_OS_MACOS)
#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#endif

namespace tepy::desktop {
namespace {
bool enabled = true;
QString target(const QString &profile) {
    return QStringLiteral("Tepy.Desktop.v1/") + profile;
}
bool vault(const QString &profile, QString &secret, bool write, bool remove) {
#ifdef Q_OS_WIN
    auto name = target(profile).toStdWString();
    if (remove || (write && secret.isEmpty()))
        return CredDeleteW(name.c_str(), CRED_TYPE_GENERIC, 0) || GetLastError() == ERROR_NOT_FOUND;
    if (write) {
        auto bytes = secret.toUtf8();
        if (bytes.size() > CRED_MAX_CREDENTIAL_BLOB_SIZE)
            return false;
        CREDENTIALW item{};
        item.Type = CRED_TYPE_GENERIC;
        item.TargetName = name.data();
        item.CredentialBlobSize = static_cast<DWORD>(bytes.size());
        item.CredentialBlob = reinterpret_cast<LPBYTE>(bytes.data());
        item.Persist = CRED_PERSIST_LOCAL_MACHINE;
        const bool ok = CredWriteW(&item, 0);
        SecureZeroMemory(bytes.data(), static_cast<SIZE_T>(bytes.size()));
        return ok;
    }
    PCREDENTIALW item = nullptr;
    if (!CredReadW(name.c_str(), CRED_TYPE_GENERIC, 0, &item))
        return GetLastError() == ERROR_NOT_FOUND;
    secret = QString::fromUtf8(reinterpret_cast<const char *>(item->CredentialBlob),
                               item->CredentialBlobSize);
    SecureZeroMemory(item->CredentialBlob, item->CredentialBlobSize);
    CredFree(item);
    return true;
#elif defined(Q_OS_MACOS)
    const auto bytes = target(profile).toUtf8();
    auto account = CFStringCreateWithBytes(nullptr, reinterpret_cast<const UInt8 *>(bytes.data()),
                                           bytes.size(), kCFStringEncodingUTF8, false);
    auto query = CFDictionaryCreateMutable(nullptr, 0, &kCFTypeDictionaryKeyCallBacks,
                                           &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(query, kSecClass, kSecClassGenericPassword);
    CFDictionarySetValue(query, kSecAttrService, CFSTR("Tepy Desktop"));
    CFDictionarySetValue(query, kSecAttrAccount, account);
    OSStatus result;
    if (write || remove) {
        result = SecItemDelete(query);
        if (write && !secret.isEmpty() &&
            (result == errSecSuccess || result == errSecItemNotFound)) {
            auto value = secret.toUtf8();
            auto data =
                CFDataCreate(nullptr, reinterpret_cast<const UInt8 *>(value.data()), value.size());
            CFDictionarySetValue(query, kSecValueData, data);
            result = SecItemAdd(query, nullptr);
            CFRelease(data);
            value.fill('\0');
        }
    } else {
        CFDictionarySetValue(query, kSecReturnData, kCFBooleanTrue);
        CFTypeRef value = nullptr;
        result = SecItemCopyMatching(query, &value);
        if (result == errSecSuccess && value && CFGetTypeID(value) == CFDataGetTypeID()) {
            const auto data = static_cast<CFDataRef>(value);
            secret = QString::fromUtf8(reinterpret_cast<const char *>(CFDataGetBytePtr(data)),
                                       CFDataGetLength(data));
        }
        if (value)
            CFRelease(value);
    }
    CFRelease(query);
    CFRelease(account);
    return result == errSecSuccess || result == errSecItemNotFound;
#else
    Q_UNUSED(profile)
    Q_UNUSED(remove)
    return !write || secret.isEmpty();
#endif
}
QSettings settings() {
    return QSettings(QSettings::NativeFormat, QSettings::UserScope, QStringLiteral("Tepy"),
                     QStringLiteral("Desktop"));
}
} // namespace
void ConnectionStore::setEnabled(bool value) {
    enabled = value;
}
SavedConnection ConnectionStore::load(const QString &profile) {
    SavedConnection result;
    if (!enabled)
        return result;
    auto store = settings();
    result.fields = store.value(QStringLiteral("connections/") + profile).toMap();
    vault(profile, result.secret, false, false);
    return result;
}
bool ConnectionStore::save(const QString &profile, const QVariantMap &fields, const QString &secret,
                           QString &error) {
    if (!enabled)
        return true;
    for (const auto *field : {"url", "address"}) {
        if (!QUrl(fields.value(QString::fromLatin1(field)).toString()).userInfo().isEmpty()) {
            error = QStringLiteral("服务地址不能内嵌用户名或密码，连接信息未保存。");
            return false;
        }
    }
    auto copy = secret;
    if (!vault(profile, copy, true, false)) {
        error = QStringLiteral("系统凭据库未能保存口令；本次连接仍可使用，口令未写入普通配置。");
        return false;
    }
    auto store = settings();
    store.setValue(QStringLiteral("connections/") + profile, fields);
    store.sync();
    if (store.status() != QSettings::NoError) {
        error = QStringLiteral("无法保存本机连接设置。");
        return false;
    }
    error.clear();
    return true;
}
bool ConnectionStore::forgetAll(QString &error) {
    if (!enabled)
        return true;
    bool ok = true;
    for (const auto *profile : {"device", "mac", "mqtt"}) {
        QString ignored;
        ok = forget(QString::fromLatin1(profile), ignored) && ok;
    }
    auto store = settings();
    store.remove(QStringLiteral("connections"));
    store.sync();
    ok = ok && store.status() == QSettings::NoError;
    error = ok ? QString() : QStringLiteral("部分连接凭据未能清除，请检查系统凭据库。");
    return ok;
}
bool ConnectionStore::forget(const QString &profile, QString &error) {
    if (!enabled)
        return true;
    QString ignored;
    const bool removed = vault(profile, ignored, false, true);
    auto store = settings();
    store.remove(QStringLiteral("connections/") + profile);
    store.sync();
    const bool ok = removed && store.status() == QSettings::NoError;
    error = ok ? QString() : QStringLiteral("无法清除保存的连接。");
    return ok;
}
} // namespace tepy::desktop
