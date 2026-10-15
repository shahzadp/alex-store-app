import 'package:flutter/material.dart';

import '../catalog_scope.dart';
import '../models/price.dart';
import '../services/launcher.dart';
import '../theme.dart';

/// About the store.
///
/// MEMORY.md Â§3: "The About page states nothing that isn't true of how the
/// store actually works â€” no invented founding year, sourcing story or
/// location. ... the copy will not invent them."
///
/// So this page describes mechanics the shopper can verify from the app
/// itself â€” how ordering works, what the prices mean, what search does with
/// their words â€” and says nothing about who runs the shop or where the goods
/// come from. Those facts are not known yet (MEMORY.md Â§6, open work), and a
/// placeholder that reads as a claim is worse than an absence.
class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final catalog = CatalogScope.of(context).state.catalog;

    return Scaffold(
      appBar: AppBar(title: const Text('About')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
        children: [
          Text(catalog?.store.name ?? 'Alex Store', style: theme.textTheme.headlineMedium),
          const SizedBox(height: 22),

          _Block(
            title: 'Ordering',
            body: catalog == null || catalog.store.whatsapp.isEmpty
                ? 'Ordering is arranged over WhatsApp.'
                : 'Message the shop on WhatsApp at +${catalog.store.whatsapp} and the order '
                    'is arranged from there. There is no basket and no checkout in this app '
                    'because there is nothing to check out â€” the shop confirms price, '
                    'availability and delivery with you directly.',
          ),
          _Block(
            title: 'Prices',
            body: 'Every price is in Pakistani rupees and is inclusive of nothing further. '
                'Prices are shown as whole rupees; no other currency is used or accepted here.',
          ),
          if (catalog != null && catalog.store.freeDeliveryOver > Price.zero)
            _Block(
              title: 'Delivery',
              body: 'Free delivery on orders over '
                  '${catalog.store.freeDeliveryOver.formatted}. '
                  'The delivery window is agreed with you over WhatsApp when you order, '
                  'rather than promised here â€” a stated timeframe that is not kept is worse '
                  'than one that is agreed.',
            ),
          _Block(
            title: 'Search',
            body: 'Search runs entirely on this device. The words you type are turned into a '
                'vector on the phone and compared against a small index that came down with '
                'the catalog; your query is not sent anywhere. That is why you can search for '
                '"something to drink out of" and find the mug.',
          ),
          _Block(
            title: 'This app',
            body: 'The catalog, including prices, stock and photographs, is read from the same '
                'file the website uses, each time the app opens. What you see here is what the '
                'shop published.',
          ),

          if (catalog != null && catalog.store.whatsapp.isNotEmpty) ...[
            const SizedBox(height: 8),
            FilledButton(
              onPressed: () => openWhatsApp(
                context: context,
                number: catalog.store.whatsapp,
                message: 'Hello, I have a question about your products.',
              ),
              child: const Text('Message the shop on WhatsApp'),
            ),
          ],
        ],
      ),
    );
  }
}

class _Block extends StatelessWidget {
  const _Block({required this.title, required this.body});

  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title.toUpperCase(), style: Theme.of(context).textTheme.labelSmall),
          const SizedBox(height: 8),
          Text(body, style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: StoreTheme.inkSoft)),
        ],
      ),
    );
  }
}