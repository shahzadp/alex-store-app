/// WhatsApp — the store's only purchase path.
///
/// MEMORY.md §3: "WhatsApp is the only purchase path. No cart, no account, no
/// checkout." There is deliberately no basket anywhere in this app, and no
/// code that could grow one. Everything that looks like a "buy" button is a
/// `wa.me` link with the product, its price and its description already
/// written into the message.
///
/// The announcement strip carries the delivery threshold but no call to
/// action: on the site the CTA was removed as redundant noise, because
/// WhatsApp is already one tap away from everywhere on the page.
library;

import 'package:flutter/material.dart';

import '../theme.dart';

/// Builds a `wa.me` link.
///
/// [message] is the pre-written text, in PLAIN form. It is URL-encoded here
/// rather than at each call site so that no screen can accidentally ship a
/// link with raw spaces or an un-escaped `&` — which truncates the message
/// silently at the first ampersand and drops the product name.
///
/// **Encode exactly once.** `Product.whatsappMessage` used to return an
/// already-encoded string, so this encoded it a second time: a newline became
/// `%250A`, WhatsApp decoded it once, and the message arrived in the chat
/// showing a literal "%0A" instead of a line break. `whatsapp_link_test.dart`
/// fails if the message ever arrives pre-encoded again.
String whatsappLink({
  required String number,
  required String message,
}) {
  final digits = number.replaceAll(RegExp(r'[^0-9]'), '');
  return 'https://wa.me/$digits?text=${Uri.encodeComponent(message)}';
}

/// The same link, aimed at the installed WhatsApp app rather than a browser.
///
/// `wa.me` is a universal link: with the app installed Android opens WhatsApp
/// directly, but without it the shopper lands in a browser and the long
/// percent-encoded message is visible in the address bar while the page
/// redirects. `whatsapp://send` skips the redirect, and the browser path stays
/// as the fallback.
///
/// This still prefills rather than sends. WhatsApp requires the shopper to tap
/// send, by design; there is no URL that sends a message without them.
String whatsappAppLink({
  required String number,
  required String message,
}) {
  final digits = number.replaceAll(RegExp(r'[^0-9]'), '');
  return 'whatsapp://send?phone=$digits&text=${Uri.encodeComponent(message)}';
}

/// A button label with "WhatsApp" picked out in the site's accent green.
///
/// The site styles the word rather than the whole button: `.btn-solid` is the
/// purple accent, and inside it `.wa-word` is `--wa-green-on-accent`
/// (styles.css:61). The green used on the page background would reach only
/// 1.65:1 on the purple, so the site carries a lighter green for this surface
/// and this is where it lives in the app.
///
/// # Do not pass a base style
///
/// The spans deliberately carry NO colour of their own, so they inherit from
/// wherever the label is placed. An earlier version took a `base` style and
/// the call sites passed `DefaultTextStyle.of(context).style` — but that
/// context is the *screen's*, above the button, so the label inherited the
/// page's dark ink and rendered dark-on-purple while only the word
/// "WhatsApp" stayed legible. Inside a button the ambient DefaultTextStyle is
/// already the button's foreground, so inheriting is both simpler and correct:
/// a light button gets light text and a dark one gets dark text, with no
/// call site able to get it wrong.
///
/// [before] and [after] are the plain-text parts, either of which may be empty.
TextSpan whatsappButtonLabel(String before, {String after = ''}) {
  return TextSpan(
    children: [
      if (before.isNotEmpty) TextSpan(text: before),
      const TextSpan(
        text: 'WhatsApp',
        style: TextStyle(color: StoreTheme.whatsappOnAccent),
      ),
      if (after.isNotEmpty) TextSpan(text: after),
    ],
  );
}

/// The announcement strip text.
///
/// Says only the delivery threshold. Returns null when there is no threshold
/// configured, so the caller can omit the bar entirely rather than render an
/// empty one — an announcement bar that says nothing is worse than no bar.
String? announcementFor({required int freeDeliveryOverPaisa, required PriceFormatter format}) {
  if (freeDeliveryOverPaisa <= 0) return null;
  return 'Free delivery over ${format(freeDeliveryOverPaisa)}';
}

/// Indirection over `Price.formatted` so this file does not depend on the
/// model layer — keeping the link builder usable from tests and from the
/// service layer alike.
typedef PriceFormatter = String Function(int paisa);