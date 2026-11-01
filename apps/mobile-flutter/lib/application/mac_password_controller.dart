import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/mac_password_store.dart';
import '../domain/commands.dart';
import '../domain/connection_profile.dart';
import 'providers.dart';

final macPasswordStoreProvider = Provider<MacPasswordStore>(
  (ref) => JsonMacPasswordStore(),
);
final macPasswordProvider =
    NotifierProvider<MacPasswordController, MacPasswordState>(
      MacPasswordController.new,
    );

/// Riverpod 状态只放是否已保存、默认选项和路径，避免 UI rebuild 携带真实密码。
final class MacPasswordState {
  const MacPasswordState({
    this.info,
    this.busy = false,
    this.path = '',
    this.message = '',
    this.error = false,
  });
  final MacPasswordInfo? info;
  final bool busy, error;
  final String path, message;
}

class MacPasswordController extends Notifier<MacPasswordState> {
  int _epoch = 0;
  bool _disposed = false;
  @override
  MacPasswordState build() {
    ref.onDispose(() {
      _disposed = true;
      ++_epoch;
    });
    ref.listen(
      sessionProvider.select((s) => s.profile),
      (_, next) => unawaited(refresh(next)),
    );
    Future.microtask(() {
      if (!_disposed) unawaited(refresh(ref.read(sessionProvider).profile));
    });
    return const MacPasswordState();
  }

  Future<void> refresh(ConnectionProfile target) async {
    final epoch = ++_epoch;
    state = MacPasswordState(path: state.path, busy: true);
    try {
      final store = ref.read(macPasswordStoreProvider);
      final path = await store.location(), info = await store.inspect(target);
      if (!_disposed && epoch == _epoch) {
        state = MacPasswordState(info: info, path: path);
      }
    } on AppFailure catch (e) {
      if (!_disposed && epoch == _epoch) {
        state = MacPasswordState(
          path: state.path,
          message: e.message,
          error: true,
        );
      }
    } catch (_) {
      if (!_disposed && epoch == _epoch) {
        state = MacPasswordState(
          path: state.path,
          message: '无法读取本地密码配置。',
          error: true,
        );
      }
    }
  }

  Future<void> save(Uint8List bytes, MacPasswordInfo options) async {
    final target = ref.read(sessionProvider).profile, epoch = ++_epoch;
    state = MacPasswordState(info: state.info, path: state.path, busy: true);
    try {
      await ref.read(macPasswordStoreProvider).save(target, bytes, options);
      if (!_disposed && epoch == _epoch) {
        state = MacPasswordState(
          info: options,
          path: state.path,
          message: '已保存当前目标的 Mac 登录密码。',
        );
      }
    } on AppFailure catch (e) {
      if (!_disposed && epoch == _epoch) {
        state = MacPasswordState(
          info: state.info,
          path: state.path,
          message: e.message,
          error: true,
        );
      }
    } finally {
      wipe(bytes);
    }
  }

  Future<void> clear() async {
    final target = ref.read(sessionProvider).profile, epoch = ++_epoch;
    state = MacPasswordState(info: state.info, path: state.path, busy: true);
    try {
      await ref.read(macPasswordStoreProvider).remove(target);
      if (!_disposed && epoch == _epoch) {
        state = MacPasswordState(path: state.path, message: '已清除当前目标的登录密码。');
      }
    } on AppFailure catch (e) {
      if (!_disposed && epoch == _epoch) {
        state = MacPasswordState(
          info: state.info,
          path: state.path,
          message: e.message,
          error: true,
        );
      }
    }
  }
}
