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
    }) => Card(
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 20,
          vertical: 12,
        ),
        leading: CircleAvatar(
          backgroundColor: const Color(0xFFE4F6F1),
          child: Icon(icon, color: brand),
        ),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Text(subtitle, style: const TextStyle(fontSize: 12)),
        trailing: const Icon(Icons.chevron_right),
        enabled: state.canAct && extraEnabled,
        onTap: state.canAct && extraEnabled ? run : null,
      ),
    );
    return ListView(
      key: const PageStorageKey('controls'),
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      children: [
        const Text(
          '让 Mac 响应你',
          style: TextStyle(fontSize: 25, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 8),
        const Text(
          '每次操作都由你发起，发送与结果反馈分别显示。',
          style: TextStyle(color: Colors.blueGrey, fontSize: 13),
        ),
        const SizedBox(height: 20),
        action(
          '唤醒屏幕',
          '发送一次 Shift 按下与释放',
          Icons.wb_sunny_outlined,
          () => unawaited(ref.read(sessionProvider.notifier).wake()),
        ),
        const SizedBox(height: 12),
        action(
          '发送文字',
          'ASCII 英文、数字与符号，使用后清理',
          Icons.text_fields,
          () => unawaited(_input(context, ref, unlock: false)),
        ),
        const SizedBox(height: 12),
        action(
          '按键与组合键',
          'Command / Option / Control / Shift',
          Icons.keyboard_command_key,
          () => unawaited(_key(context, ref)),
        ),
        const SizedBox(height: 12),
        action(
          '唤醒并输入解锁',
          '唤醒 → 等待 → 单次输入 → 观察状态',
          Icons.lock_open_outlined,
          () => unawaited(_input(context, ref, unlock: true)),
          extraEnabled: state.profile.agentId.isNotEmpty,
        ),
        const SizedBox(height: 20),
        SectionCard(
          title: phase,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
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
          style: TextStyle(fontSize: 12, color: Colors.blueGrey),
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
