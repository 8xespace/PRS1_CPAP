// lib/features/prs1/stats/prs1_episode_correlation.dart
//
// Advanced episode-level analytics:
// correlate Snore episodes with Leak-over-threshold episodes and
// High Flow-Limitation episodes.

import 'prs1_snore_episodes.dart';
import 'prs1_value_episodes.dart';

class Prs1EpisodeLink {
  const Prs1EpisodeLink({
    required this.snoreEpisodeIndex,
    required this.snoreStartEpochMs,
    required this.snoreEndEpochMsExclusive,
    required this.overlapLeakSeconds,
    required this.overlapHighFlowLimSeconds,
  });

  final int snoreEpisodeIndex;
  final int snoreStartEpochMs;
  final int snoreEndEpochMsExclusive;

  final int overlapLeakSeconds;
  final int overlapHighFlowLimSeconds;

  int get snoreDurationSeconds {
    final d = (snoreEndEpochMsExclusive - snoreStartEpochMs) ~/ 1000;
    return d < 0 ? 0 : d;
  }

  bool get hasLeakOverlap => overlapLeakSeconds > 0;
  bool get hasHighFlowLimOverlap => overlapHighFlowLimSeconds > 0;
  bool get hasBoth => hasLeakOverlap && hasHighFlowLimOverlap;
}

class Prs1EpisodeCorrelationSummary {
  const Prs1EpisodeCorrelationSummary({
    required this.snoreEpisodeCount,
    required this.snoreEpisodesWithLeakOverlap,
    required this.snoreEpisodesWithHighFlowLimOverlap,
    required this.snoreEpisodesWithBothOverlap,
    required this.totalLeakOverlapSeconds,
    required this.totalHighFlowLimOverlapSeconds,
  });

  final int snoreEpisodeCount;
  final int snoreEpisodesWithLeakOverlap;
  final int snoreEpisodesWithHighFlowLimOverlap;
  final int snoreEpisodesWithBothOverlap;
  final int totalLeakOverlapSeconds;
  final int totalHighFlowLimOverlapSeconds;
}

class Prs1EpisodeCorrelation {
  static List<Prs1EpisodeLink> link({
    required List<Prs1SnoreEpisode> snoreEpisodes,
    required List<Prs1ValueEpisode> leakEpisodes,
    required List<Prs1ValueEpisode> highFlowLimEpisodes,
  }) {
    if (snoreEpisodes.isEmpty) return const [];

    final out = <Prs1EpisodeLink>[];

    int overlapSecondsMs(int sMs, int eMs, int isSec, int ieSec) {
      final a0 = sMs;
      final a1 = eMs;
      final b0 = isSec * 1000;
      final b1 = ieSec * 1000;
      final lo = (a0 > b0) ? a0 : b0;
      final hi = (a1 < b1) ? a1 : b1;
      final d = hi - lo;
      return d <= 0 ? 0 : (d ~/ 1000);
    }

    for (int i = 0; i < snoreEpisodes.length; i++) {
      final ep = snoreEpisodes[i];
      final sMs = ep.startEpochMs;
      final eMs = ep.endEpochMsExclusive;

      int leakOv = 0;
      for (final le in leakEpisodes) {
        if (!le.overlapsMs(sMs, eMs)) continue;
        leakOv += overlapSecondsMs(sMs, eMs, le.startEpochSec, le.endEpochSecExclusive);
      }

      int flOv = 0;
      for (final fe in highFlowLimEpisodes) {
        if (!fe.overlapsMs(sMs, eMs)) continue;
        flOv += overlapSecondsMs(sMs, eMs, fe.startEpochSec, fe.endEpochSecExclusive);
      }

      out.add(
        Prs1EpisodeLink(
          snoreEpisodeIndex: i,
          snoreStartEpochMs: sMs,
          snoreEndEpochMsExclusive: eMs,
          overlapLeakSeconds: leakOv,
          overlapHighFlowLimSeconds: flOv,
        ),
      );
    }

    return List.unmodifiable(out);
  }

  static Prs1EpisodeCorrelationSummary summarize(List<Prs1EpisodeLink> links) {
    final n = links.length;
    int withLeak = 0;
    int withFl = 0;
    int withBoth = 0;
    int leakSec = 0;
    int flSec = 0;

    for (final l in links) {
      if (l.hasLeakOverlap) withLeak++;
      if (l.hasHighFlowLimOverlap) withFl++;
      if (l.hasBoth) withBoth++;
      leakSec += l.overlapLeakSeconds;
      flSec += l.overlapHighFlowLimSeconds;
    }

    return Prs1EpisodeCorrelationSummary(
      snoreEpisodeCount: n,
      snoreEpisodesWithLeakOverlap: withLeak,
      snoreEpisodesWithHighFlowLimOverlap: withFl,
      snoreEpisodesWithBothOverlap: withBoth,
      totalLeakOverlapSeconds: leakSec,
      totalHighFlowLimOverlapSeconds: flSec,
    );
  }
}
