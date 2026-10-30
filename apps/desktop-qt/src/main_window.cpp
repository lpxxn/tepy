#include "main_window.hpp"
#include "agent_page.hpp"
#include "ui.hpp"
#include <QCloseEvent>
#include <QFileDialog>
#include <QFileInfo>
#include <QFormLayout>
#include <QGroupBox>
#include <QHBoxLayout>
#include <QJsonArray>
#include <QJsonDocument>
#include <QListWidget>
#include <QMessageBox>
#include <QRegularExpressionValidator>
#include <QScrollArea>
#include <QScrollBar>
#include <QStackedWidget>
#include <QTabBar>
#include <QTabWidget>
#include <QTextDocument>
#include <QToolButton>
#include <QVBoxLayout>

namespace tepy::desktop {
MainWindow::MainWindow(QWidget *parent) : QMainWindow(parent) {
    setWindowTitle(QStringLiteral("Tepy · 设备管理"));
    resize(1180, 920);
    setMinimumSize(1040, 760);
    setStyleSheet(ui::stylesheet());
    auto *central = new QWidget(this);
    central->setObjectName(QStringLiteral("appRoot"));
    setCentralWidget(central);
    auto *root = new QHBoxLayout(central);
    root->setContentsMargins(0, 0, 0, 0);
    root->setSpacing(0);
    auto *sidebar = new QWidget(central);
    sidebar->setObjectName(QStringLiteral("sidebar"));
    sidebar->setFixedWidth(192);
    auto *side = new QVBoxLayout(sidebar);
    side->setContentsMargins(10, 28, 10, 20);
    side->setSpacing(20);
    auto *brandRow = new QHBoxLayout;
    brandRow->setContentsMargins(14, 0, 10, 0);
    brandRow->setSpacing(12);
    auto *mark = ui::label(QStringLiteral("T"), "brandMark", sidebar);
    mark->setAlignment(Qt::AlignCenter);
    mark->setFixedSize(42, 42);
    brandRow->addWidget(mark);
    auto *brandText = new QVBoxLayout;
    brandText->setSpacing(2);
    brandText->addWidget(ui::label(QStringLiteral("Tepy"), "brand", sidebar));
    brandText->addWidget(ui::label(QStringLiteral("设备管理控制台"), "sidebarSubtitle", sidebar));
    brandRow->addLayout(brandText);
    side->addLayout(brandRow);
    const QStringList titles{QStringLiteral("设备概览"), QStringLiteral("网络配置"),
                             QStringLiteral("蓝牙连接"), QStringLiteral("固件管理"),
                             QStringLiteral("Mac 状态")};
    const QStringList subtitles{QStringLiteral("连接你的设备，掌握每一项运行状态。"),
                                QStringLiteral("让设备接入 Wi-Fi，配置 MQTT 与连接参数。"),
                                QStringLiteral("配对你的 Mac，并管理蓝牙键盘连接。"),
                                QStringLiteral("升级应用固件，或通过 USB 恢复设备。"),
                                QStringLiteral("查看 Mac 会话、睡眠唤醒与键盘注册结果。")};
    auto *navigation = new QListWidget(sidebar);
    navigation->setObjectName(QStringLiteral("navigation"));
    navigation->setIconSize(QSize(20, 20));
    for (int i = 0; i < titles.size(); ++i)
        navigation->addItem(new QListWidgetItem(ui::navigationIcon(i), titles[i]));
    side->addWidget(navigation, 1);
    side->addWidget(ui::label(QStringLiteral("ESP32-S3\nDesktop 0.2.0"), "sidebarFooter", sidebar));
    root->addWidget(sidebar);
    auto *main = new QWidget(central);
    main->setObjectName(QStringLiteral("mainArea"));
    auto *layout = new QVBoxLayout(main);
    layout->setContentsMargins(28, 25, 28, 24);
    layout->setSpacing(18);
    root->addWidget(main, 1);
    auto *heading = new QVBoxLayout;
    heading->setSpacing(5);
    auto *pageTitle = ui::label(titles[0], "pageTitle", main);
    auto *pageSubtitle = ui::label(subtitles[0], "pageSubtitle", main);
    heading->addWidget(pageTitle);
    heading->addWidget(pageSubtitle);
    layout->addLayout(heading);
    const auto connectionCard = ui::card({}, {}, main);
    auto *connectionHeading = new QHBoxLayout;
    connectionHeading->addWidget(
        ui::label(QStringLiteral("连接设备"), "cardTitle", connectionCard.widget));
    connectionHeading->addStretch();
    connection_ = ui::label(QStringLiteral("未连接"), "connectionBadge", connectionCard.widget);
    connectionToggle_ = new QToolButton(connectionCard.widget);
    connectionToggle_->setText(QStringLiteral("连接设置"));
    connectionToggle_->setCheckable(true);
    connectionToggle_->setChecked(true);
    connectionToggle_->setArrowType(Qt::DownArrow);
    connectionToggle_->setToolButtonStyle(Qt::ToolButtonTextBesideIcon);
    connectionHeading->addWidget(connectionToggle_);
    connectionHeading->addWidget(connection_);
    connectionCard.layout->addLayout(connectionHeading);
    connectionDetails_ = new QWidget(connectionCard.widget);
    auto *connectionDetailsLayout = new QVBoxLayout(connectionDetails_);
    connectionDetailsLayout->setContentsMargins(0, 0, 0, 0);
    connectionDetailsLayout->setSpacing(14);
    connectionCard.layout->addWidget(connectionDetails_);
    transport_ = new QComboBox(connectionCard.widget);
    transport_->addItems({QStringLiteral("HTTP 网络"), QStringLiteral("USB 串口")});
    address_ = new QLineEdit(QStringLiteral("http://192.168.4.1"), connectionCard.widget);
    address_->setObjectName(QStringLiteral("deviceAddress"));
    address_->setPlaceholderText(QStringLiteral("设备 IP 或 .local 主机名"));
    ports_ = new QComboBox(connectionCard.widget);
    auto *refreshPortsButton =
        ui::button(QStringLiteral("刷新"), "secondary", connectionCard.widget);
    auto *portRow = new QWidget(connectionCard.widget);
    auto *portLayout = new QHBoxLayout(portRow);
    portLayout->setContentsMargins(0, 0, 0, 0);
    portLayout->setSpacing(7);
    portLayout->addWidget(ports_, 1);
    portLayout->addWidget(refreshPortsButton);
    auto *endpoint = new QStackedWidget(connectionCard.widget);
    endpoint->addWidget(address_);
    endpoint->addWidget(portRow);
    token_ = new QLineEdit(connectionCard.widget);
    token_->setObjectName(QStringLiteral("managementToken"));
    token_->setEchoMode(QLineEdit::Password);
    token_->setMaxLength(64);
    token_->setPlaceholderText(QStringLiteral("输入设备管理口令"));
    auto *fields = new QHBoxLayout;
    fields->setSpacing(14);
    fields->addWidget(ui::field(QStringLiteral("连接方式"), transport_, connectionCard.widget), 2);
    fields->addWidget(ui::field(QStringLiteral("设备地址 / 串口"), endpoint, connectionCard.widget),
                      4);
    fields->addWidget(ui::field(QStringLiteral("管理口令"), token_, connectionCard.widget), 4);
    connectionDetailsLayout->addLayout(fields);
    connect_ = ui::button(QStringLiteral("连接并读取"), "primary", connectionCard.widget);
    connect_->setObjectName(QStringLiteral("connectDevice"));
    disconnect_ = ui::button(QStringLiteral("断开"), "secondary", connectionCard.widget);
    connectionHeading->addWidget(disconnect_);
    auto *connectionActions = new QHBoxLayout;
    connectionActions->addWidget(connect_);
    connectionActions->addStretch();
    auto *credentialNote =
        ui::label(QStringLiteral("口令仅在本次运行中使用"), "muted", connectionCard.widget);
    credentialNote->setWordWrap(false);
    connectionActions->addWidget(credentialNote);
    connectionDetailsLayout->addLayout(connectionActions);
    connect(connectionToggle_, &QToolButton::toggled, this, [this](bool on) {
        connectionDetails_->setVisible(on);
        connectionToggle_->setArrowType(on ? Qt::DownArrow : Qt::RightArrow);
    });
    layout->addWidget(connectionCard.widget);
    connect(transport_, &QComboBox::currentIndexChanged, endpoint,
            &QStackedWidget::setCurrentIndex);
    notice_ = ui::label(QStringLiteral("欢迎使用 Tepy。选择连接方式，填写管理口令即可开始。"),
                        "notice", main);
    layout->addWidget(notice_);
    auto *tabs = new QTabWidget(main);
    tabs->tabBar()->hide();
    layout->addWidget(tabs, 1);
    const auto scrollPage = [tabs](QWidget *page) {
        auto *scroll = new QScrollArea(tabs);
        scroll->setWidgetResizable(true);
        scroll->setFrameShape(QFrame::NoFrame);
        scroll->setWidget(page);
        return scroll;
    };
    auto *statusPage = new QWidget(tabs);
    auto *statusLayout = new QVBoxLayout(statusPage);
    statusLayout->setContentsMargins(0, 0, 0, 0);
    statusLayout->setSpacing(16);
    auto *metrics = new QHBoxLayout;
    metrics->setSpacing(12);
    const auto metric = [&](const QString &title, QLabel *&value, QLabel *&detail) {
        auto *frame = new QFrame(statusPage);
        frame->setObjectName(QStringLiteral("metricCard"));
        auto *body = new QVBoxLayout(frame);
        body->setContentsMargins(18, 16, 18, 16);
        body->setSpacing(9);
        body->addWidget(ui::label(title, "metricTitle", frame));
        value = ui::label(QStringLiteral("—"), "metricValue", frame);
        detail = ui::label(QStringLiteral("等待连接"), "metricDetail", frame);
        body->addWidget(value);
        body->addWidget(detail);
        metrics->addWidget(frame, 1);
    };
    metric(QStringLiteral("Wi-Fi"), wifiValue_, wifiDetail_);
    metric(QStringLiteral("MQTT"), mqttValue_, mqttDetail_);
    metric(QStringLiteral("蓝牙键盘"), bleValue_, bleDetail_);
    metric(QStringLiteral("固件版本"), firmwareValue_, firmwareDetail_);
    statusLayout->addLayout(metrics);
    const auto runtime = ui::card(QStringLiteral("运行状态"), {}, statusPage);
    summary_ = ui::label(QStringLiteral("连接设备后，这里会显示网络、消息服务和键盘的最新状态。"),
                         "muted", runtime.widget);
    runtime.layout->addWidget(summary_);
    auto *runtimeActions = new QHBoxLayout;
    auto *refreshStatus = ui::button(QStringLiteral("刷新状态"), "secondary", runtime.widget);
    refreshStatusButton_ = refreshStatus;
    reboot_ = ui::button(QStringLiteral("重启设备"), "secondary", runtime.widget);
    runtimeActions->addWidget(refreshStatus);
    runtimeActions->addWidget(reboot_);
    runtimeActions->addStretch();
    runtime.layout->addLayout(runtimeActions);
    auto *showState = new QToolButton(runtime.widget);
    showState->setText(QStringLiteral("查看状态详情"));
    showState->setObjectName(QStringLiteral("toggleStateDetails"));
    showState->setCheckable(true);
    showState->setArrowType(Qt::RightArrow);
    showState->setToolButtonStyle(Qt::ToolButtonTextBesideIcon);
    runtime.layout->addWidget(showState, 0, Qt::AlignLeft);
    state_ = new QPlainTextEdit(runtime.widget);
    state_->setObjectName(QStringLiteral("stateCode"));
    state_->setReadOnly(true);
    state_->setFixedHeight(210);
    state_->hide();
    runtime.layout->addWidget(state_);
    connect(showState, &QToolButton::toggled, this, [this, showState](bool on) {
        state_->setVisible(on);
        showState->setArrowType(on ? Qt::DownArrow : Qt::RightArrow);
        if (on)
            renderStatusDetails();
    });
    statusLayout->addWidget(runtime.widget);
    const auto guide = ui::card(QStringLiteral("开始使用"), {}, statusPage);
    guide.layout->addWidget(
        ui::step(QStringLiteral("01"), QStringLiteral("配置网络"),
                 QStringLiteral("连接 Wi-Fi，填写已有 MQTT Broker 的地址和凭据。"), guide.widget));
    guide.layout->addWidget(
        ui::step(QStringLiteral("02"), QStringLiteral("连接你的 Mac"),
                 QStringLiteral("开启蓝牙配对窗口，完成配对及 ANSI 键盘布局识别。"), guide.widget));
    guide.layout->addWidget(ui::step(QStringLiteral("03"), QStringLiteral("测试唤醒与输入"),
                                     QStringLiteral("使用 MQTT 工具发送普通文字，再验证睡眠唤醒。"),
                                     guide.widget));
    statusLayout->addWidget(guide.widget);
    statusLayout->addStretch();
    tabs->addTab(scrollPage(statusPage), titles[0]);
    auto *configPage = new QWidget(tabs);
    auto *configLayout = new QVBoxLayout(configPage);
    configLayout->setContentsMargins(0, 0, 0, 0);
    configLayout->setSpacing(14);
    const auto scanCard = ui::card({}, {}, configPage);
    auto *scanRow = new QHBoxLayout;
    scan_ = ui::button(QStringLiteral("扫描 Wi-Fi"), "secondary", scanCard.widget);
    networks_ = new QComboBox(scanCard.widget);
    networks_->setPlaceholderText(QStringLiteral("扫描后选择附近网络"));
    scanRow->addWidget(networks_, 1);
    scanRow->addWidget(scan_);
    scanCard.layout->addLayout(scanRow);
    configLayout->addWidget(scanCard.widget);
    auto *configScroll = new QScrollArea(configPage);
    configScroll->setWidgetResizable(true);
    config_ = new ConfigForm(configScroll);
    configScroll->setWidget(config_);
    configLayout->addWidget(configScroll, 1);
    auto *configActions = new QHBoxLayout;
    auto *saveNote = ui::label(QStringLiteral("保存后，重启设备使配置生效。"), "muted", configPage);
    saveNote->setWordWrap(false);
    configActions->addWidget(saveNote);
    configActions->addStretch();
    reload_ = ui::button(QStringLiteral("重新读取"), "secondary", configPage);
    save_ = ui::button(QStringLiteral("保存到设备"), "primary", configPage);
    save_->setObjectName(QStringLiteral("saveConfiguration"));
    configActions->addWidget(reload_);
    configActions->addWidget(save_);
    configLayout->addLayout(configActions);
    tabs->addTab(configPage, titles[1]);
    auto *blePage = new QWidget(tabs);
    auto *bleLayout = new QVBoxLayout(blePage);
    bleLayout->setContentsMargins(0, 0, 0, 0);
    bleLayout->setSpacing(16);
    const auto bleCard =
        ui::card(QStringLiteral("连接 Mac"),
                 QStringLiteral("已有绑定时会自动重连，无需重复开启配对。"), blePage);
    bleStatus_ = ui::label(QStringLiteral("尚未读取蓝牙状态"), "bleStatus", bleCard.widget);
    bleCard.layout->addWidget(bleStatus_);
    bleCard.layout->addWidget(ui::step(
        QStringLiteral("01"), QStringLiteral("开启配对窗口"),
        QStringLiteral("在 120 秒内，前往 Mac 的“系统设置 → 蓝牙”连接 Tepy。"), bleCard.widget));
    pair_ = ui::button(QStringLiteral("开启配对窗口"), "primary", bleCard.widget);
    bleCard.layout->addWidget(pair_, 0, Qt::AlignLeft);
    bleCard.layout->addWidget(ui::step(QStringLiteral("02"), QStringLiteral("提交配对码"),
                                       QStringLiteral("若 Mac 显示六位配对码，在下方输入并提交。"),
                                       bleCard.widget));
    passkey_ = new QLineEdit(bleCard.widget);
    passkey_->setEchoMode(QLineEdit::Password);
    passkey_->setMaxLength(6);
    passkey_->setValidator(new QRegularExpressionValidator(
        QRegularExpression(QStringLiteral("[0-9]{0,6}")), passkey_));
    passkey_->setPlaceholderText(QStringLiteral("六位配对码"));
    submitKey_ = ui::button(QStringLiteral("提交配对码"), "secondary", bleCard.widget);
    auto *passkeyRow = new QHBoxLayout;
    passkeyRow->addWidget(passkey_, 1);
    passkeyRow->addWidget(submitKey_);
    bleCard.layout->addLayout(passkeyRow);
    bleCard.layout->addWidget(
        ui::step(QStringLiteral("03"), QStringLiteral("识别键盘布局"),
                 QStringLiteral("键盘设置助理要求时，用 MQTT 工具依次发送 z 和 /，选择 ANSI。"),
                 bleCard.widget));
    bleLayout->addWidget(bleCard.widget);
    const auto clearCard = ui::card(
        QStringLiteral("更换蓝牙目标"),
        QStringLiteral("清除绑定会断开当前 Mac，之后需要重新配对。Wi-Fi 和 MQTT 配置会保留。"),
        blePage);
    clear_ = ui::button(QStringLiteral("断开并清除绑定…"), "danger", clearCard.widget);
    clearCard.layout->addWidget(clear_, 0, Qt::AlignLeft);
    bleLayout->addWidget(clearCard.widget);
    bleLayout->addStretch();
    tabs->addTab(scrollPage(blePage), titles[2]);
    auto *firmwarePage = new QWidget(tabs);
    auto *firmwareLayout = new QVBoxLayout(firmwarePage);
    firmwareLayout->setContentsMargins(0, 0, 0, 0);
    firmwareLayout->setSpacing(16);
    const auto otaCard =
        ui::card(QStringLiteral("网络升级"),
                 QStringLiteral("通过 HTTP 上传应用镜像；校验成功后自动重启，保留配置与蓝牙绑定。"),
                 firmwarePage);
    image_ = new QLineEdit(otaCard.widget);
    image_->setPlaceholderText(QStringLiteral("选择 tepy.bin 应用镜像"));
    auto *chooseImage = ui::button(QStringLiteral("选择镜像…"), "secondary", otaCard.widget);
    auto *imageRow = new QHBoxLayout;
    imageRow->addWidget(image_, 1);
    imageRow->addWidget(chooseImage);
    otaCard.layout->addLayout(imageRow);
    progress_ = new QProgressBar(otaCard.widget);
    progress_->setRange(0, 100);
    progress_->setValue(0);
    progress_->setTextVisible(false);
    otaCard.layout->addWidget(progress_);
    ota_ = ui::button(QStringLiteral("上传并升级…"), "primary", otaCard.widget);
    otaCard.layout->addWidget(ota_, 0, Qt::AlignLeft);
    firmwareLayout->addWidget(otaCard.widget);
    const auto flashCard = ui::card(
        QStringLiteral("USB 刷机与恢复"),
        QStringLiteral("按 IDF 的分段清单写入固件，保留 NVS 配置区。刷机前请退出 monitor。"),
        firmwarePage);
    manifest_ = new QLineEdit(flashCard.widget);
    manifest_->setPlaceholderText(QStringLiteral("firmware/build/flasher_args.json"));
    auto *chooseManifest = ui::button(QStringLiteral("选择清单…"), "secondary", flashCard.widget);
    auto *manifestRow = new QHBoxLayout;
    manifestRow->addWidget(manifest_, 1);
    manifestRow->addWidget(chooseManifest);
    flashCard.layout->addLayout(manifestRow);
    python_ = new QLineEdit(flashCard.widget);
    python_->setPlaceholderText(QStringLiteral("已安装 esptool 的 Python"));
    const auto idfPython = QStringLiteral("C:/Espressif/tools/python/v6.1/venv/Scripts/python.exe");
    if (QFileInfo::exists(idfPython))
        python_->setText(idfPython);
    auto *choosePython = ui::button(QStringLiteral("选择 Python…"), "secondary", flashCard.widget);
    auto *pythonRow = new QHBoxLayout;
    pythonRow->addWidget(python_, 1);
    pythonRow->addWidget(choosePython);
    flashCard.layout->addLayout(pythonRow);
    flashPort_ = new QComboBox(flashCard.widget);
    flashPort_->setMinimumWidth(150);
    flashButton_ = ui::button(QStringLiteral("开始串口烧录…"), "primary", flashCard.widget);
    auto *flashActions = new QHBoxLayout;
    flashActions->addWidget(ui::label(QStringLiteral("下载端口"), "fieldLabel", flashCard.widget));
    flashActions->addWidget(flashPort_);
    flashActions->addStretch();
    flashActions->addWidget(flashButton_);
    flashCard.layout->addLayout(flashActions);
    flashLog_ = new QPlainTextEdit(flashCard.widget);
    flashLog_->setObjectName(QStringLiteral("flashLog"));
    flashLog_->setReadOnly(true);
    flashLog_->setMaximumBlockCount(1000);
    flashLog_->setFixedHeight(150);
    flashLog_->setPlaceholderText(QStringLiteral("烧录开始后将在这里显示进度与校验结果。"));
    flashCard.layout->addWidget(flashLog_);
    firmwareLayout->addWidget(flashCard.widget);
    firmwareLayout->addStretch();
    tabs->addTab(scrollPage(firmwarePage), titles[3]);
    tabs->addTab(scrollPage(new AgentPage(tabs)), titles[4]);
    connect(navigation, &QListWidget::currentRowChanged, tabs, &QTabWidget::setCurrentIndex);
    connect(tabs, &QTabWidget::currentChanged, this,
            [this, navigation, pageTitle, pageSubtitle, titles, subtitles,
             deviceCard = connectionCard.widget](int index) {
                navigation->setCurrentRow(index);
                pageTitle->setText(titles[index]);
                pageSubtitle->setText(subtitles[index]);
                deviceCard->setVisible(index != 4);
                notice_->setVisible(index != 4);
            });
    navigation->setCurrentRow(0);
    connect(refreshPortsButton, &QPushButton::clicked, this, &MainWindow::refreshPorts);
    connect(transport_, &QComboBox::currentIndexChanged, this, [this] { updateControls(); });
    connect(connect_, &QPushButton::clicked, this, &MainWindow::connectDevice);
    connect(disconnect_, &QPushButton::clicked, &client_, &DeviceClient::disconnectDevice);
    connect(&client_, &DeviceClient::connected, this, [this] {
        initialConfig_ = true;
        connection_->setText(QStringLiteral("正在验证…"));
        perform(QStringLiteral("status.get"));
        refresh_.start(3000);
    });
    connect(&client_, &DeviceClient::disconnected, this, [this] {
        refresh_.stop();
        initialConfig_ = configLoaded_ = scanPending_ = false;
        statusFailed_ = false;
        pendingAdmin_.clear();
        config_->clearSecrets();
        passkey_->clear();
        connection_->setText(QStringLiteral("未连接"));
        connectionToggle_->setChecked(true);
        ui::property(connection_, "state", QStringLiteral("disconnected"));
        for (auto *value : {wifiValue_, mqttValue_, bleValue_, firmwareValue_})
            value->setText(QStringLiteral("—"));
        for (auto *detail : {wifiDetail_, mqttDetail_, bleDetail_, firmwareDetail_})
            detail->setText(QStringLiteral("等待连接"));
        summary_->setText(QStringLiteral("连接设备后，这里会显示网络、消息服务和键盘的最新状态。"));
        bleStatus_->setText(QStringLiteral("尚未读取蓝牙状态"));
        state_->clear();
        latestStatus_ = {};
        updateControls();
    });
    connect(&client_, &DeviceClient::succeeded, this, &MainWindow::success);
    connect(&client_, &DeviceClient::failed, this, &MainWindow::failure);
    connect(&client_, &DeviceClient::uploadProgress, this, [this](qint64 sent, qint64 total) {
        if (total > 0)
            progress_->setValue(static_cast<int>(sent * 100 / total));
    });
    connect(&refresh_, &QTimer::timeout, this, [this] {
        if (!client_.busy() && !flash_.running())
            perform(scanPending_ ? QStringLiteral("wifi.scan") : QStringLiteral("status.get"), {},
                    RequestMode::Background);
    });
    connect(refreshStatus, &QPushButton::clicked, this,
            [this] { perform(QStringLiteral("status.get")); });
    connect(reload_, &QPushButton::clicked, this, [this] {
        if (QMessageBox::question(this, QStringLiteral("重新读取"),
                                  QStringLiteral("重新读取会覆盖表单中尚未保存的编辑。继续？")) ==
            QMessageBox::Yes)
            perform(QStringLiteral("config.get"));
    });
    connect(save_, &QPushButton::clicked, this, [this] {
        QString error;
        const auto patch = config_->patch(error);
        if (!error.isEmpty()) {
            failure({}, error);
            return;
        }
        pendingAdmin_ = config_->newAdminToken();
        perform(QStringLiteral("config.patch"), patch);
    });
    connect(scan_, &QPushButton::clicked, this, [this] {
        scanPending_ = true;
        scanPolls_ = 0;
        perform(QStringLiteral("wifi.scan"));
    });
    connect(networks_, qOverload<int>(&QComboBox::activated), this,
            [this](int index) { config_->setSsid(networks_->itemData(index).toString()); });
    connect(pair_, &QPushButton::clicked, this, [this] { perform(QStringLiteral("ble.pair")); });
    connect(submitKey_, &QPushButton::clicked, this, [this] {
        if (passkey_->text().size() != 6) {
            failure({}, QStringLiteral("请输入六位配对码。"));
            return;
        }
        perform(QStringLiteral("ble.passkey"), {{QStringLiteral("passkey"), passkey_->text()}});
        passkey_->clear();
    });
    connect(clear_, &QPushButton::clicked, this, [this] {
        if (QMessageBox::question(
                this, QStringLiteral("清除蓝牙绑定"),
                QStringLiteral("设备将断开 Mac 并删除绑定，之后需要重新配对。Wi-Fi 和 MQTT "
                               "配置会保留。继续？")) == QMessageBox::Yes)
            perform(QStringLiteral("ble.clear"));
    });
    connect(reboot_, &QPushButton::clicked, this, [this] { perform(QStringLiteral("reboot")); });
    connect(chooseImage, &QPushButton::clicked, this, [this] {
        browse(image_, QStringLiteral("选择应用镜像"), QStringLiteral("应用镜像 (*.bin)"));
    });
    connect(chooseManifest, &QPushButton::clicked, this, [this] {
        browse(manifest_, QStringLiteral("选择 IDF 烧录清单"),
               QStringLiteral("烧录清单 (flasher_args.json)"));
    });
    connect(choosePython, &QPushButton::clicked, this, [this] {
        browse(python_, QStringLiteral("选择 Python"),
               QStringLiteral("Python (python.exe);;所有文件 (*)"));
    });
    connect(ota_, &QPushButton::clicked, this, [this] {
        ImageInfo info;
        QString error;
        if (!inspectApplication(image_->text(), info, error)) {
            failure({}, error);
            return;
        }
        if (QMessageBox::question(
                this, QStringLiteral("OTA 升级"),
                QStringLiteral("上传 Tepy %1 并在校验通过后重启设备？").arg(info.version)) !=
            QMessageBox::Yes)
            return;
        progress_->setValue(0);
        client_.upload(image_->text());
        updateControls();
    });
    connect(flashButton_, &QPushButton::clicked, this, [this] {
        QStringList args;
        QString error;
        if (!flashArguments(manifest_->text(), flashPort_->currentText(), args, error)) {
            failure({}, error);
            return;
        }
        if (QMessageBox::question(
                this, QStringLiteral("串口烧录"),
                QStringLiteral("将按清单烧录 %1 并复位设备。此操作不写入 NVS 配置区。继续？")
                    .arg(flashPort_->currentText())) != QMessageBox::Yes)
            return;
        client_.disconnectDevice();
        flashLog_->clear();
        flash_.start(python_->text(), manifest_->text(), flashPort_->currentText());
        updateControls();
    });
    connect(&flash_, &FlashJob::output, this, [this](QString text) {
        text.replace(QChar(u'\r'), QChar(u'\n'));
        flashLog_->moveCursor(QTextCursor::End);
        flashLog_->insertPlainText(text);
    });
    connect(&flash_, &FlashJob::finished, this, [this](bool success, const QString &message) {
        notice_->setText(message);
        ui::property(notice_, "kind",
                     success ? QStringLiteral("success") : QStringLiteral("error"));
        updateControls();
    });
    refreshPorts();
    updateControls();
}
void MainWindow::browse(QLineEdit *field, const QString &title, const QString &filter) {
    const auto path = QFileDialog::getOpenFileName(this, title, field->text(), filter);
    if (!path.isEmpty())
        field->setText(path);
}
void MainWindow::refreshPorts() {
    const auto old = ports_->currentText(), oldFlash = flashPort_->currentText();
    const auto ports = SerialPort::availablePorts();
    ports_->clear();
    flashPort_->clear();
    ports_->addItems(ports);
    flashPort_->addItems(ports);
    if (ports.contains(old))
        ports_->setCurrentText(old);
    if (ports.contains(oldFlash))
        flashPort_->setCurrentText(oldFlash);
}
void MainWindow::connectDevice() {
    if (token_->text().isEmpty()) {
        failure({}, QStringLiteral("请先填写设备管理口令。"));
        return;
    }
    configLoaded_ = false;
    rebootRequired_ = false;
    if (transport_->currentIndex() == 0)
        client_.connectHttp(address_->text(), token_->text());
    else
        client_.connectSerial(ports_->currentText(), token_->text());
    updateControls();
}
void MainWindow::perform(const QString &method, const QJsonObject &params, RequestMode mode) {
    if (client_.request(method, params, mode))
        updateControls();
}
void MainWindow::updateControls() {
    const bool flashing = flash_.running(), idle = !client_.exclusiveBusy() && !flashing,
               ready = idle && client_.isConnected();
    const bool serial = transport_->currentIndex() == 1;
    const bool editableConnection = idle && !client_.isConnected();
    connect_->setEnabled(editableConnection);
    disconnect_->setEnabled(client_.isConnected() && idle);
    transport_->setEnabled(editableConnection);
    address_->setEnabled(editableConnection && !serial);
    ports_->setEnabled(editableConnection && serial);
    token_->setEnabled(editableConnection);
    config_->setEnabled(ready && configLoaded_);
    save_->setEnabled(ready && configLoaded_);
    reload_->setEnabled(ready);
    scan_->setEnabled(ready && !scanPending_);
    pair_->setEnabled(ready);
    submitKey_->setEnabled(ready);
    clear_->setEnabled(ready);
    reboot_->setEnabled(ready);
    refreshStatusButton_->setEnabled(ready);
    ota_->setEnabled(ready && client_.isHttp());
    flashButton_->setEnabled(idle);
    flashPort_->setEnabled(idle);
    manifest_->setEnabled(idle);
    python_->setEnabled(idle);
    image_->setEnabled(idle);
}
void MainWindow::renderStatusDetails() {
    if (!state_->isVisible() || latestStatus_.isEmpty() || state_->textCursor().hasSelection())
        return;
    const auto text =
        QString::fromUtf8(QJsonDocument(latestStatus_).toJson(QJsonDocument::Indented));
    if (state_->toPlainText() == text)
        return;
    const auto vertical = state_->verticalScrollBar()->value();
    const auto horizontal = state_->horizontalScrollBar()->value();
    const auto position = state_->textCursor().position();
    state_->setPlainText(text);
    auto cursor = state_->textCursor();
    cursor.setPosition(qMin(position, state_->document()->characterCount() - 1));
    state_->setTextCursor(cursor);
    state_->verticalScrollBar()->setValue(vertical);
    state_->horizontalScrollBar()->setValue(horizontal);
}
void MainWindow::success(const QString &method, const QJsonObject &result) {
    if (method == QStringLiteral("status.get")) {
        if (result.value(QStringLiteral("v")).toInt() != 1 ||
            result.value(QStringLiteral("device_id")).toString().isEmpty()) {
            failure(method, describeError(QStringLiteral("invalid_response")));
            return;
        }
        const auto wifi = result.value(QStringLiteral("wifi")).toObject(),
                   ble = result.value(QStringLiteral("ble")).toObject();
        if (statusFailed_) {
            notice_->setText(QStringLiteral("设备连接已恢复。"));
            ui::property(notice_, "kind", QStringLiteral("success"));
            statusFailed_ = false;
        }
        ui::property(connection_, "state", QStringLiteral("connected"));
        wifiValue_->setText(wifi.value(QStringLiteral("connected")).toBool()
                                ? QStringLiteral("已连接")
                                : QStringLiteral("未连接"));
        wifiDetail_->setText(
            wifi.value(QStringLiteral("ip")).toString(QStringLiteral("等待分配 IP")));
        mqttValue_->setText(result.value(QStringLiteral("mqtt"))
                                    .toObject()
                                    .value(QStringLiteral("connected"))
                                    .toBool()
                                ? QStringLiteral("在线")
                                : QStringLiteral("离线"));
        mqttDetail_->setText(result.value(QStringLiteral("time_ready")).toBool()
                                 ? QStringLiteral("设备时间已同步")
                                 : QStringLiteral("等待时间同步"));
        bleValue_->setText(ble.value(QStringLiteral("ready")).toBool() ? QStringLiteral("已就绪")
                                                                       : QStringLiteral("未就绪"));
        bleDetail_->setText(ble.value(QStringLiteral("bonded")).toBool()
                                ? QStringLiteral("已保存 Mac 绑定")
                                : QStringLiteral("尚未配对 Mac"));
        firmwareValue_->setText(result.value(QStringLiteral("firmware")).toString());
        firmwareDetail_->setText(QStringLiteral("ESP32-S3"));
        connection_->setText(
            QStringLiteral("已连接 %1").arg(result.value(QStringLiteral("device_id")).toString()));
        summary_->setText(
            QStringLiteral("固件 %1  ·  Wi-Fi %2  ·  MQTT %3  ·  蓝牙键盘%4\nIP：%5%6")
                .arg(result.value(QStringLiteral("firmware")).toString(),
                     wifi.value(QStringLiteral("connected")).toBool() ? QStringLiteral("已连接")
                                                                      : QStringLiteral("未连接"),
                     result.value(QStringLiteral("mqtt"))
                             .toObject()
                             .value(QStringLiteral("connected"))
                             .toBool()
                         ? QStringLiteral("已连接")
                         : QStringLiteral("未连接"),
                     ble.value(QStringLiteral("ready")).toBool() ? QStringLiteral("已就绪")
                                                                 : QStringLiteral("尚未就绪"),
                     wifi.value(QStringLiteral("ip")).toString(),
                     rebootRequired_ ? QStringLiteral("  ·  配置已保存，待重启") : QString()));
        bleStatus_->setText(
            QStringLiteral("绑定：%1；连接：%2；键盘就绪：%3；等待配对码：%4")
                .arg(ble.value(QStringLiteral("bonded")).toBool() ? QStringLiteral("有")
                                                                  : QStringLiteral("无"),
                     ble.value(QStringLiteral("connected")).toBool() ? QStringLiteral("是")
                                                                     : QStringLiteral("否"),
                     ble.value(QStringLiteral("ready")).toBool() ? QStringLiteral("是")
                                                                 : QStringLiteral("否"),
                     ble.value(QStringLiteral("passkey_pending")).toBool() ? QStringLiteral("是")
                                                                           : QStringLiteral("否")));
        latestStatus_ = result;
        renderStatusDetails();
        if (initialConfig_) {
            connectionToggle_->setChecked(false);
            initialConfig_ = false;
            perform(QStringLiteral("config.get"));
        }
    } else if (method == QStringLiteral("config.get")) {
        configLoaded_ = config_->load(result);
        ui::property(notice_, "kind",
                     configLoaded_ ? QStringLiteral("success") : QStringLiteral("error"));
        notice_->setText(configLoaded_ ? QStringLiteral("已读取脱敏配置。密码默认保持原值。")
                                       : describeError(QStringLiteral("invalid_response")));
    } else if (method == QStringLiteral("config.patch")) {
        if (!pendingAdmin_.isEmpty()) {
            client_.setToken(pendingAdmin_);
            token_->setText(pendingAdmin_);
        }
        pendingAdmin_.clear();
        config_->committed();
        rebootRequired_ = true;
        ui::property(notice_, "kind", QStringLiteral("success"));
        notice_->setText(QStringLiteral(
            "配置已保存。请在“状态”页重启设备；若更换 Wi-Fi，重启后使用新的设备地址连接。"));
    } else if (method == QStringLiteral("wifi.scan")) {
        scanPending_ = result.value(QStringLiteral("scanning")).toBool() && ++scanPolls_ < 10;
        if (!scanPending_) {
            networks_->clear();
            for (const auto &value : result.value(QStringLiteral("networks")).toArray()) {
                const auto entry = value.toObject();
                const auto ssid = entry.value(QStringLiteral("ssid")).toString();
                if (!ssid.isEmpty())
                    networks_->addItem(QStringLiteral("%1  (%2 dBm)")
                                           .arg(ssid)
                                           .arg(entry.value(QStringLiteral("rssi")).toInt()),
                                       ssid);
            }
            notice_->setText(QStringLiteral("扫描结束，选择 Wi-Fi 可填入配置表单。"));
        }
    } else if (method == QStringLiteral("reboot") || method == QStringLiteral("ota")) {
        client_.disconnectDevice();
        notice_->setText(
            QStringLiteral("设备已接受重启。等待启动完成后，重新连接以确认固件版本与状态。"));
    } else
        notice_->setText(QStringLiteral("操作已完成。"));
    updateControls();
}
void MainWindow::failure(const QString &method, const QString &message) {
    if (method == QStringLiteral("status.get") && !initialConfig_) {
        statusFailed_ = true;
        connection_->setText(QStringLiteral("连接异常"));
        ui::property(connection_, "state", QStringLiteral("disconnected"));
        summary_->setText(
            QStringLiteral("无法获取最新状态，卡片显示上次成功读取的结果。正在等待恢复连接。"));
    }
    if (method == QStringLiteral("config.patch"))
        pendingAdmin_.clear();
    if (method == QStringLiteral("wifi.scan"))
        scanPending_ = false;
    if (initialConfig_) {
        initialConfig_ = false;
        client_.disconnectDevice();
    }
    notice_->setText(message);
    ui::property(notice_, "kind", QStringLiteral("error"));
    updateControls();
}
void MainWindow::closeEvent(QCloseEvent *event) {
    if (flash_.running() || client_.exclusiveBusy()) {
        notice_->setText(QStringLiteral("请等待当前设备操作结束后再关闭窗口。"));
        event->ignore();
        return;
    }
    client_.disconnectDevice();
    event->accept();
}
} // namespace tepy::desktop
