import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/usb_controller.dart';
import '../../domain/connection_profile.dart';
import '../../domain/serial_management.dart';
import '../../domain/snapshots.dart';
import '../widgets/common.dart';

/// USB 配置是独立页面；使用 TextEditingController 保留草稿。
/// Wi-Fi/MQTT 新密码仅用于一次 PATCH，不写入手机连接档案。
class UsbScreen extends ConsumerStatefulWidget {
  const UsbScreen({super.key});
  @override
  ConsumerState<UsbScreen> createState() => _UsbScreenState();
}

class _UsbScreenState extends ConsumerState<UsbScreen>
    with WidgetsBindingObserver {
  final _token = TextEditingController(),
      _ssid = TextEditingController(),
      _wifiPassword = TextEditingController(),
      _mqttUri = TextEditingController(),
      _mqttUser = TextEditingController(),
      _mqttPassword = TextEditingController(),
      _ca = TextEditingController(),
      _ntp = TextEditingController(text: 'pool.ntp.org'),
      _delay = TextEditingController(text: '20'),
      _passkey = TextEditingController();
  String? _device;
  bool _remember = true, _dirty = false;
  PasswordPolicy _wifiPolicy = PasswordPolicy.keep,
      _mqttPolicy = PasswordPolicy.keep;
  String? _localError;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final saved = await ref.read(usbProvider.notifier).loadToken();
      if (mounted && _token.text.isEmpty) setState(() => _token.text = saved);
    });
  }

  void _clearSecrets() {
    _wifiPassword.clear();
    _mqttPassword.clear();
    _passkey.clear();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused) {
      _clearSecrets();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _clearSecrets();
    for (final controller in [
      _token,
      _ssid,
      _wifiPassword,
      _mqttUri,
      _mqttUser,
      _mqttPassword,
      _ca,
      _ntp,
      _delay,
      _passkey,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  void _fill(Map<String, dynamic> config) {
    final wifi = object(config['wifi'])!, mqtt = object(config['mqtt'])!;
    _ssid.text = wifi['ssid'] as String;
    _mqttUri.text = mqtt['uri'] as String;
    _mqttUser.text = mqtt['username'] as String;
    _ca.text = mqtt['ca'] as String;
    _ntp.text = config['ntp_server'] as String;
    _delay.text = '${config['key_delay_ms']}';
    _wifiPolicy = _mqttPolicy = PasswordPolicy.keep;
    _dirty = false;
    _clearSecrets();
  }

  Future<bool> _confirm(String title, String body) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('继续'),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _save() async {
    FocusScope.of(context).unfocus();
    try {
      final patch = deviceConfigPatch(
        ssid: _ssid.text,
        mqttUri: _mqttUri.text.trim(),
        mqttUsername: _mqttUser.text,
        ntp: _ntp.text.trim(),
        keyDelay: int.tryParse(_delay.text) ?? 0,
        ca: _ca.text.trim(),
        wifiPolicy: _wifiPolicy,
        wifiPassword: _wifiPassword.text,
        mqttPolicy: _mqttPolicy,
        mqttPassword: _mqttPassword.text,
      );
      _clearSecrets();
      setState(() => _localError = null);
      await ref.read(usbProvider.notifier).saveConfig(patch);
    } on AppFailure catch (error) {
      _clearSecrets();
      setState(() => _localError = error.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(usbProvider.select((s) => s.config), (_, next) {
      if (next != null) _fill(next);
    });
    ref.listen(usbProvider.select((s) => s.connected), (_, connected) {
      if (!connected) _clearSecrets();
    });
    final state = ref.watch(usbProvider),
        controller = ref.read(usbProvider.notifier);
    final editable = state.connected && state.config != null && !state.busy;
    final selected = state.devices.any((d) => d.id == _device) ? _device : null;
    Widget field(
      TextEditingController text,
      String label,
      String key, {
      bool secret = false,
      int lines = 1,
    }) => Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: TextField(
        key: Key(key),
        controller: text,
        enabled: editable,
        obscureText: secret,
        autocorrect: false,
        enableSuggestions: false,
        enableIMEPersonalizedLearning: false,
        maxLines: lines,
        onChanged: (_) => _dirty = true,
        decoration: InputDecoration(labelText: label),
      ),
    );
    Widget policy(bool wifi) => Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: DropdownButtonFormField<PasswordPolicy>(
        key: ValueKey(
          '${wifi ? 'wifi' : 'mqtt'}-${wifi ? _wifiPolicy.name : _mqttPolicy.name}',
        ),
        initialValue: wifi ? _wifiPolicy : _mqttPolicy,
        isExpanded: true,
        decoration: InputDecoration(
          labelText: wifi ? 'Wi-Fi 密码操作' : 'MQTT 密码操作',
        ),
        items: const [
          DropdownMenuItem(value: PasswordPolicy.keep, child: Text('保留原值')),
          DropdownMenuItem(value: PasswordPolicy.replace, child: Text('设置新密码')),
          DropdownMenuItem(value: PasswordPolicy.clear, child: Text('清除密码')),
        ],
        onChanged: editable
            ? (value) => setState(() {
                if (wifi) {
                  _wifiPolicy = value!;
                  _wifiPassword.clear();
                } else {
                  _mqttPolicy = value!;
                  _mqttPassword.clear();
                }
                _dirty = true;
              })
            : null,
      ),
    );
    final status = state.status;
    return ListView(
      key: const PageStorageKey('usb'),
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      children: [
        const Text(
          'USB 设备管理',
          style: TextStyle(fontSize: 25, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 8),
        const Text(
          '手机 → USB-C OTG → 数据线 → ESP32-S3 原生 USB 口。无需先配 Wi-Fi，仍需管理口令。',
          style: TextStyle(fontSize: 13, color: Colors.blueGrey),
        ),
        const SizedBox(height: 20),
        SectionCard(
          title: '连接 ESP32',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DropdownButtonFormField<String>(
                key: ValueKey('ports-${state.devices.map((d) => d.id).join()}'),
                initialValue: selected,
                isExpanded: true,
                decoration: const InputDecoration(labelText: '手机检测到的原生 USB 串口'),
                items: [
                  for (final device in state.devices)
                    DropdownMenuItem(
                      value: device.id,
                      child: Text(
                        '${device.name} · ${device.id}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: !state.connected && !state.busy
                    ? (value) => setState(() => _device = value)
                    : null,
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                key: const Key('refreshUsb'),
                onPressed: !state.busy
                    ? () => unawaited(controller.refreshDevices())
                    : null,
                icon: const Icon(Icons.refresh),
                label: const Text('刷新 USB 设备'),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('usbAdminToken'),
                controller: _token,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                enableIMEPersonalizedLearning: false,
                maxLength: 64,
                enabled: !state.connected && !state.busy,
                decoration: const InputDecoration(labelText: 'ESP32 管理口令'),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _remember,
                title: const Text('安全记住管理口令', style: TextStyle(fontSize: 13)),
                onChanged: !state.connected && !state.busy
                    ? (value) => setState(() => _remember = value ?? true)
                    : null,
              ),
              FilledButton.icon(
                onPressed: !state.connected && !state.busy && selected != null
                    ? () => unawaited(
                        controller.connect(
                          selected,
                          _token.text,
                          remember: _remember,
                        ),
                      )
                    : null,
                icon: const Icon(Icons.usb),
                label: const Text('连接并读取'),
              ),
              if (state.connected)
                OutlinedButton(
                  onPressed: () => unawaited(controller.disconnect()),
                  child: const Text('关闭 USB'),
                ),
              TextButton(
                onPressed: !state.busy
                    ? () async {
                        await controller.forgetToken();
                        if (mounted) setState(() => _token.clear());
                      }
                    : null,
                child: const Text('清除手机保存的管理口令'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        if (state.busy)
          const Padding(
            padding: EdgeInsets.only(bottom: 16),
            child: LinearProgressIndicator(),
          ),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            color: state.isError || _localError != null
                ? const Color(0xFFFFEEF0)
                : const Color(0xFFE8F6F2),
          ),
          child: Text(
            _localError ?? state.message,
            style: const TextStyle(fontSize: 13),
          ),
        ),
        const SizedBox(height: 16),
        SectionCard(
          title: '设备状态',
          child: Column(
            children: [
              DetailRow(
                '设备 ID',
                status?['device_id'] is String
                    ? status!['device_id'] as String
                    : '未知',
              ),
              DetailRow(
                '固件',
                status?['firmware'] is String
                    ? status!['firmware'] as String
                    : '未知',
              ),
              DetailRow(
                'IP',
                object(status?['wifi'])?['ip'] is String
                    ? object(status?['wifi'])!['ip'] as String
                    : '未知',
              ),
              OutlinedButton(
                onPressed: state.connected && !state.busy
                    ? () => unawaited(controller.readStatus())
                    : null,
                child: const Text('读取状态'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        SectionCard(
          title: '网络配置',
          subtitle: '读取只返回密码是否已设置。保留密码会省略字段，清除会发送空字符串。',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              field(_ssid, 'Wi-Fi SSID', 'usbSsid'),
              policy(true),
              if (_wifiPolicy == PasswordPolicy.replace)
                field(
                  _wifiPassword,
                  'Wi-Fi 新密码',
                  'usbWifiPassword',
                  secret: true,
                ),
              field(_mqttUri, 'ESP32 的 MQTT 地址', 'usbMqttUri'),
              field(_mqttUser, 'MQTT 用户名', 'usbMqttUser'),
              policy(false),
              if (_mqttPolicy == PasswordPolicy.replace)
                field(
                  _mqttPassword,
                  'MQTT 新密码',
                  'usbMqttPassword',
                  secret: true,
                ),
              field(_ca, 'CA PEM（空时使用固件证书包）', 'usbCa', lines: 3),
              field(_ntp, 'NTP 服务器', 'usbNtp'),
              field(_delay, '按下 / 释放各自间隔（5–200 ms）', 'usbKeyDelay'),
              FilledButton.icon(
                key: const Key('saveUsbConfig'),
                onPressed: editable ? () => unawaited(_save()) : null,
                icon: const Icon(Icons.save_outlined),
                label: const Text('保存配置并回读'),
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: editable
                    ? () async {
                        if (_dirty &&
                            !await _confirm('重新读取？', '将覆盖本页未保存的编辑。')) {
                          return;
                        }
                        await controller.readConfig();
                      }
                    : null,
                child: const Text('重新读取配置'),
              ),
              OutlinedButton(
                onPressed: state.connected && !state.busy
                    ? () async {
                        if (await _confirm(
                          '重启设备？',
                          '仅已保存的配置生效，USB 和蓝牙会短暂断开。',
                        )) {
                          await controller.reboot();
                        }
                      }
                    : null,
                child: const Text('重启使配置生效'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        SectionCard(
          title: '蓝牙配对',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              OutlinedButton(
                onPressed: state.connected && !state.busy
                    ? () => unawaited(controller.pair())
                    : null,
                child: const Text('开启 120 秒配对窗口'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _passkey,
                obscureText: true,
                maxLength: 6,
                keyboardType: TextInputType.number,
                enabled: state.connected && !state.busy,
                decoration: const InputDecoration(labelText: 'Mac 显示的六位配对码'),
              ),
              OutlinedButton(
                onPressed: state.connected && !state.busy
                    ? () {
                        final value = _passkey.text;
                        _passkey.clear();
                        unawaited(controller.passkey(value));
                      }
                    : null,
                child: const Text('提交配对码'),
              ),
              TextButton(
                onPressed: state.connected && !state.busy
                    ? () async {
                        if (await _confirm(
                          '清除蓝牙绑定？',
                          'ESP32 将断开当前 Mac，之后需要重新配对。',
                        )) {
                          await controller.clearBond();
                        }
                      }
                    : null,
                child: const Text('清除蓝牙绑定'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
