import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../features/prs1/aggregate/prs1_daily_models.dart';
import '../../features/prs1/model/prs1_event.dart';
import '../../features/prs1/stats/prs1_rolling_metrics.dart';

/// 呼吸中止指數（AHI）
///
/// Phase 2: 最小可視化
/// - 先畫 bucket.rollingAhi5m（1-min resolution, 5m window）
/// - 以折線/近似階梯線呈現（不追求 OSCAR 完全一致的 step look）
class Prs1ChartAhi extends StatefulWidget {
  const Prs1ChartAhi({
    super.key,
    required this.sessionStart,
    required this.sessionEnd,
    required this.bucket,
  });

  static const String chartTitle = '呼吸中止指數(AHI)';

  final DateTime sessionStart;
  final DateTime sessionEnd;
  final Prs1DailyBucket bucket;

  @override
  State<Prs1ChartAhi> createState() => _Prs1ChartAhiState();
}

class _Prs1ChartAhiState extends State<Prs1ChartAhi> {
  final ScrollController _hCtrl = ScrollController();
  List<Prs1TimePoint>? _cachedSeries;
  _NiceAxis? _cachedAxis;
  String? _cacheKey;

  static final Expando<List<Prs1TimePoint>> _cumuSeriesCache =
      Expando<List<Prs1TimePoint>>('prs1_ahi_cumu_series');
  static final Expando<String> _cumuSeriesKey = Expando<String>('prs1_ahi_cumu_key');

  static ({DateTime startLocal, DateTime endLocal}) _bucketRangeLocal(Prs1DailyBucket b) {
    // Prefer slice boundaries (handles split sessions / gaps)...
    if (b.slices.isNotEmpty) {
      DateTime s = b.slices.first.start;
      DateTime e = b.slices.first.end;
      for (final sl in b.slices.skip(1)) {
        if (sl.start.isBefore(s)) s = sl.start;
        if (sl.end.isAfter(e)) e = sl.end;
      }
      // Guard: ensure non-zero range.
      if (!e.isAfter(s)) {
        e = s.add(const Duration(minutes: 1));
      }
      return (startLocal: s, endLocal: e);
    }

    // Fallback: use day start epoch with a 24h window.
    final d0 = DateTime.fromMillisecondsSinceEpoch((b.day.toUtc().millisecondsSinceEpoch ~/ 1000) * 1000, isUtc: true).toLocal();
    return (startLocal: d0, endLocal: d0.add(const Duration(hours: 24)));
  }

  List<Prs1TimePoint> _buildCumulativeAhiSeries(Prs1DailyBucket b) {
    final r = _bucketRangeLocal(b);
    final start = r.startLocal;
    final end = r.endLocal;
    final key = '${start.millisecondsSinceEpoch}|${end.millisecondsSinceEpoch}|${b.events.length}';
    final prevKey = _cumuSeriesKey[b];
    final prev = _cumuSeriesCache[b];
    if (prev != null && prevKey == key) return prev;

    final evs = b.events
        .where((e) =>
            e.type == Prs1EventType.obstructiveApnea ||
            e.type == Prs1EventType.clearAirwayApnea ||
            e.type == Prs1EventType.hypopnea)
        .toList();
    evs.sort((a, b) => a.time.compareTo(b.time));

    final out = <Prs1TimePoint>[];
    // Guard: missing or inverted times.
    if (!end.isAfter(start)) {
      _cumuSeriesKey[b] = key;
      _cumuSeriesCache[b] = out;
      return out;
    }

    int idx = 0;
    int count = 0;
    // Sample at 5-minute cadence to keep it lightweight.
    final step = const Duration(minutes: 5);

    DateTime t = start;
    while (!t.isAfter(end)) {
      while (idx < evs.length && !evs[idx].time.isAfter(t)) {
        count += 1;
        idx += 1;
      }
      final elapsedSec = t.difference(start).inSeconds;
      final elapsedHours = (elapsedSec <= 0) ? (1.0 / 60.0) : (elapsedSec / 3600.0);
      final ahi = count / elapsedHours;
      out.add(Prs1TimePoint(tEpochSec: t.toUtc().millisecondsSinceEpoch ~/ 1000, value: ahi));
      t = t.add(step);
    }

    _cumuSeriesKey[b] = key;
    _cumuSeriesCache[b] = out;
    return out;
  }

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
    final axisEndEpochSec = axisStartEpochSec + totalMin * 60;

    // Phase 5: OSCAR-like cumulative AHI (average since session start).
    //   AHI(t) = cumulative(OA+CA+H up to t) / elapsedHours(t)
    final cumu = _buildCumulativeAhiSeries(widget.bucket);

// Cache filtered+sorted points + Y axis because scroll/drag triggers frequent rebuilds.
final key = '${widget.bucket.day.millisecondsSinceEpoch}'
    '|${widget.bucket.events.length}'
    '|${cumu.length}'
    '|${cumu.isEmpty ? 0 : cumu.first.tEpochSec}'
    '|${cumu.isEmpty ? 0 : cumu.last.tEpochSec}'
    '|${axisStartLocal.millisecondsSinceEpoch}'
    '|${axisEndLocal.millisecondsSinceEpoch}';

late final List<Prs1TimePoint> pts;
late final _NiceAxis y;

if (_cacheKey == key && _cachedSeries != null && _cachedAxis != null) {
  pts = _cachedSeries!;
  y = _cachedAxis!;
} else {
  final tmp = <Prs1TimePoint>[];
  for (final p in cumu) {
	    final v = p.value;
	    if (v == null || !v.isFinite) continue;
    final t = DateTime.fromMillisecondsSinceEpoch(p.tEpochSec * 1000, isUtc: true).toLocal();
    if (t.isBefore(axisStartLocal) || t.isAfter(axisEndLocal)) continue;
    tmp.add(p);
  }
      tmp.sort((a, b) => a.tEpochSec.compareTo(b.tEpochSec));

  double yMax = 0.0;
	  for (final p in tmp) {
	    final v = p.value;
	    if (v == null || !v.isFinite) continue;
	    if (v > yMax) yMax = v;
	  }
  // Avoid outliers exploding the chart; treated AHI usually stays low.
  // OSCAR AHI chart typically stays within a small range.
  // Keep the axis readable; allow headroom but avoid "爆高" from short-window rolling.
  yMax = yMax.clamp(0.0, 12.0);
  if (yMax < 6.0) yMax = 6.0;

  pts = tmp;
  y = _niceAxis(0.0, yMax);

  _cacheKey = key;
  _cachedSeries = pts;
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
                  Prs1ChartAhi.chartTitle,
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
                ),
                const SizedBox(width: 10),
                _LegendDot(color: Colors.red.withOpacity(0.80)),
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
                        painter: _AxisPainter(theme: theme, axisStartLocal: axisStartLocal, axisEndLocal: axisEndLocal, tickMin: y.tickMin, tickMax: y.tickMax, ticks: y.ticks, unit: ''),
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
                            painter: _AhiPainter(theme: theme, axisStartLocal: axisStartLocal, axisEndLocal: axisEndLocal,
                          axisStartEpochSec: axisStartEpochSec,
                              totalMinutes: totalMin,
                              pxPerMinute: pxPerMinute,
                              tickMin: y.tickMin,
                              tickMax: y.tickMax,
                              ticks: y.ticks,
                              pts: pts,
                              lineColor: Colors.red.withOpacity(0.80),
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

    if (unit.isNotEmpty) {
      final unitTp = TextPainter(
        text: TextSpan(text: unit, style: theme.textTheme.labelSmall?.copyWith(color: cs.onSurface.withOpacity(0.45))),
        textDirection: TextDirection.ltr,
      )..layout();
      unitTp.paint(canvas, Offset(4, size.height - unitTp.height - 4));
    }
  }

  String _fmtTick(double v) {
    if (!v.isFinite) return '';
    final isInt = (v - v.roundToDouble()).abs() < 1e-6;
    return isInt ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

class _AhiPainter extends CustomPainter {
  _AhiPainter({
    required this.theme,
    required this.axisStartLocal,
    required this.axisEndLocal,
    required this.axisStartEpochSec,
    required this.totalMinutes,
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
  final int axisStartEpochSec;
  final int totalMinutes;
  final double pxPerMinute;
  final double tickMin;
  final double tickMax;
  final List<double> ticks;
  final List<Prs1TimePoint> pts;
  final Color lineColor;

  @override
  void paint(Canvas canvas, Size size) {
    final cs = theme.colorScheme;
    const double topPad = 6.0;
    const double xAxisH = 26.0;
    final plotH = math.max(0.0, size.height - topPad - xAxisH);
    final scaleY = plotH / math.max(1e-9, (tickMax - tickMin));
    double yOf(double v) => (topPad + plotH) - ((v - tickMin) * scaleY);
    double xOfEpochSec(int tEpochSec) {
      final dMin = (tEpochSec - axisStartEpochSec) / 60.0;
      return dMin * pxPerMinute;
    }

    // grid
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

    // line
    final linePaint = Paint()
      ..color = lineColor
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;

    final path = Path();
    bool has = false;
    for (final p in pts) {
      final v = p.value;
      if (v == null || !v.isFinite) continue;
      final x = xOfEpochSec(p.tEpochSec);
      if (x < 0 || x > size.width) continue;
      final y = yOf(v);
      if (!has) {
        path.moveTo(x, y);
        has = true;
      } else {
        path.lineTo(x, y);
      }
    }
    if (has) canvas.drawPath(path, linePaint);

    // x-axis baseline
    final baseY = yOf(tickMin);
    final axisPaint = Paint()
      ..color = cs.onSurface.withOpacity(0.30)
      ..strokeWidth = 1.0;
    canvas.drawLine(Offset(0, baseY), Offset(size.width, baseY), axisPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

DateTime _axisStart2030(DateTime start) {
  final d = DateTime(start.year, start.month, start.day);
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

double _maxV(List<Prs1TimePoint> pts) {
  double m = 0;
  for (final p in pts) {
    final v = p.value;
    if (v == null || !v.isFinite) continue;
    if (v > m) m = v;
  }
  return m;
}