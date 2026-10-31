import 'dart:async';

import 'package:flutter/services.dart';

import '../domain/connection_profile.dart';

/// Android 使用系统 USB 标识，Windows 使用 COM 名称。重新插拔后需要重新枚举。
final class UsbCandidate {
  const UsbCandidate(this.id, this.name, this.vendorId, this.productId);
  final String id, name;
  final int vendorId, productId;
}

sealed class UsbEvent {
  const UsbEvent();
}

final class UsbBytes extends UsbEvent {
  const UsbBytes(this.bytes);
  final Uint8List bytes;
}

final class UsbClosed extends UsbEvent {
  const UsbClosed();
}

abstract interface class UsbTransport {
  Stream<UsbEvent> get events;
  Future<List<UsbCandidate>> list();
  Future<void> open(String id);
  Future<void> write(Uint8List bytes);
  Future<void> close();
  Future<void> dispose();
}

/// MethodChannel 发起调用，EventChannel 接收持续的字节流。
/// 平台只负责 USB，JSON 分帧与鉴权仍在独立的 Dart 业务层完成。
final class NativeUsbTransport implements UsbTransport {
  static const _methods = MethodChannel('tepy/usb');
  static const _nativeEvents = EventChannel('tepy/usb/events');
  final _events = StreamController<UsbEvent>.broadcast();
  StreamSubscription<dynamic>? _subscription;
  int? _lease;
  int _operation = 0;
  @override
  Stream<UsbEvent> get events => _events.stream;

  @override
  Future<List<UsbCandidate>> list() async {
    try {
      final raw = await _methods.invokeListMethod<dynamic>('list') ?? [];
      return [
        for (final item in raw)
          if (item is Map &&
              item['id'] is String &&
              item['name'] is String &&
              item['vendor_id'] is int &&
              item['product_id'] is int)
            UsbCandidate(
              item['id'] as String,
              item['name'] as String,
              item['vendor_id'] as int,
              item['product_id'] as int,
            ),
      ];
    } catch (_) {
      throw const AppFailure('无法枚举串口，请检查数据线、驱动或 OTG。');
    }
  }

  @override
  Future<void> open(String id) async {
    await close();
    final operation = ++_operation;
    _subscription = _nativeEvents.receiveBroadcastStream().listen(
      (dynamic event) {
        if (event is! Map || event['lease'] != _lease || _lease == null) return;
        if (event['event'] == 'data' && event['bytes'] is Uint8List) {
          _events.add(UsbBytes(event['bytes'] as Uint8List));
        } else if (event['event'] == 'closed') {
          _lease = null;
          _events.add(const UsbClosed());
        }
      },
      onError: (Object _) {
        if (_lease != null) {
          _lease = null;
          _events.add(const UsbClosed());
        }
      },
    );
    try {
      final reply = await _methods
          .invokeMapMethod<String, dynamic>('open', {'id': id})
          .timeout(const Duration(seconds: 60));
      if (operation != _operation || reply?['lease'] is! int) {
        throw const AppFailure('USB 连接已取消。');
      }
      _lease = reply!['lease'] as int;
    } catch (_) {
      if (operation == _operation) await close();
      throw const AppFailure('USB 未能连接，请检查系统授权、串口占用和原生 USB 接口。');
    }
  }

  @override
  Future<void> write(Uint8List bytes) async {
    if (_lease == null) throw const AppFailure('USB 已断开。');
    try {
      await _methods.invokeMethod<void>('write', {'bytes': bytes});
    } catch (_) {
      throw const AppFailure('USB 写入结果未确认，不自动重试。');
    }
  }

  @override
  Future<void> close() async {
    ++_operation;
    _lease = null;
    await _subscription?.cancel();
    _subscription = null;
    try {
      await _methods.invokeMethod<void>('close');
    } catch (_) {
      /* 清理路径不打印平台异常。 */
    }
  }

  @override
  Future<void> dispose() async {
    await close();
    await _events.close();
  }
}

// 保留旧名称，避免已有 Android 集成测试或扩展代码中断。
typedef AndroidUsbTransport = NativeUsbTransport;
