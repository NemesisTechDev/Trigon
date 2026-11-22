import 'dart:async';

import 'package:audio_service/audio_service.dart' as svc;
import 'package:flutter/material.dart';

import '../player/player_manager.dart';
import '../player/screens/audio_player_screen.dart';
import 'external_media_handler.dart';

/// Routes a tap on the OS media notification ("now playing" widget /
/// lock-screen widget — see NemesisAudioHandler's own doc comment) to
/// [AudioPlayerScreen], matching how most music apps (Spotify, YouTube
/// Music, the stock Android Music app, ...) treat their notification:
/// tapping it reopens the full player, rather than just bringing
/// whatever screen was already on top back to the foreground.
///
/// NemesisAudioHandler publishes the same OS notification regardless of
/// what's actually playing — a song, a movie/episode, or a live channel
/// all go through the exact same `_pushMediaItem`/`_pushPlaybackState`
/// path — so this has to gate on content type itself. Movies/episodes
/// and live TV are deliberately left alone here: there's no
/// "VideoPlayerScreen" equivalent expectation for a video notification
/// the way there is for a song one, and forcing that screen open would
/// interrupt someone who's mid-browse elsewhere in the app while a
/// video keeps playing in the background — so a tap on the notification
/// for those just keeps doing what it already did (foreground the app,
/// nothing more).
class NotificationNavigationHandler {
  NotificationNavigationHandler._();
  static final NotificationNavigationHandler instance =
      NotificationNavigationHandler._();

  StreamSubscription<bool>? _subscription;

  // Mirrors PlayerNavigation._isOpen's guard for the video player —
  // without this, a double-tap (or the stream re-emitting `true` before
  // the app has had a chance to reset it) could stack two
  // AudioPlayerScreen routes on top of each other.
  bool _audioPlayerOpen = false;

  /// Call once, right after `AudioService.init()` resolves — that's what
  /// makes `AudioService.notificationClicked` exist to listen to at all.
  void init() {
    _subscription ??=
        svc.AudioService.notificationClicked.listen(_onNotificationClicked);
  }

  void _onNotificationClicked(bool clicked) {
    if (!clicked || _audioPlayerOpen) return;

    final manager = PlayerManager.instance;

    // Nothing playing, or what's playing is video/live TV: leave the
    // notification's default behavior (just foreground the app) alone.
    if (manager.currentItemNotifier.value == null) return;
    if (manager.isVideo.value) return;

    final navigator = ExternalMediaHandler.instance.navigatorKey.currentState;
    if (navigator == null) return;

    _audioPlayerOpen = true;
    navigator
        .push(MaterialPageRoute(builder: (_) => const AudioPlayerScreen()))
        .whenComplete(() => _audioPlayerOpen = false);
  }

  void dispose() {
    _subscription?.cancel();
    _subscription = null;
  }
}
