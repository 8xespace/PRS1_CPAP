import 'package:flutter/material.dart';

/// 吐氣時間
///
/// iPad / 橫向頁面圖表模組（對齊 OSCAR 的圖表項目）。
/// 目前先建立空模組，後續再把實際繪圖與資料流嫁接進來。
class Prs1ChartExpTime extends StatelessWidget {
  const Prs1ChartExpTime({super.key});

  static const String chartTitle = '吐氣時間';

  @override
  Widget build(BuildContext context) {
    // Placeholder:
    // - 上方橫式標題（未來統一放在圖表上方）
    // - 下方保留繪圖區域（後續替換成 CustomPainter / chart widget）
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Text(
            chartTitle,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
          ),
        ),
        Container(
          height: 120,
          margin: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: Theme.of(context).colorScheme.outlineVariant.withOpacity(0.6),
            ),
          ),
          alignment: Alignment.center,
          child: Text(
            'TODO: 吐氣時間 圖表',
            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}
