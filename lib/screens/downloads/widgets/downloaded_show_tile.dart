import 'dart:io';

import 'package:flutter/material.dart';

import '../../../services/download_manager.dart';
import '../../../utils/responsive.dart';
import '../../../widgets/common/pressable.dart';
import '../../../widgets/common/landscape_art_image.dart';

const _gold = Color(0xffD4AF37);

String _fmtBytes(int bytes) {
  if (bytes <= 0) return '';
  const kb = 1024;
  const mb = kb * 1024;
  const gb = mb * 1024;
  if (bytes >= gb) return '${(bytes / gb).toStringAsFixed(1)} GB';
  return '${(bytes / mb).toStringAsFixed(0)} MB';
}

/// A downloaded show, shown as a list row rather than a poster tile —
/// [DownloadedMovieTile]'s same 16:9 rounded-corner card (itself the
/// Continue Watching row's own artwork treatment), with the series
/// name / episode count / total size read off to the right instead of
/// overlaid on the image, so the TV Shows tab reads as the same
/// row-list family as Movies rather than a separate poster grid.
///
/// Unlike the movie tile, this one also needs to reflect something
/// that isn't in [episodes] at all: another episode of this same
/// series that's still transferring. `episodes` only ever holds
/// *completed* downloads, so that state comes from DownloadManager's
/// live task list instead — hence the AnimatedBuilder wrapping just
/// the "Downloading in progress" line, while the parent list's own
/// rebuild (on any DownloadManager change) keeps `episodes` itself
/// current.
///
/// [episodes] may be empty: a series whose very first episode is still
/// transferring has no completed record yet, but still gets its row —
/// in the spot it'll settle into — showing just "Download in progress"
/// under the name, with its artwork pulled from the server instead of
/// disk.
class DownloadedShowTile extends StatelessWidget {
  final String seriesId;
  final String seriesName;
  final List<DownloadRecord> episodes;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const DownloadedShowTile({
    super.key,
    required this.seriesId,
    required this.seriesName,
    required this.episodes,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final thumbWidth = Responsive.isTV ? 220.0 : 140.0;
    const aspect = 16 / 9;

    final totalSize =
        episodes.fold<int>(0, (sum, e) => sum + e.fileSizeBytes);
    final metaParts = [
      if (episodes.isNotEmpty)
        "${episodes.length} episode${episodes.length == 1 ? '' : 's'}",
      if (totalSize > 0) _fmtBytes(totalSize),
    ];

    // No card enclosure — the row sits flush on the Downloads screen's
    // own background, matching the reference design. Only spacing
    // between rows remains; Pressable still supplies its own ripple.
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
      child: Pressable(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: thumbWidth,
                child: AspectRatio(
                  aspectRatio: aspect,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: _thumbnail(),
                      ),
                      Positioned.fill(
                        child: IgnorePointer(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.10),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        seriesName,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          height: 1.25,
                        ),
                      ),
                      const SizedBox(height: 6),
                      if (metaParts.isNotEmpty)
                        Text(
                          metaParts.join(' • '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 12,
                          ),
                        ),
                      AnimatedBuilder(
                        animation: DownloadManager.instance,
                        builder: (context, _) {
                          if (!DownloadManager.instance
                              .seriesHasActiveDownload(seriesId)) {
                            return const SizedBox.shrink();
                          }
                          return Padding(
                            padding: EdgeInsets.only(
                              top: metaParts.isNotEmpty ? 4 : 0,
                            ),
                            child: const Text(
                              "Download in progress",
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: _gold,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 6),
              // Affordance that this whole row opens into the show's
              // episode list — same purpose the dustbin icon used to
              // sit in, now filled by an unambiguous "tap to open"
              // chevron instead of a destructive action.
              const Icon(
                Icons.chevron_right_rounded,
                color: Colors.white38,
                size: 26,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _thumbnail() {
    // Same landscape-Thumb-preferred, poster-fallback rule
    // DownloadedMovieTile uses — see that file's comment.
    final path = episodes
        .map((e) => e.thumbPath ?? e.posterPath)
        .firstWhere((p) => p != null, orElse: () => null);
    if (path == null) {
      // Nothing on disk yet (first episode still transferring) — the
      // series' landscape art from the server, same request the
      // in-progress movie/song rows make for their own thumbnails.
      if (episodes.isEmpty) {
        return LandscapeArtImage(
          imageId: seriesId,
          maxWidth: 320,
          placeholder: Container(color: const Color(0xff252525)),
          errorWidget: _placeholder(),
        );
      }
      return _placeholder();
    }

    return Image.file(
      File(path),
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) => _placeholder(),
    );
  }

  Widget _placeholder() => Container(
        color: const Color(0xff252525),
        child: const Center(
          child: Icon(
            Icons.live_tv_outlined,
            color: Colors.white38,
            size: 28,
          ),
        ),
      );
}
