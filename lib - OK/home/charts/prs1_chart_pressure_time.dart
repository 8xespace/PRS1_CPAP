import 'dart:math' as math;

import 'prs1_chart_cache.dart';

import 'package:flutter/material.dart';

import '../../features/prs1/aggregate/prs1_daily_models.dart';
import '../../features/prs1/model/prs1_signal_sample.dart';


final _pressureTimeHistCache = Prs1ChartCache<String, _HistCacheEntry>(maxEntries: 128);

class _HistCacheEntry {
  const _HistCacheEntry({
    required this.binSize,
    required this.binMin,
    required this.binMax,
    required this.ipapMinutes,
    required this.epapMinutes,
    required this.totalMinutes,
  });

  final double binSize;
  final double binMin;
  final double binMax;
  /// Minutes in each pressure bin.
  final List<double> ipapMinutes;
  final List<double> epapMinutes;

  /// Total minutes represented by the histogram (IPAP + EPAP combined).
  ///
  /// This is used only for sanity checks / debug output.
  final double totalMinutes;
}


/// 壓力時間 🟢 吐氣壓力分佈、🔴 治療壓力分佈（Pressure Time / Pressure Distribution）
///
/// Phase 2: 最小可視化
/// - 先用 bucket.pressureSamples / exhalePressureSamples 做最粗 histogram。
/// - bin: 0.5 cmH2O
/// - Y 軸暫用「樣本數」(近似時間量)；Phase 3/4 再對齊 OSCAR 的 Time-at-Pressure 規則。
class Prs1ChartPressureTime extends StatelessWidget {
  const Prs1ChartPressureTime({
    super.key,
    required this.sessionStart,
    required this.sessionEnd,
    required this.bucket,
  });

  // Title only; legend is rendered as small dots + labels next to the title.
  static const String chartTitle = '壓力時間';

  final DateTime sessionStart;
  final DateTime sessionEnd;
  final Prs1DailyBucket bucket;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

// Build histogram bins (cached: expensive on repeated repaints).
const double binW = 0.5; // cmH2O
final ipap = bucket.pressureSamples;
final epap = bucket.exhalePressureSamples;
if (ipap.isEmpty && epap.isEmpty) {
  return _NoDataCard(title: chartTitle);
}

double minP = double.infinity;
double maxP = -double.infinity;
for (final s in ipap) {
  final v = s.value;
  if (v.isFinite) {
    if (v < minP) minP = v;
    if (v > maxP) maxP = v;
  }
}
for (final s in epap) {
  final v = s.value;
  if (v.isFinite) {
    if (v < minP) minP = v;
    if (v > maxP) maxP = v;
  }
}
if (!minP.isFinite || !maxP.isFinite) {
  return _NoDataCard(title: chartTitle);
}

// Keep a sane domain.
minP = (minP / binW).floorToDouble() * binW;
maxP = (maxP / binW).ceilToDouble() * binW;
if (maxP - minP < binW) maxP = minP + binW;

final cacheKey = '${bucket.day.millisecondsSinceEpoch}'
    '|${ipap.length}'
    '|${epap.length}'
    '|${ipap.isEmpty ? 0 : ipap.first.timestampMs}'
    '|${ipap.isEmpty ? 0 : ipap.last.timestampMs}'
    '|${epap.isEmpty ? 0 : epap.first.timestampMs}'
    '|${epap.isEmpty ? 0 : epap.last.timestampMs}'
    '|${binW.toStringAsFixed(2)}'
    '|${minP.toStringAsFixed(2)}'
    '|${maxP.toStringAsFixed(2)}';

final cached = _pressureTimeHistCache.get(cacheKey);
late final List<double> histImin;
late final List<double> histEmin;
late final double totalMin;

if (cached != null &&
    cached.binSize == binW &&
    cached.binMin == minP &&
    cached.binMax == maxP) {
  histImin = cached.ipapMinutes;
  histEmin = cached.epapMinutes;
  totalMin = cached.totalMinutes;
} else {
  final bins = ((maxP - minP) / binW).round() + 1;
  final tmpI = List<double>.filled(bins, 0.0);
  final tmpE = List<double>.filled(bins, 0.0);
  int binOf(double v) {
    final idx = ((v - minP) / binW).floor();
    return idx.clamp(0, bins - 1);
  }

  double total = 0.0;

  double _durMin(int i, List<Prs1SignalSample> xs) {
    if (xs.isEmpty) return 0.0;
    // Use delta to next sample; for the last sample, reuse the previous delta.
    int cur = xs[i].timestampMs;
    int next;
    if (i + 1 < xs.length) {
      next = xs[i + 1].timestampMs;
    } else if (i - 1 >= 0) {
      next = cur + (cur - xs[i - 1].timestampMs);
    } else {
      next = cur + 60000; // fall back to 60s
    }
    final dtSec = ((next - cur) / 1000.0).abs();
    // Guard against wild gaps.
    final clamped = dtSec.clamp(1.0, 300.0);
    return clamped / 60.0;
  }

  for (int i = 0; i < ipap.length; i++) {
    final s = ipap[i];
    final v = s.value;
    if (v.isFinite) {
      final dm = _durMin(i, ipap);
      tmpI[binOf(v)] += dm;
      total += dm;
    }
  }

  for (int i = 0; i < epap.length; i++) {
    final s = epap[i];
    final v = s.value;
    if (v.isFinite) {
      final dm = _durMin(i, epap);
      tmpE[binOf(v)] += dm;
      // total already accounts from ipap; if ipap empty, still want a non-zero.
      if (ipap.isEmpty) total += dm;
    }
  }

  histImin = tmpI;
  histEmin = tmpE;
  totalMin = total;

  _pressureTimeHistCache.set(
    cacheKey,
    _HistCacheEntry(
      binSize: binW,
      binMin: minP,
      binMax: maxP,
      ipapMinutes: tmpI,
      epapMinutes: tmpE,
      totalMinutes: total,
    ),
  );
}
    final maxMin = math.max(
      histImin.isEmpty ? 0.0 : histImin.reduce(math.max),
      histEmin.isEmpty ? 0.0 : histEmin.reduce(math.max),
    );
    final y = _niceAxis(0.0, maxMin);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 2),
        Row(
          children: [
            const Text(chartTitle, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
            const SizedBox(width: 10),
            _LegendDot(color: Colors.green.withOpacity(0.75)),
            const SizedBox(width: 6),
            Text('吐氣壓力分佈', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: cs.onSurface.withOpacity(0.70))),
            const SizedBox(width: 12),
            _LegendDot(color: Colors.red.withOpacity(0.75)),
            const SizedBox(width: 6),
            Text('治療壓力分佈', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: cs.onSurface.withOpacity(0.70))),
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
                    painter: _AxisPainter(theme: theme, tickMin: y.tickMin, tickMax: y.tickMax, ticks: y.ticks),
                  ),
                ),
                Expanded(
                  child: CustomPaint(
                    size: const Size(double.infinity, _chartH),
                    painter: _PressureTimeCurvePainter(
                      theme: theme,
                      tickMin: y.tickMin,
                      tickMax: y.tickMax,
                      ticks: y.ticks,
                      minP: minP,
                      binW: binW,
                      histImin: histImin,
                      histEmin: histEmin,
                      totalMin: totalMin,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

const double _chartH = 160.0;
const double _labelW = 96.0;

class _NoDataCard extends StatelessWidget {
  const _NoDataCard({required this.title});
  final String title;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 2),
        Text(title, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        Container(
          height: _chartH,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: theme.dividerColor.withOpacity(0.25)),
          ),
          alignment: Alignment.center,
          child: Text('No data', style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.onSurface.withOpacity(0.65))),
        ),
      ],
    );
  }
}

class _LegendDot extends StatelessWidget {
  const _LegendDot({required this.color});
  final Color color;
  @override
  Widget build(BuildContext context) {
    return Container(width: 10, height: 10, decoration: BoxDecoration(color: color, shape: BoxShape.circle));
  }
}

class _AxisPainter extends CustomPainter {
  _AxisPainter({required this.theme, required this.tickMin, required this.tickMax, required this.ticks});
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
  }

  String _fmtTick(double v) {
    if (!v.isFinite) return '';
    final isInt = (v - v.roundToDouble()).abs() < 1e-6;
    return isInt ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

class _PressureTimeCurvePainter extends CustomPainter {
  _PressureTimeCurvePainter({
    required this.theme,
    required this.tickMin,
    required this.tickMax,
    required this.ticks,
    required this.minP,
    required this.binW,
    required this.histImin,
    required this.histEmin,
    required this.totalMin,
  });

  final ThemeData theme;
  final double tickMin;
  final double tickMax;
  final List<double> ticks;
  final double minP;
  final double binW;
  final List<double> histImin;
  final List<double> histEmin;
  final double totalMin;

  @override
  void paint(Canvas canvas, Size size) {
    final cs = theme.colorScheme;

    const double topPad = 6.0;
    const double xAxisH = 26.0;
    final plotH = math.max(0.0, size.height - topPad - xAxisH);
    final plotW = size.width;
    final scaleY = plotH / math.max(1e-9, (tickMax - tickMin));
    double yOf(double v) => (topPad + plotH) - ((v - tickMin) * scaleY);

    // grid
    final gridPaint = Paint()
      ..color = theme.dividerColor.withOpacity(0.18)
      ..strokeWidth = 1.0;
    for (final v in ticks) {
      final y = yOf(v);
      canvas.drawLine(Offset(0, y), Offset(plotW, y), gridPaint);
    }

    final n = math.min(histImin.length, histEmin.length);
    if (n <= 0) return;
    final baseY = yOf(tickMin);

    // series paint (OSCAR-like: curve)
    final lineI = Paint()
      ..color = Colors.red.withOpacity(0.75)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;
    final lineE = Paint()
      ..color = Colors.green.withOpacity(0.75)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;

    final fillI = Paint()
      ..color = Colors.red.withOpacity(0.12)
      ..style = PaintingStyle.fill;
    final fillE = Paint()
      ..color = Colors.green.withOpacity(0.12)
      ..style = PaintingStyle.fill;

    final xSpan = (binW * n).clamp(1e-9, 1e9);
    double xOfPressure(double p) => (plotW * ((p - minP) / xSpan)).clamp(0.0, plotW);

    Path _buildPath(List<double> ys) {
      final path = Path();
      for (int i = 0; i < n; i++) {
        final p = minP + (i + 0.5) * binW;
        final x = xOfPressure(p);
        final y = yOf(ys[i]);
        if (i == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }
      return path;
    }

    Path _buildFill(Path stroke) {
      final fill = Path.from(stroke);
      fill.lineTo(plotW, baseY);
      fill.lineTo(0, baseY);
      fill.close();
      return fill;
    }

    final pI = _buildPath(histImin);
    final pE = _buildPath(histEmin);
    canvas.drawPath(_buildFill(pE), fillE);
    canvas.drawPath(_buildFill(pI), fillI);
    canvas.drawPath(pE, lineE);
    canvas.drawPath(pI, lineI);

    // baseline
    final axisPaint = Paint()
      ..color = cs.onSurface.withOpacity(0.30)
      ..strokeWidth = 1.0;
    canvas.drawLine(Offset(0, baseY), Offset(plotW, baseY), axisPaint);

    // X-axis pressure ticks (integer cmH2O)
    final labelStyle = TextStyle(
      color: cs.onSurface.withOpacity(0.55),
      fontSize: 11,
      height: 1.0,
    );
    final tickH = 6.0;
    final pStart = (minP).ceilToDouble();
    final pEnd = (minP + binW * histImin.length).floorToDouble();
    for (double p = pStart; p <= pEnd; p += 1.0) {
      final x = ((p - minP) / (binW * histImin.length)) * plotW;
      canvas.drawLine(Offset(x, baseY), Offset(x, baseY + tickH), axisPaint);
      final tp = TextPainter(
        text: TextSpan(text: p.toStringAsFixed(0), style: labelStyle),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout();
      tp.paint(canvas, Offset(x - tp.width / 2, baseY + tickH + 2));
    }

    // small hint: total minutes
    if (totalMin.isFinite && totalMin > 0) {
      final hint = '${totalMin.toStringAsFixed(0)} min';
      final tp = TextPainter(
        text: TextSpan(text: hint, style: theme.textTheme.labelSmall?.copyWith(color: cs.onSurface.withOpacity(0.40))),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset((plotW - tp.width - 4).toDouble(), 4));
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
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