// lib/features/prs1/waveform/prs1_waveform_viewport.dart
//
// Milestone G: viewport slicing + downsampling for waveform rendering.
// Strategy: min/max envelope per bucket (fast, stable, ideal for Web).

import 'dart:math' as math;

import 'prs1_waveform_index.dart';
import 'prs1_waveform_types.dart';

class Prs1WaveformViewport {
  /// Query a signal track for the given epoch-ms window and return an envelope
  /// with at most [maxBuckets] points (each point stores min/max).
  ///
  /// Gaps are represented as NaN min/max buckets.
  static List<Prs1MinMaxPoint> queryEnvelope({
    required Prs1WaveformIndex index,
    required Prs1WaveformSignal signal,
    required int startEpochMs,
    required int endEpochMsExclusive,
    required int maxBuckets,
  }) {
    if (endEpochMsExclusive <= startEpochMs || maxBuckets <= 0) return const [];

    final segs = index.track(signal);
    if (segs.isEmpty) {
      return _nanSeries(startEpochMs, endEpochMsExclusive, maxBuckets);
    }

    // Bucket width in ms (ceil to avoid zero).
    final windowMs = endEpochMsExclusive - startEpochMs;
    final bucketMs = math.max(1, (windowMs / maxBuckets).ceil());

    final out = <Prs1MinMaxPoint>[];

    // Iterate buckets; per bucket scan overlapping segments.
    int bStart = startEpochMs;
    while (bStart < endEpochMsExclusive) {
      final bEnd = math.min(endEpochMsExclusive, bStart + bucketMs);
      final mid = bStart + ((bEnd - bStart) ~/ 2);

      double minV = double.nan;
      double maxV = double.nan;

      // For each segment overlapping bucket, scan sample indices range.
      for (final seg in segs) {
        if (seg.endEpochMsExclusive <= bStart) continue;
        if (seg.startEpochMs >= bEnd) break;

        final s0 = math.max(bStart, seg.startEpochMs);
        final s1 = math.min(bEnd, seg.endEpochMsExclusive);

        // Convert to sample indices (inclusive start, exclusive end).
        int i0 = seg.indexAtEpochMs(s0);
        int i1 = seg.indexAtEpochMs(s1);
        if (i1 < i0) {
          final tmp = i0;
          i0 = i1;
          i1 = tmp;
        }
        // Ensure at least one sample.
        if (i1 == i0) i1 = math.min(seg.length - 1, i0 + 1);

        final samples = seg.channel.samples;
        for (int i = i0; i <= i1 && i < samples.length; i++) {
          final v = samples[i].toDouble();
          if (v.isNaN) continue;
          if (minV.isNaN || v < minV) minV = v;
          if (maxV.isNaN || v > maxV) maxV = v;
        }
      }

      out.add(Prs1MinMaxPoint(epochMs: mid, min: minV, max: maxV));
      bStart = bEnd;
    }

    return out;
  }

  static List<Prs1MinMaxPoint> _nanSeries(int startMs, int endMs, int maxBuckets) {
    if (endMs <= startMs || maxBuckets <= 0) return const [];
    final windowMs = endMs - startMs;
    final bucketMs = math.max(1, (windowMs / maxBuckets).ceil());
    final out = <Prs1MinMaxPoint>[];
    int bStart = startMs;
    while (bStart < endMs) {
      final bEnd = math.min(endMs, bStart + bucketMs);
      final mid = bStart + ((bEnd - bStart) ~/ 2);
      out.add(const Prs1MinMaxPoint(epochMs: 0, min: double.nan, max: double.nan)
          .copyWithEpoch(mid));
      bStart = bEnd;
    }
    return out;
  }
}

extension _MinMaxPointX on Prs1MinMaxPoint {
  Prs1MinMaxPoint copyWithEpoch(int epochMs) => Prs1MinMaxPoint(epochMs: epochMs, min: min, max: max);
}
