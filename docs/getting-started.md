# 环境、构建与首次使用

已有设备可使用 [Qt 桌面工具](desktop.md) 管理。HTTP 连接兼容现有 `/api/v1/`；USB 配置需要固件 0.2.0 及 ESP32-S3 的原生 USB 接口。Qt 和 monitor 不能同时占用同一串口。

## 构建

安装 ESP-IDF 6.1。日常开发和首次安装可以直接使用 **flash monitor**，不必先生成合并镜像。Windows 在项目根目录执行（COM7 替换为实际端口）：

```powershell
.\tools\dev\idf.ps1 -Port COM7 flash monitor
```

脚本优先使用已激活的 IDF，否则读取本机 `C:\Espressif\tools\Microsoft.v6.1.PowerShell_profile.ps1` 中的环境路径。其他位置先激活相应 IDF 环境。已激活环境后，也可以直接在固件目录运行原生命令：

```powershell
cd firmware
idf.py -p COM7 flash monitor
```

项目已预设 `esp32s3`，不用每次都运行 `set-target`。Linux / macOS 使用实际串口设备路径替换 COM7。

| 命令 | 作用 |
| --- | --- |
| `idf.py build` | 编译固件，不写入开发板 |
| `idf.py flash` | 必要时先编译，再把 bootloader、分区表和应用写入开发板 |
| `idf.py monitor` | 打开串口查看正在运行的固件，不烧录 |
| `idf.py flash monitor` | 烧录完成后立即打开串口监视器 |
| `idf.py merge-bin -o tepy-merged.bin` | 生成一个合并镜像文件，不写入开发板 |

只有需要分发一个完整烧录文件时，才额外打包：

```sh
idf.py build
idf.py merge-bin -o tepy-merged.bin
```

合并镜像位于 `firmware/build/tepy-merged.bin`，网页 OTA 使用 `firmware/build/tepy.bin`。两者都不是运行 `monitor` 的前置条件。

首次构建需要联网下载 MQTT、mDNS、cJSON managed components。生成的 `dependencies.lock` 纳入版本管理。Flash 使用 QIO、16 MB，PSRAM 使用 Octal。自有组件使用 `gnu++23`，检查 `build/compile_commands.json` 可确认。

## 首次烧录与配网

1. 连接开发板下载串口，确认端口；在项目根目录运行 `.\tools\dev\idf.ps1 -Port COM7 flash monitor`，或在 `firmware/` 目录运行 `idf.py -p COM7 flash monitor`。使用实际端口替换 COM7。
2. 首次创建配置时，从串口读取设备 ID、热点密码和管理口令，保存这些信息。普通重启或再次烧录保留 NVS 时，不会自动重复打印；若没有看到，按下文方法重新显示。
3. 手机或电脑连接 `Tepy-<设备后六位>`，打开 `http://192.168.4.1`，输入管理口令。
4. 填写 2.4 GHz Wi-Fi、Broker、NTP。默认公网 NTP 不可达时改为局域网 NTP。
5. 保存后点击重启；成功连网后热点关闭，通过串口显示的 IP 或 `http://tepy-<device_id>.local` 访问。
6. 在网页开启配对窗口，Mac 蓝牙设置中连接 `Tepy-<设备后六位>`，把 Mac 显示的六位码填到网页中。
7. 若 Mac 弹出“键盘设置助理”，按下文完成美式 ANSI 布局识别；使用 ABC 输入源并关闭 Caps Lock。必须先确认 HID 键盘记录和文本输入，再做锁屏测试，蓝牙连接成功不等于键盘识别成功。

手机浏览器不一定自动弹出配置页，直接打开上述地址即可；mDNS 不通时使用 IP。开发板仅连接下载电脑完成烧录，运行时可改独立电源。

## monitor 中没有看到设备凭据

保持 `idf.py -p COM7 monitor` 运行，等待启动完成，**在设备运行时长按 BOOT 三秒后松开**。当前默认 BOOT 对应 GPIO0；这个操作会开启配置热点并重新打印已保存的凭据，不清除配置。

输出格式如下（尖括号内容是占位说明，不是真实密码）：

```text
TEPY LOCAL SETUP
Device: <12位设备ID>
AP: Tepy-<设备ID后六位>
AP password: <热点密码>
Admin token: <网页管理口令>
http://192.168.4.1
```

手机连接 `AP` 显示的热点，使用 `AP password`；打开网页后输入 `Admin token`。这两个密码不同。设备 ID 来自 STA MAC 去掉冒号，不是日志中的 Bluetooth MAC。

不要在按 RESET 或插电时持续按住 BOOT，那会进入下载模式。`main_task: Returned from app_main()` 是正常日志：初始化完成后，后台任务继续运行。退出 monitor 使用 `Ctrl+]`。

## 配网并重启后

按“重新访问网页 → 检查网络状态 → 蓝牙配对 → 普通文字 → 睡眠唤醒 → 密码输入”的顺序验证。

### 1. 重新访问管理网页

电脑切回 ESP32 所连接的路由器 Wi-Fi，在 monitor 中找到这一行：

```text
network: IP 192.168.50.240
```

本次设备可以通过 [http://192.168.50.240](http://192.168.50.240) 访问，也可尝试 [http://tepy-24587cda3a18.local](http://tepy-24587cda3a18.local)。IP 是路由器通过 DHCP 分配的，后续可能改变，应以最新日志为准。其他设备替换为自己的 IP 和设备 ID。

重启后正常连网会关闭配置热点，此时通过路由器分配的地址管理设备。网页继续使用原来的 `Admin token` 登录。

### 2. 确认 Wi-Fi、校时和 MQTT

网页顶部“运行状态”应显示：

- Wi-Fi：已连接。
- 校时：完成。
- MQTT：已连接。

日志中的 `wifi:connected` 和 `network: IP ...` 可以确认 Wi-Fi 和 IP 已就绪；MQTT 与校时状态需要在网页中单独检查。

若一直“等待 NTP”，检查 NTP 服务器是否可达，必要时改用局域网 NTP，保存后重启。当前固件校时成功后才启动 MQTT 连接。校时完成而 MQTT 仍未连接时，检查 Broker 地址、端口、账号、密码和 TLS 配置；Broker ACL 需允许设备订阅 `tepy/<device_id>/cmd`，并发布 `/state` 和 `/reply`。

### 3. 与目标 Mac 蓝牙配对

1. 在管理网页点击“开启配对窗口”，窗口有效期为两分钟。
2. 在 Mac 的“系统设置 → 蓝牙”连接 `Tepy-<设备ID后六位>`。本次设备名称为 `Tepy-da3a18`。
3. 如果 Mac 显示六位配对码，将它填入管理网页的“Mac 显示的配对码”，点击“提交配对码”。这是蓝牙配对码，不是 Mac 登录密码。
4. 网页状态应显示蓝牙“已有绑定、已连接、可以发送”。若窗口已过期，重新开启窗口后再配对。

已有其他目标绑定时，需要先在网页清除绑定，并在原 Mac 上忽略旧设备，再进行新配对。

#### 配对码与“按 Shift 旁边的键”有什么区别

这两个提示属于不同环节，不要求每把蓝牙键盘都出现相同提示：

| 提示 | 用途 | Tepy 当前行为 |
| --- | --- | --- |
| 六位蓝牙配对码 | 确认配对双方，建立经过认证的加密连接 | 固件设置 `KeyboardOnly`、`sm_mitm = 1`，将 Mac 显示的六位码通过管理网页提交给 SMP 配对流程 |
| 按左右 Shift 旁边的键 | “键盘设置助理”判断 ANSI、ISO、JIS 物理布局 | 仅在 Mac 实际弹出该窗口时操作；没有窗口不能单独证明识别成功或失败 |

有些实体键盘无需输入配对码，也有些需要；取决于配对方式、已有绑定等条件。`KeyboardOnly` 是蓝牙安全协议的输入／输出能力声明，不是 HID 键盘设备类型声明。网页提交配对码调用的是 SMP 接口，不经过普通 HID 按键通道，因此配对码被接受也不能证明文字输入可用。

如果 Tepy 已使 Mac 弹出“键盘设置助理”，按窗口提示依次在控制端发送单键。当前固件按美式 ANSI 布局映射，左 Shift 右边是 `z`，右 Shift 左边是 `/`，不要同时发送 Shift：

```powershell
# Mac 提示按左 Shift 右边的键时发送；等下一条提示出现后再发送 /
python tools/mqtt/tepy_cli.py --host $broker --device $device key z
python tools/mqtt/tepy_cli.py --host $broker --device $device key /
```

随后如需手动选择键盘类型，选择 ANSI。这里 `$broker`、`$device` 的设置方法见下一节；若使用 TLS、认证或自定义端口，沿用相同连接参数。通过 MQTT 操作是让 Tepy 发送按键，按 Mac 内置键盘不能代替这项识别。

若 `hidutil list` 没有 Tepy 键盘记录，应继续采集 HID 枚举证据；手动打开助理或改变配对码设置本身不能证明问题已经修复。

参考：[Apple：在 Mac 上指定键盘类型](https://support.apple.com/zh-cn/guide/mac-help/mchlp2886/mac)、[Apple：设置妙控键盘、妙控鼠标或妙控板](https://support.apple.com/zh-cn/119917)。后者也说明了在系统要求时通过键盘输入配对码的流程。

### 4. 安装 MQTT 工具并查看状态

另开一个终端，保留 monitor 方便观察设备日志。以下 PowerShell 命令在项目根目录执行；如果当前位于 `firmware/`，先 `cd ..`。

```powershell
cd C:\Users\nick\go\src\lpxxn\tepy
python -m pip install -r tools/mqtt/requirements.txt

e21c305fe2615517c17b1fe5bc3454a人

$broker = "你配置的MQTT服务器地址"
$broker = "127.0.0.1"
$device = "24587cda3a18"
```

`$broker` 填写 Broker 的主机名或 IP；`$device` 使用自己设备的 12 位 ID。本次设备 ID 为 `24587cda3a18`，来自 STA MAC `24:58:7c:da:3a:18`。

Broker 启用认证时，先在同一个终端设置与 ESP32 配置相符的用户名和密码；未启用认证可跳过这段。密码通过隐藏提示读取：

```powershell
$env:TEPY_MQTT_USERNAME = Read-Host "MQTT 用户名"
$mqttPassword = Read-Host "MQTT 密码" -AsSecureString
$env:TEPY_MQTT_PASSWORD = [System.Net.NetworkCredential]::new("", $mqttPassword).Password
Remove-Variable mqttPassword
```

查询状态：

```powershell
python tools/mqtt/tepy_cli.py --host $broker --device $device status
```

该命令等待设备在线并完成校时后显示 JSON；配对完成后，`ble.ready` 应为 `true`。

以下示例默认使用普通 MQTT 的 1883 端口。TLS 连接在子命令前增加 `--tls`，自定义 CA 使用 `--ca "证书路径"`；非默认端口增加 `--port 端口号`。例如：

```powershell
python tools/mqtt/tepy_cli.py --host $broker --device $device --tls --port 8883 status
```

后续 `type`、`wake` 和 `unlock` 命令也要使用相同连接参数。TLS 默认端口为 8883，`--ca` 同时启用 TLS。更多参数见 [MQTT 工具说明](../tools/mqtt/README.md)。

### 5. 先验证普通文字输入

在 Mac 上打开文本编辑器，使用 ABC 美式输入源、关闭 Caps Lock，并点击可输入的文本区域，然后在控制端执行：

```powershell
python tools/mqtt/tepy_cli.py --host $broker --device $device type
```

工具提示输入内容时，输入 `Hello123!` 并按回车。终端不会显示这些字符；回车只是结束终端输入，默认不会向 Mac 发送回车。Mac 文本编辑器中应出现 `Hello123!`。

确认文字、大小写与符号正确后，再进入锁屏和睡眠测试。

### 6. 验证睡眠唤醒

让 Mac 睡眠后，在控制端执行：

```powershell
python tools/mqtt/tepy_cli.py --host $broker --device $device wake
```

观察 Mac 是否亮屏。`wake` 只发送一次 Shift 按下、释放，不输入密码。先验证短时睡眠，再按 [实机验收清单](testing.md) 验证过夜睡眠与重连。

### 7. 验证唤醒后输入密码

普通输入和唤醒均通过后，将 Mac 置于睡眠／锁屏状态，确认登录的是目标用户，再执行：

```powershell
python tools/mqtt/tepy_cli.py --host $broker --device $device unlock --wait 3 --enter
```

工具先隐藏读取 Mac 密码，再发送唤醒按键，等待三秒，输入密码并按回车。Mac 恢复较慢时，可调整 `--wait`（0–30 秒）。密码不作为命令行参数传递，也不写入 ESP32 配置。

返回 `status: sent` 表示 HID 报告已发送；Mac 是否真正唤醒、输入框是否就绪以及密码是否被接受，需要观察目标 Mac 确认。结果不确定时先人工检查，不自动重复密码。首版不覆盖重启后的首次登录、FileVault 解锁和中文输入。

### 常见问题

| 现象 | 检查方向 |
| --- | --- |
| 重启后原来的配置网页打不开 | 电脑切回路由器 Wi-Fi，使用 `network: IP ...` 显示的新地址 |
| 网页一直等待 NTP，MQTT 未连接 | 检查 NTP 可达性；必要时配置局域网 NTP 并重启 |
| `status` 等待设备在线并完成校时超时 | 先看网页的校时与 MQTT 状态，再检查客户端 Broker、认证、TLS 和主题 ACL |
| 提示“蓝牙键盘尚未就绪”或 `ble_not_ready` | 检查目标 Mac 配对、连接及网页“可以发送”状态 |
| 返回 `old_session` | MQTT 发生了重连；先重新查询状态，再人工确认是否需要发起新的动作 |
| 返回 `expired` | 检查发布端与 ESP32 校时，确认请求未因网络延迟过期 |
| 返回 `sent`，Mac 上没有预期文字 | 检查输入焦点、ABC 布局、Caps Lock 和屏幕状态 |

## 蓝牙已连接但 macOS 没有识别键盘

如果 `status` 显示 `connected / ready / bonded` 都为 `true`，输入也返回 `sent`，但文本编辑器没有文字，先在 Mac 终端执行：

```sh
hidutil list
```

确认是否存在 Tepy 的 `UsagePage=1`、`Usage=6` 键盘记录。设备可能使用通用名称，可同时按厂商／产品 ID 查找：

```sh
hidutil list | grep -Ei 'Tepy|303a|12346|4001|16385'
```

只有 NimBLE `notify` 和 `att_handle=...` 日志，表示已向 BLE 栈提交通知，不能证明 macOS 已注册 HID 键盘。

### 0.1.2 的历史修正与 HID 诊断字段

0.1.0 缺少 PnP ID；0.1.1 补齐后，用户的 Mac 仍未创建 HID 键盘记录。继续检查发现 SDK HID 封装会给 Report Map 添加指向电池服务 UUID（0x180F）的 External Report Reference，但该字段应引用外部特征，而且本项目的 Report Map 不包含外部电池报告。

0.1.2 改为在项目内显式注册 HID / DIS 服务，移除这项无效外部引用，直接提供固定长度的输入／输出报告、Report Reference 和二进制 PnP ID。BLE 主机、控制器和配对仍使用 ESP-IDF NimBLE；无需修改本机 SDK。启动自检会读取实际注册的各项数据，新增诊断会记录主机读到了哪些特征。2026-10-29 用户复测仍无文字输入；该版本没有解决目标 Mac 的输入问题，不能将本地自检或发送成功作为修复完成的证明。

1. 下载／使用更新后的代码，先用 `Ctrl+]` 退出占用 COM7 的 monitor。在 `firmware/` 目录执行：

   ```powershell
   idf.py -p COM7 flash monitor
   ```

2. 当前代码启动日志应显示 `App version: 0.1.5`，以及 `ble: HID profile ready: PnP=... report=... boot=... protocol=... bytes=8 external=none security=encrypted`。已有 sdkconfig 可继续使用，无需删除配置文件。
3. 在 Mac 蓝牙设置中忽略旧的 Tepy 设备；在 ESP32 管理网页点击“清除绑定”，再开启配对窗口重新配对。此操作只清除蓝牙绑定，保留 Wi-Fi、MQTT 和管理口令。
4. 查询 MQTT `status`，当前版本应看到 `firmware: "0.1.5"`。以下诊断字段自 0.1.2 起提供：

   | 字段 | 含义 |
   | --- | --- |
   | `ble.pnp_id_present` | 设备端已发布 PnP ID，且本地读取验证通过；不代表 Mac 已识别 |
   | `ble.protocol_mode` | 主机选择的 `report` 或 `boot` 模式 |
   | `ble.report_subscribed` | 主机是否订阅 Report 输入通知 |
   | `ble.boot_subscribed` | 主机是否订阅 Boot 键盘输入通知 |
   | `ble.host_reads` | 当前连接中主机实际读取过的特征／描述符名称，不包含启动自检 |
   | `ble.tx_completed` | 当前连接中 BLE 栈报告发送成功的输入通知数，不是 macOS 输入确认 |
   | `ble.tx_errors` | 当前连接中通知提交／完成报告的错误事件数 |

5. 配对过程中观察串口：主机首次读取某项数据时会打印 `HID peer read <名称> handle=... length=...`。关注 `report_map`、`information`、`input_reference`、`output_reference`、`pnp` 等名称。重连时主机可能使用缓存，不要求每次重连都读取全部元数据。
6. 通常 macOS 使用 `report` 模式，对应 `report_subscribed` 应为 `true`。再运行 `hidutil list`，确认键盘记录是否出现，然后在 TextEdit 空白文档中放好光标，发送单键测试：

   ```powershell
   python tools/mqtt/tepy_cli.py --host $broker --device $device key a
   ```

7. 输入后等待六秒，再查询 `status`；状态每五秒发布一次，避免刚发完按键就读到旧的 retained 状态。一次 `key a` 正常会提交按下、释放两条输入通知；`tx_completed` 的增长只证明 BLE 栈报告了发送结果。

如果仍没有键盘记录或文字，保留升级后的 `status`、从重新配对开始的 `HID peer read`、`HID profile ready`、`HID subscription`、`HID protocol mode` 日志供进一步定位。新增诊断不记录输入字符或密码。`host_reads` 是实际主机读取证据，主机侧是否注册键盘仍以 `hidutil list` 和实际输入为准。

### 0.1.2 实测后的下一步

本次日志确认主机读取了 HID Information、65 字节 Report Map、输入／输出 Report Reference、PnP 及设备信息，随后订阅 Report 输入通知。状态中 `tx_completed = 4`、`tx_errors = 0`，但用户仍未看到文字，Mac 也没有弹出键盘设置助理。当前证据证明 BLE 元数据读取和设备端发送流程已发生，尚未定位 macOS 拒绝／忽略输入的具体原因。

先在 Mac 检查本次 0.1.2 连接后的键盘记录，不能把升级前的 `hidutil` 结果当成本次结果：

```sh
hidutil list | grep -Ei 'Tepy|303a|12346|4001|16385'
```

若匹配到设备，需确认该设备的 `UsagePage = 1`、`Usage = 6`；仅匹配到其他 HID 用途还不算键盘已注册。记录存在时再检查键盘设置助理、输入焦点和按键处理；没有记录时继续检查主机 HID 注册过程。

需要采集主机日志时，应在复现后及时保留完整时间窗口，不再只取 `bluetoothd` 的最后 100 行。相关诊断可能来自 `hidd`、`bluetoothuserd` 或 HID 子系统。在 Mac 终端执行以下只读采集命令（只在桌面新建结果文件，不修改蓝牙设置）：

```sh
hidutil list > "$HOME/Desktop/tepy-hid-list.txt"
log show --last 10m --info --debug --style compact \
  --predicate 'process == "bluetoothd" OR process == "BTLEServer" OR process == "bluetoothuserd" OR process == "hidd" OR subsystem CONTAINS[c] "HID"' \
  > "$HOME/Desktop/tepy-hid-log.txt"
```

日志可能含其他外设信息，分享前自行检查。若配对发生在十分钟前，该命令不能追溯到配对过程，应调整时间窗口后再采集。日志中其他设备的错误或系统广播的 `error (null)` 不能直接作为 Tepy 故障的原因。

### 0.1.3：修正配对与 HID 初始化的加密时序

2026-10-29 通过 SSH 直接检查目标 Mac（macOS 27.0.1）后确认：蓝牙信息已将 Tepy 归类为 Keyboard / HID BLE，实际 HID 列表却没有 Tepy。负责 BLE HID 的 **BTLEServer** 日志记录了明确原因：

```text
21:42:58.411 Detected keyboard LE HID
21:43:00.930 Not creating HID device as the link is not encrypted
21:43:23.008 peerDidCompletePairing
21:43:27.016 Service "<private>" has timed out on peripheral "<private>"
```

主机在链路加密前就读取完 HID 元数据并订阅通知，提前尝试创建键盘失败；后来配对成功，不能使已经失败的这次初始化自动变成成功。此前只采集 `bluetoothd` 的日志遗漏了 BTLEServer 的直接错误。六位配对码本身不是无效 HID 描述符的证据。

0.1.3 为 HID Information、Report Map、Report Reference、协议／报告访问及 CCCD 写入增加加密要求。普通输入报告的 `READ_ENC` 与 CCCD 订阅权限独立，后者使用 NimBLE 的 `BLE_GATT_CHR_F_NOTIFY_INDICATE_ENC` 设置。启动日志增加 `security=encrypted`，加密完成时输出 `HID link security ...`，便于对照主机读取顺序；不输出配对码、字符或密码。

在固件目录执行 `idf.py -p COM7 flash monitor` 升级，或在项目根目录执行 `.\tools\dev\idf.ps1 -Port COM7 flash monitor`。先保留已有绑定验证重连，核对版本为 0.1.3，并在 Mac 上确认 `hidutil list` 出现 Tepy 的键盘记录。若需验证首次配对，再在双方清除 Tepy 的绑定后重新配对，管理网页提前打开以便及时提交配对码。

本次已烧录 0.1.3，并通过 SSH 确认目标 Mac 的 `hidutil` 出现 Tepy 的 `UsagePage=1 / Usage=6` 键盘设备及 AppleUserHIDEventDriver；用户确认键盘设置助理已弹出。此时按提示通过 MQTT 依次发送 `key z`、`key /`，随后选 ANSI，操作见 [配对与布局识别](#配对码与按-shift-旁边的键有什么区别)。完成后继续普通文字测试，再进行睡眠测试。

2026-10-29，用户随后确认普通文字、睡眠唤醒和 `unlock --wait 3 --enter` 解锁三个步骤均正常，基本使用流程已实测通过。长期使用前可继续验证过夜睡眠、ESP32 断电重启及网络重连，结果分别记录在 [实机验收清单](testing.md#目标-mac-验收)。

### 0.1.4：断电后已连接但输入尚未就绪

0.1.3 在后续断电复测中出现已绑定、已连接，但 `ready=false`、通知未订阅。Mac 日志显示约每 30 秒重连，ESP32 则在实际已加密并认证时报告 SMP 超时。0.1.4 调整已绑定连接的安全请求时机，并按当前连接的真实加密、认证和绑定状态处理该超时；仍要求实际通知订阅，未降低输入的安全条件。

0.1.4 的三次 USB 硬件复位验证通过，但用户真实拔电复测仍出现已加密、未订阅，因此继续修正到 0.1.5：NimBLE 的安全／订阅恢复可能早于 CONNECT，后到的 CONNECT 不得再次清空这些状态。当前已烧录 0.1.5，Wi-Fi、MQTT、管理口令及蓝牙绑定保留；串口已直接确认早到的恢复状态在 CONNECT 后保留。用户再次真实拔电后，已确认 `ready / encrypted / authenticated / report_subscribed` 均为 true，普通文字输入正常，无需重新配对。

断电恢复检查步骤：

1. 保留现有绑定，拔掉 ESP32 电源后重新插入，等待约 10 秒。
2. 查询 `status`，核对固件为 0.1.5，`connected / encrypted / authenticated / ready` 为 true，当前 `report` 模式的 `report_subscribed` 为 true。
3. `host_reads` 可能只有设备信息；已绑定主机可以使用缓存，并由 NimBLE 恢复通知订阅，不要求每次重新读取整个 Report Map。
4. 在 Mac 文本编辑器中执行 `type` 测试普通文字，通过后再测唤醒和解锁。

`security_status` 是最近一次 ENC_CHANGE 返回码，`-1` 仅表示本次连接尚未收到该事件；延迟检查也会核实实际链路安全状态。判断能否发送以 `ready` 及加密／认证／订阅字段为准。若仍失败，保留状态和从启动开始的 `HID link security`、`HID subscription`、`HID disconnected` 日志，不反复尝试登录密码。
