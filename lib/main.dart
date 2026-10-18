import 'dart:async';

import 'package:flutter/material.dart';

import 'src/catalog_scope.dart';
import 'src/models/catalog.dart';
import 'src/models/price.dart';
import 'src/screens/home_screen.dart';
import 'src/screens/product_screen.dart';
import 'src/screens/splash_screen.dart';
import 'src/services/catalog_service.dart';
import 'src/services/deep_link_service.dart';
import 'src/services/voucher_store.dart';
import 'src/services/whatsapp.dart';
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
  final _navigatorKey = GlobalKey<NavigatorState>();
  late final DeepLinkService _deepLinks;

  /// Cleared when the launch video has played and faded out.
  bool _splashDone = false;

  @override
  void initState() {
    super.initState();
    _service = CatalogService();
    // Fire and forget. The first frame renders immediately and HomeScreen
    // shows a spinner off `service.stream` while this resolves — blocking on
    // the network would mean a white screen on a slow connection, which is the
    // single worst first impression a store can give.
    unawaited(_service.load());

    _deepLinks = DeepLinkService();
    _deepLinks.onProduct = _openProductFromLink;
    _deepLinks.start();
  }

  @override
  void dispose() {
    _deepLinks.dispose();
    _service.dispose();
    super.dispose();
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
    return CatalogScope(
      service: _service,
      child: MaterialApp(
        title: 'Alex Store',
        debugShowCheckedModeBanner: false,
        theme: StoreTheme.light(),
        navigatorKey: _navigatorKey,
        home: const HomeScreen(),
        // The launch video sits ON TOP of the app, not in place of it.
        //
        // `home` above is built on the very first frame, so the catalog fetch
        // and the whole home layout happen while the video plays. By the time
        // the video has faded out the shop is already painted underneath and
        // the reveal is instant. Any deep link that arrived during the splash
        // is likewise already pushed and waiting.
        //
        // Using MaterialApp's `builder` rather than a wrapper around it is what
        // gives the splash the app's Theme and MediaQuery, so it has the real
        // screen size and insets to lay the video out against.
        builder: (context, child) => Stack(
          fit: StackFit.expand,
          children: [
            if (child != null) child,
            // The claimable voucher, shown once over the shop. It is gated on
            // the splash so it does not fight the launch video for the first
            // impression; `enabled` flips true the moment the video is gone.
            //
            // It sits BELOW the splash in paint order so the video still covers
            // it during launch, and at a stable index so its seen-marker read is
            // not thrown away when the splash leaves the tree.
            _VoucherGate(enabled: _splashDone),
            if (!_splashDone) SplashScreen(onFinished: _onSplashFinished),
          ],
        ),
      ),
    );
  }

  /// The video is over. Drop the overlay; the app is already behind it.
  void _onSplashFinished() {
    if (!mounted || _splashDone) return;
    setState(() => _splashDone = true);
  }
}

/// Shows the free-delivery voucher once, and never again.
///
/// The old announcement strip said the same thing above every screen. This is
/// the same offer announced a single time. It waits for the splash AND for the
/// catalog — the wording lives in `catalog.json` so the app and the site cannot
/// disagree about it — and falls back to the plain threshold line when the
/// catalog carries no voucher copy, so the offer is never silently lost.
class _VoucherGate extends StatefulWidget {
  const _VoucherGate({required this.enabled});

  /// False until the launch video has finished. Nothing is read or shown before
  /// then.
  final bool enabled;

  @override
  State<_VoucherGate> createState() => _VoucherGateState();
}

class _VoucherGateState extends State<_VoucherGate> {
  final VoucherStore _store = VoucherStore();

  /// The seen-marker read. Null until the splash is done, so no disk work
  /// happens behind the video.
  Future<bool>? _seen;

  /// Latched once the shopper claims or dismisses, so the prompt does not come
  /// straight back on the next catalog frame.
  bool _done = false;

  @override
  void initState() {
    super.initState();
    if (widget.enabled) _seen = _store.hasSeen();
  }

  @override
  void didUpdateWidget(covariant _VoucherGate old) {
    super.didUpdateWidget(old);
    if (widget.enabled && !old.enabled) {
      setState(() => _seen = _store.hasSeen());
    }
  }

  @override
  Widget build(BuildContext context) {
    final seen = _seen;
    if (!widget.enabled || seen == null || _done) {
      return const SizedBox.shrink();
    }

    final service = CatalogScope.of(context);
    return FutureBuilder<bool>(
      future: seen,
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