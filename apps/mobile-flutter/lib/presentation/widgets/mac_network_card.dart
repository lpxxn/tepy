import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_theme.dart';
import '../../domain/snapshots.dart';
import 'common.dart';

/// 复用于概览和 Mac 详情。旧 Agent 没有 network 字段时仍保留其它状态。
class MacNetworkCard extends StatelessWidget {
  const MacNetworkCard({super.key, required this.mac});
  final MacSnapshot? mac;
  @override
  Widget build(BuildContext context) {
    final network = mac?.network;
    return SectionCard(
      title: 'Mac IP 地址',
      icon: Icons.lan_outlined,
      subtitle: '随状态更新 · 多网卡分别显示',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (mac == null)
            const Text(
              '等待当前 Mac 状态。',
              style: TextStyle(color: muted, fontSize: 12),
            )
          else if (network == null)
            const Text(
              '尚未上报 IP，请更新 Mac Agent 至 0.2.1 或以上。',
              style: TextStyle(color: muted, fontSize: 12),
            )
          else ...[
            if (!network.available)
              const Text(
                '部分网卡信息暂不可用。',
                style: TextStyle(color: muted, fontSize: 12),
              ),
            if (network.available && network.addresses.isEmpty)
              const Text(
                '当前没有可显示的 IP 地址。',
                style: TextStyle(color: muted, fontSize: 12),
              ),
            for (final address in network.addresses)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${address.interfaceName} · ${address.family == 'ipv4' ? 'IPv4' : 'IPv6'}',
                            style: const TextStyle(fontSize: 11, color: muted),
                          ),
                          const SizedBox(height: 4),
                          SelectableText(
                            address.ip,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: '复制 IP 地址',
                      icon: const Icon(Icons.copy_rounded, size: 17),
                      onPressed: () =>
                          Clipboard.setData(ClipboardData(text: address.ip)),
                    ),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }
}
