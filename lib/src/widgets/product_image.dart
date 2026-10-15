/// Product image, with the placeholder the store uses while photographs are
/// missing.
///
/// Every `image_url` in `catalog.json` is currently null, so this is what a
/// shopper sees for every product (MEMORY.md §6, open work). It renders the
/// product's `tint` as a flat field with the name set in it — deliberately
/// quiet, because it is a stand-in, not a design.
library;

import 'package:flutter/material.dart';


/// Three tints cycle through the catalog. They come from the data, not from
/// here — this only supplies the fallback for a product with no tint at all.
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
    hex = hex.split('').map((c) => '$c$c').join();
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
    this.borderRadius = const BorderRadius.all(Radius.circular(3)),
  });

  final String? imageUrl;
  final String? tint;
  final String label;
  final int seed;

  /// Square by default, matching the shop grid.
  final double aspectRatio;
  final BorderRadius borderRadius;

  @override
  Widget build(BuildContext context) {
    final url = imageUrl;
    if (url != null && url.isNotEmpty) {
      return ClipRRect(
        borderRadius: borderRadius,
        child: AspectRatio(
          aspectRatio: aspectRatio,
          child: Image.network(
            url,
            fit: BoxFit.cover,
            // A broken image URL must not leave a hole in the grid. Falling
            // back to the tint keeps the row height identical, which matters
            // because the grid is uniform by construction.
            errorBuilder: (_, __, ___) => _placeholder(context),
            loadingBuilder: (context, child, progress) {
              if (progress == null) return child;
              return _placeholder(context);
            },
          ),
        ),
      );
    }
    return _placeholder(context);
  }

  Widget _placeholder(BuildContext context) {
    final color = tintOrFallback(tint, seed);
    return ClipRRect(
      borderRadius: borderRadius,
      child: AspectRatio(
        aspectRatio: aspectRatio,
        child: ColoredBox(
          color: color,
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                label,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12,
                  height: 1.3,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 0.3,
                  color: Color(0xFF4A4152),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}