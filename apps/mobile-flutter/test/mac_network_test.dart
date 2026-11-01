import 'package:flutter_test/flutter_test.dart';
import 'package:tepy_mobile/domain/mac_network.dart';
import 'package:tepy_mobile/domain/snapshots.dart';

import 'support/fakes.dart';

void main() {
  Map<String, dynamic> network(String ip, {String family = 'ipv4'}) => {
    'available': true,
    'addresses': [
      {'interface': 'en0', 'ip': ip, 'family': family},
    ],
  };
  test(
    'network validates numeric IPv4 and IPv6 and keeps interface labels',
    () {
      final value = MacNetwork.parse(network('192.168.50.90'))!;
      expect(value.addresses.single.interfaceName, 'en0');
      expect(value.addresses.single.ip, '192.168.50.90');
      expect(
        MacNetwork.parse(network('2001:db8::1', family: 'ipv6')),
        isNotNull,
      );
      expect(() => value.addresses.clear(), throwsUnsupportedError);
      for (final ip in [
        'mac.local',
        'http://192.168.50.90',
        '192.168.50.90/24',
        '127.0.0.1',
        '0.0.0.0',
        '169.254.1.2',
        '224.0.0.1',
      ]) {
        expect(MacNetwork.parse(network(ip)), isNull, reason: ip);
      }
      expect(MacNetwork.parse(network('2001:db8::1')), isNull);
      expect(MacNetwork.parse(network('fe80::1', family: 'ipv6')), isNull);
      expect(MacNetwork.parse(network('::', family: 'ipv6')), isNull);
      final duplicate = network('192.168.50.90');
      (duplicate['addresses'] as List).add(
        (duplicate['addresses'] as List).first,
      );
      expect(MacNetwork.parse(duplicate), isNull);
    },
  );
  test('legacy or malformed network does not invalidate keyboard state', () {
    final clock = TestClock();
    final json = macJson(clock);
    expect(MacSnapshot.parse(json, 'mac-test', clock)?.network, isNull);
    json['network'] = {'available': true, 'addresses': 'invalid'};
    final snapshot = MacSnapshot.parse(json, 'mac-test', clock)!;
    expect(snapshot.network, isNull);
    expect(snapshot.inputEligible('aabbccddeeff'), true);
    json['network'] = network('192.168.50.90');
    expect(
      MacSnapshot.parse(json, 'mac-test', clock)?.network?.addresses.single.ip,
      '192.168.50.90',
    );
  });
}
