/// A horizontal strip of product cards.
///
/// Used by "Recently viewed" on the home screen and "You may also like" on
/// the product screen — both of those are browse-after suggestions, not the
/// main grid, so they scroll sideways instead of growing the page. The card
/// cell is a fixed width and the row's height is the card's derived height,
/// so nothing ever overflows or clips.
library;

import 'package:flutter/material.dart';

import '../models/catalog.dart';
import 'product_card.dart';

class ProductRow extends StatelessWidget {
  const ProductRow({
    super.key,
    required this.products,
    required this.onTap,
    this.heroTagPrefix = 'row',
  });

  final List<Product> products;
  final void Function(Product) onTap;

  /// Suffix for the card Hero tags, so rows never collide with the grid.
  final String heroTagPrefix;

  static const double itemWidth = 150;

  static double get heightForRow => ProductGrid.cardHeightFor(itemWidth);

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: heightForRow,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.zero,
        itemCount: products.length,
        separatorBuilder: (_, __) => const SizedBox(width: 14),
        itemBuilder: (context, i) => SizedBox(
          width: itemWidth,
          child: ProductCard(
            product: products[i],
            seed: i,
            heroTagSuffix: '-$heroTagPrefix-$i',
            onTap: () => onTap(products[i]),
          ),
        ),
      ),
    );
  }
}
