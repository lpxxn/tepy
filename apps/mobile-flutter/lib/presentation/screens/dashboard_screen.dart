import 'dart:async';

import 'package:flutter/material.dart' hide LockState;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/providers.dart';
import '../../application/session_state.dart';
import '../../app/app_theme.dart';
import '../../domain/snapshots.dart';
import '../widgets/common.dart';

class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key, required this.onConnect, this.onControls});
  final VoidCallback onConnect;
  final VoidCallback? onControls;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(sessionProvider), mac = state.mac;
    final label = switch (mac?.lock ?? LockState.unknown) {
      LockState.locked => '已锁定',
      LockState.unlocked => '未锁定',
      LockState.unknown => '状态未知',
    };
    String boolean(bool? value) => value == null ? '未知' : (value ? '是' : '否');
    return PageContent(
      storageKey: const PageStorageKey('dashboard'),
      children: [
        const PageHeading(
          eyebrow: 'OVERVIEW',
          title: '设备概览',
          subtitle: '你的 Mac 与键盘设备，一眼掌握。',
        ),
        Container(
          padding: const EdgeInsets.all(26),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            gradient: const LinearGradient(
              colors: [Color(0xFF24324F), Color(0xFF131F36)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(
                          Icons.laptop_mac_rounded,
                          color: Color(0xFFAAB9FF),
                          size: 19,
                        ),
                        const SizedBox(width: 9),
                        Expanded(
                          child: Text(
                            mac?.name ?? '你的 Mac',
                            style: const TextStyle(
                              color: Color(0xFFBAC7E1),
                              fontSize: 12,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 22),
                    Text(
                      label,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 32,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -1,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      mac == null
                          ? '连接设备后，系统状态将在这里更新'
                          : '最近采样 ${((state.nowMs - mac.observedAt) ~/ 1000).clamp(0, 999)} 秒前',
                      style: const TextStyle(
                        color: Color(0xFF94A5C5),
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              // 装饰使用原生组件，无需下载外部图片。
              if (MediaQuery.sizeOf(context).width >= 700) ...[
                const SizedBox(width: 30),
                Container(
                  width: 136,
                  height: 100,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.04),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.08),
                    ),
                  ),
                  child: const Icon(
                    Icons.laptop_mac_rounded,
                    size: 67,
                    color: Color(0xFF9AAAF0),
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 18),
        if (state.savedProfile != null && state.link != LinkState.online) ...[
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Row(
                    children: [
                      Icon(
                        Icons.bookmark_border_rounded,
                        color: brand,
                        size: 20,
                      ),
                      SizedBox(width: 10),
                      Text(
                        '已保存的设备',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                  const SizedBox(height: 5),
                  Text(
                    state.savedProfile!.broker,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11, color: muted),
                  ),
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton.icon(
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
                                width: 15,
                                height: 15,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.link_rounded, size: 18),
                        label: Text(switch (state.link) {
                          LinkState.connecting => '连接中…',
                          LinkState.reconnecting => '重连中…',
                          _ => '连接设备',
                        }),
                      ),
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
          const SizedBox(height: 18),
        ],
        LayoutBuilder(
          builder: (context, constraints) {
            final columns = constraints.maxWidth >= 760 ? 4 : 2;
            final width = (constraints.maxWidth - (columns - 1) * 12) / columns;
            return Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                _Metric(
                  'ESP32',
                  state.device == null ? '未知' : '在线',
                  Icons.memory_rounded,
                  width,
                  state.device != null,
                ),
                _Metric(
                  '蓝牙键盘',
                  state.device?.ready(state) == true ? '就绪' : '未就绪',
                  Icons.bluetooth_rounded,
                  width,
                  state.device?.ready(state) == true,
                ),
                _Metric(
                  'Mac HID',
                  mac?.hidState == 'registered'
                      ? '已注册'
                      : (mac?.hidState == 'absent' ? '未注册' : '未知'),
                  Icons.keyboard_alt_outlined,
                  width,
                  mac?.hidState == 'registered',
                ),
                _Metric(
                  'MQTT',
                  linkLabel(state.link),
                  Icons.hub_outlined,
                  width,
                  state.link == LinkState.online,
                ),
              ],
            );
          },
        ),
        const SizedBox(height: 18),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            FilledButton.icon(
              key: const Key('dashboardWake'),
              onPressed: state.canAct
                  ? () => unawaited(ref.read(sessionProvider.notifier).wake())
                  : null,
              icon: const Icon(Icons.wb_sunny_outlined, size: 18),
              label: const Text('唤醒 Mac'),
            ),
            OutlinedButton.icon(
              onPressed: onControls,
              icon: const Icon(Icons.keyboard_alt_outlined, size: 18),
              label: const Text('键盘控制'),
            ),
            if (state.link == LinkState.offline && state.savedProfile == null)
              TextButton(onPressed: onConnect, child: const Text('设置连接')),
          ],
        ),
        const SizedBox(height: 18),
        const SessionNotice(),
        const SizedBox(height: 24),
        ResponsiveColumns(
          first: SectionCard(
            title: '会话与电源',
            icon: Icons.bolt_rounded,
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
          second: SectionCard(
            title: '键盘与设备',
            icon: Icons.memory_rounded,
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
        ),
      ],
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric(this.title, this.value, this.icon, this.width, this.active);
  final String title, value;
  final IconData icon;
  final double width;
  final bool active;
  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    child: Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(7),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF0F2FF),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon, color: brand, size: 17),
                ),
                const Spacer(),
                Container(
                  width: 5,
                  height: 5,
                  decoration: BoxDecoration(
                    color: active ? success : line,
                    shape: BoxShape.circle,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(title, style: const TextStyle(color: muted, fontSize: 11)),
            const SizedBox(height: 3),
            Text(
              value,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: ink,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
