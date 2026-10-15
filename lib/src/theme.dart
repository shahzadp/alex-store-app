/// Visual language.
///
/// The site is a restrained, editorial storefront: a muted palette, generous
/// whitespace, and almost no chrome. The app follows the same rules rather
/// than inventing an "app" look, because it is the same store.
///
/// The placeholder tints are lifted verbatim from `catalog.json` — every
/// product currently has `image_url: null`, so these are what the shopper
/// actually sees until real photographs exist.
library;

import 'package:flutter/material.dart';

class StoreTheme {
  const StoreTheme._();

  // Neutrals
  static const ink = Color(0xFF16130F);
  static const inkSoft = Color(0xFF5A534A);
  static const inkFaint = Color(0xFF8C8378);
  static const paper = Color(0xFFFAF7F2);
  static const surface = Color(0xFFFFFFFF);
  static const hairline = Color(0xFFE6DFD4);

  // WhatsApp. There are three greens on the site because no single one is
  // legible on all three surfaces (MEMORY.md §4, CATALOG-GUIDE.md §11); on
  // paper and on white they coincide, so one value is enough here.
  static const whatsapp = Color(0xFF1FA855);

  /// Reserved for sold-out. Never a button colour.
  static const soldOut = Color(0xFF9A9186);

  static ThemeData light() {
    final base = ThemeData.light(useMaterial3: true);

    return base.copyWith(
      colorScheme: base.colorScheme.copyWith(
        primary: ink,
        onPrimary: surface,
        secondary: whatsapp,
        onSecondary: Colors.white,
        surface: surface,
        onSurface: ink,
        error: const Color(0xFF9B2C2C),
      ),
      scaffoldBackgroundColor: paper,
      splashFactory: InkSparkle.splashFactory,
      textTheme: base.textTheme.apply(
        bodyColor: ink,
        displayColor: ink,
      ).copyWith(
        displaySmall: const TextStyle(fontSize: 30, fontWeight: FontWeight.w400, height: 1.15, letterSpacing: -0.4),
        headlineMedium: const TextStyle(fontSize: 24, fontWeight: FontWeight.w500, height: 1.2, letterSpacing: -0.3),
        headlineSmall: const TextStyle(fontSize: 19, fontWeight: FontWeight.w500, height: 1.25, letterSpacing: -0.2),
        titleMedium: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500, height: 1.3),
        titleSmall: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500, height: 1.35),
        bodyLarge: const TextStyle(fontSize: 15, height: 1.5, color: ink),
        bodyMedium: const TextStyle(fontSize: 14, height: 1.5, color: inkSoft),
        bodySmall: const TextStyle(fontSize: 12.5, height: 1.45, color: inkFaint),
        labelLarge: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, letterSpacing: 0.2),
        labelSmall: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 0.8, color: inkFaint),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: paper,
        surfaceTintColor: Colors.transparent,
        foregroundColor: ink,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(fontSize: 18, fontWeight: FontWeight.w500, color: ink, letterSpacing: -0.2),
      ),
      dividerTheme: const DividerThemeData(color: hairline, thickness: 1, space: 1),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: whatsapp,
          foregroundColor: Colors.white,
          minimumSize: const Size.fromHeight(50),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: ink,
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: ink,
          side: const BorderSide(color: hairline),
          minimumSize: const Size.fromHeight(50),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surface,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        hintStyle: const TextStyle(color: inkFaint, fontSize: 15),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(4),
          borderSide: const BorderSide(color: hairline),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(4),
          borderSide: const BorderSide(color: hairline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(4),
          borderSide: const BorderSide(color: ink, width: 1.4),
        ),
      ),
    );
  }

  /// Line reserved for a product name on a card.
  ///
  /// MEMORY.md §3: "Grid uniformity is enforced by CSS, not discipline" — the
  /// web reserves two lines for the name and three for the description, and
  /// pins the price to the bottom with `margin-top: auto`. The equivalent here
  /// is a fixed-height box: a card's contents can never change the row height,
  /// however long the text is.
  static const nameLines = 2;
  static const descriptionLines = 3;
  static const nameLineHeight = 22.0;
  static const descriptionLineHeight = 20.0;
  static const nameHeight = nameLines * nameLineHeight;
  static const descriptionHeight = descriptionLines * descriptionLineHeight;
}