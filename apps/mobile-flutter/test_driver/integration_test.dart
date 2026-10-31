import 'package:integration_test/integration_test_driver.dart';

/// 用预先构建的测试 APK 启动：Flutter 直接从 APK 读取 .debug 包名，
/// 避免首次切换 applicationIdSuffix 时复用旧 APK 的日常应用身份。
/// drive 默认只停止测试应用，不卸载日常应用。
Future<void> main() => integrationDriver();
