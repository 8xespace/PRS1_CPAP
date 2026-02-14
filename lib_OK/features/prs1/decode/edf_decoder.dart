// lib/features/prs1/decode/edf_decoder.dart

import 'dart:math' as math;
import 'dart:typed_data';

import '../../../core/logging.dart';
import '../model/prs1_session.dart';
import '../model/prs1_waveform_channel.dart';
import '../model/prs1_signal_sample.dart';

/// Minimal EDF/EDF+ header + selected signal decoder.
///
/// Current goals:
/// - Robustly identify EDF/EDF+ blobs
/// - Extract session start time & duration
/// - Decode a *small subset* of continuous channels (flow / pressure / leak / flex)
///   into [Prs1SignalSample] at ~1 Hz (time-weighted statistics friendly)
///
/// Notes:
/// - We intentionally downsample/decimate to a target rate to keep memory bounded
///   in Flutter Web sandbox runs.
/// - Scaling uses the classic EDF digital->physical mapping (physMin/Max, digMin/Max).
class EdfDecoder {
  /// Parse an EDF/EDF+ file into a [Prs1Session].
  ///
  /// If the file includes recognizable channel labels (pressure/leak/flow/flex),
  /// we decode and attach them as continuous samples.
  static Prs1Session? tryParseSession(Uint8List bytes, {String? sourcePath}) {
    if (bytes.length < 256) return null;

    // Version field is 8 ASCII characters; classic EDF uses "0       ".
    final version = _ascii(bytes, 0, 8).trim();
    if (version.isEmpty) return null;

    final startDate = _ascii(bytes, 168, 8).trim(); // dd.mm.yy
    final startTime = _ascii(bytes, 176, 8).trim(); // hh.mm.ss

    final headerBytesStr = _ascii(bytes, 184, 8).trim();
    final numRecordsStr = _ascii(bytes, 236, 8).trim();
    final durPerRecordStr = _ascii(bytes, 244, 8).trim();
    final nsStr = _ascii(bytes, 252, 4).trim();

    final headerBytes = int.tryParse(headerBytesStr);
    final numRecords = int.tryParse(numRecordsStr);
    final durPerRecord = double.tryParse(durPerRecordStr.replaceAll(',', '.'));
    final ns = int.tryParse(nsStr);

    // If this doesn't look like an EDF header, bail out.
    if (headerBytes == null || headerBytes < 256 || headerBytes > bytes.length) {
      return null;
    }

    final start = _parseEdfDateTime(startDate, startTime);
    if (start == null) return null;

    // EDF can use -1 for "unknown" data records.
    final totalSeconds = (numRecords != null && numRecords > 0 && durPerRecord != null && durPerRecord > 0)
        ? (numRecords * durPerRecord)
        : null;

    final end = totalSeconds != null ? start.add(Duration(milliseconds: (totalSeconds * 1000).round())) : start;

    Log.d(
      'EDF header: start=$start date="$startDate" time="$startTime" headerBytes=$headerBytes ns=$ns numRecords=$numRecords durRec=$durPerRecord',
      tag: 'PRS1',
    );

    // Best-effort signal decoding (safe: returns empty lists on mismatch).
    final decoded = (ns != null && ns > 0 && numRecords != null && numRecords > 0 && durPerRecord != null && durPerRecord > 0)
        ? _decodeSelectedSignals(
            bytes,
            headerBytes: headerBytes,
            ns: ns,
            numRecords: numRecords,
            durPerRecordSec: durPerRecord,
            start: start,
          )
        : const _DecodedSignals.empty();

    return Prs1Session(
      start: start,
      end: end,
      events: const [],
      pressureSamples: decoded.pressure,
      leakSamples: decoded.leak,
      flowSamples: decoded.flow,
      flexSamples: decoded.flex,
      flowWaveform: decoded.flowWaveform,
      pressureWaveform: decoded.pressureWaveform,
      leakWaveform: decoded.leakWaveform,
      flexWaveform: decoded.flexWaveform,
      sourcePath: sourcePath,
      sourceLabel: sourcePath != null ? sourcePath.split(RegExp(r'[\\/]')).last : null,
      minutesUsed: totalSeconds != null ? (totalSeconds / 60).round() : null,
    );
  }

  /// Downsample target rate for Web sandbox stability.
  static const double _targetHz = 1.0;

  static _DecodedSignals _decodeSelectedSignals(
    Uint8List bytes, {
    required int headerBytes,
    required int ns,
    required int numRecords,
    required double durPerRecordSec,
    required DateTime start,
  }) {
    try {
      final hdr = _parseSignalHeader(bytes, headerBytes: headerBytes, ns: ns);
      if (hdr == null) return const _DecodedSignals.empty();

      final selected = hdr.selectInterestingSignals();
      if (selected.isEmpty) return const _DecodedSignals.empty();

      // Precompute record layout (bytes).
      final recordSampleCounts = hdr.samplesPerRecord;
      final recordTotalSamples = recordSampleCounts.fold<int>(0, (a, b) => a + b);
      final recordBytes = recordTotalSamples * 2; // int16
      final dataStart = headerBytes;

      // Sanity check length.
      int recordCount = numRecords;
      final expectedLen = dataStart + recordCount * recordBytes;
      if (expectedLen > bytes.length) {
        Log.w('EDF length mismatch: expected >=$expectedLen got=${bytes.length}', tag: 'PRS1');
        final maxRecords = ((bytes.length - dataStart) / recordBytes).floor();
        if (maxRecords <= 0) return const _DecodedSignals.empty();
        recordCount = math.min(recordCount, maxRecords);
      }


      final outPressure = <Prs1SignalSample>[];
      final outLeak = <Prs1SignalSample>[];
      final outFlow = <Prs1SignalSample>[];
      final outFlex = <Prs1SignalSample>[];

      // Native-rate waveform buffers (Milestone D).
      final waveFlow = <double>[];
      final wavePressure = <double>[];
      final waveLeak = <double>[];
      final waveFlex = <double>[];

      double? waveFlowHz;
      double? wavePressureHz;
      double? waveLeakHz;
      double? waveFlexHz;

      String flowUnit = '';
      String pressureUnit = '';
      String leakUnit = '';
      String flexUnit = '';
      String flowLabel = '';
      String pressureLabel = '';
      String leakLabel = '';
      String flexLabel = '';

      // Per selected signal: maintain 1-second bin aggregation state.
      final bin = <int, _BinAggState>{};
      for (final s in selected) {
        bin[s.index] = _BinAggState(isBoolean: s.kind == _SigKind.flex);
      }

      final startEpoch = start.toUtc().millisecondsSinceEpoch ~/ 1000;

      int offset = dataStart;
      for (int rec = 0; rec < recordCount; rec++) {
        // Each record spans durPerRecordSec seconds.
        final recStartSec = rec * durPerRecordSec;

        // Walk each signal in EDF order. For unselected, just skip.
        for (int si = 0; si < ns; si++) {
          final nSamp = recordSampleCounts[si];
          final isSel = bin.containsKey(si);

          if (!isSel) {
            offset += nSamp * 2;
            continue;
          }

          final sig = selected.firstWhere((e) => e.index == si);
          final scale = hdr.scaleFor(si);

          final dt = durPerRecordSec / nSamp;
          final state = bin[si]!;

          for (int k = 0; k < nSamp; k++) {
            if (offset + 2 > bytes.length) break;

            final lo = bytes[offset];
            final hi = bytes[offset + 1];
            offset += 2;

            int dig = (hi << 8) | lo;
            if (dig & 0x8000 != 0) dig = dig - 0x10000; // signed int16

            final phys = scale.toPhysical(dig);

            // Store native-rate waveform.
            switch (sig.kind) {
              case _SigKind.flow:
                waveFlow.add(phys);
                waveFlowHz ??= (nSamp / durPerRecordSec);
                flowUnit = hdr.units[si];
                flowLabel = hdr.labels[si];
                break;
              case _SigKind.pressure:
                wavePressure.add(phys);
                wavePressureHz ??= (nSamp / durPerRecordSec);
                pressureUnit = hdr.units[si];
                pressureLabel = hdr.labels[si];
                break;
              case _SigKind.leak:
                waveLeak.add(phys);
                waveLeakHz ??= (nSamp / durPerRecordSec);
                leakUnit = hdr.units[si];
                leakLabel = hdr.labels[si];
                break;
              case _SigKind.flex:
                waveFlex.add(phys);
                waveFlexHz ??= (nSamp / durPerRecordSec);
                flexUnit = hdr.units[si];
                flexLabel = hdr.labels[si];
                break;
            }

            // Compute absolute epoch seconds for this sample.
            final tSec = startEpoch + (recStartSec + k * dt).floor();

            // Bin to 1Hz (or lower if source is <1Hz) by epoch second.
            state.add(tSec, phys);
          }

          // End-of-signal for this record; flush bins that are now "stable" if desired.
          // We will flush at the end globally.
        }
      }

      // Flush all bin states into outputs.
      for (final sig in selected) {
        final state = bin[sig.index]!;
        final samples = state.flushToSamples(sig.toSignalType(), startUtcEpochSec: startEpoch);
        switch (sig.kind) {
          case _SigKind.pressure:
            outPressure.addAll(samples);
            break;
          case _SigKind.leak:
            outLeak.addAll(samples);
            break;
          case _SigKind.flow:
            outFlow.addAll(samples);
            break;
          case _SigKind.flex:
            outFlex.addAll(samples);
            break;
        }
      }

      // Sort (stable) to guarantee monotonic order.
      outPressure.sort((a, b) => a.tEpochSec.compareTo(b.tEpochSec));
      outLeak.sort((a, b) => a.tEpochSec.compareTo(b.tEpochSec));
      outFlow.sort((a, b) => a.tEpochSec.compareTo(b.tEpochSec));
      outFlex.sort((a, b) => a.tEpochSec.compareTo(b.tEpochSec));

      Log.d(
        'EDF signals decoded: pressure=${outPressure.length} leak=${outLeak.length} flow=${outFlow.length} flex=${outFlex.length}',
        tag: 'PRS1',
      );

      Prs1WaveformChannel? _mkWave(List<double> v, double? hz, String unit, String label) {
        if (v.isEmpty || hz == null || hz <= 0) return null;
        // Convert to Float32 for memory efficiency.
        final f = Float32List(v.length);
        for (int i = 0; i < v.length; i++) {
          f[i] = v[i].toDouble();
        }
        return Prs1WaveformChannel(
          startEpochMs: start.toUtc().millisecondsSinceEpoch,
          sampleRateHz: hz,
          samples: f,
          unit: unit,
          label: label,
        );
      }

      return _DecodedSignals(
        pressure: outPressure,
        leak: outLeak,
        flow: outFlow,
        flex: outFlex,
        flowWaveform: _mkWave(waveFlow, waveFlowHz, flowUnit, flowLabel),
        pressureWaveform: _mkWave(wavePressure, wavePressureHz, pressureUnit, pressureLabel),
        leakWaveform: _mkWave(waveLeak, waveLeakHz, leakUnit, leakLabel),
        flexWaveform: _mkWave(waveFlex, waveFlexHz, flexUnit, flexLabel),
      );
    } catch (e, st) {
      Log.w('EDF signal decode failed: $e\n$st', tag: 'PRS1');
      return const _DecodedSignals.empty();
    }
  }

  static _EdfSignalHeader? _parseSignalHeader(Uint8List bytes, {required int headerBytes, required int ns}) {
    // Classic EDF header block sizes.
    const int fixedHeader = 256;
    final perSignalBytes = 256; // 16+80+8+8+8+8+8+80+8+32 = 256
    final expectedHeader = fixedHeader + ns * perSignalBytes;
    if (expectedHeader != headerBytes) {
      // Some EDF+ may still match; if not, be conservative.
      if (expectedHeader > bytes.length || headerBytes > bytes.length) return null;
    }

    int o = fixedHeader;

    List<String> readStrList(int len) {
      final out = <String>[];
      for (int i = 0; i < ns; i++) {
        out.add(_ascii(bytes, o + i * len, len).trim());
      }
      o += ns * len;
      return out;
    }

    List<double> readDoubleList(int len) {
      final out = <double>[];
      for (int i = 0; i < ns; i++) {
        final s = _ascii(bytes, o + i * len, len).trim().replaceAll(',', '.');
        out.add(double.tryParse(s) ?? double.nan);
      }
      o += ns * len;
      return out;
    }

    List<int> readIntList(int len) {
      final out = <int>[];
      for (int i = 0; i < ns; i++) {
        final s = _ascii(bytes, o + i * len, len).trim();
        out.add(int.tryParse(s) ?? 0);
      }
      o += ns * len;
      return out;
    }

    final labels = readStrList(16);
    // Skip transducer type (80)
    o += ns * 80;
    // Physical dimension (unit)
    final units = readStrList(8);

    final physMin = readDoubleList(8);
    final physMax = readDoubleList(8);
    final digMin = readIntList(8);
    final digMax = readIntList(8);

    // Skip prefilter (80)
    o += ns * 80;

    final samplesPerRecord = readIntList(8);
    // Skip reserved (32)
    // o += ns * 32;

    // Basic validation.
    if (labels.length != ns || samplesPerRecord.length != ns) return null;

    return _EdfSignalHeader(
      labels: labels,
      units: units,
      physMin: physMin,
      physMax: physMax,
      digMin: digMin,
      digMax: digMax,
      samplesPerRecord: samplesPerRecord,
    );
  }

  static DateTime? _parseEdfDateTime(String date, String time) {
    // dd.mm.yy and hh.mm.ss
    final d = date.split('.');
    final t = time.split('.');
    if (d.length != 3 || t.length < 2) return null;

    final dd = int.tryParse(d[0]);
    final mm = int.tryParse(d[1]);
    final yy = int.tryParse(d[2]);
    if (dd == null || mm == null || yy == null) return null;

    // EDF stores 2-digit year. We'll map 00-79 -> 2000-2079, 80-99 -> 1980-1999.
    final year = (yy <= 79) ? 2000 + yy : 1900 + yy;

    final hh = int.tryParse(t[0]) ?? 0;
    final mi = int.tryParse(t[1]) ?? 0;
    final ss = (t.length >= 3 ? int.tryParse(t[2]) : 0) ?? 0;

    try {
      return DateTime(year, mm, dd, hh, mi, ss);
    } catch (_) {
      return null;
    }
  }

  static String _ascii(Uint8List b, int offset, int len) {
    if (offset < 0 || len <= 0) return '';
    if (offset + len > b.length) return '';
    return String.fromCharCodes(b.sublist(offset, offset + len));
  }
}

class _DecodedSignals {
  const _DecodedSignals({
    required this.pressure,
    required this.leak,
    required this.flow,
    required this.flex,
    this.flowWaveform,
    this.pressureWaveform,
    this.leakWaveform,
    this.flexWaveform,
  });

  const _DecodedSignals.empty()
      : pressure = const [],
        leak = const [],
        flow = const [],
        flex = const [],
        flowWaveform = null,
        pressureWaveform = null,
        leakWaveform = null,
        flexWaveform = null;

  final List<Prs1SignalSample> pressure;
  final List<Prs1SignalSample> leak;
  final List<Prs1SignalSample> flow;
  final List<Prs1SignalSample> flex;

  final Prs1WaveformChannel? flowWaveform;
  final Prs1WaveformChannel? pressureWaveform;
  final Prs1WaveformChannel? leakWaveform;
  final Prs1WaveformChannel? flexWaveform;
}

enum _SigKind { flow, pressure, leak, flex }

class _SelectedSig {
  const _SelectedSig({
    required this.index,
    required this.kind,
  });

  final int index;
  final _SigKind kind;

  Prs1SignalType toSignalType() {
    switch (kind) {
      case _SigKind.flow:
        return Prs1SignalType.flowRate;
      case _SigKind.pressure:
        return Prs1SignalType.pressure;
      case _SigKind.leak:
        return Prs1SignalType.leak;
      case _SigKind.flex:
        return Prs1SignalType.flexActive;
    }
  }
}

class _EdfSignalHeader {
  const _EdfSignalHeader({
    required this.labels,
    required this.units,
    required this.physMin,
    required this.physMax,
    required this.digMin,
    required this.digMax,
    required this.samplesPerRecord,
  });

  final List<String> labels;
  final List<String> units;
  final List<double> physMin;
  final List<double> physMax;
  final List<int> digMin;
  final List<int> digMax;
  final List<int> samplesPerRecord;

  _EdfScale scaleFor(int i) => _EdfScale(
        physMin: physMin[i],
        physMax: physMax[i],
        digMin: digMin[i],
        digMax: digMax[i],
      );

  List<_SelectedSig> selectInterestingSignals() {
    _SigKind? classify(String labelRaw) {
      final l = labelRaw.toLowerCase();

      bool has(String s) => l.contains(s);

      // Typical labels seen in sleep EDF exports vary widely. Keep heuristics broad.
      if (has('flow')) return _SigKind.flow;
      if (has('press')) return _SigKind.pressure;
      if (has('leak')) return _SigKind.leak;

      // Flex / EPR / Expiratory assist (device dependent).
      if (has('flex') || has('epr') || has('exp') || has('exhale')) return _SigKind.flex;

      return null;
    }

    final out = <_SelectedSig>[];
    for (int i = 0; i < labels.length; i++) {
      final k = classify(labels[i]);
      if (k != null && samplesPerRecord[i] > 0) {
        out.add(_SelectedSig(index: i, kind: k));
      }
    }
    return out;
  }
}

class _EdfScale {
  const _EdfScale({
    required this.physMin,
    required this.physMax,
    required this.digMin,
    required this.digMax,
  });

  final double physMin;
  final double physMax;
  final int digMin;
  final int digMax;

  double toPhysical(int dig) {
    final denom = (digMax - digMin);
    if (denom == 0) return dig.toDouble();
    return (dig - digMin) * (physMax - physMin) / denom + physMin;
  }
}

class _BinAggState {
  _BinAggState({required this.isBoolean});

  final bool isBoolean;

  int? _currentSec;
  double _sum = 0;
  int _count = 0;

  final List<Prs1SignalSample> _out = <Prs1SignalSample>[];

  void add(int epochSec, double value) {
    // For boolean-like flags, clamp 0/1.
    final v = isBoolean ? (value >= 0.5 ? 1.0 : 0.0) : value;

    if (_currentSec == null) {
      _currentSec = epochSec;
      _sum = v;
      _count = 1;
      return;
    }

    if (epochSec == _currentSec) {
      _sum += v;
      _count += 1;
      return;
    }

    // Flush previous second.
    _flushCurrent();

    // Start new second.
    _currentSec = epochSec;
    _sum = v;
    _count = 1;
  }

  void _flushCurrent() {
    final sec = _currentSec;
    if (sec == null || _count == 0) return;

    final avg = _sum / _count;
    final finalValue = isBoolean ? (avg >= 0.5 ? 1.0 : 0.0) : avg;
    // signalType assigned later, so temporarily store as flowRate and patch when flushing.
    _out.add(Prs1SignalSample(tEpochSec: sec, value: finalValue, signalType: Prs1SignalType.flowRate));
  }

  List<Prs1SignalSample> flushToSamples(Prs1SignalType type, {required int startUtcEpochSec}) {
    // Flush last bin.
    _flushCurrent();
    _currentSec = null;

    // Patch signalType.
    final out = <Prs1SignalSample>[];
    for (final s in _out) {
      out.add(Prs1SignalSample(tEpochSec: s.tEpochSec, value: s.value, signalType: type));
    }
    return out;
  }
}