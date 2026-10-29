# 测试与验证记录

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

## 目标 Mac 验收（待执行）

| 场景 | 预期 |
| --- | --- |
| 首次配对 / 错误配对码 | 正确码绑定；错误码不绑定 |
| 全部 ASCII 32–126、连续重复字符 | ABC 美式布局逐字一致，特别检查 +、=、引号、反斜线 |
| 组合键 | Command、Option、Control、Shift 正确 |
| 锁屏、短时睡眠、过夜睡眠 | wake 后界面可用，等待后仅输入一次 |
| ESP32 重启 / Mac 蓝牙开关 | 绑定保留，可恢复连接 |
| 输入中 BLE 或 MQTT 断开 | 中止，不在重连后继续输入 |
| Broker / 路由器重启 | 自动恢复，session 改变，旧命令不执行 |
| retained / 重复 / 过期 / 非法消息 | 拒绝，不产生按键 |
| 错误 Wi-Fi / NTP 不可达 | 可恢复热点；未校时拒绝动作 |
| OTA 正常 / 中断 / 错误镜像 | 正常更新，错误不切换，启动失败回滚 |

先在文本编辑器测试，锁屏使用临时测试内容。只在人工确认输入焦点后验证密码。不要自动重复密码尝试。`sent` 不证明解锁成功。

## 本次验证记录

2026-10-28，本机 Windows 验证：

- ESP-IDF 6.1 / Xtensa GCC 15.2.0：固件编译、链接、镜像大小检查及合并镜像生成通过。自有组件编译命令最终使用 `-std=gnu++23`，异常与 RTTI 关闭。
- 本机 MinGW GCC 13.1.0：341 项 C++ 核心检查通过。
- 5 份 JSON Schema、7 个样例、3 组 CLI → 固件解析器交叉向量通过。
- 10 个 Python 客户端测试通过，其中 2 个使用本机临时 MQTT 套接字夹具和真实 Paho 客户端。
- 内置网页 JavaScript 语法检查通过；真实浏览器与设备 API 的交互待验。
- 锁定依赖：cJSON 1.7.19~2、mDNS 1.14.1、MQTT 1.1.0，详见 `firmware/dependencies.lock`。

未执行开发板刷写、实际 Wi-Fi / BLE 射频共存、目标 Mac 配对与睡眠唤醒、真实 Broker TLS 和 OTA 断电回滚。这些结果必须在硬件上补验，不能以主机测试替代。OTA 校验采用 IDF 镜像校验，不提供发布者签名验证。

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

键盘设置助理使用 MQTT 单键 `z`、`/` 完成 ANSI 布局识别，具体操作见 [配对与布局识别](getting-started.md#配对码与按-shift-旁边的键有什么区别)。实际文字、完整 ASCII、组合键、锁屏与睡眠唤醒仍需分别验收，不能由 HID 注册成功推定通过。
