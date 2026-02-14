// lib/intro/intro_splash.dart
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../home/home_page.dart';
import 'painters/restart_nebula.dart';
import 'painters/sparkle.dart';
import 'widgets/logo_naked.dart';

class IntroSplash3sEndAt4s extends StatefulWidget {
  const IntroSplash3sEndAt4s({super.key});

  @override
  State<IntroSplash3sEndAt4s> createState() => _IntroSplash3sEndAt4sState();
}

class _IntroSplash3sEndAt4sState extends State<IntroSplash3sEndAt4s>
    with TickerProviderStateMixin {
  late final AnimationController _fxCtrl;
  late final AnimationController _logoCtrl;
  late final AnimationController _progressCtrl;
  Timer? _endTimer;

  @override
  void initState() {
    super.initState();

    _fxCtrl = AnimationController(vsync: this, duration: const Duration(seconds: 3))
      ..forward();

    _logoCtrl = AnimationController(vsync: this, duration: const Duration(seconds: 3))
      ..forward();

    _progressCtrl =
        AnimationController(vsync: this, duration: const Duration(seconds: 3))
          ..forward();

    _endTimer = Timer(const Duration(seconds: 4), () {
      if (!mounted) return;
      _fxCtrl.stop();
      _logoCtrl.stop();
      _progressCtrl.stop();
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const HomePage()),
      );
    });
  }

  @override
  void dispose() {
    _endTimer?.cancel();
    _fxCtrl.dispose();
    _logoCtrl.dispose();
    _progressCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: AnimatedBuilder(
              animation: _fxCtrl,
              builder: (context, _) {
                final t = _fxCtrl.value.clamp(0.0, 1.0);

                final fade = Curves.easeInOut.transform(
                  t < 0.10 ? (t / 0.10) : (t > 0.94 ? ((1 - t) / 0.06) : 1.0),
                );

                return Opacity(
                  opacity: fade.clamp(0.0, 1.0),
                  child: Stack(
                    children: [
                      const Positioned.fill(child: ColoredBox(color: Colors.white)),
                      Positioned.fill(
                        child: CustomPaint(
                          painter: RestartNebulaPainter(progress: t),
                        ),
                      ),
                      Positioned.fill(
                        child: CustomPaint(
                          painter: SparklePainter(progress: t),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          Center(
            child: AnimatedBuilder(
              animation: Listenable.merge([_logoCtrl, _progressCtrl]),
              builder: (_, __) {
                final t = Curves.easeInOutCubic.transform(_logoCtrl.value);
                final angle = -6 * math.pi * t;
                final p = _progressCtrl.value.clamp(0.0, 1.0);

                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 22),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Transform.rotate(
                        angle: angle,
                        child: const LogoNaked(
                          assetPath: 'assets/logo.png',
                          size: 180,
                        ),
                      ),
                      const SizedBox(height: 14),
                      Text(
                        '頂極制作所',
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 2.2,
                          color: isDark ? Colors.white : Colors.black,
                          shadows: [
                            Shadow(
                              blurRadius: 18,
                              color: (isDark ? Colors.white : Colors.black)
                                  .withOpacity(0.10),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        '啟動中…',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.0,
                          color: cs.outline,
                        ),
                      ),
                      const SizedBox(height: 16),
                      _CrystalProgressBar(value: p, width: 280, height: 14),
                      const SizedBox(height: 10),
                      Text(
                        '載入中 ${(p * 100).floor()}%',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.0,
                          color: isDark ? Colors.white70 : Colors.black54,
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

// ---- 晶體進度條（維持原樣） ----

class _CrystalProgressBar extends StatelessWidget {
  final double value;
  final double width;
  final double height;

  const _CrystalProgressBar({
    required this.value,
    this.width = 280,
    this.height = 14,
  });

  @override
  Widget build(BuildContext context) {
    final v = value.clamp(0.0, 1.0);

    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color(0x55FF2D55),
              Color(0x40E91E63),
              Color(0x30FF8A80),
            ],
          ),
          border: Border.all(
            color: const Color(0x55FFFFFF),
            width: 1,
          ),
        ),
        child: Stack(
          children: [
            Positioned.fill(
              child: ColoredBox(color: Colors.black.withOpacity(0.08)),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: FractionallySizedBox(
                widthFactor: v,
                child: Container(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        Color(0xA0FF2D55),
                        Color(0x90FF5C8A),
                        Color(0x70FFD1D9),
                      ],
                      stops: [0.0, 0.55, 1.0],
                    ),
                  ),
                ),
              ),
            ),
            Positioned.fill(
              child: CustomPaint(
                painter: _CrystalShinePainter(intensity: 0.55),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CrystalShinePainter extends CustomPainter {
  final double intensity;
  const _CrystalShinePainter({required this.intensity});

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    final p = Path()
      ..moveTo(w * 0.10, 0)
      ..lineTo(w * 0.28, 0)
      ..lineTo(w * 0.20, h)
      ..lineTo(w * 0.02, h)
      ..close();

    final p2 = Path()
      ..moveTo(w * 0.55, 0)
      ..lineTo(w * 0.70, 0)
      ..lineTo(w * 0.62, h)
      ..lineTo(w * 0.47, h)
      ..close();

    final shine = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Color(0x00FFFFFF),
          Color(0x88FFFFFF),
          Color(0x00FFFFFF),
        ],
        stops: [0.0, 0.5, 1.0],
      ).createShader(Offset.zero & size);

    canvas.drawPath(p, shine..color = Colors.white.withOpacity(0.22 * intensity));
    canvas.drawPath(p2, shine..color = Colors.white.withOpacity(0.18 * intensity));

    final line = Paint()
      ..color = Colors.white.withOpacity(0.35 * intensity)
      ..strokeWidth = 1;

    canvas.drawLine(Offset(0, 0.6), Offset(w, 0.6), line);
  }

  @override
  bool shouldRepaint(covariant _CrystalShinePainter oldDelegate) {
    return oldDelegate.intensity != intensity;
  }
}
