import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../features/prs1/aggregate/prs1_daily_models.dart';

/// 吸氣時間 (Insp Time)
///
/// Phase 3：最小可用 UI
/// - 架構比照 prs1_chart_minute_vent.dart（ScrollController + CustomPainter）
/// - X 軸：以 20:30 為起算點，顯示 21:00~09:00；其餘 09:00~21:00 透過水平拖曳/捲動顯示。
/// - Y 軸：動態刻度（浮動設定），單位：秒 (s)
///
/// 重要：不改動資料引擎，只吃 DailyBucket 的 rolling time series。
class Prs1ChartInspTime extends StatefulWidget {
  const Prs1ChartInspTime({
    super.key,
    required this.sessionStart,
    required this.sessionEnd,
    required this.bucket,
  });

  static const String chartTitle = '吸氣時間';

  final DateTime sessionStart;
  final DateTime sessionEnd;
  final Prs1DailyBucket bucket;

  @override
  State<Prs1ChartInspTime> createState() => _Prs1ChartInspTimeState();
}

class _Prs1ChartInspTimeState extends State<Prs1ChartInspTime> {
  final ScrollController _hCtrl = ScrollController();

  @override
  void dispose() {
    _hCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    final startLocal = widget.sessionStart.toLocal();
    final axisStartLocal = _axisStart2030(startLocal);
    final axisEndLocal = axisStartLocal.add(const Duration(hours: 24));
    final totalMin = axisEndLocal.difference(axisStartLocal).inMinutes;

    // Collect series from bucket rolling channels.
    final pts = <_Pt>[];
    for (final sm in widget.bucket.rollingInspTime5m) {
      final v = sm.value;
      if (v == null) continue;
      pts.add(_Pt(tEpochSec: sm.tEpochSec, v: v));
    }
    pts.sort((a, b) => a.tEpochSec.compareTo(b.tEpochSec));

    // Phase 4：OSCAR 對齊（固定尺度）
    // - OSCAR 截圖：吸氣時間 Y 軸上限約 13.0 秒
    // - 仍保護性：若資料超過 13，改用自動 nice axis 避免截斷。
    final maxVal = _maxV(pts);
    final y = _fixedAxis(
      fixedMax: 13.0,
      fixedTicks: const [0.0, 4.3, 8.7, 13.0],
      dataMax: maxVal.isFinite ? maxVal : 0.0,
    );

    return LayoutBuilder(
      builder: (context, c) {
        final maxW = c.maxWidth.isFinite ? c.maxWidth : 900.0;
        final chartViewportW = math.max(0.0, maxW - _labelW);
        // keep pxPerMinute consistent with leak/pressure/minute-vent charts
        final pxPerMinute = (chartViewportW / 750.0) * 0.95;
        final contentW = totalMin * pxPerMinute;

        void onDragHorizontal(DragUpdateDetails d) {
          if (!_hCtrl.hasClients) return;
          final max = _hCtrl.position.maxScrollExtent;
          final next = (_hCtrl.offset - d.delta.dx).clamp(0.0, max);
          _hCtrl.jumpTo(next);
        }

        final lineColor = Colors.indigo.withOpacity(0.85);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 2),
            Row(
              children: [
                const Text(
                  Prs1ChartInspTime.chartTitle,
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
                ),
                const SizedBox(width: 10),
                _LegendDot(color: lineColor),
                const Spacer(),
              ],
            ),
            const SizedBox(height: 8),
            Container(
              height: _chartH,
              decoration: BoxDecoration(
                color: cs.surface,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: theme.dividerColor.withOpacity(0.25)),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: Row(
                  children: [
                    SizedBox(
                      width: _labelW,
                      child: CustomPaint(
                        size: const Size(_labelW, _chartH),
                        painter: _AxisPainter(theme: theme, tickMin: y.tickMin, tickMax: y.tickMax, ticks: y.ticks, unit: 's'),
                      ),
                    ),
                    Expanded(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onPanUpdate: onDragHorizontal,
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          controller: _hCtrl,
                          physics: const ClampingScrollPhysics(),
                          child: CustomPaint(
                            size: Size(contentW, _chartH),
                            painter: _SeriesPainter(
                              theme: theme,
                              axisStartLocal: axisStartLocal,
                              axisEndLocal: axisEndLocal,
                              pxPerMinute: pxPerMinute,
                              tickMin: y.tickMin,
                              tickMax: y.tickMax,
                              ticks: y.ticks,
                              pts: pts,
                              lineColor: lineColor,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

const double _chartH = 160.0;
const double _labelW = 96.0; // 對齊事件標記/氣流/壓力/漏氣 左欄切線

class _LegendDot extends StatelessWidget {
  const _LegendDot({required this.color});
  final Color color;
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

class _AxisPainter extends CustomPainter {
  _AxisPainter({required this.theme, required this.tickMin, required this.tickMax, required this.ticks, required this.unit});
  final ThemeData theme;
  final double tickMin;
  final double tickMax;
  final List<double> ticks;
  final String unit;

  @override
  void paint(Canvas canvas, Size size) {
    final cs = theme.colorScheme;
    final textStyle = theme.textTheme.labelSmall?.copyWith(color: cs.onSurface.withOpacity(0.75));

    const double topPad = 6.0;
    const double xAxisH = 26.0;
    final plotH = math.max(0.0, size.height - topPad - xAxisH);
    final scaleY = plotH / math.max(1e-9, (tickMax - tickMin));
    double yOf(double v) => (topPad + plotH) - ((v - tickMin) * scaleY);

    // y-axis line (darker, like OSCAR)
    final axisPaint = Paint()
      ..color = theme.dividerColor.withOpacity(0.55)
      ..strokeWidth = 1.2;
    canvas.drawLine(Offset(size.width - 1, topPad), Offset(size.width - 1, topPad + plotH), axisPaint);

    for (final v in ticks) {
      final y = yOf(v);
      final label = _fmtTick(v);
      final tp = TextPainter(
        text: TextSpan(text: label, style: textStyle),
        textDirection: TextDirection.ltr,
      )..layout();

      final dx = (size.width - 6 - tp.width).clamp(0.0, size.width - tp.width);
      tp.paint(canvas, Offset(dx.toDouble(), (y - tp.height / 2).toDouble()));
    }

    // Unit hint at bottom-left (subtle)
    final unitTp = TextPainter(
      text: TextSpan(text: unit, style: theme.textTheme.labelSmall?.copyWith(color: cs.onSurface.withOpacity(0.45))),
      textDirection: TextDirection.ltr,
    )..layout();
    unitTp.paint(canvas, Offset(4, size.height - unitTp.height - 4));
  }

  String _fmtTick(double v) {
    if (!v.isFinite) return '';
    final isInt = (v - v.roundToDouble()).abs() < 1e-6;
    return isInt ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
  }

  @override
  bool shouldRepaint(covariant _AxisPainter oldDelegate) {
    return oldDelegate.tickMin != tickMin || oldDelegate.tickMax != tickMax || oldDelegate.ticks != ticks || oldDelegate.theme != theme || oldDelegate.unit != unit;
  }
}

class _SeriesPainter extends CustomPainter {
  _SeriesPainter({
    required this.theme,
    required this.axisStartLocal,
    required this.axisEndLocal,
    required this.pxPerMinute,
    required this.tickMin,
    required this.tickMax,
    required this.ticks,
    required this.pts,
    required this.lineColor,
  });

  final ThemeData theme;
  final DateTime axisStartLocal;
  final DateTime axisEndLocal;
  final double pxPerMinute;
  final double tickMin;
  final double tickMax;
  final List<double> ticks;
  final List<_Pt> pts;
  final Color lineColor;

  @override
  void paint(Canvas canvas, Size size) {
    final cs = theme.colorScheme;
    final totalMin = axisEndLocal.difference(axisStartLocal).inMinutes;

    const double topPad = 6.0;
    const double xAxisH = 26.0;
    final plotH = math.max(0.0, size.height - topPad - xAxisH);
    final scaleY = plotH / math.max(1e-9, (tickMax - tickMin));
    double yOf(double v) => (topPad + plotH) - ((v - tickMin) * scaleY);

    // background horizontal grid
    final gridPaint = Paint()
      ..color = theme.dividerColor.withOpacity(0.22)
      ..strokeWidth = 1.0;

    // Left start line (20:30)
    final startLinePaint = Paint()
      ..color = theme.dividerColor.withOpacity(0.35)
      ..strokeWidth = 1.0;
    canvas.drawLine(Offset(0, topPad), Offset(0, topPad + plotH), startLinePaint);

    for (final v in ticks) {
      final y = yOf(v);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    // Vertical hourly grid + centered labels
    final textStyle = theme.textTheme.labelSmall?.copyWith(color: cs.onSurface.withOpacity(0.65));
    DateTime ceilToNextHour(DateTime t) {
      if (t.minute == 0 && t.second == 0 && t.millisecond == 0 && t.microsecond == 0) return t;
      final base = DateTime(t.year, t.month, t.day, t.hour);
      return base.add(const Duration(hours: 1));
    }

    final firstTick = ceilToNextHour(axisStartLocal);
    for (DateTime tt = firstTick; !tt.isAfter(axisEndLocal); tt = tt.add(const Duration(hours: 1))) {
      final m = tt.difference(axisStartLocal).inMinutes;
      if (m < 0 || m > totalMin) continue;
      final x = m * pxPerMinute;

      final p = Paint()
        ..color = theme.dividerColor.withOpacity(0.20)
        ..strokeWidth = 1.0;
      canvas.drawLine(Offset(x, topPad), Offset(x, topPad + plotH), p);

      final hh = tt.hour.toString().padLeft(2, '0');
      final tp = TextPainter(
        text: TextSpan(text: '${hh.toString().padLeft(2, '0')}:00', style: textStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      final dx = (x - tp.width / 2).clamp(0.0, math.max(0.0, size.width - tp.width)).toDouble();
      final yText = topPad + plotH + (xAxisH - tp.height) / 2;
      tp.paint(canvas, Offset(dx, yText));
    }

    // Clip to plot region before drawing series.
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, topPad, size.width, plotH));

    final linePaint = Paint()
      ..color = lineColor
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;

    if (pts.isNotEmpty) {
      final path = Path();
      bool started = false;
      for (final p in pts) {
        if (!p.v.isFinite) continue;
        final tLocal = DateTime.fromMillisecondsSinceEpoch(p.tEpochSec * 1000, isUtc: true).toLocal();
        final dm = tLocal.difference(axisStartLocal).inMilliseconds / 60000.0;
        if (dm < 0) continue;
        if (dm > totalMin) break;
        final x = dm * pxPerMinute;
        final y = yOf(p.v);
        if (!started) {
          path.moveTo(x, y);
          started = true;
        } else {
          path.lineTo(x, y);
        }
      }
      if (started) canvas.drawPath(path, linePaint);
    }

    canvas.restore();

    if (pts.isEmpty) {
      _drawCenterText(canvas, size, theme, '無資料');
    }
  }

  void _drawCenterText(Canvas canvas, Size size, ThemeData theme, String text) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: theme.textTheme.bodyMedium?.copyWith(color: theme.hintColor)),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
    )..layout(maxWidth: size.width - 20);
    tp.paint(canvas, Offset((size.width - tp.width) / 2, (size.height - tp.height) / 2));
  }

  @override
  bool shouldRepaint(covariant _SeriesPainter oldDelegate) => true;
}

DateTime _axisStart2030(DateTime sessionStartLocal) {
  final baseDay = sessionStartLocal.hour < 12
      ? DateTime(sessionStartLocal.year, sessionStartLocal.month, sessionStartLocal.day).subtract(const Duration(days: 1))
      : DateTime(sessionStartLocal.year, sessionStartLocal.month, sessionStartLocal.day);
  return DateTime(baseDay.year, baseDay.month, baseDay.day, 20, 30);
}

class _Pt {
  const _Pt({required this.tEpochSec, required this.v});
  final int tEpochSec;
  final double v;
}

double _maxV(List<_Pt> pts) {
  double m = 0;
  for (final p in pts) {
    if (p.v.isFinite) m = math.max(m, p.v);
  }
  return m;
}

double _minV(List<_Pt> pts) {
  double m = double.infinity;
  for (final p in pts) {
    if (p.v.isFinite) m = math.min(m, p.v);
  }
  return m == double.infinity ? 0 : m;
}

class _NiceAxis {
  const _NiceAxis({required this.tickMin, required this.tickMax, required this.ticks});
  final double tickMin;
  final double tickMax;
  final List<double> ticks;
}

_NiceAxis _fixedAxis({required double fixedMax, required List<double> fixedTicks, required double dataMax}) {
  // 若資料超出固定上限，使用自動刻度避免截斷。
  if (dataMax.isFinite && dataMax > fixedMax) {
    return _niceAxis(0.0, dataMax, targetTicks: 5);
  }
  return _NiceAxis(tickMin: 0.0, tickMax: fixedMax, ticks: fixedTicks);
}

_NiceAxis _niceAxis(double minVal, double maxVal, {int targetTicks = 5}) {
  if (!minVal.isFinite) minVal = 0;
  if (!maxVal.isFinite) maxVal = 0;
  if (maxVal < minVal) {
    final t = maxVal;
    maxVal = minVal;
    minVal = t;
  }
  if ((maxVal - minVal).abs() < 1e-6) {
    maxVal = maxVal + 1.0;
    minVal = math.max(0.0, minVal - 1.0);
  }

  final range = _niceNum(maxVal - minVal, round: false);
  final step = _niceNum(range / (targetTicks - 1), round: true);
  final tickMin = (minVal / step).floorToDouble() * step;
  final tickMax = (maxVal / step).ceilToDouble() * step;

  final ticks = <double>[];
  for (double v = tickMin; v <= tickMax + step * 0.5; v += step) {
    ticks.add(v);
    if (ticks.length > 20) break;
  }
  return _NiceAxis(tickMin: tickMin, tickMax: tickMax, ticks: ticks);
}

double _niceNum(double x, {required bool round}) {
  if (x <= 0 || !x.isFinite) return 1.0;
  final exp = (math.log(x) / math.ln10).floor();
  final f = x / math.pow(10.0, exp);
  double nf;
  if (round) {
    if (f < 1.5) {
      nf = 1;
    } else if (f < 3) {
      nf = 2;
    } else if (f < 7) {
      nf = 5;
    } else {
      nf = 10;
    }
  } else {
    if (f <= 1) {
      nf = 1;
    } else if (f <= 2) {
      nf = 2;
    } else if (f <= 5) {
      nf = 5;
    } else {
      nf = 10;
    }
  }
  return nf * math.pow(10.0, exp);
}
