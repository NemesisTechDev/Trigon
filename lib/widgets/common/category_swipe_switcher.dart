import 'package:flutter/material.dart';

/// Wraps a screen's category/tab content so a left-right swipe moves to
/// the next/previous item in whatever list the screen considers its
/// "categories" (library chips, music tabs, channel categories, ...),
/// with the new content sliding in from the swiped direction instead of
/// popping straight in. Used by MoviesScreen, MusicScreen, and
/// AllChannelsScreen (which covers both "All Channels" and "Favorites"
/// channels, since they share that widget) so all four of Ben's
/// category grids/lists get the same swipe feel.
///
/// [categoryKey] must change exactly when the visible category changes
/// (and stay the same for any other rebuild — search text, a
/// background refresh landing, sort changes, etc.) — it's both what
/// triggers the cross-fade and, via [child]'s own identity, is not
/// itself a widget key. This only decides the transition; it doesn't
/// touch the caller's own state.
///
/// IMPORTANT for callers: AnimatedSwitcher keeps the outgoing category's
/// widget mounted (in a Stack, alongside the incoming one) for the
/// whole cross-fade, so if [child] contains a scrollable, it must use a
/// ScrollController that's unique to this [categoryKey] — reusing one
/// shared controller across categories means two live Scrollables end
/// up attached to the same controller mid-transition, which is the
/// "ScrollController attached to multiple scroll views" crash already
/// hit once on the Music screen's tabs (see MusicScreen's
/// _contentScrollControllers). Give each category its own controller
/// (a `Map<String, ScrollController>` keyed the same way as
/// [categoryKey] works well) rather than one shared field.
class CategorySwipeSwitcher extends StatefulWidget {
  final Object categoryKey;
  final Widget child;

  /// Called when a decisive leftward swipe (finger moving left) is
  /// detected — i.e. "reveal the next category". Pass null to disable
  /// swiping forward (e.g. already at the last item).
  final VoidCallback? onSwipeNext;

  /// Called on a decisive rightward swipe — "reveal the previous
  /// category". Pass null to disable swiping back.
  final VoidCallback? onSwipePrevious;

  const CategorySwipeSwitcher({
    super.key,
    required this.categoryKey,
    required this.child,
    this.onSwipeNext,
    this.onSwipePrevious,
  });

  @override
  State<CategorySwipeSwitcher> createState() => _CategorySwipeSwitcherState();
}

class _CategorySwipeSwitcherState extends State<CategorySwipeSwitcher> {
  // Same shape of threshold as the mini player's own swipe gesture
  // (mini_player.dart's _flingVelocity) so "swipe to switch" reads as
  // the same gesture everywhere in the app — a decisive flick, not
  // every incidental horizontal wobble picked up while scrolling.
  static const double _velocityThreshold = 300;

  // Which way the *last* committed swipe went, purely for the
  // transition direction — 1 means the new content should slide in
  // from the right (a "next" swipe), -1 from the left ("previous").
  int _direction = 1;

  void _handleDragEnd(DragEndDetails details) {
    final vx = details.primaryVelocity ?? 0;

    if (vx <= -_velocityThreshold && widget.onSwipeNext != null) {
      _direction = 1;
      widget.onSwipeNext!();
    } else if (vx >= _velocityThreshold && widget.onSwipePrevious != null) {
      _direction = -1;
      widget.onSwipePrevious!();
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasSwipe = widget.onSwipeNext != null || widget.onSwipePrevious != null;
    final targetKey = ValueKey(widget.categoryKey);

    return GestureDetector(
      // translucent (not opaque) so this never steals taps meant for
      // the grid/list underneath — it only ever acts on the drag-end
      // callback above, never on taps.
      behavior: HitTestBehavior.translucent,
      onHorizontalDragEnd: hasSwipe ? _handleDragEnd : null,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 220),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        transitionBuilder: (child, animation) {
          // AnimatedSwitcher calls this once for the incoming child
          // (key == targetKey, animation running 0→1) and once more
          // for whichever child is on its way out (any other key,
          // animation running 1→0) — comparing against the *current*
          // target key is what lets the two be told apart and slide in
          // opposite directions instead of both drifting the same way.
          final entering = child.key == targetKey;
          final side = _direction == 1 ? 1.0 : -1.0;
          final beginOffset =
              entering ? Offset(side * 0.22, 0) : Offset(-side * 0.22, 0);

          return SlideTransition(
            position: Tween<Offset>(begin: beginOffset, end: Offset.zero)
                .animate(animation),
            child: FadeTransition(opacity: animation, child: child),
          );
        },
        child: KeyedSubtree(
          key: targetKey,
          child: widget.child,
        ),
      ),
    );
  }
}
