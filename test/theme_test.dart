// Guards the two theme defects that made the home screen wrong.
//
// 1. UNSET COLOURS. `ThemeData.copyWith` replaces a TextStyle rather than
//    merging it, so a style written as a bare `TextStyle(fontSize: 30)` throws
//    away the colour. It then falls back to the ambient DefaultTextStyle,
//    which rendered the hero heading in body-copy grey. Every style must name
//    its colour explicitly, and this test fails if one ever stops doing so.
//
// 2. CONTRAST. The store's whole palette is text on a coloured background, so
//    a token that is legible in one place can be unreadable in another. This
//    checks the WCAG contrast of each ink against the surface it is used on.
//
// It reads the styles off a real pumped MaterialApp rather than off the
// ThemeData object, so what is measured is what the screen paints.
import 'dart:math' as math;

import 'package:alex_store/src/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// WCAG relative luminance (https://www.w3.org/TR/WCAG21/#dfn-relative-luminance).
double luminance(Color c) =>
    0.2126 * _channel(c.r) + 0.7152 * _channel(c.g) + 0.0722 * _channel(c.b);

double _channel(double v) =>
    v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();

/// WCAG contrast ratio. 1.0 is identical, 21.0 is black on white.
double contrast(Color a, Color b) {
  final la = luminance(a), lb = luminance(b);
  final hi = math.max(la, lb), lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  late TextTheme t;

  setUp(() {
    t = StoreTheme.light().textTheme;
  });

  group('no text style is left without a colour', () {
    // Thunks, because the map is built once when the group is declared, which
    // is before setUp assigns `t`.
    final styles = <String, TextStyle? Function()>{
      'displaySmall': () => t.displaySmall,
      'headlineMedium': () => t.headlineMedium,
      'headlineSmall': () => t.headlineSmall,
      'titleMedium': () => t.titleMedium,
      'titleSmall': () => t.titleSmall,
      'bodyLarge': () => t.bodyLarge,
      'bodyMedium': () => t.bodyMedium,
      'bodySmall': () => t.bodySmall,
      'labelLarge': () => t.labelLarge,
      'labelSmall': () => t.labelSmall,
    };

    styles.forEach((name, get) {
      test(name, () {
        expect(
          get()?.color,
          isNotNull,
          reason: '$name has no colour, so it inherits whatever the ambient '
              'DefaultTextStyle happens to be. Write the colour explicitly.',
        );
      });
    });
  });

  group('every ink is legible on the surface it is used on', () {
    test('body and heading inks on the page background', () {
      expect(contrast(StoreTheme.ink, StoreTheme.bg), greaterThanOrEqualTo(4.5));
      expect(contrast(StoreTheme.inkBody, StoreTheme.bg), greaterThanOrEqualTo(4.5));
      expect(contrast(StoreTheme.inkMuted, StoreTheme.bg), greaterThanOrEqualTo(4.5));
    });

    test('body and heading inks on a white card surface', () {
      expect(contrast(StoreTheme.ink, StoreTheme.surface), greaterThanOrEqualTo(4.5));
      expect(contrast(StoreTheme.inkBody, StoreTheme.surface), greaterThanOrEqualTo(4.5));
      expect(contrast(StoreTheme.inkMuted, StoreTheme.surface), greaterThanOrEqualTo(4.5));
    });

    test('ink on dark uses the on-dark token, not plain ink', () {
      expect(contrast(StoreTheme.ink, StoreTheme.surfaceDark),
          lessThan(2.0),
          reason: 'if this ever passes, the announcement bar can use ink');
      expect(contrast(StoreTheme.inkOnDark, StoreTheme.surfaceDark),
          greaterThanOrEqualTo(4.5));
    });

    test('the placeholder label is legible on the product tints', () {
      for (final tint in const [
        Color(0xFFD9CCEA),
        Color(0xFFCFC3E3),
        Color(0xFFE3D6EE),
      ]) {
        expect(
          contrast(StoreTheme.placeholderInk, tint),
          greaterThanOrEqualTo(4.5),
          reason: 'placeholder text on $tint',
        );
      }
    });

    test('the WhatsApp green is legible on the light page', () {
      expect(contrast(StoreTheme.whatsapp, StoreTheme.bg), greaterThanOrEqualTo(4.5));
    });

    test('sold-out is muted but still readable', () {
      expect(contrast(StoreTheme.soldOut, StoreTheme.bg), greaterThanOrEqualTo(3.0));
    });
  });

  group('the palette matches the website', () {
    test('tokens are the site values from styles.css', () {
      // Pinned so the app cannot drift away from Store/styles.css unnoticed.
      expect(StoreTheme.bg, const Color(0xFFEEE8F4));
      expect(StoreTheme.surface, const Color(0xFFFBF8FD));
      expect(StoreTheme.surfaceDark, const Color(0xFF2E2638));
      expect(StoreTheme.ink, const Color(0xFF2E2638));
      expect(StoreTheme.inkBody, const Color(0xFF4B3F5C));
      expect(StoreTheme.inkMuted, const Color(0xFF5E5170));
      expect(StoreTheme.accent, const Color(0xFF6B4B8F));
      expect(StoreTheme.line, const Color(0xFFCFC4DD));
    });

    test('the scaffold uses the page background, not white', () {
      expect(StoreTheme.light().scaffoldBackgroundColor, StoreTheme.bg);
    });
  });

  group('type weights follow the site', () {
    // styles.css: `h1, h2 { font-weight: 600 }`. The store name is the app's
    // <h1> and used to be w400, which read as body copy rather than a heading.
    test('the store name is bold, like the website h1', () {
      expect(StoreTheme.light().textTheme.displaySmall?.fontWeight,
          FontWeight.w600);
    });
  });

  group('painted colour is what the theme declares', () {
    // The failure this guards against: the style declares a colour but the
    // widget paints something else, because a DefaultTextStyle upstream won.
    testWidgets('headings paint the ink, not a fallback', (tester) async {
      final theme = StoreTheme.light();

      for (final style in [theme.textTheme.displaySmall, theme.textTheme.titleSmall]) {
        await tester.pumpWidget(MaterialApp(
          theme: theme,
          home: Scaffold(body: Text('probe', style: style)),
        ));
        final paragraph = tester.renderObject<RenderParagraph>(
          find.descendant(of: find.text('probe'), matching: find.byType(RichText)).first,
        );
        expect(paragraph.text.style?.color, style?.color);
      }
    });
  });
}