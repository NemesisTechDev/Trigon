import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../services/jellyfin_services/media_service.dart';
import '../../utils/responsive.dart';
import '../common/pressable.dart';
import '../../services/cache/nemesis_image_cache.dart';

const Color _nemesisBg = Color(0xFF161616);
const Color _gold = Color(0xffD4AF37);

// Tuning for the backdrop's scroll-tied motion (see
// _buildParallaxBackdrop): the backdrop only travels at
// _heroParallaxFactor of the actual scroll distance — i.e. it lags
// behind the logo/program name/button (which scroll normally at 1:1) —
// while gaining up to _heroParallaxMaxZoom extra scale the further it's
// scrolled through, and losing that zoom again as it scrolls back. Both
// are plain functions of the current scroll offset, so scrolling back
// up reverses them automatically — no separate "scrolling up" code path
// needed. Same values Home's hero carousel uses.
const double _heroParallaxFactor = 0.5;
const double _heroParallaxMaxZoom = 0.08;

// How far short of its own box the parallax backdrop's clip stops, at
// the bottom edge — see _buildParallaxBackdrop for why.
const double _heroClipBottomInset = 4.0;

// How far past the backdrop panel's own left edge boundary to bleed a
// solid, matching-color strip in the landscape hero — see the
// seam-bleed comment where it's used in _LandscapeHero. Same root
// cause and same fix as _heroClipBottomInset just above, applied to
// the left edge instead of the bottom. The strip straddles the
// boundary on BOTH sides (this many px into the plain content panel,
// and this many px back into the backdrop panel itself) rather than
// only bleeding outward, since the actual sub-pixel seam can land on
// either side of the panel's nominal edge depending on how the
// backdrop's own composited layer happens to snap that frame.
const double _heroSeamOverscan = 10.0;

/// Live TV's hero carousel card. Full-bleed, no floating-card chrome —
/// mirrors Home's hero carousel treatment directly rather than reading
/// as a separate design: portrait is edge-to-edge with a bottom gradient
/// that hands off into the page background, landscape switches to the
/// same BBC iPlayer-style split Home uses (content on a plain panel to
/// the left, backdrop confined to the right). Channel identity is a bare
/// logo lockup (same "Primary image doubles as the channel's logo"
/// convention as [ChannelLogoCard]/[LiveChannelCard]/the channel detail
/// header) instead of a plain text title. The backdrop also lags/zooms
/// with the page's scroll offset, same as Home's hero — see
/// [_buildParallaxBackdrop].
class FeaturedChannel extends StatelessWidget {
  final Map channel;
  final Map? program;
  final VoidCallback onTap;

  /// The hero's own box height, used to clamp/normalize the parallax
  /// backdrop's scroll-tied lag and zoom (see [_buildParallaxBackdrop]).
  final double heroHeight;

  /// Raw scroll offset (in px) of the page this hero sits in, fed by
  /// the screen's own ScrollController. A ValueListenable rather than a
  /// plain double so only the backdrop transform rebuilds per scroll
  /// frame instead of the whole hero.
  final ValueListenable<double> scrollOffset;

  const FeaturedChannel({
    super.key,
    required this.channel,
    required this.program,
    required this.onTap,
    required this.heroHeight,
    required this.scrollOffset,
  });

  String _resolveBackdrop() {
    final imageTags = program?["ImageTags"];
    final primaryTag = imageTags != null ? imageTags["Primary"] : null;

    if (primaryTag != null) {
      return MediaService.getItemImage(
        program!["Id"],
        tag: primaryTag,
        size: 1200,
      );
    }

    return MediaService.getPrimaryImage(channel["Id"], size: 1200);
  }

  @override
  Widget build(BuildContext context) {
    final heroImage = _resolveBackdrop();

    // Jellyfin TV channels only ever carry a Primary image (their
    // network icon) — the same image used as the channel's "logo"
    // everywhere else it appears in the app.
    final logoUrl = MediaService.getPrimaryImage(channel["Id"], size: 500);
    final channelName = channel["Name"] ?? "";
    final programName = program?["Name"] ?? "Live Channel";
    final isLandscape = Responsive.isLandscape(context);

    return Pressable(
      onTap: onTap,
      child: isLandscape
          ? _LandscapeHero(
              heroImage: heroImage,
              logoUrl: logoUrl,
              channelName: channelName,
              programName: programName,
              onTap: onTap,
              heroHeight: heroHeight,
              scrollOffset: scrollOffset,
            )
          : _PortraitHero(
              heroImage: heroImage,
              logoUrl: logoUrl,
              channelName: channelName,
              programName: programName,
              onTap: onTap,
              heroHeight: heroHeight,
              scrollOffset: scrollOffset,
            ),
    );
  }
}

/// Wraps a backdrop widget (already sized to fill its parent) so it
/// lags behind and slowly zooms with the page's scroll offset, instead
/// of scrolling rigidly at the same rate as the logo/program name/
/// button stacked on top of it. Identical mechanism to Home's hero
/// carousel:
///
/// The backdrop sits inside a normal (non-pinned) sliver, so it already
/// scrolls at 1:1 like everything else by default. To make it lag, we
/// push it back down by `offset * (1 - _heroParallaxFactor)` on every
/// scroll frame — since that's always <= the sliver's own upward
/// translation (`offset`), the backdrop's top edge never pulls short of
/// the box's visible region, so no gap is ever exposed at the top; only
/// its unseen bottom overhang grows, which is simply clipped. The zoom
/// is a plain scale around the center driven by the same offset,
/// clamped to the hero's own height so it settles once the hero has
/// fully scrolled past (it's invisible by then anyway). Scrolling back
/// up reverses both automatically, since they're just functions of the
/// current offset — no separate "scrolling up" branch needed.
///
/// Clips a few px short of the box at the bottom (_heroClipBottomInset)
/// rather than exactly at its edge — landing inside the zone the
/// hero's own gradient has already darkened to fully opaque nemesisBg,
/// so the anti-aliased clip edge (which otherwise blends in a faint,
/// animating smear of the image's own color while scrolling) bleeds
/// from already near-black pixels instead of raw image color.
Widget _buildParallaxBackdrop({
  required double heroHeight,
  required ValueListenable<double> scrollOffset,
  required Widget child,
}) {
  return ClipRect(
    clipper: _HeroBackdropClipper(_heroClipBottomInset),
    child: ValueListenableBuilder<double>(
      valueListenable: scrollOffset,
      builder: (context, rawOffset, backdropChild) {
        final offset = rawOffset.clamp(0.0, heroHeight);
        final t = heroHeight <= 0 ? 0.0 : offset / heroHeight;
        final lag = offset * (1 - _heroParallaxFactor);
        final scale = 1.0 + t * _heroParallaxMaxZoom;
        return Transform.scale(
          scale: scale,
          alignment: Alignment.center,
          child: Transform.translate(
            offset: Offset(0, lag),
            child: backdropChild,
          ),
        );
      },
      child: child,
    ),
  );
}

/// Clips to its full box on every side except the bottom, which stops
/// [bottomInset] px short — see [_buildParallaxBackdrop] for why.
class _HeroBackdropClipper extends CustomClipper<Rect> {
  const _HeroBackdropClipper(this.bottomInset);

  final double bottomInset;

  @override
  Rect getClip(Size size) {
    final height = (size.height - bottomInset).clamp(0.0, size.height);
    return Rect.fromLTWH(0, 0, size.width, height);
  }

  @override
  bool shouldReclip(covariant _HeroBackdropClipper oldClipper) =>
      oldClipper.bottomInset != bottomInset;
}

/// Small "LIVE" pill with a dot, sitting in its own frosted chip so it
/// stays legible over any backdrop rather than plain red-on-image.
class _LiveBadge extends StatelessWidget {
  const _LiveBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: .45),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: .14)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: const BoxDecoration(
              color: Colors.redAccent,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 7),
          const Text(
            "LIVE",
            style: TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.6,
            ),
          ),
        ],
      ),
    );
  }
}

/// Bare channel logo — no surrounding box, border, or background, same
/// as Home's hero logo. Only the bounding box (height + width) is fixed,
/// so every channel's logo occupies the same footprint regardless of its
/// native aspect ratio without stretching or overflowing. Falls back to
/// the channel name if the logo fails to load, same graceful-degradation
/// Home's hero logo uses.
class _LogoBadge extends StatelessWidget {
  final String logoUrl;
  final String channelName;
  final double boxHeight;
  final double boxWidth;

  const _LogoBadge({
    required this.logoUrl,
    required this.channelName,
    required this.boxHeight,
    required this.boxWidth,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: boxHeight,
      width: boxWidth,
      child: CachedNetworkImage(
        cacheManager: NemesisImageCache.instance,
        imageUrl: logoUrl,
        fit: BoxFit.contain,
        alignment: Alignment.centerLeft,
        // No placeholder text here on purpose — showing the channel
        // name in a plain font while the logo is still loading causes
        // a visible flash right before the logo pops in. Staying blank
        // until it's ready (or definitively fails) reads as a clean
        // fade-in instead.
        placeholder: (_, __) => const SizedBox.shrink(),
        errorWidget: (_, __, ___) => Align(
          alignment: Alignment.centerLeft,
          child: Text(
            channelName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 26,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ),
    );
  }
}


/// Unchanged button — same label, icon, and gold/black color pair as
/// before, just a stadium shape so it sits naturally alongside the new
/// frosted badges. `compact` shrinks padding/type for the shorter
/// landscape layout.
class _WatchLiveButton extends StatelessWidget {
  final VoidCallback onTap;
  final bool compact;

  const _WatchLiveButton({required this.onTap, this.compact = false});

  @override
  Widget build(BuildContext context) {
    return FilledButton.icon(
      onPressed: onTap,
      icon: Icon(Icons.play_arrow, size: compact ? 18 : 20),
      label: Text(
        "Watch Live",
        style: TextStyle(
          fontWeight: FontWeight.w700,
          fontSize: compact ? 13 : 14,
        ),
      ),
      style: FilledButton.styleFrom(
        backgroundColor: _gold,
        foregroundColor: Colors.black,
        elevation: 0,
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 16 : 20,
          vertical: compact ? 9 : 12,
        ),
        shape: const StadiumBorder(),
      ),
    );
  }
}

/// Full-bleed backdrop with the badge/logo/button stack anchored to the
/// bottom — same treatment Home's hero carousel uses: a smooth
/// multi-stop gradient that fades all the way to the page background
/// color at the bottom, so the hero hands off cleanly into the rest of
/// the screen instead of ending on a hard edge.
class _PortraitHero extends StatelessWidget {
  final String heroImage;
  final String logoUrl;
  final String channelName;
  final String programName;
  final VoidCallback onTap;
  final double heroHeight;
  final ValueListenable<double> scrollOffset;

  const _PortraitHero({
    required this.heroImage,
    required this.logoUrl,
    required this.channelName,
    required this.programName,
    required this.onTap,
    required this.heroHeight,
    required this.scrollOffset,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        _buildParallaxBackdrop(
          heroHeight: heroHeight,
          scrollOffset: scrollOffset,
          child: CachedNetworkImage(
            cacheManager: NemesisImageCache.instance,
            imageUrl: heroImage,
            fit: BoxFit.cover,
            fadeInDuration: const Duration(milliseconds: 300),
            placeholder: (_, __) => Container(color: _nemesisBg),
            errorWidget: (_, __, ___) => Container(color: _nemesisBg),
          ),
        ),

        // Bottom gradient — fades all the way to the page background
        // color (not just black) so the hero blends seamlessly into
        // the content scrolling in underneath it.
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                _nemesisBg.withValues(alpha: .0),
                _nemesisBg.withValues(alpha: .0),
                _nemesisBg.withValues(alpha: .55),
                _nemesisBg.withValues(alpha: .92),
                _nemesisBg,
              ],
              stops: const [0.0, 0.4, 0.72, 0.9, 1.0],
            ),
          ),
        ),

        Positioned(
          top: 16,
          left: 16,
          child: const _LiveBadge(),
        ),

        Positioned(
          left: 20,
          right: 20,
          bottom: 24,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _LogoBadge(
                logoUrl: logoUrl,
                channelName: channelName,
                boxHeight: 90,
                boxWidth: 300,
              ),

              const SizedBox(height: 10),

              Text(
                programName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),

              const SizedBox(height: 18),

              _WatchLiveButton(onTap: onTap),
            ],
          ),
        ),
      ],
    );
  }
}

/// Landscape counterpart: same BBC iPlayer-style split Home's hero uses.
/// Content sits on a plain panel to the left; the backdrop is confined
/// to the right and blends into that panel via a left-edge gradient
/// instead of running full-bleed under the text, with the same bottom
/// fade to page background the portrait hero uses.
class _LandscapeHero extends StatelessWidget {
  final String heroImage;
  final String logoUrl;
  final String channelName;
  final String programName;
  final VoidCallback onTap;
  final double heroHeight;
  final ValueListenable<double> scrollOffset;

  const _LandscapeHero({
    required this.heroImage,
    required this.logoUrl,
    required this.channelName,
    required this.programName,
    required this.onTap,
    required this.heroHeight,
    required this.scrollOffset,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        Container(color: _nemesisBg),

        // Backdrop, confined to the right ~82% of the card so the
        // content panel always has a guaranteed plain-background strip
        // on the left to sit on, whatever the source image looks like.
        Align(
          alignment: Alignment.centerRight,
          child: FractionallySizedBox(
            widthFactor: 0.82,
            heightFactor: 1,
            child: Stack(
              fit: StackFit.expand,
              // Clip.none lets the seam-bleed strip added below extend
              // a few pixels past this panel's own left edge into the
              // plain content panel beside it — safe, since that panel
              // is the exact same solid color already.
              clipBehavior: Clip.none,
              children: [
                _buildParallaxBackdrop(
                  heroHeight: heroHeight,
                  scrollOffset: scrollOffset,
                  child: CachedNetworkImage(
                    cacheManager: NemesisImageCache.instance,
                    imageUrl: heroImage,
                    fit: BoxFit.cover,
                    fadeInDuration: const Duration(milliseconds: 300),
                    placeholder: (_, __) => Container(color: _nemesisBg),
                    errorWidget: (_, __, ___) => Container(color: _nemesisBg),
                  ),
                ),

                // Left-edge blend into the plain panel.
                DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.centerLeft,
                      end: Alignment.centerRight,
                      colors: [
                        _nemesisBg,
                        _nemesisBg.withValues(alpha: .78),
                        _nemesisBg.withValues(alpha: .0),
                      ],
                      stops: const [0.0, 0.24, 0.58],
                    ),
                  ),
                ),

                // Bottom gradient — fades to the page background color
                // so the hero blends into the content below it, same
                // intent as the portrait hero's bottom fade.
                DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        _nemesisBg.withValues(alpha: .0),
                        _nemesisBg.withValues(alpha: .45),
                        _nemesisBg.withValues(alpha: .85),
                      ],
                      stops: const [0.5, 0.85, 1.0],
                    ),
                  ),
                ),

                // Seam bleed — same root cause as _heroClipBottomInset
                // above: the parallax backdrop's Transform.scale lives
                // inside its own ClipRect/GPU layer, and its left edge
                // can land on a different physical pixel than this
                // panel's nominal boundary — most visibly while the
                // hero crossfades between channels (AnimatedSwitcher's
                // FadeTransition forces this whole panel onto its own
                // composited layer, which is exactly when fractional-
                // pixel seams like this show up). That shows as a
                // hairline of raw image color poking past — or just
                // inside — the left-edge gradient meant to hide it, so
                // this strip straddles the boundary on both sides
                // (rather than only bleeding outward) to guarantee
                // full coverage regardless of which side the seam
                // actually lands on that frame. Painting solid
                // background color here is a no-op wherever the
                // gradient/panel were already correct — it only
                // matters at the exact pixels where they weren't.
                Positioned(
                  left: -_heroSeamOverscan,
                  top: 0,
                  bottom: 0,
                  width: _heroSeamOverscan * 2,
                  child: Container(color: _nemesisBg),
                ),
              ],
            ),
          ),
        ),

        Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 16, 20),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 230),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const _LiveBadge(),

                  const SizedBox(height: 12),

                  _LogoBadge(
                    logoUrl: logoUrl,
                    channelName: channelName,
                    boxHeight: 64,
                    boxWidth: 210,
                  ),

                  const SizedBox(height: 8),

                  Text(
                    programName,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),

                  const SizedBox(height: 14),

                  _WatchLiveButton(onTap: onTap, compact: true),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
