import 'dart:io';

/// IP 是当前快照的附加信息，不用于解锁条件，也不代替 MQTT 的 Agent ID。
final class MacNetworkAddress {
  const MacNetworkAddress(this.interfaceName, this.ip, this.family);
  final String interfaceName, ip, family;
}

final class MacNetwork {
  const MacNetwork(this.available, this.addresses);
  final bool available;
  final List<MacNetworkAddress> addresses;

  static MacNetwork? parse(dynamic value) {
    if (value is! Map<String, dynamic> ||
        value['available'] is! bool ||
        value['addresses'] is! List) {
      return null; // 兼容未上报 network 的旧 Agent。
    }
    final raw = value['addresses'] as List;
    if (raw.length > 32) return null;
    final result = <MacNetworkAddress>[], seen = <String>{};
    for (final entry in raw) {
      if (entry is! Map<String, dynamic> ||
          entry['interface'] is! String ||
          !RegExp(r'^[A-Za-z0-9_.:-]{1,64}$')
              .hasMatch(entry['interface'] as String) ||
          entry['ip'] is! String ||
          (entry['ip'] as String).length > 45 ||
          !{'ipv4', 'ipv6'}.contains(entry['family'])) {
        return null;
      }
      // tryParse 只解析数字地址，不做 DNS；不接受 URL、主机名或网段。
      final ip = InternetAddress.tryParse(entry['ip'] as String);
      if (ip == null ||
          ip.isLoopback ||
          ip.isLinkLocal ||
          ip.isMulticast ||
          {'0.0.0.0', '::'}.contains(ip.address) ||
          (entry['family'] == 'ipv4') !=
              (ip.type == InternetAddressType.IPv4) ||
          !seen.add('${entry['interface']}|${ip.address}')) {
        return null;
      }
      result.add(
        MacNetworkAddress(
          entry['interface'] as String,
          ip.address,
          entry['family'] as String,
        ),
      );
    }
    return MacNetwork(value['available'] as bool, List.unmodifiable(result));
  }
}
