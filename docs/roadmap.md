# 后续应用

## Qt：apps/desktop-qt

已实现独立 CMake / Qt Widgets / C++23 项目，包含 HTTP / QSerialPort 连接、配置编辑、Wi-Fi 扫描、配对辅助、OTA 和 esptool 分段烧录。以 `protocol/v1` 为合同，不依赖固件内部实现。0.2.0 固件已补齐串口适配层，共用 Management / ConfigStore。

Windows 构建、运行包、Qt 自动测试及开发板串口鉴权链路已验证。macOS / Linux 的 QSerialPort 代码使用同一实现，尚未在这些平台构建和实测。下一轮可补齐 Qt 的真实配置保存、正常 OTA 与恢复流程验收，再增加设备列表与发布包自动化。使用方法见 [桌面工具](desktop.md)。

0.2.0 增加独立“Mac 状态”页，通过带口令的只读 HTTP 展示 Go 服务状态；已连接目标 Mac 验证，刷新不占用 ESP32 管理通道。

## Go：apps/macos-agent

0.1.0 已实现独立 Go module、TOML 配置、MQTT 心跳／遗嘱／重连、Mac 会话与锁定状态、原生电源事件、Tepy HID 诊断、只读 HTTP 和当前用户 LaunchAgent。支持 MQTT 用户名密码、自定义 CA 与客户端证书；目标 Mac 的后台部署、真实 Broker 上报和锁屏／解锁已通过验证。见 [服务文档](macos-agent.md)。

下一步验证完整睡眠／唤醒事件、TLS／mTLS Broker 和用户切换，再考虑明确的任务协作协议。普通后台服务不等同于安全登录界面的输入权限，图形桌面解锁继续由硬件 HID 与人工实测决定。

## 演进

目标 Mac 的基础输入、睡眠唤醒及断电恢复已由用户确认；Qt 管理和 Go 状态服务均已有可用版本。不引入自动重复密码尝试。配置迁移、签名固件和设备证书仍为后续功能。没有需求时不提前引入多 Broker、云端设备平台或通用插件框架。
