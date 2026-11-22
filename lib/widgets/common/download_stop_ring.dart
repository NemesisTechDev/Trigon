import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/download_manager.dart';

/// A thin white circular progress ring with a small white stop square
/// centered directly on top of it (no filled circular backdrop) —
/// tapping anywhere on the ring cancels the transfer. The "this is
/// actively downloading right now" indicator used wherever a single
/// item's live transfer needs a compact, thumbnail-corner-sized glyph
/// rather than a full progress bar — sized and colored to sit as a
/// trailing indicator next to a row's title, not as an overlay on top
/// of artwork.
///
/// Pulled out of active_downloads_section.dart (where it started
/// inlined in `_ActiveDownloadCard`, used only by the Downloads
/// screen's own DOWNLOADING section) so a downloaded show's
/// per-episode list can show the exact same indicator — see
/// DownloadedEpisodeTile — instead of growing its own copy.
///
/// Distinct from [DownloadButton]'s own progress ring (used inline on
/// movie/episode action bars and poster overlays, where a ring-tap
/// also supports pausing) — this is the plain cancel-only variant for
/// spots that only ever need "stop".
class DownloadStopRing extends StatelessWidget {
  /// 0–1 transfer progress. Ignored when [indeterminate] is true.
  final double progress;

  /// True when the total size isn't known yet (e.g. before the first
  /// response header lands) — renders a spinning indeterminate ring
  /// instead of a stalled one stuck at 0%.
  final bool indeterminate;

  final double size;
  final VoidCallback onCancel;

  /// When set, the ring controls that download itself: a tap pauses it (the
  /// square becomes a play triangle) or resumes it, and a long press cancels.
  /// Without it the ring keeps its old behaviour: a tap calls [onCancel].
  final String? downloadId;

  const DownloadStopRing({
    super.key,
    required this.progress,
    required this.onCancel,
    this.indeterminate = false,
    this.size = 28,
    this.downloadId,
  });

  @override
  Widget build(BuildContext context) {
    final id = downloadId;
    if (id == null) return _ring(paused: false, onTap: onCancel);
    return ListenableBuilder(
      listenable: DownloadManager.instance,
      builder: (context, _) {
        final paused =
            DownloadManager.instance.stateOf(id) == DownloadState.paused;
        return _ring(
          paused: paused,
          onTap: () {
            if (paused) {
              DownloadManager.instance.resumeDownload(id);
            } else {
              DownloadManager.instance.pauseDownload(id);
            }
          },
          onLongPress: () {
            HapticFeedback.mediumImpact();
            onCancel();
          },
        );
      },
    );
  }

  Widget _ring({
    required bool paused,
    required VoidCallback onTap,
    VoidCallback? onLongPress,
  }) {
    // Ratio lifted from the reference indicator: a small squared-off
    // stop glyph sitting directly inside the ring, no dark circle
    // behind it — roughly a third of the ring's own diameter, big
    // enough to read as a "stop" shape without dominating the ring.
    final stopSize = size * (10 / 28);

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      onLongPress: onLongPress,
      child: Tooltip(
        message: onLongPress == null
            ? 'Downloading — tap to cancel'
            : (paused
                ? 'Paused — tap to resume, hold to cancel'
                : 'Tap to pause, hold to cancel'),
        child: SizedBox(
          width: size,
          height: size,
          child: Stack(
            alignment: Alignment.center,
            children: [
              TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: progress),
                duration: const Duration(milliseconds: 300),
                builder: (context, value, _) => CircularProgressIndicator(
                  value: indeterminate ? null : value,
                  strokeWidth: 1.8,
                  backgroundColor: Colors.white.withValues(alpha: 0.28),
                  valueColor: AlwaysStoppedAnimation(
                    paused ? Colors.white60 : Colors.white,
                  ),
                ),
              ),
              if (paused)
                Icon(Icons.play_arrow_rounded, color: Colors.white, size: size * 0.62)
              else
                Container(
                  width: stopSize,
                  height: stopSize,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(stopSize * 0.2),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
