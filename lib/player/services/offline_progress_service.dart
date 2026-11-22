import 'dart:async';

import '../../services/offline_progress_store.dart';
import '../player_manager.dart';

/// Mirrors [PlaybackProgressService]'s shape (start/periodic tick/stop),
/// but persists watch progress to [OfflineProgressStore] instead of
/// reporting it to the Jellyfin server — the only progress source that
/// still works with no network at all. PlayerManager starts this
/// alongside (never instead of) PlaybackProgressService, but only for
/// items that are actual downloads (see DownloadManager.isDownloaded);
/// PlaybackProgressService's own server calls simply no-op/fail
/// silently when offline, same as before, so nothing about the
/// existing server-backed path changes.
class OfflineProgressService {
  OfflineProgressService._();

  static Timer? _timer;
  static String? _itemId;
  static Duration _runtime = Duration.zero;

  static void start(String itemId, Duration runtime) {
    stop();

    _itemId = itemId;
    _runtime = runtime;

    _timer = Timer.periodic(const Duration(seconds: 5), (_) {
      final position = PlayerManager.instance.player.state.position;
      _save(position);
    });
  }

  static void stop() {
    _timer?.cancel();
    _timer = null;
    _itemId = null;
    _runtime = Duration.zero;
  }

  static Future<void> _save(Duration position) async {
    final itemId = _itemId;
    if (itemId == null) return;
    await OfflineProgressStore.save(itemId, position, _runtime);
  }

  /// Same "reached 90%" early-finish moment PlaybackProgressService.
  /// markFinished() covers server-side — called from the same
  /// position-stream listener so a downloaded title flips to watched
  /// immediately rather than waiting up to 5 seconds for the next
  /// periodic tick.
  static Future<void> markFinished() async {
    final itemId = _itemId;
    if (itemId == null) return;
    await OfflineProgressStore.markFinished(itemId, _runtime);
  }

  /// Saves one final snapshot at whatever position playback actually
  /// stopped at, then tears the timer down — mirrors
  /// PlaybackProgressService.playbackStopped's "save then stop" shape.
  static Future<void> saveAndStop(Duration position) async {
    await _save(position);
    stop();
  }
}
