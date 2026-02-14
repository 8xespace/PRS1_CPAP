// Auto-generated modular stats engine
// Module: 呼吸中止指數

import 'stat_result.dart';
import 'stat_utils.dart';

class StatJAhi {
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
