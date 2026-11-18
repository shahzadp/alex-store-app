// Saved for later and recently viewed — the app's two on-device lists.
//
// Two seams are exercised:
//   1. The stores themselves, with a temporary directory in place of the
//      app-support directory — the same seam VoucherStore uses.
//   2. The saved flow end to end: MainShell → Shop tab → heart on a card →
//      Saved tab → the product is there → unsave → empty state returns.
//
// The widgets are pumped inside a real CatalogScope fed a real CatalogService
// with only the HTTP transport replaced — the same seam the delivery and
// description tests use — so what runs is the production path from JSON to
// pixels, minus the network.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:alex_store/src/catalog_scope.dart';
import 'package:alex_store/src/screens/main_shell.dart';
import 'package:alex_store/src/services/catalog_service.dart';
import 'package:alex_store/src/services/local_stores.dart';
import 'package:alex_store/src/services/search_engine.dart';
import 'package:alex_store/src/store_scope.dart';
import 'package:alex_store/src/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Minimal stand-in for the native engine; these tests never search.
class _FakeEngine implements SearchEngine {
  @override
  String get model => 'ternlight/base@0.1.1';

  @override
  bool get isReady => false;

  @override
  Future<void> warmUp() async {}

  @override
  Future<void> loadIndex(
    List<ProductVector> products, {
    required String catalogModel,
  }) async {}

  @override
  Future<List<SearchHit>> search(String query, {int limit = 10}) async =>
      const [];

  @override
  void clearIndex() {}
}

String catalogJson() {
  Map<String, Object?> product(
    String slug,
    String name,
    String category,
    int price,
  ) =>
      {
        'slug': slug,
        'name': name,
        'category': category,
        'price_cents': price,
        'in_stock': true,
        'description': 'Glazed stoneware.',
        'details': '',
        'specs': <String, String>{},
        'options': <dynamic>[],
        'image_url': null,
        'tint': '#D9CCEA',
        'vector': base64Encode(Float32List(384).buffer.asUint8List()),
      };

  return jsonEncode({
    'generated_at': '2026-11-18T00:00:00.000Z',
    'store': {
      'name': 'Alex Store',
      'whatsapp': '923288304524',
      'free_delivery_over_paisa': 600000,
      'currency': 'PKR',
    },
    'products': [
      product('stoneware-mug', 'Stoneware Mug', 'Kitchen', 780000),
      product('linen-throw', 'Linen Throw', 'Textiles', 1250000),
    ],
    'collections': <dynamic>[],
    'search_model': 'ternlight/base@0.1.1',
  });
}

Future<CatalogService> loadedCatalog() async {
  final service = CatalogService(
    engine: _FakeEngine(),
    url: 'https://example.test/catalog.json',
    readCache: () async => null,
    writeCache: (_) async {},
    fetcher: (_, __) async => catalogJson(),
  );
  await service.load();
  addTearDown(service.dispose);
  return service;
}

void main() {
  group('SavedStore', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('alex-saved-');
    });

    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test('a fresh install saves nothing', () async {
      final store = SavedStore(directory: () async => dir);
      await store.load();
      expect(store.state, isEmpty);
    });

    test('toggle saves then removes, newest first', () async {
      final store = SavedStore(directory: () async => dir);

      await store.toggle('stoneware-mug');
      await store.toggle('linen-throw');
      expect(store.state, ['linen-throw', 'stoneware-mug']);

      await store.toggle('stoneware-mug');
      expect(store.state, ['linen-throw']);
    });

    test('the list persists across instances', () async {
      await SavedStore(directory: () async => dir).toggle('stoneware-mug');

      final reopened = SavedStore(directory: () async => dir);
      await reopened.load();
      expect(reopened.state, ['stoneware-mug']);
    });

    test('clear() empties the list', () async {
      final store = SavedStore(directory: () async => dir);
      await store.toggle('stoneware-mug');
      await store.toggle('linen-throw');
      await store.clear();
      expect(store.state, isEmpty);
    });

    test('a corrupt file reads as an empty list rather than throwing',
        () async {
      await File('${dir.path}/saved.v1.json').writeAsString('{not json');
      final store = SavedStore(directory: () async => dir);
      await store.load();
      expect(store.state, isEmpty);
    });

    test('an unwritable location does not throw on toggle', () async {
      final store = SavedStore(
        directory: () async => throw const FileSystemException('no plugin'),
      );
      await store.toggle('stoneware-mug');
      expect(store.state, ['stoneware-mug']);
    });
  });

  group('RecentStore', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('alex-recent-');
    });

    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test('records most-recent first and dedupes', () async {
      final store = RecentStore(directory: () async => dir);

      await store.record('a');
      await store.record('b');
      await store.record('a');
      expect(store.state, ['a', 'b']);
    });

    test('keeps at most six entries', () async {
      final store = RecentStore(directory: () async => dir);
      for (final slug in ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h']) {
        await store.record(slug);
      }
      expect(store.state, ['h', 'g', 'f', 'e', 'd', 'c']);
    });
  });

  group('The saved flow', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('alex-saved-flow-');
    });

    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    testWidgets('save from the grid, find it under Saved, then empty',
        (tester) async {
      final saved = SavedStore(directory: () async => dir);
      final recent = RecentStore(directory: () async => dir);
      final catalog = await loadedCatalog();

      // The store writes real files, so the whole scenario runs in runAsync,
      // where real I/O completes. The other groups cover the on-disk shapes.
      await tester.runAsync(() async {
        await tester.pumpWidget(MaterialApp(
          theme: StoreTheme.light(),
          home: StoreScope(
            saved: saved,
            recent: recent,
            child: CatalogScope(service: catalog, child: const MainShell()),
          ),
        ));
        await tester.pumpAndSettle();

        // Starts on Home; the Saved tab is one tap away.
        await tester.tap(find.widgetWithText(NavigationDestination, 'Saved'));
        await tester.pumpAndSettle();
        expect(find.text('Nothing saved yet'), findsOneWidget);

        // Browse products takes the shopper to the Shop tab.
        await tester.tap(find.text('Browse products'));
        await tester.pumpAndSettle();

        // Save the mug from the grid. The toggle writes a real file, so
        // after the tap the test yields to the real event loop for a beat,
        // then settles so the stream emission rebuilds the grid.
        await tester.tap(find.bySemanticsLabel('Save Stoneware Mug for later'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pumpAndSettle();

        // The Saved tab shows it.
        await tester.tap(find.widgetWithText(NavigationDestination, 'Saved'));
        await tester.pumpAndSettle();
        expect(find.text('Stoneware Mug'), findsWidgets);

        // Unsave it there; the empty state returns.
        await tester.tap(
          find.bySemanticsLabel('Remove Stoneware Mug from saved').first,
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pumpAndSettle();
        expect(find.text('Nothing saved yet'), findsOneWidget);
      });
    });
  });
}
