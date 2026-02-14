
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../features/prs1/aggregate/prs1_daily_models.dart';
import '../../features/prs1/model/prs1_event.dart';

/// Flow / Leak / Snore 交叉分析關聯圖
///
/// 目標：比照 OSCAR 的時間軸與滑移邏輯，把三種訊號在同一張圖上「對齊時間」疊加，
/// 用於肉眼觀察關聯（例如：漏氣上升時是否伴隨打鼾/氣流受限）。
///
/// - X 軸：固定以 20:30 local 為 bucket 起點，24h 視窗，可水平拖曳
/// - Y 軸：採用 0..1 的正規化尺度（各訊號各自以當日最大值正規化），避免單位不同無法同圖顯示
/// - Series:
///   - Flow：用 Flow Limitation (FL) 事件密度 / minute 作 proxy
///   - Leak：用 bucket.leakSamples（取每分鐘平均）
///   - Snore：用 bucket.snoreHeatmap1mCounts（每分鐘 count）
class Prs1ChartCrossAnalysis extends StatefulWidget {
  const Prs1ChartCrossAnalysis({
    super.key,
    required this.sessionStart,
    required this.sessionEnd,
    required this.bucket,
  });

  final DateTime sessionStart;
  final DateTime sessionEnd;
  final Prs1DailyBucket bucket;

  @override
  State<Prs1ChartCrossAnalysis> createState() => _Prs1ChartCrossAnalysisState();
}

class _Prs1ChartCrossAnalysisState extends State<Prs1ChartCrossAnalysis> {
  // Horizontal panning (in pixels).
  double _panX = 0.0;

  // Cache series (minute-resolution, aligned to 20:30 local).
  //
  // IMPORTANT:
  // Do NOT make these `late final`. This widget is reused while the user
  // navigates days/weeks; we must be able to rebuild the series multiple times.
  late List<double> _leak1m;
  late List<double> _snore1m;
  late List<double> _fl1m;

  double _leakMax = 1.0;
  double _snoreMax = 1.0;
  double _flMax = 1.0;

  @override
  void initState() {
    super.initState();
    _buildSeries();
  }

  @override
  void didUpdateWidget(covariant Prs1ChartCrossAnalysis oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Rebuild when the selected day changes OR the underlying bucket instance
    // changes (hot reload / data reload / week navigation).
    if (oldWidget.bucket.day != widget.bucket.day || oldWidget.bucket != widget.bucket) {
      _buildSeries();
      _panX = 0;
    }
  }

  void _buildSeries() {
    const minutes = 24 * 60;

    // Snore: already minute-aligned to 20:30 local (len=1440).
    final snoreCounts = widget.bucket.snoreHeatmap1mCounts;
    _snore1m = List<double>.generate(minutes, (i) => i < snoreCounts.length ? snoreCounts[i].toDouble() : 0.0);

    // FL: count events per minute (aligned to 20:30 local).
    _fl1m = List<double>.filled(minutes, 0.0);
    final axisStartLocal = _axisStart2030(widget.sessionStart.toLocal());
    for (final e in widget.bucket.events) {
      if (e.type != Prs1EventType.flowLimitation) continue;
      final t = e.time.toLocal();
      final dMin = t.difference(axisStartLocal).inMinutes;
      if (dMin >= 0 && dMin < minutes) {
        _fl1m[dMin] += 1.0;
      }
    }

    // Leak: bin per minute average from leakSamples (aligned to 20:30 local).
    _leak1m = List<double>.filled(minutes, 0.0);
    final leakCnt = List<int>.filled(minutes, 0);
    for (final sm in widget.bucket.leakSamples) {
      final t = sm.timeLocal;
      final dMin = t.difference(axisStartLocal).inMinutes;
      if (dMin >= 0 && dMin < minutes) {
        _leak1m[dMin] += sm.value;
        leakCnt[dMin] += 1;
      }
    }
    for (var i = 0; i < minutes; i++) {
      final c = leakCnt[i];
      _leak1m[i] = c == 0 ? 0.0 : (_leak1m[i] / c);
    }

    _leakMax = _safeMax(_leak1m);
    _snoreMax = _safeMax(_snore1m);
    _flMax = _safeMax(_fl1m);
  }

  double _safeMax(List<double> v) {
    double m = 0;
    for (final x in v) {
      if (x.isFinite && x > m) m = x;
    }
    return m <= 0 ? 1.0 : m;
  }


  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final startLocal = widget.sessionStart.toLocal();
    final endLocal = widget.sessionEnd.toLocal();
    final axisStartLocal = _axisStart2030(startLocal);
    final axisEndLocal = axisStartLocal.add(const Duration(hours: 24));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 2),
        Row(
          children: [
            const Text(
              '交叉分析圖',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
            ),
            const SizedBox(width: 10),
            _LegendDot(color: Colors.green.withOpacity(0.85)),
            const SizedBox(width: 6),
            Text('漏氣率', style: theme.textTheme.labelSmall),
            const SizedBox(width: 12),
            _LegendDot(color: scheme.error.withOpacity(0.85)),
            const SizedBox(width: 6),
            Text('氣流速率', style: theme.textTheme.labelSmall),
            const SizedBox(width: 12),
            _LegendDot(color: Colors.orange.withOpacity(0.85)),
            const SizedBox(width: 6),
            Text('打鼾震動', style: theme.textTheme.labelSmall),
            const Spacer(),
            Text(
              '${_fmtHm(startLocal)}–${_fmtHm(endLocal)}',
              style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurface.withOpacity(0.7)),
            ),
          ],
        ),
        const SizedBox(height: 8),
        LayoutBuilder(
          builder: (context, constraints) {
            final w = constraints.maxWidth;
            final plotH = 140.0;

            // Keep same "feel" as other charts: about 1.5~2.0 px per minute.
            // We clamp at min/max for safety.
            final pxPerMinute = (w / (24 * 60)).clamp(1.2, 2.2);

            return Container(
              height: plotH + 34,
              decoration: BoxDecoration(
                color: scheme.surface,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: theme.dividerColor.withOpacity(0.55)),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: GestureDetector(
                  onHorizontalDragUpdate: (d) {
                    setState(() {
                      _panX += d.delta.dx;
                      // Clamp pan so user can't scroll too far beyond 0..24h.
                      final maxPan = 0.0;
                      final minPan = -(24 * 60) * pxPerMinute;
                      _panX = _panX.clamp(minPan, maxPan);
                    });
                  },
                  child: CustomPaint(
                    painter: _CrossPainter(
                      axisStartLocal: axisStartLocal,
                      axisEndLocal: axisEndLocal,
                      pxPerMinute: pxPerMinute,
                      panX: _panX,
                      leak1m: _leak1m,
                      snore1m: _snore1m,
                      fl1m: _fl1m,
                      leakMax: _leakMax,
                      snoreMax: _snoreMax,
                      flMax: _flMax,
                      scheme: scheme,
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }


  


String _fmtHm(DateTime dt) {
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

}

class _CrossPainter extends CustomPainter {
  _CrossPainter({
    required this.axisStartLocal,
    required this.axisEndLocal,
    required this.pxPerMinute,
    required this.panX,
    required this.leak1m,
    required this.snore1m,
    required this.fl1m,
    required this.leakMax,
    required this.snoreMax,
    required this.flMax,
    required this.scheme,
  });

  final DateTime axisStartLocal;
  final DateTime axisEndLocal;
  final double pxPerMinute;
  final double panX;

  final List<double> leak1m;
  final List<double> snore1m;
  final List<double> fl1m;

  final double leakMax;
  final double snoreMax;
  final double flMax;

  final ColorScheme scheme;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;

    // background
    final bg = Paint()..color = scheme.surface;
    canvas.drawRect(rect, bg);

    final gridPaint = Paint()
      ..color = scheme.outlineVariant.withOpacity(0.35)
      ..strokeWidth = 1;

    final axisPaint = Paint()
      ..color = scheme.outlineVariant.withOpacity(0.75)
      ..strokeWidth = 1;

    const leftPad = 96.0;
    const bottomPad = 22.0;
    const topPad = 10.0;

    final plot = Rect.fromLTWH(leftPad, topPad, size.width - leftPad - 6, size.height - topPad - bottomPad);

    // frame
    canvas.drawRect(plot, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = scheme.outlineVariant.withOpacity(0.65));

    // horizontal grid (0, 0.5, 1.0)
    for (final f in [0.0, 0.5, 1.0]) {
      final y = plot.bottom - f * plot.height;
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), f == 0 ? axisPaint : gridPaint);

      final tp = TextPainter(
        text: TextSpan(
          text: f.toStringAsFixed(1),
          style: TextStyle(color: scheme.onSurface.withOpacity(0.55), fontSize: 11, fontWeight: FontWeight.w600),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(plot.left - tp.width - 6, y - tp.height / 2));
    }

    // vertical hour grid & labels (match other charts).
    _drawTimeAxis(canvas, plot);

    // series paints
    final pLeak = Paint()
      ..color = Colors.green.shade600.withOpacity(0.95)
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;

    final pSnore = Paint()
      ..color = Colors.red.shade500.withOpacity(0.95)
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;

    final pFlow = Paint()
      ..color = Colors.orange.shade700.withOpacity(0.95)
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;

    _drawSeries(canvas, plot, leak1m, leakMax, pLeak);
    _drawSeries(canvas, plot, snore1m, snoreMax, pSnore);
    _drawSeries(canvas, plot, fl1m, flMax, pFlow);
  }

  void _drawSeries(Canvas canvas, Rect plot, List<double> v, double vmax, Paint paint) {
    if (v.isEmpty) return;
    final path = Path();
    bool started = false;
    // Use minute index to x mapping
    for (var i = 0; i < v.length; i++) {
      final x = plot.left + (i * pxPerMinute) + panX;
      if (x < plot.left - 2 || x > plot.right + 2) continue;

      final yNorm = (v[i] / vmax).clamp(0.0, 1.0);
      final y = plot.bottom - yNorm * plot.height;

      if (!started) {
        path.moveTo(x, y);
        started = true;
      } else {
        path.lineTo(x, y);
      }
    }
    if (started) canvas.drawPath(path, paint);
  }

  void _drawTimeAxis(Canvas canvas, Rect plot) {
    final labelStyle = TextStyle(color: scheme.onSurface.withOpacity(0.55), fontSize: 11, fontWeight: FontWeight.w600);
    final tickPaint = Paint()
      ..color = scheme.outlineVariant.withOpacity(0.55)
      ..strokeWidth = 1;

    // Hourly ticks aligned like other charts:
    // Axis starts at 20:30, but labels/grid are at 21:00, 22:00, ... (next-day) 09:00.
    final start = axisStartLocal;
    final end = axisEndLocal;

    // Draw a start marker at 20:30 (no label).
    final x0 = plot.left + panX;
    if (x0 >= plot.left - 1 && x0 <= plot.right + 1) {
      canvas.drawLine(Offset(x0, plot.top), Offset(x0, plot.bottom), tickPaint);
    }

    DateTime first;
    if (start.minute == 0 && start.second == 0) {
      first = start;
    } else {
      first = DateTime(start.year, start.month, start.day, start.hour).add(const Duration(hours: 1));
    }

    for (var t = first; !t.isAfter(end); t = t.add(const Duration(hours: 1))) {
      final minFromStart = t.difference(start).inMinutes;
      final x = plot.left + minFromStart * pxPerMinute + panX;

      if (x < plot.left - 1 || x > plot.right + 1) continue;

      canvas.drawLine(Offset(x, plot.top), Offset(x, plot.bottom), tickPaint);

      final label = '${t.hour.toString().padLeft(2, '0')}:00';
      final tp = TextPainter(text: TextSpan(text: label, style: labelStyle), textDirection: TextDirection.ltr)..layout();
      tp.paint(canvas, Offset(x - tp.width / 2, plot.bottom + 4));
    }
  }

  @override
  bool shouldRepaint(covariant _CrossPainter oldDelegate) {
    return oldDelegate.panX != panX ||
        oldDelegate.pxPerMinute != pxPerMinute ||
        oldDelegate.leak1m != leak1m ||
        oldDelegate.snore1m != snore1m ||
        oldDelegate.fl1m != fl1m;
  }
}

DateTime _axisStart2030(DateTime local) {
  // Align to OSCAR-like day window starting at 20:30 local.
  // If the session is after midnight, OSCAR's "day" still starts at 20:30
  // of the previous calendar day.
  final today2030 = DateTime(local.year, local.month, local.day, 20, 30);
  if (local.isBefore(today2030)) {
    return today2030.subtract(const Duration(days: 1));
  }
  return today2030;
}

/// Simple card wrapper matching other chart cards in the project.

class _LegendDot extends StatelessWidget {
  final Color color;
  final double size;

  const _LegendDot({
    required this.color,
    this.size = 8,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
      ),
    );
  }
}

