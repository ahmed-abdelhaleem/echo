// Material 3 theme for Echo.
//
// The visual identity work lands in M1 (T-CLIENT-013) with design tokens
// generated from `packages/design-tokens/`. This file defines a quiet,
// readable default so screens render correctly through M0.

import 'package:flutter/material.dart';

ThemeData buildLightTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF3D5A6C),
    brightness: Brightness.light,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    typography: Typography.material2021(),
  );
}

ThemeData buildDarkTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF3D5A6C),
    brightness: Brightness.dark,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    typography: Typography.material2021(),
  );
}
