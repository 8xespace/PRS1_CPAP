// lib/features/prs1/debug/prs1_phase4_validate.dart
//
// Phase 4: numerical / statistical validation against OSCAR screenshots.
// This module is intentionally UI-light: it produces a deterministic text report.

import 'package:flutter/foundation.dart';
import '../aggregate/prs1_daily_models.dart';
import '../model/prs1_event.dart';
import '../model/prs1_signal_sample.dart';
import '../stats/prs1_rolling_metrics.dart';

class OscarReferenceNight {
  const OscarReferenceNight({
    required this.dayLocalMidnight,
    this.ahi,
    this.oaIndex,
    this.caIndex,
    this.hIndex,
    this.usageSeconds,
    this.pressureP95,
    this.epapP95,
    this.snoreIndex,
  });

  final DateTime dayLocalMidnight;

  // Indices (events/hour)
  final double? ahi;
  final double? oaIndex;
  final double? caIndex;
  final double? hIndex;

  // seconds used
  final int? usageSeconds;

  // Pressure summary (cmH2O)
  final double? pressureP95;
  final double? epapP95;

  // Snore index (events/hour) if available
  final double? snoreIndex;
}

class Prs1Phase4Validator {
  static final Map<String, OscarReferenceNight> _oscarRefs = {
    // From OSCAR screenshots shared in chat
    '2026-01-30': OscarReferenceNight(
      dayLocalMidnight: DateTime(2026, 1, 30),
      ahi: 0.35,
      caIndex: 0.12,
      oaIndex: 0.23,
      hIndex: 0.00,
      usageSeconds: 8 * 3600 + 35 * 60 + 20,
      pressureP95: 12.00,
      epapP95: 9.80,
    ),
    '2026-02-01': OscarReferenceNight(
      dayLocalMidnight: DateTime(2026, 2, 1),
      ahi: 0.66,
      oaIndex: 0.22,
      caIndex: 0.00,
      hIndex: 0.44,
      usageSeconds: 9 * 3600 + 5 * 60 + 41,
      pressureP95: 10.30,
      epapP95: 0.0, // unknown in screenshot; keep 0 to signal missing
    ),
    '2026-02-02': OscarReferenceNight(
      dayLocalMidnight: DateTime(2026, 2, 2),
      ahi: 1.17,
      oaIndex: 0.43,
      caIndex: 0.53,
      hIndex: 0.21,
      usageSeconds: 9 * 3600 + 21 * 60 + 56,
      pressureP95: 11.30,
      epapP95: 0.0,
    ),
  };

  static OscarReferenceNight? refForDay(DateTime localMidnight) {
    final key = _yyyyMmDd(localMidnight);
    return _oscarRefs[key];
  }

  static String buildReport({
    required Prs1DailyBucket bucket,
    required DateTime sessionStartLocal,
    required DateTime sessionEndLocal,
    int maxRollingSampleDump = 12,
  }) {
    final ref = refForDay(bucket.day);

    final usageS = bucket.usageSeconds;
    final usageH = usageS <= 0 ? 0.0 : usageS / 3600.0;

    int cnt(Prs1EventType t) => bucket.eventCounts[t] ?? 0;

    final oa = cnt(Prs1EventType.obstructiveApnea);
    final ca = cnt(Prs1EventType.clearAirwayApnea);
    final h = cnt(Prs1EventType.hypopnea);

    final derivedAhi = usageH > 0 ? (oa + ca + h) / usageH : double.nan;
    final derivedOaIdx = usageH > 0 ? oa / usageH : double.nan;
    final derivedCaIdx = usageH > 0 ? ca / usageH : double.nan;
    final derivedHIdx = usageH > 0 ? h / usageH : double.nan;

    final engineAhi = bucket.ahi;

    final snoreCount = bucket.snoreCount;
    final snoreIdx = usageH > 0 ? snoreCount / usageH : double.nan;

    final pP95 = bucket.pressureP95;
    final eP95 = bucket.epapP95;

    // Rolling AHI sanity
    final rolling = bucket.rollingAhi5m;
    final rollingMax = _maxFinite(
      rolling
          .map((e) => e.value)
          .whereType<double>()
          .where((v) => v.isFinite),
    );
    final rollingBad = rolling
        .where((e) => (e.value != null) && e.value!.isFinite && e.value! > 8.0)
        .toList();

    // Pressure histogram stats from samples as a cross-check.
    final pressStats = _weightedStatsFromSamples(bucket.pressureSamples);
    final epapStats = _weightedStatsFromSamples(bucket.exhalePressureSamples);

    final b = StringBuffer();
    b.writeln('=== Phase4 Validation Report ===');
    b.writeln('Day(local midnight): ${_yyyyMmDd(bucket.day)}');
    b.writeln('Session: ${_fmtHm(sessionStartLocal)} -> ${_fmtHm(sessionEndLocal)}  (duration=${_fmtHms(sessionEndLocal.difference(sessionStartLocal).inSeconds)})');
    b.writeln('UsageSeconds(bucket): $usageS  (usage=${_fmtHms(usageS)})');
    b.writeln('');

    b.writeln('[Events counts]');
    b.writeln('  OA=$oa  CA=$ca  H=$h  (total=${oa + ca + h})');
    b.writeln('');
    b.writeln('[Indices (events/hour)]');
    b.writeln('  AHI(derived)=${_f2(derivedAhi)}   OA=${_f2(derivedOaIdx)}  CA=${_f2(derivedCaIdx)}  H=${_f2(derivedHIdx)}');
    b.writeln('  AHI(engine)=${engineAhi == null ? 'null' : _f2(engineAhi)}');
    b.writeln('');

    b.writeln('[Snore]');
    b.writeln('  snoreCount=$snoreCount   snorePerHour(derived)=${_f2(snoreIdx)}   snorePerHour(engine)=${bucket.snorePerHour == null ? 'null' : _f2(bucket.snorePerHour)}');
    b.writeln('');

    b.writeln('[Pressure]');
    b.writeln('  p95(engine): IPAP=${pP95 == null ? 'null' : _f2(pP95)}  EPAP=${eP95 == null ? 'null' : _f2(eP95)}');
    b.writeln('  p95(from samples): IPAP=${pressStats.p95 == null ? 'null' : _f2(pressStats.p95)}  EPAP=${epapStats.p95 == null ? 'null' : _f2(epapStats.p95)}');
    b.writeln('');

    b.writeln('[Rolling AHI 5m]');
    b.writeln('  points=${rolling.length}  max=${rollingMax == null ? 'null' : _f2(rollingMax)}');
    if (rollingBad.isNotEmpty) {
      b.writeln('  WARNING: ${rollingBad.length} points > 8.0 (likely wrong window/denominator). Showing up to $maxRollingSampleDump:');
      for (final p in rollingBad.take(maxRollingSampleDump)) {
        final tLocal = DateTime.fromMillisecondsSinceEpoch(p.tEpochSec * 1000, isUtc: true).toLocal();
        b.writeln('    ${_fmtHm(tLocal)} -> ${_f2(p.value)}');
      }
    }
    b.writeln('');

    // Compare against OSCAR reference if available.
    if (ref != null) {
      b.writeln('--- OSCAR reference (${_yyyyMmDd(ref.dayLocalMidnight)}) ---');
      b.writeln('  AHI=${ref.ahi ?? 'n/a'}  OA=${ref.oaIndex ?? 'n/a'}  CA=${ref.caIndex ?? 'n/a'}  H=${ref.hIndex ?? 'n/a'}');
      b.writeln('  usage=${ref.usageSeconds == null ? 'n/a' : _fmtHms(ref.usageSeconds!)}');
      b.writeln('  p95(IPAP)=${ref.pressureP95 ?? 'n/a'}  p95(EPAP)=${(ref.epapP95 == null || ref.epapP95 == 0.0) ? 'n/a' : ref.epapP95}');
      b.writeln('');
      b.writeln('[Diff & tolerance]');
      final diffs = <String>[
        _cmp('usageSeconds', usageS.toDouble(), ref.usageSeconds?.toDouble(), absTol: 120.0, hint: 'bucket切分/跨午夜或資料過濾'),
        _cmp('AHI', derivedAhi, ref.ahi, absTol: 0.10, hint: '事件計數或分母(使用時長)'),
        _cmp('OA idx', derivedOaIdx, ref.oaIndex, absTol: 0.10, hint: 'OA 計數/分母'),
        _cmp('CA idx', derivedCaIdx, ref.caIndex, absTol: 0.10, hint: 'CA 計數/分母'),
        _cmp('H idx', derivedHIdx, ref.hIndex, absTol: 0.10, hint: 'H 計數/分母'),
        _cmp('p95 IPAP', (pP95 ?? pressStats.p95) ?? double.nan, ref.pressureP95, absTol: 0.30, hint: 'pressureSamples 或百分位算法'),
      ];
      for (final s in diffs) {
        b.writeln('  $s');
      }
      b.writeln('');
      b.writeln('[Notes]');
      b.writeln('  * 若 usageSeconds 差很多：先檢查 daily bucket 的跨午夜切分與「有效治療段」判定。');
      b.writeln('  * 若 counts 合理但 AHI 偏差：多半是分母 hours-used 或 events 去重規則。');
      b.writeln('  * 若 rolling AHI 常破表：通常是 rolling window 的「事件數/時間」定義不一致（例如用 5 分鐘事件數直接除以 5/60 小時，但事件本身已是 index）。');
    } else {
      b.writeln('--- OSCAR reference ---');
      b.writeln('  No built-in reference for this day. Add it to _oscarRefs in prs1_phase4_validate.dart if needed.');
    }

    return b.toString();
  }

  static String _cmp(String name, double v, double? ref, {required double absTol, required String hint}) {
    if (!v.isFinite) return '$name: value=NaN/Inf (cannot compare)';
    if (ref == null) return '$name: value=${_f2(v)}  ref=n/a';
    final diff = v - ref;
    final ok = diff.abs() <= absTol;
    final sign = diff >= 0 ? '+' : '-';
    return '$name: value=${_f2(v)}  ref=${_f2(ref)}  diff=$sign${_f2(diff.abs())}  tol=±${_f2(absTol)}  => ${ok ? 'OK' : 'CHECK'}  (${ok ? 'within' : hint})';
  }

  static String _yyyyMmDd(DateTime d) {
    final y = d.year.toString().padLeft(4, '0');
    final m = d.month.toString().padLeft(2, '0');
    final dd = d.day.toString().padLeft(2, '0');
    return '$y-$m-$dd';
  }

  static String _fmtHm(DateTime d) => '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  static String _fmtHms(int sec) {
    if (sec < 0) sec = 0;
    final h = sec ~/ 3600;
    final m = (sec % 3600) ~/ 60;
    final s = sec % 60;
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  static String _f2(double? v) {
    if (v == null) return 'null';
    if (!v.isFinite) return v.toString();
    return v.toStringAsFixed(2);
  }

  static double? _maxFinite(Iterable<double> xs) {
    double? m;
    for (final x in xs) {
      if (!x.isFinite) continue;
      if (m == null || x > m) m = x;
    }
    return m;
  }

  static _WeightedStats _weightedStatsFromSamples(List<Prs1SignalSample> samples) {
    if (samples.isEmpty) return const _WeightedStats();
    // Assume each sample represents 1 unit time. If timestamps are irregular, this is still
    // a useful cross-check against engine stats.
    final vals = <double>[];
    for (final s in samples) {
      final v = s.value;
      if (v.isFinite) vals.add(v);
    }
    if (vals.isEmpty) return const _WeightedStats();
    vals.sort();
    double quant(double q) {
      if (vals.isEmpty) return double.nan;
      final idx = (q * (vals.length - 1)).clamp(0, vals.length - 1).toDouble();
      final i0 = idx.floor();
      final i1 = idx.ceil();
      if (i0 == i1) return vals[i0];
      final t = idx - i0;
      return vals[i0] * (1 - t) + vals[i1] * t;
    }
    return _WeightedStats(
      min: vals.first,
      median: quant(0.5),
      p95: quant(0.95),
      max: vals.last,
      count: vals.length,
    );
  }
}

class _WeightedStats {
  const _WeightedStats({this.min, this.median, this.p95, this.max, this.count});

  final double? min;
  final double? median;
  final double? p95;
  final double? max;
  final int? count;
}
