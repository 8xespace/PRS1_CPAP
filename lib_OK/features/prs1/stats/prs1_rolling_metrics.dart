// lib/features/prs1/stats/prs1_rolling_metrics.dart
//
// Milestone F: Rolling/windowed metrics (OSCAR-like).
//
// We build minute-resolution time series for a given day bucket.
// Focus: rolling AHI (5m/10m/30m) + event density over time.

import '../model/prs1_event.dart';
import '../model/prs1_signal_sample.dart';

class Prs1TimePoint {
  const Prs1TimePoint({required this.tEpochSec, required this.value});
  final int tEpochSec;
  final double? value;
}

class Prs1RollingMetrics {
  /// Build rolling AHI series at 1-minute resolution.
  ///
  /// - [dayStartEpochSec]: local-day start in epoch seconds (UTC-based epoch).
  /// - [minutes]: number of minutes to output (usually 24*60).
  /// - [usageSecondsPerMinute]: [minutes] length, each 0..60
  /// - [eventCountsPerMinute]: [minutes] length
  static List<Prs1TimePoint> rollingAhi({
    required int dayStartEpochSec,
    required int minutes,
    required List<int> usageSecondsPerMinute,
    required List<int> eventCountsPerMinute,
    required int windowMinutes,
  }) {
    final out = <Prs1TimePoint>[];
    if (minutes <= 0) return out;
    if (usageSecondsPerMinute.length != minutes || eventCountsPerMinute.length != minutes) return out;
    if (windowMinutes <= 0) return out;

    final prefUse = List<int>.filled(minutes + 1, 0);
    final prefEvt = List<int>.filled(minutes + 1, 0);
    for (int i = 0; i < minutes; i++) {
      prefUse[i + 1] = prefUse[i] + usageSecondsPerMinute[i];
      prefEvt[i + 1] = prefEvt[i] + eventCountsPerMinute[i];
    }

    for (int i = 0; i < minutes; i++) {
      final lo = (i - windowMinutes + 1) < 0 ? 0 : (i - windowMinutes + 1);
      final hi = i + 1;

      final useSec = prefUse[hi] - prefUse[lo];
      final evt = prefEvt[hi] - prefEvt[lo];

      double? ahi;
      if (useSec > 0) {
        final hours = useSec / 3600.0;
        ahi = evt / hours;
      } else {
        ahi = null;
      }

      out.add(Prs1TimePoint(tEpochSec: dayStartEpochSec + i * 60, value: ahi));
    }

    return out;
  }

  /// Build per-minute usage seconds array from session slices.
  static List<int> buildUsageSecondsPerMinute({
    required int dayStartEpochSec,
    required int minutes,
    required List<Prs1UsageSlice> slices,
  }) {
    final out = List<int>.filled(minutes, 0);

    for (final s in slices) {
      final a = s.startEpochSec;
      final b = s.endEpochSecExclusive;
      if (b <= a) continue;

      // Clamp to day.
      final start = a < dayStartEpochSec ? dayStartEpochSec : a;
      final end = b > dayStartEpochSec + minutes * 60 ? (dayStartEpochSec + minutes * 60) : b;
      if (end <= start) continue;

      int cur = start;
      while (cur < end) {
        final minuteIndex = ((cur - dayStartEpochSec) / 60).floor();
        if (minuteIndex < 0 || minuteIndex >= minutes) break;
        final minuteStart = dayStartEpochSec + minuteIndex * 60;
        final minuteEnd = minuteStart + 60;

        final segEnd = end < minuteEnd ? end : minuteEnd;
        out[minuteIndex] += (segEnd - cur);
        cur = segEnd;
      }
    }

    // Cap at 60 per minute.
    for (int i = 0; i < out.length; i++) {
      if (out[i] > 60) out[i] = 60;
      if (out[i] < 0) out[i] = 0;
    }

    return out;
  }

  /// Build per-minute AHI event counts (OA+CA+H) from events.
  static List<int> buildAhiEventCountsPerMinute({
    required int dayStartEpochSec,
    required int minutes,
    required List<Prs1Event> events,
  }) {
    final out = List<int>.filled(minutes, 0);
    for (final e in events) {
      final t = (e.time.millisecondsSinceEpoch / 1000).floor();
      final idx = ((t - dayStartEpochSec) / 60).floor();
      if (idx < 0 || idx >= minutes) continue;

      if (e.type == Prs1EventType.obstructiveApnea ||
          e.type == Prs1EventType.clearAirwayApnea ||
          e.type == Prs1EventType.hypopnea) {
        out[idx] += 1;
      }
    }
    return out;
  }
}

/// Session slice for rolling computation.
class Prs1UsageSlice {
  Prs1UsageSlice(this.startEpochSec, this.endEpochSecExclusive);
  final int startEpochSec;
  final int endEpochSecExclusive;
}
