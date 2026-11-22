import 'dart:io';

import 'package:flutter/material.dart';

import '../../../services/download_manager.dart';
import '../../../services/jellyfin_services/media_service.dart';
import '../../../services/offline_progress_store.dart';
import '../../../library/watch_history_service.dart';
import '../../../virtual/virtual_catalog.dart';
import '../../../widgets/common/watched_badge.dart';
import '../../../widgets/common/device_check_badge.dart';
import '../../../widgets/common/download_info_sheet.dart';
import '../../../widgets/common/download_stop_ring.dart';
import '../../../widgets/common/play_icon_overlay.dart';
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

/// A single row in a downloaded show's offline episode list (see
/// ShowDownloadsScreen) — [EpisodeCardCompact]'s thumb-left/text-right
/// layout AND its bottom gradient-scrim thumbnail treatment, so this
/// reads as the same episode-card family everywhere else in the app
/// shows it, rather than the plain-bordered-box look
/// DownloadedMovieTile/DownloadedShowTile use for movies/series. Also
/// matches EpisodeCardCompact by preferring this episode's own frame
/// grab thumbnail (record?.episodeThumbPath) over the series-shared
/// [seriesArtPath] fallback — see [_thumbnail]. Reads
/// duration + file size off to the right instead of a duration badge
/// on the thumbnail (redundant once it's already in that text) and
/// instead of the episode overview inline (that only surfaces now
/// inside the finished badge's [showDownloadInfoSheet]), and swaps its
/// trailing `DownloadButton` for whichever of this episode's two real
/// states applies here: a [DownloadStopRing] while it's still
/// transferring (tapping cancels, mirroring DownloadButton's own
/// cancel behavior), or a [DeviceCheckBadge] once it's finished —
/// tapping that opens [showDownloadInfoSheet] with Play/Delete actions
/// wired to [onTap]/[onDeleteRequested] rather than deleting outright.
///
/// Exactly one of [record] (a finished download) or [task] (still
/// queued/downloading/paused) is provided — an episode only ever has
/// one or the other at a time in DownloadManager's own state.
class DownloadedEpisodeTile extends StatelessWidget {
  final DownloadRecord? record;
  final DownloadTask? task;

  /// The series' own local art (thumbPath ?? posterPath from any of
  /// its downloaded episodes), used as this tile's thumbnail whenever
  /// the episode itself has no [DownloadRecord.episodeThumbPath] of
  /// its own — a still-downloading [task] (no per-episode image until
  /// the transfer finishes), or a finished episode whose server had
  /// no Primary image for it specifically.
  final String? seriesArtPath;

  /// Plays this episode. Only ever supplied for a finished [record] —
  /// a still-downloading [task] has no local file yet to play.
  final VoidCallback? onTap;

  /// Deletes this episode's download — wired to the "Delete Download"
  /// button of the sheet opened by tapping the finished
  /// [DeviceCheckBadge] (see [showDownloadInfoSheet]). Ignored while
  /// [task] is set.
  final VoidCallback? onDeleteRequested;

  const DownloadedEpisodeTile({
    super.key,
    this.record,
    this.task,
    this.seriesArtPath,
    this.onTap,
    this.onDeleteRequested,
  }) : assert(
          (record != null) != (task != null),
          'Provide exactly one of record or task',
        );

  /// True when this episode counts as watched outside the offline store:
  /// the snapshot UserData says Played, or (addon shows) the on-device watch
  /// history has it.
  static bool _watchedElsewhere(Map<String, dynamic> raw) {
    final ud = raw['UserData'];
    if (ud is Map && ud['Played'] == true) return true;
    final id = raw['Id']?.toString();
    if (id == null) return false;
    final v = VId.parse(id);
    if (v.kind == 'episode') {
      return WatchHistoryService.instance
          .isWatched(v.tmdbId, v.season ?? 0, v.episode ?? 0);
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final raw = record?.raw ?? task!.item;
    final number = (raw['IndexNumber'] as num?)?.toInt();
    final name = (raw['Name'] ?? record?.title ?? task?.title ?? 'Episode')
        .toString();

    final runtimeTicks = record != null
        ? record!.runtimeTicks
        : (raw['RunTimeTicks'] as num?)?.toInt() ?? 0;
    final duration = MediaService.formatRuntime(runtimeTicks);
    final size = record != null ? _fmtBytes(record!.fileSizeBytes) : '';
    final metaParts = [
      if (duration.isNotEmpty) duration,
      if (size.isNotEmpty) size,
    ];

    const thumbWidth = 140.0;
    const thumbHeight = thumbWidth * 9 / 16;

    return Pressable(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: thumbWidth,
              height: thumbHeight,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: _thumbnail(record?.episodeThumbPath),
                  ),

                  // Bottom gradient scrim — the same treatment
                  // EpisodeCardCompact uses on its thumbnail. This is
                  // what actually reads as "an episode card" rather
                  // than a re-skinned movie/show row: those two use a
                  // plain 10%-white border around the thumbnail instead
                  // (see DownloadedMovieTile/DownloadedShowTile), which
                  // this tile deliberately does not have.
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    height: thumbHeight * 0.55,
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: const BorderRadius.vertical(
                            bottom: Radius.circular(12),
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

                  // Offline watch progress for this episode — same
                  // gold bar treatment DownloadedMovieTile uses. Only
                  // meaningful once the file is actually on disk; a
                  // still-downloading episode has nothing watched yet.
                  // No duration badge here — duration already reads
                  // off to the right in metaParts, so this thumbnail
                  // doesn't need to repeat it.
                  if (record != null)
                    FutureBuilder<double?>(
                      future: OfflineProgressStore.getFraction(record!.id),
                      builder: (context, snapshot) {
                        final fraction = snapshot.data;
                        // Finished: the offline store reports 1.0 once an
                        // episode passes ~90%, and the snapshot / watch
                        // history can say so too.
                        final watched = (fraction != null && fraction >= 1.0) ||
                            _watchedElsewhere(raw);
                        if (watched) {
                          return const Positioned(
                            top: 4,
                            right: 4,
                            child: WatchedBadge(),
                          );
                        }
                        if (fraction == null || fraction <= 0) {
                          return const SizedBox.shrink();
                        }
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
                      },
                    ),

                  // Only a finished download is actually playable
                  // (onTap is only ever supplied for a `record`, never
                  // a still-transferring `task` — see the class doc),
                  // so the play glyph only shows once there's really
                  // something to tap play on.
                  if (onTap != null) const PlayIconOverlay(size: 34),
                ],
              ),
            ),

            const SizedBox(width: 14),

            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (number != null) ...[
                      Text(
                        "Episode $number",
                        style: const TextStyle(
                          color: _gold,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.3,
                        ),
                      ),
                      const SizedBox(height: 3),
                    ],
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
                    if (metaParts.isNotEmpty) ...[
                      const SizedBox(height: 4),
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
                    if (task != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        task!.state == DownloadState.queued
                            ? 'Queued'
                            : task!.waitingForWifi
                                ? 'Waiting for Wi-Fi'
                            : task!.state == DownloadState.paused
                                ? 'Paused'
                                : 'Downloading',
                        style: const TextStyle(
                          color: _gold,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),

            const SizedBox(width: 8),

            // Trailing status indicator — the one real difference
            // from EpisodeCardCompact's DownloadButton: this screen
            // only ever needs "downloading" or "done" (an offline
            // episode list has nothing "not downloaded" to show), so
            // it reads directly off record/task instead of going
            // through DownloadButton's full state machine.
            if (task != null)
              DownloadStopRing(
                size: 28,
                progress: task!.progress,
                indeterminate: task!.totalBytes <= 0,
                downloadId: task!.id,
                onCancel: () =>
                    DownloadManager.instance.cancelDownload(task!.id),
              )
            else
              Pressable(
                unconstrained: true,
                onTap: onTap == null || onDeleteRequested == null
                    ? null
                    : () => showDownloadInfoSheet(
                          context,
                          title: name,
                          overview: (raw['Overview'] ?? '').toString(),
                          onPlay: onTap!,
                          onDelete: onDeleteRequested!,
                        ),
                child: const DeviceCheckBadge(size: 34),
              ),
          ],
        ),
      ),
    );
  }

  /// Prefers this episode's own frame grab ([episodeThumbPath], set on
  /// finished downloads once episodeThumbPath fetching landed — see
  /// DownloadManager) over the series-shared [seriesArtPath], which
  /// is what a still-downloading [task] always shows (no per-episode
  /// image exists until the download finishes) and what a finished
  /// episode falls back to if the server had no Primary image for it.
  Widget _thumbnail(String? episodeThumbPath) {
    final path = episodeThumbPath ?? seriesArtPath;
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
            size: 20,
          ),
        ),
      );
}
