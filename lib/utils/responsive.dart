import 'dart:io' show Platform;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';

/// Central place for every orientation/width/device-class decision the
/// app makes.
///
/// Nothing here fakes MediaQuery or wraps the widget tree in a scaling
/// transform (that approach broke the Pixel 6 reference layout twice
/// before — see project notes). Every helper below is a pure function
/// of the real MediaQuery for the current BuildContext (or of the
/// resolved device class), called locally by whichever widget needs
/// it, the same way `topPadding` was already being read in
/// BackdropHeader. That keeps portrait completely unaffected (same
/// numbers as before) while letting landscape/tablet/TV opt into
/// different numbers.
///
/// Existing call sites (`isLandscape`, `heroHeight`, `contentAreaWidth`,
/// and `gridColumns` — used today by DownloadsScreen) keep the exact
/// same signature and produce the exact same output they always have
/// in portrait. `gridColumns`'s *internal* width source was hardened to
/// read from [availableContentWidth] (still subtracting `railWidth` in
/// landscape, exactly like before) instead of re-deriving that
/// subtraction from raw MediaQuery — see [contentAreaWidth]'s doc for
/// why the old raw arithmetic could mismatch on a real device. In
/// landscape this makes `gridColumns` *more* correct (fixes the same
/// display-cutout mismatch `contentAreaWidth` already fixed for
/// HomeScreen's rail-bleed rows), not merely equivalent. `contentPadding`
/// and `rowItemWidth` have no existing call sites yet, so their
/// behavior was safe to extend (TV overscan margin) without touching
/// anything currently on screen.
class Responsive {
  Responsive._();

  // ---------------------------------------------------------------------
  // Orientation / raw size — unchanged from before Phase 1.
  // ---------------------------------------------------------------------

  static bool isLandscape(BuildContext context) =>
      MediaQuery.orientationOf(context) == Orientation.landscape;

  static Size sizeOf(BuildContext context) => MediaQuery.sizeOf(context);

  /// Width of the NavigationRail shown in landscape (MainNavScreen).
  /// Screens that lay out content full-bleed need to know this so
  /// horizontal paddings/carousels can account for the rail eating
  /// into the available width instead of just trusting screen width.
  static const double railWidth = 84;

  // ---------------------------------------------------------------------
  // Width classes (Phase 1 addition) — a formalized way to talk about
  // "how much room do we actually have", read from the same available
  // content width every grid/hero calculation already uses. Nothing
  // currently branches on this; it exists so later phases (Home,
  // Movies, Music, Live TV, Other Screens) can ask one question
  // instead of re-deriving their own thresholds.
  // ---------------------------------------------------------------------

  static WidthClass widthClassOf(BuildContext context) {
    final width = availableContentWidth(context);
    if (width < 600) return WidthClass.compact;
    if (width < 900) return WidthClass.medium;
    return WidthClass.expanded;
  }

  // ---------------------------------------------------------------------
  // TV device class (Phase 1 addition).
  //
  // Deliberately NOT inferred from width/aspect ratio — a 1280x800
  // tablet and a 1920x1080 TV can look identical on paper but need
  // different layouts (TV needs larger touch targets/text and an
  // overscan-safe margin even though it has more raw pixels). Resolved
  // once via Android's leanback system feature
  // (`android.software.leanback`, the same signal `UiModeManager`/
  // `Configuration.UI_MODE_TYPE_TELEVISION` exposes) and cached, so
  // widgets read a plain bool instead of re-deriving a guess from
  // screen dimensions on every build.
  //
  // Call `Responsive.resolveDeviceClass()` once, early in `main()`,
  // before `runApp`:
  //
  //   WidgetsFlutterBinding.ensureInitialized();
  //   await Responsive.resolveDeviceClass();
  //   runApp(const NemesisApp());
  //
  // This file doesn't touch main.dart directly (wasn't part of this
  // change set) — wiring the call in is a one-line addition wherever
  // your app's entrypoint already lives.
  // ---------------------------------------------------------------------

  static bool _isTV = false;
  static bool? _debugTVOverride;
  static Future<void>? _resolveFuture;

  /// True when running on an Android TV / leanback device. False
  /// (safe default) until [resolveDeviceClass] has completed, and
  /// false on every non-Android platform.
  static bool get isTV => _debugTVOverride ?? _isTV;

  /// Resolves [isTV] once and caches the result. Safe to call more than
  /// once (e.g. from multiple entry points) — subsequent calls reuse
  /// the same in-flight/completed future rather than re-querying the
  /// platform.
  static Future<void> resolveDeviceClass() {
    return _resolveFuture ??= _resolveDeviceClassImpl();
  }

  static Future<void> _resolveDeviceClassImpl() async {
    if (!Platform.isAndroid) {
      _isTV = false;
      return;
    }
    try {
      final info = await DeviceInfoPlugin().androidInfo;
      _isTV = info.systemFeatures.contains('android.software.leanback');
    } catch (_) {
      // Any platform-channel failure (e.g. running in an environment
      // without the plugin registered) falls back to "not TV" rather
      // than crashing device-class resolution.
      _isTV = false;
    }
  }

  /// Test-only hook so widget tests can pump a TV-shaped device class
  /// without a real platform channel — per the size-matrix testing
  /// requirement ("mock the TV device-class flag true... rather than
  /// relying on size alone"). Reset to `null` in `tearDown`.
  @visibleForTesting
  static void debugOverrideIsTV(bool? value) {
    _debugTVOverride = value;
  }

  // ---------------------------------------------------------------------
  // Available content width.
  // ---------------------------------------------------------------------

  /// True local width of MainNavScreen's landscape content area (the
  /// Stack that sits inside its SafeArea, holding both the rail and the
  /// page content) — measured directly via [LandscapeContentWidth]
  /// rather than re-derived from MediaQuery size/viewPadding arithmetic.
  ///
  /// That arithmetic (screen width minus left/right viewPadding, to
  /// approximate what SafeArea consumed) *should* always cancel out to
  /// exactly [railWidth] of bleed on paper, but it depends on
  /// MediaQuery.padding and MediaQuery.viewPadding agreeing exactly on
  /// a given device/build — a display-cutout or 3-button-nav-bar inset
  /// reported inconsistently between the two (as seen on a Pixel 6
  /// landscape build, though not on Windows desktop, which reports zero
  /// for both) throws that cancellation off and shoves the first card
  /// in a bled row out from beside the rail to underneath/behind it.
  /// Reading the real, already-laid-out width straight from the
  /// LayoutBuilder that wraps MainNavScreen's Stack sidesteps the
  /// mismatch entirely — nothing here needs to *equal* what SafeArea
  /// did, it just *is* what SafeArea did.
  ///
  /// Falls back to the old MediaQuery-derived estimate when nothing has
  /// published a measurement (screens previewed/tested outside
  /// MainNavScreen's landscape shell, e.g. widget tests), so callers
  /// never need a null check.
  static double contentAreaWidth(BuildContext context) {
    final measured = LandscapeContentWidth.maybeOf(context);
    if (measured != null) return measured;

    final size = sizeOf(context);
    final viewPadding = MediaQuery.viewPaddingOf(context);
    return size.width - viewPadding.left - viewPadding.right;
  }

  /// [contentAreaWidth], minus the NavigationRail when one is actually
  /// on screen (landscape). `contentAreaWidth` measures the *entire*
  /// Stack MainNavScreen publishes — rail and page content combined,
  /// by design, since that's what rail-bleed rows like HomeScreen's
  /// `_bleedRowUnderRail` need. Everything that instead wants "how much
  /// room is actually left for my content" (grids, cell-extent math,
  /// max-width constraints) needs the rail subtracted back out first —
  /// that's what this method is for. Conflating the two was a bug in
  /// the first cut of this file: `gridColumns` originally subtracted
  /// `railWidth` itself before switching to `contentAreaWidth`
  /// directly, silently dropping that subtraction.
  static double availableContentWidth(BuildContext context) {
    final width = contentAreaWidth(context) -
        (isLandscape(context) ? railWidth : 0);
    return width < 0 ? 0 : width;
  }

  /// Available width left over for grid *content* after the standard
  /// horizontal content padding (left+right) has been subtracted —
  /// i.e. what per-item cell-extent math (like AlbumGrid's square-cover
  /// sizing) should divide by column count, instead of re-deriving its
  /// own "screen width minus 40" assumption per screen.
  static double gridContentWidth(
    BuildContext context, {
    double horizontalPadding = 40,
  }) {
    return (availableContentWidth(context) - horizontalPadding).clamp(
      0,
      double.infinity,
    );
  }

  /// Clamps available content width to a sane maximum so a single
  /// column/section on a 4K TV or ultra-wide tablet doesn't stretch
  /// into an absurdly wide, sparse layout. Opt-in — only screens that
  /// actually need a max-width ceiling (e.g. a detail page's text
  /// column) call this; grids keep using [availableContentWidth] since
  /// they scale column *count*, not a single column's width.
  static double constrainedContentWidth(
    BuildContext context, {
    double maxWidth = 1600,
  }) {
    return availableContentWidth(context).clamp(0, maxWidth);
  }

  // ---------------------------------------------------------------------
  // Hero/backdrop height, row item width, content padding — same
  // signatures as before Phase 1.
  // ---------------------------------------------------------------------

  /// Height for hero/backdrop headers (Home hero carousel, detail
  /// screen BackdropHeader). Portrait keeps its historical values
  /// (callers pass their own portraitHeight); landscape is capped to a
  /// fraction of the actual (short) screen height so the header can
  /// never dominate or overflow the viewport the way a flat fixed
  /// height did.
  static double heroHeight(
    BuildContext context, {
    required double portraitHeight,
    double landscapeFraction = 0.62,
    double landscapeMin = 220,
    double landscapeMax = 320,
  }) {
    if (!isLandscape(context)) return portraitHeight;
    final screenHeight = sizeOf(context).height;
    return (screenHeight * landscapeFraction)
        .clamp(landscapeMin, landscapeMax);
  }

  /// Horizontal row/carousel item extent (card width for ContentRow-style
  /// lists). Slightly larger in landscape since there's more width to
  /// spend and it matches the denser look of Spotify/YouTube landscape
  /// rows rather than stretching the same small portrait cards.
  static double rowItemWidth(BuildContext context, double portraitWidth) {
    if (!isLandscape(context)) return portraitWidth;
    return portraitWidth * 1.08;
  }

  /// Standard horizontal content padding. On TV this adds a fixed
  /// overscan-safe margin on top of the base value — TVs commonly clip
  /// a few percent of the picture at the edges, so content flush
  /// against the raw screen edge can be partially cut off on a real
  /// set even though it looks fine in a desktop/phone preview.
  static double contentPadding(BuildContext context, {double base = 20}) {
    if (isTV) return base + 24;
    return base;
  }

  /// Height for a centered placeholder/empty-state block (Search's
  /// "search your library" prompt and "no results" state, Favorites'
  /// error and empty states) — scales with available height like the
  /// flat `MediaQuery...height * .55/.6/.65` these call sites used to
  /// hand-roll individually, but clamped so a tall/short viewport can't
  /// push it to an extreme:
  ///
  ///  - On a short landscape phone (e.g. 915x411), an unclamped
  ///    fraction can end up shorter than the placeholder's own content
  ///    (icon + title + subtitle), overflowing the SizedBox that pins
  ///    it. [min] guarantees enough room regardless of [fraction].
  ///  - On a tablet or TV (where height alone can be 1280-2160px), an
  ///    unclamped fraction balloons into a huge empty block around a
  ///    small fixed-size icon/text group. [max] caps that so the
  ///    placeholder reads the same everywhere instead of "excessive
  ///    empty space" scaling with the screen.
  ///
  /// Portrait phone call sites keep producing effectively the same
  /// number this always did (their [fraction] * height rarely leaves
  /// the [min]/[max] band on a phone), so this doesn't change the
  /// Pixel 6 reference look — it only kicks in at the sizes that used
  /// to overflow or waste space.
  static double emptyStateHeight(
    BuildContext context, {
    double fraction = 0.55,
    double min = 240,
    double max = 480,
  }) {
    return (sizeOf(context).height * fraction).clamp(min, max);
  }

  // ---------------------------------------------------------------------
  // Grid columns.
  // ---------------------------------------------------------------------

  /// Poster/grid card column count driven by *available width*, not
  /// orientation directly — this is the same trick movie_grid.dart
  /// already used (wider viewport = more columns), just centralized so
  /// every grid screen (music, downloads, live tv channels, search,
  /// favorites) agrees on the same breakpoints.
  ///
  /// NOTE: these breakpoints (560/700/900/1100/1400 -> 4/5/6/7/8) are
  /// the ones already established here and already relied on by
  /// DownloadsScreen. `movie_grid.dart` currently hand-rolls a
  /// *different* set of breakpoints (700/900/1100/1400 -> 4/5/6/7) —
  /// that discrepancy is called out for Phase 2 to reconcile
  /// deliberately, not silently changed here, since either direction
  /// changes visual density on some screen.
  static int gridColumns(BuildContext context, {int portraitBase = 3}) {
    final width = availableContentWidth(context);

    if (width >= 1400) return 8;
    if (width >= 1100) return 7;
    if (width >= 900) return 6;
    if (width >= 700) return 5;
    if (width >= 560) return 4;
    // Narrow-phone tier: everything below 560dp used to collapse onto
    // the same flat `portraitBase` regardless of how narrow the phone
    // actually was — a compact phone (e.g. a Pixel 3a at ~393dp) got
    // the identical 3-column poster grid as a noticeably wider one
    // (e.g. a Pixel 6 at ~412dp), just with each card squeezed into
    // proportionally less width. That's what made grid posters read as
    // visibly smaller/cramped compared to Home's own fixed-width
    // cards on the more compact device specifically. Below 400dp, drop
    // one column so each card actually gets more width on a narrower
    // screen instead of shrinking to keep the same column count.
    if (width < 400) return (portraitBase - 1).clamp(1, portraitBase);
    return portraitBase;
  }

  /// Single entry point for "how many columns should this grid have",
  /// parameterized by what kind of content it is — posters, albums,
  /// channels, or a generic fallback — so no screen has to pick its own
  /// breakpoints.
  ///
  /// All four types now route through the exact same [gridColumns]
  /// breakpoints/`portraitBase` movie_grid.dart uses. Albums, channels,
  /// artists, and playlists previously had their own denser
  /// 480/700/1000 -> +1/+1/+1 ladder (`_denseGridColumns`, since
  /// removed) — that gave those grids a different column count than
  /// the Movies screen at the same width/orientation, which read as
  /// inconsistent app-wide. Every grid screen (movies/shows, genre
  /// grids, all-channels + favorite-channels, and the Music tab's
  /// albums/artists/playlists grids) is meant to match the Movies
  /// screen's column count at every breakpoint, in both portrait and
  /// landscape, so this is now a thin one-branch wrapper kept only so
  /// call sites can still say what kind of content they're laying out.
  static int gridColumnsForType(
    BuildContext context,
    GridContentType type, {
    int? portraitBase,
  }) {
    return gridColumns(context, portraitBase: portraitBase ?? 3);
  }
}

/// Width buckets derived from [Responsive.contentAreaWidth], for
/// screens that want to reason in "compact/medium/expanded" terms
/// instead of raw pixel thresholds. Deliberately coarser than the grid
/// breakpoints above — this is for layout *shape* decisions (e.g.
/// single-column vs. two-pane), not column counts.
enum WidthClass { compact, medium, expanded }

/// Content types a grid can hold. Kept as a parameter to
/// [Responsive.gridColumnsForType] so call sites stay self-documenting
/// about what they're laying out, even though every type currently
/// resolves to the same column-count breakpoints (see that method) —
/// app-wide grid consistency is the point, not per-type density.
enum GridContentType { poster, album, channel, generic }

/// Publishes the true, already-measured width of MainNavScreen's
/// landscape content Stack (rail + page content combined) down to
/// descendants, so screens like HomeScreen can bleed rows under the
/// rail by exactly [Responsive.railWidth] without re-deriving that
/// width themselves. See [Responsive.contentAreaWidth].
class LandscapeContentWidth extends InheritedWidget {
  final double width;

  const LandscapeContentWidth({
    super.key,
    required this.width,
    required super.child,
  });

  static double? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<LandscapeContentWidth>()
        ?.width;
  }

  @override
  bool updateShouldNotify(LandscapeContentWidth oldWidget) =>
      width != oldWidget.width;
}
