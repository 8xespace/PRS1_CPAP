import 'dart:math';
import 'package:flutter/material.dart';

class SparklePainter extends CustomPainter {
  SparklePainter({required this.t});
  final double t;

  final _rng = Random(1);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..style = PaintingStyle.fill;
    for (int i = 0; i < 80; i++) {
      final x = _rng.nextDouble() * size.width;
      final y = _rng.nextDouble() * size.height;
      final r = 1.2 + _rng.nextDouble() * 2.6;
      final a = (0.15 + 0.35 * sin(t * 2 * pi + i)) .clamp(0.0, 0.6);
      paint.color = Colors.white.withOpacity(a);
      canvas.drawCircle(Offset(x, y), r, paint);
    }
  }

  @override
  bool shouldRepaint(covariant SparklePainter oldDelegate) => oldDelegate.t != t;
}
