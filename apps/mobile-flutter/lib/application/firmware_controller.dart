import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/firmware_client.dart';
import '../domain/connection_profile.dart';
import '../domain/firmware_image.dart';
import '../domain/serial_firmware.dart';
import 'providers.dart';
import 'usb_controller.dart';

final firmwareClientFactoryProvider = Provider<FirmwareClient Function()>(
  (ref) => HttpFirmwareClient.new,
);
final firmwarePickerProvider = Provider<FirmwarePicker>(
  (ref) => NativeFirmwarePicker(),
);
final firmwareTargetStoreProvider = Provider<FirmwareTargetStore>(
  (ref) => SecureFirmwareTargetStore(),
);
// 把等待也注入：测试可以立即模拟重启，不用实际等待数十秒。
final firmwareDelayProvider = Provider<Future<void> Function(Duration)>(
  (ref) =>
      (duration) => Future<void>.delayed(duration),
);
final firmwareProvider = NotifierProvider<FirmwareController, FirmwareState>(
  FirmwareController.new,
);

enum FirmwarePhase {
  idle,
  reading,
  selecting,
  uploading,
  verifying,
  verified,
  failed,
}

enum FirmwareTransport { network, usb }

final class FirmwareState {
  const FirmwareState({
    this.phase = FirmwarePhase.idle,
    this.transport = FirmwareTransport.network,
    this.target,
    this.device,
    this.image,
    this.progress = 0,
    this.message = '连接 ESP32 的 HTTP 管理地址，选择应用镜像后升级。',
    this.error = false,
  });
  final FirmwarePhase phase;
  final FirmwareTransport transport;
  final FirmwareTarget? target;
  final Map<String, dynamic>? device;
  final FirmwareImage? image;
  final double progress;
  final String message;
  final bool error;
  bool get busy => {
    FirmwarePhase.reading,
    FirmwarePhase.selecting,
    FirmwarePhase.uploading,
    FirmwarePhase.verifying,
  }.contains(phase);
  bool get transferring =>
      phase == FirmwarePhase.uploading || phase == FirmwarePhase.verifying;
  FirmwareState copyWith({
    FirmwarePhase? phase,
    FirmwareTransport? transport,
    FirmwareTarget? target,
    Map<String, dynamic>? device,
    FirmwareImage? image,
    bool clearDevice = false,
    bool clearTarget = false,
    bool clearImage = false,
    double? progress,
    String? message,
    bool? error,
  }) => FirmwareState(
    phase: phase ?? this.phase,
    transport: transport ?? this.transport,
    target: clearTarget ? null : (target ?? this.target),
    device: clearDevice ? null : device ?? this.device,
    image: clearImage ? null : image ?? this.image,
    progress: progress ?? this.progress,
    message: message ?? this.message,
    error: error ?? this.error,
  );
}

/// 页面只发起意图；这个控制器拥有网络资源、互斥租约和升级状态机。
/// Future.timeout 不会停止原 Future，epoch 用于忽略超时或取消后的迟到结果。
class FirmwareController extends Notifier<FirmwareState> {
  FirmwareClient? _client;
  bool _disposed = false, _ownsMaintenance = false;
  int _epoch = 0;
  bool _usbJob = false;
  ({String deviceId, String session, String version})? _usbExpected;
  @override
  FirmwareState build() {
    ref.listen(usbProvider.select((s) => s.connected ? s.status : null), (
      _,
      next,
    ) {
      final expected = _usbExpected;
      if (_disposed ||
          expected == null ||
          next == null ||
          state.phase != FirmwarePhase.verifying) {
        return;
      }
      try {
        final current = validateUsbFirmwareStatus(next, expected.deviceId);
        if (current['session'] == expected.session) return;
        _usbExpected = null;
        state = state.copyWith(
          phase: current['firmware'] == expected.version
              ? FirmwarePhase.verified
              : FirmwarePhase.failed,
          device: current,
          error: current['firmware'] != expected.version,
          message: current['firmware'] == expected.version
              ? 'USB 已重新连接，确认运行版本 ${expected.version}。'
              : 'USB 重启后的版本与镜像不一致，可能已回滚；请人工检查。',
        );
      } on AppFailure catch (e) {
        _usbExpected = null;
        state = state.copyWith(
          phase: FirmwarePhase.failed,
          message: e.message,
          error: true,
          clearDevice: true,
        );
      }
    });
    ref.onDispose(() {
      _disposed = true;
      ++_epoch;
      _client?.close();
    });
    Future.microtask(_restore);
    return const FirmwareState();
  }

  Future<void> _restore() async {
    if (_disposed) return;
    final epoch = _epoch;
    try {
      final target = await ref.read(firmwareTargetStoreProvider).load();
      if (!_disposed && epoch == _epoch && target != null) {
        state = state.copyWith(target: target);
      }
    } on AppFailure catch (e) {
      if (!_disposed && epoch == _epoch) {
        state = state.copyWith(message: e.message, error: true);
      }
    }
  }

  bool _alive(int epoch) => !_disposed && epoch == _epoch;
  void selectTransport(FirmwareTransport transport) {
    if (state.busy || state.transport == transport) return;
    _usbExpected = null;
    state = state.copyWith(
      transport: transport,
      phase: FirmwarePhase.idle,
      clearDevice: true,
      error: false,
      message: transport == FirmwareTransport.usb
          ? '先在设备页连接 USB，再读取版本。固件需支持 USB 升级。'
          : '连接 ESP32 的 HTTP 管理地址，选择应用镜像后升级。',
    );
  }

  Future<void> readUsbStatus(String deviceId) async {
    if (state.busy) return;
    final epoch = ++_epoch;
    state = state.copyWith(
      transport: FirmwareTransport.usb,
      phase: FirmwarePhase.reading,
      clearDevice: true,
      error: false,
      message: '正在通过 USB 核对目标设备…',
    );
    _usbJob = true;
    try {
      final current = await ref
          .read(usbProvider.notifier)
          .firmwareOperation(
            (client) async => validateUsbFirmwareStatus(
              await client.request('status.get'),
              deviceId,
            ),
          );
      if (_alive(epoch)) {
        state = state.copyWith(
          phase: FirmwarePhase.idle,
          device: current,
          message: supportsUsbFirmware(current)
              ? 'USB 设备已确认，可选择镜像升级。'
              : '当前固件尚不支持 USB 升级，请先用网络 OTA 或 IDF 更新到固件 0.3.0。',
        );
      }
    } on AppFailure catch (e) {
      if (_alive(epoch)) {
        state = state.copyWith(
          phase: FirmwarePhase.failed,
          message: e.message,
          error: true,
        );
      }
    } catch (_) {
      if (_alive(epoch)) {
        state = state.copyWith(
          phase: FirmwarePhase.failed,
          message: 'USB 状态读取失败，请重新连接设备。',
          error: true,
        );
      }
    } finally {
      if (_alive(epoch)) _usbJob = false;
    }
  }

  Future<void> upgradeUsb(String deviceId) async {
    final image = state.image;
    if (state.busy ||
        image == null ||
        state.transport != FirmwareTransport.usb ||
        !supportsUsbFirmware(state.device)) {
      return;
    }
    final epoch = ++_epoch;
    _usbJob = true;
    state = state.copyWith(
      phase: FirmwarePhase.uploading,
      progress: 0,
      error: false,
      message: '正在通过 USB 写入备用分区，请保持数据线连接…',
    );
    try {
      final before = await ref
          .read(usbProvider.notifier)
          .firmwareOperation(
            (client) => sendUsbFirmware(
              client,
              image,
              deviceId,
              () => _alive(epoch),
              (sent, total) {
                if (_alive(epoch)) {
                  state = state.copyWith(progress: sent / total);
                }
              },
            ),
          );
      if (!_alive(epoch)) return;
      _usbExpected = (
        deviceId: deviceId,
        session: before['session'] as String,
        version: image.version,
      );
      state = state.copyWith(
        phase: FirmwarePhase.verifying,
        progress: 1,
        clearDevice: true,
        message: '镜像已校验并接受。请等设备重启，在设备页刷新并重新连接 USB，应用将核对新会话与运行版本。',
      );
      await ref.read(usbProvider.notifier).disconnect();
    } on AppFailure catch (e) {
      if (_alive(epoch)) {
        state = state.copyWith(
          phase: FirmwarePhase.failed,
          clearDevice: true,
          message: e.message,
          error: true,
        );
      }
    } catch (_) {
      if (_alive(epoch)) {
        state = state.copyWith(
          phase: FirmwarePhase.failed,
          clearDevice: true,
          message: 'USB 写入结果尚未确认，请重新连接读取版本；不会自动重传。',
          error: true,
        );
      }
    } finally {
      if (_alive(epoch)) _usbJob = false;
    }
  }

  void _release() {
    if (_ownsMaintenance && !_disposed) {
      _ownsMaintenance = false;
      ref.read(sessionProvider.notifier).setMaintenance(false);
    }
  }

  Future<void> readStatus(FirmwareTarget target, {bool remember = true}) async {
    if (state.busy) return;
    final epoch = ++_epoch;
    state = state.copyWith(
      transport: FirmwareTransport.network,
      phase: FirmwarePhase.reading,
      clearDevice: true,
      message: '正在核对设备身份与运行版本…',
      error: false,
    );
    final client = ref.read(firmwareClientFactoryProvider)();
    _client = client;
    try {
      target.validate();
      final value = await client.status(target);
      if (!_alive(epoch)) return;
      if (remember) await ref.read(firmwareTargetStoreProvider).save(target);
      if (_alive(epoch)) {
        state = state.copyWith(
          phase: FirmwarePhase.idle,
          target: target,
          device: value,
          message: '设备身份已确认，可以选择镜像并升级。',
        );
      }
    } on AppFailure catch (e) {
      if (_alive(epoch)) {
        state = state.copyWith(
          phase: FirmwarePhase.failed,
          message: e.message,
          error: true,
        );
      }
    } finally {
      client.close();
      if (identical(_client, client)) _client = null;
    }
  }

  Future<void> chooseImage() async {
    if (state.busy) return;
    final epoch = ++_epoch, previous = state.image;
    state = state.copyWith(
      phase: FirmwarePhase.selecting,
      message: '请选择 tepy.bin，正在检查镜像…',
      error: false,
    );
    try {
      final image = await ref.read(firmwarePickerProvider).pick();
      if (_alive(epoch)) {
        state = state.copyWith(
          phase: FirmwarePhase.idle,
          image: image ?? previous,
          message: image == null ? '未更换镜像。' : '镜像检查通过，请核对版本与目标设备。',
        );
      }
    } on AppFailure catch (e) {
      if (_alive(epoch)) {
        state = state.copyWith(
          phase: FirmwarePhase.failed,
          clearImage: true,
          message: e.message,
          error: true,
        );
      }
    }
  }

  Future<void> upgrade() async {
    final target = state.target, image = state.image;
    if (state.busy ||
        state.transport != FirmwareTransport.network ||
        target == null ||
        image == null ||
        state.device == null) {
      return;
    }
    if (ref.read(usbProvider).busy ||
        !ref.read(sessionProvider.notifier).setMaintenance(true)) {
      state = state.copyWith(message: '正在进行键盘或设备操作，请完成后再升级。', error: true);
      return;
    }
    _ownsMaintenance = true;
    // 每次操作创建独立 HTTP Client，取消时可直接关闭连接，不复用旧上传。
    final epoch = ++_epoch, client = ref.read(firmwareClientFactoryProvider)();
    _client = client;
    state = state.copyWith(
      phase: FirmwarePhase.reading,
      progress: 0,
      message: '升级前重新检查目标设备…',
      error: false,
    );
    try {
      final before = await client.status(target);
      if (!_alive(epoch)) return;
      if (before['busy'] != false) throw const AppFailure('ESP32 正忙，请稍后读取状态。');
      state = state.copyWith(
        phase: FirmwarePhase.uploading,
        message: '正在上传镜像，请保持设备供电和网络连接。',
      );
      await client
          .upload(target, image, (sent, total) {
            if (_alive(epoch)) state = state.copyWith(progress: sent / total);
          })
          .timeout(const Duration(seconds: 120));
      if (!_alive(epoch)) return;
      state = state.copyWith(
        phase: FirmwarePhase.verifying,
        progress: 1,
        clearDevice: true,
        message: '设备已接受镜像，正在等待重启并核对运行版本…',
      );
      // HTTP 接受上传不代表新固件启动成功：必须观察重启后的会话和实际版本。
      final verified = await _verify(
        client,
        target,
        image,
        before['session'] as String,
        epoch,
      ).timeout(const Duration(seconds: 35));
      if (_alive(epoch)) {
        state = state.copyWith(
          phase: FirmwarePhase.verified,
          device: verified,
          message: '设备已重启，运行版本 ${image.version}。',
        );
      }
    } on AppFailure catch (e) {
      if (_alive(epoch)) {
        state = state.copyWith(
          phase: FirmwarePhase.failed,
          clearDevice: true,
          message: e.message,
          error: true,
        );
        _release();
        ++_epoch;
      }
    } catch (_) {
      if (_alive(epoch)) {
        state = state.copyWith(
          phase: FirmwarePhase.failed,
          clearDevice: true,
          message: '升级结果尚未确认，请重新读取设备状态；不会自动重传。',
          error: true,
        );
        _release();
        ++_epoch;
      }
    } finally {
      client.close();
      if (identical(_client, client)) _client = null;
      if (_alive(epoch)) _release();
    }
  }

  Future<Map<String, dynamic>> _verify(
    FirmwareClient client,
    FirmwareTarget target,
    FirmwareImage image,
    String oldSession,
    int epoch,
  ) async {
    for (var i = 0; i < 12; i++) {
      if (!_alive(epoch)) throw const AppFailure('升级等待已停止。');
      await ref.read(firmwareDelayProvider)(const Duration(seconds: 2));
      if (!_alive(epoch)) throw const AppFailure('升级等待已停止。');
      try {
        final current = await client.status(target);
        if (current['session'] != oldSession) {
          if (current['firmware'] != image.version) throw const _WrongVersion();
          return current;
        }
      } on _WrongVersion {
        throw const AppFailure('重启后的版本与镜像不一致，可能已回滚；请人工检查。');
      } on AppFailure {
        /* 重启期间只重试读取，不重传镜像。 */
      }
    }
    throw const AppFailure('尚未确认设备重启和新版本，请重新读取状态，不自动重传。');
  }

  void cancel({bool background = false}) {
    // 系统文件选择器会暂时把应用切到后台；它只选择文件，不会自动执行升级。
    if (background && state.phase == FirmwarePhase.selecting) return;
    // 等待人工重新插线/授权只有只读核对，没有待发送的数据，可跨后台保留。
    if (background &&
        state.transport == FirmwareTransport.usb &&
        state.phase == FirmwarePhase.verifying) {
      return;
    }
    if (!state.busy) return;
    ++_epoch;
    _usbExpected = null;
    if (_usbJob) {
      _usbJob = false;
      unawaited(ref.read(usbProvider.notifier).disconnect());
    }
    _client?.close();
    _client = null;
    _release();
    state = state.copyWith(
      phase: FirmwarePhase.failed,
      clearDevice: true,
      message: '操作已停止，写入结果可能未确认；请重新读取运行版本。',
      error: true,
    );
  }

  Future<void> forget() async {
    if (state.busy) return;
    try {
      await ref.read(firmwareTargetStoreProvider).clear();
      state = state.copyWith(
        clearDevice: true,
        clearTarget: true,
        message: '已清除固件管理的保存连接。',
      );
    } on AppFailure catch (e) {
      state = state.copyWith(message: e.message, error: true);
    }
  }
}

final class _WrongVersion implements Exception {
  const _WrongVersion();
}
