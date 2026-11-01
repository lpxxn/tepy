import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tepy_mobile/application/providers.dart';
import 'package:tepy_mobile/domain/agent_observations.dart';

import 'support/fakes.dart';

void main() {
  test('diagnostics validate summary, identity, live source and lease', () {
    final clock = TestClock();
    expect(
      AgentDiagnostics.parse(diagnosticJson(clock), 'mac-test', clock),
      isNotNull,
    );
    for (final change in <Map<String, dynamic>>[
      {'agent_id': 'other'},
      {'source': 'doctor'},
      {'session': 'invalid'},
      {'valid_until': clock.nowMs - 1},
      {'status': 'error'},
      {
        'checks': [
          {
            'component': 'agent',
            'status': 'error',
            'code': 'agent_state_stale',
            'message': 'expired',
          },
        ],
      },
    ]) {
      expect(
        AgentDiagnostics.parse(
          {...diagnosticJson(clock), ...change},
          'mac-test',
          clock,
        ),
        isNull,
      );
    }
  });
  test(
    'history is bounded, sorted and cannot carry invalid dates or kinds',
    () {
      final clock = TestClock();
      expect(
        AgentHistory.parse(historyJson(clock, count: 200), 'mac-test')!.events,
        hasLength(200),
      );
      for (final count in [201, 202]) {
        expect(
          AgentHistory.parse(historyJson(clock, count: count), 'mac-test'),
          isNull,
        );
      }
      final invalid = historyJson(clock);
      (invalid['events'] as List)[1]['sequence'] = 1;
      expect(AgentHistory.parse(invalid, 'mac-test'), isNull);
      final date = historyJson(clock);
      (date['events'] as List)[0]['at'] = 9223372036854775807;
      expect(AgentHistory.parse(date, 'mac-test'), isNull);
      expect(
        AgentHistory.parse({
          ...historyJson(clock),
          'session': 'bad',
        }, 'mac-test'),
        isNull,
      );
    },
  );
  test(
    'new observations can arrive before state and cannot cross agent sessions',
    () async {
      final clock = TestClock(), broker = FakeBroker(TestClock());
      final container = ProviderContainer(
        overrides: [
          clockProvider.overrideWithValue(clock),
          transportFactoryProvider.overrideWithValue(() => broker),
          connectionStoreProvider.overrideWithValue(FakeStore()),
        ],
      );
      addTearDown(container.dispose);
      final controller = container.read(sessionProvider.notifier);
      await controller.initialize();
      await controller.connect(testProfile);
      broker.message(
        '${testProfile.agentPrefix}/diagnostics',
        diagnosticJson(clock),
      );
      broker.message(
        '${testProfile.agentPrefix}/events',
        historyJson(clock, count: 200),
      );
      expect(container.read(sessionProvider).history!.events, hasLength(200));
      const newer = 'cccccccccccccccccccccccccccccccc';
      broker.message(
        '${testProfile.agentPrefix}/events',
        historyJson(clock, session: newer),
      );
      expect(container.read(sessionProvider).history!.events, hasLength(200));
      broker.message('${testProfile.agentPrefix}/state', {
        ...macJson(clock, sequence: 9),
        'session': newer,
      });
      expect(container.read(sessionProvider).history!.session, newer);
      expect(container.read(sessionProvider).diagnostics, isNull);
      broker.message(
        '${testProfile.agentPrefix}/diagnostics',
        diagnosticJson(clock, session: newer),
      );
      expect(container.read(sessionProvider).diagnostics!.session, newer);
      await controller.disconnect();
      expect(container.read(sessionProvider).history, isNull);
      expect(container.read(sessionProvider).diagnostics, isNull);
    },
  );
}
