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

import '../model/prs1_breath.dart';
import '../model/prs1_waveform_channel.dart';

class Prs1BreathAnalyzer {
  /// Segment breaths from a flow waveform.
  ///
  /// [minBreathSec]/[maxBreathSec] help reject garbage or gaps.
  /// [minInspSec] helps avoid tiny spikes.
  static List<Prs1Breath> segmentBreaths(
    Prs1WaveformChannel flow, {
    double minBreathSec = 1.0,
    double maxBreathSec = 12.0,
    double minInspSec = 0.3,
    double zeroEps = 0.01,
  }) {
    if (flow.length < 3) return const [];
    final sr = flow.sampleRateHz;
    if (sr <= 0) return const [];
    final dt = 1.0 / sr;

    // Optional light smoothing: 3-sample moving average (cheap).
    double smoothedAt(int i) {
      final a = flow.samples[math.max(0, i - 1)];
      final b = flow.samples[i];
      final c = flow.samples[math.min(flow.length - 1, i + 1)];
      return (a + b + c) / 3.0;
    }

    bool isPos(double v) => v > zeroEps;
    bool isNeg(double v) => v < -zeroEps;

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

      // Integrate positive flow over inspiration to get tidal volume.
      // Flow is L/min -> L/sec by /60. Use trapezoid on smoothed flow.
      double tvL = 0.0;
      double last = smoothedAt(sIdx).clamp(0.0, double.infinity);
      for (int i = sIdx + 1; i <= eInspIdx; i++) {
        final v = smoothedAt(i).clamp(0.0, double.infinity);
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
