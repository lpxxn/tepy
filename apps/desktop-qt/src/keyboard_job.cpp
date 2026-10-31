#include "keyboard_job.hpp"
#include <QDateTime>
#include <QJsonArray>

namespace tepy::desktop {
KeyboardJob::KeyboardJob(MqttControl &mqtt, QObject *parent) : QObject(parent), mqtt_(mqtt) {
    connect(&timer_, &QTimer::timeout, this, &KeyboardJob::check);
    connect(&mqtt_, &MqttControl::changed, this, &KeyboardJob::check);
    connect(&mqtt_, &MqttControl::actionUncertain, this, [this](const QString &id) {
        if (id == request_ && busy()) {
            emit hidResult(QStringLiteral("发送结果未确认"));
            finish(QStringLiteral("连接或回执超时，结果未确认；请人工查看，不会自动重发。"),
                   QStringLiteral("error"));
        }
    });
    connect(
        &mqtt_, &MqttControl::actionReply, this,
        [this](const QString &id, const QString &status, const QString &error) {
            if (id != request_ || !busy())
                return;
            request_.clear();
            if (status != QStringLiteral("sent")) {
                emit hidResult(QStringLiteral("设备拒绝或执行中断"));
                finish(
                    QStringLiteral("设备未完成动作（%1）；后续步骤已取消，不自动重试。").arg(error),
                    QStringLiteral("error"));
                return;
            }
            emit hidResult(QStringLiteral("HID 发送完成"));
            if (stage_ == Wake) {
                wakeAt_ = QDateTime::currentMSecsSinceEpoch();
                stage_ = Waiting;
                wait_.restart();
                emit progress(QStringLiteral("唤醒指令已发送，等待设置的间隔与 Mac 锁定状态。"),
                              QStringLiteral("info"));
                timer_.start(100);
                check();
            } else if (stage_ == Typing) {
                clearSecret(password_);
                stage_ = Observing;
                wait_.restart();
                timer_.start(100);
                emit macResult(QStringLiteral("等待 Mac 状态反馈"));
                emit progress(QStringLiteral("输入已发送，正在观察 Mac 的新状态；不会重试密码。"),
                              QStringLiteral("info"));
                check();
            } else
                finish(QStringLiteral("HID 发送完成；实际输入位置与效果请在 Mac 上确认。"),
                       QStringLiteral("success"));
        });
}
KeyboardJob::~KeyboardJob() {
    clearSecret(password_);
}
bool KeyboardJob::begin(Stage stage) {
    if (busy() || !mqtt_.deviceReady() ||
        mqtt_.deviceState().value(QStringLiteral("busy")).toBool()) {
        emit progress(QStringLiteral("设备未就绪、正在忙碌或已有动作，请等待最新状态。"),
                      QStringLiteral("error"));
        return false;
    }
    session_ = mqtt_.deviceState().value(QStringLiteral("session")).toString();
    stage_ = stage;
    emit hidResult(QStringLiteral("等待设备执行回执"));
    emit macResult(QStringLiteral("尚未确认"));
    emit busyChanged(true);
    return true;
}
void KeyboardJob::submit(const QString &kind, const QJsonObject &payload) {
    request_ = mqtt_.send(kind, payload);
    if (request_.isEmpty())
        finish(QStringLiteral("当前状态不能发送动作；没有自动排队或重试。"),
               QStringLiteral("error"));
    else
        emit progress(QStringLiteral("指令已提交，等待设备执行回执。"), QStringLiteral("info"));
}
bool KeyboardJob::wake() {
    if (!begin(Simple))
        return false;
    submit(QStringLiteral("wake"), {});
    return true;
}
bool KeyboardJob::type(QByteArray text, bool enter) {
    if (!validText(text)) {
        clearSecret(text);
        emit progress(QStringLiteral("只支持 1–512 个可打印 ASCII 字符。"),
                      QStringLiteral("error"));
        return false;
    }
    if (!begin(Simple)) {
        clearSecret(text);
        return false;
    }
    submit(QStringLiteral("type_text"), {{QStringLiteral("text"), QString::fromLatin1(text)},
                                         {QStringLiteral("press_enter"), enter}});
    clearSecret(text);
    return true;
}
bool KeyboardJob::key(const QString &key, const QStringList &modifiers) {
    if (!validKey(key, modifiers)) {
        emit progress(QStringLiteral("按键或修饰键不受支持。"), QStringLiteral("error"));
        return false;
    }
    if (!begin(Simple))
        return false;
    QJsonArray array;
    for (const auto &modifier : modifiers)
        array.append(modifier);
    submit(QStringLiteral("key"),
           {{QStringLiteral("key"), key}, {QStringLiteral("modifiers"), array}});
    return true;
}
bool KeyboardJob::unlock(QByteArray password, int waitMs, bool enter) {
    if (!validText(password) || waitMs < 0 || waitMs > 30000 ||
        mqtt_.settings().agentID.isEmpty()) {
        clearSecret(password);
        emit progress(
            QStringLiteral("解锁需填写 Mac 代理 ID、1–512 个 ASCII 字符及 0–30 秒等待时间。"),
            QStringLiteral("error"));
        return false;
    }
    if (mqtt_.macFresh() &&
        mqtt_.macState()
                .value(QStringLiteral("user_session"))
                .toObject()
                .value(QStringLiteral("lock_state")) == QJsonValue(QStringLiteral("unlocked"))) {
        clearSecret(password);
        emit progress(QStringLiteral("Mac 报告当前未锁定，未发送唤醒或密码。"),
                      QStringLiteral("info"));
        return false;
    }
    if (!begin(Wake)) {
        clearSecret(password);
        return false;
    }
    password_ = std::move(password);
    delayMs_ = waitMs;
    enter_ = enter;
    submit(QStringLiteral("wake"), {});
    return true;
}
void KeyboardJob::finish(const QString &message, const QString &kind) {
    timer_.stop();
    clearSecret(password_);
    request_.clear();
    session_.clear();
    stage_ = Idle;
    mqtt_.abandon();
    emit busyChanged(false);
    emit progress(message, kind);
}
void KeyboardJob::cancel() {
    if (!busy())
        return;
    finish(QStringLiteral("后续步骤已取消；已提交给设备的按键无法撤回，不会重发。"),
           QStringLiteral("info"));
}
void KeyboardJob::check() {
    if (!busy())
        return;
    if (!mqtt_.connected() || !mqtt_.deviceReady() ||
        mqtt_.deviceState().value(QStringLiteral("session")).toString() != session_) {
        finish(QStringLiteral("设备离线、蓝牙中断、状态过期或会话改变，后续步骤已取消。"),
               QStringLiteral("error"));
        return;
    }
    if (stage_ == Waiting) {
        if (wait_.elapsed() < delayMs_)
            return;
        if (mqtt_.macFresh() &&
            mqtt_.macState().value(QStringLiteral("observed_at")).toInteger() >= wakeAt_) {
            const auto state = mqtt_.macState(),
                       user = state.value(QStringLiteral("user_session")).toObject(),
                       hid = state.value(QStringLiteral("hid")).toObject();
            if (user.value(QStringLiteral("lock_state")) ==
                QJsonValue(QStringLiteral("unlocked"))) {
                emit macResult(QStringLiteral("Mac 报告未锁定"));
                finish(QStringLiteral("Mac 已报告未锁定，未发送密码。"), QStringLiteral("success"));
                return;
            }
            const auto target = hid.value(QStringLiteral("target_device_id")).toString();
            bool correctKeyboard = target == mqtt_.settings().deviceID;
            if (target.isEmpty())
                for (const auto &device : hid.value(QStringLiteral("devices")).toArray())
                    correctKeyboard =
                        correctKeyboard ||
                        device.toObject().value(QStringLiteral("product")).toString() ==
                            QStringLiteral("Tepy-") + mqtt_.settings().deviceID.mid(6);
            if (state.value(QStringLiteral("power")).toObject().value(QStringLiteral("state")) ==
                    QJsonValue(QStringLiteral("awake")) &&
                user.value(QStringLiteral("available")).toBool() &&
                user.value(QStringLiteral("on_console")).toBool() &&
                user.value(QStringLiteral("login_done")).toBool() &&
                user.value(QStringLiteral("lock_state")) == QJsonValue(QStringLiteral("locked")) &&
                hid.value(QStringLiteral("state")) == QJsonValue(QStringLiteral("registered")) &&
                correctKeyboard && !mqtt_.deviceState().value(QStringLiteral("busy")).toBool()) {
                stage_ = Typing;
                timer_.stop();
                inputAt_ = QDateTime::currentMSecsSinceEpoch();
                submit(QStringLiteral("type_text"),
                       {{QStringLiteral("text"), QString::fromLatin1(password_)},
                        {QStringLiteral("press_enter"), enter_}});
                clearSecret(password_);
                return;
            }
        }
        if (wait_.elapsed() > delayMs_ + 20000)
            finish(QStringLiteral("未等到 Mac 已锁定、目标键盘已注册的有效状态；密码未发送。"),
                   QStringLiteral("error"));
    } else if (stage_ == Observing) {
        if (mqtt_.macFresh() &&
            mqtt_.macState().value(QStringLiteral("observed_at")).toInteger() >= inputAt_ &&
            mqtt_.macState()
                    .value(QStringLiteral("user_session"))
                    .toObject()
                    .value(QStringLiteral("lock_state")) ==
                QJsonValue(QStringLiteral("unlocked"))) {
            emit macResult(QStringLiteral("Mac 报告已解锁"));
            finish(QStringLiteral("HID 发送完成，Mac 随后报告已解锁。"), QStringLiteral("success"));
        } else if (wait_.elapsed() > 20000) {
            emit macResult(QStringLiteral("尚未确认 Mac 解锁"));
            finish(QStringLiteral("HID 已发送，未观察到解锁反馈；请人工查看，不自动重试。"),
                   QStringLiteral("info"));
        }
    }
}
} // namespace tepy::desktop
