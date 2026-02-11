// lib/home/bottom_controls_bar.dart
import 'package:flutter/material.dart';

import '../app_state.dart';

/// CPAP 專用底部控制列（此 App 不需要：搜尋列 / 我的最愛 / 瀏覽清單）
///
/// 需求：
/// - 左側：深淺模式開關
/// - 右側：四色招牌（BrandColor）
class BottomControlsBar extends StatelessWidget {
  const BottomControlsBar({
    super.key,
    required this.appState,
  });

  final AppState appState;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = appState.themeMode == ThemeMode.dark;

    return SafeArea(
      top: false,
      child: Container(
        decoration: BoxDecoration(
          color: cs.surface,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.06),
              blurRadius: 8,
              offset: const Offset(0, -2),
            ),
          ],
        ),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
        child: Row(
          children: [
            // 左：深淺模式
            Row(
              children: [
                Icon(
                  isDark ? Icons.dark_mode_rounded : Icons.light_mode_rounded,
                  size: 18,
                  color: cs.onSurface.withOpacity(0.80),
                ),
                const SizedBox(width: 8),
                Switch(
                  value: isDark,
                  onChanged: (v) => appState.setThemeMode(
                    v ? ThemeMode.dark : ThemeMode.light,
                  ),
                ),
              ],
            ),

            const Spacer(),

            // 右：四色招牌（BrandColor）
            _ColorDots(
              selected: appState.brandColor,
              onPick: (c) => appState.setBrandColor(c),
            ),
          ],
        ),
      ),
    );
  }
}

class _ColorDots extends StatelessWidget {
  const _ColorDots({
    required this.selected,
    required this.onPick,
  });

  final BrandColor selected;
  final void Function(BrandColor color) onPick;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Row(
      children: [
        _dot(
          cs,
          BrandColor.pink,
          color: const Color(0xFFF8A3C4),
          isActive: selected == BrandColor.pink,
        ),
        const SizedBox(width: 4),
        _dot(
          cs,
          BrandColor.orange,
          color: const Color(0xFFFFC894),
          isActive: selected == BrandColor.orange,
        ),
        const SizedBox(width: 4),
        _dot(
          cs,
          BrandColor.green,
          color: const Color(0xFFA1E5B2),
          isActive: selected == BrandColor.green,
        ),
        const SizedBox(width: 4),
        _dot(
          cs,
          BrandColor.blue,
          color: const Color(0xFF93B7FF),
          isActive: selected == BrandColor.blue,
        ),
      ],
    );
  }

  Widget _dot(
    ColorScheme cs,
    BrandColor brandColor, {
    required Color color,
    required bool isActive,
  }) {
    return GestureDetector(
      onTap: () => onPick(brandColor),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: 26,
        height: 26,
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: isActive ? cs.primary.withOpacity(0.12) : Colors.transparent,
        ),
        alignment: Alignment.center,
        child: _innerDot(cs, color, isActive),
      ),
    );
  }

  Widget _innerDot(ColorScheme cs, Color color, bool isActive) {
    return Container(
      width: 18,
      height: 18,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color,
        border: Border.all(
          color: isActive ? cs.onSurface : cs.outline.withOpacity(0.45),
          width: isActive ? 2 : 1,
        ),
      ),
    );
  }
}

