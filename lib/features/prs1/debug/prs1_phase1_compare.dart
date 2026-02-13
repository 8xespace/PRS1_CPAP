// lib/features/prs1/debug/prs1_phase1_compare.dart
//
// Phase 1: Data provenance verification + existence inventory (no UI plotting).
//
// This helper is intended for **development** and prints a consistent debug
// summary so we can compare PRS1.zip vs data.zip (or any two sources).

import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../decode/prs1_loader.dart';
import '../model/prs1_event.dart';
import '../model/prs1_session.dart';
import '../model/prs1_signal_sample.dart';
import '../aggregate/prs1_daily_aggregator.dart';
import '../aggregate/prs1_daily_models.dart';
import '../stats/prs1_rolling_metrics.dart';

typedef Phase1LogFn = void Function(String line);

class Prs1Phase1Summary {
  const Prs1Phase1Summary({
    required this.label,
    required this.prs1BlobCount,
    required this.parseFailures,
    required this.rawSessions,
    required this.mergedSessions,
    required this.targetDay,
    required this.bucketFound,
    required this.usageSeconds,
    required this.ahi,
    required this.eventCounts,
    required this.snoreCount,
    required this.snorePerHour,
    required this.pressureP95,
    required this.epapP95,
    required this.pressureSamplesN,
    required this.exhalePressureSamplesN,
    required this.pressureSpan,
    required this.exhalePressureSpan,
    required this.rollingAhi5mStats,
    required this.rollingAhi10mStats,
    required this.rollingAhi30mStats,
  });

  final String label;

  // Input stats
  final int prs1BlobCount;
  final int parseFailures;

  // Decode stats
  final int rawSessions;
  final int mergedSessions;

  // Target day
  final DateTime targetDay;
  final bool bucketFound;

  // Core daily stats
  final int usageSeconds;
  final double? ahi;
  final Map<Prs1EventType, int> eventCounts;

  // Snore
  final int snoreCount;
  final double? snorePerHour;

  // Pressure summary
  final double? pressureP95;
  final double? epapP95;
  final int pressureSamplesN;
  final int exhalePressureSamplesN;
  final _Span? pressureSpan;
  final _Span? exhalePressureSpan;

  // Rolling AHI
  final _SeriesStats? rollingAhi5mStats;
  final _SeriesStats? rollingAhi10mStats;
  final _SeriesStats? rollingAhi30mStats;

  
  static String _fmtD(double? v, int digits) {
    if (v == null) return 'null';
    if (v.isNaN) return 'NaN';
    return v.toStringAsFixed(digits);
  }

String toText() {
    final sb = StringBuffer();
    sb.writeln('===== Phase1 Summary: $label =====');
    sb.writeln('PRS1 blobs: $prs1BlobCount, parseFailures: $parseFailures');
    sb.writeln('Sessions: raw=$rawSessions, merged=$mergedSessions');
    sb.writeln('Target day: ${_fmtDay(targetDay)} bucketFound=$bucketFound');
    if (!bucketFound) {
      sb.writeln('(No bucket found for target day)');
      return sb.toString();
    }
    sb.writeln('usageSeconds=$usageSeconds  ahi=${_fmtD(ahi, 4)}');
    sb.writeln('eventCounts: ${_fmtEventCounts(eventCounts)}');
    sb.writeln('snoreCount=$snoreCount  snorePerHour=${_fmtD(snorePerHour, 4)}');
    sb.writeln('pressureP95=${_fmtD(pressureP95, 3)}  epapP95=${_fmtD(epapP95, 3)}');
    sb.writeln('pressureSamples=$pressureSamplesN span=${pressureSpan?.toText() ?? "n/a"}');
    sb.writeln('exhalePressureSamples=$exhalePressureSamplesN span=${exhalePressureSpan?.toText() ?? "n/a"}');
    sb.writeln('rollingAhi5m: ${rollingAhi5mStats?.toText() ?? "n/a"}');
    sb.writeln('rollingAhi10m: ${rollingAhi10mStats?.toText() ?? "n/a"}');
    sb.writeln('rollingAhi30m: ${rollingAhi30mStats?.toText() ?? "n/a"}');
    return sb.toString();
  }

  static String _fmtDay(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  static String _fmtEventCounts(Map<Prs1EventType, int> m) {
    final keys = m.keys.toList()..sort((a, b) => a.name.compareTo(b.name));
    return '{' + keys.map((k) => '${k.name}:${m[k]}').join(', ') + '}';
  }
}

class Prs1Phase1Compare {
  /// Run Phase 1 on two sources and print summaries + key diffs.
  ///
  /// This is intentionally synchronous-heavy (aggregation), so call it from a
  /// user-triggered async path (button) and consider showing a "computing" hint.
  static Future<void> runCompareFromPrs1Blobs({
    required String labelA,
    required Map<String, Uint8List> prs1BlobsA,
    required String labelB,
    required Map<String, Uint8List> prs1BlobsB,
    required DateTime targetDayLocalMidnight,
    required Phase1LogFn log,
  }) async {
    final a = _buildSummary(
      label: labelA,
      prs1Blobs: prs1BlobsA,
      targetDay: targetDayLocalMidnight,
      log: log,
    );
    final b = _buildSummary(
      label: labelB,
      prs1Blobs: prs1BlobsB,
      targetDay: targetDayLocalMidnight,
      log: log,
    );

    log(a.toText());
    log(b.toText());

    log('===== Phase1 Diff (A - B): $labelA vs $labelB =====');
    _printDiff(a, b, log);
  }

  static void _printDiff(Prs1Phase1Summary a, Prs1Phase1Summary b, Phase1LogFn log) {
    void numDiff(String k, num? av, num? bv) {
      if (av == null || bv == null) {
        log('$k: A=${av ?? "null"}  B=${bv ?? "null"}  diff=n/a');
        return;
      }
      final d = av - bv;
      log('$k: A=$av  B=$bv  diff=${d.toString()}');
    }

    numDiff('usageSeconds', a.usageSeconds, b.usageSeconds);
    numDiff('ahi', a.ahi, b.ahi);
    numDiff('snoreCount', a.snoreCount, b.snoreCount);
    numDiff('snorePerHour', a.snorePerHour, b.snorePerHour);
    numDiff('pressureP95', a.pressureP95, b.pressureP95);
    numDiff('epapP95', a.epapP95, b.epapP95);
    numDiff('pressureSamplesN', a.pressureSamplesN, b.pressureSamplesN);
    numDiff('exhalePressureSamplesN', a.exhalePressureSamplesN, b.exhalePressureSamplesN);

    // Event counts diff
    final allKeys = <Prs1EventType>{...a.eventCounts.keys, ...b.eventCounts.keys}.toList()
      ..sort((x, y) => x.name.compareTo(y.name));
    for (final k in allKeys) {
      final av = a.eventCounts[k] ?? 0;
      final bv = b.eventCounts[k] ?? 0;
      final d = av - bv;
      if (d != 0) log('eventCount.${k.name}: A=$av  B=$bv  diff=$d');
    }

    void seriesDiff(String k, _SeriesStats? as, _SeriesStats? bs) {
      if (as == null && bs == null) return;
      log('$k: A=${as?.toText() ?? "n/a"}  B=${bs?.toText() ?? "n/a"}');
    }

    seriesDiff('rollingAhi5m', a.rollingAhi5mStats, b.rollingAhi5mStats);
    seriesDiff('rollingAhi10m', a.rollingAhi10mStats, b.rollingAhi10mStats);
    seriesDiff('rollingAhi30m', a.rollingAhi30mStats, b.rollingAhi30mStats);
  }

  static Prs1Phase1Summary _buildSummary({
    required String label,
    required Map<String, Uint8List> prs1Blobs,
    required DateTime targetDay,
    required Phase1LogFn log,
  }) {
    final loader = Prs1Loader();
    final sessions = <Prs1Session>[];
    int failures = 0;

    for (final e in prs1Blobs.entries) {
      try {
        final res = loader.parse(e.value, sourcePath: e.key);
        if (res.sessions.isNotEmpty) sessions.addAll(res.sessions);
      } catch (err) {
        failures++;
      }
    }

    final merged = _mergePrs1Sessions(sessions);

    // Restrict to a small window around target day to keep Phase 1 fast and deterministic.
    final windowStart = targetDay.subtract(const Duration(days: 1));
    final windowEnd = targetDay.add(const Duration(days: 2));
    final windowSessions = merged.where((s) {
      // overlap [windowStart, windowEnd)
      return s.end.isAfter(windowStart) && s.start.isBefore(windowEnd);
    }).toList();

    final buckets = Prs1DailyAggregator().build(windowSessions);
    final dayBucket = buckets.where((b) => _sameDay(b.day, targetDay)).cast<Prs1DailyBucket?>().toList();
    final Prs1DailyBucket? b = dayBucket.isEmpty ? null : dayBucket.first;

    if (b == null) {
      return Prs1Phase1Summary(
        label: label,
        prs1BlobCount: prs1Blobs.length,
        parseFailures: failures,
        rawSessions: sessions.length,
        mergedSessions: merged.length,
        targetDay: targetDay,
        bucketFound: false,
        usageSeconds: 0,
        ahi: 0,
        eventCounts: const {},
        snoreCount: 0,
        snorePerHour: 0,
        pressureP95: 0,
        epapP95: 0,
        pressureSamplesN: 0,
        exhalePressureSamplesN: 0,
        pressureSpan: null,
        exhalePressureSpan: null,
        rollingAhi5mStats: null,
        rollingAhi10mStats: null,
        rollingAhi30mStats: null,
      );
    }

    final pressureSpan = _spanOf(b.pressureSamples);
    final epapSpan = _spanOf(b.exhalePressureSamples);

    return Prs1Phase1Summary(
      label: label,
      prs1BlobCount: prs1Blobs.length,
      parseFailures: failures,
      rawSessions: sessions.length,
      mergedSessions: merged.length,
      targetDay: targetDay,
      bucketFound: true,
      usageSeconds: b.usageSeconds,
      ahi: b.ahi,
      eventCounts: b.eventCounts,
      snoreCount: b.snoreCount,
      snorePerHour: b.snorePerHour,
      pressureP95: b.pressureP95,
      epapP95: b.epapP95,
      pressureSamplesN: b.pressureSamples.length,
      exhalePressureSamplesN: b.exhalePressureSamples.length,
      pressureSpan: pressureSpan,
      exhalePressureSpan: epapSpan,
      rollingAhi5mStats: _seriesStatsOfTimePoints(b.rollingAhi5m),
      rollingAhi10mStats: _seriesStatsOfTimePoints(b.rollingAhi10m),
      rollingAhi30mStats: _seriesStatsOfTimePoints(b.rollingAhi30m),
    );
  }

  static bool _sameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;

  static _Span? _spanOf(List<Prs1SignalSample> s) {
    if (s.isEmpty) return null;
    int minT = s.first.timestampMs;
    int maxT = s.first.timestampMs;
    for (final x in s) {
      minT = min(minT, x.timestampMs);
      maxT = max(maxT, x.timestampMs);
    }
    return _Span(minT, maxT);
  }

  
  static _SeriesStats? _seriesStatsOfSignal(List<Prs1SignalSample> s) {
    if (s.isEmpty) return null;
    double minV = s.first.value;
    double maxV = s.first.value;
    int minT = s.first.timestampMs;
    int maxT = s.first.timestampMs;
    for (final x in s) {
      minV = min(minV, x.value);
      maxV = max(maxV, x.value);
      minT = min(minT, x.timestampMs);
      maxT = max(maxT, x.timestampMs);
    }
    return _SeriesStats(n: s.length, minV: minV, maxV: maxV, span: _Span(minT, maxT));
  }

  static _SeriesStats? _seriesStatsOfTimePoints(List<Prs1TimePoint> s) {
    if (s.isEmpty) return null;
    double? minV;
    double? maxV;
    int? minT;
    int? maxT;

    for (final x in s) {
      final v = x.value;
      if (v == null) continue;
      minV = (minV == null) ? v : min(minV!, v);
      maxV = (maxV == null) ? v : max(maxV!, v);
      final tMs = x.tEpochSec * 1000;
      minT = (minT == null) ? tMs : min(minT!, tMs);
      maxT = (maxT == null) ? tMs : max(maxT!, tMs);
    }

    if (minV == null || maxV == null || minT == null || maxT == null) return null;
    final n = s.where((e) => e.value != null).length;
    return _SeriesStats(n: n, minV: minV!, maxV: maxV!, span: _Span(minT!, maxT!));
  }


  // Copied from HomePage to keep Phase 1 self-contained and reduce risk of regressions.
  static List<Prs1Session> _mergePrs1Sessions(List<Prs1Session> sessions) {
    String? keyOf(Prs1Session s) {
      final sp = s.sourcePath;
      if (sp == null || sp.isEmpty) return null;
      final m = RegExp(r'([0-9A-Fa-f]{8})\.(?:000|001|002|005)\b').firstMatch(sp);
      return m?.group(1)?.toLowerCase();
    }

    final Map<String, Prs1Session> byKey = <String, Prs1Session>{};
    final List<Prs1Session> passthrough = <Prs1Session>[];

    for (final s in sessions) {
      final k = keyOf(s);
      if (k == null) {
        passthrough.add(s);
        continue;
      }

      final prev = byKey[k];
      if (prev == null) {
        byKey[k] = s;
        continue;
      }

      // Merge fields conservatively: prefer non-empty / non-zero.
      final mergedStart = prev.start.isBefore(s.start) ? prev.start : s.start;
      final mergedEnd = prev.end.isAfter(s.end) ? prev.end : s.end;

      final mergedEvents = (prev.events.isNotEmpty) ? prev.events : s.events;

      List<Prs1SignalSample> pickLonger(List<Prs1SignalSample> a, List<Prs1SignalSample> b) =>
          (a.length >= b.length) ? a : b;

      final mergedPressure = pickLonger(prev.pressureSamples, s.pressureSamples);
      final mergedEpap = pickLonger(prev.exhalePressureSamples, s.exhalePressureSamples);
      final mergedLeak = pickLonger(prev.leakSamples, s.leakSamples);
      final mergedFlow = pickLonger(prev.flowSamples, s.flowSamples);
      final mergedFlex = pickLonger(prev.flexSamples, s.flexSamples);

      final merged = Prs1Session(
        start: mergedStart,
        end: mergedEnd,
        events: mergedEvents,
        pressureSamples: mergedPressure,
        exhalePressureSamples: mergedEpap,
        leakSamples: mergedLeak,
        flowSamples: mergedFlow,
        flexSamples: mergedFlex,
        breaths: (prev.breaths.isNotEmpty) ? prev.breaths : s.breaths,
        sourcePath: prev.sourcePath ?? s.sourcePath,
        sourceLabel: prev.sourceLabel ?? s.sourceLabel,
        minutesUsed: prev.minutesUsed ?? s.minutesUsed,
        pressureMin: prev.pressureMin ?? s.pressureMin,
        pressureMax: prev.pressureMax ?? s.pressureMax,
        leakMedian: prev.leakMedian ?? s.leakMedian,
        ahi: prev.ahi ?? s.ahi,
        flowWaveform: prev.flowWaveform ?? s.flowWaveform,
        pressureWaveform: prev.pressureWaveform ?? s.pressureWaveform,
        leakWaveform: prev.leakWaveform ?? s.leakWaveform,
        flexWaveform: prev.flexWaveform ?? s.flexWaveform,
      );

      byKey[k] = merged;
    }

    final out = <Prs1Session>[];
    out.addAll(byKey.values);
    out.addAll(passthrough);
    return out;
  }
}

class _Span {
  const _Span(this.tMinMs, this.tMaxMs);
  final int tMinMs;
  final int tMaxMs;

  String toText() {
    final a = DateTime.fromMillisecondsSinceEpoch(tMinMs, isUtc: true).toLocal();
    final b = DateTime.fromMillisecondsSinceEpoch(tMaxMs, isUtc: true).toLocal();
    return '${a.toIso8601String()} -> ${b.toIso8601String()}';
  }
}

class _SeriesStats {
  const _SeriesStats({
    required this.n,
    required this.minV,
    required this.maxV,
    required this.span,
  });

  final int n;
  final double minV;
  final double maxV;
  final _Span span;

  String toText() =>
      'n=$n min=${minV.toStringAsFixed(4)} max=${maxV.toStringAsFixed(4)} span=${span.toText()}';
}
