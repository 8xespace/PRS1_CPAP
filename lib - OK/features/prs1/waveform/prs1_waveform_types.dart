// lib/features/prs1/waveform/prs1_waveform_types.dart
//
// Milestone G: viewport-ready waveform querying & downsampling primitives.
// UI-agnostic engine layer (Web/iOS friendly).

import 'dart:typed_data';

import '../model/prs1_waveform_channel.dart';

/// Logical waveform signal tracks we support for OSCAR-style overlay rendering.
enum Prs1WaveformSignal {
  flow,
  pressure,
  leak,
  flexActive,
}

/// A waveform segment: a contiguous block of samples at a native sample rate.
class Prs1WaveformSegment {
  const Prs1WaveformSegment({
    required this.signal,
    required this.channel,
  });

  final Prs1WaveformSignal signal;
  final Prs1WaveformChannel channel;

  int get startEpochMs => channel.startEpochMs;
  int get endEpochMsExclusive => channel.endEpochMsExclusive;
  double get sampleRateHz => channel.sampleRateHz;
  String get unit => channel.unit;
  String get label => channel.label;
  int get length => channel.length;

  /// Returns sample index (clamped) for a given epoch ms.
  int indexAtEpochMs(int epochMs) {
    final dtMs = epochMs - startEpochMs;
    final idx = (dtMs / 1000.0 * sampleRateHz).floor();
    if (idx < 0) return 0;
    if (idx >= length) return length - 1;
    return idx;
  }

  /// Epoch ms for a given sample index.
  int epochMsAt(int index) => channel.epochMsAt(index);
}

/// A min/max envelope point for efficient chart rendering.
///
/// We store both min and max for a bucket; chart layer can draw a vertical line
/// or band for each x coordinate.
class Prs1MinMaxPoint {
  const Prs1MinMaxPoint({
    required this.epochMs,
    required this.min,
    required this.max,
  });

  final int epochMs;

  /// If there is no data in this bucket, min/max are NaN.
  final double min;
  final double max;

  bool get hasData => !(min.isNaN || max.isNaN);
}

/// A time-value point (e.g., for events or rolling metrics).
class Prs1TimeValuePoint {
  const Prs1TimeValuePoint({required this.epochMs, required this.value});

  final int epochMs;
  final double value;
}

/// A time flag point (0/1) intended for overlay.
class Prs1TimeFlagPoint {
  const Prs1TimeFlagPoint({required this.epochMs, required this.isOn});

  final int epochMs;
  final bool isOn;
}
