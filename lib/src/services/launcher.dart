/// Opening external links.
///
/// Wrapped in one place so that a failure is handled once and consistently,
/// and so screens do not each import `url_launcher`. On a device with no
/// WhatsApp installed the OS offers a web fallback; if even that fails the
/// shopper sees a message rather than a button that does nothing — which is
/// worse than a button that clearly cannot work.
///
/// # Do NOT gate the launch on `canLaunchUrl`
///
/// [launch] used to be `canLaunchUrl(uri) && launchUrl(uri)`. That reads as
/// defensive and is the opposite: on Android 11+ (API 30) `canLaunchUrl`
/// answers from `Intent.resolveActivity`, which **package visibility** filters
/// off the real package list unless the scheme is declared in `<queries>`. So
/// it returned `false` for a plain `https://` link — and the button announced
/// *"No app on this device can open the link"* on a phone with both WhatsApp
/// and a browser installed, while `startActivity` would have opened it,
/// because *starting* an intent is not filtered the same way as *querying* for
/// one.
///
/// `launchUrl` is already the honest answer: url_launcher's Android plugin
/// calls `startActivity` and returns false when it catches the
/// `ActivityNotFoundException`. So the pre-check bought nothing and threw away
/// the launch it was guarding. `AndroidManifest.xml` declares both schemes
/// under `<queries>` as well, so the platform also *answers* capability
/// questions about them correctly — but nothing here depends on that answer.
library;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../theme.dart';
import 'whatsapp.dart';

/// Open [url]. Returns false if nothing could handle it.
///
/// Attempt-then-report, with no capability check in front of it — see the note
/// at the top of this file for what that check cost on Android 11+.
Future<bool> launch(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null) return false;
  try {
    return await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {
    // A URL the platform rejects, or a handler that throws instead of
    // returning false. Either way it did not open.
    return false;
  }
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