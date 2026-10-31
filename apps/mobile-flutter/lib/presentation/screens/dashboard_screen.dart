import 'dart:async';

// hide 避免 Flutter 快捷键 API 的 LockState 与业务里的锁屏枚举重名。
import 'package:flutter/material.dart' hide LockState;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/providers.dart';
import '../../application/session_state.dart';
import '../../app/tepy_app.dart';
import '../../domain/snapshots.dart';
import '../widgets/common.dart';

class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key, required this.onConnect});
  final VoidCallback onConnect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(sessionProvider), mac = state.mac;
    final lock = mac?.lock ?? LockState.unknown;
    final label = switch (lock) {
      LockState.locked => '已锁定',
      LockState.unlocked => '未锁定',
      LockState.unknown => '状态未知',
    };
    String boolean(bool? value) => value == null ? '未知' : (value ? '是' : '否');
    return ListView(
      key: const PageStorageKey('dashboard'),
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      children: [
        Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(26),
            gradient: const LinearGradient(
              colors: [Color(0xFF172C44), Color(0xFF145F62)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.laptop_mac,
                    color: Color(0xFF6CE0CC),
                    size: 29,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      mac?.name ?? '你的 Mac',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        fontSize: 17,
                      ),
                    ),
                  ),
                  Text(
                    linkLabel(state.link),
                    style: const TextStyle(
                      color: Color(0xFF97D6CE),
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 28),
              Text(
                label,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 36,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                mac == null
                    ? '通过代理 ID 接收状态，无需记住 Mac IP'
                    : '最近采样 ${((state.nowMs - mac.observedAt) ~/ 1000).clamp(0, 999)} 秒前 · 超时自动显示未知',
                style: const TextStyle(color: Color(0xFFB6D2D7), fontSize: 12),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        if (state.savedProfile != null && state.link != LinkState.online) ...[
          Card(
            clipBehavior: Clip.antiAlias,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const CircleAvatar(
                        backgroundColor: Color(0xFFE4F6F1),
                        child: Icon(Icons.router_outlined, color: brand),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              '已保存的设备',
                              style: TextStyle(
                                color: ink,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              state.savedProfile!.broker,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.blueGrey,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          key: const Key('dashboardConnect'),
                          onPressed:
                              !state.loading &&
                                  !state.saving &&
                                  !state.busy &&
                                  state.link == LinkState.offline
                              ? () => unawaited(
                                  ref
                                      .read(sessionProvider.notifier)
                                      .connectSaved(),
                                )
                              : null,
                          icon:
                              state.link == LinkState.connecting ||
                                  state.link == LinkState.reconnecting
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.link),
                          label: Text(switch (state.link) {
                            LinkState.connecting => '连接中…',
                            LinkState.reconnecting => '重连中…',
                            _ => '连接设备',
                          }),
                        ),
                      ),
                      const SizedBox(width: 8),
                      TextButton(
                        onPressed: onConnect,
                        child: const Text('连接设置'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
        ],
        // Wrap 比固定高度 Grid 更适应小屏与系统大字体，卡片按内容自然增高。
        LayoutBuilder(
          builder: (context, constraints) => Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              _Metric(
                'ESP32',
                state.device == null ? '未知' : '在线',
                Icons.memory,
                constraints.maxWidth,
              ),
              _Metric(
                '蓝牙键盘',
                state.device?.ready(state) == true ? '就绪' : '未就绪',
                Icons.bluetooth,
                constraints.maxWidth,
              ),
              _Metric(
                'Mac HID',
                mac?.hidState == 'registered'
                    ? '已注册'
                    : (mac?.hidState == 'absent' ? '未注册' : '未知'),
                Icons.keyboard_outlined,
                constraints.maxWidth,
              ),
              _Metric(
                'MQTT',
                linkLabel(state.link),
                Icons.hub_outlined,
                constraints.maxWidth,
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          key: const Key('dashboardWake'),
          onPressed: state.canAct
              ? () => unawaited(ref.read(sessionProvider.notifier).wake())
              : null,
          icon: const Icon(Icons.wb_sunny_outlined),
          label: const Text('唤醒 Mac'),
        ),
        if (state.link == LinkState.offline && state.savedProfile == null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: TextButton.icon(
              onPressed: onConnect,
              icon: const Icon(Icons.settings_ethernet),
              label: const Text('设置连接'),
            ),
          ),
        const SizedBox(height: 16),
        const SessionNotice(),
        const SizedBox(height: 16),
        SectionCard(
          title: '会话与电源',
          subtitle: '系统状态用于观察，不代表密码框焦点或身份认证。',
          child: Column(
            children: [
              DetailRow('当前控制台', boolean(mac?.onConsole)),
              DetailRow('登录完成', boolean(mac?.loginDone)),
              DetailRow('电源状态', switch (mac?.powerState) {
                'awake' => '已唤醒',
                'sleeping' => '睡眠中',
                _ => '未知',
              }),
              DetailRow('最近事件', switch (mac?.lastEvent) {
                'did_wake' => '已唤醒',
                'will_sleep' => '即将睡眠',
                _ => '暂无记录',
              }),
              DetailRow('本次服务唤醒次数', mac == null ? '未知' : '${mac.wakeCount}'),
              DetailRow(
                '电源监听',
                mac == null ? '未知' : (mac.monitoring ? '运行中' : '不可用'),
              ),
              DetailRow('锁定信息来源', mac?.lockSource ?? '未知'),
            ],
          ),
        ),
        const SizedBox(height: 16),
        SectionCard(
          title: '键盘与设备',
          child: Column(
            children: [
              DetailRow('目标设备', state.profile.deviceId),
              DetailRow(
                'Mac 代理',
                state.profile.agentId.isEmpty ? '未设置' : state.profile.agentId,
              ),
              DetailRow('固件', state.device?.firmware ?? '未知'),
              DetailRow('ESP32 地址', state.device?.ip ?? '未知'),
              DetailRow(
                'Mac 键盘',
                mac == null || mac.products.isEmpty
                    ? '未发现或未知'
                    : mac.products.join('\n'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric(this.title, this.value, this.icon, this.width);
  final String title, value;
  final IconData icon;
  final double width;
  @override
  Widget build(BuildContext context) => SizedBox(
    width: (width - 12) / 2,
    child: Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: brand, size: 22),
            const SizedBox(height: 12),
            Text(
              title,
              style: const TextStyle(color: Colors.blueGrey, fontSize: 12),
            ),
            const SizedBox(height: 4),
            Text(
              value,
              style: const TextStyle(
                color: ink,
                fontWeight: FontWeight.w700,
                fontSize: 21,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
