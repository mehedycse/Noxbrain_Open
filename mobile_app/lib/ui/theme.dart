import 'package:flutter/material.dart';

class SolarTheme {
  static const Color background = Color(0xFF090D16);
  static const Color surface = Color(0xFF131B2A);
  static const Color surfaceLight = Color(0xFF1E283D);
  static const Color border = Color(0xFF26354D);

  static const Color solarAmber = Color(0xFF00E6D1); // Teal color replacing orange
  static const Color batteryGreen = Color(0xFF10B981);
  static const Color batteryDischarging = Color(0xFFEF4444);
  // The load accent now uses the solar/sun amber (was purple 0xFF8B5CF6),
  // matching the Solar Panel node, at the user's request.
  static const Color loadPurple = Color(0xFFFFB300);
  static const Color infoCyan = Color(0xFF06B6D4);

  static const Color textPrimary = Color(0xFFF8FAFC);
  static const Color textSecondary = Color(0xFF94A3B8);
  static const Color textMuted = Color(0xFF64748B);

  static ThemeData get darkTheme {
    return ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: background,
      primaryColor: solarAmber,
      cardColor: surface,
      dividerColor: border,
      colorScheme: const ColorScheme.dark(
        primary: solarAmber,
        secondary: batteryGreen,
        surface: surface,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: surface,
        elevation: 0,
        centerTitle: true,
        titleTextStyle: TextStyle(
          color: textPrimary,
          fontSize: 18,
          fontWeight: FontWeight.bold,
          letterSpacing: 0.5,
        ),
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: surface,
        selectedItemColor: solarAmber,
        unselectedItemColor: textMuted,
        type: BottomNavigationBarType.fixed,
        elevation: 8,
      ),
      fontFamily: 'Roboto',
    );
  }
}
