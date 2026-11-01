import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tepy_mobile/application/firmware_controller.dart';
import 'package:tepy_mobile/application/providers.dart';
import 'package:tepy_mobile/application/usb_controller.dart';
import 'package:tepy_mobile/data/firmware_client.dart';
import 'package:tepy_mobile/domain/connection_profile.dart';
import 'package:tepy_mobile/domain/firmware_image.dart';

import 'support/fakes.dart';
import 'support/firmware_fixtures.dart';

const target = FirmwareTarget(
  address: 'http://127.0.0.1',
  token: 'ExampleAdminTokenOnly',
  deviceId: 'aabbccddeeff',
);
void main() {
  test(
    'firmware checks target, boundaries, checksum, hash and immutable input',
    () async {
      final bytes = firmwareBytes(),
          image = FirmwareImage.inspect('tepy.bin', bytes);
      expect(image.version, '9.9.9');
      bytes[48] = 0;
      final actual = await image.chunks().expand((b) => b).toList();
      expect(actual[48], ascii.encode('9').single);
      for (final offset in [0, 1, 12, 23, 32, 48, 80, 200, 303, 330]) {
        final broken = firmwareBytes();
        broken[offset] ^= 0x20;
        expect(
          () => FirmwareImage.inspect('bad.bin', broken),
          throwsA(isA<AppFailure>()),
        );
      }
      expect(
        () =>
            FirmwareImage.inspect('wrong.bin', firmwareBytes(project: 'other')),
        throwsA(isA<AppFailure>()),
      );
      expect(
        () => FirmwareImage.inspect('truncated.bin', Uint8List(288)),
        throwsA(isA<AppFailure>()),
      );
      expect(
        () => FirmwareImage.inspect(
          'large.bin',
          Uint8List(FirmwareImage.maximumSize + 1),
        ),
        throwsA(isA<AppFailure>()),
      );
      final path = Platform.environment['TEPY_TEST_APPLICATION'];
      if (path != null) {
        expect(
          FirmwareImage.inspect(
            'tepy.bin',
            await File(path).readAsBytes(),
          ).length,
          greaterThan(288),
        );
      }
    },
  );
  test(
    'HTTP OTA sends exact binary, Bearer and content length without redirects',
    () async {
      final received = <int>[], paths = <String>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((r) async {
        paths.add(r.uri.path);
        expect(
          r.headers.value(HttpHeaders.authorizationHeader),
          'Bearer ${target.token}',
        );
        if (r.uri.path == '/api/v1/status') {
          r.response.write(
            jsonEncode({
              'v': 1,
              'device_id': target.deviceId,
              'firmware': '0.2.0',
              'session': 'a' * 32,
              'busy': false,
            }),
          );
        } else {
          expect(r.method, 'POST');
          expect(r.headers.contentType!.mimeType, 'application/octet-stream');
          expect(r.contentLength, testFirmware().length);
          await for (final block in r) {
            received.addAll(block);
          }
          r.response.write('{"ok":true,"rebooting":true}');
        }
        await r.response.close();
      });
      final client = HttpFirmwareClient();
      addTearDown(client.close);
      final address = FirmwareTarget(
        address: 'http://127.0.0.1:${server.port}',
        token: target.token,
        deviceId: target.deviceId,
      );
      expect((await client.status(address))['firmware'], '0.2.0');
      var progress = 0;
      await client.upload(address, testFirmware(), (sent, total) {
        progress = sent;
        expect(sent, lessThanOrEqualTo(total));
      });
      expect(received, firmwareBytes());
      expect(progress, firmwareBytes().length);
      expect(paths, ['/api/v1/status', '/api/v1/ota']);
    },
  );
  test('HTTP redirect and wrong identity never become an upload target', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var calls = 0, redirect = true;
    server.listen((r) async {
      calls++;
      if (redirect) {
        r.response.statusCode = 302;
        r.response.headers.set(
          'location',
          'http://127.0.0.1:${server.port}/different',
        );
      } else {
        r.response.write(
          '{"v":1,"device_id":"000000000000","firmware":"0.2.0","session":"${'a' * 32}","busy":false}',
        );
      }
      await r.response.close();
    });
    final client = HttpFirmwareClient();
    addTearDown(client.close);
    final address = FirmwareTarget(
      address: 'http://127.0.0.1:${server.port}',
      token: target.token,
      deviceId: target.deviceId,
    );
    await expectLater(client.status(address), throwsA(isA<AppFailure>()));
    expect(calls, 1);
    redirect = false;
    await expectLater(client.status(address), throwsA(isA<AppFailure>()));
    expect(calls, 2);
  });
  test(
    'OTA verifies new session/version and maintenance blocks keyboard actions',
    () async {
      final h = _Fixture();
      addTearDown(h.container.dispose);
      await h.start();
      final job = h.controller.upgrade();
      await Future<void>.delayed(Duration.zero);
      expect(h.container.read(sessionProvider).maintenance, true);
      await h.container.read(sessionProvider.notifier).wake();
      expect(h.broker.sent, isEmpty);
      await h.container.read(usbProvider.notifier).reboot();
      expect(h.container.read(usbProvider).isError, true);
      expect(h.container.read(usbProvider).message, contains('升级期间'));
      h.backend.gate.complete();
      await job;
      expect(h.container.read(firmwareProvider).phase, FirmwarePhase.verified);
      expect(h.backend.uploads, 1);
      expect(h.container.read(sessionProvider).maintenance, false);
    },
  );
  test(
    'OTA interrupted or wrong version is not retransmitted and requires reread',
    () async {
      for (final wrong in [false, true]) {
        final h = _Fixture();
        await h.start();
        h.backend.wrongVersion = wrong;
        h.backend.failUpload = !wrong;
        h.backend.gate.complete();
        await h.controller.upgrade();
        expect(h.container.read(firmwareProvider).phase, FirmwarePhase.failed);
        expect(h.container.read(firmwareProvider).device, isNull);
        await h.controller.upgrade();
        expect(h.backend.uploads, 1);
        expect(h.container.read(sessionProvider).maintenance, false);
        h.container.dispose();
      }
    },
  );
  test(
    'cancel ignores late upload callbacks and releases maintenance',
    () async {
      final h = _Fixture();
      addTearDown(h.container.dispose);
      await h.start();
      final job = h.controller.upgrade();
      await Future<void>.delayed(Duration.zero);
      h.controller.cancel(background: true);
      h.backend.gate.complete();
      await job;
      expect(h.container.read(firmwareProvider).phase, FirmwarePhase.failed);
      expect(h.container.read(sessionProvider).maintenance, false);
      expect(h.backend.uploads, 1);
    },
  );
}

class _Backend {
  final gate = Completer<void>();
  int uploads = 0;
  bool uploaded = false, failUpload = false, wrongVersion = false;
}

class _Client implements FirmwareClient {
  _Client(this.backend);
  final _Backend backend;
  @override
  Future<Map<String, dynamic>> status(FirmwareTarget t) async => {
    'v': 1,
    'device_id': t.deviceId,
    'firmware': backend.uploaded && !backend.wrongVersion ? '9.9.9' : '0.2.0',
    'session': (backend.uploaded ? 'b' : 'a') * 32,
    'busy': false,
  };
  @override
  Future<void> upload(
    FirmwareTarget t,
    FirmwareImage image,
    void Function(int, int) progress,
  ) async {
    backend.uploads++;
    await backend.gate.future;
    if (backend.failUpload) throw const AppFailure('测试上传中断');
    backend.uploaded = true;
    progress(image.length, image.length);
  }

  @override
  void close() {}
}

class _Fixture {
  final backend = _Backend(), broker = FakeBroker(TestClock());
  late ProviderContainer container;
  _Fixture() {
    container = ProviderContainer(
      overrides: [
        connectionStoreProvider.overrideWithValue(FakeStore()),
        transportFactoryProvider.overrideWithValue(() => broker),
        clockProvider.overrideWithValue(TestClock()),
        usbTransportFactoryProvider.overrideWithValue(FakeUsb.new),
        usbTokenStoreProvider.overrideWithValue(FakeUsbTokenStore()),
        firmwareTargetStoreProvider.overrideWithValue(FakeFirmwareStore()),
        firmwareClientFactoryProvider.overrideWithValue(() => _Client(backend)),
        firmwarePickerProvider.overrideWithValue(
          FakeFirmwarePicker(testFirmware()),
        ),
        firmwareDelayProvider.overrideWithValue((_) async {}),
      ],
    );
  }
  FirmwareController get controller =>
      container.read(firmwareProvider.notifier);
  Future<void> start() async {
    await container.read(sessionProvider.notifier).initialize();
    await container.read(sessionProvider.notifier).connect(testProfile);
    await controller.readStatus(target);
    await controller.chooseImage();
  }
}
