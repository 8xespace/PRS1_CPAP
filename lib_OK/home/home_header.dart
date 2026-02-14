// lib/home/home_header.dart
import 'package:flutter/material.dart';

/// CPAP 專用頂部標題列（移除「官方粉絲專頁」入口）
///
/// - 支援一般模式 / 搜尋模式（保留相容性）
/// - 左側可選返回鍵（第 2/3 層使用）
class HomeHeader extends StatelessWidget {
  const HomeHeader({
    super.key,
    this.isSearchMode = false,
    String? title,
    String? titleText,
    this.showBack = false,
    this.onBack,
    this.onBackPressed,
    this.onCancel,
  }) : titleText = titleText ?? title ?? '';

  final bool isSearchMode;
  final String titleText;

  final bool showBack;
  final VoidCallback? onBack;
  final VoidCallback? onBackPressed;

  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    final effectiveBack = onBackPressed ?? onBack;

    return Container(
      decoration: BoxDecoration(
        color: cs.surface,
        border: Border(
          bottom: BorderSide(
            color: cs.outlineVariant.withOpacity(0.30),
            width: 0.8,
          ),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.06),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Row(
        children: [
          if (isSearchMode || showBack) ...[
            IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: effectiveBack,
            ),
          ] else ...[
            const SizedBox(width: 48),
          ],
          Expanded(
            child: Text(
              isSearchMode ? '搜尋' : titleText,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w800,
                letterSpacing: 2,
              ),
            ),
          ),
          if (isSearchMode) ...[
            TextButton(
              onPressed: onCancel ?? effectiveBack,
              child: const Text(
                '取消',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ] else ...[
            const SizedBox(width: 48),
          ],
        ],
      ),
    );
  }
}
