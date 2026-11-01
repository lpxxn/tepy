import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tepy_mobile/application/providers.dart';
import 'package:tepy_mobile/application/session_controller.dart';
import 'package:tepy_mobile/application/usb_controller.dart';
import 'package:tepy_mobile/data/connection_store.dart';
import 'package:tepy_mobile/data/mqtt_transport.dart';
import 'package:tepy_mobile/data/usb_transport.dart';
import 'package:tepy_mobile/data/mac_password_store.dart';
import 'package:tepy_mobile/data/firmware_client.dart';
import 'package:tepy_mobile/domain/firmware_image.dart';
import 'package:tepy_mobile/domain/connection_profile.dart';
import 'package:tepy_mobile/domain/snapshots.dart';

const testProfile = ConnectionProfile(
  broker: 'mqtt://127.0.0.1:1883',
  deviceId: 'aabbccddeeff',
  agentId: 'mac-test',
);

/// 测试虚构数据不会连到真实 Broker，也不会使用用户的配置或密码。
final class TestClock implements AppClock {
  TestClock([this.elapsed]);
  final Duration Function()? elapsed;
  int offset = 0;
  @override
  int get tickMs => elapsed?.call().inMilliseconds ?? offset;
  @override
  int get nowMs => 1800000000000 + tickMs;
}

Map<String, dynamic> deviceJson(
  AppClock clock, {
  String session = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  String id = 'aabbccddeeff',
}) => {
  'v': 1,
  'device_id': id,
  'session': session,
  'online': true,
  'time_ready': true,
  'now': clock.nowMs,
  'busy': false,
  'firmware': '0.2.0',
  'wifi': {'ip': '192.0.2.1'},
  'ble': {'ready': true},
  'mqtt': {'connected': true},
};
Map<String, dynamic> macJson(
  AppClock clock, {
  String lock = 'locked',
  int sequence = 1,
  String id = 'mac-test',
}) => {
  'v': 1,
  'agent_id': id,
  'platform': 'darwin',
  'agent_version': '0.1.0',
  'name': 'Tepy Mac',
  'session': 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
  'sequence': sequence,
  'observed_at': clock.nowMs,
  'valid_until': clock.nowMs + 30000,
  'user_session': {
    'available': true,
    'on_console': true,
    'login_done': true,
    'lock_state': lock,
    'lock_source': 'screen_notification',
  },
  'hid': {
    'available': true,
    'state': 'registered',
    'target_device_id': 'aabbccddeeff',
    'devices': [
      {
        'product': 'Tepy-ddeeff',
        'transport': 'Bluetooth Low Energy',
        'registry_id': '0x1234',
      },
    ],
  },
  'power': {
    'state': 'awake',
    'monitoring': true,
    'last_event': 'none',
    'wake_count': 0,
  },
};

final class FakeStore implements ConnectionStore {
  ConnectionProfile? saved = testProfile;
  bool fail = false;
  @override
  Future<ConnectionProfile?> load() async => saved;
  @override
  Future<void> save(ConnectionProfile profile) async {
    if (fail) throw const AppFailure('测试安全存储失败');
    profile.validate();
    saved = profile;
  }

  @override
  Future<void> forget() async {
    saved = null;
  }
}

final class FakeBroker implements BrokerTransport {
  FakeBroker(this.clock);
  final AppClock clock;
  final _events = StreamController<BrokerEvent>.broadcast(sync: true);
  final sent = <Map<String, dynamic>>[];
  ConnectionProfile profile = testProfile;
  String lock = 'locked', session = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  bool autoAck = true, autoReply = true, autoUnlock = false, heartbeat = true;
  bool connectedAfterReturn = false;
  Completer<void>? connectGate;
  int connections = 0, sequence = 0, _packet = 0;
  Timer? _heartbeat;
  @override
  Stream<BrokerEvent> get events => _events.stream;
  @override
  Future<void> connect(ConnectionProfile value) async {
    profile = value;
    connections++;
    if (connectGate != null) await connectGate!.future;
    void connected() {
      _events.add(const BrokerConnected());
      emitDevice();
      emitMac();
    }

    if (connectedAfterReturn) {
      // 真实传输通过异步 Stream 发事件，可能晚于 connect Future 完成。
      Timer.run(connected);
    } else {
      connected();
    }
    if (heartbeat) {
      _heartbeat = Timer.periodic(const Duration(seconds: 5), (_) {
        emitDevice();
        emitMac();
      });
    }
  }

  void emitDevice() => message(
    '${profile.devicePrefix}/state',
    deviceJson(clock, session: session, id: profile.deviceId),
  );
  void emitMac() => message(
    '${profile.agentPrefix}/state',
    macJson(clock, lock: lock, sequence: ++sequence, id: profile.agentId),
  );
  void message(
    String topic,
    Map<String, dynamic> value, {
    bool retained = false,
  }) => _events.add(
    BrokerMessage(
      topic,
      Uint8List.fromList(utf8.encode(jsonEncode(value))),
      retained: retained,
    ),
  );
  void reply(
    String id, {
    bool retained = false,
    String status = 'sent',
    String error = '',
  }) => message('${profile.devicePrefix}/reply', {
    'v': 1,
    'id': id,
    'status': status,
    'error': error,
  }, retained: retained);
  @override
  int publish(String topic, Uint8List bytes) {
    final value = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    sent.add(value);
    final packet = ++_packet;
    scheduleMicrotask(() {
      if (autoAck) _events.add(BrokerPuback(packet));
      if (autoReply) reply(value['id'] as String);
      if (autoUnlock && value['type'] == 'type_text') {
        lock = 'unlocked';
        emitMac();
      }
    });
    return packet;
  }

  void drop() {
    _heartbeat?.cancel();
    _events.add(const BrokerDisconnected());
  }

  @override
  Future<void> disconnect() async {
    _heartbeat?.cancel();
  }

  @override
  Future<void> dispose() async {
    _heartbeat?.cancel();
    await _events.close();
  }
}

final class Harness {
  Harness(AppClock clock) : broker = FakeBroker(clock) {
    container = ProviderContainer(
      overrides: [
        clockProvider.overrideWithValue(clock),
        connectionStoreProvider.overrideWithValue(store),
        transportFactoryProvider.overrideWithValue(() => broker),
      ],
    );
    controller = container.read(sessionProvider.notifier);
  }
  final FakeStore store = FakeStore();
  final FakeBroker broker;
  late final ProviderContainer container;
  late final SessionController controller;
  Future<void> start() async {
    await controller.initialize();
    await controller.connect(testProfile);
  }

  void dispose() => container.dispose();
}

Map<String, dynamic> configJson() => {
  'v': 1,
  'wifi': {'ssid': 'Example-WiFi', 'password_set': true},
  'mqtt': {
    'uri': 'mqtt://192.0.2.1:1883',
    'username': '',
    'password_set': false,
    'ca': '',
  },
  'ntp_server': 'pool.ntp.org',
  'key_delay_ms': 20,
  'admin_password_set': true,
};

final class FakeUsb implements UsbTransport {
  final _events = StreamController<UsbEvent>.broadcast(sync: true);
  final sent = <Map<String, dynamic>>[];
  bool autoReply = true;
  Map<String, dynamic>? statusOverride;
  Future<void>? secretReplyGate;
  @override
  Stream<UsbEvent> get events => _events.stream;
  @override
  Future<List<UsbCandidate>> list() async => [
    const UsbCandidate('1:0', 'Test ESP32', 0x303a, 0x1001),
  ];
  @override
  Future<void> open(String id) async {}
  @override
  Future<void> write(Uint8List bytes) async {
    final value =
        jsonDecode(utf8.decode(bytes).substring(6)) as Map<String, dynamic>;
    sent.add(value);
    if (value['method'] == 'config.secrets.get') await secretReplyGate;
    if (autoReply) {
      scheduleMicrotask(
        () => frame({
          'v': 1,
          'id': value['id'],
          'ok': true,
          'result': switch (value['method']) {
            'config.get' => configJson(),
            'config.secrets.get' => {
              'v': 1,
              'wifi': {'password': 'SavedWifiOnly123'},
              'mqtt': {'password': ''},
              'admin_password': 'ExampleAdminTokenOnly0000',
            },
            _ =>
              statusOverride ??
                  {'v': 1, 'device_id': 'aabbccddeeff', 'firmware': '0.2.0'},
          },
        }),
      );
    }
  }

  void frame(Map<String, dynamic> json) => _events.add(
    UsbBytes(Uint8List.fromList(utf8.encode('@tepy:${jsonEncode(json)}\n'))),
  );
  @override
  Future<void> close() async {}
  @override
  Future<void> dispose() async {
    await _events.close();
  }
}

final class FakeUsbTokenStore implements UsbTokenStore {
  String value = '';
  @override
  Future<String> load() async => value;
  @override
  Future<void> save(String token) async {
    value = token;
  }

  @override
  Future<void> forget() async {
    value = '';
  }
}

Map<String, dynamic> diagnosticJson(
  AppClock clock, {
  String session = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
}) => {
  'v': 1,
  'agent_id': 'mac-test',
  'agent_version': '0.2.0',
  'session': session,
  'source': 'live',
  'observed_at': clock.nowMs,
  'valid_until': clock.nowMs + 30000,
  'status': 'ok',
  'checks': [
    {
      'component': 'agent',
      'status': 'ok',
      'code': 'agent_state_fresh',
      'message': '服务采样正常。',
    },
  ],
};
Map<String, dynamic> historyJson(
  AppClock clock, {
  String session = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
  int count = 3,
}) => {
  'v': 1,
  'agent_id': 'mac-test',
  'session': session,
  'observed_at': clock.nowMs,
  'capacity': 200,
  'oldest_sequence': count == 0 ? 0 : 1,
  'latest_sequence': count,
  'next_after': count,
  'truncated': false,
  'has_more': false,
  'events': [
    for (var i = 1; i <= count; i++)
      {
        'sequence': i,
        'at': clock.nowMs - i * 1000,
        'kind': i % 2 == 0 ? 'screen_unlocked' : 'screen_locked',
        'from': 'unknown',
        'to': i % 2 == 0 ? 'unlocked' : 'locked',
        'code': '',
      },
  ],
};

final class FakeMacPasswords implements MacPasswordStore {
  final values = <String, (String, MacPasswordInfo)>{};
  Completer<void>? readGate;
  Uint8List? returned;
  int reads = 0, saves = 0;
  @override
  Future<String> location() async => '/example-app-data/mac-passwords.json';
  @override
  Future<MacPasswordInfo?> inspect(ConnectionProfile p) async =>
      values[macPasswordTarget(p)]?.$2;
  @override
  Future<Uint8List?> read(ConnectionProfile p) async {
    reads++;
    await readGate?.future;
    final value = values[macPasswordTarget(p)];
    return returned = value == null
        ? null
        : Uint8List.fromList(utf8.encode(value.$1));
  }

  @override
  Future<void> save(
    ConnectionProfile p,
    Uint8List b,
    MacPasswordInfo options,
  ) async {
    values[macPasswordTarget(p)] = (ascii.decode(b), options);
    saves++;
  }

  @override
  Future<void> remove(ConnectionProfile p) async {
    values.remove(macPasswordTarget(p));
  }
}

final class FakeFirmwareStore implements FirmwareTargetStore {
  FirmwareTarget? target;
  @override
  Future<FirmwareTarget?> load() async => target;
  @override
  Future<void> save(FirmwareTarget t) async {
    target = t;
  }

  @override
  Future<void> clear() async {
    target = null;
  }
}

final class FakeFirmwarePicker implements FirmwarePicker {
  FakeFirmwarePicker([this.image]);
  FirmwareImage? image;
  @override
  Future<FirmwareImage?> pick() async => image;
}
