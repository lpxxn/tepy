#include "ui.hpp"
#include <QHBoxLayout>
#include <QPainter>
#include <QPainterPath>
#include <QStyle>

namespace tepy::desktop::ui {
QLabel *label(const QString &text, const char *name, QWidget *parent) {
    auto *result = new QLabel(text, parent);
    result->setObjectName(QString::fromLatin1(name));
    result->setTextFormat(Qt::PlainText);
    result->setWordWrap(true);
    return result;
}
Card card(const QString &title, const QString &description, QWidget *parent) {
    auto *frame = new QFrame(parent);
    frame->setObjectName(QStringLiteral("card"));
    auto *layout = new QVBoxLayout(frame);
    layout->setContentsMargins(22, 20, 22, 20);
    layout->setSpacing(14);
    if (!title.isEmpty())
        layout->addWidget(label(title, "cardTitle", frame));
    if (!description.isEmpty())
        layout->addWidget(label(description, "muted", frame));
    return {frame, layout};
}
QPushButton *button(const QString &text, const char *variant, QWidget *parent) {
    auto *result = new QPushButton(text, parent);
    result->setProperty("variant", QString::fromLatin1(variant));
    result->setCursor(Qt::PointingHandCursor);
    return result;
}
QWidget *field(const QString &title, QWidget *editor, QWidget *parent) {
    auto *result = new QWidget(parent);
    auto *layout = new QVBoxLayout(result);
    layout->setContentsMargins(0, 0, 0, 0);
    layout->setSpacing(7);
    layout->addWidget(label(title, "fieldLabel", result));
    layout->addWidget(editor);
    return result;
}
QWidget *step(const QString &number, const QString &title, const QString &description,
              QWidget *parent) {
    auto *result = new QWidget(parent);
    auto *layout = new QHBoxLayout(result);
    layout->setContentsMargins(0, 4, 0, 4);
    layout->setSpacing(14);
    auto *badge = label(number, "stepNumber", result);
    badge->setFixedSize(34, 34);
    badge->setAlignment(Qt::AlignCenter);
    layout->addWidget(badge, 0, Qt::AlignTop);
    auto *text = new QVBoxLayout;
    text->setSpacing(4);
    text->addWidget(label(title, "stepTitle", result));
    text->addWidget(label(description, "muted", result));
    layout->addLayout(text, 1);
    return result;
}
void property(QWidget *widget, const char *name, const QVariant &value) {
    if (widget->property(name) == value)
        return;
    widget->setProperty(name, value);
    widget->style()->unpolish(widget);
    widget->style()->polish(widget);
    widget->update();
}
QIcon navigationIcon(int index) {
    QPixmap pixmap(40, 40);
    pixmap.fill(Qt::transparent);
    QPainter p(&pixmap);
    p.setRenderHint(QPainter::Antialiasing);
    p.scale(2, 2);
    p.setPen(
        QPen(QColor(QStringLiteral("#8ca8ba")), 1.5, Qt::SolidLine, Qt::RoundCap, Qt::RoundJoin));
    if (index == 0) {
        for (int x : {3, 11})
            for (int y : {3, 11})
                p.drawRoundedRect(QRectF(x, y, 6, 6), 1.3, 1.3);
    } else if (index == 1) {
        p.drawArc(QRectF(1, 4, 18, 18), 40 * 16, 100 * 16);
        p.drawArc(QRectF(5, 8, 10, 10), 40 * 16, 100 * 16);
        p.setBrush(QColor(QStringLiteral("#8ca8ba")));
        p.drawEllipse(QPointF(10, 16), 1, 1);
    } else if (index == 2) {
        QPainterPath path;
        path.moveTo(10, 2);
        path.lineTo(15, 6);
        path.lineTo(5, 14);
        path.moveTo(10, 18);
        path.lineTo(15, 14);
        path.lineTo(5, 6);
        path.moveTo(10, 2);
        path.lineTo(10, 18);
        p.drawPath(path);
    } else if (index == 3) {
        p.drawRoundedRect(QRectF(3, 3, 14, 14), 2, 2);
        p.drawLine(10, 6, 10, 14);
        p.drawLine(7, 11, 10, 14);
        p.drawLine(13, 11, 10, 14);
    } else if (index == 4) {
        p.drawRoundedRect(QRectF(2, 3, 16, 11), 2, 2);
        p.drawLine(10, 14, 10, 18);
        p.drawLine(6, 18, 14, 18);
    } else {
        p.drawRoundedRect(QRectF(1, 4, 18, 12), 2, 2);
        for (int x : {4, 8, 12, 16})
            for (int y : {7, 10})
                p.drawPoint(x, y);
        p.drawLine(6, 13, 14, 13);
    }
    return QIcon(pixmap);
}
QString stylesheet() {
    return QStringLiteral(R"(
QMainWindow, QWidget#appRoot, QWidget#mainArea { background: #f4f7fb; color: #334155; }
QWidget#sidebar { background: #101d30; }
QLabel#brand { color: #f8fafc; font-size: 27px; font-weight: 700; }
QLabel#brandMark { background: qlineargradient(x1:0,y1:0,x2:1,y2:1,stop:0 #2dd4bf,stop:1 #0d9488); color: white; border-radius: 12px; font-size: 25px; font-weight: 800; }
QLabel#sidebarSubtitle { color: #7693aa; font-size: 12px; }
QLabel#sidebarFooter { color: #91a8ba; font-size: 12px; padding: 12px; background: #192b40; border-radius: 10px; }
QListWidget#navigation { border: none; background: transparent; color: #91a8ba; outline: none; font-size: 14px; }
QListWidget#navigation::item { border-radius: 9px; padding: 13px 11px; margin: 4px 10px; border-left: 3px solid transparent; }
QListWidget#navigation::item:hover { background: #1a2c40; color: #e2e8f0; }
QListWidget#navigation::item:selected { background: #183c46; color: #5eead4; border-left-color: #2dd4bf; }
QLabel#pageTitle { color: #0f172a; font-size: 25px; font-weight: 700; }
QLabel#pageSubtitle, QLabel#muted { color: #7b8a9c; font-size: 12px; }
QLabel#cardTitle { color: #172b40; font-size: 15px; font-weight: 700; }
QLabel#fieldLabel { color: #596b80; font-size: 12px; }
QLabel#stepTitle { color: #334155; font-size: 13px; font-weight: 600; }
QLabel#stepNumber { background: #e9f7f5; color: #0f766e; border: 1px solid #ccebe5; border-radius: 10px; font-size: 12px; font-weight: 700; }
QFrame#card, QFrame#metricCard { background: white; border: 1px solid #e4ebf2; border-radius: 14px; }
QLabel#metricTitle { color: #7b8a9c; font-size: 12px; }
QLabel#metricValue { color: #172b40; font-size: 22px; font-weight: 700; }
QLabel#metricDetail { color: #8b9bad; font-size: 11px; }
QLabel#connectionBadge { color: #64748b; background: #f1f5f9; border-radius: 10px; padding: 5px 11px; font-size: 11px; }
QLabel#connectionBadge[state="connected"] { color: #0f766e; background: #e6f7f2; }
QLabel#notice { background: #edf4fd; color: #4b6a91; border: 1px solid #dce8f8; border-radius: 9px; padding: 10px 14px; font-size: 12px; }
QLabel#notice[kind="success"] { background: #eaf8f3; color: #147864; border-color: #cceee2; }
QLabel#notice[kind="error"] { background: #fff1f2; color: #b74456; border-color: #fbd5dc; }
QLabel#bleStatus { background: #f0faf8; color: #347b72; border-radius: 9px; padding: 14px; }
QLineEdit, QComboBox, QSpinBox { background: #fff; color: #263d54; border: 1px solid #dce5ee; border-radius: 8px; padding: 9px 10px; min-height: 18px; selection-background-color: #c5eee7; selection-color: #134e4a; }
QLineEdit:hover, QComboBox:hover, QSpinBox:hover { border-color: #afc7d5; }
QLineEdit:focus, QComboBox:focus, QSpinBox:focus { border: 1px solid #14b8a6; background: #fbfffe; }
QLineEdit:disabled, QComboBox:disabled, QSpinBox:disabled { background: #f5f7fa; color: #9aabba; border-color: #e7edf3; }
QComboBox::drop-down { border: none; width: 25px; }
QPushButton { background: #fff; color: #475d73; border: 1px solid #dce5ee; border-radius: 8px; padding: 10px 16px; font-size: 12px; font-weight: 600; }
QPushButton:hover { background: #f8fafc; border-color: #acbfce; }
QPushButton:pressed { background: #edf2f7; }
QPushButton[variant="primary"] { background: #0d9488; color: #fff; border-color: #0d9488; }
QPushButton[variant="primary"]:hover { background: #0f8278; border-color: #0f8278; }
QPushButton[variant="primary"]:pressed { background: #0f766e; }
QPushButton[variant="danger"] { background: #fff7f8; color: #c14b60; border-color: #f5d8df; }
QPushButton[variant="danger"]:hover { background: #ffeaf0; border-color: #eeb9c5; }
QPushButton#forgetConnections { background: transparent; color: #91a8ba; border: 1px solid #2a4056; font-weight: 400; }
QPushButton#forgetConnections:hover { background: #1a2c40; color: #e2e8f0; }
QPushButton:disabled, QPushButton[variant="primary"]:disabled, QPushButton[variant="danger"]:disabled { background: #edf2f7; color: #a2afbe; border-color: #e6ecf2; }
QToolButton { border: none; background: transparent; color: #0f8c80; padding: 6px 0; font-size: 12px; }
QToolButton:hover { color: #115e59; }
QPlainTextEdit { color: #52667d; background: #f8fafc; border: 1px solid #e3ebf2; border-radius: 9px; padding: 10px; selection-background-color: #c5eee7; }
QPlainTextEdit#stateCode, QPlainTextEdit#flashLog, QPlainTextEdit#macAgentDetails { font-family: Consolas, monospace; font-size: 12px; }
QScrollArea, QScrollArea > QWidget > QWidget { background: transparent; border: none; }
QTabWidget::pane { border: none; background: transparent; }
QProgressBar { border: none; background: #edf2f7; border-radius: 5px; min-height: 9px; max-height: 9px; }
QProgressBar::chunk { background: #14b8a6; border-radius: 5px; }
QScrollBar:vertical { background: transparent; width: 7px; margin: 3px 0; }
QScrollBar::handle:vertical { background: #c6d3df; border-radius: 3px; min-height: 30px; }
QScrollBar::add-line:vertical, QScrollBar::sub-line:vertical { height: 0; }
QScrollBar::add-page:vertical, QScrollBar::sub-page:vertical { background: none; }
QToolTip { background: #fff; color: #334155; border: 1px solid #dce5ee; padding: 6px; }
)");
}
} // namespace tepy::desktop::ui
