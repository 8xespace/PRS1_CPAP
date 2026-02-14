// lib/features/record_store/cpap_record_keys.dart

/// Stable-ish device id derived from folder path (until native device serial is wired).
String deriveDeviceIdFromFolderPath(String folderPath) {
  // FNV-1a 32-bit hash (deterministic, no crypto package needed).
  const int fnvPrime = 16777619;
  int hash = 2166136261;
  for (final unit in folderPath.codeUnits) {
    hash ^= unit;
    hash = (hash * fnvPrime) & 0xFFFFFFFF;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}

String dateKeyYmd(DateTime dayLocalMidnight) {
  final y = dayLocalMidnight.year.toString().padLeft(4, '0');
  final m = dayLocalMidnight.month.toString().padLeft(2, '0');
  final d = dayLocalMidnight.day.toString().padLeft(2, '0');
  return '$y-$m-$d';
}

String sessionIdFromRange(DateTime start, DateTime end, {String? sourceLabel}) {
  final s = start.millisecondsSinceEpoch;
  final e = end.millisecondsSinceEpoch;
  final tag = (sourceLabel == null || sourceLabel.isEmpty) ? '' : '_$sourceLabel';
  return 's${s}_e${e}$tag';
}

String dailyKey(String deviceId, String dateKey) => '$deviceId|$dateKey';
String sessionKey(String deviceId, String sessionId) => '$deviceId|$sessionId';
