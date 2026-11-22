import 'dart:io';

import 'package:flutter/material.dart';

import '../../../services/download_manager.dart';
import '../../../services/jellyfin_services/media_service.dart';
import '../../../services/offline_progress_store.dart';
import '../../../utils/responsive.dart';
import '../../../widgets/common/device_check_badge.dart';
import '../../../widgets/common/download_info_sheet.dart';
import '../../../widgets/common/pressable.dart';

const _gold = Color(0xffD4AF37);

String _fmtBytes(int bytes) {
  if (bytes <= 0) return '';
  const kb = 1024;
  const mb = kb * 1024;
  const gb = mb * 1024;
  if (bytes >= gb) return '${(bytes / gb).toStringAsFixed(1)} GB';
  return '${(bytes / mb).toStringAsFixed(0)} MB';
}

/// A downloaded movie, shown as a list row rather than a poster tile —
/// the same 16:9 rounded-corner card the Home screen's Continue
/// Watching row uses for its artwork, but with the title/year/
/// duration/size read off to the right instead of overlaid on the
/// image, since there's no scrubbing progress to protect here the way
/// there is on a resumable Continue Watching card.
class DownloadedMovieTile extends StatelessWidget {
  final DownloadRecord record;

  /// Opens the movie's detail screen. Wired to long-press — the row's
  /// primary tap plays the movie (see [onPlay]).
  final VoidCallback onTap;
  final VoidCallback onPlay;
  final VoidCallback onDelete;

  const DownloadedMovieTile({
    super.key,
    required this.record,
    required this.onTap,
    required this.onPlay,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final thumbWidth = Responsive.isTV ? 220.0 : 140.0;
    const aspect = 16 / 9;

    final year = record.subtitle; // set to ProductionYear at download time
    final duration = MediaService.formatRuntime(record.runtimeTicks);
    final size = _fmtBytes(record.fileSizeBytes);
    final metaParts = [
      if (year.isNotEmpty) year,
      if (duration.isNotEmpty) duration,
      if (size.isNotEmpty) size,
    ];

    // No card enclosure — the row sits flush on the Downloads screen's
    // own background, matching the reference design. Only spacing
    // between rows remains; Pressable still supplies its own ripple.
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
      child: Pressable(
        // Tapping the row plays the movie directly — matches
        // DownloadedSongRow/DownloadedEpisodeTile, where tapping a
        // downloaded item starts playback rather than opening a detail
        // screen. The detail screen (onTap) is still reachable via
        // long-press, and via the info sheet under the trailing badge.
        onTap: onPlay,
        onLongPress: onTap,
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

                      // Offline watch progress for this download — see
                      // OfflineProgressStore. Same bottom-edge treatment
                      // Continue Watching uses on Home.
                      FutureBuilder<double?>(
                        future: OfflineProgressStore.getFraction(record.id),
                        builder: (context, snapshot) {
                          final fraction = snapshot.data;

                          if (fraction != null && fraction >= 1.0) {
                            return const Positioned(
                              top: 6,
                              left: 6,
                              child: _WatchedBadge(),
                            );
                          }

                          if (fraction != null && fraction > 0) {
                            return Positioned(
                              left: 6,
                              right: 6,
                              bottom: 6,
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(3),
                                child: SizedBox(
                                  height: 3,
                                  child: LinearProgressIndicator(
                                    value: fraction,
                                    backgroundColor:
                                        Colors.white.withValues(alpha: 0.24),
                                    valueColor: const AlwaysStoppedAnimation(
                                      _gold,
                                    ),
                                  ),
                                ),
                              ),
                            );
                          }

                          return const SizedBox.shrink();
                        },
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
                        record.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          height: 1.25,
                        ),
                      ),
                      if (metaParts.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(
                          metaParts.join(' • '),
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
                ),
              ),
              Pressable(
                unconstrained: true,
                onTap: () => showDownloadInfoSheet(
                  context,
                  title: record.title,
                  overview: (record.raw['Overview'] ?? '').toString(),
                  onPlay: onPlay,
                  onDelete: onDelete,
                ),
                child: const DeviceCheckBadge(size: 34),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _thumbnail() {
    // Prefer the cached landscape (Thumb) art — same aspect as
    // Continue Watching — falling back to the portrait poster (still
    // covers the box, just more tightly cropped) when the server never
    // had a Thumb image for this item.
    final path = record.thumbPath ?? record.posterPath;
    if (path == null) return _placeholder();

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
            Icons.movie_creation_outlined,
            color: Colors.white38,
            size: 28,
          ),
        ),
      );
}

class _WatchedBadge extends StatelessWidget {
  const _WatchedBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 20,
      height: 20,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        shape: BoxShape.circle,
      ),
      child: const Icon(
        Icons.check_rounded,
        color: _gold,
        size: 13,
      ),
    );
  }
}
