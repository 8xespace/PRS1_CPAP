// lib/features/prs1/aggregate/prs1_trend_aggregator.dart
//
// Layer 7: Weekly / Monthly Aggregation (OSCAR-style trend layer).
//
// Input: Layer 6 daily buckets (already time-bucketed).
// Output: calendar weekly (ISO Monday-start) and monthly buckets.
//
// Notes:
// - Weekly buckets: ISO-8601 week, Monday 00:00 local time.
// - Monthly buckets: calendar month.
// - AHI is recomputed from aggregated events / aggregated usage hours.
// - Other metrics are trend-friendly approximations (usage-weighted mean of daily stats).
//   This matches common UI expectations where the trend chart plots daily summaries.

import '../model/prs1_event.dart';
import 'prs1_daily_models.dart';
import 'prs1_trend_models.dart';

class Prs1TrendAggregator {
  const Prs1TrendAggregator();

  DateTime _weekStart(DateTime day) {
    // ISO Monday start: weekday 1 = Monday ... 7 = Sunday
    final d = DateTime(day.year, day.month, day.day);
    final diff = d.weekday - DateTime.monday;
    return d.subtract(Duration(days: diff));
  }

  DateTime _monthStart(DateTime day) => DateTime(day.year, day.month, 1);

  List<Prs1WeeklyBucket> buildWeekly(List<Prs1DailyBucket> daily) {
    if (daily.isEmpty) return const [];
    final map = <DateTime, List<Prs1DailyBucket>>{};
    for (final d in daily) {
      final key = _weekStart(d.day);
      (map[key] ??= <Prs1DailyBucket>[]).add(d);
    }

    final keys = map.keys.toList()..sort();
    return keys.map((k) => _buildWeek(k, map[k]!)).toList(growable: false);
  }

  List<Prs1MonthlyBucket> buildMonthly(List<Prs1DailyBucket> daily) {
    if (daily.isEmpty) return const [];
    final map = <DateTime, List<Prs1DailyBucket>>{};
    for (final d in daily) {
      final key = _monthStart(d.day);
      (map[key] ??= <Prs1DailyBucket>[]).add(d);
    }

    final keys = map.keys.toList()..sort();
    return keys.map((k) => _buildMonth(k, map[k]!)).toList(growable: false);
  }

  Prs1WeeklyBucket _buildWeek(DateTime weekStart, List<Prs1DailyBucket> days) {
    days.sort((a, b) => a.day.compareTo(b.day));
    final weekEndExclusive = weekStart.add(const Duration(days: 7));

    final usageSeconds = days.fold<int>(0, (p, d) => p + d.usageSeconds);

    final eventCounts = <Prs1EventType, int>{};
    for (final d in days) {
      d.eventCounts.forEach((t, c) {
        eventCounts[t] = (eventCounts[t] ?? 0) + c;
      });
    }

    final ahi = _recomputeAhi(eventCounts, usageSeconds);
    final snoreCount = eventCounts[Prs1EventType.snore] ?? 0;

    final pressureMedian = _usageWeightedMean(days.map((d) => _W(d.pressureMedian, d.usageSeconds)));
    final pressureP95 = _usageWeightedMean(days.map((d) => _W(d.pressureP95, d.usageSeconds)));

    final leakMedian = _usageWeightedMean(days.map((d) => _W(d.leakMedian, d.usageSeconds)));
    final leakP95 = _usageWeightedMean(days.map((d) => _W(d.leakP95, d.usageSeconds)));
    final leakPctOver = _usageWeightedMean(days.map((d) => _W(d.leakPercentOverThreshold, d.usageSeconds)));

    return Prs1WeeklyBucket(
      weekStart: weekStart,
      weekEndExclusive: weekEndExclusive,
      days: List.unmodifiable(days),
      usageSeconds: usageSeconds,
      eventCounts: Map.unmodifiable(eventCounts),
      ahi: ahi,
      snoreCount: snoreCount,
      pressureMedian: pressureMedian,
      pressureP95: pressureP95,
      leakMedian: leakMedian,
      leakP95: leakP95,
      leakPercentOverThreshold: leakPctOver,
    );
  }

  Prs1MonthlyBucket _buildMonth(DateTime monthStart, List<Prs1DailyBucket> days) {
    days.sort((a, b) => a.day.compareTo(b.day));
    final monthEndExclusive = (monthStart.month == 12)
        ? DateTime(monthStart.year + 1, 1, 1)
        : DateTime(monthStart.year, monthStart.month + 1, 1);

    final usageSeconds = days.fold<int>(0, (p, d) => p + d.usageSeconds);

    final eventCounts = <Prs1EventType, int>{};
    for (final d in days) {
      d.eventCounts.forEach((t, c) {
        eventCounts[t] = (eventCounts[t] ?? 0) + c;
      });
    }

    final ahi = _recomputeAhi(eventCounts, usageSeconds);
    final snoreCount = eventCounts[Prs1EventType.snore] ?? 0;

    final pressureMedian = _usageWeightedMean(days.map((d) => _W(d.pressureMedian, d.usageSeconds)));
    final pressureP95 = _usageWeightedMean(days.map((d) => _W(d.pressureP95, d.usageSeconds)));

    final leakMedian = _usageWeightedMean(days.map((d) => _W(d.leakMedian, d.usageSeconds)));
    final leakP95 = _usageWeightedMean(days.map((d) => _W(d.leakP95, d.usageSeconds)));
    final leakPctOver = _usageWeightedMean(days.map((d) => _W(d.leakPercentOverThreshold, d.usageSeconds)));

    return Prs1MonthlyBucket(
      monthStart: monthStart,
      monthEndExclusive: monthEndExclusive,
      days: List.unmodifiable(days),
      usageSeconds: usageSeconds,
      eventCounts: Map.unmodifiable(eventCounts),
      ahi: ahi,
      snoreCount: snoreCount,
      pressureMedian: pressureMedian,
      pressureP95: pressureP95,
      leakMedian: leakMedian,
      leakP95: leakP95,
      leakPercentOverThreshold: leakPctOver,
    );
  }

  double? _recomputeAhi(Map<Prs1EventType, int> counts, int usageSeconds) {
    if (usageSeconds <= 0) return null;
    // AHI is defined as (apneas + hypopneas) / hour.
    // In our current taxonomy, the relevant types are:
    // - obstructiveApnea (OA)
    // - clearAirwayApnea (CA)
    // - hypopnea (H)
    final oa = counts[Prs1EventType.obstructiveApnea] ?? 0;
    final ca = counts[Prs1EventType.clearAirwayApnea] ?? 0;
    final h = counts[Prs1EventType.hypopnea] ?? 0;
    final hours = usageSeconds / 3600.0;
    if (hours <= 0) return null;
    return (oa + ca + h) / hours;
  }

  double? _usageWeightedMean(Iterable<_W> items) {
    double sum = 0;
    int wsum = 0;
    for (final it in items) {
      if (it.v == null) continue;
      if (it.w <= 0) continue;
      sum += it.v! * it.w;
      wsum += it.w;
    }
    if (wsum <= 0) return null;
    return sum / wsum;
  }
}

class _W {
  const _W(this.v, this.w);
  final double? v;
  final int w;
}
