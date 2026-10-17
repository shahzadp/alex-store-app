import 'dart:async';

import 'package:flutter/material.dart';

import 'src/catalog_scope.dart';
import 'src/models/catalog.dart';
import 'src/screens/home_screen.dart';
import 'src/screens/product_screen.dart';
import 'src/screens/splash_screen.dart';
import 'src/services/catalog_service.dart';
import 'src/services/deep_link_service.dart';
import 'src/theme.dart';

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