import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart' show NativePlayer;

import '../addons/addon_models.dart';
import '../addons/stream_rules.dart';
import '../library/source_preferences.dart';
import '../player/load_progress.dart';
import '../player/models/media_item.dart';
import '../player/playback_service.dart';
import '../player/player_manager.dart';
import '../player/services/playback_queue.dart';
import '../services/app_settings.dart';
import '../services/external_media_handler.dart';
import '../torrent/torrent_engine.dart';
import 'auto_link_selector.dart';
import 'catalog_models.dart';
import 'catalog_playback.dart';

/// Keeps playback going when the link the auto selector picked does not
/// start.
///
/// SourceChooser hands over the picked link together with the links to try
/// after it ([AutoLinkChoice.queue]: every other suitable direct link of the
/// wanted quality first, best first; only when all of those have failed, the
/// torrents of that quality, most seeders / peers first; then other
/// qualities). If the link fails to start, this switches to the next one
/// without leaving the loading screen: the loading logo starts over, and the
/// person never sees an exit, a retry of the same link, or the link list.
///
/// Failures are noticed fast: an open that throws is handled at once, an
/// error that leaves the player idle within about a second (see
/// [_confirmDead]), and a link that shows no picture within
/// [directStartDeadline] / [torrentStartDeadline] is dropped.
///
/// Addons that answer after playback has started keep feeding the list of
/// links still to try ([topUp]), so starting early never costs a fallback.
///
/// A failure is any of: the player could not open the stream, the open timed
/// out, a torrent could not be prepared, a direct link left the player idle
/// after an error, or (only while another link is left to try) no picture
/// appeared within [directStartDeadline] / [torrentStartDeadline]. Once
/// playback has really started this does nothing more, so a stream that
/// breaks mid-way is handled as before.
class LinkFallbackCoordinator {
  LinkFallbackCoordinator._();
  static final LinkFallbackCoordinator instance = LinkFallbackCoordinator._();

  /// How long a link may take to put a picture on screen before the next one
  /// is tried (only while there IS a next one; the last link keeps the
  /// player's own, longer limits).
  static const Duration directStartDeadline = Duration(seconds: 35);
  static const Duration torrentStartDeadline = Duration(seconds: 90);

  /// Player errors in the first moments of an attempt may still belong to the
  /// attempt before it, so they are not trusted.
  static const Duration _errorGrace = Duration(milliseconds: 500);

  /// A player error only counts as a failed open when mpv is still idle (no
  /// file loaded) at two checks this far apart.
  static const Duration _idleRecheck = Duration(milliseconds: 300);

  _Session? _session;

  /// Starts watching playback of [choice]. Call right before playback of
  /// [AutoLinkChoice.stream] begins. Replaces any earlier session.
  void begin({
    required CatalogTitle title,
    CatalogEpisode? episode,
    required AutoLinkChoice choice,
  }) {
    end();
    final session = _Session(
      title: title,
      episode: episode,
      itemId: CatalogPlayback.itemIdFor(title, episode),
      queue: List<AddonStream>.of(choice.queue),
    );
    _session = session;
    final player = PlayerManager.instance;
    player.openFailureRecovery = _recover;

    // Playback really started (the loading screen came down on this title):
    // nothing left to watch. A stream that breaks later is not a failed
    // start and keeps its normal handling.
    void settle() {
      if (!identical(_session, session) || session.advancing) return;
      if (!player.loading.value && player.currentItem?.id == session.itemId) {
        end();
      }
    }

    player.loading.addListener(settle);
    session.detach = () => player.loading.removeListener(settle);

    // A link that cannot be opened makes the player report an error. Waiting
    // for the player's own (slower) check made every dead direct link cost
    // seconds, so the error is looked at here as well.
    session.errorSub =
        player.player.stream.error.listen((m) => _onPlayerError(session, m));

    session.attemptStartedAt = DateTime.now();
    _armDeadline(session);
  }

  /// Stops watching (a new choice was made, the person picked a link
  /// themselves, or the player was closed).
  void end() {
    final session = _session;
    _session = null;
    session?.timer?.cancel();
    session?.detach?.call();
    session?.detach = null;
    unawaited(session?.errorSub?.cancel());
    session?.errorSub = null;
  }

  /// Links that arrived after playback of [title] / [episode] had started
  /// (the addons that answered last). They are ranked with everything known
  /// and the ones not tried yet are lined up behind the link being tried, so
  /// starting early never costs a fallback. Links already tried keep their
  /// place and are never tried again.
  void topUp({
    required CatalogTitle title,
    CatalogEpisode? episode,
    required List<AddonStream> streams,
    required PlaybackQualityMode mode,
    required LinkContext ctx,
  }) {
    final session = _session;
    if (session == null ||
        session.itemId != CatalogPlayback.itemIdFor(title, episode)) {
      return;
    }
    final choice = AutoLinkSelector.selectAlways(streams, mode, ctx: ctx);
    if (choice == null) return;

    final tried = session.queue.sublist(0, session.index + 1);
    final seen = tried.map(_keyOf).toSet();
    final tail = <AddonStream>[
      for (final s in choice.queue)
        if (seen.add(_keyOf(s))) s,
    ];
    if (tail.isEmpty) return;
    session.queue = [...tried, ...tail];

    // The link being tried had no deadline while it was the last one: now
    // there is a next link, so it gets one.
    final running = session.timer?.isActive ?? false;
    if (!session.advancing && !running) _armDeadline(session);
  }

  static String _keyOf(AddonStream s) => s.infoHash ?? s.url;

  /// Called by PlayerManager when an addon stream failed to open. True means
  /// the next link has been started and the caller must NOT close the player.
  Future<bool> _recover(MediaItem failed, String reason) async {
    final session = _session;
    if (session == null || failed.id != session.itemId) return false;
    // A switch is already under way; this is the old attempt reporting.
    if (session.advancing) return true;
    session.resumeAt ??= failed.playbackPosition;
    return _advance(session, reason);
  }

  /// Called by CatalogPlayback / VirtualPlayback when a torrent could not
  /// even be prepared (so the player never saw it). Same contract as
  /// [_recover].
  ///
  /// [resumeAt] is where the failed attempt was going to resume (null = from
  /// the beginning); the next link resumes from the same place.
  Future<bool> recoverFromResolveFailure(
    CatalogTitle title,
    CatalogEpisode? episode,
    String reason, {
    Duration? resumeAt,
  }) async {
    final session = _session;
    if (session == null ||
        session.itemId != CatalogPlayback.itemIdFor(title, episode)) {
      return false;
    }
    if (session.advancing) return true;
    session.resumeAt ??= resumeAt;
    return _advance(session, reason);
  }

  void _armDeadline(_Session session) {
    session.timer?.cancel();
    // The last link keeps the player's own, longer limits.
    if (session.index >= session.queue.length - 1) return;
    final attempt = session.index;
    final wait = session.queue[attempt].isTorrent
        ? torrentStartDeadline
        : directStartDeadline;
    session.timer = Timer(wait, () => _onDeadline(session, attempt));
  }

  void _onDeadline(_Session session, int attempt) {
    if (!identical(_session, session) ||
        session.index != attempt ||
        session.advancing) {
      return;
    }
    final player = PlayerManager.instance;
    final current = player.currentItem;
    // The person left: stop watching.
    if (current == null ||
        (!player.loading.value && current.id != session.itemId)) {
      end();
      return;
    }
    // The link is still being prepared (a torrent, before the player has the
    // real item): look again shortly.
    if (current.id != session.itemId) {
      session.timer = Timer(
        const Duration(seconds: 5),
        () => _onDeadline(session, attempt),
      );
      return;
    }
    // Started: loading is over, or a picture is already on screen.
    if (!player.loading.value || (player.player.state.width ?? 0) > 0) return;
    session.resumeAt ??= player.currentItem?.playbackPosition;
    unawaited(() async {
      final moved = await _advance(session, 'no picture after the start deadline');
      if (!moved) _giveUp(session);
    }());
  }

  /// A player error: if the link really could not be opened (mpv is idle and
  /// stays idle), move on to the next link within about a second instead of
  /// waiting for the player's own check.
  void _onPlayerError(_Session session, String message) {
    if (!identical(_session, session) ||
        session.advancing ||
        session.confirming) {
      return;
    }
    // The last link keeps the player's own handling. So does a torrent: it
    // can be idle for a long while before it is opened at all.
    if (session.index + 1 >= session.queue.length) return;
    if (session.queue[session.index].isTorrent) return;
    if (DateTime.now().difference(session.attemptStartedAt) < _errorGrace) {
      return;
    }
    if (!_isWatching(session, session.index)) return;
    final current = PlayerManager.instance.currentItem;
    if (current?.raw?['AddonStream'] != true) return;
    unawaited(_confirmDead(session, session.index, message));
  }

  bool _isWatching(_Session session, int attempt) {
    if (!identical(_session, session) ||
        session.advancing ||
        session.index != attempt) {
      return false;
    }
    final player = PlayerManager.instance;
    return player.loading.value && player.currentItem?.id == session.itemId;
  }

  Future<void> _confirmDead(
    _Session session,
    int attempt,
    String message,
  ) async {
    session.confirming = true;
    try {
      for (var check = 0; check < 2; check++) {
        await Future<void>.delayed(_idleRecheck);
        if (!_isWatching(session, attempt)) return;
        // Still loaded or already showing a picture: not a failed open (a
        // decoder warning, a reconnect...). The deadline still guards it.
        if (!await _playerIsIdle()) return;
        if ((PlayerManager.instance.player.state.width ?? 0) > 0) return;
      }
      if (!_isWatching(session, attempt)) return;
      session.resumeAt ??= PlayerManager.instance.currentItem?.playbackPosition;
      final moved = await _advance(session, 'could not be opened: $message');
      if (!moved) _giveUp(session);
    } finally {
      session.confirming = false;
    }
  }

  /// True only when mpv says nothing is loaded. When that cannot be read,
  /// false: no early switch, the normal checks still run.
  Future<bool> _playerIsIdle() async {
    try {
      final platform = PlayerManager.instance.player.platform;
      if (platform is NativePlayer) {
        return (await platform.getProperty('idle-active')).trim() == 'yes';
      }
    } catch (_) {}
    return false;
  }

  /// Every link is used up and the loading screen is still up (nothing else
  /// will close it): close it with a message, like a failed open does.
  void _giveUp(_Session session) {
    final player = PlayerManager.instance;
    if (player.currentItem?.id != session.itemId || !player.loading.value) {
      return;
    }
    final nav = ExternalMediaHandler.instance.navigatorKey.currentState;
    final ctx = nav?.overlay?.context;
    if (ctx != null) {
      ScaffoldMessenger.maybeOf(ctx)?.showSnackBar(const SnackBar(
        content: Text("Couldn't open any link for this title. "
            'Try again in a moment.'),
        duration: Duration(seconds: 8),
      ));
    }
    nav?.maybePop();
  }

  Future<bool> _advance(_Session session, String reason) async {
    session.advancing = true;
    session.timer?.cancel();
    try {
      while (session.index + 1 < session.queue.length) {
        final previous = session.queue[session.index];
        session.index++;
        final next = session.queue[session.index];
        debugPrint('[LinkFallback] ${previous.typeLabel} failed ($reason); '
            'trying ${next.typeLabel} ${next.qualityLabel}');
        final started = await _start(session, next, previous);
        if (!identical(_session, session)) return true; // the person left
        if (started) {
          _armDeadline(session);
          return true;
        }
        reason = 'could not be prepared';
      }
      end();
      return false; // nothing left: the normal "could not open" path runs
    } finally {
      session.advancing = false;
    }
  }

  /// Starts [stream] on the loading screen that is already up. True when it
  /// was handed to the player (or the person left meanwhile); false when it
  /// could not even be prepared, so the caller moves on to the next one.
  Future<bool> _start(
    _Session session,
    AddonStream stream,
    AddonStream previous,
  ) async {
    final player = PlayerManager.instance;
    final title = session.title;
    final episode = session.episode;

    // A fresh load: the loading screen stays, the logo starts over from the
    // beginning (and shows the link as chosen), as for any new playback.
    final preview = CatalogPlayback.buildItem(
      title: title,
      stream: stream,
      episode: episode,
      resumeAt: session.resumeAt,
    );
    player.showLoadingPreview(preview);
    PlaybackLoadProgress.instance.linkSelected(torrentHash: stream.infoHash);

    // Leaving the quality the setting asks for is worth telling the person
    // (once: if the first pick was already outside it, they were told).
    final wanted =
        AutoLinkSelector.wanted(AppSettings.playbackQualityMode.value);
    if (wanted.contains(previous.height) && !wanted.contains(stream.height)) {
      _announce(AutoLinkSelector.overrideMessage);
    }
    unawaited(SourcePreferences.instance
        .remember('${title.type.tmdb}:${title.tmdbId}', stream));

    try {
      // A direct link is handed to the player at once: subtitles are looked
      // up in parallel and attached once it plays.
      final prepared = await CatalogPlayback.buildItemForStart(
        title: title,
        stream: stream,
        episode: episode,
        resumeAt: session.resumeAt,
      );
      // Closed or replaced while the torrent was being prepared.
      if (!identical(_session, session) ||
          player.currentItem?.id != session.itemId) {
        end();
        return true;
      }
      // From here a failure of THIS link starts the next one.
      session.advancing = false;
      session.attemptStartedAt = DateTime.now();
      unawaited(PlaybackService.playQueue(
        [prepared.item],
        source: episode != null ? PlaybackSource.season : PlaybackSource.unknown,
        title: episode != null ? title.title : null,
        artwork: episode != null ? title.backdropUrl : null,
      ).then((_) => CatalogPlayback.attachSubtitlesWhenPlaying(prepared)));
      return true;
    } on TorrentException catch (e) {
      debugPrint('[LinkFallback] torrent not ready: ${e.message}');
      return false;
    } catch (e) {
      debugPrint('[LinkFallback] could not start link: $e');
      return false;
    }
  }

  static void _announce(String message) {
    final ctx = ExternalMediaHandler
        .instance.navigatorKey.currentState?.overlay?.context;
    if (ctx == null) return;
    final messenger = ScaffoldMessenger.maybeOf(ctx);
    messenger?.hideCurrentSnackBar();
    messenger?.showSnackBar(SnackBar(
      content: Text(message),
      duration: const Duration(seconds: 6),
      behavior: SnackBarBehavior.floating,
      backgroundColor: const Color(0xff1A1A1A),
    ));
  }
}

class _Session {
  _Session({
    required this.title,
    required this.episode,
    required this.itemId,
    required this.queue,
  });

  final CatalogTitle title;
  final CatalogEpisode? episode;

  /// The id the player gives every attempt of this title / episode.
  final String itemId;

  /// The links to try, best first; [index] is the one being tried. Grows
  /// when late addon answers arrive (see topUp); the part up to [index] never
  /// changes.
  List<AddonStream> queue;
  int index = 0;

  /// When the link being tried was handed to the player.
  DateTime attemptStartedAt = DateTime.now();

  /// True while a player error is being checked (see _confirmDead).
  bool confirming = false;

  /// True while the next link is being prepared, so a late failure report
  /// from the previous one is not mistaken for a failure of the new one.
  bool advancing = false;

  /// Where to resume, kept from the first attempt.
  Duration? resumeAt;
  Timer? timer;

  /// Removes the listener that notices playback has started.
  VoidCallback? detach;

  /// Listens to the player's errors while this session is running.
  StreamSubscription<String>? errorSub;
}
