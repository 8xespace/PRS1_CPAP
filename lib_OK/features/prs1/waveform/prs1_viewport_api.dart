// lib/features/prs1/waveform/prs1_viewport_api.dart
//
// Milestone G/H/I: unified viewport query for (waveform envelopes + aligned events)
// plus OSCAR-like overlay series (flow limitation curves, snore episodes, heatmaps).
//
// This file defines the *engine-side contract* the UI layer can call.

import '../model/prs1_event.dart';
import '../aggregate/prs1_daily_models.dart';
import '../stats/prs1_snore_episodes.dart';
import '../stats/prs1_value_episodes.dart';
import '../stats/prs1_episode_correlation.dart';
import '../stats/prs1_rolling_metrics.dart';
import 'prs1_waveform_index.dart';
import 'prs1_waveform_types.dart';
import 'prs1_waveform_viewport.dart';

class Prs1ViewportResult {
  const Prs1ViewportResult({
    required this.startEpochMs,
    required this.endEpochMsExclusive,
    required this.waveforms,
    required this.events,
    required this.flowLimitationBreathSeries,
    required this.flowLimitation5mEmaSeries,
    required this.flowLimitation15mEmaSeries,
    required this.flowLimitationSeverityBands5mEma,
    required this.flowLimitationSeverityBands15mEma,
    required this.snoreEpisodes,
    required this.snoreHeatmap1mCounts,
    required this.snoreHeatmap1mMaxCount,
    required this.leakEpisodes,
    required this.episodeLinks,
  });

  final int startEpochMs;
  final int endEpochMsExclusive;

  /// Downsampled min/max envelopes by signal.
  final Map<Prs1WaveformSignal, List<Prs1MinMaxPoint>> waveforms;

  /// Events aligned to absolute time for overlay.
  final List<Prs1Event> events;

  /// Breath-resolution flow limitation score points within viewport.
  final List<Prs1TimePoint> flowLimitationBreathSeries;

  /// Smoothed minute-resolution FL curves within viewport.
  final List<Prs1TimePoint> flowLimitation5mEmaSeries;
  final List<Prs1TimePoint> flowLimitation15mEmaSeries;

  /// Severity bands aligned to the above minute series (same indices/time).
  final List<int> flowLimitationSeverityBands5mEma;
  final List<int> flowLimitationSeverityBands15mEma;

  /// Snore episodes overlapping viewport.
  final List<Prs1SnoreEpisode> snoreEpisodes;

  /// Snore heatmap (minute-resolution counts) within viewport.
  final List<Prs1TimePoint> snoreHeatmap1mCounts;
  final int snoreHeatmap1mMaxCount;

  /// Leak over-threshold episodes overlapping viewport.
  final List<Prs1ValueEpisode> leakEpisodes;

  /// Snore episode links (overlaps) overlapping viewport.
  final List<Prs1EpisodeLink> episodeLinks;
}

class Prs1ViewportApi {
  /// Build a viewport result from a daily bucket.
  ///
  /// You typically pass:
  /// - [waveformIndex] built from sessions
  /// - [bucket] representing the selected day
  /// - [startEpochMs]/[endEpochMsExclusive] from a UI timeline range
  /// - [maxBuckets] derived from viewport pixel width (e.g., 600..2000)
  static Prs1ViewportResult fromDailyBucket({
    required Prs1WaveformIndex waveformIndex,
    required Prs1DailyBucket bucket,
    required int startEpochMs,
    required int endEpochMsExclusive,
    required int maxBuckets,
    Set<Prs1WaveformSignal> signals = const {
      Prs1WaveformSignal.flow,
      Prs1WaveformSignal.pressure,
      Prs1WaveformSignal.leak,
      Prs1WaveformSignal.flexActive,
    },
  }) {
    final waveforms = <Prs1WaveformSignal, List<Prs1MinMaxPoint>>{};
    for (final s in signals) {
      waveforms[s] = Prs1WaveformViewport.queryEnvelope(
        index: waveformIndex,
        signal: s,
        startEpochMs: startEpochMs,
        endEpochMsExclusive: endEpochMsExclusive,
        maxBuckets: maxBuckets,
      );
    }

    // Event selection: include only those within the viewport.
    final events = bucket.events.where((e) {
      final t = e.time.toUtc().millisecondsSinceEpoch;
      return t >= startEpochMs && t < endEpochMsExclusive;
    }).toList(growable: false);

    // Convert viewport bounds to epoch seconds for time-series slicing.
    final startEpochSec = startEpochMs ~/ 1000;
    final endEpochSecExclusive = (endEpochMsExclusive + 999) ~/ 1000;

    // Breath-resolution FL series within viewport.
    final flBreath = bucket.flowLimitationSeries
        .where((p) => p.tEpochSec >= startEpochSec && p.tEpochSec < endEpochSecExclusive)
        .toList(growable: false);

    // Minute-resolution FL curves + band layers.
    final dayStartEpochSec = bucket.day.toUtc().millisecondsSinceEpoch ~/ 1000;
    const minutesPerDay = 24 * 60;

    int minuteIndex(int epochSec) {
      final d = epochSec - dayStartEpochSec;
      if (d <= 0) return 0;
      return d ~/ 60;
    }

    final i0 = minuteIndex(startEpochSec).clamp(0, minutesPerDay);
    // Use ceil for end boundary so the last partially covered minute is included.
    final i1 = ((endEpochSecExclusive - dayStartEpochSec + 59) ~/ 60).clamp(0, minutesPerDay);

    List<Prs1TimePoint> sliceMinuteSeries(List<Prs1TimePoint> series) {
      if (series.isEmpty) return const [];
      final s = i0;
      final e = i1;
      if (s >= e) return const [];
      return series.sublist(s, e);
    }

    List<int> sliceBands(List<int> bands) {
      if (bands.isEmpty) return const [];
      final s = i0;
      final e = i1;
      if (s >= e) return const [];
      return bands.sublist(s, e);
    }

    // Snore episodes overlapping viewport.
    final eps = bucket.snoreEpisodes.where((e) => e.overlaps(startEpochMs, endEpochMsExclusive)).toList(growable: false);

    // Snore heatmap slice -> convert to time points.
    final heatCounts = <Prs1TimePoint>[];
    if (bucket.snoreHeatmap1mCounts.isNotEmpty && i0 < i1) {
      for (int i = i0; i < i1; i++) {
        final t = dayStartEpochSec + i * 60;
        heatCounts.add(Prs1TimePoint(tEpochSec: t, value: bucket.snoreHeatmap1mCounts[i].toDouble()));
      }
    }


    // Leak episodes overlapping viewport.
    final leakEps = bucket.leakEpisodes.where((e) => e.overlapsMs(startEpochMs, endEpochMsExclusive)).toList(growable: false);

    // Episode links overlapping viewport (by snore episode time).
    final links = bucket.episodeLinks.where((l) {
      return l.snoreStartEpochMs < endEpochMsExclusive && l.snoreEndEpochMsExclusive > startEpochMs;
    }).toList(growable: false);

    return Prs1ViewportResult(
      startEpochMs: startEpochMs,
      endEpochMsExclusive: endEpochMsExclusive,
      waveforms: waveforms,
      events: events,
      flowLimitationBreathSeries: flBreath,
      flowLimitation5mEmaSeries: sliceMinuteSeries(bucket.flowLimitation5mEmaSeries),
      flowLimitation15mEmaSeries: sliceMinuteSeries(bucket.flowLimitation15mEmaSeries),
      flowLimitationSeverityBands5mEma: sliceBands(bucket.flowLimitationSeverityBands5mEma),
      flowLimitationSeverityBands15mEma: sliceBands(bucket.flowLimitationSeverityBands15mEma),
      snoreEpisodes: eps,
      snoreHeatmap1mCounts: heatCounts,
      snoreHeatmap1mMaxCount: bucket.snoreHeatmap1mMaxCount,
      leakEpisodes: leakEps,
      episodeLinks: links,
    );
  }
}
