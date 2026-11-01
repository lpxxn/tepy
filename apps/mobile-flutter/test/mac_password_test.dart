import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tepy_mobile/application/mac_password_controller.dart';
import 'package:tepy_mobile/application/providers.dart';
import 'package:tepy_mobile/data/mac_password_store.dart';
import 'package:tepy_mobile/domain/connection_profile.dart';

import 'support/fakes.dart';

void main() {
  test(
    'plaintext JSON is editable, isolated by target and atomically updated',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'tepy-password-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/mac-passwords.json'),
          store = JsonMacPasswordStore(file: () async => file);
      final input = Uint8List.fromList(ascii.encode('ExampleOnly!'));
      await store.save(testProfile, input, const MacPasswordInfo());
      expect(await file.readAsString(), contains('ExampleOnly!'));
      expect((await store.inspect(testProfile))!.enter, true);
      const other = ConnectionProfile(
        broker: 'mqtt://another.example:1883',
        deviceId: 'aabbccddeeff',
        agentId: 'mac-test',
      );
      expect(await store.read(other), isNull);
      await store.save(
        other,
        Uint8List.fromList(ascii.encode('SecondExample!')),
        const MacPasswordInfo(enter: false, waitSeconds: 5),
      );
      final json =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      (json['profiles'] as List)[0]['password'] = 'EditedExample!';
      await file.writeAsString(jsonEncode(json));
      expect(ascii.decode((await store.read(testProfile))!), 'EditedExample!');
      await store.remove(testProfile);
      expect(await store.inspect(testProfile), isNull);
      expect(ascii.decode((await store.read(other))!), 'SecondExample!');
      expect(await File('${file.path}.tmp').exists(), false);
    },
  );
  test(
    'invalid local JSON is retained and cannot send unsupported characters',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'tepy-password-invalid-',
      );
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/mac-passwords.json');
      await file.writeAsString('{broken JSON');
      final store = JsonMacPasswordStore(file: () async => file);
      await expectLater(
        store.save(
          testProfile,
          Uint8List.fromList(ascii.encode('ExampleOnly!')),
          const MacPasswordInfo(),
        ),
        throwsA(isA<AppFailure>()),
      );
      expect(await file.readAsString(), '{broken JSON');
      await file.delete();
      await expectLater(
        store.save(
          testProfile,
          Uint8List.fromList(utf8.encode('中文')),
          const MacPasswordInfo(),
        ),
        throwsA(isA<AppFailure>()),
      );
      expect(await file.exists(), false);
    },
  );
  test(
    'saved password is used once and typed buffers are cleared',
    () => fakeAsync((async) {
      final clock = TestClock(() => async.elapsed),
          broker = FakeBroker(TestClock(() => async.elapsed)),
          store = FakeMacPasswords();
      broker.autoUnlock = true;
      final container = ProviderContainer(
        overrides: [
          clockProvider.overrideWithValue(clock),
          transportFactoryProvider.overrideWithValue(() => broker),
          connectionStoreProvider.overrideWithValue(FakeStore()),
          macPasswordStoreProvider.overrideWithValue(store),
        ],
      );
      addTearDown(container.dispose);
      final controller = container.read(sessionProvider.notifier);
      unawaited(
        store.save(
          testProfile,
          Uint8List.fromList(ascii.encode('ExampleOnly!')),
          const MacPasswordInfo(),
        ),
      );
      unawaited(controller.initialize());
      async.flushMicrotasks();
      unawaited(controller.connect(testProfile));
      async.flushMicrotasks();
      unawaited(controller.unlockSaved());
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 10));
      async.flushMicrotasks();
      expect(broker.sent.where((c) => c['type'] == 'type_text'), hasLength(1));
      expect(broker.sent.last['payload']['text'], 'ExampleOnly!');
      expect(store.returned!.every((b) => b == 0), true);
      expect(container.read(sessionProvider).preparingInput, false);
      expect(store.saves, 1);
    }),
  );
  test(
    'background cancels a pending saved password read before any key is sent',
    () => fakeAsync((async) {
      final clock = TestClock(() => async.elapsed),
          broker = FakeBroker(TestClock(() => async.elapsed)),
          store = FakeMacPasswords();
      store.readGate = Completer<void>();
      final container = ProviderContainer(
        overrides: [
          clockProvider.overrideWithValue(clock),
          transportFactoryProvider.overrideWithValue(() => broker),
          connectionStoreProvider.overrideWithValue(FakeStore()),
          macPasswordStoreProvider.overrideWithValue(store),
        ],
      );
      addTearDown(container.dispose);
      final controller = container.read(sessionProvider.notifier);
      unawaited(
        store.save(
          testProfile,
          Uint8List.fromList(ascii.encode('ExampleOnly!')),
          const MacPasswordInfo(),
        ),
      );
      unawaited(controller.initialize());
      async.flushMicrotasks();
      unawaited(controller.connect(testProfile));
      async.flushMicrotasks();
      unawaited(controller.unlockSaved());
      async.flushMicrotasks();
      expect(container.read(sessionProvider).preparingInput, true);
      unawaited(controller.disconnect(background: true));
      async.flushMicrotasks();
      store.readGate!.complete();
      async.flushMicrotasks();
      expect(broker.sent, isEmpty);
      expect(store.returned!.every((b) => b == 0), true);
      expect(container.read(sessionProvider).preparingInput, false);
    }),
  );
}
