// lib/intro/painters/restart_nebula.dart
import 'dart:math' as math;
import 'package:flutter/material.dart';

class RestartNebulaPainter extends CustomPainter {
  final double progress; // 0..1
  RestartNebulaPainter({required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    final t = progress.clamp(0.0, 1.0);
    final center = Offset(size.width / 2, size.height / 2);

    void blob(Offset c, double r, Color a, Color b, double alpha) {
      final paint = Paint()
        ..shader = RadialGradient(
          colors: [
            a.withOpacity(alpha),
            b.withOpacity(alpha * 0.70),
            Colors.transparent,
          ],
          stops: const [0.0, 0.55, 1.0],
        ).createShader(Rect.fromCircle(center: c, radius: r));
      canvas.drawCircle(c, r, paint);
    }

    final diag = math.sqrt(size.width * size.width + size.height * size.height);
    final drift = 0.08 * diag;
    final dx = drift * math.sin(t * 2 * math.pi);
    final dy = drift * math.cos(t * 2 * math.pi * 0.9);

    blob(
      Offset(center.dx - diag * 0.18 + dx, center.dy - diag * 0.12 + dy),
      diag * (0.42 + 0.05 * math.sin(t * 2 * math.pi)),
      const Color(0xFFFF4FD8),
      const Color(0xFF4DFFFF),
      0.32,
    );

    blob(
      Offset(center.dx + diag * 0.22 - dx * 0.8, center.dy - diag * 0.08 + dy * 0.6),
      diag * (0.38 + 0.06 * math.cos(t * 2 * math.pi)),
      const Color(0xFF4DFFFF),
      const Color(0xFFFFC84D),
      0.26,
    );

    blob(
      Offset(center.dx + dx * 0.5, center.dy + diag * 0.18 - dy * 0.7),
      diag * (0.46 + 0.04 * math.sin(t * 2 * math.pi * 1.3)),
      const Color(0xFFFFC84D),
      const Color(0xFFFF4FD8),
      0.20,
    );

    final sweepAngle = t * 2 * math.pi;
    final band = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Colors.transparent,
          const Color(0xFFFF4FD8).withOpacity(0.12),
          const Color(0xFF4DFFFF).withOpacity(0.14),
          const Color(0xFFFFC84D).withOpacity(0.12),
          Colors.transparent,
        ],
        stops: const [0.22, 0.40, 0.55, 0.68, 0.86],
        transform: GradientRotation(sweepAngle),
      ).createShader(Offset.zero & size);
    canvas.drawRect(Offset.zero & size, band);

    final rings = 22;
    for (int i = 0; i < rings; i++) {
      final fi = i / rings;
      final rr = (math.min(size.width, size.height) * (0.18 + 0.62 * fi)) *
          (0.98 + 0.03 * math.sin(t * 2 * math.pi * 2 + fi * 8 * math.pi));
      final a = (0.02 + 0.06 * (1 - fi)) * (0.55 + 0.45 * math.sin(t * 2 * math.pi));
      final color = Color.lerp(
        const Color(0xFFFF4FD8),
        const Color(0xFF4DFFFF),
        0.5 + 0.5 * math.sin(fi * 6 * math.pi + t * 2 * math.pi),
      )!
          .withOpacity(a.clamp(0.0, 0.10));

      final p = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2 + 0.4 * (1 - fi)
        ..color = color;

      canvas.drawCircle(center, rr, p);
    }
  }

  @override
  bool shouldRepaint(covariant RestartNebulaPainter oldDelegate) {
    return oldDelegate.progress != progress;
  }
}
