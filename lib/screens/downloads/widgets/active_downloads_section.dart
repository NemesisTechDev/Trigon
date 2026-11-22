import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../../services/cache/nemesis_image_cache.dart';
import '../../../services/download_manager.dart';
import '../../../services/jellyfin_services/media_service.dart';
import '../../../utils/responsive.dart';
import '../../../widgets/common/download_stop_ring.dart';
import '../../../widgets/common/landscape_art_image.dart';

const _gold = Color(0xffD4AF37);

/// The FAILED section of the Downloads screen — the only thing that
/// still sits above the Movies/Shows/Music tabs' own lists. Active
/// (downloading) and queued items no longer get their own sections up
/// here: they render inside the tab's list, in the spot they'll settle
/// into once finished, via [InProgressDownloadRow] (movies, songs) and
/// [DownloadedShowTile]'s "Download in progress" line (TV shows).
/// Collapses to nothing when nothing has failed.
///
/// [kinds] limits which failed tasks are listed, so each tab only shows
/// its own failures (a failed episode belongs on the TV Shows tab, not
/// Movies).
List<Widget> buildActiveDownloadsSection(
  BuildContext context, {
  required Set<DownloadKind> kinds,
}) {
  final failed = DownloadManager.instance.failedTasks
      .where((t) => kinds.contains(t.kind))
      .toList();

  if (failed.isEmpty) {
    return const [SliverToBoxAdapter(child: SizedBox.shrink())];
  }

  return [
    SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _SectionLabel('FAILED'),
            const SizedBox(height: 10),
            for (final task in failed) ...[
              _FailedRow(task: task),
              const SizedBox(height: 8),
            ],
          ],
        ),
      ),
    ),
  ];
}

/// A movie or song that's still downloading or waiting in the queue,
/// drawn as a row of the Movies / Music list itself — same outer
/// spacing as [DownloadedMovieTile] / [DownloadedSongRow], with the
/// live progress ring (or queue badge) standing in where the finished
/// row's "saved to this device" badge will appear. When the transfer
/// completes the list rebuilds and this row is simply replaced by the
/// completed one in the same spot.
class InProgressDownloadRow extends StatelessWidget {
  final DownloadTask task;
  const InProgressDownloadRow({super.key, required this.task});

  @override
  Widget build(BuildContext context) {
    final queued = task.state != DownloadState.downloading &&
        task.state != DownloadState.paused;
    final position = DownloadManager.instance.queuePositionOf(task.id) ?? 1;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
      child: queued
          ? _QueuedCard(task: task, position: position)
          : _ActiveDownloadCard(task: task),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        color: Colors.white.withValues(alpha: 0.5),
        fontSize: 12,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.1,
      ),
    );
  }
}

/// The shell every row in this section shares — no card enclosure, so
/// DOWNLOADING / QUEUED / FINISHED rows sit flush on the Downloads
/// screen's own background, same as a completed [DownloadedMovieTile]
/// row, reading as one continuous list rather than separate boxes.
class _CardShell extends StatelessWidget {
  final Widget child;

  /// Song rows use [DownloadedSongRow]'s inner padding (10 / 6) rather
  /// than the movie tile's uniform 8, so an in-progress song lines up
  /// with the completed row it becomes.
  final bool square;
  const _CardShell({required this.child, this.square = false});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: square
          ? const EdgeInsets.symmetric(horizontal: 10, vertical: 6)
          : const EdgeInsets.all(8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [child],
      ),
    );
  }
}

/// The rounded thumbnail frame shared by every row here — with
/// whatever overlay (progress ring, queue badge, finished badge)
/// stacked on top. Two shapes: the default 16:9 frame, same size as
/// [DownloadedMovieTile]'s, for movies/episodes; and — when [square]
/// is set — a fixed 56×56 box matching [DownloadedSongRow]'s artwork,
/// so a song's DOWNLOADING/QUEUED/FINISHED card lines up pixel-for-
/// pixel with the completed row it's about to become.
class _ThumbFrame extends StatelessWidget {
  final Widget image;
  final Widget? overlay;
  final double opacity;
  final bool square;

  const _ThumbFrame({
    required this.image,
    this.overlay,
    this.opacity = 1,
    this.square = false,
  });

  @override
  Widget build(BuildContext context) {
    final content = Stack(
      fit: StackFit.expand,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Opacity(opacity: opacity, child: image),
        ),
        if (overlay != null)
          Positioned.fill(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: overlay,
            ),
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
    );

    if (square) {
      return SizedBox(width: 56, height: 56, child: content);
    }

    final thumbWidth = Responsive.isTV ? 220.0 : 140.0;
    return SizedBox(
      width: thumbWidth,
      child: AspectRatio(aspectRatio: 16 / 9, child: content),
    );
  }
}

Widget _networkThumb(String imageId) {
  // Thumb, falling back to Backdrop when the item has no Thumb image.
  return LandscapeArtImage(
    imageId: imageId,
    maxWidth: 320,
    placeholder: Container(color: const Color(0xff2A2A2A)),
    errorWidget: Container(
      color: const Color(0xff2A2A2A),
      child: const Icon(Icons.movie_creation_outlined,
          color: Colors.white24, size: 20),
    ),
  );
}

/// Same idea as [_networkThumb] but for a song's square artwork —
/// "Primary" art (the default `getMusicImage` type), not "Thumb",
/// matching how [DownloadedSongRow] and [SongRow] source their art.
Widget _networkSongThumb(String imageId) {
  final image = MediaService.getMusicImage(imageId, size: 200);
  return CachedNetworkImage(
    cacheManager: NemesisImageCache.instance,
    imageUrl: image,
    fit: BoxFit.cover,
    placeholder: (_, __) => Container(color: const Color(0xff252525)),
    errorWidget: (_, __, ___) => Container(
      color: const Color(0xff252525),
      child: const Icon(Icons.music_note, color: Colors.white24, size: 26),
    ),
  );
}

/// A single actively-transferring download: the same card shape as a
/// completed row, with a plain (un-scrimmed) thumbnail and the
/// circular progress/stop ring living as a trailing indicator at the
/// end of the row — same placement [DownloadedEpisodeTile] uses for
/// its own DownloadStopRing — rather than overlaid on top of the
/// artwork. Byte counts and speed live in the download notification
/// now, so this card stays to just title, percentage, and the ring.
///
/// For a song (`task.kind == DownloadKind.song`) the frame narrows to
/// the same 56×56 square [DownloadedSongRow] uses for its artwork, and
/// the second line shows the artist — task.subtitle, the same field a
/// queued/finished song card and the completed row itself all read —
/// instead of the live percentage, which the ring already conveys.
class _ActiveDownloadCard extends StatelessWidget {
  final DownloadTask task;
  const _ActiveDownloadCard({required this.task});

  @override
  Widget build(BuildContext context) {
    final progress = task.progress;
    final percent = (progress * 100).clamp(0, 100).toStringAsFixed(0);
    final isSong = task.kind == DownloadKind.song;

    return _CardShell(
      square: isSong,
      child: Expanded(
        child: Row(
          // A song row centres its text and trailing indicator against
          // the square artwork (see DownloadedSongRow); movie rows
          // top-align them beside the 16:9 thumbnail.
          crossAxisAlignment:
              isSong ? CrossAxisAlignment.center : CrossAxisAlignment.start,
          children: [
            _ThumbFrame(
              square: isSong,
              image: isSong
                  ? _networkSongThumb(task.imageId)
                  : _networkThumb(task.imageId),
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
                      task.title,
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
                    if (isSong)
                      Text(
                        task.subtitle.isNotEmpty
                            ? task.subtitle
                            : 'Downloading',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 12,
                        ),
                      )
                    else
                      Text(
                        task.waitingForWifi
                            ? 'Waiting for Wi-Fi'
                            : task.state == DownloadState.paused
                            ? (task.totalBytes > 0
                                ? 'Paused • $percent%'
                                : 'Paused')
                            : (task.totalBytes > 0
                                ? 'Downloading • $percent%'
                                : 'Downloading'),
                        style: const TextStyle(
                          color: _gold,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            Padding(
              padding: EdgeInsets.only(top: isSong ? 0 : 4),
              child: DownloadStopRing(
                size: 28,
                progress: progress,
                indeterminate: task.totalBytes <= 0,
                downloadId: task.id,
                onCancel: () =>
                    DownloadManager.instance.cancelDownload(task.id),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A queued item, waiting for a transfer slot — same card shape,
/// dimmed thumbnail, and a small clock badge in place of the progress
/// ring (nothing's actually moving yet). The trailing X backs it out
/// of the queue.
class _QueuedCard extends StatelessWidget {
  final DownloadTask task;
  final int position;
  const _QueuedCard({required this.task, required this.position});

  @override
  Widget build(BuildContext context) {
    final isSong = task.kind == DownloadKind.song;

    return _CardShell(
      square: isSong,
      child: Expanded(
        child: Row(
          // A song row centres its text and trailing indicator against
          // the square artwork (see DownloadedSongRow); movie rows
          // top-align them beside the 16:9 thumbnail.
          crossAxisAlignment:
              isSong ? CrossAxisAlignment.center : CrossAxisAlignment.start,
          children: [
            _ThumbFrame(
              square: isSong,
              image: isSong
                  ? _networkSongThumb(task.imageId)
                  : _networkThumb(task.imageId),
              opacity: 0.5,
              overlay: Center(
                child: Container(
                  width: isSong ? 26 : 30,
                  height: isSong ? 26 : 30,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.55),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.schedule_rounded,
                    color: Colors.white70,
                    size: isSong ? 14 : 16,
                  ),
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
                      task.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        height: 1.25,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Queued • #$position',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.45),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            IconButton(
              onPressed: () => DownloadManager.instance.cancelDownload(task.id),
              splashRadius: 18,
              icon: const Icon(Icons.close_rounded,
                  color: Colors.white38, size: 18),
            ),
          ],
        ),
      ),
    );
  }
}

/// A failed download — a subtle warning glyph, the (friendly) error,
/// and a Retry action that resumes from whatever bytes already landed.
/// Kept as a compact row rather than the full card shape — there's no
/// artwork state worth showing for a stalled transfer.
class _FailedRow extends StatelessWidget {
  final DownloadTask task;
  const _FailedRow({required this.task});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Icon(Icons.error_outline_rounded, color: Colors.white54, size: 16),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                task.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
              if (task.error != null)
                Text(
                  task.error!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.4),
                    fontSize: 11,
                  ),
                ),
            ],
          ),
        ),
        TextButton(
          onPressed: () => DownloadManager.instance.retryDownload(task.id),
          style: TextButton.styleFrom(
            foregroundColor: _gold,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: const Text('Retry', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
        ),
        IconButton(
          onPressed: () => DownloadManager.instance.cancelDownload(task.id),
          splashRadius: 14,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(),
          icon: const Icon(Icons.close_rounded, color: Colors.white38, size: 16),
        ),
      ],
    );
  }
}
