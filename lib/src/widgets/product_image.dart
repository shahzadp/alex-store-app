/// Product image, with the placeholder the store uses while photographs are
/// missing.
///
/// # This placeholder is the product image, not a fallback
///
/// Every `image_url` in `catalog.json` is currently null (MEMORY.md §6, open
/// work), so this is what a shopper sees for every product. That makes it the
/// single most-viewed element in the app, and it is why it is styled rather
/// than merely "something until the photo exists".
///
/// The earlier version rendered the product name in 12px over a flat colour
/// field. Read as "image missing" — which is accurate, but accurate is not the
/// same as confident, and a shop whose every product looks like a broken image
/// is a shop that looks untrustworthy.
///
/// The treatment now: a soft two-stop tint, the name set properly rather than
/// dumped in the middle, and a corner radius from the shared scale. No invented
/// imagery, no fake photography, no icon pretending to be a picture — MEMORY.md
/// §4 only allows what is verifiable.
library;

import 'package:flutter/material.dart';

import '../theme.dart';

/// Three tints cycle through the catalog. They come from the data, not from
/// here — this only supplies the fallback for a product with no tint at all.
/// These are the site's `--tint-1/2/3` values (styles.css:31-33).
const _fallbackTints = <Color>[Color(0xFFD9CCEA), Color(0xFFCFC3E3), Color(0xFFE3D6EE)];

Color tintOrFallback(String? tint, int seed) {
  if (tint != null && tint.isNotEmpty) {
    final parsed = parseTint(tint);
    if (parsed != null) return parsed;
  }
  return _fallbackTints[seed % _fallbackTints.length];
}

/// Parse `#RGB`, `#RRGGBB` or `#AARRGGBB`. Returns null for anything else
/// rather than throwing — a bad colour in the catalog should cost one product
/// its tint, not the whole screen.
Color? parseTint(String value) {
  var hex = value.trim();
  if (hex.startsWith('#')) hex = hex.substring(1);
  if (hex.length == 3) {
    hex = hex.split('').map((c) => '$c$c').join('');
  }
  if (hex.length == 6) hex = 'FF$hex';
  if (hex.length != 8) return null;
  final n = int.tryParse(hex, radix: 16);
  return n == null ? null : Color(n);
}

class ProductImage extends StatelessWidget {
  const ProductImage({
    super.key,
    required this.imageUrl,
    required this.tint,
    required this.label,
    this.seed = 0,
    this.aspectRatio = 1,
    this.borderRadius = StoreTheme.rMd,
    this.heroTag,
  });

  final String? imageUrl;
  final String? tint;
  final String label;
  final int seed;
  final double aspectRatio;
  final BorderRadius borderRadius;

  /// When set, the image is shared with the one on the product card, so
  /// pushing the product screen flies the tile from the grid into place rather
  /// than cutting to a new screen. Amazon, Shopify and Airbnb all do this; it
  /// is the single cheapest "this app was built properly" signal there is.
  ///
  /// Both images must use the same tag and the same `tint`, or the hero has
  /// nowhere to fly from and Flutter falls back to a plain cross-fade.
  final String? heroTag;

  Widget _frame(BuildContext context, Widget child) {
    if (heroTag == null) return child;
    return Hero(tag: heroTag!, child: child);
  }

  @override
  Widget build(BuildContext context) {
    final url = imageUrl;
    if (url != null && url.isNotEmpty) {
      return _frame(
        context,
        ClipRRect(
          borderRadius: borderRadius,
          child: AspectRatio(
            aspectRatio: aspectRatio,
            child: Image.network(
              url,
              fit: BoxFit.cover,
              // A network image must never leave a hole in the grid. Falling
              // back to the tint keeps the row height identical, which matters
              // because the grid is uniform by construction.
              errorBuilder: (_, __, ___) => _placeholder(context),
              loadingBuilder: (context, child, progress) {
                if (progress == null) return child;
                return _placeholder(context);
              },
              // Cross-fade in rather than popping, so the layout is stable.
              frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
                if (wasSynchronouslyLoaded) return child;
                return AnimatedOpacity(
                  opacity: frame == null ? 0 : 1,
                  duration: StoreTheme.durationMed,
                  curve: StoreTheme.curveStandard,
                  child: child,
                );
              },
            ),
          ),
        ),
      );
    }
    return _frame(context, _placeholder(context));
  }

  Widget _placeholder(BuildContext context) {
    final tint = tintOrFallback(this.tint, seed);
    return ClipRRect(
      borderRadius: borderRadius,
      child: AspectRatio(
        aspectRatio: aspectRatio,
        child: DecoratedBox(
          decoration: BoxDecoration(
            // Two stops of the same tint, so the field has depth without
            // introducing a colour that is not the product's own.
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                tint,
                Color.alphaBlend(const Color(0x1A2E2638), tint),
              ],
            ),
          ),
          child: Material(
            color: Colors.transparent,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: StoreTheme.spaceLg,
                vertical: StoreTheme.spaceMd,
              ),
              // The name set deliberately, at a size that reads as a design
              // choice rather than as a missing-image message.
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Flexible(
                    child: Text(
                      label,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        height: 1.25,
                        fontWeight: FontWeight.w500,
                        letterSpacing: 0.2,
                        color: StoreTheme.placeholderInk,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
