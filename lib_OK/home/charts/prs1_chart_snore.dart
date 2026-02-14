import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../features/prs1/aggregate/prs1_daily_models.dart';

/// 打鼾（Snore）
///
/// Phase 2: 最小可視化
/// - 使用 bucket.snoreHeatmap1mCounts（每分鐘計數）畫出最簡單的直條圖。
/// - 不追求像 OSCAR 一樣漂亮，但要求：資料流 → 座標映射全通且可視。
class Prs1ChartSnore extends StatefulWidget {
  const Prs1ChartSnore({
    super.key,
    required this.sessionStart,
    required this.sessionEnd,
    required this.bucket,
  });

  static const String chartTitle = '打鼾';

  final DateTime sessionStart;
  final DateTime sessionEnd;
  final Prs1DailyBucket bucket;

  @override
  State<Prs1ChartSnore> createState() => _Prs1ChartSnoreState();
}

class _Prs1ChartSnoreState extends State<Prs1ChartSnore> {
  final ScrollController _hCtrl = ScrollController();
  List<int>? _cachedCounts;
  _NiceAxis? _cachedAxis;
  String? _cacheKey;

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
    final axisStartEpochSec = axisStartLocal.toUtc().millisecondsSinceEpoch ~/ 1000;
        final dayStartEpochSec = DateTime(
      widget.bucket.day.year,
      widget.bucket.day.month,
      widget.bucket.day.day,
      20,
      30,
    ).toUtc().millisecondsSinceEpoch ~/ 1000; // Align with Prs1SnoreHeatmap start (20:30)

final src = widget.bucket.snoreHeatmap1mCounts;
final key = '${widget.bucket.day.millisecondsSinceEpoch}'
    '|${src.length}'
    '|${axisStartEpochSec}'
    '|${totalMin}';
List<int> counts;
_NiceAxis y;
if (_cacheKey == key && _cachedCounts != null && _cachedAxis != null) {
  counts = _cachedCounts!;
  y = _cachedAxis!;
} else {
  counts = <int>[];
  for (int i = 0; i < totalMin; i++) {
    final t = axisStartEpochSec + i * 60;
    final idx = ((t - dayStartEpochSec) ~/ 60);
    if (idx >= 0 && idx < src.length) {
      counts.add(src[idx]);
    } else {
      counts.add(0);
    }
  }
  final maxCount = counts.isEmpty ? 0 : counts.reduce(math.max);
  y = _niceAxis(0.0, maxCount.toDouble());
  _cacheKey = key;
  _cachedCounts = counts;
  _cachedAxis = y;
}

    return LayoutBuilder(
      builder: (context, c) {
        final maxW = c.maxWidth.isFinite ? c.maxWidth : 900.0;
        final chartViewportW = math.max(0.0, maxW - _labelW);
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
                  Prs1ChartSnore.chartTitle,
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
                ),
                const SizedBox(width: 10),
                _LegendDot(color: Colors.blueGrey.withOpacity(0.85)),
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
                        painter: _AxisPainter(theme: theme, axisStartLocal: axisStartLocal, axisEndLocal: axisEndLocal, tickMin: y.tickMin, tickMax: y.tickMax, ticks: y.ticks, unit: 'count'),
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
                            painter: _BarsPainter(theme: theme, axisStartLocal: axisStartLocal, axisEndLocal: axisEndLocal,
                              totalMinutes: totalMin,
                              pxPerMinute: pxPerMinute,
                              tickMin: y.tickMin,
                              tickMax: y.tickMax,
                              ticks: y.ticks,
                              counts: counts,
                              barColor: Colors.blueGrey.withOpacity(0.85),
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
const double _labelW = 96.0;

class _LegendDot extends StatelessWidget {
  const _LegendDot({required this.color});
  final Color color;
  @override
  Widget build(BuildContext context) {
    return Container(width: 10, height: 10, decoration: BoxDecoration(color: color, shape: BoxShape.circle));
  }
}

class _AxisPainter extends CustomPainter {
  _AxisPainter({required this.theme,
    required this.axisStartLocal,
    required this.axisEndLocal,
    required this.tickMin, required this.tickMax, required this.ticks, required this.unit});
  final ThemeData theme;
  final DateTime axisStartLocal;
  final DateTime axisEndLocal;
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

    final axisPaint = Paint()
      ..color = theme.dividerColor.withOpacity(0.55)
      ..strokeWidth = 1.2;
    canvas.drawLine(Offset(size.width - 1, topPad), Offset(size.width - 1, topPad + plotH), axisPaint);

    for (final v in ticks) {
      final y = yOf(v);
      final label = _fmtTick(v);
      final tp = TextPainter(text: TextSpan(text: label, style: textStyle), textDirection: TextDirection.ltr)..layout();
      final dx = (size.width - 6 - tp.width).clamp(0.0, size.width - tp.width);
      tp.paint(canvas, Offset(dx.toDouble(), (y - tp.height / 2).toDouble()));
    }

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
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

class _BarsPainter extends CustomPainter {
  _BarsPainter({required this.theme,
    required this.axisStartLocal,
    required this.axisEndLocal,
    required this.totalMinutes,
    required this.pxPerMinute,
    required this.tickMin,
    required this.tickMax,
    required this.ticks,
    required this.counts,
    required this.barColor,
  });

  final ThemeData theme;
  final DateTime axisStartLocal;
  final DateTime axisEndLocal;
  final int totalMinutes;
  final double pxPerMinute;
  final double tickMin;
  final double tickMax;
  final List<double> ticks;
  final List<int> counts;
  final Color barColor;

  @override
  void paint(Canvas canvas, Size size) {
    final cs = theme.colorScheme;
    const double topPad = 6.0;
    const double xAxisH = 26.0;
    final plotH = math.max(0.0, size.height - topPad - xAxisH);
    final scaleY = plotH / math.max(1e-9, (tickMax - tickMin));
    double yOf(double v) => (topPad + plotH) - ((v - tickMin) * scaleY);

    // grid lines (very light)
    final gridPaint = Paint()
      ..color = theme.dividerColor.withOpacity(0.18)
      ..strokeWidth = 1.0;
    for (final v in ticks) {
      final y = yOf(v);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    // Vertical hourly grid + centered labels (match leak/pressure charts)
    final textStyle2 = theme.textTheme.labelSmall?.copyWith(color: cs.onSurface.withOpacity(0.65));
    DateTime ceilToNextHour(DateTime t) {
      if (t.minute == 0 && t.second == 0 && t.millisecond == 0 && t.microsecond == 0) return t;
      final base = DateTime(t.year, t.month, t.day, t.hour);
      return base.add(const Duration(hours: 1));
    }

    final firstTick = ceilToNextHour(axisStartLocal);
    for (DateTime tt = firstTick; !tt.isAfter(axisEndLocal); tt = tt.add(const Duration(hours: 1))) {
      final m = tt.difference(axisStartLocal).inMinutes;
      if (m < 0 || m > totalMinutes) continue;
      final x = m * pxPerMinute;

      final p = Paint()
        ..color = theme.dividerColor.withOpacity(0.20)
        ..strokeWidth = 1.0;
      canvas.drawLine(Offset(x, topPad), Offset(x, topPad + plotH), p);

      final hh = tt.hour.toString().padLeft(2, '0');
      final tp = TextPainter(
        text: TextSpan(text: '$hh:00', style: textStyle2),
        textDirection: TextDirection.ltr,
      )..layout();

      final dx = (x - tp.width / 2).clamp(0.0, size.width - tp.width);
      tp.paint(canvas, Offset(dx.toDouble(), topPad + plotH + 4));
    }

    // bars
    final barPaint = Paint()..color = barColor;
    final baseY = yOf(tickMin);
    final bw = math.max(1.0, pxPerMinute * 0.85);
    final n = math.min(totalMinutes, counts.length);
    for (int i = 0; i < n; i++) {
      final c = counts[i];
      if (c <= 0) continue;
      final x = i * pxPerMinute;
      final y = yOf(c.toDouble());
      canvas.drawRect(Rect.fromLTWH(x, y, bw, (baseY - y).abs()), barPaint);
    }

    // x-axis baseline
    final axisPaint = Paint()
      ..color = cs.onSurface.withOpacity(0.30)
      ..strokeWidth = 1.0;
    canvas.drawLine(Offset(0, baseY), Offset(size.width, baseY), axisPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

DateTime _axisStart2030(DateTime sessionStartLocal) {
  final d = DateTime(sessionStartLocal.year, sessionStartLocal.month, sessionStartLocal.day);
  return d.add(const Duration(hours: 20, minutes: 30));
}

class _NiceAxis {
  const _NiceAxis({required this.tickMin, required this.tickMax, required this.ticks});
  final double tickMin;
  final double tickMax;
  final List<double> ticks;
}

_NiceAxis _niceAxis(double minV, double maxV) {
  if (!minV.isFinite) minV = 0;
  if (!maxV.isFinite) maxV = 0;
  if (maxV < minV) {
    final t = maxV;
    maxV = minV;
    minV = t;
  }
  if ((maxV - minV).abs() < 1e-9) {
    maxV = minV + 1;
  }

  // target 4 ticks
  final span = maxV - minV;
  final rawStep = span / 4.0;
  final step = _niceStep(rawStep);
  final tickMin = (minV / step).floorToDouble() * step;
  final tickMax = (maxV / step).ceilToDouble() * step;
  final ticks = <double>[];
  for (double v = tickMin; v <= tickMax + 1e-9; v += step) {
    ticks.add(v);
  }
  return _NiceAxis(tickMin: tickMin, tickMax: tickMax, ticks: ticks);
}

double _niceStep(double raw) {
  if (raw <= 0 || !raw.isFinite) return 1;
  final exp = math.pow(10, (math.log(raw) / math.ln10).floor());
  final f = raw / exp;
  double nf;
  if (f <= 1) {
    nf = 1;
  } else if (f <= 2) {
    nf = 2;
  } else if (f <= 5) {
    nf = 5;
  } else {
    nf = 10;
  }
  return nf * exp;
}
