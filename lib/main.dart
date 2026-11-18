import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import 'src/catalog_scope.dart';
import 'src/models/catalog.dart';
import 'src/models/price.dart';
import 'src/screens/main_shell.dart';
import 'src/screens/product_screen.dart';
import 'src/services/catalog_service.dart';
import 'src/services/deep_link_service.dart';
import 'src/services/local_stores.dart';
import 'src/services/voucher_store.dart';
import 'src/services/whatsapp.dart';
import 'src/store_scope.dart';
import 'src/theme.dart';
import 'src/widgets/voucher_prompt.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const AlexStoreApp());
}

class AlexStoreApp extends StatefulWidget {
  const AlexStoreApp({super.key});

  @override
  State<AlexStoreApp> createState() => _AlexStoreAppState();
}

class _AlexStoreAppState extends State<AlexStoreApp> {
  late final CatalogService _service;
  late final SavedStore _saved;
  late final RecentStore _recent;
  final _navigatorKey = GlobalKey<NavigatorState>();
  late final DeepLinkService _deepLinks;

  @override
  void initState() {
    super.initState();
    _service = CatalogService();
    // Fire and forget. The first frame renders immediately and the tab shell
    // shows skeletons off `service.stream` while this resolves — blocking on
    // the network would mean a white screen on a slow connection, which is the
    // single worst first impression a store can give.
    //
    // The `.then` warms the disk image cache for every catalogue image, so the
    // first paint of the grid lands photographs instead of tint placeholders.
    unawaited(_service.load().then(_prewarmImages));

    _saved = SavedStore();
    _recent = RecentStore();
    unawaited(_saved.load());
    unawaited(_recent.load());

    _deepLinks = DeepLinkService();
    _deepLinks.onProduct = _openProductFromLink;
    _deepLinks.start();
  }

  @override
  void dispose() {
    _deepLinks.dispose();
    _service.dispose();
    _saved.dispose();
    _recent.dispose();
    super.dispose();
  }

  /// Warm the disk image cache for every image the storefront will draw —
  /// products and the collections strip — so the first paint lands photographs
  /// instead of tint placeholders. Runs once, after the catalog lands; keeps
  /// nothing, and failures are swallowed (a slow image still renders, just
  /// later).
  void _prewarmImages(CatalogState state) {
    final catalog = state.catalog;
    if (catalog == null) return;

    final context = _navigatorKey.currentContext;
    if (context == null) return;

    final urls = <String?>[
      for (final product in catalog.products) product.imageUrl,
      for (final collection in catalog.collections) collection.imageUrl,
    ];

    for (final url in urls) {
      if (url == null || url.isEmpty) continue;
      unawaited(
        precacheImage(CachedNetworkImageProvider(url), context)
            .catchError((_) {}),
      );
    }
  }

  /// Open the product a website link pointed at.
  ///
  /// The catalog may still be loading when the link arrives — it is fetched on
  /// launch and a link can beat it. Waiting on the stream means the shopper
  /// lands on the product instead of an error saying it is gone.
  void _openProductFromLink(String slug) {
    if (_service.state.catalog?.bySlug(slug) != null) {
      _pushProduct(slug);
      return;
    }
    _service.stream
        .map<Product?>((s) => s.catalog?.bySlug(slug))
        .firstWhere((p) => p != null)
        .timeout(const Duration(seconds: 20), onTimeout: () => null)
        .then((p) {
      if (p != null) _pushProduct(slug);
    });
  }

  void _pushProduct(String slug) {
    _navigatorKey.currentState?.push(MaterialPageRoute<void>(
      builder: (_) => ProductScreen(slug: slug),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return StoreScope(
      saved: _saved,
      recent: _recent,
      child: CatalogScope(
        service: _service,
        child: MaterialApp(
          title: 'Alex Store',
          debugShowCheckedModeBanner: false,
          theme: StoreTheme.light(),
          navigatorKey: _navigatorKey,
          home: const MainShell(),
          // The launch video used to sit ON TOP of the app via this overlay
          // builder. It is gone (2026-11-18): the intro was repetitive and
          // slowed every cold start. The Android 12 system splash is the
          // entire pre-Flutter surface now.
          builder: (context, child) => Stack(
            fit: StackFit.expand,
            children: [
              if (child != null) child,
              // The claimable voucher, shown once over the shop.
              const _VoucherGate(),
            ],
          ),
        ),
      ),
    );
  }
}

/// Shows the free-delivery voucher once, and never again.
///
/// The old announcement strip said the same thing above every screen. This is
/// the same offer announced a single time. It waits for the catalog — the
/// wording lives in `catalog.json` so the app and the site cannot disagree
/// about it — and falls back to the plain threshold line when the catalog
/// carries no voucher copy, so the offer is never silently lost.
class _VoucherGate extends StatefulWidget {
  const _VoucherGate();

  @override
  State<_VoucherGate> createState() => _VoucherGateState();
}

class _VoucherGateState extends State<_VoucherGate> {
  final VoucherStore _store = VoucherStore();

  late final Future<bool> _seen;

  /// Latched once the shopper claims or dismisses, so the prompt does not come
  /// straight back on the next catalog frame.
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _seen = _store.hasSeen();
  }

  @override
  Widget build(BuildContext context) {
    if (_done) return const SizedBox.shrink();

    final service = CatalogScope.of(context);
    return FutureBuilder<bool>(
      future: _seen,
      builder: (context, seenSnapshot) {
        // Unknown or already seen: show nothing. An error reading the marker
        // fails open in the same direction as `hasSeen` — see VoucherStore.
        if (seenSnapshot.data != false) return const SizedBox.shrink();

        return StreamBuilder<CatalogState>(
          stream: service.stream,
          initialData: service.state,
          builder: (context, snapshot) {
            final catalog = (snapshot.data ?? CatalogState.empty).catalog;
            if (catalog == null) return const SizedBox.shrink();

            final voucher = catalog.store.voucher;
            final fallback = announcementFor(
              freeDeliveryOverPaisa: catalog.store.freeDeliveryOver.paisa,
              format: (paisa) => Price.paisa(paisa).formatted,
            );
            final title = voucher.isEmpty ? fallback : voucher.title;
            if (title == null || title.isEmpty) return const SizedBox.shrink();

            return VoucherPrompt(
              title: title,
              description: voucher.description,
              code: voucher.code,
              terms: voucher.terms,
              // Marked seen whether it is claimed or dismissed: the offer is a
              // first-visit gesture, not a nag the shopper has to keep closing.
              onClose: (_) {
                _store.markSeen();
                setState(() => _done = true);
              },
            );
          },
        );
      },
    );
  }
}
