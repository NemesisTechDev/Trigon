import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../services/trickplay_service.dart';
import '../../services/cache/nemesis_image_cache.dart';

/// Renders a single scrub-preview thumbnail for [position], cropped out
/// of whichever trickplay sprite sheet ("tile") covers that moment.
///
/// Rather than decode the sprite sheet manually and draw a sub-rect
/// (which would mean managing our own `ui.Image` cache/dispose cycle),
/// this leans on `cached_network_image`'s existing memory/disk cache —
/// the same one already used for posters/backdrops elsewhere — and gets
/// the crop for free with a clipped, oversized, offset `Stack`: the full
/// sprite sheet is laid out at whatever scale makes ONE cell equal
/// [width]x[height], then shifted so the desired cell lands in the
/// visible box and everything else is clipped away. Scrubbing across
/// positions that land on the same sheet reuses the exact same decoded
/// image with zero extra network calls, which is what keeps this smooth
/// during a fast drag.
///
/// SEEK-THUMBNAIL FIX (part 5): now a `StatefulWidget`, not stateless.
/// `frameFor` no longer refuses to compute a tile index past the
/// server-reported `thumbnailCount` (see its doc comment for why — that
/// count turned out to not be trustworthy), so this widget can be asked
/// to render a sheet that genuinely doesn't exist yet. It finds that out
/// the only reliable way left: actually trying the request and reacting
/// to a real failure, rather than a metadata field, deciding not to
/// render at all rather than showing a black box standing in for a tile
/// that was never generated.
class TrickplayPreview extends StatefulWidget {
  const TrickplayPreview({
    super.key,
    required this.itemId,
    required this.resolution,
    required this.position,
    this.width = 160,
    this.height = 90,
  });

  final String itemId;
  final TrickplayResolution resolution;
  final Duration position;
  final double width;
  final double height;

  @override
  State<TrickplayPreview> createState() => _TrickplayPreviewState();
}

class _TrickplayPreviewState extends State<TrickplayPreview> {
  // The most recent sprite-sheet URL that genuinely failed to load (a
  // real network/HTTP error surfaced by CachedNetworkImage, not a guess
  // made ahead of time). Scoped to a single URL, not "trickplay is
  // broken for this item forever" — a later drag that lands on an
  // earlier, already-generated sheet must still render normally, and a
  // completed (re)generation mints a new URL anyway (see `tileImageUrl`),
  // so this never needs to be reset by anything other than the URL
  // itself changing.
  String? _failedUrl;

  @override
  Widget build(BuildContext context) {
    final frame = TrickplayService.frameFor(widget.resolution, widget.position);
    final devicePixelRatio = MediaQuery.devicePixelRatioOf(context);

    final url = TrickplayService.tileImageUrl(
      widget.itemId,
      widget.resolution,
      frame.tileIndex,
    );

    // A sheet we already know 404s/errors for this exact URL: render
    // nothing rather than a stale placeholder. This is deliberately re-
    // checked every build (not just once) — as soon as `position` moves
    // to a different sheet, `url` changes and this no longer matches, so
    // the preview reappears the moment the drag is back over real data.
    if (_failedUrl == url) {
      return const SizedBox.shrink();
    }

    return Container(
      width: widget.width,
      height: widget.height,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.white, width: 1.5),
        boxShadow: const [
          BoxShadow(
            color: Colors.black54,
            blurRadius: 12,
            offset: Offset(0, 4),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: ClipRect(
        child: Stack(
          children: [
            Positioned(
              // Shift the whole (scaled-up) sprite sheet so that the
              // one cell we want sits at the top-left of the visible
              // box — everything else falls outside it and gets
              // clipped by the ClipRect above.
              left: -frame.col * widget.width,
              top: -frame.row * widget.height,
              width: widget.resolution.tileWidth * widget.width,
              height: widget.resolution.tileHeight * widget.height,
              child: CachedNetworkImage(
                cacheManager: NemesisImageCache.instance,
                // Keyed on the sheet URL (not the position) so drags
                // that stay within the same sheet don't rebuild/refetch
                // the image widget, only reposition it.
                key: ValueKey(url),
                imageUrl: url,
                httpHeaders: kTrickplayNoCacheHeaders,
                fit: BoxFit.fill,
                fadeInDuration: Duration.zero,
                // House convention (see learnings): always bound decode
                // size for CachedNetworkImage rather than decoding at
                // native resolution. A sprite sheet is `tileWidth` x
                // `tileHeight` cells, each ending up `width`x`height`
                // logical pixels on screen once scaled — this decodes to
                // that same target size (scaled for the device's pixel
                // ratio) instead of whatever raw pixel size the sheet
                // was actually generated at.
                memCacheWidth: (widget.resolution.tileWidth *
                        widget.width *
                        devicePixelRatio)
                    .round(),
                memCacheHeight: (widget.resolution.tileHeight *
                        widget.height *
                        devicePixelRatio)
                    .round(),
                placeholder: (_, __) => Container(color: Colors.black),
                // A real load failure (typically a 404 for a tile past
                // what's actually been generated) — note it via
                // `errorListener` (a side-channel callback, not part of
                // the widget tree) so `setState` isn't fired mid-build,
                // then let this build's own `errorWidget` fall back to
                // nothing-visible for the frame that's already in
                // flight. The *next* build (triggered by that setState)
                // is what actually returns `SizedBox.shrink()` from the
                // top of this method instead of reconstructing this
                // whole Container.
                errorListener: (_) {
                  if (!mounted || _failedUrl == url) return;
                  setState(() => _failedUrl = url);
                },
                errorWidget: (_, __, ___) => const SizedBox.shrink(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

