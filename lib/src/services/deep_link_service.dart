/// Opening the app from a website link.
///
/// The store's pages and the app are meant to be the same store. A shopper who
/// has the app installed and taps `shahzadp.github.io/store/product.html?slug=…`
/// in a browser should land on that product in the app, not have to find it.
///
/// # Status: the chooser works today, automatic redirect needs one server file
///
/// The app declares an intent filter for `https://shahzadp.github.io/store/*`
/// with `android:autoVerify="true"`, which already makes it appear in Android's
/// "Open with" chooser.
///
/// Going automatic — no chooser, straight into the app — additionally requires
/// `https://shahzadp.github.io/.well-known/assetlinks.json`. Android fetches
/// that from the domain ROOT, and it cannot be served from this setup: the
/// storefront is a GitHub Pages *project* repo, published under `/store/`, so
/// the root belongs to a *user* site repo (`shahzadp.github.io`) that does not
/// exist. Project Pages cannot place a file above their own path prefix.
///
/// To make it automatic, create that repo (or put a custom domain in front of
/// the storefront) and publish:
///
///   [{
///     "relation": ["delegate_permission/common.handle_all_urls"],
///     "target": {
///       "namespace": "android",
///       "package_name": "io.github.shahzadp.alex_store",
///       "sha256_cert_fingerprints": ["<SHA-256 of the signing certificate>"]
///     }
///   }]
///
/// The fingerprint is the one signing the APK. The release build currently uses
/// Flutter's DEBUG signing config (`android/app/build.gradle.kts`), so today it
/// is the debug keystore's — which changes per machine and is not something to
/// publish. Create a real release keystore first, then publish that fingerprint.
///
/// Nothing in this file changes when that file appears; the already-shipped
/// `autoVerify` flag starts working on its own.
library;

import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';

/// Extracts the product slug from a storefront URL, or null if the URL is not a
/// product page.
///
/// Handles the site's own format (`product.html?slug=x`) and a tidy path form
/// (`/store/product/x`), so both `product.html?slug=…` and a future
/// pretty URL are counted as the same link.
String? slugFromLink(String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null) return null;

  final host = uri.host;
  final isOurs = host == 'shahzadp.github.io';
  if (!isOurs) return null;

  final path = uri.path;
  // ?slug=stoneware-mug
  final fromQuery = uri.queryParameters['slug'];
  if (fromQuery != null && fromQuery.isNotEmpty) return fromQuery;

  // /store/product/stoneware-mug
  final match = RegExp(r'^/store/product/([^/?#]+)').firstMatch(path);
  if (match != null) return Uri.decodeComponent(match.group(1)!);

  return null;
}

/// Routes storefront links that arrive while the app is running or on cold
/// start.
///
/// [onProduct] is called with the slug. It receives the catalog-aware context it
/// needs, so a link tapped before the catalog has loaded is honoured rather
/// than dropped.
class DeepLinkService {
  DeepLinkService({AppLinks? appLinks}) : _appLinks = appLinks ?? AppLinks();

  final AppLinks _appLinks;
  StreamSubscription<Uri?>? _sub;

  /// A function of the incoming slug that navigates to the product.
  void Function(String slug)? onProduct;

  Future<void> start() async {
    // Cold start: the app was launched by the link.
    try {
      final initial = await _appLinks.getInitialLink();
      if (initial != null) _handle(initial);
    } catch (e, s) {
      debugPrint('could not read the initial link: $e\n$s');
    }

    // While running: a link opened from a browser on top of us.
    try {
      _sub = _appLinks.uriLinkStream.listen(
        _handle,
        onError: (Object e, StackTrace s) =>
            debugPrint('link stream error: $e\n$s'),
      );
    } catch (e, s) {
      debugPrint('could not listen for links: $e\n$s');
    }
  }

  void _handle(Uri uri) {
    final slug = slugFromLink(uri.toString());
    if (slug == null) return;
    onProduct?.call(slug);
  }

  void dispose() {
    _sub?.cancel();
    _sub = null;
  }
}