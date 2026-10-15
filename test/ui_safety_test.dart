// Guards two defects that were only visible on a real handset.
//
// 1. BUTTON LABEL CONTRAST. The label spans used to be built from
//    `DefaultTextStyle.of(context).style` at the call site. That context is the
//    screen's, ABOVE the button, so the label inherited the page's dark ink and
//    rendered dark-on-purple; only the word "WhatsApp" stayed legible. The spans
//    must therefore carry no colour of their own and inherit from the button,
//    which already carries the button's foreground.
//
// 2. THREE-BUTTON NAVIGATION AREA. Hard-coded bottom padding (28dp) is smaller
//    than the ~48dp inset of Android's three-button nav bar, so the last card
//    or footer line sat underneath it. Gesture navigation has a much smaller
//    inset, which is why this looked fine everywhere except the device.
//
// Both are asserted by pumping the real widgets with a simulated inset rather
// than by checking constants, because the failure mode is the interaction
// between a constant and a layout.
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:alex_store/src/models/catalog.dart';
import 'package:alex_store/src/models/price.dart';
import 'package:alex_store/src/services/whatsapp.dart';
import 'package:alex_store/src/theme.dart';
import 'package:alex_store/src/widgets/product_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// Android's three-button navigation bar, and what gesture nav looks like.
const threeButtonNav = 48.0;
const gestureNav = 16.0;

double _lum(Color c) {
  double ch(double v) =>
      v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b);
}

double contrast(Color a, Color b) {
  final x = _lum(a), y = _lum(b);
  return (math.max(x, y) + 0.05) / (math.min(x, y) + 0.05);
}

Product aProduct() => Product(
      slug: 'a',
      name: 'Stoneware Mug',
      category: 'Kitchen',
      price: const Price.paisa(780000),
      inStock: true,
      description: 'Glazed stoneware, holds heat well and goes in the dishwasher.',
      details: 'details',
      specs: const {},
      imageUrl: null,
      tint: '#D9CCEA',
      vector: Float32List(384),
    );

void main() {
  group('WhatsApp button label', () {
    test('the plain spans carry no colour, so they inherit the button', () {
      final span = whatsappButtonLabel('Order on ', after: ' - Rs 7,800');

      final plain =
          span.children!.whereType<TextSpan>().where((s) => s.text != 'WhatsApp');
      expect(plain, hasLength(2));
      for (final s in plain) {
        expect(s.style?.color, isNull,
            reason: '"${s.text}" must inherit, not set a colour');
      }

      final wa = span.children!.whereType<TextSpan>()
          .firstWhere((s) => s.text == 'WhatsApp');
      expect(wa.style?.color, StoreTheme.whatsappOnAccent);
    });

    testWidgets('every part of the label is legible on the button', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: StoreTheme.light(),
        home: Scaffold(
          body: Center(
            child: FilledButton(
              onPressed: () {},
              child: Text.rich(
                whatsappButtonLabel('Order on ', after: ' - Rs 7,800'),
              ),
            ),
          ),
        ),
      ));

      final paragraph = tester.renderObject<RenderParagraph>(
        find.descendant(
          of: find.byType(FilledButton),
          matching: find.byType(RichText),
        ).first,
      );

      // The rule: whatever colour a button is, its text has to be legible on
      // it. Resolve each span the way the engine does — its own colour if it
      // has one, otherwise the paragraph's — then check it against the button.
      final inherited = paragraph.text.style?.color;
      var checked = 0;
      for (final span in _allSpans(paragraph.text)) {
        if (span is! TextSpan || (span.text?.isEmpty ?? true)) continue;
        final colour = span.style?.color ?? inherited;
        expect(colour, isNotNull,
            reason: '"${span.text}" resolved to no colour at all');
        expect(
          contrast(colour!, StoreTheme.accent),
          greaterThanOrEqualTo(4.5),
          reason: '"${span.text}" is unreadable on the ${StoreTheme.accent} '
              'button: ${contrast(colour, StoreTheme.accent).toStringAsFixed(2)}:1',
        );
        checked++;
      }
      expect(checked, 3, reason: 'expected three visible spans in the label');
    });

    testWidgets('the footer label is legible too', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: StoreTheme.light(),
        home: Scaffold(
          body: Center(
            child: FilledButton(
              onPressed: () {},
              child: Text.rich(whatsappButtonLabel('Message the shop on ')),
            ),
          ),
        ),
      ));

      final paragraph = tester.renderObject<RenderParagraph>(
        find.descendant(
          of: find.byType(FilledButton),
          matching: find.byType(RichText),
        ).first,
      );
      final inherited = paragraph.text.style?.color;
      for (final span in _allSpans(paragraph.text)) {
        if (span is! TextSpan || (span.text?.isEmpty ?? true)) continue;
        final colour = span.style?.color ?? inherited;
        expect(contrast(colour!, StoreTheme.accent), greaterThanOrEqualTo(4.5));
      }
    });
  });

  group('three-button navigation area', () {
    testWidgets('reads view padding, which Scaffold does not strip', (tester) async {
      setNavInset(tester, threeButtonNav);
      late double read;

      await tester.pumpWidget(MaterialApp(
        theme: StoreTheme.light(),
        home: Builder(builder: (context) {
          read = StoreTheme.bottomSafeInset(context);
          // A Scaffold WITH a bottomNavigationBar is the case that matters: it
          // strips padding.bottom from the body, so only viewPadding still
          // carries the real inset.
          return Scaffold(
            bottomNavigationBar: const SizedBox(height: 60),
            body: const SizedBox.shrink(),
          );
        }),
      ));

      expect(read, threeButtonNav);
    });

    for (final (name, inset) in [('three-button', threeButtonNav), ('gesture', gestureNav)]) {
      testWidgets('the product grid clears a $name bar', (tester) async {
        setNavInset(tester, inset);
        await tester.pumpWidget(MaterialApp(
          theme: StoreTheme.light(),
          home: Scaffold(
            body: SingleChildScrollView(
              child: ProductGrid(products: [aProduct(), aProduct()], onTap: (_) {}),
            ),
          ),
        ));
        await tester.pumpAndSettle();

        final grid = tester.widget<GridView>(find.byType(GridView));
        final padding = grid.padding! as EdgeInsets;
        expect(padding.bottom, greaterThanOrEqualTo(inset),
            reason: 'the last row must be scrollable clear of the nav bar');
      });
    }
  });
}

/// Applies a system navigation bar inset to the test view, restoring it after.
///
/// The inset is set in PHYSICAL pixels and divided down by the device pixel
/// ratio, so the ratio is pinned to 1 first — otherwise asking for a 48dp bar
/// silently produces a 16dp one at DPR 3, and the test would assert against a
/// value it never actually configured.
void setNavInset(WidgetTester tester, double inset) {
  tester.view.devicePixelRatio = 1.0;
  tester.view.viewPadding =
      FakeViewPadding(top: 0, bottom: inset, left: 0, right: 0);
  tester.view.padding =
      FakeViewPadding(top: 0, bottom: inset, left: 0, right: 0);
  addTearDown(() {
    tester.view.resetDevicePixelRatio();
    tester.view.resetViewPadding();
    tester.view.resetPadding();
  });
}

Iterable<InlineSpan> _allSpans(InlineSpan span) sync* {
  if (span is TextSpan) {
    yield span;
    for (final child in span.children ?? const <InlineSpan>[]) {
      yield* _allSpans(child);
    }
  }
}