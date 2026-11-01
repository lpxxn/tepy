import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tepy_mobile/application/firmware_controller.dart';
import 'package:tepy_mobile/application/providers.dart';
import 'package:tepy_mobile/application/usb_controller.dart';
import 'package:tepy_mobile/domain/firmware_image.dart';
import 'package:tepy_mobile/domain/serial_firmware.dart';
import 'package:tepy_mobile/domain/serial_management.dart';

import 'support/fakes.dart';
import 'support/firmware_fixtures.dart';
import 'support/usb_firmware_wire.dart';

void main() {
  test(
    'USB upgrade sends exact blocks once with boot session while MQTT offline',
    () async {
      final wire = UsbFirmwareWire();
      final serial = SerialManagement(wire);
      addTearDown(serial.dispose);
      await serial.connect('1:0', 'ExampleAdminTokenOnly0000');
      final bytes = firmwareBytes(payloadSize: 9000),
          image = FirmwareImage.inspect('tepy.bin', bytes),
          progress = <int>[];
      final before = await sendUsbFirmware(
        serial,
        image,
        'aabbccddeeff',
        () => true,
        (sent, _) => progress.add(sent),
      );
      expect(before['session'], 'd' * 32);
      expect(wire.imageBytes, bytes);
      expect(wire.finishes, 1);
      expect(progress.last, bytes.length);
      expect(progress.length, greaterThan(2));
      expect(
        wire.sent.every((f) => f['token'] == 'ExampleAdminTokenOnly0000'),
        true,
      );
      final offsets = wire.sent
          .where((f) => f['method'] == 'ota.write')
          .map((f) => (f['params'] as Map)['offset'])
          .toList();
      expect(offsets, offsets.toSet().toList());
    },
  );
  test('old firmware or wrong target never starts writing', () async {
    final wire = UsbFirmwareWire()..supported = false;
    final client = SerialManagement(wire);
    addTearDown(client.dispose);
    await client.connect('1:0', 'ExampleAdminTokenOnly0000');
    for (final id in ['aabbccddeeff', '000000000000']) {
      await expectLater(
        sendUsbFirmware(client, testFirmware(), id, () => true, (_, _) {}),
        throwsA(isA<Exception>()),
      );
    }
    expect(wire.begins, 0);
  });
  test('mismatched ACK aborts once without finish or retry', () async {
    final wire = UsbFirmwareWire()..wrongAck = true;
    final client = SerialManagement(wire);
    addTearDown(client.dispose);
    await client.connect('1:0', 'ExampleAdminTokenOnly0000');
    await expectLater(
      sendUsbFirmware(
        client,
        testFirmware(),
        'aabbccddeeff',
        () => true,
        (_, _) {},
      ),
      throwsA(isA<Exception>()),
    );
    expect(wire.sent.where((f) => f['method'] == 'ota.write'), hasLength(1));
    expect(wire.aborts, 1);
    expect(wire.finishes, 0);
  });
  test(
    'USB controller waits for reconnect and confirms new session/version',
    () async {
      for (final rollback in [false, true]) {
        final h = _Fixture();
        addTearDown(h.container.dispose);
        h.wire.rollback = rollback;
        await h.start();
        await h.firmware.upgradeUsb('aabbccddeeff');
        expect(
          h.container.read(firmwareProvider).phase,
          FirmwarePhase.verifying,
        );
        h.firmware.cancel(background: true);
        expect(
          h.container.read(firmwareProvider).phase,
          FirmwarePhase.verifying,
        );
        expect(h.container.read(usbProvider).connected, false);
        expect(h.container.read(sessionProvider).maintenance, false);
        await h.usb.connect('1:0', 'ExampleAdminTokenOnly0000');
        expect(
          h.container.read(firmwareProvider).phase,
          rollback ? FirmwarePhase.failed : FirmwarePhase.verified,
        );
        expect(h.wire.begins, 1);
        expect(h.wire.finishes, 1);
      }
    },
  );
  test(
    'cancelling mid-block closes port, releases lock and ignores late ACK',
    () async {
      final h = _Fixture();
      addTearDown(h.container.dispose);
      await h.start();
      h.wire.writeGate = Completer<void>();
      final job = h.firmware.upgradeUsb('aabbccddeeff');
      for (
        var i = 0;
        i < 20 && !h.wire.sent.any((f) => f['method'] == 'ota.write');
        i++
      ) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(h.container.read(sessionProvider).maintenance, true);
      await h.container.read(sessionProvider.notifier).wake();
      expect(h.broker.sent, isEmpty);
      h.firmware.cancel();
      h.wire.writeGate!.complete();
      await job;
      expect(h.container.read(sessionProvider).maintenance, false);
      expect(h.container.read(firmwareProvider).phase, FirmwarePhase.failed);
      expect(h.wire.finishes, 0);
    },
  );
}

final class _Fixture {
  final wire = UsbFirmwareWire(), broker = FakeBroker(TestClock());
  late final ProviderContainer container = ProviderContainer(
    overrides: [
      clockProvider.overrideWithValue(TestClock()),
      connectionStoreProvider.overrideWithValue(FakeStore()),
      transportFactoryProvider.overrideWithValue(() => broker),
      usbTransportFactoryProvider.overrideWithValue(() => wire),
      usbTokenStoreProvider.overrideWithValue(FakeUsbTokenStore()),
      firmwareTargetStoreProvider.overrideWithValue(FakeFirmwareStore()),
      firmwarePickerProvider.overrideWithValue(
        FakeFirmwarePicker(testFirmware()),
      ),
    ],
  );
  UsbController get usb => container.read(usbProvider.notifier);
  FirmwareController get firmware => container.read(firmwareProvider.notifier);
  Future<void> start() async {
    await container.read(sessionProvider.notifier).connect(testProfile);
    await usb.connect('1:0', 'ExampleAdminTokenOnly0000');
    firmware.selectTransport(FirmwareTransport.usb);
    await firmware.readUsbStatus('aabbccddeeff');
    await firmware.chooseImage();
  }
}
