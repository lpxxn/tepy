#pragma once
#include "keyboard_job.hpp"
#include <QCheckBox>
#include <QComboBox>
#include <QLabel>
#include <QLineEdit>
#include <QPushButton>
#include <QSpinBox>
#include <QWidget>

namespace tepy::desktop {
class KeyboardPage final : public QWidget {
    Q_OBJECT
  public:
    explicit KeyboardPage(QWidget *parent = nullptr);
    bool busy() const { return job_.busy(); }
    void forget();
    void useDeviceID(const QString &id);
  signals:
    void macStateChanged(QJsonObject state);

  private:
    void connectBroker();
    void remember();
    void refresh();
    void execute();
    MqttControl mqtt_;
    KeyboardJob job_;
    QLineEdit *broker_, *username_, *password_, *deviceID_, *agentID_, *ca_, *cert_, *keyFile_,
        *input_;
    QComboBox *action_, *key_;
    QSpinBox *wait_;
    QCheckBox *enter_;
    QList<QCheckBox *> modifiers_;
    QWidget *connectionFields_, *actionFields_, *inputRow_, *keyRow_, *waitRow_;
    QPushButton *connect_, *disconnect_, *send_, *cancel_;
    QLabel *notice_, *brokerValue_, *deviceValue_, *bleValue_, *macValue_, *hidResult_, *macResult_;
};
} // namespace tepy::desktop
