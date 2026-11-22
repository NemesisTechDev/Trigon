import 'package:flutter/material.dart';

/// A full-screen, invisible hit-test layer that drives all of the
/// player's swipe/tap gestures (tap to toggle controls, double-tap to
/// seek, horizontal drag to scrub, vertical drag for brightness/
/// volume). It sits above the video surface but does not draw
/// anything itself or wrap it — the video stays a separate, always
/// full-screen sibling so shrinking this layer's hit-test area (via
/// [topExclusion]/[bottomExclusion]) never crops or repositions the
/// picture, only where gestures are recognised.
class PlayerGestureLayer extends StatelessWidget {

  final GestureTapCallback onTap;

  final GestureTapDownCallback onDoubleTapDown;

  final GestureDragStartCallback onHorizontalDragStart;

  final GestureDragUpdateCallback onHorizontalDragUpdate;

  final GestureDragEndCallback onHorizontalDragEnd;

  final GestureDragUpdateCallback onVerticalDragUpdate;

  /// Optional: fired when a vertical drag begins (used by the volume
  /// boost's "slide again to go beyond 100%" rule, which needs to know
  /// where each individual swipe started).
  final GestureDragStartCallback? onVerticalDragStart;

  /// Strip at the very top of the screen, in logical pixels, that this
  /// layer's gesture detector does NOT cover. Keeps a swipe-down from
  /// the top edge (the OS gesture for revealing the status bar) from
  /// ever entering this layer's gesture arena in the first place —
  /// physically excluding the area is what stops it being read as a
  /// brightness/volume adjustment, rather than trying to detect and
  /// special-case it after the fact.
  final double topExclusion;

  /// Same idea as [topExclusion], but for the bottom edge. Also used
  /// while the player controls (and therefore the seek bar) are
  /// visible: sized to the seek bar/bottom-bar's own height so that
  /// area is entirely outside this layer's hit-test rect, and its taps
  /// and drags go straight to the seek bar without competing with this
  /// layer's own tap/drag recognisers in the same gesture arena — that
  /// competition was why seeking sometimes needed a second tap.
  final double bottomExclusion;

  const PlayerGestureLayer({

    super.key,

    required this.onTap,

    required this.onDoubleTapDown,

    required this.onHorizontalDragStart,

    required this.onHorizontalDragUpdate,

    required this.onHorizontalDragEnd,

    required this.onVerticalDragUpdate,

    this.onVerticalDragStart,

    this.topExclusion = 0,

    this.bottomExclusion = 0,

  });

  @override
  Widget build(BuildContext context) {

    return Positioned(

      top: topExclusion,

      left: 0,

      right: 0,

      bottom: bottomExclusion,

      child: GestureDetector(

        behavior: HitTestBehavior.opaque,

        onTap: onTap,

        onDoubleTapDown: onDoubleTapDown,

        onHorizontalDragStart: onHorizontalDragStart,

        onHorizontalDragUpdate: onHorizontalDragUpdate,

        onHorizontalDragEnd: onHorizontalDragEnd,

        onVerticalDragStart: onVerticalDragStart,

        onVerticalDragUpdate: onVerticalDragUpdate,

        // No visual child — the video surface is rendered as its own
        // always-full-screen sibling behind this layer now, rather
        // than as this widget's child, so this layer purely exists to
        // catch input over whatever region top/bottom exclusion leave
        // it.
        child: const SizedBox.expand(),

      ),

    );

  }
}
