// lib/features/record_store/cpap_record_models.dart

class CpapDailyStats {
  const CpapDailyStats({
    required this.dateKey,
    this.ahi,
    this.usageMinutes,
    this.leakP95,
    this.pressureP95,
    this.flowLimitationP95,
    required this.updatedAtMs,
  });

  final String dateKey; // YYYY-MM-DD (local day bucket)
  final double? ahi;
  final double? usageMinutes;
  final double? leakP95;
  final double? pressureP95;
  final double? flowLimitationP95;
  final int updatedAtMs;

  Map<String, dynamic> toJson() => {
        'dateKey': dateKey,
        'ahi': ahi,
        'usageMinutes': usageMinutes,
        'leakP95': leakP95,
        'pressureP95': pressureP95,
        'flowLimitationP95': flowLimitationP95,
        'updatedAtMs': updatedAtMs,
      };

  static CpapDailyStats fromJson(Map<String, dynamic> m) => CpapDailyStats(
        dateKey: (m['dateKey'] as String?) ?? '',
        ahi: (m['ahi'] as num?)?.toDouble(),
        usageMinutes: (m['usageMinutes'] as num?)?.toDouble(),
        leakP95: (m['leakP95'] as num?)?.toDouble(),
        pressureP95: (m['pressureP95'] as num?)?.toDouble(),
        flowLimitationP95: (m['flowLimitationP95'] as num?)?.toDouble(),
        updatedAtMs: (m['updatedAtMs'] as num?)?.toInt() ?? 0,
      );
}

class CpapSessionMeta {
  const CpapSessionMeta({
    required this.sessionId,
    required this.startMs,
    required this.endMs,
    this.sourceLabel,
  });

  final String sessionId;
  final int startMs;
  final int endMs;
  final String? sourceLabel;

  Map<String, dynamic> toJson() => {
        'sessionId': sessionId,
        'startMs': startMs,
        'endMs': endMs,
        'sourceLabel': sourceLabel,
      };

  static CpapSessionMeta fromJson(Map<String, dynamic> m) => CpapSessionMeta(
        sessionId: (m['sessionId'] as String?) ?? '',
        startMs: (m['startMs'] as num?)?.toInt() ?? 0,
        endMs: (m['endMs'] as num?)?.toInt() ?? 0,
        sourceLabel: m['sourceLabel'] as String?,
      );
}
