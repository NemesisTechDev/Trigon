import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';

enum _RefreshPhase { idle, dragging, snapBack, armed, refreshing, settleBack }

/// A pull-to-refresh wrapper with real rubber-band drag tracking, but a
/// floating "liquid glass" indicator instead of the classic Material
/// look — the page content stays put and the indicator hovers on top
/// of it as it's pulled down, the way YouTube's own pull-to-refresh
/// reads, rather than the whole screen visibly dragging down.
///
/// Drop-in compatible with [RefreshIndicator]: same [onRefresh] contract
/// (a `Future<void> Function()`), same [color]/[backgroundColor] knobs.
class ResistiveRefresh extends StatefulWidget {
  const ResistiveRefresh({
    super.key,
    required this.onRefresh,
    required this.child,
    this.color,
    this.backgroundColor,
    this.triggerDistance = 72,
    this.maxDragDistance = 130,
  });

  /// Called when the user releases past [triggerDistance]. Mirrors
  /// [RefreshIndicator.onRefresh] — the indicator keeps spinning until
  /// the returned future completes.
  final RefreshCallback onRefresh;

  /// Must contain a [Scrollable] descendant (a ListView, GridView,
  /// CustomScrollView, etc.) sitting at scroll offset 0 for the pull
  /// gesture to be detected — same requirement as [RefreshIndicator].
  final Widget child;

  final Color? color;
  final Color? backgroundColor;

  /// How far (in raw, unresisted drag pixels) the user needs to pull
  /// before releasing triggers a refresh. The content itself no longer
  /// moves, so this is purely a threshold for the gesture, not a
  /// distance anything travels on screen.
  final double triggerDistance;

  /// The asymptote the resistance curve approaches. Only used to shape
  /// how quickly the indicator's own reveal (opacity/scale) reaches
  /// full strength relative to [triggerDistance] — nothing on screen
  /// is actually dragged this far anymore.
  final double maxDragDistance;

  @override
  State<ResistiveRefresh> createState() => _ResistiveRefreshState();
}

class _ResistiveRefreshState extends State<ResistiveRefresh>
    with SingleTickerProviderStateMixin {
  late final AnimationController _settleController;
  Animation<double>? _settleAnimation;

  // Raw, unresisted accumulated drag distance while the underlying
  // scrollable sits pinned at its top edge. Only meaningful mid-drag —
  // once released, the animation below takes over in display-pixel
  // space directly.
  double _rawDrag = 0;
  _RefreshPhase _phase = _RefreshPhase.idle;

  @override
  void initState() {
    super.initState();
    _settleController = AnimationController(vsync: this)
      ..addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _settleController.dispose();
    super.dispose();
  }

  // Diminishing-returns curve: responsive near zero, then asymptotically
  // approaches maxDragDistance the harder you pull. This is what makes
  // the indicator's own reveal feel like a resisted pull (quick to
  // appear, harder to push past "fully shown") even though the content
  // underneath no longer moves at all.
  double _resist(double raw) {
    if (raw <= 0) return 0;
    final t = raw / widget.maxDragDistance;
    return widget.maxDragDistance * (1 - math.exp(-t));
  }

  double get _indicatorStrength {
    switch (_phase) {
      case _RefreshPhase.dragging:
        return _resist(_rawDrag);
      case _RefreshPhase.idle:
        return 0;
      case _RefreshPhase.snapBack:
      case _RefreshPhase.armed:
      case _RefreshPhase.settleBack:
        return _settleAnimation?.value ?? 0;
      case _RefreshPhase.refreshing:
        return widget.triggerDistance;
    }
  }

  bool _handleNotification(ScrollNotification notification) {
    // A refresh is in flight (or settling back down after one finished)
    // — ignore further scroll notifications from the content underneath
    // so a second drag can't stack another pull on top of it.
    if (_phase == _RefreshPhase.refreshing ||
        _phase == _RefreshPhase.settleBack ||
        _phase == _RefreshPhase.armed) {
      return false;
    }

    final atTop = notification.metrics.extentBefore <= 0;

    // On Android, ClampingScrollPhysics (the platform default) hard-
    // clamps the scroll position at the top instead of letting it
    // move past 0 — so pulling down while already at the top never
    // produces a ScrollUpdateNotification there at all. Flutter
    // reports that rejected motion as an OverscrollNotification
    // instead, with the rejected amount in `.overscroll` (negative at
    // the top edge). The stock RefreshIndicator explicitly handles
    // this notification type for the same reason. Without it, this
    // widget only ever responded on iOS's bouncy scroll physics
    // (which really does move pixels past 0, so it still fires an
    // ordinary ScrollUpdateNotification) — on Android, the actual
    // target platform here, the pull gesture silently did nothing.
    if (notification is OverscrollNotification) {
      if (notification.overscroll < 0) {
        setState(() {
          _phase = _RefreshPhase.dragging;
          _rawDrag = math.max(0, _rawDrag - notification.overscroll);
        });
      } else if (_rawDrag > 0) {
        setState(() {
          _rawDrag = 0;
          _phase = _RefreshPhase.idle;
        });
      }
      return false;
    }

    if (notification is ScrollUpdateNotification &&
        notification.dragDetails != null) {
      final delta = notification.dragDetails!.delta.dy;

      if (atTop && (delta > 0 || _rawDrag > 0)) {
        setState(() {
          _phase = _RefreshPhase.dragging;
          _rawDrag = math.max(0, _rawDrag + delta);
        });
      } else if (_rawDrag > 0) {
        // Either scrolled back into the content, or dragging up from a
        // resting pull — nothing left to show, collapse immediately.
        setState(() {
          _rawDrag = 0;
          _phase = _RefreshPhase.idle;
        });
      }
    } else if (_phase == _RefreshPhase.dragging &&
        (notification is ScrollEndNotification ||
            (notification is ScrollUpdateNotification &&
                notification.dragDetails == null))) {
      _onRelease();
    }

    return false;
  }

  void _onRelease() {
    final resisted = _resist(_rawDrag);
    _rawDrag = 0;

    if (resisted >= widget.triggerDistance) {
      _phase = _RefreshPhase.armed;
      _animateFromTo(resisted, widget.triggerDistance, onDone: _startRefresh);
    } else {
      _phase = _RefreshPhase.snapBack;
      _animateFromTo(
        resisted,
        0,
        onDone: () {
          if (mounted) setState(() => _phase = _RefreshPhase.idle);
        },
      );
    }
  }

  void _animateFromTo(double start, double target, {VoidCallback? onDone}) {
    _settleAnimation = Tween<double>(begin: start, end: target).animate(
      CurvedAnimation(parent: _settleController, curve: Curves.easeOutCubic),
    );
    setState(() {});
    _settleController
      ..stop()
      ..value = 0
      ..duration = const Duration(milliseconds: 220)
      ..forward().whenCompleteOrCancel(() {
        if (mounted) onDone?.call();
      });
  }

  Future<void> _startRefresh() async {
    if (!mounted) return;
    setState(() => _phase = _RefreshPhase.refreshing);
    try {
      await widget.onRefresh();
    } finally {
      if (!mounted) return;
      _phase = _RefreshPhase.settleBack;
      _animateFromTo(
        widget.triggerDistance,
        0,
        onDone: () {
          if (mounted) setState(() => _phase = _RefreshPhase.idle);
        },
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    // Gold by default, same brand accent every other pull-to-refresh
    // call site already passes explicitly — kept as the fallback here
    // too rather than the theme's primary color, so a call site that
    // forgets to specify one still gets the gold glyph, not white.
    const goldFallback = Color(0xffD4AF37);
    final color = widget.color ?? goldFallback;
    final bg = widget.backgroundColor ?? Theme.of(context).canvasColor;
    final strength = _indicatorStrength;
    final progress = (strength / widget.triggerDistance).clamp(0.0, 1.0);
    final spinning =
        _phase == _RefreshPhase.refreshing ||
        _phase == _RefreshPhase.settleBack;

    return Stack(
      clipBehavior: Clip.none,
      children: [
        // The page itself no longer drags down under the finger — only
        // the floating indicator below reacts to the pull. Content
        // stays exactly where it already is throughout the whole
        // gesture, same as YouTube's own pull-to-refresh.
        NotificationListener<ScrollNotification>(
          onNotification: _handleNotification,
          child: widget.child,
        ),
        if (progress > 0.01)
          Positioned(
            top: 14,
            left: 0,
            right: 0,
            child: IgnorePointer(
              child: Align(
                alignment: Alignment.topCenter,
                child: Opacity(
                  opacity: progress,
                  child: Transform.scale(
                    scale: 0.55 + 0.45 * progress,
                    child: _LiquidGlassCircle(
                      tint: bg,
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: spinning
                            ? CircularProgressIndicator(
                                strokeWidth: 2.4,
                                color: color,
                              )
                            // Dragging: a circular-arrow glyph that
                            // winds clockwise as the pull nears the
                            // trigger threshold (a full turn at
                            // progress == 1), rather than a plain arrow
                            // flipping direction — reads as "spinning up"
                            // into the same CircularProgressIndicator
                            // spinner above the moment it's released,
                            // instead of two visually unrelated glyphs
                            // handing off to each other.
                            : Transform.rotate(
                                angle: progress * 2 * math.pi,
                                child: Icon(
                                  Icons.refresh_rounded,
                                  size: 20,
                                  color: color,
                                ),
                              ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// The "liquid glass" pill itself: a blurred, translucent circle with a
/// faint edge highlight and soft drop shadow, sitting on top of
/// whatever content happens to be behind it — same frosted-glass
/// material feel as iOS's system pull-to-refresh, rather than a flat
/// opaque disc.
class _LiquidGlassCircle extends StatelessWidget {
  const _LiquidGlassCircle({required this.tint, required this.child});

  final Color tint;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: .3),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: ClipOval(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: Container(
            width: 44,
            height: 44,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: tint.withValues(alpha: .42),
              border: Border.all(
                color: Colors.white.withValues(alpha: .22),
                width: 1,
              ),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

