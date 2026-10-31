import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/providers.dart';
import '../../application/session_state.dart';
import '../../app/tepy_app.dart';
import '../../domain/commands.dart';
import '../widgets/common.dart';

class ControlsScreen extends ConsumerWidget {
  const ControlsScreen({super.key, required this.onConnect});
  final VoidCallback onConnect;

  Future<void> _input(
    BuildContext context,
    WidgetRef ref, {
    required bool unlock,
  }) async {
    // 密码只存在于这次 Dialog 和任务中，不放进 Provider 的可展示状态。
    final result = await showDialog<_InputResult>(
      context: context,
      builder: (_) => _InputDialog(unlock: unlock),
    );
    if (result == null) return;
    if (!context.mounted) {
      wipe(result.bytes);
      return;
    }
    final controller = ref.read(sessionProvider.notifier);
    if (unlock) {
      await controller.unlock(
        result.bytes,
        enter: result.enter,
        waitSeconds: result.waitSeconds,
      );
    } else {
      await controller.typeText(result.bytes, enter: result.enter);
    }
  }

  Future<void> _key(BuildContext context, WidgetRef ref) async {
    final result = await showDialog<(String, List<String>)>(
      context: context,
      builder: (_) => const _KeyDialog(),
    );
    if (result != null && context.mounted) {
      await ref.read(sessionProvider.notifier).key(result.$1, result.$2);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(sessionProvider);
    final phase = switch (state.phase) {
      JobPhase.idle => '等待操作',
      JobPhase.waking => '发送唤醒',
      JobPhase.sending => '发送按键',
      JobPhase.waitingForMac => '等待 Mac 就绪',
      JobPhase.typing => '发送输入',
      JobPhase.observing => '观察 Mac 反馈',
    };
    Widget action(
      String title,
      String subtitle,
      IconData icon,
      VoidCallback run, {
      bool extraEnabled = true,
    }) {
      final enabled = state.canAct && extraEnabled;
      final leading = Container(
        padding: const EdgeInsets.all(11),
        decoration: BoxDecoration(
          color: const Color(0xFFF0F2FF),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(icon, color: enabled ? brand : muted, size: 22),
      );
      final caption = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: enabled ? ink : muted,
            ),
          ),
          const SizedBox(height: 6),
          Text(subtitle, style: const TextStyle(fontSize: 12, color: muted)),
        ],
      );
      final arrow = Icon(
        Icons.north_east_rounded,
        color: enabled ? brand : line,
        size: 19,
      );
      return Card(
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: enabled ? run : null,
          child: LayoutBuilder(
            builder: (context, constraints) {
              // 手机使用横向短卡片，让常用动作少滚动；桌面保留宽松的双列卡片。
              final compact = constraints.maxWidth < 420;
              return Padding(
                padding: EdgeInsets.all(compact ? 18 : 22),
                child: compact
                    ? Row(
                        children: [
                          leading,
                          const SizedBox(width: 14),
                          Expanded(child: caption),
                          const SizedBox(width: 8),
                          arrow,
                        ],
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(children: [leading, const Spacer(), arrow]),
                          const SizedBox(height: 18),
                          caption,
                        ],
                      ),
              );
            },
          ),
        ),
      );
    }

    return PageContent(
      storageKey: const PageStorageKey('controls'),
      children: [
        const PageHeading(
          eyebrow: 'KEYBOARD CONTROL',
          title: '让 Mac 响应你',
          subtitle: '从一次唤醒，到一段输入。每次操作都由你发起。',
        ),
        ResponsiveColumns(
          first: action(
            '唤醒屏幕',
            '轻按一次 Shift，唤醒你的 Mac',
            Icons.wb_sunny_outlined,
            () => unawaited(ref.read(sessionProvider.notifier).wake()),
          ),
          second: action(
            '发送文字',
            '输入英文、数字和符号，使用后清理',
            Icons.text_fields_rounded,
            () => unawaited(_input(context, ref, unlock: false)),
          ),
        ),
        const SizedBox(height: 16),
        ResponsiveColumns(
          first: action(
            '按键与组合键',
            'Command / Option / Control / Shift',
            Icons.keyboard_command_key_rounded,
            () => unawaited(_key(context, ref)),
          ),
          second: action(
            '唤醒并输入解锁',
            '唤醒 → 等待 → 单次输入 → 观察状态',
            Icons.lock_open_rounded,
            () => unawaited(_input(context, ref, unlock: true)),
            extraEnabled: state.profile.agentId.isNotEmpty,
          ),
        ),
        const SizedBox(height: 24),
        SectionCard(
          title: phase,
          icon: Icons.radio_button_checked_rounded,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (state.busy) ...[
                const LinearProgressIndicator(),
                const SizedBox(height: 16),
              ],
              DetailRow('HID 回执', state.hidResult),
              DetailRow('Mac 反馈', state.macResult),
              if (state.busy)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: OutlinedButton.icon(
                    key: const Key('cancelJob'),
                    onPressed: () =>
                        ref.read(sessionProvider.notifier).cancel(),
                    icon: const Icon(Icons.stop_circle_outlined),
                    label: const Text('取消后续步骤'),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        const SessionNotice(),
        if (state.link == LinkState.offline)
          TextButton(onPressed: onConnect, child: const Text('前往连接设置')),
        const SizedBox(height: 16),
        const Text(
          '请确认 Mac 的输入焦点和美式 ABC 布局。未知状态不等于解锁；取消无法撤回已经提交的按键。',
          style: TextStyle(fontSize: 12, color: muted),
        ),
      ],
    );
  }
}

final class _InputResult {
  const _InputResult(this.bytes, this.enter, this.waitSeconds);
  final Uint8List bytes;
  final bool enter;
  final int waitSeconds;
}

/// Dialog 自己管理输入框、开关和 Slider，这些临时状态不需要全局 Riverpod。
class _InputDialog extends StatefulWidget {
  const _InputDialog({required this.unlock});
  final bool unlock;
  @override
  State<_InputDialog> createState() => _InputDialogState();
}

class _InputDialogState extends State<_InputDialog>
    with WidgetsBindingObserver {
  final _text = TextEditingController();
  bool _enter = false;
  double _wait = 3;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _text.clear(); // 即使没有点击执行，切入后台也清理临时输入。
      if (mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _text.clear();
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.unlock ? '唤醒并输入解锁' : '发送文字'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            widget.unlock
                ? '确认 Mac 密码框焦点。本次内容不保存、不记录，未知状态不会继续输入。'
                : '内容隐藏显示，只支持 1–512 个可打印 ASCII 字符。',
            style: const TextStyle(fontSize: 13, color: Colors.blueGrey),
          ),
          const SizedBox(height: 18),
          TextField(
            key: const Key('actionInput'),
            controller: _text,
            obscureText: true,
            maxLength: 512,
            autocorrect: false,
            enableSuggestions: false,
            enableIMEPersonalizedLearning: false,
            keyboardType: TextInputType.visiblePassword,
            decoration: InputDecoration(
              labelText: widget.unlock ? '本次 Mac 密码' : '本次输入内容',
            ),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('输入后按回车', style: TextStyle(fontSize: 14)),
            value: _enter,
            onChanged: (value) => setState(() => _enter = value),
          ),
          if (widget.unlock) ...[
            Text('唤醒回执后等待 ${_wait.round()} 秒'),
            Slider(
              value: _wait,
              min: 0,
              max: 30,
              divisions: 30,
              onChanged: (value) => setState(() => _wait = value),
            ),
          ],
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () {
          _text.clear();
          Navigator.pop(context);
        },
        child: const Text('取消'),
      ),
      FilledButton(
        key: const Key('confirmInput'),
        onPressed: () {
          final bytes = Uint8List.fromList(utf8.encode(_text.text));
          _text.clear();
          Navigator.pop(context, _InputResult(bytes, _enter, _wait.round()));
        },
        child: const Text('执行一次'),
      ),
    ],
  );
}

class _KeyDialog extends StatefulWidget {
  const _KeyDialog();
  @override
  State<_KeyDialog> createState() => _KeyDialogState();
}

class _KeyDialogState extends State<_KeyDialog> {
  final _key = TextEditingController(text: 'ENTER');
  final _modifiers = <String>{};
  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('按键与组合键'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _key,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: '按键名或单个字符',
              helperText: '例如 ENTER、F1、z、/',
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            children: [
              for (final modifier in modifierNames)
                FilterChip(
                  label: Text(modifier),
                  selected: _modifiers.contains(modifier),
                  onSelected: (value) => setState(() {
                    value
                        ? _modifiers.add(modifier)
                        : _modifiers.remove(modifier);
                  }),
                ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'GUI = Command · ALT = Option',
            style: TextStyle(fontSize: 12, color: Colors.blueGrey),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () =>
            Navigator.pop(context, (_key.text, _modifiers.toList())),
        child: const Text('发送一次'),
      ),
    ],
  );
}
