import 'package:flutter/material.dart';

import '../../services/download_manager.dart';
import 'device_check_badge.dart';
import 'addon_download_sheet.dart';
import 'movie_download_quality_sheet.dart';

/// Icon-only control that shows the live download state for a single
/// Jellyfin item and drives DownloadManager directly — the one download
/// indicator used everywhere in Nemesis (movie/episode action bars,
/// episode rows, poster overlays, song rows) so every surface in the
/// app renders the exact same premium visual language for all six
/// download states:
///
///  • Not downloaded — a plain outline download icon
///  • Queued         — a muted, dimmed download icon
///  • Downloading    — a thin white progress ring with a white stop
///                     square; tapping the ring itself (not the stop
///                     square) pauses
///  • Paused         — the same ring, frozen at its last progress,
///                     with a small resume glyph in the center
///  • Completed       — the shared [DeviceCheckBadge] (cellphone with
///                     a gold tick), same as the Downloads screen
///  • Failed          — a small muted warning glyph; tapping retries
class DownloadButton extends StatelessWidget {
  final Map<String, dynamic> item;
  final DownloadKind kind;
  final double size;
  final Color color;

  const DownloadButton({
    super.key,
    required this.item,
    required this.kind,
    this.size = 22,
    this.color = Colors.white,
  });

  String get _id => item['Id']?.toString() ?? '';

  Future<void> _start(BuildContext context) async {
    // Titles from the virtual server have no file on a Jellyfin server:
    // they are downloaded from addon sources (direct links or torrents).
    if (isAddonDownloadable(item)) {
      await showAddonDownloadSheet(context, item);
      return;
    }

    // A movie asks which quality first (see showMovieDownloadQualitySheet
    // — picking Original starts the same downloadMovie call below).
    // Only real movies: anything else that reaches this button as
    // DownloadKind.movie keeps starting immediately, as before.
    if (kind == DownloadKind.movie && item['Type'] == 'Movie') {
      await showMovieDownloadQualitySheet(context, item);
      return;
    }

    // An episode goes through the same quality step as a movie (see
    // showEpisodeDownloadQualitySheet) — Original starts the same
    // downloadEpisode call below.
    if (kind == DownloadKind.episode) {
      await showEpisodeDownloadQualitySheet(context, item);
      return;
    }

    switch (kind) {
      case DownloadKind.movie:
        await DownloadManager.instance.downloadMovie(item);
        break;
      case DownloadKind.episode:
        await DownloadManager.instance.downloadEpisode(item);
        break;
      case DownloadKind.song:
        await DownloadManager.instance.downloadSong(item);
        break;
    }
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xff1E1E1E),
        title: const Text(
          'Remove download?',
          style: TextStyle(color: Colors.white),
        ),
        content: Text(
          '"${item['Name'] ?? 'This item'}" will be deleted from your device.',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'Remove',
              style: TextStyle(color: Colors.redAccent),
            ),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await DownloadManager.instance.deleteDownload(_id);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: DownloadManager.instance,
      builder: (context, _) {
        final id = _id;
        final downloaded = DownloadManager.instance.isDownloaded(id);
        final state = DownloadManager.instance.stateOf(id);

        if (downloaded) {
          return _CompletedBadge(
            key: const ValueKey('completed'),
            size: size,
            onTap: () => _confirmDelete(context),
          );
        }

        switch (state) {
          case DownloadState.downloading:
          case DownloadState.paused:
            final task = DownloadManager.instance.taskFor(id);
            final progress = task?.progress ?? 0;
            final paused = state == DownloadState.paused;
            return _ProgressRing(
              key: ValueKey(paused ? 'paused' : 'downloading'),
              size: size,
              progress: progress,
              paused: paused,
              onTapRing: () {
                if (paused) {
                  DownloadManager.instance.resumeDownload(id);
                } else {
                  DownloadManager.instance.pauseDownload(id);
                }
              },
              onCancel: () => DownloadManager.instance.cancelDownload(id),
            );

          case DownloadState.queued:
            return _StateIcon(
              key: const ValueKey('queued'),
              tooltip: 'Queued — tap to cancel',
              icon: Icons.schedule_rounded,
              iconColor: Colors.white38,
              size: size,
              onTap: () => DownloadManager.instance.cancelDownload(id),
            );

          case DownloadState.failed:
            return _StateIcon(
              key: const ValueKey('failed'),
              tooltip: 'Download failed — tap to retry',
              icon: Icons.error_outline_rounded,
              iconColor: Colors.white54,
              size: size,
              onTap: () => DownloadManager.instance.retryDownload(id),
            );

          case null:
            return _StateIcon(
              key: const ValueKey('notDownloaded'),
              tooltip: 'Download',
              icon: Icons.download_outlined,
              iconColor: color,
              size: size,
              onTap: () => _start(context),
            );
        }
      },
    );
  }
}

/// A single tappable glyph with a fade/scale swap between states — used
/// for every non-progress state (not-downloaded, queued, completed,
/// failed) so switching between them feels like the same restrained
/// transition as the progress ring appearing/disappearing.
class _StateIcon extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final double size;
  final String tooltip;
  final VoidCallback onTap;

  const _StateIcon({
    super.key,
    required this.icon,
    required this.iconColor,
    required this.size,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size + 20,
      height: size + 20,
      child: Center(
        child: IconButton(
          onPressed: onTap,
          padding: EdgeInsets.zero,
          splashRadius: 20,
          tooltip: tooltip,
          icon: AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            transitionBuilder: (child, anim) => FadeTransition(
              opacity: anim,
              child: ScaleTransition(scale: anim, child: child),
            ),
            child: Icon(icon, color: iconColor, size: size, key: ValueKey(icon)),
          ),
        ),
      ),
    );
  }
}

/// Tappable wrapper around the shared [DeviceCheckBadge] — same hit
/// area/tooltip treatment [_StateIcon] uses for every other state, so
/// the completed state slots into the same AnimatedSwitcher-driven
/// layout without growing its own footprint.
class _CompletedBadge extends StatelessWidget {
  final double size;
  final VoidCallback onTap;

  const _CompletedBadge({
    super.key,
    required this.size,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size + 20,
      height: size + 20,
      child: Center(
        child: IconButton(
          onPressed: onTap,
          padding: EdgeInsets.zero,
          splashRadius: 20,
          tooltip: 'Downloaded — tap to remove',
          icon: DeviceCheckBadge(size: size),
        ),
      ),
    );
  }
}

/// The compact circular progress ring used for the downloading and
/// paused states — a thin white ring (real progress, not simulated)
/// with a small white stop square on top, no filled backdrop — the
/// same white ring + stop glyph language [DownloadStopRing] uses on
/// the Downloads screen. Downloading animates normally; paused
/// freezes the same ring at its last known progress and swaps the
/// center glyph to a resume triangle. Tapping the ring itself (outside
/// the small center glyph's own hit area) pauses or resumes; the
/// glyph in the center is the only way to cancel outright, keeping
/// the two actions unambiguous.
class _ProgressRing extends StatelessWidget {
  final double size;
  final double progress;
  final bool paused;
  final VoidCallback onTapRing;
  final VoidCallback onCancel;

  const _ProgressRing({
    super.key,
    required this.size,
    required this.progress,
    required this.paused,
    required this.onTapRing,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    final box = size + 20;
    final stopSize = size * 0.32;
    return SizedBox(
      width: box,
      height: box,
      child: Stack(
        alignment: Alignment.center,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onTapRing,
            onLongPress: onCancel,
            child: SizedBox(
              width: box,
              height: box,
              child: Center(
                child: SizedBox(
                  width: size,
                  height: size,
                  child: TweenAnimationBuilder<double>(
                    tween: Tween(begin: 0, end: progress),
                    duration: paused
                        ? Duration.zero
                        : const Duration(milliseconds: 300),
                    curve: Curves.easeOut,
                    builder: (context, value, _) => CircularProgressIndicator(
                      value: progress > 0 ? value : null,
                      strokeWidth: 2.2,
                      color: paused
                          ? Colors.white.withValues(alpha: 0.6)
                          : Colors.white,
                      backgroundColor: Colors.white24,
                    ),
                  ),
                ),
              ),
            ),
          ),
          IconButton(
            // The stop square pauses (tap again to resume); holding the ring
            // cancels, as do the notification's Cancel button and the
            // Downloads screen.
            onPressed: onTapRing,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            splashRadius: 14,
            tooltip: paused
                ? 'Paused — tap to resume, hold to cancel'
                : 'Tap to pause, hold to cancel',
            icon: paused
                ? Icon(
                    Icons.play_arrow_rounded,
                    color: Colors.white,
                    size: size * 0.66,
                  )
                : Container(
                    width: stopSize,
                    height: stopSize,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(stopSize * 0.2),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
