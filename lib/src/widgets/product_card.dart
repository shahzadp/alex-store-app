/// The product card, used by every grid in the app.
///
/// # Why the heights are hard-coded
///
/// MEMORY.md §3: "Grid uniformity is enforced by CSS, not discipline. The
/// web reserves two lines for the name, three for the description, and pins
/// everything to the card bottom. Text that exceeds that is clamped with an
/// ellipsis and always available in full on the product page."
///
/// The Flutter equivalent is a fixed-height text box. Because the name and
/// description slots cannot grow, every card in a row is the same height no
/// matter what the catalog says — which is the property that makes the grid
/// look deliberate rather than approximate.
///
/// CATALOG-GUIDE.md §3 keeps names to two or three words and descriptions well
/// under 300 characters for exactly this reason. Truncation here is a safe
/// fallback, not the intended state.
library;

import 'package:flutter/material.dart';

import '../models/catalog.dart';
import '../theme.dart';
import '../widgets/product_image.dart';

class ProductCard extends StatelessWidget {
  const ProductCard({
    super.key,
    required this.product,
    required this.onTap,
    this.seed = 0,
  });

  final Product product;
  final VoidCallback onTap;

  /// Varies the placeholder tint for products that carry none.
  final int seed;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      // Ink on the card rather than a border: the site uses a hairline grid
      // with no card chrome, and a ripple needs *something* to sit on.
      splashColor: const Color(0x14000000),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: StoreTheme.cardVerticalPadding),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            ProductImage(
              imageUrl: product.imageUrl,
              tint: product.tint,
              label: product.name,
              seed: seed,
              aspectRatio: StoreTheme.cardImageAspect,
            ),
            const SizedBox(height: StoreTheme.cardGapImage),

            // Reserved, never grown.
            SizedBox(
              height: StoreTheme.nameHeight,
              child: Text(
                product.name,
                maxLines: StoreTheme.nameLines,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            const SizedBox(height: StoreTheme.cardGapName),

            SizedBox(
              height: StoreTheme.descriptionHeight,
              child: Text(
                product.description,
                maxLines: StoreTheme.descriptionLines,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            const SizedBox(height: StoreTheme.cardGapDescription),

            // Fixed height, so every price line in the row sits on the same
            // baseline regardless of whether it is a price or "Sold out".
            const SizedBox(height: StoreTheme.cardGapPrice),
            SizedBox(
              height: StoreTheme.priceRowHeight,
              child: _PriceRow(product: product),
            ),
          ],
        ),
      ),
    );
  }
}

/// Price, with the WhatsApp affordance underneath.
///
/// These were on one line and overflowed a two-column cell by 134px: "Order on
/// WhatsApp" is wider than half a phone. Stacked, the block is a fixed height
/// that fits any cell width.
class _PriceRow extends StatelessWidget {
  const _PriceRow({required this.product});

  final Product product;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (!product.inStock) {
      return Text(
        'Sold out',
        style: theme.textTheme.titleSmall?.copyWith(color: StoreTheme.soldOut),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          product.price.formatted,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleSmall,
        ),
        const SizedBox(height: 2),
        Text(
          'Order on WhatsApp',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.labelSmall?.copyWith(
            color: StoreTheme.whatsapp,
            letterSpacing: 0.2,
          ),
        ),
      ],
    );
  }
}

/// A grid that keeps its rows even.
///
/// # Why the aspect ratio is derived, not typed in
///
/// This used to hard-code `childAspectRatio: 0.66`. That number was wrong by a
/// wide margin: a two-column card is about 150dp wide, so 0.66 gave a 228dp
/// cell, while the card's contents are ~340dp tall. Every card therefore
/// overflowed its slot by more than 100dp and the cards rendered on top of one
/// another with no visible gap.
///
/// A hard-coded ratio cannot be right, because the correct value depends on
/// the cell width, which depends on the screen. But the card's height is
/// *knowable*: the name and description slots are fixed height, so the only
/// variable is the square image, whose height is the cell width. So the grid
/// computes the exact height the card will need and derives the ratio from it.
/// `grid_layout_test.dart` pumps this at three screen widths and fails if a
/// card ever outgrows its cell again.
///
/// The result is still uniform by construction: every card gets the same cell,
/// and the fixed-height text boxes mean content length cannot change it.
class ProductGrid extends StatelessWidget {
  const ProductGrid({
    super.key,
    required this.products,
    required this.onTap,
    this.padding = const EdgeInsets.symmetric(horizontal: 20),
  });

  final List<Product> products;
  final void Function(Product) onTap;
  final EdgeInsets padding;

  /// Two columns on a phone, three on a tablet, matching the site's grid.
  static int columnsFor(double width) {
    if (width >= 900) return 3;
    return 2;
  }

  /// The height a card occupies, given a cell width.
  ///
  /// Mirrors the widget tree built by [ProductCard]. If one changes, this must
  /// change with it, which is what `cardFitsItsCell` in the test asserts.
  static double cardHeightFor(double cellWidth) {
    return StoreTheme.cardVerticalPadding * 2 +
        (cellWidth / StoreTheme.cardImageAspect) +
        StoreTheme.cardGapImage +
        StoreTheme.nameHeight +
        StoreTheme.cardGapName +
        StoreTheme.descriptionHeight +
        StoreTheme.cardGapDescription +
        StoreTheme.cardGapPrice +
        StoreTheme.priceRowHeight;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = columnsFor(constraints.maxWidth);
        final spacing = StoreTheme.cardGap;
        final available = constraints.maxWidth - padding.horizontal;
        final cellWidth =
            (available - spacing * (columns - 1)) / columns;
        final cellHeight = cardHeightFor(cellWidth);

        return GridView.builder(
          // The bottom inset is added here rather than by each caller, because
          // the grid is the last thing on both the home screen and the shop
          // screen, and a grid that does not clear the three-button navigation
          // bar puts the last product under it.
          padding: padding.copyWith(
            bottom: padding.bottom + StoreTheme.bottomSafeInset(context),
          ),
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: products.length,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: spacing,
            crossAxisSpacing: spacing,
            // Width over height, so the cell is exactly as tall as the card.
            childAspectRatio: cellWidth / cellHeight,
          ),
          itemBuilder: (context, i) => ProductCard(
            product: products[i],
            seed: i,
            onTap: () => onTap(products[i]),
          ),
        );
      },
    );
  }
}