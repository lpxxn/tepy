import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/firmware_controller.dart';
import '../../application/providers.dart';
import '../../application/usb_controller.dart';
import '../../data/firmware_client.dart';
import '../../domain/serial_firmware.dart';
import '../widgets/common.dart';
import '../widgets/secret_text_field.dart';

class FirmwareScreen extends ConsumerStatefulWidget {
  const FirmwareScreen({super.key, required this.onUsbRequested});
  final VoidCallback onUsbRequested;
  @override
  ConsumerState<FirmwareScreen> createState() => _FirmwareScreenState();
}

class _FirmwareScreenState extends ConsumerState<FirmwareScreen> {
  final _address = TextEditingController(),
      _token = TextEditingController(),
      _device = TextEditingController();
  bool _dirty = false, _remember = true;
  @override
  void initState() {
    super.initState();
    _device.text = ref.read(sessionProvider).profile.deviceId;
  }

  @override
  void dispose() {
    _address.dispose();
    _token.clear();
    _token.dispose();
    _device.dispose();
    super.dispose();
  }

  FirmwareTarget _target() => FirmwareTarget(
    address: _address.text.trim(),
    token: _token.text,
    deviceId: _device.text.trim().toLowerCase(),
  );
  @override
  Widget build(BuildContext context) {
    ref.listen(firmwareProvider.select((s) => s.target), (_, target) {
      if (!_dirty && target != null) {
        _address.text = target.address;
        _token.text = target.token;
        _device.text = target.deviceId;
      }
    });
    final state = ref.watch(firmwareProvider),
        session = ref.watch(sessionProvider),
        controller = ref.read(firmwareProvider.notifier);
    final usb = state.transport == FirmwareTransport.usb,
        usbState = ref.watch(usbProvider);
    final phase = switch (state.phase) {
      FirmwarePhase.reading => '核对设备',
      FirmwarePhase.selecting => '选择镜像',
      FirmwarePhase.uploading => '上传镜像',
      FirmwarePhase.verifying => '等待设备重启',
      FirmwarePhase.verified => '版本已确认',
      FirmwarePhase.failed => '需要检查',
      _ => '准备升级',
    };
    Widget field(TextEditingController value, String label, String key) =>
        Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: TextField(
            key: Key(key),
            controller: value,
            enabled: !state.busy,
            onChanged: (_) => setState(() => _dirty = true),
            decoration: InputDecoration(labelText: label),
          ),
        );
    return PageContent(
      storageKey: const PageStorageKey('firmware'),
      children: [
        const PageHeading(
          eyebrow: 'FIRMWARE',
          title: '固件管理',
          subtitle: '选择应用镜像，通过网络或 USB 升级 ESP32，再确认运行版本。',
        ),
        SegmentedButton<FirmwareTransport>(
          segments: const [
            ButtonSegment(
              value: FirmwareTransport.network,
              label: Text('网络 OTA'),
              icon: Icon(Icons.wifi_rounded, size: 17),
            ),
            ButtonSegment(
              value: FirmwareTransport.usb,
              label: Text('USB 升级'),
              icon: Icon(Icons.usb_rounded, size: 17),
            ),
          ],
          selected: {state.transport},
          showSelectedIcon: false,
          onSelectionChanged: state.busy
              ? null
              : (value) => controller.selectTransport(value.first),
        ),
        const SizedBox(height: 20),
        ResponsiveColumns(
          first: usb
              ? SectionCard(
                  title: 'USB 连接',
                  icon: Icons.usb_rounded,
                  subtitle: '使用已连接的 USB 设备，可离线升级。',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      DetailRow('串口状态', usbState.connected ? '已连接' : '未连接'),
                      const SizedBox(height: 12),
                      field(_device, '目标 ESP32 设备 ID', 'otaDevice'),
                      FilledButton.icon(
                        key: const Key('usbOtaReadStatus'),
                        onPressed:
                            !state.busy && usbState.connected && !usbState.busy
                            ? () async {
                                await controller.readUsbStatus(
                                  _device.text.trim().toLowerCase(),
                                );
                                if (mounted &&
                                    !ref.read(firmwareProvider).error) {
                                  setState(() => _dirty = false);
                                }
                              }
                            : null,
                        icon: const Icon(Icons.refresh_rounded, size: 18),
                        label: const Text('通过 USB 读取版本'),
                      ),
                      TextButton.icon(
                        onPressed: state.phase == FirmwarePhase.uploading
                            ? null
                            : widget.onUsbRequested,
                        icon: const Icon(Icons.cable_rounded, size: 18),
                        label: Text(
                          state.phase == FirmwarePhase.verifying
                              ? '前往设备页重新连接 USB'
                              : '前往设备页连接 USB',
                        ),
                      ),
                      const Text(
                        '使用 ESP32 原生 USB 数据口。首次需用网络 OTA 或 IDF 更新到固件 0.3.0；此后可通过 USB 日常升级，保留配置与绑定。',
                        style: TextStyle(color: Colors.blueGrey, fontSize: 12),
                      ),
                    ],
                  ),
                )
              : SectionCard(
                  title: '连接目标设备',
                  icon: Icons.router_outlined,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      field(
                        _address,
                        'ESP32 管理地址，例如 http://192.168.50.240',
                        'otaAddress',
                      ),
                      if (session.device?.ip.isNotEmpty == true)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 14),
                          child: TextButton.icon(
                            onPressed: !state.busy
                                ? () => setState(() {
                                    _address.text =
                                        'http://${session.device!.ip}';
                                    _device.text = session.profile.deviceId;
                                    _dirty = true;
                                  })
                                : null,
                            icon: const Icon(Icons.link_rounded, size: 16),
                            label: const Text('使用当前 ESP32 的地址'),
                          ),
                        ),
                      field(_device, 'ESP32 设备 ID', 'otaDevice'),
                      SecretTextField(
                        inputKey: const Key('otaToken'),
                        controller: _token,
                        enabled: !state.busy,
                        onChanged: (_) => setState(() => _dirty = true),
                        decoration: const InputDecoration(
                          labelText: 'ESP32 管理口令',
                        ),
                      ),
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text(
                          '记住管理连接',
                          style: TextStyle(fontSize: 13),
                        ),
                        value: _remember,
                        onChanged: !state.busy
                            ? (v) => setState(() => _remember = v ?? true)
                            : null,
                      ),
                      FilledButton.icon(
                        key: const Key('otaReadStatus'),
                        onPressed: !state.busy
                            ? () async {
                                await controller.readStatus(
                                  _target(),
                                  remember: _remember,
                                );
                                if (mounted &&
                                    !ref.read(firmwareProvider).error) {
                                  setState(() => _dirty = false);
                                }
                              }
                            : null,
                        icon: const Icon(Icons.refresh_rounded, size: 18),
                        label: const Text('连接并读取版本'),
                      ),
                      TextButton(
                        onPressed: !state.busy
                            ? () async {
                                await controller.forget();
                                if (mounted &&
                                    !ref.read(firmwareProvider).error) {
                                  setState(() {
                                    _token.clear();
                                    _dirty = true;
                                  });
                                }
                              }
                            : null,
                        child: const Text('清除保存的管理连接'),
                      ),
                    ],
                  ),
                ),
          second: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SectionCard(
                title: '运行中的固件',
                icon: Icons.memory_rounded,
                child: Column(
                  children: [
                    DetailRow(
                      '设备 ID',
                      state.device?['device_id'] as String? ?? '尚未核对',
                    ),
                    DetailRow(
                      '版本',
                      state.device?['firmware'] as String? ?? '未知',
                    ),
                    DetailRow('目标芯片', 'ESP32-S3'),
                    DetailRow(
                      '状态',
                      state.device == null
                          ? '请先读取状态'
                          : state.device!['busy'] == true
                          ? '设备忙碌'
                          : '可管理',
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              SectionCard(
                title: '应用镜像',
                icon: Icons.description_outlined,
                subtitle: '选择 tepy.bin，最大 4 MiB。',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    OutlinedButton.icon(
                      key: const Key('otaPickImage'),
                      onPressed: !state.busy
                          ? () => unawaited(controller.chooseImage())
                          : null,
                      icon: const Icon(Icons.folder_open_rounded, size: 18),
                      label: const Text('选择应用镜像'),
                    ),
                    if (state.image != null) ...[
                      const SizedBox(height: 16),
                      Text(
                        state.image!.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      DetailRow('镜像版本', state.image!.version),
                      DetailRow(
                        '大小',
                        '${(state.image!.length / 1024).toStringAsFixed(1)} KiB',
                      ),
                      const SizedBox(height: 8),
                      const Text('SHA256', style: TextStyle(fontSize: 11)),
                      SelectableText(
                        state.image!.digest,
                        style: const TextStyle(fontSize: 10),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        SectionCard(
          title: phase,
          icon: Icons.system_update_alt_rounded,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (state.busy) ...[
                LinearProgressIndicator(
                  value: state.phase == FirmwarePhase.uploading
                      ? state.progress
                      : null,
                ),
                const SizedBox(height: 16),
              ],
              Text(
                state.message,
                style: TextStyle(
                  fontSize: 13,
                  color: state.error ? Colors.redAccent : null,
                ),
              ),
              const SizedBox(height: 18),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  FilledButton.icon(
                    key: const Key('otaUpgrade'),
                    onPressed:
                        !state.busy &&
                            !_dirty &&
                            state.device != null &&
                            state.image != null &&
                            !session.busy &&
                            !session.preparingInput &&
                            (!usb ||
                                (usbState.connected &&
                                    !usbState.busy &&
                                    supportsUsbFirmware(state.device)))
                        ? () async {
                            final approved = await showDialog<bool>(
                              context: context,
                              builder: (dialog) => AlertDialog(
                                title: const Text('上传固件并重启？'),
                                content: Text(
                                  '方式：${usb ? 'USB 数据线' : '网络 OTA'}\n设备：${state.device!['device_id']}\n当前版本：${state.device!['firmware']}\n镜像版本：${state.image!.version}\n\n${usb ? '请保持数据线连接。写入后需在设备页重新连接，以确认运行版本。' : '请保持 ESP32 供电和网络连接。'}',
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () =>
                                        Navigator.pop(dialog, false),
                                    child: const Text('取消'),
                                  ),
                                  FilledButton(
                                    onPressed: () =>
                                        Navigator.pop(dialog, true),
                                    child: const Text('开始升级'),
                                  ),
                                ],
                              ),
                            );
                            if (approved == true) {
                              if (usb) {
                                await controller.upgradeUsb(
                                  _device.text.trim().toLowerCase(),
                                );
                              } else {
                                await controller.upgrade();
                              }
                            }
                          }
                        : null,
                    icon: const Icon(Icons.upgrade_rounded, size: 19),
                    label: const Text('上传并升级'),
                  ),
                  if (state.busy)
                    OutlinedButton(
                      onPressed: controller.cancel,
                      child: const Text('停止等待'),
                    ),
                  if (usb && state.phase == FirmwarePhase.verifying)
                    TextButton.icon(
                      onPressed: widget.onUsbRequested,
                      icon: const Icon(Icons.cable_rounded, size: 18),
                      label: const Text('重新连接 USB 核对版本'),
                    ),
                ],
              ),
              const SizedBox(height: 14),
              const Text(
                '上传结束后仍会核对重启和版本。中断或未确认时，先读取设备状态；不会自动重传镜像。',
                style: TextStyle(fontSize: 11),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
