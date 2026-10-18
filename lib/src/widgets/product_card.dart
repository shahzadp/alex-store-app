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
import 'package:flutter/services.dart';

import '../catalog_scope.dart';
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
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: StoreTheme.cardVerticalPadding),
      child: Material(
        color: Colors.transparent,
        borderRadius: StoreTheme.rMd,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () {
            // A tactile confirmation at the moment of intent, which is what
            // makes a tap feel like it landed. Silent taps read as ignored.
            HapticFeedback.selectionClick();
            onTap();
          },
          splashColor: StoreTheme.accent.withValues(alpha: 0.06),
          highlightColor: StoreTheme.accent.withValues(alpha: 0.03),
          // No padding here: the outer Padding already supplies the card's
          // vertical inset. It was here once and doubled the card's height,
          // which overflowed the grid by exactly that much.
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
                Stack(
                  children: [
                    ProductImage(
                      imageUrl: product.imageUrl,
                      tint: product.tint,
                      label: product.name,
                      seed: seed,
                      aspectRatio: StoreTheme.cardImageAspect,
                      heroTag: 'product-image-${product.slug}',
                    ),
                    // Sold-out is a state, not a styling of the price. A card
                    // that merely greys its text gives no reason why, and one
                    // that looks identical to an in-stock card is the thing
                    // that costs a sale: a shopper taps it, reads the product,
                    // and only then finds they cannot order.
                    if (!product.inStock) const _SoldOutVeil(),
                  ],
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
                SizedBox(
                  height: StoreTheme.priceRowHeight,
                  child: _PriceRow(product: product),
                ),
              ],
            ),
          ),
        ),
    );
  }
}

/// Washes the tile and labels it, so an unsaleable card is legible at a glance
/// from two metres away rather than only when it is tapped.
class _SoldOutVeil extends StatelessWidget {
  const _SoldOutVeil();

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: StoreTheme.bg.withValues(alpha: 0.55),
          borderRadius: StoreTheme.rMd,
        ),
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: StoreTheme.spaceMd,
              vertical: StoreTheme.spaceXs + 2,
            ),
            decoration: BoxDecoration(
              color: StoreTheme.surfaceDark.withValues(alpha: 0.92),
              borderRadius: StoreTheme.rSm,
            ),
            child: const Text(
              'Sold out',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.4,
                color: StoreTheme.inkOnDark,
              ),
            ),
          ),
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
///
/// When the catalog carries a `delivery_percent`, the delivery-included figure
/// is shown struck through *before* the price — the same two spans the site
/// renders (`.price__was` then `.price__now`). The price itself never changes.
/// They share one line, so the card's reserved height is untouched.
class _PriceRow extends StatelessWidget {
  const _PriceRow({required this.product});

  final Product product;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (!product.inStock) {
      // Muted but struck-through-free: a strikethrough would imply a discount
      // that does not exist (MEMORY.md §4, only verifiable claims).
      return Text(
        'Sold out',
        style: theme.textTheme.titleSmall?.copyWith(color: StoreTheme.soldOut),
      );
    }

    final store = CatalogScope.maybeOf(context)?.state.catalog?.store;
    final included = store?.deliveryIncluded(product.price);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text.rich(
          TextSpan(
            children: [
              if (included != null)
                TextSpan(
                  text: '${included.formatted}  ',
                  // 13 against the 14px price is the site's 0.92em, and the same
                  // struck-through grey.
                  style: const TextStyle(
                    color: StoreTheme.inkMuted,
                    fontWeight: FontWeight.w400,
                    fontSize: 13,
                    decoration: TextDecoration.lineThrough,
                    decorationColor: StoreTheme.inkMuted,
                  ),
                ),
              TextSpan(text: product.price.formatted),
            ],
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleSmall,
          // Mirrors the site's `aria-label` on the struck span, so a screen
          // reader hears what the strikethrough means rather than two numbers.
          semanticsLabel: included == null
              ? null
              : '${included.formatted} including delivery. '
                  '${product.price.formatted}',
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