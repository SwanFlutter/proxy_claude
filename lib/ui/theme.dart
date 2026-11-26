import 'package:flutter/material.dart';

class AppTheme {
  const AppTheme._();

  static const Color seed = Color(0xFF14B8A6); // teal

  static ThemeData _build(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(seedColor: seed, brightness: brightness);
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      brightness: brightness,
      scaffoldBackgroundColor: brightness == Brightness.dark
          ? const Color(0xFF0C1317)
          : const Color(0xFFF6F8F9),
      visualDensity: VisualDensity.compact,
    );
  }

  static ThemeData get light => _build(Brightness.light);
  static ThemeData get dark => _build(Brightness.dark);
}
