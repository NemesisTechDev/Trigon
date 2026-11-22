import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart' show Dio, Options, ResponseType;

import 'package:flutter/material.dart';

import '../player/models/audio_track.dart';
import '../player/models/media_item.dart';
import '../player/models/subtitle_track.dart';
import 'default_subtitle.dart';
import '../player/player_manager.dart';
import '../player/playback_service.dart';
import '../player/screens/audio_player_screen.dart';
import '../player/screens/player_navigation.dart';
import '../player/services/media_stream_parser.dart';
import '../player/services/playback_queue.dart';
import '../services/external_media_handler.dart';
import '../services/download_manager.dart';
import '../services/media_extras_cache_service.dart';
import '../services/sidecar_subtitles.dart';
import 'cast_manager.dart';
import 'cast_skip_controller.dart';
import 'local_cast_format.dart';
import 'local_cast_server.dart';
import 'local_video_transcode_service.dart' show LocalAudioStreamInfo;
import 'models/cast_session.dart';
import 'models/cast_states.dart';

/// CASTING PHASE 8 — PLAYBACK INTEGRATION.
///
/// The one piece of new state this phase introduces: a small reactive
/// coordinator that sits between [PlayerManager] (local playback — the
/// existing, untouched architecture) and [CastManager] (remote playback,
/// Phases 3-7). Neither of those two classes imports the other or gained
/// a compile-time dependency on the other's shape — this class only ever
/// reads their existing public surface (ValueNotifiers, the handful of
/// methods each already exposed) and reacts. That keeps this phase
/// additive: everything PlayerManager/CastManager could already do still
/// works exactly as before if this file didn't exist; this just makes
/// the two cooperate instead of running fully unaware of each other, per
/// the master prompt's Phase 8 objective.
///
/// ## What this owns
///
/// - **LOCAL → REMOTE handoff.** The moment a cast session finishes
///   connecting (`CastManager.instance.activeSession` goes from null/
///   connecting to connected) while [PlayerManager] has something loaded,
///   this pauses local playback and sends that same item, at its current
///   position, to the newly-connected device — so tapping a device in the
///   picker while something is already playing on the phone *moves* it to
///   the TV instead of running both at once (the master prompt's "prevent
///   double playback" requirement, for this specific, most-likely-to-
///   double-play scenario).
/// - **REMOTE → LOCAL offer.** The moment a session ends (`activeSession`
///   goes back to null) after having actually loaded something, this
///   shows a short SnackBar offering to resume on this device from the
///   TV's last reported position — the reverse handoff the master prompt
///   asks for. Purely an offer: doing nothing leaves local playback
///   exactly as it was (stopped, if this was a handoff-started session;
///   untouched, if the person was never playing locally at all).
/// - **[isHandoffActive]**, the one piece of new public state — true
///   whenever *this device's own local playback* is the thing currently
///   being cast (as opposed to, say, a "Cast" action sent straight from a
///   detail screen that never played locally at all — see
///   `CastToButton`/`resolveLibraryItem`, Phase 7). `VideoPlayerScreen`
///   reads this to swap its normal touch/gesture controls for a "Casting
///   — tap to control" panel instead of showing controls for a stream
///   that isn't actually rendering to this screen anymore (still-frozen
///   last frame notwithstanding).
///
/// ## What this deliberately does NOT do
///
/// It does not intercept every "Play" tap app-wide and redirect it to an
/// already-connected cast session (e.g. tapping a *different* movie's
/// Play button on some other screen while already casting something
/// else). The master prompt's own examples for Phase 8 — "starting a
/// cast session while something is playing locally", "disconnecting a
/// cast session" — are both about the transition around a single active
/// playback, not a global "hijack every local Play button while
/// connected" rule, and Phase 7 already flagged its own version of this
/// exact ambiguity (Movie/Show Details' Cast action always replacing
/// without confirming) as something for Ben to weigh in on rather than
/// something to guess big changes around. Redirecting every local Play
/// button through here would mean touching `PlaybackService.
/// playLibraryItem()` and every other local-playback entry point across
/// the app — explicitly the thing Phase 7's handoff said must NOT change.
/// If "Play always goes to whatever I'm connected to, everywhere" turns
/// out to be the wanted behavior, that's a deliberate, larger product
/// decision for a later phase, not something to fold in here silently.
class PlaybackCoordinator {
  PlaybackCoordinator._();

  static final PlaybackCoordinator instance = PlaybackCoordinator._();

  /// True while local playback has been hived off to a cast session this
  /// coordinator itself started via [_handleSessionConnected] — i.e. the
  /// thing currently on the TV *is* what was just playing on this phone,
  /// not a separate "Cast to" send that never touched local playback.
  /// `VideoPlayerScreen` (and, eventually, other local-playback surfaces)
  /// read this to show casting-aware UI instead of normal local controls.
  final ValueNotifier<bool> isHandoffActive = ValueNotifier(false);

  bool _initialized = false;
  bool _wasConnected = false;

  // Mirrors of the current session's own currentItem/position, kept live
  // (not read lazily off the session at disconnect time) because
  // CastManager.disconnect() disposes the session's ValueNotifiers
  // *before* activeSession itself flips to null — by the time this
  // class's activeSession listener fires, session.position/currentItem
  // are already torn down. Tracking our own copy, updated for as long as
  // the session lives, is what lets the REMOTE → LOCAL resume offer still
  // know what was playing and how far along it was.
  MediaItem? _lastCastItem;
  Duration _lastCastPosition = Duration.zero;
  CastSession? _observedSession;
  VoidCallback? _positionListener;
  VoidCallback? _itemListener;
  VoidCallback? _playbackStateListener;

  /// CASTING FIX (queue redirect + accurate playing/next/previous while
  /// casting music): true whenever [PlayerManager]'s notifiers are being
  /// mirrored from the active session's own state — see
  /// [PlayerManager.beginCastMirror] — rather than genuinely reflecting
  /// local mpv. Set for the *audio* LOCAL → REMOTE handoff below and for
  /// every subsequent [playAudioQueueOnActiveCast] call (picking a new
  /// song elsewhere in the app while already casting); left false for a
  /// video handoff, which keeps its existing, unmirrored behavior.
  bool _mirroringAudio = false;

  /// EPISODE NAV FIX (previous/next episode buttons missing or not
  /// advancing while casting): `_castVideoQueue` (in
  /// `PlaybackService`) deliberately only ever hands the connected
  /// target a *single* loaded episode — see its own doc comment on why
  /// a real multi-item `loadQueue()` send isn't trustworthy across all
  /// three transports — so the receiver's own `next()`/`previous()`
  /// command (what [castNext]/[castPrevious] used to fall back to for
  /// every non-mirrored-audio session, video included) has no sibling
  /// queue of its own to advance through, and most receivers never even
  /// report `next`/`previous` capability for a single-item load in the
  /// first place. [PlaybackQueue.instance] is populated with the full
  /// season/series list regardless (`PlaybackService.playQueue`), so —
  /// same as the existing mirrored-audio case just below — it's the one
  /// reliable source of "what's the next/previous episode", with the
  /// skip itself sent as a fresh single-item load rather than a
  /// transport-native command. True for a mirrored audio queue (as
  /// before) or for a cast session whose current item is a video
  /// episode drawn from a season/series queue.
  bool get _shouldDriveSkipFromQueue {
    if (_mirroringAudio) return true;
    final queue = PlaybackQueue.instance;
    final current = queue.current;
    if (current == null || current.audioOnly) return false;
    return queue.source == PlaybackSource.season ||
        queue.source == PlaybackSource.series;
  }

  /// Whether the active cast session (if any) is currently an app-driven
  /// audio queue — i.e. [PlaybackQueue.instance] is the source of truth
  /// for what's playing/next/previous, as opposed to a single item sent
  /// once via `CastToButton` or an unmirrored video handoff. Read by
  /// `CastTransportControls`' audio row so its shuffle/repeat/next/
  /// previous controls know they can drive the local queue directly
  /// instead of depending on the connected target's own (frequently
  /// unreliable — see [castNext]'s doc comment) queue support.
  bool get isMirroringAudio => _mirroringAudio;

  /// The session's own [CastPlaybackState] as of the last time
  /// [_playbackStateListener] fired — compared against the *new* value on
  /// every subsequent fire so [_maybeAutoAdvanceQueue] can tell "this was
  /// already idle/stopped" (nothing to react to) apart from "this just
  /// finished playing" (advance the queue). Reset whenever observation
  /// starts/stops so a stale value from a previous session can never leak
  /// into a fresh one.
  CastPlaybackState? _lastObservedPlaybackState;

  /// SEEK-RESTART FIX: the poll timer started by [_deferAutoAdvanceCheck]
  /// while a seek's flicker is being ridden out — cancelled outright in
  /// [_stopObservingSession] so a session teardown (disconnect, a fresh
  /// session replacing this one) can never leave a stray timer running
  /// past the observation it belongs to.
  Timer? _deferredAutoAdvanceTimer;

  // -----------------------------------------------------------------
  // EXPLICIT "CAST THIS TITLE" WHILE SOMETHING ELSE IS PLAYING
  // -----------------------------------------------------------------
  //
  // ROOT CAUSE (a song is playing, the person taps Cast on a movie's
  // details screen, picks a TV — and the TV gets the SONG, or nothing, and
  // the mini player stays on the song): connecting a session is, by
  // design, a "hand off whatever is playing locally" event
  // ([_handleSessionConnected]). The Cast button on a details screen then
  // loads the MOVIE into the same session a network round trip later
  // (`resolveLibraryItem`). The two loads raced: the song's hand-off ran
  // first, the movie superseded it on the TV, but the hand-off's tail
  // still ran afterwards and switched the mini player into "mirroring the
  // song" mode.
  //
  // Now the details screen declares its intent BEFORE opening the device
  // picker ([beginExplicitCast]). While that intent is pending the
  // connect-time hand-off is skipped (local audio is only paused — never
  // stopped or dismissed, so its mini player is intact), and
  // [prepareForExplicitCast] right before the real load parks whatever
  // song was on screen/on the TV so that, when the session ends, that song
  // is the one waiting in the mini player, paused and ready.
  bool _explicitCastPending = false;
  Timer? _explicitCastTimer;

  /// Bumped whenever an explicit cast takes over, so a connect-time
  /// hand-off that was already in flight can tell it has been superseded
  /// and must not start mirroring its (now abandoned) item.
  int _handoffEpoch = 0;

  /// The song that was playing (locally, or mirrored from the TV) when a
  /// movie/episode was explicitly cast over it. Consumed on disconnect.
  MediaItem? _displacedAudio;
  Duration _displacedAudioPosition = Duration.zero;
  bool _displacedAudioMirrorOnly = false;

  /// Call BEFORE opening the device picker for an explicit "cast this
  /// title" action. Pair with [endExplicitCast] in a `finally`.
  void beginExplicitCast() {
    _explicitCastPending = true;
    _explicitCastTimer?.cancel();
    // Safety net: an intent must never outlive the gesture that made it.
    _explicitCastTimer = Timer(const Duration(seconds: 90), () {
      _explicitCastPending = false;
    });
  }

  void endExplicitCast() {
    _explicitCastPending = false;
    _explicitCastTimer?.cancel();
    _explicitCastTimer = null;
  }

  /// Call right before `CastManager.loadAndPlay(castItem)` for an explicit
  /// cast of a movie/episode/channel on a CONNECTED session. Keeps whatever
  /// song was playing from fighting the new title for the TV or the mini
  /// player, and remembers it for the disconnect.
  Future<void> prepareForExplicitCast(MediaItem castItem) async {
    if (castItem.audioOnly) return;
    _handoffEpoch++;
    if (CastManager.instance.activeSession.value == null) return;
    final manager = PlayerManager.instance;

    if (_mirroringAudio) {
      // A song queue is currently mirrored from the TV. The movie replaces
      // it on the TV; the song stays in the mini player (not dismissed).
      final song = manager.currentItem;
      if (song != null && song.audioOnly) {
        _displacedAudio = song;
        _displacedAudioPosition = _lastCastPosition;
        _displacedAudioMirrorOnly = true;
      }
      manager.endCastMirror();
      _mirroringAudio = false;
      isHandoffActive.value = false;
    } else if (!manager.castMirrorActive) {
      final local = manager.currentItem;
      if (local != null && local.audioOnly) {
        _displacedAudio = local;
        _displacedAudioPosition = manager.position.value;
        _displacedAudioMirrorOnly = false;
      }
    }
    // Local audio never plays while a session is connected; make sure the
    // song is paused (never stopped — its mini player must survive).
    await manager.enforceNoLocalAudioWhileCasting();
  }

  /// The text shown when a cast fails. A DLNA failure carries a specific
  /// reason (the TV refused the stream / never started it) which is far
  /// more useful than the generic sentence.
  String _castFailureText(Object e, String title, {String? deviceName}) {
    if (e is LocalCastUnsupportedException) return e.message;
    final kind = CastManager.instance.activeSession.value?.transportKind;
    if (kind == CastTransportKind.dlna && e is StateError) {
      final m = e.message.toString();
      if (m.isNotEmpty) return m;
    }
    return deviceName != null
        ? '"$title" couldn\'t be cast to $deviceName.'
        : '"$title" couldn\'t be cast to the TV.';
  }

  /// Public wrapper of [_castFailureText] for `PlaybackService`, so a failed
  /// video redirect shows the transport's real reason (the TV refused the
  /// stream, never fetched the file, …) instead of one fixed sentence.
  String castFailureText(Object e, String title, {String? deviceName}) =>
      _castFailureText(e, title, deviceName: deviceName);

  /// Why the last [_sendMirroredItem] failed (null when it didn't).
  Object? _lastSendError;

  /// Call once at startup, after `CastManager.instance.registerTransport`
  /// has run for every transport (main.dart) — this only ever reacts to
  /// `activeSession` changes, so the exact moment relative to transport
  /// registration doesn't matter much, but matching where
  /// `DownloadManager.instance.init()`/etc. already sit keeps every
  /// singleton's startup wiring in one obvious place.
  void init() {
    if (_initialized) return;
    _initialized = true;
    CastManager.instance.activeSession.addListener(_onActiveSessionChanged);
    // Lets CastManager.connect pick DLNA (not a Jellyfin session) for a TV
    // that offers both when local-only media is what's being cast.
    CastManager.instance.hasLocalMediaProvider = () =>
        (PlayerManager.instance.currentItem?.isLocal ?? false) ||
        (PlaybackQueue.instance.current?.isLocal ?? false);

    // Shuffle pressed while casting: a TV that keeps its own copy of the
    // queue (Jellyfin session, Nemesis Native, Google Cast) must be given
    // the new order — see [_onShuffleChanged].
    PlaybackQueue.instance.shuffleNotifier.addListener(_onShuffleChanged);
    _lastRepeatMode = PlaybackQueue.instance.repeatMode;
    PlaybackQueue.instance.repeatModeNotifier.addListener(_onRepeatChanged);

    // NO LOCAL AUDIO WHILE CASTING: PlayerManager never imports the
    // casting layer, so the two pieces it needs are injected here — the
    // "is a session connected" check its mpv guards use, and the
    // redirect that sends a play request to the TV instead of mpv.
    PlayerManager.instance.isCastConnected =
        () => CastManager.instance.isCasting;
    PlayerManager.instance.redirectPlayToCast = _redirectLocalPlayToCast;

    // Skip Intro/Credits + Next Episode/Show/Movie widgets while a video is
    // cast: PlayerManager's own position listener only ever sees local mpv,
    // so this feeds the same notifiers from the cast session instead.
    CastSkipController.instance.init();
  }

  /// Called by [PlayerManager.playMedia] when something asks mpv to play
  /// while a cast session is connected (a screen that calls
  /// `PlayerManager` directly, the queue/episode panels' fallback after a
  /// failed `castJumpTo`, repeat/auto-advance...). Sends [item] to the TV
  /// as a normal mirrored item. Always returns true while a session is
  /// connected: a failure is reported, never answered with local audio.
  Future<bool> _redirectLocalPlayToCast(MediaItem item) async {
    if (!CastManager.instance.isCasting) return false;

    final manager = PlayerManager.instance;
    if (!item.audioOnly) releaseLocalVideoCastFor(item);

    _mirroringAudio = item.audioOnly;
    if (item.audioOnly) {
      isHandoffActive.value = true;
      manager.suspendAdaptiveQualityForCast();
    }
    manager.beginCastMirror(item);

    final sent = await _sendMirroredItem(item);
    if (!sent && CastManager.instance.isCasting) {
      final err = _lastSendError;
      reportCastFailure(err != null
          ? _castFailureText(err, item.title)
          : '"${item.title}" couldn\'t be cast to the TV.');
    }
    return true;
  }

  /// Shows [message] in the same snackbar every other cast failure uses.
  /// Public so `PlaybackService` can report a failed redirect instead of
  /// falling back to local playback while a session is still connected.
  void reportCastFailure(String message) => _showCastFailureMessage(message);

  void _onActiveSessionChanged() {
    final session = CastManager.instance.activeSession.value;

    if (session != null && !_wasConnected) {
      _wasConnected = true;
      _observeSession(session);
      _handleSessionConnected(session);
    } else if (session == null && _wasConnected) {
      _wasConnected = false;
      _stopObservingSession();
      _handleSessionDisconnected();
    } else if (session != null) {
      // Same non-null session as before but this listener still fired —
      // only happens if activeSession's *identity* changed without going
      // through null in between, which CastManager never actually does
      // today (connect() always disconnects any existing session first).
      // Re-pointing the observation defensively costs nothing if this
      // path is ever exercised in the future.
      if (!identical(session, _observedSession)) {
        _stopObservingSession();
        _observeSession(session);
      }
    }
  }

  Timer? _shuffleResyncTimer;

  /// SHUFFLE-WHILE-CASTING FIX. Shuffle only ever reordered this phone's
  /// [PlaybackQueue]. A DLNA renderer plays one URL at a time, so the phone
  /// queue is the only queue and nothing more is needed there. But a TV that
  /// was handed the whole queue up front (a Kodi / MagConnect style Jellyfin
  /// session, Nemesis Native, Google Cast) kept playing and top-up-ing its
  /// OLD order, ignoring the shuffle. Once the toggle settles, the queue is
  /// re-sent starting at the song that is playing now, at its current
  /// position, so the TV's idea of "next" matches the phone's.
  void _onShuffleChanged() {
    // `shuffleNotifier` flips BEFORE PlaybackQueue has re-ordered itself, so
    // nothing may be read from the queue until this timer fires.
    _shuffleResyncTimer?.cancel();
    _shuffleResyncTimer = Timer(
      const Duration(milliseconds: 400),
      () => unawaited(_resyncCastQueueAfterShuffle()),
    );
  }

  QueueRepeatMode _lastRepeatMode = QueueRepeatMode.off;

  /// Repeat-all rebuilds the queue (everything rotated to continue after the
  /// current song, wrapping around), and leaving it drops the songs before
  /// the current one again — so a TV holding its own copy of the queue needs
  /// it re-sent on those two switches. Off <-> one changes no order, and with
  /// shuffle on the order is already shuffled either way, so nothing is
  /// re-sent for those (a re-send restarts the song's buffer for nothing).
  void _onRepeatChanged() {
    final queue = PlaybackQueue.instance;
    final previous = _lastRepeatMode;
    final now = queue.repeatMode;
    _lastRepeatMode = now;
    final touchesAll =
        previous == QueueRepeatMode.all || now == QueueRepeatMode.all;
    if (!touchesAll || queue.shuffleNotifier.value) return;
    _onShuffleChanged(); // same debounce + re-send
  }

  Future<void> _resyncCastQueueAfterShuffle() async {
    if (!_mirroringAudio || !CastManager.instance.isCasting) return;
    final session = CastManager.instance.activeSession.value;
    if (session == null) return;
    final kind = session.transportKind;
    if (kind != CastTransportKind.googleCast) {
      return; // DLNA: the phone queue already is the queue.
    }

    final queue = PlaybackQueue.instance;
    final current = queue.current;
    // If the TV is still switching songs, that load decides what plays.
    if (current == null || session.currentItem.value?.id != current.id) return;
    if (queue.items.length < 2) return;

    final position = session.position.value;
    final wasPaused = session.playbackState.value == CastPlaybackState.paused;
    try {
      await CastManager.instance.playQueue(
        queue.items,
        startIndex: queue.currentIndex,
        startAt: position,
      );
      if (wasPaused && CastManager.instance.isCasting) {
        try {
          await CastManager.instance.pause();
        } catch (_) {}
      }
    } catch (e) {
      debugPrint('CASTING DEBUG: re-sending queue after shuffle failed: $e');
    }
  }

  void _observeSession(CastSession session) {
    _observedSession = session;
    // PHASE 2 (F2.2 / F1.5): what the session reports for a local item is
    // the COPY resolved for the TV (phone-server URLs for the file and the
    // cover). The app only ever keeps the original — the copy's URLs die
    // with the server at disconnect, and the "resume on this phone" offer
    // and the mini player must never be pointed at them.
    MediaItem? appItem(MediaItem? i) =>
        i == null ? null : CastManager.instance.appItemFor(i);
    _lastCastItem = appItem(session.currentItem.value);
    _lastCastPosition = session.position.value;
    _lastObservedPlaybackState = session.playbackState.value;

    _itemListener = () {
      _lastCastItem = appItem(session.currentItem.value);
      // CASTING FIX: keeps mini player / song rows / AudioPlayerScreen
      // pointed at whatever track the *session itself* just advanced to
      // — including a device-initiated skip (tapping next on the TV's
      // own remote, or the receiver auto-advancing its own loaded
      // queue) that this app never drove locally at all.
      final item = appItem(session.currentItem.value);
      if (_mirroringAudio && item != null) {
        PlayerManager.instance.updateCastMirrorItem(item);

        // CASTING FIX (Queue screen frozen while casting): this used to
        // be the one place `PlaybackQueue.instance`'s own index never
        // actually moved once a session took over — `updateCastMirrorItem`
        // only ever touched PlayerManager's notifiers, so QueueScreen's
        // "Now playing"/"Next up" list (bound to
        // `PlaybackQueue.currentIndexNotifier`/`queueNotifier` directly)
        // silently froze on whatever position casting started at, no
        // matter what the receiver did afterward. Re-pointing the local
        // queue's index at whatever the receiver actually reports keeps
        // the Queue screen (and anything else reading PlaybackQueue,
        // like `hasNext`/`hasPrevious`) accurate for both a
        // receiver-initiated advance and this class's own
        // castNext()/castPrevious()/auto-advance below (which already
        // move the index themselves before sending, so this is a no-op
        // for those).
        final queue = PlaybackQueue.instance;
        if (queue.current?.id != item.id) {
          final index = queue.items.indexWhere((i) => i.id == item.id);
          if (index != -1) queue.jumpTo(index);
        }
      }
    };
    _positionListener = () {
      _lastCastPosition = session.position.value;
      if (_mirroringAudio) _pushMirrorPlaybackState(session);
    };
    _playbackStateListener = () {
      final previous = _lastObservedPlaybackState;
      final current = session.playbackState.value;
      _lastObservedPlaybackState = current;

      if (_mirroringAudio) {
        _pushMirrorPlaybackState(session);

        // SEEK-RESTART FIX (root cause): a seek command (dragging/
        // tapping the seek bar on a casted song, from either the audio
        // player screen or the cast info tab) can make the receiver
        // flash through `idle`/`buffering` for a moment while it
        // re-buffers at the new position, before landing back on
        // `playing`. That flicker used to read as a genuine "previous ->
        // natural end" transition to `_maybeAutoAdvanceQueue`, which
        // reacted by treating the track as finished — replaying it from
        // position 0 (repeat-one, or repeat-all wrapping a short/
        // single-item queue back to itself) or skipping to the next
        // item, either of which is exactly what looked like "seeking
        // restarts the song".
        //
        // `session.idleReason` (Google Cast only — see CastIdleReason's
        // doc comment) is the SDK's own authoritative answer to "did
        // this actually end, or did we just interrupt it ourselves?".
        // Only ever used to make the guard *stronger*, never weaker than
        // the original isSeekPending timing check:
        //  - `interrupted`/`cancelled` are exactly what a seek/stop/
        //    reload produce on their own, on purpose — an unconditional
        //    "never treat this as a track ending", with no timing race
        //    left to lose regardless of whether isSeekPending happens to
        //    still be true or has already cleared.
        //  - `finished` is the one case confident enough to skip the
        //    defer/poll entirely and check immediately — the receiver
        //    itself says the content genuinely ran out.
        //  - Anything else (`none`/`error`, or `null` — no reason
        //    reported at all, which the Cast SDK's own docs say is
        //    possible, and always the case for JellyfinRemoteTransport/
        //    NemesisNativeTransport) falls back to the original
        //    `isSeekPending`-timing defer exactly as before, rather than
        //    assuming an unconfirmed idle is a real end.
        final reason = session.idleReason.value;
        if (reason == CastIdleReason.interrupted ||
            reason == CastIdleReason.cancelled) {
          // Known, on-purpose side effect of our own command — never a
          // track ending. Nothing to defer or check.
        } else if (reason == CastIdleReason.finished) {
          _maybeAutoAdvanceQueue(previous, current);
        } else if (session.isSeekPending) {
          _deferAutoAdvanceCheck(session, previous);
        } else {
          _maybeAutoAdvanceQueue(previous, current);
        }
      }
    };

    session.currentItem.addListener(_itemListener!);
    session.position.addListener(_positionListener!);
    session.playbackState.addListener(_playbackStateListener!);
  }

  void _pushMirrorPlaybackState(CastSession session) {
    PlayerManager.instance.updateCastMirrorPlayback(
      playing_: session.playbackState.value == CastPlaybackState.playing,
      position_: session.position.value,
      duration_: session.duration.value,
    );
  }

  void _stopObservingSession() {
    if (_observedSession != null) {
      if (_itemListener != null) {
        _observedSession!.currentItem.removeListener(_itemListener!);
      }
      if (_positionListener != null) {
        _observedSession!.position.removeListener(_positionListener!);
      }
      if (_playbackStateListener != null) {
        _observedSession!.playbackState.removeListener(_playbackStateListener!);
      }
    }
    // SEEK-RESTART FIX: a deferred check left running past this
    // session's own lifetime would otherwise fire against whatever
    // *new* session/state happens to be current by the time its poll
    // catches isSeekPending clearing — stale by definition.
    _deferredAutoAdvanceTimer?.cancel();
    _deferredAutoAdvanceTimer = null;
    _observedSession = null;
    _itemListener = null;
    _positionListener = null;
    _playbackStateListener = null;
    _lastObservedPlaybackState = null;
  }

  /// SEEK-RESTART FIX: called instead of [_maybeAutoAdvanceQueue] the
  /// moment `_playbackStateListener` sees `session.isSeekPending` still
  /// true — i.e. the playback-state flip it just observed might only be
  /// a seek settling, not a real end-of-track. Polls (cheaply — a plain
  /// bool check every 150ms, capped by CastSession's own seek-grace
  /// windows) until the seek resolves one way or the other, then makes
  /// the real auto-advance decision against whatever `playbackState`
  /// actually is *at that point* — not the possibly-stale value that
  /// triggered this in the first place, since the receiver may have
  /// already moved on (e.g. settled back on `playing` at the sought-to
  /// position, which is the common case and correctly results in no
  /// auto-advance at all).
  void _deferAutoAdvanceCheck(
    CastSession session,
    CastPlaybackState? previousBeforeFlicker,
  ) {
    _deferredAutoAdvanceTimer?.cancel();
    _deferredAutoAdvanceTimer = Timer.periodic(
      const Duration(milliseconds: 150),
      (timer) {
        // The session this was watching got torn down (disconnect, a
        // new session taking over) while waiting — nothing left to
        // check against. _stopObservingSession already cancels this
        // timer directly, but guarding on identity too costs nothing
        // and protects against any future reordering of that teardown.
        if (!_mirroringAudio || !identical(session, _observedSession)) {
          timer.cancel();
          return;
        }
        if (session.isSeekPending) return; // Still settling — keep polling.

        timer.cancel();
        _deferredAutoAdvanceTimer = null;
        _maybeAutoAdvanceQueue(previousBeforeFlicker, session.playbackState.value);
      },
    );
  }

  // -----------------------------------------------------------------
  // QUEUE NAVIGATION (manual next/previous + natural end-of-track)
  // -----------------------------------------------------------------

  /// States that mean "actually doing something with the loaded item" —
  /// used by [_maybeAutoAdvanceQueue] to recognize a genuine "this track
  /// just finished" transition rather than, say, the idle state a
  /// freshly-connected session starts in before anything has ever been
  /// loaded.
  static const _activeCastStates = {
    CastPlaybackState.playing,
    CastPlaybackState.paused,
    CastPlaybackState.buffering,
    CastPlaybackState.loading,
  };

  /// States that mean "nothing is playing right now" — reached either by
  /// the receiver naturally running out of what it was told to play, or
  /// by an explicit stop. Landing here right after having been in one of
  /// [_activeCastStates] is what this class treats as "the track ended".
  static const _naturalEndCastStates = {
    CastPlaybackState.idle,
    CastPlaybackState.ended,
    CastPlaybackState.stopped,
  };

  /// CASTING FIX (song ends -> playback just stops instead of advancing):
  /// the three transports' own end-of-track handling is, at best,
  /// inconsistent — Jellyfin Remote only ever reports "no NowPlayingItem"
  /// (this app can't tell "the receiver's own queue ran out" apart from
  /// "the receiver never had a real queue to begin with", and several
  /// real Jellyfin session receivers are documented elsewhere in this
  /// file as only ever honoring the first item of a multi-item `Playing`
  /// command regardless of what else was sent), and Nemesis Native has no
  /// real receiver to verify this against at all yet. Rather than trust
  /// any of the three to correctly advance their own loaded queue at
  /// end-of-track, this watches the session's own playback state and
  /// drives the *next* load itself the moment something that was
  /// actually playing stops — the same "the phone decides what plays
  /// next" model [castNext]/[castPrevious] already use for a manual skip,
  /// just triggered by the track ending on its own instead of a button
  /// press.
  void _maybeAutoAdvanceQueue(
    CastPlaybackState? previous,
    CastPlaybackState current,
  ) {
    if (previous == null || !_activeCastStates.contains(previous)) return;
    if (!_naturalEndCastStates.contains(current)) return;

    final queue = PlaybackQueue.instance;

    // Repeat-one: replay the same track rather than consuming it, same
    // semantics as PlayerManager's own local repeat-one handling.
    if (queue.repeatMode == QueueRepeatMode.one) {
      final same = queue.current;
      if (same != null) unawaited(_sendMirroredItem(same));
      return;
    }

    final nextItem = queue.completeCurrent();
    if (nextItem != null) unawaited(_sendMirroredItem(nextItem));
    // Queue genuinely exhausted (repeat off, nothing left) — leave the
    // session as-is, matching local playback's own "nothing left, just
    // stop" behavior rather than guessing at something else to play.
  }

  /// Manual "next" — the cast row's skip-next button and any other
  /// programmatic caller. While an app-driven audio queue is mirrored
  /// (the normal case for every audio cast session — see
  /// [isMirroringAudio]) or a video episode is playing from a season/
  /// series queue (see [_shouldDriveSkipFromQueue]), this advances
  /// [PlaybackQueue.instance] itself and sends the resulting item as a
  /// fresh single-item load, rather than asking the connected
  /// transport's own `NextTrack`/`next()` command to move within
  /// whatever queue the receiver may or may not have actually kept —
  /// see [_maybeAutoAdvanceQueue]'s doc comment for why that can't be
  /// trusted across all three transports/receivers. Falls back to the
  /// transport's own command only for a standalone item with nothing in
  /// [PlaybackQueue] to advance to (e.g. a lone movie), which keeps its
  /// existing, receiver-driven behavior untouched.
  Future<void> castNext() async {
    if (!_shouldDriveSkipFromQueue || !CastManager.instance.isCasting) {
      // DLNA FIX: a standalone item (nothing in PlaybackQueue to advance
      // to) used to fall through to the transport's own next(), which
      // UPnP/DLNA doesn't have — so the lock-screen/notification skip
      // button threw UnsupportedCastCommand. Only forward when the
      // connected target actually reports it; otherwise there's simply
      // nothing to skip to, which is not an error.
      final session = CastManager.instance.activeSession.value;
      if (session != null && session.capability.next) {
        await CastManager.instance.next();
      }
      return;
    }

    final item = PlaybackQueue.instance.next();
    if (item == null) return;

    final sent = await _sendMirroredItem(item);
    if (!sent && CastManager.instance.isCasting) {
      final err = _lastSendError;
      reportCastFailure(err != null
          ? _castFailureText(err, item.title)
          : '"${item.title}" couldn\'t be cast to the TV.');
    }
  }

  /// Manual "previous" — mirrors [PlayerManager.playPrevious]'s own
  /// "restart the current track if it's already a few seconds in"
  /// convention (using the session's own reported position, since local
  /// mpv is paused/irrelevant during a mirrored cast), rather than always
  /// jumping back a full track the way a bare `previous()` transport
  /// command would.
  Future<void> castPrevious() async {
    if (!_shouldDriveSkipFromQueue || !CastManager.instance.isCasting) {
      // DLNA FIX: see castNext(). A standalone item has no previous
      // track; restart it instead of throwing on a transport (UPnP/DLNA)
      // that has no previous() command.
      final session = CastManager.instance.activeSession.value;
      if (session != null && session.capability.previous) {
        await CastManager.instance.previous();
      } else if (session != null && session.capability.seek) {
        await CastManager.instance.seek(Duration.zero);
      }
      return;
    }

    final session = _observedSession;
    final pastRestartThreshold = session != null &&
        session.position.value > const Duration(seconds: 3);

    if (pastRestartThreshold) {
      await _restartCurrentOnCast();
      return;
    }

    final item = PlaybackQueue.instance.previous();
    if (item == null) {
      await _restartCurrentOnCast();
      return;
    }

    final sent = await _sendMirroredItem(item);
    if (!sent && CastManager.instance.isCasting) {
      final err = _lastSendError;
      reportCastFailure(err != null
          ? _castFailureText(err, item.title)
          : '"${item.title}" couldn\'t be cast to the TV.');
    }
  }

  /// PHASE 4: "previous" past the first seconds restarts the track. That is
  /// a seek to 0 — and on a TV that cannot seek (a file from the phone on a
  /// minimal DLNA renderer) the seek is refused or switched off, in which
  /// case the same track is simply sent again instead of the tap doing
  /// nothing.
  Future<void> _restartCurrentOnCast() async {
    try {
      await CastManager.instance.seek(Duration.zero);
      return;
    } catch (e) {
      debugPrint('CASTING DEBUG: restart by seek failed ($e) — sending the '
          'current item again');
    }
    final current = PlaybackQueue.instance.current;
    if (current == null || !CastManager.instance.isCasting) return;
    final sent = await _sendMirroredItem(current);
    if (!sent && CastManager.instance.isCasting) {
      final err = _lastSendError;
      reportCastFailure(err != null
          ? _castFailureText(err, current.title)
          : '\"${current.title}\" couldn\'t be cast to the TV.');
    }
  }

  /// PHASE 4: warms the cover of the item that follows [item] in the queue
  /// (DLNA only), a few seconds after [item] has started so it never
  /// competes with the load itself.
  void _prefetchFollowing(MediaItem item) {
    unawaited(Future<void>.delayed(const Duration(seconds: 4), () {
      if (!CastManager.instance.isCasting) return;
      final queue = PlaybackQueue.instance;
      if (queue.current?.id != item.id) return;
      final items = queue.items;
      final i = items.indexWhere((e) => e.id == item.id);
      if (i < 0 || i + 1 >= items.length) return;
      CastManager.instance.prefetchNextItem(items[i + 1]);
    }));
  }

  /// Jumps [PlaybackQueue.instance] straight to [index] and sends that
  /// track to the active cast session — what `QueueScreen`/
  /// `EpisodeListPanel` call instead of `PlayerManager.instance
  /// .playMedia()` (a purely local call) when the person taps a row
  /// while already casting. Returns false — no side effects beyond the
  /// queue-index jump itself, which is harmless either way — if nothing
  /// is actually connected, *or* if the send to the TV itself failed,
  /// so the caller can fall back to normal local playback either way
  /// rather than the tap silently doing nothing and needing a second
  /// press to actually start something playing somewhere.
  Future<bool> castJumpTo(int index) async {
    if (!CastManager.instance.isCasting) return false;

    final item = PlaybackQueue.instance.jumpTo(index);
    if (item == null) return false;

    // A tap in the Queue screen/episode panel is exactly the same kind
    // of "keep this on the TV, don't touch local mpv" pick
    // `playAudioQueueOnActiveCast` already handles for a song tapped
    // elsewhere in the app — mark this an app-driven mirrored queue if
    // it wasn't already flagged as one (e.g. the person opened the
    // Queue screen for a session that was only ever casting a single
    // standalone item). RECLICK FIX: this used to force `true`
    // unconditionally, mislabeling a tapped video *episode* as an
    // audio-mirrored session too — harmless for `isMirroringAudio`'s
    // own audio-row reader (which never sees a video item), but wrong
    // for anything else keying off it. Reflects the actual item now.
    _mirroringAudio = item.audioOnly;
    PlayerManager.instance.beginCastMirror(item);

    return _sendMirroredItem(item);
  }

  /// RECLICK FIX (episode/song tap sometimes needing a second tap to
  /// actually reach the TV): this used to swallow a failed
  /// `loadAndPlay` behind a bare `debugPrint`, so every caller —
  /// [castNext], [castPrevious], and especially [castJumpTo] — always
  /// reported success regardless of whether anything actually reached
  /// the connected session. `castJumpTo`'s caller (`EpisodeListPanel`/
  /// `QueueScreen`) trusted that reported success and skipped its own
  /// local-playback fallback, so a failed first attempt looked like the
  /// tap did nothing at all — tapping the same row again then retried
  /// the load and (assuming the failure was transient) worked. Now
  /// returns whether the send actually succeeded, so a genuine failure
  /// is visible to the caller instead of silently reported as done.
  Future<bool> _sendMirroredItem(MediaItem item) async {
    PlayerManager.instance.updateCastMirrorItem(item);
    _lastSendError = null;
    // NEXT-NEEDS-TWO-TAPS FIX: a DLNA load that failed to start (Kodi /
    // MagConnect dropping the new URI during a track switch) used to leave
    // the TV empty and the queue already advanced, so the person's second
    // tap loaded the song AFTER it — one song skipped every time. A DLNA
    // load is now tried once more, for the same song, unless the person has
    // already moved the queue on.
    final isDlna = CastManager.instance.activeSession.value?.transportKind ==
        CastTransportKind.dlna;
    final maxTries = isDlna ? 2 : 1;
    for (var attempt = 1; attempt <= maxTries; attempt++) {
      // PHASE 0 (diagnostics): when each send starts and how long it took.
      final sendStartedAt = DateTime.now();
      debugPrint(
        'CASTING DEBUG: sending "${item.title}" to the cast session '
        '(try $attempt/$maxTries, local=${item.isLocal}, '
        'audio=${item.audioOnly})',
      );
      try {
        await CastManager.instance.loadAndPlay(item);
        _lastSendError = null;
        debugPrint(
          'CASTING DEBUG: send of "${item.title}" returned OK after '
          '${DateTime.now().difference(sendStartedAt).inMilliseconds} ms',
        );
        if (isDlna) _prefetchFollowing(item);
        return true;
      } catch (e) {
        _lastSendError = e;
        debugPrint(
          'CASTING DEBUG: castNext/castPrevious/castJumpTo failed to load '
          '"${item.title}" on the active cast session '
          '(try $attempt/$maxTries): $e',
        );
        // PHASE 1: a second send only after a QUICK failure (the TV refused
        // at once). A send that took long enough for the TV to have been
        // visibly working is not repeated — the transport has already
        // waited, adopted a late start, or failed for a stated reason, and a
        // blind re-send would restart a start that was merely slow.
        if (attempt == maxTries ||
            DateTime.now().difference(sendStartedAt) >
                const Duration(seconds: 8) ||
            e is LocalCastUnsupportedException ||
            !CastManager.instance.isCasting ||
            PlaybackQueue.instance.current?.id != item.id) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 600));
        if (!CastManager.instance.isCasting ||
            PlaybackQueue.instance.current?.id != item.id) {
          break;
        }
      }
    }
    return false;
  }

  // -----------------------------------------------------------------
  // LOCAL → REMOTE
  // -----------------------------------------------------------------

  /// A newly-connected session just appeared. If this device was playing
  /// something locally, that's the content that should now be on the TV
  /// — pause here, send it there.
  Future<void> _handleSessionConnected(CastSession session) async {
    final manager = PlayerManager.instance;
    final localItem = manager.currentItem;

    // PHASE 0 (diagnostics): the connect-time handoff races with the tap
    // that caused the connection (finding F5.3) — show which one saw what.
    debugPrint(
      'CASTING DEBUG: session connected (${session.transportKind}, '
      '"${session.device.displayName}"); explicitCastPending='
      '$_explicitCastPending; local current item='
      '${localItem == null ? 'none' : '"${localItem.title}" (local=${localItem.isLocal}, audio=${localItem.audioOnly}, playing=${manager.playing.value})'}',
    );

    // The person tapped Cast on a specific title: THAT title goes to the
    // TV, not whatever happens to be playing here. See
    // [beginExplicitCast]. Local audio is only paused (never stopped), so
    // its mini player is still there, paused, when the session ends.
    if (_explicitCastPending) {
      unawaited(manager.enforceNoLocalAudioWhileCasting());
      return;
    }
    final epoch = _handoffEpoch;
    // PHASE 1: lets the handoff notice that a tap-driven load reached this
    // session while it was still preparing (see CastManager.loadSeq).
    final seqAtConnect = CastManager.instance.loadSeq;

    // Nothing playing locally (the person connected from, say, the Home
    // app bar with nothing loaded) — nothing to hand off. The session
    // stays connected and idle, exactly as CastManager already leaves it;
    // Cast-to-TV actions (Movie/Show Details' CastToButton) load their
    // own content into it separately.
    if (localItem == null) {
      // NO LOCAL AUDIO WHILE CASTING: nothing to hand off, but a stream
      // that was still opening locally must not start playing on the
      // phone now that a session is connected.
      unawaited(manager.enforceNoLocalAudioWhileCasting());
      return;
    }

    // Live TV/channels don't have a meaningful "position" to hand off,
    // and Jellyfin Remote/Google Cast sessions loading a live channel
    // URL the same way a VOD item loads is untested territory this phase
    // didn't have a real device to validate against — deferred rather
    // than guessed at. Local live playback is paused rather than left
    // running: phone audio must never play while a session is connected.
    if (localItem.live) {
      unawaited(manager.enforceNoLocalAudioWhileCasting());
      return;
    }

    // The corrected, real-timeline position — never the transcode-
    // relative `player.state.position` directly (see PlayerManager's own
    // `_absolutePosition` doc comment on why raw stream position can
    // read as "9 seconds into this transcode" rather than the item's
    // actual position for a StartTimeTicks-based reopen).
    final localPosition = manager.position.value;
    final wasPlaying = manager.playing.value;

    // Music (and any audio) cast from this phone starts over on the TV;
    // only video carries the phone's position across.
    final castStartAt = localItem.audioOnly ? Duration.zero : localPosition;

    // Pause (not stop): `stop()` tears down PlaybackQueue/currentItem
    // entirely, which would also collapse the mini player / video
    // screen's own state out from under it. Pausing leaves everything
    // exactly where it was, ready for a clean REMOTE → LOCAL resume if
    // the cast session ends shortly after, or for the person to just
    // back out of the player if they don't want that.
    if (wasPlaying) {
      await manager.player.pause();
    }

    isHandoffActive.value = true;

    // Auto quality has nothing useful left to do once the stream it'd
    // be adjusting is paused and handed off to a TV — see
    // PlayerManager.suspendAdaptiveQualityForCast's own doc comment for
    // why this needs to be an explicit suspend rather than just leaving
    // it running against a paused player.
    manager.suspendAdaptiveQualityForCast();

    // CASTING FIX (next/previous didn't work): sending only the single
    // current item via loadAndPlay() left the receiver with no queue of
    // its own — Google Cast's next()/previous() only ever become
    // reachable once a real queueLoadItems() call has happened (see
    // GoogleCastTransport's own capability doc comment), and Jellyfin
    // Remote/Nemesis Native's NextTrack/PreviousTrack commands have
    // nothing to advance through if the session was only ever told
    // about one ItemId. For audio, hand off the *whole* local
    // PlaybackQueue instead — same startIndex/position, but now next/
    // previous/shuffle/repeat on the TV actually have a real queue to
    // act on, matching what the Now Playing screen already let you do
    // locally.
    //
    // CASTING FIX (next/previous EPISODE didn't work): this used to stay
    // audio-only, on the assumption video would need its own, bigger
    // product decision (see this class's own top-level doc comment) —
    // but an episode's local PlaybackQueue is already populated with the
    // full season (EpisodeRow/EpisodeList's onTap sets `source:
    // PlaybackSource.season` before ever calling this), so the exact
    // same "hand off the whole queue instead of one item" fix applies
    // just as directly here. The Jellyfin Remote / Nemesis Native
    // transports that used to take this video path no longer exist, so
    // video keeps single-item behavior on Google Cast and DLNA; only
    // audio hands off the whole queue.
    final localQueue = PlaybackQueue.instance;
    final useFullQueue = localItem.audioOnly &&
        localQueue.current?.id == localItem.id &&
        localQueue.items.length > 1;

    // CASTING FIX (OpenSubtitles/Open-With/downloaded sidecar subtitles
    // invisible on the TV): a subtitle active on the phone right now that
    // only exists as raw text in this app's own memory — an OpenSubtitles
    // search result, a downloaded movie/episode's own saved sidecar, or a
    // same-named .srt/.vtt sidecar an Open With/Play With file was opened
    // with (auto-selected by
    // PlayerManager._reapplyCachedSubtitleIfAny) — used to have
    // "genuinely nothing to carry over" on handoff: none of those have a
    // server-side stream index or hosted URL a Cast receiver could ever
    // load (see this function's own comment on that, just below). Now
    // that [LocalCastServer] can serve raw text over plain HTTP the same
    // way it already serves a local video/song file and its artwork
    // (`CastManager._ensureCastableLocalItem`), registering it here gives
    // it a real url this receiver can fetch, turning it into an ordinary
    // sidecar text track exactly like a Jellyfin one.
    //
    // Deliberately done *before* `loadAndPlay`/`playQueue` below, and
    // stashed onto `localItem.raw` by mutating it in place — not a
    // copy — since that's the exact same MediaItem instance about to be
    // handed to `GoogleCastTransport._subtitleTracksFor` (via
    // `CastManager._ensureCastableLocalItem`/`_ensureFullMediaItem`), so
    // the track is declared right from the initial `load()`/
    // `queueLoadItems()` call rather than bolted on after — the same
    // timing a Jellyfin-backed default subtitle already gets. Every
    // `MediaItem` this app builds for a playable item always carries a
    // `raw` map (Jellyfin items get their real server JSON;
    // ExternalMediaHandler/LocalMusicService build a synthetic one for
    // anything without a server-side item — see MediaItem's own doc
    // comment) — the null check below is only ever a defensive
    // no-registration fallback, not an expected path in practice.
    //
    // Covers both raw-text-in-memory tracks (`subtitleData` — OpenSubtitles
    // downloads and Open With/Play With sidecars) and a downloaded movie/
    // episode's own subtitle sidecar (`localPath` — a plain file already
    // sitting on this device, read straight off disk here exactly the way
    // PlayerManager.selectSubtitleTrack already does for local playback).
    // A real Jellyfin-backed track (neither field set) is handled the
    // existing way, just below inside the try block, since it already has
    // everything it needs (a real stream index Jellyfin's own MediaStreams
    // already describes) without going through LocalCastServer at all.
    final subtitleToCarry = manager.selectedSubtitle.value;
    if (subtitleToCarry != null && localItem.raw != null) {
      String? rawContent = subtitleToCarry.subtitleData;
      if (rawContent == null && subtitleToCarry.localPath != null) {
        try {
          rawContent = SubtitleText.decode(
              await File(subtitleToCarry.localPath!).readAsBytes());
        } catch (e) {
          debugPrint(
            'CASTING DEBUG: failed to read local subtitle sidecar '
            '${subtitleToCarry.localPath} for cast handoff: $e',
          );
        }
      }

      if (rawContent != null && rawContent.trim().isNotEmpty) {
        try {
          final url = await LocalCastServer.instance.registerSubtitleText(
            title: localItem.title,
            content: rawContent,
          );
          if (url != null) {
            localItem.raw!['CastSidecarSubtitleUrl'] = url.toString();
            localItem.raw!['CastSidecarSubtitleName'] =
                subtitleToCarry.displayTitle;
            // SUBTITLE ACTIVATION FIX: bake activation into this very
            // first load() instead of relying only on the follow-up
            // `selectSubtitleTrack(kLocalCastSubtitleTrackId)` call
            // further down — see GoogleCastTransport
            // ._defaultSubtitleTrackId's `CastActiveSubtitleId` doc
            // comment for why that follow-up alone can race the
            // receiver and silently do nothing.
            localItem.raw!['CastActiveSubtitleId'] = kLocalCastSubtitleTrackId;
          }
        } catch (e) {
          // Best-effort, same as every other optional cast fixup in this
          // class — a subtitle that fails to register shouldn't block the
          // handoff itself; `_subtitleTracksFor` simply has nothing to
          // declare for it, same as before this fix existed.
          debugPrint(
            'CASTING DEBUG: failed to register local subtitle for cast '
            'handoff: $e',
          );
        }
      }
    }

    // LOCAL VIDEO CAST TRACKS: declare every text subtitle on the phone to
    // the TV up front, not just the selected one — see
    // _prepareLocalCastTracks.
    await _prepareLocalCastTracks(session, localItem);

    // DEFAULT SUBTITLE: a fresh cast starts on the title's default
    // subtitle (CastManager does that), but a handoff must keep what the
    // person chose on the phone instead — "Off" stays off on the TV, and a
    // server track picked locally is the one that starts showing.
    final handoffSubtitle = manager.selectedSubtitle.value;
    final handoffSubtitleOff =
        handoffSubtitle == null && manager.subtitlesTurnedOffByUser;
    final carriesSubtitleChoice = handoffSubtitle != null || handoffSubtitleOff;
    if (carriesSubtitleChoice) {
      final handoffRaws = <Map<String, dynamic>>[
        if (localItem.raw != null) localItem.raw!,
        if (localQueue.current?.id == localItem.id &&
            localQueue.current?.raw != null &&
            !identical(localQueue.current!.raw, localItem.raw))
          localQueue.current!.raw!,
      ];
      for (final raw in handoffRaws) {
        if (handoffSubtitleOff) {
          raw[kCastSubtitlesOffHint] = true;
          raw.remove(kCastActiveSubtitleHint);
        } else {
          raw.remove(kCastSubtitlesOffHint);
          // A real server track picked on the phone (its index is the
          // Jellyfin stream index): have the TV start on it directly. The
          // raw-text / sidecar cases already stamped their own hint above.
          if (!localItem.isLocal &&
              handoffSubtitle!.subtitleData == null &&
              handoffSubtitle.localPath == null &&
              handoffSubtitle.index >= 0) {
            raw[kCastActiveSubtitleHint] = handoffSubtitle.index;
          }
        }
      }
    }

    // PHASE 1 (one load per tap): the tap that caused this connection (or
    // any later one) may already have loaded ITS item on the session while
    // this handoff was preparing. Loading the older, phone-side item now
    // would overwrite the one the person just chose — and leave the phone's
    // state, the queue and the TV describing different items.
    if (CastManager.instance.loadSeq != seqAtConnect) {
      debugPrint(
        'CASTING DEBUG: handoff of "${localItem.title}" skipped — another '
        'load was requested on this session first',
      );
      isHandoffActive.value = false;
      _stopLocalCastTrackSync();
      return;
    }
    final expectedSeq = CastManager.instance.loadSeq + 1;

    try {
      if (useFullQueue) {
        await CastManager.instance.playQueue(
          localQueue.items,
          startIndex: localQueue.currentIndex,
          startAt: castStartAt,
          manualSubtitleItemId: carriesSubtitleChoice ? localItem.id : null,
        );
      } else {
        await CastManager.instance.loadAndPlay(
          localItem,
          startAt: castStartAt,
          autoSubtitle: !carriesSubtitleChoice,
        );
      }

      // An explicit cast of another title took over while this hand-off was
      // still loading: the TV now belongs to that title. Don't start
      // mirroring (or re-selecting subtitles for) the abandoned item.
      //
      // PHASE 2 (F2.4): the load itself may have swapped this session for
      // its DLNA twin (a local file on a Jellyfin / Native session) — that
      // is the same connection continuing, not a different one taking over.
      final liveSession = CastManager.instance.liveSessionFor(session);
      if (epoch != _handoffEpoch ||
          CastManager.instance.loadSeq != expectedSeq ||
          liveSession == null) {
        isHandoffActive.value = false;
        _stopLocalCastTrackSync();
        return;
      }

      // CASTING FIX (selected subtitle lost on handoff): a subtitle
      // active on the phone right before this handoff used to just get
      // dropped — `loadAndPlay()`/`playQueue()` above only carry the
      // item itself, never whatever subtitle selection went with it, so
      // the TV always started back at Jellyfin's own "default" subtitle
      // flag (or nothing) regardless of what the person had actually
      // picked locally. Re-applies that same selection to the fresh
      // session right after it loads.
      //
      // Only for a real Jellyfin-backed track (`subtitleData == null`):
      // both server subtitles and OpenSubtitles downloads show up here
      // as `SubtitleTrack`s, but an OpenSubtitles one only ever exists
      // as raw text sitting in this app's own memory
      // (`SubtitleTrack.subtitleData`) — there's no server-side stream
      // index or hosted URL a TV could ever load for it, so there's
      // genuinely nothing to carry over for that case (the same reason
      // `SubtitleSheet` already hides its own "Search online" entry
      // entirely while casting, rather than offering a control that
      // can't work).
      //
      // Best-effort, same as every other optional cast fixup in this
      // class: swallows failure (session/target doesn't support
      // subtitle switching, or this particular track isn't one the
      // receiver can render — e.g. Google Cast skipping image-based
      // PGS/VobSub tracks entirely, see GoogleCastTransport
      // `_subtitleTracksFor`'s own doc comment) rather than failing a
      // handoff that already otherwise succeeded.
      final localSubtitle = manager.selectedSubtitle.value;
      if (localSubtitle != null && localSubtitle.subtitleData == null) {
        try {
          await CastManager.instance.selectSubtitleTrack(localSubtitle.index);
        } catch (_) {
          // Not supported by this session/target — leave the TV on
          // whatever load()/loadQueue() itself already selected.
        }
      } else if (localItem.raw?['CastSidecarSubtitleUrl'] != null) {
        // CASTING FIX (OpenSubtitles/Open-With/downloaded sidecar
        // subtitles invisible on the TV), continued from this function's
        // pre-load registration above: a raw-text track was successfully
        // registered with LocalCastServer and is now declared under the
        // shared [kLocalCastSubtitleTrackId] both
        // `GoogleCastTransport._subtitleTracksFor` and this select call
        // agree on — `localSubtitle.index` above was never a real Cast
        // trackId for one of these to begin with, so this needs its own
        // explicit id rather than reusing that branch.
        try {
          await CastManager.instance
              .selectSubtitleTrack(kLocalCastSubtitleTrackId);
        } catch (_) {
          // Same as above — not supported by this session/target.
        }
      }

      // LOCAL VIDEO CAST TRACKS: from here on, subtitle picks (including
      // fresh OpenSubtitles downloads) and audio-track picks made on the
      // phone are mirrored to the TV — see _startLocalCastTrackSync.
      await _startLocalCastTrackSync(liveSession, localItem);

      // CASTING FIX (double audio / stale controls): from this point on,
      // the mini player / song rows / AudioPlayerScreen / OS media
      // session should reflect the *session's* playback, not local's
      // (which is sitting paused for the rest of the handoff) — without
      // this, `playing` stayed permanently false the whole time
      // something was actually playing on the TV, so every "currently
      // playing" indicator in the app showed paused throughout a
      // perfectly healthy cast session.
      if (localItem.audioOnly) {
        _mirroringAudio = true;
        manager.beginCastMirror(localItem);
      }
    } catch (e) {
      // Load failed on the receiver end — hand control back to local
      // playback rather than leaving the person stuck looking at a
      // "casting" panel for a session that never actually started
      // playing anything. CastManager itself already reflects the
      // failure via the session's own error state (see connect()'s
      // catch block) for the connected-session sheet to show; this only
      // undoes the local side of the handoff.
      //
      // NO LOCAL AUDIO WHILE CASTING: this used to resume local mpv here
      // (`if (wasPlaying) player.play()`), which put the same title back
      // on the phone while the session was still connected. Local stays
      // paused; the failure is reported below and the person can retry
      // the cast or disconnect to resume on this device.
      isHandoffActive.value = false;
      _stopLocalCastTrackSync();
      if (!CastManager.instance.isCasting) {
        manager.resumeAdaptiveQualityAfterCast();
      }

      // CASTING FIX: a local-only song (LocalMusicService) or Open
      // With/Play With file (ExternalMediaHandler) — see
      // MediaItem.isLocal/castStreamUrl — used to always fail here, on
      // every transport, since nothing gave it a network-reachable URL
      // at all. LocalCastServer (see CastManager._ensureCastableLocalItem)
      // now makes that actually work in the common case, so a failure
      // here for a local item is no longer a given — it's a specific
      // reason (an unsupported format with no server around to
      // transcode it, the LAN address couldn't be determined, the
      // openContentFd native bridge isn't wired up yet) that
      // LocalCastUnsupportedException already carries a clear,
      // user-facing message for. Falling back to the old generic
      // message only for whatever's left — a genuinely unexpected
      // exception this wasn't written to anticipate.
      _showCastFailureMessage(
        _castFailureText(
          e,
          localItem.title,
          deviceName: session.device.displayName,
        ),
      );
    }
  }

  void _showCastFailureMessage(String message) {
    final context = ExternalMediaHandler.instance.navigatorKey.currentContext;
    if (context == null) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text(message),
      ),
    );
  }

  // -----------------------------------------------------------------
  // MID-SESSION REDIRECT (new song picked while already casting)
  // -----------------------------------------------------------------

  /// CASTING FIX: called by [PlaybackService] instead of opening local
  /// playback whenever a freshly-picked *audio* queue (tapping a song,
  /// album, or playlist anywhere in the app) coincides with an already-
  /// connected cast session — so picking something new while casting
  /// keeps it on the TV instead of starting a second, local playback of
  /// the same or a different song. Scoped to audio only, matching every
  /// other casting fix in this file; video Play buttons elsewhere in the
  /// app remain the pre-existing, deliberately-unaddressed behavior (see
  /// this class's own top-level doc comment on why that's a separate,
  /// bigger product decision).
  ///
  /// Returns true if the queue was sent to the TV, or if sending it
  /// failed while the cast session is still connected (the failure is
  /// reported to the person instead) — in both cases the caller must
  /// not start local playback, since the TV is the only place playback
  /// belongs while a session is live. Returns false (no side effects
  /// beyond whatever PlaybackQueue.setQueue already always does) only
  /// if nothing is actually connected, or if the session was lost
  /// during the send — the caller falls back to normal local playback
  /// so the tap still does something.
  Future<bool> playAudioQueueOnActiveCast(
    List<MediaItem> allItems, {
    int startIndex = 0,
    PlaybackSource source = PlaybackSource.unknown,
    String? title,
    String? artwork,
  }) async {
    if (allItems.isEmpty) return false;
    if (!CastManager.instance.isCasting) {
      // DEBUG (tap-to-redirect investigation): if this ever prints while
      // the cast panel/mini player clearly show an active session, the
      // bug is in CastManager.isCasting's own state, not in whichever
      // screen called this.
      debugPrint(
        'CASTING DEBUG: playAudioQueueOnActiveCast bailed — '
        'CastManager.instance.isCasting was false.',
      );
      return false;
    }

    // ROOT CAUSE (songs tapped in Favorites — a list that mixes server
    // songs and "On This Device" songs — failed to cast to a Jellyfin
    // Remote / Nemesis Native target): those two transports only send
    // Jellyfin item ids, which a local file doesn't have, and their
    // loadQueue() throws for the WHOLE queue if even one item in it is
    // local. So a server song tapped in a mixed list failed just because
    // some other favorite in the same list lives on the phone, and a
    // tapped local song failed too (with no clear reason). Only Google
    // Cast can play local files (LocalCastServer serves them over HTTP).
    //
    // For any other transport: a tapped local song is refused up front
    // with a notification (nothing is sent, and the TV keeps playing
    // whatever it had); a tapped server song is cast with the local
    // songs left out of the queue it's sent. Returns true either way so
    // the caller does NOT fall back to playing it on the phone.
    var items = allItems;
    var queueStart = startIndex.clamp(0, allItems.length - 1);
    var targetKind = CastManager.instance.activeSession.value?.transportKind;
    // PHASE 2 (F2.4): a local song on a Jellyfin / Native session no longer
    // asks the person to disconnect and reconnect — when the TV also answers
    // as a DLNA renderer the session is switched to that by itself, keeping
    // the queue and the mini player.
    if (!(targetKind?.switchesTracksByReload ?? false) &&
        allItems[queueStart].isLocal) {
      await CastManager.instance.ensureLocalCapableSession();
      if (!CastManager.instance.isCasting) return false;
      targetKind = CastManager.instance.activeSession.value?.transportKind;
    }
    // Google Cast and DLNA can both play files this phone serves itself
    // (LocalCastServer); Jellyfin Remote / Nemesis Native cannot.
    if (!(targetKind?.switchesTracksByReload ?? false) &&
        allItems.any((i) => i.isLocal)) {
      final tapped = allItems[queueStart];
      if (tapped.isLocal) {
        // A local song tapped from a screen that had nothing playing yet
        // was already given a loading preview + full player screen by the
        // caller; nothing will ever replace that preview now, so clear it
        // (the audio player screen closes itself once the item is null).
        final manager = PlayerManager.instance;
        if (manager.loading.value &&
            manager.currentItem?.id == tapped.id &&
            PlaybackQueue.instance.current?.id != tapped.id) {
          manager.loading.value = false;
          manager.currentItemNotifier.value = null;
        }
        _showCastFailureMessage(
          '"${tapped.title}" is stored on this device, and this TV can only '
          'play it over Google Cast or DLNA — it doesn\'t offer either '
          '(or its DLNA connection failed), so it can\'t be cast to it.',
        );
        return true;
      }
      items = allItems.where((i) => !i.isLocal).toList();
      queueStart = items.indexWhere((i) => identical(i, tapped));
      if (queueStart < 0) queueStart = 0;
    }
    startIndex = queueStart;

    PlaybackQueue.instance.setQueue(
      items,
      startIndex: startIndex,
      source: source,
      title: title,
      artwork: artwork,
    );

    final manager = PlayerManager.instance;
    final item = items[startIndex.clamp(0, items.length - 1)];

    // Local mpv is left completely alone — paused if it happened to be
    // playing something else already (matches the connect-time handoff's
    // own "pause, never stop" reasoning: PlaybackQueue/currentItem stay
    // intact for a clean fallback if casting ends), never opened fresh
    // for this new pick, so there is no local audio blip at all.
    if (manager.playing.value) {
      unawaited(manager.player.pause());
    }
    manager.suspendAdaptiveQualityForCast();

    isHandoffActive.value = true;
    _mirroringAudio = true;
    manager.beginCastMirror(item);

    try {
      debugPrint(
        'CASTING DEBUG: sending ${items.length} item(s) to '
        '${CastManager.instance.activeSession.value?.transportKind} — '
        'startIndex=$startIndex, tapped item="${item.title}" '
        '(isLocal=${item.isLocal}, audioOnly=${item.audioOnly})',
      );
      await CastManager.instance.playQueue(items, startIndex: startIndex);
      return true;
    } catch (e, st) {
      // DEBUG (tap-to-redirect investigation): this used to swallow the
      // real reason a redirect failed — every failure silently fell back
      // to local playback with zero explanation unless the item happened
      // to be a local file. Logging it here is the fastest way to tell
      // "session doesn't support queueing this many items", "a field the
      // transport needed was missing from this particular queue", and an
      // actual local-file miss apart from each other.
      debugPrint('CASTING DEBUG: playAudioQueueOnActiveCast failed: $e');
      debugPrint('CASTING DEBUG: stack: $st');

      // FAILED-SONG-ON-PHONE FIX: a failure here used to always return
      // false, and PlaybackService then started the same song on the
      // phone -- even when the failure was only a late load timeout (the
      // TV had already skipped to the next song) or when the person had
      // since tapped something else that is now playing on the TV. If
      // the session is still connected, the TV is the only place
      // playback belongs: report the failure, leave the mirror and
      // session state alone (they follow what the TV really plays), and
      // return true so the caller does NOT fall back to local playback.
      if (CastManager.instance.isCasting) {
        _showCastFailureMessage(_castFailureText(e, item.title));
        return true;
      }

      manager.endCastMirror();
      _mirroringAudio = false;
      isHandoffActive.value = false;
      manager.resumeAdaptiveQualityAfterCast();

      if (item.isLocal) {
        _showCastFailureMessage(
          e is LocalCastUnsupportedException
              ? e.message
              : '"${item.title}" couldn\'t be cast — playing it on this '
                  'device instead.',
        );
      }
      return false;
    }
  }

  // -----------------------------------------------------------------
  // LOCAL VIDEO CAST: AUDIO + SUBTITLE TRACKS (Open With / Play With)
  // -----------------------------------------------------------------
  //
  // Movies/episodes get audio + subtitle switching on the TV for free from
  // Jellyfin (server MediaStreams + Stream.vtt). A local file opened via
  // Open With/Play With has none of that, so this does what VLC's Cast
  // does, on the phone:
  //
  //  - SUBTITLES: every text subtitle the phone has (sidecar files from the
  //    same folder, OpenSubtitles downloads) is served by LocalCastServer
  //    as WebVTT and declared to the receiver at load, so picking one is a
  //    plain setActiveTrackIDs. A subtitle that shows up AFTER load (a
  //    fresh OpenSubtitles download) can't be added to media the receiver
  //    already has, so that one case reloads the stream at the current
  //    position with the new track declared.
  //  - AUDIO: the Default Media Receiver can't switch audio streams inside
  //    a progressive file, so the chosen track is remuxed into a new MPEG-TS
  //    on the phone (LocalVideoTranscodeService.remuxToMpegTsWithAudio) and
  //    the TV is reloaded with it at the current position.
  //
  // Picks are made through the normal local PlayerManager selection (mpv is
  // still holding the file, paused, during a handoff) so the phone's own
  // state stays right for when local playback resumes; this class just
  // mirrors them to the TV. Google Cast only, and only for a genuine
  // LOCAL -> REMOTE handoff (mpv has the file to list tracks from).

  MediaItem? _localCastItem;
  final Map<int, int> _localSubCastIds = {};
  int _nextLocalSubCastId = kLocalCastSubtitleTrackId + 1;
  final Map<int, String> _localAudioUrls = {};
  /// The audio track index this coordinator has itself put on the TV, or
  /// null while the TV is still on whatever the receiver picked by
  /// default when the file was first handed over. It used to start at 0
  /// on the assumption the receiver always plays the file's first audio
  /// stream — but the Default Media Receiver chooses its own default for
  /// a multi-audio MP4/MKV, so picking "track 1" (index 0) on the phone
  /// when the TV was actually on another track hit the same-index
  /// shortcut in [switchLocalCastAudio], updated only the phone's paused
  /// mpv and never touched the TV.
  int? _localAudioIndex;
  VoidCallback? _localSubtitleListener;

  /// Bumped every time this coordinator starts or stops owning a local video
  /// cast ([_localCastItem] set / cleared).
  ///
  /// ROOT CAUSE (Audio button greyed out / wrong branch while casting an
  /// Open With/Play With video): [isLocalVideoCast] is plain state, not a
  /// notifier, and the bottom bar only rebuilt on `activeSession` changes.
  /// The session is published BEFORE this coordinator has declared the video
  /// local (handoff: [_prepareLocalCastTracks] runs after the session
  /// appears), so the bar made its "is this a local cast?" decision once, too
  /// early, and kept it — falling into the Jellyfin branch whose Audio
  /// button is disabled for local items (the transport sets
  /// `audioTrackSelection: false` for them). The bar now also listens to this.
  final ValueNotifier<int> localCastRevision = ValueNotifier<int>(0);

  /// True when the current local video cast was started on an
  /// ALREADY-CONNECTED session (see [prepareExternalVideoForActiveCast]) —
  /// local mpv never opened the file, so its audio tracks are meaningless
  /// and PlayerManager.castOnlySubtitles is set for the duration.
  bool _localCastDirect = false;

  /// Delayed copies of local-cast subtitle tracks, keyed by the ORIGINAL
  /// track's Cast id — see [setLocalCastSubtitleDelay].
  final Map<int, _LocalCastDelayVariant> _localDelayVariants = {};
  int _nextLocalDelayVariantId = kLocalCastSubtitleTrackId + 1000;
  Future<void> _localTrackOps = Future<void>.value();
  static const Duration _localTrackOpTimeout = Duration(minutes: 6);

  /// True while a Google Cast session is playing an Open With/Play With
  /// video this coordinator handed off (so the Audio/Subtitles buttons
  /// should list the PHONE's tracks instead of Jellyfin's).
  bool get isLocalVideoCast {
    final local = _localCastItem;
    final session = CastManager.instance.activeSession.value;
    if (local == null || session == null) return false;
    if (!session.isConnected || !session.transportKind.switchesTracksByReload) {
      return false;
    }
    // ROOT CAUSE (Subtitles sheet dead during Open With/Play With
    // casting): this used to require `currentItem.id == local.id`
    // outright. GoogleCastTransport._applyMediaStatus sets
    // `session.currentItem` to null whenever the receiver reports "no
    // media status" outside the post-load settle window (a track
    // reload, the TV app hiccuping) — during exactly that window this
    // returned false, so the sheet fell through to the *Jellyfin*
    // branch, which sends this phone's own (negative / mpv) subtitle
    // indices straight to the receiver as Cast trackIds: nothing
    // matches on the TV, and the checkmark logic keyed off a different
    // notifier, so it looked like taps did nothing. A null current item
    // still means "this coordinator's local video is the session"; only
    // a DIFFERENT item (something else was cast over it) ends it.
    final current = session.currentItem.value;
    return current == null || current.id == local.id;
  }

  /// The local [SubtitleTrack.index] currently active on the TV, for the
  /// Subtitles sheet's checkmark (null = off/unknown).
  int? subtitleIndexForCastId(int? castId) {
    if (castId == null) return null;
    for (final entry in _localSubCastIds.entries) {
      if (entry.value == castId) return entry.key;
    }
    return null;
  }

  /// Subtitles the phone can actually serve to a TV — raw text in memory
  /// or a file on disk. mpv-embedded tracks have neither, so they stay
  /// local-only.
  static bool isCastableLocalSubtitle(SubtitleTrack t) =>
      (t.subtitleData != null && t.subtitleData!.trim().isNotEmpty) ||
      t.localPath != null;

  Future<String?> _subtitleText(SubtitleTrack t) async {
    final data = t.subtitleData;
    if (data != null && data.trim().isNotEmpty) return data;
    final path = t.localPath;
    if (path != null) {
      try {
        // SIDECAR FIX: bytes + decode (BOM / UTF-16 / legacy code pages)
        // instead of readAsString(), which threw on non-UTF-8 files.
        final text = SubtitleText.decode(await File(path).readAsBytes());
        if (text.trim().isNotEmpty) return text;
      } catch (e) {
        debugPrint('CASTING DEBUG: failed to read subtitle file $path: $e');
      }
    }
    return null;
  }

  /// Runs local-cast track operations one at a time — a quick second tap
  /// mustn't start a second reload while the first is still in flight.
  Future<void> _enqueueLocalTrackOp(Future<void> Function() op) {
    final done = Completer<void>();
    _localTrackOps = _localTrackOps.then((_) async {
      try {
        // Bounded, so one hung reload can't leave every later
        // subtitle/audio pick queued behind it forever.
        await op().timeout(_localTrackOpTimeout);
        done.complete();
      } catch (e, st) {
        done.completeError(e, st);
      }
    });
    return done.future;
  }

  /// Runs BEFORE the handoff `load()`: registers every castable phone
  /// subtitle other than the already-registered selected one and stashes
  /// them on `localItem.raw` (mutated in place — the same map
  /// GoogleCastTransport._subtitleTracksFor reads, see the handoff's own
  /// comment on why that works) so they're declared in the very first
  /// load.
  Future<void> _prepareLocalCastTracks(
    CastSession session,
    MediaItem localItem,
  ) async {
    _stopLocalCastTrackSync();

    if (!session.transportKind.switchesTracksByReload) return;
    if (!localItem.isLocal || localItem.audioOnly || localItem.live) return;
    final raw = localItem.raw;
    if (raw == null) return;

    final manager = PlayerManager.instance;
    _localCastItem = localItem;
    localCastRevision.value++;
    raw.remove('CastLocalSubtitles');
    raw.remove('CastLocalRemuxedTs');

    // The selected subtitle was registered by the handoff just above under
    // the shared id (kLocalCastSubtitleTrackId) when it had castable text.
    final selected = manager.selectedSubtitle.value;
    if (selected != null && raw['CastSidecarSubtitleUrl'] != null) {
      _localSubCastIds[selected.index] = kLocalCastSubtitleTrackId;
    }

    final extra = <Map<String, dynamic>>[];
    for (final track in manager.subtitles.value) {
      if (_localSubCastIds.containsKey(track.index)) continue;
      if (!isCastableLocalSubtitle(track)) continue;

      final text = await _subtitleText(track);
      if (text == null) continue;

      final url = await LocalCastServer.instance.registerSubtitleText(
        title: localItem.title,
        content: text,
      );
      if (url == null) continue;

      final id = _nextLocalSubCastId++;
      _localSubCastIds[track.index] = id;
      extra.add({'id': id, 'url': url.toString(), 'name': track.displayTitle});
    }
    if (extra.isNotEmpty) raw['CastLocalSubtitles'] = extra;
  }

  /// Runs AFTER a successful handoff load: remembers the original stream
  /// URL (so switching back to the first audio track needs no new remux),
  /// starts mirroring phone subtitle picks to the TV, and re-applies a
  /// non-default audio track that was already selected on the phone.
  Future<void> _startLocalCastTrackSync(
    CastSession session,
    MediaItem localItem, {
    bool syncAudio = true,
  }) async {
    if (_localCastItem == null || _localCastItem!.id != localItem.id) return;

    final manager = PlayerManager.instance;
    // The original (direct) stream plays whichever audio track the
    // receiver defaults to — NOT necessarily track 0 — so it is never
    // registered as a reusable "track 0" URL and the TV's current index
    // stays unknown until an audio track is explicitly forced.
    _localAudioIndex = null;
    _localAudioUrls.clear();

    void onSubtitleChanged() {
      unawaited(
        _enqueueLocalTrackOp(_syncLocalSubtitleToCast).catchError((_) {}),
      );
    }

    _localSubtitleListener = onSubtitleChanged;
    manager.selectedSubtitle.addListener(onSubtitleChanged);

    // HANDOFF AUDIO LIST (open locally, then connect): normally mpv's own
    // track list is already there; if it never shows up the Audio button
    // stays greyed out for the whole cast, so fall back to a header probe.
    if (!_localCastDirect) {
      unawaited(_ensureHandoffAudioTracks(localItem));
    }

    final audio = manager.selectedAudio.value;
    if (syncAudio && audio != null && audio.index > 0) {
      try {
        await switchLocalCastAudio(audio, showProgress: false);
      } catch (e) {
        debugPrint('CASTING DEBUG: initial audio track switch failed: $e');
      }
    }
  }

  void _stopLocalCastTrackSync() {
    final hadLocalCast = _localCastItem != null;
    final listener = _localSubtitleListener;
    if (listener != null) {
      PlayerManager.instance.selectedSubtitle.removeListener(listener);
    }
    _localSubtitleListener = null;
    _localCastItem = null;
    if (_localCastDirect) {
      _localCastDirect = false;
      PlayerManager.instance.castOnlySubtitles = false;
    }
    _localDelayVariants.clear();
    _nextLocalDelayVariantId = kLocalCastSubtitleTrackId + 1000;
    _localSubCastIds.clear();
    _nextLocalSubCastId = kLocalCastSubtitleTrackId + 1;
    _localAudioUrls.clear();
    _localAudioIndex = null;
    if (hadLocalCast) localCastRevision.value++;
  }

  /// Called by the Subtitles sheet while a local video is being cast, in
  /// place of a bare `PlayerManager.selectSubtitleTrack`.
  ///
  /// ROOT CAUSE (tapping a subtitle did nothing on the TV / never showed
  /// as picked): the TV sync used to hang entirely off
  /// `PlayerManager.selectedSubtitle`'s listener, and a ValueNotifier only
  /// notifies when the value actually CHANGES. The first sidecar of an
  /// Open With file is auto-selected locally before the handoff — so if
  /// it never rendered on the TV (see LocalCastServer's CORS fix) the
  /// only obvious retry, tapping that same track again, changed nothing
  /// locally, fired no listener and sent nothing to the TV. This picks
  /// locally as before, then — only when the local value did NOT change
  /// (so the listener stayed silent) — forces the same TV sync itself.
  /// When the value did change the listener already queued the sync and
  /// a second one here would just be a redundant round-trip.
  Future<void> selectLocalCastSubtitle(SubtitleTrack? track) async {
    final manager = PlayerManager.instance;
    final before = manager.selectedSubtitle.value;
    final willChange = before?.index != track?.index;

    // INSTANT TICK: with the file open in the phone's paused mpv
    // (handoff), `selectSubtitleTrack` only records the pick AFTER mpv has
    // finished loading the subtitle, so the sheet's checkmark (and the TV
    // mirror, which hangs off this same notifier) lagged behind the tap.
    // The TV is fed from the subtitle text, never from mpv, so the pick is
    // recorded first and mpv catches up afterwards.
    if (willChange) manager.selectedSubtitle.value = track;

    try {
      await manager.selectSubtitleTrack(track);
    } catch (_) {
      // mpv couldn't load it: put the previous pick back (this also moves
      // the TV back) and let the sheet show its usual error.
      if (willChange && manager.selectedSubtitle.value?.index == track?.index) {
        manager.selectedSubtitle.value = before;
      }
      rethrow;
    }

    final changed = willChange;
    if (!changed && isLocalVideoCast) {
      unawaited(
        _enqueueLocalTrackOp(() => _syncLocalSubtitleToCast(force: true))
            .catchError((_) {}),
      );
    }
  }

  /// Puts [activateId] (a Cast track id already declared on the TV for this
  /// video; null = subtitles off) on screen by reloading the video at its
  /// current position with that track activated inside the load request —
  /// see _syncLocalSubtitleToCast for why a bare setActiveTrackIDs isn't
  /// relied on here. The "activate on next load" hint is updated on every
  /// raw map the reload can read (the cast item and the phone's item can
  /// be different instances) and put back if the reload fails.
  ///
  /// Falls back to the plain track switch only when the item carries no
  /// receiver-reachable stream URL to reload with (nothing to re-send).
  Future<void> _applyLocalCastSubtitle(
    CastSession session,
    MediaItem item, {
    required int? activateId,
  }) async {
    final base = session.currentItem.value ?? item;
    final rawMaps = _castRawMaps(session, item);
    final previousActive = [
      for (final raw in rawMaps) raw['CastActiveSubtitleId'],
    ];

    for (final raw in rawMaps) {
      if (activateId == null) {
        raw.remove('CastActiveSubtitleId');
      } else {
        raw['CastActiveSubtitleId'] = activateId;
      }
    }

    try {
      if (base.castStreamUrl == null) {
        if (session.capability.subtitleTrackSelection) {
          await CastManager.instance.selectSubtitleTrack(activateId ?? -1);
        }
        return;
      }

      await CastManager.instance.reloadResolvedItem(base);
      // load() only writes this when something is activated, so Off has to
      // record itself — otherwise tapping the previously active track again
      // would look "already active" and be skipped.
      session.activeSubtitleTrackId.value = activateId ?? -1;
    } catch (e) {
      for (var i = 0; i < rawMaps.length; i++) {
        final previous = previousActive[i];
        if (previous == null) {
          rawMaps[i].remove('CastActiveSubtitleId');
        } else {
          rawMaps[i]['CastActiveSubtitleId'] = previous;
        }
      }
      debugPrint('CASTING DEBUG: local cast subtitle switch failed: $e');
      _showCastFailureMessage('Couldn\'t switch subtitles on the TV.');
    }
  }

  /// Mirrors the phone's currently selected subtitle onto the TV.
  ///
  /// [force] re-sends the pick even if the session already claims that
  /// track is active (the session's value is set optimistically, so it can
  /// say "active" while the receiver never actually rendered it).
  Future<void> _syncLocalSubtitleToCast({bool force = false}) async {
    final item = _localCastItem;
    final session = CastManager.instance.activeSession.value;
    if (item == null || session == null || !isLocalVideoCast) return;

    final sub = PlayerManager.instance.selectedSubtitle.value;

    try {
      // ROOT CAUSE (Off did nothing / only the first subtitle ever showed,
      // Open With/Play With over Google Cast): the one subtitle that works
      // is the one activated by the load() request itself
      // (`activeTrackIds`). Every later change used to rely on a bare
      // `setActiveTrackIDs` call to the receiver, and on these local-file
      // casts that call was silently not taking effect — Off left the
      // subtitle on screen and picking any other declared track changed
      // nothing, with no error anywhere. A reload at the current position
      // with the wanted track baked into load() is the exact mechanism that
      // already works for the first subtitle (and for a fresh OpenSubtitles
      // download below), so a declared track — or Off — now goes through
      // it too. Every track is already declared (see _prepareLocalCastTracks),
      // so nothing needs registering again here.
      if (sub == null) {
        final active = session.activeSubtitleTrackId.value;
        final alreadyOff = active == null || active < 0;
        if (alreadyOff && !force) {
          // Cleared so a later reload (e.g. an audio-track switch) doesn't
          // resurrect a subtitle that was just turned off.
          for (final raw in _castRawMaps(session, item)) {
            raw.remove('CastActiveSubtitleId');
          }
          return;
        }
        await _applyLocalCastSubtitle(session, item, activateId: null);
        return;
      }

      var castId = _localSubCastIds[sub.index];
      if (castId != null) {
        // A track that was given a delay keeps it when it is picked again:
        // the TV gets the delayed copy's id, not the original's.
        final targetId = _localDelayVariants[castId]?.variantId ?? castId;
        if (force || session.activeSubtitleTrackId.value != targetId) {
          await _applyLocalCastSubtitle(session, item, activateId: targetId);
        }
        return;
      }

      // Not declared to the receiver yet (a fresh OpenSubtitles download):
      // needs a reload with the new track in the declared list.
      final text = await _subtitleText(sub);
      if (text == null) return; // mpv-embedded track — can't be served.

      final url = await LocalCastServer.instance.registerSubtitleText(
        title: item.title,
        content: text,
      );
      if (url == null) {
        // .ass/.ssa (no cue timing lines) or an unreadable file: there is
        // nothing the TV can show, and a silent no-op after a tap looks
        // like a dead button.
        _showCastFailureMessage(
          'That subtitle format can\'t be shown on the TV (use an .srt or '
          '.vtt subtitle).',
        );
        return;
      }

      castId ??= _nextLocalSubCastId++;
      _localSubCastIds[sub.index] = castId;

      final raw = item.raw!;
      final existing = raw['CastLocalSubtitles'];
      raw['CastLocalSubtitles'] = [
        // Never declare the same Cast trackId twice — a duplicate id in
        // one `tracks` list makes the receiver ignore/reject the track.
        if (existing is List)
          ...existing.where((e) => !(e is Map && e['id'] == castId)),
        {'id': castId, 'url': url.toString(), 'name': sub.displayTitle},
      ];
      // SUBTITLE ACTIVATION FIX: same reasoning as the handoff's own
      // `CastActiveSubtitleId` fix above — bake activation into the
      // reload's own load() call rather than only the follow-up
      // selectSubtitleTrack below, which used to be the sole way this
      // freshly-declared track was activated and could race the
      // receiver still settling into the just-reloaded stream.
      raw['CastActiveSubtitleId'] = castId;

      final base = session.currentItem.value ?? item;
      await CastManager.instance.reloadResolvedItem(base);
      try {
        await CastManager.instance.selectSubtitleTrack(castId);
      } catch (_) {
        // Best-effort follow-up — load()'s own activeTrackIds above is
        // now the real fix; this is just a backstop for a receiver that
        // didn't honor it.
      }
    } catch (e) {
      debugPrint('CASTING DEBUG: subtitle sync to TV failed: $e');
      // Previously silent — the sheet closed, nothing appeared on the TV
      // and there was no hint why. Same snackbar channel every other
      // local-cast failure already uses.
      _showCastFailureMessage('Couldn\'t switch subtitles on the TV.');
    }
  }

  // -----------------------------------------------------------------
  // LOCAL VIDEO CAST — SESSION ALREADY CONNECTED (Open With / Play With)
  // -----------------------------------------------------------------
  //
  // The handoff above only runs when a session CONNECTS while a local video
  // is playing. When the TV is already connected and a file is opened via
  // Open With/Play With, PlaybackService sends it straight to the TV and
  // local mpv never opens it — so none of the handoff's subtitle work
  // happened: no sidecar subtitle declared on the TV, no phone-side
  // subtitle list for the sheet, and `isLocalVideoCast` stayed false (so
  // the Subtitles sheet showed its Jellyfin layout with nothing in it).
  //
  // This does the same preparation for that path, before the TV load:
  // the subtitle files found next to the video (or a remembered
  // OpenSubtitles pick) become the phone-side subtitle list WITHOUT
  // involving mpv (PlayerManager.seedCastOnlySubtitles), the first is
  // declared + activated in the first load, and the rest are declared
  // alongside it — identical to what the handoff produces.

  /// Call BEFORE `CastManager.loadAndPlay(item)` for an Open With/Play With
  /// video while a Google Cast session is connected. Best-effort: anything
  /// that can't be prepared just leaves the video without that subtitle.
  Future<void> prepareExternalVideoForActiveCast(MediaItem item) async {
    // Whatever local-cast state an earlier video left behind is over.
    _stopLocalCastTrackSync();

    final session = CastManager.instance.activeSession.value;
    if (session == null ||
        !session.isConnected ||
        !session.transportKind.switchesTracksByReload) {
      return;
    }
    if (!item.isLocal || item.audioOnly || item.live) return;
    final raw = item.raw;
    if (raw == null) return;

    final manager = PlayerManager.instance;

    // Same choice PlayerManager._reapplyCachedSubtitleIfAny makes for a
    // locally-opened file: a remembered OpenSubtitles pick wins, otherwise
    // every subtitle file found next to the video, in folder order.
    final entries =
        <({String content, String displayTitle, String language})>[];
    final cached = await MediaExtrasCacheService.readSubtitle(item.id);
    if (cached != null) {
      entries.add((
        content: cached.content,
        displayTitle: cached.displayTitle,
        language: cached.language,
      ));
    } else {
      var sidecars = (raw['SidecarSubtitles'] as List?)
              ?.whereType<Map>()
              .toList() ??
          <Map>[];

      // DOWNLOADED FILE CAST STRAIGHT TO THE TV: a downloaded movie/episode
      // keeps its subtitles as files next to the video (never in `raw`), so
      // read them from disk here — otherwise the TV got the video with no
      // subtitle at all. Same lookup the local player uses
      // (DownloadManager.subtitlePathsFor: saved list + same-name files in
      // the folder), or the plain folder scan for a video file path.
      if (sidecars.isEmpty) {
        try {
          var paths = DownloadManager.instance.subtitlePathsFor(item.id);
          var stem = '';
          final record = DownloadManager.instance.recordFor(item.id);
          if (record?.mediaPath != null) {
            stem = SidecarSubtitles.stemOf(record!.mediaPath!);
          } else if (item.streamUrl.startsWith('/')) {
            stem = SidecarSubtitles.stemOf(item.streamUrl);
            paths = (await SidecarSubtitles.find(item.streamUrl))
                .map((f) => f.path)
                .toList();
          }
          if (paths.isNotEmpty) {
            sidecars = (await SidecarSubtitles.readFiles(
              paths,
              videoStem: stem,
              shortNames: true,
            ))
                .cast<Map>()
                .toList();
          }
        } catch (e) {
          debugPrint('CASTING DEBUG: reading downloaded subtitles failed: $e');
        }
      }

      for (var i = 0; i < sidecars.length; i++) {
        final content = sidecars[i]['content'] as String?;
        if (content == null || content.trim().isEmpty) continue;
        entries.add((
          content: content,
          displayTitle: (sidecars[i]['fileName'] as String?) ??
              (i == 0 ? 'Subtitle' : 'Subtitle ${i + 1}'),
          language: '',
        ));
      }
    }

    manager.seedCastOnlySubtitles(entries);

    // The selected (first) subtitle is declared under the shared id and
    // activated by the very first load() — same keys, same reasoning as
    // the handoff in _handleSessionConnected.
    raw.remove('CastSidecarSubtitleUrl');
    raw.remove('CastSidecarSubtitleName');
    raw.remove('CastActiveSubtitleId');

    final selected = manager.selectedSubtitle.value;
    final selectedText = selected?.subtitleData;
    if (selected != null &&
        selectedText != null &&
        selectedText.trim().isNotEmpty) {
      try {
        final url = await LocalCastServer.instance.registerSubtitleText(
          title: item.title,
          content: selectedText,
        );
        if (url != null) {
          raw['CastSidecarSubtitleUrl'] = url.toString();
          raw['CastSidecarSubtitleName'] = selected.displayTitle;
          raw['CastActiveSubtitleId'] = kLocalCastSubtitleTrackId;
        }
      } catch (e) {
        debugPrint(
          'CASTING DEBUG: failed to register local subtitle for direct '
          'cast: $e',
        );
      }
    }

    // Declares every other castable subtitle too and marks this coordinator
    // as owning a local video cast (`isLocalVideoCast` becomes true).
    await _prepareLocalCastTracks(session, item);
    if (_localCastItem == null) return;

    _localCastDirect = true;
    manager.castOnlySubtitles = true;

    // AUDIO TRACKS (Audio button dead when the TV was already connected):
    // local mpv never opens this file, so there is no phone-side audio
    // track list at all — `seedCastOnlySubtitles` above even clears it —
    // and the Audio button (enabled only for a non-empty list) stayed
    // greyed out for the whole cast. The file's audio streams are read
    // with a quick header-only ffmpeg probe instead. Not awaited: the
    // TV load must not wait on it, and the button simply lights up as
    // soon as the list lands (it listens to `manager.audioTracks`).
    unawaited(_seedLocalCastAudio(item));
  }

  /// Reads the audio streams of a local video that was sent straight to an
  /// already-connected TV (see [prepareExternalVideoForActiveCast]) and
  /// publishes them as the phone-side audio list, exactly as mpv's own
  /// track list does for a file opened locally first — so the Audio sheet,
  /// its checkmark and [switchLocalCastAudio] behave identically in both
  /// "open then connect" and "connect then open" flows.
  ///
  /// Track `index` is the stream's position among the file's AUDIO streams
  /// (`0:a:N`), which is precisely what [switchLocalCastAudio] hands to
  /// ffmpeg. Best-effort: on any failure the list stays empty and the
  /// button stays disabled, as before.
  Future<void> _seedLocalCastAudio(MediaItem item) async {
    try {
      final List<LocalAudioStreamInfo> streams =
          await LocalCastServer.instance.probeAudioStreams(
        item: item,
        sourceUri: item.streamUrl,
      );
      if (streams.isEmpty) return;

      // The probe takes a moment — make sure this video is still the one
      // being cast directly (not replaced, stopped or disconnected).
      final manager = PlayerManager.instance;
      if (!_localCastDirect ||
          _localCastItem?.id != item.id ||
          !manager.castOnlySubtitles) {
        return;
      }

      final tracks = <AudioTrack>[
        for (var i = 0; i < streams.length; i++)
          AudioTrack(
            index: i,
            // Shown as the row's title: the container's own track name, or
            // "Track N" (+ language) like VLC labels unnamed tracks.
            displayTitle: streams[i].title.isNotEmpty
                ? streams[i].title
                : (streams[i].language.isNotEmpty
                    ? 'Track ${i + 1} - [${streams[i].language}]'
                    : 'Track ${i + 1}'),
            // Shown as the row's subtitle.
            language: streams[i].codec.toUpperCase(),
            isDefault: streams[i].isDefault,
            // No mpv track exists for this file — never used to select
            // anything (see _mirrorLocalAudioPick's cast-only branch).
            nativeId: 'cast-audio-$i',
          ),
      ];

      manager.audioTracks.value = tracks;
      manager.selectedAudio.value =
          tracks.firstWhere((t) => t.isDefault, orElse: () => tracks.first);
    } catch (e) {
      debugPrint('LOCAL CAST AUDIO: couldn\'t read audio tracks: $e');
    }
  }

  /// Call right AFTER a successful `loadAndPlay` that followed
  /// [prepareExternalVideoForActiveCast]: starts mirroring the phone's
  /// subtitle picks (including fresh OpenSubtitles downloads) to the TV.
  Future<void> startDirectLocalCastSync(MediaItem item) async {
    final session = CastManager.instance.activeSession.value;
    if (session == null || !_localCastDirect) return;
    await _startLocalCastTrackSync(session, item, syncAudio: false);
  }

  /// Undoes [prepareExternalVideoForActiveCast] when the load failed.
  void cancelLocalVideoCastFor(MediaItem item) {
    if (_localCastDirect || _localCastItem?.id == item.id) {
      _stopLocalCastTrackSync();
    }
  }

  /// Another video is about to replace the local one on the TV: its
  /// subtitle bookkeeping must not linger.
  void releaseLocalVideoCastFor(MediaItem next) {
    final local = _localCastItem;
    if (local != null && local.id != next.id) {
      _stopLocalCastTrackSync();
    }
  }

  // -----------------------------------------------------------------
  // LOCAL VIDEO CAST: SUBTITLE DELAY
  // -----------------------------------------------------------------
  //
  // The TV can't shift a subtitle live, so a delay is a time-shifted COPY
  // of the active track, declared under its own Cast id, with the TV
  // reloaded at its current position — the same technique
  // setServerCastSubtitleDelay uses for server movies/episodes. Delay 0
  // simply re-selects the original track (still declared, no reload).

  /// Whether the phone-side track [localIndex] is one the TV has (so its
  /// delay can be changed).
  bool canDelayLocalCastSubtitle(int? localIndex) =>
      localIndex != null && _localSubCastIds.containsKey(localIndex);

  /// The delay currently applied on the TV to the phone-side track
  /// [localIndex].
  Duration localCastSubtitleDelayFor(int? localIndex) {
    if (localIndex == null) return Duration.zero;
    final baseId = _localSubCastIds[localIndex];
    if (baseId == null) return Duration.zero;
    return _localDelayVariants[baseId]?.delay ?? Duration.zero;
  }

  /// Applies [delay] (positive = subtitle appears later) to the subtitle
  /// currently selected for the local video on the TV. Throws
  /// [LocalCastUnsupportedException] (message safe to show) when it can't;
  /// the TV keeps what it had.
  Future<void> setLocalCastSubtitleDelay(Duration delay) {
    return _enqueueLocalTrackOp(() async {
      final item = _localCastItem;
      final session = CastManager.instance.activeSession.value;
      if (item == null || session == null || !isLocalVideoCast) {
        throw LocalCastUnsupportedException(
          'The TV isn\'t playing this video any more, so its subtitles '
          'can\'t be changed.',
        );
      }

      final sub = PlayerManager.instance.selectedSubtitle.value;
      final baseId = sub == null ? null : _localSubCastIds[sub.index];
      if (sub == null || baseId == null) {
        throw LocalCastUnsupportedException(
          'Turn a subtitle on first, then adjust its delay.',
        );
      }

      final current = _localDelayVariants[baseId]?.delay ?? Duration.zero;
      if (current == delay) return;

      final rawMaps = _castRawMaps(session, item);
      final previousLists = [
        for (final raw in rawMaps)
          raw['CastLocalSubtitles'] is List
              ? List<dynamic>.from(raw['CastLocalSubtitles'] as List)
              : null,
      ];
      final previousActive = [
        for (final raw in rawMaps) raw['CastActiveSubtitleId'],
      ];

      void restoreRaw() {
        for (var i = 0; i < rawMaps.length; i++) {
          if (previousLists[i] == null) {
            rawMaps[i].remove('CastLocalSubtitles');
          } else {
            rawMaps[i]['CastLocalSubtitles'] = previousLists[i];
          }
          if (previousActive[i] == null) {
            rawMaps[i].remove('CastActiveSubtitleId');
          } else {
            rawMaps[i]['CastActiveSubtitleId'] = previousActive[i];
          }
        }
      }

      if (delay == Duration.zero) {
        // The original track is still declared on the TV — no reload.
        for (final raw in rawMaps) {
          raw['CastActiveSubtitleId'] = baseId;
        }
        try {
          await CastManager.instance.selectSubtitleTrack(baseId);
        } catch (e) {
          restoreRaw();
          if (e is LocalCastUnsupportedException) rethrow;
          throw LocalCastUnsupportedException(
            'The TV didn\'t switch back to the original subtitle timing.',
          );
        }
        _localDelayVariants.remove(baseId);
        return;
      }

      final text = await _subtitleText(sub);
      if (text == null || !text.contains('-->')) {
        throw LocalCastUnsupportedException(
          'This subtitle can\'t be delayed on the TV (it isn\'t a text '
          'subtitle the phone can read).',
        );
      }

      final url = await LocalCastServer.instance.registerSubtitleText(
        title: item.title,
        content: _shiftSubtitleText(text, delay),
      );
      if (url == null) {
        throw LocalCastUnsupportedException(
          'The delayed subtitle couldn\'t be sent to the TV.',
        );
      }

      final variantId = _nextLocalDelayVariantId++;
      final seconds = delay.inMilliseconds / 1000;
      final entry = <String, dynamic>{
        'id': variantId,
        'url': url.toString(),
        'name': '${sub.displayTitle} '
            '(${seconds >= 0 ? '+' : ''}${seconds.toStringAsFixed(2)}s)',
      };

      // An earlier delayed copy of the same track is replaced, not stacked.
      final staleId = _localDelayVariants[baseId]?.variantId;
      for (final raw in rawMaps) {
        final existing = raw['CastLocalSubtitles'];
        raw['CastLocalSubtitles'] = [
          if (existing is List)
            ...existing.where(
              (e) => !(e is Map && staleId != null && e['id'] == staleId),
            ),
          entry,
        ];
        // Activated by the reload's own load() call (the follow-up select
        // below is only a backstop) — see
        // GoogleCastTransport._defaultSubtitleTrackId.
        raw['CastActiveSubtitleId'] = variantId;
      }

      try {
        final base = session.currentItem.value ?? item;
        await CastManager.instance.reloadResolvedItem(base);
        try {
          await CastManager.instance.selectSubtitleTrack(variantId);
        } catch (_) {
          // Best-effort backstop — load()'s own activeTrackIds is the real
          // activation.
        }
      } catch (e) {
        restoreRaw();
        if (e is LocalCastUnsupportedException) rethrow;
        throw LocalCastUnsupportedException(
          'The TV didn\'t accept the delayed subtitle.',
        );
      }

      _localDelayVariants[baseId] =
          _LocalCastDelayVariant(variantId: variantId, delay: delay);
    });
  }

  /// Switches the TV's audio track for a local video (see the section
  /// comment) and mirrors the choice into local mpv. Throws
  /// [LocalCastUnsupportedException] (message safe to show) when the track
  /// can't be prepared for the TV; the TV keeps playing what it had.
  ///
  /// This is the same thing VLC's Cast output does: the Cast SDK has no
  /// call that swaps the audio stream of media the receiver already has
  /// open, so a NEW stream containing only the wanted audio is produced
  /// on the phone and the receiver is reloaded with it at the position
  /// the TV is at right now.
  ///
  /// [showProgress] shows a persistent "Switching audio track…" notice for
  /// the duration of the work. ROOT CAUSE of the "nothing happens" report:
  /// the Audio sheet closes the moment a track is tapped and the remux of a
  /// multi-GB file (plus the TV reload) can take a long while — with no
  /// notice at all that is indistinguishable from a dead button.
  Future<void> switchLocalCastAudio(
    AudioTrack track, {
    bool showProgress = true,
  }) {
    return _enqueueLocalTrackOp(() async {
      if (showProgress) {
        _showCastProgress('Switching audio track on the TV…');
      }
      try {
        await _switchLocalCastAudioNow(track);
      } finally {
        if (showProgress) _hideCastProgress();
      }
    });
  }

  Future<void> _switchLocalCastAudioNow(AudioTrack track) async {
    final item = _localCastItem;
    final session = CastManager.instance.activeSession.value;
    debugPrint(
      'LOCAL CAST AUDIO: switch requested -> #${track.index} '
      '"${track.displayTitle}" (localItem=${item?.id}, '
      'isLocalVideoCast=$isLocalVideoCast, direct=$_localCastDirect, '
      'tvIndex=$_localAudioIndex)',
    );
    if (item == null || session == null || !isLocalVideoCast) {
      // Used to be a bare `return`, which made the sheet look like it
      // worked while nothing at all had been sent to the TV.
      throw LocalCastUnsupportedException(
        'The TV isn\'t playing this video any more, so its audio track '
        'can\'t be changed.',
      );
    }

    // Only skip the TV when THIS coordinator has already put exactly
    // this track there. While the TV is still on the receiver's own
    // default ([_localAudioIndex] == null) every pick — including the
    // track that looks "already selected" on the phone — is forced.
    if (_localAudioIndex == track.index) {
      await _mirrorLocalAudioPick(track);
      return;
    }

    debugPrint(
      'LOCAL CAST AUDIO: forcing TV to audio #${track.index} '
      '"${track.displayTitle}" (TV was on '
      '${_localAudioIndex == null ? 'the receiver default' : '#$_localAudioIndex'})',
    );

    var url = _localAudioUrls[track.index];
    if (url == null) {
      final uri = await LocalCastServer.instance.registerMediaWithAudioTrack(
        item: item,
        sourceUri: item.streamUrl,
        audioIndex: track.index,
      );
      url = uri.toString();
      _localAudioUrls[track.index] = url;
    }
    debugPrint('LOCAL CAST AUDIO: remuxed stream ready at $url');

    // A reload drops the active text track, so remember it to re-apply.
    // Falls back to the raw hint this same reload machinery stashes
    // (see _syncLocalSubtitleToCast/the handoff's CastActiveSubtitleId
    // fix) rather than only `session.activeSubtitleTrackId` — that
    // notifier is only ever set once a *previous* load's activation
    // actually lands, so reading it alone could silently lose a
    // subtitle that was selected moments ago.
    final activeSub = session.activeSubtitleTrackId.value ??
        (item.raw?['CastActiveSubtitleId'] as int?);

    // The item actually handed to the transport. `currentItem` can be a
    // different MediaItem instance than `item`, so the hints the
    // transport reads off `raw` are written to both maps.
    final base = session.currentItem.value ?? item;
    final rawMaps = <Map<String, dynamic>>[
      item.raw!,
      if (base.raw != null && !identical(base.raw, item.raw)) base.raw!,
    ];
    for (final raw in rawMaps) {
      // The swapped-in stream is always an MPEG-TS remux, whatever the
      // source container was (see GoogleCastTransport
      // ._resolveCastMedia's `CastLocalRemuxedTs` check).
      raw['CastLocalRemuxedTs'] = true;

      // SUBTITLE ACTIVATION FIX: bake the carried-over subtitle into
      // this reload's own load() call (see GoogleCastTransport
      // ._defaultSubtitleTrackId's doc comment) instead of relying only
      // on the follow-up selectSubtitleTrack below.
      if (activeSub != null && activeSub >= 0) {
        raw['CastActiveSubtitleId'] = activeSub;
      } else {
        raw.remove('CastActiveSubtitleId');
      }
    }

    await CastManager.instance
        .reloadResolvedItem(base.copyWith(remoteStreamUrl: url));
    _localAudioIndex = track.index;
    debugPrint('LOCAL CAST AUDIO: TV reloaded on audio #${track.index}');

    await _mirrorLocalAudioPick(track);

    if (activeSub != null && activeSub >= 0) {
      try {
        await CastManager.instance.selectSubtitleTrack(activeSub);
      } catch (_) {
        // Best-effort backstop — load()'s own activeTrackIds above is
        // the real fix.
      }
    }

  }

  ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? _castProgressBar;

  void _showCastProgress(String message) {
    final context = ExternalMediaHandler.instance.navigatorKey.currentContext;
    if (context == null) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    _castProgressBar?.close();
    _castProgressBar = messenger.showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        duration: const Duration(minutes: 10),
        content: Row(
          children: [
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 12),
            Expanded(child: Text(message)),
          ],
        ),
      ),
    );
  }

  void _hideCastProgress() {
    _castProgressBar?.close();
    _castProgressBar = null;
  }

  /// Builds the phone-side audio list from an ffmpeg header probe — the same
  /// shape [_seedLocalCastAudio] publishes.
  List<AudioTrack> _audioTracksFromProbe(List<LocalAudioStreamInfo> streams) {
    return <AudioTrack>[
      for (var i = 0; i < streams.length; i++)
        AudioTrack(
          index: i,
          displayTitle: streams[i].title.isNotEmpty
              ? streams[i].title
              : (streams[i].language.isNotEmpty
                  ? 'Track ${i + 1} - [${streams[i].language}]'
                  : 'Track ${i + 1}'),
          language: streams[i].codec.toUpperCase(),
          isDefault: streams[i].isDefault,
          nativeId: 'cast-audio-$i',
        ),
    ];
  }

  /// HANDOFF (video opened locally, TV connected afterwards): the Audio list
  /// normally comes from mpv. If it is still empty a moment after the
  /// handoff, publish the probe's list instead so the Audio button is never
  /// left dead. Never overwrites a list mpv did deliver.
  Future<void> _ensureHandoffAudioTracks(MediaItem item) async {
    final manager = PlayerManager.instance;
    for (var i = 0; i < 6; i++) {
      if (manager.audioTracks.value.isNotEmpty) return;
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (_localCastItem?.id != item.id) return;
    }
    if (manager.audioTracks.value.isNotEmpty) return;

    try {
      final streams = await LocalCastServer.instance.probeAudioStreams(
        item: item,
        sourceUri: item.streamUrl,
      );
      if (streams.isEmpty) return;
      if (_localCastItem?.id != item.id ||
          manager.audioTracks.value.isNotEmpty) {
        return;
      }
      final tracks = _audioTracksFromProbe(streams);
      manager.audioTracks.value = tracks;
      manager.selectedAudio.value ??=
          tracks.firstWhere((t) => t.isDefault, orElse: () => tracks.first);
      debugPrint(
        'LOCAL CAST AUDIO: mpv reported no audio tracks after handoff — '
        'published ${tracks.length} from the file probe.',
      );
    } catch (e) {
      debugPrint('LOCAL CAST AUDIO: handoff audio probe failed: $e');
    }
  }

  /// Mirrors an audio pick into the phone's own (paused) mpv so its state
  /// is right when local playback resumes. Never allowed to fail the TV
  /// switch that has already succeeded by the time this runs.
  Future<void> _mirrorLocalAudioPick(AudioTrack track) async {
    final manager = PlayerManager.instance;

    // Cast-only (TV was already connected, mpv never opened this file):
    // there is no phone-side track to switch — asking mpv would target
    // whatever stale file it last had — so only the checkmark state moves.
    //
    // Same for a track list that was built by the ffmpeg probe instead of by
    // mpv ([_ensureHandoffAudioTracks]): its nativeId is a placeholder mpv
    // has never heard of.
    if (manager.castOnlySubtitles || track.nativeId.startsWith('cast-audio-')) {
      manager.selectedAudio.value = track;
      return;
    }

    try {
      await manager.selectAudioTrack(track);
    } catch (e) {
      debugPrint('LOCAL CAST AUDIO: phone-side mirror failed: $e');
    }
  }

  // -----------------------------------------------------------------
  // SERVER VIDEO CAST: ONLINE SUBTITLES + SUBTITLE DELAY (Google Cast)
  // -----------------------------------------------------------------
  //
  // A movie/episode that comes from the Jellyfin server already gets its
  // own subtitle list on the TV (server MediaStreams -> declared Cast text
  // tracks). What it did NOT get, while casting, was the two things the
  // Subtitles sheet offers for local playback: "Search online
  // (OpenSubtitles)" and the Delay control. Both were hidden because they
  // only ever acted on the phone's paused mpv.
  //
  //  - ONLINE SUBTITLE: same mechanism as a fresh OpenSubtitles download
  //    during a local-video cast (_syncLocalSubtitleToCast) — the text is
  //    served by LocalCastServer as WebVTT, declared to the receiver under
  //    a new track id through `raw['CastLocalSubtitles']` (which
  //    GoogleCastTransport._subtitleTracksFor reads for ANY item, not
  //    only local ones), and the stream is reloaded at the current
  //    position, because the Cast SDK cannot add a text track to media
  //    the receiver already has open.
  //  - DELAY: the Default Media Receiver has no subtitle-offset control
  //    either, so the active subtitle's text is fetched (server track) or
  //    taken from memory (online download), every cue time is shifted, and
  //    the result is declared as an extra "variant" track and activated
  //    with the same reload. Variants are never listed in the sheet — they
  //    map back to the track they came from (serverCastBaseSubtitleId).
  //    Delay 0 just switches back to the original track (no reload).

  /// Bumped whenever the set of online subtitles / delay variants for the
  /// cast item changes, so the Subtitles sheet can rebuild its list.
  final ValueNotifier<int> serverCastSubtitlesRevision = ValueNotifier<int>(0);

  int _nextServerCastSubId = kLocalCastSubtitleTrackId + 100;
  final Map<String, List<_ServerCastSub>> _serverCastOnline = {};
  final Map<int, _ServerCastDelayVariant> _serverCastDelayVariants = {};
  final Map<String, String> _serverSubtitleTextCache = {};

  /// True while a Google Cast session is playing a Jellyfin-server movie/
  /// episode (i.e. NOT an Open With/Play With file, which has its own
  /// local-cast machinery above, and not a song or live channel).
  bool get isServerVideoCast {
    final session = CastManager.instance.activeSession.value;
    if (session == null || !session.isConnected) return false;
    if (!session.transportKind.switchesTracksByReload) return false;
    if (isLocalVideoCast) return false;
    final item = session.currentItem.value;
    return item != null && !item.isLocal && !item.audioOnly && !item.live;
  }

  /// The user-visible track a Cast track id belongs to: the id itself, or
  /// — for a delay variant — the original track it was shifted from.
  /// Null for "no subtitle" (null / negative).
  int? serverCastBaseSubtitleId(int? castId) {
    if (castId == null || castId < 0) return null;
    return _serverCastDelayVariants[castId]?.baseId ?? castId;
  }

  /// The delay currently applied on the TV for the active Cast track id.
  Duration serverCastSubtitleDelayFor(int? castId) {
    if (castId == null) return Duration.zero;
    return _serverCastDelayVariants[castId]?.delay ?? Duration.zero;
  }

  Set<int> _declaredCastSubtitleIds(MediaItem item) {
    final extra = item.raw?['CastLocalSubtitles'];
    if (extra is! List) return const <int>{};
    return {
      for (final e in extra)
        if (e is Map && e['id'] is int) e['id'] as int,
    };
  }

  /// OpenSubtitles downloads that are declared on the TV for [item],
  /// shaped as [SubtitleTrack]s so the Subtitles sheet can list them next
  /// to the server's own tracks. Filtered to ids actually present in the
  /// item's current declared list, so a download made for an earlier load
  /// of the same title never shows up as a track the TV doesn't have.
  List<SubtitleTrack> serverCastOnlineTracks(MediaItem? item) {
    if (item == null) return const [];
    final subs = _serverCastOnline[item.id];
    if (subs == null || subs.isEmpty) return const [];
    final declared = _declaredCastSubtitleIds(item);
    return [
      for (final s in subs)
        if (declared.contains(s.id))
          SubtitleTrack(
            index: s.id,
            language: s.language,
            displayTitle: s.name,
            isDefault: false,
            isForced: false,
            nativeId: 'cast-${s.id}',
            isExternal: true,
          ),
    ];
  }

  /// Every Cast-side raw map that has to carry a hint for the next
  /// load(): the item the session holds and the one being reloaded can be
  /// different instances (see switchLocalCastAudio's identical handling).
  List<Map<String, dynamic>> _castRawMaps(CastSession session, MediaItem item) {
    final base = session.currentItem.value ?? item;
    return [
      if (item.raw != null) item.raw!,
      if (base.raw != null && !identical(base.raw, item.raw)) base.raw!,
    ];
  }

  MediaItem _requireServerCastItem(CastSession? session) {
    final item = session?.currentItem.value;
    if (session == null || item == null || item.raw == null || !isServerVideoCast) {
      throw LocalCastUnsupportedException(
        'The TV isn\'t playing this video any more, so its subtitles '
        'can\'t be changed.',
      );
    }
    return item;
  }

  /// Sends an OpenSubtitles download to the TV and switches to it. Awaits
  /// the reload, so the caller's spinner stays up until the TV has it;
  /// throws [LocalCastUnsupportedException] (message safe to show) if it
  /// can't be delivered, leaving the TV playing what it had.
  Future<void> addOnlineSubtitleToServerCast({
    required String content,
    required String displayTitle,
    required String language,
  }) {
    return _enqueueLocalTrackOp(() async {
      final session = CastManager.instance.activeSession.value;
      final item = _requireServerCastItem(session);

      final url = await LocalCastServer.instance.registerSubtitleText(
        title: item.title,
        content: content,
      );
      if (url == null) {
        throw LocalCastUnsupportedException(
          'That subtitle couldn\'t be sent to the TV (not a text subtitle, '
          'or this phone\'s Wi-Fi address couldn\'t be found).',
        );
      }

      final id = _nextServerCastSubId++;
      final entry = <String, dynamic>{
        'id': id,
        'url': url.toString(),
        'name': displayTitle,
      };

      final rawMaps = _castRawMaps(session!, item);
      final previousLists = [
        for (final raw in rawMaps)
          raw['CastLocalSubtitles'] is List
              ? List<dynamic>.from(raw['CastLocalSubtitles'] as List)
              : null,
      ];
      final previousActive = [
        for (final raw in rawMaps) raw['CastActiveSubtitleId'],
      ];

      for (final raw in rawMaps) {
        final existing = raw['CastLocalSubtitles'];
        raw['CastLocalSubtitles'] = [
          if (existing is List) ...existing,
          entry,
        ];
        // Activated by the reload's own load() call (the follow-up
        // select below is only a backstop) — see GoogleCastTransport
        // ._defaultSubtitleTrackId.
        raw['CastActiveSubtitleId'] = id;
      }

      try {
        await _reloadServerCastItem(session, item, activateId: id);
      } catch (e) {
        // Put the item back exactly as it was so a failed reload doesn't
        // leave a declared-but-unreachable track behind.
        for (var i = 0; i < rawMaps.length; i++) {
          if (previousLists[i] == null) {
            rawMaps[i].remove('CastLocalSubtitles');
          } else {
            rawMaps[i]['CastLocalSubtitles'] = previousLists[i];
          }
          if (previousActive[i] == null) {
            rawMaps[i].remove('CastActiveSubtitleId');
          } else {
            rawMaps[i]['CastActiveSubtitleId'] = previousActive[i];
          }
        }
        if (e is LocalCastUnsupportedException) rethrow;
        throw LocalCastUnsupportedException(
          'The TV didn\'t accept the subtitle.',
        );
      }

      (_serverCastOnline[item.id] ??= []).add(
        _ServerCastSub(
          id: id,
          name: displayTitle,
          language: language,
          content: content,
        ),
      );
      serverCastSubtitlesRevision.value++;
    });
  }

  Future<void> _reloadServerCastItem(
    CastSession session,
    MediaItem item, {
    required int activateId,
  }) async {
    final base = session.currentItem.value ?? item;
    await CastManager.instance.reloadResolvedItem(base);
    try {
      await CastManager.instance.selectSubtitleTrack(activateId);
    } catch (_) {
      // Best-effort backstop — load()'s own activeTrackIds is the real
      // activation.
    }
  }

  /// Subtitle pick on the TV for a server item. Routed through here (not
  /// straight to CastManager) so the "activate this on the next reload"
  /// hint stays right, and so "Off" doesn't throw when the item had no
  /// subtitle tracks to begin with (capability.subtitleTrackSelection is
  /// false then, and there is nothing active to turn off).
  Future<void> selectServerCastSubtitle(int trackId) async {
    final session = CastManager.instance.activeSession.value;
    if (session == null) return;
    final raw = session.currentItem.value?.raw;

    if (trackId < 0) {
      raw?.remove('CastActiveSubtitleId');
      if (!session.capability.subtitleTrackSelection) return;
    } else {
      raw?['CastActiveSubtitleId'] = trackId;
    }
    await CastManager.instance.selectSubtitleTrack(trackId);
  }

  /// Applies [delay] (positive = subtitle appears later) to the subtitle
  /// currently showing on the TV. See the section comment for how; the
  /// TV reloads at its current position unless [delay] is zero.
  Future<void> setServerCastSubtitleDelay(Duration delay) {
    return _enqueueLocalTrackOp(() async {
      final session = CastManager.instance.activeSession.value;
      final item = _requireServerCastItem(session);

      final activeId = session!.activeSubtitleTrackId.value;
      final baseId = serverCastBaseSubtitleId(activeId);
      if (baseId == null) {
        throw LocalCastUnsupportedException(
          'Turn a subtitle on first, then adjust its delay.',
        );
      }
      if (serverCastSubtitleDelayFor(activeId) == delay) return;

      if (delay == Duration.zero) {
        // The original track is still declared on the TV — no reload.
        for (final raw in _castRawMaps(session, item)) {
          raw['CastActiveSubtitleId'] = baseId;
        }
        await CastManager.instance.selectSubtitleTrack(baseId);
        return;
      }

      final source = await _serverCastSubtitleSource(item, baseId);
      if (source == null) {
        throw LocalCastUnsupportedException(
          'This subtitle can\'t be delayed on the TV (it isn\'t a text '
          'subtitle the phone can read).',
        );
      }

      final url = await LocalCastServer.instance.registerSubtitleText(
        title: item.title,
        content: _shiftSubtitleText(source.text, delay),
      );
      if (url == null) {
        throw LocalCastUnsupportedException(
          'The delayed subtitle couldn\'t be sent to the TV.',
        );
      }

      final variantId = _nextServerCastSubId++;
      final seconds = delay.inMilliseconds / 1000;
      final entry = <String, dynamic>{
        'id': variantId,
        'url': url.toString(),
        'name': '${source.name} '
            '(${seconds >= 0 ? '+' : ''}${seconds.toStringAsFixed(2)}s)',
        'variantOf': baseId,
      };

      final rawMaps = _castRawMaps(session, item);
      final previousLists = [
        for (final raw in rawMaps)
          raw['CastLocalSubtitles'] is List
              ? List<dynamic>.from(raw['CastLocalSubtitles'] as List)
              : null,
      ];
      final previousActive = [
        for (final raw in rawMaps) raw['CastActiveSubtitleId'],
      ];

      // Earlier variants of the same track are replaced, not stacked.
      final staleVariantIds = _serverCastDelayVariants.entries
          .where((e) => e.value.baseId == baseId)
          .map((e) => e.key)
          .toSet();

      for (final raw in rawMaps) {
        final existing = raw['CastLocalSubtitles'];
        raw['CastLocalSubtitles'] = [
          if (existing is List)
            ...existing.where(
              (e) => !(e is Map && staleVariantIds.contains(e['id'])),
            ),
          entry,
        ];
        raw['CastActiveSubtitleId'] = variantId;
      }

      try {
        await _reloadServerCastItem(session, item, activateId: variantId);
      } catch (e) {
        for (var i = 0; i < rawMaps.length; i++) {
          if (previousLists[i] == null) {
            rawMaps[i].remove('CastLocalSubtitles');
          } else {
            rawMaps[i]['CastLocalSubtitles'] = previousLists[i];
          }
          if (previousActive[i] == null) {
            rawMaps[i].remove('CastActiveSubtitleId');
          } else {
            rawMaps[i]['CastActiveSubtitleId'] = previousActive[i];
          }
        }
        if (e is LocalCastUnsupportedException) rethrow;
        throw LocalCastUnsupportedException(
          'The TV didn\'t accept the delayed subtitle.',
        );
      }

      for (final id in staleVariantIds) {
        _serverCastDelayVariants.remove(id);
      }
      _serverCastDelayVariants[variantId] =
          _ServerCastDelayVariant(baseId: baseId, delay: delay);
      serverCastSubtitlesRevision.value++;
    });
  }

  /// The text (and display name) behind Cast track [baseId] of [item]: the
  /// in-memory content of an online download, or the server's WebVTT for a
  /// text subtitle stream. Null for image-based tracks and anything that
  /// can't be fetched.
  Future<({String text, String name})?> _serverCastSubtitleSource(
    MediaItem item,
    int baseId,
  ) async {
    final online = _serverCastOnline[item.id];
    if (online != null) {
      for (final s in online) {
        if (s.id == baseId) return (text: s.content, name: s.name);
      }
    }

    final mediaSourceId =
        (item.mediaSources != null && item.mediaSources!.isNotEmpty)
            ? item.mediaSources!.first['Id'] as String? ?? item.id
            : item.id;
    final tracks = MediaStreamParser.subtitles(
      item.mediaStreams,
      itemId: item.id,
      mediaSourceId: mediaSourceId,
    );
    for (final track in tracks) {
      if (track.index != baseId) continue;
      final url = track.externalUrl;
      if (url == null) return null;

      var text = _serverSubtitleTextCache[url];
      if (text == null) {
        try {
          final response = await Dio().get<String>(
            url,
            options: Options(
              responseType: ResponseType.plain,
              receiveTimeout: const Duration(seconds: 20),
            ),
          );
          text = response.data;
        } catch (e) {
          debugPrint('CASTING DEBUG: failed to fetch subtitle for delay: $e');
          return null;
        }
        if (text == null || !text.contains('-->')) return null;
        _serverSubtitleTextCache[url] = text;
      }
      return (text: text, name: track.displayTitle);
    }
    return null;
  }

  static final RegExp _cueTimestamp =
      RegExp(r'(?:(\d{1,3}):)?(\d{2}):(\d{2})([.,])(\d{3})');

  /// Moves every cue time in SRT or WebVTT [text] by [delay] (clamped at
  /// zero), keeping each timestamp's own decimal separator so the result
  /// is still valid SRT (converted to WebVTT by LocalCastServer) or valid
  /// WebVTT. Only lines containing `-->` are touched, so cue text and
  /// cue settings are left alone.
  static String _shiftSubtitleText(String text, Duration delay) {
    final shiftMs = delay.inMilliseconds;
    final lines =
        text.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');

    String two(int v) => v.toString().padLeft(2, '0');

    for (var i = 0; i < lines.length; i++) {
      if (!lines[i].contains('-->')) continue;
      lines[i] = lines[i].replaceAllMapped(_cueTimestamp, (m) {
        final hours = int.tryParse(m.group(1) ?? '0') ?? 0;
        final minutes = int.parse(m.group(2)!);
        final seconds = int.parse(m.group(3)!);
        final millis = int.parse(m.group(5)!);

        var total =
            (((hours * 60) + minutes) * 60 + seconds) * 1000 + millis + shiftMs;
        if (total < 0) total = 0;

        final hh = total ~/ 3600000;
        final mm = (total ~/ 60000) % 60;
        final ss = (total ~/ 1000) % 60;
        final mmm = total % 1000;
        return '${two(hh)}:${two(mm)}:${two(ss)}${m.group(4)}'
            '${mmm.toString().padLeft(3, '0')}';
      });
    }
    return lines.join('\n');
  }

  void _resetServerCastSubtitleState() {
    _serverCastOnline.clear();
    _serverCastDelayVariants.clear();
    _serverSubtitleTextCache.clear();
    _nextServerCastSubId = kLocalCastSubtitleTrackId + 100;
    serverCastSubtitlesRevision.value++;
  }

  // -----------------------------------------------------------------
  // REMOTE → LOCAL
  // -----------------------------------------------------------------

  void _handleSessionDisconnected() {
    final wasHandoff = isHandoffActive.value;
    isHandoffActive.value = false;

    // CASTING FIX: captured *before* endCastMirror() below resets it —
    // tells _resumeLocally() whether local mpv genuinely has this item
    // open (a real LOCAL → REMOTE handoff) or was only ever mirroring
    // the session's own state (a song picked via
    // playAudioQueueOnActiveCast while already casting, never opened in
    // local mpv at all). Comparing by id alone can't tell these apart —
    // a mirrored id can coincidentally equal what mpv actually has
    // loaded (e.g. the very first mirrored song, right after a real
    // handoff) — so this has to be tracked explicitly instead.
    final wasMirrorOnly = PlayerManager.instance.castMirrorActive;
    PlayerManager.instance.endCastMirror();
    _mirroringAudio = false;
    _stopLocalCastTrackSync();
    _resetServerCastSubtitleState();

    // No-ops if this session was never a handoff in the first place
    // (see suspendAdaptiveQualityForCast/resumeAdaptiveQualityAfterCast's
    // own guards) — a plain "Cast to" that never touched local playback
    // never suspended anything here to begin with.
    PlayerManager.instance.resumeAdaptiveQualityAfterCast();

    final item = _lastCastItem;
    final position = _lastCastPosition;
    _lastCastItem = null;
    _lastCastPosition = Duration.zero;

    final displaced = _displacedAudio;
    final displacedPosition = _displacedAudioPosition;
    final displacedMirrorOnly = _displacedAudioMirrorOnly;
    _displacedAudio = null;
    _displacedAudioPosition = Duration.zero;
    _displacedAudioMirrorOnly = false;
    endExplicitCast();

    // Nothing was ever actually loaded on the receiver (connected, then
    // disconnected again before picking anything to play) — there's
    // nothing meaningful to offer resuming.
    if (item == null) return;

    // A movie/episode was cast OVER a song. The song is what the person
    // goes back to: if it was held by local playback it is simply still in
    // the mini player, paused and ready (nothing to offer); if it was only
    // being mirrored from the TV, local playback never had it, so offer to
    // start it here. Offering to resume the movie instead would replace
    // the song they expect to find.
    if (displaced != null && !item.audioOnly) {
      if (displacedMirrorOnly) {
        _offerLocalResume(
          displaced,
          displacedPosition,
          wasHandoff: false,
          wasMirrorOnly: true,
        );
      }
      return;
    }

    _offerLocalResume(
      item,
      position,
      wasHandoff: wasHandoff,
      wasMirrorOnly: wasMirrorOnly,
    );
  }

  /// Surfaces a short-lived SnackBar offering to pick local playback back
  /// up from where the TV left off. Uses `ExternalMediaHandler`'s own
  /// root `navigatorKey` rather than plumbing a BuildContext through
  /// every `CastManager.disconnect()` call site (the device picker, the
  /// connected-session sheet's Disconnect button, a transport noticing
  /// the TV went away on its own) — that key is already the established
  /// place this codebase reaches for a context-free way to talk to the
  /// UI (see ExternalMediaHandler's own doc comment).
  void _offerLocalResume(
    MediaItem item,
    Duration position, {
    required bool wasHandoff,
    required bool wasMirrorOnly,
  }) {
    final context = ExternalMediaHandler.instance.navigatorKey.currentContext;
    if (context == null) return;

    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;

    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 8),
        content: Text(
          wasHandoff
              ? 'Disconnected from cast — resume "${item.title}" here?'
              : 'Casting ended — resume "${item.title}" on this device?',
        ),
        action: SnackBarAction(
          label: 'RESUME',
          onPressed: () =>
              _resumeLocally(item, position, wasMirrorOnly: wasMirrorOnly),
        ),
      ),
    );
  }

  void _resumeLocally(
    MediaItem item,
    Duration position, {
    required bool wasMirrorOnly,
  }) {
    final manager = PlayerManager.instance;

    // If this device's own local playback is still sitting right where
    // the handoff left it — same item, just paused, VideoPlayerScreen/
    // mini player never went away — resume it in place: a seek (only if
    // actually needed) + play preserves the exact same local session
    // (subtitle/audio track selections, PlaybackQueue, any in-flight
    // adaptive-quality state) instead of tearing all of that down to
    // reopen the stream from scratch. This is the common case, since
    // [isHandoffActive] only offers "Resume" for a session this
    // coordinator's own LOCAL → REMOTE handoff started.
    //
    // CASTING FIX: `!wasMirrorOnly` guards this — a mirrored item's id
    // can equal `manager.currentItem?.id` (mirroring sets exactly that)
    // even though local mpv never actually opened it, which used to mean
    // "Resume" would just call `player.play()` on whatever mpv had
    // stale/nothing loaded instead of the track the person actually saw
    // on screen. A mirror-only track always falls through to the
    // cold-start path below instead.
    if (!wasMirrorOnly && manager.currentItem?.id == item.id) {
      final drift = (manager.position.value - position).abs();
      if (drift > const Duration(seconds: 2)) {
        manager.seekToAbsolute(position);
      }
      manager.player.play();
      return;
    }

    // Otherwise — a "Cast to" that never played locally in the first
    // place, or local playback has since moved on to something else —
    // cold-start it, mirroring ExternalMediaHandler._playAudio/_playVideo's
    // established "loading preview up front, push the right screen, start
    // the queue underneath it" flow, the same one every other "just play
    // this one thing" entry point in the app already uses.
    final resumed = position > Duration.zero
        ? item.copyWith(playbackPosition: position)
        : item;

    final context = ExternalMediaHandler.instance.navigatorKey.currentContext;
    if (context == null) return;

    manager.showLoadingPreview(resumed);

    if (resumed.audioOnly) {
      Navigator.of(context, rootNavigator: true).push(
        MaterialPageRoute(builder: (_) => const AudioPlayerScreen()),
      );
      PlaybackService.playQueue([resumed], source: PlaybackSource.unknown);
    } else {
      unawaited(
        PlaybackService.playQueue([resumed], source: PlaybackSource.unknown),
      );
      unawaited(PlayerNavigation.open(context));
    }
  }
}

/// An OpenSubtitles download declared on the TV for a Jellyfin-server
/// movie/episode — see PlaybackCoordinator.addOnlineSubtitleToServerCast.
class _ServerCastSub {
  _ServerCastSub({
    required this.id,
    required this.name,
    required this.language,
    required this.content,
  });

  final int id;
  final String name;
  final String language;
  final String content;
}

/// A time-shifted copy of a subtitle track, declared on the TV under its
/// own Cast track id — see PlaybackCoordinator.setServerCastSubtitleDelay.
class _ServerCastDelayVariant {
  const _ServerCastDelayVariant({required this.baseId, required this.delay});

  final int baseId;
  final Duration delay;
}

/// A time-shifted copy of a local-video subtitle track, declared on the TV
/// under its own Cast track id — see
/// PlaybackCoordinator.setLocalCastSubtitleDelay.
class _LocalCastDelayVariant {
  const _LocalCastDelayVariant({required this.variantId, required this.delay});

  final int variantId;
  final Duration delay;
}
