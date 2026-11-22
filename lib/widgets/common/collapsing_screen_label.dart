import 'package:flutter/material.dart';

// "Hide the screen label on scroll down, bring it back on scroll up" —
// the same behaviour as the top bar in the reference video: only the
// label part of a screen's header (title, back button, app bar actions)
// slides away, while the control rows underneath it (tabs, chips, sort
// row, search field) stay pinned, so the list/grid below gains the
// label's height as extra visible area in both portrait and landscape.
//
// Three small pieces, all used the same way on every screen:
//
//  * [LabelCollapseScope] — wrap the screen's header + scrollable area
//    (for screens using a Scaffold app bar, wrap the whole Scaffold).
//    It owns the slide animation and listens to the scroll
//    notifications bubbling up from the list/grid underneath, so no
//    screen needs its own ScrollController listener, TickerProvider or
//    extra state.
//  * [CollapsibleLabel] — wrap the label widget(s) of a Column-style
//    header. Used by Movies, Music, Downloads, Live TV and the
//    genre/tag/studio grids.
//  * [CollapsibleAppBar] — drop-in for `Scaffold.appBar` on the screens
//    that use a plain AppBar as their label (TV Guide, All/Favorite
//    Channels, Favorites, Profile & Settings, Settings).
//
// Why the slide is time-based (a short snap animation started when the
// scroll direction changes) rather than tracking the finger 1:1: the
// label lives *outside* the scrollable (Movies/Music/etc. swap whole
// grid "lanes" with CategorySwipeSwitcher, and the pinned chip rows
// must not move with the lane), so a per-pixel collapse would make the
// content move at double speed for the first few dp of every scroll —
// the label shrinking and the list scrolling would both push the same
// rows upward. A quick eased snap (like AppBar's floating+snap) avoids
// that and matches the reference video, where the bar snaps away/back.

/// Distance the list has to move down before the label starts hiding.
/// Small enough to feel immediate, big enough that finger jitter at the
/// start of a touch doesn't hide it.
const double _kHideAfterScrollDown = 10;

/// Distance the list has to move back up before the label returns. A bit
/// shorter than the hide distance so revealing feels responsive.
const double _kShowAfterScrollUp = 8;

/// Within this many dp of the top the label is always shown.
const double _kTopEpsilon = 1;

/// Never hide the label unless at least this much scrollable content is
/// still left below the current position. Hiding gives the viewport the
/// label's height back (~56–64dp), which shrinks the scroll range by the
/// same amount — without this margin a list that only barely overflows
/// could end up with nothing left to scroll, leaving the label hidden
/// with no way to scroll it back into view.
const double _kMinRemainingToHide = 88;

/// Gap kept above the pinned control row once the label has collapsed,
/// so the chips/tabs don't sit flush against the status bar. Screens
/// whose original top margin was 15 keep the first 8 outside the
/// collapsing part and put the remaining 7 inside it (see
/// [CollapsibleLabel.topPadding]) — the expanded layout is unchanged.
const double kCollapsedLabelTopGap = 8;

class LabelCollapseController {
  LabelCollapseController({required TickerProvider vsync})
      : _animation = AnimationController(
          vsync: vsync,
          duration: const Duration(milliseconds: 200),
        );

  final AnimationController _animation;

  bool _hiddenTarget = false;

  // Net scroll distance in the current direction, reset whenever the
  // direction flips or a new drag starts.
  double _accumulated = 0;

  /// Rebuilds anything that follows the slide (the label wrappers).
  Listenable get listenable => _animation;

  /// 0 = label fully shown, 1 = fully hidden. The easing is baked into
  /// the animation itself (see [hide]/[show]) so this can be used as-is.
  double get hiddenFraction => _animation.value;

  void hide() {
    if (_hiddenTarget) return;
    _hiddenTarget = true;
    _animation.animateTo(1.0, curve: Curves.easeOutCubic);
  }

  void show() {
    if (!_hiddenTarget) return;
    _hiddenTarget = false;
    _animation.animateTo(0.0, curve: Curves.easeOutCubic);
  }

  /// Feed with every [ScrollNotification] bubbling up from the screen's
  /// scrollable. Always returns false so it never swallows a
  /// notification meant for someone else (ResistiveRefresh, scrollbars).
  bool handleScroll(ScrollNotification notification) {
    final metrics = notification.metrics;

    // Only the vertical list/grid drives the label. Horizontal chip rows,
    // poster carousels and single-line text fields also bubble scroll
    // notifications through here.
    if (metrics.axis != Axis.vertical) return false;
    if (!metrics.hasContentDimensions || !metrics.hasPixels) return false;

    if (notification is ScrollStartNotification) {
      _accumulated = 0;
      return false;
    }

    // At the very top (or pulled past it by overscroll / pull-to-refresh)
    // there's nothing scrolled away to make room for, so the label is
    // always visible.
    if (metrics.extentBefore <= _kTopEpsilon) {
      _accumulated = 0;
      show();
      return false;
    }

    if (notification is ScrollUpdateNotification) {
      // Rubber-banding past the bottom edge (bouncing physics) reports a
      // scroll back up that isn't the user reversing direction.
      if (metrics.pixels > metrics.maxScrollExtent) return false;

      final delta = notification.scrollDelta ?? 0;
      if (delta == 0) return false;

      if (delta > 0) {
        _accumulated = (_accumulated > 0 ? _accumulated : 0) + delta;
        if (_accumulated >= _kHideAfterScrollDown &&
            metrics.extentAfter >= _kMinRemainingToHide) {
          hide();
        }
      } else {
        _accumulated = (_accumulated < 0 ? _accumulated : 0) + delta;
        if (_accumulated <= -_kShowAfterScrollUp) {
          show();
        }
      }
    }

    return false;
  }

  /// Feed with every [ScrollMetricsNotification] (content or viewport size
  /// changed without the user scrolling — a search filter shrinking the
  /// list, a tab swapping in an empty state). If the list stops being
  /// scrollable while the label is hidden, no further scroll event will
  /// ever arrive to bring it back, so bring it back here.
  bool handleMetrics(ScrollMetricsNotification notification) {
    final metrics = notification.metrics;

    if (metrics.axis != Axis.vertical) return false;
    if (!metrics.hasContentDimensions) return false;

    if (_hiddenTarget && metrics.maxScrollExtent - metrics.minScrollExtent <= 0.5) {
      _accumulated = 0;
      show();
    }

    return false;
  }

  void dispose() => _animation.dispose();
}

class _LabelCollapseInherited extends InheritedWidget {
  const _LabelCollapseInherited({
    required this.controller,
    required super.child,
  });

  final LabelCollapseController controller;

  @override
  bool updateShouldNotify(_LabelCollapseInherited oldWidget) =>
      controller != oldWidget.controller;
}

class LabelCollapseScope extends StatefulWidget {
  const LabelCollapseScope({
    super.key,
    this.resetKey,
    required this.child,
  });

  /// When this value changes (a different category/tab/lane became
  /// visible) the label is brought back, since the new content starts
  /// from its own scroll position.
  final Object? resetKey;

  final Widget child;

  /// The controller of the nearest scope, or null when there isn't one
  /// (widgets then simply render without collapsing). Doesn't subscribe
  /// the caller to anything — the controller instance never changes for
  /// the life of a scope.
  static LabelCollapseController? maybeOf(BuildContext context) {
    return context
        .getInheritedWidgetOfExactType<_LabelCollapseInherited>()
        ?.controller;
  }

  @override
  State<LabelCollapseScope> createState() => _LabelCollapseScopeState();
}

class _LabelCollapseScopeState extends State<LabelCollapseScope>
    with SingleTickerProviderStateMixin {
  late final LabelCollapseController _controller =
      LabelCollapseController(vsync: this);

  @override
  void didUpdateWidget(covariant LabelCollapseScope oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.resetKey != widget.resetKey) {
      // Post-frame rather than inline: this runs mid-build, and starting
      // the animation notifies the label wrappers underneath.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _controller.show();
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _LabelCollapseInherited(
      controller: _controller,
      child: NotificationListener<ScrollNotification>(
        onNotification: _controller.handleScroll,
        child: NotificationListener<ScrollMetricsNotification>(
          onNotification: _controller.handleMetrics,
          child: widget.child,
        ),
      ),
    );
  }
}

/// Wraps a screen's label so it slides up out of view (clipped at its own
/// top edge, everything below it moving up with it) and back down.
///
/// [topPadding]/[bottomPadding] sit *inside* the collapsing part, so the
/// spacing around the label disappears together with it — pass whatever
/// gaps the screen had above/below its label before, minus the
/// [kCollapsedLabelTopGap] that should stay above the pinned row.
class CollapsibleLabel extends StatelessWidget {
  const CollapsibleLabel({
    super.key,
    required this.child,
    this.topPadding = 0,
    this.bottomPadding = 0,
    this.enabled = true,
  });

  final Widget child;
  final double topPadding;
  final double bottomPadding;

  /// False keeps the label fully shown (e.g. while a selection bar is
  /// occupying the label's slot and must stay visible).
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final controller = LabelCollapseScope.maybeOf(context);

    final padded = (topPadding == 0 && bottomPadding == 0)
        ? child
        : Padding(
            padding: EdgeInsetsDirectional.only(
              top: topPadding,
              bottom: bottomPadding,
            ),
            child: child,
          );

    if (controller == null) return padded;

    return AnimatedBuilder(
      animation: controller.listenable,
      // Built once — only the ClipRect/Align around it changes per frame.
      child: padded,
      builder: (context, child) {
        final hidden = enabled ? controller.hiddenFraction : 0.0;

        return ClipRect(
          child: Align(
            // Bottom-aligned so the label's *top* is what slides out of
            // the clip, i.e. it moves up under the status bar rather
            // than being squashed from below.
            alignment: AlignmentDirectional.bottomStart,
            heightFactor: 1.0 - hidden,
            child: child,
          ),
        );
      },
    );
  }
}

/// Drop-in replacement for `Scaffold.appBar` on screens whose label is a
/// plain AppBar. Pass an [AppBar] built with `primary: false` as [child]
/// — this widget supplies the status-bar inset itself, which is what
/// lets the bar collapse down to *just* the inset (the pinned content
/// below then starts right under the status bar) instead of collapsing
/// to nothing and letting the body slide up behind the status bar.
class CollapsibleAppBar extends StatelessWidget implements PreferredSizeWidget {
  const CollapsibleAppBar({
    super.key,
    required this.child,
    this.enabled = true,
  });

  final Widget child;

  /// False keeps the bar fully shown (e.g. Favorites while its bar is
  /// showing the song selection actions).
  final bool enabled;

  // The Scaffold adds the status-bar inset on top of this for the slot's
  // maximum height; the actual height is smaller while collapsed.
  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
      child: CollapsibleLabel(enabled: enabled, child: child),
    );
  }
}
