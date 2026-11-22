import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../utils/artwork_accent_extractor.dart';
import '../../../utils/logo_trimmer.dart';
import '../../../utils/app_fonts.dart';
import '../../../utils/responsive.dart';
import '../../../services/jellyfin_services/media_service.dart';
import '../../../services/cache/nemesis_image_cache.dart';
import '../../../widgets/common/pressable.dart';
import '../../../widgets/common/rating_badges.dart';

const Color _pageBg = Color(0xff111111);

/// A single "other movie" identity the collapsed bar can switch to on a
/// collection detail screen — its own logo and its own backdrop (used
/// to derive the tint color), distinct from the collection's own
/// (often logo-less) identity.
/// A single genre pill in the portrait header's genre row — same look
/// as the plain chip this replaces, but tappable (Pressable + ripple)
/// when [onTap] is provided, invoking it with [genre].
class _GenreChip extends StatelessWidget {
  final String genre;
  final ValueChanged<String>? onTap;

  const _GenreChip({required this.genre, required this.onTap});

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
        style: const TextStyle(color: Colors.white, fontSize: 12),
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

class BackdropAlternate {
  final String? logoUrl;
  final String accentImageUrl;

  const BackdropAlternate({
    this.logoUrl,
    required this.accentImageUrl,
  });
}

/// Backdrop hero for movie/series/collection detail screens.
///
/// Expanded, this looks like it always has: full backdrop image, big
/// logo, poster + title block. Scrolling collapses it into a pinned
/// bar — the back button stays put throughout, and past the
/// collapse point a gradient tinted with a color pulled from the
/// backdrop fades in behind them (strongest on the right, the same
/// idea as the audio player's artwork-accent background) along with a
/// small version of the movie's logo on the left.
///
/// On a collection detail screen, pass [alternateItems] plus
/// [scrollOffset] (the raw pixel offset of the enclosing
/// CustomScrollView) and the collapsed bar's logo/tint will cycle
/// through the collection's individual movies the further the person
/// scrolls, instead of statically showing the collection's own
/// (usually logo-less) identity.
class BackdropHeader extends StatefulWidget {
  final String backdropUrl;
  final String posterUrl;

  /// Optional small versions shown instantly while the full ones load
  /// (posterPreviewUrl is normally the URL the grid card already cached).
  final String? backdropPreviewUrl;
  final String? posterPreviewUrl;
  final String? logoUrl;
  final Map<String, dynamic> item;
  final VoidCallback onBack;

  /// Invoked with a genre's name when its chip is tapped — left null
  /// makes the genre chips non-interactive.
  final ValueChanged<String>? onGenreTap;

  final List<BackdropAlternate>? alternateItems;
  final ValueListenable<double>? scrollOffset;

  /// When true, the expanded header drops the poster card entirely and
  /// centers the logo where the poster + metadata block used to sit,
  /// with the metadata/ratings row and genre chips centered underneath
  /// it — the same "no icon, centered logo" treatment the landscape
  /// detail layout already uses. Defaults to false so other screens
  /// sharing this widget (collection, cast/crew detail) keep the
  /// original poster + left-aligned title/metadata layout.
  final bool centerLogoNoIcon;

  /// When true, the expanded header keeps the poster/icon — unlike
  /// [centerLogoNoIcon], which drops it in favor of a logo — but
  /// stacks it above a centered title instead of beside it, with the
  /// metadata/ratings row and genre chips centered underneath. Used by
  /// the collection and cast/crew detail screens' portrait layouts.
  /// No logo is shown in this mode even when [logoUrl] is supplied.
  /// Ignored when [centerLogoNoIcon] is also true. Defaults to false
  /// so other screens sharing this widget (movie/series detail) keep
  /// the original poster + left-aligned title/metadata row layout.
  final bool centerIcon;

  /// Overrides how far the bottom-anchored info block (icon/poster,
  /// title, metadata) sits above the header's bottom edge. Null keeps
  /// the built-in inset (30 portrait / 14 landscape). Lets a screen
  /// that puts its own content directly under the header (the cast &
  /// crew screen's role chip) tighten the gap between the two without
  /// changing the header for every other screen sharing this widget.
  final double? infoBottomInset;

  const BackdropHeader({
    super.key,
    required this.backdropUrl,
    required this.posterUrl,
    required this.item,
    required this.onBack,
    this.onGenreTap,
    this.logoUrl,
    this.backdropPreviewUrl,
    this.posterPreviewUrl,
    this.alternateItems,
    this.scrollOffset,
    this.centerLogoNoIcon = false,
    this.centerIcon = false,
    this.infoBottomInset,
  });

  @override
  State<BackdropHeader> createState() => _BackdropHeaderState();
}

class _BackdropHeaderState extends State<BackdropHeader> {
  // The header's collapse/expand rate is fixed 1:1 to raw scroll pixels
  // (SliverPersistentHeader computes its own on-screen size directly
  // from shrinkOffset — nothing in build() below can slow that down).
  // The only real way to make the shrink take longer is to widen the
  // scroll distance between fully-expanded and fully-collapsed, i.e.
  // make this taller. Was 500; bumped up so there's more scroll runway
  // before it fully collapses.
  static const double _portraitExpandedHeight = 620;

  @override
  Widget build(BuildContext context) {
    final topPadding = MediaQuery.paddingOf(context).top;
    final isLandscape = Responsive.isLandscape(context);

    // Portrait keeps the historical fixed 500px header untouched. In
    // landscape the same fixed height would exceed the entire usable
    // screen height on a phone (e.g. ~400px on the Pixel 6) — capping
    // it to a fraction of actual screen height instead means the
    // header never dominates or clips the rest of the page.
    final expandedHeight = Responsive.heroHeight(
      context,
      portraitHeight: _portraitExpandedHeight,
      landscapeFraction: 0.72,
      landscapeMin: 220,
      landscapeMax: 300,
    );

    return SliverPersistentHeader(
      pinned: true,
      delegate: _BackdropHeaderDelegate(
        backdropUrl: widget.backdropUrl,
        posterUrl: widget.posterUrl,
        backdropPreviewUrl: widget.backdropPreviewUrl,
        posterPreviewUrl: widget.posterPreviewUrl,
        logoUrl: widget.logoUrl,
        item: widget.item,
        onBack: widget.onBack,
        onGenreTap: widget.onGenreTap,
        alternateItems: widget.alternateItems,
        scrollOffset: widget.scrollOffset,
        topPadding: topPadding,
        expandedHeight: expandedHeight,
        isLandscape: isLandscape,
        centerLogoNoIcon: widget.centerLogoNoIcon,
        centerIcon: widget.centerIcon,
        infoBottomInset: widget.infoBottomInset,
      ),
    );
  }
}

class _BackdropHeaderDelegate extends SliverPersistentHeaderDelegate {
  final String backdropUrl;
  final String posterUrl;
  final String? backdropPreviewUrl;
  final String? posterPreviewUrl;
  final String? logoUrl;
  final Map<String, dynamic> item;
  final VoidCallback onBack;
  final ValueChanged<String>? onGenreTap;
  final List<BackdropAlternate>? alternateItems;
  final ValueListenable<double>? scrollOffset;
  final double topPadding;
  final double expandedHeight;
  final bool isLandscape;
  final bool centerLogoNoIcon;
  final bool centerIcon;
  final double? infoBottomInset;

  _BackdropHeaderDelegate({
    required this.backdropUrl,
    required this.posterUrl,
    this.backdropPreviewUrl,
    this.posterPreviewUrl,
    required this.logoUrl,
    required this.item,
    required this.onBack,
    this.onGenreTap,
    required this.alternateItems,
    required this.scrollOffset,
    required this.topPadding,
    required this.expandedHeight,
    required this.isLandscape,
    this.centerLogoNoIcon = false,
    this.centerIcon = false,
    this.infoBottomInset,
  });

  double get _collapsedHeight => topPadding + 56;

  Widget _flat() => Container(color: _pageBg);

  /// Small backdrop painted right away under the full one.
  Widget _backdropStandIn() {
    final preview = backdropPreviewUrl;
    if (preview == null || preview.isEmpty) return _flat();
    return CachedNetworkImage(
      cacheManager: NemesisImageCache.instance,
      imageUrl: preview,
      fit: BoxFit.cover,
      fadeInDuration: const Duration(milliseconds: 120),
      placeholder: (_, __) => _flat(),
      errorWidget: (_, __, ___) => _flat(),
    );
  }

  /// Poster stand-in: the grid card's own (already cached) image, same
  /// decode size so Flutter's memory cache hits with no grey flash.
  Widget _posterStandIn(double w, double h) {
    const grey = Color(0xff2A2A2A);
    final preview = posterPreviewUrl;
    if (preview == null || preview.isEmpty) return Container(color: grey);
    return CachedNetworkImage(
      cacheManager: NemesisImageCache.instance,
      imageUrl: preview,
      width: w,
      height: h,
      fit: BoxFit.cover,
      memCacheWidth: 260,
      fadeInDuration: Duration.zero,
      fadeOutDuration: Duration.zero,
      placeholder: (_, __) => Container(color: grey),
      errorWidget: (_, __, ___) => Container(color: grey),
    );
  }

  /// Whether [item] is likely to have an IMDb/Rotten Tomatoes rating to
  /// show — used only to decide whether the separating dot before
  /// RatingsRow renders, since RatingsRow itself resolves
  /// asynchronously (or synchronously from cache) and quietly renders
  /// nothing when it comes back empty.
  bool _hasRatingSignal(Map<String, dynamic> item) {
    final providerIds = item["ProviderIds"];
    return providerIds is Map &&
        (providerIds["Imdb"] ?? providerIds["IMDB"] ?? providerIds["imdb"]) !=
            null;
  }

  // Multiplier applied to `t` (0-1 scroll progress) when computing how
  // fast the big logo/poster/info block fades and shrinks away.
  // Previously 1.6, which meant everything finished fading out at
  // ~63% of the way through the collapse — the header still had ~37%
  // more physical scroll distance left to shrink through, so the last
  // stretch of the scroll felt like nothing was happening (all the
  // "scaling down" had already rushed to completion early). Bringing
  // this down to 1.0 spreads the fade across the *entire* collapse
  // distance instead, so the shrink reads as one smooth, evenly-paced
  // motion rather than a fast burst followed by a dead zone — and the
  // same applies symmetrically on the way back out while scrolling up.
  static const double _fadeSpeed = 1.0;

  @override
  double get minExtent => _collapsedHeight;

  @override
  double get maxExtent => expandedHeight;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    final range = (maxExtent - minExtent).clamp(1.0, double.infinity);
    final t = (shrinkOffset / range).clamp(0.0, 1.0);

    // A Series item's RunTimeTicks reflects a single (often arbitrary)
    // episode's duration, not the show as a whole, so it's misleading
    // to show it here — only movies get a duration readout.
    final runtime = item["Type"] == "Series"
        ? ""
        : MediaService.formatRuntime(item["RunTimeTicks"]);
    final year = item["ProductionYear"]?.toString() ?? "";
    final official = item["OfficialRating"] ?? "";
    final genres = (item["Genres"] as List? ?? []).take(4);

    // Landscape has roughly half the vertical room portrait does, so
    // the poster, logo, and their offsets all scale down together
    // rather than the fixed portrait sizes fighting for space inside
    // a much shorter header.
    final posterWidth = isLandscape ? 92.0 : 135.0;
    final posterHeight = isLandscape ? 132.0 : 200.0;
    final infoRowBottom = infoBottomInset ?? (isLandscape ? 14.0 : 30.0);
    final logoHeight = isLandscape ? 40.0 : 80.0;
    final titleFontSize = isLandscape ? 20.0 : 28.0;

    return SizedBox(
      height: expandedHeight,
      child: Stack(
        fit: StackFit.expand,
        children: [
          /// Backdrop
          CachedNetworkImage(
            cacheManager: NemesisImageCache.instance,
            imageUrl: backdropUrl,
            fit: BoxFit.cover,
            fadeInDuration: const Duration(milliseconds: 250),
            placeholder: (_, __) => _backdropStandIn(),
            errorWidget: (_, __, ___) => _backdropStandIn(),
          ),

          /// Dark overlay
          Container(color: Colors.black.withValues(alpha: .35)),

          /// Smooth fade into page
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: [0.0, 0.45, 0.75, 1.0],
                colors: [
                  Colors.transparent,
                  Colors.transparent,
                  Color(0xAA111111),
                  Color(0xff111111),
                ],
              ),
            ),
          ),

          /// Logo + Poster + Movie info, as ONE bottom-anchored group.
          ///
          /// OVERLAP FIX: the logo used to be a separately-`Positioned`
          /// box at a fixed `bottom: 210.0` ("logoBottom"), completely
          /// disconnected from how tall the title/metadata block below
          /// actually turned out to be. A movie title that wraps to its
          /// full allowed 2 lines (long title, or a narrower text
          /// column — poster + padding leave less width for text on a
          /// wider poster/narrower screen), plus a genre chip row
          /// wrapping to two lines of its own, could grow the info
          /// block's rendered height past the ~180px gap the fixed
          /// logo position assumed, and its top edge would rise straight
          /// into the logo sitting above it. Putting logo, poster, and
          /// title/metadata into one Column and anchoring the whole
          /// group from the bottom instead means the logo's position is
          /// always "however tall the info block is, plus a fixed gap"
          /// — it physically cannot overlap, regardless of how many
          /// lines the title or genre chips wrap to.
          Positioned(
            left: 24,
            right: 24,
            bottom: infoRowBottom,
            child: Opacity(
              opacity: (1 - t * _fadeSpeed).clamp(0.0, 1.0),
              child: centerLogoNoIcon
                  ? _buildCenteredLogoContent(
                      context,
                      logoHeight: logoHeight,
                      runtime: runtime,
                      year: year,
                      official: official,
                      genres: genres,
                    )
                  : centerIcon
                      ? _buildCenteredIconContent(
                          context,
                          posterWidth: posterWidth,
                          posterHeight: posterHeight,
                          titleFontSize: titleFontSize,
                          runtime: runtime,
                          year: year,
                          official: official,
                          genres: genres,
                        )
                      : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Big movie logo — fades out as the header collapses,
                  // handing off to the small collapsed logo near the
                  // top instead. Rendered via TrimmedLogo with a fixed
                  // target area so every title's logo occupies the
                  // same visual footprint here, regardless of whether
                  // the source art is a bold, blocky mark or a thin
                  // single-line wordmark — otherwise some logos read as
                  // oversized and others as tiny next to each other.
                  if (logoUrl != null) ...[
                    SizedBox(
                      height: logoHeight,
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: TrimmedLogo(
                          url: logoUrl!,
                          alignment: Alignment.centerRight,
                          targetArea:
                              logoHeight * (isLandscape ? 3.2 : 2.6) * logoHeight,
                          maxWidth: isLandscape ? 180 : 300,
                          maxHeight: logoHeight,
                          fallbackText: item["Name"]?.toString(),
                        ),
                      ),
                    ),
                    SizedBox(height: isLandscape ? 10.0 : 16.0),
                  ],
                  Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Hero(
                    tag: "poster_${item["Id"]}",
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(18),
                      child: posterUrl.isEmpty
                          ? Container(
                              width: posterWidth,
                              height: posterHeight,
                              color: const Color(0xff2A2A2A),
                              child: const Icon(
                                Icons.person,
                                color: Colors.white30,
                                size: 42,
                              ),
                            )
                          : CachedNetworkImage(
                              cacheManager: NemesisImageCache.instance,
                              imageUrl: posterUrl,
                              width: posterWidth,
                              height: posterHeight,
                              fit: BoxFit.cover,
                              fadeInDuration: const Duration(milliseconds: 200),
                              placeholder: (_, __) =>
                                  _posterStandIn(posterWidth, posterHeight),
                              errorWidget: (_, __, ___) => Container(
                                color: const Color(0xff2A2A2A),
                                child: const Icon(
                                  Icons.person,
                                  color: Colors.white30,
                                  size: 42,
                                ),
                              ),
                            ),
                    ),
                  ),

                  const SizedBox(width: 20),

                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          item["Name"] ?? "",
                          maxLines: isLandscape ? 1 : 2,
                          overflow: TextOverflow.ellipsis,
                          style: AppFonts.dosis(fontSize: titleFontSize, fontWeight: FontWeight.bold),
                        ),

                        SizedBox(height: isLandscape ? 6 : 10),

                        Wrap(
                          spacing: 8,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            if (runtime.isNotEmpty)
                              Text(
                                runtime,
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 14,
                                ),
                              ),

                            if (runtime.isNotEmpty && year.isNotEmpty)
                              const Text(
                                "•",
                                style: TextStyle(color: Colors.white54),
                              ),

                            if (year.isNotEmpty)
                              Text(
                                year,
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 14,
                                ),
                              ),

                            if (year.isNotEmpty && official.isNotEmpty)
                              const Text(
                                "•",
                                style: TextStyle(color: Colors.white54),
                              ),

                            if (official.isNotEmpty)
                              Text(
                                official,
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 14,
                                ),
                              ),

                            // Separator + RatingsRow are grouped into a single
                            // Row so Wrap treats them as one atomic unit: if
                            // there isn't room left on the current line, the
                            // dot moves down together with the ratings it
                            // introduces instead of being stranded at the end
                            // of the line above it (the bug being fixed here).
                            if (_hasRatingSignal(item))
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Text(
                                    "•",
                                    style: TextStyle(color: Colors.white54),
                                  ),
                                  const SizedBox(width: 8),
                                  RatingsRow(
                                    item: Map<String, dynamic>.from(item),
                                    fontSize: 14,
                                    textColor: Colors.white,
                                    badgeHeight: 15,
                                  ),
                                ],
                              ),
                          ],
                        ),

                        if (genres.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              for (final genre in genres)
                                _GenreChip(
                                  genre: genre.toString(),
                                  onTap: onGenreTap,
                                ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
                  ),
                ],
              ),
            ),
          ),

          /// Collapsed identity — gradient tint + small logo, cross-fading
          /// in as the header collapses. When [alternateItems] is
          /// supplied (collection screens), this also cycles through the
          /// collection's own movies the further the person scrolls.
          _CollapsedIdentityBar(
            t: t,
            barHeight: minExtent,
            defaultLogoUrl: logoUrl,
            defaultAccentImageUrl: backdropPreviewUrl ?? backdropUrl,
            alternateItems: alternateItems,
            scrollOffset: scrollOffset,
            collapseDistance: range,
          ),

          /// Back button — fixed position, always visible, never clipped
          /// since it sits near the top of this (top-anchored) stack.
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

  /// The "no icon" expanded content used when [centerLogoNoIcon] is
  /// true: the poster card is dropped entirely and the logo is
  /// centered where the icon + metadata block used to sit, with the
  /// duration/year/rating (+ ratings row) centered underneath it, and
  /// genre chips centered in their own row below that — matching the
  /// landscape detail layout's logo/metadata treatment
  /// (_LandscapeMetaRow in movie_details_screen.dart). Falls back to
  /// nothing (no title text) when there's no logo, same as landscape.
  Widget _buildCenteredLogoContent(
    BuildContext context, {
    required double logoHeight,
    required String runtime,
    required String year,
    required String official,
    required Iterable genres,
  }) {
    final infoParts = <Widget>[];
    void addDot() {
      if (infoParts.isNotEmpty) {
        infoParts.add(
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              "•",
              style: TextStyle(color: Colors.white54, fontSize: 14),
            ),
          ),
        );
      }
    }

    if (runtime.isNotEmpty) {
      addDot();
      infoParts.add(
        Text(
          runtime,
          style: const TextStyle(color: Colors.white70, fontSize: 14),
        ),
      );
    }

    if (year.isNotEmpty) {
      addDot();
      infoParts.add(
        Text(
          year,
          style: const TextStyle(color: Colors.white70, fontSize: 14),
        ),
      );
    }

    if (official.isNotEmpty) {
      addDot();
      infoParts.add(
        Text(
          official,
          style: const TextStyle(color: Colors.white70, fontSize: 14),
        ),
      );
    }

    // RatingsRow is deliberately NOT folded into infoParts (and gets no
    // "•" of its own) — it always renders as its own centered row below
    // the runtime/year/official-rating line rather than trying to share
    // a line with them. Wrap treats every child as an independent unit,
    // so a dot added here as a separate infoParts entry could end up
    // stranded at the end of the line above when only RatingsRow itself
    // ran out of room — exactly the dangling-separator bug this
    // structure avoids. See _hasRatingSignal's doc for why this check
    // (rather than waiting on RatingsRow's own async resolution) is
    // what gates the spacing below.
    final hasRatings = _hasRatingSignal(item);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (logoUrl != null) ...[
          SizedBox(
            height: logoHeight,
            width: double.infinity,
            child: TrimmedLogo(
              url: logoUrl!,
              alignment: Alignment.center,
              targetArea:
                  logoHeight * (isLandscape ? 3.2 : 2.6) * logoHeight,
              maxWidth: isLandscape ? 220 : 300,
              maxHeight: logoHeight,
              fallbackText: item["Name"]?.toString(),
            ),
          ),
          SizedBox(height: isLandscape ? 10.0 : 16.0),
        ],

        // Runtime / year / official rating — its own centered line,
        // with no trailing separator now that RatingsRow never shares
        // it.
        if (infoParts.isNotEmpty)
          Wrap(
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: infoParts,
          ),

        // Ratings badges — always their own centered line, no leading
        // separator, whether or not the line above wrapped.
        if (hasRatings) ...[
          if (infoParts.isNotEmpty) const SizedBox(height: 8),
          RatingsRow(
            item: Map<String, dynamic>.from(item),
            fontSize: 14,
            textColor: Colors.white,
            badgeHeight: 15,
          ),
        ],

        if (genres.isNotEmpty) ...[
          if (infoParts.isNotEmpty || hasRatings) const SizedBox(height: 12),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final genre in genres)
                _GenreChip(
                  genre: genre.toString(),
                  onTap: onGenreTap,
                ),
            ],
          ),
        ],
      ],
    );
  }

  /// The "centered icon" expanded content used when [centerIcon] is
  /// true: keeps the poster/icon (unlike [_buildCenteredLogoContent],
  /// which drops it for a logo) but stacks it above a centered title,
  /// so the header reads icon → title → metadata → genre chips, all
  /// centered, instead of the side-by-side poster+text row. No logo
  /// is shown here even when [logoUrl] is supplied.
  Widget _buildCenteredIconContent(
    BuildContext context, {
    required double posterWidth,
    required double posterHeight,
    required double titleFontSize,
    required String runtime,
    required String year,
    required String official,
    required Iterable genres,
  }) {
    final infoParts = <Widget>[];
    void addDot() {
      if (infoParts.isNotEmpty) {
        infoParts.add(
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              "•",
              style: TextStyle(color: Colors.white54, fontSize: 14),
            ),
          ),
        );
      }
    }

    if (runtime.isNotEmpty) {
      addDot();
      infoParts.add(
        Text(
          runtime,
          style: const TextStyle(color: Colors.white70, fontSize: 14),
        ),
      );
    }

    if (year.isNotEmpty) {
      addDot();
      infoParts.add(
        Text(
          year,
          style: const TextStyle(color: Colors.white70, fontSize: 14),
        ),
      );
    }

    if (official.isNotEmpty) {
      addDot();
      infoParts.add(
        Text(
          official,
          style: const TextStyle(color: Colors.white70, fontSize: 14),
        ),
      );
    }

    // Same reasoning as _buildCenteredLogoContent: RatingsRow always
    // gets its own centered line below runtime/year/official-rating
    // rather than sharing one with them, so a Wrap-forced line break
    // never strands a dangling "•" at the end of the line above.
    final hasRatings = _hasRatingSignal(item);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Hero(
          tag: "poster_${item["Id"]}",
          child: ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: posterUrl.isEmpty
                ? Container(
                    width: posterWidth,
                    height: posterHeight,
                    color: const Color(0xff2A2A2A),
                    child: const Icon(
                      Icons.person,
                      color: Colors.white30,
                      size: 42,
                    ),
                  )
                : CachedNetworkImage(
                    cacheManager: NemesisImageCache.instance,
                    imageUrl: posterUrl,
                    width: posterWidth,
                    height: posterHeight,
                    fit: BoxFit.cover,
                    fadeInDuration: const Duration(milliseconds: 200),
                    placeholder: (_, __) =>
                        _posterStandIn(posterWidth, posterHeight),
                    errorWidget: (_, __, ___) => Container(
                      color: const Color(0xff2A2A2A),
                      child: const Icon(
                        Icons.person,
                        color: Colors.white30,
                        size: 42,
                      ),
                    ),
                  ),
          ),
        ),

        SizedBox(height: isLandscape ? 10.0 : 16.0),

        Text(
          item["Name"] ?? "",
          textAlign: TextAlign.center,
          maxLines: isLandscape ? 1 : 2,
          overflow: TextOverflow.ellipsis,
          style: AppFonts.dosis(
            fontSize: titleFontSize,
            fontWeight: FontWeight.bold,
          ),
        ),

        if (infoParts.isNotEmpty) ...[
          const SizedBox(height: 10),
          Wrap(
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: infoParts,
          ),
        ],

        if (hasRatings) ...[
          SizedBox(height: infoParts.isNotEmpty ? 8 : 10),
          RatingsRow(
            item: Map<String, dynamic>.from(item),
            fontSize: 14,
            textColor: Colors.white,
            badgeHeight: 15,
          ),
        ],

        if (genres.isNotEmpty) ...[
          SizedBox(height: infoParts.isNotEmpty || hasRatings ? 12 : 10),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final genre in genres)
                _GenreChip(
                  genre: genre.toString(),
                  onTap: onGenreTap,
                ),
            ],
          ),
        ],
      ],
    );
  }

  @override
  bool shouldRebuild(covariant _BackdropHeaderDelegate oldDelegate) {
    return oldDelegate.backdropUrl != backdropUrl ||
        oldDelegate.posterUrl != posterUrl ||
        oldDelegate.backdropPreviewUrl != backdropPreviewUrl ||
        oldDelegate.posterPreviewUrl != posterPreviewUrl ||
        oldDelegate.logoUrl != logoUrl ||
        oldDelegate.item != item ||
        oldDelegate.alternateItems != alternateItems ||
        oldDelegate.scrollOffset != scrollOffset ||
        oldDelegate.topPadding != topPadding ||
        oldDelegate.expandedHeight != expandedHeight ||
        oldDelegate.isLandscape != isLandscape ||
        oldDelegate.centerLogoNoIcon != centerLogoNoIcon ||
        oldDelegate.infoBottomInset != infoBottomInset ||
        oldDelegate.centerIcon != centerIcon;
  }
}

/// Renders the gradient tint (strongest on the right, matching the
/// reference behavior) and the small left-aligned logo shown once the
/// header is collapsed. Picks its color by sampling the relevant
/// backdrop with [ArtworkAccentExtractor] (same utility the audio
/// player uses), and smoothly cross-fades whenever the identity it's
/// showing changes — either because the movie's own art finished
/// loading, or because scrolling further advanced to the next
/// alternate movie in a collection.
class _CollapsedIdentityBar extends StatefulWidget {
  final double t;
  final double barHeight;
  final String? defaultLogoUrl;
  final String defaultAccentImageUrl;
  final List<BackdropAlternate>? alternateItems;
  final ValueListenable<double>? scrollOffset;
  final double collapseDistance;

  const _CollapsedIdentityBar({
    required this.t,
    required this.barHeight,
    required this.defaultLogoUrl,
    required this.defaultAccentImageUrl,
    required this.alternateItems,
    required this.scrollOffset,
    required this.collapseDistance,
  });

  @override
  State<_CollapsedIdentityBar> createState() => _CollapsedIdentityBarState();
}

class _CollapsedIdentityBarState extends State<_CollapsedIdentityBar> {
  // How far (in scroll pixels) each alternate movie gets before handing
  // off to the next one. Kept fairly short — collection screens often
  // don't have a huge amount of scrollable content below the header,
  // so a wide step meant the alternation rarely, if ever, kicked in.
  static const double _stepDistance = 160;

  // High-water mark of the scroll offset seen so far. The alternate
  // shown is derived from this instead of the live offset, so scrolling
  // back up leaves whichever movie is currently showing in place —
  // it only advances to the next one once the person scrolls down
  // further than they ever have before, then holds there again. Only
  // grows, never shrinks, for the lifetime of this bar.
  double _maxOffset = 0;

  @override
  void initState() {
    super.initState();
    _maxOffset = widget.scrollOffset?.value ?? 0;
    widget.scrollOffset?.addListener(_onScroll);
  }

  @override
  void didUpdateWidget(covariant _CollapsedIdentityBar oldWidget) {
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
    // Only rebuild (this small widget, not the whole header) when the
    // high-water mark actually advances — an upward scroll shouldn't
    // trigger a rebuild here since nothing about the shown alternate
    // changes.
    if (offset > _maxOffset) {
      setState(() => _maxOffset = offset);
    }
  }

  @override
  Widget build(BuildContext context) {
    String? logoUrl = widget.defaultLogoUrl;
    String accentImageUrl = widget.defaultAccentImageUrl;

    final alternates = widget.alternateItems;

    if (alternates != null && alternates.isNotEmpty) {
      // Starts alternating the moment the bar is fully collapsed — not
      // an extra step-distance beyond that — so it's the very first
      // thing shown in the collapsed bar rather than the (often
      // logo-less) collection identity.
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

/// One accent-color extraction + its gradient/logo paint, keyed by the
/// image it was extracted from so switching identities (collection
/// alternation) cross-fades cleanly via the implicit AnimatedSwitcher
/// above rather than popping between colors.
///
/// Public — also reused directly (no alternate-item cycling) by other
/// detail screens (music album/artist/playlist, live TV channel) that
/// want the same "collapsed bar takes the artwork's color, with a small
/// logo on the left" treatment as this one.
class AccentTintedBar extends StatefulWidget {
  final String accentImageUrl;
  final String? logoUrl;
  final double barHeight;

  const AccentTintedBar({
    super.key,
    required this.accentImageUrl,
    required this.logoUrl,
    required this.barHeight,
  });

  @override
  State<AccentTintedBar> createState() => _AccentTintedBarState();
}

class _AccentTintedBarState extends State<AccentTintedBar> {
  Color? _accent;

  @override
  void initState() {
    super.initState();
    _loadAccent();
  }

  Future<void> _loadAccent() async {
    final color = await ArtworkAccentExtractor.extractFromUrl(
      widget.accentImageUrl,
    );
    if (!mounted) return;
    setState(() => _accent = color);
  }

  @override
  Widget build(BuildContext context) {
    final accent = _accent;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeOut,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: [
            _pageBg,
            accent == null ? _pageBg : Color.lerp(_pageBg, accent, 0.85)!,
          ],
        ),
      ),
      child: Padding(
        padding: EdgeInsets.only(
          top: widget.barHeight - 56,
        ),
        child: Row(
          children: [
            const SizedBox(width: 66),
            if (widget.logoUrl != null)
              Expanded(
                child: Align(
                  alignment: Alignment.center,
                  // Previously faded in only once `accent != null`, so
                  // the logo — which loads fast on its own via
                  // TrimmedLogo's own CachedNetworkImage fallback — sat
                  // hidden behind whatever the (much slower,
                  // network-bound) accent color extraction was doing.
                  // It now shows as soon as it's ready; only the
                  // background tint below waits on the accent color,
                  // and it already has a sensible default (the plain
                  // page background) to sit at in the meantime.
                  child: SizedBox(
                    height: 26,
                    child: TrimmedLogo(
                      url: widget.logoUrl!,
                      alignment: Alignment.center,
                    ),
                  ),
                ),
              ),
            const SizedBox(width: 96),
          ],
        ),
      ),
    );
  }
}
