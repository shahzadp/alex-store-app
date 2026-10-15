/// Fetches, caches and validates the store catalog.
///
/// The app reads exactly one file: `catalog.json` on the site. It cannot run
/// sql.js and never sees `catalog.sql` (CATALOG-GUIDE.md §8).
///
/// # Refresh policy
///
/// The catalog is small (~23 KB with vectors) and the app is a storefront for
/// a handful of products, so the simplest correct policy wins: fetch on every
/// launch, fall back to the last good copy from disk when offline, and show a
/// banner saying which is being used. No background polling, no diffing, no
/// cache-busting token to get wrong.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/catalog.dart';
import 'search_engine.dart';
import 'rust_search_engine.dart';

/// The storefront's own origin. The site's real pages, not the Pages root, so
/// a custom domain can be swapped in by changing this one constant.
///
/// This is also the host the app declares for deep links
/// (see `deep_link_service.dart`), so the browser link and the app handle the
/// same URLs.
const String kSiteUrl = 'https://shahzadp.github.io/store';

/// Where the catalog lives.
const String kCatalogUrl = '$kSiteUrl/catalog.json';

/// The canonical web address for a product — the site's `product.html`.
///
/// The link is the same URL the website itself uses, so a link copied from the
/// app opens the right page on the site and, on a device with the app, offers
/// the app as a target. `product.js` reads this same `?slug=` parameter.
String productPageUrl(String slug) => '$kSiteUrl/product.html?slug=$slug';

/// Outcome of a refresh.
enum CatalogSource { network, cache, none }

class CatalogState {
  const CatalogState({
    required this.catalog,
    required this.source,
    required this.isLoading,
    this.error,
  });

  final Catalog? catalog;

  /// Where the current catalog came from, so the UI can be honest about it.
  final CatalogSource source;

  final bool isLoading;
  final String? error;

  static const empty = CatalogState(
    catalog: null,
    source: CatalogSource.none,
    isLoading: false,
  );

  bool get hasCatalog => catalog != null;

  /// True when search can run: a catalog is loaded and fully indexed.
  bool get isSearchable => catalog?.isSearchable ?? false;
}

class CatalogService {
  CatalogService({
    SearchEngine? engine,
    this.url = kCatalogUrl,
    Future<String?> Function()? readCache,
    Future<void> Function(String)? writeCache,
    this.timeout = const Duration(seconds: 20),
  })  : engine = engine ?? RustSearchEngine(),
        _readCache = readCache,
        _writeCache = writeCache;

  final SearchEngine engine;
  final String url;
  final Duration timeout;

  final Future<String?> Function()? _readCache;
  final Future<void> Function(String)? _writeCache;

  CatalogState _state = CatalogState.empty;
  CatalogState get state => _state;

  final _controller = StreamController<CatalogState>.broadcast();
  Stream<CatalogState> get stream => _controller.stream;

  void _emit(CatalogState next) {
    _state = next;
    if (!_controller.isClosed) _controller.add(next);
  }

  /// Load the catalog and, if it is complete, load its vectors into the engine.
  ///
  /// Never throws: a failed refresh leaves whatever was already on screen, and
  /// reports the reason through [CatalogState.error].
  Future<CatalogState> load() async {
    _emit(CatalogState(
      catalog: _state.catalog,
      source: _state.source,
      isLoading: true,
    ));

    String? raw;
    var source = CatalogSource.none;

    try {
      raw = await _fetch(url);
      source = CatalogSource.network;
    } catch (networkError) {
      // Offline, DNS failure, 404, a captive portal serving HTML — all of
      // these land here. The cached copy is always better than an error page.
      raw = await _loadCache();
      if (raw == null) {
        _emit(CatalogState(
          catalog: null,
          source: CatalogSource.none,
          isLoading: false,
          error: 'Could not reach the store. Check your connection and try again.',
        ));
        return _state;
      }
      source = CatalogSource.cache;
    }

    final Catalog catalog;
    try {
      catalog = Catalog.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (e) {
      // A parse failure on a cached copy means it was written by an older
      // build with a different shape. Dropping it is correct; keeping it would
      // make every subsequent launch fail the same way.
      _emit(CatalogState(
        catalog: null,
        source: CatalogSource.none,
        isLoading: false,
        error: source == CatalogSource.cache
            ? 'The saved catalog could not be read. Reconnect to refresh.'
            : 'The store sent a catalog this app cannot read.',
      ));
      return _state;
    }

    await _writeCacheSafely(raw);

    // Only a well-formed catalog is worth showing. An empty product list is
    // not a valid storefront — it means a truncated or wrong file — and it
    // would render as a shop with nothing in it.
    if (catalog.products.isEmpty) {
      _emit(CatalogState(
        catalog: null,
        source: CatalogSource.none,
        isLoading: false,
        error: 'The store catalog came back empty.',
      ));
      return _state;
    }

    await _loadEngine(catalog);

    _emit(CatalogState(catalog: catalog, source: source, isLoading: false));
    return _state;
  }

  /// Push the catalog's vectors into the search engine.
  ///
  /// A failure here does not block the catalog — browsing and WhatsApp do not
  /// need search. It is recorded on the engine and surfaced by
  /// [Catalog.isSearchable].
  Future<void> _loadEngine(Catalog catalog) async {
    if (!catalog.isSearchable) {
      engine.clearIndex();
      return;
    }
    try {
      await engine.loadIndex(
        catalog.products
            .map((p) => (slug: p.slug, vector: p.vector!))
            .toList(growable: false),
        catalogModel: catalog.searchModel,
      );
    } on SearchException {
      engine.clearIndex();
    } catch (_) {
      engine.clearIndex();
    }
  }

  /// Run a semantic search and map the hits back to products.
  ///
  /// Slugs in the result that are not in the catalog are dropped rather than
  /// throwing: the index is loaded from the same file, so this should not
  /// happen, and a stale index is a display problem, not a crash.
  Future<List<(Product, double)>> search(String query, {int limit = 10}) async {
    final catalog = _state.catalog;
    if (catalog == null) return const [];

    final trimmed = query.trim();
    if (trimmed.isEmpty) return const [];

    if (!catalog.isSearchable) {
      throw SearchException(
        SearchProblem.incompleteIndex,
        'catalog is missing vectors for: ${catalog.unindexedSlugs.join(', ')}',
      );
    }

    final hits = await engine.search(trimmed, limit: limit);

    final out = <(Product, double)>[];
    for (final hit in hits) {
      final product = catalog.bySlug(hit.slug);
      if (product != null) out.add((product, hit.score));
    }
    return out;
  }

  // ── transport ─────────────────────────────────────────────────────────────

  Future<String> _fetch(String target) async {
    final client = HttpClient()
      ..connectionTimeout = timeout
      ..userAgent = 'AlexStoreApp/1.0 (+flutter)';

    try {
      final request = await client.getUrl(Uri.parse(target));
      final response = await request.close().timeout(timeout);

      if (response.statusCode != 200) {
        throw HttpException('catalog.json returned HTTP ${response.statusCode}', uri: Uri.parse(target));
      }

      final body = await response.transform(utf8.decoder).join();
      if (body.isEmpty) throw HttpException('catalog.json was empty');

      // Cached aggressively: the file is versioned by the site's own cache
      // headers, and re-fetching 23 KB on every cold start is not worth the
      // bytes. The failure path above still handles a stale file.
      return body;
    } finally {
      client.close(force: true);
    }
  }

  Future<String?> _loadCache() async {
    if (_readCache == null) return null;
    try {
      return await _readCache();
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeCacheSafely(String raw) async {
    if (_writeCache == null) return;
    try {
      await _writeCache(raw);
    } catch (_) {
      // A read-only or full filesystem must not stop the app from working.
    }
  }

  void dispose() => _controller.close();
}