import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tepy_mobile/data/mac_password_store.dart';
import 'package:tepy_mobile/domain/connection_profile.dart';

/// 验证 path_provider 和原生文件替换，始终使用自己创建的随机测试目录。
/// 不打开真实 mac-passwords.json，也不发布任何键盘动作。
Future<void> checkNativePasswordStorage() async {
  final support = await getApplicationSupportDirectory();
  await support.create(recursive: true);
  final temporary = await support.createTemp('storage-smoke-');
  final file = File('${temporary.path}/test-passwords.json');
  final store = JsonMacPasswordStore(file: () async => file);
  const profile = ConnectionProfile(
    broker: 'mqtt://example.invalid:1883',
    agentId: 'mac-test',
    deviceId: 'aabbccddeeff',
  );
  try {
    for (final value in ['ExampleFirst!', 'ExampleReplacement!']) {
      await store.save(
        profile,
        Uint8List.fromList(value.codeUnits),
        const MacPasswordInfo(),
      );
      final bytes = await store.read(profile);
      expect(bytes, value.codeUnits);
      bytes?.fillRange(0, bytes.length, 0);
    }
    await store.remove(profile);
    expect(await store.inspect(profile), isNull);
  } finally {
    // temporary 来自本次 createTemp，不使用用户提供的路径。
    await temporary.delete(recursive: true);
  }
}
