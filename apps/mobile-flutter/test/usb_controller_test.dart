import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tepy_mobile/application/usb_controller.dart';
import 'package:tepy_mobile/domain/serial_management.dart';

import 'support/fakes.dart';

void main() {
  test(
    'USB authenticates before reading configuration; saves then reads back',
    () async {
      final usb = FakeUsb(), tokens = FakeUsbTokenStore();
      final container = ProviderContainer(
        overrides: [
          usbTransportFactoryProvider.overrideWithValue(() => usb),
          usbTokenStoreProvider.overrideWithValue(tokens),
        ],
      );
      addTearDown(container.dispose);
      final controller = container.read(usbProvider.notifier);
      await controller.refreshDevices();
      expect(container.read(usbProvider).devices, hasLength(1));
      await controller.connect('1:0', 'ExampleAdminTokenOnly0000');
      expect(usb.sent.map((s) => s['method']), ['status.get', 'config.get']);
      expect(
        usb.sent.every((s) => s['token'] == 'ExampleAdminTokenOnly0000'),
        true,
      );
      expect(container.read(usbProvider).connected, true);
      expect(tokens.value, 'ExampleAdminTokenOnly0000');
      final patch = deviceConfigPatch(
        ssid: 'Example-WiFi',
        mqttUri: 'mqtt://192.0.2.1:1883',
        mqttUsername: '',
        ntp: 'pool.ntp.org',
        keyDelay: 20,
        ca: '',
        wifiPolicy: PasswordPolicy.replace,
        wifiPassword: 'ExampleOnly123',
      );
      await controller.saveConfig(patch);
      expect(usb.sent.map((s) => s['method']).skip(2), [
        'config.patch',
        'config.get',
      ]);
      expect((patch['wifi'] as Map).containsKey('password'), false);
      expect(container.read(usbProvider).message, contains('回读'));
      await controller.forgetToken();
      expect(tokens.value, isEmpty);
      expect(container.read(usbProvider).connected, false);
    },
  );

  test(
    'USB disconnect cancels pending request and ignores late old reply',
    () => fakeAsync((async) {
      final usb = FakeUsb()..autoReply = false;
      final container = ProviderContainer(
        overrides: [
          usbTransportFactoryProvider.overrideWithValue(() => usb),
          usbTokenStoreProvider.overrideWithValue(FakeUsbTokenStore()),
        ],
      );
      final controller = container.read(usbProvider.notifier);
      unawaited(controller.connect('1:0', 'ExampleAdminTokenOnly0000'));
      async.flushMicrotasks();
      expect(usb.sent.length, 1);
      final oldId = usb.sent.single['id'];
      unawaited(controller.disconnect());
      async.flushMicrotasks();
      usb.frame({'v': 1, 'id': oldId, 'ok': true, 'result': configJson()});
      async.elapse(const Duration(seconds: 16));
      async.flushMicrotasks();
      final state = container.read(usbProvider);
      expect(state.connected, false);
      expect(state.busy, false);
      expect(state.config, isNull);
      expect(state.message, contains('关闭'));
      expect(usb.sent.length, 1);
      container.dispose();
      async.flushMicrotasks();
    }),
  );

  test(
    'unauthorized USB does not read or remember configuration',
    () => fakeAsync((async) {
      final usb = FakeUsb()..autoReply = false, tokens = FakeUsbTokenStore();
      final container = ProviderContainer(
        overrides: [
          usbTransportFactoryProvider.overrideWithValue(() => usb),
          usbTokenStoreProvider.overrideWithValue(tokens),
        ],
      );
      final controller = container.read(usbProvider.notifier);
      unawaited(controller.connect('1:0', 'ExampleWrongToken'));
      async.flushMicrotasks();
      usb.frame({
        'v': 1,
        'id': usb.sent.single['id'],
        'ok': false,
        'error': 'unauthorized',
      });
      async.flushMicrotasks();
      expect(usb.sent.length, 1);
      expect(tokens.value, isEmpty);
      expect(container.read(usbProvider).connected, false);
      expect(container.read(usbProvider).message, contains('口令不正确'));
      container.dispose();
      async.flushMicrotasks();
    }),
  );
}
