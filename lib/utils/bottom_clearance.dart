import 'package:flutter/material.dart';

import '../player/player_manager.dart';
import 'responsive.dart';

/// Centralizes the space every screen needs to reserve at the bottom
/// of its own scrollable content so nothing ever sits behind
/// MainNavScreen's floating bottom chrome — the mini player (portrait
/// *and* landscape), and, in portrait only, the tab bar drawn below
/// it.
///
/// MainNavScreen paints that chrome in a plain Stack on top of the
/// content Navigator rather than a real `Scaffold.extendBody` (see
/// its own class-level doc comment for why — a GlobalKey reactivation
/// crash), so none of the usual "SafeArea/Scaffold automatically
/// leaves room for the bottom bar" machinery applies here. Every
/// screen has to ask for this explicitly, which is what this file is
/// for, instead of each one re-deriving (or forgetting to derive) its
/// own estimate.
///
/// Deliberately excludes the safe-area bottom inset (the gesture-nav
/// bar on a real device) — every existing call site already adds
/// `MediaQuery.paddingOf(context).bottom` (or `MediaQuery.paddingOf`)
/// on top of this separately, and MainNavScreen's own bottom bar
/// *also* pads itself by that same inset once (see
/// `_buildPortraitBottomBar`/`_buildLandscapeBottomBar`), so folding
/// it in here too would double-count it. This is purely the height of
/// the chrome itself.
class BottomClearance {
  BottomClearance._();

  /// [BottomNavigationBar]'s own intrinsic height with
  /// `showUnselectedLabels: true` at *default* text scale — the exact
  /// configuration MainNavScreen's portrait tab bar always uses (see
  /// `_buildPortraitBottomBar`). Used only as a fallback, before
  /// MainNavScreen's first frame has published a real measurement (see
  /// [reportPortraitChromeHeight]/[reportLandscapeChromeHeight] below) —
  /// e.g. a screen's very first build, or a widget test that never
  /// mounts MainNavScreen at all. Once a device's font/display-size
  /// setting is scaled up, the tab bar's *actual* rendered height grows
  /// past this fixed number (label text needs more room), which used to
  /// leave every screen reserving too little space — that's what was
  /// letting page content render underneath the nav bar/mini player on
  /// a phone with a larger text setting. Portrait only: landscape
  /// replaces the tab bar with the side rail, so this never applies
  /// there.
  static const double tabBarHeight = 56;

  /// Mirrors `_MiniPlayerState._height` in mini_player.dart exactly, at
  /// default text scale. Same fallback-only role as [tabBarHeight] —
  /// see its doc comment.
  static const double miniPlayerHeight = 72;

  /// Real, measured height of whatever MainNavScreen's portrait bottom
  /// chrome slot (mini player + tab bar together, whichever combination
  /// is actually visible) rendered as, published once per layout by
  /// [MainNavScreen] via `MeasureSize` — the same "measure the actual
  /// widget instead of guessing its height" approach already used for
  /// the video player's own bottom bar (see `PlayerBottomBar`/
  /// `manager.bottomBarHeight`). Null until that first measurement
  /// lands (e.g. before MainNavScreen's first frame).
  static final ValueNotifier<double?> _measuredPortraitChromeHeight =
      ValueNotifier(null);

  /// Same as [_measuredPortraitChromeHeight], for the landscape bottom
  /// chrome slot (mini player only — see `_buildLandscapeBottomBar`).
  static final ValueNotifier<double?> _measuredLandscapeChromeHeight =
      ValueNotifier(null);

  /// Called by MainNavScreen's `MeasureSize` wrapper around whichever
  /// bottom bar is currently mounted. `isLandscape` picks which of the
  /// two measured notifiers this update belongs to, so a rotation mid-
  /// flight can never attribute a landscape measurement to the portrait
  /// slot or vice versa.
  static void reportChromeHeight(double height, {required bool isLandscape}) {
    final notifier = isLandscape
        ? _measuredLandscapeChromeHeight
        : _measuredPortraitChromeHeight;
    if (notifier.value != height) notifier.value = height;
  }

  /// True exactly when `MiniPlayer.build()` would render the full bar
  /// rather than collapsing to `SizedBox.shrink()` — mirrors that
  /// check verbatim (see mini_player.dart) so this can never drift out
  /// of sync with what's actually on screen.
  static bool isMiniPlayerVisible() {
    final manager = PlayerManager.instance;
    return manager.currentItemNotifier.value != null &&
        !manager.isVideo.value &&
        manager.showMiniPlayer.value;
  }

  /// Fires on every change that could flip [isMiniPlayerVisible]'s
  /// result, for widgets that want to rebuild exactly when the answer
  /// might change instead of recomputing it once per unrelated
  /// rebuild for no reason.
  static Listenable get listenable => Listenable.merge([
        PlayerManager.instance.currentItemNotifier,
        PlayerManager.instance.isVideo,
        PlayerManager.instance.showMiniPlayer,
        _measuredPortraitChromeHeight,
        _measuredLandscapeChromeHeight,
      ]);

  /// Non-reactive snapshot of how much extra bottom clearance (beyond
  /// the safe-area inset, added separately as always) content needs
  /// *right now*. Safe to call directly from any build() that already
  /// rebuilds for other reasons whenever this could change — e.g. one
  /// already wrapped in a `ValueListenableBuilder` on
  /// `PlayerManager.instance.currentItemNotifier` for its own purposes
  /// — since that rebuild will pick up the current answer anyway. For
  /// everywhere else, wrap the padding in [BottomClearanceBuilder]
  /// instead so it reacts on its own.
  ///
  /// Prefers the real, measured chrome height MainNavScreen publishes
  /// (see [reportChromeHeight]) — which already reflects whatever the
  /// device's actual text/display scale rendered, mini player included
  /// or not — over the fixed [tabBarHeight]/[miniPlayerHeight] estimate.
  /// Falls back to the old fixed-constant math only when no measurement
  /// has landed yet (screen's first build, or a widget test that never
  /// mounts MainNavScreen).
  static double of(BuildContext context) {
    final isLandscape = Responsive.isLandscape(context);
    final measured = isLandscape
        ? _measuredLandscapeChromeHeight.value
        : _measuredPortraitChromeHeight.value;

    if (measured != null) return measured;

    // Fallback estimate — see the doc comments on tabBarHeight/
    // miniPlayerHeight for why this can undercount on a larger text
    // scale, and only exists for the brief window before a real
    // measurement is available.
    var clearance = isMiniPlayerVisible() ? miniPlayerHeight : 0.0;
    if (!isLandscape) clearance += tabBarHeight;
    return clearance;
  }
}

/// Reactive wrapper around [BottomClearance.of], for the (common) case
/// of a screen that isn't already inside a builder listening to the
/// same [PlayerManager] notifiers for some other reason. Rebuilds only
/// this small subtree — never the whole screen — whenever the mini
/// player's visibility changes, the same narrow-`ValueListenableBuilder`-
/// over-`setState` approach already used everywhere else in this
/// codebase for per-frame/state-driven updates.
///
/// `builder`'s `clearance` argument is just [BottomClearance.of] —
/// safe-area inset is still the caller's own responsibility to add on
/// top, exactly as every existing call site already does.
class BottomClearanceBuilder extends StatelessWidget {
  final Widget Function(BuildContext context, double clearance) builder;

  const BottomClearanceBuilder({super.key, required this.builder});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: BottomClearance.listenable,
      builder: (context, _) => builder(context, BottomClearance.of(context)),
    );
  }
}
