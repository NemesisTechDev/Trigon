import 'dart:async';

import 'package:flutter/foundation.dart';

import '../player/models/media_item.dart';
import '../player/player_manager.dart';
import '../player/services/playback_queue.dart';
import '../services/jellyfin_services/media_service.dart';
import '../casting/cast_manager.dart';
import '../casting/playback_coordinator.dart';
import '../virtual/virtual_playback.dart';

/// Which episode a series' main Play button will start, and whether the
/// show counts as "in progress" (so the button reads "Continue Watching"
/// instead of "Start Watching"). See [PlaybackService.pickSeriesTarget].
class SeriesPlayTarget {
  final Map<String, dynamic> episode;
  final bool inProgress;
  const SeriesPlayTarget({required this.episode, required this.inProgress});

  int? get season => (episode['ParentIndexNumber'] as num?)?.toInt();
  int? get number => (episode['IndexNumber'] as num?)?.toInt();

  /// "Episode 4" (season 1 / unknown season) or "S2 · Episode 4". Null when
  /// the episode carries no number at all.
  String? get episodeLabel {
    final n = number;
    if (n == null || n <= 0) return null;
    final sn = season;
    return (sn != null && sn > 1) ? 'S$sn · Episode $n' : 'Episode $n';
  }
}

class PlaybackService {
  PlaybackService._();

  /// The transport's own reason for the most recent failed [_castVideo]
  /// (e.g. "the TV refused the stream", "the TV couldn't reach this phone"),
  /// or null when the last one succeeded. ROOT CAUSE (every video failure
  /// read as the same sentence): [_castVideo] swallowed the exception and
  /// returned false, and its callers then showed one fixed message, so the
  /// precise reason the DLNA transport produces never reached the person.
  static String? _lastCastVideoFailure;

  /// The message for a failed video cast: the transport's reason when there
  /// is one, else the old generic sentence.
  static String _videoCastFailureText(MediaItem item) =>
      _lastCastVideoFailure ?? '"${item.title}" couldn\'t be cast to the TV.';

  static Future<void> playItem(
      MediaItem item,
      ) async {
    // NAMESIS PRIME: titles from the virtual TMDB server have no stream of
    // their own; the person's addons provide it.
    if (VirtualPlayback.isVirtual(item)) {
      await VirtualPlayback.play(item);
      return;
    }

    // CASTING FIX: a song tapped while already casting should play on
    // the TV, not start a second, local playback of it — see
    // PlaybackCoordinator.playAudioQueueOnActiveCast's own doc comment
    // for why this is scoped to audio only. Falls through to the normal
    // local path below if nothing is actually connected, or if sending
    // it to the TV failed for some reason (e.g. a local-only file).
    if (item.audioOnly && CastManager.instance.isCasting) {
      final redirected = await PlaybackCoordinator.instance
          .playAudioQueueOnActiveCast([item]);
      if (redirected || CastManager.instance.isCasting) return;
      debugPrint(
        'CASTING DEBUG: playItem("${item.title}") fell back to LOCAL '
        'playback after a failed cast redirect — see the '
        'CASTING DEBUG lines above from playAudioQueueOnActiveCast for '
        'why.',
      );
    } else if (!item.audioOnly && CastManager.instance.isCasting) {
      // CASTING FIX (video/live redirect): previously this app
      // deliberately left every non-audio Play button alone while
      // casting (see PlaybackCoordinator's own top-level doc comment,
      // "If 'Play always goes to whatever I'm connected to, everywhere'
      // turns out to be the wanted behavior, that's a deliberate, larger
      // product decision for a later phase") — that decision has now
      // been made explicitly: a movie, episode, or live channel started
      // from any Play/Continue Watching/Watch Live entry point while a
      // TV is connected should go straight to that TV, the same way a
      // song already does, instead of starting a second, local playback
      // that has nothing to do with what's on screen. `_castVideo`
      // handles the actual redirect (and, per its own doc comment,
      // replacing whatever the TV is already showing first).
      final redirected = await _castVideo(item);
      if (redirected) {
        // CASTING FIX (episode-list button/panel invisible while
        // casting): _castVideo only ever sends this one item straight
        // to CastManager — it never touches PlaybackQueue. Every
        // cast-aware UI surface that cares about "what's the current
        // queue" (PlayerTopBar's episode-list toggle, EpisodeListPanel's
        // list, PlaybackCoordinator.castJumpTo) reads PlaybackQueue
        // directly, the same as it does for local playback, so leaving
        // it stale/untouched here meant none of those ever had anything
        // to show for a Play tap that got redirected straight to an
        // already-casting session. Mirrors exactly what the
        // un-redirected local path below already does for a single
        // item.
        PlaybackQueue.instance.setQueue(
          [item],
          source: PlaybackSource.unknown,
        );
        return;
      }

      // NO LOCAL AUDIO WHILE CASTING: a failed send used to fall through
      // to local playback, putting the title's audio on the phone while
      // the session stayed connected. While a session is still live the
      // TV is the only place playback belongs — report and stop.
      if (CastManager.instance.isCasting) {
        _clearOrphanedLocalLoadingState(PlayerManager.instance);
        PlaybackCoordinator.instance.reportCastFailure(
          _videoCastFailureText(item),
        );
        return;
      }
      debugPrint(
        'CASTING DEBUG: playItem("${item.title}") fell back to LOCAL '
        'playback after a failed video cast redirect.',
      );
    }

    PlaybackQueue.instance.setQueue(
      [item],
      source: PlaybackSource.unknown,
    );

    await PlayerManager.instance.playMedia(item);
  }

  /// Sends a single non-audio [item] (movie, episode, or live channel)
  /// straight to the already-connected cast session, replacing whatever
  /// it's currently showing — [CastManager.loadAndPlay] always loads a
  /// fresh source on the receiver, which is what "dismisses" anything
  /// already playing there; there's no separate stop-then-load step
  /// needed. Also pauses local mpv first if it happened to be playing
  /// something else, the same "never let two things play at once"
  /// guard [PlaybackCoordinator.playAudioQueueOnActiveCast] already
  /// applies for audio.
  ///
  /// Returns true if the item was sent to the TV (the caller should not
  /// also start local playback); false if nothing is connected or the
  /// send failed, in which case the caller falls back to local playback
  /// so the tap still does something.
  static Future<bool> _castVideo(MediaItem item) async {
    if (!CastManager.instance.isCasting) return false;

    final manager = PlayerManager.instance;
    if (manager.playing.value) {
      unawaited(manager.player.pause());
    }

    // LOCAL VIDEO CAST, SESSION ALREADY CONNECTED (Open With/Play With):
    // the connect-time handoff in PlaybackCoordinator never runs here (the
    // TV was connected before the file was opened), so without this the
    // coordinator never learned this video is a local one — no sidecar
    // subtitle reached the TV and the Subtitles sheet fell back to its
    // Jellyfin-server layout with nothing in it. Mirrors the handoff's
    // own subtitle preparation; see
    // PlaybackCoordinator.prepareExternalVideoForActiveCast.
    final isExternalVideo = item.isLocal &&
        !item.audioOnly &&
        !item.live &&
        item.raw?['IsExternalFile'] == true;

    _lastCastVideoFailure = null;
    try {
      if (isExternalVideo) {
        // Subtitle/audio-track bookkeeping is a nicety: if it throws (an
        // addon stream has no on-device file to probe, say) the video must
        // still be sent to the TV rather than the whole cast being aborted.
        try {
          await PlaybackCoordinator.instance
              .prepareExternalVideoForActiveCast(item);
        } catch (e) {
          debugPrint(
            'CASTING DEBUG: external video preparation failed, casting '
            'without track sync: $e',
          );
          PlaybackCoordinator.instance.cancelLocalVideoCastFor(item);
        }
      } else {
        PlaybackCoordinator.instance.releaseLocalVideoCastFor(item);
      }

      // RESUME FIX: `item.playbackPosition` is the same field
      // `PlayerManager.playMedia()` seeks to for local playback (see
      // MediaItem.copyWith's doc comment) — it's already populated from
      // Jellyfin's UserData.PlaybackPositionTicks for anything opened
      // from Continue Watching/a resume point. Casting never read it
      // before this, so `loadAndPlay` fell back to its `startAt:
      // Duration.zero` default and every cast redirect — Continue
      // Watching included — always started the item over from the top
      // instead of resuming where it left off.
      // PHASE 1: see CastManager.loadSeq.
      final expectedSeq = CastManager.instance.loadSeq + 1;
      await CastManager.instance.loadAndPlay(
        item,
        startAt: item.playbackPosition ?? Duration.zero,
      );
      _clearOrphanedLocalLoadingState(manager);
      if (CastManager.instance.loadSeq != expectedSeq) {
        // A newer load overtook this one on the TV: it owns the mirror and
        // the queue now, so this stale item must not overwrite them.
        debugPrint('CASTING DEBUG: _castVideo("${item.title}") was '
            'overtaken by a newer cast load — not mirroring it');
        return true;
      }

      // CASTING FIX (switching titles while casting looks stale until
      // the player screen is dismissed and reopened): this used to
      // leave every local, PlayerManager-facing notifier completely
      // untouched on a successful redirect — fine for the *first* item
      // sent to an already-connected session (nothing local to update
      // yet), but wrong for every switch after that. `CastManager
      // .loadAndPlay()` above already updated the session's own
      // `currentItem` correctly (that's what the video-casting mini
      // player bar reads, and it does update live) — but
      // VideoPlayerScreen's own backdrop/title fall back to whichever
      // item PlayerManager's `currentItemNotifier` was last pointed at
      // *before* falling back to the session's item (see its own
      // `item ?? castItem` — now `castItem ?? item` — doc comment),
      // and that notifier was still sitting on whatever was cast (or
      // played locally) first. `beginCastMirror` is the same "make
      // every local, PlayerManager-driven surface reflect what's
      // actually on the cast session" entry point the audio redirect
      // path already uses (`playAudioQueueOnActiveCast`) — reusing it
      // here for video keeps the two paths consistent and fixes the
      // stale backdrop/title without needing the person to back out
      // of the player screen and reopen it just to force a refresh.
      manager.beginCastMirror(item);

      if (isExternalVideo) {
        try {
          await PlaybackCoordinator.instance.startDirectLocalCastSync(item);
        } catch (e) {
          debugPrint(
            'CASTING DEBUG: local cast subtitle sync failed to start: $e',
          );
        }
      }
      return true;
    } catch (e) {
      if (isExternalVideo) {
        PlaybackCoordinator.instance.cancelLocalVideoCastFor(item);
      }
      // The real reason, for the snackbar the callers show (see
      // [_lastCastVideoFailure]) as well as the log.
      _lastCastVideoFailure = PlaybackCoordinator.instance.castFailureText(
        e,
        item.title,
        deviceName: CastManager.instance.activeSession.value?.device.displayName,
      );
      debugPrint('CASTING DEBUG: _castVideo("${item.title}") failed: $e');
      debugPrint('CASTING DEBUG: -> shown to the person as: '
          '$_lastCastVideoFailure');
      return false;
    }
  }

  /// CASTING FIX (stuck "loading" screen / controls vanishing on the
  /// video-casting mini player): every Play/Continue Watching/Watch
  /// Live entry point calls `PlayerManager.instance.showLoadingPreview
  /// (item)` — which sets the *local* `loading` flag true — immediately
  /// before firing off this whole `playItem`/`playQueue` call, so the
  /// local player screen (if it were opening) has something to show
  /// while the network resolves. That flag is normally cleared a moment
  /// later by `PlayerManager.playMedia()`/`playQueue()` once the real
  /// local stream opens — but a successful cast redirect returns before
  /// ever reaching that call, so `loading` (and `buffering`, set by the
  /// same local-playback path) was left permanently stuck true with
  /// nothing left to ever clear it.
  ///
  /// That orphaned true stuck around invisibly for as long as nothing
  /// read it — until the video-casting mini player was tapped open:
  /// `PlayerOverlayLayer`'s `LoadingOverlay` renders an opaque backdrop
  /// + pulsing logo any time `loading` is true, and
  /// `PlayerControlsLayer` refuses to show controls at all while
  /// `loading`/`buffering` is true — both of them reacting to *local*
  /// mpv state that's meaningless once what's actually on screen is a
  /// cast session, and both painted on top of the casting backdrop/
  /// controls. That's what "sometimes shows a loading screen instead of
  /// the casting screen" and "controls disappear completely" actually
  /// were — not two different bugs, just this one orphaned flag being
  /// read by two different pieces of UI.
  static void _clearOrphanedLocalLoadingState(PlayerManager manager) {
    manager.loading.value = false;
    manager.buffering.value = false;
  }

  /// Entry point for playback started from a raw Jellyfin item map coming
  /// from a list endpoint — Continue Watching or the home hero carousel —
  /// rather than from a detail screen that already assembled a full
  /// season/series queue itself.
  ///
  /// Detail screens build a proper multi-item queue (source `season` or
  /// `series`) before starting playback, which is what makes the in-player
  /// episode list, and next/previous episode controls work. Continue
  /// Watching and the hero carousel used to skip straight to
  /// [playItem] with just the single tapped item, so none of that queue
  /// context existed — this mirrors the detail-screen flow instead so
  /// playback started from anywhere behaves the same.
  static Future<void> playLibraryItem(
      Map<String, dynamic> item,
      ) async {
    final type = item["Type"];

    if (type == "Episode") {
      final played = await _playEpisodeQueue(
        seriesId: item["SeriesId"]?.toString(),
        seasonId: item["SeasonId"]?.toString(),
        episodeId: item["Id"].toString(),
        title: item["SeriesName"]?.toString(),
      );

      if (played) return;

      // No seriesId/seasonId on the item (shouldn't normally happen for
      // an Episode) — fall back to single-item playback below rather
      // than failing outright.
    }

    if (type == "Series") {
      final played = await _playSeriesFromResumeOrStart(item);
      if (played) return;
    }

    final media = MediaService.mediaItemFromJellyfin(
      Map<String, dynamic>.from(item),
    );

    await playItem(media);
  }

  /// Loads the full sibling-episode list for [seasonId] and starts
  /// playback queued at [episodeId], exactly like tapping an episode from
  /// a season's episode list on the detail screen. Returns false (without
  /// side effects) if the episode couldn't be resolved this way, so the
  /// caller can fall back to single-item playback.
  static Future<bool> _playEpisodeQueue({
    required String? seriesId,
    required String? seasonId,
    required String episodeId,
    String? title,
    int? preferredIndex,
  }) async {
    if (seriesId == null || seasonId == null) return false;

    try {
      final episodes = await MediaService.getEpisodes(seriesId, seasonId);

      final index = preferredIndex ??
          episodes.indexWhere((e) => e["Id"].toString() == episodeId);

      if (index == -1 || episodes.isEmpty) return false;

      final queue = MediaService.mediaItemsFromList(episodes);

      await playQueue(
        queue,
        startIndex: index,
        source: PlaybackSource.season,
        title: title,
      );

      return true;
    } catch (_) {
      return false;
    }
  }

  /// Decides which episode a series' Play button starts, across ALL
  /// seasons (specials / season 0 are ignored unless they're all there is):
  ///  • the first episode with a saved resume position, else
  ///  • the first unwatched episode, else
  ///  • the very first episode (everything already watched).
  /// [SeriesPlayTarget.inProgress] is true when something is mid-way, or
  /// some episodes are watched and an unwatched one remains — i.e. the
  /// button should say "Continue Watching" rather than "Start Watching".
  static SeriesPlayTarget? pickSeriesTarget(List<dynamic> all) {
    final eps = all
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    if (eps.isEmpty) return null;

    int seasonOf(Map e) => (e['ParentIndexNumber'] as num?)?.toInt() ?? 1;
    int numberOf(Map e) => (e['IndexNumber'] as num?)?.toInt() ?? 0;

    final regular = eps.where((e) => seasonOf(e) != 0).toList();
    final source = regular.isNotEmpty ? regular : eps;

    // Stable sort by (season, episode) — keeps server order for ties.
    final indexed = source.asMap().entries.toList()
      ..sort((a, b) {
        var c = seasonOf(a.value).compareTo(seasonOf(b.value));
        if (c == 0) c = numberOf(a.value).compareTo(numberOf(b.value));
        return c != 0 ? c : a.key.compareTo(b.key);
      });
    final pool = indexed.map((e) => e.value).toList();

    bool hasTicks(Map e) =>
        ((e['UserData']?['PlaybackPositionTicks'] as num?) ?? 0) > 0;
    bool isPlayed(Map e) => e['UserData']?['Played'] == true;

    Map<String, dynamic>? resume;
    Map<String, dynamic>? unwatched;
    var anyProgress = false;
    for (final e in pool) {
      if (hasTicks(e)) {
        resume ??= e;
        anyProgress = true;
      }
      if (isPlayed(e)) {
        anyProgress = true;
      } else {
        unwatched ??= e;
      }
    }

    final target = resume ?? unwatched ?? pool.first;
    final inProgress = resume != null || (unwatched != null && anyProgress);
    return SeriesPlayTarget(episode: target, inProgress: inProgress);
  }

  /// Network version of [pickSeriesTarget] — one request for the whole
  /// series. Returns null when the server can't be reached or has no
  /// episodes, so callers can fall back.
  static Future<SeriesPlayTarget?> resolveSeriesTarget(
    Map<String, dynamic> series,
  ) async {
    final seriesId = series["Id"]?.toString();
    if (seriesId == null) return null;
    try {
      final episodes = await MediaService.getSeriesEpisodesForDownload(
        seriesId,
        withSources: false,
      );
      return pickSeriesTarget(episodes);
    } catch (_) {
      return null;
    }
  }

  /// Resolves a Series-type item (as returned by the hero carousel) to an
  /// actual playable episode — the in-progress one if there is a resume
  /// point, otherwise the first unwatched episode, otherwise the very
  /// first episode of the first season — then starts it via the same
  /// queued playback as [_playEpisodeQueue].
  static Future<bool> _playSeriesFromResumeOrStart(
      Map<String, dynamic> series,
      ) async {
    final seriesId = series["Id"]?.toString();
    if (seriesId == null) return false;

    // Same episode the detail screen's button label names (checked across
    // every season, not just the first one that has episodes).
    final target = await resolveSeriesTarget(series);
    if (target != null) {
      final played = await _playEpisodeQueue(
        seriesId: seriesId,
        seasonId: target.episode["SeasonId"]?.toString(),
        episodeId: target.episode["Id"].toString(),
        title: series["Name"]?.toString(),
      );
      if (played) return true;
    }

    try {
      final seasons = await MediaService.getSeasons(seriesId);

      for (final season in seasons) {
        final seasonId = season["Id"]?.toString();
        if (seasonId == null) continue;

        final episodes = await MediaService.getEpisodes(seriesId, seasonId);
        if (episodes.isEmpty) continue;

        final resumeIndex = episodes.indexWhere((e) {
          final ticks = e["UserData"]?["PlaybackPositionTicks"] ?? 0;
          return ticks > 0;
        });

        final unwatchedIndex = episodes.indexWhere(
          (e) => e["UserData"]?["Played"] != true,
        );

        final startIndex = resumeIndex != -1
            ? resumeIndex
            : (unwatchedIndex != -1 ? unwatchedIndex : 0);

        final queue = MediaService.mediaItemsFromList(episodes);

        await playQueue(
          queue,
          startIndex: startIndex,
          source: PlaybackSource.season,
          title: series["Name"]?.toString(),
        );

        return true;
      }
    } catch (_) {
      // Fall through to returning false below.
    }

    return false;
  }

  static Future<void> playQueue(
      List<MediaItem> items, {
        int startIndex = 0,
        PlaybackSource source = PlaybackSource.unknown,
        String? title,
        String? artwork,
      }) async {
    if (items.isEmpty) return;

    // NAMESIS PRIME: see playItem. Of a virtual season queue only the tapped
    // episode is played; BingeCoordinator lines up the next one afterwards.
    final startItem = items[startIndex.clamp(0, items.length - 1)];
    if (VirtualPlayback.isVirtual(startItem)) {
      await VirtualPlayback.play(startItem);
      return;
    }

    // CASTING FIX: same redirect as playItem() above, for the
    // multi-item entry point every Play/Continue Watching/season-list
    // entry point actually calls (episode lists, series Play, TV
    // guide/live channel entry points, and every song/album/playlist
    // screen). A queue is only ever redirected when every item in it is
    // the same "kind" (all audio, or all video/live) — a mixed queue
    // (shouldn't normally happen) falls through to local playback
    // rather than guessing which half of it the TV should get.
    if (CastManager.instance.isCasting) {
      final nonAudioCount = items.where((i) => !i.audioOnly).length;

      if (nonAudioCount == items.length) {
        // All non-audio — a movie's single-item "queue", or a season/
        // series episode list. Same redirect decision as playItem()'s
        // video branch, just for the multi-item case — see
        // _castVideoQueue's own doc comment for why this always sends
        // just the tapped item via the same single-item load every
        // movie already uses, rather than the TV's own queue support.
        final redirected = await _castVideoQueue(
          items,
          startIndex: startIndex,
        );
        if (redirected) {
          // CASTING FIX (episode-list button/panel invisible while
          // casting): same reasoning as playItem() above —
          // _castVideoQueue only ever sends the single tapped episode
          // to the TV via _castVideo; it never populates PlaybackQueue
          // with the rest of the season/series. Populating it here
          // (source/title/artwork/startIndex, exactly like the
          // un-redirected local path a few lines down already does)
          // keeps PlaybackQueue accurate as the queue of record even
          // when the actual playback command went to a TV instead of
          // local mpv — which is what PlayerTopBar's episode-list
          // toggle, EpisodeListPanel, and
          // PlaybackCoordinator.castJumpTo all depend on.
          PlaybackQueue.instance.setQueue(
            items,
            startIndex: startIndex,
            source: source,
            title: title,
            artwork: artwork,
          );
          return;
        }
        // NO LOCAL AUDIO WHILE CASTING: see playItem() — a failed send
        // never falls back to local playback while still connected.
        if (CastManager.instance.isCasting) {
          _clearOrphanedLocalLoadingState(PlayerManager.instance);
          PlaybackCoordinator.instance.reportCastFailure(
            _videoCastFailureText(
              items[startIndex.clamp(0, items.length - 1)],
            ),
          );
          return;
        }
        debugPrint(
          'CASTING DEBUG: playQueue() fell back to LOCAL playback after '
          'a failed video cast redirect — source=$source, title=$title.',
        );
      } else if (nonAudioCount > 0) {
        // DEBUG (tap-to-redirect investigation): this is the most likely
        // silent-failure mode for Songs/Most Played/Favorites/Search/
        // Playlist — if even one item in the queue isn't flagged
        // audioOnly (missing/unexpected "Type" or "MediaType" on that
        // particular song's raw Jellyfin map), the `every()` check below
        // fails for the WHOLE queue and every song in it plays locally,
        // not just the odd one out.
        debugPrint(
          'CASTING DEBUG: playQueue() skipped the cast redirect — '
          '$nonAudioCount of ${items.length} item(s) in this queue are '
          'not flagged audioOnly (and not all of them are either), so '
          'this looks like a mixed queue. source=$source, title=$title',
        );

        // NO LOCAL AUDIO WHILE CASTING: a mixed queue used to fall
        // through to local playback. Cast just the tapped item's kind
        // instead (the same rule as a pure queue), never the phone.
        final tappedIndex = startIndex.clamp(0, items.length - 1);
        final tapped = items[tappedIndex];
        if (tapped.audioOnly) {
          final sameKind = items.where((i) => i.audioOnly).toList();
          final idx = sameKind.indexWhere((i) => identical(i, tapped));
          await PlaybackCoordinator.instance.playAudioQueueOnActiveCast(
            sameKind,
            startIndex: idx < 0 ? 0 : idx,
            source: source,
            title: title,
            artwork: artwork,
          );
        } else {
          final sent = await _castVideoQueue([tapped]);
          if (sent) {
            PlaybackQueue.instance.setQueue(
              [tapped],
              source: source,
              title: title,
              artwork: artwork,
            );
          } else {
            _clearOrphanedLocalLoadingState(PlayerManager.instance);
            PlaybackCoordinator.instance.reportCastFailure(
              _videoCastFailureText(tapped),
            );
          }
        }
        if (CastManager.instance.isCasting) return;
      } else {
        final redirected = await PlaybackCoordinator.instance
            .playAudioQueueOnActiveCast(
          items,
          startIndex: startIndex,
          source: source,
          title: title,
          artwork: artwork,
        );
        if (redirected || CastManager.instance.isCasting) return;
        debugPrint(
          'CASTING DEBUG: playQueue() fell back to LOCAL playback after '
          'a failed cast redirect — source=$source, title=$title. See '
          'the CASTING DEBUG lines above for why.',
        );
      }
    }

    await PlayerManager.instance.playQueue(
      items,
      startIndex: startIndex,
      source: source,
      title: title,
      artwork: artwork,
    );
  }

  /// Queue counterpart to [_castVideo].
  ///
  /// CASTING FIX (episode selection stops the old item without starting
  /// the new one): this used to try `CastManager.playQueue()` — each
  /// transport's `loadQueue()` — first, with a single-item `loadAndPlay`
  /// fallback only if that threw. For Nemesis Native, `loadQueue()`
  /// itself says why that's unsafe for video: it's a fire-and-forget
  /// WebSocket send with no acknowledgment from the TV at all (see its
  /// own doc comment — "stays unverified-against-a-real-receiver"),
  /// unlike the single-item `load()`/`loadAndPlay()` path `CastToButton`
  /// already uses successfully for movies. `await`ing that send only
  /// ever confirms the phone handed a message to the socket, never that
  /// the TV actually loaded anything — so a queue send "succeeding"
  /// (never throwing) tore down whatever was already casting without
  /// reliably starting the new episode, exactly matching "dismisses the
  /// current one without playing the selected one". Jellyfin Remote's
  /// own `loadQueue` does properly await a real HTTP response, but
  /// `session.capability.queue` doesn't distinguish which transport is
  /// live — going straight to the same well-tested single-item load
  /// [_castVideo] already uses for movies is the one path confirmed
  /// solid across all three transports, at the cost of the TV's own
  /// next/previous not knowing about sibling episodes (in-app
  /// next/previous, driven by [PlaybackQueue], is unaffected).
  static Future<bool> _castVideoQueue(
    List<MediaItem> items, {
    int startIndex = 0,
  }) async {
    final redirected = await _castVideo(
      items[startIndex.clamp(0, items.length - 1)],
    );
    return redirected;
  }

  /// Resolves a raw Jellyfin item map into the actual playable
  /// [MediaItem] it represents — mirrors [playLibraryItem]'s Episode/
  /// Series resolution, but only resolves; it never starts local
  /// playback and never touches [PlaybackQueue]/[PlayerManager].
  ///
  /// Added for Casting Phase 7's "Cast" action on Movie/Show details:
  /// the master prompt requires that action to "let the user send
  /// content directly to a TV without first playing it locally", but a
  /// Series item (like a Play tap) has no media source of its own —
  /// `CastManager.loadAndPlay()` needs a real resolved [MediaItem] up
  /// front, the same way [playLibraryItem] resolves one for local
  /// playback. Deliberately duplicates the read-only season/episode
  /// lookups in [_playEpisodeQueue]/[_playSeriesFromResumeOrStart] rather
  /// than refactoring those to share code with this — both of those are
  /// already-shipped, already-tested paths for the existing local Play
  /// button, and this is a new, narrower need (no queue, no
  /// PlayerManager side effects) with different enough semantics
  /// (returns instead of starting playback) that reusing them exactly
  /// would mean threading a "don't actually play" flag through
  /// PlayerManager-facing code — a bigger, riskier change to a working
  /// system than a few duplicated GET calls.
  static Future<MediaItem> resolveLibraryItem(
      Map<String, dynamic> item,
      ) async {
    final type = item["Type"];

    if (type == "Episode") {
      final resolved = await _resolveEpisode(
        seriesId: item["SeriesId"]?.toString(),
        seasonId: item["SeasonId"]?.toString(),
        episodeId: item["Id"].toString(),
      );
      if (resolved != null) return resolved;
    }

    if (type == "Series") {
      final resolved = await _resolveSeriesFromResumeOrStart(item);
      if (resolved != null) return resolved;
    }

    return MediaService.mediaItemFromJellyfin(
      Map<String, dynamic>.from(item),
    );
  }

  /// Read-only counterpart to [_playEpisodeQueue] — looks up the same
  /// sibling-episode list just to confirm/refresh this one episode's own
  /// record (Jellyfin's list endpoints return fresher UserData/resume
  /// position than a stale item map a screen might be holding), without
  /// building a queue or starting playback.
  static Future<MediaItem?> _resolveEpisode({
    required String? seriesId,
    required String? seasonId,
    required String episodeId,
  }) async {
    if (seriesId == null || seasonId == null) return null;

    try {
      final episodes = await MediaService.getEpisodes(seriesId, seasonId);
      final index = episodes.indexWhere((e) => e["Id"].toString() == episodeId);
      if (index == -1) return null;

      return MediaService.mediaItemFromJellyfin(
        Map<String, dynamic>.from(episodes[index]),
      );
    } catch (_) {
      return null;
    }
  }

  /// Read-only counterpart to [_playSeriesFromResumeOrStart] — same
  /// in-progress/first-unwatched/S1E1 resolution, but returns the
  /// resolved episode instead of queuing and playing it.
  static Future<MediaItem?> _resolveSeriesFromResumeOrStart(
      Map<String, dynamic> series,
      ) async {
    final seriesId = series["Id"]?.toString();
    if (seriesId == null) return null;

    final target = await resolveSeriesTarget(series);
    if (target != null) {
      return MediaService.mediaItemFromJellyfin(target.episode);
    }

    try {
      final seasons = await MediaService.getSeasons(seriesId);

      for (final season in seasons) {
        final seasonId = season["Id"]?.toString();
        if (seasonId == null) continue;

        final episodes = await MediaService.getEpisodes(seriesId, seasonId);
        if (episodes.isEmpty) continue;

        final resumeIndex = episodes.indexWhere((e) {
          final ticks = e["UserData"]?["PlaybackPositionTicks"] ?? 0;
          return ticks > 0;
        });

        final unwatchedIndex = episodes.indexWhere(
          (e) => e["UserData"]?["Played"] != true,
        );

        final startIndex = resumeIndex != -1
            ? resumeIndex
            : (unwatchedIndex != -1 ? unwatchedIndex : 0);

        return MediaService.mediaItemFromJellyfin(
          Map<String, dynamic>.from(episodes[startIndex]),
        );
      }
    } catch (_) {
      // Fall through to returning null below.
    }

    return null;
  }
}

