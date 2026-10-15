/// Opening external links.
///
/// Wrapped in one place so that a failure is handled once and consistently,
/// and so screens do not each import `url_launcher`. On a device with no
/// WhatsApp installed the OS offers a web fallback; if even that fails the
/// shopper sees a message rather than a button that does nothing — which is
/// worse than a button that clearly cannot work.
library;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../theme.dart';
import 'whatsapp.dart';

/// Open [url]. Returns false if nothing could handle it.
Future<bool> launch(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null) return false;
  try {
    if (await canLaunchUrl(uri)) return await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {
    return false;
  }
  return false;
}

/// Launch a `wa.me` link, telling the shopper if it could not be opened.
///
/// WhatsApp is the only purchase path in this store (MEMORY.md §3), so a
/// silently-dead button here means a lost sale with no explanation.
///
/// Tries `whatsapp://send` first so the app opens directly, then falls back to
/// the `https://wa.me` universal link for devices without WhatsApp installed.
/// Either way the message is PREFILLED and the shopper taps send — WhatsApp
/// offers no way to send on someone's behalf.
Future<void> openWhatsApp({
  required BuildContext context,
  required String number,
  required String message,
}) async {
  final direct = whatsappAppLink(number: number, message: message);
  final opened = await launch(direct);
  if (opened || !context.mounted) return;

  final openedWeb = await launch(whatsappLink(number: number, message: message));
  if (openedWeb || !context.mounted) return;

  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      backgroundColor: StoreTheme.surface,
      title: const Text('Could not open WhatsApp'),
      content: Text(
        'No app on this device can open the link.\n\n'
        'Message the shop on +$number instead.',
        style: Theme.of(context).textTheme.bodyMedium,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
        TextButton(
          onPressed: () async {
            Navigator.of(context).pop();
            await launch('https://wa.me/$number');
          },
          child: const Text('Try again'),
        ),
      ],
    ),
  );
}