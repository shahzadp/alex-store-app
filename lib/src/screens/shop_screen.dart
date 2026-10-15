import 'package:flutter/material.dart';

import '../catalog_scope.dart';
import '../services/catalog_service.dart';
import '../models/catalog.dart';
import '../theme.dart';
import '../widgets/product_card.dart';
import 'product_screen.dart';
import 'search_screen.dart';

/// Every product, filterable by category.
///
/// The filter is a plain subset of the fetched catalog — no request, no query.
/// With eight products there is nothing a server could do better, and a filter
/// that can fail is a filter that eventually will.
class ShopScreen extends StatefulWidget {
  const ShopScreen({super.key});

  @override
  State<ShopScreen> createState() => _ShopScreenState();
}

class _ShopScreenState extends State<ShopScreen> {
  String? _category;
  bool _inStockOnly = false;

  @override
  Widget build(BuildContext context) {
    final service = CatalogScope.of(context);

    return StreamBuilder<CatalogState>(
      stream: service.stream,
      initialData: service.state,
      builder: (context, snapshot) {
        final state = snapshot.data ?? CatalogState.empty;
        final catalog = state.catalog;

        if (catalog == null) {
          return const Scaffold(body: Center(child: CircularProgressIndicator(strokeWidth: 2)));
        }

        final products = _filter(catalog);

        return Scaffold(
          appBar: AppBar(
            title: const Text('Shop'),
            actions: [
              IconButton(
                tooltip: 'Search',
                icon: const Icon(Icons.search),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const SearchScreen()),
                ),
              ),
              const SizedBox(width: 6),
            ],
          ),
          body: Column(
            children: [
              _Filters(
                categories: catalog.categories.toList()..sort(),
                selected: _category,
                inStockOnly: _inStockOnly,
                onCategory: (c) => setState(() => _category = c),
                onInStockOnly: (v) => setState(() => _inStockOnly = v),
              ),
              const Divider(height: 1),
              Expanded(
                child: products.isEmpty
                    ? const _Empty()
                    : SingleChildScrollView(
                        child: ProductGrid(
                          products: products,
                          onTap: (p) => Navigator.of(context).push(
                            MaterialPageRoute(builder: (_) => ProductScreen(slug: p.slug)),
                          ),
                        ),
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  List<Product> _filter(Catalog catalog) {
    var products = catalog.products;
    if (_category != null) {
      products = products.where((p) => p.category == _category).toList();
    }
    if (_inStockOnly) {
      products = products.where((p) => p.inStock).toList();
    }
    return products;
  }
}

class _Filters extends StatelessWidget {
  const _Filters({
    required this.categories,
    required this.selected,
    required this.inStockOnly,
    required this.onCategory,
    required this.onInStockOnly,
  });

  final List<String> categories;
  final String? selected;
  final bool inStockOnly;
  final ValueChanged<String?> onCategory;
  final ValueChanged<bool> onInStockOnly;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 9),
        children: [
          _Chip(
            label: 'All',
            selected: selected == null,
            onTap: () => onCategory(null),
          ),
          for (final c in categories) ...[
            const SizedBox(width: 7),
            _Chip(label: c, selected: selected == c, onTap: () => onCategory(c)),
          ],
          const SizedBox(width: 7),
          _Chip(label: 'In stock', selected: inStockOnly, onTap: () => onInStockOnly(!inStockOnly)),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? StoreTheme.ink : StoreTheme.surface,
      borderRadius: BorderRadius.circular(3),
      child: InkWell(
        borderRadius: BorderRadius.circular(3),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
          decoration: BoxDecoration(
            border: Border.all(color: selected ? StoreTheme.ink : StoreTheme.line),
            borderRadius: BorderRadius.circular(3),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w500,
              color: selected ? Colors.white : StoreTheme.ink,
            ),
          ),
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          'Nothing matches those filters.',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      ),
    );
  }
}