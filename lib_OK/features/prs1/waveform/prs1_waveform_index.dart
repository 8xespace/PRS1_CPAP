// lib/features/prs1/waveform/prs1_waveform_index.dart
//
// Milestone G: multi-session, multi-channel waveform index (day-aligned).
// Provides a stable data structure for viewport queries without forcing a UI.
// Handles:
// - segment sorting & light boundary normalization
// - multi-session merge into a single timeline per signal
// - gap/NaN preservation (handled by viewport query)

import '../model/prs1_session.dart';
import '../model/prs1_waveform_channel.dart';
import 'prs1_waveform_types.dart';

class Prs1WaveformIndex {
  const Prs1WaveformIndex._(this._tracksBySignal);

  final Map<Prs1WaveformSignal, List<Prs1WaveformSegment>> _tracksBySignal;

  List<Prs1WaveformSegment> track(Prs1WaveformSignal signal) =>
      _tracksBySignal[signal] ?? const [];

  /// Returns earliest epochMs across all segments for a signal, or null if absent.
  int? minEpochMs(Prs1WaveformSignal signal) {
    final t = track(signal);
    if (t.isEmpty) return null;
    return t.first.startEpochMs;
  }

  /// Returns latest end epochMs across all segments for a signal, or null if absent.
  int? maxEpochMsExclusive(Prs1WaveformSignal signal) {
    final t = track(signal);
    if (t.isEmpty) return null;
    return t.last.endEpochMsExclusive;
  }

  bool get isEmpty => _tracksBySignal.values.every((v) => v.isEmpty);

  /// Build index from parsed sessions. Safe: ignores null waveforms.
  ///
  /// Boundary normalization:
  /// - Sort segments by startEpochMs per signal.
  /// - If two adjacent segments overlap by <= [maxOverlapMsSnap], we snap the
  ///   later segment to start at the previous end (trim prefix) to avoid
  ///   double-drawing.
  /// - If the gap between segments is <= [maxGapMsSnap], we snap the later
  ///   segment start to previous end to reduce small EDF record-boundary drift.
  static Prs1WaveformIndex build(
    List<Prs1Session> sessions, {
    int maxOverlapMsSnap = 1500,
    int maxGapMsSnap = 1500,
  }) {
    final by = <Prs1WaveformSignal, List<Prs1WaveformSegment>>{
      Prs1WaveformSignal.flow: <Prs1WaveformSegment>[],
      Prs1WaveformSignal.pressure: <Prs1WaveformSegment>[],
      Prs1WaveformSignal.leak: <Prs1WaveformSegment>[],
      Prs1WaveformSignal.flexActive: <Prs1WaveformSegment>[],
    };

    for (final s in sessions) {
      _addIf(by, Prs1WaveformSignal.flow, s.flowWaveform);
      _addIf(by, Prs1WaveformSignal.pressure, s.pressureWaveform);
      _addIf(by, Prs1WaveformSignal.leak, s.leakWaveform);
      _addIf(by, Prs1WaveformSignal.flexActive, s.flexWaveform);
    }

    // Sort and normalize per signal.
    final out = <Prs1WaveformSignal, List<Prs1WaveformSegment>>{};
    for (final entry in by.entries) {
      final segs = List<Prs1WaveformSegment>.from(entry.value);
      segs.sort((a, b) => a.startEpochMs.compareTo(b.startEpochMs));
      out[entry.key] = _normalizeBoundaries(
        segs,
        maxOverlapMsSnap: maxOverlapMsSnap,
        maxGapMsSnap: maxGapMsSnap,
      );
    }
    return Prs1WaveformIndex._(out);
  }

  static void _addIf(
    Map<Prs1WaveformSignal, List<Prs1WaveformSegment>> by,
    Prs1WaveformSignal signal,
    Prs1WaveformChannel? ch,
  ) {
    if (ch == null || ch.length == 0) return;
    by[signal]!.add(Prs1WaveformSegment(signal: signal, channel: ch));
  }

  static List<Prs1WaveformSegment> _normalizeBoundaries(
    List<Prs1WaveformSegment> segs, {
    required int maxOverlapMsSnap,
    required int maxGapMsSnap,
  }) {
    if (segs.length <= 1) return segs;

    final normalized = <Prs1WaveformSegment>[];
    Prs1WaveformSegment? prev;
    for (final cur in segs) {
      if (prev == null) {
        normalized.add(cur);
        prev = cur;
        continue;
      }
      final overlapMs = prev.endEpochMsExclusive - cur.startEpochMs;
      final gapMs = cur.startEpochMs - prev.endEpochMsExclusive;

      // Small overlap: trim the later segment prefix.
      if (overlapMs > 0 && overlapMs <= maxOverlapMsSnap) {
        final trimmed = _trimPrefixToEpochMs(cur, prev.endEpochMsExclusive);
        normalized.add(trimmed);
        prev = trimmed;
        continue;
      }

      // Small gap: snap start to previous end to reduce drift (no sample insert).
      if (gapMs > 0 && gapMs <= maxGapMsSnap) {
        final snapped = _snapStartToEpochMs(cur, prev.endEpochMsExclusive);
        normalized.add(snapped);
        prev = snapped;
        continue;
      }

      // Big overlap: keep both (viewport query prefers later segments when sampling).
      normalized.add(cur);
      prev = cur;
    }
    return normalized;
  }

  static Prs1WaveformSegment _trimPrefixToEpochMs(Prs1WaveformSegment seg, int newStartMs) {
    final ch = seg.channel;
    final sr = ch.sampleRateHz;
    final trimSamples = ((newStartMs - ch.startEpochMs) / 1000.0 * sr).round();
    if (trimSamples <= 0) return seg;
    if (trimSamples >= ch.samples.length) return seg;

    final sliced = ch.samples.sublist(trimSamples);
    final newCh = Prs1WaveformChannel(
      startEpochMs: newStartMs,
      sampleRateHz: sr,
      samples: sliced,
      unit: ch.unit,
      label: ch.label,
    );
    return Prs1WaveformSegment(signal: seg.signal, channel: newCh);
  }

  static Prs1WaveformSegment _snapStartToEpochMs(Prs1WaveformSegment seg, int newStartMs) {
    final ch = seg.channel;
    if (newStartMs == ch.startEpochMs) return seg;
    final newCh = Prs1WaveformChannel(
      startEpochMs: newStartMs,
      sampleRateHz: ch.sampleRateHz,
      samples: ch.samples,
      unit: ch.unit,
      label: ch.label,
    );
    return Prs1WaveformSegment(signal: seg.signal, channel: newCh);
  }
}
