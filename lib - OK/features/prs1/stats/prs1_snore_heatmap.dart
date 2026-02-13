// lib/features/prs1/stats/prs1_snore_heatmap.dart
//
// Minute-resolution snore "intensity" series to back OSCAR-like heatmaps.
// This is intentionally simple and fast:
// - Each minute bucket contains the sum of snore-like event intensities in that minute.
// - UI can map counts (or normalized counts) to a color ramp.

import '../model/prs1_event.dart';

class Prs1SnoreHeatmap {
  /// Build a [minutes] length array of snore intensity per minute.
  ///
  /// Strategy (robust across PRS1 variants):
  /// - Treat these event types as "snore-like":
  ///     - Prs1EventType.snore (prefer value as snoreCount/intensity if present)
  ///     - Prs1EventType.vibratorySnore (VS)
  ///     - Prs1EventType.vibratorySnore2 (VS2)
  /// - If value is null/<=0, fall back to 1.
  static List<int> countsPerMinute({
    required int dayStartEpochSec,
    required int minutes,
    required List<Prs1Event> events,
  }) {
    final out = List<int>.filled(minutes, 0);
    if (minutes <= 0) return out;

    final start = dayStartEpochSec;
    final end = dayStartEpochSec + minutes * 60;

    for (final e in events) {
      final isSnoreLike = (e.type == Prs1EventType.snore ||
          e.type == Prs1EventType.vibratorySnore ||
          e.type == Prs1EventType.vibratorySnore2);
      if (!isSnoreLike) continue;

      final t = e.time.toUtc().millisecondsSinceEpoch ~/ 1000;
      if (t < start || t >= end) continue;

      final m = (t - start) ~/ 60;
      if (m < 0 || m >= minutes) continue;

      final num? raw = e.value;
      final int v = (raw == null) ? 1 : raw.round();
      out[m] += (v <= 0 ? 1 : v);
    }
    return out;
  }

  /// Return the maximum minute-count (0 if empty).
  static int maxCount(List<int> counts) {
    int m = 0;
    for (final c in counts) {
      if (c > m) m = c;
    }
    return m;
  }
}
