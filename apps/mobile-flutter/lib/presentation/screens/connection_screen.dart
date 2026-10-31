import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/providers.dart';
import '../../application/session_state.dart';
import '../../domain/connection_profile.dart';
import '../widgets/common.dart';

/// TextEditingController 属于界面层，必须在 State.dispose 中释放。
/// 不能在 build() 里创建，否则每次收到状态消息都会重置文本和光标。
class ConnectionScreen extends ConsumerStatefulWidget {
  const ConnectionScreen({super.key});
  @override
  ConsumerState<ConnectionScreen> createState() => _ConnectionScreenState();
}

class _ConnectionScreenState extends ConsumerState<ConnectionScreen> {
  late final TextEditingController _broker,
      _device,
      _agent,
      _username,
      _password,
      _ca,
      _certificate,
      _key;
  bool _dirty = false, _editKey = false;

  @override
  void initState() {
    super.initState();
    _broker = TextEditingController();
    _device = TextEditingController();
    _agent = TextEditingController();
    _username = TextEditingController();
    _password = TextEditingController();
    _ca = TextEditingController();
    _certificate = TextEditingController();
    _key = TextEditingController();
    _fill(ref.read(sessionProvider).profile);
  }

  void _fill(ConnectionProfile profile) {
    _broker.text = profile.broker;
    _device.text = profile.deviceId;
    _agent.text = profile.agentId;
    _username.text = profile.username;
    _password.text = profile.password;
    _ca.text = profile.caPem;
    _certificate.text = profile.clientCertificatePem;
    _key.text = profile.clientKeyPem;
  }

  ConnectionProfile _profile() => ConnectionProfile(
    broker: _broker.text.trim(),
    deviceId: _device.text.trim().toLowerCase(),
    agentId: _agent.text.trim(),
    username: _username.text,
    password: _password.text,
    caPem: _ca.text.trim(),
    clientCertificatePem: _certificate.text.trim(),
    clientKeyPem: _key.text.trim(),
  );

  @override
  void dispose() {
    for (final field in [
      _broker,
      _device,
      _agent,
      _username,
      _password,
      _ca,
      _certificate,
      _key,
    ]) {
      field.dispose();
    }
    super.dispose();
  }

  Future<void> _connect({required bool save}) async {
    FocusScope.of(context).unfocus();
    final controller = ref.read(sessionProvider.notifier), profile = _profile();
    if (save) {
      await controller.save(profile);
      if (!mounted || ref.read(sessionProvider).isError) return;
      _dirty = false;
    }
    await controller.connect(profile);
  }

  Future<void> _forget() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清除保存的连接？'),
        content: const Text('只清除这台手机保存的连接信息，ESP32 和 Mac 配置不变。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('保留'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    await ref.read(sessionProvider.notifier).forget();
    if (!mounted || ref.read(sessionProvider).isError) return;
    setState(() {
      _dirty = false;
      _editKey = false;
      _fill(ref.read(sessionProvider).profile);
    });
  }

  @override
  Widget build(BuildContext context) {
    // 异步恢复档案时填一次表单；用户已经开始编辑后，网络刷新不覆盖草稿。
    ref.listen(sessionProvider.select((s) => s.profile), (_, next) {
      if (!_dirty) _fill(next);
    });
    final state = ref.watch(sessionProvider);
    final editable =
        !state.loading &&
        !state.saving &&
        state.link == LinkState.offline &&
        !state.busy;
    Widget field(
      TextEditingController controller,
      String label,
      String key, {
      bool secret = false,
      int lines = 1,
      String? helper,
    }) => Padding(
      // 输入框内部也有 Scrollable。独立 PageStorageKey 隔离滚动距离，
      // 防止读取到祖先 ExpansionTile 保存的 bool 展开状态。
      key: PageStorageKey('connection-input-$key'),
      padding: const EdgeInsets.only(bottom: 16),
      child: TextField(
        key: Key(key),
        controller: controller,
        enabled: editable,
        obscureText: secret,
        maxLines: lines,
        autocorrect: false,
        enableSuggestions: false,
        enableIMEPersonalizedLearning: false,
        onChanged: (_) => _dirty = true,
        decoration: InputDecoration(
          labelText: label,
          helperText: helper,
          helperMaxLines: 3,
        ),
      ),
    );
    return ListView(
      key: const PageStorageKey('connection'),
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      children: [
        const Text(
          '连接你的设备',
          style: TextStyle(fontSize: 25, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: () => showLicensePage(
            context: context,
            applicationName: 'Tepy Mobile',
            applicationVersion: '0.1.3',
          ),
          child: const Text('开源许可'),
        ),
        const Text(
          '手机使用 Broker 的局域网地址。Mac 更换 IP 后，无需修改代理 ID。',
          style: TextStyle(color: Colors.blueGrey, fontSize: 13),
        ),
        const SizedBox(height: 20),
        SectionCard(
          title: 'MQTT Broker',
          subtitle: '连接信息可记住，Mac 登录密码不在此处填写。',
          child: Column(
            children: [
              field(
                _broker,
                'Broker 地址',
                'brokerField',
                helper: '例如 mqtt://192.168.50.99:1883；手机上不要填 127.0.0.1',
              ),
              field(_device, 'ESP32 设备 ID', 'deviceField'),
              field(_agent, 'Mac 代理 ID', 'agentField'),
              field(_username, 'Broker 用户名（可选）', 'usernameField'),
              field(
                _password,
                'Broker 密码（可选）',
                'brokerPasswordField',
                secret: true,
              ),
              const Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Mac 代理 ID 可留空查看 ESP32 和发送普通按键；解锁流程需要它。',
                  style: TextStyle(fontSize: 12, color: Colors.blueGrey),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Card(
          // 圆角外观不会自动裁剪子级 Material 上的水波纹；在卡片边界显式裁剪。
          clipBehavior: Clip.antiAlias,
          child: ExpansionTile(
            // 展开状态和外层列表、各输入框的滚动位置使用不同存储路径。
            key: const PageStorageKey('connection-tls-expansion'),
            // 内部点击层也使用同一圆角，按住、展开与收起时的高亮保持一致。
            // 不设置边线，外层 Card 负责绘制浅色边框。
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.all(Radius.circular(22)),
            ),
            collapsedShape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.all(Radius.circular(22)),
            ),
            clipBehavior: Clip.antiAlias,
            title: const Text(
              'TLS 证书',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            subtitle: const Text(
              'mqtts:// · CA / 客户端证书',
              style: TextStyle(fontSize: 12),
            ),
            childrenPadding: const EdgeInsets.all(20),
            children: [
              const Padding(
                padding: EdgeInsets.only(bottom: 16),
                child: Text(
                  '留空使用系统 CA。自定义证书粘贴 PEM；客户端证书与未加密私钥成对填写，不跳过服务器校验。',
                  style: TextStyle(fontSize: 12, color: Colors.blueGrey),
                ),
              ),
              field(_ca, 'CA PEM（可选）', 'caField', lines: 4),
              field(
                _certificate,
                '客户端证书 PEM（可选）',
                'certificateField',
                lines: 4,
              ),
              if (_editKey)
                field(_key, '客户端私钥 PEM（敏感）', 'privateKeyField', lines: 4)
              else
                OutlinedButton.icon(
                  onPressed: editable
                      ? () => setState(() => _editKey = true)
                      : null,
                  icon: const Icon(Icons.key_outlined),
                  label: Text(_key.text.isEmpty ? '填写客户端私钥' : '编辑已保存私钥'),
                ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: editable
                    ? () => setState(() {
                        _certificate.clear();
                        _key.clear();
                        _dirty = true;
                        _editKey = false;
                      })
                    : null,
                child: const Text('清空客户端证书和私钥'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        if (state.loading || state.saving)
          const Padding(
            padding: EdgeInsets.all(12),
            child: LinearProgressIndicator(),
          ),
        FilledButton.icon(
          key: const Key('saveConnect'),
          onPressed: editable ? () => unawaited(_connect(save: true)) : null,
          icon: const Icon(Icons.link),
          label: const Text('保存并连接'),
        ),
        const SizedBox(height: 10),
        OutlinedButton(
          onPressed: editable ? () => unawaited(_connect(save: false)) : null,
          child: const Text('仅本次连接，不保存'),
        ),
        if (state.link != LinkState.offline)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: OutlinedButton.icon(
              onPressed: () =>
                  unawaited(ref.read(sessionProvider.notifier).disconnect()),
              icon: const Icon(Icons.link_off),
              label: const Text('断开连接'),
            ),
          ),
        const SizedBox(height: 16),
        const SessionNotice(),
        const SizedBox(height: 16),
        TextButton.icon(
          onPressed: !state.loading && !state.saving && !state.busy
              ? () => unawaited(_forget())
              : null,
          icon: const Icon(Icons.delete_outline),
          label: const Text('清除手机保存的连接'),
        ),
        const SizedBox(height: 8),
        const Text(
          'Tepy Mobile 0.1.3 · 连接时恢复状态，不积压离线动作。',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 11, color: Colors.blueGrey),
        ),
      ],
    );
  }
}
