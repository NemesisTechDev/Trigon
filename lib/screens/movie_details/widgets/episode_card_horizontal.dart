import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../../services/jellyfin_services/media_service.dart';
import '../../../services/download_manager.dart';
import '../../../widgets/common/download_button.dart';
import '../../../widgets/common/watched_badge.dart';
import '../../../widgets/common/pressable.dart';
import '../../../widgets/common/play_icon_overlay.dart';
import '../../../widgets/common/rating_badges.dart';
import '../../../services/cache/nemesis_image_cache.dart';

const _gold = Color(0xffD4AF37);

/// Poster-style horizontal episode card for the landscape detail
/// screen's episode row (thumbnail + duration badge up top, episode
/// number / name / two-line preview / download button underneath —
/// see the reference "Recommended for you" card). An episode that's
/// been started but not finished gets the same bottom progress bar
/// Continue Watching cards use, instead of the plain duration badge
/// alone.
class EpisodeCardHorizontal extends StatelessWidget {
  final dynamic episode;
  final VoidCallback? onTap;
  final double width;

  /// The parent series' IMDb id (from the series item's ProviderIds,
  /// already loaded by the details screen) — used to look up this
  /// episode's own rating via RatingsService.fetchEpisode. See that
  /// method's doc for why this goes through the series' id rather than
  /// the episode's own ProviderIds.
  final String? seriesImdbId;

  const EpisodeCardHorizontal({
    super.key,
    required this.episode,
    this.onTap,
    this.width = 240,
    this.seriesImdbId,
  });

  @override
  Widget build(BuildContext context) {
    final id = episode["Id"] ?? "";
    final name = episode["Name"] ?? "";
    final overview = episode["Overview"] ?? "";
    final number = episode["IndexNumber"]?.toString() ?? "";
    final runtime = MediaService.formatRuntime(episode["RunTimeTicks"]);
    final seasonNumber = (episode["ParentIndexNumber"] as num?)?.toInt();
    final episodeNumber = (episode["IndexNumber"] as num?)?.toInt();
    final hasEpisodeRating = seriesImdbId != null &&
        seriesImdbId!.isNotEmpty &&
        seasonNumber != null &&
        episodeNumber != null;

    final userData = episode["UserData"] ?? {};
    final played = userData["Played"] == true;
    final positionTicks = userData["PlaybackPositionTicks"] ?? 0;
    final runtimeTicks = episode["RunTimeTicks"] ?? 0;

    // Same definition Continue Watching uses: some progress saved,
    // but not yet marked fully played.
    final inProgress = !played && positionTicks > 0 && runtimeTicks > 0;
    final progress =
        inProgress ? (positionTicks / runtimeTicks).clamp(0.0, 1.0) : 0.0;

    final height = width * 9 / 16;

    return SizedBox(
      width: width,
      child: Pressable(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            /// Thumbnail
            SizedBox(
              width: width,
              height: height,
              child: Stack(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: CachedNetworkImage(
                      cacheManager: NemesisImageCache.instance,
                      imageUrl: MediaService.getEpisodeThumbUrl(id),
                      width: width,
                      height: height,
                      fit: BoxFit.cover,
                      // Fixed on-screen size — cap the decoded bitmap
                      // to roughly that (at 2x for retina) instead of
                      // decoding the full source image for a row that
                      // can scroll through a lot of episodes.
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

                  // Bottom scrim so the duration badge (and the
                  // progress bar, when present) stay readable
                  // regardless of what's underneath them.
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    height: height * 0.55,
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: const BorderRadius.vertical(
                            bottom: Radius.circular(14),
                          ),
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.transparent,
                              Colors.black.withValues(alpha: 0.75),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),

                  if (runtime.isNotEmpty)
                    Positioned(
                      left: 8,
                      bottom: inProgress ? 13 : 8,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.play_arrow_rounded,
                            color: Colors.white,
                            size: 16,
                          ),
                          const SizedBox(width: 2),
                          Text(
                            runtime,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),

                  if (played)
                    const Positioned(
                      top: 8,
                      right: 8,
                      child: WatchedBadge(),
                    ),

                  // Continue-watching-style progress bar for an
                  // episode that's been started but not finished yet.
                  if (inProgress)
                    Positioned(
                      left: 6,
                      right: 6,
                      bottom: 6,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: progress,
                          minHeight: 4,
                          backgroundColor: Colors.white24,
                          valueColor:
                              const AlwaysStoppedAnimation<Color>(_gold),
                        ),
                      ),
                    ),

                  const PlayIconOverlay(size: 44),
                ],
              ),
            ),

            const SizedBox(height: 10),

            if (number.isNotEmpty)
              // scaleDown guard: a couple of rating badges next to the
              // episode number can occasionally run wider than this
              // card's fixed width (unlike the plain "Episode N" text
              // this replaces, which was always short) — shrinks
              // instead of overflowing rather than needing its own
              // width calculation against `width` above.
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      "Episode $number",
                      style: const TextStyle(
                        color: _gold,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.3,
                      ),
                    ),
                    if (hasEpisodeRating) ...[
                      const SizedBox(width: 8),
                      RatingsRow(
                        item: Map<String, dynamic>.from(episode),
                        seriesImdbId: seriesImdbId,
                        seasonNumber: seasonNumber,
                        episodeNumber: episodeNumber,
                        fontSize: 11,
                        textColor: Colors.white70,
                        badgeHeight: 12,
                        gap: 6,
                      ),
                    ],
                  ],
                ),
              ),

            if (number.isNotEmpty) const SizedBox(height: 3),

            Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),

            const SizedBox(height: 6),

            Text(
              overview,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 12.5,
                height: 1.35,
              ),
            ),

            const SizedBox(height: 4),

            Align(
              alignment: Alignment.centerRight,
              // DownloadButton renders an IconButton, which claims
              // Material's 48dp minimum tap target regardless of the
              // 20px icon `size` passed below — that's the actual
              // footprint the card's height budget needs to account
              // for, not the icon size. Pin it down to a compact
              // footer-sized box (tight constraints override the
              // IconButton's internal minimum) so the card's real
              // height matches what it was designed to be.
              child: SizedBox(
                height: 24,
                width: 24,
                child: DownloadButton(
                  item: Map<String, dynamic>.from(episode),
                  kind: DownloadKind.episode,
                  size: 20,
                  color: Colors.white70,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
