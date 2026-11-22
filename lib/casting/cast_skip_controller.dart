import 'dart:async';

import 'package:flutter/foundation.dart';

import '../player/models/media_item.dart';
import '../player/models/skip_segment.dart';
import '../player/services/segment_service.dart';
import '../player/player_manager.dart';
import '../player/services/movie_recommendation_service.dart';
import '../player/services/playback_queue.dart';
import '../player/services/show_recommendation_service.dart';
import '../services/app_settings.dart';
import '../services/download_manager.dart';
import '../services/jellyfin_services/media_service.dart';
import 'cast_manager.dart';
import 'models/cast_session.dart';
import 'models/cast_states.dart';

/// Keeps the video player screen's Skip Intro / Skip Credits pill and its
/// Next Episode / Next Show / Next Movie cards alive while a video is being
/// cast, for every transport (DLNA/UPnP, Google Cast, Jellyfin Remote,
/// Nemesis Native).
///
/// WHY THIS EXISTS: those widgets are drawn by [PlayerOverlayLayer] from
/// notifiers on [PlayerManager] (`activeSkipSegment`, `showNextEpisode`, ...)
/// that are only ever written by PlayerManager's own local mpv position
/// listener. While a video is cast, mpv is paused (or never opened), so that
/// listener goes silent and the widgets never appeared. This controller is
/// the cast-side equivalent of that listener: it watches the CAST SESSION's
/// position/duration/current item and writes the very same notifiers, so the
/// existing widgets (look, placement, dismiss behaviour) are reused as-is.
///
/// The trigger rules deliberately mirror PlayerManager's position listener
/// (real Outro segment start, falling back to the last 25 s of an episode /
/// 5 min of a movie, same recommendations setting, same "arm only once a
/// tick plausibly belongs to the new item" guard). What it never does:
/// touch local mpv, report playback progress, or mark anything watched —
/// that all stays with the transports and the existing cast code.
///
/// Actions: Skip seeks the TV through [CastManager.seek]; "Play now" goes
/// through [PlayerManager.playNext]/[PlayerManager.playMedia], which while a
/// cast session is connected already divert to the TV
/// (see PlayerManager.playMedia / PlaybackCoordinator._redirectLocalPlayToCast).
class CastSkipController {
  CastSkipController._();

  static final CastSkipController instance = CastSkipController._();

  bool _initialized = false;

  CastSession? _session;

  // ---- per cast item state -------------------------------------------------
  String? _itemId;
  MediaItem? _item;
  List<SkipSegment> _segments = const [];

  /// Bumped on every item/session change so a late async result (segment
  /// fetch, recommendation fetch) for a previous item can never apply.
  int _epoch = 0;

  DateTime _itemChangedAt = DateTime.now();
  Duration _positionAtChange = Duration.zero;
  Duration _startHint = Duration.zero;
  bool _armed = false;

  bool _nextEpisodeShown = false;
  bool _nextShowShown = false;
  bool _nextMovieShown = false;

  /// The segment whose Skip button was just pressed — hidden until the TV
  /// has moved past it, so the optimistic seek landing exactly on
  /// `segment.end` (still inside the inclusive [start, end] window) can't
  /// make the button flash straight back.
  SkipSegment? _skippedSegment;

  /// True once this controller has written PlayerManager's notifiers, so it
  /// knows it has something to clean up when the session ends.
  bool _drivingNotifiers = false;

  // The notifiers a few listeners below are attached to.
  CastSession? _listening;

  void init() {
    if (_initialized) return;
    _initialized = true;
    CastManager.instance.activeSession.addListener(_onActiveSessionChanged);
    _onActiveSessionChanged();
  }

  /// True while a connected cast session holds a real, non-live video — i.e.
  /// while this controller (not PlayerManager's local listener) owns the skip
  /// / next-up widgets. [PlayerOverlayLayer] uses it to route the widget
  /// actions to the TV instead of local mpv.
  bool get isDriving {
    final session = _session;
    final item = _item;
    return session != null &&
        session.isConnected &&
        item != null &&
        !item.audioOnly &&
        !item.live;
  }

  // ---------------------------------------------------------------------
  // Session / item tracking
  // ---------------------------------------------------------------------

  void _onActiveSessionChanged() {
    final session = CastManager.instance.activeSession.value;
    if (identical(session, _session)) return;

    _detach();
    _epoch++;
    _resetItemState();
    if (_drivingNotifiers) _clearNotifiers();

    _session = session;
    if (session == null) return;

    session.currentItem.addListener(_onItemChanged);
    session.position.addListener(_evaluate);
    session.connectionState.addListener(_evaluate);
    session.capabilityNotifier.addListener(_evaluate);
    session.playbackState.addListener(_evaluate);
    _listening = session;

    _onItemChanged();
  }

  void _detach() {
    final old = _listening;
    _listening = null;
    if (old == null) return;
    // CastManager.disconnect() disposes the session's notifiers before
    // activeSession flips to null (see PlaybackCoordinator's own note on
    // this) — removing listeners from an already-disposed notifier must
    // never take the app down.
    try {
      old.currentItem.removeListener(_onItemChanged);
      old.position.removeListener(_evaluate);
      old.connectionState.removeListener(_evaluate);
      old.capabilityNotifier.removeListener(_evaluate);
      old.playbackState.removeListener(_evaluate);
    } catch (_) {}
  }

  void _resetItemState() {
    _itemId = null;
    _item = null;
    _segments = const [];
    _armed = false;
    _nextEpisodeShown = false;
    _nextShowShown = false;
    _nextMovieShown = false;
    _skippedSegment = null;
  }

  void _onItemChanged() {
    final session = _session;
    if (session == null) return;

    final item = session.currentItem.value;

    // Same item re-published (CastManager backfills mediaStreams/trickplay
    // into currentItem after load) — keep all per-item state, just refresh
    // the reference.
    if (item != null && item.id == _itemId) {
      _item = item;
      return;
    }

    _epoch++;
    final epoch = _epoch;

    _resetItemState();
    // A new cast video takes over from whatever local playback last left in
    // these notifiers (handoff mid-outro, previous cast item's cards, ...).
    final takesOver = item != null && !item.audioOnly && !item.live;
    if (_drivingNotifiers || takesOver) _clearNotifiers();

    _itemId = item?.id;
    _item = item;

    if (item == null) return;

    _itemChangedAt = DateTime.now();
    _positionAtChange = session.position.value;
    _startHint = item.playbackPosition ?? Duration.zero;

    if (!takesOver) return;

    _segments = item.skipSegments;
    if (_segments.isEmpty) {
      unawaited(_loadSegments(item, epoch));
    }

    _evaluate();
  }

  Future<void> _loadSegments(MediaItem item, int epoch) async {
    List<SkipSegment> segments;
    try {
      if (item.raw?['AddonStream'] == true) {
        // Addon titles: community database + manual button (chapters can't
        // be read while the TV is playing).
        segments = SegmentService.compose(
          item: item,
          community: await SegmentService.community(item),
        );
      } else {
        segments = await MediaService.getSkipSegments(item.id);
      }
    } catch (_) {
      return;
    }
    if (epoch != _epoch || _itemId != item.id) return;
    _segments = segments;
    _evaluate();
  }

  // ---------------------------------------------------------------------
  // Trigger evaluation (cast-side twin of PlayerManager's position listener)
  // ---------------------------------------------------------------------

  void _evaluate() {
    final session = _session;
    final item = _item;

    if (session == null ||
        item == null ||
        item.audioOnly ||
        item.live ||
        !session.isConnected) {
      if (_drivingNotifiers) _clearNotifiers();
      return;
    }

    final manager = PlayerManager.instance;
    final position = session.position.value;

    // Jellyfin's own runtime wins over whatever the receiver reports (a
    // transcoded stream can report a partial/odd duration) — same rule the
    // local player follows. Falls back to the receiver's value only when the
    // item has no runtime.
    final total =
        item.runtime > Duration.zero ? item.runtime : session.duration.value;

    // Arm only once a position sample plausibly belongs to THIS item. Right
    // after an item switch the session can still be reporting the previous
    // item's position (near its end — that is where Next Episode fires),
    // which would otherwise instantly trigger the card for the item after.
    if (!_armed) {
      final since = DateTime.now().difference(_itemChangedAt);
      if (position <= _startHint + const Duration(seconds: 10) ||
          position + const Duration(seconds: 5) < _positionAtChange ||
          (session.playbackState.value == CastPlaybackState.playing &&
              since >= const Duration(seconds: 6))) {
        _armed = true;
      }
    }

    _drivingNotifiers = true;

    // ---- Skip Intro / Skip Credits -----------------------------------------
    SkipSegment? segment;
    if (_armed && session.capability.seek) {
      for (final s in _segments) {
        if (position >= s.start && position <= s.end) {
          segment = s;
          break;
        }
      }
    }

    final skipped = _skippedSegment;
    if (skipped != null) {
      if (position > skipped.end) {
        _skippedSegment = null;
      } else if (segment != null && _sameSegment(segment, skipped)) {
        segment = null;
      }
    }

    _set(manager.activeSkipSegment, segment);

    // ---- Next Episode / Next Show / Next Movie -----------------------------
    SkipSegment? outro;
    for (final s in _segments) {
      if (s.type == SkipSegmentType.outro) {
        outro = s;
        break;
      }
    }
    // Same implausible-data guard as the local listener: a real credits
    // segment never starts before the halfway point.
    if (outro != null && outro.start < total * 0.5) outro = null;

    final reachedRealOutro = _armed && outro != null && position >= outro.start;
    final reachedFallback = _armed &&
        outro == null &&
        total > Duration.zero &&
        position >= total - const Duration(seconds: 25);
    final reachedMovieFallback = _armed &&
        outro == null &&
        total > Duration.zero &&
        position >= total - const Duration(seconds: 300);

    // PlaybackQueue is only trustworthy for decisions here when it is
    // actually the queue THIS cast item belongs to — a direct "Cast to" from a
    // details screen never builds one, and the queue may still hold whatever
    // was played before.
    final queue = PlaybackQueue.instance;
    final queueMatches = queue.current?.id == item.id;
    final isEpisodeQueue = queueMatches &&
        (queue.source == PlaybackSource.season ||
            queue.source == PlaybackSource.series);
    final hasNext = queueMatches && queue.hasNext;
    final isEpisodeItem = item.seriesId != null || item.episodeNumber != null;

    if (isEpisodeQueue &&
        hasNext &&
        !_nextEpisodeShown &&
        !_nextShowShown &&
        (reachedRealOutro || reachedFallback)) {
      _nextEpisodeShown = true;
      manager.nextEpisode.value = queue.items[queue.currentIndex + 1];
      manager.showNextEpisode.value = true;
    }

    if (isEpisodeQueue &&
        !hasNext &&
        !_nextShowShown &&
        AppSettings.autoQueueRecommendations.value &&
        (reachedRealOutro || reachedFallback)) {
      // Set before the fetch, not after it resolves — this runs on every
      // position tick.
      _nextShowShown = true;
      unawaited(_showNextShow(item, _epoch));
    }

    if (!isEpisodeQueue &&
        !isEpisodeItem &&
        !hasNext &&
        !_nextMovieShown &&
        AppSettings.autoQueueRecommendations.value &&
        (reachedRealOutro || reachedMovieFallback)) {
      _nextMovieShown = true;
      unawaited(_showNextMovie(item, _epoch));
    }
  }

  Future<void> _showNextMovie(MediaItem finished, int epoch) async {
    final queue = PlaybackQueue.instance;
    final alreadyQueued = queue.items.map((i) => i.id).toSet();

    MediaItem? recommendation;
    try {
      if (DownloadManager.instance.isDownloaded(finished.id)) {
        recommendation = MovieRecommendationService.instance
            .recommendNextDownloaded(finished, exclude: alreadyQueued);
      } else {
        recommendation = await MovieRecommendationService.instance
            .recommendNext(finished, exclude: alreadyQueued)
            .catchError((_) => null);
      }
    } catch (_) {
      recommendation = null;
    }

    if (epoch != _epoch || _itemId != finished.id) return;
    if (recommendation == null) return;

    // Only a queue that really contains this movie gets the recommendation
    // appended (so Dismiss/auto-continue behave exactly like local). A
    // direct "Cast to" has no such queue and must not have an unrelated one
    // — e.g. a paused song's — modified; Play now plays the pick directly
    // instead (see [playRecommendation]).
    if (queue.current?.id == finished.id) {
      queue.appendRecommendations([recommendation]);
    }

    final manager = PlayerManager.instance;
    manager.nextMovieRecommendation.value = recommendation;
    manager.showNextMovie.value = true;
  }

  Future<void> _showNextShow(MediaItem finished, int epoch) async {
    final queue = PlaybackQueue.instance;
    final alreadyQueued = queue.items.map((i) => i.id).toSet();

    MediaItem? recommendation;
    try {
      if (DownloadManager.instance.isDownloaded(finished.id)) {
        recommendation = ShowRecommendationService.instance
            .recommendNextDownloaded(finished, exclude: alreadyQueued);
      } else {
        recommendation = await ShowRecommendationService.instance
            .recommendNext(finished, exclude: alreadyQueued)
            .catchError((_) => null);
      }
    } catch (_) {
      recommendation = null;
    }

    if (epoch != _epoch || _itemId != finished.id) return;
    if (recommendation == null) return;

    // Only reachable for an episode queue that contains this episode (see
    // _evaluate), so appending is always safe here.
    if (queue.current?.id == finished.id) {
      queue.appendRecommendations([recommendation]);
    }

    final manager = PlayerManager.instance;
    manager.nextShowRecommendation.value = recommendation;
    manager.showNextShow.value = true;
  }

  // ---------------------------------------------------------------------
  // Actions (called by PlayerOverlayLayer while [isDriving])
  // ---------------------------------------------------------------------

  /// Skip Intro / Skip Credits: seeks the TV to the end of [segment].
  /// Throws what [CastManager.seek] throws (unsupported / unreachable) so
  /// the caller can surface it; the button comes back in that case.
  Future<void> skip(SkipSegment segment) async {
    final session = _session;
    if (session == null) return;

    final item = _item;
    final total = (item != null && item.runtime > Duration.zero)
        ? item.runtime
        : session.duration.value;

    var target = segment.manual
        ? session.position.value + const Duration(seconds: 85)
        : segment.end;
    // Seeking onto/past the very end of the file makes some receivers
    // reject the command or end the item outright — stop just short of it.
    if (total > const Duration(seconds: 2) && target >= total) {
      target = total - const Duration(seconds: 1);
    }

    _skippedSegment = segment;
    _set(PlayerManager.instance.activeSkipSegment, null);

    try {
      await CastManager.instance.seek(target);
    } catch (_) {
      // The seek never happened — bring the button back.
      _skippedSegment = null;
      _evaluate();
      rethrow;
    }
  }

  /// Play now for a Next Movie / Next Show card while casting.
  ///
  /// When the recommendation sits right after the current item in the queue
  /// that item belongs to, this is exactly the local behaviour
  /// ([PlayerManager.playNext] — moves the queue and, because a cast session
  /// is connected, sends the item to the TV). Otherwise (a direct "Cast to"
  /// with no queue of its own) the pick is simply played on the TV.
  Future<void> playRecommendation(MediaItem recommendation) async {
    final manager = PlayerManager.instance;
    final queue = PlaybackQueue.instance;

    final next = queue.hasNext && queue.currentIndex >= 0
        ? queue.items[queue.currentIndex + 1]
        : null;

    if (queue.current?.id == _itemId && next?.id == recommendation.id) {
      await manager.playNext();
    } else {
      await manager.playMedia(recommendation, resume: false);
    }
  }

  // ---------------------------------------------------------------------
  // helpers
  // ---------------------------------------------------------------------

  bool _sameSegment(SkipSegment a, SkipSegment b) =>
      a.type == b.type && a.start == b.start && a.end == b.end;

  void _set<T>(ValueNotifier<T> notifier, T value) {
    if (notifier.value != value) notifier.value = value;
  }

  void _clearNotifiers() {
    final manager = PlayerManager.instance;
    _drivingNotifiers = false;
    _set<SkipSegment?>(manager.activeSkipSegment, null);
    _set<bool>(manager.showNextEpisode, false);
    _set<MediaItem?>(manager.nextEpisode, null);
    _set<bool>(manager.showNextShow, false);
    _set<MediaItem?>(manager.nextShowRecommendation, null);
    _set<bool>(manager.showNextMovie, false);
    _set<MediaItem?>(manager.nextMovieRecommendation, null);
  }
}
