import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

import '../domain/commands.dart';
import '../domain/connection_profile.dart';

/// sealed 限定事件子类只能在本文件声明。控制器可以用 switch 穷尽处理这些情况。
sealed class BrokerEvent {
  const BrokerEvent();
}

final class BrokerConnected extends BrokerEvent {
  const BrokerConnected();
}

final class BrokerDisconnected extends BrokerEvent {
  const BrokerDisconnected();
}

final class BrokerMessage extends BrokerEvent {
  const BrokerMessage(this.topic, this.bytes, {required this.retained});
  final String topic;
  final Uint8List bytes;
  final bool retained;
}

final class BrokerPuback extends BrokerEvent {
  const BrokerPuback(this.packetId);
  final int packetId;
}

/// 业务代码只依赖这个接口，不直接操作第三方 MQTT Client。
abstract interface class BrokerTransport {
  Stream<BrokerEvent> get events;
  Future<void> connect(ConnectionProfile profile);
  int publish(String topic, Uint8List bytes);
  Future<void> disconnect();
  Future<void> dispose();
}

final class DartMqttTransport implements BrokerTransport {
  // broadcast 允许测试探针和业务控制器同时监听，但消息仍只由业务层执行校验。
  final _events = StreamController<BrokerEvent>.broadcast();
  MqttServerClient? _client;
  StreamSubscription<List<MqttReceivedMessage<MqttMessage>>>? _messages;
  StreamSubscription<MqttPublishMessage>? _published;
  Completer<void>? _subscriptionGate;
  bool _disposed = false;

  @override
  Stream<BrokerEvent> get events => _events.stream;

  @override
  Future<void> connect(ConnectionProfile profile) async {
    final uri = profile.validate();
    await disconnect();
    if (_disposed) throw const AppFailure('连接已关闭。');
    final client = MqttServerClient.withPort(
      uri.host,
      'tepy-mobile-${requestId()}',
      uri.hasPort ? uri.port : (uri.scheme == 'mqtts' ? 8883 : 1883),
      maxConnectionAttempts: 1,
    );
    _client = client;
    client
      ..logging(on: false)
      ..setProtocolV311()
      ..autoReconnect = false
      ..resubscribeOnAutoReconnect = false
      ..keepAlivePeriod = 15
      ..disconnectOnNoResponsePeriod = 5
      ..connectionTimeout = 8000
      ..connectTimeoutPeriod = 4000
      ..connectionMessage = (MqttConnectMessage()
          .withClientIdentifier(client.clientIdentifier)
          .startClean());
    try {
      if (uri.scheme == 'mqtts') {
        // 从系统根证书开始，自定义 CA 是补充，不是“跳过校验”。
        final context = SecurityContext(withTrustedRoots: true)
          ..minimumTlsProtocolVersion = TlsProtocolVersion.tls1_2;
        if (profile.caPem.isNotEmpty) {
          context.setTrustedCertificatesBytes(utf8.encode(profile.caPem));
        }
        if (profile.clientCertificatePem.isNotEmpty) {
          context.useCertificateChainBytes(
            utf8.encode(profile.clientCertificatePem),
          );
          context.usePrivateKeyBytes(utf8.encode(profile.clientKeyPem));
        }
        client
          ..secure = true
          ..securityContext = context;
        // 不设置 onBadCertificate=true，保留 Dart 的证书与主机名校验。
      }
      client.onDisconnected = () {
        if (identical(_client, client) && !_disposed) {
          _events.add(const BrokerDisconnected());
        }
      };
      await client.connect(
        profile.username.isEmpty ? null : profile.username,
        profile.password.isEmpty ? null : profile.password,
      );
      if (!identical(_client, client) || _disposed) {
        client.disconnect();
        throw const AppFailure('连接已取消。');
      }
      if (client.connectionStatus?.state != MqttConnectionState.connected) {
        throw const AppFailure('Broker 拒绝连接，请核对地址、认证和权限。');
      }
      // mqtt_client 的 published 流在 connect 之后才建立。
      _published = client.published?.listen((message) {
        if (identical(_client, client) && !_disposed) {
          final packetId = message.variableHeader?.messageIdentifier;
          if (packetId != null) _events.add(BrokerPuback(packetId));
        }
      });
      _messages = client.updates?.listen((batch) {
        if (!identical(_client, client) || _disposed) return;
        for (final update in batch) {
          final message = update.payload;
          if (message is! MqttPublishMessage ||
              message.payload.message.length > 16384) {
            continue;
          }
          _events.add(
            BrokerMessage(
              update.topic,
              Uint8List.fromList(message.payload.message),
              retained: message.header?.retain ?? false,
            ),
          );
        }
      });
      final topics = <String>{
        '${profile.devicePrefix}/state',
        '${profile.devicePrefix}/reply',
        if (profile.agentId.isNotEmpty) ...[
          '${profile.agentPrefix}/state',
          '${profile.agentPrefix}/availability',
        ],
      };
      final acknowledged = <String>{};
      final gate = Completer<void>();
      _subscriptionGate = gate;
      client.onSubscribed = (topic) {
        acknowledged.add(topic);
        if (acknowledged.containsAll(topics) && !gate.isCompleted) {
          gate.complete();
        }
      };
      client.onSubscribeFail = (_) {
        if (!gate.isCompleted) {
          gate.completeError(const AppFailure('Broker 拒绝订阅，请检查 ACL。'));
        }
      };
      for (final topic in topics) {
        client.subscribe(topic, MqttQos.atLeastOnce);
      }
      await gate.future.timeout(const Duration(seconds: 6));
      if (!identical(_client, client) || _disposed) {
        throw const AppFailure('连接已取消。');
      }
      _subscriptionGate = null;
      _events.add(const BrokerConnected());
    } catch (error) {
      if (identical(_client, client)) await disconnect();
      if (error is AppFailure) rethrow;
      throw const AppFailure('MQTT 连接失败，请检查网络、认证及 TLS 证书。');
    }
  }

  @override
  int publish(String topic, Uint8List bytes) {
    final client = _client;
    if (client?.connectionStatus?.state != MqttConnectionState.connected) {
      throw const AppFailure('MQTT 已断开，动作没有排队。');
    }
    final builder = MqttClientPayloadBuilder()
      ..addUTF8String(utf8.decode(bytes));
    // QoS 1 的 PUBACK 只表示 Broker 收到包，不能当作 HID 的 sent 回执。
    return client!.publishMessage(
      topic,
      MqttQos.atLeastOnce,
      builder.payload!,
      retain: false,
    );
  }

  @override
  Future<void> disconnect() async {
    final old = _client;
    _client = null; // 先失效身份，旧回调即使迟到也不会恢复连接状态。
    final gate = _subscriptionGate;
    _subscriptionGate = null;
    if (gate != null && !gate.isCompleted) {
      gate.completeError(const AppFailure('订阅已取消。'));
    }
    await _messages?.cancel();
    _messages = null;
    await _published?.cancel();
    _published = null;
    try {
      old?.disconnect();
    } catch (_) {
      /* 断开清理不展示底层异常。 */
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await disconnect();
    await _events.close();
  }
}
