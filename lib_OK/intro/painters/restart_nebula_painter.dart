import 'dart:math';
import 'package:flutter/material.dart';

class RestartNebulaPainter extends CustomPainter {
  RestartNebulaPainter({required this.t});
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final g = RadialGradient(
      center: Alignment(0.1, -0.2),
      radius: 1.15,
      colors: [
        const Color(0xFFBFE9FF).withOpacity(0.55),
        const Color(0xFFFFC6E6).withOpacity(0.45),
        const Color(0xFFD2FFD9).withOpacity(0.40),
        const Color(0xFFFFE0B3).withOpacity(0.30),
        Colors.white.withOpacity(0.92),
      ],
      stops: const [0.0, 0.35, 0.60, 0.80, 1.0],
    );
    final paint = Paint()..shader = g.createShader(rect);
    canvas.drawRect(rect, paint);

    // subtle rings
    final ringPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0
      ..color = Colors.white.withOpacity(0.10);
    final c = Offset(size.width * 0.5, size.height * 0.55);
    for (int i = 0; i < 6; i++) {
      final rr = 80.0 + i * 70.0 + 8.0 * sin(t * 2 * pi + i);
      canvas.drawCircle(c, rr, ringPaint);
    }
  }

  @override
  bool shouldRepaint(covariant RestartNebulaPainter oldDelegate) => oldDelegate.t != t;
}
