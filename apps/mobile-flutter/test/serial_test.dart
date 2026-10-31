import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tepy_mobile/domain/connection_profile.dart';
import 'package:tepy_mobile/domain/serial_management.dart';

import 'support/fakes.dart';

void main() {
  test('configuration rejects zero, large and overflowing ports safely', () {
    for (final port in ['0', '65536', '999999999999999999999999999999']) {
      expect(
        () => deviceConfigPatch(
          ssid: 'Example',
          mqttUri: 'mqtt://example.test:$port',
          mqttUsername: '',
          ntp: 'pool.ntp.org',
          keyDelay: 20,
          ca: '',
        ),
        throwsA(isA<AppFailure>()),
      );
    }
  });
  test(
    'frame splitting, joined messages, boot logs, CRLF and oversized recovery',
    () {
      final frames = <Map<String, dynamic>>[];
      final decoder = SerialFrameDecoder(frames.add);
      addTearDown(decoder.dispose);
      decoder.add(
        Uint8List.fromList(utf8.encode('Admin token: DO-NOT-EXPOSE\n@tep')),
      );
      decoder.add(
        Uint8List.fromList(utf8.encode('y:{"v":1}\r\n@tepy:{"v":2}\n')),
      );
      expect(frames.map((f) => f['v']), [1, 2]);
      decoder.add(
        Uint8List.fromList(
          utf8.encode('@tepy:${'x' * 21000}\n@tepy:{"v":3}\n'),
        ),
      );
      expect(frames.last['v'], 3);
      expect(frames.length, 3);
    },
  );
  test(
    'half frame timeout clears parser',
    () => fakeAsync((async) {
      final frames = <Map<String, dynamic>>[];
      final decoder = SerialFrameDecoder(frames.add);
      decoder.add(Uint8List.fromList(utf8.encode('@tepy:{')));
      async.elapse(const Duration(seconds: 6));
      decoder.add(Uint8List.fromList(utf8.encode('@tepy:{"v":1}\n')));
      expect(frames.length, 1);
      decoder.dispose();
    }),
  );
  test('USB request carries token and matches only its reply id', () async {
    final usb = FakeUsb();
    final client = SerialManagement(usb);
    addTearDown(client.dispose);
    await client.connect('1:0', 'ExampleAdminTokenOnly0000');
    final result = await client.request('config.get');
    expect(result['v'], 1);
    expect(usb.sent.single['token'], 'ExampleAdminTokenOnly0000');
    expect(usb.sent.single['method'], 'config.get');
    expect(usb.sent.single['params'], isEmpty);
    expect(() => client.request('type_text'), throwsA(isA<AppFailure>()));
  });
  test(
    'wrong id ignored and expired operation never resends',
    () => fakeAsync((async) {
      final usb = FakeUsb()..autoReply = false;
      final client = SerialManagement(usb);
      unawaited(client.connect('1:0', 'ExampleAdminTokenOnly0000'));
      async.flushMicrotasks();
      var failed = false;
      unawaited(
        client
            .request('status.get')
            .then(
              (_) {},
              onError: (Object _) {
                failed = true;
              },
            ),
      );
      async.flushMicrotasks();
      usb.frame({'v': 1, 'id': 'old-id', 'ok': true, 'result': {}});
      expect(failed, false);
      async.elapse(const Duration(seconds: 16));
      async.flushMicrotasks();
      expect(failed, true);
      expect(usb.sent.length, 1);
      unawaited(client.dispose());
      async.flushMicrotasks();
    }),
  );
}
