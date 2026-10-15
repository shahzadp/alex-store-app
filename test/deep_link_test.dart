// Guards the two new pieces: the link a shopper copies, and the link the app
// accepts back.
//
// These have to agree. If `productPageUrl` produces a URL `slugFromLink`
// cannot read, the copy button hands people a link that opens the site but not
// the app — which is worse than no copy button, because it looks like it works.
import 'package:alex_store/src/services/catalog_service.dart';
import 'package:alex_store/src/services/deep_link_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('the copied link', () {
    test('is the site product page with the slug', () {
      expect(productPageUrl('stoneware-mug'),
          'https://shahzadp.github.io/store/product.html?slug=stoneware-mug');
    });

    test('is the URL the website itself uses', () {
      // product.js reads ?slug=, so this is the canonical form.
      expect(Uri.parse(productPageUrl('x')).queryParameters['slug'], 'x');
    });
  });

  group('a link coming back in', () {
    test('reads the slug out of the site product page', () {
      expect(
        slugFromLink('https://shahzadp.github.io/store/product.html?slug=brass-tray'),
        'brass-tray',
      );
    });

    test('round-trips what the copy button produces', () {
      // The case that actually matters: copy from the app, open it, app opens.
      for (final slug in ['stoneware-mug', 'brass-tray', 'linen-napkin-set']) {
        expect(slugFromLink(productPageUrl(slug)), slug,
            reason: 'copied link for $slug does not come back as $slug');
      }
    });

    test('accepts the tidy path form too', () {
      expect(slugFromLink('https://shahzadp.github.io/store/product/brass-tray'),
          'brass-tray');
    });

    test('tolerates a trailing ? or extra parameters', () {
      expect(
        slugFromLink('https://shahzadp.github.io/store/product.html?slug=x&ref=a'),
        'x',
      );
    });

    test('rejects a link to a different site', () {
      expect(slugFromLink('https://example.com/store/product.html?slug=x'), isNull);
    });

    test('rejects the site home page', () {
      expect(slugFromLink('https://shahzadp.github.io/store/'), isNull);
    });

    test('rejects a page that is not a product', () {
      expect(slugFromLink('https://shahzadp.github.io/store/shop.html'), isNull);
    });

    test('rejects an empty slug', () {
      expect(slugFromLink('https://shahzadp.github.io/store/product.html?slug='),
          isNull);
    });

    test('rejects junk rather than throwing', () {
      for (final junk in ['', 'not a url', '::::', 'https://', '://%']) {
        expect(slugFromLink(junk), isNull, reason: 'junk input: $junk');
      }
    });

    test('decodes a percent-encoded slug', () {
      expect(
        slugFromLink('https://shahzadp.github.io/store/product/mug%20one'),
        'mug one',
      );
    });
  });
}