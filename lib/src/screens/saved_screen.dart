/// Saved for later — the wishlist.
///
/// Everything here is drawn from two local sources: the [SavedStore]'s slug
/// list, and the catalog already in memory. A saved slug whose product is
/// gone from the catalog simply does not render; a catalog that has not
/// loaded yet shows the same grid the shop shows, so the shape is familiar.
/// Saving again costs nothing: the toggle on every card writes through to
/// the store, and this screen rebuilds from its stream.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../catalog_scope.dart';
import '../services/catalog_service.dart';
import '../services/local_stores.dart';
import '../store_scope.dart';
import '../theme.dart';
import '../widgets/product_card.dart';
import '../widgets/skeleton.dart';
import '../widgets/states.dart';
import 'main_shell.dart';
import 'product_screen.dart';

class SavedScreen extends StatelessWidget {
  const SavedScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final saved = StoreScope.of(context).saved;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Saved'),
        actions: [
          _ClearAllAction(saved: saved),
          const SizedBox(width: StoreTheme.spaceSm),
        ],
      ),
      body: StreamBuilder<List<String>>(
        stream: saved.stream,
        initialData: saved.state,
        builder: (context, savedSnapshot) {
          final service = CatalogScope.of(context);
          return StreamBuilder<CatalogState>(
            stream: service.stream,
            initialData: service.state,
            builder: (context, catalogSnapshot) {
              final state = catalogSnapshot.data ?? CatalogState.empty;
              final catalog = state.catalog;

              if (catalog == null) {
                if (state.isLoading) return const SkeletonProductGrid(count: 2);
                return StoreErrorState(
                  message: state.error,
                  onRetry: () => service.load(),
                );
              }

              final slugs = savedSnapshot.data ?? const <String>[];
              final bySlug = {for (final p in catalog.products) p.slug: p};
              final products = [
                for (final slug in slugs)
                  if (bySlug[slug] != null) bySlug[slug]!,
              ];

              if (products.isEmpty) {
                return StoreEmptyState(
                  icon: Icons.favorite_border_rounded,
                  title: 'Nothing saved yet',
                  message: 'Tap the heart on any product — it will wait for '
                      'you here, on this device.',
                  actionLabel: 'Browse products',
                  onAction: () {
                    // Inside the shell, switch tabs; outside it, do nothing
                    // rather than dead-end (the product grid is not a route).
                    ShellSwitcher.maybeSwitchTo(context, ShellTab.shop);
                  },
                );
              }

              return ProductGrid(
                products: products,
                onTap: (p) => Navigator.of(context).push(
                  MaterialPageRoute(
                      builder: (_) => ProductScreen(slug: p.slug)),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

/// Trash icon that only appears when there is something to clear, and only
/// ever clears after a confirmation.
class _ClearAllAction extends StatelessWidget {
  const _ClearAllAction({required this.saved});

  final SavedStore saved;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<String>>(
      stream: saved.stream,
      initialData: saved.state,
      builder: (context, snapshot) {
        final count = snapshot.data?.length ?? 0;
        if (count == 0) return const SizedBox.shrink();

        return IconButton(
          tooltip: 'Clear saved',
          icon: const Icon(Icons.delete_outline_rounded),
          onPressed: () => _confirm(context, count),
        );
      },
    );
  }

  Future<void> _confirm(BuildContext context, int count) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear saved?'),
        content: Text(
          'Remove ${count == 1 ? 'this product' : 'all $count products'} from your saved list on this device?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      unawaited(saved.clear());
    }
  }
}
