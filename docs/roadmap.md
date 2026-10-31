# 后续应用

## Qt：apps/desktop-qt

已实现独立 CMake / Qt Widgets / C++23 项目，包含 HTTP / QSerialPort 连接、配置编辑、Wi-Fi 扫描、配对辅助、OTA 和 esptool 分段烧录。以 `protocol/v1` 为合同，不依赖固件内部实现。0.2.0 固件已补齐串口适配层，共用 Management / ConfigStore。

Windows 构建、运行包、Qt 自动测试及开发板串口鉴权链路已验证。macOS / Linux 的 QSerialPort 代码使用同一实现，尚未在这些平台构建和实测。下一轮可补齐 Qt 的真实配置保存、正常 OTA 与恢复流程验收，再增加设备列表与发布包自动化。使用方法见 [桌面工具](desktop.md)。

0.2.0 增加独立“Mac 状态”页，通过带口令的只读 HTTP 展示 Go 服务状态；已连接目标 Mac 验证，刷新不占用 ESP32 管理通道。

0.3.0 增加 Qt MQTT、键盘控制和 Mac MQTT 反馈，支持唤醒、文字、组合键与单次解锁流程。服务地址和口令可恢复，口令交由系统凭据库；键盘输入不保存。已通过自动执行／故障测试、Windows 凭据库及真实 Broker 只读检查；Qt 发起的真实 Mac 解锁与 TLS／mTLS 连接仍需专项验收。下一轮可增加设备列表、发布自动化及多平台构建。

## Go：apps/macos-agent

0.1.0 已实现独立 Go module、TOML 配置、MQTT 心跳／遗嘱／重连、Mac 会话与锁定状态、原生电源事件、Tepy HID 诊断、只读 HTTP 和当前用户 LaunchAgent。支持 MQTT 用户名密码、自定义 CA 与客户端证书；目标 Mac 的后台部署、真实 Broker 上报和锁屏／解锁已通过验证。见 [服务文档](macos-agent.md)。

下一步验证完整睡眠／唤醒事件、TLS／mTLS Broker 和用户切换，再考虑明确的任务协作协议。普通后台服务不等同于安全登录界面的输入权限，图形桌面解锁继续由硬件 HID 与人工实测决定。

## 演进

Flutter Mobile 0.1.2 位于 `apps/mobile-flutter`，已实现 Android MQTT 状态／控制、单次解锁、连接安全记忆和 USB OTG 管理，附中文注释、学习导读与自动测试。0.1.1 修复连接成功后旧重试仍运行导致的状态清空和解锁中断，用户已确认手机真实解锁成功、状态不闪烁；0.1.2 修复 TLS 证书展开灰框。不引入新的固件或 Go 协议。手机 OTA、ROM 刷机、iOS 和多设备档案留待实际需求；USB OTG 真实保存／重启仍需专项验收。见 [手机文档](mobile-flutter.md)。

目标 Mac 的基础输入、睡眠唤醒及断电恢复已由用户确认；Qt 管理和 Go 状态服务均已有可用版本。不引入自动重复密码尝试。配置迁移、签名固件和设备证书仍为后续功能。没有需求时不提前引入多 Broker、云端设备平台或通用插件框架。

### Flutter Windows（0.2.0）

已实现与 Android 共用的现代界面、桌面导航 / 分栏、MQTT / TLS、系统安全存储及原生 COM 串口管理。后续可考虑多连接档案、应用签名与安装器；Windows Flutter 目前以便携目录交付，与 Qt 配置独立，不提供固件 ROM 刷机或 OTA。
