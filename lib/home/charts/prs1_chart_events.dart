import 'dart:math' as math;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import '../../features/prs1/model/prs1_event.dart';

/// 事件標記（對齊 OSCAR 右側最上方事件列）
///
/// 需求重點：
/// 1) 左側標題固定（不隨時間軸水平捲動）
/// 2) 時間軸可水平捲動，且支援滑鼠「按住拖曳」
/// 3) lane 列高更緊湊（約原本 60%）
class Prs1ChartEvents extends StatefulWidget {
  const Prs1ChartEvents({
    super.key,
    required this.sessionStart,
    required this.sessionEnd,
    required this.events,
  });

  final DateTime sessionStart;
  final DateTime sessionEnd;
  final List<Prs1Event> events;

  @override
  State<Prs1ChartEvents> createState() => _Prs1ChartEventsState();
}

class _Prs1ChartEventsState extends State<Prs1ChartEvents> {
  final ScrollController _hCtrl = ScrollController();
  // 像素/分鐘：依 viewport 動態決定，使 21:00~09:00（12h）剛好落在可視區，09:00~21:00 隱藏於右側可水平捲動。

  @override
  void dispose() {
    _hCtrl.dispose();
    super.dispose();
  }

  void _onDragHorizontal(DragUpdateDetails d) {
    if (!_hCtrl.hasClients) return;
    final max = _hCtrl.position.maxScrollExtent;
    final next = (_hCtrl.offset - d.delta.dx).clamp(0.0, max);
    _hCtrl.jumpTo(next);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    // 以 21:00 作為一天時間軸起點，整段顯示 24h（21:00~隔日21:00）
    final axisStart = _EventsPainter.axisStartForSession(widget.sessionStart);
    final axisEnd = axisStart.add(const Duration(hours: 24, minutes: 30));

    // 真實 session 區間（用於 clamp / debug），但座標軸固定用 axisStart/axisEnd
    final start = widget.sessionStart;
    final end = widget.sessionEnd.isAfter(widget.sessionStart)
        ? widget.sessionEnd
        : widget.sessionStart.add(const Duration(minutes: 1));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '事件標記',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        LayoutBuilder(
          builder: (context, constraints) {
            final lanes = _EventsPainter.lanes;
            final totalMinutes = axisEnd.difference(axisStart).inMinutes; // fixed 1440 (24h)

            final labelW = _EventsPainter.fixedLabelWidth;
            final viewportW = constraints.maxWidth;
            final chartViewportW = math.max(0.0, viewportW - labelW);

            // 讓 20:30~09:00（12.5h=750min）剛好落在可視寬度內（約 95%），白天 09:00~21:00 需要水平捲動才看得到。
            final pxPerMinute = chartViewportW <= 0
                ? 1.0
                : (chartViewportW / (12.5 * 60)) * 0.95;

            final contentW = math.max(
              chartViewportW,
              (_EventsPainter.plotLeftPad + _EventsPainter.rightPad) +
                  (totalMinutes * pxPerMinute),
            );

            return Container(
              decoration: BoxDecoration(
                color: scheme.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: scheme.outlineVariant),
              ),
              padding: const EdgeInsets.only(bottom: 6), // 避免下緣出框穿幫
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: labelW,
                    child: CustomPaint(
                      painter: _EventsLabelPainter(
                        lanes: lanes,
                        scheme: scheme,
                      ),
                      child: SizedBox(height: _EventsPainter.preferredHeight),
                    ),
                  ),
                  Expanded(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onHorizontalDragUpdate: _onDragHorizontal,
                      child: ScrollConfiguration(
                        behavior: const _ChartScrollBehavior(),
                        child: SingleChildScrollView(
                          controller: _hCtrl,
                          scrollDirection: Axis.horizontal,
                          child: SizedBox(
                            width: contentW,
                            child: CustomPaint(
                              painter: _EventsPainter(
                                start: axisStart,
                                end: axisEnd,
                                events: widget.events,
                                colorScheme: scheme,
                                drawLabels: false,
                                pxPerMinute: pxPerMinute,
                              ),
                              child: SizedBox(height: _EventsPainter.preferredHeight),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ],
    );
  }
}

/// Web/桌機：允許滑鼠/觸控板捲動；拖曳由 GestureDetector 處理
class _ChartScrollBehavior extends MaterialScrollBehavior {
  const _ChartScrollBehavior();
  @override
  Set<PointerDeviceKind> get dragDevices => {
        PointerDeviceKind.touch,
        PointerDeviceKind.mouse,
        PointerDeviceKind.trackpad,
        PointerDeviceKind.stylus,
        PointerDeviceKind.unknown,
      };
}

class _LaneDef {
  const _LaneDef(this.type, this.shortLabel, this.colorHint);

  final Prs1EventType type;
  final String shortLabel;

  /// A stable color hint for the lane (not theme-dependent).
  final Color colorHint;
}

class _EventsLabelPainter extends CustomPainter {
  _EventsLabelPainter({
    required this.lanes,
    required this.scheme,
  });

  final List<_LaneDef> lanes;
  final ColorScheme scheme;

  @override
  void paint(Canvas canvas, Size size) {
    final laneCount = lanes.length;
    final topPad = _EventsPainter.topPad;
    final bottomPad = _EventsPainter.bottomPad;
    final laneGap = _EventsPainter.laneGap;

    final availableH = _EventsPainter.preferredHeight - topPad - bottomPad;
    final laneH = math.max<double>(
      _EventsPainter.minLaneHeight,
      ((availableH - laneGap * (laneCount - 1)) / laneCount).toDouble(),
    );
    // 背景由上層 Container 決定；此處不額外鋪底色（保持乾淨白底黑字）。

    final textPainter = TextPainter(
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    );

    double y = topPad;
    for (int i = 0; i < laneCount; i++) {
      final rect = Rect.fromLTWH(0, y, size.width, laneH);
      // Labels for lanes are drawn in this fixed (non-scroll) label column.
      // The scrolling event canvas (_EventsPainter) must NOT draw labels,
      // otherwise labels appear duplicated.
      final label = lanes[i].shortLabel;
      textPainter.text = TextSpan(
        text: label,
        style: TextStyle(
          color: scheme.onSurface,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      );
      textPainter.layout(maxWidth: size.width - 8);
      textPainter.paint(
        canvas,
        Offset(4, y + (laneH - textPainter.height) / 2),
      );

      y += laneH + laneGap;
    }

    // right divider
    canvas.drawLine(
      Offset(size.width - 1, topPad),
      Offset(size.width - 1, _EventsPainter.preferredHeight - bottomPad),
      Paint()..color = scheme.outlineVariant,
    );
  }

  @override
  bool shouldRepaint(covariant _EventsLabelPainter oldDelegate) {
    return oldDelegate.lanes.length != lanes.length || oldDelegate.scheme != scheme;
  }
}

class _EventsPainter extends CustomPainter {

  // --- Layout tuning for Chinese lane labels ---
  // 中文欄名較長，為了可讀性提高每列最小高度
  static const double _minLaneHeight = 22.8; // 60% of 38.0 for compact rows
  static const double _topPad = 10.0;
  static const double _bottomPad = 28.0;

  // Public aliases (used by widget/layout code)
  static const double minLaneHeight = _minLaneHeight;
  static const double topPad = _topPad;
  static const double bottomPad = _bottomPad;

  // Keep label column width aligned with painter's internal left padding.
  static const double fixedLabelWidth = 96.0; // width of the fixed label column (UI)
  static const double plotLeftPad = 0.0; // plot starts at 0 because labels are rendered in a separate fixed column
  static const double rightPad = 10.0;

  // Lanes are rendered contiguously in the painter; keep gap at 0 for consistent height math.
  static const double laneGap = 0.0;


  /// Preferred height so each lane has enough vertical space.
  static final double preferredHeight = _topPad + _bottomPad + (_lanes.length * _minLaneHeight);

  /// 以 21:00 作為 24h 時間軸起點；若 sessionStart 在中午以前，視為隔天清晨，回推到前一日 21:00。
  static DateTime axisStartForSession(DateTime sessionStart) {
    final d = DateTime(sessionStart.year, sessionStart.month, sessionStart.day);
    final baseDay = (sessionStart.hour < 12) ? d.subtract(const Duration(days: 1)) : d;
    return DateTime(baseDay.year, baseDay.month, baseDay.day, 20, 30);
  }


  _EventsPainter({
    required this.start,
    required this.end,
    required this.events,
    required this.colorScheme,
    this.drawLabels = false,
    this.pxPerMinute,
  });

  final DateTime start;
  final DateTime end;
  final List<Prs1Event> events;
  final ColorScheme colorScheme;

  // Optional toggles for future tuning; currently not required by paint logic.
  final bool drawLabels;
  final double? pxPerMinute;


  // OSCAR-like lane ordering (top-to-bottom).
  static const List<_LaneDef> _lanes = [
    _LaneDef(Prs1EventType.periodicBreathing, '週期性呼吸', Color(0xFF7CD77B)), // PB
    _LaneDef(Prs1EventType.variableBreathing, '變動呼吸', Color(0xFF63C7C7)), // VB
    _LaneDef(Prs1EventType.largeLeak, '大量漏氣', Color(0xFFB06CFF)), // LL
    _LaneDef(Prs1EventType.clearAirwayApnea, '中樞型中止', Color(0xFF5A7BFF)), // CA
    _LaneDef(Prs1EventType.obstructiveApnea, '阻塞性中止', Color(0xFF1EA7FF)), // OA
    _LaneDef(Prs1EventType.hypopnea, '低通氣', Color(0xFFFFB000)), // H
    _LaneDef(Prs1EventType.flowLimitation, '氣流限制', Color(0xFFFFE066)), // FL
    _LaneDef(Prs1EventType.rera, '呼吸引發的覺醒', Color(0xFFFFC857)), // RE
    // VS / VS2 must appear directly under RE (per OSCAR lane order).
    _LaneDef(Prs1EventType.vibratorySnore, '打鼾 VS', Color(0xFFFF6B6B)),
    _LaneDef(Prs1EventType.vibratorySnore2, '打鼾 VS2', Color(0xFFE53935)),
    _LaneDef(Prs1EventType.pressurePulse, '壓力脈衝', Color(0xFF9AA0A6)), // PP
    _LaneDef(Prs1EventType.breathNotDetected, '未監測到呼吸', Color(0xFF616161)), // BND
  ];

  static List<_LaneDef> get lanes => _lanes;


  @override
  void paint(Canvas canvas, Size size) {
    final leftPad = plotLeftPad;   // plot left padding (labels are rendered in a separate fixed column)
    final rightPad = 10.0;
    final topPad = _topPad;
    final bottomPad = _bottomPad; // room for x-axis labels

    final plotW = math.max(1.0, size.width - leftPad - rightPad).toDouble();

    final laneCount = _lanes.length;

    // 依 lanes 數量給足每列高度（中文字可讀），避免擠壓重疊。
    final plotH = math.max(1.0, size.height - topPad - bottomPad).toDouble();
    final laneH = math.max(_minLaneHeight, plotH / laneCount).toDouble();
    final effectivePlotH = laneH * laneCount;

    // Background
    final bg = Paint()..color = colorScheme.surface;
    canvas.drawRect(Offset.zero & size, bg);

    // Alternating lane background + grid lines
    for (var i = 0; i < laneCount; i++) {
      final y0 = topPad + i * laneH;
      final laneRect = Rect.fromLTWH(leftPad, y0, plotW, laneH);
      final laneBg = Paint()
        ..color = (i % 2 == 0)
            ? Color.alphaBlend(colorScheme.surfaceVariant.withOpacity(0.35), colorScheme.surface)
            : Color.alphaBlend(colorScheme.surfaceVariant.withOpacity(0.18), colorScheme.surface);
      canvas.drawRect(laneRect, laneBg);

      final grid = Paint()
        ..color = colorScheme.outlineVariant.withOpacity(0.55)
        ..strokeWidth = 1;
      canvas.drawLine(Offset(leftPad, y0), Offset(leftPad + plotW, y0), grid);
    }
    // bottom grid
    final grid = Paint()
      ..color = colorScheme.outlineVariant.withOpacity(0.55)
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(leftPad, topPad + effectivePlotH),
      Offset(leftPad + plotW, topPad + effectivePlotH),
      grid,
    );


    // Lane labels are rendered in the fixed left column (UI). Keep this optional for debug only.
    if (drawLabels && fixedLabelWidth > 0) {
      for (var i = 0; i < laneCount; i++) {
        final lane = _lanes[i];
        final yCenter = topPad + i * laneH + laneH / 2;

        final tp = TextPainter(
          text: TextSpan(
            text: lane.shortLabel,
            style: TextStyle(
              color: colorScheme.onSurfaceVariant,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: fixedLabelWidth - 10);

        // Draw at the far-left of the canvas
        tp.paint(canvas, Offset(8, yCenter - tp.height / 2));
      }
    }

final totalMs = end.difference(start).inMilliseconds;
    if (totalMs <= 0) return;

    double xOf(DateTime t) {
      final ms = t.difference(start).inMilliseconds;
      final r = (ms / totalMs).clamp(0.0, 1.0);
      return leftPad + r * plotW;
    }

    // Events
    for (final e in events) {
      // clamp to session window
      if (e.time.isBefore(start) || e.time.isAfter(end)) continue;

        var t = e.type;
        if (t == Prs1EventType.snore) t = Prs1EventType.vibratorySnore;
        if (t == Prs1EventType.pressureChange) t = Prs1EventType.pressurePulse;
        final laneIndex = _lanes.indexWhere((l) => l.type == t);
      if (laneIndex < 0) continue;

      final lane = _lanes[laneIndex];
      final x = xOf(e.time);
      final y0 = topPad + laneIndex * laneH;
      final y1 = y0 + laneH;

      final p = Paint()
        ..color = lane.colorHint.withOpacity(0.95)
        ..strokeWidth = 2;

      // OSCAR-like vertical marker within lane
      final inset = laneH * 0.20;
      canvas.drawLine(Offset(x, y0 + inset), Offset(x, y1 - inset), p);
    }

    // X-axis ticks (hourly)
    final tickPaint = Paint()
      ..color = colorScheme.outlineVariant.withOpacity(0.65)
      ..strokeWidth = 1;

    final labelStyle = TextStyle(
      color: colorScheme.onSurfaceVariant,
      fontSize: 11,
      fontWeight: FontWeight.w500,
    );

    // Start at the next full hour after start (or start hour itself if aligned)
    DateTime tick = DateTime(start.year, start.month, start.day, start.hour);
    if (tick.isBefore(start)) tick = tick.add(const Duration(hours: 1));

    while (tick.isBefore(end)) {
      final x = xOf(tick);
      // tick line
      canvas.drawLine(
        Offset(x, topPad + effectivePlotH),
        Offset(x, topPad + effectivePlotH + 4),
        tickPaint,
      );

      final label = '${tick.hour.toString().padLeft(2, '0')}:${tick.minute.toString().padLeft(2, '0')}';
      final tp = TextPainter(
        text: TextSpan(text: label, style: labelStyle),
        textDirection: TextDirection.ltr,
      )..layout();

      tp.paint(canvas, Offset(x - tp.width / 2, topPad + effectivePlotH + 6));
      tick = tick.add(const Duration(hours: 1));
    }
  }

  @override
  bool shouldRepaint(covariant _EventsPainter oldDelegate) {
    return oldDelegate.start != start ||
        oldDelegate.end != end ||
        oldDelegate.events != events ||
        oldDelegate.colorScheme != colorScheme;
  }
}