// lib/features/prs1/stats/prs1_weighted_value_stats.dart
//
// Generic weighted statistics for scalar values.
// Useful for breath-by-breath metrics where weights are durations (seconds).

import 'dart:math' as math;

class Prs1WeightedValueStats {
  static double? weightedQuantile(List<double> values, List<double> weights, double q) {
    if (values.isEmpty || weights.isEmpty || values.length != weights.length) return null;
    if (q.isNaN) return null;

    final qq = q.clamp(0.0, 1.0);

    final pairs = <_Pair>[];
    for (int i = 0; i < values.length; i++) {
      final w = weights[i];
      if (w <= 0) continue;
      final v = values[i];
      if (v.isNaN || v.isInfinite) continue;
      pairs.add(_Pair(v, w));
    }
    if (pairs.isEmpty) return null;

    pairs.sort((a, b) => a.v.compareTo(b.v));
    final totalW = pairs.fold<double>(0.0, (a, p) => a + p.w);
    if (totalW <= 0) return null;

    if (qq <= 0.0) return pairs.first.v;
    if (qq >= 1.0) return pairs.last.v;

    final target = totalW * qq;

    double cum = 0.0;
    double prevCum = 0.0;
    double? prevV;

    for (final p in pairs) {
      prevCum = cum;
      cum += p.w;
      if (cum >= target) {
        if (prevV == null) return p.v; // first bucket
        final span = cum - prevCum; // == p.w
        if (span <= 0) return p.v;
        final t = ((target - prevCum) / span).clamp(0.0, 1.0);
        // Linear interpolation between previous value and current value.
        return prevV + (p.v - prevV) * t;
      }
      prevV = p.v;
    }
    return pairs.last.v;
  }


  static double? weightedMedian(List<double> values, List<double> weights) => weightedQuantile(values, weights, 0.5);

  static double? min(List<double> values) => _min(values);
  static double? max(List<double> values) => _max(values);

  static double? _min(List<double> values) {
    double? m;
    for (final v in values) {
      if (v.isNaN || v.isInfinite) continue;
      m = (m == null) ? v : math.min(m, v);
    }
    return m;
  }

  static double? _max(List<double> values) {
    double? m;
    for (final v in values) {
      if (v.isNaN || v.isInfinite) continue;
      m = (m == null) ? v : math.max(m, v);
    }
    return m;
  }
}

class _Pair {
  _Pair(this.v, this.w);
  final double v;
  final double w;
}
