// lib/features/prs1/index/prs1_header_index.dart

import 'dart:typed_data';

import '../../../core/logging.dart';

/// Minimal per-file header info for Phase 1 "Header 準濾".
class Prs1HeaderEntry {
  Prs1HeaderEntry({
    required this.relativePath,
    required this.sizeBytes,
    required this.timestampLocal,
    required this.kind,
    this.sessionId,
  });

  final String relativePath;
  final int sizeBytes;

  /// Best-effort local timestamp derived from header.
  ///
  /// For PRS1 chunk files this comes from common header (unix seconds).
  /// For EDF this comes from EDF header start date/time.
  final DateTime? timestampLocal;

  /// 'chunk' | 'edf' | 'other'
  final String kind;

  /// PRS1 sessionId for chunk files (if available)
  final int? sessionId;
}

class Prs1HeaderIndex {
  Prs1HeaderIndex({required this.entries});

  final List<Prs1HeaderEntry> entries;

  DateTime? get lastUsedDateLocal {
    DateTime? newest;
    for (final e in entries) {
      final t = e.timestampLocal;
      if (t == null) continue;
      if (newest == null || t.isAfter(newest)) newest = t;
    }
    return newest;
  }

  /// Builds a header index from a map of relativePath -> header bytes.
  ///
  /// [sizeBytesByRelPath] is optional but helps debug counts/visibility.
  static Prs1HeaderIndex buildFromHeads({
    required Map<String, Uint8List> headBytesByRelPath,
    Map<String, int>? sizeBytesByRelPath,
  }) {
    final out = <Prs1HeaderEntry>[];
    for (final e in headBytesByRelPath.entries) {
      final rel = e.key;
      final head = e.value;
      final lower = rel.toLowerCase();

      if (lower.endsWith('.edf')) {
        out.add(
          Prs1HeaderEntry(
            relativePath: rel,
            sizeBytes: sizeBytesByRelPath?[rel] ?? head.length,
            timestampLocal: _tryParseEdfStartLocal(head),
            kind: 'edf',
          ),
        );
        continue;
      }

      // Numeric 3-digit extension (.000..999)
      if (RegExp(r'\.[0-9]{3}\$').hasMatch(lower) && head.length >= 15) {
        final sid = _u32le(head, 7);
        final ts = _u32le(head, 11);
        final tLocal = _unixSecondsToLocal(ts);
        out.add(
          Prs1HeaderEntry(
            relativePath: rel,
            sizeBytes: sizeBytesByRelPath?[rel] ?? head.length,
            timestampLocal: tLocal,
            kind: 'chunk',
            sessionId: sid,
          ),
        );
        continue;
      }

      out.add(
        Prs1HeaderEntry(
          relativePath: rel,
          sizeBytes: sizeBytesByRelPath?[rel] ?? head.length,
          timestampLocal: null,
          kind: 'other',
        ),
      );
    }

    out.sort((a, b) => a.relativePath.compareTo(b.relativePath));
    return Prs1HeaderIndex(entries: out);
  }

  static int _u32le(Uint8List b, int o) {
    return (b[o]) | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);
  }

  static DateTime? _unixSecondsToLocal(int ts) {
    // Safety range: 2000..2100
    if (ts < 946684800 || ts > 4102444800) return null;
    return DateTime.fromMillisecondsSinceEpoch(ts * 1000, isUtc: true).toLocal();
  }

  /// EDF header is 256 bytes. Start date/time offsets are standardized:
  /// - 168..175 : startdate (dd.mm.yy)
  /// - 176..183 : starttime (hh.mm.ss)
  static DateTime? _tryParseEdfStartLocal(Uint8List head) {
    if (head.length < 184) return null;

    String readAscii(int start, int len) {
      final sub = Uint8List.sublistView(head, start, start + len);
      return String.fromCharCodes(sub).trim();
    }

    final date = readAscii(168, 8);
    final time = readAscii(176, 8);

    // dd.mm.yy / hh.mm.ss
    try {
      final d = date.split('.');
      final t = time.split('.');
      if (d.length != 3 || t.length != 3) return null;

      final dd = int.parse(d[0]);
      final mm = int.parse(d[1]);
      final yy = int.parse(d[2]);

      final hh = int.parse(t[0]);
      final mi = int.parse(t[1]);
      final ss = int.parse(t[2]);

      // EDF uses 2-digit year. Heuristic:
      // - 85..99 => 1985..1999
      // - else => 2000..2084
      final year = (yy >= 85) ? (1900 + yy) : (2000 + yy);

      // EDF header is local time in many devices; treat as local.
      return DateTime(year, mm, dd, hh, mi, ss);
    } catch (e) {
      Log.w('EDF header date parse failed: date="$date" time="$time" err=$e', tag: 'PRS1');
      return null;
    }
  }
}
