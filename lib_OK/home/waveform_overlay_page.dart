// lib/home/waveform_overlay_page.dart
//
// Milestone UI: OSCAR-like timeline overlay with pan/zoom/cursor.
//
// This is a sandbox viewer to exercise the engine-side viewport API without
// committing to final product UI.

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../features/prs1/aggregate/prs1_daily_models.dart';
import '../features/prs1/model/prs1_event.dart';
import '../features/prs1/stats/prs1_rolling_metrics.dart';
import '../features/prs1/stats/prs1_episode_correlation.dart';
import '../features/prs1/waveform/prs1_viewport_api.dart';
import '../features/prs1/waveform/prs1_waveform_index.dart';
import '../features/prs1/waveform/prs1_waveform_types.dart';

class WaveformOverlayPage extends StatefulWidget {
  const WaveformOverlayPage({super.key});

  @override
  State<WaveformOverlayPage> createState() => _WaveformOverlayPageState();
}

class _WaveformOverlayPageState extends State<WaveformOverlayPage> {
  int _dayIndex = 0;

  // Viewport in epoch ms.
  int _startMs = 0;
  int _endMs = 0;

  // Cursor position in epoch ms (nullable).
  int? _cursorMs;

  // Gesture state
  double? _scaleStartSpanMs;
  int? _scaleStartMidMs;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final app = AppState.of(context);
    final buckets = app.prs1DailyBuckets;
    if (buckets.isEmpty) return;

    _dayIndex = _dayIndex.clamp(0, buckets.length - 1);
    final day = buckets[_dayIndex].day.toUtc();
    final dayStartMs = day.millisecondsSinceEpoch;
    final dayEndMs = dayStartMs + 24 * 3600 * 1000;

    // Initialize viewport only once per page open.
    if (_startMs == 0 && _endMs == 0) {
      // Default: show 2 hours starting at first slice start if present.
      int initStart = dayStartMs;
      final sl = buckets[_dayIndex].slices;
      if (sl.isNotEmpty) {
        initStart = sl.first.start.toUtc().millisecondsSinceEpoch;
      }
      final initEnd = (initStart + 2 * 3600 * 1000).clamp(dayStartMs, dayEndMs);
      _startMs = initStart;
      _endMs = initEnd;
    } else {
      // Clamp to the current day.
      _startMs = _startMs.clamp(dayStartMs, dayEndMs - 1000);
      _endMs = _endMs.clamp(_startMs + 1000, dayEndMs);
    }
  }

  void _setDay(int idx) {
    final app = AppState.of(context);
    final buckets = app.prs1DailyBuckets;
    if (buckets.isEmpty) return;

    final i = idx.clamp(0, buckets.length - 1);
    setState(() {
      _dayIndex = i;
      _cursorMs = null;

      final dayStartMs = buckets[i].day.toUtc().millisecondsSinceEpoch;
      final dayEndMs = dayStartMs + 24 * 3600 * 1000;

      // Reset to first slice start for that day.
      int initStart = dayStartMs;
      final sl = buckets[i].slices;
      if (sl.isNotEmpty) initStart = sl.first.start.toUtc().millisecondsSinceEpoch;
      final initEnd = (initStart + 2 * 3600 * 1000).clamp(dayStartMs, dayEndMs);
      _startMs = initStart;
      _endMs = initEnd;
    });
  }

  void _pan(double dx, double widthPx) {
    if (widthPx <= 0) return;
    final span = _endMs - _startMs;
    final dt = (-dx / widthPx) * span;
    final app = AppState.of(context);
    final buckets = app.prs1DailyBuckets;
    if (buckets.isEmpty) return;

    final dayStartMs = buckets[_dayIndex].day.toUtc().millisecondsSinceEpoch;
    final dayEndMs = dayStartMs + 24 * 3600 * 1000;

    int newStart = (_startMs + dt).round();
    int newEnd = newStart + span;

    if (newStart < dayStartMs) {
      newStart = dayStartMs;
      newEnd = newStart + span;
    }
    if (newEnd > dayEndMs) {
      newEnd = dayEndMs;
      newStart = newEnd - span;
    }
    setState(() {
      _startMs = newStart;
      _endMs = newEnd;
    });
  }

  void _zoom(double scale, double focalDx, double widthPx) {
    if (widthPx <= 0) return;
    final app = AppState.of(context);
    final buckets = app.prs1DailyBuckets;
    if (buckets.isEmpty) return;

    final dayStartMs = buckets[_dayIndex].day.toUtc().millisecondsSinceEpoch;
    final dayEndMs = dayStartMs + 24 * 3600 * 1000;

    final oldSpan = (_scaleStartSpanMs ?? (_endMs - _startMs)).toDouble();
    final mid = (_scaleStartMidMs ?? ((_startMs + _endMs) ~/ 2));

    final targetSpan = (oldSpan / scale).clamp(5 * 1000.0, 12 * 3600 * 1000.0);
    // keep focal point stable: map focal x to time.
    final frac = (focalDx / widthPx).clamp(0.0, 1.0);
    final focalMs = (_startMs + frac * (_endMs - _startMs)).round();

    int newStart = (focalMs - frac * targetSpan).round();
    int newEnd = newStart + targetSpan.round();

    // Clamp to day bounds
    if (newStart < dayStartMs) {
      newStart = dayStartMs;
      newEnd = newStart + targetSpan.round();
    }
    if (newEnd > dayEndMs) {
      newEnd = dayEndMs;
      newStart = newEnd - targetSpan.round();
    }

    setState(() {
      _startMs = newStart;
      _endMs = newEnd;
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = AppState.of(context);
    final buckets = app.prs1DailyBuckets;
    final index = app.prs1WaveformIndex;

    if (buckets.isEmpty || index == null) {
      return const Scaffold(
        body: Center(child: Text('No PRS1 data loaded')),
      );
    }

    final bucket = buckets[_dayIndex];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Waveform Overlay'),
        actions: [
          DropdownButton<int>(
            value: _dayIndex,
            underline: const SizedBox.shrink(),
            onChanged: (v) {
              if (v == null) return;
              _setDay(v);
            },
            items: List.generate(buckets.length, (i) {
              final d = buckets[i].day;
              final label = '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
              return DropdownMenuItem(value: i, child: Text(label));
            }),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, c) {
          final width = c.maxWidth;
          final height = c.maxHeight;

          final maxBuckets = width.isFinite ? math.max(400, width.round()) : 800;

          final viewport = Prs1ViewportApi.fromDailyBucket(
            waveformIndex: index,
            bucket: bucket,
            startEpochMs: _startMs,
            endEpochMsExclusive: _endMs,
            maxBuckets: maxBuckets,
          );

          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) {
              final frac = (d.localPosition.dx / width).clamp(0.0, 1.0);
              final t = (_startMs + frac * (_endMs - _startMs)).round();
              setState(() => _cursorMs = t);
            },
            onHorizontalDragUpdate: (d) => _pan(d.delta.dx, width),
            onScaleStart: (d) {
              _scaleStartSpanMs = (_endMs - _startMs).toDouble();
              _scaleStartMidMs = ((_startMs + _endMs) ~/ 2);
            },
            onScaleUpdate: (d) {
              // ignore if it's essentially a pan gesture from scale detector
              if (d.scale.isFinite && (d.scale - 1.0).abs() > 0.01) {
                _zoom(d.scale, d.focalPoint.dx, width);
              } else if (d.focalPointDelta.dx.abs() > 0.5) {
                _pan(d.focalPointDelta.dx, width);
              }
            },
            onScaleEnd: (_) {
              _scaleStartSpanMs = null;
              _scaleStartMidMs = null;
            },
            child: CustomPaint(
              size: Size(width, height),
              painter: _WaveformOverlayPainter(
                viewport: viewport,
                cursorEpochMs: _cursorMs,
              ),
            ),
          );
        },
      ),
    );
  }
}

class _WaveformOverlayPainter extends CustomPainter {
  _WaveformOverlayPainter({
    required this.viewport,
    required this.cursorEpochMs,
  });

  final Prs1ViewportResult viewport;
  final int? cursorEpochMs;

  static const _signals = [
    Prs1WaveformSignal.flow,
    Prs1WaveformSignal.pressure,
    Prs1WaveformSignal.leak,
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final padL = 48.0;
    final padR = 8.0;
    final padT = 8.0;
    final padB = 24.0;

    final plotW = size.width - padL - padR;
    final plotH = size.height - padT - padB;
    if (plotW <= 10 || plotH <= 10) return;

    final trackH = plotH / 4.0; // 3 wave tracks + FL track
    final x0 = padL;
    final y0 = padT;

    // Background
    final bg = Paint()..color = const Color(0xFF101214);
    canvas.drawRect(Offset.zero & size, bg);

    // Grid lines
    final grid = Paint()
      ..color = const Color(0xFF2A2D33)
      ..strokeWidth = 1.0;

    for (int i = 0; i <= 4; i++) {
      final y = y0 + i * trackH;
      canvas.drawLine(Offset(x0, y), Offset(x0 + plotW, y), grid);
    }

    // Heatmap (snore minute counts) in FL track background
    _drawHeatmap(canvas, Rect.fromLTWH(x0, y0 + 3 * trackH, plotW, trackH));

    // Waveform tracks
    for (int i = 0; i < _signals.length; i++) {
      _drawWaveTrack(
        canvas,
        signal: _signals[i],
        rect: Rect.fromLTWH(x0, y0 + i * trackH, plotW, trackH),
      );
    }

    // Flow Limitation curves (on FL track)
    _drawFlowLimitationTrack(canvas, Rect.fromLTWH(x0, y0 + 3 * trackH, plotW, trackH));

    // Event markers (top track)
    _drawEvents(canvas, Rect.fromLTWH(x0, y0, plotW, trackH));

    // Snore episodes overlay (FL track)
    _drawSnoreEpisodes(canvas, Rect.fromLTWH(x0, y0 + 3 * trackH, plotW, trackH));

    // Leak episodes overlay (leak track)
    _drawLeakEpisodes(canvas, Rect.fromLTWH(x0, y0 + 2 * trackH, plotW, trackH));

    // Cursor
    if (cursorEpochMs != null) {
      final x = _tToX(cursorEpochMs!, x0, plotW);
      final p = Paint()
        ..color = const Color(0xFFE6E6E6)
        ..strokeWidth = 1.0;
      canvas.drawLine(Offset(x, y0), Offset(x, y0 + plotH), p);
    }

    // Axes label (simple)
    final tp = TextPainter(
      text: TextSpan(
        text: 'pan / pinch-zoom / tap for cursor',
        style: const TextStyle(color: Color(0xFFB7BCC7), fontSize: 12),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: size.width);
    tp.paint(canvas, Offset(8, size.height - 18));
  }

  void _drawWaveTrack(Canvas canvas, {required Prs1WaveformSignal signal, required Rect rect}) {
    final pts = viewport.waveforms[signal] ?? const [];
    if (pts.isEmpty) return;

    // Find global min/max for scaling.
    double minV = double.infinity;
    double maxV = double.negativeInfinity;
    for (final p in pts) {
      if (p.min.isNaN || p.max.isNaN) continue;
      minV = math.min(minV, p.min);
      maxV = math.max(maxV, p.max);
    }
    if (!minV.isFinite || !maxV.isFinite || (maxV - minV).abs() < 1e-9) {
      minV = 0;
      maxV = 1;
    }

    final stroke = Paint()
      ..color = const Color(0xFF7EE787)
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;

    final fill = Paint()
      ..color = const Color(0x337EE787)
      ..style = PaintingStyle.fill;

    final path = Path();
    final path2 = Path();

    for (int i = 0; i < pts.length; i++) {
      final x = rect.left + (i / math.max(1, pts.length - 1)) * rect.width;
      final yMin = rect.bottom - ((pts[i].min - minV) / (maxV - minV)) * rect.height;
      final yMax = rect.bottom - ((pts[i].max - minV) / (maxV - minV)) * rect.height;

      if (i == 0) {
        path.moveTo(x, yMax);
        path2.moveTo(x, yMin);
      } else {
        path.lineTo(x, yMax);
        path2.lineTo(x, yMin);
      }
    }

    // close area between min and max
    final area = Path()..addPath(path, Offset.zero);
    final rev = Path();
    for (int i = pts.length - 1; i >= 0; i--) {
      final x = rect.left + (i / math.max(1, pts.length - 1)) * rect.width;
      final yMin = rect.bottom - ((pts[i].min - minV) / (maxV - minV)) * rect.height;
      if (i == pts.length - 1) {
        rev.moveTo(x, yMin);
      } else {
        rev.lineTo(x, yMin);
      }
    }
    area.addPath(rev, Offset.zero);
    area.close();

    canvas.drawPath(area, fill);
    canvas.drawPath(path, stroke);
    canvas.drawPath(path2, stroke);

    // label
    final label = signal.name.toUpperCase();
    final tp = TextPainter(
      text: TextSpan(text: label, style: const TextStyle(color: Color(0xFFB7BCC7), fontSize: 11)),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: rect.width);
    tp.paint(canvas, Offset(rect.left + 4, rect.top + 2));
  }

  void _drawHeatmap(Canvas canvas, Rect rect) {
    final maxC = viewport.snoreHeatmap1mMaxCount;
    if (maxC <= 0) return;

    final p = Paint()..style = PaintingStyle.fill;
    for (final tp in viewport.snoreHeatmap1mCounts) {
      final v = tp.value ?? 0.0;
      final intensity = ((maxC <= 0) ? 0.0 : (v / maxC)).clamp(0.0, 1.0);
      if (intensity <= 0) continue;
      final x = _tToX(tp.tEpochSec * 1000, rect.left, rect.width);
      // 1 minute width in pixels
      final minW = (60 * 1000) / (viewport.endEpochMsExclusive - viewport.startEpochMs) * rect.width;
      p.color = Color.fromARGB((20 + 120 * intensity).round(), 255, 200, 0);
      canvas.drawRect(Rect.fromLTWH(x, rect.top, math.max(1.0, minW), rect.height), p);
    }
  }

  void _drawEvents(Canvas canvas, Rect rect) {
    final p = Paint()
      ..color = const Color(0xFF58A6FF)
      ..strokeWidth = 1.0;
    for (final e in viewport.events) {
      final x = _tToX(e.time.toUtc().millisecondsSinceEpoch, rect.left, rect.width);
      canvas.drawLine(Offset(x, rect.top), Offset(x, rect.bottom), p);
    }
  }

  void _drawSnoreEpisodes(Canvas canvas, Rect rect) {
    final p = Paint()..style = PaintingStyle.fill;
    for (final e in viewport.snoreEpisodes) {
      final x0 = _tToX(e.startEpochMs, rect.left, rect.width);
      final x1 = _tToX(e.endEpochMsExclusive, rect.left, rect.width);
      final inten = (e.peakDensityPerMin60s / 10.0).clamp(0.1, 1.0);
      p.color = Color.fromARGB((30 + 80 * inten).round(), 255, 120, 120);
      canvas.drawRect(Rect.fromLTWH(x0, rect.top, math.max(1.0, x1 - x0), rect.height), p);
    }
  }

  void _drawLeakEpisodes(Canvas canvas, Rect rect) {
    final p = Paint()..style = PaintingStyle.fill;
    for (final e in viewport.leakEpisodes) {
      final x0 = _tToX(e.startEpochSec * 1000, rect.left, rect.width);
      final x1 = _tToX(e.endEpochSecExclusive * 1000, rect.left, rect.width);
      p.color = const Color(0x3358A6FF);
      canvas.drawRect(Rect.fromLTWH(x0, rect.top, math.max(1.0, x1 - x0), rect.height), p);
    }
  }

  void _drawFlowLimitationTrack(Canvas canvas, Rect rect) {
    // draw 5m and 15m EMA curves (0..1) in FL track.
    void drawSeries(List<Prs1TimePoint> series, Color color) {
      if (series.isEmpty) return;
      final path = Path();
      for (int i = 0; i < series.length; i++) {
        final tMs = series[i].tEpochSec * 1000;
        final x = _tToX(tMs, rect.left, rect.width);
        final v = series[i].value;
         if (v == null || v.isNaN) continue;
         final y = rect.bottom - (v.clamp(0.0, 1.0)) * rect.height;
        if (i == 0) path.moveTo(x, y);
        else path.lineTo(x, y);
      }
      final p = Paint()
        ..color = color
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke;
      canvas.drawPath(path, p);
    }

    drawSeries(viewport.flowLimitation5mEmaSeries, const Color(0xFFE6E6E6));
    drawSeries(viewport.flowLimitation15mEmaSeries, const Color(0xFFB7BCC7));

    // severity band strip at bottom
    final bands = viewport.flowLimitationSeverityBands5mEma;
    if (bands.isNotEmpty) {
      final p = Paint()..style = PaintingStyle.fill;
      for (int i = 0; i < bands.length; i++) {
        final b = bands[i];
        if (b < 0) continue;
        final x0 = rect.left + (i / bands.length) * rect.width;
        final x1 = rect.left + ((i + 1) / bands.length) * rect.width;
        if (b == 0) p.color = const Color(0x2200FF00);
        if (b == 1) p.color = const Color(0x22FFFF00);
        if (b >= 2) p.color = const Color(0x22FF0000);
        canvas.drawRect(Rect.fromLTWH(x0, rect.bottom - 6, x1 - x0, 6), p);
      }
    }

    final tp = TextPainter(
      text: const TextSpan(text: 'FL (EMA)', style: TextStyle(color: Color(0xFFB7BCC7), fontSize: 11)),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: rect.width);
    tp.paint(canvas, Offset(rect.left + 4, rect.top + 2));
  }

  double _tToX(int epochMs, double left, double width) {
    final t0 = viewport.startEpochMs;
    final t1 = viewport.endEpochMsExclusive;
    if (t1 <= t0) return left;
    final frac = ((epochMs - t0) / (t1 - t0)).clamp(0.0, 1.0);
    return left + frac * width;
  }

  @override
  bool shouldRepaint(covariant _WaveformOverlayPainter oldDelegate) {
    return oldDelegate.viewport.startEpochMs != viewport.startEpochMs ||
        oldDelegate.viewport.endEpochMsExclusive != viewport.endEpochMsExclusive ||
        oldDelegate.cursorEpochMs != cursorEpochMs ||
        oldDelegate.viewport.waveforms != viewport.waveforms ||
        oldDelegate.viewport.events != viewport.events ||
        oldDelegate.viewport.flowLimitation5mEmaSeries != viewport.flowLimitation5mEmaSeries ||
        oldDelegate.viewport.flowLimitation15mEmaSeries != viewport.flowLimitation15mEmaSeries ||
        oldDelegate.viewport.snoreEpisodes != viewport.snoreEpisodes ||
        oldDelegate.viewport.leakEpisodes != viewport.leakEpisodes;
  }
}
