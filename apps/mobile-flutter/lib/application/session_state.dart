import '../domain/connection_profile.dart';
import '../domain/snapshots.dart';

enum LinkState { offline, connecting, online, reconnecting }

enum JobPhase { idle, waking, sending, waitingForMac, typing, observing }

/// Riverpod 对外发布的不可变快照。
/// 特别注意：这里没有“本次要输入的文字／Mac 密码”字段。
final class SessionState implements AppClock {
  const SessionState({
    this.profile = const ConnectionProfile(),
    this.savedProfile,
    this.loading = true,
    this.saving = false,
    this.link = LinkState.offline,
    this.phase = JobPhase.idle,
    this.device,
    this.mac,
    this.nowMs = 0,
    this.tickMs = 0,
    this.awaitingPuback = false,
    this.message = '连接 Broker 后查看 Mac 状态并执行操作。',
    this.isError = false,
    this.hidResult = '尚未发送',
    this.macResult = '尚未确认',
  });
  final ConnectionProfile profile;

  /// 安全存储中实际保存的档案，与“仅本次连接”的临时档案分别记录。
  final ConnectionProfile? savedProfile;
  final bool loading, saving, awaitingPuback, isError;
  final LinkState link;
  final JobPhase phase;
  final DeviceSnapshot? device;
  final MacSnapshot? mac;
  @override
  final int nowMs;
  @override
  final int tickMs;
  final String message, hidResult, macResult;
  bool get busy => phase != JobPhase.idle;
  bool get canAct =>
      link == LinkState.online &&
      !busy &&
      !awaitingPuback &&
      device?.ready(this) == true &&
      device?.busy == false;

  /// 可空字段通过 clearX 显式清除，避免“传 null 是保留还是清除”的歧义。
  SessionState copyWith({
    ConnectionProfile? profile,
    ConnectionProfile? savedProfile,
    bool clearSavedProfile = false,
    bool? loading,
    bool? saving,
    LinkState? link,
    JobPhase? phase,
    DeviceSnapshot? device,
    MacSnapshot? mac,
    bool clearDevice = false,
    bool clearMac = false,
    int? nowMs,
    int? tickMs,
    bool? awaitingPuback,
    String? message,
    bool? isError,
    String? hidResult,
    String? macResult,
  }) => SessionState(
    profile: profile ?? this.profile,
    savedProfile: clearSavedProfile
        ? null
        : (savedProfile ?? this.savedProfile),
    loading: loading ?? this.loading,
    saving: saving ?? this.saving,
    link: link ?? this.link,
    phase: phase ?? this.phase,
    device: clearDevice ? null : (device ?? this.device),
    mac: clearMac ? null : (mac ?? this.mac),
    nowMs: nowMs ?? this.nowMs,
    tickMs: tickMs ?? this.tickMs,
    awaitingPuback: awaitingPuback ?? this.awaitingPuback,
    message: message ?? this.message,
    isError: isError ?? this.isError,
    hidResult: hidResult ?? this.hidResult,
    macResult: macResult ?? this.macResult,
  );
}
