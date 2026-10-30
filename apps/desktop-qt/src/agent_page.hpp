#pragma once
#include "agent_client.hpp"
#include <QLabel>
#include <QLineEdit>
#include <QPlainTextEdit>
#include <QPushButton>
#include <QWidget>

namespace tepy::desktop {
class AgentPage final : public QWidget {
    Q_OBJECT
  public:
    explicit AgentPage(QWidget *parent = nullptr);

  private:
    void showState(const QJsonObject &state);
    void showFailure(const QString &message);
    AgentClient client_;
    QLineEdit *address_, *token_;
    QPushButton *connect_, *disconnect_;
    QLabel *notice_, *badge_, *online_, *session_, *hid_, *mqtt_, *details_, *devices_;
    QPlainTextEdit *raw_;
    QJsonObject latest_;
};
} // namespace tepy::desktop
