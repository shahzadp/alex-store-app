// The launch video is the one screen that can lock a shopper out of a working
// shop, so the things worth asserting about it are not "does it look right" but
// "does it always end".
//
// Three claims are checked here:
//
//  1. It plays — with the audio, at full volume — and hands over afterwards.
//  2. The fade it hands over through is the COMPOSITION'S OWN fade, frame for
//     frame. `AlexStore.tsx` fades out over frames 140->150 at 30 fps; if that
//     render ever changes, this is the test that says the app no longer matches
//     it, rather than a shopper noticing a stutter.
//  3. A video that never arrives still lets the app open. That is the failure
//     this widget most needs to survive, and it cannot be seen by eye because
//     it only happens on a device with something wrong.
//
// The fake below stands in for ExoPlayer through `VideoPlayerPlatform`. It is
// driven the way the real platform drives the controller — an `initialized`
// event carrying the clip's size and duration, then a reported position that
// reaches the end — so the test exercises the same code path a handset does,
// including the controller's own 100 ms position polling.
import 'dart:async';
import 'dart:io';

import 'package:alex_store/src/screens/splash_screen.dart';
import 'package:alex_store/src/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

/// The real clip: out/alex-store/video.mp4 — 1080x1920, 5.013 s.
const _clip = Duration(seconds: 5);
const _size = Size(1080, 1920);

void main() {
  group('the composition still fades the way the app expects', () {
    test('the overlay fade is the video\'s own fade, to the millisecond', () {
      // AlexStore.tsx: interpolate(frame, [140, 150], [1, 0]) at fps = 30.
      const fadeFrames = 150 - 140;
      const fps = 30;
      final composition = (Duration.millisecondsPerSecond * fadeFrames / fps).round();

      expect(
        SplashScreen.defaultFadeOut.inMilliseconds,
        composition,
        reason: 'the overlay would dissolve at a different speed than the '
            'video fades, which is the one thing "matching" means here',
      );
      expect(composition, 333);
    });
  });

  group('playing', () {
    late _FakeVideoPlayer native;

    setUp(() {
      native = _FakeVideoPlayer();
      VideoPlayerPlatform.instance = native;
    });

    testWidgets('plays with the audio, then hands over after the fade',
        (tester) async {
      var finished = 0;
      await tester.pumpWidget(_host(SplashScreen(onFinished: () => finished++)));
      await tester.pump();

      native.emitInitialized(duration: _clip, size: _size);
      await tester.pump();
      await tester.pump();

      expect(native.played, isTrue, reason: 'the splash must actually play');
      expect(native.volume, 1.0, reason: 'the clip has an audio sting and it is unmuted');
      expect(native.looping, isFalse, reason: 'a loop would never hand over');
      expect(find.byType(VideoPlayer), findsOneWidget);

      // Playback reaches the end. The controller polls position every 100 ms,
      // which is how a real completion arrives.
      native.position = native.duration;
      await tester.pump(const Duration(milliseconds: 150));

      expect(finished, 0,
          reason: 'the overlay must fade out, not vanish at the last frame');

      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();

      expect(finished, 1, reason: 'the app is handed over exactly once');

      await _teardown(tester);
    });

    testWidgets('covers the screen rather than letterboxing', (tester) async {
      await tester.pumpWidget(_host(SplashScreen(onFinished: () {})));
      await tester.pump();
      native.emitInitialized(duration: _clip, size: _size);
      await tester.pump();
      await tester.pump();

      final fitted = tester.widget<FittedBox>(
        find.descendant(
          of: find.byType(SplashScreen),
          matching: find.byType(FittedBox),
        ),
      );
      expect(fitted.fit, BoxFit.cover,
          reason: 'the clip is 9:16 and phones are taller; contain would put '
              'two edges on screen in the first thing the shopper sees');

      await _teardown(tester);
    });

    testWidgets('paints the video\'s opening gradient until the first frame',
        (tester) async {
      await tester.pumpWidget(_host(SplashScreen(onFinished: () {})));
      await tester.pump();

      // Nothing from the decoder yet: no black rectangle, the composition's own
      // opening gradient instead.
      expect(find.byType(VideoPlayer), findsNothing);

      final backdrop = tester.widget<DecoratedBox>(
        find
            .descendant(
              of: find.byType(SplashScreen),
              matching: find.byType(DecoratedBox),
            )
            .first,
      );
      final gradient =
          (backdrop.decoration as BoxDecoration).gradient! as LinearGradient;

      // The three stops are the three in AlexStore.tsx, and the same three the
      // Android window is set to in res/values/colors.xml.
      expect(gradient.colors, const [
        Color(0xFFF5F3FF),
        Color(0xFFFDF2F8),
        Color(0xFFECFEFF),
      ]);

      await _teardown(tester);
    });
  });

  group('failing', () {
    testWidgets('a decoder that reports an error still opens the shop',
        (tester) async {
      final native = _FakeVideoPlayer();
      VideoPlayerPlatform.instance = native;

      var finished = 0;
      await tester.pumpWidget(_host(SplashScreen(onFinished: () => finished++)));
      await tester.pump();

      native.emitError(PlatformException(code: 'VideoError', message: 'no decoder'));
      await tester.pump();
      await tester.pump();

      // The fade still runs, so the hand-over is not a jump cut.
      expect(finished, 0);
      await tester.pump(const Duration(milliseconds: 400));
      expect(finished, 1);

      await _teardown(tester);
    });

    testWidgets('a stall mid-playback is not allowed to hold the app hostage',
        (tester) async {
      final native = _FakeVideoPlayer();
      VideoPlayerPlatform.instance = native;

      var finished = 0;
      await tester.pumpWidget(_host(SplashScreen(onFinished: () => finished++)));
      await tester.pump();

      native.emitInitialized(duration: _clip, size: _size);
      await tester.pump();
      await tester.pump();

      // The position never advances, so completion is never reported. The
      // deadline is the only thing that ends this, and it must.
      expect(finished, 0);
      await tester.pump(_clip + SplashScreen.defaultFadeOut + const Duration(seconds: 2));
      await tester.pump(const Duration(milliseconds: 400));

      expect(finished, 1, reason: 'a stalled video must not strand the shopper');

      await _teardown(tester);
    });
  });

  group('the Android launch window', () {
    // Three surfaces have to agree on the same three stops, and only one of them
    // is in this file: the composition that rendered the video, the Android
    // window that covers the cold start before Flutter exists
    // (res/values/colors.xml), and the backdrop this widget paints while the
    // decoder warms up. If one drifts the launch shows a seam — a different
    // shade arriving a few hundred milliseconds in — and no single file is
    // wrong on its own, so nothing else would catch it.
    testWidgets('uses the same three stops as the in-app backdrop',
        (tester) async {
      final xml = File(
        'android/app/src/main/res/values/colors.xml',
      ).readAsStringSync();

      String declared(String name) {
        final match = RegExp(
          '<color name="$name">#([0-9A-Fa-f]{6})</color>',
        ).firstMatch(xml);
        expect(match, isNotNull, reason: 'colors.xml does not define $name');
        return match!.group(1)!.toUpperCase();
      }

      VideoPlayerPlatform.instance = _FakeVideoPlayer();
      await tester.pumpWidget(_host(SplashScreen(onFinished: () {})));
      await tester.pump();

      final backdrop = tester.widget<DecoratedBox>(
        find
            .descendant(
              of: find.byType(SplashScreen),
              matching: find.byType(DecoratedBox),
            )
            .first,
      );
      final painted = ((backdrop.decoration as BoxDecoration).gradient!
              as LinearGradient)
          .colors
          .map((c) => (c.toARGB32() & 0xFFFFFF)
              .toRadixString(16)
              .padLeft(6, '0')
              .toUpperCase())
          .toList();

      expect(
        [
          declared('splash_top'),
          declared('splash_mid'),
          declared('splash_bottom'),
        ],
        painted,
        reason: 'the Android launch window would show a different gradient '
            'from the one the app paints, so the start of the app would seam',
      );

      // And that the drawable actually references them: a colour defined but
      // never used would pass the check above and still show the default.
      final drawable = File(
        'android/app/src/main/res/drawable/launch_background.xml',
      ).readAsStringSync();
      for (final name in ['splash_top', 'splash_mid', 'splash_bottom']) {
        expect(drawable, contains('@color/$name'));
      }

      await _teardown(tester);
    });
  });
}

Widget _host(Widget child) =>
    MaterialApp(theme: StoreTheme.light(), home: child);

/// Unmounts the splash so the controller's position timer is cancelled.
///
/// Without this the test ends with a live `Timer.periodic`, which the test
/// binding reports as a failure in its own right.
Future<void> _teardown(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
}

/// Stands in for ExoPlayer.
///
/// Deliberately not a mock library: the controller's interaction with the
/// platform is small and the interesting part is the ORDER — initialized, then
/// a position that reaches the end — so it is written out rather than recorded.
class _FakeVideoPlayer extends VideoPlayerPlatform {
  final _events = StreamController<VideoEvent>.broadcast();

  Duration duration = _clip;
  Duration position = Duration.zero;

  bool played = false;
  bool looping = true;
  double? volume;

  @override
  Future<void> init() async {}

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async => 1;

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => _events.stream;

  @override
  Future<void> dispose(int playerId) async {}

  @override
  Future<void> setLooping(int playerId, bool looping) async {
    this.looping = looping;
  }

  @override
  Future<void> play(int playerId) async {
    played = true;
  }

  @override
  Future<void> pause(int playerId) async {}

  @override
  Future<void> setVolume(int playerId, double volume) async {
    this.volume = volume;
  }

  @override
  Future<void> seekTo(int playerId, Duration position) async {
    this.position = position;
  }

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}

  @override
  Future<Duration> getPosition(int playerId) async => position;

  @override
  Widget buildViewWithOptions(VideoViewOptions options) => const SizedBox.shrink();

  void emitInitialized({required Duration duration, required Size size}) {
    this.duration = duration;
    _events.add(VideoEvent(
      eventType: VideoEventType.initialized,
      duration: duration,
      size: size,
      rotationCorrection: 0,
      buffered: const <DurationRange>[],
    ));
  }

  void emitError(Object error) => _events.addError(error);
}
