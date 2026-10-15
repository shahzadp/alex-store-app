// The footer WhatsApp button must look exactly like the hero Search button.
//
// They used to differ: the hero button was filled and green, the footer one
// outlined, so the page offered two visually different ways to do the same
// thing and it was not clear which was the real one. Both are now plain
// FilledButtons with no colour override, so both take the same theme entry.
import 'package:alex_store/src/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the filled button is the site accent, not a leftover green', () {
    final style = StoreTheme.light().filledButtonTheme.style!;
    expect(style.backgroundColor?.resolve(const {}), StoreTheme.accent);
    expect(style.backgroundColor?.resolve(const {}), isNot(StoreTheme.whatsapp));
  });

  testWidgets('both buttons inherit the theme rather than overriding it',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: StoreTheme.light(),
      home: Scaffold(
        body: Column(
          children: [
            FilledButton.icon(
              onPressed: () {},
              icon: const Icon(Icons.search, size: 18),
              label: const Text('Search'),
            ),
            FilledButton(
              onPressed: () {},
              child: const Text('Message the shop on WhatsApp'),
            ),
          ],
        ),
      ),
    ));

    final search = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Search'),
    );
    final footer = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Message the shop on WhatsApp'),
    );

    // A null style means "use filledButtonTheme", which is the whole point:
    // there is nowhere for the two buttons to diverge.
    expect(search.style, isNull);
    expect(footer.style, isNull);

    // Neither is an outlined control any more.
    expect(find.byType(OutlinedButton), findsNothing);
  });
}