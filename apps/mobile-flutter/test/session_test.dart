import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tepy_mobile/application/providers.dart';
import 'package:tepy_mobile/application/session_state.dart';
import 'package:tepy_mobile/domain/connection_profile.dart';

import 'support/fakes.dart';

void main() {
  test(
    'quick connect uses saved profile after temporary connection and forget',
    () => fakeAsync((async) {
      final h = Harness(TestClock(() => async.elapsed));
      addTearDown(h.dispose);
      unawaited(h.controller.initialize());
      async.flushMicrotasks();
      expect(h.broker.connections, 0);
      expect(h.container.read(sessionProvider).savedProfile, testProfile);
      const temporary = ConnectionProfile(
        broker: 'mqtt://temporary.example:1883',
        deviceId: 'aabbccddeeff',
        agentId: 'mac-test',
      );
      unawaited(h.controller.connect(temporary));
      async.flushMicrotasks();
      unawaited(h.controller.disconnect());
      async.flushMicrotasks();
      unawaited(h.controller.connectSaved());
      unawaited(h.controller.connectSaved());
      async.flushMicrotasks();
      expect(h.broker.connections, 2);
      expect(h.broker.profile, testProfile);
      unawaited(h.controller.disconnect());
      async.flushMicrotasks();
      h.store.fail = true;
      unawaited(h.controller.save(temporary));
      async.flushMicrotasks();
      expect(h.container.read(sessionProvider).savedProfile, testProfile);
      h.store.fail = false;
      unawaited(h.controller.forget());
      async.flushMicrotasks();
      expect(h.container.read(sessionProvider).savedProfile, isNull);
      unawaited(h.controller.connectSaved());
      async.flushMicrotasks();
      expect(h.broker.connections, 2);
      expect(h.container.read(sessionProvider).message, contains('先在连接页保存'));
      unawaited(h.controller.save(temporary));
      async.flushMicrotasks();
      expect(h.container.read(sessionProvider).savedProfile, temporary);
      unawaited(h.controller.connectSaved());
      async.flushMicrotasks();
      expect(h.broker.connections, 3);
      expect(h.broker.profile, temporary);
    }),
  );
  test(
    'late connected event must cancel scheduled retry and keep unlock alive',
    () => fakeAsync((async) {
      final h = Harness(TestClock(() => async.elapsed));
      addTearDown(h.dispose);
      h.broker.connectedAfterReturn = true;
      h.broker.autoUnlock = true;
      unawaited(h.start());
      async.flushMicrotasks();
      async.elapse(Duration.zero);
      expect(h.container.read(sessionProvider).link, LinkState.online);
      final input = Uint8List.fromList('ExampleOnly!'.codeUnits);
      unawaited(h.controller.unlock(input, waitSeconds: 3, enter: true));
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 8));
      async.flushMicrotasks();
      expect(h.broker.connections, 1, reason: '已经连接，迟到事件之前安排的重试不能重建连接');
      expect(h.broker.sent.map((c) => c['type']), ['wake', 'type_text']);
      expect(h.container.read(sessionProvider).macResult, 'Mac 报告已解锁');
    }),
  );
  test(
    'wake + post-wake Mac state + single input + observed unlock',
    () => fakeAsync((async) {
      final h = Harness(TestClock(() => async.elapsed));
      addTearDown(h.dispose);
      h.broker.autoUnlock = true;
      unawaited(h.start());
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 1));
      final bytes = Uint8List.fromList('ExampleOnly!'.codeUnits);
      unawaited(h.controller.unlock(bytes, waitSeconds: 0, enter: true));
      async.flushMicrotasks();
      expect(h.broker.sent.length, 1); // 旧的 retained locked 不能触发密码。
      async.elapse(const Duration(seconds: 5));
      async.flushMicrotasks();
      expect(h.broker.sent.map((c) => c['type']), ['wake', 'type_text']);
      final state = h.container.read(sessionProvider);
      expect(state.busy, false);
      expect(state.macResult, 'Mac 报告已解锁');
      expect(bytes.every((c) => c == 0), true);
    }),
  );
  test(
    'unknown Mac expires without input or retry',
    () => fakeAsync((async) {
      final h = Harness(TestClock(() => async.elapsed));
      addTearDown(h.dispose);
      h.broker.lock = 'unknown';
      unawaited(h.start());
      async.flushMicrotasks();
      final bytes = Uint8List.fromList('ExampleOnly!'.codeUnits);
      unawaited(h.controller.unlock(bytes, waitSeconds: 0));
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 21));
      async.flushMicrotasks();
      expect(h.broker.sent.length, 1);
      expect(h.container.read(sessionProvider).busy, false);
      expect(bytes.every((c) => c == 0), true);
    }),
  );
  test(
    'already unlocked and invalid characters never wake',
    () => fakeAsync((async) {
      final h = Harness(TestClock(() => async.elapsed));
      addTearDown(h.dispose);
      h.broker.lock = 'unlocked';
      unawaited(h.start());
      async.flushMicrotasks();
      unawaited(
        h.controller.unlock(Uint8List.fromList('ExampleOnly!'.codeUnits)),
      );
      async.flushMicrotasks();
      unawaited(h.controller.typeText(Uint8List.fromList([255])));
      async.flushMicrotasks();
      expect(h.broker.sent, isEmpty);
    }),
  );
  test(
    'disconnect cancels, foreground reconnect never replays',
    () => fakeAsync((async) {
      final h = Harness(TestClock(() => async.elapsed));
      addTearDown(h.dispose);
      h.broker.autoReply = false;
      unawaited(h.start());
      async.flushMicrotasks();
      final bytes = Uint8List.fromList('ExampleOnly!'.codeUnits);
      unawaited(h.controller.typeText(bytes));
      async.flushMicrotasks();
      h.broker.drop();
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 3));
      async.flushMicrotasks();
      expect(h.broker.connections, 2);
      expect(h.broker.sent.length, 1);
      expect(h.container.read(sessionProvider).busy, false);
      expect(bytes.every((c) => c == 0), true);
    }),
  );
  test(
    'wrong / retained / duplicate reply cannot complete current action',
    () => fakeAsync((async) {
      final h = Harness(TestClock(() => async.elapsed));
      addTearDown(h.dispose);
      h.broker.autoReply = false;
      unawaited(h.start());
      async.flushMicrotasks();
      unawaited(h.controller.wake());
      async.flushMicrotasks();
      final id = h.broker.sent.single['id'] as String;
      h.broker.reply('old-id');
      h.broker.reply(id, retained: true);
      async.flushMicrotasks();
      expect(h.container.read(sessionProvider).busy, true);
      h.broker.reply(id);
      async.flushMicrotasks();
      h.broker.reply(id);
      async.flushMicrotasks();
      expect(h.container.read(sessionProvider).hidResult, 'HID 发送完成');
      expect(h.broker.sent.length, 1);
    }),
  );
  test(
    'session change cancels waiting password immediately',
    () => fakeAsync((async) {
      final h = Harness(TestClock(() => async.elapsed));
      addTearDown(h.dispose);
      unawaited(h.start());
      async.flushMicrotasks();
      final bytes = Uint8List.fromList('ExampleOnly!'.codeUnits);
      unawaited(h.controller.unlock(bytes, waitSeconds: 3));
      async.flushMicrotasks();
      h.broker.session = 'c' * 32;
      h.broker.emitDevice();
      async.flushMicrotasks();
      expect(bytes.every((c) => c == 0), true);
      async.elapse(const Duration(seconds: 5));
      expect(h.broker.sent.length, 1);
      expect(h.container.read(sessionProvider).busy, false);
    }),
  );
  test(
    'cancel still bounds an unacknowledged packet; no replay after timeout',
    () => fakeAsync((async) {
      final h = Harness(TestClock(() => async.elapsed));
      addTearDown(h.dispose);
      h.broker.autoAck = h.broker.autoReply = false;
      unawaited(h.start());
      async.flushMicrotasks();
      unawaited(h.controller.wake());
      async.flushMicrotasks();
      h.controller.cancel();
      async.flushMicrotasks();
      expect(h.container.read(sessionProvider).awaitingPuback, true);
      async.elapse(const Duration(seconds: 8));
      async.flushMicrotasks();
      expect(h.broker.connections, 2);
      expect(h.broker.sent.length, 1);
    }),
  );
  test(
    'background suspends retry and never resumes a task',
    () => fakeAsync((async) {
      final h = Harness(TestClock(() => async.elapsed));
      addTearDown(h.dispose);
      unawaited(h.start());
      async.flushMicrotasks();
      unawaited(h.controller.disconnect(background: true));
      async.flushMicrotasks();
      async.elapse(const Duration(minutes: 1));
      async.flushMicrotasks();
      expect(h.broker.connections, 1);
      expect(h.container.read(sessionProvider).link, LinkState.offline);
    }),
  );
}
