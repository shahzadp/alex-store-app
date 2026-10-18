// The voucher is shown once, and only once.
//
// Two seams are exercised: VoucherStore, which remembers the marker on disk, and
// VoucherPrompt, which is the thing the shopper sees and closes. The wiring that
// puts them together (`_VoucherGate` in main.dart) is deliberately thin, and it
// is the store's answer that decides whether the offer appears at all.
import 'dart:io';

import 'package:alex_store/src/services/voucher_store.dart';
import 'package:alex_store/src/theme.dart';
import 'package:alex_store/src/widgets/voucher_prompt.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('VoucherStore', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('alex-voucher-');
    });

    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test('a fresh install has not seen the voucher', () async {
      expect(await VoucherStore(directory: () async => dir).hasSeen(), isFalse);
    });

    test('a marker is remembered across instances', () async {
      await VoucherStore(directory: () async => dir).markSeen();
      expect(await VoucherStore(directory: () async => dir).hasSeen(), isTrue);
    });

    test('an unwritable location reads as not-seen rather than throwing',
        () async {
      final store = VoucherStore(
        directory: () async => throw const FileSystemException('no plugin'),
      );
      // Showing the offer twice is the harmless direction to fail in; an
      // exception on launch is not.
      expect(await store.hasSeen(), isFalse);
      await store.markSeen();
    });
  });

  group('VoucherPrompt', () {
    Future<void> pump(
      WidgetTester tester, {
      required void Function(bool claimed) onClose,
    }) async {
      await tester.pumpWidget(MaterialApp(
        theme: StoreTheme.light(),
        home: Scaffold(
          body: VoucherPrompt(
            title: 'Free delivery over Rs 6,000',
            description: 'Claim it and delivery is on us.',
            code: 'FREEDELIVERY',
            terms: 'Orders over Rs 6,000.',
            onClose: onClose,
          ),
        ),
      ));
    }

    testWidgets('names the offer and its code', (tester) async {
      await pump(tester, onClose: (_) {});

      expect(find.text('Free delivery over Rs 6,000'), findsOneWidget);
      expect(find.text('FREEDELIVERY'), findsOneWidget);
      expect(find.text('Claim voucher'), findsOneWidget);
    });

    testWidgets('claiming reports a claim, after the celebration',
        (tester) async {
      bool? claimed;
      await pump(tester, onClose: (c) => claimed = c);

      await tester.tap(find.text('Claim voucher'));
      await tester.pump(); // the burst starts
      expect(find.text('Voucher claimed — see you at checkout.'), findsOneWidget);
      expect(claimed, isNull, reason: 'the overlay lingers for the confetti');

      await tester.pump(const Duration(seconds: 3));
      expect(claimed, isTrue);
    });

    testWidgets('dismissing reports no claim', (tester) async {
      bool? claimed;
      await pump(tester, onClose: (c) => claimed = c);

      await tester.tap(find.text('No thanks'));
      await tester.pump();

      expect(claimed, isFalse);
    });
  });
}
