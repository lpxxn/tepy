# 架构与目录约定

## 数据流

MQTT → JSON 校验 → 类型化 Command → 单任务执行器 → BLE HID。HTTP / USB 串口管理接口经统一 Management 服务调用配置、网络和蓝牙服务，不直接产生键盘动作。HTTP 另提供流式 OTA。

Mac 原生会话／IOKit 电源事件／HID 诊断 → Go 状态快照 → MQTT 状态主题及只读 HTTP → Qt“Mac 状态”页。该数据流与 ESP32 的管理和键盘动作独立；Mac 状态不会触发密码输入。状态包含采样时间、租约和未知值，避免将历史消息当作实时结果。

## 组件职责

| 目录 | 职责 |
| --- | --- |
| firmware/main | 初始化、资源组装、按键恢复、状态快照、命令任务 |
| tepy_core | 与硬件无关的命令、字符映射、校验、去重和执行 |
| tepy_ble | NimBLE 生命周期、绑定、配对码、HID |
| tepy_config | 版本化配置、NVS、敏感字段脱敏 |
| tepy_network | STA / SoftAP、SNTP、mDNS、连接恢复 |
| tepy_mqtt | MQTT 会话、收包、发布、TLS |
| tepy_web | HTTP Bearer 管理、静态页面、API 路由 |
| tepy_management | HTTP / USB 共用的配置、状态、配对和重启业务 |
| tepy_serial | USB Serial/JTAG 驱动、带前缀 JSON 分帧、逐请求鉴权 |
| tepy_ota | 镜像接收、检查、备用分区、回滚确认 |
| protocol/v1 | 所有客户端共享的 JSON Schema 和样例 |
| apps/desktop-qt | Qt Widgets 设备管理及 Mac 状态展示，独立 CMake 工程 |
| apps/macos-agent | TOML 配置、Mac 原生观察、MQTT／HTTP、LaunchAgent，独立 Go module |
| apps/mobile-flutter | Android 界面、Riverpod 状态、MQTT 控制、USB OTG 管理，独立 Flutter 项目 |

自有组件使用 C++23，异常和 RTTI 关闭。入口有 C linkage；底层 ESP-IDF、NimBLE 保留 C 实现。使用 RAII、固定容量命令缓冲及显式错误返回。配置受互斥锁保护；网络回调只更新状态，输入在独立 FreeRTOS 任务完成。

从 0.1.2 起，HID 服务由 `tepy_ble` 内的 C++ 服务表显式注册，运行时不使用 SDK `esp_hidd` 封装。`hid_profile.hpp` 定义 HOGP 特征、权限与报告引用；`hid_profile.cpp` 提供可主机测试的字节访问器；`gatt.cpp` 把同一服务表映射到 NimBLE，记录真实主机读取并处理协议及 LED 写入。Report Map 只包含本 HID 服务的键盘报告，不发布 External Report Reference；电池服务独立提供 Battery Level。PnP 按七个二进制字节输出，不调用字符串长度函数。

从 0.1.3 起，HID 服务的所有可读值、Report Reference 描述符要求加密，所有可写值要求加密；Report 与 Boot 输入还设置 `BLE_GATT_CHR_F_NOTIFY_INDICATE_ENC`，单独保护 NimBLE 自动生成的 CCCD 写入。只设置输入的 `READ_ENC` 不会保护其他元数据或 CCCD；macOS 可能在配对完成前枚举并订阅，随后因链路尚未加密而拒绝创建 HID 设备。DIS 设备信息仍可公开读取，配对认证方式保持不变。

从 0.1.4 起，已绑定连接使用 NimBLE 主机事件队列上的一次性 callout，等待一秒让 Mac 优先恢复链路加密；若实际已加密并认证，则不重复发起 Security Request，否则再请求安全过程。首次配对仍立即请求认证。ENC_CHANGE 仅对当前连接生效；状态 13（SMP 超时）只有在连接仍存在且实际已加密、已认证、已绑定时才视为非致命，不主动断开。其他失败、未加密或未认证仍终止连接。CCCD 恢复由 NimBLE 根据原绑定处理，业务层继续等待真实订阅事件，不擅自将订阅标成开启。

从 0.1.5 起，通过 `adopt_connection` 在首个有效连接事件／GATT 访问中建立应用状态，并对同一连接保持幂等。ESP-IDF 的 CONNECT 回调会等远端版本查询完成，可能晚于加密与订阅恢复；不能在后到的 CONNECT 再次清空状态。首次接管任何连接仍先检查 NimBLE 中的实际连接及唯一允许的目标绑定／配对窗口，避免将未授权主机纳入可用状态。

Profile 访问由独立互斥锁保护；通知前先复制状态、释放锁，再调用 NimBLE，避免与主机访问回调形成锁顺序反转。主机侧 SDK 解析测试与 GATT 字节契约测试独立于无线硬件；它们不证明 macOS 已经注册键盘。

MQTT 重连生成新的随机 session；只接受当前 session。每条动作最多未来 30 秒有效，需先 SNTP 校时。去重缓存不驱逐仍有效的记录，缓存满则拒绝。OTA 与键盘执行互斥。网络断线或 BLE 中断后不会自动续发文本。

## 扩展约定

Qt 与 Go 只依赖公开协议。0.2.0 的串口适配器复用 Management / ConfigStore，不在 USB 接收任务中重新实现配置规则，也不把串口作为另一个键盘动作入口。串口独立 FreeRTOS 任务有输入长度上限和半帧超时，不回显接收内容。

Qt 位于独立的 `apps/desktop-qt` CMake 工程。`DeviceClient` 将同一个操作名映射到 HTTP 或串口；`SerialPort` 在专用线程中使用 QSerialPort；`ConfigForm` 管理脱敏配置和密码的保留／替换／清除；`FlashJob` 通过 QProcess 参数列表调用 esptool；`protocol` 校验 URL、帧与镜像／清单；`ui` 与 `MainWindow` 负责视觉及交互。GUI 不链接固件组件。

从桌面 0.1.1 起，`busy()` 表示存在待回复请求，`exclusiveBusy()` 单独表示前台独占操作。状态／扫描轮询使用后台模式，不禁用表单。用户操作可以取消对旧后台读取的等待，再立即发起请求；HTTP 忽略已取消的回复对象，串口忽略旧 ID。配置保存、配对、重启和 OTA 等前台操作不被其他请求取消，也不自动重发。样式属性未变化时不重新 polish；状态详情按需更新，并保留用户的选择和滚动位置。

桌面 0.2.0 的 `AgentClient` 使用独立网络管理器和五秒定时器，校验 Mac 状态版本、身份及租约；`AgentPage` 展示锁定、HID、MQTT 和电源事件。Mac 服务与 ESP32 使用不同口令，连接及失败状态互不影响。只读请求禁止重定向。0.3.0 起服务口令交由系统凭据库保存。

桌面 0.3.0 的 `MqttControl` 管理 Qt MQTT／TLS、精确主题订阅、状态租约与单个待回复动作；每次重连创建新客户端，不重放旧动作。`KeyboardJob` 在 GUI 事件循环中用定时器处理唤醒、等待、输入与 Mac 反馈，不阻塞线程，不保存输入。`KeyboardPage` 提供独立连接与结果展示，并向 Mac 页推送 MQTT 状态；HTTP 诊断可单独使用。`ConnectionStore` 将非秘密设置交给 QSettings、口令交给 Windows Credential Manager／macOS Keychain，凭据库失败时不回退明文。

Go 的 `internal/platform` 隔离 CGo / C++23 原生桥接和 hidutil 解析；`service` 合并采样与事件，`model` 提供线程安全快照；`mqtt`、`api` 只发布／读取快照；`config` 负责 TOML、严格校验和 TLS；`launchd` 管理当前 GUI 用户的服务。分布式通知在主线程 CFRunLoop 中处理，采样与 MQTT 在独立 goroutine 中运行。收到系统睡眠询问后立即确认，不因网络请求阻止睡眠。其他平台只提供测试 stub，不能安装为 Mac 服务。目录与部署细节见 [Go 服务文档](macos-agent.md)。

Flutter Mobile 0.1.0 采用 domain / data / application / presentation 分层。Riverpod Notifier 管理不可变快照，传输与安全存储通过接口注入；单次动作和单次解锁不保存输入，不在断线后重放。Android USB Host 桥接只提供字节流，Dart SerialManagement 负责 `@tepy:` 分帧、请求鉴权及 ID 匹配，复用既有固件串口协议。页面控制器持有草稿，不由状态心跳重建输入。进入后台取消后续步骤并关闭 MQTT / USB。详细代码索引见 [学习导读](flutter-learning.md)。

协议主版本变化新增目录；兼容字段变化更新当前 Schema 和样例。配置版本不支持时返回错误，保留 NVS，不自动擦除。

首版只支持一个活动 Broker、一个蓝牙目标。固件运行时对象存活至重启；网页随应用原子升级。

### Flutter 0.2.0 的平台边界

`apps/mobile-flutter` 同时构建 Android 和 Windows，保留目录名以兼容已有脚本。共享 Dart domain / application / presentation，平台差异集中在 `data/platform_info.dart`、系统存储插件及两端 USB 原生桥。Windows runner 只有生命周期、窗口与串口职责，不解析业务 JSON。主题在 app_theme，导航按宽度自适应，根协议与 Qt / Go 构建继续独立。
