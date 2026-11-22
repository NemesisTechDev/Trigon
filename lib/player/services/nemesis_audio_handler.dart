import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show MethodChannel, MissingPluginException, PlatformException;
import 'package:audio_service/audio_service.dart' as svc;

import '../player_manager.dart';
import 'playback_queue.dart';
import '../models/media_item.dart' as app;
import '../../utils/artwork_source.dart';
import '../../casting/cast_manager.dart';
import '../../casting/playback_coordinator.dart';
import '../../casting/models/cast_session.dart';
import '../../casting/models/cast_states.dart' as cast;

/// Bridges [PlayerManager]'s media_kit [Player] to the OS media session.
///
/// Android/iOS don't show the lock-screen / notification "now playing"
/// widget just because audio is playing — the app has to publish a
/// MediaSession (Android) or Now Playing info (iOS) itself. That's what
/// this class does, using the `audio_service` package to handle the
/// platform plumbing. It doesn't own playback; PlayerManager/media_kit
/// still does all of that. It only mirrors PlayerManager's state into the
/// shape audio_service expects, and forwards taps on the notification's
/// controls back into PlayerManager.
class NemesisAudioHandler extends svc.BaseAudioHandler
    with svc.QueueHandler, svc.SeekHandler {
  final PlayerManager _manager = PlayerManager.instance;
  late final VoidCallback _itemListener;
  late final VoidCallback _stateListener;
  late final VoidCallback _favoriteListener;
  late final VoidCallback _repeatListener;

  // CASTING FIX (audio double-playback / stale lock-screen state): while
  // a cast session is active, the OS media session this class publishes
  // needs to reflect and control *that* session — not the local player,
  // which PlaybackCoordinator has already paused for the duration of the
  // handoff (see its own doc comment). Without this, the notification/
  // lock-screen kept showing local's permanently-paused state (so it
  // always offered "Play"), and tapping it — or a Bluetooth headset's
  // play button, or Android Auto, all of which only ever talk to this
  // handler — called straight into `_manager.player.play()`, resuming
  // local audio right alongside whatever was already going on the TV.
  // `_activeCastSession` mirrors `CastManager.instance.activeSession` so
  // every place below only has to check one nullable field.
  CastSession? _activeCastSession;
  VoidCallback? _castSessionListener;
  late final VoidCallback _activeSessionListener;

  // MEDIA NOTIFICATION "HIDE" FIX: the OS media widget only allows
  // hiding when the notification isn't ongoing, i.e. when nothing is
  // playing. audio_service can't toggle that per-state, so MainActivity
  // exposes a tiny channel that flips FLAG_ONGOING_EVENT on its
  // notification (see applyMediaNotificationOngoing in MainActivity.kt).
  static const MethodChannel _notificationChannel =
      MethodChannel('com.nemesis.app/media_notification');
  final List<StreamSubscription<dynamic>> _ongoingSubs = [];
  Timer? _ongoingDebounce;
  Timer? _ongoingPoll;

  NemesisAudioHandler() {
    _itemListener = () => _pushMediaItem(_manager.currentItemNotifier.value);
    _stateListener = _pushPlaybackState;

    // Favorite/repeat changes don't come from PlayerManager's normal
    // playback streams, so they get their own listeners rather than
    // piggybacking on _stateListener/_itemListener.
    _favoriteListener = () => _pushMediaItem(_manager.currentItemNotifier.value);
    _repeatListener = _pushPlaybackState;

    _manager.currentItemNotifier.addListener(_itemListener);
    _manager.playing.addListener(_stateListener);
    _manager.buffering.addListener(_stateListener);
    _manager.position.addListener(_stateListener);
    _manager.duration.addListener(_stateListener);
    _manager.bufferedPosition.addListener(_stateListener);
    _manager.isFavorite.addListener(_favoriteListener);
    PlaybackQueue.instance.repeatModeNotifier.addListener(_repeatListener);

    _activeSessionListener = _onActiveCastSessionChanged;
    CastManager.instance.activeSession.addListener(_activeSessionListener);
    _onActiveCastSessionChanged();

    _pushMediaItem(_manager.currentItemNotifier.value);
    _pushPlaybackState();
    _initOngoingSync();
  }

  /// Keeps the notification's "ongoing" flag equal to `playing`.
  ///
  /// audio_service rebuilds the notification (without the flag) whenever
  /// its controls or metadata change, and again when artwork finishes
  /// loading, so this re-applies on every such change (debounced past
  /// audio_service's own platform call) and polls cheaply while playing
  /// to cover the async artwork rebuild. The native call is a no-op when
  /// the flag is already correct.
  void _initOngoingSync() {
    _ongoingSubs.add(playbackState
        .map((s) =>
            '${s.playing}|${s.processingState}|${s.controls.map((c) => c.androidIcon).join(',')}')
        .distinct()
        .listen((_) => _scheduleOngoingSync()));
    _ongoingSubs.add(mediaItem
        .map((m) =>
            '${m?.id}|${m?.title}|${m?.artist}|${m?.artUri}|${m?.duration}')
        .distinct()
        .listen((_) => _scheduleOngoingSync()));
  }

  void _scheduleOngoingSync() {
    _ongoingDebounce?.cancel();
    _ongoingDebounce =
        Timer(const Duration(milliseconds: 150), _applyOngoing);
    if (playbackState.value.playing) {
      _ongoingPoll ??=
          Timer.periodic(const Duration(seconds: 2), (_) => _applyOngoing());
    } else {
      _ongoingPoll?.cancel();
      _ongoingPoll = null;
    }
  }

  Future<void> _applyOngoing() async {
    try {
      await _notificationChannel.invokeMethod<bool>(
          'setOngoing', {'ongoing': playbackState.value.playing});
    } on MissingPluginException {
      // Non-Android platform / native side not wired — nothing to do.
    } on PlatformException {
      // Best-effort cosmetic behavior; never let it affect playback.
    }
  }

  void _onActiveCastSessionChanged() {
    final session = CastManager.instance.activeSession.value;

    if (!identical(session, _activeCastSession)) {
      if (_activeCastSession != null && _castSessionListener != null) {
        _activeCastSession!.playbackState.removeListener(_castSessionListener!);
        _activeCastSession!.position.removeListener(_castSessionListener!);
      }

      _activeCastSession = session;

      if (session != null) {
        _castSessionListener = _pushPlaybackState;
        session.playbackState.addListener(_castSessionListener!);
        session.position.addListener(_castSessionListener!);
      } else {
        _castSessionListener = null;
      }
    }

    _pushPlaybackState();
  }

  bool get _isCasting =>
      _activeCastSession != null && _activeCastSession!.isConnected;

  /// Rewrites a Jellyfin image URL for the system media notification
  /// specifically.
  ///
  /// Every other art tile in the app (`item.image` as used by the mini
  /// player, queue screen, full player, etc.) only bounds `maxWidth` —
  /// see MediaService.getPrimaryImage — because those tiles already sit
  /// inside their own square `BoxFit.cover` container, so whatever
  /// aspect ratio Jellyfin actually returns gets cropped client-side
  /// regardless. The OS's own lock-screen/notification media widget has
  /// no such wrapper: on Android 13+ it generates its background by
  /// tiling this exact bitmap into a fixed round "blob" shape, which
  /// needs a genuinely square image to fill edge to edge. A
  /// `maxWidth`-only image keeps the source's real aspect ratio (e.g. a
  /// non-square cover, or one with letterboxing baked in), so the
  /// system pillar/letterboxes it into that square slot instead of
  /// cropping it — leaving the plain notification-card background
  /// showing through at the edges instead of full bleed, which is what
  /// Ben's screenshots showed compared to VLC.
  ///
  /// Swapping `maxWidth`/`maxHeight` for `fillWidth`+`fillHeight` (equal
  /// values) tells Jellyfin to actually crop server-side to that exact
  /// square — the same aspect-fill Jellyfin's own web client uses for
  /// its square library tiles — so the bitmap that reaches the
  /// notification is already square and covers the whole shape the way
  /// VLC's does.
  Uri? _squareArtUri(String imageUrl) {
    final uri = Uri.tryParse(imageUrl);
    if (uri == null) return null;

    const size = '512';
    final params = Map<String, String>.from(uri.queryParameters)
      ..remove('maxWidth')
      ..remove('maxHeight')
      ..['fillWidth'] = size
      ..['fillHeight'] = size;

    return uri.replace(queryParameters: params);
  }

  void _pushMediaItem(app.MediaItem? item) {
    if (item == null) {
      mediaItem.add(null);
      return;
    }

    final duration =
        _manager.duration.value == Duration.zero ? item.runtime : _manager.duration.value;

    mediaItem.add(svc.MediaItem(
      id: item.id,
      title: item.title,
      // ARTIST DISPLAY FIX (notification/lock-screen showing only one
      // artist on multi-artist tracks): MediaService.mediaItemFromJellyfin
      // deliberately keeps `artistName` singular (first artist only) for
      // LRCLIB lyrics matching, which needs one clean name rather than a
      // joined list — see that field's own doc comment. The full,
      // comma-joined artist credit lives in `subtitle` instead (that
      // file's "ARTIST DISPLAY FIX" comment), which is exactly what the
      // audio player screen and mini player already render. This was
      // preferring the singular `artistName` whenever it was non-empty
      // (i.e. for every song), so the notification/lock-screen widget
      // never showed the full joined list the way the in-app player
      // does. Preferring `subtitle` here — falling back to `artistName`
      // only when subtitle is empty — makes the notification match. For
      // non-audio items (video, live TV) this is a no-op: `artistName`
      // is already empty there, so `subtitle` (the show/series name) was
      // already what displayed either way.
      artist: item.subtitle.isNotEmpty ? item.subtitle : item.artistName,
      // A local song's artwork is a plain filesystem path — the system
      // media notification (Glide-backed on Android) needs a proper
      // file:// URI to load it, not a bare path, which is what
      // Uri.tryParse would otherwise produce. Remote (Jellyfin) artwork
      // goes through _squareArtUri above so the notification background
      // fully covers instead of leaving gaps — see its doc comment.
      artUri: item.image == null
          ? null
          : (isRemoteArtwork(item.image!)
              ? _squareArtUri(item.image!)
              : Uri.file(item.image!)),
      duration: duration,
      // Lets the OS lock-screen/notification widget draw a heart icon
      // that reflects the track's live favorite state, and route taps
      // on it back to setRating() below via
      // MediaSessionCompat.Callback.onSetRating.
      rating: svc.Rating.newHeartRating(_manager.isFavorite.value),
    ));
  }

  svc.AudioServiceRepeatMode _toServiceRepeatMode(QueueRepeatMode mode) {
    switch (mode) {
      case QueueRepeatMode.one:
        return svc.AudioServiceRepeatMode.one;
      case QueueRepeatMode.all:
        return svc.AudioServiceRepeatMode.all;
      case QueueRepeatMode.off:
        return svc.AudioServiceRepeatMode.none;
    }
  }

  void _pushPlaybackState() {
    // CASTING FIX: while a session is connected, the OS media session
    // mirrors *that* session's playback — not local's, which is sitting
    // paused for the duration of the handoff (see PlaybackCoordinator).
    // Sourcing `playing`/position/duration/buffered from local here would
    // permanently show "Play" (local is always paused while casting) and
    // freeze the seek bar at the position local was at when the handoff
    // happened — the "not in sync" half of the reported bug, on top of
    // the "double audio" half `play()`/`pause()` below fix.
    final session = _activeCastSession;
    final casting = _isCasting;
    final playing = casting
        ? session!.playbackState.value == cast.CastPlaybackState.playing
        : _manager.playing.value;
    final currentDuration =
        casting ? session!.duration.value : _manager.duration.value;
    final buffering = casting
        ? session!.playbackState.value == cast.CastPlaybackState.buffering ||
            session.playbackState.value == cast.CastPlaybackState.loading
        : _manager.buffering.value;
    final currentPosition =
        casting ? session!.position.value : _manager.position.value;
    final bufferedPosition =
        casting ? session!.position.value : _manager.bufferedPosition.value;

    // Keep the media item's duration in sync once mpv determines the
    // real value. It's initially pushed in _pushMediaItem using the
    // Jellyfin-reported runtime (or zero, if that's unavailable too) —
    // at that point mpv hasn't opened the stream yet, so the true
    // duration isn't known. Only this state listener (fired again once
    // _manager.duration updates) hears about that, so without this the
    // notification/lock-screen seek bar would stay at zero/hidden for
    // the whole first track and only look "fixed" once a second
    // MediaItem happened to get pushed on the next track change.
    final current = mediaItem.value;
    if (current != null &&
        currentDuration != Duration.zero &&
        current.duration != currentDuration) {
      mediaItem.add(current.copyWith(duration: currentDuration));
    }

    final isFavorite = _manager.isFavorite.value;
    final repeatMode = PlaybackQueue.instance.repeatMode;

    playbackState.add(playbackState.value.copyWith(
      controls: [
        svc.MediaControl.skipToPrevious,
        playing ? svc.MediaControl.pause : svc.MediaControl.play,
        svc.MediaControl.skipToNext,
        // Rendered as the 4th/5th icons on the expanded lock-screen /
        // notification widget, after skipToNext (matches the
        // prev–seekbar–next–favorite–repeat layout). These aren't part
        // of audio_service's fixed control set, so they're declared as
        // custom actions and routed back through customAction() below.
        // The androidIcon string must match a drawable resource that
        // exists under android/app/src/main/res/drawable/ in the native
        // project — that folder isn't part of the lib/ zip, so the
        // corresponding drawables need to be added there directly.
        svc.MediaControl(
          androidIcon: isFavorite
              ? 'drawable/ic_favorite_filled'
              : 'drawable/ic_favorite_outline',
          label: isFavorite ? 'Remove favorite' : 'Add favorite',
          action: svc.MediaAction.custom,
          customAction: const svc.CustomMediaAction(name: 'favorite'),
        ),
        svc.MediaControl(
          // Android renders notification action icons as a flat white
          // silhouette (it strips any color/tint you give it), so "off"
          // vs "all" can't be told apart by shading alone — only "one"
          // gets a visually distinct icon (with a "1" glyph).
          androidIcon: repeatMode == QueueRepeatMode.one
              ? 'drawable/ic_repeat_one'
              : 'drawable/ic_repeat',
          label: 'Repeat',
          action: svc.MediaAction.custom,
          customAction: const svc.CustomMediaAction(name: 'repeat'),
        ),
      ],
      systemActions: const {
        svc.MediaAction.seek,
        svc.MediaAction.seekForward,
        svc.MediaAction.seekBackward,
        // Android only routes a headset's fast-forward / rewind keys
        // (KEYCODE_MEDIA_FAST_FORWARD / _REWIND, e.g. long-press
        // next/previous) to the app when these are declared on the
        // session. They add no notification buttons — only `controls` do.
        svc.MediaAction.fastForward,
        svc.MediaAction.rewind,
        svc.MediaAction.stop,
      },
      // Which 3 controls show in the *collapsed* notification; the
      // favorite/repeat controls (indices 3, 4) only appear in the
      // expanded lock-screen widget, same as the target screenshot.
      androidCompactActionIndices: const [0, 1, 2],
      processingState: buffering
          ? svc.AudioProcessingState.buffering
          : svc.AudioProcessingState.ready,
      playing: playing,
      updatePosition: currentPosition,
      bufferedPosition: bufferedPosition,
      // Declaring this (independent of the `controls` list above, which
      // only supports the fixed set of keycode-mappable actions —
      // play/pause/stop/skip/rewind/fast-forward) is what lets some
      // OEM lock-screen widgets (and Android Auto) draw their own
      // repeat button and route taps to setRepeatMode() below.
      repeatMode: _toServiceRepeatMode(PlaybackQueue.instance.repeatMode),
    ));
  }

  // CASTING FIX: every command below used to go straight to `_manager`/
  // local `player` unconditionally — the actual mechanism behind "cast
  // connects, but the phone still plays audio and the two drift out of
  // sync". These are the only entry points a lock-screen tap, Bluetooth
  // headset button, Android Auto, or Wear OS ever calls, and none of
  // them route through the in-app cast-aware widgets (MiniPlayer,
  // PlayerControlsBar) at all — so as long as this class only ever
  // touched local playback, any of those OS-level controls could resume
  // local audio right alongside an already-connected cast session with
  // no way for the person to have prevented it from the app's own UI.

  @override
  Future<void> play() =>
      _isCasting ? CastManager.instance.play() : _manager.player.play();

  @override
  Future<void> pause() =>
      _isCasting ? CastManager.instance.pause() : _manager.player.pause();

  @override
  Future<void> seek(Duration position) => _isCasting
      ? CastManager.instance.seek(position)
      : _manager.seekTo(position);

  // BLUETOOTH VIDEO CONTROLS FIX: only play/pause used to work from a
  // headset during video playback. Next/Previous called the *music* queue
  // helpers unconditionally, which silently do nothing for a movie (no
  // queue), a live channel (no queue — channels are a separate list) or a
  // standalone stream; and the headset's fast-forward/rewind keys were
  // never declared to the media session at all (see systemActions in
  // _pushPlaybackState). The video-aware routing below mirrors what the
  // video screen's own buttons and PiP actions already do.
  static const Duration _videoSeekStep = Duration(seconds: 10);

  bool get _isLiveItem => _manager.currentItem?.live ?? false;
  bool get _isVideoItem {
    final item = _manager.currentItem;
    return item != null && !item.audioOnly && !item.live;
  }

  Future<void> _seekRelative(Duration delta) async {
    if (_isCasting) {
      final session = _activeCastSession!;
      if (!session.capability.seek) return;
      final duration = session.duration.value;
      var target = session.position.value + delta;
      if (target.isNegative) target = Duration.zero;
      if (duration > Duration.zero && target > duration) target = duration;
      await CastManager.instance.seek(target);
      return;
    }
    // Live TV has no timeline to seek in.
    if (_isLiveItem) return;
    await _manager.seekBy(delta);
  }

  @override
  Future<void> fastForward() => _seekRelative(_videoSeekStep);

  @override
  Future<void> rewind() => _seekRelative(-_videoSeekStep);

  @override
  Future<void> skipToNext() async {
    if (_isCasting) {
      // DLNA FIX: go through the coordinator, which advances the app's own
      // queue (works on every transport, incl. UPnP/DLNA which has no
      // native next) instead of asking the TV to do it.
      return PlaybackCoordinator.instance.castNext();
    }
    // Live TV: Next = next channel.
    if (_isLiveItem) {
      if (_manager.hasNextChannel) await _manager.playNextChannel();
      return;
    }
    // Music tracks / episodes with something queued behind them.
    if (_manager.hasNext) return _manager.playNext();
    // A movie or one-off stream: nothing to skip to, so behave like a
    // headset's "forward" instead of doing nothing.
    if (_isVideoItem) return _seekRelative(_videoSeekStep);
    return _manager.playNext();
  }

  @override
  Future<void> skipToPrevious() async {
    if (_isCasting) {
      return PlaybackCoordinator.instance.castPrevious();
    }
    if (_isLiveItem) {
      if (_manager.hasPreviousChannel) await _manager.playPreviousChannel();
      return;
    }
    if (_manager.hasPrevious) return _manager.playPrevious();
    // A movie or one-off stream: playPrevious() would jump it back to 0:00
    // (its "restart the track" rule), which is a nasty surprise from a
    // headset button — step back 10s instead.
    if (_isVideoItem) return _seekRelative(-_videoSeekStep);
    return _manager.playPrevious();
  }

  // Fired when the user taps the heart on the lock-screen/notification
  // widget. Android surfaces this via
  // MediaSessionCompat.Callback.onSetRating, which audio_service
  // forwards here — the actual rating value passed isn't used, tapping
  // just toggles favorite state the same way the in-app heart button
  // does.
  @override
  Future<void> setRating(svc.Rating rating, [Map<String, dynamic>? extras]) {
    return _manager.toggleFavorite();
  }

  // Fired when the user taps the repeat button on the lock-screen/
  // notification widget, via
  // MediaSessionCompat.Callback.onSetRepeatMode.
  @override
  Future<void> setRepeatMode(svc.AudioServiceRepeatMode repeatMode) async {
    final queue = PlaybackQueue.instance;

    switch (repeatMode) {
      case svc.AudioServiceRepeatMode.none:
        queue.repeatMode = QueueRepeatMode.off;
        break;
      case svc.AudioServiceRepeatMode.one:
        queue.repeatMode = QueueRepeatMode.one;
        break;
      case svc.AudioServiceRepeatMode.all:
      case svc.AudioServiceRepeatMode.group:
        queue.repeatMode = QueueRepeatMode.all;
        break;
    }

    queue.repeatModeNotifier.value = queue.repeatMode;
  }

  // Fired when the user taps the favorite or repeat icon on the
  // lock-screen/notification widget (the two custom MediaControls
  // declared in _pushPlaybackState). Android surfaces both taps here via
  // MediaSessionCompat.Callback.onCustomAction.
  @override
  Future<dynamic> customAction(String name, [Map<String, dynamic>? extras]) async {
    switch (name) {
      case 'favorite':
        await _manager.toggleFavorite();
        break;
      case 'repeat':
        final queue = PlaybackQueue.instance;
        final next = switch (queue.repeatMode) {
          QueueRepeatMode.off => QueueRepeatMode.all,
          QueueRepeatMode.all => QueueRepeatMode.one,
          QueueRepeatMode.one => QueueRepeatMode.off,
        };
        queue.repeatMode = next;
        queue.repeatModeNotifier.value = next;
        break;
    }
  }

  @override
  Future<void> stop() async {
    await _manager.stop();
    await super.stop();
  }

  void dispose() {
    _ongoingDebounce?.cancel();
    _ongoingPoll?.cancel();
    for (final sub in _ongoingSubs) {
      sub.cancel();
    }
    _manager.currentItemNotifier.removeListener(_itemListener);
    _manager.playing.removeListener(_stateListener);
    _manager.buffering.removeListener(_stateListener);
    _manager.position.removeListener(_stateListener);
    _manager.duration.removeListener(_stateListener);
    _manager.bufferedPosition.removeListener(_stateListener);
    _manager.isFavorite.removeListener(_favoriteListener);
    PlaybackQueue.instance.repeatModeNotifier.removeListener(_repeatListener);

    CastManager.instance.activeSession.removeListener(_activeSessionListener);
    if (_activeCastSession != null && _castSessionListener != null) {
      _activeCastSession!.playbackState.removeListener(_castSessionListener!);
      _activeCastSession!.position.removeListener(_castSessionListener!);
    }
  }
}
