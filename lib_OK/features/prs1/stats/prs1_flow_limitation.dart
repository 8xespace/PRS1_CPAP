// lib/features/prs1/stats/prs1_flow_limitation.dart
//
// Continuous flow limitation indicator estimated from the Flow waveform.
//
// Maintainable baseline:
// - Reuse breath segmentation windows (start -> inspEnd).
// - For each inspiration, compute a "flattening" score in [0, 1].
//
// Shape factor:
// - Let r = meanPositive / peakPositive over inspiration.
// - A more "flat-topped" inspiratory waveform yields larger r.
// - Map r to [0,1] with conservative bounds.

import 'dart:math' as math;

import '../model/prs1_breath.dart';
import '../model/prs1_waveform_channel.dart';
import '../stats/prs1_rolling_metrics.dart' show Prs1TimePoint;

class Prs1FlowLimitation {
  /// Compute a continuous flow limitation time series at breath resolution.
  ///
  /// Returns points at breath start time (tEpochSec) with value in [0,1].
  static List<Prs1TimePoint> seriesFromBreaths(
    Prs1WaveformChannel flow,
    List<Prs1Breath> breaths, {
    double zeroEps = 0.01,
  }) {
    if (flow.length < 3 || breaths.isEmpty) return const [];
    final out = <Prs1TimePoint>[];

    for (final b in breaths) {
      final score = _scoreBreath(flow, b, zeroEps: zeroEps);
      if (score == null) continue;
      out.add(Prs1TimePoint(tEpochSec: (b.startEpochMs ~/ 1000), value: score));
    }
    return out;
  }

  /// Public scorer for a single breath (used by aggregators).
  static double? scoreBreath(
    Prs1WaveformChannel flow,
    Prs1Breath b, {
    double zeroEps = 0.01,
  }) {
    return _scoreBreath(flow, b, zeroEps: zeroEps);
  }

  /// Convert a breath-resolution FL series into a **minute-bucketed** series.
  ///
  /// - Buckets are aligned to minute boundaries.
  /// - Each minute's value is the (unweighted) median of breath scores in that minute.
  /// - Missing minutes are emitted as NaN to preserve gaps for plotting.
  static List<Prs1TimePoint> minuteMedianSeries({
    required List<Prs1TimePoint> breathSeries,
    required int dayStartEpochSec,
    required int minutes,
  }) {
    // Pre-fill with NaNs so callers always get a fixed-length series.
    final out = List<Prs1TimePoint>.generate(
      minutes,
      (i) => Prs1TimePoint(
        tEpochSec: dayStartEpochSec + i * 60,
        value: double.nan,
      ),
      growable: false,
    );
    if (breathSeries.isEmpty) return out;

    // Collect values per minute.
    final buckets = <int, List<double>>{};
    for (final p in breathSeries) {
      final t = p.tEpochSec;
      if (t < dayStartEpochSec || t >= dayStartEpochSec + minutes * 60) continue;
      final v = p.value;
      if (v == null || v.isNaN) continue;
      final m = ((t - dayStartEpochSec) ~/ 60);
      buckets.putIfAbsent(m, () => <double>[]).add(v);
    }

    double median(List<double> xs) {
      xs.sort();
      final n = xs.length;
      if (n == 0) return double.nan;
      if (n.isOdd) return xs[n ~/ 2];
      return (xs[n ~/ 2 - 1] + xs[n ~/ 2]) / 2.0;
    }

    for (int i = 0; i < minutes; i++) {
      final xs = buckets[i];
      if (xs == null || xs.isEmpty) continue;
      out[i] = Prs1TimePoint(
        tEpochSec: dayStartEpochSec + i * 60,
        value: median(xs),
      );
    }
    return out;
  }

  /// Exponential moving average over a minute-bucketed series.
  ///
  /// - `windowMinutes`: smoothing horizon (e.g. 5 or 15).
  /// - NaN (or null) inputs produce NaN outputs and do **not** update the EMA state.
  static List<Prs1TimePoint> emaSeries({
    required List<Prs1TimePoint> minuteSeries,
    int windowMinutes = 5,
  }) {
    if (minuteSeries.isEmpty) return const [];
    final alpha = 2.0 / (windowMinutes + 1.0);

    double? ema;
    final out = <Prs1TimePoint>[];

    for (final p in minuteSeries) {
      final x = p.value;
      if (x == null || x.isNaN) {
        out.add(Prs1TimePoint(tEpochSec: p.tEpochSec, value: double.nan));
        continue;
      }
      ema = (ema == null) ? x : (alpha * x + (1.0 - alpha) * ema!);
      out.add(Prs1TimePoint(tEpochSec: p.tEpochSec, value: ema));
    }
    return out;
  }

  /// Convert a minute-resolution FL curve into severity bands:
  /// - 0: [0.0, 0.1)
  /// - 1: [0.1, 0.3)
  /// - 2: [0.3, +inf)
  /// Missing minutes are encoded as -1.
  static List<int> bandedSeverity({
    required List<Prs1TimePoint> minuteSeries,
  }) {
    final out = List<int>.filled(minuteSeries.length, -1, growable: false);
    for (int i = 0; i < minuteSeries.length; i++) {
      final v = minuteSeries[i].value;
      if (v == null || v.isNaN) {
        out[i] = -1;
      } else if (v < 0.1) {
        out[i] = 0;
      } else if (v < 0.3) {
        out[i] = 1;
      } else {
        out[i] = 2;
      }
    }
    return out;
  }

  static double? _scoreBreath(
    Prs1WaveformChannel flow,
    Prs1Breath b, {
    required double zeroEps,
  }) {
    final sr = flow.sampleRateHz;
    if (sr <= 0) return null;

    int idxAt(int epochMs) {
      final x = ((epochMs - flow.startEpochMs) * sr / 1000.0).round();
      return x.clamp(0, flow.length - 1);
    }

    final i0 = idxAt(b.startEpochMs);
    final i1 = idxAt(b.inspEndEpochMs);
    if (i1 <= i0 + 2) return null;

    double peak = 0.0;
    double sum = 0.0;
    int n = 0;

    // Cheap 3-sample smoothing inline.
    double sm(int i) {
      final a = flow.samples[math.max(0, i - 1)];
      final c = flow.samples[math.min(flow.length - 1, i + 1)];
      final v = (a + flow.samples[i] + c) / 3.0;
      return v;
    }

    for (int i = i0; i <= i1; i++) {
      final v = sm(i);
      if (v <= zeroEps) continue;
      peak = math.max(peak, v);
      sum += v;
      n++;
    }

    if (n < 5 || peak <= 0) return null;

    final mean = sum / n;
    final r = (mean / peak).clamp(0.0, 1.0);

    // Conservative mapping:
    // - typical "triangular-ish" inspiration: r ~ 0.45..0.60
    // - flat-topped / limited: r increases toward 0.75..0.90
    const lo = 0.55;
    const hi = 0.85;

    final score = ((r - lo) / (hi - lo)).clamp(0.0, 1.0);
    return score.isNaN ? null : score;
  }
}
