#pragma once
#include "config_form.hpp"
#include "device_client.hpp"
#include "flash_job.hpp"
#include <QLabel>
#include <QMainWindow>
#include <QPlainTextEdit>
#include <QProgressBar>
#include <QPushButton>
#include <QTimer>
#include <QToolButton>

namespace tepy::desktop {
class AgentPage;
class KeyboardPage;
class MainWindow final : public QMainWindow {
    Q_OBJECT
  public:
    explicit MainWindow(QWidget *parent = nullptr);

  protected:
    void closeEvent(QCloseEvent *event) override;

  private:
    void refreshPorts();
    void connectDevice();
    void updateControls();
    void success(const QString &method, const QJsonObject &result);
    void failure(const QString &method, const QString &message);
    void perform(const QString &method, const QJsonObject &params = {},
                 RequestMode mode = RequestMode::Foreground);
    void renderStatusDetails();
    void browse(QLineEdit *field, const QString &title, const QString &filter);
    DeviceClient client_;
    FlashJob flash_;
    QTimer refresh_;
    QComboBox *transport_, *ports_, *flashPort_, *networks_;
    QLineEdit *address_, *token_, *passkey_, *image_, *manifest_, *python_;
    QLabel *connection_, *summary_, *notice_, *bleStatus_;
    QLabel *wifiValue_, *mqttValue_, *bleValue_, *firmwareValue_;
    QLabel *wifiDetail_, *mqttDetail_, *bleDetail_, *firmwareDetail_;
    QPlainTextEdit *state_, *flashLog_;
    ConfigForm *config_;
    QPushButton *connect_, *disconnect_, *save_, *reload_, *scan_, *pair_, *submitKey_, *clear_,
        *reboot_, *ota_, *flashButton_;
    QPushButton *refreshStatusButton_;
    QProgressBar *progress_;
    QWidget *connectionDetails_;
    QToolButton *connectionToggle_;
    QString pendingAdmin_;
    bool initialConfig_{}, configLoaded_{}, scanPending_{}, rebootRequired_{};
    unsigned scanPolls_{};
    bool statusFailed_{};
    QJsonObject latestStatus_;
    AgentPage *agentPage_;
    KeyboardPage *keyboardPage_;
};
} // namespace tepy::desktop
