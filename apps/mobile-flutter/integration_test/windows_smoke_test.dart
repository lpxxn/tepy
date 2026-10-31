import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:tepy_mobile/app/tepy_app.dart';
import 'package:tepy_mobile/application/providers.dart';
import 'package:tepy_mobile/application/session_state.dart';
import 'package:tepy_mobile/application/usb_controller.dart';
import 'package:tepy_mobile/data/connection_store.dart';
import 'package:tepy_mobile/data/usb_transport.dart';
import 'package:tepy_mobile/domain/commands.dart';
import 'package:tepy_mobile/domain/connection_profile.dart';
import 'package:tepy_mobile/domain/serial_management.dart';

/// 原生 Windows 测试：临时存储项、真实串口、只读 MQTT。
/// 不读取/覆盖用户连接档案；不保存配置、不配对、不发送键盘内容。
class _EmptyStore implements ConnectionStore {
  @override
  Future<ConnectionProfile?> load() async => null;
  @override
  Future<void> save(ConnectionProfile profile) async =>
      throw StateError('测试不保存档案');
  @override
  Future<void> forget() async => throw StateError('测试不删除档案');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Windows native UI, secure storage, COM and MQTT', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [connectionStoreProvider.overrideWithValue(_EmptyStore())],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const TepyApp()),
    );
    await tester.pumpAndSettle();
    final key = 'tepy.smoke.${requestId()}', value = requestId();
    const storage = FlutterSecureStorage();
    try {
      await storage.write(key: key, value: value);
      expect(await storage.read(key: key), value);
    } finally {
      await storage.delete(key: key);
    }
    final usb = NativeUsbTransport();
    try {
      final ports = await usb.list();
      expect(
        ports.every((p) => p.id.startsWith('COM') && p.vendorId == 0x303a),
        true,
      );
      if (const bool.fromEnvironment('TEPY_USB_CHECK')) {
        expect(ports, isNotEmpty, reason: '请连接 ESP32 原生 USB 并退出其他串口程序');
        // 使用明确无效的凭据获取 unauthorized，验证实际双向字节流，不读取敏感配置。
        final reply = Completer<Map<String, dynamic>>();
        final id = requestId();
        final decoder = SerialFrameDecoder((frame) {
          if (frame['id'] == id && !reply.isCompleted) reply.complete(frame);
        });
        final subscription = usb.events.listen((event) {
          if (event is UsbBytes) {
            decoder.add(event.bytes);
            wipe(event.bytes);
          }
        });
        try {
          await usb.open(ports.first.id);
          final bytes = Uint8List.fromList(
            utf8.encode(
              '@tepy:${jsonEncode({'v': 1, 'id': id, 'method': 'status.get', 'token': 'invalid-smoke-test', 'params': <String, Object>{}})}\n',
            ),
          );
          try {
            await usb.write(bytes);
          } finally {
            wipe(bytes);
          }
          final response = await reply.future.timeout(
            const Duration(seconds: 10),
          );
          expect(response['ok'], false);
          expect(response['error'], 'unauthorized');
        } finally {
          await subscription.cancel();
          decoder.dispose();
          await usb.close();
        }
        // 关闭后重新打开，验证旧连接的 lease 不会污染新连接。
        await usb.open(ports.first.id);
        await usb.close();
      }
    } finally {
      await usb.dispose();
    }
    if (const bool.fromEnvironment('TEPY_BROKER_CHECK')) {
      final controller = container.read(sessionProvider.notifier);
      await controller.connect(
        const ConnectionProfile(broker: 'mqtt://127.0.0.1:1883'),
      );
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 300));
        if (container.read(sessionProvider).device != null) break;
      }
      expect(container.read(sessionProvider).link, LinkState.online);
      expect(container.read(sessionProvider).device, isNotNull);
      final unstable = <bool>[];
      final listener = container.listen(sessionProvider, (_, state) {
        unstable.add(state.link != LinkState.online || state.device == null);
      });
      try {
        for (var i = 0; i < 20; i++) {
          await tester.pump(const Duration(seconds: 1));
        }
        expect(unstable.where((v) => v), isEmpty);
      } finally {
        listener.close();
        await controller.disconnect();
      }
    }
    for (final tab in ['操作', '设备', '连接', '状态']) {
      await tester.tap(find.text(tab).last);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
    await tester.tap(find.text('设备').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('refreshUsb')));
    await tester.pumpAndSettle();
    expect(container.read(usbProvider).isError, false);
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    await tester.pumpAndSettle();
  });
}
