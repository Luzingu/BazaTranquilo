import 'package:flutter/material.dart';

class BazaColors {
  static const yellow = Color(0xFFFFC400);
  static const ink = Color(0xFF14161A);
  static const muted = Color(0xFF6B7280);
  static const surface = Color(0xFFF4F5F7);
  static const green = Color(0xFF16A34A);
  static const red = Color(0xFFDC2626);
}

ThemeData bazaTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: BazaColors.yellow,
    primary: BazaColors.yellow,
    onPrimary: BazaColors.ink,
    secondary: BazaColors.ink,
    onSecondary: Colors.white,
    surface: Colors.white,
    onSurface: BazaColors.ink,
    error: BazaColors.red,
  );
  final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(14));
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: Colors.white,
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.white,
      foregroundColor: BazaColors.ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        color: BazaColors.ink,
        fontSize: 20,
        fontWeight: FontWeight.w700,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(54),
        shape: shape,
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(54),
        shape: shape,
        foregroundColor: BazaColors.ink,
        side: const BorderSide(color: Color(0xFFD1D5DB)),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: BazaColors.ink),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: BazaColors.surface,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: BazaColors.ink, width: 1.5),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );
}
