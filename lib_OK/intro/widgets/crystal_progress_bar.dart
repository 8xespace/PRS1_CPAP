import 'package:flutter/material.dart';

class CrystalProgressBar extends StatelessWidget {
  const CrystalProgressBar({super.key, required this.t});

  final double t;

  @override
  Widget build(BuildContext context) {
    final p = t.clamp(0.0, 1.0);
    return Container(
      height: 12,
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.06),
        borderRadius: BorderRadius.circular(999),
      ),
      child: FractionallySizedBox(
        alignment: Alignment.centerLeft,
        widthFactor: p,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            gradient: const LinearGradient(
              colors: [
                Color(0xFFFF4B7D),
                Color(0xFFFF9DB3),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
