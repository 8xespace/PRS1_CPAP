import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../features/prs1/aggregate/prs1_daily_models.dart';

/// 漏氣率（Leak Rate）
///
/// 對齊 OSCAR 的 Leak Rate 圖：
/// - 綠線：總漏氣率（b.leakSamples）
/// - 黑線：平均漏氣率（b.unintentionalLeakSamples）
/// - 紅色虛線：漏氣閾值（b.largeLeakThresholdLpm，常見 24 L/min）
///
/// 重要：不改動資料引擎，只吃 DailyBucket 的 channel。
class Prs1ChartLeakRate extends StatefulWidget {
  const Prs1ChartLeakRate({
    super.key,
    required this.sessionStart,
    required this.sessionEnd,
    required this.bucket,
  });

  static const String chartTitle = '漏氣率';

  final DateTime sessionStart;
  final DateTime sessionEnd;
  final Prs1DailyBucket bucket;

  @override
  State<Prs1ChartLeakRate> createState() => _Prs1ChartLeakRateState();
}

class _Prs1ChartLeakRateState extends State<Prs1ChartLeakRate> {
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
    final endLocal = widget.sessionEnd.toLocal();
    final axisStartLocal = _axisStart2030(startLocal);
    final axisEndLocal = axisStartLocal.add(const Duration(hours: 24));
    final totalMin = axisEndLocal.difference(axisStartLocal).inMinutes;

    // Collect series from bucket channels.
    final totalPts = <_Pt>[];
    final unintPts = <_Pt>[];
    for (final sm in widget.bucket.leakSamples) {
      totalPts.add(_Pt(tEpochSec: sm.tEpochSec, v: sm.value));
    }
    for (final sm in widget.bucket.unintentionalLeakSamples) {
      unintPts.add(_Pt(tEpochSec: sm.tEpochSec, v: sm.value));
    }
    totalPts.sort((a, b) => a.tEpochSec.compareTo(b.tEpochSec));
    unintPts.sort((a, b) => a.tEpochSec.compareTo(b.tEpochSec));

    // Threshold (Large Leak) is expected to be a per-night value.
    // If the bucket value is missing/NaN, fall back to a baseline-derived estimate,
    // and finally to the clinical default 24 L/min so the dashed line never disappears.
    final rawThreshold = widget.bucket.largeLeakThresholdLpm;
    final baseline = widget.bucket.leakBaselineLpm;
    final threshold = (rawThreshold.isFinite && rawThreshold > 0)
        ? rawThreshold
        : (((baseline ?? 0.0).isFinite ? (baseline ?? 0.0) : 0.0) + 24.0);

    // Dynamic Y axis (0..niceMax), ~5 ticks like OSCAR (but float by data).
    final maxVal = _max3(
      _maxV(totalPts),
      _maxV(unintPts),
      threshold.isFinite ? threshold : 0.0,
    );
    final y = _niceAxis(maxVal);

    return LayoutBuilder(
      builder: (context, c) {
        final maxW = c.maxWidth.isFinite ? c.maxWidth : 900.0;
        final chartViewportW = math.max(0.0, maxW - _labelW);
        // keep pxPerMinute consistent with pressure chart formula
        final pxPerMinute = (chartViewportW / 750.0) * 0.95;
        final contentW = totalMin * pxPerMinute;

        void onDragHorizontal(DragUpdateDetails d) {
          if (!_hCtrl.hasClients) return;
          final max = _hCtrl.position.maxScrollExtent;
          final next = (_hCtrl.offset - d.delta.dx).clamp(0.0, max);
          _hCtrl.jumpTo(next);
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 2),
            Row(
              children: [
                const Text(
                  Prs1ChartLeakRate.chartTitle,
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
                ),
                const SizedBox(width: 10),
                _LegendDot(color: Colors.green.withOpacity(0.85)),
                const SizedBox(width: 6),
                Text('總漏氣率', style: theme.textTheme.labelSmall),
                const SizedBox(width: 12),
                _LegendDot(color: cs.onSurface.withOpacity(0.75)),
                const SizedBox(width: 6),
                Text('平均漏氣率', style: theme.textTheme.labelSmall),
                const SizedBox(width: 12),
                _LegendDash(color: cs.error.withOpacity(0.85)),
                const SizedBox(width: 6),
                Text('漏氣閾值', style: theme.textTheme.labelSmall),
                const Spacer(),
                Text(
                  '${_fmtHm(startLocal)}–${_fmtHm(endLocal)}',
                  style: theme.textTheme.labelSmall?.copyWith(color: cs.onSurface.withOpacity(0.7)),
                ),
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
                        painter: _LeakAxisPainter(theme: theme, tickMin: y.tickMin, tickMax: y.tickMax, ticks: y.ticks),
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
                            painter: _LeakPainter(
                              theme: theme,
                              axisStartLocal: axisStartLocal,
                              axisEndLocal: axisEndLocal,
                              pxPerMinute: pxPerMinute,
                              tickMin: y.tickMin,
                              tickMax: y.tickMax,
                              ticks: y.ticks,
                              total: totalPts,
                              unintentional: unintPts,
                              threshold: threshold,
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
const double _labelW = 96.0; // 對齊事件標記/氣流/壓力左欄切線

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

class _LegendDash extends StatelessWidget {
  const _LegendDash({required this.color});
  final Color color;
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 18,
      height: 10,
      child: CustomPaint(painter: _LegendDashPainter(color)),
    );
  }
}

class _LegendDashPainter extends CustomPainter {
  _LegendDashPainter(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..strokeWidth = 1.2;
    const dash = 5.0;
    double x = 0;
    final y = size.height / 2;
    while (x < size.width) {
      canvas.drawLine(Offset(x, y), Offset(math.min(size.width, x + dash), y), p);
      x += dash * 2;
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

String _fmtHm(DateTime t) {
  final hh = t.hour.toString().padLeft(2, '0');
  final mm = t.minute.toString().padLeft(2, '0');
  return '$hh:$mm';
}

class _Pt {
  const _Pt({required this.tEpochSec, required this.v});
  final int tEpochSec;
  final double v;
}

double _maxV(List<_Pt> pts) {
  double m = 0.0;
  for (final p in pts) {
    if (!p.v.isFinite) continue;
    if (p.v > m) m = p.v;
  }
  return m;
}

double _max3(double a, double b, double c) => math.max(a, math.max(b, c));

/// Choose axis start at 20:30 (same rule used by pressure/flow charts).
DateTime _axisStart2030(DateTime sessionStartLocal) {
  // If start time is after noon, treat it as same-day evening.
  // If it's before noon (typical "next day morning" end time), shift back one day.
  final baseDay = sessionStartLocal.hour < 12
      ? DateTime(sessionStartLocal.year, sessionStartLocal.month, sessionStartLocal.day).subtract(const Duration(days: 1))
      : DateTime(sessionStartLocal.year, sessionStartLocal.month, sessionStartLocal.day);

  return DateTime(baseDay.year, baseDay.month, baseDay.day, 20, 30);
}

class _NiceAxis {
  const _NiceAxis({required this.tickMin, required this.tickMax, required this.ticks});
  final double tickMin;
  final double tickMax;
  final List<double> ticks;
}

/// Build 0..niceMax with 5 ticks (0,step,2step,3step,4step).
_NiceAxis _niceAxis(double maxVal) {
  // OSCAR style: 5 labels (0 .. tickMax) with 4 equal intervals.
  final m = (maxVal.isFinite && maxVal > 0) ? maxVal : 1.0;
  final targetMax = m * 1.05; // small headroom

  // Choose a "nice" max on a 5 L/min grid (35, 40, 45...) so step can be fractional like 8.8.
  final tickMax = (math.max(5.0, (targetMax / 5.0).ceilToDouble() * 5.0));
  final step = tickMax / 4.0;

  return _NiceAxis(
    tickMin: 0.0,
    tickMax: tickMax,
    ticks: <double>[0.0, step, step * 2, step * 3, tickMax],
  );
}

/// Nice number helper (Graphics Gems style).
double _niceNum(double x, {required bool round}) {
  if (x <= 0 || !x.isFinite) return 1.0;
  final exp = math.log(x) / math.ln10;
  final e = exp.floorToDouble();
  final f = x / math.pow(10, e);
  double nf;
  if (round) {
    if (f < 1.5) nf = 1;
    else if (f < 3) nf = 2;
    else if (f < 7) nf = 5;
    else nf = 10;
  } else {
    if (f <= 1) nf = 1;
    else if (f <= 2) nf = 2;
    else if (f <= 5) nf = 5;
    else nf = 10;
  }
  return nf * math.pow(10, e);
}

class _LeakAxisPainter extends CustomPainter {
  _LeakAxisPainter({required this.theme, required this.tickMin, required this.tickMax, required this.ticks});
  final ThemeData theme;
  final double tickMin;
  final double tickMax;
  final List<double> ticks;

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

    // Unit hint at bottom-left (optional, subtle)
    final unit = TextPainter(
      text: TextSpan(text: 'L/min', style: theme.textTheme.labelSmall?.copyWith(color: cs.onSurface.withOpacity(0.45))),
      textDirection: TextDirection.ltr,
    )..layout();
    unit.paint(canvas, Offset(4, size.height - unit.height - 4));
  }

  String _fmtTick(double v) {
    // OSCAR-like: keep 1 decimal whenever it's not an integer (e.g. 8.8, 17.5, 26.3).
    if (!v.isFinite) return '';
    final isInt = (v - v.roundToDouble()).abs() < 1e-6;
    return isInt ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
  }

  @override
  bool shouldRepaint(covariant _LeakAxisPainter oldDelegate) {
    return oldDelegate.tickMin != tickMin || oldDelegate.tickMax != tickMax || oldDelegate.ticks != ticks || oldDelegate.theme != theme;
  }
}

class _LeakPainter extends CustomPainter {
  _LeakPainter({
    required this.theme,
    required this.axisStartLocal,
    required this.axisEndLocal,
    required this.pxPerMinute,
    required this.tickMin,
    required this.tickMax,
    required this.ticks,
    required this.total,
    required this.unintentional,
    required this.threshold,
  });

  final ThemeData theme;
  final DateTime axisStartLocal;
  final DateTime axisEndLocal;
  final double pxPerMinute;
  final double tickMin;
  final double tickMax;
  final List<double> ticks;
  final List<_Pt> total;
  final List<_Pt> unintentional;
  final double threshold;

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

    // Left start line (20:30) — must align with other charts.
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
        text: TextSpan(text: '$hh:00', style: textStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      final dx = (x - tp.width / 2).clamp(0.0, math.max(0.0, size.width - tp.width)).toDouble();
      final yText = topPad + plotH + (xAxisH - tp.height) / 2;
      tp.paint(canvas, Offset(dx, yText));
    }

    // Clip to plot region before drawing series.
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, topPad, size.width, plotH));

    final totalPaint = Paint()
      ..color = Colors.green.withOpacity(0.85)
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;

    final unintPaint = Paint()
      ..color = cs.onSurface.withOpacity(0.75)
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;

    final threshPaint = Paint()
      ..color = cs.error.withOpacity(0.85)
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;

    // threshold dashed horizontal line
    if (threshold.isFinite && threshold > 0) {
      final yT = yOf(threshold);
      const dash = 6.0;
      double x = 0;
      while (x < size.width) {
        canvas.drawLine(Offset(x, yT), Offset(math.min(size.width, x + dash), yT), threshPaint);
        x += dash * 2;
      }
    }

    void drawSeries(List<_Pt> pts, Paint paint) {
  if (pts.isEmpty) return;
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
  if (started) {
    canvas.drawPath(path, paint);
  }
}

    drawSeries(total, totalPaint);
    drawSeries(unintentional, unintPaint);

    canvas.restore();

    // Empty state hint
    if (total.isEmpty && unintentional.isEmpty) {
      _drawCenterText(canvas, size, theme, '無漏氣資料');
    }
  }

  void _drawCenterText(Canvas canvas, Size size, ThemeData theme, String text) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: theme.textTheme.bodyMedium?.copyWith(color: theme.hintColor),
      ),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
    )..layout(maxWidth: size.width - 20);
    tp.paint(canvas, Offset((size.width - tp.width) / 2, (size.height - tp.height) / 2));
  }

  @override
  bool shouldRepaint(covariant _LeakPainter oldDelegate) => true;
}
