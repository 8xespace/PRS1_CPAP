// lib/main.dart
import 'package:flutter/material.dart';
import 'intro/intro_splash.dart';

void main() {
  runApp(const TopHomeApp());
}

class TopHomeApp extends StatelessWidget {
  const TopHomeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '頂極制作所',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFFE91E63),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorSchemeSeed: const Color(0xFFE91E63),
      ),
      themeMode: ThemeMode.system,
      home: const IntroSplash3sEndAt4s(),
    );
  }
}
