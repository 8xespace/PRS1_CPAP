// lib/features/prs1/aggregate/weighted_stats.dart
//
// Time-weighted statistics helpers (median/percentiles) used by the daily aggregation engine.
//
// We keep this file standalone and dependency-free so it can be reused later for weekly/monthly rollups.

class WeightedPoint {
  const WeightedPoint(this.value, this.weightSeconds);

  final double value;

  /// Weight in seconds (must be >= 0).
  final int weightSeconds;
}

class WeightedStats {
  /// Compute a weighted quantile (0..1) using cumulative weights.
  ///
  /// - Points with non-positive weight are ignored.
  /// - Returns null when no valid points exist.
  static double? quantile(List<WeightedPoint> points, double q) {
    if (points.isEmpty) return null;
    if (q.isNaN) return null;
    final qq = q.clamp(0.0, 1.0);

    final filtered = <WeightedPoint>[];
    var total = 0;
    for (final p in points) {
      final w = p.weightSeconds;
      if (w <= 0) continue;
      filtered.add(p);
      total += w;
    }
    if (filtered.isEmpty || total <= 0) return null;

    filtered.sort((a, b) => a.value.compareTo(b.value));

    final target = total * qq;
    var cum = 0.0;
    for (final p in filtered) {
      cum += p.weightSeconds;
      if (cum >= target) return p.value;
    }
    return filtered.last.value;
  }

  static double? median(List<WeightedPoint> points) => quantile(points, 0.5);

  static double? p95(List<WeightedPoint> points) => quantile(points, 0.95);

  /// Weighted mean.
  static double? mean(List<WeightedPoint> points) {
    if (points.isEmpty) return null;
    var totalW = 0;
    var sum = 0.0;
    for (final p in points) {
      final w = p.weightSeconds;
      if (w <= 0) continue;
      totalW += w;
      sum += p.value * w;
    }
    if (totalW <= 0) return null;
    return sum / totalW;
  }

  /// Percentage (0..100) of time where value > threshold.
  static double? percentOver(List<WeightedPoint> points, double threshold) {
    if (points.isEmpty) return null;
    var totalW = 0;
    var overW = 0;
    for (final p in points) {
      final w = p.weightSeconds;
      if (w <= 0) continue;
      totalW += w;
      if (p.value > threshold) overW += w;
    }
    if (totalW <= 0) return null;
    return (overW / totalW) * 100.0;
  }
}
