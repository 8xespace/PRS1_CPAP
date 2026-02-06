// lib/main.dart
import 'package:flutter/material.dart';

import 'app_state.dart';
import 'intro/intro_splash.dart';

void main() {
  runApp(const TopHomeApp());
}

class TopHomeApp extends StatefulWidget {
  const TopHomeApp({super.key});

  @override
  State<TopHomeApp> createState() => _TopHomeAppState();
}

class _TopHomeAppState extends State<TopHomeApp> {
  final AppState _appState = appStateStore;

  @override
  void dispose() {
    _appState.dispose();
    super.dispose();
  }

  ThemeData _buildTheme({
    required Brightness brightness,
    required BrandColor brandColor,
  }) {
    final base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorSchemeSeed: brandColor.color,
    );

    // 母本規則：AppBar + Scaffold 一致化，並讓 seedColor 真正反映在元件上
    final cs = base.colorScheme;

    return base.copyWith(
      scaffoldBackgroundColor: cs.surface,
      appBarTheme: AppBarTheme(
        backgroundColor: cs.surface,
        foregroundColor: cs.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 用 AnimatedBuilder 讓 MaterialApp 隨 AppState 即時刷新
    return AnimatedBuilder(
      animation: _appState,
      builder: (context, _) {
        return AppStateScope(
          notifier: _appState,
          child: MaterialApp(
            title: '頂極制作所',
            debugShowCheckedModeBanner: false,
            themeMode: _appState.themeMode,
            theme: _buildTheme(
              brightness: Brightness.light,
              brandColor: _appState.brandColor,
            ),
            darkTheme: _buildTheme(
              brightness: Brightness.dark,
              brandColor: _appState.brandColor,
            ),
            home: const IntroSplash3sEndAt4s(),
          ),
        );
      },
    );
  }
}
