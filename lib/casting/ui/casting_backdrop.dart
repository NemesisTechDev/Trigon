import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../player/models/media_item.dart';
import '../../services/cache/nemesis_image_cache.dart';
import '../../utils/artwork_source.dart';
import '../../widgets/player/pulsing_logo.dart';
import '../cast_manager.dart';
import '../models/cast_session.dart';
import '../models/cast_states.dart';

const Color _pageBg = Color(0xff161616);
const Color _goldAccent = Color(0xffD4AF37);

/// CASTING PHASE 14 — the backdrop shown behind the player controls once
/// [PlaybackCoordinator] has handed this screen's playback off to a TV.
///
/// Previously this state painted [CastingActivePanel]'s fullscreen panel:
/// a flat black container with a small poster/title card, replacing the
/// controls entirely. That worked, but it also had the video player
/// screen open on a plain black rectangle for as long as the cast
/// session lasted — nothing like the movie/show detail screen the
/// person just came from, and nothing at all like the live TV detail
/// screen for a channel. This widget instead reuses each of those
/// screens' own hero art (movie/episode: [MediaItem.backdrop] — falls
/// back to the series' art for episodes already, see
/// `MediaService.mediaItemFromJellyfin`'s own `backdropLogoId` comment;
/// live TV: [MediaItem.logo], which is really the channel's Primary
/// image — the same "stretched" full-bleed treatment
/// `live_tv_detail_screen.dart` already gives it, since Jellyfin
/// channels never have a real Backdrop-type image of their own) so the
/// casting screen reads as a continuation of the title/channel the
/// person was just looking at, not a dead end.
///
/// Purely decorative — sits behind [VideoSurface] in
/// `VideoPlayerScreen`'s Stack while casting, with the normal control
/// chrome (top bar, center transport, bottom bar) painted on top of it
/// exactly as it would be over the real video. The video itself keeps
/// playing on the TV; nothing here drives or reads playback state.
class CastingBackdrop extends StatelessWidget {
  const CastingBackdrop({super.key, required this.item});

  final MediaItem? item;

  @override
  Widget build(BuildContext context) {
    final isLive = item?.live ?? false;

    // Live channels' `backdrop` field resolves to a Backdrop-type image
    // Jellyfin never actually has for a TvChannel (see
    // `MediaService.mediaItemFromJellyfin`) — `logo` is what's
    // populated with the channel's real Primary image for exactly this
    // reason, so that's the one to stretch full-bleed here, matching
    // live_tv_detail_screen's own `backdrop` local variable (itself
    // built from `getPrimaryImage`, not `getBackdropUrl`).
    final imageUrl = isLive ? item?.logo : item?.backdrop;

    // CASTING FIX: a video opened through Android's Open With/Play With
    // now carries its own decoded-first-frame `backdrop` (see
    // ExternalMediaHandler._buildMediaItem's own doc comment) instead of
    // always being null the way every other local item's `backdrop`
    // still is — an on-disk cache path, not an http(s) URL, so it can't
    // go through `CachedNetworkImage` (which only knows how to fetch a
    // network URL) the way every Jellyfin-backed backdrop here already
    // does. `isRemoteArtwork` is the same http(s)-vs-local-path check
    // `CastingMediaCard`/`MiniPlayer` already use for exactly this
    // "either kind of image can show up in this field" situation.
    final isLocalImageFile = imageUrl != null && !isRemoteArtwork(imageUrl);

    // LOCAL CASTING: an on-device song cast to video (rare, but the
    // audio-only Now Playing screen can still end up showing this via
    // the same casting-state swap) or a video opened through Android's
    // Open With/Play With with no readable frame to decode (a corrupt
    // file, an exotic codec MediaMetadataRetriever couldn't parse) has no
    // `backdrop` at all to fall back to. Rather than leave the screen on
    // a flat, featureless color in that case, show the same treatment
    // VLC's own casting screen uses when it has nothing to show behind
    // the controls either: the app's own mark, badged with the cast
    // glyph, centered on the dark background.
    final showLocalCastMark = imageUrl == null && (item?.isLocal ?? false);

    // FULL-SCREEN-BACKDROP FIX: this used to wrap the content below in
    // its own `Positioned.fill`. `Positioned` is only meaningful as a
    // *direct* child of `Stack` — but this widget doesn't control what
    // its caller wraps it in, and both places it's actually built from
    // (VideoPlayerScreen's `_buildFullPlayer`) hand it down through a
    // couple of `ValueListenableBuilder`s, not directly as a `Stack`
    // child. `VideoSurface` — the widget `CastingBackdrop` swaps places
    // with at that exact spot the instant a cast handoff starts — already
    // documents this exact pitfall on itself and deliberately uses
    // `SizedBox.expand` instead for that reason. `CastingBackdrop` had
    // the same call site but not the same fix, so instead of reliably
    // filling the screen the way the loading backdrop does, it could
    // come up sized to nothing beyond its own content. Matching
    // VideoSurface's approach here makes the two fully interchangeable
    // at that call site, the way the surrounding code already assumes
    // they are.
    return SizedBox.expand(
      child: Container(
        color: _pageBg,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (imageUrl != null)
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 500),
                // FULL-SCREEN-BACKDROP FIX PART 2: AnimatedSwitcher's
                // *own* internal layout (its default layoutBuilder) is
                // a Stack with fit: StackFit.loose, not expand — so
                // even though this whole widget is already forced to
                // full-screen size above, AnimatedSwitcher hands its
                // child loose (not tight) constraints. Without an
                // explicit width/height, CachedNetworkImage responds to
                // loose constraints by sizing itself to the image's own
                // aspect ratio (full width, proportionally shorter
                // height) and centering — BoxFit.cover never gets a
                // chance to do its job because it only controls how the
                // image paints *within* an already-sized box, not what
                // determines that box's size. Net effect: a
                // correctly-cropped-looking image floating short of
                // full height, black showing above/below (the top
                // sliver hidden behind the top bar/casting banner, the
                // bottom sliver exposed) — same root cause already
                // documented for the hero carousel's crossfade snap.
                // SizedBox.expand here forces the box regardless of the
                // loose constraints AnimatedSwitcher passes down, the
                // same fix already applied one level up on this widget.
                child: SizedBox.expand(
                  key: ValueKey(imageUrl),
                  child: isLocalImageFile
                      ? Image.file(
                          File(imageUrl),
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) =>
                              Container(color: _pageBg),
                        )
                      : CachedNetworkImage(
                          cacheManager: NemesisImageCache.instance,
                          imageUrl: imageUrl,
                          fit: BoxFit.cover,
                          fadeInDuration: const Duration(milliseconds: 300),
                          errorWidget: (_, __, ___) =>
                              Container(color: _pageBg),
                        ),
                ),
              ),

            if (showLocalCastMark) const _LocalCastMark(),

            // Same dark top/bottom scrim every backdrop hero in this app
            // already carries (BackdropHeader, live_tv_detail_screen's
            // expanded header) — keeps the top bar's back/cast buttons
            // and the bottom bar's action row legible over bright
            // artwork without needing their own individual gradients to
            // do all of that work alone.
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black54,
                    Colors.black26,
                    Colors.black54,
                  ],
                  stops: [0.0, 0.5, 1.0],
                ),
              ),
            ),

            // The pulsing logo while the TV is loading or buffering — the
            // same beat as the player's own buffering logo. Touch-blind, so
            // the controls painted on top keep working.
            _CastBufferingIndicator(item: item),
          ],
        ),
      ),
    );
  }
}

/// Pulsing logo shown over the casting backdrop whenever the connected TV
/// reports that it is loading or buffering ([CastPlaybackState.loading] /
/// [CastPlaybackState.buffering]). Uses the title's logo artwork when there
/// is one, otherwise the app mark, pulsing with the shared logo beat.
class _CastBufferingIndicator extends StatelessWidget {
  const _CastBufferingIndicator({required this.item});

  final MediaItem? item;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<CastSession?>(
      valueListenable: CastManager.instance.activeSession,
      builder: (_, session, __) {
        if (session == null) return const SizedBox.shrink();
        return ValueListenableBuilder<CastPlaybackState>(
          valueListenable: session.playbackState,
          builder: (_, state, __) {
            final busy = state == CastPlaybackState.buffering ||
                state == CastPlaybackState.loading;
            return IgnorePointer(
              child: AnimatedOpacity(
                opacity: busy ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOut,
                child: busy
                    ? ColoredBox(
                        color: Colors.black26,
                        child: Center(child: _logo()),
                      )
                    : const SizedBox.expand(),
              ),
            );
          },
        );
      },
    );
  }

  Widget _logo() {
    final logo = item?.logo;
    final isLive = item?.live ?? false;
    if (!isLive && logo != null && logo.isNotEmpty && isRemoteArtwork(logo)) {
      return PulsingLogo(logoUrl: logo, width: 220, fillProgress: false);
    }
    return const _PulsingMark();
  }
}

/// The app mark pulsing with the shared logo beat — the stand-in when a
/// title has no logo artwork (live channels, local files).
class _PulsingMark extends StatefulWidget {
  const _PulsingMark();

  @override
  State<_PulsingMark> createState() => _PulsingMarkState();
}

class _PulsingMarkState extends State<_PulsingMark>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: kLogoPulseDuration,
  )..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _pulse,
      builder: (_, child) => Transform.scale(
        scale: kLogoPulseMin + _pulse.value * kLogoPulseRange,
        child: child,
      ),
      child: Image.asset(
        'assets/images/nemesis_logo.png',
        width: 110,
        fit: BoxFit.contain,
      ),
    );
  }
}

/// The app logo merged with the cast glyph, badge-style — the same
/// "no artwork to show, so show our own mark instead" treatment VLC's
/// casting screen uses. Centered, sized modestly (this sits behind full
/// player chrome, not as its own focal screen) so it reads as a calm
/// placeholder rather than competing with the top bar/transport controls
/// painted on top of it.
class _LocalCastMark extends StatelessWidget {
  const _LocalCastMark();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SizedBox(
        width: 108,
        height: 108,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Center(
              child: Opacity(
                opacity: 0.9,
                child: Image.asset(
                  'assets/images/nemesis_logo.png',
                  width: 88,
                  height: 88,
                  fit: BoxFit.contain,
                  // No errorBuilder fallback icon here on purpose — if
                  // the logo asset is ever missing this should read as
                  // "something's wrong", not silently swap to a generic
                  // icon that masks it.
                ),
              ),
            ),
            Positioned(
              right: 0,
              bottom: 4,
              child: Container(
                padding: const EdgeInsets.all(7),
                decoration: BoxDecoration(
                  color: _pageBg,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white24, width: 1.5),
                ),
                child: const Icon(
                  Icons.cast_connected_rounded,
                  size: 22,
                  color: _goldAccent,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
