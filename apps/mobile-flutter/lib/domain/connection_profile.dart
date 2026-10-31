import 'dart:convert';

/// 一个连接档案。这里只存 Broker 认证信息，绝不存 Mac 登录密码。
///
/// Dart 的 final 表示“字段不能重新赋值”。配合 const 构造函数，可以把对象
/// 当成不可变的数据快照使用；用户修改表单时，我们创建新对象而不是偷偷修改旧对象。
final class ConnectionProfile {
  const ConnectionProfile({
    this.broker = 'mqtt://192.168.50.99:1883',
    this.deviceId = '24587cda3a18',
    this.agentId = 'mac-51958cda3625',
    this.username = '',
    this.password = '',
    this.caPem = '',
    this.clientCertificatePem = '',
    this.clientKeyPem = '',
  });

  final String broker, deviceId, agentId, username, password;
  final String caPem, clientCertificatePem, clientKeyPem;

  String get devicePrefix => 'tepy/$deviceId';
  String get agentPrefix => 'tepy/macos/$agentId';

  /// 校验失败只返回固定说明，不把 URL、密码或 PEM 放进异常信息。
  Uri validate() {
    final uri = Uri.tryParse(broker);
    if (uri == null ||
        !{'mqtt', 'mqtts'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.path.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const AppFailure('地址需为 mqtt://主机:端口 或 mqtts://主机:端口，凭据单独填写。');
    }
    // Uri.port 会验证显式端口；try/catch 避免把输入原文包含在 FormatException 中。
    // 未知 scheme 的默认端口为 0；Uri 会规范化 :0，所以也检查输入原始结尾。
    final explicitPort = RegExp(r':([0-9]+)$').firstMatch(broker)?.group(1);
    if (explicitPort != null && int.tryParse(explicitPort) == 0) {
      throw const AppFailure('Broker 端口范围为 1–65535。');
    }
    try {
      if (uri.hasPort && (uri.port < 1 || uri.port > 65535)) {
        throw const AppFailure('Broker 端口范围为 1–65535。');
      }
    } on FormatException {
      throw const AppFailure('Broker 端口无效。');
    }
    if (!RegExp(r'^[a-f0-9]{12}$').hasMatch(deviceId) ||
        (agentId.isNotEmpty &&
            !RegExp(r'^[A-Za-z0-9_.-]{1,64}$').hasMatch(agentId))) {
      throw const AppFailure('设备 ID 为 12 位小写十六进制；代理 ID 只能含字母、数字、点、横线和下划线。');
    }
    if (utf8.encode(username).length > 256 ||
        utf8.encode(password).length > 4096) {
      throw const AppFailure('Broker 用户名或密码过长。');
    }
    if (clientCertificatePem.isEmpty != clientKeyPem.isEmpty) {
      throw const AppFailure('客户端证书和私钥必须成对填写。');
    }
    if (uri.scheme != 'mqtts' &&
        (caPem.isNotEmpty || clientCertificatePem.isNotEmpty)) {
      throw const AppFailure('证书只用于 mqtts:// 连接。');
    }
    if ([
      caPem,
      clientCertificatePem,
      clientKeyPem,
    ].any((s) => s.length > 16384)) {
      throw const AppFailure('单份 PEM 内容不能超过 16 KiB。');
    }
    return uri;
  }

  /// 这个 Map 含认证秘密，只能交给安全存储，不能用于日志或页面“状态详情”。
  Map<String, Object> toStorageJson() => {
    'v': 1,
    'broker': broker,
    'device_id': deviceId,
    'agent_id': agentId,
    'username': username,
    'password': password,
    'ca_pem': caPem,
    'client_certificate_pem': clientCertificatePem,
    'client_key_pem': clientKeyPem,
  };

  factory ConnectionProfile.fromStorageJson(Map<String, dynamic> json) {
    if (json['v'] != 1) throw const AppFailure('连接配置版本不受支持，原数据没有被清除。');
    String text(String key) {
      final value = json[key];
      if (value is! String) throw const AppFailure('保存的连接配置格式不正确。');
      return value;
    }

    return ConnectionProfile(
      broker: text('broker'),
      deviceId: text('device_id'),
      agentId: text('agent_id'),
      username: text('username'),
      password: text('password'),
      caPem: text('ca_pem'),
      clientCertificatePem: text('client_certificate_pem'),
      clientKeyPem: text('client_key_pem'),
    )..validate();
  }
}

/// 业务层的可展示错误。只使用开发者提供的安全文案，不透传底层异常原文。
final class AppFailure implements Exception {
  const AppFailure(this.message);
  final String message;
  @override
  String toString() => message;
}
