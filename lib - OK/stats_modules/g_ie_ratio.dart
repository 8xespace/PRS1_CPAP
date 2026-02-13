// Auto-generated modular stats engine
// Module: I:E 比

import 'stat_result.dart';
import 'stat_utils.dart';

class StatGIeRatio {
  StatResult compute(List<double> samples) {
    if (samples.isEmpty) return const StatResult();
    final s = List<double>.from(samples)..sort();
    double? q(double p) => statQuantileSorted(s, p);
    return StatResult(
      min: statMin(s),
      median: q(0.5),
      p95: q(0.95),
      max: statMax(s),
    );
  }
}
