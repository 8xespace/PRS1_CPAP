// lib/features/record_store/cpap_record_store.dart
//
// CPAP record continuity store:
// A) deviceId + dateKey -> daily stats bucket (5 key indicators)
// B) deviceId + sessionId -> raw session meta (optional)
//
// Web persistence: localStorage
// iOS/Android persistence: currently stubbed (safe no-op), can be wired later.

import 'dart:convert';

import '../prs1/aggregate/prs1_daily_models.dart';
import '../prs1/model/prs1_session.dart';
import 'cpap_record_keys.dart';
import 'cpap_record_models.dart';
import 'store_backend.dart';

class CpapRecordStore {
  CpapRecordStore._();

  static final CpapRecordStore I = CpapRecordStore._();

  final StoreBackend _backend = createStoreBackend();

  bool _loaded = false;

  // deviceId -> dateKey -> stats
  final Map<String, Map<String, CpapDailyStats>> _dailyByDevice = {};

  // deviceId -> sessionId -> meta
  final Map<String, Map<String, CpapSessionMeta>> _sessionByDevice = {};

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    final raw = await _backend.loadJson();
    if (raw == null || raw.isEmpty) return;
    try {
      final root = jsonDecode(raw);
      if (root is! Map) return;

      final devices = root['devices'];
      if (devices is Map) {
        for (final entry in devices.entries) {
          final deviceId = entry.key.toString();
          final dm = entry.value;
          if (dm is! Map) continue;

          final daily = <String, CpapDailyStats>{};
          final dailyMap = dm['daily'];
          if (dailyMap is Map) {
            for (final e in dailyMap.entries) {
              final dk = e.key.toString();
              final v = e.value;
              if (v is Map) {
                daily[dk] = CpapDailyStats.fromJson(Map<String, dynamic>.from(v));
              }
            }
          }

          final sess = <String, CpapSessionMeta>{};
          final sessMap = dm['sessions'];
          if (sessMap is Map) {
            for (final e in sessMap.entries) {
              final sid = e.key.toString();
              final v = e.value;
              if (v is Map) {
                sess[sid] = CpapSessionMeta.fromJson(Map<String, dynamic>.from(v));
              }
            }
          }

          if (daily.isNotEmpty) _dailyByDevice[deviceId] = daily;
          if (sess.isNotEmpty) _sessionByDevice[deviceId] = sess;
        }
      }
    } catch (_) {
      // swallow corrupted store
    }
  }

  Future<void> _flush() async {
    final root = <String, dynamic>{
      'version': 1,
      'devices': <String, dynamic>{},
    };

    final devices = root['devices'] as Map<String, dynamic>;
    for (final deviceId in {..._dailyByDevice.keys, ..._sessionByDevice.keys}) {
      final daily = _dailyByDevice[deviceId] ?? const {};
      final sess = _sessionByDevice[deviceId] ?? const {};
      devices[deviceId] = {
        'daily': {for (final e in daily.entries) e.key: e.value.toJson()},
        'sessions': {for (final e in sess.entries) e.key: e.value.toJson()},
      };
    }

    await _backend.saveJson(jsonEncode(root));
  }

  /// Upsert daily stats from engine buckets.
  ///
  /// Only stores the 5 key indicators:
  /// AHI, usage, leak p95, pressure p95, flow limitation p95.
  Future<void> upsertFromEngine({
    required String folderPath,
    required List<Prs1DailyBucket> dailyBuckets,
    required List<Prs1Session> sessions,
  }) async {
    await ensureLoaded();

    final deviceId = deriveDeviceIdFromFolderPath(folderPath);
    final dailyMap = _dailyByDevice.putIfAbsent(deviceId, () => {});
    final sessMap = _sessionByDevice.putIfAbsent(deviceId, () => {});

    final nowMs = DateTime.now().millisecondsSinceEpoch;

    for (final b in dailyBuckets) {
      final dk = dateKeyYmd(b.day);
      dailyMap[dk] = CpapDailyStats(
        dateKey: dk,
        ahi: b.ahi,
        usageMinutes: b.usageSeconds / 60.0,
        leakP95: b.leakP95,
        pressureP95: b.pressureP95,
        flowLimitationP95: b.flowLimitationP95,
        updatedAtMs: nowMs,
      );
    }

    // Optional session meta
    for (final s in sessions) {
      final sid = sessionIdFromRange(s.start, s.end, sourceLabel: s.sourceLabel);
      sessMap[sid] = CpapSessionMeta(
        sessionId: sid,
        startMs: s.start.millisecondsSinceEpoch,
        endMs: s.end.millisecondsSinceEpoch,
        sourceLabel: s.sourceLabel,
      );
    }

    await _flush();
  }

  List<CpapDailyStats> getLatestDailyStats({
    required String folderPath,
    required int days,
  }) {
    final deviceId = deriveDeviceIdFromFolderPath(folderPath);
    final daily = _dailyByDevice[deviceId];
    if (daily == null || daily.isEmpty) return const [];

    final items = daily.values.toList();
    items.sort((a, b) => b.dateKey.compareTo(a.dateKey)); // desc by YYYY-MM-DD
    if (items.length <= days) return items;
    return items.sublist(0, days);
  }
}
