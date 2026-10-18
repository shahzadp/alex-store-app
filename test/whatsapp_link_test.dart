// Guards the WhatsApp message encoding.
//
// The reported symptom was a message arriving in the chat as
//
//   Hello%0A%0AStoneware%20Mug%20%E2%80%94%20Rs%207%2C800
//
// — percent escapes visible as literal text, instead of a message with real
// line breaks and spaces.
//
// Cause: `Product.whatsappMessage` returned `Uri.encodeComponent(message)` and
// `whatsappLink` encoded it AGAIN. A newline became `%250A`, WhatsApp decoded
// the query parameter once, and what it showed was the single-encoded string.
// The link was valid the whole time, which is why nothing errored.
//
// The rule these tests enforce: the message crosses the boundary ONCE. If
// anything is already `%`-encoded on the way into `whatsappLink`, it is a bug.
import 'dart:typed_data';

import 'package:alex_store/src/models/catalog.dart';
import 'package:alex_store/src/models/price.dart';
import 'package:alex_store/src/services/whatsapp.dart';
import 'package:flutter_test/flutter_test.dart';

const number = '923288304524';

Product aProduct() => Product(
      slug: 'stoneware-mug',
      name: 'Stoneware Mug',
      category: 'Kitchen',
      price: const Price.paisa(780000),
      inStock: true,
      description:
          'Glazed stoneware, holds heat well and goes in the dishwasher.',
      details:
          'Thrown in small batches and glazed inside and out, so it holds heat '
          'as well as it looks doing it. The foot is left unglazed, which '
          'stops it sticking to a shelf or a table.',
      specs: const {},
      options: const [],
      imageUrl: null,
      tint: '#D9CCEA',
      vector: Float32List(384),
    );

/// What WhatsApp actually shows: it decodes the query parameter exactly once.
String asWhatsAppShows(String url) =>
    Uri.parse(url).queryParameters['text'] ?? '';

void main() {
  group('the message is encoded exactly once', () {
    test('whatsappLink does not leave percent escapes in the message', () {
      final url = whatsappLink(
        number: number,
        message: "Hi Alex Store! I'd like to order:\n\n*Stoneware Mug*",
      );

      final shown = asWhatsAppShows(url);
      expect(shown, isNot(contains('%')),
          reason: 'WhatsApp would display: $shown');
      expect(shown, contains('\n'), reason: 'line breaks must be real');
    });

    test('the raw url contains single escapes, never %25', () {
      final url = whatsappLink(number: number, message: 'a\nb c');
      // %25 is the encoding of a literal '%'. Its presence means the message was
      // encoded twice.
      expect(url.contains('%25'), isFalse,
          reason: 'double-encoded: $url');
      expect(url, 'https://wa.me/923288304524?text=a%0Ab%20c');
    });

    test('whatsappAppLink encodes once too', () {
      final url = whatsappAppLink(number: number, message: 'a\nb c');
      expect(url.contains('%25'), isFalse, reason: 'double-encoded: $url');
      expect(url, startsWith('whatsapp://send?phone=923288304524&text='));
      expect(asWhatsAppShows(url), 'a\nb c');
    });

    test('both links agree on the message', () {
      final message = "Hi Alex Store! I'd like to order:\n\n*Stoneware Mug*";
      expect(asWhatsAppShows(whatsappLink(number: number, message: message)),
          asWhatsAppShows(whatsappAppLink(number: number, message: message)));
    });
  });

  group('the product message matches the site', () {
    final message = aProduct().whatsappMessage('Alex Store');

    test('names the store and the product', () {
      expect(message, contains("Hi Alex Store! I'd like to order:"));
      expect(message, contains('*Stoneware Mug*'),
          reason: 'the site uses WhatsApp *bold* for the product name');
      expect(message, contains('Kitchen — Rs 7,800'),
          reason: 'the site sends the category as well as the price');
      expect(message, contains('Is it available?'));
    });

    test('is plain text, not percent-encoded', () {
      expect(message, isNot(contains('%0A')));
      expect(message, contains('\n'));
    });

    test('does not include the long description copy', () {
      // common.js: "only ask about the detail if there is any, and keep it to
      // one extra line". The app used to append the whole details block, which
      // made the order message long enough that the shop would not read it.
      expect(message, isNot(contains('unglazed')));
      expect(message.split('\n').length, lessThanOrEqualTo(8),
          reason: 'order message is longer than the site would send');
    });

    test('survives the full round trip to a URL unchanged', () {
      final url = whatsappLink(number: number, message: message);
      expect(asWhatsAppShows(url), message);
    });

    test('survives an ampersand in the copy', () {
      final p = Product(
        slug: 'x',
        name: 'Salt & Pepper Mill',
        category: 'Kitchen',
        price: const Price.paisa(100000),
        inStock: true,
        description: 'Ceramic, for salt & pepper.',
        details: '',
        specs: const {},
        options: const [],
        imageUrl: null,
        tint: null,
        vector: Float32List(384),
      );
      final shown = asWhatsAppShows(
        whatsappLink(number: number, message: p.whatsappMessage('Alex Store')),
      );
      expect(shown, contains('Salt & Pepper Mill'),
          reason: 'an unescaped & would truncate the message');
      expect(shown, contains('salt & pepper'));
    });
  });
}