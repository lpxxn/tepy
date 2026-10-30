#pragma once
#include <QComboBox>
#include <QJsonObject>
#include <QLineEdit>
#include <QPlainTextEdit>
#include <QSpinBox>
#include <QWidget>

namespace tepy::desktop {
class SecretField final : public QWidget {
    Q_OBJECT
  public:
    explicit SecretField(bool allowClear, QWidget *parent = nullptr);
    void reset(bool isSet);
    void committed();
    bool addTo(QJsonObject &target, const QString &key, QString &error, int minimum,
               int maximum) const;
    QString replacement() const;
    QComboBox *mode() const { return mode_; }
    QLineEdit *editor() const { return edit_; }

  private:
    QComboBox *mode_;
    QLineEdit *edit_;
    bool isSet_{};
};
class ConfigForm final : public QWidget {
    Q_OBJECT
  public:
    explicit ConfigForm(QWidget *parent = nullptr);
    bool load(const QJsonObject &config);
    QJsonObject patch(QString &error) const;
    QString newAdminToken() const { return admin_->replacement(); }
    void clearSecrets();
    void committed();
    void setSsid(const QString &value) { ssid_->setText(value); }

  private:
    QLineEdit *ssid_, *uri_, *username_, *ntp_;
    SecretField *wifiPassword_, *mqttPassword_, *admin_;
    QPlainTextEdit *ca_;
    QSpinBox *delay_;
};
} // namespace tepy::desktop
