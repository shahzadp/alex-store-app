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
        padding: const EdgeInsets.symmetric(vertical: 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            ProductImage(
              imageUrl: product.imageUrl,
              tint: product.tint,
              label: product.name,
              seed: seed,
            ),
            const SizedBox(height: 12),

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
            const SizedBox(height: 4),

            SizedBox(
              height: StoreTheme.descriptionHeight,
              child: Text(
                product.description,
                maxLines: StoreTheme.descriptionLines,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            const SizedBox(height: 10),

            // Spacer pushes the price to the bottom of the card, so the price
            // line sits on one baseline across the whole row.
            const SizedBox(height: 4),
            _PriceRow(product: product),
          ],
        ),
      ),
    );
  }
}

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

    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(product.price.formatted, style: theme.textTheme.titleSmall),
        const SizedBox(width: 8),
        Text(
          'Order on WhatsApp',
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
/// Uses a fixed child aspect ratio rather than `SliverGridDelegateWithMaxCrossAxisExtent`,
/// which measures children and produces ragged rows the moment one product
/// has a longer description than its neighbours.
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

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // One column on a phone, two on anything wider — the site does the same
        // and a two-up grid on a 360dp screen makes the descriptions
        // unreadable.
        final columns = constraints.maxWidth >= 560 ? 3 : (constraints.maxWidth >= 380 ? 2 : 1);
        const spacing = 18.0;

        return GridView.builder(
          padding: padding,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: products.length,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: spacing,
            crossAxisSpacing: spacing,
            // Tall enough for image + two name lines + three description lines
            // + price row, so the row height is a function of the grid and
            // never of the content.
            childAspectRatio: columns == 1 ? 1.9 : 0.66,
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