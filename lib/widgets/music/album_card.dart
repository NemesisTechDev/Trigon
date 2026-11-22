import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import '../../services/jellyfin_services/media_service.dart';
import '../common/pressable.dart';
import '../../services/cache/nemesis_image_cache.dart';

class AlbumCard extends StatelessWidget {
  final Map album;
  final VoidCallback? onTap;
  final bool showLabels;

  // Lets a caller that already knows its own cell width (every current
  // caller does — AlbumGrid/MusicScreen's Albums grid compute it for
  // their own mainAxisExtent math anyway, and every fixed-width row
  // caller already has a known constant) pass it through so the
  // network image decodes at roughly the size it's actually rendered
  // at. Deliberately a plain parameter rather than a LayoutBuilder here
  // — AlbumCard is also used as a SliverGrid cell inside AlbumGrid's
  // CustomScrollView, the same sliver context where a LayoutBuilder
  // elsewhere in this app previously caused an element-reparenting
  // crash (see AlbumGrid's/MovieGrid's own doc comments) — safer not
  // to risk that class of bug for an image-quality improvement.
  // Omitted, behavior is unchanged from before (flat 300px fetch/decode).
  final double? decodeWidth;

  const AlbumCard({
    super.key,
    required this.album,
    this.onTap,
    this.showLabels = true,
    this.decodeWidth,
  });

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);

    // decodeWidth drives the actual *network* request size too, not
    // just the client-side decode cap below — MediaService.getMusicImage's
    // size param becomes the server's maxWidth, so a flat 300 here would
    // have kept fetching a 300px source image even on a TV/tablet cell
    // rendering at 700+ logical px, no matter what memCacheWidth said.
    // Clamped so a caller that hasn't been updated to pass decodeWidth
    // keeps the exact original 300px fetch, and so a plausible-but-huge
    // cell size can't request an unbounded image from the server.
    final requestedSize = decodeWidth != null
        ? ((decodeWidth! * dpr).round()).clamp(150, 800).toInt()
        : 300;

    final image = MediaService.getMusicImage(
      album["Id"],
      size: requestedSize,
    );

    final memCacheWidth = requestedSize;

    return Pressable(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 1,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: CachedNetworkImage(
                cacheManager: NemesisImageCache.instance,
                imageUrl: image,
                fit: BoxFit.cover,
                // Card art is ~130 logical px square in every row that
                // used it before this became responsive — see
                // decodeWidth above for where the real render size
                // comes from now. Falls back to the original flat
                // 300px fetch/decode when no caller passes one.
                memCacheWidth: memCacheWidth,
                fadeInDuration: const Duration(milliseconds: 250),
                placeholder: (_, __) => Container(
                  color: const Color(0xff252525),
                ),
                errorWidget: (_, __, ___) => Container(
                  color: const Color(0xff252525),
                  child: const Center(
                    child: Icon(
                      Icons.album,
                      color: Colors.white24,
                      size: 42,
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (showLabels) ...[
            const SizedBox(height: 8),
            Text(
              album["Name"] ?? "",
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w600,
              ),
            ),
            Text(
              album["AlbumArtist"] ?? "",
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white54,
                fontSize: 12,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
