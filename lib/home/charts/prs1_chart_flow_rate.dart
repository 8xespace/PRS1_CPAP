import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../features/prs1/model/prs1_session.dart';
import '../../features/prs1/waveform/prs1_waveform_index.dart';
import '../../features/prs1/waveform/prs1_waveform_types.dart';
import '../../features/prs1/waveform/prs1_waveform_viewport.dart';

/// 氣流速率 (Flow Rate) 全日(24h)時間軸波形圖：
/// - 以「20:30」作為右側圖表的軸起點（避免 21:00 刻度被上方標題遮擋）
/// - 時間軸總長 24 小時（20:30 -> 隔日 20:30）
/// - 預設視窗等效顯示 20:30~09:00；其餘時間可水平滑移查看
/// - 支援滑鼠/觸控拖曳水平滑移
class Prs1ChartFlowRate extends StatefulWidget {
  const Prs1ChartFlowRate({
    super.key,
    required this.sessionStart,
    required this.sessionEnd,
    required this.sessions,
  });

  final DateTime? sessionStart;
  final DateTime? sessionEnd;

  /// 當日所有 session（用來建立 waveform index，確保波形完整）
  final List<Prs1Session> sessions;

  @override
  State<Prs1ChartFlowRate> createState() => _Prs1ChartFlowRateState();
}

class _Prs1ChartFlowRateState extends State<Prs1ChartFlowRate> {
  final ScrollController _hCtrl = ScrollController();

  static const double _labelW = 96.0; // 對齊事件標記左欄切線
  static const double _chartH = 220.0;

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
    final sessionStart = widget.sessionStart;
    final sessionEnd = widget.sessionEnd;

    if (sessionStart == null || sessionEnd == null) {
      return _empty(context, '無氣流速率資料');
    }

    final axisStartLocal = _axisStart2030(sessionStart);
    final axisEndLocal = axisStartLocal.add(const Duration(hours: 24));
    final totalMinutes = axisEndLocal.difference(axisStartLocal).inMinutes; // 1440

    final index = Prs1WaveformIndex.build(widget.sessions);

    return LayoutBuilder(
      builder: (context, c) {
        final maxW = c.maxWidth.isFinite ? c.maxWidth : 900.0;

        // 讓 20:30~09:00（12.5h=750min）在螢幕上視覺上「滿版」；其餘水平捲動查看
        final chartViewportW = math.max(0.0, maxW - _labelW);
        final pxPerMinute = (chartViewportW / 750.0) * 0.95;
        final totalW = totalMinutes * pxPerMinute;

        final startUtcMs = axisStartLocal.toUtc().millisecondsSinceEpoch;
        final endUtcMs = axisEndLocal.toUtc().millisecondsSinceEpoch;

        final maxBuckets = math.min(totalW.floor().clamp(300, 5000), 3000);
        final pts = Prs1WaveformViewport.queryEnvelope(
          index: index,
          signal: Prs1WaveformSignal.flow,
          startEpochMs: startUtcMs,
          endEpochMsExclusive: endUtcMs,
          maxBuckets: maxBuckets,
        );

        // 找一個合理的 ±max 讓刻度/波形一致（OSCAR 風格：四捨五入到 10 的倍數）
        double absMax = 0;
        for (final p in pts) {
          if (p.min.isNaN || p.max.isNaN) continue;
          absMax = math.max(absMax, p.max.abs());
          absMax = math.max(absMax, p.min.abs());
        }
        absMax = (absMax.isFinite ? absMax : 0) * 1.10;
        double tickMax = absMax > 0 ? absMax : 1.0;
        tickMax = (tickMax / 10.0).ceilToDouble() * 10.0;

        void onDragHorizontal(DragUpdateDetails d) {
          if (!_hCtrl.hasClients) return;
          final max = _hCtrl.position.maxScrollExtent;
          final next = (_hCtrl.offset - d.delta.dx).clamp(0.0, max);
          _hCtrl.jumpTo(next);
        }

        return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '氣流速率',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: _chartH,

          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                border: Border.all(
                  color: Theme.of(context).dividerColor.withOpacity(0.25),
                ),
              ),
              child: Row(
                children: [
                  // 左側正負刻度（固定不隨水平捲動）
                  SizedBox(
                    width: _labelW,
                    height: _chartH,
                    child: CustomPaint(
                      painter: _FlowRateAxisPainter(
                        theme: Theme.of(context),
                        tickMax: tickMax,
                      ),
                    ),
                  ),
                  // 波形（可水平捲動 + 滑鼠拖曳）
                  Expanded(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onPanUpdate: onDragHorizontal,
                      child: ScrollConfiguration(
                        behavior: const ScrollBehavior().copyWith(
                          dragDevices: {
                            PointerDeviceKind.touch,
                            PointerDeviceKind.mouse,
                            PointerDeviceKind.trackpad,
                          },
                        ),
                        child: SingleChildScrollView(
                          controller: _hCtrl,
                          scrollDirection: Axis.horizontal,
                          child: CustomPaint(
                            size: Size(totalW, _chartH),
                            painter: _FlowRatePainter(
                              theme: Theme.of(context),
                              pts: pts,
                              tickMax: tickMax,
                              axisStartLocal: axisStartLocal,
                              axisEndLocal: axisEndLocal,
                              pxPerMinute: pxPerMinute,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          ),
        ],
      );
      },
    );
  }

  Widget _empty(BuildContext context, String text) {
    return SizedBox(
      height: _chartH,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Theme.of(context).dividerColor.withOpacity(0.25)),
        ),
        child: Center(
          child: Text(
            text,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).hintColor,
                ),
          ),
        ),
      ),
    );
  }
}

class _FlowRatePainter extends CustomPainter {
  _FlowRatePainter({
    required this.theme,
    required this.pts,
    required this.tickMax,
    required this.axisStartLocal,
    required this.axisEndLocal,
    required this.pxPerMinute,
  });

  final ThemeData theme;
  final List<Prs1MinMaxPoint> pts;
  final double tickMax;
  final DateTime axisStartLocal;
  final DateTime axisEndLocal;
  final double pxPerMinute;

  @override
  void paint(Canvas canvas, Size size) {
    final cs = theme.colorScheme;

    // 與右側波形 painter 一致：保留下方時間軸高度，避免刻度落到時間軸區
    const double xAxisH = 26.0;
    final plotH = math.max(0.0, size.height - xAxisH);
    final plotRect = Rect.fromLTWH(0, 0, size.width, plotH);


    final gridPaint = Paint()
      ..color = theme.dividerColor.withOpacity(0.25)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;

    // 先畫出「數值圖」的封閉長方形邊框（你要的完整矩形）
    final borderPaint = Paint()
      ..color = theme.dividerColor.withOpacity(0.35)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;
    canvas.drawRect(plotRect, borderPaint);

    // 只在 plotRect 內繪製格線/波形（超出正負值範圍就不畫）
    canvas.save();
    canvas.clipRect(plotRect);

    // 背景水平中線 (0)
    final midY = plotH / 2;
    canvas.drawLine(Offset(0, midY), Offset(size.width, midY), gridPaint);

    // 淡淡的上下參考線（±tickMax/3、±tickMax）
    final scaleY = (plotH * 0.45) / tickMax;
    for (final v in <double>[tickMax / 3, -tickMax / 3, tickMax, -tickMax]) {
      final y = (midY - v * scaleY).clamp(0.0, plotH);
      final p = Paint()
        ..color = theme.dividerColor.withOpacity(0.15)
        ..strokeWidth = 1.0;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), p);
    }

    // 時間垂直網格：每 1 小時一格（對齊事件標記）
    DateTime _ceilToNextHour(DateTime t) {
      if (t.minute == 0 && t.second == 0 && t.millisecond == 0 && t.microsecond == 0) {
        return t;
      }
      final base = DateTime(t.year, t.month, t.day, t.hour);
      return base.add(const Duration(hours: 1));
    }

    final totalMin = axisEndLocal.difference(axisStartLocal).inMinutes;
    final firstTick = _ceilToNextHour(axisStartLocal);
    for (DateTime tt = firstTick; !tt.isAfter(axisEndLocal); tt = tt.add(const Duration(hours: 1))) {
      final m = tt.difference(axisStartLocal).inMinutes;
      if (m < 0 || m > totalMin) continue;
      final x = m * pxPerMinute;
      final p = Paint()
        ..color = theme.dividerColor.withOpacity(0.20)
        ..strokeWidth = 1.0;
      // 垂直格線只畫到 plotRect（不延伸到時間刻度區）
      canvas.drawLine(Offset(x, 0), Offset(x, plotH), p);
    }

    if (pts.isEmpty) {
      _drawCenterText(canvas, Size(size.width, plotH), theme, '無氣流速率資料');
      canvas.restore();
      _paintXAxis(canvas, size, plotH, xAxisH);
      return;
    }

    final wavePaint = Paint()
      ..color = cs.onSurface.withOpacity(0.70)
      ..strokeWidth = 1.0
      ..strokeCap = StrokeCap.round;

    // 用 min/max 畫垂直線段（envelope）
    for (final p in pts) {
      final utc = DateTime.fromMillisecondsSinceEpoch(p.epochMs, isUtc: true);
      final tLocal = utc.toLocal();
      final dm = tLocal.difference(axisStartLocal).inMilliseconds / 60000.0;
      if (dm < 0 || dm > totalMin) continue;

      final x = dm * pxPerMinute;
      final minV = p.min;
      final maxV = p.max;
      if (minV.isNaN || maxV.isNaN) continue;

      // 你要「正負值以外不需要繪製線段」：把 y clamp 在 plotRect 內，避免越界
      final y0 = (midY - maxV * scaleY).clamp(0.0, plotH);
      final y1 = (midY - minV * scaleY).clamp(0.0, plotH);
      if ((y0 - y1).abs() < 0.2) continue;
      canvas.drawLine(Offset(x, y0), Offset(x, y1), wavePaint);
    }

    canvas.restore();

    // 最後畫時間刻度（獨立在下方 xAxisH 區塊，文字置中對準分割線）
    _paintXAxis(canvas, size, plotH, xAxisH);
  }

  void _paintXAxis(Canvas canvas, Size size, double plotH, double xAxisH) {
    final cs = theme.colorScheme;

    // x 軸基準線（在數值圖下方）
    final axisPaint = Paint()
      ..color = theme.dividerColor.withOpacity(0.35)
      ..strokeWidth = 1.0;
    canvas.drawLine(Offset(0, plotH), Offset(size.width, plotH), axisPaint);

    DateTime _ceilToNextHour(DateTime t) {
      if (t.minute == 0 && t.second == 0 && t.millisecond == 0 && t.microsecond == 0) {
        return t;
      }
      final base = DateTime(t.year, t.month, t.day, t.hour);
      return base.add(const Duration(hours: 1));
    }

    final totalMin = axisEndLocal.difference(axisStartLocal).inMinutes;
    final textStyle = theme.textTheme.labelSmall?.copyWith(
          color: cs.onSurface.withOpacity(0.82),
        );
    if (textStyle == null) return;

    final yText = plotH + (xAxisH - (theme.textTheme.labelSmall?.fontSize ?? 10) - 2) / 2;

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

      // 置中對準「時間分割線」
      final dx = (x - tp.width / 2)
          .clamp(0.0, math.max(0.0, size.width - tp.width))
          .toDouble();
      tp.paint(canvas, Offset(dx, yText));
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
  bool shouldRepaint(covariant _FlowRatePainter oldDelegate) {
    return oldDelegate.pts != pts ||
        oldDelegate.tickMax != tickMax ||
        oldDelegate.axisStartLocal != axisStartLocal ||
        oldDelegate.axisEndLocal != axisEndLocal ||
        oldDelegate.pxPerMinute != pxPerMinute;
  }
}

class _FlowRateAxisPainter extends CustomPainter {
  _FlowRateAxisPainter({
    required this.theme,
    required this.tickMax,
  });

  final ThemeData theme;
  final double tickMax;

  @override
  void paint(Canvas canvas, Size size) {
    final cs = theme.colorScheme;

    // 與主波形 painter 一致：下方保留時間軸高度
    const double xAxisH = 26.0;
    final plotH = math.max(0.0, size.height - xAxisH);
    final plotRect = Rect.fromLTWH(0, 0, size.width, plotH);

    // 右側邊界線（用來跟事件標記「切線」對齊）
    final borderPaint = Paint()
      ..color = theme.dividerColor.withOpacity(0.45)
      ..strokeWidth = 1.0;
    canvas.drawLine(Offset(size.width - 1, 0), Offset(size.width - 1, plotH), borderPaint);

    canvas.save();
    canvas.clipRect(plotRect);

    final midY = plotH / 2;
    final scaleY = (plotH * 0.5) / tickMax;

    // 刻度：+max, +max/3, 0, -max/3, -max
    final ticks = <double>[tickMax, tickMax / 3, 0, -tickMax / 3, -tickMax];

    final tickPaint = Paint()
      ..color = theme.dividerColor.withOpacity(0.55)
      ..strokeWidth = 1.0;

    final labelStyle = theme.textTheme.labelSmall?.copyWith(
          color: cs.onSurface.withOpacity(0.82),
        );

    for (final v in ticks) {
      const double edgeInset = 5.0;
      final yTick = (midY - v * scaleY).clamp(edgeInset, plotH - edgeInset);
      // 小刻度線
      canvas.drawLine(Offset(size.width - 10, yTick), Offset(size.width - 1, yTick), tickPaint);

      if (labelStyle != null) {
        final label = _fmtTick(v);
        final tp = TextPainter(
          text: TextSpan(text: label, style: labelStyle),
          textDirection: TextDirection.ltr,
        )..layout();

        final yText = (yTick - tp.height / 2).clamp(edgeInset, plotH - edgeInset - tp.height);
        tp.paint(canvas, Offset(size.width - 12 - tp.width, yText));
      }
    }

    canvas.restore();

    // 0 中線強調
    final zeroPaint = Paint()
      ..color = cs.onSurface.withOpacity(0.12)
      ..strokeWidth = 1.0;
    canvas.drawLine(Offset(0, midY), Offset(size.width - 1, midY), zeroPaint);
  }

  String _fmtTick(double v) {
    if (v == 0) return '0';
    // 盡量不顯示小數
    final a = v.abs();
    if (a >= 100) return v.toStringAsFixed(0);
    if (a >= 10) return v.toStringAsFixed(0);
    return v.toStringAsFixed(1);
  }

  @override
  bool shouldRepaint(covariant _FlowRateAxisPainter oldDelegate) {
    return oldDelegate.tickMax != tickMax || oldDelegate.theme != theme;
  }
}
