// lib/features/prs1/model/prs1_signal_sample.dart

/// A single continuous-signal sample, referenced by absolute epoch seconds.
///
/// Milestone A (L8): we establish the *data channel* so that daily/weekly/monthly
/// aggregation can carry time-series samples (pressure/leak/flow) in addition to
/// events.
///
/// Notes:
/// - [tEpochSec] is expected to be UNIX epoch seconds.
/// - For bucketing we expose a convenient local-time [timeLocal].
class Prs1SignalSample {
  const Prs1SignalSample({
    required this.tEpochSec,
    required this.value,
    required this.signalType,
  });

  final int tEpochSec;
  final double value;
  final Prs1SignalType signalType;

  /// Local time derived from epoch seconds.
  ///
  /// If the device timestamps are already local, this will shift by timezone.
  /// We'll standardize the conversion behavior here and adjust later if we
  /// confirm a different PRS1 timestamp convention.
  DateTime get timeLocal => DateTime.fromMillisecondsSinceEpoch(tEpochSec * 1000, isUtc: true).toLocal();
}

enum Prs1SignalType {
  flowRate,
  pressure,
  leak,
  flexActive,
}
