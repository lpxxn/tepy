# Tepy Mobile 0.1.3

Flutter / Dart / Riverpod 编写的 Android 控制台。通过 MQTT 查看 Mac、ESP32 与 BLE 状态，发送唤醒、文字、组合键或单次解锁；通过 USB OTG 配置 ESP32。复用根目录 `protocol/v1`，不依赖 Qt、Go 或 ESP-IDF 构建系统。

- [安装、连接与 USB 使用](../../docs/mobile-flutter.md)
- [Flutter / Dart 学习导读](../../docs/flutter-learning.md)
- [协议](../../docs/protocol.md) · [测试记录](../../docs/testing.md)

## 构建

本轮环境：Flutter 3.47.9 / Dart 3.13.7，JDK 17，Android SDK 36 / NDK 28.2.13676358 / CMake 3.22.1；Android 最低 API 24。直接依赖固定版本，提交 `pubspec.lock`。USB 原生驱动固定为 usb-serial-for-android 3.11.0。

```powershell
cd apps/mobile-flutter
flutter pub get
flutter analyze
flutter test
flutter build apk --release --target-platform android-arm64
```

开发构建需要 Android SDK、Google Maven、Maven Central、JitPack 与 Flutter/Pub 下载源。Gradle Wrapper 使用官方 9.3.1 bin 分发包并校验 SHA-256。网络代理可由当前终端配置；不在仓库保存全局代理或开发机路径。

`release` 当前使用本机开发签名，供本地学习与实测。正式分发前设置自己的 keystore，并将签名文件和密码留在版本库外。当前 APK 不打包服务密码、私钥或 Mac 登录内容。

## 代码入口

```text
lib/
  main.dart                         ProviderScope 与应用启动
  app/tepy_app.dart                  主题、导航、前后台生命周期
  domain/                           配置、状态、命令、串口分帧及校验
  data/                             MQTT、系统安全存储、USB 平台通道
  application/                      Riverpod 状态与异步流程控制
  presentation/screens/             状态 / 操作 / USB 设备 / 连接四页
  presentation/widgets/             通用卡片、提示与详情行
android/app/src/main/kotlin/.../     MainActivity、USB Host 原生桥接
test/                               领域、异步流程、串口、界面测试
integration_test/                   显式运行的手机原生集成测试
```

前台连接由用户发起，进入后台关闭连接并取消后续操作。连接信息可安全记忆；Mac 登录输入只用于当次操作，不保存、不回显、不记日志。`sent` 表示 HID 发送完成，Mac 的解锁结果单独展示。

USB 仅支持 ESP32-S3 原生 USB Serial/JTAG（VID 0x303A），需要固件 0.2.0+、OTG 数据连接和现有管理口令。暂不在手机端提供 OTA、ROM 刷机、普通串口终端或 USB 键盘动作。

0.1.1 修复 MQTT 已连接后仍每秒重连的竞态，避免状态卡反复变为未知、按钮禁用和解锁等待中断。Debug / 集成测试使用独立包名 `com.tepy.tepy_mobile.debug`；日常 Release 包名不变，升级保留连接档案。

0.1.2 为 TLS 展开区域和各输入框分配独立 PageStorageKey，修复展开时读取错误滚动状态产生的灰框；展开、收起和私钥编辑不覆盖草稿。

0.1.3 将 TLS 点击高亮裁剪为圆角，并在状态页的 Mac 状态卡下方增加已保存连接入口。快捷连接只使用已保存档案，连接中禁止重复点击；“仅本次连接”不会替换这个入口使用的档案。

第三方组件与许可见 [THIRD_PARTY.md](THIRD_PARTY.md)。
