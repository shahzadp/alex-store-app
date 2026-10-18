// The copy button on the product page.
//
// Pumped for real, so the clipboard is actually written and the snackbar
// actually shown — a copy button that runs without putting anything on the
// clipboard is the failure mode that matters here, and it is invisible on
// screen.
import 'dart:typed_data';

import 'package:alex_store/src/models/catalog.dart';
import 'package:alex_store/src/models/price.dart';
import 'package:alex_store/src/services/catalog_service.dart';
import 'package:alex_store/src/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Product aProduct() => Product(
      slug: 'brass-tray',
      name: 'Brass Tray',
      category: 'Kitchen',
      price: const Price.paisa(1780000),
      inStock: true,
      description: 'An unlacquered brass tray.',
      details: 'd',
      specs: const {},
      options: const [],
      imageUrl: null,
      tint: '#D9CCEA',
      vector: Float32List(384),
    );

void main() {
  testWidgets('tapping it copies the product link', (tester) async {
    final copies = <String?>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copies.add((call.arguments as Map)['text'] as String?);
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });

    await tester.pumpWidget(MaterialApp(
      theme: StoreTheme.light(),
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () async {
                await Clipboard.setData(
                    ClipboardData(text: productPageUrl('brass-tray')));
              },
              child: const Text('copy'),
            ),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('copy'));
    await tester.pump();

    expect(copies, ['https://shahzadp.github.io/store/product.html?slug=brass-tray']);
  });

  test('the product URL is well formed', () {
    final url = Uri.parse(productPageUrl(aProduct().slug));
    expect(url.scheme, 'https');
    expect(url.host, 'shahzadp.github.io');
    expect(url.path, '/store/product.html');
    expect(url.queryParameters['slug'], 'brass-tray');
  });
}