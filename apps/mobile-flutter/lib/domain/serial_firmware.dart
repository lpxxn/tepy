import 'dart:convert';

import 'connection_profile.dart';
import 'firmware_image.dart';
import 'serial_management.dart';
import 'snapshots.dart';

/// USB 直接读取设备状态，不依赖 MQTT、SNTP、Wi-Fi 或 Mac 在线。
Map<String, dynamic> validateUsbFirmwareStatus(
  Map<String, dynamic> status,
  String deviceId,
) {
  // 启动会话独立于 MQTT：未配网也可以更新，Broker 重连不会冒充设备重启。
  final session = status['boot_session'] ?? status['session'];
  if (!RegExp(r'^[a-f0-9]{12}$').hasMatch(deviceId) ||
      status['v'] != 1 ||
      status['device_id'] != deviceId ||
      status['firmware'] is! String ||
      (status['firmware'] as String).isEmpty ||
      (status['firmware'] as String).length > 64 ||
      session is! String ||
      !(RegExp(r'^[a-f0-9]{32}$').hasMatch(session) ||
          (!supportsUsbFirmware(status) && session.isEmpty)) ||
      status['busy'] is! bool) {
    throw const AppFailure('USB 设备身份或状态无效，请核对设备 ID。');
  }
  return {...status, 'session': session};
}

bool supportsUsbFirmware(Map<String, dynamic>? status) {
  final capability = object(status?['usb_ota']),
      size = capability?['max_chunk_bytes'];
  return capability?['v'] == 1 && size is int && size > 0 && size <= 3072;
}

/// 停等协议：一块只发一次，必须收到精确 next_offset 才继续。
/// 整包 SHA 与设备会话都绑定到本次事务；取消后绝不补发 finish。
Future<Map<String, dynamic>> sendUsbFirmware(
  SerialManagement client,
  FirmwareImage image,
  String deviceId,
  bool Function() alive,
  void Function(int sent, int total) progress,
) async {
  void check() {
    if (!alive()) throw const AppFailure('USB 升级已取消，不再继续写入。');
  }

  check();
  final before = validateUsbFirmwareStatus(
    await client.request('status.get'),
    deviceId,
  );
  check();
  if (!supportsUsbFirmware(before)) {
    throw const AppFailure('设备尚不支持 USB 升级，请先通过网络 OTA 或 IDF 更新到固件 0.3.0。');
  }
  if (before['busy'] != false) throw const AppFailure('ESP32 正忙，请稍后重新读取状态。');
  String? uploadId;
  try {
    final begin = await client.request('ota.begin', {
      'device_id': deviceId,
      'session': before['session'] as String,
      'size': image.length,
      'sha256': image.digest,
    });
    final id = begin['upload_id'], chunk = begin['max_chunk_bytes'];
    if (id is! String || !RegExp(r'^[a-f0-9]{32}$').hasMatch(id)) {
      throw const AppFailure('设备返回的 USB 升级事务无效。');
    }
    uploadId = id;
    if (begin['next_offset'] != 0 ||
        chunk is! int ||
        chunk < 1 ||
        chunk > 3072) {
      throw const AppFailure('设备返回的 USB 分块参数无效。');
    }
    check();
    var offset = 0;
    await for (final bytes in image.chunks(size: chunk)) {
      check();
      final reply = await client.request('ota.write', {
        'upload_id': id,
        'offset': offset,
        'data': base64Encode(bytes),
      });
      check();
      offset += bytes.length;
      if (reply['next_offset'] != offset) {
        throw const AppFailure('USB 分块回执偏移不匹配，升级已停止。');
      }
      progress(offset, image.length);
    }
    check();
    final finish = await client.request('ota.finish', {'upload_id': id});
    if (finish['ok'] != true || finish['rebooting'] != true) {
      throw const AppFailure('设备未确认 USB 镜像，需重新连接并检查运行版本。');
    }
    return before;
  } catch (_) {
    // 请求已经结束才能取消；拔线/关闭时交给设备的 30 秒超时丢弃未完成事务。
    if (uploadId != null && client.connected) {
      try {
        await client
            .request('ota.abort', {'upload_id': uploadId})
            .timeout(const Duration(seconds: 2));
      } catch (_) {
        await client.close(); // 中止回执也不明确时关闭串口，清理仍在等待的请求。
      }
    }
    rethrow;
  }
}
