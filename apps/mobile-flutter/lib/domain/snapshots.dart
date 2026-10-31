/// 本文件不依赖 Flutter：JSON 校验和状态有效性可以独立做单元测试。
/// “蓝牙连着”“HID 发送成功”“Mac 报告解锁”是三种不同证据，不能混为一个 bool。
enum LockState { locked, unlocked, unknown }

/// 可注入的时钟使超时测试不必真的等几十秒。
abstract interface class AppClock {
  int get nowMs;
  int get tickMs;
}

final class SystemClock implements AppClock {
  final Stopwatch _watch = Stopwatch()..start();
  @override
  int get nowMs => DateTime.now().millisecondsSinceEpoch;
  @override
  int get tickMs => _watch.elapsedMilliseconds;
}

Map<String, dynamic>? object(Object? value) =>
    value is Map<String, dynamic> ? value : null;

/// ESP32 每五秒发布一次状态。这里同时检查 Unix 时间和本地单调计时，
/// 防止时钟被调回后，把很久以前收到的 retained 消息重新当成实时状态。
final class DeviceSnapshot {
  const DeviceSnapshot({
    required this.session,
    required this.sampledAt,
    required this.receivedTick,
    required this.timeReady,
    required this.bleReady,
    required this.mqttConnected,
    required this.busy,
    required this.firmware,
    required this.ip,
  });
  final String session, firmware, ip;
  final int sampledAt, receivedTick;
  final bool timeReady, bleReady, mqttConnected, busy;

  bool fresh(AppClock clock) =>
      clock.tickMs - receivedTick <= 15000 &&
      sampledAt > clock.nowMs - 15000 &&
      sampledAt <= clock.nowMs + 5000;
  bool ready(AppClock clock) =>
      fresh(clock) && timeReady && bleReady && mqttConnected;

  static DeviceSnapshot? parse(
    Map<String, dynamic> json,
    String id,
    AppClock clock,
  ) {
    final ble = object(json['ble']), mqtt = object(json['mqtt']);
    if (json['v'] != 1 ||
        json['device_id'] != id ||
        json['online'] != true ||
        json['session'] is! String ||
        !RegExp(r'^[a-f0-9]{32}$').hasMatch(json['session'] as String) ||
        json['now'] is! int ||
        json['time_ready'] is! bool ||
        json['busy'] is! bool ||
        ble?['ready'] is! bool ||
        mqtt?['connected'] is! bool) {
      return null;
    }
    final result = DeviceSnapshot(
      session: json['session'] as String,
      sampledAt: json['now'] as int,
      receivedTick: clock.tickMs,
      timeReady: json['time_ready'] as bool,
      busy: json['busy'] as bool,
      bleReady: ble!['ready'] as bool,
      mqttConnected: mqtt!['connected'] as bool,
      firmware: json['firmware'] is String ? json['firmware'] as String : '未知',
      ip: object(json['wifi'])?['ip'] is String
          ? object(json['wifi'])!['ip'] as String
          : '',
    );
    return result.fresh(clock) ? result : null;
  }
}

/// Mac 的可空布尔值保留 null，而不是把缺失字段默认为 false。
/// 这是 Dart 空安全真正有用的地方：不知道是否在控制台，不等于已经离开控制台。
final class MacSnapshot {
  const MacSnapshot({
    required this.name,
    required this.session,
    required this.sequence,
    required this.observedAt,
    required this.validUntil,
    required this.receivedTick,
    required this.lock,
    required this.lockSource,
    required this.available,
    required this.onConsole,
    required this.loginDone,
    required this.hidState,
    required this.targetDeviceId,
    required this.products,
    required this.powerState,
    required this.monitoring,
    required this.lastEvent,
    required this.wakeCount,
  });
  final String name,
      session,
      lockSource,
      hidState,
      targetDeviceId,
      powerState,
      lastEvent;
  final int sequence, observedAt, validUntil, receivedTick, wakeCount;
  final LockState lock;
  final bool available, monitoring;
  final bool? onConsole, loginDone;
  final List<String> products;

  bool fresh(AppClock clock) =>
      clock.nowMs < validUntil &&
      observedAt <= clock.nowMs + 5000 &&
      clock.tickMs - receivedTick <= 180000;
  bool keyboardMatches(String id) =>
      hidState == 'registered' &&
      (targetDeviceId == id ||
          (targetDeviceId.isEmpty &&
              products.contains('Tepy-${id.substring(6)}')));
  bool inputEligible(String id) =>
      available &&
      onConsole == true &&
      loginDone == true &&
      lock == LockState.locked &&
      powerState == 'awake' &&
      keyboardMatches(id);

  static MacSnapshot? parse(
    Map<String, dynamic> json,
    String id,
    AppClock clock,
  ) {
    final user = object(json['user_session']),
        hid = object(json['hid']),
        power = object(json['power']);
    if (json['v'] != 1 ||
        json['platform'] != 'darwin' ||
        json['agent_id'] != id ||
        json['name'] is! String ||
        (json['name'] as String).length > 128 ||
        json['session'] is! String ||
        !RegExp(r'^[a-f0-9]{32}$').hasMatch(json['session'] as String) ||
        json['sequence'] is! int ||
        (json['sequence'] as int) < 1 ||
        json['observed_at'] is! int ||
        json['valid_until'] is! int ||
        user?['available'] is! bool ||
        ![true, false, null].contains(user?['on_console']) ||
        ![true, false, null].contains(user?['login_done']) ||
        !{'locked', 'unlocked', 'unknown'}.contains(user?['lock_state']) ||
        !{
          'cg_session_property',
          'io_console_property',
          'screen_notification',
          'unavailable',
        }.contains(user?['lock_source']) ||
        !{'registered', 'absent', 'unknown'}.contains(hid?['state']) ||
        hid?['available'] is! bool ||
        hid?['target_device_id'] is! String ||
        !RegExp(r'^([a-f0-9]{12})?$')
            .hasMatch(hid!['target_device_id'] as String) ||
        hid['devices'] is! List ||
        (hid['devices'] as List).length > 8 ||
        !{'awake', 'sleeping', 'unknown'}.contains(power?['state']) ||
        power?['monitoring'] is! bool ||
        power?['wake_count'] is! int ||
        !{'none', 'will_sleep', 'did_wake'}.contains(power?['last_event'])) {
      return null;
    }
    final observed = json['observed_at'] as int,
        until = json['valid_until'] as int;
    if (observed < 1 || until <= observed || until - observed > 180000) {
      return null;
    }
    final products = <String>[];
    for (final raw in hid['devices'] as List) {
      final device = object(raw);
      if (device?['product'] is! String ||
          (device!['product'] as String).length > 128 ||
          device['transport'] is! String ||
          device['registry_id'] is! String) {
        return null;
      }
      products.add(device['product'] as String);
    }
    if (hid['state'] == 'registered' &&
        (products.isEmpty || hid['available'] != true)) {
      return null;
    }
    if (hid['state'] == 'absent' &&
        (products.isNotEmpty || hid['available'] != true)) {
      return null;
    }
    final result = MacSnapshot(
      name: json['name'] as String,
      session: json['session'] as String,
      sequence: json['sequence'] as int,
      observedAt: observed,
      validUntil: until,
      receivedTick: clock.tickMs,
      lock: LockState.values.byName(user!['lock_state'] as String),
      lockSource: user['lock_source'] as String,
      available: user['available'] as bool,
      onConsole: user['on_console'] as bool?,
      loginDone: user['login_done'] as bool?,
      hidState: hid['state'] as String,
      targetDeviceId: hid['target_device_id'] as String,
      products: List.unmodifiable(products),
      powerState: power!['state'] as String,
      monitoring: power['monitoring'] as bool,
      lastEvent: power['last_event'] as String,
      wakeCount: power['wake_count'] as int,
    );
    return result.fresh(clock) ? result : null;
  }
}
