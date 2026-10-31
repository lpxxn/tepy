import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/connection_profile.dart';

enum AppPlatform { android, windows, other }

/// 只在平台边界判断系统。测试可覆盖 Provider，不必伪造操作系统。
final appPlatformProvider = Provider<AppPlatform>(
  (ref) => Platform.isWindows
      ? AppPlatform.windows
      : (Platform.isAndroid ? AppPlatform.android : AppPlatform.other),
);

final defaultProfileProvider = Provider<ConnectionProfile>(
  (ref) => ConnectionProfile(
    broker: ref.read(appPlatformProvider) == AppPlatform.windows
        ? 'mqtt://127.0.0.1:1883'
        : 'mqtt://192.168.50.99:1883',
  ),
);
