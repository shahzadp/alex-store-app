// The order button on a handset that "cannot open the link" and is lying.
//
// This is the regression guard for a bug that could not be seen on the machine
// it was built on. The button did
//
//     canLaunchUrl(uri) && launchUrl(uri)
//
// and on Android 11+ (API 30) `canLaunchUrl` answers from
// `Intent.resolveActivity`, which package visibility filters before it reaches
// the package list, unless the scheme is declared in `<queries>`. It therefore
// said FALSE for `https://` itself — so the shopper got
//
//     Could not open WhatsApp
//     No app on this device can open the link.
//
// on a phone with both WhatsApp and a browser installed. On a handset whose
// Android reports handlers differently the same APK worked, which is the whole
// difficulty: the code was wrong, not the phone, and the phone could not say so.
//
// The fake below IS that handset: [canLaunch] answers false for every URL while
// [launchUrl] succeeds. Asserting that the button opens WhatsApp anyway is the
// same as asserting that nothing consults `canLaunchUrl` first. The other tests
// cover the two paths that must still exist — no WhatsApp (web fallback) and
// nothing at all (the dialog, and its retry).
import 'package:alex_store/src/services/launcher.dart';
import 'package:alex_store/src/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

const number = '923288304524';
const message = 'Hello, I have a question about your products.';

/// A platform that opens whatever it is told to and answers capability
/// questions however the test says — including the Android 11 lie.
class _FakeUrlLauncher extends UrlLauncherPlatform {
  /// What `canLaunchUrl` reports. False for everything is the Android 11+ case
  /// with no matching `<queries>` entry, and it is the default here on purpose.
  bool canHandle = false;

  /// URL prefixes that really open. Anything else throws
  /// `ActivityNotFoundException` on a device, which the plugin reports as
  /// `false` — so that is what this returns.
  List<String> opens = const [];

  final List<String> launched = [];
  int canLaunchCalls = 0;

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> canLaunch(String url) async {
    canLaunchCalls++;
    return canHandle;
  }

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    launched.add(url);
    return opens.any(url.startsWith);
  }
}

/// The button, in a real tree, so the dialog can actually be shown.
Widget _host(void Function(BuildContext) onPressed) => MaterialApp(
      theme: StoreTheme.light(),
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () => onPressed(context),
              child: const Text('order'),
            ),
          ),
        ),
      ),
    );

Future<void> _tap(WidgetTester tester) async {
  await tester.tap(find.text('order'));
  await tester.pumpAndSettle();
}

void main() {
  late _FakeUrlLauncher platform;

  setUp(() {
    platform = _FakeUrlLauncher();
    UrlLauncherPlatform.instance = platform;
  });

  void order(BuildContext context) =>
      openWhatsApp(context: context, number: number, message: message);

  testWidgets('opens WhatsApp even when the platform claims it cannot',
      (tester) async {
    // Both of these are false on the failing handset, WhatsApp installed or not.
    platform.canHandle = false;
    platform.opens = const ['whatsapp://'];

    await tester.pumpWidget(_host(order));
    await _tap(tester);

    expect(platform.canLaunchCalls, 0,
        reason: 'asking canLaunchUrl first is the bug: on Android 11+ it '
            'answers false for every scheme and the launch never happens');
    expect(platform.launched, hasLength(1));
    expect(platform.launched.single, startsWith('whatsapp://send?phone=$number'),
        reason: 'the app should be opened directly, not through a browser');
    expect(find.text('Could not open WhatsApp'), findsNothing);
  });

  testWidgets('falls back to wa.me when there is no WhatsApp app',
      (tester) async {
    // No WhatsApp: only the universal link opens, the browser still can.
    platform.canHandle = false;
    platform.opens = const ['https://'];

    await tester.pumpWidget(_host(order));
    await _tap(tester);

    expect(platform.launched, hasLength(2),
        reason: 'the app link has to be tried, and its failure has to fall '
            'through rather than end in the dialog');
    expect(platform.launched[0], startsWith('whatsapp://'));
    expect(platform.launched[1], startsWith('https://wa.me/$number'),
        reason: 'and the message has to be on the web link too, so the app '
            'path and the browser path send the same thing');
    expect(platform.launched[1], contains(Uri.encodeComponent(message)));
    expect(find.text('Could not open WhatsApp'), findsNothing);
  });

  testWidgets('only gives up when nothing at all can open it', (tester) async {
    platform.canHandle = false;
    platform.opens = const [];

    await tester.pumpWidget(_host(order));
    await _tap(tester);

    expect(platform.launched, hasLength(2),
        reason: 'the dialog is the last resort, not the first');
    expect(find.text('Could not open WhatsApp'), findsOneWidget);
    // The number is the fallback the shopper is told to use by hand, so it has
    // to be on screen — and in the international form WhatsApp accepts.
    expect(find.textContaining('+$number'), findsOneWidget);
  });

  testWidgets('"Try again" retries, and can succeed', (tester) async {
    platform.canHandle = false;
    platform.opens = const [];

    await tester.pumpWidget(_host(order));
    await _tap(tester);
    expect(find.text('Try again'), findsOneWidget);

    // The shopper installs WhatsApp, or the browser appears. Either way the
    // retry has to actually relaunch rather than just close the dialog.
    platform.opens = const ['https://'];
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();

    expect(platform.launched.last, startsWith('https://wa.me/$number'),
        reason: 'retrying a scheme that just failed would loop forever');
    expect(find.text('Could not open WhatsApp'), findsNothing);
  });
}
