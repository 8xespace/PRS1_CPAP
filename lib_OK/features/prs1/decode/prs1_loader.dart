// lib/features/prs1/decode/prs1_loader.dart

import 'dart:typed_data';

import '../../../core/logging.dart';
import '../binary/le_reader.dart';
import '../model/prs1_device.dart';
import '../model/prs1_event.dart';
import '../model/prs1_session.dart';
import '../model/prs1_signal_sample.dart';
import '../model/prs1_waveform_channel.dart';
import 'edf_decoder.dart';
import 'frame_decoder.dart';
import 'event_decoder.dart';
import 'session_stats.dart';

// === PRS1 debug logging toggle ===
// Set to true only when you need to inspect decode internals.
const bool kPrs1CliVerbose = false;


/// Core decoder scaffold that will be progressively filled to match OSCAR's prs1_loader.cpp.
///
/// Current stage:
/// - Detects basic file kind (EDF vs unknown)
/// - For EDF, extracts session start time & duration (no waveform decoding yet)
/// - Keeps stable types so we can later plug in the real PRS1 binary frame/event pipeline
class Prs1Loader {
  const Prs1Loader();

  /// Parse a single PRS1-related file blob.
  ///
  /// [sourcePath] is optional but strongly recommended (used for labels/debug).
  Prs1ParseResult parse(Uint8List bytes, {String? sourcePath}) {
    final r = LeReader(bytes);

    final head = Prs1DebugHeader(
      length: bytes.length,
      b0: bytes.isNotEmpty ? bytes[0] : null,
      first16: bytes.length >= 16 ? Uint8List.sublistView(bytes, 0, 16) : Uint8List.fromList(bytes),
    );

    // Heuristic: attempt to read ASCII magic if present.
    String? magic;
    if (bytes.length >= 4) {
      final m = r.str(4, trimNull: false);
      final printable = m.codeUnits.every((c) => c >= 0x20 && c <= 0x7E);
      if (printable) magic = m;
      r.seek(0);
    }

    final detected = Prs1FileKind.detect(bytes, sourcePath: sourcePath);
    Log.d('PRS1 parse: kind=$detected magic=${magic ?? "(none)"} len=${bytes.length} src=${sourcePath ?? "(mem)"}', tag: 'PRS1');

    // Third layer: EDF header -> session.
    if (detected == Prs1FileKind.edf) {
      final s = EdfDecoder.tryParseSession(bytes, sourcePath: sourcePath);
      return Prs1ParseResult(
        kind: detected,
        magic: magic,
        header: head,
        device: null,
        sessions: s != null ? [s] : const [],
      );
    }

    // PRS1 "chunk" files (.001/.002/.005, etc.)
    //
    // OSCAR parses Philips System One data as a sequence of data "chunks".
    // Each chunk begins with a 15-byte common header:
    //   [0]=fileVersion, [1..2]=blockSize (u16le), [3]=htype (0 normal,1 interval/wave),
    //   [4]=family, [5]=familyVersion, [6]=ext, [7..10]=sessionId (u32le), [11..14]=timestamp (u32le unix).
    //
    // For our UI (Layer 3/6), the most important metric is *usage duration*.
    // We can compute that reliably from interval chunks (htype==1) by reading
    // interval_count and interval_seconds (see OSCAR's ReadWaveformHeader).
    if (detected == Prs1FileKind.chunk) {
      final sessions = _parseChunkFile(bytes, sourcePath: sourcePath);
      return Prs1ParseResult(
        kind: detected,
        magic: magic,
        header: head,
        device: null,
        sessions: sessions,
      );
    }

    // Layer 4-5: PRS1 binary frame/event pipeline.
///
/// Layer 4 gave us deterministic slicing + placeholder semantics.
/// Layer 5 adds:
/// - CRC16 footer detection (in FrameDecoder)
/// - Best-effort absolute timestamp extraction (in EventDecoder)
///
/// This is still not full OSCAR parity yet, but it produces *realistic* event times
/// when the underlying records carry unix timestamps.
    if (detected == Prs1FileKind.binary000 || detected == Prs1FileKind.binary001 || detected == Prs1FileKind.binary002) {
      final frames = const FrameDecoder().decode(bytes).toList(growable: false);

      // Fallback anchor when we only have minute-offset style records.
      final fallbackStart = DateTime(2000, 1, 1, 0, 0, 0);

      final events = EventDecoder().decodeFrames(
        frames,
        sessionStart: fallbackStart,
      );

      DateTime sessionStart = fallbackStart;
      DateTime sessionEnd = fallbackStart;

      if (events.isNotEmpty) {
        events.sort((a, b) => a.time.compareTo(b.time));
        sessionStart = events.first.time;
        sessionEnd = events.last.time.add(const Duration(minutes: 1));
      }

      final minutesUsed = sessionEnd.difference(sessionStart).inMinutes;

      final stats = Prs1SessionStats.fromEvents(
        events: events,
        minutesUsed: minutesUsed,
      );

      final s = Prs1Session(
        start: sessionStart,
        end: sessionEnd,
        events: events,
        sourcePath: sourcePath,
        sourceLabel: detected.name,
        minutesUsed: minutesUsed,
        ahi: stats.ahi,
        pressureMin: stats.pressureMin,
        pressureMax: stats.pressureMax,
        leakMedian: stats.leakMedian,
      );

      return Prs1ParseResult(
        kind: detected,
        magic: magic,
        header: head,
        device: null,
        sessions: [s],
      );
    }

    return Prs1ParseResult(
      kind: detected,
      magic: magic,
      header: head,
      device: null,
      sessions: const [],
    );
  }
}

// ---------------- Chunk parsing (OSCAR-style) ----------------

class _ChunkSummary {
  _ChunkSummary({required this.sessionId});

  final int sessionId;
  DateTime? start;
  DateTime? end;
  int usageSeconds = 0;

  // Low-rate signal samples (typically per-minute) extracted from event chunks (.002).
  // These feed the daily aggregator percentile metrics (Leak p95 / Pressure p95).
  final List<Prs1SignalSample> pressureSamples = <Prs1SignalSample>[];
  // Separate exhale/Flex-affected pressure line (OSCAR green line).
  final List<Prs1SignalSample> exhalePressureSamples = <Prs1SignalSample>[];
  final List<Prs1SignalSample> leakSamples = <Prs1SignalSample>[];
  final List<Prs1SignalSample> flowLimSamples = <Prs1SignalSample>[];

  // High-rate flow waveform (from interval chunks ext=0x05). Required for breath-derived metrics (MV/RR/TV).
  final List<double> flowWaveLpm = <double>[];
  double? flowWaveSampleRateHz;
  int? flowWaveStartEpochMs;

  // Phase0: log .005 waveform header summary once per session (safety checkpoint).
  bool loggedWave005Header = false;


  /// Best-effort device minimum pressure setting (cmH2O) extracted from settings chunks (.001).
  double? minPressureSettingCmH2O;
  final List<double> _minPressureCandidates = <double>[];

  /// Discrete events (OA/CA/H/FL/snore/etc) extracted from event chunks (.002).
  /// These feed daily AHI and FL summaries.
  final List<Prs1Event> events = <Prs1Event>[];

  // ---- Debug counters (for FlexPressureAverage / EPAP green line) ----
  int stats11Count = 0; // how many 0x11 Statistics records were parsed
  int epapSampleCount = 0; // how many FlexPressureAverage samples were emitted
  int? unknownEventCode; // first unknown event code that caused an early break
  final Set<int> stats11Sizes = <int>{}; // observed hblock size for 0x11

  void addSlice(DateTime s, Duration d) {
    start = (start == null || s.isBefore(start!)) ? s : start;
    final e = s.add(d);
    end = (end == null || e.isAfter(end!)) ? e : end;
    usageSeconds += d.inSeconds;
  }
}

List<Prs1Session> _parseChunkFile(Uint8List bytes, {String? sourcePath}) {
  // For Layer 3 UI we need:
  // - stable session start/end times
  // - usage seconds (from interval chunks .005)
  // - low-rate pressure/leak samples (from event chunks .002) so we can compute p95 metrics.
  //
  // This is still *not* full OSCAR parity, but it follows OSCAR's chunk header layout closely
  // (notably: v3 "normal" chunks contain a checksum byte *after* the hdb block).
  final bySession = <int, _ChunkSummary>{};

  int u16(int o) => bytes[o] | (bytes[o + 1] << 8);
  int u32(int o) => bytes[o] | (bytes[o + 1] << 8) | (bytes[o + 2] << 16) | (bytes[o + 3] << 24);

  DateTime? tsToLocal(int ts) {
    if (ts < 946684800 || ts > 4102444800) return null; // 2000..2100
    return DateTime.fromMillisecondsSinceEpoch(ts * 1000, isUtc: true).toLocal();
  }

  // Parse a v2/v3 chunk header and return (dataStart, hblock).
  ({int dataStart, Map<int, int> hblock})? parseNormalHeader(int pos, int fileVersion) {
    // Common 15-byte header already validated by caller.
    if (fileVersion == 2) {
      // OSCAR ReadHeader(v2): reads 1 extra byte, then uses bytes[15] as hdb length,
      // then reads 2*hdb bytes pairs. No checksum byte in v2.
      if (pos + 16 > bytes.length) return null;
      final hdbLen = bytes[pos + 15];
      final hdbStart = pos + 16;
      final hdbBytes = hdbLen * 2;
      if (hdbStart + hdbBytes > pos + (bytes[pos + 1] | (bytes[pos + 2] << 8))) return null;
      final hblock = <int, int>{};
      int p = hdbStart;
      for (int i = 0; i < hdbLen; i++) {
        hblock[bytes[p]] = bytes[p + 1];
        p += 2;
      }
      return (dataStart: p, hblock: hblock);
    }

    // v3 normal header: extra1 (hdbLen) + header data block (pairs) + checksum byte.
    if (pos + 16 > bytes.length) return null;
    final hdbLen = bytes[pos + 15];
    final hdbStart = pos + 16;
    final hdbBytes = hdbLen * 2;
    int p = hdbStart + hdbBytes;
    if (p + 1 > pos + (bytes[pos + 1] | (bytes[pos + 2] << 8))) return null;
    final hblock = <int, int>{};
    int q = hdbStart;
    for (int i = 0; i < hdbLen; i++) {
      hblock[bytes[q]] = bytes[q + 1];
      q += 2;
    }
    // Skip checksum byte.
    p += 1;
    return (dataStart: p, hblock: hblock);
  }

  int pos = 0;
  while (pos + 15 <= bytes.length) {
    final fileVersion = bytes[pos + 0];
    if (fileVersion < 2 || fileVersion > 3) break;

    final blockSize = bytes[pos + 1] | (bytes[pos + 2] << 8);
    if (blockSize <= 0) break;
    if (pos + blockSize > bytes.length) {
      // Truncated tail.
      break;
    }

    final htype = bytes[pos + 3];
    final family = bytes[pos + 4];
    final familyVer = bytes[pos + 5];
    final ext = bytes[pos + 6];
    final sessionId = (bytes[pos + 7]) |
        (bytes[pos + 8] << 8) |
        (bytes[pos + 9] << 16) |
        (bytes[pos + 10] << 24);
    final ts = u32(pos + 11);

    final t = tsToLocal(ts);

    // Ensure a session bucket exists.
    final summary = bySession.putIfAbsent(sessionId, () => _ChunkSummary(sessionId: sessionId));
    if (t != null) {
      // Even normal chunks advance the session time bounds.
      summary.start = (summary.start == null || t.isBefore(summary.start!)) ? t : summary.start;
      summary.end = (summary.end == null || t.isAfter(summary.end!)) ? t : summary.end;
    }

    // Interval / waveform chunk (.005) => compute duration + (ext=0x05) decode flow waveform.
    if (htype == 0x01 && t != null) {
      // Follow OSCAR's ReadWaveformHeader layout (prs1_parser.cpp):
      // fixed 4 bytes: interval_count(u16), interval_seconds(u8), wvfm_signals(u8)
      if (pos + 19 <= bytes.length) {
        final intervalCount = bytes[pos + 15] | (bytes[pos + 16] << 8);
        final intervalSeconds = bytes[pos + 17];
        final wvfmSignals = bytes[pos + 18];
        final durationSec = intervalCount * intervalSeconds;
        if (durationSec > 0 && durationSec < 24 * 3600) {
          summary.addSlice(t, Duration(seconds: durationSec));
        }

        // DreamStation / PRS1 flow waveform is typically ext=0x05, fileVersion=3, wvfmSignals=1.
        // Decode raw int8 samples and scale to L/min so breath analyzer can compute MV/RR/TV.
        if (ext == 0x05 && intervalCount > 0 && intervalSeconds > 0 && wvfmSignals > 0) {
          int p = pos + 19; // start of waveformInfo array
          int? flowInterleave;
          for (int i = 0; i < wvfmSignals; i++) {
            if (p + (fileVersion == 3 ? 4 : 3) > bytes.length) break;
            final kind = bytes[p];
            final interleave = bytes[p + 1] | (bytes[p + 2] << 8);
            if (fileVersion == 3) {
              // bytes[p+3] is always_8 (bits per sample), ignore.
              p += 4;
            } else {
              p += 3;
            }
            // OSCAR uses `kind` as a channel index; on DreamStation flow is kind==0 when only 1 signal exists.
            if (kind == 0 && flowInterleave == null) {
              flowInterleave = interleave;
            }
          }
          if (p + 1 <= bytes.length) {
            // trailing always_0
            p += 1;
          }
          if (fileVersion == 3 && p + 1 <= bytes.length) {
            // header additive checksum byte (stored after waveform header)
            p += 1;
          }

          final interleave = flowInterleave ?? (bytes[pos + 20] | (bytes[pos + 21] << 8));
          final sampleRateHz = interleave / intervalSeconds;
          final sampleCount = intervalCount * interleave;

          final blockEnd = pos + blockSize;
          int dataEnd = blockEnd;
          // v3 chunks include CRC32 at end; drop it if present.
          if (fileVersion == 3 && dataEnd - p >= 4) {
            dataEnd -= 4;
          }
          final dataLen = dataEnd - p;

          // Phase0 checkpoint: log .005 waveform header summary (once per session) for reverse-engineering parity with OSCAR.
          if (!summary.loggedWave005Header) {
            summary.loggedWave005Header = true;
            Log.d(
              'PRS1 .005 header: sid=$sessionId fv=$fileVersion htype=$htype ext=$ext '
              'intervalCount=$intervalCount intervalSec=$intervalSeconds signals=$wvfmSignals '
              'flowInterleave=${flowInterleave ?? -1} sampleRateHz=${sampleRateHz.toStringAsFixed(3)} '
              'sampleCount=$sampleCount dataLen=$dataLen blockSize=$blockSize pos=$pos '
              'src=${sourcePath ?? "(mem)"}',
              tag: 'PRS1',
            );
          }
          if (sampleCount > 0 && dataLen >= sampleCount) {
            // Use a conservative scale that matches OSCAR magnitude for PRS1 DreamStation.
            const double kFlowScaleLpmPerCount = 1.095;

            summary.flowWaveStartEpochMs ??= t.toUtc().millisecondsSinceEpoch;
            summary.flowWaveSampleRateHz ??= sampleRateHz;

            for (int i = 0; i < sampleCount; i++) {
              final raw = bytes[p + i];
              final int s8 = (raw & 0x80) != 0 ? raw - 256 : raw;
              summary.flowWaveLpm.add(s8 * kFlowScaleLpmPerCount);
            }
          }
        }
      }
    }

// Event chunk (.002) => extract per-interval leak/pressure samples.
    if (htype == 0x00 && ext == 0x02 && t != null) {
      final hdr = parseNormalHeader(pos, fileVersion);
      if (hdr != null) {
        final dataStart = hdr.dataStart;
        final hblock = hdr.hblock;

        // Only implement the device family we currently target (DreamStation CPAP: family 0, v6).
        if (family == 0x00 && familyVer == 0x06) {
          int p = dataStart;
          int tEpoch = ts; // unix seconds, UTC

          while (p < pos + blockSize) {
            if (p >= pos + blockSize) break;
            final code = bytes[p++];
            if (!hblock.containsKey(code)) {
              // Unknown event code.
              //
              // In the field we sometimes see short corrupt spans (or we mis-read
              // the delta-prefix rule for a device variant). Hard-breaking here
              // causes us to lose downstream 0x11 Statistics records, which are
              // the only reliable source for Flex/EPAP (OSCAR green line).
              //
              // Strategy:
              // - Record the first unknown code for debugging.
              // - Try to resync by scanning ahead for the next byte that is a
              //   known event code (present in hblock). If found, jump there and
              //   continue. Otherwise, stop.
              summary.unknownEventCode ??= code;
              int? next;
              final scanLimit = (pos + blockSize).clamp(0, bytes.length);
              for (int r = p; r < scanLimit && r < p + 24; r++) {
                final c = bytes[r];
                if (hblock.containsKey(c)) {
                  next = r;
                  break;
                }
              }
              if (next == null) break;
              p = next;
              continue;
            }
            final size = hblock[code]!;
            // Ensure payload within chunk.
            if (p + size > pos + blockSize) break;

            // All events except 0x12 have a 16-bit delta time prefix.
            final payloadStart = p;
            if (code != 0x12) {
              if (p + 2 > pos + blockSize) break;
              final dtSec = u16(p);
              tEpoch += dtSec;
              p += 2;
            }
            // --- Discrete respiratory events (needed for AHI + basic FL counts) ---
            // OSCAR (prs1_parser_xpap.cpp) ParseEventsF0V6 interprets most respiratory flags as:
            //   - 2-byte delta-time prefix (already applied to tEpoch)
            //   - 1-byte "elapsed" indicating how many seconds BEFORE (tEpoch) the event actually occurred.
            // Mappings (DreamStation CPAP: family 0 v6):
            //   0x06 -> Obstructive Apnea      (elapsed = payload[0])
            //   0x07 -> Clear Airway Apnea    (elapsed = payload[0])
            //   0x0A -> Hypopnea              (elapsed = payload[0])
            //   0x0B -> Hypopnea (variant)    (elapsed = payload[1])
            //   0x0C -> Flow Limitation       (elapsed = payload[0])
            //
            // Note: hblock[code] "size" includes the delta prefix, so OA/CA/H(0x0A)/FL are commonly size==3.
            DateTime atEpoch(int epochSec) =>
                DateTime.fromMillisecondsSinceEpoch(epochSec * 1000, isUtc: true).toLocal();

            int clampEpoch(int epochSec) => (epochSec < 0) ? 0 : epochSec;

            if (code == 0x06 && size >= 3) {
              final elapsedSec = bytes[p + 0];
              final eTime = clampEpoch(tEpoch - elapsedSec);
              summary.events.add(
                Prs1Event(
                  time: atEpoch(eTime),
                  type: Prs1EventType.obstructiveApnea,
                  value: elapsedSec.toDouble(),
                  code: code,
                  sourceOffset: p,
                ),
              );
            } else if (code == 0x07 && size >= 3) {
              final elapsedSec = bytes[p + 0];
              final eTime = clampEpoch(tEpoch - elapsedSec);
              summary.events.add(
                Prs1Event(
                  time: atEpoch(eTime),
                  type: Prs1EventType.clearAirwayApnea,
                  value: elapsedSec.toDouble(),
                  code: code,
                  sourceOffset: p,
                ),
              );
            } else if (code == 0x0A && size >= 3) {
              final elapsedSec = bytes[p + 0];
              final eTime = clampEpoch(tEpoch - elapsedSec);
              summary.events.add(
                Prs1Event(
                  time: atEpoch(eTime),
                  type: Prs1EventType.hypopnea,
                  value: elapsedSec.toDouble(),
                  code: code,
                  sourceOffset: p,
                ),
              );
            } else if (code == 0x0B && size >= 4) {
              final elapsedSec = bytes[p + 1];
              final eTime = clampEpoch(tEpoch - elapsedSec);
              summary.events.add(
                Prs1Event(
                  time: atEpoch(eTime),
                  type: Prs1EventType.hypopnea,
                  value: elapsedSec.toDouble(),
                  code: code,
                  sourceOffset: p,
                ),
              );
            } else if ((code == 0x14 || code == 0x15) && size >= 3) {
              // Hypopnea variants seen in OSCAR PRS1 parser (family 0 / v6)
              final elapsedSec = bytes[p + 0];
              final eTime = clampEpoch(tEpoch - elapsedSec);
              summary.events.add(
                Prs1Event(
                  time: atEpoch(eTime),
                  type: Prs1EventType.hypopnea,
                  value: elapsedSec.toDouble(),
                  code: code,
                  sourceOffset: p,
                ),
              );
            } else if (code == 0x0C && size >= 3) {
              final elapsedSec = bytes[p + 0];
              final eTime = clampEpoch(tEpoch - elapsedSec);
              summary.events.add(
                Prs1Event(
                  time: atEpoch(eTime),
                  type: Prs1EventType.flowLimitation,
                  value: elapsedSec.toDouble(),
                  code: code,
                  sourceOffset: p,
                ),
              );
            } else if (code == 0x04 && size >= 3) {
              // Pressure Pulse (PP) - OSCAR: PRS1PressurePulseEvent (ParseEventsF0V6 case 0x04)
              final durationSec = bytes[p + 0];
              final eTime = clampEpoch(tEpoch);
              summary.events.add(
                Prs1Event(
                  time: atEpoch(eTime),
                  type: Prs1EventType.pressurePulse,
                  value: durationSec.toDouble(),
                  code: code,
                  sourceOffset: p,
                ),
              );
            } else if (code == 0x05 && size >= 3) {
              // RERA (RE) - OSCAR: PRS1RERAEvent
              final elapsedSec = bytes[p + 0];
              final eTime = clampEpoch(tEpoch - elapsedSec);
              summary.events.add(
                Prs1Event(
                  time: atEpoch(eTime),
                  type: Prs1EventType.rera,
                  value: elapsedSec.toDouble(),
                  code: code,
                  sourceOffset: p,
                ),
              );
            } else if (code == 0x0D && size == 2) {
              // Vibratory Snore (VS) - OSCAR: PRS1VibratorySnoreEvent
              // F0V6: VS record contains only the 16-bit delta-time prefix (no payload bytes).
              final eTime = clampEpoch(tEpoch);
              summary.events.add(
                Prs1Event(
                  time: atEpoch(eTime),
                  type: Prs1EventType.vibratorySnore,
                  value: 1.0,
                  code: code,
                  sourceOffset: p,
                ),
              );
            } else if (code == 0x12 && size >= 4) {
              // Snores-at-pressure summary (not time-distributed waveform).
              // OSCAR: PRS1SnoresAtPressureEvent (ParseEventsF0V6 case 0x12)
              // Layout (payload, no delta-time prefix for 0x12):
              //   payload[0] = mode (0=CPAP,1=EPAP,2=IPAP)
              //   payload[1] = pressure (0.1 cmH2O)
              //   payload[2..3] = u16 snore count
              final mode = bytes[p + 0];
              final pressureTenth = bytes[p + 1];
              final count = u16(p + 2);

              // Keep it as a snore-like discrete intensity at this epoch so the Snore chart can visualize.
              if (count > 0) {
                summary.events.add(
                  Prs1Event(
                    time: atEpoch(clampEpoch(tEpoch)),
                    type: Prs1EventType.snore,
                    value: count.toDouble(),
                    code: code,
                    sourceOffset: p,
                  ),
                );
              }

              // Also store a typed record if you later want to show pressure-linked snore stats.
              summary.events.add(
                Prs1Event(
                  time: atEpoch(clampEpoch(tEpoch)),
                  type: Prs1EventType.snoresAtPressure,
                  value: count.toDouble(),
                  code: code,
                  sourceOffset: p,
                  meta: {
                    'mode': mode,
                    'pressureTenth': pressureTenth,
                  },
                ),
              );
            } else if (code == 0x0E && size >= 3) {
              // Variable Breathing (VB)
              final elapsedSec = bytes[p + 0];
              final eTime = clampEpoch(tEpoch - elapsedSec);
              summary.events.add(
                Prs1Event(
                  time: atEpoch(eTime),
                  type: Prs1EventType.variableBreathing,
                  value: elapsedSec.toDouble(),
                  code: code,
                  sourceOffset: p,
                ),
              );
            } else if (code == 0x0F && size >= 3) {
              // Periodic Breathing (PB)
              final elapsedSec = bytes[p + 0];
              final eTime = clampEpoch(tEpoch - elapsedSec);
              summary.events.add(
                Prs1Event(
                  time: atEpoch(eTime),
                  type: Prs1EventType.periodicBreathing,
                  value: elapsedSec.toDouble(),
                  code: code,
                  sourceOffset: p,
                ),
              );
            } else if (code == 0x10 && size >= 3) {
              // Large Leak (LL)
              final elapsedSec = bytes[p + 0];
              final eTime = clampEpoch(tEpoch - elapsedSec);
              summary.events.add(
                Prs1Event(
                  time: atEpoch(eTime),
                  type: Prs1EventType.largeLeak,
                  value: elapsedSec.toDouble(),
                  code: code,
                  sourceOffset: p,
                ),
              );

            }

            // Pressure setting adjustment (OSCAR: PRS1PressureSetEvent) in F0V6.
            //
            // In OSCAR's xpap parser this is event code 0x02 ("Pressure adjustment")
            // and the payload byte is in 0.1 cmH2O.
            if (code == 0x01 && size >= 3) {
              // DreamStation (family 0 v6) "Pressure adjustment" (single pressure).
              // OSCAR: ParseEventsF0V6 -> case 0x01 -> PRS1PressureSetEvent(t, data[pos])
              final pressure = bytes[p + 0] / 10.0;
              summary.pressureSamples.add(
                Prs1SignalSample(
                  tEpochSec: tEpoch,
                  value: pressure,
                  signalType: Prs1SignalType.pressure,
                ),
              );
            } else if (code == 0x02 && size >= 4) {
              // DreamStation (family 0 v6) "Pressure adjustment" (bi-level).
              // Payload: [EPAP, IPAP] in 0.1 cmH2O. The OSCAR red line corresponds to IPAP/setpoint.
              final ipap = bytes[p + 1] / 10.0;
              summary.pressureSamples.add(
                Prs1SignalSample(
                  tEpochSec: tEpoch,
                  value: ipap,
                  signalType: Prs1SignalType.pressure,
                ),
              );
            }

            // Stats record (code 0x11): contains total leak + flex pressure average.
            // OSCAR (DreamStation / PRS1 v6):
            //   - TotalLeakEvent(t, data[pos])
            //   - FlexPressureAverageEvent(t, data[pos+2])
            //
            // In the wild, we have seen variants where the flex byte shifts (pos+1) or
            // is encoded with extra padding. We therefore decode defensively:
            //   1) Prefer payload[2] (OSCAR)
            //   2) Otherwise scan payload[1..] for the first value that looks like a
            //      pressure in 0.1 cmH2O within a sane range (4.0..25.0 => 40..250)
            //   3) Fallback to payload[1]
            if (code == 0x11) {
              summary.stats11Count += 1;
              summary.stats11Sizes.add(size);
              final payloadLen = (payloadStart + size) - p;
              if (payloadLen >= 2) {
                final leak = bytes[p + 0].toDouble();

                // DreamStation (family 0 v6) Statistics record layout (OSCAR ParseEventsF0V6):
                //   payload[0] = TotalLeak
                //   payload[1] = Snore count (per interval)
                //   payload[2] = FlexPressureAverage (0.1 cmH2O)
                //
                // The UI expects a minute-resolution snore series (bucket.snoreHeatmap1mCounts),
                // so we emit a Prs1EventType.snore with value == snoreCount at the interval time.
                if (payloadLen >= 3) {
                  final snoreCount = bytes[p + 1];
                  if (snoreCount > 0) {
                    summary.events.add(
                      Prs1Event(
                        time: atEpoch(tEpoch),
                        type: Prs1EventType.snore,
                        value: snoreCount.toDouble(),
                        code: code,
                        sourceOffset: p + 1,
                      ),
                    );
                  }
                }

                int pickFlexTenth() {
                  // 1) OSCAR expected position.
                  if (payloadLen >= 3) {
                    final v = bytes[p + 2];
                    if (v >= 40 && v <= 250) return v;
                  }
                  // 2) Scan remaining bytes for plausible 0.1 cmH2O pressure.
                  final scanStart = (payloadLen >= 3) ? 1 : 1;
                  for (int i = scanStart; i < payloadLen; i++) {
                    final v = bytes[p + i];
                    if (v >= 40 && v <= 250) return v;
                  }
                  // 3) Fallback.
                  return bytes[p + 1];
                }

                final flexTenth = pickFlexTenth();
                final flexPressureAvg = flexTenth / 10.0;

                summary.leakSamples.add(
                  Prs1SignalSample(tEpochSec: tEpoch, value: leak, signalType: Prs1SignalType.leak),
                );
                // Keep flex-pressure series separate from therapy setpoint (pressureSamples).
                summary.exhalePressureSamples.add(
                  Prs1SignalSample(tEpochSec: tEpoch, value: flexPressureAvg, signalType: Prs1SignalType.exhalePressure),
                );

                // Count only plausible samples.
                if (flexTenth >= 40 && flexTenth <= 250) {
                  summary.epapSampleCount += 1;
                }
              }
            }

            // Advance to next event start. The hblock size already includes the delta prefix.
            p = payloadStart + size;
          }

          // Keep deterministic ordering.
          summary.pressureSamples.sort((a, b) => a.tEpochSec.compareTo(b.tEpochSec));
          summary.exhalePressureSamples.sort((a, b) => a.tEpochSec.compareTo(b.tEpochSec));
          summary.leakSamples.sort((a, b) => a.tEpochSec.compareTo(b.tEpochSec));
          summary.events.sort((a, b) => a.time.compareTo(b.time));

          // ---- Debug output: prove whether we ever scanned 0x11 Statistics and extracted EPAP samples ----
          // This is intentionally loud in debug runs; it helps us decide whether the problem is:
          //   A) never reached 0x11, B) reached 0x11 but failed to pick flex byte, or C) downstream wiring.
          final probeLine = () {
            final sizes = (summary.stats11Sizes.toList()..sort());
            final epapHead = summary.exhalePressureSamples.take(3).map((e) => e.value.toStringAsFixed(1)).join(',');
            return 'PRS1[session=${summary.sessionId}] 0x11_stats=${summary.stats11Count} epap_samples=${summary.epapSampleCount} sizes=$sizes epap_head=[$epapHead] unknown=${summary.unknownEventCode == null ? "-" : "0x${summary.unknownEventCode!.toRadixString(16)}"}';
          }();

          // IMPORTANT: Web builds often don't show debug-level logs.
          // We intentionally emit this as INFO and also print() so it's visible in Chrome console.
          if (kPrs1CliVerbose) {
          Log.i(probeLine, tag: 'PRS1');
          // ignore: avoid_print
          print(probeLine);
        }
}
      }
    }

    // Settings/config chunk (.001) => best-effort extract AutoCPAP minimum pressure setting.
    //
    // DreamStation P-series often encodes pressure settings in 0.5 cmH2O steps.
    // We do not fully decode the settings schema yet; instead we scan payload bytes
    // for plausible "half-cm" values and use the median as a robust estimate.
    //
    // This is used to route/normalize EPAP-like pressure samples into therapy-pressure stats
    // so our reported Min/Median/P95/Max matches OSCAR's "Pressure Setting" row.
    if (htype == 0x00 && ext == 0x01 && t != null) {
      final hdr = parseNormalHeader(pos, fileVersion);
      if (hdr != null) {
        final dataStart = hdr.dataStart;
        final hblock = hdr.hblock;

        int p = dataStart;
        int tEpoch = ts;

        while (p < pos + blockSize) {
          final code = bytes[p++];
          if (!hblock.containsKey(code)) break;
          final size = hblock[code]!;
          if (p + size > pos + blockSize) break;

          final payloadStart = p;
          if (code != 0x12) {
            if (p + 2 > pos + blockSize) break;
            final dtSec = u16(p);
            tEpoch += dtSec;
            p += 2;
          }

          // Scan remaining bytes for half-cm pressure values (4.0..20.0 cmH2O).
          final remain = (payloadStart + size) - p;
          for (int i = 0; i < remain; i++) {
            final raw = bytes[p + i];
            if (raw < 8 || raw > 40) continue; // 4.0..20.0 in 0.5 steps
            final cm = raw / 2.0;
            summary._minPressureCandidates.add(cm);
          }

          p = payloadStart + size;
        }
      }
    }


    pos += blockSize;
  }

  final sessions = <Prs1Session>[];
  for (final s in bySession.values) {
    final start = s.start;
    final end = s.end;
    if (start == null || end == null) continue;
    final usedMin = (s.usageSeconds / 60).round();

    // ---- Pressure routing + baseline calibration ---------------------------------
    // OSCAR's "Pressure Setting" row reports therapy pressure (cmH2O) statistics.
    // For DreamStation AutoCPAP, our raw per-interval pressure samples are often EPAP-like
    // (lowered by Flex). To align with OSCAR, we normalize the series so that its minimum
    // matches the device's configured minimum pressure.
    //
    // 1) Extract a best-effort configured min pressure from settings chunks (.001).
    // 2) Compute epapMin from the raw series.
    // 3) Apply offset = (configuredMin - epapMin) to the whole series.
    //    If configuredMin is unavailable, fallback to (epapMin + 2.0) rounded to 0.5.
    if (s.minPressureSettingCmH2O == null && s._minPressureCandidates.isNotEmpty) {
      final sorted = List<double>.from(s._minPressureCandidates)..sort();
      s.minPressureSettingCmH2O = sorted[sorted.length ~/ 2];
    }

    // If we already decoded explicit pressure-setting events (0x02), use that
    // series as the therapy setpoint.
    final hasSetpointSeries = s.pressureSamples.isNotEmpty;

    // Otherwise we can only derive an EPAP/Flex-affected pressure average from
    // Stats 0x11; in that case we keep it as exhalePressureSamples and
    // (temporarily) normalize it to approximate OSCAR's therapy pressure stats.
    final epapMin = (s.exhalePressureSamples.isEmpty)
        ? null
        : (s.exhalePressureSamples.map((e) => e.value).reduce((a, b) => a < b ? a : b));

    final baseline = (s.minPressureSettingCmH2O != null)
        ? s.minPressureSettingCmH2O!
        : ((epapMin != null) ? ((epapMin + 2.0) * 2).round() / 2.0 : null);

    final derivedSetpointSamples = (!hasSetpointSeries && baseline != null && epapMin != null)
        ? s.exhalePressureSamples
            .map((e) => Prs1SignalSample(
                  tEpochSec: e.tEpochSec,
                  value: e.value + (baseline - epapMin),
                  signalType: Prs1SignalType.pressure,
                ))
            .toList(growable: false)
        : const <Prs1SignalSample>[];

    final therapyPressureSamples = hasSetpointSeries ? s.pressureSamples : derivedSetpointSamples;
    // -----------------------------------------------------------------------------

    
    final flowWf = (s.flowWaveLpm.isNotEmpty && (s.flowWaveSampleRateHz ?? 0) > 0)
        ? Prs1WaveformChannel(
            startEpochMs: s.flowWaveStartEpochMs ?? start.toUtc().millisecondsSinceEpoch,
            sampleRateHz: s.flowWaveSampleRateHz ?? 5.0,
            samples: Float32List.fromList(s.flowWaveLpm.map((e) => e.toDouble()).toList(growable: false)),
            unit: 'L/min',
            label: 'Flow',
          )
        : null;

sessions.add(
      Prs1Session(
        start: start,
        end: (s.usageSeconds > 0) ? start.add(Duration(seconds: s.usageSeconds)) : end,
        events: List.unmodifiable(s.events),
        pressureSamples: therapyPressureSamples,
        exhalePressureSamples: List.unmodifiable(s.exhalePressureSamples),
        leakSamples: s.leakSamples,
        flowWaveform: flowWf,
        sourcePath: sourcePath,
        sourceLabel: 'chunk',
        minutesUsed: usedMin,
        ahi: null,
        pressureMin: null,
        pressureMax: null,
        leakMedian: null,
      ),
    );
  }

  // Prefer latest-first.
  sessions.sort((a, b) => b.start.compareTo(a.start));
  return sessions;
}

enum Prs1FileKind {
  unknown,
  /// OSCAR-style "chunk" container files (Philips System One): .000/.001/.002/.003/.004/.005 ...
  /// These are NOT simple frame streams; they contain variable-size chunks with headers.
  chunk,

  /// Legacy experimental frame streams (kept for backwards compatibility).
  binary000,
  binary001,
  binary002,
  edf,
  other,
  ;

  static Prs1FileKind detect(Uint8List bytes, {String? sourcePath}) {
    // Prefer file extension when available; it is the most reliable for PRS1.
    final sp = (sourcePath ?? '').toLowerCase();
    // Philips System One chunk containers (.000~.005 etc)
    if (sp.endsWith('.000') || sp.endsWith('.001') || sp.endsWith('.002') || sp.endsWith('.003') || sp.endsWith('.004') || sp.endsWith('.005')) {
      // Heuristic: chunk header must be present and blockSize must be plausible.
      if (_looksLikePrs1Chunk(bytes)) return Prs1FileKind.chunk;
    }
    if (sp.endsWith('.edf')) return Prs1FileKind.edf;

    // Fallback: sniff EDF header.
    if (_looksLikeEdf(bytes)) return Prs1FileKind.edf;

    // Content sniff: PRS1 chunk header.
    if (_looksLikePrs1Chunk(bytes)) return Prs1FileKind.chunk;

    return Prs1FileKind.unknown;
  }

  static bool _looksLikePrs1Chunk(Uint8List bytes) {
    if (bytes.length < 16) return false;
    final fileVersion = bytes[0];
    if (fileVersion < 2 || fileVersion > 3) return false;
    final blockSize = bytes[1] | (bytes[2] << 8);
    if (blockSize < 16 || blockSize > bytes.length) return false;
    final htype = bytes[3];
    if (htype != 0x00 && htype != 0x01) return false;
    return true;
  }

  static bool _looksLikeEdf(Uint8List bytes) {
    if (bytes.length < 256) return false;

    // EDF version is 8 ASCII chars; commonly "0       ".
    final v = String.fromCharCodes(bytes.sublist(0, 8)).trim();
    if (v.isEmpty) return false;

    // Header bytes field is ASCII int at offset 184, len 8.
    final hbStr = String.fromCharCodes(bytes.sublist(184, 192)).trim();
    final hb = int.tryParse(hbStr);
    if (hb == null || hb < 256 || hb > 16384) return false;

    // Records field at offset 236, len 8 (ASCII int)
    final recStr = String.fromCharCodes(bytes.sublist(236, 244)).trim();
    final rec = int.tryParse(recStr);
    if (rec == null || rec < -1 || rec > 1000000) return false;

    return true;
  }
}


class Prs1DebugHeader {
  const Prs1DebugHeader({
    required this.length,
    required this.b0,
    required this.first16,
  });

  final int length;
  final int? b0;
  final Uint8List first16;
}

class Prs1ParseResult {
  const Prs1ParseResult({
    required this.kind,
    required this.magic,
    required this.header,
    required this.device,
    required this.sessions,
  });

  final Prs1FileKind kind;
  final String? magic;
  final Prs1DebugHeader header;
  final Prs1Device? device;
  final List<Prs1Session> sessions;
}