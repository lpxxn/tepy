import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'connection_profile.dart';

/// 普通 ESP-IDF 应用镜像：校验段边界、S3 芯片、app_desc、XOR 与附加 SHA256。
/// SHA256 只检查文件完整性，不是发布者签名。设备还会执行自己的完整镜像校验。
final class FirmwareImage {
  FirmwareImage._(this.name, this.version, this.digest, this._bytes);
  static const maximumSize = 4 * 1024 * 1024;
  final String name, version, digest;
  final Uint8List _bytes;
  int get length => _bytes.length;
  Stream<List<int>> chunks() async* {
    for (var start = 0; start < _bytes.length; start += 16384) {
      yield Uint8List.sublistView(
        _bytes,
        start,
        (start + 16384).clamp(0, _bytes.length),
      );
    }
  }

  static FirmwareImage inspect(String name, Uint8List input) {
    Never invalid([String? text]) => throw AppFailure(
      text ?? '请选择完整的 ESP32-S3 tepy.bin 应用镜像，不要使用合并镜像或 bootloader。',
    );
    if (input.length <= 288 ||
        input.length > maximumSize ||
        input[0] != 0xe9 ||
        input[1] < 1 ||
        input[1] > 16) {
      invalid();
    }
    // IDF 文件字段使用小端序。24 字节镜像头后是 8 字节首段头，再是 app_desc。
    final data = ByteData.sublistView(input);
    if (data.getUint16(12, Endian.little) != 9 ||
        data.getUint32(32, Endian.little) != 0xabcd5432 ||
        input[23] != 1) {
      invalid();
    }
    String field(int start) {
      final bytes = input.sublist(start, start + 32), zero = bytes.indexOf(0);
      if (zero < 1) invalid();
      try {
        return ascii.decode(bytes.sublist(0, zero));
      } catch (_) {
        invalid();
      }
    }

    final version = field(48), project = field(80);
    if (project != 'tepy' || version.codeUnits.any((c) => c < 32 || c > 126)) {
      invalid('镜像项目名必须是 tepy，版本必须是可打印字符。');
    }
    var position = 24, checksum = 0xef;
    for (var segment = 0; segment < input[1]; segment++) {
      if (position + 8 > input.length) invalid();
      final size = data.getUint32(position + 4, Endian.little);
      position += 8;
      if (position + size > input.length || (segment == 0 && size < 256)) {
        invalid();
      }
      for (var i = position; i < position + size; i++) {
        checksum ^= input[i];
      }
      position += size;
    }
    // 所有段之后补零到 16 字节块的最后一字节，此处保存 XOR 校验和。
    final checksumAt = ((position + 16) ~/ 16) * 16 - 1;
    if (checksumAt + 33 != input.length || input[checksumAt] != checksum) {
      invalid('镜像长度或校验和不匹配，文件可能损坏。');
    }
    for (var i = position; i < checksumAt; i++) {
      if (input[i] != 0) invalid('镜像填充区域无效。');
    }
    final expected = sha256
        .convert(Uint8List.sublistView(input, 0, checksumAt + 1))
        .bytes;
    for (var i = 0; i < 32; i++) {
      if (expected[i] != input[checksumAt + 1 + i]) {
        invalid('镜像 SHA256 不匹配，文件可能损坏。');
      }
    }
    return FirmwareImage._(
      name,
      version,
      sha256.convert(input).toString(),
      Uint8List.fromList(input).asUnmodifiableView(),
    );
  }
}
