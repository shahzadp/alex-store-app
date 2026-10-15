import 'package:flutter/material.dart';

import '../catalog_scope.dart';
import '../services/catalog_service.dart';
import '../models/catalog.dart';
import '../models/price.dart';
import '../services/launcher.dart';
import '../services/whatsapp.dart';
import '../theme.dart';
import '../widgets/product_card.dart';
import '../widgets/product_image.dart';
import 'product_screen.dart';
import 'search_screen.dart';
import 'shop_screen.dart';

/// The shop's front door.
///
/// Structure follows the site's index page: the delivery threshold, then the
/// hero, then the product grid, then collections. Products come first because
/// the grid is what a shopper came for; collections are the browse-after.
/// Nothing that a shopper has to dismiss first, and no cart, because there is
/// no cart (MEMORY.md §3).
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final service = CatalogScope.of(context);

    return StreamBuilder<CatalogState>(
      stream: service.stream,
      initialData: service.state,
      builder: (context, snapshot) {
        final state = snapshot.data ?? CatalogState.empty;

        return Scaffold(
          body: SafeArea(
            bottom: false,
            child: Column(
              children: [
                AnnouncementBar(state: state),
                Expanded(child: _Body(state: state)),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.state});

  final CatalogState state;

  @override
  Widget build(BuildContext context) {
    final catalog = state.catalog;

    if (catalog == null) {
      if (state.isLoading) {
        return const Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2, color: StoreTheme.inkMuted),
          ),
        );
      }
      return _LoadError(message: state.error);
    }

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(child: _Hero(catalog: catalog)),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 36, 20, 8),
            child: Row(
              children: [
                Text('Shop', style: Theme.of(context).textTheme.headlineSmall),
                const Spacer(),
                TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const ShopScreen()),
                  ),
                  child: const Text('All products'),
                ),
              ],
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: ProductGrid(
            products: catalog.products,
            onTap: (p) => _openProduct(context, p),
          ),
        ),
        if (catalog.collections.isNotEmpty)
          SliverToBoxAdapter(child: _Collections(collections: catalog.collections)),
        const SliverToBoxAdapter(child: _Footer()),
        // Clears the three-button navigation bar. The grid above adds its own
        // inset, but the footer is the last thing here and it was landing
        // under the nav buttons on a handset.
        SliverToBoxAdapter(
          child: SizedBox(height: 28 + StoreTheme.bottomSafeInset(context)),
        ),
      ],
    );
  }

  static void _openProduct(BuildContext context, Product product) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ProductScreen(slug: product.slug)),
    );
  }
}

/// The delivery-threshold strip.
///
/// States only the threshold. On the site a call-to-action here was removed as
/// redundant — WhatsApp is already one tap from every product, the drawer and
/// the footer (MEMORY.md §3) — so this bar carries information and nothing else.
///
/// Hidden entirely when the store has no threshold configured: an empty
/// announcement bar is worse than none.
class AnnouncementBar extends StatelessWidget {
  const AnnouncementBar({super.key, required this.state});

  final CatalogState state;

  @override
  Widget build(BuildContext context) {
    final catalog = state.catalog;
    final text = catalog == null
        ? null
        : announcementFor(
            freeDeliveryOverPaisa: catalog.store.freeDeliveryOver.paisa,
            format: (paisa) => Price.paisa(paisa).formatted,
          );
    if (text == null) return const SizedBox.shrink();

    return Container(
      width: double.infinity,
      color: StoreTheme.surfaceDark,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: const TextStyle(color: StoreTheme.inkOnDark, fontSize: 12.5, letterSpacing: 0.2),
      ),
    );
  }
}

class _Hero extends StatelessWidget {
  const _Hero({required this.catalog});

  final Catalog catalog;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 28, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(catalog.store.name, style: theme.textTheme.displaySmall),
          const SizedBox(height: 10),
          // Only what is verifiable about the store. No invented founding
          // year, sourcing story or location (MEMORY.md §3).
          Text(
            'Stoneware, linen and brass for an already-lived room. '
            'Order over WhatsApp; delivery arranged with you.',
            style: theme.textTheme.bodyLarge?.copyWith(color: StoreTheme.inkBody),
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const SearchScreen()),
                  ),
                  icon: const Icon(Icons.search, size: 18),
                  label: const Text('Search'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const ShopScreen()),
                  ),
                  icon: const Icon(Icons.grid_view, size: 17),
                  label: const Text('Browse'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Collections extends StatelessWidget {
  const _Collections({required this.collections});

  final List<ProductCollection> collections;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 34, 20, 12),
          child: Text('COLLECTIONS', style: TextStyle(fontSize: 11, letterSpacing: 0.8, color: StoreTheme.inkMuted)),
        ),
        SizedBox(
          height: 178,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            itemCount: collections.length,
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (context, i) => _CollectionTile(collection: collections[i], seed: i),
          ),
        ),
      ],
    );
  }
}

/// A collection is editorial and deliberately not a product group
/// (CATALOG-GUIDE.md §6: linking them would be a schema change). So this is
/// a description, not a link into a filtered list — tapping it says what it
/// is rather than pretending it filters.
class _CollectionTile extends StatelessWidget {
  const _CollectionTile({required this.collection, required this.seed});

  final ProductCollection collection;
  final int seed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 190,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ProductImage(
            imageUrl: collection.imageUrl,
            tint: collection.tint,
            label: collection.title,
            seed: seed + 3,
            aspectRatio: 1.7,
          ),
          const SizedBox(height: 8),
          Text(
            collection.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 2),
          Text(
            collection.description,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer();

  @override
  Widget build(BuildContext context) {
    final catalog = CatalogScope.of(context).state.catalog;
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 40, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Divider(),
          const SizedBox(height: 16),
          // Filled, so it is the same purple as the hero's Search button. An
          // outlined variant here read as a second kind of action, and the two
          // side by side looked like one was important and one was not.
          if (catalog != null)
            FilledButton(
              onPressed: () => openWhatsApp(
                context: context,
                number: catalog.store.whatsapp,
                message: 'Hello, I have a question about your products.',
              ),
              child: Text.rich(
                whatsappButtonLabel('Message the shop on '),
              ),
            ),
          const SizedBox(height: 14),
          Text(
            'Prices in Pakistani rupees. Free delivery over '
            '${(catalog?.store.freeDeliveryOver ?? Price.zero).formatted}.',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _LoadError extends StatelessWidget {
  const _LoadError({this.message});

  final String? message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              message ?? 'The store could not be loaded.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 18),
            OutlinedButton(
              onPressed: () => CatalogScope.of(context).load(),
              child: const Text('Try again'),
            ),
          ],
        ),
      ),
    );
  }
}