/// The interface the app talks to, independent of how the vectors are
/// computed.
///
/// The only production implementation is `RustSearchEngine`, which calls into
/// the native ternlight engine over flutter_rust_bridge. Keeping this abstract
/// means the UI, the tests and the catalog plumbing never import generated
/// bindings, so `flutter test` runs without a native build and without the
/// codegen step.
library;

import 'dart:typed_data';

/// A ranked search result.
class SearchHit {
  const SearchHit({required this.slug, required this.score});

  final String slug;

  /// Cosine similarity, 1.0 = identical. ternlight's vectors are
  /// L2-normalised so the dot product *is* the cosine.
  final double score;
}

/// A product's precomputed embedding.
typedef ProductVector = ({String slug, Float32List vector});

/// Why a search could not run. Distinct from "no results" — the two look
/// identical on screen, and MEMORY.md §4 is largely about that confusion.
enum SearchProblem {
  /// No index has been loaded yet.
  noIndex,

  /// The catalog is missing vectors for at least one product. Searching would
  /// rank against an incomplete index, which silently returns nothing.
  incompleteIndex,

  /// The catalog's vectors were built by a different encoder than the engine
  /// compiled into this app. Every score would be meaningless and every result
  /// would look plausible.
  modelMismatch,

  /// The native library failed to load, or the engine refused the input.
  engineUnavailable,

  /// No product carries a vector, or the query was blank.
  empty,
}

class SearchException implements Exception {
  const SearchException(this.problem, this.message);

  final SearchProblem problem;
  final String message;

  /// Text safe to show a shopper.
  String get userMessage => switch (problem) {
    SearchProblem.noIndex => 'Search is still starting up.',
    SearchProblem.incompleteIndex =>
      'Search is unavailable right now — the store catalog is being reindexed.',
    SearchProblem.modelMismatch =>
      'Search is unavailable: the app and the store use different search models.',
    SearchProblem.engineUnavailable =>
      'Search is unavailable on this device.',
    SearchProblem.empty => 'Type something to search.',
  };

  @override
  String toString() => 'SearchException($problem): $message';
}

/// Computes semantic similarity between a query and a set of products.
abstract class SearchEngine {
  /// The `SEARCH_MODEL` string this engine was built against. Must equal the
  /// catalog's `search_model` or every comparison is between two different
  /// models.
  String get model;

  /// Whether the native engine has loaded and can answer queries.
  bool get isReady;

  /// Force the model and tokenizer to initialise. Idempotent.
  Future<void> warmUp();

  /// Load the product vectors. Replaces whatever was loaded before.
  ///
  /// Throws [SearchException] with [SearchProblem.incompleteIndex] if any
  /// product has no vector, and [SearchProblem.modelMismatch] if the catalog
  /// was indexed by a different encoder.
  Future<void> loadIndex(List<ProductVector> products, {required String catalogModel});

  /// Rank products against `query`, best first, at most [limit] results.
  Future<List<SearchHit>> search(String query, {int limit = 10});

  /// Drop the loaded index.
  void clearIndex();
}