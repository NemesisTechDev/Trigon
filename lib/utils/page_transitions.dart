import 'package:flutter/material.dart';

/// The app-wide page transition: the new page slides in from the right
/// while the page underneath drifts a short way left (a parallax), with
/// no fading, scaling or edge-swipe gesture involved.
///
/// Why not the Material defaults: both the zoom and the fade-forwards
/// builders fade/scale the incoming page AND the outgoing page, which
/// makes the GPU re-composite two full-screen pages (hero images,
/// blurred artwork, long lists) through off-screen layers on every frame
/// of the transition — the "not buttery" push/pop. This one only moves
/// existing, already-painted layers sideways (a pure translation, no
/// opacity layers), which stays at full frame rate even on heavy
/// screens.
///
/// Unlike [CupertinoPageTransitionsBuilder] it deliberately does not
/// attach the iOS-style left-edge swipe-to-pop gesture: the full-screen
/// players use the left edge for gestures of their own, and Android's
/// system back gesture already covers that edge.
class NemesisPageTransitionsBuilder extends PageTransitionsBuilder {
  const NemesisPageTransitionsBuilder();

  // Longer than Material's fixed 300ms. The curve used to be
  // fastEaseInToSlowEaseOut, which Cupertino pairs with a 500ms
  // duration; squeezed into 300ms it covered most of the screen in the
  // first handful of frames (a ~15% -of-width hop per frame), which
  // reads as stepping rather than gliding. Honoured by MaterialPageRoute
  // on Flutter versions where PageTransitionsBuilder exposes durations;
  // on older ones the curve below still smooths the 300ms default.
  Duration get transitionDuration => const Duration(milliseconds: 380);

  Duration get reverseTransitionDuration => const Duration(milliseconds: 320);

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return _NemesisSlideTransition(
      animation: animation,
      secondaryAnimation: secondaryAnimation,
      child: child,
    );
  }
}

class _NemesisSlideTransition extends StatefulWidget {
  const _NemesisSlideTransition({
    required this.animation,
    required this.secondaryAnimation,
    required this.child,
  });

  final Animation<double> animation;
  final Animation<double> secondaryAnimation;
  final Widget child;

  @override
  State<_NemesisSlideTransition> createState() =>
      _NemesisSlideTransitionState();
}

class _NemesisSlideTransitionState extends State<_NemesisSlideTransition> {
  // Incoming page: from one full width to the right, to rest.
  static final Animatable<Offset> _enter = Tween<Offset>(
    begin: const Offset(1.0, 0.0),
    end: Offset.zero,
  );

  // Page underneath: from rest, a third of its width to the left.
  static final Animatable<Offset> _exit = Tween<Offset>(
    begin: Offset.zero,
    end: const Offset(-0.3, 0.0),
  );

  // Gentle ease-out (easeOutQuad-shaped): finite starting speed, then
  // a long soft landing, so per-frame travel stays small and even. The
  // reverse is its mirror image (flipped), so popping starts moving
  // immediately and settles softly, instead of dwelling at the start
  // the way the same curve played backwards would.
  static const Curve _curve = Cubic(0.25, 0.46, 0.45, 0.94);

  late _SteadyStartAnimation _primaryClock;
  late _SteadyStartAnimation _secondaryClock;
  late CurvedAnimation _primary;
  late CurvedAnimation _secondary;

  @override
  void initState() {
    super.initState();
    _createCurves();
  }

  @override
  void didUpdateWidget(covariant _NemesisSlideTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animation != widget.animation ||
        oldWidget.secondaryAnimation != widget.secondaryAnimation) {
      _disposeCurves();
      _createCurves();
    }
  }

  @override
  void dispose() {
    _disposeCurves();
    super.dispose();
  }

  void _createCurves() {
    _primaryClock = _SteadyStartAnimation(widget.animation);
    _secondaryClock = _SteadyStartAnimation(widget.secondaryAnimation);
    _primary = CurvedAnimation(
      parent: _primaryClock,
      curve: _curve,
      reverseCurve: _curve.flipped,
    );
    _secondary = CurvedAnimation(
      parent: _secondaryClock,
      curve: _curve,
      reverseCurve: _curve.flipped,
    );
  }

  void _disposeCurves() {
    _primary.dispose();
    _secondary.dispose();
    _primaryClock.dispose();
    _secondaryClock.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final textDirection = Directionality.of(context);
    return SlideTransition(
      position: _primary.drive(_enter),
      textDirection: textDirection,
      child: SlideTransition(
        position: _secondary.drive(_exit),
        textDirection: textDirection,
        child: widget.child,
      ),
    );
  }
}

/// Re-bases a route animation so a slow first frame can't make the
/// transition jump.
///
/// A route's controller starts the instant the push is requested, but
/// the destination page is only built/laid out on the *next* frame. An
/// animation value is a function of elapsed wall-clock time, so if that
/// first build takes 80ms the very next frame lands ~25% of the way
/// through the slide: the page visibly skips its opening stretch (the
/// "stutter at the start" of a push to a heavy screen). This wrapper
/// notices the first non-zero value of a fresh forward run and treats
/// it as the new zero, stretching the remainder of the animation over
/// what is left of its duration, so motion always starts from rest and
/// then runs continuously. When the first frame is cheap the offset is
/// ~one frame and the wrapper is effectively invisible.
///
/// Only a run that begins from dismissed is ever re-based (a back
/// gesture that is cancelled and resumes, or a pop, is never touched),
/// and the re-base is dropped as soon as the animation is dismissed or
/// starts its reverse run from fully completed.
class _SteadyStartAnimation extends Animation<double>
    with AnimationWithParentMixin<double> {
  _SteadyStartAnimation(this.parent) {
    _last = parent.status;
    // Built mid-push: the controller is already running forward but the
    // page has not had its first frame yet.
    _armed = _last == AnimationStatus.forward && parent.value == 0.0;
    parent.addStatusListener(_onStatus);
  }

  @override
  final Animation<double> parent;

  late AnimationStatus _last;
  bool _armed = false;
  double _base = 0.0;

  void _onStatus(AnimationStatus status) {
    final previous = _last;
    _last = status;
    switch (status) {
      case AnimationStatus.dismissed:
        _base = 0.0;
        _armed = false;
      case AnimationStatus.forward:
        if (previous == AnimationStatus.dismissed) {
          _base = 0.0;
          _armed = true;
        }
      case AnimationStatus.reverse:
        if (previous == AnimationStatus.completed) {
          _base = 0.0;
          _armed = false;
        }
      case AnimationStatus.completed:
        _armed = false;
    }
  }

  @override
  double get value {
    final raw = parent.value;
    if (_armed && raw > 0.0) {
      // Keep a sliver of runway so the remap can never divide by ~0.
      _base = raw.clamp(0.0, 0.9);
      _armed = false;
    }
    if (_base <= 0.0) return raw;
    return ((raw - _base) / (1.0 - _base)).clamp(0.0, 1.0);
  }

  void dispose() {
    parent.removeStatusListener(_onStatus);
  }
}

/// Applies [NemesisPageTransitionsBuilder] on every platform.
const PageTransitionsTheme nemesisPageTransitionsTheme = PageTransitionsTheme(
  builders: <TargetPlatform, PageTransitionsBuilder>{
    TargetPlatform.android: NemesisPageTransitionsBuilder(),
    TargetPlatform.iOS: NemesisPageTransitionsBuilder(),
    TargetPlatform.fuchsia: NemesisPageTransitionsBuilder(),
    TargetPlatform.linux: NemesisPageTransitionsBuilder(),
    TargetPlatform.macOS: NemesisPageTransitionsBuilder(),
    TargetPlatform.windows: NemesisPageTransitionsBuilder(),
  },
);
