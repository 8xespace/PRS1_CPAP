// lib/intro/painters/sparkle.dart
import 'dart:math' as math;
import 'package:flutter/material.dart';

class SparklePainter extends CustomPainter {
  final double progress; // 0..1
  SparklePainter({required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final baseR = math.min(size.width, size.height) * 0.42;
    final t = progress;

    const n = 46;
    for (int i = 0; i < n; i++) {
      final fi = i / n;
      final a = (t * 2 * math.pi) + fi * 2 * math.pi * 2;
      final wobble = 0.10 * math.sin((t * 6 * math.pi) + fi * 10 * math.pi);
      final r = baseR * (0.55 + 0.45 * fi + wobble);

      final p = Offset(
        center.dx + math.cos(a) * r,
        center.dy + math.sin(a) * r,
      );

      final s = 1.2 + 2.8 * (0.5 + 0.5 * math.sin(a * 3 + t * 4 * math.pi));
      final alpha = (0.10 + 0.55 * (0.5 + 0.5 * math.sin(a + t * 2 * math.pi)))
          .clamp(0.0, 0.65);

      final cMix = (0.5 + 0.5 * math.sin(fi * 6 * math.pi + t * 2 * math.pi));
      final color = Color.lerp(
        const Color(0xFFFF4FD8),
        const Color(0xFF4DFFFF),
        cMix,
      )!
          .withOpacity(alpha);

      canvas.drawCircle(p, s, Paint()..color = color);
    }
  }

  @override
  bool shouldRepaint(covariant SparklePainter oldDelegate) {
    return oldDelegate.progress != progress;
  }
}
