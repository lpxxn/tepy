import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../domain/commands.dart';
import '../domain/connection_profile.dart';

/// 用户明确选择的明文 JSON。本文件独立于 Broker 安全存储，也不会被发布工具复制。
/// 路径注入可让测试只使用临时目录，不接触真实应用数据。
abstract interface class MacPasswordStore {
  Future<String> location();
  Future<MacPasswordInfo?> inspect(ConnectionProfile target);
  Future<Uint8List?> read(ConnectionProfile target);
  Future<void> save(
    ConnectionProfile target,
    Uint8List password,
    MacPasswordInfo options,
  );
  Future<void> remove(ConnectionProfile target);
}

final class MacPasswordInfo {
  const MacPasswordInfo({this.enter = true, this.waitSeconds = 3});
  final bool enter;
  final int waitSeconds;
}

String macPasswordTarget(ConnectionProfile target) {
  final uri = target.validate();
  if (target.agentId.isEmpty) throw const AppFailure('请先设置 Mac 代理 ID，再保存登录密码。');
  final port = uri.hasPort ? uri.port : (uri.scheme == 'mqtts' ? 8883 : 1883);
  return '${uri.scheme}://${uri.host.toLowerCase()}:$port|${target.agentId}|${target.deviceId}';
}

final class JsonMacPasswordStore implements MacPasswordStore {
  JsonMacPasswordStore({Future<File> Function()? file})
    : _file = file ?? _defaultFile;
  final Future<File> Function() _file;
  Future<void> _tail = Future.value();
  static Future<File> _defaultFile() async => File(
    '${(await getApplicationSupportDirectory()).path}/mac-passwords.json',
  );
  @override
  Future<String> location() async => (await _file()).path;

  Future<List<Map<String, dynamic>>> _entries(File file) async {
    if (!await file.exists()) return [];
    if (await file.length() > 65536) {
      throw const AppFailure('密码 JSON 超过 64 KiB，请检查本地文件。');
    }
    try {
      final value = jsonDecode(await file.readAsString());
      if (value is! Map<String, dynamic> ||
          value['v'] != 1 ||
          value['profiles'] is! List ||
          (value['profiles'] as List).length > 32) {
        throw const FormatException();
      }
      final result = <Map<String, dynamic>>[];
      final keys = <String>{};
      for (final entry in value['profiles'] as List) {
        if (entry is! Map<String, dynamic> ||
            entry['broker'] is! String ||
            entry['agent_id'] is! String ||
            entry['device_id'] is! String ||
            entry['password'] is! String ||
            entry['press_enter'] is! bool ||
            entry['wait_seconds'] is! int ||
            (entry['wait_seconds'] as int) < 0 ||
            (entry['wait_seconds'] as int) > 30) {
          throw const FormatException();
        }
        final target = _target(entry);
        final bytes = Uint8List.fromList(
          utf8.encode(entry['password'] as String),
        );
        try {
          validateText(bytes);
        } finally {
          wipe(bytes);
        }
        if (!keys.add(macPasswordTarget(target))) throw const FormatException();
        result.add(entry);
      }
      return result;
    } catch (_) {
      throw const AppFailure('本地密码 JSON 格式无效，原文件未被自动删除；请检查 v 和 profiles。');
    }
  }

  ConnectionProfile _target(Map<String, dynamic> e) => ConnectionProfile(
    broker: e['broker'] as String,
    agentId: e['agent_id'] as String,
    deviceId: e['device_id'] as String,
  );
  Future<Map<String, dynamic>?> _find(ConnectionProfile target) async {
    final key = macPasswordTarget(target);
    for (final e in await _entries(await _file())) {
      if (macPasswordTarget(_target(e)) == key) return e;
    }
    return null;
  }

  @override
  Future<MacPasswordInfo?> inspect(ConnectionProfile target) async {
    if (target.agentId.isEmpty) return null;
    final e = await _find(target);
    return e == null
        ? null
        : MacPasswordInfo(
            enter: e['press_enter'] as bool,
            waitSeconds: e['wait_seconds'] as int,
          );
  }

  @override
  Future<Uint8List?> read(ConnectionProfile target) async {
    try {
      final e = await _find(target);
      return e == null
          ? null
          : Uint8List.fromList(utf8.encode(e['password'] as String));
    } on AppFailure {
      rethrow;
    } catch (_) {
      throw const AppFailure('无法读取本地密码文件。');
    }
  }

  // 同一实例串行修改，临时文件写完再替换；失败不清空原配置。
  Future<void> _write(
    ConnectionProfile target,
    Uint8List? bytes,
    MacPasswordInfo? options,
  ) {
    final done = Completer<void>();
    final copy = bytes == null ? null : Uint8List.fromList(bytes);
    _tail = _tail.then((_) async {
      try {
        final key = macPasswordTarget(target), file = await _file();
        final entries = await _entries(file);
        entries.removeWhere((e) => macPasswordTarget(_target(e)) == key);
        if (copy != null && options != null) {
          validateText(copy);
          if (options.waitSeconds < 0 ||
              options.waitSeconds > 30 ||
              entries.length >= 32) {
            throw const AppFailure('等待时间或保存数量超出范围。');
          }
          entries.add({
            'broker': target.broker,
            'agent_id': target.agentId,
            'device_id': target.deviceId,
            'password': ascii.decode(copy),
            'press_enter': options.enter,
            'wait_seconds': options.waitSeconds,
          });
        }
        final encoded = const JsonEncoder.withIndent('  ')
            .convert({'v': 1, 'profiles': entries});
        if (utf8.encode(encoded).length > 65536) {
          throw const AppFailure('密码配置过大，未保存。');
        }
        await file.parent.create(recursive: true);
        final temporary = File('${file.path}.tmp');
        try {
          await temporary.writeAsString('$encoded\n', flush: true);
          await temporary.rename(file.path);
        } finally {
          if (await temporary.exists()) await temporary.delete();
        }
        done.complete();
      } on AppFailure catch (e) {
        done.completeError(e);
      } catch (_) {
        done.completeError(const AppFailure('本地密码文件保存失败，未自动重试。'));
      } finally {
        wipe(copy);
      }
    });
    return done.future;
  }

  @override
  Future<void> save(
    ConnectionProfile target,
    Uint8List password,
    MacPasswordInfo options,
  ) => _write(target, password, options);
  @override
  Future<void> remove(ConnectionProfile target) => _write(target, null, null);
}
