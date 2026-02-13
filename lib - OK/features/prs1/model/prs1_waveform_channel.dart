// lib/features/prs1/model/prs1_waveform_channel.dart
//
// High-rate waveform container (Milestone D).
// Stores scaled physical units at the channel's native sample rate.

import 'dart:typed_data';

class Prs1WaveformChannel {
  const Prs1WaveformChannel({
    required this.startEpochMs,
    required this.sampleRateHz,
    required this.samples,
    required this.unit,
    required this.label,
  });

  final int startEpochMs;
  final double sampleRateHz;

  /// Scaled physical values. Use Float32List to keep memory bounded.
  final Float32List samples;

  /// Physical unit string from EDF header (e.g., 'L/min', 'cmH2O').
  final String unit;

  /// Original EDF label (trimmed).
  final String label;

  int get length => samples.length;

  /// Epoch milliseconds for a given sample index.
  int epochMsAt(int index) => startEpochMs + (index * 1000.0 / sampleRateHz).round();

  /// Epoch seconds for a given sample index.
  int epochSecAt(int index) => (epochMsAt(index) / 1000).floor();

  /// Returns an approximate end epoch ms (exclusive).
  int get endEpochMsExclusive => epochMsAt(samples.length);
}
