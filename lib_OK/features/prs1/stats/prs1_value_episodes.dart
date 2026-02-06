// lib/features/prs1/stats/prs1_value_episodes.dart
//
// Episode/segment extraction for continuous numeric signals.
//
// Used for:
// - Leak "over-threshold" segments (beyond %time)
// - High flow-limitation segments derived from minute bands

import 'prs1_time_weighted_stats.dart';

class Prs1ValueEpisode {
  const Prs1ValueEpisode({
    required this.startEpochSec,
    required this.endEpochSecExclusive,
    required this.maxValue,
    required this.meanValue,
  });

  final int startEpochSec;
  final int endEpochSecExclusive;
  final double maxValue;
  final double meanValue;

  int get durationSec {
    final d = endEpochSecExclusive - startEpochSec;
    return d < 0 ? 0 : d;
  }

  bool overlapsMs(int startEpochMs, int endEpochMsExclusive) {
    final s = startEpochSec * 1000;
    final e = endEpochSecExclusive * 1000;
    return s < endEpochMsExclusive && e > startEpochMs;
  }
}

class Prs1ValueEpisodes {
  /// Build episodes from weighted intervals where value > threshold.
  ///
  /// Episodes are merged across short gaps (<= [gapToleranceSec]).
  static List<Prs1ValueEpisode> fromIntervalsOverThreshold(
    List<Prs1WeightedInterval<double>> intervals, {
    required double threshold,
    int minDurationSec = 30,
    int gapToleranceSec = 5,
  }) {
    if (intervals.isEmpty) return const [];

    final sorted = List<Prs1WeightedInterval<double>>.from(intervals)
      ..sort((a, b) => a.t0.compareTo(b.t0));

    int? curStart;
    int? curEnd;
    double maxV = double.negativeInfinity;
    double sumVxT = 0;
    int sumT = 0;

    final out = <Prs1ValueEpisode>[];

    void flush() {
      if (curStart == null || curEnd == null) return;
      final dur = curEnd! - curStart!;
      if (dur >= minDurationSec && sumT > 0) {
        out.add(
          Prs1ValueEpisode(
            startEpochSec: curStart!,
            endEpochSecExclusive: curEnd!,
            maxValue: maxV.isFinite ? maxV : threshold,
            meanValue: sumVxT / sumT,
          ),
        );
      }
      curStart = null;
      curEnd = null;
      maxV = double.negativeInfinity;
      sumVxT = 0;
      sumT = 0;
    }

    for (final it in sorted) {
      if (!(it.value > threshold)) {
        // non-over segment breaks the run
        flush();
        continue;
      }

      if (curStart == null) {
        curStart = it.t0;
        curEnd = it.t1;
      } else {
        // merge if gap small
        if (it.t0 <= curEnd! + gapToleranceSec) {
          if (it.t1 > curEnd!) curEnd = it.t1;
        } else {
          flush();
          curStart = it.t0;
          curEnd = it.t1;
        }
      }

      if (it.value > maxV) maxV = it.value;
      final seconds = it.seconds;
      if (seconds > 0) {
        sumVxT += it.value * seconds;
        sumT += seconds;
      }
    }

    flush();
    return List.unmodifiable(out);
  }

  /// Build episodes from minute-resolution bands.
  ///
  /// [bands] must be a 1-minute series for a full day (typically length 1440).
  /// [bandPredicate] returns true if that minute is "inside" an episode.
  static List<Prs1ValueEpisode> fromMinuteBands(
    List<int> bands, {
    required int dayStartEpochSec,
    required bool Function(int band) bandPredicate,
    int minDurationSec = 60,
    int gapToleranceMinutes = 0,
  }) {
    if (bands.isEmpty) return const [];

    final out = <Prs1ValueEpisode>[];

    int? curStartMin;
    int? curEndMin;

    void flush() {
      if (curStartMin == null || curEndMin == null) return;
      final startSec = dayStartEpochSec + curStartMin! * 60;
      final endSec = dayStartEpochSec + curEndMin! * 60;
      final dur = endSec - startSec;
      if (dur >= minDurationSec) {
        out.add(
          Prs1ValueEpisode(
            startEpochSec: startSec,
            endEpochSecExclusive: endSec,
            maxValue: 1.0,
            meanValue: 1.0,
          ),
        );
      }
      curStartMin = null;
      curEndMin = null;
    }

    for (int i = 0; i < bands.length; i++) {
      final inside = bandPredicate(bands[i]);
      if (!inside) {
        flush();
        continue;
      }

      if (curStartMin == null) {
        curStartMin = i;
        curEndMin = i + 1;
      } else {
        final gapMin = i - curEndMin!;
        if (gapMin <= gapToleranceMinutes) {
          curEndMin = i + 1;
        } else {
          flush();
          curStartMin = i;
          curEndMin = i + 1;
        }
      }
    }

    flush();
    return List.unmodifiable(out);
  }
}
