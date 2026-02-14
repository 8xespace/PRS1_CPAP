// lib/features/prs1/aggregate/prs1_trend_models.dart

import '../model/prs1_event.dart';
import 'prs1_daily_models.dart';

/// Weekly aggregation bucket (calendar week, ISO-8601 Monday start).
class Prs1WeeklyBucket {
  const Prs1WeeklyBucket({
    required this.weekStart,
    required this.weekEndExclusive,
    required this.days,
    required this.usageSeconds,
    required this.eventCounts,
    required this.ahi,
    required this.snoreCount,
    required this.pressureMedian,
    required this.pressureP95,
    required this.leakMedian,
    required this.leakP95,
    required this.leakPercentOverThreshold,
  });

  /// Local week start (Monday 00:00).
  final DateTime weekStart;

  /// weekStart + 7 days.
  final DateTime weekEndExclusive;

  /// Daily buckets in this week.
  final List<Prs1DailyBucket> days;

  /// Total usage time in seconds for the week.
  final int usageSeconds;

  /// Sum of event counts across the week.
  final Map<Prs1EventType, int> eventCounts;

  /// Weekly AHI recomputed from total (OA+CA+H) / hoursUsed.
  final double? ahi;

  final int snoreCount;

  /// Trend stats (usage-weighted mean of daily stats, if present).
  final double? pressureMedian;
  final double? pressureP95;

  final double? leakMedian;
  final double? leakP95;

  /// Usage-weighted mean of daily % over threshold.
  final double? leakPercentOverThreshold;
}

/// Monthly aggregation bucket (calendar month).
class Prs1MonthlyBucket {
  const Prs1MonthlyBucket({
    required this.monthStart,
    required this.monthEndExclusive,
    required this.days,
    required this.usageSeconds,
    required this.eventCounts,
    required this.ahi,
    required this.snoreCount,
    required this.pressureMedian,
    required this.pressureP95,
    required this.leakMedian,
    required this.leakP95,
    required this.leakPercentOverThreshold,
  });

  /// Local month start (YYYY-MM-01 00:00).
  final DateTime monthStart;

  /// First day of next month (exclusive).
  final DateTime monthEndExclusive;

  final List<Prs1DailyBucket> days;
  final int usageSeconds;
  final Map<Prs1EventType, int> eventCounts;
  final double? ahi;
  final int snoreCount;

  /// Trend stats (usage-weighted mean of daily stats, if present).
  final double? pressureMedian;
  final double? pressureP95;

  final double? leakMedian;
  final double? leakP95;

  final double? leakPercentOverThreshold;
}
