# 测试与验证记录

当前固件版本为 **0.2.0**，桌面工具为 **0.3.0**，Mac Agent 为 **0.1.0**。2026-10-29，0.1.3 的 HID 注册已通过 SSH 确认，用户确认普通文字输入、睡眠唤醒、唤醒后解锁正常；随后发现断电重连失败。0.1.5 修正安全请求竞态及冷启动回调顺序后，用户真实拔电复测确认恢复且输入正常；2026-10-30 用户补充确认验证无问题，要求继续开发。未提供逐项持续时间或次数的场景仍保留专项记录，不据此填写过夜睡眠等具体结果。

0.2.0 新增共享管理服务与 USB 串口；Qt 使用 QSerialPort，提供四页管理界面。自动测试、COM7 烧录及错误口令拒绝链路已通过，真实配置写入与 OTA 全流程仍待验收，见本页末尾。

## 自动化

先构建一次固件以取得 managed cJSON，再使用同一个 Python 安装并运行测试依赖：

```powershell
python -m pip install --target .venv/test-deps -r tools/dev/requirements.txt -r tools/mqtt/requirements.txt
.\tools\dev\test.ps1
```

脚本从 PATH 查找本机 g++、CMake 和 Ninja，也兼容本机已有的 Qt MinGW 工具路径；其他路径使用 `-Compiler` 参数指定 g++。这不引入 Qt 库依赖。Python 可通过 `-Python` 指定。

HID 描述符回归测试编译同一 ESP-IDF 源码中的真实 `esp_hid_common.c`，仅替换日志输出。脚本使用 `IDF_PATH` 或本机 IDF 安装路径；其他安装位置通过 `-IdfPath` 指定。需要先构建固件，生成实际的 `firmware/build/config/sdkconfig.h`。

`tools/dev/test.ps1` 构建并运行主机侧 C++23 核心测试，再检查协议 Schema、样例和 MQTT 工具。测试使用与固件相同的核心源码。覆盖完整 ASCII 字符映射、符号 / 重复字符、组合键、JSON 边界、过期 / 会话 / retained 拒绝、缓存满和中途断线。真实 Paho 收发测试只连接临时的 127.0.0.1 协议夹具，不访问用户 Broker；它不代表 ESP32 无线链路已经通过测试。

固件构建：`tools/dev/idf.ps1 build`。构建通过仅证明编译与链接，不等于蓝牙唤醒实测通过。

## 目标 Mac 验收

| 场景 | 预期 | 实机结果 |
| --- | --- | --- |
| 配对与 HID 注册 | 绑定后出现可用键盘设备 | 已通过；SSH 确认 HID 记录，用户确认键盘设置助理出现 |
| 普通文字输入 | `type` 输入内容出现在文本编辑器 | 0.1.3、0.1.5 用户确认通过 |
| 睡眠唤醒 | `wake` 后 Mac 亮屏 | 0.1.3 用户确认通过；睡眠时长未记录 |
| 唤醒后解锁 | `unlock --wait 3 --enter` 唤醒、等待、输入密码并回车 | 0.1.3 用户确认通过 |
| 错误配对码 / 重复配对 | 错误码不绑定，多次正确配对可恢复 | 待专项验收 |
| 全部 ASCII 32–126、连续重复字符 | ABC 美式布局逐字一致，特别检查 +、=、引号、反斜线 | 主机自动测试通过；完整实机字符集待验 |
| 组合键 | Command、Option、Control、Shift 正确 | 待实机专项验收 |
| 过夜睡眠 | 长时间睡眠后仍可唤醒及输入 | 待验收 |
| ESP32 USB 硬件复位 | 绑定保留，通知订阅与 Mac HID 自动恢复 | 0.1.4 三次通过，各次观察超过 30 秒 |
| ESP32 物理断电再上电 | 自动恢复并可再次输入 | 0.1.3 / 0.1.4 失败；0.1.5 用户实测通过，无需重新配对 |
| Mac 蓝牙开关 | 可恢复连接 | 待专项验收 |
| 输入中 BLE 或 MQTT 断开 | 中止，不在重连后继续输入 | 主机自动测试通过；故障注入实测待验 |
| Broker / 路由器重启 | 自动恢复，session 改变，旧命令不执行 | 待实机验收 |
| retained / 重复 / 过期 / 非法消息 | 拒绝，不产生按键 | 主机自动测试通过；实机专项待验 |
| 错误 Wi-Fi / NTP 不可达 | 可恢复热点；未校时拒绝动作 | 待实机专项验收 |
| OTA 正常 / 中断 / 错误镜像 | 正常更新，错误不切换，启动失败回滚 | 待实机验收 |

先在文本编辑器测试，锁屏使用临时测试内容。只在人工确认输入焦点后验证密码。不要自动重复密码尝试。`sent` 不证明解锁成功。

## 本次验证记录

2026-10-28，本机 Windows 验证：

- ESP-IDF 6.1 / Xtensa GCC 15.2.0：固件编译、链接、镜像大小检查及合并镜像生成通过。自有组件编译命令最终使用 `-std=gnu++23`，异常与 RTTI 关闭。
- 本机 MinGW GCC 13.1.0：341 项 C++ 核心检查通过。
- 5 份 JSON Schema、7 个样例、3 组 CLI → 固件解析器交叉向量通过。
- 10 个 Python 客户端测试通过，其中 2 个使用本机临时 MQTT 套接字夹具和真实 Paho 客户端。
- 内置网页 JavaScript 语法检查通过；真实浏览器与设备 API 的交互待验。
- 锁定依赖：cJSON 1.7.19~2、mDNS 1.14.1、MQTT 1.1.0，详见 `firmware/dependencies.lock`。

截至上述 2026-10-28 本机验证，尚未执行开发板刷写、实际 Wi-Fi / BLE 射频共存、目标 Mac 配对与睡眠唤醒、真实 Broker TLS 和 OTA 断电回滚。后续已完成的硬件验证见下文 0.1.3 记录，剩余项目见上表。OTA 校验采用 IDF 镜像校验，不提供发布者签名验证。

### 0.1.1 HID 修复回归

用户提供的 0.1.0 实机日志确认了 Wi-Fi、MQTT、校时和蓝牙配对成功，但 macOS `hidutil list` 无 Tepy 键盘记录，文本输入失败；不将该状态记为 HID 验收通过。

本机发现并修正了 DIS PnP ID 特征默认关闭的问题，同时统一型号／Appearance、初始化输入报告长度、按当前协议订阅判断就绪，并加入发布服务的启动自检。362 项主机侧检查通过，包括真实 SDK HID 解析器检查报告 ID、八字节输入和一字节输出，以及 PnP 编码和协议订阅错配回归；5 份 Schema、7 个样例、3 组交叉向量和 10 个 Python 测试通过。

后续实机复测确认 0.1.1 仍没有目标 Mac 的 HID 键盘记录和文字输入，未通过 HID 验收；睡眠唤醒验收尚未进行。

### 0.1.2 GATT 服务修正与诊断

后续用户实测确认：0.1.1 已发布 PnP，Report 通知也已订阅，但 macOS 仍没有键盘记录和文字输入。Bluetooth 日志样本主要为系统广播和其他外设，没有提供 Tepy 的明确拒绝原因。

SDK 原 HID 服务表会发布一个指向 Battery Service UUID 的 External Report Reference；本项目键盘 Report Map 没有对应外部报告。0.1.2 用项目内 C++ 服务表注册 HID / DIS，移除该引用，固定输入八字节、输出一字节、Report Reference 两字节、PnP 七字节；启动时读取实际注册的 GATT 数据逐项检查。BLE 主机和控制器仍使用 NimBLE，没有修改外部 SDK。

403 项主机侧检查通过，包括同一 SDK HID 解析器、实际 GATT 值访问器的初始值／当前值、Report Reference、PnP、特征权限、协议切换、LED 读写及非法写入拒绝；5 份 Schema、7 个样例、3 组交叉向量和 10 个 Python 测试通过。固件构建及镜像打包通过。

新增 `host_reads` 和 TX 诊断可区分本地自检、主机枚举和 BLE 通知发送，不能将本地测试或 TX 成功当作输入验收。

2026-10-29，用户在目标 Mac 上复测 0.1.2：

- 固件启动、Wi-Fi、MQTT、校时、BLE 认证绑定及 Report 输入订阅正常。
- 设备端日志记录主机读取 HID Information（4 字节）、Report Map（65 字节）、两个 Report Reference（各 2 字节）、PnP（7 字节）及设备信息。
- MQTT 状态显示 `tx_completed = 4`、`tx_errors = 0`；这些计数是 BLE 栈结果，未确认 macOS 应用收到按键。
- 用户确认文字编辑器仍没有文字，且 Tepy 没有触发键盘设置助理。0.1.2 尚未取得新的 Mac `hidutil list` 结果，不能仅依据旧版本列表断定新版本的 HID 注册状态。

0.1.2 文本输入验收失败，根因仍未确定，睡眠唤醒与解锁未验收。下一步采集当前版本的主机 HID 记录和覆盖配对过程的主机日志；流程见 [首次使用与故障定位](getting-started.md#012-实测后的下一步)。配对码属于当前固件主动选择的 SMP 认证方式，不能据此判断 HID 设备类型。

### 0.1.3 加密时序修正

2026-10-29，通过用户授权的 SSH 直接检查 Mac，确认系统为 macOS 27.0.1（26A434），Tepy 0.1.2 在蓝牙信息中已显示为 Keyboard、HID BLE，但 `hidutil` 及 IOHIDUserDevice 中没有 Tepy。此前未采集的 BTLEServer 进程在同次配对中输出 `Not creating HID device as the link is not encrypted`，约 22 秒后才收到 `peerDidCompletePairing`，随后记录服务超时。

0.1.3 将 HID 元数据、Report Reference 和协议／报告访问设为要求加密，并单独要求 CCCD 写入加密，防止主机先完成 HID 初始化、后完成配对。保留原配对认证策略和 DIS 公开读取，增加不含敏感内容的链路安全状态日志。

417 项核心检查通过，包括所有 HID 读写及通知订阅的加密权限契约；5 份 Schema、7 个样例、3 组交叉向量及 10 项 Python 客户端测试通过。固件编译、链接和合并镜像生成通过。

用户退出 monitor 并确认后，已通过 COM7 烧录 0.1.3，烧录校验通过，保留 NVS。用户在 Mac 重新连接／配对后，于 22:06 通过 SSH 直接确认：

```text
VendorID  ProductID  UsagePage  Usage  Transport             Product
0x303a    0x4001     1          6      Bluetooth Low Energy  Tepy-da3a18
```

`hidutil` 同时列出 Tepy 的 IOHIDUserDevice 和 AppleUserHIDEventService，驱动为 AppleUserHIDEventDriver；BTLEServer 日志先记录 `peerDidCompletePairing`，随后记录 IOHIDUserDevice `Start`。用户也确认 Mac 已弹出要求按左 Shift 右侧按键的键盘设置助理。**HID 键盘注册实测通过。** 首次配对过程中有一次 Confirm Value 校验失败，随后重新配对完成；尚未进行重复配对稳定性验收。

键盘设置助理使用 MQTT 单键 `z`、`/` 完成 ANSI 布局识别，具体操作见 [配对与布局识别](getting-started.md#配对码与按-shift-旁边的键有什么区别)。

随后用户按“普通文字输入 → 睡眠后 `wake` → `unlock --wait 3 --enter`”三个步骤测试，并明确反馈“都试过了，没有问题”。据此记录普通文字输入、睡眠唤醒及唤醒后密码输入解锁实测通过；这是用户对 Mac 实际界面结果的确认，不是依据 MQTT `sent` 推断。未采集或保存登录密码。

本次未记录睡眠持续时间和重复次数，不能据此记为过夜睡眠或长期稳定性通过；完整 ASCII、组合键、断线恢复和 OTA 仍按上表专项验收。

### 0.1.4 断电重连修正

用户随后实测 0.1.3 断电再上电：Wi-Fi、MQTT、绑定均保留，但 `ready = false`，Report / Boot 订阅均为 false，输入被正确拒绝。直接读取 Mac 日志发现约每 30 秒重连一次；ESP32 串口同时记录 `HID link security status=13 encrypted=1 authenticated=1 bonded=1`，随后固件主动以认证失败结束连接。

这是重连安全请求的竞态：连接实际已经安全，冗余的 SMP 安全过程仍可能超时。此前代码将所有非零返回码视为链路不安全，导致主动断开循环。[ESP-IDF BLE UART 官方移植说明](https://github.com/espressif/esp-idf/blob/master/examples/bluetooth/common/ble_uart/PORTING.md#9-faq) 也记录了同样的 `status=13 / encrypted=1 / bonded=1` 现象。

0.1.4 延迟已绑定连接的主动安全请求，优先检查 Mac 已恢复的加密／认证；对仍已加密、已认证、已绑定的当前连接单独处理超时。未加密、未认证、未绑定或 Confirm Value 校验失败等情况仍拒绝。通知订阅必须通过真实写入／绑定恢复事件确认，不跳过订阅检查。

427 项核心检查、5 份 Schema、7 个样例、3 组交叉向量、10 项 Python 客户端测试通过；包含超时不能绕过加密、MITM 认证和绑定约束的回归。固件构建和 COM7 烧录校验通过，NVS 配置及绑定保留。硬件重启与真实断电复测结果继续记录在本节。

使用 ESP-IDF 官方 monitor 的复位功能进行了三次实际 USB 硬件复位，串口均确认 `USB_UART_CHIP_RESET` 及 0.1.4 启动。三次均从绑定恢复 Report 输入订阅，串口出现 `HID subscription handle=38 reason=3 report=1`，设备启动后约 2.3–2.6 秒恢复订阅；Mac 随后自动恢复 Tepy 键盘与 AppleUserHIDEventDriver。每次均观察超过 30 秒，未再出现原先由 `status=13` 引起的主动断开循环。后两次还直接记录到 `status=0 encrypted=1 authenticated=1 bonded=1`。未清除绑定或重新输入配对码。

上述结果是硬件复位验证，不等同于物理断电验收。随后用户真实拔电复测确认：0.1.4 的 `encrypted / authenticated` 为 true，但 `security_status = -1`、两种通知订阅仍为 false、`ready = false`。因此 0.1.4 未通过物理断电恢复验收。

### 0.1.5 冷启动事件顺序修正

继续检查实际 SDK 源码确认：外设建立物理连接后，NimBLE 发起 Read Remote Version，完成后才发送应用 CONNECT 回调；在此之前，安全恢复、CCCD 恢复和 GATT 访问均可能已发生。此前 CONNECT 无条件清空安全、订阅、协议和读取记录；0.1.4 新增的安全回调当前连接检查还会丢弃尚未收到 CONNECT 时到达的加密事件，造成冷启动时应用状态与实际链路不一致。

0.1.5 在 CONNECT、安全、订阅或实际 GATT 访问首次到达时，先查询实际连接并验证目标身份，再初始化一次连接状态；同一连接后到的 CONNECT 保留已有状态。订阅仍来自 NimBLE 实际写入或恢复事件，不从绑定状态推定，不修改 SDK 或绕过加密／认证。新增 `HID attach ... source=...` 和 CONNECT 状态日志用于核对事件顺序。

427 项核心检查、5 份 Schema、7 个样例、3 组交叉向量与 10 项客户端测试通过。这些测试覆盖现有安全策略及协议，不将其当作冷启动事件顺序已通过实机验证；物理拔电结果待补充。

0.1.5 编译及 COM7 烧录校验通过。启动后串口直接观察到：安全恢复发生于 2231 ms，Report 订阅恢复于 2248 ms，CONNECT 回调于 2290 ms 才到达，此时 `encrypted=1 authenticated=1 report=1` 已保留。SSH 同时确认 Mac 已创建 Tepy 键盘。该实机顺序验证了晚到 CONNECT 不能重新清空状态。

退出 monitor 后，用户保持原绑定并再次真实拔电上电，提供了 0.1.5 的 MQTT 状态：`connected / ready / bonded / encrypted / authenticated / report_subscribed` 均为 true，`security_status = 0`，`boot_subscribed = false`（当前为 Report 模式，符合预期）。随后执行 `type`，回复 `sent`，并明确确认“好了”。据此记录真实断电自动恢复及普通文字输入实测通过；没有清除绑定或重新配对。SSH 也观察到本次断电后 Mac 自动重新创建 Tepy 的 IOHIDUserDevice。

本次只记录了一次 0.1.5 物理断电成功，不据此推定多次冷启动、过夜睡眠或全部故障恢复均通过；这些项目继续单独验收。

### 0.2.0 与 Qt Desktop 0.1.0

2026-10-30，本机 Windows / ESP-IDF 6.1 / Qt 6.12.0：

- 固件构建、镜像大小检查和合并镜像生成通过。COM7 分段烧录与芯片端 Hash 校验通过；未写 NVS 区域，未清除绑定。
- 427 项现有核心检查、20 项串口协议检查通过。串口检查覆盖拆包、粘包、CRLF、超长帧丢弃与恢复、半帧清理、鉴权在业务调用之前、畸形／重复字段拒绝、敏感内容不回显及业务错误封装。
- 7 份 JSON Schema、9 个样例、3 组 MQTT 工具 → 固件解析器交叉向量通过；10 项 Python MQTT 客户端测试通过。
- QtTest 报告为 18 passed、0 failed、0 skipped（含初始化／清理和参数化错误场景）。覆盖 HTTP 路由、Bearer、拒绝重定向、错误回复、配置密码保留／清除、UTF-8 长度、镜像目标检查、分段烧录不写 NVS、上传内容一致、15 秒超时不重试、切换连接后忽略旧串口事件，以及窗口连接后读取状态与配置、解锁保存按钮的流程。
- 已使用真实 `tepy.bin` 核对 Qt 镜像检查器的目标、项目与版本字段。Qt 的串口检查通过真实 COM7 / QSerialPort 发送故意错误口令，收到真实固件的 `unauthorized`；不写配置，不发送键盘动作。
- 四页界面已生成并检查中文截图，连接后收起设置栏，配置和长内容支持滚动；另检查 1040×760 紧凑窗口。文档预览使用测试夹具数据，不代表实机状态。
- `windeployqt` 已打包 Widgets / Network / SerialPort 及依赖；在仅保留 Windows 系统目录的 PATH 下执行分发包 `--self-check`，退出码为 0。
- 固件分发脚本检查应用版本及合并镜像中的应用字节一致，生成 `dist/firmware/0.2.0/` 和 SHA256SUMS。

没有读取或记录真实设备管理口令、Wi-Fi / MQTT 密码或 Mac 登录密码。Qt 的完整合法口令读取、真实配置写入／重启、配对码提交、OTA 及其失败恢复仍需实机端到端验收；串口错误口令测试不代替这些验收。0.2.0 未重新完成 Mac 文本／睡眠与 OTA 断电专项，也未完成 macOS / Linux 桌面构建验收。


### Qt Desktop 0.1.1 自动刷新修复

2026-10-30，用户报告页面周期性闪烁、按钮短暂变灰。确认每三秒定时读取复用了前台忙碌状态，禁用并恢复表单；相同样式属性仍反复 unpolish / polish，隐藏的 JSON 文档也在每次回复后整体重建。

0.1.1 区分后台读取和前台独占操作。定时状态／扫描不锁定控件，用户操作优先于旧后台读取；进行中的前台请求仍互斥，不自动重发。相同样式不重复应用，详情仅在可见且未选择文本时刷新，并保存滚动位置。

QtTest：21 passed、0 failed、1 skipped。新增回归直接运行三秒定时器和延迟回复，观察轮询开始至结束的 EnabledChange 事件为 0，输入焦点、草稿和选区保持不变；隐藏详情没有文档变化，打开后显示最新状态，后续轮询保留选中文本。另验证前台保存取代后台读取而不丢失、不重发，后台模式不能发送写操作，重复样式值不触发 polish。

本次未更改固件，不重烧 ESP32；USB 实机检查未重复执行（对应可选测试跳过）。Windows 分发包另做独立启动检查。用户需退出旧桌面窗口再打开 0.1.1。

### macOS Agent 0.1.0 与 Qt Desktop 0.2.0

2026-10-30，目标 M1 Max / macOS 27.0.1，原生 Go 1.27.3、CGo、CoreGraphics / IOKit；Windows Qt 6.12.0：

- Go 在 Windows 通过全部测试与 vet；目标 Mac 原生 `go test -race ./...` 和 `go vet ./...` 通过。覆盖 TOML 严格解析、未知版本／字段拒绝、初始化不覆盖文件、秘密不进入错误、TLS CA／客户端证书加载及错误私钥拒绝、状态并发拷贝、锁定事件回退与控制台边界、租约、电源状态变化、HTTP 鉴权／方法／过期拒绝、HID Devices 解析和 LaunchAgent 参数转义。
- MQTT 测试使用真实 Paho 客户端连接本地测试 Broker，核对 CONNECT 用户名密码、干净会话、QoS 1 retained 遗嘱、状态消息、事件通知和过期状态不发布。另通过真实局域网 Broker 订阅收到代理的 heartbeat／retained 状态，MQTT connected 为 true。TLS／mTLS 证书加载已测，远程 TLS Broker 的端到端连接尚未验收。
- 已原生构建并安装当前 GUI 用户的 LaunchAgent，确认 launchctl 为 running，更新安装保留 TOML。配置在 `~/Library/Application Support/Tepy/agent.toml`；程序、配置与日志不依赖临时源码目录运行。本次按用户明确授权监听 `0.0.0.0:18765`，未修改系统防火墙。
- HID 实机状态为 registered，匹配 Tepy-da3a18（Bluetooth Low Energy）。IOKit 电源监听注册成功；这不等于完整睡眠／唤醒事件已经验证。
- 用户手动锁屏／解锁并回复完成后，真实 MQTT 观测依次为 unknown → locked（cg_session_property）→ unlocked（screen_notification）；对应 locked / unlocked 的 Unix 毫秒为 1793374595015 / 1793374602684。未读取、保存或自动输入 Mac 登录密码。
- 锁定属性在未锁定时可能缺失，因此原生快照保留 unknown；持续运行的服务可使用当前 GUI 会话实际观察到的解锁通知。主线程 CFRunLoop 处理通知，采样与 MQTT 独立运行。此信号只用于状态观察，不是认证凭据。
- 测试期间 Mac DHCP 地址从 `192.168.50.90` 变为 `192.168.50.2`。旧 IP 超时不能据此判定睡眠或服务退出；更新地址后恢复 HTTP／SSH 和 MQTT 观测。Windows 的 `.local` 名称解析本轮未验证。
- QtTest：25 passed、0 failed、2 skipped（可选固件镜像／USB 硬件项本轮未设置）。新增 Mac 状态校验、过期拒绝、只读 Bearer、身份改变停止和页面连接测试；到目标 Mac 的真实 HTTP 检查通过，并生成口令遮蔽的实机页面截图。
- 427 项固件核心检查、20 项串口协议检查、8 份 JSON Schema、10 个样例、3 组 CLI → 固件交叉向量和 10 项 Python MQTT 客户端测试通过；本轮未改固件、未重新烧录 ESP32。

发布目录及压缩包包含程序、示例配置和文档，不含真实 TOML、SDK、源码 vendor 或登录凭据。Windows Qt 包另检查依赖部署和仅系统 PATH 下的独立启动。

仍待专项验收：Go 完整睡眠／唤醒与过夜恢复、用户切换／退出登录、其他 macOS 版本、TLS／mTLS Broker 实机部署，以及已有 Qt 配置写入／OTA 端到端项目。早前固件睡眠唤醒通过的记录，不代替新 Go 电源观察链路的验收。

2026-10-31，用户确认本轮验证无异常，并告知 Mac 当前地址为 `192.168.50.246`。本次反馈未逐项列出专项测试结果，以上专项继续按各自记录验收；使用文档中的当前连接地址已同步更新。

### Qt Desktop 0.3.0 MQTT 与连接记忆

2026-10-31，Windows / Qt 6.12.0 / C++23。Qt MQTT 6.12.0 官方固定版本源码已在工作区构建，归档 Hash 与构建方式见 `apps/desktop-qt/THIRD_PARTY.md`；未修改全局 Qt 安装。

- 原桌面测试：25 passed、0 failed、2 skipped。真实 Mac HTTP（192.168.50.246）通过；可选固件镜像和 USB 硬件项目本轮未设置。修正原轮询测试等待服务端写入但尚未送达界面的时序，改为等待可见详情实际更新；焦点、草稿、按钮和选区保持检查仍保留。
- 新 MQTT 测试：15 passed、0 failed、0 skipped。真实 QMqttClient 连接测试 Broker，检查 MQTT 3.1.1／干净会话／认证字段、QoS 1／retain=false、session／expires_at、非当前 ID 与 retained 回复拒绝、重复回复忽略、旧时间／错误身份状态拒绝、完整单次解锁、未知或未锁定不输入、会话变化取消、断线重连不重放、未收到 PUBACK 时取消仍按六秒期限关闭连接、页面输入清理，以及 Windows 凭据库随机条目的写入／恢复／删除。
- 真实局域网 Broker 的只读测试收到目标 ESP32 和 Mac Agent 的有效状态；此测试不发布动作、不输入密码。既有固件／Go 未修改，未重烧 ESP32 或重新部署 Go。
- Windows Qt 通过 `mqtt://127.0.0.1:1883` 读取同机 Broker 的状态通过；另测 `192.168.50.99` 时未取得就绪状态，未进一步将其归因为具体网络设置。Qt 的本机默认地址采用已验证的 localhost；ESP32／Mac Broker 配置保持局域网地址，不修改网络设置。
- 连接地址等非秘密值由 QSettings 保存，口令在 Windows Credential Manager。测试只操作随机 test 档案，未读取或改写用户已有的服务口令；其他界面测试关闭持久化。URL 内嵌凭据的保存被拒绝。
- 六页界面、键盘控制连接收起和结果区域已生成并检查中文截图；控制页截图使用虚构状态和本地测试 Broker。发布包包含独立 Qt MQTT DLL、模块源码／许可及桌面源码；另做系统 PATH 下启动与 Hash 检查。

待实机专项：由 Qt 触发目标 Mac 的文字／组合键／完整解锁，TLS／mTLS Broker 握手与错误证书场景，macOS Keychain／Qt 构建和 Linux 平台。上述虚构密码只进入本机测试 Broker，不将自动化解锁夹具当作真实 Mac 登录验收。

### Flutter Mobile 0.1.0

2026-10-31，Flutter 3.47.9 / Dart 3.13.7 / Riverpod 3.4.3，Windows 开发机；手机为 OPPO Find X9（PLJ110 / Android 17）。代码与协议独立于 Qt / Go 构建，不更改固件与 Mac 服务。

- `flutter analyze` 无问题，Dart 格式检查通过，25 项领域／异步／串口／界面测试通过。
- 输入与配置覆盖全部可打印 ASCII、长度、组合键、版本与租约、未知字段类型、密码保留／替换／清除；不使用用户真实凭据。
- 流程测试覆盖唤醒后新 Mac 状态、一次输入、未知或已解锁不输入、断线恢复不重放、错误 ID／retained／重复回执、ESP32 会话改变、取消后 PUBACK 六秒上限及进入后台取消。
- 真实 Dart MQTT 客户端连接本机测试端点，核对 3.1.1、clean session、认证标志、四个精确订阅、QoS 1／retain=false 和独立 PUBACK；FakeBroker 测试另验证业务流程。
- USB 分帧测试覆盖拆包、粘包、CRLF、普通日志丢弃、超长及半帧恢复、逐请求 token、错误 ID、超时不重发。控制器测试核对鉴权后读取、保存后回读、新密码引用清理、忘记口令、断线取消和迟到回复忽略。
- USB 配置的零端口、超范围端口及超出整数范围的端口统一返回固定说明，不透传输入原文或产生未处理异常。
- 四页中文界面预览已检查；320 像素窄屏无溢出。表单保留草稿、密码对话框清理、键盘输入不进入连接存储均有自动测试。
- 真实 Broker 只读预检中，Mac Agent 在线并持续上报；ESP32 当时 retained 状态为 offline。此结果不能作为手机唤醒／输入已验收。

Android Debug APK 已构建成功，包含 Kotlin USB Host 桥接与 JNI / Keystore 依赖。构建使用 SDK 36 / NDK 28.2.13676358 / CMake 3.22.1；库编译平台通过 AGP finalizeDsl 与 SDK 36 对齐。首次依赖下载使用工作区独立 Gradle 缓存和镜像，不修改用户全局 Gradle / 代理设置；Gradle 官方分发包 SHA-256 与 USB 驱动官方源码归档均已校验。

Find X9 上的原生集成测试已通过（1 项集成场景）：四页导航无异常，使用随机测试条目验证系统安全存储写入／读取／删除，Android USB 枚举通道可调用，手机通过局域网 Broker 完成连接／订阅并收到有效 Mac Agent 状态。测试不发布键盘或配置动作，不使用已有口令。没有接入手机到 ESP32 的实际 OTG 链路，USB 枚举可调用不等于配置读写通过。发布包使用重新构建的普通 `lib/main.dart` 入口。

最终 arm64 Release APK 约 17.7 MB，使用开发签名。AOT 入口、API 24 / target 36、APK v2 签名及发布目录 SHA256SUMS 已核对；源文件包排除 SDK、缓存、keystore、真实 TOML 与本地恢复值。普通运行版已通过 ADB 安装并在 Find X9 前台启动，实机界面检查正常，启动日志未见 FATAL / Unhandled / JNI 类加载错误。代码包含系统字体适配，不捆绑截图使用的 Windows 字体。构建与打包脚本的 `-Check -Package` 流程已实际执行通过。

手机至 ESP32 的实际 OTG 授权、合法口令读取／配置保存／重启、手机发起的真实按键与完整解锁、远程 TLS／mTLS Broker 尚待专项验收。内存缓冲清理不保证 Dart 字符串、输入法或框架副本全部擦除。

### Flutter Mobile 0.1.1 连接竞态修复

用户报告手机只能唤醒而没有输入，且状态在在线／未知、就绪／未就绪间切换，按钮同时禁用。控制器假定 connect Future 完成时成功事件已经投递；实际异步 Stream 通知可能晚到，finally 安排的一秒重试没有被成功事件取消，导致持续替换连接并清空状态，三秒等待也被取消。

新增回归在修复前实测八秒创建九次连接，未通过；修复后只创建一次连接，并完成默认三秒等待后的单次文本发送和虚构解锁反馈。真实 MQTT 客户端与本机测试 Broker 另验证连续三秒不重连、不清空状态；界面测试连续八秒检查在线、就绪、锁定卡片和可用按钮。

0.1.1 的格式检查、静态检查、28 项自动测试及 Release arm64 构建通过。修复同时在成功事件中取消旧重试，重试调度及连接入口核对当前是否在线；没有取消状态租约、Mac 前置检查或增加密码重试。

Debug 使用 `com.tepy.tepy_mobile.debug` 和独立名称“测试”，日常包名不变。真机运行先构建测试 APK，再以 drive 的 `--use-application-binary` 读取 APK 实际包名，避免首次切换包名时工具复用旧缓存的日常应用身份。该切换过程曾误卸载旧日常版；已向用户说明并重新安装修复版，不将此过程记作保留原连接数据成功。

Find X9 / Android 17 的最终 drive 集成测试通过：真实 Broker、ESP32 0.2.0、Mac Agent 0.1.0 连续观察 45 秒，所有状态通知均保持 online、设备可操作与 Mac 状态有效，至少收到四份不同时间的 ESP32 快照，没有中途清空或按钮禁用。完整集成场景含启动、Keystore、USB 枚举和四页导航，约 55 秒结束。日常 0.1.1 已装回并核对版本；测试后仍保留日常包，已切回日常界面。

测试前仅发送一次 Shift 将睡眠中的 Mac 唤醒并等待 Agent 恢复上报；持续测试自身不发送动作、不输入密码。随后用户在日常 0.1.1 明确确认“解锁成功，状态不闪了”，据此记录手机真实解锁和状态稳定通过。未读取、记录或自动输入真实登录密码。

### Flutter Mobile 0.1.2 TLS 展开修复

用户报告“TLS 证书”展开后出现无限长灰框。新增回归确认异常为 ScrollPosition 恢复滚动位置时将 bool 转为 double：ExpansionTile 的展开状态与输入框内部 Scrollable 继承同一 PageStorage 路径。给展开控件和各输入框外层分配独立 PageStorageKey，保留 TextField 原有定位 Key，隔离展开状态和滚动距离。

界面回归覆盖实际展开后 CA 字段存在、反复收起／展开、草稿保留、私钥编辑，以及已连接时的只读展开；不只检查折叠态。Find X9 的独立 drive 真机测试也已反复展开／收起 TLS 区域并通过。移除 ExpansionTile 默认上下黑线，保留 Card 自身圆角和浅色边框。

0.1.2 的格式检查、静态检查、29 项自动测试和 Release arm64 构建通过；TLS 展开截图已检查，无灰框和默认黑色分隔线。未更改 MQTT 执行逻辑，0.1.1 的真实解锁与状态稳定验证继续有效。

已使用 `adb install -r` 覆盖安装日常版并启动，核对为 versionName 0.1.2 / versionCode 3；本次没有卸载或清除日常应用数据。

### Flutter Mobile 0.1.3 圆角点击反馈与快捷连接

TLS 卡片和 ExpansionTile 内部 Material 使用相同的 22 像素圆角，边界显式 Clip.antiAlias，防止按下高亮越过圆角。检查了折叠和展开时按住手势、动画推进后的截图；保留卡片浅色圆角边框，没有新增上下分隔线。

状态页在 Mac 状态卡下方显示已保存设备的连接入口，连接中显示进度并禁止重复连接。控制器分别保存本次 profile 与 savedProfile，临时连接不覆盖快捷入口；成功保存更新档案，清除后移除入口，失败保存保留原档案。沿用现有系统安全存储格式，不新增明文配置或自动连接。

0.1.3 格式检查、静态检查、31 项自动测试及 Release arm64 构建通过。新增控制器回归覆盖已保存档案恢复、临时连接后快捷重连、重复调用、失败保存、清除与重新保存；320 像素宽界面验证状态页入口、连接中禁用及清除后隐藏。按住状态与快捷入口截图已检查。

已覆盖安装并启动日常版，核对 versionName 0.1.3 / versionCode 4，未卸载或清除应用数据。

### Tepy Flutter 0.2.0：现代界面与 Windows

2026-10-31，Flutter 3.47.9 / Dart 3.13.7 / Riverpod 3.4.3。统一靛蓝主题、内置 OFL 中文字体、深色 Mac 状态卡与紧凑手机操作卡；Windows 侧栏、宽屏分栏及受限宽度表单。手机、窗口使用同一业务与协议，不改固件 / Go / Qt。

- 格式与 `flutter analyze` 通过，32 项自动测试通过。新增 1440 × 1000 桌面导航、缩小至 800 × 700 切换底栏、恢复窗口后草稿保留，以及桌面文字操作。保留 320 像素、TLS 展开/按住裁剪、连接不闪烁、保存档案和输入不持久化回归。
- Windows 11 x64 / Visual Studio 2022 17.14.41 / SDK 10.0.26100.0 Release 构建通过。首次构建因系统未装 ATL 缺少 atlstr.h，经官方 Visual Studio Installer 补装 v143 ATL 后通过，未修改安全存储插件。
- 原生 Windows 集成场景通过：随机安全存储条目写 / 读 / 删、真实 ESP32 COM 枚举和双向收发、关闭重新打开、本机 Broker 的只读连接 / 设备状态及连续 20 秒稳定观察、四页导航和页面刷新。串口使用明确无效测试口令，仅收到 unauthorized；未读取实际管理口令、保存配置或发布键盘指令。
- 原生 Windows 窗口已启动，能显示真实 ESP32 / BLE / Mac 状态。桌面与手机中文预览、TLS 按住效果已检查。字体来自 Google Fonts Noto Sans SC，派生名 Tepy Sans，源 Hash 和许可记录在应用 THIRD_PARTY.md。

原生 COM 的有效口令读取 / 保存 / 重启、拔线恢复、远程 TLS / mTLS 以及 Windows 发起完整 Mac 解锁仍待对应实机验收；不将无效口令的通信测试当作配置写入验收。

Find X9 / Android 17 的独立测试 APK 已在 0.2.0 通过原生 drive 场景（约 61 秒）：安全存储随机条目、USB 枚举、四页导航、TLS 反复展开 / 收起，以及真实 Broker、ESP32 和 Mac 状态连续 45 秒稳定，无中途清空或按钮禁用。测试不输入 Mac 密码。APK 的独立包名 com.tepy.tepy_mobile.debug 已在安装前核对；首次调试连接受下载代理影响，退出后令本机 VM Service 绕过代理，再次运行通过。

最终交付已完成：日常 Android 0.2.0 / versionCode 5 使用 adb install -r 覆盖安装并启动，未卸载或清除应用数据；实机截图确认新字体、主题及已保存设备入口正常。Release APK 签名校验通过，应用 AOT 库为 arm64。Windows 便携包在仅含系统目录的 PATH 下成功启动，并恢复已有安全存储档案，未自动连接或执行动作。

`flutter-windows.ps1 -Check -Package` 和 `mobile.ps1 -Package` 已实际运行。Windows 包含完整 Flutter bundle、native_assets.json、x64 CRT、源码、协议、许可和说明；字体随 APK / Windows assets 离线提供。两个发布目录的 SHA256SUMS 全部核对通过，Windows ZIP 完整性检查通过；排除 SDK、缓存、keystore、local.properties 与本地配置。
