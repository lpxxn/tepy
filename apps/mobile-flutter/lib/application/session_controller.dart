import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/connection_store.dart';
import '../data/platform_info.dart';
import '../data/mqtt_transport.dart';
import '../domain/commands.dart';
import '../domain/connection_profile.dart';
import '../domain/snapshots.dart';
import 'providers.dart';
import 'session_state.dart';

/// 连接、消息校验与单次键盘任务的协调者。Widget 只表达用户意图，
/// 不直接发布 JSON，也不在 build() 里连接网络。
class SessionController extends Notifier<SessionState> {
  late BrokerTransport _transport;
  late ConnectionStore _store;
  late AppClock _clock;
  StreamSubscription<BrokerEvent>? _subscription;
  Timer? _ticker, _retryTimer, _ackTimer, _replyTimer;
  bool _disposed = false,
      _initialized = false,
      _wantConnection = false,
      _dialing = false;
  int _connectionEpoch = 0, _jobEpoch = 0, _retrySeconds = 1;
  int? _packetId;
  _Pending? _pending;
  Uint8List? _secret;
  String? _jobSession;
  Completer<void>? _cancelSignal;

  @override
  SessionState build() {
    _transport = ref.read(transportFactoryProvider)();
    _store = ref.read(connectionStoreProvider);
    _clock = ref.read(clockProvider);
    _subscription = _transport.events.listen(_onEvent);
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    ref.onDispose(() {
      // onDispose 只清理资源，不再给已销毁的 Provider 设置 state。
      _disposed = true;
      _wantConnection = false;
      _ticker?.cancel();
      _retryTimer?.cancel();
      _ackTimer?.cancel();
      _replyTimer?.cancel();
      wipe(_secret);
      _secret = null;
      if (_cancelSignal?.isCompleted == false) _cancelSignal!.complete();
      _failPending(const AppFailure('操作已结束。'));
      unawaited(_subscription?.cancel());
      unawaited(_transport.dispose());
    });
    return SessionState(
      profile: ref.read(defaultProfileProvider),
      nowMs: _clock.nowMs,
      tickMs: _clock.tickMs,
    );
  }

  /// async/await 让异步代码按阅读顺序表达；等待存储时不会阻塞界面线程。
  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    try {
      final saved = await _store.load();
      if (!_disposed) {
        state = state.copyWith(
          profile: saved,
          savedProfile: saved,
          loading: false,
        );
      }
    } on AppFailure catch (error) {
      if (!_disposed) {
        state = state.copyWith(
          loading: false,
          message: error.message,
          isError: true,
        );
      }
    }
  }

  Future<void> save(ConnectionProfile profile) async {
    if (state.loading || state.saving || _wantConnection) return;
    state = state.copyWith(saving: true);
    try {
      await _store.save(profile);
      if (!_disposed) {
        state = state.copyWith(
          profile: profile,
          savedProfile: profile,
          message: '连接信息已安全保存；不会自动连接。',
          isError: false,
        );
      }
    } on AppFailure catch (error) {
      if (!_disposed) {
        state = state.copyWith(message: error.message, isError: true);
      }
    } finally {
      if (!_disposed) state = state.copyWith(saving: false);
    }
  }

  Future<void> forget() async {
    if (state.saving) return;
    await disconnect();
    if (_disposed) return;
    state = state.copyWith(saving: true);
    try {
      await _store.forget();
      if (!_disposed) {
        state = state.copyWith(
          profile: ref.read(defaultProfileProvider),
          clearSavedProfile: true,
          message: '已清除本机保存的连接信息。',
          isError: false,
        );
      }
    } on AppFailure catch (error) {
      if (!_disposed) {
        state = state.copyWith(message: error.message, isError: true);
      }
    } finally {
      if (!_disposed) state = state.copyWith(saving: false);
    }
  }

  /// 状态页快捷连接只使用已保存档案，不能误用上次的“仅本次连接”配置。
  Future<void> connectSaved() async {
    if (_disposed) return;
    final saved = state.savedProfile;
    if (saved == null) {
      state = state.copyWith(message: '请先在连接页保存连接信息。', isError: true);
      return;
    }
    await connect(saved);
  }

  Future<void> connect(ConnectionProfile profile) async {
    if (state.loading || state.saving || state.busy || _wantConnection) return;
    try {
      profile.validate();
    } on AppFailure catch (error) {
      state = state.copyWith(message: error.message, isError: true);
      return;
    }
    _wantConnection = true;
    _retrySeconds = 1;
    ++_connectionEpoch;
    state = state.copyWith(profile: profile);
    await _dial();
  }

  Future<void> _dial() async {
    if (_disposed ||
        !_wantConnection ||
        _dialing ||
        state.link == LinkState.online) {
      return;
    }
    _dialing = true;
    final epoch = _connectionEpoch;
    state = state.copyWith(
      link: LinkState.connecting,
      clearDevice: true,
      clearMac: true,
      message: '正在连接 MQTT 并订阅状态…',
      isError: false,
    );
    try {
      await _transport.connect(state.profile);
    } on AppFailure catch (error) {
      if (!_disposed && epoch == _connectionEpoch) {
        state = state.copyWith(
          link: LinkState.offline,
          message: error.message,
          isError: true,
        );
      }
    } finally {
      if (!_disposed && epoch == _connectionEpoch) {
        _dialing = false;
        if (state.link != LinkState.online) _scheduleRetry();
      }
    }
  }

  void _scheduleRetry() {
    if (_disposed ||
        !_wantConnection ||
        _dialing ||
        state.link == LinkState.online ||
        _retryTimer?.isActive == true) {
      return;
    }
    state = state.copyWith(link: LinkState.reconnecting);
    _retryTimer = Timer(Duration(seconds: _retrySeconds), () {
      _retryTimer = null;
      // Timer 已经排入事件队列时，cancel 可能来不及；仍由 _dial 核对当前连接。
      unawaited(_dial());
    });
    _retrySeconds = (_retrySeconds * 2).clamp(1, 30);
  }

  /// Android 切入后台也走这条路径。回来只恢复表单，不恢复旧任务或自动输入。
  Future<void> disconnect({bool background = false}) async {
    _wantConnection = false;
    ++_connectionEpoch;
    _dialing = false;
    _retryTimer?.cancel();
    _ackTimer?.cancel();
    _packetId = null;
    _invalidateJob(background ? '已进入后台，后续操作已取消；返回后请手动连接。' : '已断开，后续步骤已取消。');
    if (!_disposed) {
      state = state.copyWith(
        link: LinkState.offline,
        awaitingPuback: false,
        clearDevice: true,
        clearMac: true,
      );
    }
    await _transport.disconnect();
  }

  void _lost() {
    if (_disposed) return;
    _ackTimer?.cancel();
    _packetId = null;
    _invalidateJob('连接中断，结果可能未确认；不会重发或继续输入。');
    state = state.copyWith(
      link: LinkState.offline,
      awaitingPuback: false,
      clearDevice: true,
      clearMac: true,
      isError: true,
    );
    unawaited(_transport.disconnect());
    _scheduleRetry();
  }

  void _onEvent(BrokerEvent event) {
    if (_disposed) return;
    switch (event) {
      case BrokerConnected():
        if (!_wantConnection) return;
        // connect 的 Future 和 Stream 是两个异步信号，先后顺序不能假定。
        // 若 Future 先完成，finally 可能已安排重试；成功后必须撤销它。
        _retryTimer?.cancel();
        _retryTimer = null;
        _retrySeconds = 1;
        state = state.copyWith(
          link: LinkState.online,
          message: 'MQTT 已连接，等待设备和 Mac 状态。',
          isError: false,
        );
      case BrokerDisconnected():
        _lost();
      case BrokerPuback(:final packetId):
        if (packetId == _packetId) {
          _packetId = null;
          _ackTimer?.cancel();
          state = state.copyWith(awaitingPuback: false);
        }
      case BrokerMessage():
        _message(event);
    }
  }

  void _message(BrokerMessage event) {
    if (!_wantConnection || event.bytes.length > 16384) return;
    final profile = state.profile;
    if (event.topic == '${profile.agentPrefix}/availability') {
      if (ascii.decode(event.bytes, allowInvalid: true) == 'offline') {
        state = state.copyWith(clearMac: true);
      }
      return;
    }
    Map<String, dynamic>? json;
    try {
      json = object(jsonDecode(utf8.decode(event.bytes)));
    } catch (_) {
      return;
    }
    if (json == null || json['v'] != 1) return;
    if (event.topic == '${profile.devicePrefix}/reply') {
      final pending = _pending;
      if (event.retained ||
          pending == null ||
          json['id'] != pending.id ||
          !{'sent', 'rejected', 'failed'}.contains(json['status']) ||
          json['error'] is! String ||
          !RegExp(r'^[a-z_]{0,64}$').hasMatch(json['error'] as String)) {
        return;
      }
      if (!pending.result.isCompleted) {
        pending.result.complete((
          status: json['status'] as String,
          error: json['error'] as String,
        ));
      }
    } else if (event.topic == '${profile.devicePrefix}/state') {
      if (json['device_id'] == profile.deviceId && json['online'] == false) {
        state = state.copyWith(clearDevice: true);
        _checkRunningJob();
        return;
      }
      final device = DeviceSnapshot.parse(json, profile.deviceId, _clock);
      if (device != null) {
        state = state.copyWith(device: device);
        _checkRunningJob();
      }
    } else if (profile.agentId.isNotEmpty &&
        event.topic == '${profile.agentPrefix}/state') {
      final mac = MacSnapshot.parse(json, profile.agentId, _clock),
          old = state.mac;
      if (mac != null &&
          !(old != null &&
              old.session == mac.session &&
              mac.sequence <= old.sequence)) {
        state = state.copyWith(mac: mac);
      }
    }
  }

  void _tick() {
    if (_disposed) return;
    state = state.copyWith(
      nowMs: _clock.nowMs,
      tickMs: _clock.tickMs,
      clearDevice: state.device?.fresh(_clock) == false,
      clearMac: state.mac?.fresh(_clock) == false,
    );
    _checkRunningJob();
  }

  void _checkRunningJob() {
    if (state.busy &&
        (state.link != LinkState.online ||
            state.device?.ready(_clock) != true ||
            state.device?.session != _jobSession)) {
      _invalidateJob('设备状态过期、蓝牙中断或会话改变，后续步骤已取消。');
    }
  }

  void _ensureJob(int token) {
    if (_disposed ||
        token != _jobEpoch ||
        !state.busy ||
        state.link != LinkState.online ||
        state.device?.ready(_clock) != true ||
        state.device?.session != _jobSession) {
      throw const AppFailure('本次操作已经停止，不会继续发送。');
    }
  }

  void _failPending(AppFailure error) {
    final pending = _pending;
    _pending = null;
    _replyTimer?.cancel();
    if (pending != null && !pending.result.isCompleted) {
      pending.result.completeError(error);
    }
  }

  void _invalidateJob(String message) {
    ++_jobEpoch;
    wipe(_secret);
    _secret = null;
    _jobSession = null;
    if (_cancelSignal?.isCompleted == false) _cancelSignal!.complete();
    _failPending(const AppFailure('本次操作已取消。'));
    if (!_disposed) {
      state = state.copyWith(phase: JobPhase.idle, message: message);
    }
    // 不清 PUBACK 定时器：即使用户取消等待，未确认的网络包仍受六秒上限约束。
  }

  void cancel() {
    if (state.busy) _invalidateJob('后续步骤已取消；已提交的按键无法撤回。');
  }

  Future<void> _operate({
    Uint8List? input,
    void Function()? validate,
    required Future<void> Function(int token) work,
  }) async {
    int? token;
    try {
      validate?.call();
      if (input != null) validateText(input);
      if (state.busy ||
          _pending != null ||
          _packetId != null ||
          state.link != LinkState.online ||
          state.device?.ready(_clock) != true ||
          state.device?.busy != false) {
        throw const AppFailure('设备尚未就绪或已有操作，请等待最新状态。');
      }
      token = ++_jobEpoch;
      _jobSession = state.device!.session;
      _secret = input;
      _cancelSignal = Completer<void>();
      state = state.copyWith(
        phase: JobPhase.sending,
        hidResult: '等待设备回执',
        macResult: '尚未确认',
        message: '正在执行单次操作…',
        isError: false,
      );
      await work(token);
    } on AppFailure catch (error) {
      if (!_disposed && (token == null || token == _jobEpoch)) {
        state = state.copyWith(message: error.message, isError: true);
      }
    } catch (_) {
      if (!_disposed && (token == null || token == _jobEpoch)) {
        state = state.copyWith(message: '操作结果未确认，请人工检查；不会自动重试。', isError: true);
      }
    } finally {
      wipe(input);
      if (!_disposed && token != null && token == _jobEpoch) {
        wipe(_secret);
        _secret = null;
        _jobSession = null;
        if (_cancelSignal?.isCompleted == false) _cancelSignal!.complete();
        state = state.copyWith(phase: JobPhase.idle);
      }
    }
  }

  Future<void> _send(
    int token,
    String type,
    Map<String, Object> payload, {
    int strokes = 1,
  }) async {
    _ensureJob(token);
    if (_pending != null || _packetId != null || state.device!.busy) {
      throw const AppFailure('设备忙碌，动作没有排队。');
    }
    final pending = _Pending(requestId());
    _pending = pending;
    final wire = encodeCommand(
      id: pending.id,
      session: _jobSession!,
      nowMs: _clock.nowMs,
      type: type,
      payload: payload,
    );
    try {
      _packetId = _transport.publish('${state.profile.devicePrefix}/cmd', wire);
      state = state.copyWith(awaitingPuback: true);
      _ackTimer = Timer(const Duration(seconds: 6), _lost);
      final milliseconds = (strokes * 400 + 20000).clamp(30000, 225200);
      _replyTimer = Timer(Duration(milliseconds: milliseconds), () {
        _failPending(const AppFailure('等待 HID 回执超时，结果未确认；不自动重试。'));
      });
      if (type == 'type_text') {
        wipe(_secret);
        _secret = null;
      }
    } catch (_) {
      _pending = null;
      throw const AppFailure('指令提交失败或结果未确认，不自动重发。');
    } finally {
      wipe(wire);
    }
    try {
      final reply = await pending.result.future;
      _ensureJob(token);
      if (reply.status != 'sent') {
        throw AppFailure('设备未完成动作（${reply.error}），不自动重试。');
      }
      state = state.copyWith(hidResult: 'HID 发送完成');
    } finally {
      if (identical(_pending, pending)) {
        _pending = null;
        _replyTimer?.cancel();
      }
    }
  }

  Future<void> _delay(int token, Duration duration) async {
    _ensureJob(token);
    final done = Completer<void>();
    final timer = Timer(duration, done.complete);
    unawaited(
      _cancelSignal!.future.then((_) {
        if (!done.isCompleted) done.complete();
      }),
    );
    try {
      await done.future;
      _ensureJob(token);
    } finally {
      timer.cancel();
    }
  }

  Future<void> wake() => _operate(
    work: (token) async {
      state = state.copyWith(phase: JobPhase.waking);
      await _send(token, 'wake', {});
      state = state.copyWith(message: '唤醒按键已发送，屏幕是否点亮请在 Mac 确认。');
    },
  );

  Future<void> typeText(Uint8List input, {bool enter = false}) => _operate(
    input: input,
    work: (token) async {
      state = state.copyWith(phase: JobPhase.typing);
      await _send(token, 'type_text', {
        'text': ascii.decode(input),
        'press_enter': enter,
      }, strokes: input.length + (enter ? 1 : 0));
      state = state.copyWith(message: 'HID 发送完成，实际输入位置与效果请在 Mac 确认。');
    },
  );

  Future<void> key(String key, List<String> modifiers) => _operate(
    validate: () => validateKey(key, modifiers),
    work: (token) async {
      await _send(token, 'key', {'key': key, 'modifiers': modifiers});
      state = state.copyWith(message: '按键发送完成。');
    },
  );

  Future<void> unlock(
    Uint8List input, {
    bool enter = false,
    int waitSeconds = 3,
  }) => _operate(
    input: input,
    validate: () {
      if (waitSeconds < 0 ||
          waitSeconds > 30 ||
          state.profile.agentId.isEmpty) {
        throw const AppFailure('解锁需配置 Mac 代理 ID，等待时间为 0–30 秒。');
      }
      if (state.mac?.fresh(_clock) == true &&
          state.mac?.lock == LockState.unlocked) {
        throw const AppFailure('Mac 报告未锁定，没有发送密码。');
      }
    },
    work: (token) async {
      state = state.copyWith(phase: JobPhase.waking);
      await _send(token, 'wake', {});
      final wakeAt = _clock.nowMs;
      state = state.copyWith(
        phase: JobPhase.waitingForMac,
        message: '等待间隔及唤醒之后的 Mac 锁定状态…',
      );
      await _delay(token, Duration(seconds: waitSeconds));
      final waitStart = _clock.tickMs;
      while (true) {
        _ensureJob(token);
        final mac = state.mac;
        if (mac != null && mac.fresh(_clock) && mac.observedAt >= wakeAt) {
          if (mac.lock == LockState.unlocked) {
            state = state.copyWith(macResult: 'Mac 报告未锁定', message: '没有发送密码。');
            return;
          }
          if (mac.inputEligible(state.profile.deviceId) &&
              state.device?.busy == false &&
              _packetId == null) {
            break;
          }
        }
        if (_clock.tickMs - waitStart >= 20000) {
          throw const AppFailure('未等到有效的 Mac 锁定／目标键盘状态，密码未发送。');
        }
        await _delay(token, const Duration(milliseconds: 200));
      }
      state = state.copyWith(phase: JobPhase.typing);
      final inputAt = _clock.nowMs;
      await _send(token, 'type_text', {
        'text': ascii.decode(input),
        'press_enter': enter,
      }, strokes: input.length + (enter ? 1 : 0));
      state = state.copyWith(
        phase: JobPhase.observing,
        message: 'HID 已发送，等待 Mac 的新状态，不重试密码。',
      );
      final observeStart = _clock.tickMs;
      while (_clock.tickMs - observeStart < 20000) {
        _ensureJob(token);
        final mac = state.mac;
        if (mac != null &&
            mac.fresh(_clock) &&
            mac.observedAt >= inputAt &&
            mac.lock == LockState.unlocked) {
          state = state.copyWith(
            macResult: 'Mac 报告已解锁',
            message: 'HID 发送完成，Mac 随后报告已解锁。',
          );
          return;
        }
        await _delay(token, const Duration(milliseconds: 200));
      }
      state = state.copyWith(
        macResult: '尚未确认 Mac 解锁',
        message: 'HID 已发送，未观察到解锁反馈；请人工查看，不自动重试。',
      );
    },
  );
}

typedef _Reply = ({String status, String error});

final class _Pending {
  _Pending(this.id);
  final String id;
  final result = Completer<_Reply>();
}
