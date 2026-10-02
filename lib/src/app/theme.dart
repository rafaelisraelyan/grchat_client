import 'package:flutter/material.dart';

const _accent = Color(0xFF574CC9);

final grchatDark = ThemeData(
  useMaterial3: true,
  brightness: Brightness.dark,
  colorScheme: const ColorScheme.dark(
    primary: _accent,
    surface: Color(0xFF1B1A1D),
    surfaceContainerHighest: Color(0xFF232225),
  ),
  scaffoldBackgroundColor: const Color(0xFF1B1A1D),
);

final grchatLight = ThemeData(
  useMaterial3: true,
  brightness: Brightness.light,
  colorScheme: const ColorScheme.light(
    primary: _accent,
    surface: Color(0xFFF5F4F7),
    surfaceContainerHighest: Color(0xFFE8E6EC),
  ),
  scaffoldBackgroundColor: const Color(0xFFF5F4F7),
);
