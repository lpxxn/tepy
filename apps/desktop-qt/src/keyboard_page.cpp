#include "keyboard_page.hpp"
#include "connection_store.hpp"
#include "ui.hpp"
#include <QFileDialog>
#include <QHBoxLayout>
#include <QToolButton>
#include <QVBoxLayout>

namespace tepy::desktop {
KeyboardPage::KeyboardPage(QWidget *parent) : QWidget(parent), mqtt_(this), job_(mqtt_, this) {
    auto *layout = new QVBoxLayout(this);
    layout->setContentsMargins(0, 0, 0, 0);
    layout->setSpacing(16);
    const auto connection = ui::card(
        QStringLiteral("MQTT 控制连接"),
        QStringLiteral(
            "连接 Broker，同时接收 ESP32 与 Mac 状态。地址改变后也可通过代理 ID 查看 Mac。"),
        this);
    connectionFields_ = new QWidget(connection.widget);
    auto *fields = new QVBoxLayout(connectionFields_);
    fields->setContentsMargins(0, 0, 0, 0);
    fields->setSpacing(12);
    const auto line = [&](const char *name, const QString &placeholder) {
        auto *editor = new QLineEdit(connectionFields_);
        editor->setObjectName(QString::fromLatin1(name));
        editor->setPlaceholderText(placeholder);
        editor->setMaxLength(4096);
        return editor;
    };
    broker_ = line("mqttBroker", QStringLiteral("mqtt://127.0.0.1:1883 或远程 Broker"));
    deviceID_ = line("mqttDeviceID", QStringLiteral("ESP32 的 12 位 device_id"));
    deviceID_->setMaxLength(12);
    agentID_ = line("mqttAgentID", QStringLiteral("Mac TOML 的 agent_id，可留空观察设备"));
    agentID_->setMaxLength(64);
    auto *row = new QHBoxLayout;
    row->addWidget(ui::field(QStringLiteral("Broker 地址"), broker_, connectionFields_), 2);
    row->addWidget(ui::field(QStringLiteral("ESP32 设备 ID"), deviceID_, connectionFields_), 1);
    row->addWidget(ui::field(QStringLiteral("Mac 代理 ID"), agentID_, connectionFields_), 2);
    fields->addLayout(row);
    username_ = line("mqttUsername", QStringLiteral("无需认证时留空"));
    password_ = line("mqttPassword", QStringLiteral("由系统凭据库记住"));
    password_->setEchoMode(QLineEdit::Password);
    auto *credentials = new QHBoxLayout;
    credentials->addWidget(ui::field(QStringLiteral("用户名"), username_, connectionFields_), 1);
    credentials->addWidget(ui::field(QStringLiteral("Broker 密码"), password_, connectionFields_),
                           1);
    fields->addLayout(credentials);
    auto *advanced = new QToolButton(connectionFields_);
    advanced->setText(QStringLiteral("TLS 证书设置"));
    advanced->setCheckable(true);
    advanced->setArrowType(Qt::RightArrow);
    advanced->setToolButtonStyle(Qt::ToolButtonTextBesideIcon);
    fields->addWidget(advanced, 0, Qt::AlignLeft);
    auto *certificates = new QWidget(connectionFields_);
    auto *certificateFields = new QVBoxLayout(certificates);
    certificateFields->setContentsMargins(0, 0, 0, 0);
    ca_ = line("mqttCA", QStringLiteral("留空使用系统 CA"));
    cert_ = line("mqttCertificate", QStringLiteral("客户端 PEM 证书，可选"));
    keyFile_ = line("mqttKeyFile", QStringLiteral("与客户端证书配对的 PEM 私钥路径"));
    for (const auto &item :
         {qMakePair(QStringLiteral("CA 证书"), ca_), qMakePair(QStringLiteral("客户端证书"), cert_),
          qMakePair(QStringLiteral("客户端私钥"), keyFile_)}) {
        auto *pathRow = new QHBoxLayout;
        pathRow->addWidget(ui::field(item.first, item.second, certificates), 1);
        auto *browse = ui::button(QStringLiteral("选择文件"), "secondary", certificates);
        pathRow->addWidget(browse, 0, Qt::AlignBottom);
        certificateFields->addLayout(pathRow);
        connect(browse, &QPushButton::clicked, this, [this, field = item.second] {
            const auto path = QFileDialog::getOpenFileName(
                this, QStringLiteral("选择 PEM 文件"), {},
                QStringLiteral("PEM 文件 (*.pem *.crt *.key);;所有文件 (*)"));
            if (!path.isEmpty())
                field->setText(path);
        });
    }
    fields->addWidget(certificates);
    certificates->hide();
    connect(advanced, &QToolButton::toggled, certificates, &QWidget::setVisible);
    connect(advanced, &QToolButton::toggled, advanced,
            [advanced](bool on) { advanced->setArrowType(on ? Qt::DownArrow : Qt::RightArrow); });
    connection.layout->addWidget(connectionFields_);
    auto *connectionActions = new QHBoxLayout;
    connect_ = ui::button(QStringLiteral("连接 MQTT"), "primary", connection.widget);
    connect_->setObjectName(QStringLiteral("connectMQTT"));
    disconnect_ = ui::button(QStringLiteral("断开"), "secondary", connection.widget);
    connectionActions->addWidget(connect_);
    connectionActions->addWidget(disconnect_);
    connectionActions->addStretch();
    auto *connectionToggle = new QToolButton(connection.widget);
    connectionToggle->setText(QStringLiteral("连接设置"));
    connectionToggle->setCheckable(true);
    connectionToggle->setChecked(true);
    connectionToggle->setArrowType(Qt::DownArrow);
    connectionToggle->setToolButtonStyle(Qt::ToolButtonTextBesideIcon);
    connectionActions->addWidget(connectionToggle);
    connect(connectionToggle, &QToolButton::toggled, this, [this, connectionToggle](bool on) {
        connectionFields_->setVisible(on);
        connectionToggle->setArrowType(on ? Qt::DownArrow : Qt::RightArrow);
    });
    connection.layout->addLayout(connectionActions);
    layout->addWidget(connection.widget);
    auto *metrics = new QHBoxLayout;
    metrics->setSpacing(12);
    const auto metric = [&](const QString &title, QLabel *&value) {
        auto *frame = new QFrame(this);
        frame->setObjectName(QStringLiteral("metricCard"));
        auto *body = new QVBoxLayout(frame);
        body->setContentsMargins(16, 14, 16, 14);
        body->addWidget(ui::label(title, "metricTitle", frame));
        value = ui::label(QStringLiteral("未知"), "metricValue", frame);
        body->addWidget(value);
        metrics->addWidget(frame, 1);
    };
    metric(QStringLiteral("MQTT"), brokerValue_);
    metric(QStringLiteral("ESP32"), deviceValue_);
    metric(QStringLiteral("蓝牙键盘"), bleValue_);
    metric(QStringLiteral("Mac 锁定状态"), macValue_);
    layout->addLayout(metrics);
    const auto actionCard =
        ui::card(QStringLiteral("键盘操作"),
                 QStringLiteral("请确认 Mac 输入位置。解锁流程等待 Mac "
                                "报告已锁定且目标键盘已注册；密码只用于本次操作。"),
                 this);
    actionFields_ = new QWidget(actionCard.widget);
    actionFields_->setObjectName(QStringLiteral("keyboardFields"));
    auto *form = new QVBoxLayout(actionFields_);
    form->setContentsMargins(0, 0, 0, 0);
    form->setSpacing(12);
    action_ = new QComboBox(actionFields_);
    action_->setObjectName(QStringLiteral("keyboardAction"));
    action_->addItems({QStringLiteral("唤醒屏幕"), QStringLiteral("发送文字"),
                       QStringLiteral("发送按键 / 组合键"), QStringLiteral("唤醒并输入解锁")});
    form->addWidget(ui::field(QStringLiteral("操作类型"), action_, actionFields_));
    input_ = new QLineEdit(actionFields_);
    input_->setObjectName(QStringLiteral("keyboardInput"));
    input_->setMaxLength(512);
    input_->setEchoMode(QLineEdit::Password);
    input_->setPlaceholderText(QStringLiteral("仅支持美式 ABC 布局的可打印 ASCII，结束后清空"));
    inputRow_ =
        ui::field(QStringLiteral("输入内容（隐藏，本次使用后清理）"), input_, actionFields_);
    form->addWidget(inputRow_);
    keyRow_ = new QWidget(actionFields_);
    auto *keys = new QHBoxLayout(keyRow_);
    keys->setContentsMargins(0, 0, 0, 0);
    key_ = new QComboBox(keyRow_);
    key_->setObjectName(QStringLiteral("keyboardKey"));
    key_->setEditable(true);
    key_->addItems({QStringLiteral("ENTER"), QStringLiteral("TAB"), QStringLiteral("ESC"),
                    QStringLiteral("SPACE"), QStringLiteral("BACKSPACE"), QStringLiteral("LEFT"),
                    QStringLiteral("RIGHT"), QStringLiteral("UP"), QStringLiteral("DOWN"),
                    QStringLiteral("z"), QStringLiteral("/")});
    keys->addWidget(ui::field(QStringLiteral("按键名或单个字符"), key_, keyRow_), 1);
    for (const auto *name : {"CTRL", "SHIFT", "ALT", "GUI"}) {
        auto *check = new QCheckBox(QString::fromLatin1(name), keyRow_);
        modifiers_ << check;
        keys->addWidget(check);
    }
    form->addWidget(keyRow_);
    wait_ = new QSpinBox(actionFields_);
    wait_->setObjectName(QStringLiteral("keyboardWait"));
    wait_->setRange(0, 30);
    wait_->setValue(3);
    wait_->setSuffix(QStringLiteral(" 秒"));
    waitRow_ = ui::field(QStringLiteral("唤醒回执后等待"), wait_, actionFields_);
    form->addWidget(waitRow_);
    enter_ = new QCheckBox(QStringLiteral("输入完成后按回车（默认关闭）"), actionFields_);
    enter_->setObjectName(QStringLiteral("keyboardEnter"));
    form->addWidget(enter_);
    const auto updateAction = [this] {
        input_->clear();
        const auto index = action_->currentIndex();
        inputRow_->setVisible(index == 1 || index == 3);
        enter_->setVisible(index == 1 || index == 3);
        keyRow_->setVisible(index == 2);
        waitRow_->setVisible(index == 3);
    };
    connect(action_, &QComboBox::currentIndexChanged, this, updateAction);
    updateAction();
    actionCard.layout->addWidget(actionFields_);
    auto *actions = new QHBoxLayout;
    send_ = ui::button(QStringLiteral("执行一次"), "primary", actionCard.widget);
    send_->setObjectName(QStringLiteral("executeKeyboard"));
    cancel_ = ui::button(QStringLiteral("取消后续步骤"), "secondary", actionCard.widget);
    cancel_->setObjectName(QStringLiteral("cancelKeyboard"));
    actions->addWidget(send_);
    actions->addWidget(cancel_);
    actions->addStretch();
    actionCard.layout->addLayout(actions);
    layout->addWidget(actionCard.widget);
    const auto result = ui::card(QStringLiteral("执行结果"), {}, this);
    hidResult_ = ui::label(QStringLiteral("HID：尚未发送"), "stepTitle", result.widget);
    macResult_ = ui::label(QStringLiteral("Mac：尚未确认"), "muted", result.widget);
    result.layout->addWidget(hidResult_);
    result.layout->addWidget(macResult_);
    layout->addWidget(result.widget);
    notice_ =
        ui::label(QStringLiteral(
                      "不会保存键盘输入或自动重试密码；取消仅停止后续步骤，已提交的按键无法撤回。"),
                  "notice", this);
    layout->addWidget(notice_);
    layout->addStretch();
    const auto saved = ConnectionStore::load(QStringLiteral("mqtt"));
    broker_->setText(
        saved.fields.value(QStringLiteral("url"), QStringLiteral("mqtt://127.0.0.1:1883"))
            .toString());
    for (const auto &item :
         {qMakePair(QStringLiteral("username"), username_),
          qMakePair(QStringLiteral("device"), deviceID_),
          qMakePair(QStringLiteral("agent"), agentID_), qMakePair(QStringLiteral("ca"), ca_),
          qMakePair(QStringLiteral("cert"), cert_), qMakePair(QStringLiteral("key"), keyFile_)})
        item.second->setText(saved.fields.value(item.first).toString());
    password_->setText(saved.secret);
    for (auto *editor : {broker_, username_, password_, deviceID_, agentID_, ca_, cert_, keyFile_})
        connect(editor, &QLineEdit::editingFinished, this, &KeyboardPage::remember);
    connect(connect_, &QPushButton::clicked, this, &KeyboardPage::connectBroker);
    connect(disconnect_, &QPushButton::clicked, &mqtt_, &MqttControl::stop);
    connect(&mqtt_, &MqttControl::changed, this, &KeyboardPage::refresh);
    connect(&mqtt_, &MqttControl::activeChanged, this, [this, connectionToggle](bool active) {
        connectionFields_->setEnabled(!active);
        connect_->setEnabled(!active);
        disconnect_->setEnabled(active);
        connectionToggle->setChecked(!active);
    });
    connect(&mqtt_, &MqttControl::notice, this, [this](const QString &text, bool error) {
        if (!job_.busy()) {
            notice_->setText(text);
            ui::property(notice_, "kind", error ? QStringLiteral("error") : QStringLiteral("info"));
        }
    });
    connect(send_, &QPushButton::clicked, this, &KeyboardPage::execute);
    connect(cancel_, &QPushButton::clicked, &job_, &KeyboardJob::cancel);
    connect(&job_, &KeyboardJob::busyChanged, this, [this](bool busy) {
        actionFields_->setEnabled(!busy);
        refresh();
    });
    connect(&job_, &KeyboardJob::progress, this, [this](const QString &text, const QString &kind) {
        notice_->setText(text);
        ui::property(notice_, "kind", kind);
    });
    connect(&job_, &KeyboardJob::hidResult, this,
            [this](const QString &text) { hidResult_->setText(text); });
    connect(&job_, &KeyboardJob::macResult, this,
            [this](const QString &text) { macResult_->setText(text); });
    refresh();
}
void KeyboardPage::connectBroker() {
    BrokerSettings settings{broker_->text().trimmed(),
                            username_->text(),
                            password_->text(),
                            ca_->text(),
                            cert_->text(),
                            keyFile_->text(),
                            deviceID_->text().trimmed().toLower(),
                            agentID_->text().trimmed()};
    if (!mqtt_.start(settings))
        return;
    remember();
}
void KeyboardPage::remember() {
    QString error;
    if (!ConnectionStore::save(QStringLiteral("mqtt"),
                               {{QStringLiteral("url"), broker_->text().trimmed()},
                                {QStringLiteral("username"), username_->text()},
                                {QStringLiteral("device"), deviceID_->text().trimmed().toLower()},
                                {QStringLiteral("agent"), agentID_->text().trimmed()},
                                {QStringLiteral("ca"), ca_->text()},
                                {QStringLiteral("cert"), cert_->text()},
                                {QStringLiteral("key"), keyFile_->text()}},
                               password_->text(), error)) {
        notice_->setText(error);
        ui::property(notice_, "kind", QStringLiteral("error"));
    }
}
void KeyboardPage::refresh() {
    brokerValue_->setText(mqtt_.connected() ? QStringLiteral("在线") : QStringLiteral("未连接"));
    deviceValue_->setText(mqtt_.deviceFresh() ? QStringLiteral("在线") : QStringLiteral("未知"));
    bleValue_->setText(mqtt_.deviceReady() ? QStringLiteral("就绪") : QStringLiteral("未就绪"));
    const auto state = mqtt_.macFresh() ? mqtt_.macState() : QJsonObject();
    const auto locked = state.value(QStringLiteral("user_session"))
                            .toObject()
                            .value(QStringLiteral("lock_state"))
                            .toString();
    macValue_->setText(locked == QStringLiteral("locked")     ? QStringLiteral("已锁定")
                       : locked == QStringLiteral("unlocked") ? QStringLiteral("未锁定")
                                                              : QStringLiteral("未知"));
    send_->setEnabled(!job_.busy() && mqtt_.deviceReady() &&
                      !mqtt_.deviceState().value(QStringLiteral("busy")).toBool());
    cancel_->setEnabled(job_.busy());
    disconnect_->setEnabled(mqtt_.active());
    emit macStateChanged(state);
}
void KeyboardPage::execute() {
    auto text = input_->text().toUtf8();
    input_->clear();
    if (action_->currentIndex() == 0)
        job_.wake();
    else if (action_->currentIndex() == 1)
        job_.type(std::move(text), enter_->isChecked());
    else if (action_->currentIndex() == 2) {
        QStringList mods;
        for (const auto *check : modifiers_)
            if (check->isChecked())
                mods << check->text();
        job_.key(key_->currentText(), mods);
    } else
        job_.unlock(std::move(text), wait_->value() * 1000, enter_->isChecked());
    clearSecret(text);
}
void KeyboardPage::forget() {
    job_.cancel();
    mqtt_.stop();
    password_->clear();
    input_->clear();
    username_->clear();
    deviceID_->clear();
    agentID_->clear();
    ca_->clear();
    cert_->clear();
    keyFile_->clear();
    broker_->setText(QStringLiteral("mqtt://127.0.0.1:1883"));
}
void KeyboardPage::useDeviceID(const QString &id) {
    if (deviceID_->text().isEmpty())
        deviceID_->setText(id);
}
} // namespace tepy::desktop
