// lib/features/prs1/decode/event_registry.dart
//
// Layer 6: a table-driven event registry.
//
// Goal:
// - Separate *record framing* from *event semantics*.
// - Keep the decoding pipeline compilable even before full OSCAR parity.
//
// This registry is intentionally conservative and heuristic-based.
// It will be upgraded by swapping parsers and adding tables as we port more
// of prs1_loader.cpp.

import 'dart:typed_data';

import '../binary/le_reader.dart';
import '../model/prs1_event.dart';
import 'record_decoder.dart';

typedef RecordParser = List<Prs1Event> Function(Prs1Record r, {required DateTime fallbackStart});

class EventRegistry {
  EventRegistry() {
    // Register parsers by record type (sub-record header type), when known.
    // 0xFF is our synthetic "unknown" wrapper => parse as a single event record.
    _parsers[0xFF] = _parseGenericEventRecord;
  }

  final Map<int, RecordParser> _parsers = <int, RecordParser>{};

  List<Prs1Event> decodeRecord(Prs1Record r, {required DateTime fallbackStart}) {
    final p = _parsers[r.type] ?? _parseGenericEventRecord;
    return p(r, fallbackStart: fallbackStart);
  }

  // ---------- Heuristic parsers ----------

  List<Prs1Event> _parseGenericEventRecord(Prs1Record r, {required DateTime fallbackStart}) {
    final data = r.data;
    if (data.length < 3) return const [];

    final lr = LeReader(Uint8List.sublistView(data));
    final code = lr.u8();

    // Try absolute unix seconds (u32le).
    DateTime? tAbs;
    if (lr.remaining >= 4) {
      final unixSeconds = lr.u32();
      tAbs = _tryUnixSeconds(unixSeconds);
    }

    DateTime t;
    if (tAbs != null) {
      t = tAbs;
    } else {
      // Fallback: minute offset from a synthetic start.
      if (lr.remaining < 2) return const [];
      final minuteOffset = lr.u16();
      t = fallbackStart.add(Duration(minutes: minuteOffset));
    }

    // Attempt to parse either:
    // 1) scalar value (s16 / 10)
    // 2) sample series (u16 samplePeriodSec, u16 count, count*s16 values)
    //
    // We do this based on remaining length and plausibility.
    if (lr.remaining >= 4) {
      final peekPeriod = lr.peekU16();
      final peekCount = lr.peekU16(2);

      final remainingAfterHeader = lr.remaining - 4;
      final bytesNeeded = peekCount * 2;

      final looksLikeSeries =
          peekPeriod > 0 &&
          peekPeriod <= 60 &&
          peekCount > 0 &&
          peekCount <= 6000 &&
          remainingAfterHeader >= bytesNeeded;

      if (looksLikeSeries) {
        final periodSec = lr.u16();
        final count = lr.u16();
        // Read raw series first so we can classify unknown series (e.g. flex flags).
        final rawValues = <int>[];
        for (int i = 0; i < count; i++) {
          if (lr.remaining < 2) break;
          rawValues.add(lr.s16());
        }

        var eventType = mapCode(code, isSeries: true);
        // Heuristic: if this is an unknown series and values look boolean-like, treat as flexActiveSample.
        if (eventType == Prs1EventType.unknown && rawValues.isNotEmpty) {
          bool looksBool = true;
          for (final rv in rawValues) {
            if (!(rv == 0 || rv == 1 || rv == 10)) {
              looksBool = false;
              break;
            }
          }
          if (looksBool) eventType = Prs1EventType.flexActiveSample;
        }

        final events = <Prs1Event>[];
        final n = rawValues.length;
        for (int i = 0; i < n; i++) {
          final vRaw = rawValues[i];
          final ti = t.add(Duration(seconds: periodSec * i));
          final num v = (eventType == Prs1EventType.flexActiveSample)
              ? ((vRaw == 0) ? 0.0 : 1.0)
              : _scale(code, vRaw);
          events.add(_mk(
            time: ti,
            type: eventType,
            value: v.toDouble(),
            code: code,
            flags: r.flags,
            crcOk: r.crcOk,
            sourceOffset: r.frameOffset,
            raw: r.raw,
          ));
        }
        return events;
      }
    }

    // Scalar value, best-effort.
    num? value;
    if (lr.remaining >= 2) {
      final vRaw = lr.s16();
      value = _scale(code, vRaw);
    }

    return [
      _mk(
        time: t,
        type: mapCode(code, isSeries: false),
        value: value,
        code: code,
        flags: r.flags,
        crcOk: r.crcOk,
        sourceOffset: r.frameOffset,
        raw: r.raw,
      ),
    ];
  }

  Prs1Event _mk({
    required DateTime time,
    required Prs1EventType type,
    num? value,
    int? code,
    int? flags,
    bool? crcOk,
    int? sourceOffset,
    Uint8List? raw,
  }) {
    return Prs1Event(
      time: time,
      type: type,
      value: value,
      code: code,
      flags: flags,
      crcOk: crcOk,
      sourceOffset: sourceOffset,
      raw: raw == null ? null : _trim(raw, 128),
    );
  }

  Uint8List _trim(Uint8List bytes, int max) {
    if (bytes.length <= max) return bytes;
    return Uint8List.sublistView(bytes, 0, max);
  }

  DateTime? _tryUnixSeconds(int unixSeconds) {
    // 2000-01-01 .. 2100-01-01
    const min = 946684800;
    const max = 4102444800;
    if (unixSeconds < min || unixSeconds > max) return null;
    return DateTime.fromMillisecondsSinceEpoch(unixSeconds * 1000, isUtc: true).toLocal();
  }

  num _scale(int code, int raw) {
    // Best-effort: these will be replaced by proper tables.
    switch (code) {
      // pressure-like
      case 0x30:
      case 0x33:
        return raw / 10.0;
      // leak-like
      case 0x20:
      case 0x31:
        return raw / 10.0;
      // flow-like (often higher resolution)
      case 0x32:
        return raw / 100.0;
      default:
        return raw / 10.0;
    }
  }

  Prs1EventType mapCode(int code, {required bool isSeries}) {
    // Layer 6: expand mapping and separate "samples" vs "events".
    switch (code) {
      case 0x01:
        return Prs1EventType.obstructiveApnea;
      case 0x02:
        return Prs1EventType.clearAirwayApnea;
      case 0x03:
        return Prs1EventType.hypopnea;
      case 0x10:
        return Prs1EventType.flowLimitation;
      case 0x11:
        return Prs1EventType.snore;
      case 0x12:
        return Prs1EventType.periodicBreathing;
      case 0x13:
        return Prs1EventType.rera;
      case 0x14:
        return Prs1EventType.vibratorySnore;
      case 0x15:
        return Prs1EventType.vibratorySnore2;
      case 0x16:
        return Prs1EventType.breathNotDetected;
      case 0x20:
        return Prs1EventType.largeLeak;
      case 0x30:
        return isSeries ? Prs1EventType.pressureSample : Prs1EventType.pressureChange;
      case 0x31:
        return Prs1EventType.leakSample;
      case 0x32:
        return Prs1EventType.flowSample;
      default:
        return Prs1EventType.unknown;
    }
  }
}
