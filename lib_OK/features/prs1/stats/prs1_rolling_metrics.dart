// lib/features/prs1/stats/prs1_rolling_metrics.dart
//
// Milestone F: Rolling/windowed metrics (OSCAR-like).
//
// We build minute-resolution time series for a given day bucket.
// Focus: rolling AHI (5m/10m/30m) + event density over time.

import '../model/prs1_event.dart';
import '../model/prs1_breath.dart';
import '../model/prs1_signal_sample.dart';

class Prs1TimePoint {
  const Prs1TimePoint({required this.tEpochSec, required this.value});
  final int tEpochSec;
  final double? value;
}

class Prs1RollingMetrics {
  /// Rolling median of a breath-derived metric, resampled to 1 point per minute.
  ///
  /// MV / RR / TV are all produced from the same breath segmentation pipeline,
  /// so the daily aggregator uses this shared helper.
  static List<Prs1TimePoint> rollingMedianBreathMetric({
    required int dayStartEpochSec,
    required List<Prs1Breath> breaths,
    required int windowMinutes,
    required double Function(Prs1Breath b) valueOf,
  }) {
    return rollingBreathMedian(
      dayStartEpochSec: dayStartEpochSec,
      breaths: breaths,
      minutes: 24 * 60,
      windowMinutes: windowMinutes,
      valueOf: valueOf,
    );
  }

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

  /// Rolling median from breath-level metrics.
  ///
  /// - Samples are binned to 1-minute buckets by [Prs1Breath.startEpochMs].
  /// - For each minute, we look back [windowMinutes] and compute the median.
  /// - If a window has no samples, the point value is null.
  static List<Prs1TimePoint> rollingMedianFromBreaths({
    required DateTime day,
    required List<Prs1Breath> breaths,
    required int windowMinutes,
    required double? Function(Prs1Breath b) valueOf,
  }) {
    final dayStart = DateTime.utc(day.year, day.month, day.day);
    final dayStartEpochSec = dayStart.millisecondsSinceEpoch ~/ 1000;

    // 24h + 1 point at end (for alignment with other rolling series)
    const totalMinutes = 24 * 60;
    final perMin = List<List<double>>.generate(totalMinutes, (_) => <double>[]);

    for (final b in breaths) {
      final v = valueOf(b);
      if (v == null || v.isNaN || v.isInfinite) continue;
      final sec = b.startEpochMs ~/ 1000;
      final idx = (sec - dayStartEpochSec) ~/ 60;
      if (idx < 0 || idx >= totalMinutes) continue;
      perMin[idx].add(v);
    }

    final out = <Prs1TimePoint>[];
    for (var m = 0; m <= totalMinutes; m++) {
      final endMin = m.clamp(0, totalMinutes - 1);
      final startMin = (endMin - windowMinutes + 1).clamp(0, totalMinutes - 1);
      final window = <double>[];
      for (var i = startMin; i <= endMin; i++) {
        if (perMin[i].isNotEmpty) window.addAll(perMin[i]);
      }

      final val = window.isEmpty ? null : _median(window);
      out.add(Prs1TimePoint(
        tEpochSec: dayStartEpochSec + m * 60,
        value: val,
      ));
    }
    return out;
  }

  static double _median(List<double> values) {
    values.sort();
    final n = values.length;
    if (n == 0) return double.nan;
    if (n.isOdd) return values[n ~/ 2];
    final a = values[n ~/ 2 - 1];
    final b = values[n ~/ 2];
    return (a + b) / 2.0;
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

  /// Rolling median series derived from breath-level metrics.
  ///
  /// Used for MV/RR/TV pre-chart series. Values are:
  /// - Binned to 1-minute buckets by breath.startEpochSec
  /// - For each minute `m`, we look back `windowMinutes` (inclusive) and
  ///   compute a median of all values in that window.
  ///
  /// If there are no breaths in the window, the point's value will be null.
  static List<Prs1TimePoint> rollingBreathMedian({
    required int dayStartEpochSec,
    required int minutes,
    required List<Prs1Breath> breaths,
    required int windowMinutes,
    required double? Function(Prs1Breath b) valueOf,
  }) {
    final perMin = List<List<double>>.generate(minutes, (_) => <double>[]);

    for (final b in breaths) {
      final v = valueOf(b);
      if (v == null || v.isNaN || v.isInfinite) continue;
      final bStartEpochSec = (b.startEpochMs / 1000).floor();
      final idx = ((bStartEpochSec - dayStartEpochSec) / 60).floor();
      if (idx < 0 || idx >= minutes) continue;
      perMin[idx].add(v);
    }

    final out = <Prs1TimePoint>[];
    for (int i = 0; i < minutes; i++) {
      final start = (i - windowMinutes + 1).clamp(0, minutes - 1);
      final buf = <double>[];
      for (int k = start; k <= i; k++) {
        buf.addAll(perMin[k]);
      }
      final med = _medianOrNull(buf);
      out.add(Prs1TimePoint(tEpochSec: dayStartEpochSec + i * 60, value: med));
    }
    return out;
  }

  /// Rolling mean series derived from breath-level metrics.
  static List<Prs1TimePoint> rollingBreathMean({
    required int dayStartEpochSec,
    required int minutes,
    required List<Prs1Breath> breaths,
    required int windowMinutes,
    required double? Function(Prs1Breath b) valueOf,
  }) {
    final perMin = List<List<double>>.generate(minutes, (_) => <double>[]);
    for (final b in breaths) {
      final v = valueOf(b);
      if (v == null || v.isNaN || v.isInfinite) continue;
      final bStartEpochSec = (b.startEpochMs / 1000).floor();
      final idx = ((bStartEpochSec - dayStartEpochSec) / 60).floor();
      if (idx < 0 || idx >= minutes) continue;
      perMin[idx].add(v);
    }

    final out = <Prs1TimePoint>[];
    for (int i = 0; i < minutes; i++) {
      final start = (i - windowMinutes + 1).clamp(0, minutes - 1);
      double sum = 0;
      int count = 0;
      for (int k = start; k <= i; k++) {
        final list = perMin[k];
        for (final v in list) {
          sum += v;
          count += 1;
        }
      }
      final mean = count == 0 ? null : (sum / count);
      out.add(Prs1TimePoint(tEpochSec: dayStartEpochSec + i * 60, value: mean));
    }
    return out;
  }

  static double? _medianOrNull(List<double> values) {
    if (values.isEmpty) return null;
    values.sort();
    final n = values.length;
    if (n.isOdd) return values[n ~/ 2];
    final a = values[n ~/ 2 - 1];
    final b = values[n ~/ 2];
    return (a + b) / 2.0;
  }
}

/// Session slice for rolling computation.
class Prs1UsageSlice {
  Prs1UsageSlice(this.startEpochSec, this.endEpochSecExclusive);
  final int startEpochSec;
  final int endEpochSecExclusive;
}
