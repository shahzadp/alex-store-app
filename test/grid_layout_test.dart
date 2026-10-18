// Proves the grid-overlap bug reported from the device stays fixed.
//
// The report: product cards rendered on top of each other with no gap. The grid
// is a fixed-aspect GridView whose cell height comes from `childAspectRatio`,
// while the card inside is laid out by its own content. When the content is
// taller than the cell, every card overflows its slot and they collide.
//
// Two layers of check:
//   1. Pump the real ProductGrid at several widths. Flutter throws on overflow,
//      so simply laying it out IS the assertion.
//   2. Measure the real ProductCard and compare against the height the grid
//      predicts. That catches the case where the card's contents change but
//      the prediction does not, which would otherwise reintroduce the overlap
//      silently.
//
// ProductGrid and ProductCard are public and take products directly, so this
// exercises the app's real code with no service, no HTTP and no replica.
import 'dart:typed_data';

import 'package:alex_store/src/models/catalog.dart';
import 'package:alex_store/src/models/price.dart';
import 'package:alex_store/src/widgets/product_card.dart';
import 'package:alex_store/src/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Product product(String slug, String name, String description) => Product(
      slug: slug,
      name: name,
      category: 'cat',
      price: const Price.paisa(780000),
      inStock: true,
      description: description,
      details: 'details',
      specs: const {},
      options: const [],
      imageUrl: null,
      tint: '#D9CCEA',
      vector: Float32List(384),
    );

/// The longest thing the catalog is allowed to contain, per CATALOG-GUIDE.md.
final _longDescription =
    'A heavy stoneware mug, hand-glazed in a soft matte cream and fired at a '
    'high temperature so the glaze sits flat against the clay. Holds about '
    '350ml, which is a full mug rather than an oversized tumbler.';

void main() {
  group('the grid lays out without overflowing', () {
    for (final width in [320.0, 360.0, 412.0, 800.0]) {
      testWidgets('at ${width.toInt()}dp wide', (tester) async {
        tester.view.physicalSize = Size(width * 3, 2400 * 3);
        tester.view.devicePixelRatio = 3.0;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(MaterialApp(
          theme: StoreTheme.light(),
          home: Scaffold(
            body: SingleChildScrollView(
              child: ProductGrid(
                products: [
                  product('a', 'Stoneware Mug', _longDescription),
                  product('b', 'Linen Napkin Set',
                      'Stonewashed linen napkins, sold as a set of four.'),
                  product('c', 'Brass Taper Holder',
                      'Unlacquered brass that will patina with use.'),
                ],
                onTap: (_) {},
              ),
            ),
          ),
        ));

        await tester.pumpAndSettle();
      });
    }
  });

  group('the grid predicts the card height correctly', () {
    testWidgets('measured card height matches cardHeightFor', (tester) async {
      for (final width in [320.0, 360.0, 412.0, 480.0, 800.0, 1024.0]) {
        final columns = ProductGrid.columnsFor(width);
        // ProductGrid's default padding is horizontal: 20.
        final available = width - 40;
        final cellWidth =
            (available - StoreTheme.cardGap * (columns - 1)) / columns;
        final predicted = ProductGrid.cardHeightFor(cellWidth);

        await tester.pumpWidget(MaterialApp(
          theme: StoreTheme.light(),
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: cellWidth,
                child: ProductCard(
                  product: product('a', 'Stoneware Mug', _longDescription),
                  onTap: () {},
                ),
              ),
            ),
          ),
        ));
        await tester.pumpAndSettle();

        final measured = tester
            .getSize(find.byType(ProductCard))
            .height;

        expect(
          measured,
          lessThanOrEqualTo(predicted),
          reason: 'at ${width}dp the card is ${measured.toStringAsFixed(1)}px '
              'but the grid only reserved ${predicted.toStringAsFixed(1)}px, '
              'so it would overflow into its neighbour',
        );
      }
    });
  });

  group('columns', () {
    test('two on every phone width, three on a tablet', () {
      expect(ProductGrid.columnsFor(320), 2);
      expect(ProductGrid.columnsFor(360), 2);
      expect(ProductGrid.columnsFor(412), 2);
      expect(ProductGrid.columnsFor(600), 2);
      expect(ProductGrid.columnsFor(1000), 3);
    });

    test('cards are separated by a visible gap', () {
      expect(StoreTheme.cardGap, greaterThanOrEqualTo(12));
    });
  });
}