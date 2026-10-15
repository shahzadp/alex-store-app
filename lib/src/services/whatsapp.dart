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

/// Builds a `wa.me` link.
///
/// [message] is the pre-written text. It is URL-encoded here rather than at
/// each call site so that no screen can accidentally ship a link with raw
/// spaces or an un-escaped `&` — which truncates the message silently at the
/// first ampersand and drops the product name.
String whatsappLink({
  required String number,
  required String message,
}) {
  final digits = number.replaceAll(RegExp(r'[^0-9]'), '');
  return 'https://wa.me/$digits?text=${Uri.encodeComponent(message)}';
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