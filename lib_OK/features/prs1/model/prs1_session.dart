// lib/features/prs1/model/prs1_session.dart

import 'prs1_event.dart';
import 'prs1_signal_sample.dart';
import 'prs1_waveform_channel.dart';
import 'prs1_breath.dart';

class Prs1Session {
  const Prs1Session({
    required this.start,
    required this.end,
    required this.events,
    this.pressureSamples = const [],
    this.leakSamples = const [],
    this.flowSamples = const [],
    this.flexSamples = const [],
    this.flowWaveform,
    this.pressureWaveform,
    this.leakWaveform,
    this.flexWaveform,
    this.breaths = const [],
    this.sourcePath,
    this.sourceLabel,
    this.minutesUsed,
    this.pressureMin,
    this.pressureMax,
    this.leakMedian,
    this.ahi,
  });

  final DateTime start;
  final DateTime end;
  final List<Prs1Event> events;

  /// Continuous signal samples (Milestone A / L8). These may be empty until the
  /// decoder layer is extended to extract time-series channels.
  final List<Prs1SignalSample> pressureSamples;
  final List<Prs1SignalSample> leakSamples;
  final List<Prs1SignalSample> flowSamples;

  /// Optional: boolean-like signal (0/1) indicating Flex active over time.
  final List<Prs1SignalSample> flexSamples;


  /// Optional high-rate waveforms (native sample rate).
  final Prs1WaveformChannel? flowWaveform;
  final Prs1WaveformChannel? pressureWaveform;
  final Prs1WaveformChannel? leakWaveform;

  /// Optional high-rate/flag waveform for Flex active (0/1).
  final Prs1WaveformChannel? flexWaveform;

  /// Breath-by-breath derived metrics (Milestone E). May be empty if flow waveform
  /// is unavailable or segmentation hasn't run.
  final List<Prs1Breath> breaths;


  final String? sourcePath;
  final String? sourceLabel;

  final int? minutesUsed;
  final double? pressureMin;
  final double? pressureMax;
  final double? leakMedian;
  final double? ahi;
}
