#include "agent_page.hpp"
#include "ui.hpp"
#include <QDateTime>
#include <QHBoxLayout>
#include <QJsonArray>
#include <QJsonDocument>
#include <QScrollBar>
#include <QToolButton>

namespace tepy::desktop {
AgentPage::AgentPage(QWidget *parent) : QWidget(parent), client_(this) {
    auto *layout = new QVBoxLayout(this);
    layout->setContentsMargins(0, 0, 0, 0);
    layout->setSpacing(16);
    const auto connection =
        ui::card(QStringLiteral("Mac 状态服务"),
                 QStringLiteral("连接运行在 Mac 上的 Go 服务，查看会话、睡眠与键盘诊断。"), this);
    address_ = new QLineEdit(connection.widget);
    address_->setObjectName(QStringLiteral("macAgentAddress"));
    address_->setPlaceholderText(QStringLiteral("http://192.168.50.2:18765"));
    token_ = new QLineEdit(connection.widget);
    token_->setObjectName(QStringLiteral("macAgentToken"));
    token_->setEchoMode(QLineEdit::Password);
    token_->setMaxLength(128);
    token_->setPlaceholderText(QStringLiteral("Go 服务 TOML 的 http.token"));
    auto *fields = new QHBoxLayout;
    fields->addWidget(ui::field(QStringLiteral("Mac 服务地址"), address_, connection.widget), 1);
    fields->addWidget(ui::field(QStringLiteral("服务口令"), token_, connection.widget), 1);
    connection.layout->addLayout(fields);
    auto *buttons = new QHBoxLayout;
    connect_ = ui::button(QStringLiteral("连接 Mac"), "primary", connection.widget);
    connect_->setObjectName(QStringLiteral("connectMacAgent"));
    disconnect_ = ui::button(QStringLiteral("断开"), "secondary", connection.widget);
    buttons->addWidget(connect_);
    buttons->addWidget(disconnect_);
    buttons->addStretch();
    badge_ = ui::label(QStringLiteral("未连接"), "connectionBadge", connection.widget);
    buttons->addWidget(badge_);
    connection.layout->addLayout(buttons);
    layout->addWidget(connection.widget);
    notice_ = ui::label(
        QStringLiteral("口令与 ESP32 管理口令独立。此页面每五秒只读刷新，不保存凭据或执行解锁。"),
        "notice", this);
    layout->addWidget(notice_);
    auto *metrics = new QHBoxLayout;
    metrics->setSpacing(12);
    const auto metric = [&](const QString &title, QLabel *&value) {
        auto *frame = new QFrame(this);
        frame->setObjectName(QStringLiteral("metricCard"));
        auto *body = new QVBoxLayout(frame);
        body->setContentsMargins(18, 16, 18, 16);
        body->addWidget(ui::label(title, "metricTitle", frame));
        value = ui::label(QStringLiteral("未知"), "metricValue", frame);
        body->addWidget(value);
        metrics->addWidget(frame, 1);
    };
    metric(QStringLiteral("Mac 服务"), online_);
    metric(QStringLiteral("锁定状态"), session_);
    metric(QStringLiteral("Tepy 键盘"), hid_);
    metric(QStringLiteral("MQTT"), mqtt_);
    layout->addLayout(metrics);
    const auto events = ui::card(QStringLiteral("会话与唤醒"), {}, this);
    details_ = ui::label(QStringLiteral("等待 Mac 服务上报。"), "muted", events.widget);
    events.layout->addWidget(details_);
    layout->addWidget(events.widget);
    const auto hidCard = ui::card(
        QStringLiteral("键盘诊断"),
        QStringLiteral("检查 Mac 的 HID 注册结果；发送完成与实际输入效果仍需分别确认。"), this);
    devices_ = ui::label(QStringLiteral("尚未读取键盘信息。"), "muted", hidCard.widget);
    hidCard.layout->addWidget(devices_);
    layout->addWidget(hidCard.widget);
    auto *toggle = new QToolButton(this);
    toggle->setText(QStringLiteral("查看 Mac 状态详情"));
    toggle->setCheckable(true);
    toggle->setArrowType(Qt::RightArrow);
    toggle->setToolButtonStyle(Qt::ToolButtonTextBesideIcon);
    layout->addWidget(toggle, 0, Qt::AlignLeft);
    raw_ = new QPlainTextEdit(this);
    raw_->setReadOnly(true);
    raw_->setObjectName(QStringLiteral("macAgentDetails"));
    raw_->setFixedHeight(210);
    raw_->hide();
    layout->addWidget(raw_);
    layout->addStretch();
    connect(toggle, &QToolButton::toggled, this, [this, toggle](bool on) {
        raw_->setVisible(on);
        toggle->setArrowType(on ? Qt::DownArrow : Qt::RightArrow);
        if (on && !latest_.isEmpty())
            raw_->setPlainText(
                QString::fromUtf8(QJsonDocument(latest_).toJson(QJsonDocument::Indented)));
    });
    connect(connect_, &QPushButton::clicked, this,
            [this] { client_.start(address_->text(), token_->text()); });
    connect(disconnect_, &QPushButton::clicked, &client_, &AgentClient::stop);
    connect(&client_, &AgentClient::activeChanged, this, [this](bool active) {
        address_->setEnabled(!active);
        token_->setEnabled(!active);
        connect_->setEnabled(!active);
        disconnect_->setEnabled(active);
        if (!active) {
            badge_->setText(QStringLiteral("未连接"));
            ui::property(badge_, "state", QStringLiteral("disconnected"));
            online_->setText(QStringLiteral("未知"));
            session_->setText(QStringLiteral("未知"));
            hid_->setText(QStringLiteral("未知"));
            mqtt_->setText(QStringLiteral("未知"));
            latest_ = {};
            raw_->clear();
            details_->setText(QStringLiteral("等待 Mac 服务上报。"));
            devices_->setText(QStringLiteral("尚未读取键盘信息。"));
        } else {
            badge_->setText(QStringLiteral("正在验证…"));
        }
    });
    connect(&client_, &AgentClient::updated, this, &AgentPage::showState);
    connect(&client_, &AgentClient::failed, this, &AgentPage::showFailure);
    disconnect_->setEnabled(false);
}
void AgentPage::showState(const QJsonObject &s) {
    latest_ = s;
    badge_->setText(s.value(QStringLiteral("name")).toString());
    ui::property(badge_, "state", QStringLiteral("connected"));
    online_->setText(QStringLiteral("在线"));
    const auto user = s.value(QStringLiteral("user_session")).toObject(),
               hid = s.value(QStringLiteral("hid")).toObject(),
               power = s.value(QStringLiteral("power")).toObject(),
               mqtt = s.value(QStringLiteral("mqtt")).toObject();
    const auto lock = user.value(QStringLiteral("lock_state")).toString();
    session_->setText(lock == QStringLiteral("locked")     ? QStringLiteral("已锁定")
                      : lock == QStringLiteral("unlocked") ? QStringLiteral("未锁定")
                                                           : QStringLiteral("未知"));
    const auto registered = hid.value(QStringLiteral("state")).toString();
    hid_->setText(registered == QStringLiteral("registered") ? QStringLiteral("已注册")
                  : registered == QStringLiteral("absent")   ? QStringLiteral("未注册")
                                                             : QStringLiteral("未知"));
    mqtt_->setText(!mqtt.value(QStringLiteral("configured")).toBool() ? QStringLiteral("未配置")
                   : mqtt.value(QStringLiteral("connected")).toBool() ? QStringLiteral("在线")
                                                                      : QStringLiteral("离线"));
    const auto boolean = [](const QJsonValue &v) {
        return v.isBool() ? (v.toBool() ? QStringLiteral("是") : QStringLiteral("否"))
                          : QStringLiteral("未知");
    };
    const auto event = power.value(QStringLiteral("last_event")).toString();
    const auto eventName = event == QStringLiteral("did_wake")     ? QStringLiteral("已唤醒")
                           : event == QStringLiteral("will_sleep") ? QStringLiteral("即将睡眠")
                                                                   : QStringLiteral("暂无记录");
    details_->setText(
        QStringLiteral("用户会话可用：%1 · 当前控制台：%2 · 登录完成：%3\n最近电源事件：%4 · "
                       "唤醒次数：%5 · 监听：%6\n服务 %7 · 最后采样 %8")
            .arg(boolean(user.value(QStringLiteral("available"))),
                 boolean(user.value(QStringLiteral("on_console"))),
                 boolean(user.value(QStringLiteral("login_done"))), eventName)
            .arg(power.value(QStringLiteral("wake_count")).toInteger())
            .arg(power.value(QStringLiteral("monitoring")).toBool() ? QStringLiteral("运行中")
                                                                    : QStringLiteral("不可用"),
                 s.value(QStringLiteral("agent_version")).toString(),
                 QDateTime::fromMSecsSinceEpoch(s.value(QStringLiteral("observed_at")).toInteger())
                     .toString(QStringLiteral("yyyy-MM-dd HH:mm:ss"))));
    QStringList names;
    for (const auto &item : hid.value(QStringLiteral("devices")).toArray()) {
        const auto device = item.toObject();
        names << device.value(QStringLiteral("product")).toString() + QStringLiteral(" · ") +
                     device.value(QStringLiteral("transport")).toString();
    }
    devices_->setText(names.isEmpty()
                          ? QStringLiteral("未发现目标键盘，或诊断暂不可用；请结合状态详情查看。")
                          : names.join(QChar(u'\n')));
    notice_->setText(QStringLiteral(
        "状态已更新。在线回执、锁定状态与键盘注册分别展示；未知状态不会视为解锁成功。"));
    ui::property(notice_, "kind", QStringLiteral("success"));
    if (raw_->isVisible() && !raw_->textCursor().hasSelection()) {
        const auto text = QString::fromUtf8(QJsonDocument(s).toJson(QJsonDocument::Indented));
        if (raw_->toPlainText() != text) {
            const auto position = raw_->verticalScrollBar()->value();
            raw_->setPlainText(text);
            raw_->verticalScrollBar()->setValue(position);
        }
    }
}
void AgentPage::showFailure(const QString &message) {
    badge_->setText(QStringLiteral("暂时不可用"));
    ui::property(badge_, "state", QStringLiteral("disconnected"));
    for (auto *label : {online_, session_, hid_, mqtt_})
        label->setText(QStringLiteral("未知"));
    notice_->setText(message);
    ui::property(notice_, "kind", QStringLiteral("error"));
}
} // namespace tepy::desktop
