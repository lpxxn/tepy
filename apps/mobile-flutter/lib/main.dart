import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/tepy_app.dart';

void main() {
  // 先初始化平台通道，再由 ProviderScope 提供整个应用的 Riverpod 状态容器。
  WidgetsFlutterBinding.ensureInitialized();
  // Maven 原生库不会自动出现在 Flutter 的 Pub 许可清单中，显式补入其原文。
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks([
      'usb-serial-for-android 3.11.0',
    ], await rootBundle.loadString('third_party/usb-serial-LICENSE.txt'));
  });
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks([
      'Tepy Sans (Noto Sans SC subset)',
    ], await rootBundle.loadString('assets/fonts/OFL.txt'));
  });
  runApp(const ProviderScope(child: TepyApp()));
}
