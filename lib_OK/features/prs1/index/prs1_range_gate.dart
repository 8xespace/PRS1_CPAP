// lib/features/prs1/index/prs1_range_gate.dart

/// Hard range gate for Phase 1.
///
/// Any deep read/decode must be constrained to [allowedStart]..[allowedEnd].
class Prs1RangeGate {
  Prs1RangeGate({required this.allowedStart, required this.allowedEnd});

  final DateTime allowedStart;
  final DateTime allowedEnd;

  bool isAllowed(DateTime t) {
    return !t.isBefore(allowedStart) && !t.isAfter(allowedEnd);
  }

  @override
  String toString() => 'Prs1RangeGate(start=$allowedStart end=$allowedEnd)';
}
