#pragma once
#include <QFrame>
#include <QIcon>
#include <QLabel>
#include <QPushButton>
#include <QVBoxLayout>

namespace tepy::desktop::ui {
struct Card {
    QFrame *widget;
    QVBoxLayout *layout;
};
Card card(const QString &title, const QString &description, QWidget *parent);
QLabel *label(const QString &text, const char *name, QWidget *parent);
QPushButton *button(const QString &text, const char *variant, QWidget *parent);
QWidget *field(const QString &title, QWidget *editor, QWidget *parent);
QWidget *step(const QString &number, const QString &title, const QString &description,
              QWidget *parent);
void property(QWidget *widget, const char *name, const QVariant &value);
QIcon navigationIcon(int index);
QString stylesheet();
} // namespace tepy::desktop::ui
