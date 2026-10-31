import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../data/usb_transport.dart';
import 'commands.dart';
import 'connection_profile.dart';
import 'snapshots.dart';

/// USB 字节块不等于一条消息：可能半条、几条粘在一起，还可能夹着固件日志。
/// 只保留以 @tepy: 开头的行；普通日志在前缀不匹配时就丢弃，不展示恢复口令。
final class SerialFrameDecoder {
  SerialFrameDecoder(this.onFrame);
  final void Function(Map<String, dynamic>) onFrame;
  static const _prefix = [64, 116, 101, 112, 121, 58]; // ASCII "@tepy:"
  final _line = <int>[];
  bool _dropping = false;
  Timer? _timeout;
  void add(Uint8List bytes) {
    for (final byte in bytes) {
      if (byte == 10) {
        if (!_dropping && _line.length >= 6) {
          var end = _line.length;
          if (end > 6 && _line[end - 1] == 13) end--;
          if (end - 6 <= 20000) {
            try {
              final value = object(
                jsonDecode(utf8.decode(_line.sublist(6, end))),
              );
              if (value != null) onFrame(value);
            } catch (_) {
              /* 无效行不进入业务层，也不输出原文。 */
            }
          }
        }
        reset();
        continue;
      }
      if (_dropping) continue;
      if (_line.length < 6 && byte != _prefix[_line.length]) {
        _discard();
        continue;
      }
      _line.add(byte);
      if (_line.length > 20007) _discard();
    }
    _timeout?.cancel();
    if (_line.isNotEmpty) _timeout = Timer(const Duration(seconds: 5), reset);
  }

  void _discard() {
    _line.fillRange(0, _line.length, 0);
    _line.clear();
    _dropping = true;
  }

  void reset() {
    _timeout?.cancel();
    _line.fillRange(0, _line.length, 0);
    _line.clear();
    _dropping = false;
  }

  void dispose() => reset();
}

/// 串口请求每次带 token；物理插线不跳过鉴权。只允许一个有效请求，迟到旧 ID 忽略。
final class SerialManagement {
  SerialManagement(this.transport, {this.onClosed}) {
    _decoder = SerialFrameDecoder(_receive);
    _subscription = transport.events.listen((event) {
      switch (event) {
        case UsbBytes(:final bytes):
          _decoder.add(bytes);
          wipe(bytes);
        case UsbClosed():
          _fail(const AppFailure('USB 已拔出，结果可能未确认。'));
          _connected = false;
          _token = '';
          _decoder.reset();
          onClosed?.call();
      }
    });
  }
  final UsbTransport transport;
  final void Function()? onClosed;
  late final SerialFrameDecoder _decoder;
  StreamSubscription<UsbEvent>? _subscription;
  Completer<Map<String, dynamic>>? _pending;
  Timer? _timeout;
  String _token = '', _id = '';
  bool _connected = false;
  bool get connected => _connected;

  Future<void> connect(String deviceId, String token) async {
    if (token.isEmpty ||
        token.length > 64 ||
        token.codeUnits.any((c) => c < 33 || c > 126)) {
      throw const AppFailure('请填写有效的设备管理口令。');
    }
    await close();
    await transport.open(deviceId);
    _token = token;
    _connected = true;
  }

  Future<Map<String, dynamic>> request(
    String method, [
    Map<String, Object> params = const {},
  ]) async {
    if (!_connected || _pending != null) {
      throw const AppFailure('USB 未连接或正在处理请求。');
    }
    if (!{
      'status.get',
      'config.get',
      'config.patch',
      'wifi.scan',
      'ble.pair',
      'ble.passkey',
      'ble.clear',
      'reboot',
    }.contains(method)) {
      throw const AppFailure('串口管理不支持该操作。');
    }
    final id = requestId();
    final body = utf8.encode(
      jsonEncode({
        'v': 1,
        'id': id,
        'method': method,
        'token': _token,
        'params': params,
      }),
    );
    if (body.length > 20000) {
      body.fillRange(0, body.length, 0);
      throw const AppFailure('管理请求过长。');
    }
    final wire = Uint8List.fromList([...ascii.encode('@tepy:'), ...body, 10]);
    body.fillRange(0, body.length, 0);
    final pending = Completer<Map<String, dynamic>>();
    _id = id;
    _pending = pending;
    _timeout = Timer(
      const Duration(seconds: 15),
      () => _fail(const AppFailure('等待串口回执超时，结果未确认；请先重新读取，不自动重发。')),
    );
    try {
      // 同时挂上 write 和 reply 的错误处理，拔线发生在 write 期间也不会产生未处理 Future。
      final values = await Future.wait<Object?>([
        pending.future,
        transport.write(wire).timeout(const Duration(seconds: 5)),
      ], eagerError: true);
      return values.first! as Map<String, dynamic>;
    } on AppFailure {
      rethrow;
    } catch (_) {
      throw const AppFailure('串口写入结果未确认，不自动重发。');
    } finally {
      wipe(wire);
      if (identical(_pending, pending)) {
        _pending = null;
        _id = '';
        _timeout?.cancel();
      }
    }
  }

  void _receive(Map<String, dynamic> frame) {
    final pending = _pending;
    if (pending == null ||
        frame['v'] != 1 ||
        frame['id'] != _id ||
        frame['ok'] is! bool) {
      return;
    }
    if (frame['ok'] == true && object(frame['result']) != null) {
      if (!pending.isCompleted) {
        pending.complete(frame['result'] as Map<String, dynamic>);
      }
    } else if (frame['ok'] == false && frame['error'] is String) {
      final code = frame['error'] as String;
      final message = code == 'unauthorized'
          ? '设备管理口令不正确。'
          : (RegExp(r'^[a-z_]{1,64}$').hasMatch(code)
                ? '设备拒绝操作（$code）。'
                : '设备拒绝操作。');
      if (!pending.isCompleted) pending.completeError(AppFailure(message));
    }
  }

  void _fail(AppFailure error) {
    if (_pending?.isCompleted == false) _pending!.completeError(error);
  }

  Future<void> close() async {
    _connected = false;
    _token = '';
    _id = '';
    _timeout?.cancel();
    _decoder.reset();
    _fail(const AppFailure('USB 连接已关闭。'));
    await transport.close();
  }

  Future<void> dispose() async {
    await close();
    await _subscription?.cancel();
    _decoder.dispose();
    await transport.dispose();
  }
}

enum PasswordPolicy { keep, replace, clear }

/// PATCH 的“省略”和“空字符串”语义不同。这里集中编码，界面不自己拼密码字段。
Map<String, Object> deviceConfigPatch({
  required String ssid,
  required String mqttUri,
  required String mqttUsername,
  required String ntp,
  required int keyDelay,
  required String ca,
  PasswordPolicy wifiPolicy = PasswordPolicy.keep,
  String wifiPassword = '',
  PasswordPolicy mqttPolicy = PasswordPolicy.keep,
  String mqttPassword = '',
}) {
  final uri = Uri.tryParse(mqttUri);
  var validPort = true;
  try {
    if (uri != null && uri.hasPort) {
      validPort = uri.port >= 1 && uri.port <= 65535;
    }
  } on FormatException {
    // 超出 Dart 整数范围的端口也只给出固定说明，不透传输入原文。
    validPort = false;
  }
  if (utf8.encode(ssid).length > 32 ||
      utf8.encode(mqttUri).length > 256 ||
      (mqttUri.isNotEmpty &&
          (uri == null ||
              !{'mqtt', 'mqtts'}.contains(uri.scheme) ||
              uri.host.isEmpty ||
              uri.userInfo.isNotEmpty ||
              uri.path.isNotEmpty ||
              uri.hasQuery ||
              uri.hasFragment ||
              !validPort ||
              RegExp(r':0+$').hasMatch(mqttUri))) ||
      utf8.encode(mqttUsername).length > 128 ||
      ntp.isEmpty ||
      utf8.encode(ntp).length > 128 ||
      keyDelay < 5 ||
      keyDelay > 200 ||
      utf8.encode(ca).length > 8192) {
    throw const AppFailure('请检查 SSID、MQTT 地址、CA、NTP 和按键间隔范围。');
  }
  final wifiBytes = utf8.encode(wifiPassword).length;
  if (wifiPolicy == PasswordPolicy.replace &&
      (wifiBytes < 8 || wifiBytes > 63)) {
    throw const AppFailure('Wi-Fi 新密码为 8–63 字节；开放网络请选择清除。');
  }
  if (mqttPolicy == PasswordPolicy.replace &&
      (mqttPassword.isEmpty || utf8.encode(mqttPassword).length > 256)) {
    throw const AppFailure('MQTT 新密码为 1–256 字节；无密码请选择清除。');
  }
  return {
    'v': 1,
    'wifi': <String, Object>{
      'ssid': ssid,
      if (wifiPolicy == PasswordPolicy.replace) 'password': wifiPassword,
      if (wifiPolicy == PasswordPolicy.clear) 'password': '',
    },
    'mqtt': <String, Object>{
      'uri': mqttUri,
      'username': mqttUsername,
      'ca': ca,
      if (mqttPolicy == PasswordPolicy.replace) 'password': mqttPassword,
      if (mqttPolicy == PasswordPolicy.clear) 'password': '',
    },
    'ntp_server': ntp,
    'key_delay_ms': keyDelay,
  };
}
