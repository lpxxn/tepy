# Tepy

ESP32-S3 上的 MQTT → BLE 键盘桥接器，使用 ESP-IDF 6.1 / C++23。目标是唤醒已配对的 Mac，并按指令输入英文、数字、符号和组合键。

目标硬件：ESP32-S3-WROOM-1-N16R8；目标 Mac：M1 Max、macOS 27、开盖接电源。ESP32 独立供电。

0.1.3 已在目标 Mac（macOS 27.0.1）通过 HID 注册、普通文字输入、睡眠唤醒和唤醒后解锁实测。过夜睡眠与故障恢复等剩余验收见 [测试记录](docs/testing.md)。

0.1.5 已通过真实拔电上电后的自动重连、通知恢复和普通文字输入实测，无需重新配对。用户随后确认验证正常。

当前固件 **0.2.0** 增加 USB 串口管理，与网页共用配置、蓝牙和设备管理服务。**Qt Desktop 0.3.0** 提供 HTTP / USB 管理、MQTT 键盘控制和 Mac 状态反馈，使用 Qt Widgets / QSerialPort / Qt MQTT / C++23。服务地址和连接口令可跨次启动恢复，键盘输入不保存；状态轮询不打断表单输入。

**macOS Agent 0.1.0** 已在目标 Mac 原生构建并安装为当前用户的后台服务，提供 MQTT 心跳、会话／锁定状态、电源事件与 Tepy HID 诊断，使用 TOML 配置。真实 Broker 上报和用户手动锁屏／解锁已验证；完整睡眠／唤醒事件验收见测试记录。

## 从这里开始

- [环境、构建与首次使用](docs/getting-started.md)
- [架构与目录约定](docs/architecture.md)
- [配置与恢复](docs/configuration.md)
- [MQTT / HTTP 协议](docs/protocol.md)
- [OTA 和串口恢复](docs/ota.md)
- [测试与实机验收](docs/testing.md)
- [Qt 桌面工具使用与构建](docs/desktop.md)
- [Qt 唤醒、输入、解锁与连接记忆](docs/keyboard-control.md)
- [macOS Go 服务安装、配置与使用](docs/macos-agent.md)
- [Qt / Go 路线图](docs/roadmap.md)

已经完成网页配网并重启设备后，继续阅读 [连接 Mac、测试输入与睡眠唤醒](docs/getting-started.md#配网并重启后)。

## 仓库布局

`firmware/` 独立构建固件；`protocol/v1/` 是共享协议和样例；`apps/desktop-qt/` 是独立 Qt 项目，`apps/macos-agent/` 是独立 Go module；`tools/` 放构建、测试及 MQTT 客户端工具。各应用独立管理依赖，不从固件私有头文件复制协议。

## 功能边界

固件包括 BLE 配对与键盘、MQTT、热点配网、网页 / 串口管理和双分区 OTA。Qt 负责设备管理、键盘动作和 Mac 状态展示；Python MQTT 工具仍可独立使用。Go 服务只提供状态观察，不接收输入密码、执行脚本或解锁命令。

`sent` 只表示 HID 发送完成，不能证明屏幕已亮或密码已被接受。重启后的首次登录、FileVault 解锁和中文输入不在首版范围。键盘布局使用美式 ABC；实际蓝牙唤醒兼容性必须按测试文档在目标 Mac 上确认。

构建与测试结果见 [验证记录](docs/testing.md)。首次安装使用串口；Qt 启动及普通连接不会自动烧录固件。
