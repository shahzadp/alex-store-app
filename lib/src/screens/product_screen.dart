import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../catalog_scope.dart';
import '../services/catalog_service.dart';
import '../models/catalog.dart';
import '../services/launcher.dart';
import '../services/whatsapp.dart';
import '../theme.dart';
import '../widgets/product_image.dart';

/// One product.
///
/// # Layout follows the site's product page
///
/// MEMORY.md §3: "Product page = three regions. Product, a Specifications box
/// to its right on desktop, and a scrollable Full description box beneath."
/// On a phone the specs box moves under the product, which is the same reading
/// order as the desktop column.
///
/// # What is shown, and what is not
///
/// The site ships all three text fields (CATALOG-GUIDE.md §5):
///   * `description` — the one-line blurb, repeated under the price so the
///     product page does not force a scroll to find it;
///   * `details` — the long write-up, in the "Full description" box;
///   * `specs` — the structured table, omitted entirely when empty rather
///     than rendered as an empty box.
class ProductScreen extends StatelessWidget {
  const ProductScreen({super.key, required this.slug});

  final String slug;

  @override
  Widget build(BuildContext context) {
    final service = CatalogScope.of(context);

    return StreamBuilder<CatalogState>(
      stream: service.stream,
      initialData: service.state,
      builder: (context, snapshot) {
        final catalog = (snapshot.data ?? CatalogState.empty).catalog;
        final product = catalog?.bySlug(slug);

        // The catalog can be replaced by a refresh while this screen is open.
        // A slug that no longer exists is a deleted product, not an error to
        // crash on.
        if (product == null) {
          return Scaffold(
            appBar: AppBar(),
            body: const Center(child: Text('This product is no longer available.')),
          );
        }

        return Scaffold(
          appBar: AppBar(title: Text(product.name, maxLines: 1, overflow: TextOverflow.ellipsis)),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 120),
            children: [
              ProductImage(
                imageUrl: product.imageUrl,
                tint: product.tint,
                label: product.name,
                aspectRatio: 1.25,
              ),
              const SizedBox(height: 18),
              Text(product.name, style: Theme.of(context).textTheme.headlineMedium),
              const SizedBox(height: 6),
              _Category(category: product.category),
              const SizedBox(height: 14),
              _PriceBlock(product: product),
              const SizedBox(height: 14),
              Text(product.description, style: Theme.of(context).textTheme.bodyLarge),
              const SizedBox(height: 26),

              if (product.specs.isNotEmpty) ...[
                _Section(
                  title: 'Specifications',
                  child: _SpecsTable(specs: product.specs),
                ),
                const SizedBox(height: 18),
              ],

              _Section(
                title: 'Full description',
                // The long copy is inside a bounded, scrollable box on the
                // site so the specifications table stays visible. Same here —
                // otherwise this section pushes the WhatsApp button off-screen.
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 260),
                  child: SingleChildScrollView(
                    child: Text(
                      product.details.isEmpty ? product.description : product.details,
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: StoreTheme.inkBody),
                    ),
                  ),
                ),
              ),
            ],
          ),
          bottomNavigationBar: _WhatsAppBar(product: product),
        );
      },
    );
  }
}

class _Category extends StatelessWidget {
  const _Category({required this.category});

  final String category;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text('CATEGORY', style: Theme.of(context).textTheme.labelSmall),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            category,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(letterSpacing: 0),
          ),
        ),
      ],
    );
  }
}

class _PriceBlock extends StatelessWidget {
  const _PriceBlock({required this.product});

  final Product product;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (!product.inStock) {
      return Text(
        'Sold out',
        style: theme.textTheme.headlineSmall?.copyWith(color: StoreTheme.soldOut),
      );
    }

    return Text(product.price.formatted, style: theme.textTheme.headlineSmall);
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title.toUpperCase(), style: Theme.of(context).textTheme.labelSmall),
        const SizedBox(height: 8),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: StoreTheme.surface,
            border: Border.all(color: StoreTheme.line),
            borderRadius: BorderRadius.circular(3),
          ),
          child: child,
        ),
      ],
    );
  }
}

class _SpecsTable extends StatelessWidget {
  const _SpecsTable({required this.specs});

  final Map<String, String> specs;

  @override
  Widget build(BuildContext context) {
    final entries = specs.entries.toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < entries.length; i++) ...[
          if (i > 0) const SizedBox(height: 9),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                // A fixed label column keeps the values on one left edge,
                // which is what makes a two-column table readable. The web
                // does this with a grid; a fixed width is the same idea.
                width: 112,
                child: Text(
                  entries[i].key,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: StoreTheme.inkMuted),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(entries[i].value, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: StoreTheme.ink)),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

/// The purchase action, pinned above the system nav bar.
///
/// Sold-out products get a disabled control rather than a working WhatsApp
/// link: CATALOG-GUIDE.md §7 — sold out means `in_stock = 0` and the card says
/// so, rather than pretending to be purchasable.
class _WhatsAppBar extends StatelessWidget {
  const _WhatsAppBar({required this.product});

  final Product product;

  @override
  Widget build(BuildContext context) {
    final catalog = CatalogScope.of(context).state.catalog;

    return Container(
      decoration: const BoxDecoration(
        color: StoreTheme.bg,
        border: Border(top: BorderSide(color: StoreTheme.line)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
          child: Row(
            children: [
              // Secondary: copies the link. Narrow and quiet on purpose, so the
              // order action stays the obvious one.
              Expanded(
                flex: 3,
                child: product.inStock
                    ? FilledButton(
                        onPressed: () => openWhatsApp(
                          context: context,
                          number: catalog?.store.whatsapp ?? '',
                          message: product.whatsappMessage(
                              catalog?.store.name ?? 'Alex Store'),
                        ),
                        child: Text.rich(
                          whatsappButtonLabel(
                            'Order on ',
                            after: ' — ${product.price.formatted}',
                          ),
                        ),
                      )
                    : _SoldOutButton(),
              ),
              const SizedBox(width: 10),
              Tooltip(
                message: 'Copy link',
                child: OutlinedButton(
                  onPressed: () => _copyLink(context),
                  style: OutlinedButton.styleFrom(
                    // Square, because it holds only an icon.
                    padding: EdgeInsets.zero,
                    minimumSize: const Size(48, 48),
                  ),
                  child: const Icon(Icons.link, size: 20),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Copy the product's own web link to the clipboard.
  ///
  /// The link is the same URL the website uses, so it opens the product on the
  /// site for anyone, and offers the app to anyone who has it installed.
  Future<void> _copyLink(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: productPageUrl(product.slug)));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Text('Link copied'),
          duration: Duration(seconds: 2),
        ),
      );
  }
}

class _SoldOutButton extends StatelessWidget {
  const _SoldOutButton();

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      onPressed: null,
      child: Text(
        'Sold out',
        style: TextStyle(color: StoreTheme.soldOut.withValues(alpha: 1)),
      ),
    );
  }
}