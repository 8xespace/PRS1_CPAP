// lib/intro/widgets/logo_naked.dart
import 'package:flutter/material.dart';

class LogoNaked extends StatelessWidget {
  final String assetPath;
  final double size;

  const LogoNaked({
    super.key,
    required this.assetPath,
    required this.size,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        boxShadow: [
          BoxShadow(
            blurRadius: 32,
            spreadRadius: 4,
            color: Colors.black.withOpacity(0.20),
          ),
          BoxShadow(
            blurRadius: 64,
            spreadRadius: 10,
            color: Colors.white.withOpacity(isDark ? 0.06 : 0.10),
          ),
        ],
      ),
      child: Image.asset(
        assetPath,
        fit: BoxFit.contain,
        errorBuilder: (_, __, ___) {
          // 母本容錯：若專案尚未放置 logo.png，避免直接 crash
          return const FlutterLogo(size: 96);
        },
      ),
    );
  }
}
