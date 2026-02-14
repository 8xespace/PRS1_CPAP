// lib/features/prs1/model/prs1_breath.dart
//
// Breath-by-breath derived metrics (Milestone E).

class Prs1Breath {
  const Prs1Breath({
    required this.startEpochMs,
    required this.inspEndEpochMs,
    required this.endEpochMs,
    required this.tidalVolumeLiters,
    required this.respRateBpm,
    required this.minuteVentilationLpm,
    required this.inspTimeSec,
    required this.expTimeSec,
    required this.ieRatio,
  });

  final int startEpochMs;
  final int inspEndEpochMs;
  final int endEpochMs;

  final double tidalVolumeLiters;       // TV (L)
  final double respRateBpm;             // RR (breaths/min)
  final double minuteVentilationLpm;    // MV (L/min)
  final double inspTimeSec;
  final double expTimeSec;
  final double ieRatio;

  int get durationMs => (endEpochMs - startEpochMs);
  double get durationSec => durationMs / 1000.0;
}
