#include "config_form.hpp"
#include "ui.hpp"
#include <QFile>
#include <QFileDialog>
#include <QFormLayout>
#include <QHBoxLayout>
#include <QLabel>
#include <QMessageBox>
#include <QPushButton>
#include <QRegularExpression>
#include <QToolButton>
#include <QVBoxLayout>

namespace tepy::desktop {
SecretField::SecretField(bool allowClear, QWidget *parent) : QWidget(parent) {
    auto *layout = new QHBoxLayout(this);
    layout->setContentsMargins(0, 0, 0, 0);
    mode_ = new QComboBox(this);
    mode_->addItem(QStringLiteral("保留原值"), 0);
    mode_->addItem(QStringLiteral("设置新值"), 1);
    if (allowClear)
        mode_->addItem(QStringLiteral("清除"), 2);
    edit_ = new QLineEdit(this);
    edit_->setEchoMode(QLineEdit::Password);
    edit_->setEnabled(false);
    layout->addWidget(mode_);
    layout->addWidget(edit_, 1);
    connect(mode_, &QComboBox::currentIndexChanged, this, [this] {
        edit_->clear();
        edit_->setEnabled(mode_->currentData().toInt() == 1);
    });
}
void SecretField::reset(bool isSet) {
    isSet_ = isSet;
    mode_->setCurrentIndex(0);
    edit_->clear();
    edit_->setPlaceholderText(isSet ? QStringLiteral("已设置，保持不变")
                                    : QStringLiteral("尚未设置"));
}
void SecretField::committed() {
    const auto mode = mode_->currentData().toInt();
    reset(mode == 0 ? isSet_ : mode == 1);
}
QString SecretField::replacement() const {
    return mode_->currentData().toInt() == 1 ? edit_->text() : QString();
}
bool SecretField::addTo(QJsonObject &target, const QString &key, QString &error, int minimum,
                        int maximum) const {
    const auto mode = mode_->currentData().toInt();
    if (!mode)
        return true;
    const auto value = mode == 2 ? QString() : edit_->text();
    if (mode == 1 && (value.toUtf8().size() < minimum || value.toUtf8().size() > maximum)) {
        error = QStringLiteral("新密码长度须为 %1–%2 字节；要保留密码请选择“保留原值”。")
                    .arg(minimum)
                    .arg(maximum);
        return false;
    }
    target.insert(key, value);
    return true;
}
ConfigForm::ConfigForm(QWidget *parent) : QWidget(parent) {
    auto *layout = new QVBoxLayout(this);
    layout->setContentsMargins(0, 0, 2, 0);
    layout->setSpacing(14);
    ssid_ = new QLineEdit(this);
    ssid_->setObjectName(QStringLiteral("wifiSsid"));
    uri_ = new QLineEdit(this);
    uri_->setObjectName(QStringLiteral("mqttUri"));
    uri_->setPlaceholderText(
        QStringLiteral("mqtt://192.168.50.10:1883 或 mqtts://broker.example.com:8883"));
    username_ = new QLineEdit(this);
    username_->setObjectName(QStringLiteral("mqttUsername"));
    ntp_ = new QLineEdit(QStringLiteral("pool.ntp.org"), this);
    ntp_->setObjectName(QStringLiteral("ntpServer"));
    wifiPassword_ = new SecretField(true, this);
    wifiPassword_->setObjectName(QStringLiteral("wifiPassword"));
    mqttPassword_ = new SecretField(true, this);
    mqttPassword_->setObjectName(QStringLiteral("mqttPassword"));
    admin_ = new SecretField(false, this);
    admin_->setObjectName(QStringLiteral("adminPassword"));
    ca_ = new QPlainTextEdit(this);
    ca_->setObjectName(QStringLiteral("mqttCa"));
    ca_->setMaximumHeight(115);
    ca_->setPlaceholderText(
        QStringLiteral("自定义 CA 的 PEM 内容；留空使用固件证书包。不会跳过证书验证。"));
    delay_ = new QSpinBox(this);
    delay_->setRange(5, 200);
    delay_->setValue(20);
    delay_->setSuffix(QStringLiteral(" ms"));
    auto *import = ui::button(QStringLiteral("导入 CA 证书…"), "secondary", this);
    connect(import, &QPushButton::clicked, this, [this] {
        const auto path =
            QFileDialog::getOpenFileName(this, QStringLiteral("选择 CA 证书"), {},
                                         QStringLiteral("PEM 证书 (*.pem *.crt);;所有文件 (*)"));
        if (path.isEmpty())
            return;
        QFile file(path);
        if (!file.open(QIODevice::ReadOnly) || file.size() > 8192) {
            QMessageBox::warning(this, QStringLiteral("CA 证书"),
                                 QStringLiteral("文件无法读取或超过 8192 字节。"));
            return;
        }
        ca_->setPlainText(QString::fromUtf8(file.readAll()));
    });
    auto *caBox = new QWidget(this);
    auto *caLayout = new QVBoxLayout(caBox);
    caLayout->setContentsMargins(0, 0, 0, 0);
    caLayout->addWidget(ca_);
    caLayout->addWidget(import, 0, Qt::AlignRight);
    const auto form = [](QWidget *parent) {
        auto *result = new QFormLayout(parent);
        result->setContentsMargins(0, 0, 0, 0);
        result->setSpacing(14);
        result->setHorizontalSpacing(20);
        result->setFieldGrowthPolicy(QFormLayout::AllNonFixedFieldsGrow);
        return result;
    };
    const auto wifiCard =
        ui::card(QStringLiteral("Wi-Fi 网络"),
                 QStringLiteral("选择设备要连接的无线网络。已保存的密码默认保留。"), this);
    auto *wifiBody = new QWidget(wifiCard.widget);
    auto *wifiForm = form(wifiBody);
    wifiForm->addRow(QStringLiteral("网络名称"), ssid_);
    wifiForm->addRow(QStringLiteral("网络密码"), wifiPassword_);
    wifiCard.layout->addWidget(wifiBody);
    layout->addWidget(wifiCard.widget);
    const auto mqttCard =
        ui::card(QStringLiteral("MQTT 消息服务"),
                 QStringLiteral("填写已有 Broker 的连接信息。远程连接可使用 mqtts://。"), this);
    auto *mqttBody = new QWidget(mqttCard.widget);
    auto *mqttForm = form(mqttBody);
    mqttForm->addRow(QStringLiteral("Broker 地址"), uri_);
    mqttForm->addRow(QStringLiteral("用户名"), username_);
    mqttForm->addRow(QStringLiteral("密码"), mqttPassword_);
    mqttCard.layout->addWidget(mqttBody);
    auto *caToggle = new QToolButton(mqttCard.widget);
    caToggle->setText(QStringLiteral("自定义 CA 证书（可选）"));
    caToggle->setCheckable(true);
    caToggle->setArrowType(Qt::RightArrow);
    caToggle->setToolButtonStyle(Qt::ToolButtonTextBesideIcon);
    caBox->hide();
    mqttCard.layout->addWidget(caToggle, 0, Qt::AlignLeft);
    mqttCard.layout->addWidget(caBox);
    connect(caToggle, &QToolButton::toggled, this, [caBox, caToggle](bool on) {
        caBox->setVisible(on);
        caToggle->setArrowType(on ? Qt::DownArrow : Qt::RightArrow);
    });
    layout->addWidget(mqttCard.widget);
    const auto advanced = ui::card({}, {}, this);
    auto *advancedToggle = new QToolButton(advanced.widget);
    advancedToggle->setText(QStringLiteral("高级设置 · 时间、输入与管理口令"));
    advancedToggle->setCheckable(true);
    advancedToggle->setArrowType(Qt::RightArrow);
    advancedToggle->setToolButtonStyle(Qt::ToolButtonTextBesideIcon);
    auto *advancedBody = new QWidget(advanced.widget);
    auto *advancedForm = form(advancedBody);
    advancedForm->addRow(QStringLiteral("NTP 服务器"), ntp_);
    advancedForm->addRow(QStringLiteral("按键间隔"), delay_);
    advancedForm->addRow(QStringLiteral("管理口令"), admin_);
    advancedBody->hide();
    advanced.layout->addWidget(advancedToggle, 0, Qt::AlignLeft);
    advanced.layout->addWidget(advancedBody);
    connect(advancedToggle, &QToolButton::toggled, this, [advancedBody, advancedToggle](bool on) {
        advancedBody->setVisible(on);
        advancedToggle->setArrowType(on ? Qt::DownArrow : Qt::RightArrow);
    });
    layout->addWidget(advanced.widget);
    layout->addStretch();
}
bool ConfigForm::load(const QJsonObject &config) {
    if (config.value(QStringLiteral("v")).toInt() != 1 ||
        !config.value(QStringLiteral("wifi")).isObject() ||
        !config.value(QStringLiteral("mqtt")).isObject())
        return false;
    const auto wifi = config.value(QStringLiteral("wifi")).toObject(),
               mqtt = config.value(QStringLiteral("mqtt")).toObject();
    ssid_->setText(wifi.value(QStringLiteral("ssid")).toString());
    uri_->setText(mqtt.value(QStringLiteral("uri")).toString());
    username_->setText(mqtt.value(QStringLiteral("username")).toString());
    ntp_->setText(
        config.value(QStringLiteral("ntp_server")).toString(QStringLiteral("pool.ntp.org")));
    delay_->setValue(config.value(QStringLiteral("key_delay_ms")).toInt(20));
    ca_->setPlainText(mqtt.value(QStringLiteral("ca")).toString());
    wifiPassword_->reset(wifi.value(QStringLiteral("password_set")).toBool());
    mqttPassword_->reset(mqtt.value(QStringLiteral("password_set")).toBool());
    admin_->reset(true);
    return true;
}
QJsonObject ConfigForm::patch(QString &error) const {
    error.clear();
    const auto ssid = ssid_->text(), uri = uri_->text().trimmed(), ntp = ntp_->text().trimmed();
    if (ssid.toUtf8().size() > 32) {
        error = QStringLiteral("Wi-Fi 名称不能超过 32 字节。");
        return {};
    }
    if (!uri.isEmpty() &&
        (!QRegularExpression(QStringLiteral("^mqtts?://[^\\s@/?#]+$")).match(uri).hasMatch() ||
         uri.toUtf8().size() > 256)) {
        error =
            QStringLiteral("MQTT 地址须为 mqtt://主机:端口 或 mqtts://主机:端口，凭据请单独填写。");
        return {};
    }
    if (ntp.isEmpty() || ntp.toUtf8().size() > 128 ||
        ntp.contains(QRegularExpression(QStringLiteral("\\s")))) {
        error = QStringLiteral("请输入有效的 NTP 服务器名称。");
        return {};
    }
    if (username_->text().toUtf8().size() > 128) {
        error = QStringLiteral("MQTT 用户名不能超过 128 字节。");
        return {};
    }
    const auto ca = ca_->toPlainText();
    if (ca.toUtf8().size() > 8192 ||
        (!ca.isEmpty() && (!ca.contains(QStringLiteral("-----BEGIN CERTIFICATE-----")) ||
                           ca.contains(QStringLiteral("PRIVATE KEY"))))) {
        error = QStringLiteral("CA 须为 PEM 证书，不能包含私钥，最长 8192 字节。");
        return {};
    }
    QJsonObject wifi{{QStringLiteral("ssid"), ssid}};
    QJsonObject mqtt{{QStringLiteral("uri"), uri},
                     {QStringLiteral("username"), username_->text()},
                     {QStringLiteral("ca"), ca}};
    QJsonObject root{{QStringLiteral("v"), 1},
                     {QStringLiteral("ntp_server"), ntp},
                     {QStringLiteral("key_delay_ms"), delay_->value()}};
    if (!wifiPassword_->addTo(wifi, QStringLiteral("password"), error, 8, 63) ||
        !mqttPassword_->addTo(mqtt, QStringLiteral("password"), error, 1, 256) ||
        !admin_->addTo(root, QStringLiteral("admin_password"), error, 16, 64))
        return {};
    if (root.contains(QStringLiteral("admin_password")) &&
        !QRegularExpression(QStringLiteral("^[!-~]{16,64}$"))
             .match(root.value(QStringLiteral("admin_password")).toString())
             .hasMatch()) {
        error = QStringLiteral("管理口令须为 16–64 个不含空格的 ASCII 可打印字符。");
        return {};
    }
    root.insert(QStringLiteral("wifi"), wifi);
    root.insert(QStringLiteral("mqtt"), mqtt);
    return root;
}
void ConfigForm::clearSecrets() {
    wifiPassword_->reset(false);
    mqttPassword_->reset(false);
    admin_->reset(false);
}
void ConfigForm::committed() {
    wifiPassword_->committed();
    mqttPassword_->committed();
    admin_->committed();
}
} // namespace tepy::desktop
