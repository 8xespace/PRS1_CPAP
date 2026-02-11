// lib/features/prs1/stats/prs1_breath_analyzer.dart
//
// Milestone E: Breath segmentation and derived metrics from flow waveform.
//
// Assumptions:
// - Flow waveform unit is L/min (common). If different, caller should normalize.
// - We use a simple zero-crossing based segmentation:
//   * inspiration starts: flow crosses from <=0 to >0
//   * inspiration ends:  flow crosses from >=0 to <0
//   * breath ends: next inspiration start
//
// This is a conservative baseline that is easy to maintain and fast enough for Web.

import 'dart:math' as math;
import 'package:tophome/core/constants.dart';

import '../model/prs1_breath.dart';
import '../model/prs1_waveform_channel.dart';

class Prs1BreathAnalyzer {
  /// Segment breaths from a flow waveform.
  ///
  /// [minBreathSec]/[maxBreathSec] help reject garbage or gaps.
  /// [minInspSec] helps avoid tiny spikes.
  static List<Prs1Breath> segmentBreaths(
    Prs1WaveformChannel flow, {
    Prs1WaveformChannel? leak,
    double leakOverThreshold = 24.0,
    double leakRejectFraction = 0.5,

    double minBreathSec = 1.0,
    double maxBreathSec = 12.0,
    double minInspSec = 0.3,
    double zeroEps = 0.01,
  }) {
    if (flow.length < 3) return const [];
    final sr = flow.sampleRateHz;
    if (sr <= 0) return const [];
    final dt = 1.0 / sr;

    // --- OSCAR-aligned preprocessing (DreamStation/PRS1) ---
    // 1) Baseline (DC) offset correction: estimate median of a subsample and subtract.
    // 2) Noise deadband: derive a robust epsilon from low-percentile absolute deviation to reduce spurious crossings.
    //
    // This keeps architecture unchanged (still waveform-derived MV/RR/TV), but improves
    // breath segmentation stability and brings RR/TV closer to OSCAR.
    double _percentileSorted(List<double> sorted, double p) {
      if (sorted.isEmpty) return double.nan;
      if (p <= 0) return sorted.first;
      if (p >= 100) return sorted.last;
      final n = sorted.length;
      final rank = (p / 100.0) * (n - 1);
      final lo = rank.floor();
      final hi = rank.ceil();
      if (lo == hi) return sorted[lo];
      final w = rank - lo;
      return sorted[lo] * (1.0 - w) + sorted[hi] * w;
    }

    // Subsample up to ~5000 points to bound CPU/memory on Web.
    final subsampleStep = math.max(1, (flow.length / 5000).floor());
    final subs = <double>[];
    for (int i = 0; i < flow.length; i += subsampleStep) {
      subs.add(flow.samples[i].toDouble());
    }
    subs.sort();
    final baseline = _percentileSorted(subs, 50.0);

    // Robust noise scale from absolute deviation around baseline.
    final absDev = <double>[];
    for (int i = 0; i < subs.length; i++) {
      absDev.add((subs[i] - baseline).abs());
    }
    absDev.sort();
    final noiseP10 = _percentileSorted(absDev, 10.0);
    final adaptiveZeroEps = math.max(zeroEps, math.max(0.05, noiseP10 * 1.5));

    
// Leak-aware: map a flow sample index to an approximate leak value (L/min) if provided.
double leakAtFlowIndex(int flowIndex) {
  if (leak == null || leak!.length == 0 || leak!.sampleRateHz <= 0) return double.nan;
  final ms = flow.epochMsAt(flowIndex);
  final relMs = ms - leak!.startEpochMs;
  if (relMs < 0) return leak!.samples.first.toDouble();
  final li = (relMs * leak!.sampleRateHz / 1000.0).round();
  final idx = li.clamp(0, leak!.length - 1);
  return leak!.samples[idx].toDouble();
}

// Optional light smoothing: 3-sample moving average (cheap).
    double smoothedAt(int i) {
      final a = flow.samples[math.max(0, i - 1)];
      final b = flow.samples[i];
      final c = flow.samples[math.min(flow.length - 1, i + 1)];
      final v = (a + b + c) / 3.0;

      // Baseline correction.
      final vc = v - baseline;

      // Deadband to suppress noise-induced crossings near zero.
      // When leak is high, expand the deadband a bit to reduce spurious zero-crossings.
      double eps = adaptiveZeroEps;
      final lv = leakAtFlowIndex(i);
      if (!lv.isNaN && lv > leakOverThreshold) {
        // Scale modestly with leak excess; tuned conservatively.
        eps *= (1.0 + (lv - leakOverThreshold) * 0.02).clamp(1.0, 3.0);
      }
      if (vc.abs() < eps) return 0.0;
      return vc;
    }

    bool isPos(double v) => v > adaptiveZeroEps;
    bool isNeg(double v) => v < -adaptiveZeroEps;

    final inspStarts = <int>[];
    final inspEnds = <int>[];

    // Find zero crossings.
    double prev = smoothedAt(0);
    for (int i = 1; i < flow.length; i++) {
      final cur = smoothedAt(i);

      // neg/zero -> pos : inspiration start
      if (!isPos(prev) && isPos(cur)) {
        inspStarts.add(i);
      }

      // pos/zero -> neg : inspiration end
      if (!isNeg(prev) && isNeg(cur)) {
        inspEnds.add(i);
      }

      prev = cur;
    }

    if (inspStarts.length < 2) return const [];

    // For each inspiration start, find the next inspiration end AFTER it.
    int endPtr = 0;
    final breaths = <Prs1Breath>[];

    for (int si = 0; si < inspStarts.length - 1; si++) {
      final sIdx = inspStarts[si];
      final nextSIdx = inspStarts[si + 1];

      // Advance endPtr to first end >= sIdx.
      while (endPtr < inspEnds.length && inspEnds[endPtr] <= sIdx) {
        endPtr++;
      }
      if (endPtr >= inspEnds.length) break;

      final eInspIdx = inspEnds[endPtr];
      if (eInspIdx >= nextSIdx) {
        // No valid inspiration end before next start.
        continue;
      }

      final breathDur = (nextSIdx - sIdx) * dt;
      if (breathDur < minBreathSec || breathDur > maxBreathSec) continue;

      final inspDur = (eInspIdx - sIdx) * dt;
      if (inspDur < minInspSec) continue;

      final expDur = math.max(0.0, breathDur - inspDur);
      if (expDur <= 0) continue;

if (expDur <= 0) continue;

// Leak-aware rejection: if leak is over threshold for a large fraction of this breath window,
// skip it to avoid inflating RR/MV due to artifacty crossings under large leak.
if (leak != null) {
  final startMs = flow.epochMsAt(sIdx);
  final endMs = flow.epochMsAt(nextSIdx);
  final relStart = startMs - leak!.startEpochMs;
  final relEnd = endMs - leak!.startEpochMs;
  if (relEnd > 0) {
    final li0 = (relStart * leak!.sampleRateHz / 1000.0).floor();
    final li1 = (relEnd * leak!.sampleRateHz / 1000.0).ceil();
    final a = li0.clamp(0, leak!.length - 1);
    final b = li1.clamp(0, leak!.length - 1);
    if (b > a) {
      int over = 0;
      final n = b - a + 1;
      for (int li = a; li <= b; li++) {
        final v = leak!.samples[li];
        if (v > leakOverThreshold) over++;
      }
      final frac = over / n;
      if (frac >= leakRejectFraction) {
        continue;
      }
    }
  }
}


      // Integrate positive flow over inspiration to get tidal volume.
      // Flow is L/min -> L/sec by /60. Use trapezoid on smoothed flow.
      double tvL = 0.0;
      double last = (smoothedAt(sIdx) * AppConstants.prs1FlowGain).clamp(0.0, double.infinity);
      for (int i = sIdx + 1; i <= eInspIdx; i++) {
        final v = (smoothedAt(i) * AppConstants.prs1FlowGain).clamp(0.0, double.infinity);
        final avg = (last + v) / 2.0;
        tvL += (avg / 60.0) * dt;
        last = v;
      }

      final rr = 60.0 / breathDur;
      final mv = tvL * rr;

      final startMs = flow.epochMsAt(sIdx);
      final inspEndMs = flow.epochMsAt(eInspIdx);
      final endMs = flow.epochMsAt(nextSIdx);

      breaths.add(
        Prs1Breath(
          startEpochMs: startMs,
          inspEndEpochMs: inspEndMs,
          endEpochMs: endMs,
          tidalVolumeLiters: tvL,
          respRateBpm: rr,
          minuteVentilationLpm: mv,
          inspTimeSec: inspDur,
          expTimeSec: expDur,
          ieRatio: expDur > 0 ? (inspDur / expDur) : double.nan,
        ),
      );
    }

    return breaths;
  }
}
