// lib/features/prs1/aggregate/prs1_daily_aggregator.dart
//
// Layer 6: Daily Aggregation Engine (OSCAR-style).
//
// Topology:
// Absolute Time (epoch seconds)
// └── Day Bucket (00:00–23:59)
//     └── Session slices
//         └── Signal samples / Events
//
// Notes:
// - We aggregate using *local time* day buckets (DateTime(year,month,day)).
// - We recompute daily AHI from event counts / hours used.
// - For pressure/leak percentiles we require sample events (pressureSample/leakSample).
//   If samples are not present yet, those fields remain null (engine is still structurally correct).

import 'dart:math' as math;

import '../model/prs1_event.dart';
import '../model/prs1_session.dart';
import '../model/prs1_signal_sample.dart';
import '../model/prs1_breath.dart';
import '../stats/prs1_breath_analyzer.dart';
import '../stats/prs1_flow_limitation.dart';
import '../stats/prs1_snore_episodes.dart';
import '../stats/prs1_snore_heatmap.dart';
import '../stats/prs1_value_episodes.dart';
import '../stats/prs1_episode_correlation.dart';
import '../stats/prs1_weighted_value_stats.dart';
import '../stats/prs1_rolling_metrics.dart';
import 'prs1_daily_models.dart';
import '../stats/prs1_time_weighted_stats.dart';

/// Reference (ground truth) values exported from OSCAR for validation.
///
/// This is a temporary in-code map while we validate the engine; later we can
/// load this from a user-supplied JSON/CSV snapshot.
class Prs1OscarReference {
  const Prs1OscarReference({required this.min, required this.median, required this.p95, required this.max});
  final double min;
  final double median;
  final double p95;
  final double max;

  static Prs1OscarReference? pressureForDay(DateTime dayLocal) {
    final key = DateTime(dayLocal.year, dayLocal.month, dayLocal.day);
    final ref = _pressureByDay[key];
    return ref;
  }

  // Known days from screenshots (expand as you provide more).
  static final Map<DateTime, Prs1OscarReference> _pressureByDay = <DateTime, Prs1OscarReference>{
    DateTime(2026, 1, 30): const Prs1OscarReference(min: 9.50, median: 9.50, p95: 12.00, max: 13.10),
    DateTime(2026, 1, 31): const Prs1OscarReference(min: 9.50, median: 9.50, p95: 12.50, max: 13.30),
  };
}

double? _biasPct(double? app, double? ref) {
  if (app == null || ref == null) return null;
  if (ref == 0) return null;
  return (app - ref) / ref * 100.0;
}


class Prs1DailyAggregationConfig {
  const Prs1DailyAggregationConfig({
    this.leakOverThreshold = 24.0,
    this.minSampleSegmentSeconds = 1,
  });

  /// Common clinical threshold (can be device/profile dependent; keep configurable).
  final double leakOverThreshold;

  /// Ignore sample segments smaller than this to reduce noise.
  final int minSampleSegmentSeconds;
}

class Prs1DailyAggregator {
  const Prs1DailyAggregator({this.config = const Prs1DailyAggregationConfig()});

  final Prs1DailyAggregationConfig config;

  DateTime _dayKey(DateTime dt) => DateTime(dt.year, dt.month, dt.day);

  void _bucketizeSamples(
    Map<DateTime, _MutableBucket> buckets,
    List<Prs1SignalSample> samples,
    Prs1SignalType expectedType,
    {DateTime? anchorDay}
  ) {
    if (samples.isEmpty) return;
    for (final sm in samples) {
      if (sm.signalType != expectedType) continue;
      final t = sm.timeLocal;
      final day = anchorDay ?? _dayKey(t);
      final b = buckets[day];
      if (b == null) continue;
      if (!b.containsTime(t)) continue;

      switch (expectedType) {
        case Prs1SignalType.pressure:
          b.pressureSamples.add(sm);
          break;
        case Prs1SignalType.exhalePressure:
          b.exhalePressureSamples.add(sm);
          break;
        case Prs1SignalType.leak:
          b.leakSamples.add(sm);
          break;
        case Prs1SignalType.flowRate:
          b.flowSamples.add(sm);
          break;
        case Prs1SignalType.flexActive:
          b.flexSamples.add(sm);
          break;
      }
    }
  }

  void _bucketizeSampleEvents(
    Map<DateTime, _MutableBucket> buckets,
    List<Prs1Event> events,
  ) {
    for (final e in events) {
      if ((e.type != Prs1EventType.pressureSample &&
              e.type != Prs1EventType.leakSample &&
              e.type != Prs1EventType.flowSample &&
              e.type != Prs1EventType.flexActiveSample) ||
          e.value == null) {
        continue;
      }

      final v = e.value;
      if (v is! num) continue;

      final day = _dayKey(e.time);
      final b = buckets[day];
      if (b == null) continue;
      if (!b.containsTime(e.time)) continue;

      final tEpochSec = (e.time.millisecondsSinceEpoch / 1000).floor();

      if (e.type == Prs1EventType.pressureSample) {
        b.pressureSamples.add(
          Prs1SignalSample(tEpochSec: tEpochSec, value: v.toDouble(), signalType: Prs1SignalType.pressure),
        );
      } else if (e.type == Prs1EventType.leakSample) {
        b.leakSamples.add(
          Prs1SignalSample(tEpochSec: tEpochSec, value: v.toDouble(), signalType: Prs1SignalType.leak),
        );
      } else {
        b.flowSamples.add(
          Prs1SignalSample(tEpochSec: tEpochSec, value: v.toDouble(), signalType: Prs1SignalType.flowRate),
        );
      }
    }
  }

  /// Build daily buckets for all days covered by [sessions].
  ///
  /// Returns buckets sorted ascending by day.
  List<Prs1DailyBucket> build(List<Prs1Session> sessions) {
    if (sessions.isEmpty) return const [];

    // Gather day range.
    DateTime minStart = sessions.first.start;
    DateTime maxStart = sessions.first.start;
    for (final s in sessions) {
      if (s.start.isBefore(minStart)) minStart = s.start;
      if (s.start.isAfter(maxStart)) maxStart = s.start;
    }

    final startDay = _dayKey(minStart);
    final endDay = _dayKey(maxStart);

    // Build buckets for all days in range.
    final buckets = <DateTime, _MutableBucket>{};
    DateTime cur = startDay;
    while (!cur.isAfter(endDay)) {
      buckets[cur] = _MutableBucket(cur, config);
      cur = cur.add(const Duration(days: 1));
    }

    // 1) Build session slices per *session-start day* (OSCAR-style nightly grouping).
    //    This keeps a single sleep session together even if it crosses midnight.
    for (final s in sessions) {
      final day = _dayKey(s.start);
      final b = buckets[day];
      if (b == null) continue;
      b.addSlice(Prs1SessionSlice(session: s, start: s.start, end: s.end));
    }

// 2) Bucketize events by absolute time (clamp to day).
    for (final s in sessions) {
      final day = _dayKey(s.start);
      final b = buckets[day];
      if (b == null) continue;
      for (final e in s.events) {
        // Keep all events within the session window (even across midnight).
        if (!b.containsTime(e.time)) continue;
        b.addEvent(e);
      }
    }

    // 2b) Bucketize continuous signal samples (Milestone A).
    //
    // This establishes the data channel needed for L8 statistics (median/p95/%over-threshold).
    for (final s in sessions) {
      _bucketizeSamples(buckets, s.pressureSamples, Prs1SignalType.pressure, anchorDay: _dayKey(s.start));
      _bucketizeSamples(buckets, s.exhalePressureSamples, Prs1SignalType.exhalePressure);
      _bucketizeSamples(buckets, s.leakSamples, Prs1SignalType.leak, anchorDay: _dayKey(s.start));
      _bucketizeSamples(buckets, s.flowSamples, Prs1SignalType.flowRate);
      _bucketizeSamples(buckets, s.flexSamples, Prs1SignalType.flexActive);

      // Back-compat: if decoders still represent samples as event types,
      // convert them into the dedicated signal-sample channel.
      _bucketizeSampleEvents(buckets, s.events);
    }

    // 3) Build pressure/leak weighted stats when sample events exist.
    for (final b in buckets.values) {
      b.computeDerived(config);
    }

    final out = buckets.values.map((m) => m.freeze()).toList(growable: false);
    out.sort((a, b) => a.day.compareTo(b.day));
    return out;
  }
}

class _MutableBucket {
  _MutableBucket(this.day, this.cfg) : largeLeakThresholdLpm = cfg.leakOverThreshold; // fallback; will be overwritten by total-leak mean (OSCAR dashed line)

  final DateTime day;
  final Prs1DailyAggregationConfig cfg;
  final List<Prs1SessionSlice> slices = [];
  final List<Prs1Event> events = [];
  final List<Prs1SignalSample> pressureSamples = [];
  final List<Prs1SignalSample> exhalePressureSamples = [];
  final List<Prs1SignalSample> leakSamples = [];
  final List<Prs1SignalSample> unintentionalLeakSamples = [];
  double? leakBaselineLpm;

  /// Large-leak threshold expressed on the **total leak** axis (L/min).
  ///
  /// Default is [Prs1DailyAggregationConfig.leakOverThreshold]. When baseline/intentional
  /// leak is estimated, this becomes: baseline + cfg.leakOverThreshold.
  double largeLeakThresholdLpm;

  // Legacy constant kept for reference only. Do not use in new logic.
  static const double kLargeLeakThresholdLpm = 24.0;
  final List<Prs1SignalSample> flowSamples = [];
  final List<Prs1SignalSample> flexSamples = [];
  final Map<Prs1EventType, int> counts = {};

  // Breath-by-breath (Milestone E)
  final List<Prs1Breath> breaths = [];

  int usageSeconds = 0;

  double? ahi;
  int snoreCount = 0;
  double? snorePerHour;
  double? flexDutyCycle;

  double? pressureMin;
  double? pressureMedian;
  double? pressureP95;
  double? pressureMax;

  double? epapMin;
  double? epapMedian;
  double? epapP95;
  double? epapMax;

  // OSCAR reference + bias (optional, validation only)
  double? pressureOscarMin;
  double? pressureOscarMedian;
  double? pressureOscarP95;
  double? pressureOscarMax;
  double? pressureBiasPctMin;
  double? pressureBiasPctMedian;
  double? pressureBiasPctP95;
  double? pressureBiasPctMax;

  double? leakMedian;
  double? leakMin;
  double? leakMax;
  double? leakP95;
  double? leakPercentOver;


  // Breath-derived daily stats
  double? tidalVolumeMedian;
  double? tidalVolumeP95;
  double? respRateMedian;
  double? respRateP95;
  double? minuteVentMedian;
  double? minuteVentP95;

  double? tidalVolumeMin;
  double? tidalVolumeMax;
  double? respRateMin;
  double? respRateMax;
  double? minuteVentMin;
  double? minuteVentMax;
  double? inspTimeMin;
  double? inspTimeMax;
  double? expTimeMin;
  double? expTimeMax;
  double? ieRatioMin;
  double? ieRatioMax;
  double? inspTimeMedian;
  double? inspTimeP95;
  double? expTimeMedian;
  double? expTimeP95;
  double? ieRatioMedian;
  double? ieRatioP95;

  // Flow limitation derived from flow waveform (0..1)
  double? flowLimitationMedian;
  double? flowLimitationP95;
  List<Prs1TimePoint> flowLimitationSeries = const [];
  List<Prs1TimePoint> flowLimitation1mMedianSeries = const [];
  List<Prs1TimePoint> flowLimitation5mEmaSeries = const [];
  List<Prs1TimePoint> flowLimitation15mEmaSeries = const [];
  List<int> flowLimitationSeverityBands5mEma = const [];
  List<int> flowLimitationSeverityBands15mEma = const [];

  // Snore heatmap (minute-resolution).
  List<int> snoreHeatmap1mCounts = const [];
  int snoreHeatmap1mMaxCount = 0;


  // Snore episode / cluster analysis
  List<Prs1SnoreEpisode> snoreEpisodes = const [];
  int snoreEpisodeCount = 0;
  int snoreEpisodeTotalSeconds = 0;
  double? snoreEpisodeMaxPeakDensityPerMin;


  // Leak episodes (over-threshold segments).
  List<Prs1ValueEpisode> leakEpisodes = const [];
  int leakEpisodeCount = 0;
  int leakEpisodeTotalSeconds = 0;

  // Episode correlation (Snore ↔ Leak/High-FL overlap).
  List<Prs1EpisodeLink> episodeLinks = const [];
  Prs1EpisodeCorrelationSummary episodeCorrelationSummary = const Prs1EpisodeCorrelationSummary(
    snoreEpisodeCount: 0,
    snoreEpisodesWithLeakOverlap: 0,
    snoreEpisodesWithHighFlowLimOverlap: 0,
    snoreEpisodesWithBothOverlap: 0,
    totalLeakOverlapSeconds: 0,
    totalHighFlowLimOverlapSeconds: 0,
  );

  // Rolling/windowed series
  List<Prs1TimePoint> rollingAhi5m = const [];
  List<Prs1TimePoint> rollingAhi10m = const [];
  List<Prs1TimePoint> rollingAhi30m = const [];

  void addSlice(Prs1SessionSlice s) {
    slices.add(s);
    usageSeconds += s.durationSeconds;
  }

  bool containsTime(DateTime t) {
    for (final s in slices) {
      if (!t.isBefore(s.start) && t.isBefore(s.end)) return true;
    }
    return false;
  }

  void addEvent(Prs1Event e) {
    events.add(e);
    counts[e.type] = (counts[e.type] ?? 0) + 1;
  }

  void addPressureSample(Prs1SignalSample s) => pressureSamples.add(s);

  void addLeakSample(Prs1SignalSample s) => leakSamples.add(s);

  void addFlowSample(Prs1SignalSample s) => flowSamples.add(s);


  void computeDerived(Prs1DailyAggregationConfig cfg) {
    // Daily usage (seconds) already computed via slices.

    // Daily AHI recompute from event counts / hours used.
    final hoursUsed = usageSeconds / 3600.0;
    if (hoursUsed > 0) {
      final oa = counts[Prs1EventType.obstructiveApnea] ?? 0;
      final ca = counts[Prs1EventType.clearAirwayApnea] ?? 0;
      final h = counts[Prs1EventType.hypopnea] ?? 0;
      ahi = (oa + ca + h) / hoursUsed;
    } else {
      ahi = null;
    }

    // Flow limitation fallback when we don't have the high-rate flow waveform.
    // PRS1/DreamStation event streams include discrete FlowLimitation events (0x0C in F0V6).
    // Our "FL p95" UI expects a scalar; if waveform-based computation is unavailable,
    // we expose a reasonable proxy: FlowLimitation events per hour.
    final flCount = counts[Prs1EventType.flowLimitation] ?? 0;
    final flPerHour = (hoursUsed > 0) ? (flCount / hoursUsed) : null;
    if (flowLimitationP95 == null) flowLimitationP95 = flPerHour;
    if (flowLimitationMedian == null) flowLimitationMedian = flPerHour;

    // Snore (already time-clamped to session slices).
    snoreCount = counts[Prs1EventType.snore] ?? 0;
    snorePerHour = (hoursUsed > 0) ? (snoreCount / hoursUsed) : null;

    // Snore episode/cluster analysis (group snore events into episodes).
    snoreEpisodes = Prs1SnoreEpisodes.build(events);
    snoreEpisodeCount = snoreEpisodes.length;
    snoreEpisodeTotalSeconds = snoreEpisodes.fold<int>(0, (a, e) => a + e.durationSec);
    snoreEpisodeMaxPeakDensityPerMin =
        snoreEpisodes.isEmpty ? null : snoreEpisodes.map((e) => e.peakDensityPerMin60s).reduce((a, b) => a > b ? a : b);

    // Snore heatmap (minute-resolution) for OSCAR-like intensity overlays.
    final dayStartEpochSecHeat = day.toUtc().millisecondsSinceEpoch ~/ 1000;
    final minutesHeat = 24 * 60;
    snoreHeatmap1mCounts = Prs1SnoreHeatmap.countsPerMinute(
      dayStartEpochSec: dayStartEpochSecHeat,
      minutes: minutesHeat,
      events: events,
    );
    snoreHeatmap1mMaxCount = Prs1SnoreHeatmap.maxCount(snoreHeatmap1mCounts);


    // Flex duty cycle (if flex samples exist; values should be 0/1 or similar).
    flexDutyCycle = _dutyCycleFromNumericSamples(
      flexSamples,
      threshold: 0.5,
      cfg: cfg,
    );

    // Pressure stats (min/median/95/max).
    final pressureIntervals = _numericIntervalsWithinSlices(
      samples: pressureSamples,
      slices: slices,
      cfg: cfg,
    );
    pressureMin = _minIntervalValue(pressureIntervals);
    pressureMax = _maxIntervalValue(pressureIntervals);
    pressureMedian = _weightedQuantileFromIntervals(pressureIntervals, 0.5);
    pressureP95 = _weightedQuantileFromIntervals(pressureIntervals, 0.95);

    // EPAP/Flex (green line) stats.
    final epapIntervals = _numericIntervalsWithinSlices(
      samples: exhalePressureSamples,
      slices: slices,
      cfg: cfg,
    );
    epapMin = _minIntervalValue(epapIntervals);
    epapMax = _maxIntervalValue(epapIntervals);
    epapMedian = _weightedQuantileFromIntervals(epapIntervals, 0.5);
    epapP95 = _weightedQuantileFromIntervals(epapIntervals, 0.95);

    // Leak stats (median/95/% over threshold).
    final leakIntervals = _numericIntervalsWithinSlices(
      samples: leakSamples,
      slices: slices,
      cfg: cfg,
    );
    leakMedian = _weightedQuantileFromIntervals(leakIntervals, 0.5);
    leakP95 = _weightedQuantileFromIntervals(leakIntervals, 0.95);
    // Also compute min/max for OSCAR-like summary table.
    leakMin = _minIntervalValue(leakIntervals);
    leakMax = _maxIntervalValue(leakIntervals);

    // DreamStation provides **total leak** samples. OSCAR's dashed "Large Leak" line is
    // typically expressed on the *total leak* axis, and will vary by night because
    // baseline/intentional leak (mask vent) varies with pressure/mask.
    //
    // We estimate baseline/intentional leak as a low-percentile of total leak over the
    // whole night, then define the per-bucket large-leak threshold as:
    //   thresholdTotal = baseline + cfg.leakOverThreshold
    // where cfg.leakOverThreshold is the conventional unintentional leak threshold (e.g. 24 L/min).
    // Use bucket-scoped threshold so UI & summary table can reflect nightly changes.
    largeLeakThresholdLpm = cfg.leakOverThreshold; // fallback; will be overwritten by total-leak mean (OSCAR dashed line)

    // Derive an OSCAR-like "Leak Rate" (unintentional) series.
    // OSCAR's black line is *not* simply "Total - constant". It behaves like
    // Total Leaks minus an estimated intentional/baseline leak that depends on
    // pressure/mask venting. When the derived unintentional leak is ~0 all night,
    // the black line effectively "disappears" (matching what you observed).
    if (leakSamples.isNotEmpty) {
      final totalVals = leakSamples
          .map((e) => e.value)
          .whereType<double>()
          .where((v) => v.isFinite)
          .toList();

      if (totalVals.isEmpty) {
        leakBaselineLpm = null;
        largeLeakThresholdLpm = cfg.leakOverThreshold; // safe fallback
        unintentionalLeakSamples..clear();
      } else {
        // Keep your requested behavior: dashed threshold = nightly Total-Leaks mean.
        final mean = totalVals.reduce((a, b) => a + b) / totalVals.length;
        largeLeakThresholdLpm = mean.isFinite ? mean : cfg.leakOverThreshold;

        // Build a pressure-dependent "intentional leak" model using the lower envelope
        // of Total Leaks across pressure bins.
        final model = _MutableBucket._estimateIntentionalLeakModel(
          totalLeakSamples: leakSamples,
          pressureSamples: pressureSamples,
        );
        leakBaselineLpm = model?.baselineAtMedianPressure;

        unintentionalLeakSamples
          ..clear()
          ..addAll(
            leakSamples.map(
              (s) {
                final p = _MutableBucket._valueAtTimestampMs(pressureSamples, s.timestampMs);
                final expected = (model != null && p != null)
                    ? (model.intercept + model.slope * p)
                    : (model?.baselineAtMedianPressure ?? 0.0);
                final v = s.value - expected;
                return Prs1SignalSample(
                  timestampMs: s.timestampMs,
                  value: (v.isFinite && v > 0) ? v : 0.0,
                  signalType: Prs1SignalType.leak,
                );
              },
            ),
          );
      }
    }

    // % time over large-leak threshold (on total-leak axis).
    final fracOver = _fractionOverFromIntervals(leakIntervals, largeLeakThresholdLpm);
    leakPercentOver = fracOver;

    // Leak over-threshold episodes (segments), for OSCAR-like analysis beyond %time.
    leakEpisodes = Prs1ValueEpisodes.fromIntervalsOverThreshold(
      leakIntervals,
      threshold: largeLeakThresholdLpm,
      minDurationSec: 30,
      gapToleranceSec: 5,
    );
    leakEpisodeCount = leakEpisodes.length;
    leakEpisodeTotalSeconds = leakEpisodes.fold<int>(0, (a, e) => a + e.durationSec);


    // Breath-derived metrics (TV / RR / MV / insp/exp / I:E).
    final tv = <double>[];
    final rr = <double>[];
    final mv = <double>[];
    final inspT = <double>[];
    final expT = <double>[];
    final ie = <double>[];
    final w = <double>[]; // weights: breath duration seconds

    for (final sl in slices) {
      final sess = sl.session;
      final wf = sess.flowWaveform;
      if (wf == null) continue;

      // Use cached breaths if present; otherwise segment on demand.
      final breathList = sess.breaths.isNotEmpty
          ? sess.breaths
          : Prs1BreathAnalyzer.segmentBreaths(
              wf,
              leak: sess.leakWaveform,
              leakOverThreshold: cfg.leakOverThreshold,
            );

      final slStartMs = sl.start.toUtc().millisecondsSinceEpoch;
      final slEndMs = sl.end.toUtc().millisecondsSinceEpoch;

      for (final b in breathList) {
        if (b.startEpochMs < slStartMs || b.startEpochMs >= slEndMs) continue;

        final dur = b.durationSec;
        if (dur <= 0) continue;

        tv.add(b.tidalVolumeLiters * 1000.0);
        rr.add(b.respRateBpm);
        mv.add(b.minuteVentilationLpm);
        inspT.add(b.inspTimeSec);
        expT.add(b.expTimeSec);
        ie.add(b.ieRatio);
        w.add(dur);
      }
    }

    if (tv.isNotEmpty) {
      tidalVolumeMedian = Prs1WeightedValueStats.weightedMedian(tv, w);
      tidalVolumeP95 = Prs1WeightedValueStats.weightedQuantile(tv, w, 0.95);

      tidalVolumeMin = Prs1WeightedValueStats.min(tv);
      tidalVolumeMax = Prs1WeightedValueStats.max(tv);

      respRateMin = Prs1WeightedValueStats.min(rr);
      respRateMax = Prs1WeightedValueStats.max(rr);

      minuteVentMin = Prs1WeightedValueStats.min(mv);
      minuteVentMax = Prs1WeightedValueStats.max(mv);

      inspTimeMin = Prs1WeightedValueStats.min(inspT);
      inspTimeMax = Prs1WeightedValueStats.max(inspT);

      expTimeMin = Prs1WeightedValueStats.min(expT);
      expTimeMax = Prs1WeightedValueStats.max(expT);

      ieRatioMin = Prs1WeightedValueStats.min(ie);
      ieRatioMax = Prs1WeightedValueStats.max(ie);


      respRateMedian = Prs1WeightedValueStats.weightedMedian(rr, w);
      respRateP95 = Prs1WeightedValueStats.weightedQuantile(rr, w, 0.95);

      minuteVentMedian = Prs1WeightedValueStats.weightedMedian(mv, w);
      minuteVentP95 = Prs1WeightedValueStats.weightedQuantile(mv, w, 0.95);

      inspTimeMedian = Prs1WeightedValueStats.weightedMedian(inspT, w);
      inspTimeP95 = Prs1WeightedValueStats.weightedQuantile(inspT, w, 0.95);

      expTimeMedian = Prs1WeightedValueStats.weightedMedian(expT, w);
      expTimeP95 = Prs1WeightedValueStats.weightedQuantile(expT, w, 0.95);

      ieRatioMedian = Prs1WeightedValueStats.weightedMedian(ie, w);
      ieRatioP95 = Prs1WeightedValueStats.weightedQuantile(ie, w, 0.95);

      // Flow limitation (0..1) derived from inspiratory flattening.
      // Build per-breath points within the day slices and compute weighted stats.
      final flVals = <double>[];
      final flW = <double>[];
      final flSeries = <Prs1TimePoint>[];

      for (final sl in slices) {
        final sess = sl.session;
        final wf = sess.flowWaveform;
        if (wf == null) continue;
        final breathList2 = sess.breaths.isNotEmpty ? sess.breaths : Prs1BreathAnalyzer.segmentBreaths(wf);

        final slStartMs = sl.start.toUtc().millisecondsSinceEpoch;
        final slEndMs = sl.end.toUtc().millisecondsSinceEpoch;

        for (final b in breathList2) {
          if (b.startEpochMs < slStartMs || b.startEpochMs >= slEndMs) continue;
          final sc = Prs1FlowLimitation.scoreBreath(wf, b, zeroEps: 0.01);
          if (sc == null) continue;
          flSeries.add(Prs1TimePoint(tEpochSec: (b.startEpochMs ~/ 1000), value: sc));
          final dur = b.durationSec;
          if (dur > 0) {
            flVals.add(sc);
            flW.add(dur);
          }
        }
      }

      flowLimitationSeries = List.unmodifiable(flSeries);
      if (flVals.isNotEmpty) {
        flowLimitationMedian = Prs1WeightedValueStats.weightedMedian(flVals, flW);
        flowLimitationP95 = Prs1WeightedValueStats.weightedQuantile(flVals, flW, 0.95);
      } else {
        // Keep any fallback values (e.g., FL events/hour) set earlier.
      }

      // Convert breath-resolution FL points into an OSCAR-like continuous curve:
      // 1) 1-minute median buckets
      // 2) 5-minute EMA smoothing
      final dayStartEpochSec2 = day.toUtc().millisecondsSinceEpoch ~/ 1000;
      const minutesInDay2 = 24 * 60;
      final fl1m = Prs1FlowLimitation.minuteMedianSeries(
        breathSeries: flSeries,
        dayStartEpochSec: dayStartEpochSec2,
        minutes: minutesInDay2,
      );
      flowLimitation1mMedianSeries = List.unmodifiable(fl1m);
      final flEma5 = Prs1FlowLimitation.emaSeries(minuteSeries: fl1m, windowMinutes: 5);
      flowLimitation5mEmaSeries = List.unmodifiable(flEma5);

      final flEma15 = Prs1FlowLimitation.emaSeries(minuteSeries: fl1m, windowMinutes: 15);
      flowLimitation15mEmaSeries = List.unmodifiable(flEma15);

      // Banded severity curves (for OSCAR-like color layers).
      flowLimitationSeverityBands5mEma = Prs1FlowLimitation.bandedSeverity(minuteSeries: flEma5);
      flowLimitationSeverityBands15mEma = Prs1FlowLimitation.bandedSeverity(minuteSeries: flEma15);

    } else {
      tidalVolumeMedian = null;
      tidalVolumeP95 = null;
      respRateMedian = null;
      respRateP95 = null;
      minuteVentMedian = null;
      minuteVentP95 = null;
      inspTimeMedian = null;
      inspTimeP95 = null;
      expTimeMedian = null;
      expTimeP95 = null;
      ieRatioMedian = null;
      ieRatioP95 = null;

      // Keep any fallback values (e.g., FL events/hour) set earlier.
      flowLimitationSeries = const [];
      flowLimitation1mMedianSeries = const [];
      flowLimitation5mEmaSeries = const [];
      flowLimitation15mEmaSeries = const [];
      flowLimitationSeverityBands5mEma = const [];
      flowLimitationSeverityBands15mEma = const [];
    }


    // Episode correlation: Snore episodes ↔ Leak-over-threshold episodes ↔ High Flow-Limitation episodes.
    // Define "High FL" as severity band == 2 on the 5-minute EMA (>= 0.3).
    final dayStartEpochSecCorr = day.toUtc().millisecondsSinceEpoch ~/ 1000;
    final highFlEpisodes = Prs1ValueEpisodes.fromMinuteBands(
      flowLimitationSeverityBands5mEma,
      dayStartEpochSec: dayStartEpochSecCorr,
      bandPredicate: (b) => b >= 2,
      minDurationSec: 60,
      gapToleranceMinutes: 0,
    );
    episodeLinks = Prs1EpisodeCorrelation.link(
      snoreEpisodes: snoreEpisodes,
      leakEpisodes: leakEpisodes,
      highFlowLimEpisodes: highFlEpisodes,
    );
    episodeCorrelationSummary = Prs1EpisodeCorrelation.summarize(episodeLinks);



    // Rolling AHI (minute-resolution) within the day bucket.
    final dayStartEpochSec = day.toUtc().millisecondsSinceEpoch ~/ 1000;
    const minutes = 24 * 60;

    final usageSlices = slices
        .map(
          (s) => Prs1UsageSlice(
            s.start.toUtc().millisecondsSinceEpoch ~/ 1000,
            s.end.toUtc().millisecondsSinceEpoch ~/ 1000,
          ),
        )
        .toList(growable: false);

    final usePerMin = Prs1RollingMetrics.buildUsageSecondsPerMinute(
      dayStartEpochSec: dayStartEpochSec,
      minutes: minutes,
      slices: usageSlices,
    );

    final evtPerMin = Prs1RollingMetrics.buildAhiEventCountsPerMinute(
      dayStartEpochSec: dayStartEpochSec,
      minutes: minutes,
      events: events,
    );

    rollingAhi5m = Prs1RollingMetrics.rollingAhi(
      dayStartEpochSec: dayStartEpochSec,
      minutes: minutes,
      usageSecondsPerMinute: usePerMin,
      eventCountsPerMinute: evtPerMin,
      windowMinutes: 5,
    );

    rollingAhi10m = Prs1RollingMetrics.rollingAhi(
      dayStartEpochSec: dayStartEpochSec,
      minutes: minutes,
      usageSecondsPerMinute: usePerMin,
      eventCountsPerMinute: evtPerMin,
      windowMinutes: 10,
    );

    rollingAhi30m = Prs1RollingMetrics.rollingAhi(
      dayStartEpochSec: dayStartEpochSec,
      minutes: minutes,
      usageSecondsPerMinute: usePerMin,
      eventCountsPerMinute: evtPerMin,
      windowMinutes: 30,
    );

    // IMPORTANT:
    // For user-facing "AHI" we must match OSCAR / standard definition:
    //   AHI = (OA + CA + H) / hoursUsed
    // The earlier version overwrote the whole-night average with a *peak* rolling AHI
    // (e.g. 30-minute window max), which can easily produce scary / untrustworthy values.
    // We keep the whole-night AHI computed above and do NOT override it here.

  }

  /// Build piecewise-constant numeric intervals **clamped to session slices**.
  ///
  /// This is crucial because PRS1 sessions can be discontinuous within a day,
  /// and we must not let a sample's "hold" duration leak past a slice boundary.
  List<Prs1WeightedInterval<double>> _numericIntervalsWithinSlices({
    required List<Prs1SignalSample> samples,
    required List<Prs1SessionSlice> slices,
    required Prs1DailyAggregationConfig cfg,
  }) {
    if (samples.isEmpty || slices.isEmpty) return const [];

    final sorted = List<Prs1SignalSample>.from(samples)
      ..sort((a, b) => a.tEpochSec.compareTo(b.tEpochSec));

    final out = <Prs1WeightedInterval<double>>[];

    for (final sl in slices) {
      final t0 = (sl.start.millisecondsSinceEpoch / 1000).floor();
      final t1 = (sl.end.millisecondsSinceEpoch / 1000).floor();
      if (t1 <= t0) continue;

      // Pull samples that start within this slice.
      final inSlice = <Prs1SignalSample>[];
      for (final sm in sorted) {
        if (sm.tEpochSec < t0) continue;
        if (sm.tEpochSec >= t1) break;
        inSlice.add(sm);
      }
      if (inSlice.isEmpty) continue;

      for (int i = 0; i < inSlice.length; i++) {
        final cur = inSlice[i];
        final nextT = (i + 1 < inSlice.length) ? inSlice[i + 1].tEpochSec : t1;
        final segEnd = (nextT < t1) ? nextT : t1;
        final dur = segEnd - cur.tEpochSec;
        if (dur < cfg.minSampleSegmentSeconds) {
          // Keep the point for min/max visibility, but give it 0 seconds so it does not affect weighted quantiles.
          final v = cur.value;
          if (v.isNaN || v.isInfinite) { /* skip */ } else {
            out.add(Prs1WeightedInterval<double>(t0: cur.tEpochSec, t1: cur.tEpochSec, value: v));
          }
          continue;
        }
        final v = cur.value;
        if (v.isNaN || v.isInfinite) continue;
        out.add(Prs1WeightedInterval<double>(t0: cur.tEpochSec, t1: segEnd, value: v));
      }
    }

    return out;
  }

  static double? _minIntervalValue(List<Prs1WeightedInterval<double>> intervals) {
    double? m;
    for (final it in intervals) {
      m = (m == null) ? it.value : math.min(m, it.value);
    }
    return m;
  }

  static double? _maxIntervalValue(List<Prs1WeightedInterval<double>> intervals) {
    double? m;
    for (final it in intervals) {
      m = (m == null) ? it.value : math.max(m, it.value);
    }
    return m;
  }

  static 
double? _minValueFromIntervals(List<Prs1WeightedInterval<double>> intervals) {
  if (intervals.isEmpty) return null;
  double m = intervals.first.value;
  for (final it in intervals) {
    if (it.value < m) m = it.value;
  }
  return m;
}

double? _maxValueFromIntervals(List<Prs1WeightedInterval<double>> intervals) {
  if (intervals.isEmpty) return null;
  double m = intervals.first.value;
  for (final it in intervals) {
    if (it.value > m) m = it.value;
  }
  return m;
}

  double? _weightedQuantileFromIntervals(List<Prs1WeightedInterval<double>> intervals, double q) {
    if (intervals.isEmpty) return null;
    final qq = q.clamp(0.0, 1.0);

    final positive = intervals.where((it) => it.seconds > 0).toList(growable: false);
    if (positive.isEmpty) return null;

    final totalW = positive.fold<int>(0, (acc, it) => acc + it.seconds);
    if (totalW <= 0) return null;

    final sorted = List<Prs1WeightedInterval<double>>.from(positive)
      ..sort((a, b) => a.value.compareTo(b.value));

    if (qq <= 0.0) return sorted.first.value;
    if (qq >= 1.0) return sorted.last.value;

    final target = totalW * qq;

    int cum = 0;
    int prevCum = 0;
    double? prevV;

    for (final it in sorted) {
      prevCum = cum;
      cum += it.seconds;
      if (cum >= target) {
        if (prevV == null) return it.value;
        final span = cum - prevCum; // == it.seconds
        if (span <= 0) return it.value;
        final t = ((target - prevCum) / span).clamp(0.0, 1.0);
        return prevV + (it.value - prevV) * t;
      }
      prevV = it.value;
    }
    return sorted.last.value;
  }


  static double? _fractionOverFromIntervals(List<Prs1WeightedInterval<double>> intervals, double threshold) {
    if (intervals.isEmpty) return null;
    final total = intervals.fold<int>(0, (acc, it) => acc + it.seconds);
    if (total <= 0) return null;
    final over = intervals.where((it) => it.value > threshold).fold<int>(0, (acc, it) => acc + it.seconds);
    return over / total;
  }

  double? _dutyCycleFromNumericSamples(
    List<Prs1SignalSample> samples, {
    required double threshold,
    required Prs1DailyAggregationConfig cfg,
  }) {
    if (samples.isEmpty) return null;

    // Convert numeric samples to bool samples via thresholding.
    // Reuse the stats core's dutyCycle on bool intervals (piecewise constant).
    return Prs1TimeWeightedStats.dutyCycle(
      samples: samples,
      timeEpochSec: (s) => (s as Prs1SignalSample).tEpochSec,
      value: (s) => (s as Prs1SignalSample).value > threshold,
      // No explicit end time here because we clamp to slices via interval builder elsewhere.
      // Flex is optional; leaving endEpochSec null makes the last sample contribute 0s if it stands alone.
      // Once a real Flex channel is decoded, we can provide proper endEpochSec (slice end) similarly.
      endEpochSec: null,
    );
  }

  /// Returns the last sample value at or before [timestampMs].
  /// Assumes [samples] are sorted by timestampMs.
  static double? _valueAtTimestampMs(List<Prs1SignalSample> samples, int timestampMs) {
    if (samples.isEmpty) return null;

    int lo = 0;
    int hi = samples.length - 1;

    // Fast bounds.
    if (timestampMs < samples.first.timestampMs) return null;
    if (timestampMs >= samples.last.timestampMs) return samples.last.value;

    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      final t = samples[mid].timestampMs;
      if (t == timestampMs) {
        return samples[mid].value;
      } else if (t < timestampMs) {
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    // hi is the index of the last element < timestampMs.
    if (hi < 0) return null;
    return samples[hi].value;
  }

  /// Estimate the *intentional* (mask vent) leak baseline from Total Leaks + Pressure,
  /// so we can compute an OSCAR-like "Leak Rate" (unintentional) as:
  ///   max(0, total - intentional(pressure)).
  ///
  /// OSCAR's black line often disappears on nights where leak rate stays ~0.
  /// This model aims to reproduce that behavior without requiring mask metadata.
  static ({double intercept, double slope, double baselineAtMedianPressure}) _estimateIntentionalLeakModel({
    required List<Prs1SignalSample> totalLeakSamples,
    required List<Prs1SignalSample> pressureSamples,
      }) {
    if (totalLeakSamples.isEmpty || pressureSamples.isEmpty) {
      return (intercept: 0.0, slope: 0.0, baselineAtMedianPressure: 0.0);
    }

    // Build (pressure, totalLeak) pairs where both channels are defined.
    // Note: totalLeakSamples is already session-scoped in this codebase, so we do not
    // need an additional "slices" clamp here.
    final pairs = <({double p, double leak})>[];
    for (final s in totalLeakSamples) {
      final t = s.timestampMs;
      final p = _valueAtTimestampMs(pressureSamples, t);
      if (p == null) continue;
      if (!s.value.isFinite || !p.isFinite) continue;
      pairs.add((p: p, leak: s.value));
    }


    if (pairs.length < 10) {
      // Fallback: use a low percentile as a constant baseline.
      final leaks = pairs.map((e) => e.leak).toList()..sort();
      final idx = (leaks.length * 0.2).floor().clamp(0, leaks.length - 1);
      final base = leaks.isEmpty ? 0.0 : leaks[idx];
      return (intercept: base, slope: 0.0, baselineAtMedianPressure: base);
    }

    // Bin by pressure (0.5 cmH2O steps), take lower-envelope (20th percentile) per bin.
    const binSize = 0.5;
    final bins = <double, List<double>>{};
    for (final e in pairs) {
      final key = (e.p / binSize).roundToDouble() * binSize;
      (bins[key] ??= <double>[]).add(e.leak);
    }

    final xs = <double>[];
    final ys = <double>[];
    for (final entry in bins.entries) {
      final v = entry.value;
      if (v.length < 4) continue; // too sparse
      v.sort();
      final idx = (v.length * 0.2).floor().clamp(0, v.length - 1);
      xs.add(entry.key);
      ys.add(v[idx]);
    }

    if (xs.length < 2) {
      final leaks = pairs.map((e) => e.leak).toList()..sort();
      final idx = (leaks.length * 0.2).floor().clamp(0, leaks.length - 1);
      final base = leaks.isEmpty ? 0.0 : leaks[idx];
      return (intercept: base, slope: 0.0, baselineAtMedianPressure: base);
    }

    // Simple least-squares fit: leak = a + b * pressure
    final n = xs.length;
    double sumX = 0, sumY = 0, sumXX = 0, sumXY = 0;
    for (int i = 0; i < n; i++) {
      final x = xs[i];
      final y = ys[i];
      sumX += x;
      sumY += y;
      sumXX += x * x;
      sumXY += x * y;
    }
    final denom = (n * sumXX - sumX * sumX);
    final slope = denom.abs() < 1e-9 ? 0.0 : (n * sumXY - sumX * sumY) / denom;
    final intercept = (sumY - slope * sumX) / n;

    // Baseline at median pressure in the pairs.
    final ps = pairs.map((e) => e.p).toList()..sort();
    final pMed = ps[ps.length ~/ 2];
    final baseAtMed = (intercept + slope * pMed).clamp(0.0, double.infinity);

    return (
      intercept: intercept,
      slope: slope,
      baselineAtMedianPressure: baseAtMed,
    );
  }
  Prs1DailyBucket freeze() {
    return Prs1DailyBucket(
      day: day,
      slices: List.unmodifiable(slices),
      events: List.unmodifiable(events),
      pressureSamples: List.unmodifiable(pressureSamples),
      exhalePressureSamples: List.unmodifiable(exhalePressureSamples),
      leakSamples: List.unmodifiable(leakSamples),
      unintentionalLeakSamples: List.unmodifiable(unintentionalLeakSamples),
      leakBaselineLpm: leakBaselineLpm,
      largeLeakThresholdLpm: largeLeakThresholdLpm,
      flowSamples: List.unmodifiable(flowSamples),
      flexSamples: List.unmodifiable(flexSamples),
      usageSeconds: usageSeconds,
      eventCounts: Map.unmodifiable(counts),
      ahi: ahi,
      snoreCount: snoreCount,
      snorePerHour: snorePerHour,
      flexDutyCycle: flexDutyCycle,
      pressureMin: pressureMin,
      pressureMedian: pressureMedian,
      pressureP95: pressureP95,
      pressureMax: pressureMax,
      epapMin: epapMin,
      epapMedian: epapMedian,
      epapP95: epapP95,
      epapMax: epapMax,
      pressureOscarMin: pressureOscarMin,
      pressureOscarMedian: pressureOscarMedian,
      pressureOscarP95: pressureOscarP95,
      pressureOscarMax: pressureOscarMax,
      pressureBiasPctMin: pressureBiasPctMin,
      pressureBiasPctMedian: pressureBiasPctMedian,
      pressureBiasPctP95: pressureBiasPctP95,
      pressureBiasPctMax: pressureBiasPctMax,
      leakMedian: leakMedian,
      leakP95: leakP95,
      leakMin: leakMin,
      leakMax: leakMax,
      leakPercentOverThreshold: leakPercentOver,
      tidalVolumeMedian: tidalVolumeMedian,
      tidalVolumeP95: tidalVolumeP95,
      // Min/Max are not yet explicitly decoded; for now we approximate with
      // available stats so the engine and UI remain functional.
      tidalVolumeMin: tidalVolumeMin,
      tidalVolumeMax: tidalVolumeMax,
      respRateMedian: respRateMedian,
      respRateP95: respRateP95,
      respRateMin: respRateMin,
      respRateMax: respRateMax,
      minuteVentMedian: minuteVentMedian,
      minuteVentP95: minuteVentP95,
      minuteVentMin: minuteVentMin,
      minuteVentMax: minuteVentMax,
      minuteVentOscarMin: null,
      minuteVentOscarMedian: null,
      minuteVentOscarP95: null,
      minuteVentOscarMax: null,
      minuteVentBiasPctMin: null,
      minuteVentBiasPctMedian: null,
      minuteVentBiasPctP95: null,
      minuteVentBiasPctMax: null,
      inspTimeMedian: inspTimeMedian,
      inspTimeP95: inspTimeP95,
      inspTimeMin: inspTimeMin,
      inspTimeMax: inspTimeMax,
      expTimeMedian: expTimeMedian,
      expTimeP95: expTimeP95,
      expTimeMin: expTimeMin,
      expTimeMax: expTimeMax,
      ieRatioMedian: ieRatioMedian,
      ieRatioP95: ieRatioP95,
      ieRatioMin: ieRatioMin,
      ieRatioMax: ieRatioMax,
      flowLimitationMedian: flowLimitationMedian,
      flowLimitationP95: flowLimitationP95,
      flowLimitationMin: flowLimitationMedian,
      flowLimitationMax: (flowLimitationP95 ?? flowLimitationMedian),
      flowLimitationSeries: List.unmodifiable(flowLimitationSeries),
      flowLimitation1mMedianSeries: List.unmodifiable(flowLimitation1mMedianSeries),
      flowLimitation5mEmaSeries: List.unmodifiable(flowLimitation5mEmaSeries),
      flowLimitation15mEmaSeries: List.unmodifiable(flowLimitation15mEmaSeries),
      flowLimitationSeverityBands5mEma: List.unmodifiable(flowLimitationSeverityBands5mEma),
      flowLimitationSeverityBands15mEma: List.unmodifiable(flowLimitationSeverityBands15mEma),
      snoreHeatmap1mCounts: List.unmodifiable(snoreHeatmap1mCounts),
      snoreHeatmap1mMaxCount: snoreHeatmap1mMaxCount,
      snoreEpisodes: List.unmodifiable(snoreEpisodes),
      snoreEpisodeCount: snoreEpisodeCount,
      snoreEpisodeTotalSeconds: snoreEpisodeTotalSeconds,
      snoreEpisodeMaxPeakDensityPerMin: snoreEpisodeMaxPeakDensityPerMin,
      leakEpisodes: List.unmodifiable(leakEpisodes),
      leakEpisodeCount: leakEpisodeCount,
      leakEpisodeTotalSeconds: leakEpisodeTotalSeconds,
      episodeLinks: List.unmodifiable(episodeLinks),
      episodeCorrelationSummary: episodeCorrelationSummary,
      rollingAhi5m: List.unmodifiable(rollingAhi5m),
      rollingAhi10m: List.unmodifiable(rollingAhi10m),
      rollingAhi30m: List.unmodifiable(rollingAhi30m),
    );
  }
}