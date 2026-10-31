import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:tepy_mobile/app/tepy_app.dart';
import 'package:tepy_mobile/application/providers.dart';
import 'package:tepy_mobile/application/session_state.dart';
import 'package:tepy_mobile/data/usb_transport.dart';
import 'package:tepy_mobile/domain/commands.dart';
import 'package:tepy_mobile/domain/connection_profile.dart';
import 'package:tepy_mobile/main.dart' as app;

/// 显式指定手机设备才运行；真实 Broker 部分只订阅，不发布键盘或配置动作。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native phone UI, Keystore, USB enumeration and optional MQTT read-only',
    (tester) async {
      app.main();
      await tester.pumpAndSettle();
      expect(find.byType(TepyApp), findsOneWidget);
      const storage = FlutterSecureStorage();
      final key = 'tepy.smoke.${requestId()}', value = requestId();
      try {
        await storage.write(key: key, value: value);
        expect(await storage.read(key: key) == value, true);
      } finally {
        await storage.delete(key: key);
      }
      final usb = AndroidUsbTransport();
      expect(await usb.list(), isList);
      await usb.dispose();

      const checkDevice = bool.fromEnvironment('TEPY_DEVICE_CHECK');
      if (checkDevice || const bool.fromEnvironment('TEPY_BROKER_CHECK')) {
        final container = ProviderScope.containerOf(
          tester.element(find.byType(TepyApp)),
        );
        final controller = container.read(sessionProvider.notifier);
        await controller.connect(
          const ConnectionProfile(
            broker: String.fromEnvironment(
              'TEPY_BROKER',
              defaultValue: 'mqtt://192.168.50.99:1883',
            ),
          ),
        );
        for (var i = 0; i < 60; i++) {
          await tester.pump(const Duration(milliseconds: 300));
          if (container.read(sessionProvider).mac != null &&
              (!checkDevice ||
                  container.read(sessionProvider).device != null)) {
            break;
          }
        }
        final state = container.read(sessionProvider);
        expect(state.link, LinkState.online, reason: '手机未完成 MQTT 连接与订阅');
        if (checkDevice) {
          expect(state.device != null, true, reason: 'ESP32 未提供有效状态');
        }
        expect(state.mac != null, true, reason: 'Mac 未提供有效状态');
        // 旧测试只等到了首次状态，遗漏了连接后一秒的错误重试。
        // 连续观察 45 秒，覆盖多次设备心跳、Mac 心跳和 MQTT keepalive。
        final unstable = <String>[];
        final samples = <int>{};
        final listener = container.listen(sessionProvider, (_, next) {
          if (next.link != LinkState.online ||
              next.mac == null ||
              (checkDevice && !next.canAct)) {
            unstable.add(
              '${next.link.name}:device=${next.device != null},mac=${next.mac != null},ready=${next.canAct}',
            );
          }
          final device = next.device;
          if (device != null) samples.add(device.sampledAt);
        });
        try {
          for (var i = 0; i < 45; i++) {
            await tester.pump(const Duration(seconds: 1));
          }
          expect(unstable, isEmpty, reason: '连接稳定期间出现状态清空或按钮禁用');
          if (checkDevice) expect(samples.length, greaterThanOrEqualTo(4));
        } finally {
          listener.close();
        }
        await controller.disconnect();
      }
      for (final tab in ['操作', '设备', '连接', '状态']) {
        await tester.tap(find.text(tab).last);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
      await tester.tap(find.text('连接').last);
      await tester.pumpAndSettle();
      final page = find.byKey(const PageStorageKey('connection'));
      final scrollable = find
          .descendant(of: page, matching: find.byType(Scrollable))
          .first;
      await tester.scrollUntilVisible(
        find.text('TLS 证书'),
        220,
        scrollable: scrollable,
      );
      Future<void> reveal(Finder target) async {
        final bounds = tester.getRect(page);
        for (var i = 0; i < 12; i++) {
          final center = tester.getCenter(target).dy;
          if (center > bounds.top + 60 && center < bounds.bottom - 60) return;
          await tester.drag(
            scrollable,
            Offset(0, center >= bounds.bottom - 60 ? -200 : 200),
          );
          await tester.pumpAndSettle();
        }
        fail('TLS 控件未进入可点击区域');
      }

      for (var i = 0; i < 2; i++) {
        await reveal(find.text('TLS 证书'));
        await tester.tap(find.text('TLS 证书'));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('caField')), findsOneWidget);
        expect(tester.takeException(), isNull);
        await reveal(find.text('TLS 证书'));
        await tester.tap(find.text('TLS 证书'));
        await tester.pumpAndSettle();
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
}
