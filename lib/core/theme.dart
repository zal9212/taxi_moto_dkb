import 'package:flutter/material.dart';

/// Palette et thème de l'app — inspiré du design validé
/// (fond clair, cartes noires pour les montants clés, accent vert lime).
class AppColors {
  AppColors._();

  static const Color fond = Color(0xFFF4F4F2);
  static const Color carteNoire = Color(0xFF181818);
  static const Color carteNoireClaire = Color(0xFF242424);
  static const Color accentLime = Color(0xFFC8F169);
  static const Color accentLimeTexte = Color(0xFF1A2B00);
  static const Color texteNoir = Color(0xFF181818);
  static const Color texteGris = Color(0xFF9A9A96);
  static const Color bordure = Color(0xFFE2E2DF);
  static const Color succes = Color(0xFF4A7A0A);
  static const Color succesFond = Color(0xFFDFF0C2);
  static const Color danger = Color(0xFFA33333);
  static const Color dangerFond = Color(0xFFFBE0DD);
  static const Color avertissement = Color(0xFFB5860A);
  static const Color avertissementFond = Color(0xFFFBEFD9);
}

class AppTheme {
  AppTheme._();

  static ThemeData get light {
    return ThemeData(
      useMaterial3: true,
      scaffoldBackgroundColor: AppColors.fond,
      fontFamily: 'Roboto',
      colorScheme: ColorScheme.fromSeed(
        seedColor: AppColors.accentLime,
        brightness: Brightness.light,
        primary: AppColors.carteNoire,
        secondary: AppColors.accentLime,
        surface: Colors.white,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.fond,
        elevation: 0,
        foregroundColor: AppColors.texteNoir,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: AppColors.texteNoir,
          fontSize: 17,
          fontWeight: FontWeight.w600,
        ),
      ),
      cardTheme: CardThemeData(
        color: Colors.white,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: AppColors.bordure, width: 0.6),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.accentLime,
          foregroundColor: AppColors.accentLimeTexte,
          elevation: 0,
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: AppColors.bordure),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: AppColors.bordure),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: AppColors.carteNoire, width: 1.4),
        ),
        labelStyle: const TextStyle(color: AppColors.texteGris, fontSize: 13),
      ),
    );
  }
}
