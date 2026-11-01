import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:tepy_mobile/domain/firmware_image.dart';

Uint8List firmwareBytes({
  String version = '9.9.9',
  String project = 'tepy',
  int payloadSize = 256,
}) {
  final checksumAt = ((32 + payloadSize + 16) ~/ 16) * 16 - 1;
  final bytes = Uint8List(checksumAt + 33), data = ByteData.sublistView(bytes);
  bytes[0] = 0xe9;
  bytes[1] = 1;
  bytes[23] = 1;
  data.setUint16(12, 9, Endian.little);
  data.setUint32(24, 0x3fca0000, Endian.little);
  data.setUint32(28, payloadSize, Endian.little);
  data.setUint32(32, 0xabcd5432, Endian.little);
  bytes.setRange(48, 48 + version.length, ascii.encode(version));
  bytes.setRange(80, 80 + project.length, ascii.encode(project));
  var sum = 0xef;
  for (var i = 288; i < 32 + payloadSize; i++) {
    bytes[i] = i & 255;
  }
  for (var i = 32; i < 32 + payloadSize; i++) {
    sum ^= bytes[i];
  }
  bytes[checksumAt] = sum;
  bytes.setRange(
    checksumAt + 1,
    bytes.length,
    sha256.convert(bytes.sublist(0, checksumAt + 1)).bytes,
  );
  return bytes;
}

FirmwareImage testFirmware() =>
    FirmwareImage.inspect('tepy.bin', firmwareBytes());
