// lib/features/prs1/decode/session_stats.dart
//
// Best-effort session-level statistics derived from decoded PRS1 events.
// This layer is intentionally conservative: it never assumes OSCAR-perfect
// semantics; it only uses what we already decode today.

import '../model/prs1_event.dart';

class Prs1SessionStats {
  const Prs1SessionStats({
    required this.minutesUsed,
    required this.ahi,
    required this.pressureMin,
    required this.pressureMax,
    required this.leakMedian,
    required this.apneaCount,
    required this.hypopneaCount,
    required this.largeLeakCount,
  });

  final int minutesUsed;

  /// Apnea-Hypopnea Index (events per hour), best-effort.
  final double ahi;

  final double? pressureMin;
  final double? pressureMax;

  /// Median leak value (if leak samples exist); best-effort.
  final double? leakMedian;

  final int apneaCount;
  final int hypopneaCount;
  final int largeLeakCount;

  static Prs1SessionStats fromEvents({
    required List<Prs1Event> events,
    required int minutesUsed,
  }) {
    int apnea = 0;
    int hypopnea = 0;
    int largeLeak = 0;

    final pressureSamples = <double>[];
    final leakSamples = <double>[];

    for (final e in events) {
      switch (e.type) {
        case Prs1EventType.obstructiveApnea:
        case Prs1EventType.clearAirwayApnea:
          apnea += 1;
          break;
        case Prs1EventType.hypopnea:
          hypopnea += 1;
          break;
        case Prs1EventType.largeLeak:
          largeLeak += 1;
          break;
        case Prs1EventType.pressureSample:
          if (e.value is num) pressureSamples.add((e.value as num).toDouble());
          break;
        case Prs1EventType.leakSample:
          if (e.value is num) leakSamples.add((e.value as num).toDouble());
          break;
        default:
          break;
      }
    }

    double? pMin;
    double? pMax;
    if (pressureSamples.isNotEmpty) {
      pressureSamples.sort();
      pMin = pressureSamples.first;
      pMax = pressureSamples.last;
    }

    double? leakMedian;
    if (leakSamples.isNotEmpty) {
      leakSamples.sort();
      final mid = leakSamples.length ~/ 2;
      leakMedian = leakSamples.length.isOdd
          ? leakSamples[mid]
          : (leakSamples[mid - 1] + leakSamples[mid]) / 2.0;
    }

    final hours = minutesUsed <= 0 ? 0.0 : minutesUsed / 60.0;
    final ahi = hours <= 0 ? 0.0 : (apnea + hypopnea) / hours;

    return Prs1SessionStats(
      minutesUsed: minutesUsed,
      ahi: ahi,
      pressureMin: pMin,
      pressureMax: pMax,
      leakMedian: leakMedian,
      apneaCount: apnea,
      hypopneaCount: hypopnea,
      largeLeakCount: largeLeak,
    );
  }
}
