/// Catalog domain model.
///
/// Mirrors the shape of the site's `catalog.json`, which is the only file the
/// app can read — it cannot run sql.js and never parses `catalog.sql`.
/// See CATALOG-GUIDE.md §8.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'price.dart';

/// The store's settings block.
class Store {
  const Store({
    required this.name,
    required this.whatsapp,
    required this.freeDeliveryOver,
    required this.currency,
  });

  final String name;

  /// Digits only, no `+`, no separators — the site's `settings.whatsapp`.
  final String whatsapp;

  /// Free-delivery threshold.
  ///
  /// A [Price], not a bare int: this is money, and `Product.price` is a
  /// [Price] too. Having one of them be a raw paisa count is how "Rs 6,000"
  /// and "600000" end up in the same expression.
  final Price freeDeliveryOver;

  /// Always `PKR`. There is no currency selector and no USD anywhere in this
  /// store; the field exists only so the app can assert that rather than
  /// assume it.
  final String currency;

  static const Store empty = Store(
    name: 'Alex Store',
    whatsapp: '',
    freeDeliveryOver: Price.zero,
    currency: 'PKR',
  );

  factory Store.fromJson(Map<String, dynamic> json) {
    final wa = (json['whatsapp'] as String?) ?? '';
    return Store(
      name: (json['name'] as String?)?.trim().isNotEmpty == true
          ? (json['name'] as String).trim()
          : 'Alex Store',
      whatsapp: wa.replaceAll(RegExp(r'[^0-9]'), ''),
      freeDeliveryOver: Price.paisa(_asInt(json['free_delivery_over_paisa'])),
      currency: (json['currency'] as String?) ?? 'PKR',
    );
  }
}

/// One product.
///
/// Note the three separate text fields, which are the single most common
/// source of confusion in this store (CATALOG-GUIDE.md §5):
///
///  * [description] — one factual line. On cards, in search, in the WhatsApp
///    message. This is the text that gets embedded.
///  * [details] — the long write-up on the product page. Not searchable.
///  * [specs] — structured label/value data for the specifications box.
///    Not searchable.
class Product {
  const Product({
    required this.slug,
    required this.name,
    required this.category,
    required this.price,
    required this.inStock,
    required this.description,
    required this.details,
    required this.specs,
    required this.imageUrl,
    required this.tint,
    required this.vector,
  });

  final String slug;
  final String name;
  final String category;
  final Price price;
  final bool inStock;
  final String description;
  final String details;
  final Map<String, String> specs;
  final String? imageUrl;
  final String? tint;

  /// The precomputed ternlight embedding, decoded from base64. Null when the
  /// catalog is not fully indexed — see [Catalog.isSearchable].
  final Float32List? vector;

  /// The WhatsApp message, pre-written exactly as the site builds it: the
  /// product, its price and its description, so the shopkeeper does not have
  /// to reconstruct what is being asked about.
  String whatsappMessage(String whatsappNumber) {
    final buffer = StringBuffer()
      ..writeln('Hello, I would like to order:')
      ..writeln()
      ..writeln('$name — ${price.formatted}')
      ..writeln()
      ..writeln(description);
    if (details.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln(details);
    }
    return Uri.encodeComponent(buffer.toString());
  }

  factory Product.fromJson(Map<String, dynamic> json) {
    return Product(
      slug: (json['slug'] as String?) ?? '',
      name: (json['name'] as String?) ?? '',
      category: (json['category'] as String?)?.trim().isNotEmpty == true
          ? (json['category'] as String).trim()
          : 'General',
      price: Price.paisa(_asInt(json['price_cents'])),
      inStock: json['in_stock'] != false,
      description: (json['description'] as String?) ?? '',
      details: (json['details'] as String?) ?? '',
      specs: _asSpecs(json['specs']),
      imageUrl: _asStringOrNull(json['image_url']),
      tint: _asStringOrNull(json['tint']),
      vector: _asVector(json['vector']),
    );
  }

  /// Base64 float32 blob from `catalog.json`.
  ///
  /// Returns null — never throws, never pads — for anything that is not a
  /// well-formed [Product.embeddingDims]-element vector. A wrong-width vector
  /// would make the dot product meaningless, and MEMORY.md §4 is largely a
  /// catalogue of ways a plausible-looking wrong answer gets shipped.
  static Float32List? _asVector(Object? raw) {
    if (raw is! String || raw.isEmpty) return null;
    try {
      final bytes = base64Decode(raw);
      if (bytes.length != embeddingDims * 4) return null;
      // copy() rather than view(): the underlying buffer may be larger than
      // the slice, and a stray offset into the FFI would be a nightmare to
      // debug.
      return Float32List.fromList(
        Float32List.view(bytes.buffer, bytes.offsetInBytes, embeddingDims),
      );
    } on FormatException {
      return null;
    }
  }

  /// Dimensions of a ternlight embedding. Must equal `SEARCH_DIMS` in the
  /// site's `db.js` and `EMBEDDING_DIMS` in the Rust crate.
  static const int embeddingDims = 384;

  static Map<String, String> _asSpecs(Object? raw) {
    if (raw is! Map) return const {};
    final out = <String, String>{};
    raw.forEach((key, value) {
      final label = (key as String?)?.trim() ?? '';
      final text = (value as String?)?.trim() ?? '';
      // A blank label or value is a rendering artefact, not information.
      if (label.isEmpty || text.isEmpty) return;
      out[label] = text;
    });
    return out;
  }
}

/// An editorial collection. Deliberately not a product group — CATALOG-GUIDE
/// §6: linking collections to products is a schema change, not a styling one.
class ProductCollection {
  const ProductCollection({
    required this.slug,
    required this.title,
    required this.description,
    required this.imageUrl,
    required this.tint,
  });

  final String slug;
  final String title;
  final String description;
  final String? imageUrl;
  final String? tint;

  factory ProductCollection.fromJson(Map<String, dynamic> json) {
    return ProductCollection(
      slug: (json['slug'] as String?) ?? '',
      title: (json['title'] as String?) ?? '',
      description: (json['description'] as String?) ?? '',
      imageUrl: _asStringOrNull(json['image_url']),
      tint: _asStringOrNull(json['tint']),
    );
  }
}

/// The whole catalog, as fetched from the site.
class Catalog {
  const Catalog({
    required this.generatedAt,
    required this.store,
    required this.products,
    required this.collections,
    required this.searchModel,
  });

  final DateTime? generatedAt;
  final Store store;
  final List<Product> products;
  final List<ProductCollection> collections;

  /// The encoder these vectors belong to, from the site's `SEARCH_MODEL`.
  final String searchModel;

  /// True when every product carries a vector, i.e. the site's
  /// `indexIsComplete()`.
  ///
  /// This is the guard that matters. Per CATALOG-GUIDE.md §1, an incomplete
  /// index makes **every** search return nothing, silently, across the whole
  /// app — the site looks fine and nobody is told. So the app refuses to
  /// search rather than showing an empty result the user reads as "we don't
  /// stock that".
  bool get isSearchable =>
      products.isNotEmpty && products.every((p) => p.vector != null);

  /// Products missing a vector. Non-empty means the site needs a reindex.
  List<String> get unindexedSlugs =>
      products.where((p) => p.vector == null).map((p) => p.slug).toList();

  Set<String> get categories {
    final set = <String>{};
    for (final p in products) {
      if (p.category.isNotEmpty) set.add(p.category);
    }
    return set;
  }

  Product? bySlug(String slug) {
    for (final p in products) {
      if (p.slug == slug) return p;
    }
    return null;
  }

  static Catalog fromJson(Map<String, dynamic> json) {
    return Catalog(
      generatedAt: DateTime.tryParse((json['generated_at'] as String?) ?? ''),
      store: Store.fromJson(
        (json['store'] as Map?)?.cast<String, dynamic>() ?? const {},
      ),
      products: ((json['products'] as List?) ?? const [])
          .whereType<Map>()
          .map((m) => Product.fromJson(m.cast<String, dynamic>()))
          .toList(growable: false),
      collections: ((json['collections'] as List?) ?? const [])
          .whereType<Map>()
          .map((m) => ProductCollection.fromJson(m.cast<String, dynamic>()))
          .toList(growable: false),
      searchModel: (json['search_model'] as String?) ?? '',
    );
  }
}

String? _asStringOrNull(Object? raw) {
  if (raw is! String) return null;
  final trimmed = raw.trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// Coerce a JSON value to an integer.
///
/// The catalog is generated, so these should always be integers already — but
/// `catalog.json` is a file on a web server that anyone with push access can
/// change, and `jsonDecode` happily returns a double for `780000.0`. Rounding
/// rather than throwing keeps one malformed price from making the whole
/// catalog unreadable.
int _asInt(Object? raw) {
  if (raw is int) return raw;
  if (raw is double) return raw.isFinite ? raw.round() : 0;
  if (raw is String) return int.tryParse(raw.trim()) ?? 0;
  return 0;
}