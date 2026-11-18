import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../catalog_scope.dart';
import '../services/catalog_service.dart';
import '../models/catalog.dart';
import '../theme.dart';
import '../widgets/product_card.dart';
import '../widgets/skeleton.dart';
import '../widgets/states.dart';
import 'main_shell.dart';
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

enum _Sort { featured, priceAsc, priceDesc, name }

const _sortLabels = <_Sort, String>{
  _Sort.featured: 'Featured',
  _Sort.priceAsc: 'Price: Low to High',
  _Sort.priceDesc: 'Price: High to Low',
  _Sort.name: 'Name A–Z',
};

class _ShopScreenState extends State<ShopScreen> {
  String? _category;
  bool _inStockOnly = false;
  _Sort _sort = _Sort.featured;

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
          // The grid of skeletons is the same width as the real grid, so nothing
          // shifts when the catalog lands.
          return Scaffold(
            appBar: AppBar(
              title: const Text('Shop'),
              actions: [
                _SearchAction(),
              ],
            ),
            body: const SkeletonProductGrid(count: 4),
          );
        }

        final products = _filter(catalog);

        return Scaffold(
          appBar: AppBar(
            title: const Text('Shop'),
            actions: [
              _SearchAction(),
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
              // How many there are, and how many are shown. A filtered grid
              // with no count reads as a broken grid, not a filtered one.
              Padding(
                padding: const EdgeInsets.fromLTRB(StoreTheme.screenEdge,
                    StoreTheme.spaceMd, StoreTheme.screenEdge, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          '${products.length} '
                          '${products.length == 1 ? 'product' : 'products'}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        const Spacer(),
                        if (_category != null || _inStockOnly) ...[
                          TextButton(
                            onPressed: () => setState(() {
                              _category = null;
                              _inStockOnly = false;
                            }),
                            child: const Text('Clear filters'),
                          ),
                        ],
                        _SortButton(
                          value: _sort,
                          onChanged: (s) => setState(() => _sort = s),
                        ),
                      ],
                    ),
                    if (_sort != _Sort.featured)
                      Text(
                        'Sorted by ${_sortLabels[_sort]}',
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: products.isEmpty
                    ? _Empty(
                        onReset: () => setState(() {
                              _category = null;
                              _inStockOnly = false;
                            }))
                    : SingleChildScrollView(
                        child: ProductGrid(
                          products: products,
                          onTap: (p) => Navigator.of(context).push(
                            MaterialPageRoute(
                                builder: (_) => ProductScreen(slug: p.slug)),
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
    return switch (_sort) {
      _Sort.featured => products,
      _Sort.priceAsc => [...products]
        ..sort((a, b) => a.price.compareTo(b.price)),
      _Sort.priceDesc => [...products]
        ..sort((a, b) => b.price.compareTo(a.price)),
      _Sort.name => [...products]
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase())),
    };
  }
}

/// The filters are a plain subset of the fetched catalog — no request, no query.
/// With a handful of products there is nothing a server could do better, and a
/// filter that can fail is a filter that eventually will.
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
    final all = [null, ...categories];
    return SizedBox(
      height: 52,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(
          horizontal: StoreTheme.screenEdge,
          vertical: StoreTheme.spaceSm,
        ),
        itemCount: all.length + 1,
        itemBuilder: (context, i) {
          if (i == all.length) {
            final last = i == 0;
            return Padding(
              padding: EdgeInsets.only(left: last ? 0 : StoreTheme.spaceSm),
              child: _Chip(
                label: 'In stock',
                selected: inStockOnly,
                onTap: () => onInStockOnly(!inStockOnly),
              ),
            );
          }
          final c = all[i];
          return Padding(
            padding: EdgeInsets.only(left: i == 0 ? 0 : StoreTheme.spaceSm),
            child: _Chip(
              label: c ?? 'All',
              selected: selected == c,
              onTap: () => onCategory(c),
            ),
          );
        },
      ),
    );
  }
}

/// A filter chip with a visible selected state and a real check affordance.
class _Chip extends StatelessWidget {
  const _Chip(
      {required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? StoreTheme.ink : StoreTheme.surface,
      borderRadius: StoreTheme.rSm,
      child: InkWell(
        borderRadius: StoreTheme.rSm,
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        child: AnimatedContainer(
          duration: StoreTheme.durationFast,
          curve: StoreTheme.curveStandard,
          padding: const EdgeInsets.symmetric(
            horizontal: StoreTheme.spaceLg,
            vertical: StoreTheme.spaceSm,
          ),
          decoration: BoxDecoration(
            border: Border.all(
              color: selected ? StoreTheme.ink : StoreTheme.line,
            ),
            borderRadius: StoreTheme.rSm,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // A tick, so the selected state survives being seen out of the
              // corner of the eye and is not carried by colour alone.
              if (selected) ...[
                const Icon(Icons.check, size: 14, color: StoreTheme.inkOnDark),
                const SizedBox(width: StoreTheme.spaceXs + 2),
              ],
              Text(
                label,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 0.1,
                  color: selected ? StoreTheme.inkOnDark : StoreTheme.ink,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// App-bar search action. Inside the shell it switches to the Search tab;
/// outside it falls back to a pushed route.
class _SearchAction extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: 'Search',
      icon: const Icon(Icons.search),
      onPressed: () {
        if (ShellSwitcher.maybeSwitchTo(context, ShellTab.search)) return;
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const SearchScreen()),
        );
      },
    );
  }
}

/// The sort menu. A quiet icon next to the count: the grid order is the
/// default everywhere else, so this is an affordance, not a control the
/// shopper must engage with.
class _SortButton extends StatelessWidget {
  const _SortButton({required this.value, required this.onChanged});

  final _Sort value;
  final ValueChanged<_Sort> onChanged;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<_Sort>(
      tooltip: 'Sort products',
      icon: const Icon(Icons.sort_rounded),
      initialValue: value,
      onSelected: onChanged,
      itemBuilder: (context) => [
        for (final entry in _sortLabels.entries)
          PopupMenuItem<_Sort>(
            value: entry.key,
            // A tick, so the current order is visible and not colour-bound.
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 26,
                  child: entry.key == value
                      ? const Icon(Icons.check,
                          size: 17, color: StoreTheme.accent)
                      : null,
                ),
                Text(entry.value),
              ],
            ),
          ),
      ],
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.onReset});

  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    return StoreEmptyState(
      icon: Icons.filter_alt_off_outlined,
      title: 'Nothing matches those filters',
      message: 'Try a different category, or show everything the shop carries.',
      actionLabel: 'Show everything',
      onAction: onReset,
    );
  }
}
