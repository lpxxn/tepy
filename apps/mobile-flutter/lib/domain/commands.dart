import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'connection_profile.dart';

/// 随机请求 ID 用于去重，和登录密码没有关系。Random.secure() 使用系统随机源。
String requestId() {
  final random = Random.secure();
  return List.generate(
    16,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

void validateText(Uint8List bytes) {
  if (bytes.isEmpty ||
      bytes.length > 512 ||
      bytes.any((c) => c < 32 || c > 126)) {
    throw const AppFailure('只支持 1–512 个可打印 ASCII 字符，请在 Mac 使用美式 ABC 布局。');
  }
}

const namedKeys = [
  'ENTER',
  'TAB',
  'ESC',
  'BACKSPACE',
  'DELETE',
  'SPACE',
  'LEFT',
  'RIGHT',
  'UP',
  'DOWN',
  'HOME',
  'END',
  'PAGEUP',
  'PAGEDOWN',
  'CAPSLOCK',
  'F1',
  'F2',
  'F3',
  'F4',
  'F5',
  'F6',
  'F7',
  'F8',
  'F9',
  'F10',
  'F11',
  'F12',
];
const modifierNames = ['CTRL', 'SHIFT', 'ALT', 'GUI'];

void validateKey(String key, List<String> modifiers) {
  final singleAscii =
      key.length == 1 && key.codeUnitAt(0) >= 32 && key.codeUnitAt(0) <= 126;
  if ((!singleAscii && !namedKeys.contains(key)) ||
      modifiers.any((m) => !modifierNames.contains(m)) ||
      modifiers.toSet().length != modifiers.length) {
    throw const AppFailure('按键或修饰键无效。');
  }
}

/// 编码只在发送时进行。调用者负责使用后清理 bytes；不能把返回值写到日志。
Uint8List encodeCommand({
  required String id,
  required String session,
  required int nowMs,
  required String type,
  required Map<String, Object> payload,
}) => Uint8List.fromList(
  utf8.encode(
    jsonEncode({
      'v': 1,
      'id': id,
      'session': session,
      'expires_at': nowMs + 10000,
      'type': type,
      'payload': payload,
    }),
  ),
);

/// Uint8List 是可变字节数组，可以覆盖我们拥有的缓冲。
/// Dart String 不可变、框架可能持有临时副本，因此不能声称整个进程的所有副本都已擦除。
void wipe(Uint8List? bytes) => bytes?.fillRange(0, bytes.length, 0);
