// Time-weighted statistics utilities for PRS1 continuous samples.
// Milestone B: the statistical "heart" of the engine.
//
// Design goals:
// - Works with irregularly spaced samples.
// - Uses *time duration* between samples as weights (seconds).
// - Produces robust weighted quantiles (median, 95th, etc.).
// - Computes fraction/time over/under thresholds and in ranges.
// - Generic: can be used for pressure/leak/flow and also binary flags (e.g., Flex active).

import 'dart:math' as math;

class Prs1WeightedInterval<T> {
  /// Interval start time, epoch seconds.
  final int t0;

  /// Interval end time (exclusive), epoch seconds.
  final int t1;

  /// Value held over [t0, t1).
  final T value;

  const Prs1WeightedInterval({
    required this.t0,
    required this.t1,
    required this.value,
  });

  int get seconds => math.max(0, t1 - t0);
}

/// Builds piecewise-constant time intervals from a list of samples.
///
/// Assumptions:
/// - Each sample represents the value at its timestamp and holds until the next sample.
/// - The last sample holds until [endEpochSec] if provided; otherwise it contributes 0 seconds.
List<Prs1WeightedInterval<double>> buildNumericIntervals({
  required List<dynamic> samples,
  required int Function(dynamic s) timeEpochSec,
  required double Function(dynamic s) value,
  int? endEpochSec,
}) {
  if (samples.isEmpty) return const [];
  final sorted = List<dynamic>.from(samples)
    ..sort((a, b) => timeEpochSec(a).compareTo(timeEpochSec(b)));

  final intervals = <Prs1WeightedInterval<double>>[];
  for (int i = 0; i < sorted.length; i++) {
    final s = sorted[i];
    final t0 = timeEpochSec(s);
    final t1 = (i + 1 < sorted.length) ? timeEpochSec(sorted[i + 1]) : (endEpochSec ?? t0);
    if (t1 <= t0) continue;

    final v = value(s);
    if (v.isNaN || v.isInfinite) continue;

    intervals.add(Prs1WeightedInterval<double>(t0: t0, t1: t1, value: v));
  }
  return intervals;
}

/// Builds piecewise-constant time intervals from boolean samples (e.g., Flex active).
List<Prs1WeightedInterval<bool>> buildBoolIntervals({
  required List<dynamic> samples,
  required int Function(dynamic s) timeEpochSec,
  required bool Function(dynamic s) value,
  int? endEpochSec,
}) {
  if (samples.isEmpty) return const [];
  final sorted = List<dynamic>.from(samples)
    ..sort((a, b) => timeEpochSec(a).compareTo(timeEpochSec(b)));

  final intervals = <Prs1WeightedInterval<bool>>[];
  for (int i = 0; i < sorted.length; i++) {
    final s = sorted[i];
    final t0 = timeEpochSec(s);
    final t1 = (i + 1 < sorted.length) ? timeEpochSec(sorted[i + 1]) : (endEpochSec ?? t0);
    if (t1 <= t0) continue;
    intervals.add(Prs1WeightedInterval<bool>(t0: t0, t1: t1, value: value(s)));
  }
  return intervals;
}

class Prs1TimeWeightedStats {
  /// Weighted quantile (0..1) of a numeric series using time (seconds) as weights.
  ///
  /// This is NOT a simple average across sample points; it is time-weighted across
  /// the piecewise-constant intervals.
  ///
  /// If [endEpochSec] is provided, the last sample contributes duration until that time.
  /// If not provided, the last sample contributes 0 seconds (by design).
  static double? weightedQuantile({
    required List<dynamic> samples,
    required double q,
    required int Function(dynamic s) timeEpochSec,
    required double Function(dynamic s) value,
    int? endEpochSec,
  }) {
    if (samples.isEmpty) return null;
    final qq = q.clamp(0.0, 1.0);
    final intervals = buildNumericIntervals(
      samples: samples,
      timeEpochSec: timeEpochSec,
      value: value,
      endEpochSec: endEpochSec,
    );
    if (intervals.isEmpty) return null;

    final totalW = intervals.fold<int>(0, (acc, it) => acc + it.seconds);
    if (totalW <= 0) return null;

    // Sort intervals by value for quantile computation.
    final sorted = List<Prs1WeightedInterval<double>>.from(intervals)
      ..sort((a, b) => a.value.compareTo(b.value));

    // OSCAR-style nearest-rank target (1..totalW seconds).
    // This tends to better match OSCAR's percentile reporting for piecewise-constant signals.
    final target = math.max(1, (totalW * qq).ceil());
    int cum = 0;
    for (final it in sorted) {
      final w = it.seconds;
      if (w <= 0) continue;
      cum += w;
      if (cum >= target) return it.value;
    }
    return sorted.last.value;
  }

  static double? weightedMedian({
    required List<dynamic> samples,
    required int Function(dynamic s) timeEpochSec,
    required double Function(dynamic s) value,
    int? endEpochSec,
  }) {
    return weightedQuantile(
      samples: samples,
      q: 0.5,
      timeEpochSec: timeEpochSec,
      value: value,
      endEpochSec: endEpochSec,
    );
  }

  static double? weightedP95({
    required List<dynamic> samples,
    required int Function(dynamic s) timeEpochSec,
    required double Function(dynamic s) value,
    int? endEpochSec,
  }) {
    return weightedQuantile(
      samples: samples,
      q: 0.95,
      timeEpochSec: timeEpochSec,
      value: value,
      endEpochSec: endEpochSec,
    );
  }

  /// Returns total seconds represented by the intervals (i.e., denominator for fractions).
  static int totalSecondsNumeric({
    required List<dynamic> samples,
    required int Function(dynamic s) timeEpochSec,
    required double Function(dynamic s) value,
    int? endEpochSec,
  }) {
    final intervals = buildNumericIntervals(
      samples: samples,
      timeEpochSec: timeEpochSec,
      value: value,
      endEpochSec: endEpochSec,
    );
    return intervals.fold<int>(0, (acc, it) => acc + it.seconds);
  }

  /// Fraction of time where value > threshold.
  static double? fractionOver({
    required List<dynamic> samples,
    required double threshold,
    required int Function(dynamic s) timeEpochSec,
    required double Function(dynamic s) value,
    int? endEpochSec,
  }) {
    final intervals = buildNumericIntervals(
      samples: samples,
      timeEpochSec: timeEpochSec,
      value: value,
      endEpochSec: endEpochSec,
    );
    if (intervals.isEmpty) return null;

    final total = intervals.fold<int>(0, (acc, it) => acc + it.seconds);
    if (total <= 0) return null;

    final over = intervals
        .where((it) => it.value > threshold)
        .fold<int>(0, (acc, it) => acc + it.seconds);

    return over / total;
  }

  /// Fraction of time where value >= min && value <= max.
  static double? fractionInRange({
    required List<dynamic> samples,
    required double min,
    required double max,
    required int Function(dynamic s) timeEpochSec,
    required double Function(dynamic s) value,
    int? endEpochSec,
  }) {
    final intervals = buildNumericIntervals(
      samples: samples,
      timeEpochSec: timeEpochSec,
      value: value,
      endEpochSec: endEpochSec,
    );
    if (intervals.isEmpty) return null;

    final total = intervals.fold<int>(0, (acc, it) => acc + it.seconds);
    if (total <= 0) return null;

    final inRange = intervals
        .where((it) => it.value >= min && it.value <= max)
        .fold<int>(0, (acc, it) => acc + it.seconds);

    return inRange / total;
  }

  static int timeAboveSeconds({
    required List<dynamic> samples,
    required double threshold,
    required int Function(dynamic s) timeEpochSec,
    required double Function(dynamic s) value,
    int? endEpochSec,
  }) {
    final intervals = buildNumericIntervals(
      samples: samples,
      timeEpochSec: timeEpochSec,
      value: value,
      endEpochSec: endEpochSec,
    );
    return intervals
        .where((it) => it.value > threshold)
        .fold<int>(0, (acc, it) => acc + it.seconds);
  }

  static int timeBelowSeconds({
    required List<dynamic> samples,
    required double threshold,
    required int Function(dynamic s) timeEpochSec,
    required double Function(dynamic s) value,
    int? endEpochSec,
  }) {
    final intervals = buildNumericIntervals(
      samples: samples,
      timeEpochSec: timeEpochSec,
      value: value,
      endEpochSec: endEpochSec,
    );
    return intervals
        .where((it) => it.value < threshold)
        .fold<int>(0, (acc, it) => acc + it.seconds);
  }

  static int timeInRangeSeconds({
    required List<dynamic> samples,
    required double min,
    required double max,
    required int Function(dynamic s) timeEpochSec,
    required double Function(dynamic s) value,
    int? endEpochSec,
  }) {
    final intervals = buildNumericIntervals(
      samples: samples,
      timeEpochSec: timeEpochSec,
      value: value,
      endEpochSec: endEpochSec,
    );
    return intervals
        .where((it) => it.value >= min && it.value <= max)
        .fold<int>(0, (acc, it) => acc + it.seconds);
  }

  /// Duty cycle (fraction of time true) for boolean samples (e.g., Flex active).
  static double? dutyCycle({
    required List<dynamic> samples,
    required int Function(dynamic s) timeEpochSec,
    required bool Function(dynamic s) value,
    int? endEpochSec,
  }) {
    final intervals = buildBoolIntervals(
      samples: samples,
      timeEpochSec: timeEpochSec,
      value: value,
      endEpochSec: endEpochSec,
    );
    if (intervals.isEmpty) return null;

    final total = intervals.fold<int>(0, (acc, it) => acc + it.seconds);
    if (total <= 0) return null;

    final on = intervals.where((it) => it.value).fold<int>(0, (acc, it) => acc + it.seconds);
    return on / total;
  }
}
