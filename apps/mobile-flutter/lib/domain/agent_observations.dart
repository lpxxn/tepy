import 'snapshots.dart';

final _session = RegExp(r'^[a-f0-9]{32}$');
final _code = RegExp(r'^[a-z_]{1,64}$');
const _statuses = {'ok', 'warning', 'error', 'skipped'};

/// 新的诊断和历史拥有独立模型，不能用于允许发送密码，也不修改旧状态协议。
final class AgentCheck {
  const AgentCheck(this.component, this.status, this.code, this.message);
  final String component, status, code, message;
}

final class AgentDiagnostics {
  const AgentDiagnostics({
    required this.session,
    required this.version,
    required this.observedAt,
    required this.validUntil,
    required this.receivedTick,
    required this.status,
    required this.checks,
  });
  final String session, version, status;
  final int observedAt, validUntil, receivedTick;
  final List<AgentCheck> checks;
  bool fresh(AppClock clock) =>
      clock.nowMs < validUntil &&
      observedAt <= clock.nowMs + 5000 &&
      clock.tickMs - receivedTick <= 180000;

  static AgentDiagnostics? parse(
    Map<String, dynamic> json,
    String agent,
    AppClock clock,
  ) {
    if (json['v'] != 1 ||
        json['agent_id'] != agent ||
        json['source'] != 'live' ||
        json['session'] is! String ||
        !_session.hasMatch(json['session'] as String) ||
        json['agent_version'] is! String ||
        (json['agent_version'] as String).length > 64 ||
        !{'ok', 'warning', 'error'}.contains(json['status']) ||
        json['observed_at'] is! int ||
        json['valid_until'] is! int ||
        json['checks'] is! List) {
      return null;
    }
    final observed = json['observed_at'] as int,
        until = json['valid_until'] as int,
        raw = json['checks'] as List;
    if (observed < 1 ||
        until <= observed ||
        until - observed > 180000 ||
        raw.isEmpty ||
        raw.length > 32) {
      return null;
    }
    final checks = <AgentCheck>[];
    for (final value in raw) {
      final check = object(value);
      if (check == null ||
          check['component'] is! String ||
          !_code.hasMatch(check['component'] as String) ||
          !_statuses.contains(check['status']) ||
          check['code'] is! String ||
          !_code.hasMatch(check['code'] as String) ||
          check['message'] is! String ||
          (check['message'] as String).isEmpty ||
          (check['message'] as String).length > 256) {
        return null;
      }
      checks.add(
        AgentCheck(
          check['component'] as String,
          check['status'] as String,
          check['code'] as String,
          check['message'] as String,
        ),
      );
    }
    // 汇总以最严重检查为准，避免恶意或损坏消息把 error 标成 ok。
    final summary = checks.any((c) => c.status == 'error')
        ? 'error'
        : checks.any((c) => c.status == 'warning')
        ? 'warning'
        : 'ok';
    if (summary != json['status']) return null;
    final result = AgentDiagnostics(
      session: json['session'] as String,
      version: json['agent_version'] as String,
      observedAt: observed,
      validUntil: until,
      receivedTick: clock.tickMs,
      status: summary,
      checks: List.unmodifiable(checks),
    );
    return result.fresh(clock) ? result : null;
  }
}

const eventLabels = <String, String>{
  'agent_started': '服务启动',
  'screen_locked': '屏幕锁定',
  'screen_unlocked': '屏幕解锁',
  'screen_lock_unknown': '锁定状态未知',
  'will_sleep': '即将睡眠',
  'did_wake': '系统唤醒',
  'console_active': '进入活动控制台',
  'console_inactive': '离开活动控制台',
  'console_unknown': '控制台状态未知',
  'hid_registered': '键盘已注册',
  'hid_absent': '键盘未找到',
  'hid_unknown': '键盘状态未知',
  'mqtt_connected': 'MQTT 已连接',
  'mqtt_disconnected': 'MQTT 已断开',
  'mqtt_error': 'MQTT 连接异常',
  'power_monitor_ready': '电源监听已就绪',
  'power_monitor_unavailable': '电源监听不可用',
};
const _eventStates = {
  '',
  'running',
  'unknown',
  'active',
  'inactive',
  'locked',
  'unlocked',
  'registered',
  'absent',
  'sleeping',
  'awake',
  'unavailable',
  'ready',
  'connected',
  'disconnected',
};

final class AgentHistoryEvent {
  const AgentHistoryEvent(
    this.sequence,
    this.at,
    this.kind,
    this.from,
    this.to,
    this.code,
  );
  final int sequence, at;
  final String kind, from, to, code;
}

final class AgentHistory {
  const AgentHistory({
    required this.session,
    required this.observedAt,
    required this.latestSequence,
    required this.events,
  });
  final String session;
  final int observedAt, latestSequence;
  final List<AgentHistoryEvent> events;
  static AgentHistory? parse(Map<String, dynamic> json, String agent) {
    if (json['v'] != 1 ||
        json['agent_id'] != agent ||
        json['session'] is! String ||
        !_session.hasMatch(json['session'] as String) ||
        json['observed_at'] is! int ||
        (json['observed_at'] as int) < 1 ||
        json['capacity'] != 200 ||
        json['oldest_sequence'] is! int ||
        json['latest_sequence'] is! int ||
        json['next_after'] != json['latest_sequence'] ||
        json['has_more'] != false ||
        json['truncated'] != false ||
        json['events'] is! List ||
        (json['events'] as List).length > 200) {
      return null;
    }
    final oldest = json['oldest_sequence'] as int,
        latest = json['latest_sequence'] as int;
    if (oldest < 0 || latest < oldest) return null;
    final events = <AgentHistoryEvent>[];
    var previous = oldest - 1;
    for (final raw in json['events'] as List) {
      final e = object(raw);
      if (e == null ||
          e['sequence'] is! int ||
          (e['sequence'] as int) != previous + 1 ||
          e['at'] is! int ||
          (e['at'] as int) < 1 ||
          (e['at'] as int) > 8640000000000000 ||
          !eventLabels.containsKey(e['kind']) ||
          !_eventStates.contains(e['from']) ||
          !_eventStates.contains(e['to']) ||
          e['code'] is! String ||
          ((e['code'] as String).isNotEmpty &&
              !_code.hasMatch(e['code'] as String))) {
        return null;
      }
      previous = e['sequence'] as int;
      events.add(
        AgentHistoryEvent(
          previous,
          e['at'] as int,
          e['kind'] as String,
          e['from'] as String,
          e['to'] as String,
          e['code'] as String,
        ),
      );
    }
    if (events.isEmpty
        ? oldest != 0 || latest != 0
        : oldest < 1 || events.last.sequence != latest) {
      return null;
    }
    return AgentHistory(
      session: json['session'] as String,
      observedAt: json['observed_at'] as int,
      latestSequence: latest,
      events: List.unmodifiable(events),
    );
  }
}
