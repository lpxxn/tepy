# Tepy

ESP32-S3 上的 MQTT → BLE 键盘桥接器，使用 ESP-IDF 6.1 / C++23。目标是唤醒已配对的 Mac，并按指令输入英文、数字、符号和组合键。

目标硬件：ESP32-S3-WROOM-1-N16R8；目标 Mac：M1 Max、macOS 27、开盖接电源。ESP32 独立供电。

## 从这里开始

- [环境、构建与首次使用](docs/getting-started.md)
- [架构与目录约定](docs/architecture.md)
- [配置与恢复](docs/configuration.md)
- [MQTT / HTTP 协议](docs/protocol.md)
- [OTA 和串口恢复](docs/ota.md)
- [测试与实机验收](docs/testing.md)
- [Qt / Go 路线图](docs/roadmap.md)

已经完成网页配网并重启设备后，继续阅读 [连接 Mac、测试输入与睡眠唤醒](docs/getting-started.md#配网并重启后)。

## 仓库布局

`firmware/` 独立构建固件；`protocol/v1/` 是共享协议和样例；`apps/desktop-qt/`、`apps/macos-agent/` 预留后续应用；`tools/` 放开发及 MQTT 客户端工具。各应用独立管理依赖，不从固件私有头文件复制协议。

## 功能边界

首版包括 BLE 配对与键盘、MQTT、热点配网、网页管理和双分区 OTA。Qt 和 Go 目录仅有扩展说明，未实现客户端。

`sent` 只表示 HID 发送完成，不能证明屏幕已亮或密码已被接受。重启后的首次登录、FileVault 解锁和中文输入不在首版范围。键盘布局使用美式 ABC；实际蓝牙唤醒兼容性必须按测试文档在目标 Mac 上确认。

构建与测试结果见 [验证记录](docs/testing.md)。首次安装使用串口；本项目不会自动刷写连接中的开发板。
