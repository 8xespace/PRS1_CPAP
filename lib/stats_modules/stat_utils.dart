// lib/stats_modules/stat_utils.dart
// Small helpers used across modules.

double? statMin(List<double> v) => v.isEmpty ? null : v.first;
double? statMax(List<double> v) => v.isEmpty ? null : v.last;

/// v must be sorted ascending.
double? statQuantileSorted(List<double> v, double q) {
  if (v.isEmpty) return null;
  if (q <= 0) return v.first;
  if (q >= 1) return v.last;
  final idx = (v.length * q).floor();
  final i = idx.clamp(0, v.length - 1);
  return v[i];
}
