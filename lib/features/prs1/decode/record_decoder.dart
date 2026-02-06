// lib/features/prs1/decode/record_decoder.dart
//
// Layer 6: introduce a sub-record abstraction so we can converge on OSCAR's
// table-driven decoding without breaking compilation on Web.
//
// Reality check:
// - PRS1 variants differ. Some store: [u16 len][payload][u16 crc]
// - Inside payload, many store 1+ logical sub-records, often as:
//     [u8 type][u8 flags][u16 len][len bytes data]
//   This file implements a conservative heuristic splitter:
//   - If the pattern fits, we yield sub-records
//   - Otherwise, we treat the whole payload as a single record.

import 'dart:typed_data';

import '../binary/le_reader.dart';
import 'frame_decoder.dart';

class RecordDecoder {
  const RecordDecoder();

  Iterable<Prs1Record> decode(Prs1Frame frame) sync* {
    final p = frame.payload;
    if (p.length < 4) {
      yield Prs1Record.single(frame);
      return;
    }

    final r = LeReader(p);
    int idx = 0;

    while (!r.eof) {
      final start = r.pos;
      if (r.remaining < 4) break;

      final type = r.u8();
      final flags = r.u8();
      final len = r.u16();

      // Heuristic sanity:
      // - len must fit in remaining bytes
      // - len must be non-zero (otherwise we risk infinite loops)
      if (len == 0) break;
      if (len > r.remaining) {
        // Not a sub-record stream; fall back to whole payload.
        idx = 0;
        break;
      }

      final data = r.bytes(len);
      yield Prs1Record(
        frameOffset: frame.offset,
        indexInFrame: idx,
        type: type,
        flags: flags,
        data: data,
        crcOk: frame.crcOk,
        raw: frame.raw,
      );
      idx++;

      // Hard guard: avoid pathological loops.
      if (idx > 50000) break;

      // If we consumed exactly the frame payload, we're done.
      if (r.eof) return;

      // Otherwise, continue; some payloads pack multiple sub-records.
      // If the next header is implausible, we will break and fallback below.
      final look = r.pos;
      if (r.remaining >= 4) {
        final t2 = p[look];
        final len2 = p[look + 2] | (p[look + 3] << 8);
        if (len2 == 0 || len2 > r.remaining - 4) {
          break;
        }
        // t2 is free-form; we don't constrain it.
      }
    }

    // Fallback to a single synthetic record when the heuristic doesn't fit.
    if (idx == 0) {
      yield Prs1Record(
        frameOffset: frame.offset,
        indexInFrame: 0,
        type: 0xFF,
        flags: 0,
        data: p,
        crcOk: frame.crcOk,
        raw: frame.raw,
      );
    }
  }
}

class Prs1Record {
  const Prs1Record({
    required this.frameOffset,
    required this.indexInFrame,
    required this.type,
    required this.flags,
    required this.data,
    required this.crcOk,
    required this.raw,
  });

  factory Prs1Record.single(Prs1Frame frame) => Prs1Record(
        frameOffset: frame.offset,
        indexInFrame: 0,
        type: 0xFF,
        flags: 0,
        data: frame.payload,
        crcOk: frame.crcOk,
        raw: frame.raw,
      );

  final int frameOffset;
  final int indexInFrame;

  /// Best-effort record type (u8) when we detect a sub-record header.
  /// When unknown, we use 0xFF.
  final int type;

  /// Best-effort flags (u8) when we detect a sub-record header.
  final int flags;

  /// Record data (header removed if sub-record header was detected).
  final Uint8List data;

  final bool crcOk;
  final Uint8List raw;
}
