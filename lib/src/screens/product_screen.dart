import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../catalog_scope.dart';
import '../services/catalog_service.dart';
import '../models/catalog.dart';
import '../models/price.dart';
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
class ProductScreen extends StatefulWidget {
  const ProductScreen({super.key, required this.slug});

  final String slug;

  @override
  State<ProductScreen> createState() => _ProductScreenState();
}

class _ProductScreenState extends State<ProductScreen> {
  /// Chosen add-ons, by key. A preference, never a price: it is carried into the
  /// WhatsApp message and nothing else. Nothing is selected to begin with, so
  /// the buyer opts in rather than out — matching the site's unticked boxes.
  final Set<String> _selected = <String>{};

  void _setOption(String key, bool on) {
    setState(() {
      if (on) {
        _selected.add(key);
      } else {
        _selected.remove(key);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final service = CatalogScope.of(context);

    return StreamBuilder<CatalogState>(
      stream: service.stream,
      initialData: service.state,
      builder: (context, snapshot) {
        final catalog = (snapshot.data ?? CatalogState.empty).catalog;
        final product = catalog?.bySlug(widget.slug);

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
          appBar: AppBar(
            title: Text(product.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          body: ListView(
            padding: EdgeInsets.fromLTRB(
                StoreTheme.screenEdge, 4, StoreTheme.screenEdge,
                120 + StoreTheme.bottomSafeInset(context)),
            children: [
              ProductImage(
                imageUrl: product.imageUrl,
                tint: product.tint,
                label: product.name,
                aspectRatio: 1.25,
                heroTag: 'product-image-${product.slug}',
              ),
              const SizedBox(height: StoreTheme.spaceLg),
              Text(product.name, style: Theme.of(context).textTheme.headlineMedium),
              const SizedBox(height: StoreTheme.spaceSm),
              _Category(category: product.category),
              const SizedBox(height: StoreTheme.spaceMd),
              _PriceBlock(
                product: product,
                // The delivery-included total, shown struck through beside the
                // price. Null when the catalog sets no delivery percentage.
                included: catalog?.store.deliveryIncluded(product.price),
              ),
              const SizedBox(height: StoreTheme.spaceLg),
              Text(product.description,
                  style: Theme.of(context).textTheme.bodyLarge),
              if (product.options.isNotEmpty) ...[
                const SizedBox(height: StoreTheme.spaceLg),
                _Options(
                  options: product.options,
                  selected: _selected,
                  onChanged: _setOption,
                ),
              ],
              const SizedBox(height: StoreTheme.spaceXxl),

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
          bottomNavigationBar:
              _WhatsAppBar(product: product, selected: _selected),
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
    final theme = Theme.of(context);
    return Row(
      children: [
        Text('CATEGORY', style: theme.textTheme.labelSmall),
        const SizedBox(width: StoreTheme.spaceMd),
        Container(width: 1, height: 11, color: StoreTheme.line),
        const SizedBox(width: StoreTheme.spaceMd),
        Flexible(
          child: Text(
            category,
            style: theme.textTheme.bodySmall?.copyWith(
              letterSpacing: 0,
              color: StoreTheme.ink,
            ),
          ),
        ),
      ],
    );
  }
}

class _PriceBlock extends StatelessWidget {
  const _PriceBlock({required this.product, this.included});

  final Product product;

  /// The price with delivery added, struck through before the price itself, or
  /// null when the catalog sets no delivery percentage.
  final Price? included;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (!product.inStock) {
      return Row(
        children: [
          Text(
            'Sold out',
            style: theme.textTheme.headlineSmall?.copyWith(color: StoreTheme.soldOut),
          ),
          const SizedBox(width: StoreTheme.spaceMd),
          Text(
            'This product cannot be ordered right now.',
            style: theme.textTheme.bodySmall,
          ),
        ],
      );
    }

    // The price is the loudest thing under the name, which is where a shopper
    // looks for it and where every shop they have used puts it.
    final now = Text(
      product.price.formatted,
      style: theme.textTheme.headlineMedium?.copyWith(
        color: StoreTheme.ink,
        letterSpacing: -0.4,
      ),
    );

    if (included == null) return now;

    // Wrap rather than Row: if both figures will not fit they fall onto a
    // second line instead of overflowing, which is the only place on this
    // screen either could be long enough to matter.
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: StoreTheme.spaceSm,
      children: [
        Semantics(
          // Mirrors the site's `aria-label` on `.price__was`, so the strikethrough
          // is explained rather than read as a second price.
          label: '${included!.formatted} including delivery',
          excludeSemantics: true,
          child: Text(
            included!.formatted,
            style: theme.textTheme.headlineMedium?.copyWith(
              // 0.92em of the 24px price, the site's own ratio.
              fontSize: 22,
              fontWeight: FontWeight.w400,
              color: StoreTheme.inkMuted,
              decoration: TextDecoration.lineThrough,
              decorationColor: StoreTheme.inkMuted,
            ),
          ),
        ),
        now,
      ],
    );
  }
}

/// Selectable add-ons, such as a cold drink.
///
/// A preference, not a price: the choice — and any surcharge, shown beneath the
/// name — is carried into the WhatsApp message and never changes the total on
/// the page, so a tick is an answer to the shop rather than a line on the bill.
/// Nothing is ticked to begin with — the buyer opts in.
class _Options extends StatelessWidget {
  const _Options({
    required this.options,
    required this.selected,
    required this.onChanged,
  });

  final List<ProductOption> options;
  final Set<String> selected;
  final void Function(String key, bool on) onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('ADD-ONS', style: theme.textTheme.labelSmall),
        const SizedBox(height: StoreTheme.spaceMd),
        // The card look (border, radius, lift) is on the Container; the surface
        // colour is on the Material inside it. A ListTile paints its ink on the
        // nearest Material, and a coloured DecoratedBox between the two would
        // swallow every splash.
        Container(
          width: double.infinity,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            border: Border.all(color: StoreTheme.line),
            borderRadius: StoreTheme.rMd,
            boxShadow: StoreTheme.shadowSm,
          ),
          child: Material(
            color: StoreTheme.surface,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: StoreTheme.spaceMd,
                vertical: StoreTheme.spaceSm,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final option in options)
                    CheckboxListTile(
                      value: selected.contains(option.key),
                      onChanged: (v) => onChanged(option.key, v ?? false),
                      title:
                          Text(option.label, style: theme.textTheme.bodyMedium),
                      subtitle: _meta(option, theme),
                      controlAffinity: ListTileControlAffinity.leading,
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      visualDensity: VisualDensity.compact,
                      activeColor: StoreTheme.accent,
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// "500ml · + Rs 100" under an add-on's name, or null when it carries
  /// neither. The surcharge is shown here, on the choice, rather than folded
  /// into the price above — the page price never changes with a choice.
  Widget? _meta(ProductOption option, ThemeData theme) {
    final parts = <String>[
      if (option.desc.isNotEmpty) option.desc,
      if (option.price.paisa > 0) '+ ${option.price.formatted}',
    ];
    if (parts.isEmpty) return null;
    return Text(parts.join(' · '), style: theme.textTheme.bodySmall);
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
        const SizedBox(height: StoreTheme.spaceMd),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(StoreTheme.spaceLg),
          decoration: BoxDecoration(
            color: StoreTheme.surface,
            border: Border.all(color: StoreTheme.line),
            // A card, not a box: the shadow lifts it off the page background
            // which is the same colour as the section, so a flat border alone
            // left it looking pasted on.
            borderRadius: StoreTheme.rMd,
            boxShadow: StoreTheme.shadowSm,
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
          // A hairline between rows rather than a gap, so the table reads as
          // one object with rows rather than as a list of loose pairs.
          if (i > 0)
            const Divider(height: StoreTheme.spaceLg + 1, thickness: 1),
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
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: StoreTheme.inkMuted),
                ),
              ),
              const SizedBox(width: StoreTheme.spaceMd),
              Expanded(
                child: Text(
                  entries[i].value,
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(color: StoreTheme.ink),
                ),
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
  const _WhatsAppBar({required this.product, required this.selected});

  final Product product;

  /// Chosen add-on keys. Stated in the message either way, matching the site.
  final Set<String> selected;

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
                              catalog?.store.name ?? 'Alex Store',
                              selectedOptions: selected),
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