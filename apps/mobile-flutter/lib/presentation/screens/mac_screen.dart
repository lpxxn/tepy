import 'package:flutter/material.dart' hide LockState;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/app_theme.dart';
import '../../application/providers.dart';
import '../../application/session_state.dart';
import '../../domain/agent_observations.dart';
import '../../domain/snapshots.dart';
import '../widgets/common.dart';
import '../widgets/mac_network_card.dart';

class MacScreen extends ConsumerStatefulWidget {
  const MacScreen({super.key, required this.onConnect});
  final VoidCallback onConnect;
  @override
  ConsumerState<MacScreen> createState() => _MacScreenState();
}

class _MacScreenState extends ConsumerState<MacScreen> {
  int _tab = 0;
  String _filter = '全部';
  @override
  Widget build(BuildContext context) {
    final state = ref.watch(sessionProvider), mac = state.mac;
    final connected = state.link == LinkState.online && mac != null;
    final report = state.diagnostics, history = state.history;
    final reportValid =
        connected &&
        report?.session == mac.session &&
        report?.fresh(state) == true;
    return PageContent(
      storageKey: const PageStorageKey('mac'),
      children: [
        const PageHeading(
          eyebrow: 'MAC WORKSPACE',
          title: 'Mac 状态与诊断',
          subtitle: '查看系统会话、键盘条件和最近事件，定位每次操作的结果。',
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(22),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(13),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF0F2FF),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Icon(
                    Icons.laptop_mac_rounded,
                    color: brand,
                    size: 28,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        mac?.name ?? '你的 Mac',
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        state.profile.agentId.isEmpty
                            ? '请在连接页设置 Mac 代理 ID'
                            : state.profile.agentId,
                        style: const TextStyle(color: muted, fontSize: 11),
                      ),
                    ],
                  ),
                ),
                StatusBadge(connected ? '在线' : '未知', active: connected),
              ],
            ),
          ),
        ),
        const SizedBox(height: 18),
        SegmentedButton<int>(
          segments: const [
            ButtonSegment(
              value: 0,
              label: Text('状态'),
              icon: Icon(Icons.monitor_heart_outlined, size: 17),
            ),
            ButtonSegment(
              value: 1,
              label: Text('诊断'),
              icon: Icon(Icons.health_and_safety_outlined, size: 17),
            ),
            ButtonSegment(
              value: 2,
              label: Text('事件'),
              icon: Icon(Icons.history_rounded, size: 17),
            ),
          ],
          selected: {_tab},
          onSelectionChanged: (values) => setState(() => _tab = values.first),
          showSelectedIcon: false,
        ),
        const SizedBox(height: 20),
        if (state.observationError.isNotEmpty) ...[
          _note(state.observationError),
          const SizedBox(height: 16),
        ],
        if (!connected) ...[
          _note(
            state.profile.agentId.isEmpty
                ? '尚未设置 Mac 代理 ID。'
                : '等待当前会话的有效 Mac 状态。旧历史与诊断不代表在线。',
          ),
          if (state.link == LinkState.offline)
            TextButton(
              onPressed: widget.onConnect,
              child: const Text('前往连接设置'),
            ),
        ] else if (_tab == 0) ...[
          MacNetworkCard(mac: mac),
          const SizedBox(height: 16),
          ResponsiveColumns(
            first: SectionCard(
              title: '会话与电源',
              icon: Icons.bolt_outlined,
              child: Column(
                children: [
                  DetailRow('屏幕状态', switch (mac.lock) {
                    LockState.locked => '已锁定',
                    LockState.unlocked => '未锁定',
                    _ => '未知',
                  }),
                  DetailRow('当前控制台', _boolean(mac.onConsole)),
                  DetailRow('登录完成', _boolean(mac.loginDone)),
                  DetailRow('电源', switch (mac.powerState) {
                    'awake' => '已唤醒',
                    'sleeping' => '睡眠中',
                    _ => '未知',
                  }),
                  DetailRow('电源监听', mac.monitoring ? '运行中' : '不可用'),
                  DetailRow('本次唤醒次数', '${mac.wakeCount}'),
                ],
              ),
            ),
            second: SectionCard(
              title: '服务与键盘',
              icon: Icons.keyboard_alt_outlined,
              child: Column(
                children: [
                  DetailRow('Agent 版本', mac.agentVersion),
                  DetailRow('目标 HID', switch (mac.hidState) {
                    'registered' => '已注册',
                    'absent' => '未找到',
                    _ => '未知',
                  }),
                  DetailRow(
                    '键盘',
                    mac.products.isEmpty ? '暂无' : mac.products.join('\n'),
                  ),
                  DetailRow('锁定状态来源', mac.lockSource),
                  DetailRow(
                    '最近采样',
                    '${((state.nowMs - mac.observedAt) ~/ 1000).clamp(0, 999)} 秒前',
                  ),
                ],
              ),
            ),
          ),
        ] else if (_tab == 1) ...[
          if (!reportValid)
            _note('尚未收到有效诊断。请确认 Agent 0.2.0 及以上在线，Broker 允许 diagnostics 主题。'),
          if (reportValid) ...[
            SectionCard(
              title: '检查结果',
              subtitle: switch (report!.status) {
                'error' => '有需要处理的问题',
                'warning' => '部分条件尚未确认',
                _ => '当前检查正常',
              },
              icon: Icons.fact_check_outlined,
              child: Column(
                children: [for (final check in report.checks) _check(check)],
              ),
            ),
          ],
        ] else ...[
          if (history == null || history.session != mac.session)
            _note('等待当前进程的事件历史。需要 Agent 0.2.0 及以上及 events 主题权限。')
          else ...[
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                for (final filter in ['全部', '会话', '电源', '键盘', '连接'])
                  ChoiceChip(
                    label: Text(filter),
                    selected: _filter == filter,
                    onSelected: (_) => setState(() => _filter = filter),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            _note('最近 ${history.events.length} 条 · 最多保留 200 条 · 服务重启后清空'),
            const SizedBox(height: 14),
            if (history.events.isEmpty) _note('当前服务暂时没有事件。'),
            for (final event in history.events.reversed.where(_matches)) ...[
              _event(event),
              const SizedBox(height: 10),
            ],
          ],
        ],
      ],
    );
  }

  String _boolean(bool? value) => value == null
      ? '未知'
      : value
      ? '是'
      : '否';
  Widget _note(String text) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: const Color(0xFFEDF1F8),
      borderRadius: BorderRadius.circular(14),
    ),
    child: Text(
      text,
      style: const TextStyle(fontSize: 12, color: muted, height: 1.7),
    ),
  );
  Widget _check(AgentCheck check) {
    final color = switch (check.status) {
      'error' => const Color(0xFFCA536C),
      'warning' => const Color(0xFFB77D22),
      'ok' => success,
      _ => muted,
    };
    final label = switch (check.component) {
      'agent' => '服务采样',
      'mqtt' => 'MQTT',
      'user_session' => '用户会话',
      'screen_lock' => '屏幕锁定',
      'hid' => '蓝牙键盘',
      'power' => '电源监听',
      _ => check.component,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            check.status == 'ok'
                ? Icons.check_circle_outline_rounded
                : Icons.info_outline_rounded,
            color: color,
            size: 20,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                Text(
                  check.message,
                  style: const TextStyle(
                    fontSize: 12,
                    color: muted,
                    height: 1.6,
                  ),
                ),
                const SizedBox(height: 3),
                Text(check.code, style: TextStyle(fontSize: 10, color: color)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  bool _matches(AgentHistoryEvent event) => switch (_filter) {
    '会话' =>
      event.kind.startsWith('screen_') || event.kind.startsWith('console_'),
    '电源' =>
      event.kind.contains('sleep') ||
          event.kind.contains('wake') ||
          event.kind.startsWith('power_'),
    '键盘' => event.kind.startsWith('hid_'),
    '连接' => event.kind.startsWith('mqtt_'),
    _ => true,
  };
  Widget _event(AgentHistoryEvent event) {
    final time = DateTime.fromMillisecondsSinceEpoch(event.at).toLocal();
    String pad(int n) => n.toString().padLeft(2, '0');
    final date =
        '${pad(time.month)}/${pad(time.day)} ${pad(time.hour)}:${pad(time.minute)}:${pad(time.second)}';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Row(
          children: [
            const Icon(
              Icons.radio_button_checked_rounded,
              color: brand,
              size: 17,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    eventLabels[event.kind] ?? event.kind,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '$date  ·  #${event.sequence}',
                    style: const TextStyle(fontSize: 11, color: muted),
                  ),
                  if (event.code.isNotEmpty)
                    Text(
                      event.code,
                      style: const TextStyle(fontSize: 10, color: muted),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
