import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tepy_mobile/application/providers.dart';
import 'package:tepy_mobile/application/session_state.dart';
import 'package:tepy_mobile/domain/snapshots.dart';
import 'package:tepy_mobile/data/mqtt_transport.dart';
import 'package:tepy_mobile/domain/connection_profile.dart';

import 'support/fakes.dart';

/// 使用真实 mqtt_client 与本机最小 MQTT 3.1.1 测试端点，避免 FakeBroker
/// 与业务代码“互相同意”却漏掉线上订阅、retain 或 PUBACK 语义。
void main() {
  test(
    'real MQTT event ordering keeps one connection and fresh statuses',
    () async {
      final broker = await _WireBroker.start();
      final client = DartMqttTransport(), clock = SystemClock();
      final container = ProviderContainer(
        overrides: [
          connectionStoreProvider.overrideWithValue(FakeStore()),
          clockProvider.overrideWithValue(clock),
          transportFactoryProvider.overrideWithValue(() => client),
        ],
      );
      final controller = container.read(sessionProvider.notifier);
      final seen = <LinkState>[];
      final listener = container.listen(
        sessionProvider.select((s) => s.link),
        (_, next) => seen.add(next),
      );
      addTearDown(() async {
        listener.close();
        await controller.disconnect();
        container.dispose();
        await broker.dispose();
      });
      await controller.initialize();
      await controller.connect(
        ConnectionProfile(
          broker: 'mqtt://127.0.0.1:${broker.server.port}',
          deviceId: 'aabbccddeeff',
          agentId: 'mac-test',
        ),
      );
      // 让真实异步 Stream 投递连接通知，然后观察超过原先一秒重试的期限。
      await Future<void>.delayed(const Duration(milliseconds: 20));
      broker.publish('tepy/aabbccddeeff/state', jsonEncode(deviceJson(clock)));
      broker.publish('tepy/macos/mac-test/state', jsonEncode(macJson(clock)));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(container.read(sessionProvider).canAct, true);
      seen.clear();
      await Future<void>.delayed(const Duration(seconds: 3));
      expect(broker.connections, 1);
      expect(seen, isEmpty, reason: '稳定连接不能再次切入重连状态');
      expect(container.read(sessionProvider).canAct, true);
      expect(container.read(sessionProvider).mac, isNotNull);
    },
  );
  test(
    'real MQTT wire: clean session, exact subscriptions, QoS1 and PUBACK',
    () async {
      final broker = await _WireBroker.start();
      final client = DartMqttTransport();
      final events = <BrokerEvent>[];
      final sub = client.events.listen(events.add);
      addTearDown(() async {
        await client.dispose();
        await sub.cancel();
        await broker.dispose();
      });
      final connected = client.events.firstWhere((e) => e is BrokerConnected);
      await client.connect(
        ConnectionProfile(
          broker: 'mqtt://127.0.0.1:${broker.server.port}',
          deviceId: 'aabbccddeeff',
          agentId: 'mac-test',
          username: 'ExampleUser',
          password: 'ExamplePasswordOnly',
        ),
      );
      await connected.timeout(const Duration(seconds: 2));
      expect(broker.connectBody[6], 4); // MQTT 协议级别 4 = 3.1.1。
      expect(broker.connectBody[7] & 2, 2); // clean session。
      expect(broker.connectBody[7] & 0xc0, 0xc0); // 用户名、密码标志。
      expect(broker.topics.toSet(), {
        'tepy/aabbccddeeff/state',
        'tepy/aabbccddeeff/reply',
        'tepy/macos/mac-test/state',
        'tepy/macos/mac-test/availability',
      });
      final received = client.events.where((e) => e is BrokerMessage).first;
      broker.publish('tepy/aabbccddeeff/state', '{"v":1}', retained: true);
      final message =
          await received.timeout(const Duration(seconds: 2)) as BrokerMessage;
      expect(message.retained, true);
      expect(utf8.decode(message.bytes), '{"v":1}');
      final acknowledged = client.events.where((e) => e is BrokerPuback).first;
      final id = client.publish(
        'tepy/aabbccddeeff/cmd',
        Uint8List.fromList(utf8.encode('{"type":"wake"}')),
      );
      final ack = await acknowledged.timeout(
        const Duration(seconds: 2),
      ) as BrokerPuback;
      expect(ack.packetId, id);
      expect(broker.lastPublishHeader & 0xf, 2); // QoS1，retain=false，dup=false。
      expect(broker.lastPublishTopic, 'tepy/aabbccddeeff/cmd');
      expect(broker.lastPublishBody, '{"type":"wake"}');
      expect(events.whereType<BrokerConnected>(), hasLength(1));
    },
  );
}

final class _WireBroker {
  _WireBroker(this.server) {
    _accept = server.listen((socket) {
      connections++;
      _socket = socket;
      _read = socket.listen(_bytes, onError: (Object _) {});
    });
  }
  static Future<_WireBroker> start() async =>
      _WireBroker(await ServerSocket.bind(InternetAddress.loopbackIPv4, 0));
  final ServerSocket server;
  StreamSubscription<Socket>? _accept;
  StreamSubscription<Uint8List>? _read;
  Socket? _socket;
  final _buffer = <int>[];
  final topics = <String>[];
  List<int> connectBody = [];
  int lastPublishHeader = 0;
  String lastPublishTopic = '', lastPublishBody = '';
  int connections = 0;

  void _bytes(Uint8List bytes) {
    _buffer.addAll(bytes);
    while (_buffer.length >= 2) {
      var remaining = 0, multiplier = 1, offset = 1;
      while (true) {
        if (offset >= _buffer.length) return;
        final digit = _buffer[offset++];
        remaining += (digit & 127) * multiplier;
        if (digit & 128 == 0) break;
        multiplier *= 128;
      }
      if (_buffer.length < offset + remaining) return;
      final header = _buffer.first,
          body = _buffer.sublist(offset, offset + remaining);
      _buffer.removeRange(0, offset + remaining);
      switch (header >> 4) {
        case 1:
          connectBody = body;
          _socket!.add([0x20, 2, 0, 0]);
        case 8:
          var index = 2;
          final granted = <int>[];
          while (index < body.length) {
            final length = body[index] * 256 + body[index + 1];
            index += 2;
            topics.add(utf8.decode(body.sublist(index, index + length)));
            index += length;
            expect(body[index++], 1);
            granted.add(1);
          }
          _socket!.add([
            0x90,
            2 + granted.length,
            body[0],
            body[1],
            ...granted,
          ]);
        case 3:
          lastPublishHeader = header;
          final length = body[0] * 256 + body[1];
          lastPublishTopic = utf8.decode(body.sublist(2, 2 + length));
          lastPublishBody = utf8.decode(body.sublist(4 + length));
          _socket!.add([0x40, 2, body[2 + length], body[3 + length]]);
        case 12:
          _socket!.add([0xd0, 0]);
      }
    }
  }

  void publish(String topic, String payload, {bool retained = false}) {
    final name = utf8.encode(topic), data = utf8.encode(payload);
    final body = [name.length >> 8, name.length & 255, ...name, ...data];
    final length = <int>[];
    var remaining = body.length;
    do {
      var digit = remaining % 128;
      remaining ~/= 128;
      if (remaining > 0) digit |= 128;
      length.add(digit);
    } while (remaining > 0);
    _socket!.add([retained ? 0x31 : 0x30, ...length, ...body]);
  }

  Future<void> dispose() async {
    await _read?.cancel();
    _socket?.destroy();
    await _accept?.cancel();
    await server.close();
  }
}
