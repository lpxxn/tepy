import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tepy_mobile/domain/commands.dart';
import 'package:tepy_mobile/domain/connection_profile.dart';
import 'package:tepy_mobile/domain/serial_management.dart';
import 'package:tepy_mobile/domain/snapshots.dart';

import 'support/fakes.dart';

void main() {
  test('all printable ASCII; invalid input never becomes a command', () {
    validateText(Uint8List.fromList(List.generate(95, (i) => i + 32)));
    validateText(Uint8List(512)..fillRange(0, 512, 65));
    for (final bytes in [
      Uint8List(0),
      Uint8List.fromList([10]),
      Uint8List.fromList(utf8.encode('中文')),
      Uint8List(513),
    ]) {
      expect(() => validateText(bytes), throwsA(isA<AppFailure>()));
    }
    validateKey('F12', ['GUI']);
    validateKey('/', []);
    expect(() => validateKey('F13', []), throwsA(isA<AppFailure>()));
    expect(() => validateKey('z', ['GUI', 'GUI']), throwsA(isA<AppFailure>()));
  });
  test('command contract and owned buffer cleanup', () {
    final id = requestId();
    expect(id, matches(RegExp(r'^[a-f0-9]{32}$')));
    final wire = encodeCommand(
      id: id,
      session: 'a' * 32,
      nowMs: 1800000000000,
      type: 'wake',
      payload: {},
    );
    final json = jsonDecode(utf8.decode(wire)) as Map;
    expect(
      json.keys,
      unorderedEquals(['v', 'id', 'session', 'expires_at', 'type', 'payload']),
    );
    expect(json['expires_at'], 1800000010000);
    wipe(wire);
    expect(wire.every((c) => c == 0), true);
  });
  test(
    'profile rejects URL credentials, unpaired keys and future versions',
    () {
      for (final broker in [
        'http://host',
        'mqtt://user:private@host',
        'mqtt://host/path',
        'mqtt://host:0',
      ]) {
        try {
          ConnectionProfile(broker: broker).validate();
          fail('accepted invalid URL');
        } on AppFailure catch (error) {
          expect(error.message, isNot(contains('private')));
        }
      }
      expect(
        () => const ConnectionProfile(clientKeyPem: 'key').validate(),
        throwsA(isA<AppFailure>()),
      );
      expect(
        () => const ConnectionProfile(caPem: 'CA').validate(),
        throwsA(isA<AppFailure>()),
      );
      expect(
        () => ConnectionProfile.fromStorageJson({
          ...testProfile.toStorageJson(),
          'v': 2,
        }),
        throwsA(isA<AppFailure>()),
      );
      expect(testProfile.toStorageJson().keys, isNot(contains('mac_password')));
    },
  );
  test('device lease and unknown Mac state are explicit', () {
    final clock = TestClock();
    final json = deviceJson(clock);
    expect(
      DeviceSnapshot.parse(json, 'aabbccddeeff', clock)?.ready(clock),
      true,
    );
    expect(
      DeviceSnapshot.parse(
        {...json, 'now': clock.nowMs - 16000},
        'aabbccddeeff',
        clock,
      ),
      isNull,
    );
    expect(
      DeviceSnapshot.parse(
        {...json, 'now': clock.nowMs + 6000},
        'aabbccddeeff',
        clock,
      ),
      isNull,
    );
    final mac = macJson(clock, lock: 'unknown');
    expect(MacSnapshot.parse(mac, 'mac-test', clock)?.lock, LockState.unknown);
    expect(MacSnapshot.parse(mac, 'wrong-mac', clock), isNull);
    expect(
      MacSnapshot.parse(
        {...mac, 'valid_until': clock.nowMs + 190000},
        'mac-test',
        clock,
      ),
      isNull,
    );
  });
  test('configuration keeps, replaces and clears distinctly', () {
    Map<String, Object> patch({
      PasswordPolicy wifi = PasswordPolicy.keep,
      PasswordPolicy mqtt = PasswordPolicy.keep,
    }) => deviceConfigPatch(
      ssid: 'Example',
      mqttUri: 'mqtt://192.0.2.1:1883',
      mqttUsername: '',
      ntp: 'pool.ntp.org',
      keyDelay: 20,
      ca: '',
      wifiPolicy: wifi,
      wifiPassword: 'EXAMPLE-ONLY',
      mqttPolicy: mqtt,
      mqttPassword: 'EXAMPLE-ONLY',
    );
    expect((patch()['wifi'] as Map).containsKey('password'), false);
    expect((patch(wifi: PasswordPolicy.clear)['wifi'] as Map)['password'], '');
    expect(
      (patch(mqtt: PasswordPolicy.replace)['mqtt'] as Map)['password'],
      'EXAMPLE-ONLY',
    );
    expect(
      () => deviceConfigPatch(
        ssid: '中' * 11,
        mqttUri: '',
        mqttUsername: '',
        ntp: 'pool.ntp.org',
        keyDelay: 20,
        ca: '',
      ),
      throwsA(isA<AppFailure>()),
    );
  });
}
