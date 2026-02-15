import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../app_state.dart';
import '../features/prs1/aggregate/prs1_daily_models.dart';
import '../features/prs1/model/prs1_session.dart';
import '../features/prs1/model/prs1_waveform_channel.dart';
import '../features/prs1/stats/prs1_rolling_metrics.dart';
import 'charts/prs1_chart_events.dart';
import 'charts/prs1_chart_flow_rate.dart';
import 'charts/prs1_chart_cross_analysis.dart';
import 'charts/prs1_chart_pressure.dart';
import 'charts/prs1_chart_leak_rate.dart';
import 'charts/prs1_chart_snore.dart';
import 'charts/prs1_chart_ahi.dart';
import 'charts/prs1_chart_pressure_time.dart';
import 'charts/prs1_chart_tidal_volume.dart';
import 'charts/prs1_chart_resp_rate.dart';
import 'charts/prs1_chart_minute_vent.dart';
import 'charts/prs1_chart_insp_time.dart';
import 'charts/prs1_chart_exp_time.dart';
import 'package:tophome/features/prs1/derive/prs1_event_deriver.dart';

// --- Brand color helpers (keep Layer-3 colors synced with selected BrandColor) ---
Color _deepen(Color c, {required Brightness brightness, double amountLight = 0.60, double amountDark = 0.25}) {
  // Blend towards black to get a stable "accent" that still tracks BrandColor.
  final t = brightness == Brightness.dark ? amountDark : amountLight;
  return Color.lerp(c, Colors.black, t)!;
}

Color _soften(Color c, Color toward, {double t = 0.65}) {
  return Color.lerp(c, toward, t)!;
}

Color _readableOn(Color bg) {
  // Simple luminance-based contrast choice.
  return bg.computeLuminance() > 0.55 ? Colors.black : Colors.white;
}

/// Phase 4：右側圖表序列載入的 key（順序固定）。
enum _ChartKey {
  events,
  flowRate,
  crossAnalysis,
  pressure,
  leakRate,
  tidalVolume,
  respRate,
  minuteVent,
  snore,
  inspTime,
  expTime,
  ahi,
  pressureTime,
}


/// 單列統計資料（對齊 OSCAR：最小 / 中間值 / 95% / 最大）
class _StatRow {
  final String label;
  final String unit;
  final double? min;
  final double? median;
  final double? p95;
  final double? max;

  const _StatRow(
    this.label, {
    this.unit = '',
    required this.min,
    required this.median,
    required this.p95,
    required this.max,
  });
}

/// 給一般使用者看的「核心指標」：整晚 AHI（與 OSCAR Daily AHI 對齊）。
class _AhiBanner extends StatelessWidget {
  const _AhiBanner({required this.ahi, this.onTap});

  final double? ahi;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final v = ahi;
    final text = v == null ? '—' : v.toStringAsFixed(2);

    final appState = AppStateScope.of(context);
    final cs = theme.colorScheme;
    final bg = _deepen(appState.brandColor.color, brightness: cs.brightness);
    final fg = _readableOn(bg);

    final content = Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            blurRadius: 12,
            spreadRadius: 0,
            offset: const Offset(0, 6),
            color: Colors.black.withOpacity(0.10),
          ),
        ],
      ),
      child: Center(
        child: Text(
          '呼吸中止指數 (AHI)：$text',
          style: theme.textTheme.titleLarge?.copyWith(
            color: fg,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.2,
          ),
        ),
      ),
    );

    if (onTap == null) return content;

    // Phase 3：AHI 變按鈕（點擊後展開右側區域）。
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: content,
      ),
    );
  }
}

class Prs1DashboardPage extends StatefulWidget {
  const Prs1DashboardPage({super.key});

  @override
  State<Prs1DashboardPage> createState() => _Prs1DashboardPageState();
}

class _Prs1DashboardPageState extends State<Prs1DashboardPage> {
  static const bool kPrs1UiLogs = false; // set true to re-enable Phase4/5 debugPrint logs
  late ScrollController _rightChartsCtrl;
  Key _rightChartsListKey = UniqueKey();

  // Phase 4：右側圖表序列載入（按 AHI 後才開始），並支援 cancel。
  bool _showRight = false;
  final List<_ChartKey> _loadedCharts = <_ChartKey>[];
  int _queueToken = 0;
  DateTime? _queueDay;

  
  @override
  void initState() {
    super.initState();
    _rightChartsCtrl = ScrollController();
  }

  @override
  void dispose() {
    _rightChartsCtrl.dispose();
    super.dispose();
  }

ColorScheme get scheme => Theme.of(context).colorScheme;

  int _selectedIndex = 0; // index into last7
  bool _didInitSelection = false;
  int _weekOffset = 0; // 0 = latest week, -1 = previous week ...
  void _prevWeek(int maxBackWeeks) {
    if (_weekOffset > -maxBackWeeks) {
      setState(() {
        _weekOffset -= 1;
        _selectedIndex = 0;
        _didInitSelection = false;
        _hardClearWorkingSet('date/window changed');
      });
    }
  }

  void _nextWeek() {
    if (_weekOffset < 0) {
      setState(() {
        _weekOffset += 1;
        _selectedIndex = 0;
        _didInitSelection = false;
        _hardClearWorkingSet('date/window changed');
      });
    }
  }

  
  void _hardClearWorkingSet(String reason) {
    // Phase 5：記憶體釋放保證（偏硬控制）：
    // - 右側只保留「目前選日」，一換日就全部丟掉重算。
    // - 取消載入隊列、清空右側 charts、重建 ScrollController 以釋放 ScrollPosition/clients。
    if (kPrs1UiLogs) debugPrint('[PRS1][Phase5] clear working set: $reason');

    // cancel queue + clear right
    _queueToken++;
    _queueDay = null;
    _loadedCharts.clear();
    _showRight = false;

    // Recreate controller AFTER this frame to avoid disposing an attached controller.
    final old = _rightChartsCtrl;
    _rightChartsCtrl = ScrollController();
    _rightChartsListKey = UniqueKey();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      try {
        old.dispose();
      } catch (_) {}
      if (kPrs1UiLogs) debugPrint('[PRS1][Phase5] controllers disposed/recreated; right cleared.');
    });
  }

void _cancelRight({required bool resetShowRight}) {

    _queueToken++;
    _queueDay = null;
    _loadedCharts.clear();
    _rightChartsListKey = UniqueKey();
    if (resetShowRight) {
      _showRight = false;
    }
    // 確保回到頂部，避免下一次載入從中段開始。
    if (_rightChartsCtrl.hasClients) {
      try {
        _rightChartsCtrl.jumpTo(0);
      } catch (_) {}
    }

  }

  Future<void> _startChartQueueForDay(DateTime day) async {
    // 先 cancel 舊任務與清空右側，但保留 showRight=true（讓右側區域立刻存在）。
    _queueToken++;
    final myToken = _queueToken;
    _queueDay = day;
    _loadedCharts.clear();
    _rightChartsListKey = UniqueKey();
    _showRight = true;

    if (kPrs1UiLogs) debugPrint('[PRS1][Phase4] start ChartLoadQueue day=$day');

    // 逐張載入：每張完成就更新 UI。
    for (final k in _ChartKey.values) {
      if (!mounted) return;
      if (myToken != _queueToken) {
        if (kPrs1UiLogs) debugPrint('[PRS1][Phase4] queue cancelled (token changed)');
        return;
      }
      if (_queueDay != day) {
        if (kPrs1UiLogs) debugPrint('[PRS1][Phase4] queue cancelled (day changed)');
        return;
      }

      setState(() {
        _loadedCharts.add(k);
      });

      // 小間隔讓使用者看起來像「逐張出現」，同時避免一次性建構造成尖峰。
      await Future.delayed(const Duration(milliseconds: 70));
    }

    if (kPrs1UiLogs) debugPrint('[PRS1][Phase4] queue finished ($day)');
  }

  String _chartTitle(_ChartKey k) {
    switch (k) {
      case _ChartKey.events:
        return '事件標記';
      case _ChartKey.flowRate:
        return '氣流速率';
      case _ChartKey.crossAnalysis:
        return '交叉分析圖';
      case _ChartKey.pressure:
        return '壓力';
      case _ChartKey.leakRate:
        return '漏氣率';
      case _ChartKey.tidalVolume:
        return '呼吸容量';
      case _ChartKey.respRate:
        return '呼吸速率';
      case _ChartKey.minuteVent:
        return '分鐘通氣率';
      case _ChartKey.snore:
        return '打鼾';
      case _ChartKey.inspTime:
        return '吸氣時間';
      case _ChartKey.expTime:
        return '吐氣時間';
      case _ChartKey.ahi:
        return '呼吸中止指數 AHI';
      case _ChartKey.pressureTime:
        return '壓力時間';
    }
  }

  Widget _buildChartByKey(
    _ChartKey k, {
    required DateTime? sessionStart,
    required DateTime? sessionEnd,
    required List<Prs1Session> sessions,
    required Prs1DailyBucket bucket,
  }) {
    // 若缺少 session window，回傳提示（仍然算「逐張出現」）。
    if (sessionStart == null || sessionEnd == null) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withOpacity(0.35),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Text(
          '${_chartTitle(k)}：本日資料缺少 session 起訖時間（尚未建立 slices / session window）',
          style: TextStyle(
            color: scheme.onSurface.withOpacity(0.75),
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
    }

    switch (k) {
      case _ChartKey.events:
        return Prs1ChartEvents(
          sessionStart: sessionStart,
          sessionEnd: sessionEnd,
          events: Prs1EventDeriver.derive(decodedEvents: bucket.events),
        );
      case _ChartKey.flowRate:
        return Prs1ChartFlowRate(
          sessionStart: sessionStart,
          sessionEnd: sessionEnd,
          sessions: sessions,
        );
      case _ChartKey.crossAnalysis:
        return Prs1ChartCrossAnalysis(
          sessionStart: sessionStart,
          sessionEnd: sessionEnd,
          bucket: bucket,
        );
      case _ChartKey.pressure:
        return Prs1ChartPressure(
          sessionStart: sessionStart,
          sessionEnd: sessionEnd,
          sessions: sessions,
        );
      case _ChartKey.leakRate:
        return Prs1ChartLeakRate(
          sessionStart: sessionStart,
          sessionEnd: sessionEnd,
          bucket: bucket,
        );
      case _ChartKey.tidalVolume:
        return Prs1ChartTidalVolume(
          sessionStart: sessionStart,
          sessionEnd: sessionEnd,
          bucket: bucket,
        );
      case _ChartKey.respRate:
        return Prs1ChartRespRate(
          sessionStart: sessionStart,
          sessionEnd: sessionEnd,
          bucket: bucket,
        );
      case _ChartKey.minuteVent:
        return Prs1ChartMinuteVent(
          sessionStart: sessionStart,
          sessionEnd: sessionEnd,
          bucket: bucket,
        );
      case _ChartKey.snore:
        return Prs1ChartSnore(
          sessionStart: sessionStart,
          sessionEnd: sessionEnd,
          bucket: bucket,
        );
      case _ChartKey.inspTime:
        return Prs1ChartInspTime(
          sessionStart: sessionStart,
          sessionEnd: sessionEnd,
          bucket: bucket,
        );
      case _ChartKey.expTime:
        return Prs1ChartExpTime(
          sessionStart: sessionStart,
          sessionEnd: sessionEnd,
          bucket: bucket,
        );
      case _ChartKey.ahi:
        return Prs1ChartAhi(
          sessionStart: sessionStart,
          sessionEnd: sessionEnd,
          bucket: bucket,
        );
      case _ChartKey.pressureTime:
        return Prs1ChartPressureTime(
          sessionStart: sessionStart,
          sessionEnd: sessionEnd,
          bucket: bucket,
        );
    }
  }

  /// 從「所有 buckets（已排序）」取出指定週視窗（每週 7 天，往前翻週）。
  /// - weekOffset=0：最新 7 天
  /// - weekOffset=1：再往前 7 天
  static List<Prs1DailyBucket> _buildWeekWindow(List<Prs1DailyBucket> sorted, int weekOffset) {
    if (sorted.isEmpty) return const [];
    // weekOffset: 0 = latest week, -1 = previous week, etc.
    final endExclusive = sorted.length + (weekOffset * 7);
    final clampedEnd = math.min(sorted.length, math.max(0, endExclusive));
    final start = math.max(0, clampedEnd - 7);
    if (start >= clampedEnd) return const [];
    return sorted.sublist(start, clampedEnd);
  }

  @override
  Widget build(BuildContext context) {
    final store = AppStateScope.of(context);
    final buckets = List<Prs1DailyBucket>.from(store.prs1DailyBuckets);
    buckets.sort((a, b) => a.day.compareTo(b.day));

    final maxBackWeeks = math.min(4, (buckets.length - 1) ~/ 7);
    // clamp _weekOffset so it never exceeds available data window
    if (_weekOffset < -maxBackWeeks) {
      _weekOffset = -maxBackWeeks;
      _selectedIndex = 0;
      _didInitSelection = false;
    }
    final last7 = _buildWeekWindow(buckets, _weekOffset);
    if (last7.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('我的本周睡眠呼吸紀錄')),
        body: const Center(child: Text('尚無資料')),
      );
    }

    // 預設選最後一天（僅第一次進入頁面時）
    if (!_didInitSelection) {
      _selectedIndex = last7.length - 1;
      _didInitSelection = true;
    }
    _selectedIndex = _selectedIndex.clamp(0, last7.length - 1).toInt();
    final b = last7[_selectedIndex];
    final ymdLabel = _formatDateToChinese(b.day);

    // Session time window (align with OSCAR header: start/end/usage)
    final DateTime? sessionStart = b.slices.isEmpty
        ? null
        : b.slices.map((s) => s.session.start).reduce((a, c) => a.isBefore(c) ? a : c);

    final DateTime? sessionEnd = b.slices.isEmpty
        ? null
        : b.slices.map((s) => s.session.end).reduce((a, c) => a.isAfter(c) ? a : c);

    // Sessions list for waveform index (FlowRate chart stitches segments via index)
    final sessions = b.slices.map((s) => s.session).toList();

final startLabel = sessionStart == null ? '—' : _formatHm(sessionStart);
final endLabel = sessionEnd == null ? '—' : _formatHm(sessionEnd);
final usageLabel = _formatDurationHm(Duration(seconds: b.usageSeconds));

    // AHI：使用「整晚平均」(OA + CA + H) / 小時，與 OSCAR 的 Daily AHI 對齊。
    // 注意：rollingAhi5m/30m 的最大值可能會「爆表」，不適合作為給一般用戶看的核心數字。
    final double? nightlyAhi = b.ahi;

// AHI 統計列：用較穩定的 rollingAhi30m 來取 min/median/p95/max（避免 5m 視窗爆表）。
final ahiSeries = b.rollingAhi30m.map((e) => e.value).whereType<double>().toList();
final ahiStats = _statsOfValues(ahiSeries.isEmpty ? <double>[] : ahiSeries);

// Snore 統計列：以每分鐘打鼾計數（heatmap 1m）做 min/median/p95/max，對齊 OSCAR 的「打鼾」統計。
final snoreSeries = b.snoreHeatmap1mCounts.map((e) => e.toDouble()).toList();
final snoreStats = _statsOfValues(snoreSeries);

    // 這個欄位在模型中允許為 null；null 就讓 UI 顯示「—」。
    final double? leakOverPct = (b.leakPercentOverThreshold == null)
        ? null
        : (b.leakPercentOverThreshold! * 100.0);

    final rows = <_StatRow>[
      _StatRow('陽壓治療壓力值', unit: 'cmH₂O', min: b.pressureMin, median: b.pressureMedian, p95: b.pressureP95, max: b.pressureMax),
      _StatRow('吐氣壓力 (EPAP)', unit: 'cmH₂O', min: b.epapMin, median: b.epapMedian, p95: b.epapP95, max: b.epapMax),
      if (b.pressureOscarMin != null)
        _StatRow('陽壓治療壓力值 (OSCAR)', unit: 'cmH₂O', min: b.pressureOscarMin, median: b.pressureOscarMedian, p95: b.pressureOscarP95, max: b.pressureOscarMax),
      if (b.pressureBiasPctMin != null)
        _StatRow('壓力偏差比例 (本App vs OSCAR)', unit: '%', min: b.pressureBiasPctMin, median: b.pressureBiasPctMedian, p95: b.pressureBiasPctP95, max: b.pressureBiasPctMax),
      _StatRow('分鐘通氣量', unit: 'L/min', min: b.minuteVentMin, median: b.minuteVentMedian, p95: b.minuteVentP95, max: b.minuteVentMax),
      _StatRow('呼吸率', unit: '/min', min: b.respRateMin, median: b.respRateMedian, p95: b.respRateP95, max: b.respRateMax),
      _StatRow('呼吸容積', unit: 'mL', min: b.tidalVolumeMin, median: b.tidalVolumeMedian, p95: b.tidalVolumeP95, max: b.tidalVolumeMax),
      _StatRow('打鼾', unit: '', min: snoreStats.min, median: snoreStats.median, p95: snoreStats.p95, max: snoreStats.max),
      _StatRow('吸氣時間', unit: 's', min: b.inspTimeMin, median: b.inspTimeMedian, p95: b.inspTimeP95, max: b.inspTimeMax),
      _StatRow('吐氣時間', unit: 's', min: b.expTimeMin, median: b.expTimeMedian, p95: b.expTimeP95, max: b.expTimeMax),
      _StatRow('I:E 比', unit: '', min: b.ieRatioMin, median: b.ieRatioMedian, p95: b.ieRatioP95, max: b.ieRatioMax),
      _StatRow('面罩漏氣率', unit: 'L/min', min: b.leakMin, median: b.leakMedian, p95: b.leakP95, max: b.leakMax),
      _StatRow('漏氣超過閾值的比例', unit: '%', min: leakOverPct, median: leakOverPct, p95: leakOverPct, max: leakOverPct),
      _StatRow('呼吸中止指數 (AHI)', unit: '', min: ahiStats.min, median: nightlyAhi ?? ahiStats.median, p95: ahiStats.p95, max: ahiStats.max),
      _StatRow('氣流受限值', unit: '', min: b.flowLimitationMin, median: b.flowLimitationMedian, p95: b.flowLimitationP95, max: b.flowLimitationMax),
    ];

    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.surface,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        centerTitle: true,
        title: const Text('我的本周睡眠呼吸紀錄'),
        actions: const [],
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            // iPad / 橫向：左右並排（右側寬度 = 左側的 300% ≈ 放大 200%）
            final isWide = constraints.maxWidth >= 820;

            // 統計區（左欄）不要再縮小：避免 iPad/桌面下可讀性崩壞。
            const double minLeftWidth = 430;

            // Phase 4：右側圖表序列載入（按 AHI 後才開始），並逐張出現。
            // 重要：在 _showRight=false 時，右側 widget 完全不建立。
            Widget _rightPanel() {
              final cs = Theme.of(context).colorScheme;
              final bg = cs.surfaceContainerHighest.withOpacity(0.20);

              final total = _ChartKey.values.length;
              final done = _loadedCharts.length;

              Widget tileHeader(String title, {String? subtitle}) {
                return Container(
                  width: double.infinity,
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
                  decoration: BoxDecoration(
                    color: bg,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: cs.outlineVariant.withOpacity(0.75)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w900,
                          color: cs.onSurface.withOpacity(0.92),
                        ),
                      ),
                      if (subtitle != null) ...[
                        const SizedBox(height: 6),
                        Text(
                          subtitle,
                          style: TextStyle(
                            fontSize: 13,
                            height: 1.25,
                            color: cs.onSurface.withOpacity(0.72),
                          ),
                        ),
                      ],
                    ],
                  ),
                );
              }

              return Padding(
                padding: const EdgeInsets.fromLTRB(0, 12, 12, 12),
                child: Scrollbar(
                  controller: _rightChartsCtrl,
                  thumbVisibility: true,
                  child: ListView(
                    key: _rightChartsListKey,
                    controller: _rightChartsCtrl,
                    children: [
                      for (final k in _loadedCharts) ...[
                        _LowCostChartTile(
                          title: _chartTitle(k),
                          // Phase 6：延遲 build，並用 ClipRect/Align 做一次性揭露動畫。
                          buildChart: () => _buildChartByKey(
                            k,
                            sessionStart: sessionStart,
                            sessionEnd: sessionEnd,
                            sessions: sessions,
                            bucket: b,
                          ),
                        ),
                        const SizedBox(height: 12),
                      ],
                      if (done < total)
                        tileHeader('下一張：${_chartTitle(_ChartKey.values[done])}'),
                    ],
                  ),
                ),
              );
            }

            // 左側（週柱狀圖 + AHI Banner + 統計表格）
            // Phase 2 重點：即使是寬螢幕（iPad/桌面），也只 render 這個左側，右側完全不建立。
            final leftPanel = ConstrainedBox(
              constraints: const BoxConstraints(minWidth: minLeftWidth),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                child: Column(
                  children: [
                    _WeekCard(
                      buckets: last7,
                      selectedIndex: _selectedIndex,
                      onSelect: (i) {
                        setState(() {
                          _selectedIndex = i;
                          _hardClearWorkingSet('date/window changed');
                        });
                      },
                      weekOffset: _weekOffset,
                      onPrevWeek: _weekOffset > -maxBackWeeks ? () => _prevWeek(maxBackWeeks) : null,
                      onNextWeek: _weekOffset < 0 ? _nextWeek : null,
                    ),
                    const SizedBox(height: 12),
                    _AhiBanner(
                      ahi: nightlyAhi,
                      onTap: () {
                        if (!isWide) return;
                        // Phase 4：開始序列載入右側圖表（按指定順序逐張出現）。
                        if (_showRight && _queueDay == b.day) return;
                        setState(() {
                          // 先把右側開起來，並清空舊狀態。
                          _cancelRight(resetShowRight: false);
                          _showRight = true;
                        });
                        _startChartQueueForDay(b.day);
                      },
                    ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: _StatsPanel(
                        dateLabel: ymdLabel,
                        startLabel: startLabel,
                        endLabel: endLabel,
                        usageLabel: usageLabel,
                        rows: rows,
                      ),
                    ),
                  ],
                ),
              ),
            );

            if (isWide) {
              // Phase 4：起始只 render 左側；按下 AHI 後，左側以「迅速」動畫縮到固定寬度，右側逐張載入。
              if (!_showRight) return leftPanel;

              final totalW = constraints.maxWidth;
              const minRightW = 360.0;
              final leftFromW = math.max(minLeftWidth, totalW - minRightW);

              return Row(
                children: [
                  TweenAnimationBuilder<double>(
                    tween: Tween<double>(begin: leftFromW, end: minLeftWidth),
                    duration: const Duration(milliseconds: 240),
                    curve: Curves.fastOutSlowIn,
                    builder: (context, w, child) => SizedBox(width: w, child: child),
                    child: leftPanel,
                  ),
                  Expanded(child: _rightPanel()),
                ],
              );
            }

            // 窄螢幕：僅顯示左側統計
            return leftPanel;

          },
        ),
      ),
    );
  }

  static List<Prs1DailyBucket> _buildLast7Days(List<Prs1DailyBucket> sorted) {
    if (sorted.isEmpty) return const [];
    final start = math.max(0, sorted.length - 7);
    return sorted.sublist(start);
  }
}

/// Phase 6：低成本視覺特效（不複製 samples、不建立第二份 Path/點列）
///
/// 作法：
/// 1) 先顯示 skeleton / 標題（幾乎不吃記憶體）
/// 2) 延遲一小段時間後才真正 build chart widget
/// 3) 用 ClipRect + Align(heightFactor) 做一次性的「揭露」動畫（不產生裁切後的新 samples list）
class _LowCostChartTile extends StatefulWidget {
  const _LowCostChartTile({
    required this.title,
    required this.buildChart,
    this.preDelay = const Duration(milliseconds: 40),
    this.revealDuration = const Duration(milliseconds: 220),
  });

  final String title;
  final Widget Function() buildChart;
  final Duration preDelay;
  final Duration revealDuration;

  @override
  State<_LowCostChartTile> createState() => _LowCostChartTileState();
}

class _LowCostChartTileState extends State<_LowCostChartTile> {
  int _stage = 0; // 0=skeleton, 1=ready (still skeleton), 2=build+reveal
  Widget? _built;

  @override
  void initState() {
    super.initState();
    // 先讓 ListView 佈局穩定，再延遲建構圖表（避免一次性尖峰）。
    Future.delayed(const Duration(milliseconds: 10), () {
      if (!mounted) return;
      setState(() => _stage = 1);
    });
    Future.delayed(widget.preDelay, () {
      if (!mounted) return;
      setState(() {
        _stage = 2;
        _built ??= widget.buildChart();
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final bg = cs.surfaceContainerHighest.withOpacity(0.20);


    Widget skeleton() {
      return Container(
        width: double.infinity,
        height: 160,
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest.withOpacity(0.35),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: cs.outlineVariant.withOpacity(0.75)),
        ),
        alignment: Alignment.center,
        child: Text(
          _stage == 0 ? '準備中…' : '繪製中…',
          style: TextStyle(
            color: cs.onSurface.withOpacity(0.70),
            fontSize: 13,
            fontWeight: FontWeight.w700,
          ),
        ),
      );
    }

    Widget body;
    if (_stage < 2 || _built == null) {
      body = skeleton();
    } else {
      final child = _built!;
      body = TweenAnimationBuilder<double>(
        tween: Tween<double>(begin: 0.0, end: 1.0),
        duration: widget.revealDuration,
        curve: Curves.easeOutCubic,
        builder: (context, t, _) {
          return ClipRect(
            child: Align(
              alignment: Alignment.topCenter,
              heightFactor: t,
              child: child,
            ),
          );
        },
      );
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: cs.outlineVariant.withOpacity(0.75)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // NOTE: Per UI spec, remove the auto-generated small section header on each right-side tile.
          // Each chart widget already renders its own title internally.
          body,
        ],
      ),
    );
  }
}

class _WeekCard extends StatelessWidget {
  final List<Prs1DailyBucket> buckets;
  final int selectedIndex;
  final ValueChanged<int> onSelect;
  final int weekOffset;
  final VoidCallback? onPrevWeek;
  final VoidCallback? onNextWeek;

  const _WeekCard({
    required this.buckets,
    required this.selectedIndex,
    required this.onSelect,
    required this.weekOffset,
    this.onPrevWeek,
    this.onNextWeek,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final appState = AppStateScope.of(context);
    final accent = _deepen(appState.brandColor.color, brightness: theme.colorScheme.brightness);
    final maxUsage = buckets.map((e) => e.usageSeconds).fold<int>(0, (p, c) => math.max(p, c));
    final cardBorder = BorderRadius.circular(16);

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 16, 14, 12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: cardBorder,
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant.withOpacity(0.6)),
      ),
      child: Column(
        children: [
          // 上方 AppBar 已有標題，卡片內不再重複顯示。
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: List.generate(buckets.length, (i) {
              final b = buckets[i];
              final ratio = maxUsage <= 0 ? 0.0 : (b.usageSeconds / maxUsage);
              final h = 18 + (ratio * 74);
              final isSel = i == selectedIndex;
              final date = _formatDateToMmDd(b.day);

              return Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => onSelect(i),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 180),
                        height: h,
                        width: 15,
                        decoration: BoxDecoration(
                          color: isSel
                                ? _deepen(AppStateScope.of(context).brandColor.color, brightness: Theme.of(context).colorScheme.brightness)
                                : _soften(AppStateScope.of(context).brandColor.color, Theme.of(context).colorScheme.surface, t: 0.80),
                          // 細瘦長條柱狀圖（避免膠囊形狀）。
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        date,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: isSel ? FontWeight.w700 : FontWeight.w400,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }),
          ),
          const SizedBox(height: 10),
          Divider(height: 1, color: Theme.of(context).colorScheme.outlineVariant.withOpacity(0.6)),
          const SizedBox(height: 10),
          IconTheme(
            data: IconThemeData(color: accent),
            child: Row(
              children: [
              IconButton(
                onPressed: onPrevWeek,
                icon: const Icon(Icons.arrow_left, size: 34),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 52, minHeight: 52),
              ),
              Expanded(
                child: Center(
                  child: Text(
                    '睡眠區間：${_formatDateToChinese(buckets.first.day)} ~ ${_formatDateToChinese(buckets.last.day)}',
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
              ),
              if (weekOffset < 0)
                IconButton(
                  onPressed: onNextWeek,
                  icon: const Icon(Icons.arrow_right, size: 34),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                )
              else
              const SizedBox(width: 52),
            ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 第三層統計資料卡：
/// - 僅此區塊可垂直滾動（上方週柱狀圖固定）
/// - 欄位標題列凍結（類似 Excel 凍結視窗）

/// 第三層統計資料卡：
/// - 僅此區塊可垂直滾動（上方週柱狀圖固定）
/// - 欄位標題列凍結（類似 Excel 凍結視窗）
class _StatsPanel extends StatelessWidget {
  final String dateLabel;
  final String startLabel;
  final String endLabel;
  final String usageLabel;
  final List<_StatRow> rows;

  const _StatsPanel({
    required this.dateLabel,
    required this.startLabel,
    required this.endLabel,
    required this.usageLabel,
    required this.rows,
  });

  @override
  Widget build(BuildContext context) {
    final cardBorder = BorderRadius.circular(16);

    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: cardBorder,
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant.withOpacity(0.6)),
      ),
      child: Column(
        children: [
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: const [
              Text('統計資料', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            ],
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '本日$dateLabel',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 13),
                ),
                const SizedBox(height: 4),
                Text(
                  '開始：$startLabel  結束：$endLabel  使用時間：$usageLabel',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 13),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Divider(height: 1, color: Theme.of(context).colorScheme.outlineVariant.withOpacity(0.6)),
          _FrozenHeaderRow(),
          Divider(height: 1, color: Theme.of(context).colorScheme.outlineVariant.withOpacity(0.6)),
          // 僅表格內容可滾動
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
              itemCount: rows.length,
              separatorBuilder: (_, __) => Divider(height: 1, color: Theme.of(context).colorScheme.outlineVariant.withOpacity(0.35)),
              itemBuilder: (context, i) {
                final r = rows[i];
                final isPercent = r.unit == '%' || r.label.contains('%') || r.label.contains('比例');
                final isCountInt = r.label == '打鼾';
                return _DataRowResponsive(
                  label: r.label,
                  unit: r.unit,
                  min: _fmt(r.min, isPercent: isPercent, decimals: isCountInt ? 0 : 2),
                  median: _fmt(r.median, isPercent: isPercent, decimals: isCountInt ? 0 : 2),
                  p95: _fmt(r.p95, isPercent: isPercent, decimals: isCountInt ? 0 : 2),
                  max: _fmt(r.max, isPercent: isPercent, decimals: isCountInt ? 0 : 2),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  static String _fmt(double? v, {required bool isPercent, int decimals = 2}) {
    if (v == null || v.isNaN || v.isInfinite) return '—';
    if (isPercent) return '${v.toStringAsFixed(0)}%';
    return v.toStringAsFixed(decimals.clamp(0, 6));
  }
}

class _FrozenHeaderRow extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    const headerStyle = TextStyle(fontSize: 14, fontWeight: FontWeight.w700);
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
      child: Row(
        children: const [
          Expanded(flex: 32, child: Text('通道', style: headerStyle)),
          Expanded(flex: 17, child: Text('最小', style: headerStyle, textAlign: TextAlign.right)),
          Expanded(flex: 17, child: Text('中間值', style: headerStyle, textAlign: TextAlign.right)),
          Expanded(flex: 17, child: Text('95%', style: headerStyle, textAlign: TextAlign.right)),
          Expanded(flex: 17, child: Text('最大', style: headerStyle, textAlign: TextAlign.right)),
        ],
      ),
    );
  }
}

class _DataRowResponsive extends StatelessWidget {
  final String label;
  final String unit;
  final String min;
  final String median;
  final String p95;
  final String max;

  const _DataRowResponsive({
    required this.label,
    required this.unit,
    required this.min,
    required this.median,
    required this.p95,
    required this.max,
  });

  @override
  Widget build(BuildContext context) {
    final left = unit.isEmpty ? label : '$label($unit)';
    const cellStyle = TextStyle(fontSize: 14, height: 1.0);
    return SizedBox(
      height: 44,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(flex: 32, child: Text(left, style: cellStyle)),
          Expanded(flex: 17, child: Text(min, style: cellStyle, textAlign: TextAlign.right)),
          Expanded(flex: 17, child: Text(median, style: cellStyle, textAlign: TextAlign.right)),
          Expanded(flex: 17, child: Text(p95, style: cellStyle, textAlign: TextAlign.right)),
          Expanded(flex: 17, child: Text(max, style: cellStyle, textAlign: TextAlign.right)),
        ],
      ),
    );
  }
}

class _Stats {
  final double? min;
  final double? median;
  final double? p95;
  final double? max;

  const _Stats({required this.min, required this.median, required this.p95, required this.max});
}

_Stats _statsOfValues(List<double> values) {
  final v = values.where((e) => e.isFinite).toList()..sort();
  if (v.isEmpty) return const _Stats(min: null, median: null, p95: null, max: null);
  return _Stats(
    min: v.first,
    median: _percentileSorted(v, 0.50),
    p95: _percentileSorted(v, 0.95),
    max: v.last,
  );
}

double _percentileSorted(List<double> sorted, double p) {
  if (sorted.isEmpty) return double.nan;
  final idx = (p.clamp(0, 1) * (sorted.length - 1));
  final lo = idx.floor();
  final hi = idx.ceil();
  if (lo == hi) return sorted[lo];
  final w = idx - lo;
  return sorted[lo] * (1 - w) + sorted[hi] * w;
}

String _formatDateToMmDd(DateTime d) {
  final mm = d.month.toString().padLeft(2, '0');
  final dd = d.day.toString().padLeft(2, '0');
  return '$mm/$dd';
}

String _formatDateToChinese(DateTime d) {
  final y = d.year.toString().padLeft(4, '0');
  final m = d.month.toString().padLeft(2, '0');
  final day = d.day.toString().padLeft(2, '0');
  return '${y}年${m}月${day}日';
}


String _formatHm(DateTime dt) {
  final h = dt.hour.toString().padLeft(2, '0');
  final m = dt.minute.toString().padLeft(2, '0');
  return '${h}時${m}分';
}

String _formatDurationHm(Duration d) {
  final totalMinutes = d.inMinutes;
  final hh = (totalMinutes ~/ 60).toString().padLeft(2, '0');
  final mm = (totalMinutes % 60).toString().padLeft(2, '0');
  return '${hh}時${mm}分';
}