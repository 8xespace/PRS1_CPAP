// lib/features/prs1/model/prs1_event.dart

import 'dart:typed_data';

enum Prs1EventType {
  unknown,

  // Respiratory events
  obstructiveApnea,
  clearAirwayApnea,
  hypopnea,
  flowLimitation,
  snore,
  periodicBreathing,

  // Therapy/metrics
  largeLeak,
  pressureChange,

  // Continuous channels (future)
  pressureSample,
  leakSample,
  flowSample,
  flexActiveSample,
}

class Prs1Event {
  const Prs1Event({
    required this.time,
    required this.type,
    this.value,
    this.code,
    this.flags,
    this.crcOk,
    this.sourceOffset,
    this.raw,
  });

  final DateTime time;
  final Prs1EventType type;

  /// Numeric value (units depend on [type] and upstream parser).
  final num? value;

  /// Underlying PRS1 event code or record type (best-effort).
  final int? code;

  /// Best-effort flags field (if available).
  final int? flags;

  /// Whether the source record had a valid CRC (when CRC footer is present).
  final bool? crcOk;

  /// Offset in the blob where the source frame started (for debugging).
  final int? sourceOffset;

  /// Raw bytes of the decoded record (best-effort, may be truncated).
  final Uint8List? raw;
}