// Guards the card's height, which is derived arithmetic rather than measured
// layout. A refactor broke it by nesting an extra Padding inside the card,
// doubling its vertical inset and overflowing the grid by exactly that much.
// The analyzer said nothing; only the RenderFlex overflow in a widget test
// caught it.
//
// The rule: cardHeightFor() and the tree ProductCard builds must agree. If they
// do not, the grid assigns each card a cell it does not fit and they overlap.
//
// The card is constrained to the exact cell width the grid would give it, so
// the measurement is of the card alone and not of whatever the test view
// happens to be sized. (The first version of this test forgot to size the test
// view at all, so the grid laid out at the 800dp default and every number was
// wrong — which is why it fails loudly rather than silently.)
import 'dart:typed_data';

import 'package:alex_store/src/models/catalog.dart';
import 'package:alex_store/src/models/price.dart';
import 'package:alex_store/src/widgets/product_card.dart';
import 'package:alex_store/src/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Product product(String slug, String description, {bool inStock = true}) =>
    Product(
      slug: slug,
      name: slug,
      category: 'Kitchen',
      price: const Price.paisa(780000),
      inStock: inStock,
      description: description,
      details: 'd',
      specs: const {},
      options: const [],
      imageUrl: null,
      tint: '#D9CCEA',
      vector: Float32List(384),
    );

/// The cell width the grid gives at [screenWidth].
double cellWidthFor(double screenWidth) {
  final columns = ProductGrid.columnsFor(screenWidth);
  return (screenWidth -
          StoreTheme.screenEdge * 2 -
          StoreTheme.cardGap * (columns - 1)) /
      columns;
}

void main() {
  testWidgets('a card fits the cell the grid gives it', (tester) async {
    for (final screenWidth in [320.0, 360.0, 412.0, 800.0]) {
      final cell = cellWidthFor(screenWidth);
      final reserved = ProductGrid.cardHeightFor(cell);

      await tester.pumpWidget(MaterialApp(
        theme: StoreTheme.light(),
        home: Scaffold(
          body: Center(
            // Constrained to exactly what the grid would hand it.
            child: SizedBox(
              width: cell,
              child: ProductCard(
                product: product('a', 'A description that is reasonably long.'),
                onTap: () {},
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      final measured = tester.getSize(find.byType(ProductCard)).height;
      expect(
        measured,
        lessThanOrEqualTo(reserved + 0.01),
        reason: 'at ${screenWidth}dp the card is ${measured.toStringAsFixed(1)} '
            'but the grid reserved ${reserved.toStringAsFixed(1)}',
      );
    }
  });

  testWidgets('sold-out and in-stock cards are the same height',
      (tester) async {
    // A taller sold-out card would leave a gap in the middle of a row, and a
    // shorter one would let the row go ragged.
    final cell = cellWidthFor(412);
    double? inStockHeight;

    for (final inStock in [true, false]) {
      await tester.pumpWidget(MaterialApp(
        theme: StoreTheme.light(),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: cell,
              child: ProductCard(
                product: product('a', 'A description.', inStock: inStock),
                onTap: () {},
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      final h = tester.getSize(find.byType(ProductCard)).height;
      inStockHeight ??= h;
      expect(h, inStockHeight,
          reason: 'the sold-out variant changed the card height');
    }
  });

  test('cardHeightFor accounts for every part of the card', () {
    // If a widget is added to the card and this constant is not updated, the
    // grid silently clips it. Pinned so the relationship is inspectable.
    final cell = 151.0;
    final byHand = StoreTheme.cardVerticalPadding * 2 +
        cell / StoreTheme.cardImageAspect +
        StoreTheme.cardGapImage +
        StoreTheme.nameHeight +
        StoreTheme.cardGapName +
        StoreTheme.descriptionHeight +
        StoreTheme.cardGapDescription +
        StoreTheme.cardGapPrice +
        StoreTheme.priceRowHeight;
    expect(ProductGrid.cardHeightFor(cell), byHand);
  });
}
