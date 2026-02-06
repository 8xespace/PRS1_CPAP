// lib/features/prs1/stats/prs1_snore_heatmap.dart
//
// Minute-resolution snore "intensity" series to back OSCAR-like heatmaps.
// This is intentionally simple and fast:
// - Each minute bucket contains the count of snore events in that minute.
// - UI can map counts (or normalized counts) to a color ramp.

import '../model/prs1_event.dart';

class Prs1SnoreHeatmap {
  /// Build a [minutes] length array of snore event counts per minute.
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
      if (e.type != Prs1EventType.snore) continue;
      final t = e.time.toUtc().millisecondsSinceEpoch ~/ 1000;
      if (t < start || t >= end) continue;
      final m = (t - start) ~/ 60;
      if (m >= 0 && m < minutes) out[m] += 1;
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
