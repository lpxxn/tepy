import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:tepy_mobile/data/usb_transport.dart';

import 'fakes.dart';

/// 协议另一端的最小实现：收真实 JSON 字节、检查偏移并重建二进制。
/// 默认没有 MQTT session，验证 USB 完全离线时仍能更新。
final class UsbFirmwareWire implements UsbTransport {
  final _events = StreamController<UsbEvent>.broadcast(sync: true);
  final sent = <Map<String, dynamic>>[], imageBytes = <int>[];
  bool opened = false,
      supported = true,
      wrongAck = false,
      accepted = false,
      rollback = false;
  String boot = 'd' * 32, version = '0.3.0', expectedHash = '';
  int expectedSize = 0, begins = 0, finishes = 0, aborts = 0;
  Completer<void>? writeGate;
  @override
  Stream<UsbEvent> get events => _events.stream;
  Map<String, dynamic> status() => {
    'v': 1,
    'device_id': 'aabbccddeeff',
    'firmware': version,
    'session': '',
    'boot_session': boot,
    'busy': false,
    if (supported) 'usb_ota': {'v': 1, 'max_chunk_bytes': 3072},
  };
  @override
  Future<List<UsbCandidate>> list() async => [
    const UsbCandidate('1:0', 'Test ESP32', 0x303a, 0x1001),
  ];
  @override
  Future<void> open(String id) async {
    opened = true;
    if (accepted) {
      boot = 'e' * 32;
      version = rollback ? '0.3.0' : '9.9.9';
    }
  }

  @override
  Future<void> write(Uint8List bytes) async {
    final frame =
        jsonDecode(utf8.decode(bytes).substring(6)) as Map<String, dynamic>;
    sent.add(frame);
    final method = frame['method'], params = frame['params'] as Map;
    Map<String, dynamic> result = {};
    String? error;
    if (frame['token'] != 'ExampleAdminTokenOnly0000') {
      error = 'unauthorized';
    } else if (method == 'status.get') {
      result = status();
    } else if (method == 'config.get') {
      result = configJson();
    } else if (method == 'ota.begin') {
      begins++;
      if (params['device_id'] != 'aabbccddeeff' || params['session'] != boot) {
        error = 'wrong_device_session';
      } else {
        expectedSize = params['size'] as int;
        expectedHash = params['sha256'] as String;
        imageBytes.clear();
        result = {
          'upload_id': 'b' * 32,
          'next_offset': 0,
          'max_chunk_bytes': 3072,
        };
      }
    } else if (method == 'ota.write') {
      await writeGate?.future;
      if (params['offset'] != imageBytes.length) {
        error = 'invalid_chunk';
      } else {
        imageBytes.addAll(base64Decode(params['data'] as String));
        result = {'next_offset': imageBytes.length + (wrongAck ? 1 : 0)};
      }
    } else if (method == 'ota.finish') {
      finishes++;
      if (expectedSize != imageBytes.length ||
          sha256.convert(imageBytes).toString() != expectedHash) {
        error = 'digest_mismatch';
      } else {
        accepted = true;
        result = {'ok': true, 'rebooting': true};
      }
    } else if (method == 'ota.abort') {
      aborts++;
      result = {'next_offset': 0};
    } else {
      error = 'unknown_method';
    }
    if (!opened) return;
    final reply = utf8.encode(
      '@tepy:${jsonEncode({'v': 1, 'id': frame['id'], 'ok': error == null, if (error == null) 'result': result else 'error': error})}\n',
    );
    // 故意分割前缀，覆盖 EventChannel 分片；普通日志不能影响协议。
    _events.add(
      UsbBytes(Uint8List.fromList(ascii.encode('I boot: test log\n'))),
    );
    _events.add(UsbBytes(Uint8List.fromList(reply.sublist(0, 4))));
    _events.add(UsbBytes(Uint8List.fromList(reply.sublist(4))));
  }

  @override
  Future<void> close() async {
    if (opened) {
      opened = false;
      _events.add(const UsbClosed());
    }
  }

  @override
  Future<void> dispose() async {
    opened = false;
    await _events.close();
  }
}
