import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../utils/app_fonts.dart';
import 'blurred_backdrop_image.dart';
import '../../screens/movie_details/widgets/backdrop_header.dart'
    show BackdropAlternate, AccentTintedBar;
import 'rating_badges.dart' show RatingsRow;
import 'pressable.dart';

const Color _pageBg = Color(0xff111111);

/// Same signal backdrop_header.dart uses to decide whether a
/// separating dot belongs before RatingsRow — RatingsRow itself
/// resolves asynchronously (or synchronously from cache) and quietly
/// renders nothing when it comes back empty, so this is only used to
/// reserve the dot/spacing.
bool _hasRatingSignal(Map<String, dynamic>? item) {
  if (item == null) return false;
  final providerIds = item["ProviderIds"];
  return providerIds is Map &&
      (providerIds["Imdb"] ?? providerIds["IMDB"] ?? providerIds["imdb"]) !=
          null;
}

/// Shared landscape-only header for detail screens whose portrait
/// header centers around one image + a title, rather than the
/// movie/series screen's richer runtime/genre/logo layout — cast &
/// crew (person photo) and collections (collection poster) both use
/// this so their landscape appearance stays visually consistent.
///
/// Renders the given icon centered with [title] beneath it, over the
/// same heavily-blurred full-bleed backdrop treatment
/// [LandscapeBackdropBackground] uses on the movie/series detail
/// screen's landscape layout — rather than BackdropHeader's sharp
/// backdrop + gradient.
class CenteredLandscapeHeader extends StatelessWidget {
  final String backdropUrl;
  final double expandedHeight;
  final VoidCallback onBack;
  final String title;

  /// Builds the centered icon at the given side length — called with a
  /// shrinking size as the header collapses, so callers don't need to
  /// manage that animation themselves (e.g. `(size) => ClipOval(...)`
  /// or `(size) => ClipRRect(...)`).
  final Widget Function(double size) iconBuilder;

  /// Icon side length at full expansion; shrinks by [iconShrink] as
  /// the header collapses to [minExtent].
  final double baseIconSize;
  final double iconShrink;

  /// When false, skips painting this header's own blurred backdrop,
  /// scrim, and bottom fade-to-page gradient — only the icon/title
  /// block and back button are drawn. Used when a caller already
  /// paints an equivalent full-page backdrop behind this header (e.g.
  /// the collection detail screen's landscape layout), so this header
  /// doesn't duplicate it or draw a seam-causing fade of its own.
  /// Defaults to true, so existing callers are unaffected.
  final bool showBackground;

  /// Optional alternate identities (e.g. the collection's own
  /// movies/series) that the collapsed bar cycles through as the
  /// person scrolls further down, and the raw scroll offset that
  /// drives that cycling — same mechanism as [BackdropHeader] uses in
  /// portrait, so the collapsed top bar behaves identically in both
  /// orientations instead of just fading to a blank bar here.
  final List<BackdropAlternate>? alternateItems;
  final ValueListenable<double>? scrollOffset;

  /// Optional full item record (e.g. a collection's BoxSet) used to
  /// render the same year / PG rating / rating-badges / genre-chips
  /// row BackdropHeader shows in portrait. Left null by callers (like
  /// cast & crew) that have nothing meaningful to show here — the row
  /// and chip wrap are simply omitted in that case.
  final Map<String, dynamic>? item;

  /// Invoked with a genre string when one of the genre chips is
  /// tapped — same callback shape as BackdropHeader's onGenreTap, so
  /// callers wire both headers up to the same handler. Left null,
  /// chips render as plain non-interactive pills (previous behavior).
  final ValueChanged<String>? onGenreTap;

  const CenteredLandscapeHeader({
    super.key,
    required this.backdropUrl,
    required this.expandedHeight,
    required this.onBack,
    required this.title,
    required this.iconBuilder,
    this.baseIconSize = 96,
    this.iconShrink = 24,
    this.showBackground = true,
    this.alternateItems,
    this.scrollOffset,
    this.item,
    this.onGenreTap,
  });

  @override
  Widget build(BuildContext context) {
    final topPadding = MediaQuery.paddingOf(context).top;

    return SliverPersistentHeader(
      pinned: true,
      delegate: _CenteredLandscapeHeaderDelegate(
        backdropUrl: backdropUrl,
        title: title,
        iconBuilder: iconBuilder,
        baseIconSize: baseIconSize,
        iconShrink: iconShrink,
        onBack: onBack,
        topPadding: topPadding,
        expandedHeight: expandedHeight,
        showBackground: showBackground,
        alternateItems: alternateItems,
        scrollOffset: scrollOffset,
        item: item,
        onGenreTap: onGenreTap,
      ),
    );
  }
}

class _CenteredLandscapeHeaderDelegate extends SliverPersistentHeaderDelegate {
  final String backdropUrl;
  final String title;
  final Widget Function(double size) iconBuilder;
  final double baseIconSize;
  final double iconShrink;
  final VoidCallback onBack;
  final double topPadding;
  final double expandedHeight;
  final bool showBackground;
  final List<BackdropAlternate>? alternateItems;
  final ValueListenable<double>? scrollOffset;
  final Map<String, dynamic>? item;
  final ValueChanged<String>? onGenreTap;

  _CenteredLandscapeHeaderDelegate({
    required this.backdropUrl,
    required this.title,
    required this.iconBuilder,
    required this.baseIconSize,
    required this.iconShrink,
    required this.onBack,
    required this.topPadding,
    required this.expandedHeight,
    required this.showBackground,
    required this.alternateItems,
    required this.scrollOffset,
    required this.item,
    required this.onGenreTap,
  });

  double get _collapsedHeight => topPadding + 56;

  @override
  double get minExtent => _collapsedHeight;

  @override
  double get maxExtent => expandedHeight;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    final range = (maxExtent - minExtent).clamp(1.0, double.infinity);
    final t = (shrinkOffset / range).clamp(0.0, 1.0);

    // Icon shrinks a little as it heads toward the collapsed bar, same
    // "everything eases out together" feel BackdropHeader's
    // poster/title block has on the movie screen.
    final iconSize = baseIconSize - (t * iconShrink);

    return SizedBox(
      height: expandedHeight,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // SCROLL/TRANSITION STUTTER FIX: this sigma-32 Gaussian blur is
          // one of the most expensive things Skia/Impeller does per frame
          // (see MainNavScreen's own rail-blur doc comment for the same
          // point about a different blur) — and this header's two other
          // Stack children directly below (the collapsed identity bar's
          // Opacity, and the icon/title block's Opacity) both animate on
          // every single frame this header is actively collapsing, i.e.
          // continuously throughout a scroll gesture. A sibling's need to
          // repaint propagates up to the nearest RepaintBoundary and
          // forces *everything* under it to repaint too — with none
          // here, that meant this entire (otherwise static) blurred
          // backdrop was being redone from scratch on every scroll frame
          // the whole time the header collapses, and again on every frame
          // of the page-transition animation that first mounts it.
          // Portrait's BackdropHeader never had this problem because it
          // has no blur here at all — this is what made landscape
          // noticeably worse than portrait for both scrolling and page
          // transitions on detail screens using this header. Isolating
          // just this static layer (blur + scrim + fade) behind its own
          // RepaintBoundary lets the engine cache its rendered output as
          // a texture and reuse it untouched while the two Opacity
          // animations above run independently.
          if (showBackground)
            RepaintBoundary(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  /// Heavily blurred backdrop — same full-bleed treatment
                  /// as the movie/series landscape split layout's
                  /// background, scaled up slightly so the blur never
                  /// reveals the plain page background at the image's
                  /// own edges.
                  // Blurred once (see BlurredBackdropImage) rather than by
                  // a live sigma-32 ImageFilter redone every frame.
                  Transform.scale(
                    scale: 1.15,
                    child: BlurredBackdropImage(
                      url: backdropUrl,
                      placeholder: Container(color: _pageBg),
                    ),
                  ),

                  /// Dark scrim so the centered icon/title stay legible
                  /// over the blurred art regardless of how bright it is.
                  Container(color: Colors.black.withValues(alpha: .55)),

                  /// Smooth fade into the page at the bottom, same as
                  /// BackdropHeader, so the header blends into the
                  /// scrolled content below rather than ending on a hard
                  /// edge.
                  Container(
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        stops: [0.0, 0.5, 0.8, 1.0],
                        colors: [
                          Colors.transparent,
                          Colors.transparent,
                          Color(0xAA111111),
                          Color(0xff111111),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),

          /// Collapsed identity bar — same tinted-gradient + cycling
          /// logo treatment BackdropHeader shows once collapsed in
          /// portrait, so the pinned top bar behaves identically in
          /// both orientations instead of fading to a blank bar here.
          _CenteredCollapsedIdentityBar(
            t: t,
            barHeight: minExtent,
            defaultAccentImageUrl: backdropUrl,
            alternateItems: alternateItems,
            scrollOffset: scrollOffset,
            collapseDistance: range,
          ),

          /// Centered icon + title (+ optional year/rating/genre meta,
          /// same data BackdropHeader shows in portrait) — fades out on
          /// the way to collapsed, same as BackdropHeader's info block.
          ///
          /// This block must NOT be laid out against the header's
          /// *current* height. As the sliver collapses toward minExtent
          /// that height shrinks well below the block's natural height,
          /// and the FittedBox(scaleDown) that used to wrap it here
          /// re-fit the whole block (icon, title, chips) to the smaller
          /// box on every frame — which is the visible "everything
          /// scales down while scrolling" effect. Instead the block is
          /// fitted ONCE, against the fully expanded height
          /// ([expandedHeight] minus the top inset and bottom margin —
          /// all constants, so the scale never changes while
          /// scrolling), inside an OverflowBox that keeps that fixed
          /// size and bottom-anchors it to the shrinking header. The
          /// block then simply rides up with the header's bottom edge
          /// at its normal size, clipped by the header's bounds, the
          /// same way the album detail screen's landscape identity
          /// block scrolls away without resizing.
          Positioned.fill(
            // OverflowBox below paints past its own bounds as the header
            // shrinks; clip to the header so nothing draws outside it.
            child: ClipRect(
            child: Padding(
              padding: EdgeInsets.only(top: topPadding),
              child: Opacity(
                opacity: (1 - t).clamp(0.0, 1.0),
                // LayoutBuilder gives the info block a real width to wrap
                // its title/genre chips against — FittedBox alone would
                // hand its child unbounded constraints, which breaks
                // title wrapping/ellipsis and genre-chip wrapping (both
                // need a finite width, not just a finite height).
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    // Bottom-anchored (with a small reserved margin)
                    // rather than dead-centered — see the doc comment
                    // just above on why: centering split this header's
                    // slack space evenly above/below the icon/title/chip
                    // block, and since that block is much shorter than
                    // expandedHeight, the "below" half left a large,
                    // unwanted gap between the genre chips and whatever
                    // a caller places right after this header (e.g. the
                    // Play/Favorite buttons on the collection detail
                    // screen).
                    final fittedHeight =
                        (expandedHeight - topPadding - 16)
                            .clamp(0.0, double.infinity);

                    return Align(
                      alignment: Alignment.bottomCenter,
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: OverflowBox(
                          alignment: Alignment.bottomCenter,
                          minHeight: 0,
                          maxHeight: fittedHeight,
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: SizedBox(
                              width: constraints.maxWidth,
                              child: _CenteredHeaderInfo(
                                icon: iconBuilder(iconSize),
                                title: title,
                                item: item,
                                onGenreTap: onGenreTap,
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
            ),
          ),

          /// Back button — fixed position, always visible, matching
          /// BackdropHeader's placement/style exactly.
          Positioned(
            top: topPadding + 6,
            left: 18,
            child: CircleAvatar(
              radius: 22,
              backgroundColor: Colors.black45,
              child: IconButton(
                onPressed: onBack,
                icon: const Icon(Icons.arrow_back, color: Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  bool shouldRebuild(covariant _CenteredLandscapeHeaderDelegate oldDelegate) {
    return oldDelegate.backdropUrl != backdropUrl ||
        oldDelegate.title != title ||
        oldDelegate.baseIconSize != baseIconSize ||
        oldDelegate.iconShrink != iconShrink ||
        oldDelegate.topPadding != topPadding ||
        oldDelegate.expandedHeight != expandedHeight ||
        oldDelegate.alternateItems != alternateItems ||
        oldDelegate.scrollOffset != scrollOffset ||
        oldDelegate.item != item ||
        oldDelegate.onGenreTap != onGenreTap;
  }
}

/// The icon/title block plus the optional year • PG rating • ratings
/// row and genre chips — same metadata BackdropHeader shows in
/// portrait, just centered instead of left-aligned next to a poster.
/// Split out from the delegate's build() so it can be measured and
/// scaled as a single unit by the FittedBox above.
class _CenteredHeaderInfo extends StatelessWidget {
  final Widget icon;
  final String title;
  final Map<String, dynamic>? item;
  final ValueChanged<String>? onGenreTap;

  const _CenteredHeaderInfo({
    required this.icon,
    required this.title,
    required this.item,
    this.onGenreTap,
  });

  @override
  Widget build(BuildContext context) {
    final year = item?["ProductionYear"]?.toString() ?? "";
    final official = item?["OfficialRating"]?.toString() ?? "";
    final genres = (item?["Genres"] as List? ?? []).take(4).toList();
    final hasRating = _hasRatingSignal(item);

    return Column(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        icon,
        const SizedBox(height: 14),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40),
          child: Text(
            title,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: AppFonts.dosis(
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),

        if (year.isNotEmpty || official.isNotEmpty || hasRating) ...[
          const SizedBox(height: 8),
          Wrap(
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            children: [
              if (year.isNotEmpty)
                Text(
                  year,
                  style: const TextStyle(color: Colors.white70, fontSize: 14),
                ),

              if (year.isNotEmpty && official.isNotEmpty)
                const Text("•", style: TextStyle(color: Colors.white54)),

              if (official.isNotEmpty)
                Text(
                  official,
                  style: const TextStyle(color: Colors.white70, fontSize: 14),
                ),

              if (hasRating) ...[
                if (year.isNotEmpty || official.isNotEmpty)
                  const Text("•", style: TextStyle(color: Colors.white54)),
                RatingsRow(
                  item: Map<String, dynamic>.from(item!),
                  fontSize: 14,
                  textColor: Colors.white,
                  badgeHeight: 15,
                ),
              ],
            ],
          ),
        ],

        if (genres.isNotEmpty) ...[
          const SizedBox(height: 10),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final genre in genres)
                _CenteredGenreChip(
                  genre: genre.toString(),
                  onTap: onGenreTap,
                ),
            ],
          ),
        ],
      ],
    );
  }
}

/// Landscape counterpart to backdrop_header.dart's `_GenreChip` — same
/// look (plain pill, or Pressable + ripple when [onTap] is provided),
/// reused here instead of duplicating a plain Container so this
/// header's genre chips are tappable too.
class _CenteredGenreChip extends StatelessWidget {
  final String genre;
  final ValueChanged<String>? onTap;

  const _CenteredGenreChip({required this.genre, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      decoration: BoxDecoration(
        color: const Color(0xff2A2A2A),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        genre,
        style: const TextStyle(color: Colors.white70, fontSize: 12),
      ),
    );

    if (onTap == null) return chip;

    return Pressable(
      onTap: () => onTap!(genre),
      borderRadius: BorderRadius.circular(20),
      child: chip,
    );
  }
}

/// Landscape counterpart to BackdropHeader's `_CollapsedIdentityBar` —
/// same high-water-mark scroll-driven alternation and
/// [AccentTintedBar] paint, reused here (rather than duplicated) so
/// both orientations' collapsed top bars cycle through a collection's
/// movies identically. Unlike the portrait version, this header has
/// no "default" logo of its own (a collection rarely has one), so the
/// bar simply stays hidden until scrolling has advanced into the
/// alternates.
class _CenteredCollapsedIdentityBar extends StatefulWidget {
  final double t;
  final double barHeight;
  final String defaultAccentImageUrl;
  final List<BackdropAlternate>? alternateItems;
  final ValueListenable<double>? scrollOffset;
  final double collapseDistance;

  const _CenteredCollapsedIdentityBar({
    required this.t,
    required this.barHeight,
    required this.defaultAccentImageUrl,
    required this.alternateItems,
    required this.scrollOffset,
    required this.collapseDistance,
  });

  @override
  State<_CenteredCollapsedIdentityBar> createState() =>
      _CenteredCollapsedIdentityBarState();
}

class _CenteredCollapsedIdentityBarState
    extends State<_CenteredCollapsedIdentityBar> {
  static const double _stepDistance = 160;

  double _maxOffset = 0;

  @override
  void initState() {
    super.initState();
    _maxOffset = widget.scrollOffset?.value ?? 0;
    widget.scrollOffset?.addListener(_onScroll);
  }

  @override
  void didUpdateWidget(covariant _CenteredCollapsedIdentityBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scrollOffset != widget.scrollOffset) {
      oldWidget.scrollOffset?.removeListener(_onScroll);
      widget.scrollOffset?.addListener(_onScroll);
    }
  }

  @override
  void dispose() {
    widget.scrollOffset?.removeListener(_onScroll);
    super.dispose();
  }

  void _onScroll() {
    final offset = widget.scrollOffset!.value;
    if (offset > _maxOffset) {
      setState(() => _maxOffset = offset);
    }
  }

  @override
  Widget build(BuildContext context) {
    String? logoUrl;
    String accentImageUrl = widget.defaultAccentImageUrl;

    final alternates = widget.alternateItems;

    if (alternates != null && alternates.isNotEmpty) {
      // Starts alternating the moment the bar is fully collapsed — not
      // an extra step-distance beyond that — same as the portrait
      // version.
      final past = _maxOffset - widget.collapseDistance;
      if (past >= 0) {
        final index = (past / _stepDistance).floor() % alternates.length;
        final alternate = alternates[index];
        logoUrl = alternate.logoUrl;
        accentImageUrl = alternate.accentImageUrl;
      }
    }

    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      height: widget.barHeight,
      child: IgnorePointer(
        child: Opacity(
          opacity: widget.t,
          child: AccentTintedBar(
            key: ValueKey(accentImageUrl),
            accentImageUrl: accentImageUrl,
            logoUrl: logoUrl,
            barHeight: widget.barHeight,
          ),
        ),
      ),
    );
  }
}
