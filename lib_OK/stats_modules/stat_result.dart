// lib/stats_modules/stat_result.dart
// Shared result model for modular CPAP stats.

class StatResult {
  final double? min;
  final double? median;
  final double? p95;
  final double? max;

  const StatResult({this.min, this.median, this.p95, this.max});

  bool get isEmpty => min == null && median == null && p95 == null && max == null;
}
