import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../domain/connection_profile.dart';
import '../domain/firmware_image.dart';
import '../domain/snapshots.dart';

final class FirmwareTarget {
  const FirmwareTarget({
    required this.address,
    required this.token,
    required this.deviceId,
  });
  final String address, token, deviceId;
  Uri validate() {
    final uri = Uri.tryParse(address);
    if (uri == null ||
        !{'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        !{'', '/'}.contains(uri.path)) {
      throw const AppFailure('设备地址需为 http://主机:端口 或 https://主机:端口，不含路径或凭据。');
    }
    try {
      if (uri.hasPort && (uri.port < 1 || uri.port > 65535)) {
        throw const FormatException();
      }
    } catch (_) {
      throw const AppFailure('设备端口范围为 1–65535。');
    }
    if (RegExp(r':0/?$').hasMatch(address) ||
        !RegExp(r'^[a-f0-9]{12}$').hasMatch(deviceId) ||
        token.isEmpty ||
        token.length > 64 ||
        token.codeUnits.any((c) => c < 33 || c > 126)) {
      throw const AppFailure('请填写正确的目标设备 ID 与管理口令。');
    }
    return uri;
  }
}

abstract interface class FirmwareTargetStore {
  Future<FirmwareTarget?> load();
  Future<void> save(FirmwareTarget target);
  Future<void> clear();
}

final class SecureFirmwareTargetStore implements FirmwareTargetStore {
  final _storage = const FlutterSecureStorage();
  static const _key = 'tepy.firmware.target.v1';
  @override
  Future<FirmwareTarget?> load() async {
    try {
      final raw = await _storage.read(key: _key);
      if (raw == null) return null;
      final json = object(jsonDecode(raw));
      if (json?['v'] != 1 ||
          json?['address'] is! String ||
          json?['token'] is! String ||
          json?['device_id'] is! String) {
        throw const FormatException();
      }
      final target = FirmwareTarget(
        address: json!['address'] as String,
        token: json['token'] as String,
        deviceId: json['device_id'] as String,
      );
      target.validate();
      return target;
    } catch (_) {
      throw const AppFailure('无法恢复已保存的固件管理连接，原配置未删除。');
    }
  }

  @override
  Future<void> save(FirmwareTarget target) async {
    target.validate();
    try {
      await _storage.write(
        key: _key,
        value: jsonEncode({
          'v': 1,
          'address': target.address,
          'token': target.token,
          'device_id': target.deviceId,
        }),
      );
    } catch (_) {
      throw const AppFailure('无法保存固件管理连接。');
    }
  }

  @override
  Future<void> clear() async {
    try {
      await _storage.delete(key: _key);
    } catch (_) {
      throw const AppFailure('无法清除固件管理连接。');
    }
  }
}

abstract interface class FirmwarePicker {
  Future<FirmwareImage?> pick();
}

final class NativeFirmwarePicker implements FirmwarePicker {
  @override
  Future<FirmwareImage?> pick() async {
    try {
      const group = XTypeGroup(
        label: 'Tepy 应用镜像',
        extensions: ['bin'],
        mimeTypes: ['application/octet-stream'],
      );
      final file = await openFile(acceptedTypeGroups: [group]);
      if (file == null) return null;
      final length = await file.length();
      if (length <= 288 || length > FirmwareImage.maximumSize) {
        throw const AppFailure('请选择不超过 4 MiB 的 tepy.bin 应用镜像。');
      }
      // 文件长度可能在选择后变化；流式读取时仍检查上限。
      final builder = BytesBuilder();
      await for (final block in file.openRead()) {
        if (builder.length + block.length > FirmwareImage.maximumSize) {
          throw const AppFailure('镜像文件超过 4 MiB。');
        }
        builder.add(block);
      }
      return FirmwareImage.inspect(file.name, builder.takeBytes());
    } on AppFailure {
      rethrow;
    } catch (_) {
      throw const AppFailure('无法读取所选固件文件。');
    }
  }
}

abstract interface class FirmwareClient {
  Future<Map<String, dynamic>> status(FirmwareTarget target);
  Future<void> upload(
    FirmwareTarget target,
    FirmwareImage image,
    void Function(int, int) progress,
  );
  void close();
}

final class HttpFirmwareClient implements FirmwareClient {
  HttpFirmwareClient({HttpClient? client}) : _client = client ?? HttpClient() {
    _client.connectionTimeout = const Duration(seconds: 5);
    _client.findProxy = (_) => 'DIRECT';
  }
  final HttpClient _client;
  Future<Map<String, dynamic>> _response(HttpClientResponse response) async {
    if (response.statusCode >= 300 && response.statusCode < 400) {
      await response.listen((_) {}).cancel();
      throw const AppFailure('设备返回重定向，请填写设备的实际地址。');
    }
    final builder = BytesBuilder(), watch = Stopwatch()..start();
    final reader = StreamIterator<List<int>>(response);
    try {
      while (true) {
        final remaining = 10000 - watch.elapsedMilliseconds;
        if (remaining <= 0) throw TimeoutException('response');
        if (!await reader.moveNext().timeout(
          Duration(milliseconds: remaining),
        )) {
          break;
        }
        final bytes = reader.current;
        if (builder.length + bytes.length > 65536) {
          throw const AppFailure('设备回复过大。');
        }
        builder.add(bytes);
      }
    } finally {
      await reader.cancel();
    }
    Map<String, dynamic>? json;
    try {
      json = object(jsonDecode(utf8.decode(builder.takeBytes())));
    } catch (_) {
      throw const AppFailure('设备回复格式无效。');
    }
    if (response.statusCode >= 300 && response.statusCode < 400) {
      throw const AppFailure('设备返回重定向，请填写设备的实际地址。');
    }
    if (response.statusCode != 200) {
      final code = json?['error'];
      throw AppFailure(switch (code) {
        'unauthorized' => 'ESP32 管理口令不正确。',
        'busy' => '设备正在输入或升级，请稍后重新读取状态。',
        'wrong_project' => '设备拒绝镜像：项目名不匹配。',
        'invalid_image' => '设备拒绝镜像：完整性校验失败。',
        _ => '设备拒绝请求，写入结果可能未确认；请重新读取状态。',
      });
    }
    if (json == null) throw const AppFailure('设备回复格式无效。');
    return json;
  }

  @override
  Future<Map<String, dynamic>> status(FirmwareTarget target) async {
    try {
      final request = await _client.getUrl(
        target.validate().resolve('/api/v1/status'),
      );
      request.followRedirects = false;
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer ${target.token}',
      );
      final result = await _response(
        await request.close().timeout(const Duration(seconds: 6)),
      );
      if (result['v'] != 1 ||
          result['device_id'] != target.deviceId ||
          result['firmware'] is! String ||
          (result['firmware'] as String).length > 64 ||
          (result['firmware'] as String).isEmpty ||
          result['session'] is! String ||
          !RegExp(r'^[a-f0-9]{32}$').hasMatch(result['session'] as String) ||
          result['busy'] is! bool) {
        throw const AppFailure('设备身份或状态无效，请确认连接的是目标 ESP32。');
      }
      return result;
    } on AppFailure {
      rethrow;
    } catch (_) {
      throw const AppFailure('无法读取 ESP32 状态，请检查地址、网络和管理口令。');
    }
  }

  @override
  Future<void> upload(
    FirmwareTarget target,
    FirmwareImage image,
    void Function(int, int) progress,
  ) async {
    try {
      final request = await _client.postUrl(
        target.validate().resolve('/api/v1/ota'),
      );
      request.followRedirects = false;
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer ${target.token}',
      );
      request.headers.contentType = ContentType('application', 'octet-stream');
      request.contentLength = image.length;
      var sent = 0;
      // 进度仅表示提交给网络栈的字节，最终成功还要等待设备回执和重启版本。
      await for (final block in image.chunks()) {
        request.add(block);
        await request.flush();
        sent += block.length;
        progress(sent, image.length);
      }
      final result = await _response(await request.close());
      if (result['ok'] != true || result['rebooting'] != true) {
        throw const AppFailure('设备未确认升级；请先重新读取状态，不要重复上传。');
      }
    } on AppFailure {
      rethrow;
    } catch (_) {
      throw const AppFailure('上传中断或结果未确认；请先查询运行版本，不自动重发。');
    }
  }

  @override
  void close() => _client.close(force: true);
}
