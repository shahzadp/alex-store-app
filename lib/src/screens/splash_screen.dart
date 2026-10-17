import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

/// The shop's opening video, played once as the app starts.
///
/// This is the app's splash screen. It replaces the blank Android launch window
/// with the composition that the storefront already uses â€” the mark, the name,
/// the underline â€” together with its audio.
///
/// # It is an overlay, not a route
///
/// It is stacked ABOVE `MaterialApp`'s navigator rather than pushed onto it, so
/// the store is built from the very first frame underneath. The catalog fetch
/// starts while the video plays and the shop is already laid out when the video
/// ends; nothing is waiting on the video except the reveal. A pushed route would
/// hold the fetch back for the length of the clip and then show a loading state,
/// which is the opposite of what a splash is for.
///
/// # The fade matches the composition's own
///
/// `AlexStore.tsx` fades the whole composition out over its last 10 frames â€”
/// 333 ms at 30 fps â€” ending on black. [fadeOut] is the same 333 ms, so once
/// playback ends the overlay dissolves over exactly that long and then removes
/// itself. The hand-off reads as one continuous fade rather than the video
/// stopping and the shop appearing.
///
/// # Nothing here may trap the shopper
///
/// A splash is the one screen that can lock a user out of a working app, so
/// every path out of this widget ends in [SplashScreen.onFinished]: a decoder
/// that never reports completion, an asset that will not load, or a stall
/// mid-playback all fall through a deadline rather than hanging. See [_finish].
class SplashScreen extends StatefulWidget {
  const SplashScreen({
    super.key,
    required this.onFinished,
    this.assetPath = defaultAsset,
    this.fadeOut = defaultFadeOut,
  });

  /// The published composition. Rendered by Remotion from
  /// `Remotion/src/compositions/AlexStore/AlexStore.tsx`, 1080x1920, 30 fps,
  /// 150 frames.
  static const defaultAsset = 'assets/splash/alex-store.mp4';

  /// Frames 140-150 of that composition, which is its own fade-out.
  static const defaultFadeOut = Duration(milliseconds: 333);

  /// Called once the video has played and the overlay has faded away.
  final VoidCallback onFinished;

  final String assetPath;
  final Duration fadeOut;

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  /// The composition's opening frame, as a gradient.
  ///
  /// `AlexStore.tsx` paints a radial gradient of `#f5f3ff -> #fdf2f8 ->
  /// #ecfeff` and this is the same three stops. Painting it behind the texture
  /// covers the gap between Flutter's first frame and the decoder's first frame
  /// â€” a few hundred milliseconds on a cold start â€” so the launch is a single
  /// uninterrupted surface instead of a flash of something else.
  ///
  /// Linear rather than radial: over that gap the difference is invisible, and
  /// `background: radial-gradient(1200px 1600px ...)` in a 1080x1920 frame is
  /// close to a vertical wash anyway.
  static const _backdrop = BoxDecoration(
    gradient: LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [Color(0xFFF5F3FF), Color(0xFFFDF2F8), Color(0xFFECFEFF)],
      stops: [0.0, 0.45, 1.0],
    ),
  );

  late final VideoPlayerController _video;
  late final AnimationController _fade;

  /// Fires if the video never gets to the end on its own. Replaced once the
  /// real duration is known.
  Timer? _deadline;

  bool _ready = false;
  bool _finishing = false;

  @override
  void initState() {
    super.initState();

    _fade = AnimationController(
      vsync: this,
      duration: widget.fadeOut,
      value: 1,
    )..addStatusListener((status) {
        // The overlay is gone; the app underneath is already built.
        if (status == AnimationStatus.dismissed) widget.onFinished();
      });

    _video = VideoPlayerController.asset(widget.assetPath)
      ..addListener(_onVideoTick);

    // Deliberately short for the load only. It is replaced below with one sized
    // to the actual clip.
    _deadline = Timer(const Duration(seconds: 8), _finish);

    unawaited(_start());
  }

  Future<void> _start() async {
    try {
      await _video.initialize();
      // The sting, at full media volume. Unmuted on purpose: the clip is five
      // seconds of the shop's own audio and it was asked for. `video_player`
      // installs its own lifecycle observer, so this pauses if the shopper
      // leaves the app mid-splash and resumes when they come back.
      await _video.setVolume(1);
      await _video.setLooping(false);
      if (!mounted) return;

      setState(() => _ready = true);

      // Now that the length is known, replace the load deadline: the clip, plus
      // its fade, plus a second of slack for a decoder that stalls near the end.
      _deadline?.cancel();
      _deadline = Timer(
        _video.value.duration + widget.fadeOut + const Duration(seconds: 1),
        _finish,
      );

      await _video.play();
    } catch (_) {
      // An unreadable video is not a reason for a shopper to be unable to open
      // the shop. Skip straight to the fade.
      _finish();
    }
  }

  /// Playback ended, failed, or ran out of time. Dissolve, then hand over.
  void _finish() {
    if (_finishing) return;
    _finishing = true;
    _deadline?.cancel();
    _deadline = null;
    if (!mounted) return;
    _fade.reverse();
  }

  void _onVideoTick() {
    final value = _video.value;
    if (value.isInitialized && value.isCompleted) _finish();
  }

  @override
  void dispose() {
    _deadline?.cancel();
    _video
      ..removeListener(_onVideoTick)
      // Disposing is also what stops the audio. A controller left alive would
      // keep playing the sting over the shop.
      ..dispose();
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = _video.value.size;

    return FadeTransition(
      opacity: _fade,
      child: DecoratedBox(
        decoration: _backdrop,
        child: SizedBox.expand(
          child: !_ready || size.isEmpty
              ? const SizedBox.shrink()
              // cover, not contain: the clip is 1080x1920 and phones are taller
              // (20:9 is common), so filling the screen crops the gradient at
              // the sides. Letterboxing the opening frame would put two edges
              // on screen in the first thing the shopper sees.
              : FittedBox(
                  fit: BoxFit.cover,
                  clipBehavior: Clip.hardEdge,
                  child: SizedBox(
                    width: size.width,
                    height: size.height,
                    child: VideoPlayer(_video),
                  ),
                ),
        ),
      ),
    );
  }
}
