/// Visual language.
///
/// These are the site's own tokens, copied from `Store/styles.css` so the app
/// and the website are the same store rather than two things that resemble
/// each other. Changing a value here means changing it there.
///
/// # Every text style carries an explicit colour
///
/// An earlier version declared `displaySmall`, `headlineSmall`, `titleMedium`
/// and `titleSmall` with no `color`. `ThemeData.copyWith` REPLACES a style
/// rather than merging it, so writing a bare `TextStyle(fontSize: 30)` discards
/// the colour that `.apply(bodyColor:, displayColor:)` had just put there. The
/// style then falls back to whatever the ambient `DefaultTextStyle` happens to
/// be, which is not something a reader of this file can predict — and which
/// rendered the hero heading in body-copy grey instead of near-black. Every
/// style below therefore names its colour, and `theme_test.dart` fails if one
/// is ever left unset.
library;

import 'package:flutter/material.dart';

class StoreTheme {
  const StoreTheme._();

  // ── Surfaces and ink ─────────────────────────────────────────────────────
  // Verbatim from styles.css. These are the names that file uses, so the two
  // stay greppable against each other.
  static const bg = Color(0xFFEEE8F4);
  static const surfaceDark = Color(0xFF2E2638);
  static const surface = Color(0xFFFBF8FD);
  static const ink = Color(0xFF2E2638);
  static const inkBody = Color(0xFF4B3F5C);
  static const inkMuted = Color(0xFF5E5170);
  static const inkAccent = Color(0xFF5B3C80);
  static const line = Color(0xFFCFC4DD);
  static const accent = Color(0xFF6B4B8F);
  static const error = Color(0xFF8C3B4A);

  // Ink for use ON a dark surface. Different token, different contrast job:
  // `ink` on `surfaceDark` would be invisible.
  static const inkOnDark = Color(0xFFEEE8F4);
  static const inkOnDarkMuted = Color(0xFFCFC4DD);

  // WhatsApp. The site carries three greens because one is not legible on all
  // three surfaces (styles.css:59-61); on light backgrounds the dark green is
  // the only correct choice.
  static const whatsapp = Color(0xFF0F6B36);

  /// The word "WhatsApp" inside a purple `.btn-solid`. The dark green used on
  /// the page reaches only 1.65:1 on the accent, so the site carries a lighter
  /// green for this one surface. Measured at 4.54:1.
  static const whatsappOnAccent = Color(0xFF5CEB8F);

  /// Reserved for sold-out. Never a button colour.
  static const soldOut = Color(0xFF8E8296);

  /// Placeholder label colour. Sits on the product tints, which are all light
  /// purples, so it is body ink rather than pure dark.
  static const placeholderInk = Color(0xFF4B3F5C);

  static ThemeData light() {
    final base = ThemeData.light(useMaterial3: true);

    return base.copyWith(
      colorScheme: base.colorScheme.copyWith(
        primary: accent,
        onPrimary: surface,
        secondary: whatsapp,
        onSecondary: surface,
        surface: surface,
        onSurface: ink,
        error: error,
        outline: line,
      ),
      scaffoldBackgroundColor: bg,
      splashFactory: InkSparkle.splashFactory,
      // NOTE: no `.apply(bodyColor:, displayColor:)`. It works, but `copyWith`
      // below replaces the styles anyway, so the only thing it buys is a
      // false sense that colours are handled. They are set explicitly instead.
      textTheme: base.textTheme.copyWith(
        displaySmall: TextStyle(fontSize: 30, fontWeight: FontWeight.w400, height: 1.15, letterSpacing: -0.4, color: ink),
        headlineMedium: TextStyle(fontSize: 24, fontWeight: FontWeight.w500, height: 1.2, letterSpacing: -0.3, color: ink),
        headlineSmall: TextStyle(fontSize: 19, fontWeight: FontWeight.w500, height: 1.25, letterSpacing: -0.2, color: ink),
        titleMedium: TextStyle(fontSize: 16, fontWeight: FontWeight.w500, height: 1.3, color: ink),
        titleSmall: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, height: 1.35, color: ink),
        bodyLarge: TextStyle(fontSize: 15, height: 1.5, color: ink),
        bodyMedium: TextStyle(fontSize: 14, height: 1.5, color: inkBody),
        bodySmall: TextStyle(fontSize: 12.5, height: 1.45, color: inkMuted),
        labelLarge: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, letterSpacing: 0.2, color: ink),
        labelSmall: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 0.8, color: inkMuted),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: bg,
        surfaceTintColor: Colors.transparent,
        foregroundColor: ink,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(fontSize: 18, fontWeight: FontWeight.w500, color: ink, letterSpacing: -0.2),
      ),
      dividerTheme: const DividerThemeData(color: line, thickness: 1, space: 1),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: surface,
          minimumSize: const Size.fromHeight(50),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: inkAccent,
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: ink,
          side: const BorderSide(color: line),
          minimumSize: const Size.fromHeight(50),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surface,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        hintStyle: const TextStyle(color: inkMuted, fontSize: 15),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(4),
          borderSide: const BorderSide(color: line),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(4),
          borderSide: const BorderSide(color: line),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(4),
          borderSide: const BorderSide(color: ink, width: 1.4),
        ),
      ),
    );
  }

  // ── Product card geometry ────────────────────────────────────────────────
  //
  // These exist so ProductGrid can DERIVE its cell height instead of guessing
  // one with a hard-coded `childAspectRatio`. The name and description slots
  // are fixed height, so the card's total height is a function of the cell
  // width alone — which means the grid can compute the exact aspect ratio that
  // fits, and a card can never overflow its slot and collide with its
  // neighbours.

  /// Image aspect within a card. Square, matching the shop grid.
  static const cardImageAspect = 1.0;

  static const cardVerticalPadding = 18.0;
  static const cardGapImage = 12.0;
  static const cardGapName = 4.0;
  static const cardGapDescription = 10.0;
  static const cardGapPrice = 4.0;

  /// The price and its WhatsApp label stack on two lines. On one line they
  /// overflowed a two-column cell by 134px, because "Order on WhatsApp" is
  /// wider than half a phone.
  static const priceRowHeight = 38.0;

  static const cardGap = 18.0;

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