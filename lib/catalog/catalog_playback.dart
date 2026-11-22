import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../addons/addon_manager.dart';
import '../addons/addon_models.dart';
import '../casting/cast_manager.dart';
import '../library/source_preferences.dart';
import '../library/watch_entry.dart';
import '../library/watch_history_service.dart';
import '../player/models/media_item.dart';
import '../player/playback_service.dart';
import '../player/player_manager.dart';
import '../player/screens/player_navigation.dart';
import '../player/services/playback_queue.dart';
import '../services/external_media_handler.dart';
import '../services/jellyfin_services/media_service.dart';
import '../virtual/virtual_catalog.dart';
import '../torrent/torrent_engine.dart';
import 'catalog_models.dart';
import 'link_fallback.dart';

/// An item ready to play plus the subtitle lookup still running for it (see
/// [CatalogPlayback.buildItemForStart]).
class PreparedItem {
  const PreparedItem(this.item, this.pendingSubtitles);

  final MediaItem item;

  /// Null when the subtitles were already waited for (casting).
  final Future<List<Map<String, String>>>? pendingSubtitles;
}

/// Bridge from "the person picked a stream" to the existing player.
///
/// The player was written around Jellyfin items, but it already has a path
/// for media that is *not* on a Jellyfin server (Android's Open With). An
/// addon stream is exactly that kind of item, so it is built the same way:
/// `raw['IsLocal']` + `raw['IsExternalFile']` make PlayerManager skip every
/// Jellyfin-only step (quality transcoding, server progress reports) and just
/// open `streamUrl` in mpv.
///
/// Extra keys in `raw` (all prefixed so they can't clash with Jellyfin's):
///  - `AddonStream`   true for every item built here
///  - `NamesisTitle`  TitleSnapshot JSON, read by WatchHistoryService and
///                    BingeCoordinator
///  - `NamesisEpisode` episode JSON (episodes only)
///  - `HttpHeaders`   request headers the addon asked for (see PHASE3.md for
///                    the one-line PlayerManager patch that applies them)
class CatalogPlayback {
  CatalogPlayback._();

  /// The id every attempt at playing [title] / [episode] gets, whichever
  /// link it uses (LinkFallbackCoordinator matches failures by it).
  static String itemIdFor(CatalogTitle title, CatalogEpisode? episode) =>
      episode != null
          ? 'addon_tv_${title.tmdbId}_s${episode.season}e${episode.number}'
          : 'addon_${title.type.tmdb}_${title.tmdbId}';

  static MediaItem buildItem({
    required CatalogTitle title,
    required AddonStream stream,
    CatalogEpisode? episode,
    List<Map<String, String>> subtitles = const [],
    Duration? resumeAt,
  }) {
    // Dart does not promote `episode` through a bool variable, so keep a
    // local that is checked directly.
    final ep = episode;
    final id = itemIdFor(title, ep);

    final runtimeMinutes =
        ep != null ? (ep.runtime ?? title.runtime) : title.runtime;
    final runtime = Duration(minutes: runtimeMinutes ?? 0);

    // Same convention Jellyfin episodes use, which the player's own
    // "Next episode" card expects: title = episode name, subtitle = show.
    final displayTitle = ep != null ? ep.name : title.title;
    final displaySubtitle =
        ep != null ? title.title : (title.year?.toString() ?? '');

    // What the player's Info sheet reads (same keys a Jellyfin item has).
    final vid =
        '${title.type == CatalogType.movie ? 'm' : 's'}${title.tmdbId}';
    final cert = VirtualCatalog.certificationFor(vid);
    final imdb = title.imdbId;

    final raw = <String, dynamic>{
      'Id': id,
      'Name': displayTitle,
      'SeriesName': title.title,
      'Overview': (ep != null && ep.overview.isNotEmpty)
          ? ep.overview
          : title.overview,
      if (title.year != null) 'ProductionYear': title.year,
      if (cert != null && cert.isNotEmpty) 'OfficialRating': cert,
      'Genres': title.genres,
      'ProviderIds': {
        'Tmdb': title.tmdbId.toString(),
        if (imdb != null && imdb.isNotEmpty) 'Imdb': imdb,
      },
      if (ep != null && imdb != null && imdb.isNotEmpty)
        'SeriesImdbId': imdb,
      if (ep != null && cert != null && cert.isNotEmpty)
        'SeriesOfficialRating': cert,
      'Type': ep != null ? 'Episode' : 'Movie',
      'RunTimeTicks': runtime.inMicroseconds * 10,
      'IsLocal': true,
      'IsExternalFile': true,
      'AddonStream': true,
      if (stream.viaTorrent) 'IsTorrent': true,
      // Read by the player's Quality sheet to mark the quality now playing.
      'StreamHeight': stream.height,
      'LocalUri': stream.url,
      'MimeType': _mimeFor(stream.url),
      if (_extFor(stream) != null) 'FileExtension': _extFor(stream),
      'TmdbId': title.tmdbId,
      'UserData': {'IsFavorite': false, 'PlayCount': 0},
      'NamesisTitle': TitleSnapshot.of(title).toJson(),
      if (ep != null) 'NamesisEpisode': episodeToRaw(ep),
      if (stream.headers.isNotEmpty) 'HttpHeaders': stream.headers,
      if (subtitles.isNotEmpty) 'SidecarSubtitles': subtitles,
    };

    return MediaItem(
      id: id,
      title: displayTitle,
      subtitle: displaySubtitle,
      streamUrl: stream.url,
      image: ep != null
          ? (TmdbImages.still(ep.stillPath) ?? title.posterUrl)
          : title.posterUrl,
      // w1280, not the grid's w780: this fills the whole player loading
      // screen, and w780 stretched edge to edge looks soft.
      backdrop: TmdbImages.backdrop(title.backdropPath, size: 'w1280') ??
          title.backdropUrl,
      logo: _logoFor(title),
      seriesImage: ep != null ? title.posterUrl : null,
      // NAMESIS PRIME: the same ids the virtual server uses, so the in-player
      // episode panel can list every season and episode of this show.
      seriesId: ep != null ? VId.seriesOf(title.tmdbId) : null,
      seasonId: ep != null ? VId.seasonOf(title.tmdbId, ep.season) : null,
      seasonNumber: ep?.season,
      episodeNumber: ep?.number,
      runtime: runtime,
      playbackPosition: resumeAt,
      raw: raw,
    );
  }

  /// Quality change while watching: plays [stream] (the best source of the
  /// quality the person picked) in place of the current one, continuing from
  /// the same moment.
  ///
  /// A torrent can take a while to find peers, so the current stream keeps
  /// playing until the new one is ready; if it cannot start, the person keeps
  /// watching and gets a message instead of a dead player.
  static Future<void> switchSource({
    required MediaItem current,
    required CatalogTitle title,
    required AddonStream stream,
    CatalogEpisode? episode,
  }) async {
    final manager = PlayerManager.instance;
    final startedId = current.id;
    final position = manager.position.value;
    final resumeAt =
        position > const Duration(seconds: 3) ? position : null;

    void say(String message, {int seconds = 4}) {
      final ctx = ExternalMediaHandler
          .instance.navigatorKey.currentState?.overlay?.context;
      if (ctx == null) return;
      final messenger = ScaffoldMessenger.maybeOf(ctx);
      messenger?.hideCurrentSnackBar();
      messenger?.showSnackBar(SnackBar(
        content: Text(message),
        duration: Duration(seconds: seconds),
        behavior: SnackBarBehavior.floating,
        backgroundColor: const Color(0xff1A1A1A),
      ));
    }

    final label =
        stream.qualityLabel.isEmpty ? 'this source' : stream.qualityLabel;
    say(
      stream.isTorrent
          ? 'Switching to $label. Finding peers, playback continues meanwhile.'
          : 'Switching to $label\u2026',
      seconds: stream.isTorrent ? 8 : 3,
    );

    try {
      unawaited(SourcePreferences.instance
          .remember('${title.type.tmdb}:${title.tmdbId}', stream));

      final item = await buildItemResolved(
        title: title,
        stream: stream,
        episode: episode,
        resumeAt: resumeAt,
      );

      // The person may have closed the player or moved on while this loaded.
      if (manager.currentItem?.id != startedId) return;

      await PlaybackService.playQueue([item], source: PlaybackSource.unknown);
    } on TorrentException catch (e) {
      say(e.message, seconds: 8);
    } catch (e) {
      debugPrint('[CatalogPlayback] quality switch failed: $e');
      say('Could not switch quality. Still playing the previous one.');
    }
  }

  /// Like [buildItem] but also fetches subtitles (bounded to a few seconds).
  /// Used for items that are queued ahead of time.
  static Future<MediaItem> buildItemResolved({
    required CatalogTitle title,
    required AddonStream stream,
    CatalogEpisode? episode,
    Duration? resumeAt,
  }) async {
    // A torrent source is first turned into a local http address by the
    // torrent engine (throws TorrentException with a readable message).
    final resolvedStream =
        await TorrentEngine.instance.resolve(stream, episode: episode);
    final subs = await _loadSubtitles(title, resolvedStream, episode)
        .timeout(const Duration(seconds: 4), onTimeout: () => const []);
    return buildItem(
      title: title,
      stream: resolvedStream,
      episode: episode,
      subtitles: subs,
      resumeAt: resumeAt,
    );
  }

  /// For STARTING playback on a loading screen that is already up (first
  /// link, or the next link after one failed): never waits for subtitles.
  /// They are looked up in parallel with the torrent engine and attached once
  /// the video plays ([attachSubtitlesWhenPlaying]), exactly as [play] does.
  /// While casting they are waited for, because a cast session is sent the
  /// subtitles together with the item.
  ///
  /// A direct link is therefore handed to the player at once. A torrent is
  /// first turned into a local address by the torrent engine (throws
  /// TorrentException with a readable message).
  static Future<PreparedItem> buildItemForStart({
    required CatalogTitle title,
    required AddonStream stream,
    CatalogEpisode? episode,
    Duration? resumeAt,
  }) async {
    final subsFuture = _loadSubtitles(title, stream, episode)
        .timeout(const Duration(seconds: 4), onTimeout: () => const []);
    final playStream = stream.isTorrent
        ? await TorrentEngine.instance.resolve(stream, episode: episode)
        : stream;
    final casting = CastManager.instance.isCasting;
    final subsNow = casting ? await subsFuture : const <Map<String, String>>[];
    final item = buildItem(
      title: title,
      stream: playStream,
      episode: episode,
      subtitles: subsNow,
      resumeAt: resumeAt,
    );
    return PreparedItem(item, casting ? null : subsFuture);
  }

  /// Adds the subtitles found by [buildItemForStart] once the item is really
  /// playing. Call right after the item was handed to the player.
  static void attachSubtitlesWhenPlaying(PreparedItem prepared) {
    final subs = prepared.pendingSubtitles;
    if (subs == null) return;
    unawaited(_attachSubtitlesLater(prepared.item, subs));
  }

  /// Opens the player screen immediately (so the person sees a loading state
  /// right away), then starts playback. Resumes where the person stopped
  /// unless [startOver] is true.
  ///
  /// Progress tracking and next-episode queueing are not started here: they
  /// react to the playing item (see WatchHistoryService / BingeCoordinator),
  /// so they work the same when the next episode auto-starts.
  static Future<void> play(
    BuildContext context, {
    required CatalogTitle title,
    required AddonStream stream,
    CatalogEpisode? episode,
    bool startOver = false,
  }) async {
    // Remember this choice so next time (and the next episode) can reuse it.
    unawaited(SourcePreferences.instance
        .remember('${title.type.tmdb}:${title.tmdbId}', stream));

    // Where the person stopped last time (null = from the beginning).
    final resumeAt = startOver
        ? null
        : WatchHistoryService.instance.positionFor(title, episode);

    final preview = buildItem(
      title: title,
      stream: stream,
      episode: episode,
      resumeAt: resumeAt,
    );
    PlayerManager.instance.showLoadingPreview(preview);

    // Playback must never wait for subtitles. They start looking right now,
    // in parallel with the torrent engine, and are attached once the video
    // is playing (see _attachSubtitlesLater). Before, the lookup ran only
    // AFTER the torrent was ready and held playback back for up to 4 s on
    // every start.
    unawaited(() async {
      final clock = Stopwatch()..start();
      final subsFuture = _loadSubtitles(title, stream, episode)
          .timeout(const Duration(seconds: 4), onTimeout: () => const []);

      AddonStream playStream = stream;
      if (stream.isTorrent) {
        try {
          playStream =
              await TorrentEngine.instance.resolve(stream, episode: episode);
        } catch (e) {
          // The auto selector may have another link to try: the loading
          // screen stays and playback moves on to it.
          if (await LinkFallbackCoordinator.instance.recoverFromResolveFailure(
              title, episode, e is TorrentException ? e.message : '$e',
              resumeAt: resumeAt)) {
            return;
          }
          final nav = ExternalMediaHandler.instance.navigatorKey.currentState;
          final ctx = nav?.overlay?.context;
          if (ctx != null) {
            ScaffoldMessenger.maybeOf(ctx)?.showSnackBar(SnackBar(
              content: Text(e is TorrentException
                  ? e.message
                  : 'Could not start the torrent.'),
              duration: const Duration(seconds: 8),
            ));
          }
          nav?.maybePop();
          return;
        }
        debugPrint('[CatalogPlayback] torrent resolved in '
            '${clock.elapsedMilliseconds} ms');
      }

      // A cast session is sent the subtitles together with the item, so
      // only then are they waited for.
      final casting = CastManager.instance.isCasting;
      final subsNow = casting ? await subsFuture : const <Map<String, String>>[];
      final item = buildItem(
        title: title,
        stream: playStream,
        episode: episode,
        subtitles: subsNow,
        resumeAt: resumeAt,
      );
      await PlaybackService.playQueue([item], source: PlaybackSource.unknown);
      if (!casting) unawaited(_attachSubtitlesLater(item, subsFuture));
    }());

    // PlayerNavigation.open completes only when the player screen closes,
    // so it must come last.
    if (!context.mounted) return;
    await PlayerNavigation.open(context);
  }

  // ---------- helpers ----------

  /// Adds the subtitles found for [item] once it is really playing (the
  /// loading screen is gone), the same way Open With adds the subtitle files
  /// it finds next to a video.
  static Future<void> _attachSubtitlesLater(
    MediaItem item,
    Future<List<Map<String, String>>> subsFuture,
  ) async {
    try {
      final subs = await subsFuture;
      if (subs.isEmpty) return;
      final manager = PlayerManager.instance;
      if (manager.loading.value) {
        final done = Completer<void>();
        void listener() {
          if (!manager.loading.value && !done.isCompleted) done.complete();
        }

        manager.loading.addListener(listener);
        try {
          await done.future.timeout(const Duration(seconds: 300), onTimeout: () {});
        } finally {
          manager.loading.removeListener(listener);
        }
      }
      if (manager.currentItem?.id != item.id) return;
      await manager.applyLateSidecarSubtitles(item, subs);
    } catch (e) {
      debugPrint('[CatalogPlayback] late subtitles failed: $e');
    }
  }

  /// The title's logo, for the pulsing-logo loading and buffering screens.
  /// Uses the same virtual id the detail screen used, so the logo path that
  /// screen registered is found. Null when none is known.
  static String? _logoFor(CatalogTitle title) {
    final vid =
        '${title.type == CatalogType.movie ? 'm' : 's'}${title.tmdbId}';
    final url = MediaService.getLogoUrl(vid);
    return url.contains('/no-image/') ? null : url;
  }

  /// Real container extension (mkv, mp4...) from the addon's file name or the
  /// link's path; null when neither says. Casting depends on it.
  static String? _extFor(AddonStream stream) {
    final re = RegExp(r'\.([A-Za-z0-9]{1,5})$');
    final name = stream.fileName?.trim() ?? '';
    var m = re.firstMatch(name);
    if (m == null) {
      final path = Uri.tryParse(stream.url)?.path ?? '';
      m = re.firstMatch(path);
    }
    return m?.group(1)?.toLowerCase();
  }

  static String _mimeFor(String url) {
    final path = (Uri.tryParse(url)?.path ?? url).toLowerCase();
    if (path.endsWith('.mkv')) return 'video/x-matroska';
    if (path.endsWith('.webm')) return 'video/webm';
    if (path.endsWith('.m3u8')) return 'application/x-mpegURL';
    if (path.endsWith('.mov')) return 'video/quicktime';
    return 'video/mp4';
  }

  static final Dio _subDio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 4),
      receiveTimeout: const Duration(seconds: 4),
      responseType: ResponseType.plain,
      validateStatus: (_) => true,
    ),
  );

  /// Collects subtitle files from the stream itself plus any addon that
  /// serves `subtitles`, downloads up to three (English first), and returns
  /// them in the `{content, fileName}` shape PlayerManager's sidecar
  /// subtitle loader already understands.
  static Future<List<Map<String, String>>> _loadSubtitles(
    CatalogTitle title,
    AddonStream stream,
    CatalogEpisode? episode,
  ) async {
    try {
      final id = episode != null
          ? title.addonId(season: episode.season, episode: episode.number)
          : title.addonId();
      final fromAddons =
          await AddonManager.instance.subtitlesFor(title.type.addon, id);

      final all = <AddonSubtitle>[...stream.subtitles, ...fromAddons];
      if (all.isEmpty) return const [];

      bool isEnglish(AddonSubtitle s) => s.lang.toLowerCase().startsWith('en');
      all.sort(
          (a, b) => (isEnglish(b) ? 1 : 0).compareTo(isEnglish(a) ? 1 : 0));

      final seen = <String>{};
      final picked = all.where((s) => seen.add(s.url)).take(3).toList();

      // All files at once (they used to be fetched one after another).
      final fetched = await Future.wait(picked.map((s) async {
        try {
          final res = await _subDio.get<String>(s.url);
          final text = res.data;
          if (res.statusCode != 200 || text == null || text.isEmpty) {
            return null;
          }
          if (text.length > 2 * 1024 * 1024) return null;
          return <String, String>{
            'content': text,
            'fileName': '${s.lang.toUpperCase()}${_subExt(s.url)}',
          };
        } catch (_) {
          return null;
        }
      }));
      final out = fetched.whereType<Map<String, String>>().toList();
      return out;
    } catch (e) {
      debugPrint('[CatalogPlayback] subtitle load failed: $e');
      return const [];
    }
  }

  static String _subExt(String url) {
    final p = (Uri.tryParse(url)?.path ?? '').toLowerCase();
    for (final ext in const ['.vtt', '.ass', '.ssa', '.srt']) {
      if (p.endsWith(ext)) return ext;
    }
    return '.srt';
  }
}
