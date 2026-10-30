# 后续应用

## Qt：apps/desktop-qt

已实现独立 CMake / Qt Widgets / C++23 项目，包含 HTTP / QSerialPort 连接、配置编辑、Wi-Fi 扫描、配对辅助、OTA 和 esptool 分段烧录。以 `protocol/v1` 为合同，不依赖固件内部实现。0.2.0 固件已补齐串口适配层，共用 Management / ConfigStore。

Windows 构建、运行包、Qt 自动测试及开发板串口鉴权链路已验证。macOS / Linux 的 QSerialPort 代码使用同一实现，尚未在这些平台构建和实测。下一轮可补齐 Qt 的真实配置保存、正常 OTA 与恢复流程验收，再增加设备列表与发布包自动化。使用方法见 [桌面工具](desktop.md)。

## Go：apps/macos-agent

独立 Go module，负责 Mac 在线状态与唤醒后的任务协作，可报告用户会话状态。不能把普通后台服务等同于安全登录界面的输入权限，图形桌面解锁仍由硬件 HID 与人工实测决定。

## 演进

目标 Mac 的基础输入、睡眠唤醒及断电恢复已由用户确认；本阶段实现 Qt 管理工具。Go 服务是后续阶段，优先做在线状态和用户会话协作，不引入自动重复密码尝试。配置迁移、签名固件和设备证书仍为后续功能。没有需求时不提前引入多 Broker、云端设备平台或通用插件框架。
