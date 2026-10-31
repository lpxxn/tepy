# Android 手机控制台

Tepy Flutter 0.2.0 位于 `apps/mobile-flutter`。当前提供 arm64 APK，适用于 Android 7.0（API 24）以上；本轮目标手机为 OPPO Find X9 / PLJ110 / Android 17。日常应用 ID 为 `com.tepy.tepy_mobile`，与 Qt、Go、ESP32 的配置独立。

0.1.1 修复 MQTT 连接成功与异步事件的时序竞态。旧版可能在已经连接后继续每秒重连，导致状态在在线／未知之间切换、按钮禁用，以及唤醒后的输入步骤被取消。升级保留已保存连接。Debug / 真机集成测试使用独立的 `com.tepy.tepy_mobile.debug`（“Tepy 测试”），测试清理不影响日常应用。

0.1.2 修复“TLS 证书”展开时的灰框，支持重复展开／收起、私钥编辑，以及已连接时查看证书区域；去掉默认上下分隔黑线，保留卡片圆角边框。

0.1.3 修复 TLS 按下时的矩形灰色高亮，折叠和展开状态都按圆角裁剪。状态页的 Mac 状态卡下方新增“已保存的设备”卡片，可直接点击“连接设备”，旁边保留“连接设置”。连接中显示进度并禁用重复连接，连接成功后收起这个入口。

0.2.0 统一为现代靛蓝主题与内置中文字体，手机使用底部导航，Windows 使用侧边导航和分栏布局；连接记忆、TLS 圆角与状态稳定修复继续保留。同一份 Flutter 代码现可在 Windows x64 运行，详见 [Windows 使用与构建](flutter-windows.md)。Windows 同机 Broker 默认地址为 `mqtt://127.0.0.1:1883`，Android 保持局域网地址。两种系统的连接档案各自保存，不自动同步。

## 安装与连接

开发 APK 使用本机开发签名。通过 USB 调试安装时：

```powershell
adb devices
adb -s <手机序列号> install -r dist/mobile-flutter/0.2.0/tepy-mobile-0.2.0-arm64.apk
```

也可将 APK 复制到手机后按系统安装界面操作。版本升级使用相同签名；不要为了处理安装错误直接卸载已有应用，以免丢失连接信息。

打开“连接”页，填写：

| 字段 | 当前示例 |
| --- | --- |
| Broker | `mqtt://192.168.50.99:1883` |
| ESP32 ID | `24587cda3a18` |
| Mac Agent ID | `mac-51958cda3625` |
| 用户名 / 密码 | 按 Broker 实际认证配置填写 |

手机和 Broker 需要网络互通。手机的 `127.0.0.1` 指手机自身，不能照搬 Windows Qt 连接同机 Broker 时使用的 localhost。手机不需要连接 Mac 的 SSH 或 HTTP 地址；Mac IP 改变后继续通过固定的 Agent ID 查看 MQTT 状态。

“保存并连接”将连接档案交给 Android 系统安全存储；“仅连接”不更新已保存档案。再次启动会恢复输入框，不自动建立连接或执行动作。“清除已保存连接”只删除本应用连接档案。设备 USB 管理口令在“设备”页独立管理。Mac 登录输入不会保存。

已有保存档案时，可在状态页直接“连接设备”；从后台返回或手动断开后也可使用。这个按钮使用最后一次成功保存的档案，不会误用“仅本次连接”的临时配置。没有保存档案或已清除档案时，先到“连接”页设置并保存。

远程 Broker 使用 `mqtts://主机名:8883`。TLS 验证服务器证书及主机名；系统信任链足够时 CA 留空，自签 CA 时填写 PEM。mTLS 同时填写客户端证书与私钥；不允许跳过证书验证。证书项只用于手机到 Broker 的连接，ESP32 的 Broker/CA 配置在 USB 页面另设。

## 状态与键盘操作

“状态”页分别显示 Mac 锁定、电源、目标 HID、ESP32、BLE 和 MQTT。状态过期、断线或字段不可确认时显示未知，不能以旧的 retained 状态推断 Mac 当前已解锁。

“操作”页支持：

- **唤醒**：发送 Shift 按下与释放。
- **文字**：美式 ABC 布局可打印 ASCII，1–512 字符；回车默认关闭。
- **组合键**：选择按键与 Ctrl / Shift / Alt / GUI 修饰键。
- **单次解锁**：先完整检查输入，再唤醒、默认等待三秒，等待新的 Mac 锁定且目标 HID 已注册状态，发送一次文本，最后观察新的解锁状态。

解锁需要 Go Agent 在线。Mac 已显示未锁定时跳过输入；状态未知或 HID 未就绪时不发送密码。HID `sent` 和 Mac 状态结果独立展示。观察超时只表示未确认，不自动重试密码。

同一时间只执行一个动作。请求使用当前 ESP32 session、十秒有效期、QoS 1、retain=false；连接恢复不会重放旧动作。取消只能停止后续步骤，不能撤回已经交给 ESP32 的按键。应用进入后台或手机锁屏时关闭连接、清理输入、取消流程；回到前台需手动连接。

## 手机 USB 配置 ESP32

接线：**手机 USB-C → OTG 转接头 / 支持数据的 USB-C 线 → ESP32-S3 原生 USB 口**。OTG 让手机作为 USB 主机，手机给开发板供电并访问串口。若板上有两个 USB 插口，选 ESP32 原生 USB / USB Serial/JTAG，当前不支持只接外置 CH340 / CP210x 的 UART 口。无需电脑参与，也无需先给 ESP32 配 Wi-Fi。手机接 ESP32 时通常不能同时用同一个接口接电脑 ADB。

1. 确认 ESP32 固件为 **0.2.0+**，已启用原生 USB 串口管理。
2. 打开“设备”，点“刷新 USB 设备”，选择 ESP32。Android 显示端口 ID，不叫 Windows COM7；重新插拔后应刷新。
3. 填写 ESP32 的**管理口令**，不是热点密码、MQTT 密码或 Mac 登录密码。口令来自首次串口输出；已有 Qt / 网页使用的管理口令相同。
4. 点连接，在 Android 的 USB 授权提示中允许。应用鉴权后读取状态与脱敏配置，不自动更改设置。
5. 编辑 SSID、Broker、用户名、CA、NTP 或按键间隔。Wi-Fi / MQTT 密码分别选择“保留原值”“设置新密码”或“清除密码”；脱敏读取不会拿到原密码。
6. 点保存，成功后自动回读配置；再手动点击“重启设备”。重启后刷新、重新连接，读取状态确认 Wi-Fi / MQTT / BLE。

支持开启蓝牙配对窗口、提交六位配对码及显式清除绑定。清除绑定前需确认；普通连接、读取或保存不会清除已有 Mac 配对。

原生接口为 115200 / 8N1，复用 `@tepy:` JSON 协议，每条请求携带管理口令，15 秒回执超时不重发。拔线或重启时若没有收到保存回执，先重新读取配置，再决定下一步。普通启动日志在 Dart 分帧层丢弃，不显示恢复口令。

USB 口令可以安全记忆；本次新 Wi-Fi / MQTT 密码与配对码发送后清理，不存入手机连接档案。进入后台关闭串口。首版暂不提供手机 OTA、ROM 刷机、通用串口终端；USB 管理不会直接输入键盘字符，键盘动作仍走 MQTT。

## 开发与验收

参见 [应用 README](../apps/mobile-flutter/README.md)、[学习导读](flutter-learning.md) 与 [测试记录](testing.md)。日常检查可运行：

```powershell
./tools/dev/mobile.ps1 -Check
./tools/dev/mobile.ps1 -Build
```

若终端使用下载代理，真机 drive 连接前设置 `NO_PROXY=localhost,127.0.0.1,::1`，避免本机 Dart 调试服务走代理。

集成测试需要显式指定设备；先构建独立测试 APK，再让 drive 从 APK 读取包名，避免首次切换包名时复用旧应用身份：

```powershell
cd apps/mobile-flutter
flutter build apk --debug --target integration_test/phone_smoke_test.dart --target-platform android-arm64 --dart-define=TEPY_DEVICE_CHECK=true --dart-define=TEPY_BROKER=mqtt://192.168.50.99:1883
flutter drive -d <手机序列号> --driver test_driver/integration_test.dart --target integration_test/phone_smoke_test.dart --use-application-binary=build/app/outputs/flutter-apk/app-debug.apk
```

移除构建命令里的 DEVICE_CHECK 可仅检查原生界面、存储和 USB 枚举；改成 BROKER_CHECK 则只要求 Mac Agent。启用真实 Broker 检查时会持续观察 45 秒，需保持 Mac 唤醒、ESP32 在线及手机解锁，期间不要操作测试界面。测试不发送按键。不要直接使用旧 APK 缓存运行 `flutter test -d` 切换包名；上面的预构建 drive 流程使用 APK 的实际身份。

集成测试构建的是测试入口，日常安装使用 `lib/main.dart`。Debug / Release 切换时让 Flutter 重新生成插件注册文件，不加 `--no-pub`。Find X9 的原生安全存储、四页导航、USB 枚举及真实 Broker / Mac 状态只读订阅已通过；0.1.1 的手机真实解锁和状态稳定已由用户确认。手机至 ESP32 的实际 OTG 读写、完整 ASCII／组合键及远程 TLS/mTLS Broker 仍需专项实机验收。
