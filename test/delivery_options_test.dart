// The delivery-included figure and the add-on options, end to end through the
// model layer and the widgets that render them.
//
// Two claims are kept honest here:
//   1. The struck-through figure is the price with delivery added, and the main
//      price never moves. A catalog that sets no `delivery_percent` renders
//      exactly as it always did.
//   2. Add-ons are a preference, not a price: they ride in the WhatsApp message
//      and never touch the total.
//
// The widgets are pumped inside a real CatalogScope fed a real CatalogService,
// with only the HTTP transport replaced — the same seam `catalog_refresh_test`
// uses — so what is exercised is the production path from JSON to pixels.
import 'dart:convert';
import 'dart:typed_data';

import 'package:alex_store/src/catalog_scope.dart';
import 'package:alex_store/src/models/catalog.dart';
import 'package:alex_store/src/models/price.dart';
import 'package:alex_store/src/screens/product_screen.dart';
import 'package:alex_store/src/services/catalog_service.dart';
import 'package:alex_store/src/services/search_engine.dart';
import 'package:alex_store/src/theme.dart';
import 'package:alex_store/src/widgets/product_card.dart';
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

/// A one-product catalog, with the delivery and option settings parameterised.
String catalogJson({
  int deliveryPercent = 10,
  List<Map<String, Object?>> options = const [],
}) {
  return jsonEncode({
    'generated_at': '2026-10-18T00:00:00.000Z',
    'store': {
      'name': 'Alex Store',
      'whatsapp': '923288304524',
      'free_delivery_over_paisa': 600000,
      'delivery_percent': deliveryPercent,
      'voucher': {
        'title': 'Free delivery over Rs 6,000',
        'code': 'FREEDELIVERY',
        'description': 'Claim it and delivery is on us.',
        'terms': 'Orders over Rs 6,000.',
      },
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
        'details': '',
        'specs': <String, String>{},
        'options': options,
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

/// Every Text widget's visible string, so a value inside a Text.rich span — the
/// price row on a card — is still findable.
String visibleText(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .map((w) => w.data ?? w.textSpan?.toPlainText() ?? '')
    .join(' | ');

/// The product page is a `ListView`, so its lower children are only built once
/// they are within the cache extent. A tall viewport keeps the whole page —
/// add-ons included — in the tree so a finder can see it.
void useTallView(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 3200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void main() {
  group('Price.plusPercent', () {
    test('adds the percentage in whole paisa', () {
      expect(const Price.paisa(780000).plusPercent(10),
          const Price.paisa(858000));
      expect(const Price.paisa(100).plusPercent(10), const Price.paisa(110));
    });

    test('rounds to the nearest paisa rather than truncating', () {
      // 10015 * 1.10 = 11016.5 paisa, which must land on 11017.
      expect(const Price.paisa(10015).plusPercent(10),
          const Price.paisa(11017));
    });

    test('zero percent is the price itself', () {
      expect(const Price.paisa(780000).plusPercent(0),
          const Price.paisa(780000));
    });
  });

  group('Store delivery settings', () {
    test('reads delivery_percent and the voucher from the catalog block', () {
      final store = Store.fromJson({
        'name': 'Alex Store',
        'whatsapp': '923288304524',
        'free_delivery_over_paisa': 600000,
        'delivery_percent': 10,
        'voucher': {
          'title': 'Free delivery over Rs 6,000',
          'code': 'FREEDELIVERY',
          'description': 'd',
          'terms': 't',
        },
      });
      expect(store.deliveryPercent, 10);
      expect(store.voucher.title, 'Free delivery over Rs 6,000');
      expect(store.voucher.code, 'FREEDELIVERY');
      expect(store.voucher.isEmpty, isFalse);
    });

    test('an absent delivery block means no delivery pricing at all', () {
      final store = Store.fromJson({'name': 'Alex Store'});
      expect(store.deliveryPercent, 0);
      expect(store.voucher.isEmpty, isTrue);
      expect(store.deliveryIncluded(const Price.paisa(780000)), isNull);
    });
  });

  group('add-ons in the WhatsApp message', () {
    /// A plain add-on: no size, no surcharge.
    final plain = Product.fromJson({
      'slug': 'french-fries',
      'name': 'French Fries',
      'category': 'Food & Drinks',
      'price_cents': 35000,
      'in_stock': true,
      'description': 'Crisp, salted.',
      'details': '',
      'specs': <String, String>{},
      'options': [
        {'key': 'cold-drink', 'label': 'Cold drink'},
      ],
    });

    /// The catalog's real shape: a size and a Rs 100 surcharge.
    final sized = Product.fromJson({
      'slug': 'french-fries',
      'name': 'French Fries',
      'category': 'Food & Drinks',
      'price_cents': 35000,
      'in_stock': true,
      'description': 'Crisp, salted.',
      'details': '',
      'specs': <String, String>{},
      'options': [
        {
          'key': 'cold-drink',
          'label': 'Cold drink',
          'desc': '500ml',
          'price_cents': 10000,
        },
      ],
    });

    test('a plain option is stated "no" when it is not chosen', () {
      expect(plain.whatsappMessage('Alex Store'), contains('Cold drink: no'));
    });

    test('a plain option is stated "yes" when it is chosen', () {
      final message =
          plain.whatsappMessage('Alex Store', selectedOptions: {'cold-drink'});
      expect(message, contains('Cold drink: yes'));
    });

    test('a sized option carries its size on the line', () {
      expect(sized.whatsappMessage('Alex Store'),
          contains('Cold drink (500ml): no'));
    });

    test('a chosen option states its surcharge, not the page price', () {
      final message =
          sized.whatsappMessage('Alex Store', selectedOptions: {'cold-drink'});
      expect(message, contains('Cold drink (500ml): yes (+ Rs 100)'));
      // The price line above is untouched — the surcharge rides on the option.
      expect(message, contains('Food & Drinks — Rs 350'));
    });

    test('the price line never absorbs a surcharge', () {
      expect(sized.whatsappMessage('Alex Store'), contains('Rs 350'));
      expect(sized.whatsappMessage('Alex Store'), isNot(contains('Rs 450')));
    });

    test('desc and surcharge are read from the catalog', () {
      final option = sized.options.single;
      expect(option.key, 'cold-drink');
      expect(option.label, 'Cold drink');
      expect(option.desc, '500ml');
      expect(option.price, const Price.paisa(10000));
      expect(option.named, 'Cold drink (500ml)');
    });

    test('a half-filled option row is dropped rather than rendered', () {
      final p = Product.fromJson({
        'slug': 'x',
        'name': 'X',
        'options': [
          {'key': 'ok', 'label': 'Fine'},
          {'key': '', 'label': 'No key'},
          {'key': 'no-label', 'label': ''},
        ],
      });
      expect(p.options.map((o) => o.key), ['ok']);
    });
  });

  group('the struck-through delivery figure on a card', () {
    testWidgets('is the price plus delivery, with the price unchanged',
        (tester) async {
      final service = await loaded(catalogJson());
      final product = service.state.catalog!.products.single;

      await tester.pumpWidget(CatalogScope(
        service: service,
        child: MaterialApp(
          theme: StoreTheme.light(),
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 160,
                child: ProductCard(product: product, onTap: () {}),
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      final text = visibleText(tester);
      // 780000 paisa * 1.10 = 858000 paisa.
      expect(text, contains('Rs 8,580'));
      expect(text, contains('Rs 7,800'));
    });

    testWidgets('is absent when the catalog sets no delivery percent',
        (tester) async {
      final service = await loaded(catalogJson(deliveryPercent: 0));
      final product = service.state.catalog!.products.single;

      await tester.pumpWidget(CatalogScope(
        service: service,
        child: MaterialApp(
          theme: StoreTheme.light(),
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 160,
                child: ProductCard(product: product, onTap: () {}),
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      expect(visibleText(tester), isNot(contains('Rs 8,580')));
    });
  });

  group('the product screen add-ons', () {
    testWidgets('shows the size and surcharge, starts clear, and toggles',
        (tester) async {
      useTallView(tester);
      final service = await loaded(catalogJson(
        options: const [
          {
            'key': 'cold-drink',
            'label': 'Cold drink',
            'desc': '500ml',
            'price_cents': 10000,
          },
        ],
      ));

      await tester.pumpWidget(CatalogScope(
        service: service,
        child: MaterialApp(
          theme: StoreTheme.light(),
          home: const ProductScreen(slug: 'stoneware-mug'),
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.text('Cold drink'), findsOneWidget);
      expect(find.textContaining('500ml'), findsOneWidget);
      expect(find.textContaining('+ Rs 100'), findsOneWidget);

      Checkbox checkbox() => tester.widget<Checkbox>(find.byType(Checkbox));
      expect(checkbox().value, isFalse, reason: 'the buyer opts in');

      await tester.tap(find.byType(Checkbox));
      await tester.pumpAndSettle();
      expect(checkbox().value, isTrue);

      // Ticking it does not move the price on the page; the Rs 100 is stated on
      // the option and in the order message only.
      expect(visibleText(tester), contains('Rs 7,800'));
      expect(visibleText(tester), isNot(contains('Rs 7,900')));
    });

    testWidgets('shows no add-on box when the product has no options',
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

      expect(find.byType(Checkbox), findsNothing);
      expect(find.text('ADD-ONS'), findsNothing);
    });
  });
}
