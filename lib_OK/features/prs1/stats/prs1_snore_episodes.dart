// lib/features/prs1/stats/prs1_snore_episodes.dart
//
// Snore episode / cluster analysis.
//
// We group snore events into episodes if consecutive events are within [maxGapSec].
// Each episode summarizes:
// - start/end (epochMs)
// - count
// - durationSec
// - density (events per minute)
// - peakDensity60s (max snore count in any 60s window within the episode)
//
// This is designed to back an OSCAR-like "episodes" overlay in the future UI.

import '../model/prs1_event.dart';

class Prs1SnoreEpisode {
  const Prs1SnoreEpisode({
    required this.startEpochMs,
    required this.endEpochMsExclusive,
    required this.count,
    required this.durationSec,
    required this.densityPerMin,
    required this.peakDensityPerMin60s,
  });

  final int startEpochMs;
  final int endEpochMsExclusive;
  final int count;
  final int durationSec;
  final double densityPerMin;
  final double peakDensityPerMin60s;

  bool overlaps(int startMs, int endMsExclusive) {
    return startEpochMs < endMsExclusive && endEpochMsExclusive > startMs;
  }
}

class Prs1SnoreEpisodes {
  static List<Prs1SnoreEpisode> build(
    List<Prs1Event> events, {
    int maxGapSec = 10,
  }) {
    final snoreTimes = events
        .where((e) => e.type == Prs1EventType.snore)
        .map((e) => e.time.toUtc().millisecondsSinceEpoch)
        .toList(growable: false);

    if (snoreTimes.isEmpty) return const [];
    snoreTimes.sort();

    final episodes = <Prs1SnoreEpisode>[];

    int epStart = snoreTimes.first;
    int last = snoreTimes.first;
    int count = 1;
    final gapMs = maxGapSec * 1000;

    void closeEpisode(int epStartMs, int epEndMsExclusive, int cnt) {
      final durSec = ((epEndMsExclusive - epStartMs) / 1000).round().clamp(1, 1 << 30);
      final dens = cnt / (durSec / 60.0);

      final peakCnt60 = _peakCountInWindow(snoreTimes, epStartMs, epEndMsExclusive, windowMs: 60000);
      final peakDens60 = peakCnt60 / 1.0; // per minute in 60s window

      episodes.add(
        Prs1SnoreEpisode(
          startEpochMs: epStartMs,
          endEpochMsExclusive: epEndMsExclusive,
          count: cnt,
          durationSec: durSec,
          densityPerMin: dens,
          peakDensityPerMin60s: peakDens60,
        ),
      );
    }

    for (int i = 1; i < snoreTimes.length; i++) {
      final t = snoreTimes[i];
      if (t - last <= gapMs) {
        last = t;
        count++;
        continue;
      }
      // close previous
      closeEpisode(epStart, last + 1000, count);
      // new
      epStart = t;
      last = t;
      count = 1;
    }
    closeEpisode(epStart, last + 1000, count);

    return episodes;
  }

  static int _peakCountInWindow(
    List<int> sortedTimes,
    int startMs,
    int endMsExclusive, {
    required int windowMs,
  }) {
    // Two-pointer sliding window over the global sorted list, but constrained to episode range.
    // Collect indices within episode first for simplicity.
    final times = sortedTimes.where((t) => t >= startMs && t < endMsExclusive).toList(growable: false);
    if (times.isEmpty) return 0;

    int best = 1;
    int j = 0;
    for (int i = 0; i < times.length; i++) {
      final t0 = times[i];
      while (j < times.length && times[j] < t0 + windowMs) {
        j++;
      }
      best = best < (j - i) ? (j - i) : best;
    }
    return best;
  }
}
