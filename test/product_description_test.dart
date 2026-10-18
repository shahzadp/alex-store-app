// The "Full description" box grows with its copy instead of scrolling inside a
// fixed height.
//
// It used to be clamped (260px here, `max-height: min(42vh, 340px)` on the
// site) with its own scrollbar, so the end of a long write-up was hidden until
// the shopper scrolled a second, nested region. The page is the only thing that
// should scroll. This is the regression guard for that: a capped box brought
// back as an inner scroll view fails here.
//
// Pumped through a real CatalogScope and a real CatalogService with only the
// HTTP transport swapped, the same seam delivery_options_test uses.
import 'dart:convert';
import 'dart:typed_data';

import 'package:alex_store/src/catalog_scope.dart';
import 'package:alex_store/src/screens/product_screen.dart';
import 'package:alex_store/src/services/catalog_service.dart';
import 'package:alex_store/src/services/search_engine.dart';
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

/// A write-up comfortably taller than the 260px the box used to be capped at,
/// so a capped box would hide part of it behind a scrollbar rather than show it.
final String longDetails = List.generate(
  40,
  (i) => 'Paragraph ${i + 1}: the long-form copy for this product, written to '
      'run well past a single screen so the layout has to grow.',
).join(' ');

String catalogJson() {
  return jsonEncode({
    'generated_at': '2026-10-18T00:00:00.000Z',
    'store': {
      'name': 'Alex Store',
      'whatsapp': '923288304524',
      'free_delivery_over_paisa': 600000,
      'delivery_percent': 10,
      'currency': 'PKR',
    },
    'products': [
      {
        'slug': 'stoneware-mug',
        'name': 'Stoneware Mug',
        'category': 'Kitchen',
        'price_cents': 780000,
        'in_stock': true,
        'description': 'Glazed stoneware.',
        'details': longDetails,
        'specs': <String, String>{},
        'options': const <Object>[],
        'image_url': null,
        'tint': '#D9CCEA',
        'vector': base64Encode(Float32List(384).buffer.asUint8List()),
      },
    ],
    'collections': <dynamic>[],
    'search_model': 'ternlight/base@0.1.1',
  });
}

/// A loaded service reading [raw] instead of the network.
Future<CatalogService> loaded(String raw) async {
  final service = CatalogService(
    engine: _FakeEngine(),
    url: 'https://example.test/catalog.json',
    readCache: () async => null,
    writeCache: (_) async {},
    fetcher: (_, __) async => raw,
  );
  await service.load();
  addTearDown(service.dispose);
  return service;
}

/// The product page is a `ListView`, so its lower children are only built once
/// they are within the cache extent. A tall viewport keeps the whole page in the
/// tree so a finder can see it.
void useTallView(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 4000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('the full description grows rather than scrolling on its own',
      (tester) async {
    useTallView(tester);
    final service = await loaded(catalogJson());

    await tester.pumpWidget(CatalogScope(
      service: service,
      child: MaterialApp(
        theme: StoreTheme.light(),
        home: const ProductScreen(slug: 'stoneware-mug'),
      ),
    ));
    await tester.pumpAndSettle();

    final desc = find.textContaining('Paragraph 40:');
    expect(desc, findsOneWidget, reason: 'the whole write-up is rendered');

    // Nothing on the page scrolls on its own. The capped box used to be a
    // `SingleChildScrollView`, so bringing that back fails here.
    expect(find.byType(SingleChildScrollView), findsNothing);

    // And the copy is genuinely laid out taller than the cap it used to have,
    // so "it grew" is the reason the assertion above can pass.
    expect(tester.getSize(desc).height, greaterThan(260));
  });
}
