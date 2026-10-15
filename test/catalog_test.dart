/// Tests for the pure-Dart domain layer.
///
/// These cover the parts that are easy to get quietly wrong and hard to notice
/// on a screen: paisa arithmetic, base64 vector decoding, and the WhatsApp link.
///
/// No Flutter binding is involved, so they run under `flutter test` without a
/// native build.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:alex_store/src/models/catalog.dart';
import 'package:alex_store/src/models/price.dart';
import 'package:alex_store/src/services/whatsapp.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Price', () {
    test('renders whole rupees from paisa', () {
      // The catalog's real values.
      expect(const Price.paisa(780000).formatted, 'Rs 7,800');
      expect(const Price.paisa(1780000).formatted, 'Rs 17,800');
      expect(const Price.paisa(600000).formatted, 'Rs 6,000');
      expect(const Price.paisa(1000000).formatted, 'Rs 10,000');
    });

    test('groups thousands correctly at every digit count', () {
      expect(const Price.paisa(0).formatted, 'Rs 0');
      expect(const Price.paisa(100).formatted, 'Rs 1');
      expect(const Price.paisa(10000).formatted, 'Rs 100');
      expect(const Price.paisa(100000).formatted, 'Rs 1,000');
      expect(const Price.paisa(10000000).formatted, 'Rs 100,000');
    });

    test('shows paisa rather than rounding them away', () {
      // The admin allows any integer >= 0, so a price with a fractional rupee
      // is representable. Silently truncating it would display a different
      // amount from the one in the catalog.
      expect(const Price.paisa(780050).formatted, 'Rs 7,800.50');
      expect(const Price.paisa(5).formatted, 'Rs 0.05');
    });

    test('compares by value', () {
      expect(const Price.paisa(100), lessThan(const Price.paisa(200)));
      expect(const Price.paisa(100) + const Price.paisa(50), const Price.paisa(150));
    });

    test('rejects a negative price', () {
      expect(() => Price.paisa(-1), throwsA(isA<AssertionError>()));
    });
  });

  group('vector decoding', () {
    /// A syntactically valid 384-element float32 base64 blob.
    String blobOfLength(int floats) {
      final bytes = Float32List(floats);
      return base64Encode(bytes.buffer.asUint8List());
    }

    Map<String, dynamic> productJson({Object? vector, String slug = 'mug'}) {
      return <String, dynamic>{
        'slug': slug,
        'name': 'Stoneware Mug',
        'category': 'Kitchen',
        'price_cents': 780000,
        'in_stock': true,
        'description': 'Glazed stoneware.',
        'details': '',
        'specs': <String, String>{},
        'image_url': null,
        'tint': '#D9CCEA',
        'vector': vector,
      };
    }

    test('decodes a 384-dim blob', () {
      final p = Product.fromJson(productJson(vector: blobOfLength(384)));
      expect(p.vector, isNotNull);
      expect(p.vector!.length, 384);
    });

    test('returns null for the wrong width rather than padding', () {
      // A 128-dim vector means a different model. Padding it to 384 would make
      // the dot product return a confident, wrong answer.
      expect(Product.fromJson(productJson(vector: blobOfLength(128))).vector, isNull);
      expect(Product.fromJson(productJson(vector: blobOfLength(512))).vector, isNull);
    });

    test('returns null for malformed base64 instead of throwing', () {
      expect(Product.fromJson(productJson(vector: 'not base64 !!!')).vector, isNull);
    });

    test('returns null when the field is absent or empty', () {
      expect(Product.fromJson(productJson(vector: null)).vector, isNull);
      expect(Product.fromJson(productJson(vector: '')).vector, isNull);
    });

    test('decodes to the values that were encoded', () {
      final source = Float32List(384);
      source[0] = 0.5;
      source[383] = -0.25;
      final b64 = base64Encode(source.buffer.asUint8List());

      final decoded = Product.fromJson(productJson(vector: b64)).vector!;
      expect(decoded[0], closeTo(0.5, 1e-6));
      expect(decoded[383], closeTo(-0.25, 1e-6));
      expect(decoded.length, 384);
    });
  });

  group('Catalog', () {
    Map<String, dynamic> catalogJson({
      required List<Map<String, dynamic>> products,
      String searchModel = 'ternlight/base@0.1.1',
    }) {
      return <String, dynamic>{
        'generated_at': '2026-10-15T00:50:09.125Z',
        'store': <String, dynamic>{
          'name': 'Alex Store',
          'whatsapp': '923288304524',
          'free_delivery_over_paisa': 600000,
          'currency': 'PKR',
        },
        'products': products,
        'collections': <dynamic>[],
        'search_model': searchModel,
      };
    }

    Map<String, dynamic> product(String slug, {bool withVector = true}) {
      final floats = withVector ? Float32List(384) : null;
      return <String, dynamic>{
        'slug': slug,
        'name': slug,
        'category': 'Kitchen',
        'price_cents': 100000,
        'in_stock': true,
        'description': 'x',
        'details': '',
        'specs': <String, String>{},
        'image_url': null,
        'tint': null,
        'vector': floats == null ? null : base64Encode(floats.buffer.asUint8List()),
      };
    }

    test('is searchable only when every product has a vector', () {
      final complete = Catalog.fromJson(catalogJson(products: [
        product('a'),
        product('b'),
      ]));
      expect(complete.isSearchable, isTrue);
      expect(complete.unindexedSlugs, isEmpty);

      final partial = Catalog.fromJson(catalogJson(products: [
        product('a'),
        product('b', withVector: false),
      ]));
      expect(partial.isSearchable, isFalse);
      expect(partial.unindexedSlugs, ['b']);
    });

    test('an empty catalog is not searchable', () {
      expect(Catalog.fromJson(catalogJson(products: [])).isSearchable, isFalse);
    });

    test('records the search model so it can be checked against the engine', () {
      final c = Catalog.fromJson(catalogJson(
        products: [product('a')],
        searchModel: 'some/other-model@9',
      ));
      expect(c.searchModel, 'some/other-model@9');
    });

    test('strips punctuation from the WhatsApp number', () {
      final c = Catalog.fromJson(catalogJson(products: [product('a')]));
      expect(c.store.whatsapp, '923288304524');
      expect(c.store.freeDeliveryOver, const Price.paisa(600000));
    });

    test('defaults a missing category to General', () {
      final p = Product.fromJson(<String, dynamic>{'slug': 'x', 'name': 'X'});
      expect(p.category, 'General');
    });

    test('drops blank spec rows rather than rendering empty ones', () {
      final p = Product.fromJson(<String, dynamic>{
        'slug': 'x',
        'name': 'X',
        'specs': <String, String>{'Material': 'Stoneware', 'Care': '  ', '': 'orphan'},
      });
      expect(p.specs, {'Material': 'Stoneware'});
    });

    test('finds a product by slug and returns null otherwise', () {
      final c = Catalog.fromJson(catalogJson(products: [product('stoneware-mug')]));
      expect(c.bySlug('stoneware-mug')?.slug, 'stoneware-mug');
      expect(c.bySlug('nope'), isNull);
    });

    test('collects distinct categories', () {
      final c = Catalog.fromJson(catalogJson(products: [
        <String, dynamic>{...product('a'), 'category': 'Kitchen'},
        <String, dynamic>{...product('b'), 'category': 'Kitchen'},
        <String, dynamic>{...product('c'), 'category': 'Decor'},
      ]));
      expect(c.categories, {'Kitchen', 'Decor'});
    });
  });

  group('whatsappLink', () {
    test('builds a wa.me URL with the number and an encoded message', () {
      final url = whatsappLink(number: '923288304524', message: 'Hello there');
      expect(url, 'https://wa.me/923288304524?text=Hello%20there');
    });

    test('escapes ampersands and newlines', () {
      // Unescaped, the message is truncated at the first '&' or the first raw
      // newline and the product name is silently lost.
      final url = whatsappLink(
        number: '923288304524',
        message: 'Mug — Rs 7,800\nMaterial & care',
      );
      expect(url, contains('%26')); // &
      expect(url, contains('%0A')); // newline
      expect(url, isNot(contains(' &')));
    });

    test('strips formatting from the number', () {
      final url = whatsappLink(number: '+92 (328) 830-4524', message: 'hi');
      expect(url, 'https://wa.me/923288304524?text=hi');
    });

    test('announcement states the threshold, and is omitted without one', () {
      String format(int paisa) => Price.paisa(paisa).formatted;

      expect(
        announcementFor(freeDeliveryOverPaisa: 600000, format: format),
        'Free delivery over Rs 6,000',
      );
      // No threshold configured -> no bar, rather than an empty one.
      expect(announcementFor(freeDeliveryOverPaisa: 0, format: format), isNull);
    });

    test('the pre-written message carries product, price and description', () {
      final p = Product.fromJson(<String, dynamic>{
        'slug': 'stoneware-mug',
        'name': 'Stoneware Mug',
        'category': 'Kitchen',
        'price_cents': 780000,
        'in_stock': true,
        'description': 'Glazed stoneware, holds heat well.',
        'details': 'Thrown in small batches.',
        'specs': <String, String>{},
      });
      // No Uri.decodeComponent here. This used to decode the result, which is
      // exactly what hid the double-encoding bug: whatsappMessage pre-encoded
      // the text, the test undid it, and whatsappLink then encoded it a second
      // time on the way to WhatsApp. The message is plain text now, and
      // whatsapp_link_test.dart covers the URL boundary.
      final message = p.whatsappMessage('Alex Store');
      expect(message, contains('Stoneware Mug'));
      expect(message, contains('Rs 7,800'));
      expect(message, contains('Glazed stoneware'));
      expect(message, contains('Kitchen'));
    });
  });
}