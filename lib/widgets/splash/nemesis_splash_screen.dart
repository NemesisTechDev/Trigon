import 'package:flutter/material.dart';

import 'splash_mark.dart';

/// Animated splash shown at app launch while [StartupScreen.getStartScreen]
/// resolves which real screen to show (Setup / Login / Home).
///
/// The launch starts as the app icon: gold ([_iconGold], the launcher icon's
/// background) with the black mark, at the centre of the screen, the same
/// size and position as the native splash (res/values*/styles.xml,
/// res/drawable/splash_icon.xml), so the launcher's zoom flows into it. From
/// there the colours switch smoothly to the splash's own look: the gold
/// background fades to pure black while the black mark turns gold. Then the
/// soft vertical shimmer glides across the mark. The shimmer always finishes
/// before the splash exits, and the exit is the same fade as before.
///
/// [future] is whatever async work decides the next screen - passed in
/// rather than started here, so this widget owns only the animation and
/// timing, not app-startup logic.
class NemesisSplashScreen extends StatefulWidget {
  const NemesisSplashScreen({
    super.key,
    required this.future,
    this.quick = false,
  });

  final Future<Widget> Function() future;

  /// Skips the colour change and the shimmer: the splash is only a plain
  /// holding screen until [future] resolves, then hands off at once. Used
  /// when Android recreates the app after killing it, which should feel like
  /// returning to the app, not starting it.
  final bool quick;

  @override
  State<NemesisSplashScreen> createState() => _NemesisSplashScreenState();
}

class _NemesisSplashScreenState extends State<NemesisSplashScreen>
    with TickerProviderStateMixin {
  /// One sweep: the band travels from fully off the left edge of the mark to
  /// fully off the right edge. SLOW on purpose (same speed as before: it used
  /// to be the first 72 % of a 6 s cycle).
  static const Duration _sweepDuration = Duration(milliseconds: 4320);

  // 0 -> 1 over exactly one sweep. At value 0 the band is fully off the left
  // of the mark and at value 1 fully off the right, so both the resting state
  // and the restart of a further sweep are invisible (no jump).
  late final AnimationController _shimmerController;
  late final Animation<double> _sweep;
  late final AnimationController _colorController;
  late final Animation<double> _colors;

  Widget? _resolvedScreen;
  bool _handoff = false;
  bool _sweepRunning = false;
  bool _firstSweepDone = false;

  @override
  void initState() {
    super.initState();

    _shimmerController = AnimationController(
      vsync: this,
      duration: _sweepDuration,
    );
    _sweep = Tween<double>(begin: -1.15, end: 1.15).animate(
      CurvedAnimation(
        parent: _shimmerController,
        curve: Curves.easeInOutSine,
      ),
    );

    _colorController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 380),
    );
    _colors = CurvedAnimation(
      parent: _colorController,
      curve: Curves.easeInOutCubic,
    );

    if (widget.quick) {
      _colorController.value = 1;
      _firstSweepDone = true;
    }

    _resolveNextScreen();
    _runShimmer();
  }

  Future<void> _resolveNextScreen() async {
    final screen = await widget.future();
    if (!mounted) return;
    _resolvedScreen = screen;
    _tryHandoff();
  }

  Future<void> _runShimmer() async {
    if (widget.quick) return;
    // A very short beat on the icon look, then the colours switch (quickly,
    // on an ease-in-out curve so it stays smooth), then the shimmer.
    await Future<void>.delayed(const Duration(milliseconds: 80));
    if (!mounted) return;
    await _colorController.forward();
    if (!mounted) return;
    await Future<void>.delayed(const Duration(milliseconds: 120));
    // Exactly ONE sweep, never a second. If the next screen is already
    // resolved when it ends, the hand-off starts right away; if not, the
    // splash simply stays on the finished mark (band parked off it) and
    // [_resolveNextScreen] hands off the moment the screen is ready.
    if (!mounted || _handoff) return;
    _sweepRunning = true;
    await _shimmerController.forward(from: 0.0);
    // (If the widget was disposed mid-sweep the future above never
    // completes, so nothing below runs for a disposed state.)
    if (!mounted) return;
    _sweepRunning = false;
    _firstSweepDone = true;
    _tryHandoff();
  }

  /// Exits the splash only when the next screen is ready AND the shimmer is
  /// not mid-sweep AND at least one full sweep has been seen.
  void _tryHandoff() {
    if (!mounted || _handoff) return;
    if (_resolvedScreen == null) return;
    if (!_firstSweepDone || _sweepRunning) return;
    setState(() => _handoff = true);
  }

  @override
  void dispose() {
    _shimmerController.dispose();
    _colorController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 450),
      switchInCurve: Curves.easeIn,
      switchOutCurve: Curves.easeOut,
      layoutBuilder: (currentChild, previousChildren) => Stack(
        fit: StackFit.expand,
        children: [...previousChildren, if (currentChild != null) currentChild],
      ),
      child: _handoff && _resolvedScreen != null
          ? KeyedSubtree(
              key: const ValueKey('resolved'),
              child: _resolvedScreen!,
            )
          : AnimatedBuilder(
              key: const ValueKey('splash'),
              animation: _colors,
              builder: (context, _) => ColoredBox(
                // Gold (the icon) -> pure black (the splash).
                color: Color.lerp(_iconGold, Colors.black, _colors.value)!,
                child: _SplashArt(sweep: _sweep, colors: _colors),
              ),
            ),
    );
  }
}

/// The app icon's gold (same value as ic_launcher_background in
/// res/values/ic_launcher_background.xml and the native splash background).
const Color _iconGold = Color(0xFFD4AF37);

class _SplashArt extends StatelessWidget {
  const _SplashArt({required this.sweep, required this.colors});

  final Animation<double> sweep;

  /// 0 = icon look (black mark), 1 = splash look (gold mark).
  final Animation<double> colors;

  // Warm, pale gold highlight (same RGB at 0% / ~85% alpha) - reads as
  // light catching polished gold rather than a white flash.
  static const _highlightClear = Color(0x00FFF1B8);
  static const _highlightPeak = Color(0xE6FFF1B8);

  Widget _mark() {
    final img = SplashMark.image;
    // Exactly the canvas the native splash draws (106 x 122 dp, visible mark
    // 102 x 118 dp with a transparent margin): same size, same centre, never
    // cropped. BoxFit.fill is safe because the canvas and the image have the
    // same aspect ratio.
    final double w = img != null ? SplashMark.logicalWidth : 128;
    final double h = img != null ? SplashMark.logicalHeight : 128;

    // The artwork itself is the gold mark.
    Widget art() => img != null
        ? RawImage(
            image: img,
            fit: BoxFit.fill,
            filterQuality: FilterQuality.high,
          )
        // Fallback only if the embedded mark failed to decode.
        : Image.asset('assets/images/nemesis_logo.png', fit: BoxFit.contain);

    return SizedBox(
      width: w,
      height: h,
      child: AnimatedBuilder(
        animation: colors,
        builder: (context, _) {
          final t = colors.value;
          // The icon look (black mark) turns into the gold mark by
          // cross-fading two copies of the same artwork.
          return Stack(
            fit: StackFit.expand,
            children: [
              if (t < 1)
                Opacity(
                  opacity: 1 - t,
                  child: ColorFiltered(
                    colorFilter:
                        const ColorFilter.mode(Colors.black, BlendMode.srcIn),
                    child: art(),
                  ),
                ),
              if (t > 0) Opacity(opacity: t, child: art()),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // The mark is centred (Center + fixed logical size, the same canvas the
    // native splash draws); only the shimmer overlay animates.
    return Center(
      child: RepaintBoundary(
        child: AnimatedBuilder(
          animation: sweep,
          child: _mark(),
          builder: (context, child) {
            final slide = sweep.value;
            // srcATop paints the moving highlight band ONLY where the
            // mark has pixels, so the shimmer runs along the gold
            // strokes and never lights up the black around them.
            return ShaderMask(
              blendMode: BlendMode.srcATop,
              shaderCallback: (Rect bounds) {
                return LinearGradient(
                  // Left -> right with NO vertical component: the colour
                  // only changes along x, so the band is perfectly
                  // vertical.
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                  colors: const [
                    _highlightClear,
                    _highlightPeak,
                    _highlightClear,
                  ],
                  stops: const [0.36, 0.5, 0.64],
                  transform: _SlideGradientTransform(slide),
                ).createShader(bounds);
              },
              child: child,
            );
          },
        ),
      ),
    );
  }
}

/// Slides a gradient horizontally by [slide] x the painted bounds' width
/// (-1.15 .. 1.15 puts the band fully off the mark on either side).
class _SlideGradientTransform extends GradientTransform {
  const _SlideGradientTransform(this.slide);

  final double slide;

  @override
  Matrix4? transform(Rect bounds, {TextDirection? textDirection}) {
    return Matrix4.translationValues(bounds.width * slide, 0.0, 0.0);
  }
}
