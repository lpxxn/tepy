import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/connection_store.dart';
import '../data/mqtt_transport.dart';
import '../domain/snapshots.dart';
import 'session_controller.dart';
import 'session_state.dart';

/// 普通 Provider 负责依赖注入。业务控制器不知道真实对象来自哪里；
/// 测试用 overrideWithValue 换成内存存储、假 Broker 和可控时钟。
final connectionStoreProvider = Provider<ConnectionStore>(
  (ref) => SecureConnectionStore(),
);
final transportFactoryProvider = Provider<BrokerTransport Function()>(
  (ref) => DartMqttTransport.new,
);
final clockProvider = Provider<AppClock>((ref) => SystemClock());

/// NotifierProvider = 一个负责修改状态的控制器 + 它当前的不可变状态。
/// watch(sessionProvider) 读取状态；read(sessionProvider.notifier) 调用操作方法。
/// 不依赖代码生成，便于刚学习 Flutter 时跟踪实际调用路径。
final sessionProvider = NotifierProvider<SessionController, SessionState>(
  SessionController.new,
);
