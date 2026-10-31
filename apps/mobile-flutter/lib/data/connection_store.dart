import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../domain/connection_profile.dart';

/// 把“如何存储”藏在接口后面。测试可替换为内存实现，不接触手机凭据。
abstract interface class ConnectionStore {
  Future<ConnectionProfile?> load();
  Future<void> save(ConnectionProfile profile);
  Future<void> forget();
}

/// 首版只有一个连接档案，连同 Broker 密码、客户端私钥一起交给系统安全存储。
/// Android 由插件使用 Keystore 支持的加密实现；不额外写一个明文 JSON 文件。
final class SecureConnectionStore implements ConnectionStore {
  SecureConnectionStore([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();
  final FlutterSecureStorage _storage;
  static const _key = 'tepy.connection.v1';

  @override
  Future<ConnectionProfile?> load() async {
    try {
      final raw = await _storage.read(key: _key);
      if (raw == null) return null;
      final json = jsonDecode(raw);
      if (json is! Map<String, dynamic>) {
        throw const AppFailure('保存的连接配置格式不正确。');
      }
      return ConnectionProfile.fromStorageJson(json);
    } on AppFailure {
      rethrow; // 保留已消除敏感信息的业务错误。
    } catch (_) {
      throw const AppFailure('无法读取安全存储，原连接信息未被自动删除。');
    }
  }

  @override
  Future<void> save(ConnectionProfile profile) async {
    profile.validate();
    try {
      await _storage.write(
        key: _key,
        value: jsonEncode(profile.toStorageJson()),
      );
    } catch (_) {
      throw const AppFailure('系统安全存储保存失败，未退回明文保存。');
    }
  }

  @override
  Future<void> forget() async {
    try {
      // 不使用 deleteAll，避免影响这个应用将来保存的其他独立设置。
      await _storage.delete(key: _key);
    } catch (_) {
      throw const AppFailure('无法清除保存的连接，请稍后重试。');
    }
  }
}
