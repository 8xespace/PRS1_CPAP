// lib/features/prs1/decode/event_decoder.dart
//
// Layer 6: EventDecoder now runs:
//   frames -> (sub)records -> registry-driven event parsing
//
// This keeps Web compilation stable while we progressively replace heuristics
// with OSCAR-equivalent tables.

import '../model/prs1_event.dart';
import 'event_registry.dart';
import 'frame_decoder.dart';
import 'record_decoder.dart';

class EventDecoder {
  EventDecoder({EventRegistry? registry}) : _registry = registry ?? EventRegistry();

  final EventRegistry _registry;

  List<Prs1Event> decodeFrames(
    Iterable<Prs1Frame> frames, {
    required DateTime sessionStart,
  }) {
    final out = <Prs1Event>[];
    const rd = RecordDecoder();

    for (final f in frames) {
      for (final rec in rd.decode(f)) {
        out.addAll(_registry.decodeRecord(rec, fallbackStart: sessionStart));
      }
    }

    return out;
  }
}
