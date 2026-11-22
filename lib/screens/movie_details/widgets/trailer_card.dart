import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../../services/cache/nemesis_image_cache.dart';
import '../../../services/external_metadata/trailer_service.dart';
import '../../../widgets/common/pressable.dart';

/// Most YouTube trailer thumbnails bake their own black letterboxing
/// into the image pixels (the source frame is narrower than 16:9),
/// so BoxFit.cover alone won't crop it out — it just fills the box
/// with the letterboxed image as-is. Scaling the image up slightly
/// before clipping pushes those bars outside the visible card.
const _thumbnailZoom = 1.22;

/// Horizontal trailer card for the Trailers popup's browsing row —
/// same footprint/visual language as EpisodeCardHorizontal (16:9
/// thumbnail with bottom scrim, label underneath) so the two rows
/// never visually drift apart, just with a centered play icon
/// instead of an episode number.
class TrailerCard extends StatelessWidget {
  final TrailerInfo trailer;
  final VoidCallback? onTap;
  final double width;

  const TrailerCard({
    super.key,
    required this.trailer,
    this.onTap,
    this.width = 240,
  });

  @override
  Widget build(BuildContext context) {
    final height = width * 9 / 16;

    return SizedBox(
      width: width,
      child: Pressable(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: width,
              height: height,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: Transform.scale(
                      scale: _thumbnailZoom,
                      child: CachedNetworkImage(
                        cacheManager: NemesisImageCache.instance,
                        imageUrl: trailer.thumbnailUrl,
                        width: width,
                        height: height,
                        fit: BoxFit.cover,
                        memCacheWidth: (width * 2).toInt(),
                        memCacheHeight: (height * 2).toInt(),
                        placeholder: (_, __) => Container(
                          color: const Color(0xff252525),
                        ),
                        errorWidget: (_, __, ___) => Container(
                          color: const Color(0xff252525),
                          child: const Icon(
                            Icons.movie_creation_outlined,
                            color: Colors.white38,
                          ),
                        ),
                      ),
                    ),
                  ),

                  // Darken slightly so the centered play icon stays
                  // legible against any thumbnail.
                  IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(14),
                        color: Colors.black.withValues(alpha: 0.18),
                      ),
                      child: SizedBox(width: width, height: height),
                    ),
                  ),

                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.black.withValues(alpha: 0.55),
                      border: Border.all(color: Colors.white, width: 1.5),
                    ),
                    child: const Icon(
                      Icons.play_arrow_rounded,
                      color: Colors.white,
                      size: 28,
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 10),

            Text(
              trailer.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
