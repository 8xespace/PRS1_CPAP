import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../features/prs1/model/prs1_session.dart';

// === UI chart debug logging toggle ===
const bool kPrs1UiPressureVerbose = false;


/// 壓力（Pressure）
///
/// 對齊 OSCAR 的「Pressure」圖：
/// - 紅線：壓力設定（AutoCPAP setpoint / therapy pressure setting）
/// - 綠線：吐氣壓力（Flex / EPAP-like pressure average）
///
/// 兩條線都採用 step-hold（階梯線）：水平 hold 到下一筆，再垂直跳到新值。
class Prs1ChartPressure extends StatefulWidget {
  const Prs1ChartPressure({
    super.key,
    required this.sessionStart,
    required this.sessionEnd,
    required this.sessions,
  });

  static const String chartTitle = '壓力';

  final DateTime sessionStart;
  final DateTime sessionEnd;
  final List<Prs1Session> sessions;

  @override
  State<Prs1ChartPressure> createState() => _Prs1ChartPressureState();
}

class _Prs1ChartPressureState extends State<Prs1ChartPressure> {
  final ScrollController _hCtrl = ScrollController();

  static const double _labelW = 96.0;
  static const double _chartH = 170.0;

  @override
  void dispose() {
    _hCtrl.dispose();
    super.dispose();
  }

  DateTime _axisStart2030(DateTime sessionStartLocal) {
    // 若 sessionStart 落在中午前（通常代表跨日凌晨），則軸起點要回推到前一天 20:30。
    final baseDay = sessionStartLocal.hour < 12
        ? sessionStartLocal.subtract(const Duration(days: 1))
        : sessionStartLocal;
    return DateTime(baseDay.year, baseDay.month, baseDay.day, 20, 30);
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

    // Collect both series across sessions.
    final red = <_Pt>[];
    final green = <_Pt>[];
    for (final s in widget.sessions) {
      for (final sm in s.pressureSamples) {
        red.add(_Pt(tEpochSec: sm.tEpochSec, v: sm.value));
      }
      for (final sm in s.exhalePressureSamples) {
        green.add(_Pt(tEpochSec: sm.tEpochSec, v: sm.value));
      }
    }
    red.sort((a, b) => a.tEpochSec.compareTo(b.tEpochSec));
    green.sort((a, b) => a.tEpochSec.compareTo(b.tEpochSec));

    // DEBUG: show whether UI actually received EPAP samples, and their time range.
    if (kDebugMode) {
      int _minT(List<_Pt> pts) => pts.isEmpty ? -1 : pts.first.tEpochSec;
      int _maxT(List<_Pt> pts) => pts.isEmpty ? -1 : pts.last.tEpochSec;
      final gMin = _minT(green);
      final gMax = _maxT(green);
      final rMin = _minT(red);
      final rMax = _maxT(red);
    if (kPrs1UiPressureVerbose) {
      debugPrint('PRS1[ui_pressure_chart] sessions=${widget.sessions.length} red=${red.length} green=${green.length} '
          'greenMin=$gMin greenMax=$gMax redMin=$rMin redMax=$rMax axisDay=${axisStartLocal.toIso8601String()}');
    }

    }

    // Determine Y scale (cmH2O).
    //
    // 依照 OSCAR：固定顯示 7, 9, 11, 13（不要跟著資料自動生成太多刻度，避免表頭糊成一團）。
    // 仍保留少量 padding，讓線不會貼到上下框線。
    const yTicks = <double>[7, 9, 11, 13];
    const double tickMin = 7.0;
    const double tickMax = 13.0;

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

        // 對齊上方「事件標記 / 氣流速率」：整個壓力框不要額外左右縮排，
        // 左側起始線（20:30）應與上方圖表的起始位置切齊。
        return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 2),
        Row(
          children: [
            const Text(
              Prs1ChartPressure.chartTitle,
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
            ),
            const SizedBox(width: 10),
            _LegendDot(color: cs.error.withOpacity(0.85)),
            const SizedBox(width: 6),
            Text('壓力設定', style: theme.textTheme.labelSmall),
            const SizedBox(width: 12),
            _LegendDot(color: Colors.green.withOpacity(0.85)),
            const SizedBox(width: 6),
            Text('吐氣壓力', style: theme.textTheme.labelSmall),
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
                // Y-axis gutter
                SizedBox(
                  width: _labelW,
                  child: CustomPaint(
                    size: const Size(_labelW, _chartH),
                    painter: _PressureAxisPainter(theme: theme, tickMin: tickMin, tickMax: tickMax, ticks: yTicks),
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
                        painter: _PressurePainter(
                          theme: theme,
                          axisStartLocal: axisStartLocal,
                          axisEndLocal: axisEndLocal,
                          pxPerMinute: pxPerMinute,
                          tickMin: tickMin,
                          tickMax: tickMax,
                          ticks: yTicks,
                          pressureSetting: red,
                          exhalePressure: green,
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

class _PressurePainter extends CustomPainter {
  _PressurePainter({
    required this.theme,
    required this.axisStartLocal,
    required this.axisEndLocal,
    required this.pxPerMinute,
    required this.tickMin,
    required this.tickMax,
    required this.ticks,
    required this.pressureSetting,
    required this.exhalePressure,
  });

  final ThemeData theme;
  final DateTime axisStartLocal;
  final DateTime axisEndLocal;
  final double pxPerMinute;
  final double tickMin;
  final double tickMax;
  final List<double> ticks;
  final List<_Pt> pressureSetting;
  final List<_Pt> exhalePressure;

  @override
  void paint(Canvas canvas, Size size) {
    final cs = theme.colorScheme;
    final totalMin = axisEndLocal.difference(axisStartLocal).inMinutes;

    // Horizontal grid (align to OSCAR-like Y ticks)
    final gridPaint = Paint()
      ..color = theme.dividerColor.withOpacity(0.22)
      ..strokeWidth = 1.0;
    const double topPad = 6.0;
    const double xAxisH = 26.0;
    final plotH = math.max(0.0, size.height - topPad - xAxisH);
    final scaleY = plotH / math.max(1e-9, (tickMax - tickMin));
    double yOf(double v) => (topPad + plotH) - ((v - tickMin) * scaleY);

    // 左側起始線（20:30），對齊「氣流速率」的時間軸起點。
    final startLinePaint = Paint()
      ..color = theme.dividerColor.withOpacity(0.35)
      ..strokeWidth = 1.0;
    canvas.drawLine(Offset(0, topPad), Offset(0, topPad + plotH), startLinePaint);

    for (final v in ticks) {
      final y = yOf(v);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    // Vertical hourly grid
    DateTime _ceilToNextHour(DateTime t) {
      if (t.minute == 0 && t.second == 0 && t.millisecond == 0 && t.microsecond == 0) return t;
      final base = DateTime(t.year, t.month, t.day, t.hour);
      return base.add(const Duration(hours: 1));
    }


    final firstTick = _ceilToNextHour(axisStartLocal);
    for (DateTime tt = firstTick; !tt.isAfter(axisEndLocal); tt = tt.add(const Duration(hours: 1))) {
      final m = tt.difference(axisStartLocal).inMinutes;
      if (m < 0 || m > totalMin) continue;
      final x = m * pxPerMinute;
      final p = Paint()
        ..color = theme.dividerColor.withOpacity(0.20)
        ..strokeWidth = 1.0;
      canvas.drawLine(Offset(x, topPad), Offset(x, topPad + plotH), p);
    }

    if (pressureSetting.isEmpty && exhalePressure.isEmpty) {
      _drawCenterText(canvas, size, theme, '無壓力資料');
      return;
    }

    // Plot area (leave small top/bottom padding)

    void drawStepLine(List<_Pt> pts, Paint paint) {
      if (pts.isEmpty) return;
      // Start from first point.
      _Pt? prev;
      for (final p in pts) {
        if (!p.v.isFinite) continue;
        final tLocal = DateTime.fromMillisecondsSinceEpoch(p.tEpochSec * 1000, isUtc: true).toLocal();
        final dm = tLocal.difference(axisStartLocal).inMilliseconds / 60000.0;
        if (dm < 0) {
          prev = p;
          continue;
        }
        if (dm > totalMin) break;
        final x = dm * pxPerMinute;
        final y = yOf(p.v).clamp(topPad, topPad + plotH);
        if (prev == null) {
          prev = p;
          continue;
        }
        // Horizontal hold from prev time to current time, at prev value.
        final prevLocal = DateTime.fromMillisecondsSinceEpoch(prev.tEpochSec * 1000, isUtc: true).toLocal();
        final prevDm = prevLocal.difference(axisStartLocal).inMilliseconds / 60000.0;
        final x0 = (prevDm.clamp(0.0, totalMin.toDouble())) * pxPerMinute;
        final y0 = yOf(prev.v).clamp(topPad, topPad + plotH);
        canvas.drawLine(Offset(x0, y0), Offset(x, y0), paint);
        // Vertical jump to new value.
        canvas.drawLine(Offset(x, y0), Offset(x, y), paint);
        prev = p;
      }
    }

    final redPaint = Paint()
      ..color = cs.error.withOpacity(0.85)
      // OSCAR-like thin lines
      ..strokeWidth = 1.0
      ..strokeCap = StrokeCap.square;

    // OSCAR-like EPAP line (thin green).
    final greenPaint = Paint()
      ..color = Colors.green.withOpacity(0.85)
      ..strokeWidth = 1.0
      ..strokeCap = StrokeCap.square;

    drawStepLine(pressureSetting, redPaint);
    drawStepLine(exhalePressure, greenPaint);

    // Bottom time labels (hourly)
    final textStyle = theme.textTheme.labelSmall?.copyWith(
      color: cs.onSurface.withOpacity(0.82),
    );
    if (textStyle != null) {
      // x 軸基準線（在數值圖下方，時間刻度位於其下方）
final axisPaint = Paint()
  ..color = theme.dividerColor.withOpacity(0.35)
  ..strokeWidth = 1.0;
canvas.drawLine(Offset(0, topPad + plotH), Offset(size.width, topPad + plotH), axisPaint);

final firstTick = _ceilToNextHour(axisStartLocal);
      for (DateTime tt = firstTick; !tt.isAfter(axisEndLocal); tt = tt.add(const Duration(hours: 1))) {
        final m = tt.difference(axisStartLocal).inMinutes;
        if (m < 0 || m > totalMin) continue;
        final x = m * pxPerMinute;
        final hh = tt.hour.toString().padLeft(2, '0');
        final tp = TextPainter(
          text: TextSpan(text: '$hh:00', style: textStyle),
          textDirection: TextDirection.ltr,
        )..layout();
        final dx = (x - tp.width / 2)
            .clamp(0.0, math.max(0.0, size.width - tp.width))
            .toDouble();
        final yText = topPad + plotH + (xAxisH - tp.height) / 2;
        tp.paint(canvas, Offset(dx, yText));
      }
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
  bool shouldRepaint(covariant _PressurePainter oldDelegate) {
    return oldDelegate.pressureSetting != pressureSetting ||
        oldDelegate.exhalePressure != exhalePressure ||
        oldDelegate.tickMax != tickMax ||
        oldDelegate.axisStartLocal != axisStartLocal ||
        oldDelegate.axisEndLocal != axisEndLocal ||
        oldDelegate.pxPerMinute != pxPerMinute;
  }
}

class _PressureAxisPainter extends CustomPainter {
  _PressureAxisPainter({required this.theme, required this.tickMin, required this.tickMax, required this.ticks});
  final ThemeData theme;
  final double tickMin;
  final double tickMax;
  final List<double> ticks;

  @override
  void paint(Canvas canvas, Size size) {
    final cs = theme.colorScheme;

    // IMPORTANT: axis painter must match the plot area's geometry exactly,
    // otherwise the Y labels will drift and look like "random numbers".
    const double topPad = 6.0;
    const double xAxisH = 26.0;
    final plotH = math.max(0.0, size.height - topPad - xAxisH);
    final denom = math.max(1e-9, (tickMax - tickMin));
    double yOf(double v) => (topPad + plotH) - ((v - tickMin) / denom) * plotH;

    final axisX = size.width - 1;
    final axisPaint = Paint()
      ..color = theme.dividerColor.withOpacity(0.70)
      ..strokeWidth = 2.0;
    // Darker Y-axis line like OSCAR (only across plot, not through x-axis labels).
    canvas.drawLine(Offset(axisX, topPad), Offset(axisX, topPad + plotH), axisPaint);

    final tickPaint = Paint()
      ..color = theme.dividerColor.withOpacity(0.60)
      ..strokeWidth = 1.0;

    final labelStyle = theme.textTheme.labelSmall?.copyWith(
      color: cs.onSurface.withOpacity(0.88),
      fontSize: 12,
    );
    if (labelStyle == null) return;

    for (final v in ticks) {
      final y = yOf(v);
      // Small tick mark on the axis line.
      canvas.drawLine(Offset(axisX - 8, y), Offset(axisX, y), tickPaint);

      final tp = TextPainter(
        text: TextSpan(text: _fmtTick(v), style: labelStyle),
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.right,
      )..layout(maxWidth: math.max(0.0, axisX - 10));

      // Right-align labels close to the axis, centered vertically.
      tp.paint(canvas, Offset(axisX - 10 - tp.width, y - tp.height / 2));
    }
  }

  String _fmtTick(double v) {
    // Keep trailing .0 off.
    if ((v - v.roundToDouble()).abs() < 1e-9) return v.toStringAsFixed(0);
    return v.toStringAsFixed(1);
  }

  @override
  bool shouldRepaint(covariant _PressureAxisPainter oldDelegate) {
    return oldDelegate.tickMin != tickMin || oldDelegate.tickMax != tickMax || !listEquals(oldDelegate.ticks, ticks) || oldDelegate.theme != theme;
  }
}