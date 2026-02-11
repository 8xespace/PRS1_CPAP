// lib/features/prs1/binary/crc.dart

import 'dart:typed_data';

/// CRC utilities.
///
/// PRS1 files use multiple checksums depending on record type/firmware.
/// Until we finish mirroring OSCAR's exact variants, we provide the common ones.
class Crc {
  /// CRC-16/CCITT-FALSE (poly 0x1021, init 0xFFFF, xorOut 0x0000).
  static int crc16CcittFalse(Uint8List data, {int init = 0xFFFF}) {
    int crc = init & 0xFFFF;
    for (final b in data) {
      crc ^= (b << 8);
      for (int i = 0; i < 8; i++) {
        if ((crc & 0x8000) != 0) {
          crc = ((crc << 1) ^ 0x1021) & 0xFFFF;
        } else {
          crc = (crc << 1) & 0xFFFF;
        }
      }
    }
    return crc & 0xFFFF;
  }

  /// Standard CRC-32 (ISO-HDLC), poly 0x04C11DB7 (reflected 0xEDB88320), init 0xFFFFFFFF, xorOut 0xFFFFFFFF.
  static int crc32(Uint8List data) {
    int crc = 0xFFFFFFFF;
    for (final b in data) {
      crc ^= b;
      for (int i = 0; i < 8; i++) {
        final mask = -(crc & 1);
        crc = (crc >> 1) ^ (0xEDB88320 & mask);
      }
    }
    return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
  }
}
