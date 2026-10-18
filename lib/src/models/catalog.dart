/// Catalog domain model.
///
/// Mirrors the shape of the site's `catalog.json`, which is the only file the
/// app can read — it cannot run sql.js and never parses `catalog.sql`.
/// See CATALOG-GUIDE.md §8.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'price.dart';

/// The free-delivery offer, as a claimable voucher.
///
/// Replaces the old top strip: the offer is still the same benefit, but it is
/// announced once (see `voucher_prompt.dart`) rather than pinned above every
/// screen. The wording lives in the catalog, so the app and the site cannot
/// drift apart on what the voucher says.
class Voucher {
  const Voucher({
    required this.title,
    required this.code,
    required this.description,
    required this.terms,
  });

  final String title;
  final String code;
  final String description;
  final String terms;

  /// True when there is nothing worth announcing.
  bool get isEmpty => title.isEmpty;

  static const Voucher none =
      Voucher(title: '', code: '', description: '', terms: '');

  factory Voucher.fromJson(Map<String, dynamic> json) {
    return Voucher(
      title: (json['title'] as String?)?.trim() ?? '',
      code: (json['code'] as String?)?.trim() ?? '',
      description: (json['description'] as String?)?.trim() ?? '',
      terms: (json['terms'] as String?)?.trim() ?? '',
    );
  }
}

/// The store's settings block.
class Store {
  const Store({
    required this.name,
    required this.whatsapp,
    required this.freeDeliveryOver,
    required this.deliveryPercent,
    required this.deliveryPercentLow,
    required this.deliveryThresholdPaisa,
    required this.voucher,
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

  /// Delivery, as a percentage of the order (`settings.delivery_percent`).
  /// Zero means the catalog carries no delivery pricing and no struck-through
  /// figure is shown anywhere.
  final int deliveryPercent;

  /// Delivery percentage applied to prices below [deliveryThresholdPaisa].
  final int deliveryPercentLow;

  /// Price (in paisa) below which [deliveryPercentLow] applies instead of
  /// [deliveryPercent]. 1000 Rs by default.
  final int deliveryThresholdPaisa;

  /// The claimable free-delivery offer. [Voucher.isEmpty] when unset.
  final Voucher voucher;

  /// Always `PKR`. There is no currency selector and no USD anywhere in this
  /// store; the field exists only so the app can assert that rather than
  /// assume it.
  final String currency;

  /// What delivery would add to [price], or null when no percentage is set.
  Price? deliveryIncluded(Price price) {
    final pct = price.paisa < deliveryThresholdPaisa
        ? deliveryPercentLow
        : deliveryPercent;
    return pct > 0 ? price.plusPercent(pct) : null;
  }

  static const Store empty = Store(
    name: 'Alex Store',
    whatsapp: '',
    freeDeliveryOver: Price.zero,
    deliveryPercent: 0,
    deliveryPercentLow: 0,
    deliveryThresholdPaisa: 100000,
    voucher: Voucher.none,
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
      deliveryPercent: _asInt(json['delivery_percent']),
      deliveryPercentLow: _asInt(json['delivery_percent_low']),
      deliveryThresholdPaisa: _asInt(json['delivery_threshold_paisa']) == 0
          ? 100000
          : _asInt(json['delivery_threshold_paisa']),
      voucher: Voucher.fromJson(
        (json['voucher'] as Map?)?.cast<String, dynamic>() ?? const {},
      ),
      currency: (json['currency'] as String?) ?? 'PKR',
    );
  }
}

/// A selectable add-on on a product, such as "Cold drink (500ml)".
///
/// A preference, not a price: [price] is an optional surcharge stated in the
/// WhatsApp order message so the shop knows what to pack and what it costs, but
/// the price shown on the page never changes with the choice — the same rule the
/// site follows. [key] is the stable identifier (derived from the label by the
/// site), [label] is what the shopper reads, and [desc] is optional detail, such
/// as the bottle size.
class ProductOption {
  const ProductOption({
    required this.key,
    required this.label,
    this.desc = '',
    this.price = Price.zero,
  });

  final String key;
  final String label;

  /// Optional detail beside the label, e.g. "500ml".
  final String desc;

  /// Optional surcharge. Stated in the order message and never added to the
  /// price shown on screen.
  final Price price;

  /// The whole phrase for a message line: "Cold drink (500ml)".
  String get named => desc.isEmpty ? label : '$label ($desc)';
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
    required this.options,
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

  /// Selectable add-ons, in the catalog's order. Empty for most products.
  final List<ProductOption> options;

  final String? imageUrl;
  final String? tint;

  /// The precomputed ternlight embedding, decoded from base64. Null when the
  /// catalog is not fully indexed — see [Catalog.isSearchable].
  final Float32List? vector;

  /// The WhatsApp message, pre-written exactly as the site builds it in
  /// `common.js:productLink`, so the shopkeeper does not have to reconstruct
  /// what is being asked about.
  ///
  /// Returns PLAIN TEXT. It must not be URL-encoded here: `whatsappLink`
  /// encodes the message, and encoding twice produces `%250A` for a newline,
  /// which WhatsApp then renders literally as "%0A" instead of a line break.
  /// Encoding belongs in exactly one place.
  ///
  /// [storeName] is interpolated the way the site does ("Hi Alex Store! ...").
  ///
  /// [selectedOptions] is the set of chosen add-on keys. Every option is stated
  /// either way — "Cold drink (500ml): yes" or "... : no" — so an unticked box
  /// is an explicit answer rather than a silence, matching
  /// `common.js:productLink`. A chosen option that carries a surcharge also
  /// states it, "(+ Rs 100)", on that line rather than in the price above: the
  /// price shown on the page never changes with a choice.
  ///
  /// Note what is NOT here: the long [details] copy. The site deliberately
  /// keeps this to a few lines — "only ask about the detail if there is any,
  /// and keep it to one extra line" — and an order message long enough to
  /// scroll is one the shopkeeper will not read.
  String whatsappMessage(String storeName, {Set<String> selectedOptions = const {}}) {
    final lines = <String>[
      "Hi $storeName! I'd like to order:",
      '',
      '*$name*',
      // The site uses an em dash here (`common.js:productLink`); the app mirrors
      // it character for character so the shop reads one format.
      '$category — ${price.formatted}',
    ];
    if (description.isNotEmpty) lines.add(description);
    for (final option in options) {
      if (option.label.isEmpty) continue;
      final chosen = selectedOptions.contains(option.key);
      if (chosen && option.price.paisa > 0) {
        lines.add('${option.named}: yes (+ ${option.price.formatted})');
      } else {
        lines.add('${option.named}: ${chosen ? 'yes' : 'no'}');
      }
    }
    lines
      ..add('')
      ..add('Is it available?');
    return lines.join('\n');
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
      options: _asOptions(json['options']),
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

  /// Selectable add-ons from `catalog.json`, in order.
  ///
  /// Anything without both a key and a label is dropped: a half-filled row
  /// would render a checkbox that cannot be matched back to an answer.
  static List<ProductOption> _asOptions(Object? raw) {
    if (raw is! List) return const [];
    final out = <ProductOption>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final key = (item['key'] as String?)?.trim() ?? '';
      final label = (item['label'] as String?)?.trim() ?? '';
      if (key.isEmpty || label.isEmpty) continue;
      out.add(ProductOption(
        key: key,
        label: label,
        desc: (item['desc'] as String?)?.trim() ?? '',
        price: Price.paisa(_asInt(item['price_cents'])),
      ));
    }
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