import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../data/usb_transport.dart';
import '../domain/connection_profile.dart';
import '../domain/serial_management.dart';
import '../domain/snapshots.dart';

/// USB 与 MQTT 是独立连接；没有 Wi-Fi 也能经 USB 管理 ESP32。
final usbTransportFactoryProvider = Provider<UsbTransport Function()>(
  (ref) => AndroidUsbTransport.new,
);
final usbTokenStoreProvider = Provider<UsbTokenStore>(
  (ref) => SecureUsbTokenStore(),
);
final usbProvider = NotifierProvider<UsbController, UsbState>(
  UsbController.new,
);

abstract interface class UsbTokenStore {
  Future<String> load();
  Future<void> save(String token);
  Future<void> forget();
}

final class SecureUsbTokenStore implements UsbTokenStore {
  final _storage = const FlutterSecureStorage();
  static const _key = 'tepy.usb.admin.v1';
  @override
  Future<String> load() async {
    try {
      return await _storage.read(key: _key) ?? '';
    } catch (_) {
      throw const AppFailure('无法读取 USB 管理口令。');
    }
  }

  @override
  Future<void> save(String token) async {
    try {
      await _storage.write(key: _key, value: token);
    } catch (_) {
      throw const AppFailure('USB 已连接，但系统未能记住管理口令。');
    }
  }

  @override
  Future<void> forget() async {
    try {
      await _storage.delete(key: _key);
    } catch (_) {
      throw const AppFailure('无法清除手机保存的 USB 管理口令。');
    }
  }
}

final class UsbState {
  const UsbState({
    this.devices = const [],
    this.connected = false,
    this.busy = false,
    this.config,
    this.status,
    this.message = '用 OTG 线连接 ESP32 原生 USB 口，然后刷新设备。',
    this.isError = false,
  });
  final List<UsbCandidate> devices;
  final bool connected, busy, isError;
  final Map<String, dynamic>? config, status;
  final String message;
  UsbState copyWith({
    List<UsbCandidate>? devices,
    bool? connected,
    bool? busy,
    Map<String, dynamic>? config,
    Map<String, dynamic>? status,
    bool clear = false,
    String? message,
    bool? isError,
  }) => UsbState(
    devices: devices ?? this.devices,
    connected: connected ?? this.connected,
    busy: busy ?? this.busy,
    config: clear ? null : (config ?? this.config),
    status: clear ? null : (status ?? this.status),
    message: message ?? this.message,
    isError: isError ?? this.isError,
  );
}

class UsbController extends Notifier<UsbState> {
  late UsbTransport _transport;
  late SerialManagement _client;
  late UsbTokenStore _tokens;
  bool _disposed = false;
  int _epoch = 0;
  @override
  UsbState build() {
    _tokens = ref.read(usbTokenStoreProvider);
    _transport = ref.read(usbTransportFactoryProvider)();
    _client = SerialManagement(
      _transport,
      onClosed: () {
        if (!_disposed) {
          ++_epoch;
          state = state.copyWith(
            connected: false,
            busy: false,
            clear: true,
            message: 'USB 已断开，写入结果可能未确认。',
            isError: true,
          );
        }
      },
    );
    ref.onDispose(() {
      _disposed = true;
      ++_epoch;
      unawaited(_client.dispose());
    });
    return const UsbState();
  }

  Future<String> loadToken() async {
    try {
      return await _tokens.load();
    } on AppFailure catch (error) {
      if (!_disposed) {
        state = state.copyWith(message: error.message, isError: true);
      }
      return '';
    }
  }

  /// _run 是统一的前台互斥入口。15 秒超时由 SerialManagement 处理，绝不重发写操作。
  Future<void> _run(Future<void> Function() work) async {
    if (_disposed || state.busy) return;
    final epoch = _epoch;
    state = state.copyWith(busy: true, isError: false);
    try {
      await work();
    } on AppFailure catch (error) {
      if (!_disposed && epoch == _epoch) {
        state = state.copyWith(message: error.message, isError: true);
      }
    } catch (_) {
      if (!_disposed && epoch == _epoch) {
        state = state.copyWith(
          message: 'USB 操作结果未确认，请人工检查，不自动重试。',
          isError: true,
        );
      }
    } finally {
      if (!_disposed && epoch == _epoch) state = state.copyWith(busy: false);
    }
  }

  void _alive(int epoch) {
    if (_disposed || epoch != _epoch) throw const AppFailure('USB 操作已经取消。');
  }

  Future<void> refreshDevices() => _run(() async {
    final epoch = _epoch;
    final devices = await _transport.list();
    _alive(epoch);
    if (!_disposed) {
      state = state.copyWith(
        devices: List.unmodifiable(devices),
        message: devices.isEmpty
            ? '没有发现 ESP32 原生 USB 串口，请确认 OTG 和数据线。'
            : '请选择设备并填写管理口令。',
      );
    }
  });

  Future<void> connect(String id, String token, {bool remember = true}) =>
      _run(() async {
        final epoch = _epoch;
        try {
          await _client.connect(id, token);
          _alive(epoch);
          final status = await _client.request('status.get');
          _alive(epoch);
          final config = await _readConfig();
          _alive(epoch);
          state = state.copyWith(
            connected: true,
            status: status,
            config: config,
            message: 'USB 鉴权通过，已读取状态与脱敏配置。',
          );
        } catch (_) {
          if (epoch == _epoch) await _client.close();
          rethrow;
        }
        if (remember) await _tokens.save(token);
      });

  Future<void> disconnect() async {
    ++_epoch;
    if (!_disposed) {
      state = state.copyWith(
        connected: false,
        busy: false,
        clear: true,
        message: 'USB 已关闭，后续步骤已取消。',
      );
    }
    await _client.close();
  }

  Future<Map<String, dynamic>> _readConfig() async {
    final config = await _client.request('config.get');
    final wifi = object(config['wifi']), mqtt = object(config['mqtt']);
    if (config['v'] != 1 ||
        wifi?['ssid'] is! String ||
        wifi?['password_set'] is! bool ||
        mqtt?['uri'] is! String ||
        mqtt?['username'] is! String ||
        mqtt?['password_set'] is! bool ||
        mqtt?['ca'] is! String ||
        config['ntp_server'] is! String ||
        config['key_delay_ms'] is! int) {
      throw const AppFailure('设备配置结构或版本不受支持，禁止保存。');
    }
    return config;
  }

  Future<void> readStatus() => _run(() async {
    final epoch = _epoch, result = await _client.request('status.get');
    _alive(epoch);
    state = state.copyWith(status: result, message: 'USB 状态已更新。');
  });
  Future<void> readConfig() => _run(() async {
    final epoch = _epoch, result = await _readConfig();
    _alive(epoch);
    state = state.copyWith(config: result, message: '已重新读取脱敏配置。');
  });
  Future<void> saveConfig(Map<String, Object> patch) async {
    try {
      await _run(() async {
        final epoch = _epoch;
        if (state.config == null) throw const AppFailure('请先读取配置。');
        await _client.request('config.patch', patch);
        _alive(epoch);
        final config = await _readConfig();
        _alive(epoch);
        state = state.copyWith(
          config: config,
          message: '配置保存成功并已回读；请手动重启使其生效。',
        );
      });
    } finally {
      // 删除调用者本次 PATCH 的敏感引用；不可变字符串的框架副本不能保证全部擦除。
      for (final group in ['wifi', 'mqtt']) {
        final values = patch[group];
        if (values is Map) values.remove('password');
      }
    }
  }

  Future<void> reboot() => _run(() async {
    await _client.request('reboot');
    await disconnect();
    if (!_disposed) {
      state = state.copyWith(message: '设备已接受重启，启动后重新刷新 USB 设备并连接。');
    }
  });
  Future<void> pair() => _run(() async {
    final epoch = _epoch;
    await _client.request('ble.pair');
    _alive(epoch);
    if (!_disposed) {
      state = state.copyWith(message: '已开启 120 秒蓝牙配对窗口，请在 Mac 连接。');
    }
  });
  Future<void> passkey(String value) => _run(() async {
    final epoch = _epoch;
    if (!RegExp(r'^[0-9]{6}$').hasMatch(value)) {
      throw const AppFailure('配对码需为六位数字。');
    }
    await _client.request('ble.passkey', {'passkey': value});
    _alive(epoch);
    if (!_disposed) state = state.copyWith(message: '配对码已提交。');
  });
  Future<void> clearBond() => _run(() async {
    final epoch = _epoch;
    await _client.request('ble.clear');
    _alive(epoch);
    if (!_disposed) state = state.copyWith(message: '蓝牙绑定已清除，需要重新配对。');
  });
  Future<void> forgetToken() => _run(() async {
    await _tokens.forget();
    await disconnect();
  });
}
