import 'package:flutter/material.dart';

import '../../casting/cast_manager.dart';
import 'player_screen_registry.dart';
import 'video_player_screen.dart';

/// Opens [VideoPlayerScreen] on the root navigator, guarding against it
/// being pushed more than once at a time.
///
/// Every "Play"/"Resume"/"Continue Watching" tap handler in the app awaits
/// a network call (`PlaybackService.playItem`/`playQueue`) before pushing
/// this screen. None of those buttons disabled themselves while that
/// await was in flight, so a slow connection plus an impatient extra tap
/// (or two different rows both racing to open the same in-progress item)
/// could fire the push twice, stacking two full [VideoPlayerScreen]
/// routes on top of each other — which looked like "duplicated" player
/// controls. Routing every call site through this single guarded helper
/// fixes that everywhere at once.
class PlayerNavigation {
  PlayerNavigation._();

  static bool _isOpen = false;

  /// True while the video player screen is on top.
  static bool get isOpen => _isOpen;

  /// Bumped every time a player screen (video or embed) has been closed.
  /// Home listens to this to refresh Continue Watching after each exit.
  static final ValueNotifier<int> closeSignal = ValueNotifier<int>(0);

  static void notifyClosed() => closeSignal.value++;

  /// CASTING FIX (auto-redirect): every one of the call sites above now
  /// sends its Play/Resume/Watch Live tap straight to an already-
  /// connected cast session instead of local playback (see
  /// `PlaybackService.playItem`/`playQueue`'s video-redirect branches) —
  /// so pushing this screen right after, the way every one of those call
  /// sites still unconditionally does, would pop the local video player
  /// open on top of a phone that isn't actually playing anything, right
  /// as the video-casting mini player appears underneath it. Skipping
  /// the push whenever a cast session is connected mirrors how tapping
  /// Play for a song while casting never opened the local audio player
  /// screen either — the mini player alone reflects what's happening.
  ///
  /// [force] bypasses that skip. Only the video-casting mini player's
  /// own tap handler should ever pass `force: true` — a deliberate tap
  /// on that bar should always be able to reopen this screen to show/
  /// manage the active session, regardless of what's playing.
  static Future<void> open(BuildContext context, {bool force = false}) async {
    if (_isOpen) return;
    if (!force && CastManager.instance.isCasting) return;

    _isOpen = true;

    try {
      // OPEN WITH FIX: replaces an already-open audio player screen rather
      // than stacking on top of it (see PlayerScreenRegistry).
      await PlayerScreenRegistry.openExclusive(
        Navigator.of(context, rootNavigator: true),
        PlayerScreenKind.video,
        MaterialPageRoute<void>(
          builder: (_) => const VideoPlayerScreen(),
        ),
      );
    } finally {
      _isOpen = false;
      notifyClosed();
    }
  }
}
