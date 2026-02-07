import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../features/prs1/aggregate/prs1_daily_models.dart';
import '../features/prs1/stats/prs1_rolling_metrics.dart';

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
  const _AhiBanner({required this.ahi});

  final double? ahi;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final v = ahi;
    final text = v == null ? '—' : v.toStringAsFixed(2);

    // 用品牌色的深色調，維持你偏好的沉穩酒紅感。
    final bg = const Color(0xFF7A3E54);
    final fg = theme.colorScheme.onPrimary;

    return Container(
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
  }
}

class Prs1DashboardPage extends StatefulWidget {
  const Prs1DashboardPage({super.key});

  @override
  State<Prs1DashboardPage> createState() => _Prs1DashboardPageState();
}

class _Prs1DashboardPageState extends State<Prs1DashboardPage> {
  int _selectedIndex = 0; // 0 = 最早；會在 build 時矯正到最後一天

  @override
  Widget build(BuildContext context) {
    final store = AppStateScope.of(context);
    final buckets = List<Prs1DailyBucket>.from(store.prs1DailyBuckets);
    buckets.sort((a, b) => a.day.compareTo(b.day));

    final last7 = _buildLast7Days(buckets);
    if (last7.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('我的本周睡眠呼吸紀錄')),
        body: const Center(child: Text('尚無資料')),
      );
    }

    // 預設選最後一天
    _selectedIndex = _selectedIndex.clamp(0, last7.length - 1);
    if (_selectedIndex == 0) {
      // 只有第一次進來或狀態重置時，指向最新一天
      _selectedIndex = last7.length - 1;
    }

    final b = last7[_selectedIndex];
    final ymdLabel = _formatDateToChinese(b.day);

    // AHI：使用「整晚平均」(OA + CA + H) / 小時，與 OSCAR 的 Daily AHI 對齊。
    // 注意：rollingAhi5m/30m 的最大值可能會「爆表」，不適合作為給一般用戶看的核心數字。
    final double? nightlyAhi = b.ahi;

    // 這個欄位在模型中允許為 null；null 就讓 UI 顯示「—」。
    final double? leakOverPct = (b.leakPercentOverThreshold == null)
        ? null
        : (b.leakPercentOverThreshold! * 100.0);

    final rows = <_StatRow>[
      _StatRow('陽壓治療壓力值', unit: 'cmH₂O', min: b.pressureMin, median: b.pressureMedian, p95: b.pressureP95, max: b.pressureMax),
      if (b.pressureOscarMin != null)
        _StatRow('陽壓治療壓力值 (OSCAR)', unit: 'cmH₂O', min: b.pressureOscarMin, median: b.pressureOscarMedian, p95: b.pressureOscarP95, max: b.pressureOscarMax),
      if (b.pressureBiasPctMin != null)
        _StatRow('壓力偏差比例 (本App vs OSCAR)', unit: '%', min: b.pressureBiasPctMin, median: b.pressureBiasPctMedian, p95: b.pressureBiasPctP95, max: b.pressureBiasPctMax),
      _StatRow('分鐘通氣量', unit: 'L/min', min: b.minuteVentMin, median: b.minuteVentMedian, p95: b.minuteVentP95, max: b.minuteVentMax),
      _StatRow('呼吸率', unit: '/min', min: b.respRateMin, median: b.respRateMedian, p95: b.respRateP95, max: b.respRateMax),
      _StatRow('呼吸容積', unit: 'mL', min: b.tidalVolumeMin, median: b.tidalVolumeMedian, p95: b.tidalVolumeP95, max: b.tidalVolumeMax),
      _StatRow('吸氣時間', unit: 's', min: b.inspTimeMin, median: b.inspTimeMedian, p95: b.inspTimeP95, max: b.inspTimeMax),
      _StatRow('吐氣時間', unit: 's', min: b.expTimeMin, median: b.expTimeMedian, p95: b.expTimeP95, max: b.expTimeMax),
      _StatRow('I:E 比', unit: '', min: b.ieRatioMin, median: b.ieRatioMedian, p95: b.ieRatioP95, max: b.ieRatioMax),
      _StatRow('面罩漏氣率', unit: 'L/min', min: b.leakMin, median: b.leakMedian, p95: b.leakP95, max: b.leakMax),
      _StatRow('漏氣超過閾值的比例', unit: '%', min: leakOverPct, median: leakOverPct, p95: leakOverPct, max: leakOverPct),
      _StatRow('呼吸中止指數 (AHI)', unit: '', min: nightlyAhi, median: nightlyAhi, p95: nightlyAhi, max: nightlyAhi),
      _StatRow('氣流受限值', unit: '', min: b.flowLimitationMin, median: b.flowLimitationMedian, p95: b.flowLimitationP95, max: b.flowLimitationMax),
    ];

    return Scaffold(
      backgroundColor: const Color(0xFFFFF6F7),
      appBar: AppBar(
        backgroundColor: const Color(0xFFFFF6F7),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        centerTitle: true,
        title: const Text('我的本周睡眠呼吸紀錄'),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 上方柱狀圖固定，不跟著下方統計表一起滾動。
              _WeekCard(
                buckets: last7,
                selectedIndex: _selectedIndex,
                onSelect: (i) => setState(() => _selectedIndex = i),
              ),
              const SizedBox(height: 14),
              // 一般用戶最直覺關心的核心指標：整晚 AHI（與 OSCAR 對齊）。
              _AhiBanner(ahi: nightlyAhi),
              const SizedBox(height: 14),
              // 下方統計資料框獨立滾動（並凍結欄位標題列）。
              Expanded(
                child: _StatsPanel(
                  dateLabel: ymdLabel,
                  rows: rows,
                ),
              ),
            ],
          ),
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

class _WeekCard extends StatelessWidget {
  final List<Prs1DailyBucket> buckets;
  final int selectedIndex;
  final ValueChanged<int> onSelect;

  const _WeekCard({
    required this.buckets,
    required this.selectedIndex,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final maxUsage = buckets.map((e) => e.usageSeconds).fold<int>(0, (p, c) => math.max(p, c));
    final cardBorder = BorderRadius.circular(16);

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 16, 14, 12),
      decoration: BoxDecoration(
        color: const Color(0xFFFFFBFB),
        borderRadius: cardBorder,
        border: Border.all(color: const Color(0xFFDCC9CF)),
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
                        width: 10,
                        decoration: BoxDecoration(
                          color: isSel ? const Color(0xFF7B3D59) : const Color(0xFFE8D7DE),
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
          const Divider(height: 1, color: Color(0xFFDCC9CF)),
          const SizedBox(height: 10),
          Text(
            '睡眠區間：${_formatDateToChinese(buckets.first.day)} ~ ${_formatDateToChinese(buckets.last.day)}',
            style: const TextStyle(fontSize: 13),
          ),
        ],
      ),
    );
  }
}

/// 第三層統計資料卡：
/// - 僅此區塊可垂直滾動（上方週柱狀圖固定）
/// - 欄位標題列凍結（類似 Excel 凍結視窗）
class _StatsPanel extends StatelessWidget {
  final String dateLabel;
  final List<_StatRow> rows;

  const _StatsPanel({
    required this.dateLabel,
    required this.rows,
  });

  @override
  Widget build(BuildContext context) {
    final cardBorder = BorderRadius.circular(16);

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFFFFFBFB),
        borderRadius: cardBorder,
        border: Border.all(color: const Color(0xFFDCC9CF)),
      ),
      child: Column(
        children: [
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text('統計資料', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              const SizedBox(width: 10),
              Text('本日：$dateLabel', style: const TextStyle(fontSize: 13)),
            ],
          ),
          const SizedBox(height: 10),
          const Divider(height: 1, color: Color(0xFFDCC9CF)),
          _FrozenHeaderRow(),
          const Divider(height: 1, color: Color(0xFFDCC9CF)),
          // 僅表格內容可滾動
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
              itemCount: rows.length,
              separatorBuilder: (_, __) => const Divider(height: 1, color: Color(0xFFE6D6DB)),
              itemBuilder: (context, i) {
                final r = rows[i];
                final isPercent = r.label.contains('比例');
                return _DataRowResponsive(
                  label: r.label,
                  unit: r.unit,
                  min: _fmt(r.min, isPercent: isPercent),
                  median: _fmt(r.median, isPercent: isPercent),
                  p95: _fmt(r.p95, isPercent: isPercent),
                  max: _fmt(r.max, isPercent: isPercent),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  static String _fmt(double? v, {required bool isPercent}) {
    if (v == null || v.isNaN || v.isInfinite) return '—';
    if (isPercent) return '${v.toStringAsFixed(3)}%';
    return v.toStringAsFixed(2);
  }
}

class _FrozenHeaderRow extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    const headerStyle = TextStyle(fontSize: 13, fontWeight: FontWeight.w700);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Row(
        children: const [
          Expanded(flex: 42, child: Text('通道', style: headerStyle)),
          Expanded(flex: 14, child: Text('最小', style: headerStyle, textAlign: TextAlign.right)),
          Expanded(flex: 14, child: Text('中間值', style: headerStyle, textAlign: TextAlign.right)),
          Expanded(flex: 14, child: Text('95%', style: headerStyle, textAlign: TextAlign.right)),
          Expanded(flex: 16, child: Text('最大', style: headerStyle, textAlign: TextAlign.right)),
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
    final left = unit.isEmpty ? label : '$label\n($unit)';
    const cellStyle = TextStyle(fontSize: 13);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(flex: 42, child: Text(left, style: cellStyle)),
          Expanded(flex: 14, child: Text(min, style: cellStyle, textAlign: TextAlign.right)),
          Expanded(flex: 14, child: Text(median, style: cellStyle, textAlign: TextAlign.right)),
          Expanded(flex: 14, child: Text(p95, style: cellStyle, textAlign: TextAlign.right)),
          Expanded(flex: 16, child: Text(max, style: cellStyle, textAlign: TextAlign.right)),
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
