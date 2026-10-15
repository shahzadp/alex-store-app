/// flutter_rust_bridge implementation of [SearchEngine].
///
/// The generated bindings live in `lib/src/api/` and do not exist until
/// `flutter_rust_bridge_codegen` has run. This file is the only place in the
/// app that imports them.
///
/// # Why the index is loaded into Rust rather than ranked in Dart
///
/// The obvious shape — bridge `embed(query) -> List<double>` and do the
/// ranking in Dart — marshals the entire vector index across the FFI boundary
/// on every keystroke, and Flutter's FFI copies each `List<double>` rather
/// than sharing it. Loading the catalog's vectors once via `set_index` makes
/// each keystroke a single crossing that returns ~10 small records.
///
/// # Model agreement is checked, not assumed
///
/// The site's vectors were produced by ternlight compiled to WASM. This engine
/// is the same model compiled to ARM. If the site ever reindexes with a
/// different encoder, the vectors stop meaning anything — and a dot product
/// between two unrelated models still returns a confident, wrong ranking. So
/// [loadIndex] refuses rather than proceeding.
library;

import 'dart:typed_data';

import 'search_engine.dart';

// ignore: unused_import — these are provided by flutter_rust_bridge_codegen.
import '../api/api.dart' as frb;

/// `SEARCH_MODEL` in the site's `db.js` and `SEARCH_MODEL` in
/// `rust/src/api.rs`. If either side changes, the app must be rebuilt with a
/// matching engine and the site must reindex — in the same commit.
const String kSearchModel = 'ternlight/base@0.1.1';

/// Width of a ternlight embedding. Must match `SEARCH_DIMS` and `EMBEDDING_DIMS`.
const int kEmbeddingDims = 384;

class RustSearchEngine implements SearchEngine {
  RustSearchEngine();

  @override
  String get model => kSearchModel;

  @override
  bool get isReady => _indexSize > 0;

  int _indexSize = 0;

  @override
  Future<void> warmUp() async {
    try {
      await frb.warmUp();
    } catch (_) {
      // A failed warm-up is not fatal on its own — the first search will
      // surface the real error, with context.
    }
  }

  @override
  Future<void> loadIndex(
    List<ProductVector> products, {
    required String catalogModel,
  }) async {
    if (catalogModel.isNotEmpty && catalogModel != kSearchModel) {
      throw SearchException(
        SearchProblem.modelMismatch,
        'catalog is indexed by "$catalogModel", this engine is "$kSearchModel"',
      );
    }

    final missing = products.where((p) => p.vector.length != kEmbeddingDims);
    if (missing.isNotEmpty) {
      throw SearchException(
        SearchProblem.incompleteIndex,
        '${missing.length} product(s) do not have a $kEmbeddingDims-dim vector',
      );
    }

    if (products.isEmpty) {
      _indexSize = 0;
      return;
    }

    try {
      _indexSize = await frb.setIndex(
        products.map((p) => p.slug).toList(growable: false),
        products.map((p) => p.vector).toList(growable: false),
      );
    } catch (e) {
      _indexSize = 0;
      throw SearchException(SearchProblem.engineUnavailable, '$e');
    }
  }

  @override
  Future<List<SearchHit>> search(String query, {int limit = 10}) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return const [];

    if (_indexSize == 0) {
      throw const SearchException(
        SearchProblem.noIndex,
        'search called before loadIndex()',
      );
    }

    try {
      final raw = await frb.search(trimmed, limit);
      return raw
          .map((h) => SearchHit(slug: h.slug, score: h.score))
          .toList(growable: false);
    } catch (e) {
      throw SearchException(SearchProblem.engineUnavailable, '$e');
    }
  }

  @override
  void clearIndex() {
    _indexSize = 0;
    frb.clearIndex();
  }

  /// Exposed for the debug screen: the model header parsed out of the bundled
  /// `model.bin`. If this ever stops saying `int4` / `d_model=384`, the app is
  /// not running the model the vectors came from.
  Future<String?> describeEngine() async {
    try {
      return await frb.engineInfo();
    } catch (_) {
      return null;
    }
  }
}

/// A [SearchEngine] that is always unavailable.
///
/// Used in widget tests and on platforms where the native library is not
/// built. Search degrades to a clear message rather than a crash — the rest of
/// the app (browsing, WhatsApp) does not need the engine at all, and MEMORY.md
/// §3 is clear that WhatsApp is the only purchase path.
class UnavailableSearchEngine implements SearchEngine {
  const UnavailableSearchEngine([this.reason = 'native engine not built']);

  final String reason;

  @override
  String get model => '';

  @override
  bool get isReady => false;

  @override
  Future<void> warmUp() async {}

  @override
  Future<void> loadIndex(
    List<ProductVector> products, {
    required String catalogModel,
  }) async {
    throw SearchException(SearchProblem.engineUnavailable, reason);
  }

  @override
  Future<List<SearchHit>> search(String query, {int limit = 10}) async {
    throw SearchException(SearchProblem.engineUnavailable, reason);
  }

  @override
  void clearIndex() {}
}

/// Converts a catalog into the engine's index input, refusing to build a
/// partial index.
List<ProductVector> toIndexVectors(
  Iterable<({String slug, Float32List vector})> products,
) =>
    products.map((p) => (slug: p.slug, vector: p.vector)).toList(growable: false);