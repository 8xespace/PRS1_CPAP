// lib/features/prs1/stats/prs1_oscar_reference.dart
//
// Lightweight OSCAR reference table used for verification during development.
// In production, this can be replaced by parsing OSCAR exports or user-provided baselines.

class Prs1OscarReferenceStats {
  const Prs1OscarReferenceStats({
    required this.min,
    required this.median,
    required this.p95,
    required this.max,
  });

  final double min;
  final double median;
  final double p95;
  final double max;
}

class Prs1OscarReference {
  // Key: YYYY-MM-DD (local day)
  static const Map<String, Prs1OscarReferenceStats> _pressure = {
    // From OSCAR screenshot (2026/01/31): Pressure (cmH2O) min/median/95/max
    '2026-01-31': Prs1OscarReferenceStats(min: 9.50, median: 9.50, p95: 12.50, max: 13.30),
  };

  static Prs1OscarReferenceStats? pressureForDay(DateTime dayLocalMidnight) {
    final y = dayLocalMidnight.year.toString().padLeft(4, '0');
    final m = dayLocalMidnight.month.toString().padLeft(2, '0');
    final d = dayLocalMidnight.day.toString().padLeft(2, '0');
    return _pressure['$y-$m-$d'];
  }
}
