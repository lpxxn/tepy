# Tepy Flutter Windows

0.2.0 开始，`apps/mobile-flutter` 同一份 Dart / Riverpod 代码支持 Android 与 Windows x64。目录名保留以兼容已有工具。Windows 版本包括 Mac / ESP32 状态、唤醒、文字、组合键、单次解锁，以及原生 USB COM 串口管理。

## 运行与连接

将 `tepy-flutter-0.4.0-windows-x64.zip` 解压到独立目录，再运行 `tepy.exe`。保留旁边的 DLL 和 `data/`，不要单独移动 exe。无需安装 Flutter、Qt、Go 或 ESP-IDF；便携包附带应用所需的 x64 CRT。当前为本地开发版本，尚未进行发行签名。

在“连接”页填写 Broker、ESP32 ID 和 Mac 代理 ID。Broker 就在这台 Windows 电脑上时使用 `mqtt://127.0.0.1:1883`；连接其他电脑或服务器则填其可达地址。手机和 ESP32 仍使用局域网 / 远程地址，不能把自己的 localhost 当作 Windows 的地址。

“保存并连接”安全记忆连接信息，下次在状态页点击“连接设备”即可。Qt、Windows Flutter、Android 的档案各自独立。0.3.0 可在操作页将 Mac 登录密码单独保存为明文 JSON，完整实际路径在页面显示。普通临时输入不保存。TLS / mTLS 与手机规则一致，见 [手机控制台](mobile-flutter.md)。

窗口宽度达到 1000 时使用侧栏和桌面分栏，窄窗口使用底栏。字体随应用离线打包，无需网络下载。最小窗口为 640 × 560；键盘 Tab 可在输入框和按钮之间移动。最小化进入隐藏状态时取消后续任务并关闭 MQTT / USB；恢复后手动连接，避免继续旧的输入。

## COM 串口管理

1. ESP32 使用 0.2.0+ 固件，以数据线接到电脑，选板上的 **ESP32 原生 USB** 插口。
2. 退出占用该 COM 端口的 `idf.py monitor`、Qt 或其他串口程序。
3. 在“设备”页刷新，选择检测到的 ESP32 COM 端口。当前仅枚举 Espressif VID `0x303A`，不支持外置 CH340 / CP210x UART。
4. 填写现有 ESP32 管理口令，点“连接并读取”。默认串口参数为 115200 / 8N1。
5. 编辑配置、保存并回读，再手动重启；重启或拔线后重新刷新连接。

管理口令可安全记忆；脱敏配置不会返回旧 Wi-Fi / MQTT 密码。Windows 原生桥只传字节，逐请求鉴权、密码保留 / 替换 / 清除、超时不重发等规则复用 Dart 实现。支持配对窗口、配对码与显式清除绑定。0.3.0 在“固件”页提供网络 OTA；ROM 刷机仍使用现有 Qt 或 IDF 工具。

## 构建与打包

开发机需要 Flutter 3.47.9 / Dart 3.13.7、Visual Studio 2022 的“使用 C++ 的桌面开发”、Windows SDK 和 **C++ ATL for latest v143 build tools (x86 & x64)**。安全存储 Windows 插件依赖 ATL；`flutter doctor` 通过也可能需要单独补选它。

```powershell
flutter doctor -v
cd apps/mobile-flutter
flutter pub get
flutter run -d windows
flutter build windows --release --target lib/main.dart
```

可从仓库根目录运行：

```powershell
./tools/dev/flutter-windows.ps1 -Flutter C:/path/to/flutter/bin/flutter.bat -Check -Package
```

脚本执行格式 / 静态检查、Dart 测试、Release 构建，复制完整 bundle、匹配的本地 x64 CRT、文档 / 协议 / 源码并生成 Hash 和 ZIP。构建前关闭同目录运行的旧程序，避免 exe / DLL 被占用。代理可通过 `-Proxy http://host:port` 仅作用于当前进程。

Windows Release 输出为 `build/windows/x64/runner/Release/tepy.exe`，发布目录为 `dist/flutter-windows/0.4.0/`。Android 构建仍使用 `tools/dev/mobile.ps1`，两者独立。

Android / Windows 共用 `pubspec.yaml` 的版本。发布脚本只取 `+` 前的版本生成目录和 ZIP 名称；只增加构建号仍写入同一目录。完整的版本维护、覆盖行为和各项目发布路径见 [构建、发布目录与版本号](releases.md)。

原生集成测试（测试自身不读取或覆盖保存的连接档案）：

```powershell
cd apps/mobile-flutter
flutter test -d windows integration_test/windows_smoke_test.dart
# 选测真实 ESP32 原生 USB、以及本机 Broker（只读）：
flutter test -d windows integration_test/windows_smoke_test.dart --dart-define=TEPY_USB_CHECK=true --dart-define=TEPY_BROKER_CHECK=true
```

USB 检查发送无效测试口令，只期望 `unauthorized` 回执，验证串口收发及重新打开，不改变配置。MQTT 检查只订阅并观察设备状态。真实 Mac 密码输入、远程证书和完整故障场景仍按 [验收文档](testing.md) 人工确认。

构建参考：[Flutter Windows](https://docs.flutter.dev/platform-integration/windows/building)、[环境设置](https://docs.flutter.dev/platform-integration/windows/setup)。

## 0.3.0 Mac、密码与 OTA

新增“Mac”页接入 Agent 0.2.0 的状态、诊断和最近事件；操作页支持本机明文 JSON 保存登录密码；固件页支持系统文件选择器与网络 OTA。使用步骤及文件格式见 [管理功能](flutter-management.md)。Android / Windows 数据各自独立，不在发布目录保存用户密码。

## 0.4.0 USB 升级

在设备页使用 COM 连接后，固件页选择 USB 升级即可离线写入 tepy.bin。复用管理口令，保留 NVS / 蓝牙绑定；首次需固件 0.3.0+。重启后刷新并重新连接端口，由应用核对启动会话和实际版本。参见 [完整步骤](flutter-usb-ota.md)。
