import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/mac_password_controller.dart';
import '../../application/providers.dart';
import '../../data/mac_password_store.dart';
import '../../domain/commands.dart';
import '../../domain/connection_profile.dart';
import 'common.dart';
import 'secret_text_field.dart';

class MacPasswordSettings extends ConsumerWidget {
  const MacPasswordSettings({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final saved = ref.watch(macPasswordProvider),
        session = ref.watch(sessionProvider);
    final enabled =
        !saved.busy &&
        !session.busy &&
        !session.preparingInput &&
        !session.maintenance;
    return SectionCard(
      title: 'Mac 登录密码',
      icon: Icons.password_rounded,
      subtitle: saved.info == null
          ? '保存一次，之后解锁可选择直接使用。'
          : '当前目标已保存登录密码，解锁时无需再次输入。',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            '按你的设置，密码保存在本机明文 JSON 中，用于本项目的锁屏解锁流程。',
            style: TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 8,
            children: [
              FilledButton.tonalIcon(
                key: const Key('macPasswordSettings'),
                onPressed: enabled
                    ? () async {
                        final result = await showDialog<_SavedInput>(
                          context: context,
                          builder: (_) => _PasswordDialog(
                            options: saved.info ?? const MacPasswordInfo(),
                          ),
                        );
                        if (result == null) return;
                        if (!context.mounted) {
                          wipe(result.bytes);
                          return;
                        }
                        await ref
                            .read(macPasswordProvider.notifier)
                            .save(result.bytes, result.options);
                      }
                    : null,
                icon: const Icon(Icons.edit_outlined, size: 18),
                label: Text(saved.info == null ? '设置并保存' : '替换已保存密码'),
              ),
              if (saved.info != null)
                TextButton(
                  onPressed: enabled
                      ? () async {
                          final confirmed = await showDialog<bool>(
                            context: context,
                            builder: (dialog) => AlertDialog(
                              title: const Text('清除保存的 Mac 密码？'),
                              content: const Text(
                                '清除当前 Mac、ESP32 和 Broker 对应的条目。',
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(dialog, false),
                                  child: const Text('取消'),
                                ),
                                FilledButton(
                                  onPressed: () => Navigator.pop(dialog, true),
                                  child: const Text('清除'),
                                ),
                              ],
                            ),
                          );
                          if (confirmed == true) {
                            await ref
                                .read(macPasswordProvider.notifier)
                                .clear();
                          }
                        }
                      : null,
                  child: const Text('清除保存的密码'),
                ),
              TextButton(
                onPressed: enabled
                    ? () => ref
                          .read(macPasswordProvider.notifier)
                          .refresh(session.profile)
                    : null,
                child: const Text('重新读取 JSON'),
              ),
            ],
          ),
          if (saved.info != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                '默认等待 ${saved.info!.waitSeconds} 秒 · ${saved.info!.enter ? '输入后回车' : '输入后不回车'}',
                style: const TextStyle(fontSize: 12),
              ),
            ),
          if (saved.message.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                saved.message,
                style: TextStyle(
                  fontSize: 12,
                  color: saved.error ? Colors.redAccent : null,
                ),
              ),
            ),
          if (saved.path.isNotEmpty) ...[
            const SizedBox(height: 12),
            const Text('本地配置位置', style: TextStyle(fontSize: 11)),
            const SizedBox(height: 4),
            SelectableText(saved.path, style: const TextStyle(fontSize: 10)),
          ],
        ],
      ),
    );
  }
}

final class _SavedInput {
  const _SavedInput(this.bytes, this.options);
  final Uint8List bytes;
  final MacPasswordInfo options;
}

class _PasswordDialog extends StatefulWidget {
  const _PasswordDialog({required this.options});
  final MacPasswordInfo options;
  @override
  State<_PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends State<_PasswordDialog>
    with WidgetsBindingObserver {
  final _password = TextEditingController();
  late bool _enter;
  late double _wait;
  String? _error;
  @override
  void initState() {
    super.initState();
    _enter = widget.options.enter;
    _wait = widget.options.waitSeconds.toDouble();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _password.clear();
      if (mounted && Navigator.of(context).canPop()) Navigator.pop(context);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _password.clear();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('保存 Mac 登录密码'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            '将保存到当前连接目标对应的本机 JSON 文件。',
            style: TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 18),
          SecretTextField(
            inputKey: const Key('savedMacPasswordInput'),
            controller: _password,
            maxLength: 512,
            decoration: InputDecoration(
              labelText: 'Mac 登录密码',
              errorText: _error,
            ),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('默认输入后按回车', style: TextStyle(fontSize: 13)),
            value: _enter,
            onChanged: (v) => setState(() => _enter = v),
          ),
          Text('默认唤醒后等待 ${_wait.round()} 秒'),
          Slider(
            value: _wait,
            min: 0,
            max: 30,
            divisions: 30,
            onChanged: (v) => setState(() => _wait = v),
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
        key: const Key('saveMacPassword'),
        onPressed: () {
          final bytes = Uint8List.fromList(utf8.encode(_password.text));
          try {
            validateText(bytes);
            _password.clear();
            Navigator.pop(
              context,
              _SavedInput(
                bytes,
                MacPasswordInfo(enter: _enter, waitSeconds: _wait.round()),
              ),
            );
          } on AppFailure catch (e) {
            wipe(bytes);
            setState(() => _error = e.message);
          }
        },
        child: const Text('保存到本机 JSON'),
      ),
    ],
  );
}
