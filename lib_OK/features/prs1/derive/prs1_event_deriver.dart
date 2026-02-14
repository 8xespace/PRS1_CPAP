import 'package:tophome/features/prs1/model/prs1_event.dart';

/// Derivation layer for event markers.
///
/// - Phase 1: normalize decoded events into the lanes we display (PB/LL/CA/OA/H/FL/RE/VS/VS2/PP/BND).
/// - Future: derive additional events from waveform channels (e.g. auto-detected RERA/snore/flow limits),
///           and/or merge multi-source event streams.
class Prs1EventDeriver {
  static List<Prs1Event> derive({
    required List<Prs1Event> decodedEvents,
  }) {
    final out = <Prs1Event>[];

    for (final e in decodedEvents) {
      // Normalize legacy/alternate snore typing.
      //
      // OSCAR treats the "Snore count" statistic (continuous numeric channel) as the basis
      // for VS2 indexing/flags, while the precise vibratory snore markers (VS) come from
      // a different event stream.
      //
      // Therefore, when a firmware emits only `snore` without explicit VS/VS2, we:
      //   1) keep the original `snore` event (used by the snore heatmap/chart), and
      //   2) also emit a VS2 flag event so it can appear in the Event Markers lanes.
      if (e.type == Prs1EventType.snore) {
        out.add(e);
        final v = (e.value == null || (e.value ?? 0) <= 0) ? 1.0 : e.value;
        out.add(
          Prs1Event(
            time: e.time,
            type: Prs1EventType.vibratorySnore2,
            value: v,
            code: e.code,
            sourceOffset: e.sourceOffset,
            meta: e.meta,
          ),
        );
        continue;
      }

      out.add(e);
    }

    out.sort((a, b) => a.time.compareTo(b.time));

    // Downsample dense VS/VS2 streams (some records are intensity samples).
    // OSCAR displays these as sparse tick events; we collapse adjacent samples into one event.
    const vsGap = Duration(seconds: 10);
    const vs2Gap = Duration(seconds: 10);

    final filtered = <Prs1Event>[];
    Prs1Event? lastVs;
    Prs1Event? lastVs2;

    for (final e in out) {
      if (e.type == Prs1EventType.vibratorySnore) {
        final v = (e.value ?? 0);
        if (v <= 0) continue;
        if (lastVs != null && e.time.difference(lastVs!.time).abs() < vsGap) continue;
        lastVs = e;
        filtered.add(e);
        continue;
      }
      if (e.type == Prs1EventType.vibratorySnore2) {
        final v = (e.value ?? 0);
        if (v <= 0) continue;
        if (lastVs2 != null && e.time.difference(lastVs2!.time).abs() < vs2Gap) continue;
        lastVs2 = e;
        filtered.add(e);
        continue;
      }
      filtered.add(e);
    }

    return filtered;
  }
}
