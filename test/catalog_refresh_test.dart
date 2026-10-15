// Pull-to-refresh must actually pull a NEW catalog in.
//
// The point of the feature is that a shopper can see a catalog published after
// they installed the app, without an app update. So a refresh has to refetch,
// reparse, and RELOAD the vectors into the engine — not just re-render what is
// already in memory.
//
// This drives the real CatalogService, with only the HTTP transport replaced.
// Everything else — parsing, validation, cache write, index load — is the
// production code, which is what makes the test worth running.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:alex_store/src/services/catalog_service.dart';
import 'package:alex_store/src/services/search_engine.dart';
import 'package:flutter_test/flutter_test.dart';

/// Minimal stand-in for the native engine. Counts index loads, because "the
/// vectors were reloaded" is the assertion that actually matters.
class _RecordingEngine implements SearchEngine {
  int indexLoads = 0;
  List<String>? lastSlugs;

  @override
  String get model => 'ternlight/base@0.1.1';

  @override
  bool get isReady => lastSlugs != null && lastSlugs!.isNotEmpty;

  @override
  Future<void> warmUp() async {}

  @override
  Future<void> loadIndex(
    List<ProductVector> products, {
    required String catalogModel,
  }) async {
    indexLoads++;
    lastSlugs = products.map((p) => p.slug).toList(growable: false);
  }

  @override
  Future<List<SearchHit>> search(String query, {int limit = 10}) async =>
      const [];

  @override
  void clearIndex() => lastSlugs = null;
}

String catalogJsonWith(List<String> slugs) => jsonEncode({
      'generated_at': '2026-10-16T00:00:00.000Z',
      'store': {
        'name': 'Alex Store',
        'whatsapp': '923288304524',
        'free_delivery_over_paisa': 600000,
        'currency': 'PKR',
      },
      'products': [
        for (final slug in slugs)
          {
            'slug': slug,
            'name': slug,
            'category': 'Kitchen',
            'price_cents': 780000,
            'in_stock': true,
            'description': 'A $slug.',
            'details': '',
            'specs': <String, String>{},
            'image_url': null,
            'tint': '#D9CCEA',
            'vector': base64Encode(Float32List(384).buffer.asUint8List()),
          },
      ],
      'collections': <dynamic>[],
      'search_model': 'ternlight/base@0.1.1',
    });

void main() {
  test('a newly published product arrives on refresh, with its vector', () async {
    final engine = _RecordingEngine();
    var calls = 0;

    final service = CatalogService(
      engine: engine,
      url: 'https://example.test/catalog.json',
      readCache: () async => null,
      writeCache: (_) async {},
      fetcher: (url, timeout) async {
        calls++;
        // First fetch is the catalog the app shipped with; second is what the
        // shop published afterwards.
        return calls == 1
            ? catalogJsonWith(['mug'])
            : catalogJsonWith(['mug', 'brass-tray']);
      },
    );

    final first = await service.load();
    expect(first.hasCatalog, isTrue);
    expect(first.catalog!.products, hasLength(1));
    expect(engine.indexLoads, 1);

    // Refresh: the new product must be visible AND searchable.
    final second = await service.load();
    expect(second.catalog!.products, hasLength(2));
    expect(second.catalog!.bySlug('brass-tray'), isNotNull);
    expect(second.isSearchable, isTrue,
        reason: 'search must work with the newly added product');

    // The engine has to be reloaded, not just the model layer.
    expect(engine.indexLoads, 2);
    expect(engine.lastSlugs, containsAll(['mug', 'brass-tray']));
  });

  test('a failing refresh keeps the current catalog on screen', () async {
    final engine = _RecordingEngine();
    var calls = 0;

    final service = CatalogService(
      engine: engine,
      url: 'https://example.test/catalog.json',
      readCache: () async => null,
      writeCache: (_) async {},
      fetcher: (url, timeout) async {
        calls++;
        if (calls == 1) return catalogJsonWith(['mug']);
        throw const HttpException('network down');
      },
    );

    final first = await service.load();
    expect(first.catalog!.products, hasLength(1));

    final second = await service.load();
    expect(second.catalog, isNotNull,
        reason: 'a failed refresh must not blank the storefront');
    expect(second.catalog!.products, hasLength(1));
    // The index survives, so search keeps working.
    expect(engine.lastSlugs, ['mug']);
  });

  test('an unreachable first launch says so rather than showing an empty shop',
      () async {
    final service = CatalogService(
      engine: _RecordingEngine(),
      url: 'https://example.test/catalog.json',
      readCache: () async => null,
      writeCache: (_) async {},
      fetcher: (url, timeout) async => throw const HttpException('offline'),
    );

    final state = await service.load();
    expect(state.catalog, isNull);
    expect(state.isSearchable, isFalse);
    expect(state.error, isNotNull);
  });
}