// lib/features/prs1/aggregate/prs1_daily_models.dart

import '../model/prs1_event.dart';
import '../model/prs1_session.dart';
import '../model/prs1_signal_sample.dart';
import '../stats/prs1_rolling_metrics.dart';
import '../stats/prs1_snore_episodes.dart';
import '../stats/prs1_value_episodes.dart';
import '../stats/prs1_episode_correlation.dart';

/// A slice of a session that lies within a single local day bucket.
class Prs1SessionSlice {
  const Prs1SessionSlice({
    required this.session,
    required this.start,
    required this.end,
  });

  final Prs1Session session;
  final DateTime start;
  final DateTime end;

  int get durationSeconds {
    final s = end.difference(start).inSeconds;
    return s < 0 ? 0 : s;
  }
}

/// Daily bucket (local midnight-based), intended to match OSCAR's "Daily Aggregation" layer.
///
/// This is **engine-only** and intentionally UI-agnostic.
class Prs1DailyBucket {
  const Prs1DailyBucket({
    required this.day,
    required this.slices,
    required this.events,
    required this.pressureSamples,
    required this.leakSamples,
    required this.flowSamples,
    required this.flexSamples,
    required this.usageSeconds,
    required this.eventCounts,
    required this.ahi,
    required this.snoreCount,
    required this.snorePerHour,
    required this.flexDutyCycle,
    required this.pressureMin,
    required this.pressureMedian,
    required this.pressureP95,
    required this.pressureMax,
    this.pressureOscarMin,
    this.pressureOscarMedian,
    this.pressureOscarP95,
    this.pressureOscarMax,
    this.pressureBiasPctMin,
    this.pressureBiasPctMedian,
    this.pressureBiasPctP95,
    this.pressureBiasPctMax,
    this.minuteVentOscarMin,
    this.minuteVentOscarMedian,
    this.minuteVentOscarP95,
    this.minuteVentOscarMax,
    this.minuteVentBiasPctMin,
    this.minuteVentBiasPctMedian,
    this.minuteVentBiasPctP95,
    this.minuteVentBiasPctMax,
    required this.leakMedian,
    required this.leakMin,
    required this.leakMax,
    required this.leakP95,
    required this.leakPercentOverThreshold,
    required this.tidalVolumeMedian,
    required this.tidalVolumeP95,
    required this.tidalVolumeMin,
    required this.tidalVolumeMax,
    required this.respRateMedian,
    required this.respRateP95,
    required this.respRateMin,
    required this.respRateMax,
    required this.minuteVentMedian,
    required this.minuteVentP95,
    required this.minuteVentMin,
    required this.minuteVentMax,
    required this.inspTimeMedian,
    required this.inspTimeP95,
    required this.inspTimeMin,
    required this.inspTimeMax,
    required this.expTimeMedian,
    required this.expTimeP95,
    required this.expTimeMin,
    required this.expTimeMax,
    required this.ieRatioMedian,
    required this.ieRatioP95,
    required this.ieRatioMin,
    required this.ieRatioMax,
    required this.flowLimitationMedian,
    required this.flowLimitationP95,
    required this.flowLimitationMin,
    required this.flowLimitationMax,
    required this.flowLimitationSeries,
    required this.flowLimitation1mMedianSeries,
    required this.flowLimitation5mEmaSeries,
    required this.flowLimitation15mEmaSeries,
    required this.flowLimitationSeverityBands5mEma,
    required this.flowLimitationSeverityBands15mEma,
    required this.snoreHeatmap1mCounts,
    required this.snoreHeatmap1mMaxCount,
    required this.snoreEpisodes,
    required this.snoreEpisodeCount,
    required this.snoreEpisodeTotalSeconds,
    required this.snoreEpisodeMaxPeakDensityPerMin,
    required this.leakEpisodes,
    required this.leakEpisodeCount,
    required this.leakEpisodeTotalSeconds,
    required this.episodeLinks,
    required this.episodeCorrelationSummary,
    required this.rollingAhi5m,
    required this.rollingAhi10m,
    required this.rollingAhi30m,
  });

  /// Local midnight (YYYY-MM-DD 00:00:00 local time).
  final DateTime day;

  /// All session slices that overlap this day.
  final List<Prs1SessionSlice> slices;

  /// Events that fall within this day bucket (already time-clamped).
  final List<Prs1Event> events;

  /// Continuous signal samples (Milestone A / L8).
  ///
  /// These lists are *engine channels*: they may be empty until decoders start
  /// extracting time-series signals from PRS1.
  final List<Prs1SignalSample> pressureSamples;
  final List<Prs1SignalSample> leakSamples;
  final List<Prs1SignalSample> flowSamples;
  final List<Prs1SignalSample> flexSamples;

  /// Total therapy usage time within this day bucket.
  final int usageSeconds;

  /// Count of each event type within this day.
  final Map<Prs1EventType, int> eventCounts;

  /// Daily AHI recomputed from event counts & usage time:
  /// (OA + CA + H) / hoursUsed.
  final double? ahi;

  /// Daily snore count (same as eventCounts[snore], provided for convenience).
  final int snoreCount;

  /// Snore density (events per hour of usage) for this day.
  final double? snorePerHour;

  /// Flex active duty cycle (0..1) within this day, if flex samples exist.
  final double? flexDutyCycle;

  // Pressure (if pressure samples are available; otherwise null).
  final double? pressureMin;
  final double? pressureMedian;
  final double? pressureP95;
  final double? pressureMax;


  // OSCAR reference for pressure (optional).
  final double? pressureOscarMin;
  final double? pressureOscarMedian;
  final double? pressureOscarP95;
  final double? pressureOscarMax;

  // Bias % (App vs OSCAR) for pressure (optional).
  final double? pressureBiasPctMin;
  final double? pressureBiasPctMedian;
  final double? pressureBiasPctP95;
  final double? pressureBiasPctMax;

  // MV (Minute Ventilation) OSCAR-mode verification
  final double? minuteVentOscarMin;
  final double? minuteVentOscarMedian;
  final double? minuteVentOscarP95;
  final double? minuteVentOscarMax;

  // bias% = (thisApp - oscar) / oscar * 100
  final double? minuteVentBiasPctMin;
  final double? minuteVentBiasPctMedian;
  final double? minuteVentBiasPctP95;
  final double? minuteVentBiasPctMax;


  // Leak (if leak samples are available; otherwise null).
  final double? leakMedian;
  final double? leakMin;
  final double? leakMax;
  final double? leakP95;

  /// Percentage (0..100) of time where leak > threshold (if leak samples exist).
  final double? leakPercentOverThreshold;


  // Breath-derived metrics (from high-rate Flow waveform segmentation; may be null if waveform/breaths unavailable).
  final double? tidalVolumeMedian;
  final double? tidalVolumeP95;
  final double? tidalVolumeMin;
  final double? tidalVolumeMax;
  final double? respRateMedian;
  final double? respRateP95;
  final double? respRateMin;
  final double? respRateMax;
  final double? minuteVentMedian;
  final double? minuteVentP95;
  final double? minuteVentMin;
  final double? minuteVentMax;
  final double? inspTimeMedian;
  final double? inspTimeP95;
  final double? inspTimeMin;
  final double? inspTimeMax;
  final double? expTimeMedian;
  final double? expTimeP95;
  final double? expTimeMin;
  final double? expTimeMax;
  final double? ieRatioMedian;
  final double? ieRatioP95;

  final double? ieRatioMin;
  final double? ieRatioMax;
  // Flow limitation (continuous indicator estimated from flow waveform).
  final double? flowLimitationMedian;
  final double? flowLimitationP95;
  final double? flowLimitationMin;
  final double? flowLimitationMax;
  final List<Prs1TimePoint> flowLimitationSeries;

  /// Minute-bucketed median FL curve (1-minute resolution).
  final List<Prs1TimePoint> flowLimitation1mMedianSeries;

  /// Smoothed FL curve (EMA over the 1-minute median series, default 5 minutes).
  final List<Prs1TimePoint> flowLimitation5mEmaSeries;

  /// Smoothed FL curve (EMA over the 1-minute median series, default 15 minutes).
  final List<Prs1TimePoint> flowLimitation15mEmaSeries;

  /// Severity bands derived from the 5-minute EMA curve (length == 1440).
  /// -1 = missing, 0 = [0.0,0.1), 1 = [0.1,0.3), 2 = [0.3,+inf)
  final List<int> flowLimitationSeverityBands5mEma;

  /// Severity bands derived from the 15-minute EMA curve (length == 1440).
  final List<int> flowLimitationSeverityBands15mEma;

  /// Snore heatmap at 1-minute resolution: count of snore events per minute.
  final List<int> snoreHeatmap1mCounts;

  /// Maximum snore count in any single minute (useful for normalizing heatmap intensity).
  final int snoreHeatmap1mMaxCount;


  // Snore episodes (clustered segments).
  final List<Prs1SnoreEpisode> snoreEpisodes;
  final int snoreEpisodeCount;
  final int snoreEpisodeTotalSeconds;
  final double? snoreEpisodeMaxPeakDensityPerMin;

  // Leak episodes (over-threshold segments, beyond %time).
  final List<Prs1ValueEpisode> leakEpisodes;
  final int leakEpisodeCount;
  final int leakEpisodeTotalSeconds;

  // Episode correlation (Snore ↔ Leak/High-FL overlap).
  final List<Prs1EpisodeLink> episodeLinks;
  final Prs1EpisodeCorrelationSummary episodeCorrelationSummary;

  // Rolling/windowed metrics (minute-resolution time series for the day).
  final List<Prs1TimePoint> rollingAhi5m;
  final List<Prs1TimePoint> rollingAhi10m;
  final List<Prs1TimePoint> rollingAhi30m;

}