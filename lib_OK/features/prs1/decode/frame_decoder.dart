// lib/features/prs1/decode/frame_decoder.dart

import 'dart:typed_data';

import '../binary/crc.dart';
import '../binary/le_reader.dart';

/// Frame/record-level decoder for PRS1 binary blobs.
///
/// Layer 5 upgrade:
/// - Still uses a conservative length-prefixed iterator (u16le length),
///   but now attempts to detect and strip an in-record CRC16 footer.
///
/// Why:
/// - Many PRS1 variants store records as: [u16 len][...data...][u16 crc16]
///   where crc16 is computed over the data portion.
/// - We don't assume this is always true; we merely mark [crcOk] when it matches.
class FrameDecoder {
  const FrameDecoder();

  /// Iterate records inside a PRS1 blob.
  ///
  /// Strategy:
  /// - Read u16 little-endian length (len)
  /// - Read [len] bytes as a raw block
  /// - If block ends with crc16 that matches block[0:len-2], strip it and set crcOk=true
  ///
  /// Notes:
  /// - Some PRS1 variants use u32 lengths or have per-record headers; we will
  ///   upgrade once we mirror the concrete layout from OSCAR.
  Iterable<Prs1Frame> decode(Uint8List bytes) sync* {
    final r = LeReader(bytes);
    int guard = 0;

    while (!r.eof) {
      if (r.remaining < 2) break;

      final offset = r.pos;
      final len = r.u16();

      // Basic sanity checks to avoid infinite loops on garbage.
      if (len == 0) break;
      if (len > r.remaining) break;

      final raw = r.bytes(len);

      bool crcOk = false;
      int? crcRead;
      Uint8List payload = raw;

      if (raw.length >= 4) {
        // Try CRC16 footer: last 2 bytes are little-endian crc.
        final dataLen = raw.length - 2;
        final expected = (raw[dataLen] | (raw[dataLen + 1] << 8)) & 0xFFFF;
        final computed = Crc.crc16CcittFalse(Uint8List.sublistView(raw, 0, dataLen));

        if (computed == expected) {
          crcOk = true;
          crcRead = expected;
          payload = Uint8List.sublistView(raw, 0, dataLen);
        }
      }

      yield Prs1Frame(
        offset: offset,
        length: len,
        payload: payload,
        raw: raw,
        crcOk: crcOk,
        crc16: crcRead,
      );

      guard++;
      if (guard > 200000) {
        // Hard guard: if we ever hit this, the format isn't length-prefixed in this way.
        break;
      }
    }
  }
}

class Prs1Frame {
  const Prs1Frame({
    required this.offset,
    required this.length,
    required this.payload,
    required this.raw,
    required this.crcOk,
    required this.crc16,
  });

  /// Offset in the original blob where the record starts (at length field).
  final int offset;

  /// Raw block length (as stored after the u16 length field).
  final int length;

  /// Best-effort payload bytes (CRC footer stripped when detected).
  final Uint8List payload;

  /// Raw bytes (includes CRC footer when present).
  final Uint8List raw;

  /// Whether a CRC16 footer was detected and verified.
  final bool crcOk;

  /// CRC16 value that was read when [crcOk] is true.
  final int? crc16;
}
