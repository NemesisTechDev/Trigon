import 'dart:ui' show ImageFilter;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../../services/jellyfin_services/media_service.dart';
import '../../../widgets/common/pressable.dart';
import '../../../services/cache/nemesis_image_cache.dart';
import '../../profile/parental/parental_prompts.dart';

const _gold = Color(0xffD4AF37);

class MovieCard extends StatelessWidget {
  final dynamic item;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  // Multi-select look (same as the song rows): while [selectionMode] is
  // on, unselected posters are dimmed and every poster shows a round
  // check badge, filled gold when [selected].
  final bool selectionMode;
  final bool selected;

  const MovieCard({
    super.key,
    required this.item,
    this.onTap,
    this.onLongPress,
    this.selectionMode = false,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) {
    final id = (item["Id"] ?? "").toString();

    // A TMDB-only filmography credit (see
    // CastCrewDetailScreen._tmdbFilmography — no matching Jellyfin
    // item, so no server id to build an image URL from) carries its
    // own already-complete TMDB poster URL instead. Every other
    // caller's item has a real "Id" and never sets "ImageUrl", so
    // this only changes behavior for that one case.
    final overrideImageUrl = item["ImageUrl"] as String?;
    final imageUrl = (id.isEmpty &&
            overrideImageUrl != null &&
            overrideImageUrl.isNotEmpty)
        ? overrideImageUrl
        : MediaService.getImageUrl(id, maxWidth: 300);

    final ratio =
        (item["PrimaryImageAspectRatio"] as num?)
            ?.toDouble() ??
            (2 / 3);

    // Parental Controls: a search result that is blocked is still listed,
    // but blurred and locked. Tapping it only explains why - it never opens.
    final blocked = item is Map && item["ParentalBlocked"] == true;

    return Pressable(
      borderRadius: BorderRadius.circular(16),
      onTap: blocked
          ? () => ParentalPrompts.showTitleBlocked(context, item)
          : onTap,
      onLongPress: blocked ? null : onLongPress,
      child: Hero(
        // Id-less TMDB credits have nothing unique to key off besides
        // their own name — two different id-less credits sharing an
        // exact title is rare enough not to worry about here, and a
        // shared/duplicate Hero tag only risks a mistimed transition,
        // not a crash.
        tag: blocked
            ? "blocked_poster_${id.isNotEmpty ? id : item["Name"]}"
            : "poster_${id.isNotEmpty ? id : item["Name"]}",
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: AspectRatio(
            aspectRatio: ratio,
            child: Stack(
              fit: StackFit.expand,
              children: [
                _maybeBlurred(
                  blocked,
                  CachedNetworkImage(
                  cacheManager: NemesisImageCache.instance,
                  imageUrl: imageUrl,
                  fit: BoxFit.contain,
                  // Card is ~130 logical px wide in every row that uses it.
                  // Capping the decode target keeps posters sharp on retina
                  // screens while avoiding decoding a full oversized bitmap
                  // per card, which is the main cause of slide/scroll jank.
                  memCacheWidth: 260,
                  fadeInDuration:
                  const Duration(milliseconds: 250),
                  placeholder: (_, __) => Container(
                    color: const Color(0xff252525),
                  ),
                  errorWidget: (_, __, ___) => Container(
                    color: const Color(0xff252525),
                    child: const Center(
                      child: Icon(
                        Icons.movie_creation_outlined,
                        color: Colors.white38,
                        size: 42,
                      ),
                    ),
                  ),
                  ),
                ),
                if (blocked)
                  const Positioned.fill(
                    child: ColoredBox(color: Color(0x66000000)),
                  ),
                if (blocked)
                  const Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.lock_outline, color: _gold, size: 34),
                        SizedBox(height: 6),
                        Text(
                          "Blocked",
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                if (selectionMode)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: AnimatedOpacity(
                        duration: const Duration(milliseconds: 150),
                        opacity: selected ? 0 : 1,
                        child: const ColoredBox(color: Color(0x80000000)),
                      ),
                    ),
                  ),
                if (selectionMode)
                  Positioned(
                    top: 6,
                    right: 6,
                    child: Container(
                      width: 22,
                      height: 22,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: selected ? _gold : Colors.black54,
                        border: Border.all(
                          color: selected ? _gold : Colors.white70,
                          width: 1.5,
                        ),
                      ),
                      child: selected
                          ? const Icon(
                              Icons.check,
                              size: 15,
                              color: Colors.black,
                            )
                          : null,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The poster itself when allowed; heavily blurred when blocked.
  static Widget _maybeBlurred(bool blocked, Widget poster) {
    if (!blocked) return poster;
    return ImageFiltered(
      imageFilter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
      child: poster,
    );
  }
}
