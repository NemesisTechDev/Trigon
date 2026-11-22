import 'dart:async';

import 'package:flutter/foundation.dart';

import 'cache/library_cache.dart';
import 'jellyfin_services/jellyfin_client.dart';
import 'jellyfin_services/media_service.dart';

/// The single definition of every list request behind the Movies grid, the
/// Music tabs and Live TV, so a screen and the background prewarm
/// ([LibraryPrefetcher]) always ask for byte-identical data under the same
/// cache key — and, via [LibraryCache.fetch]'s in-flight sharing, never
/// download the same list twice when they overlap.
class LibraryFeeds {
  LibraryFeeds._();

  static const String librariesKey = 'movies_libraries_v1';
  static const String musicLibraryKey = 'music_library_v1';

  /// Grouped Live TV payload ({channels, programs}) kept in memory so
  /// LiveTvScreen can paint in its very first frame. Its persistent copy is
  /// the existing SharedPreferences blob (StorageService.getLiveTvCache).
  static const String liveTvKey = 'livetv_v1';
  static const String _liveTvChannelsKey = 'livetv_channels_v1';
  static const String _liveTvGuideKey = 'livetv_guide_v1';

  // ---- Movies / TV Shows ------------------------------------------------

  static String movieKey({
    required String mode,
    required String? libraryId,
    required String sort,
  }) =>
      'movies_v2_${mode}_${libraryId ?? 'all'}_$sort';

  static Future<List<dynamic>> libraries() =>
      LibraryCache.instance.fetch(librariesKey, MediaService.getLibraries);

  /// [library] is a raw Jellyfin library map (or null for "all").
  static Future<List<dynamic>> movies({
    required String mode,
    required dynamic library,
    required String sort,
  }) {
    final libraryId = library?["Id"]?.toString();
    final isCollectionLibrary =
        library?["CollectionType"]?.toString().toLowerCase() == "boxsets";

    return LibraryCache.instance.fetch(
      movieKey(mode: mode, libraryId: libraryId, sort: sort),
      () => MediaService.getItems(
        parentId: libraryId,
        includeItemTypes: isCollectionLibrary
            ? "BoxSet"
            : mode == "movies"
                ? "Movie"
                : "Series",
        sortBy: sort,
        sortOrder: sort == "SortName" ? "Ascending" : "Descending",
        // The grid only needs poster/title/year/rating, and the detail
        // screen re-fetches the full record itself. The default Fields
        // list also asked for MediaSources + MediaStreams (every audio,
        // video and subtitle track of every title) for up to 500 titles —
        // by far the biggest part of this response.
        fields: MediaService.movieGridFields,
      ),
    );
  }

  /// NAMESIS PRIME: the first screenful only (60 titles = 3 TMDB pages in
  /// parallel), so a grid shows something after one round trip while
  /// [movies] keeps loading the full list. Not cached under the main key.
  static Future<List<dynamic>> moviesQuick({
    required String mode,
    required dynamic library,
    required String sort,
  }) {
    final libraryId = library?["Id"]?.toString();
    final isCollectionLibrary =
        library?["CollectionType"]?.toString().toLowerCase() == "boxsets";
    return MediaService.getItems(
      parentId: libraryId,
      includeItemTypes: isCollectionLibrary
          ? "BoxSet"
          : mode == "movies"
              ? "Movie"
              : "Series",
      sortBy: sort,
      sortOrder: sort == "SortName" ? "Ascending" : "Descending",
      fields: MediaService.movieGridFields,
      limit: 60,
    );
  }

  // ---- Music ------------------------------------------------------------

  static String musicKey(String tab, String sort) => 'music_v1_${tab}_$sort';

  /// The Music library id as a one-element list ([] when there's none).
  static Future<List<dynamic>> musicLibrary() =>
      LibraryCache.instance.fetch(musicLibraryKey, () async {
        final library = await MediaService.getMusicLibrary();
        return library == null ? <dynamic>[] : <dynamic>[library];
      });

  /// Server-backed Music tabs only (albums / artists / songs / playlists /
  /// mostPlayed — "localFiles" is a device scan and is never cached here).
  /// [tab] and [sort] are MusicTab.name / MusicSort.name.
  static Future<List<dynamic>> musicTab({
    required String tab,
    required String sort,
    required String? libraryId,
    required Map<String, String> sortQuery,
  }) {
    final sortBy = sortQuery["sortBy"]!;
    final sortOrder = sortQuery["sortOrder"]!;

    // Every tab except playlists is scoped to the Music library. Until its
    // id is known the answer is simply "nothing yet" — returned WITHOUT
    // going through the cache, so an empty placeholder is never persisted
    // and then shown as a real empty library on the next launch.
    if (tab != 'playlists' && libraryId == null) {
      return Future<List<dynamic>>.value(<dynamic>[]);
    }

    return LibraryCache.instance.fetch(musicKey(tab, sort), () async {
      switch (tab) {
        case 'albums':
          return MediaService.getMusicAlbums(
            parentId: libraryId,
            sortBy: sortBy,
            sortOrder: sortOrder,
          );
        case 'artists':
          return MediaService.getAlbumArtists(
            parentId: libraryId,
            sortBy: sortBy,
            sortOrder: sortOrder,
          );
        case 'songs':
          return MediaService.getSongs(
            parentId: libraryId,
            sortBy: sortBy,
            sortOrder: sortOrder,
          );
        case 'mostPlayed':
          return MediaService.getMostPlayedSongs(parentId: libraryId);
        case 'playlists':
          return MediaService.getPlaylists(
            sortBy: sortBy,
            sortOrder: sortOrder,
          );
      }
      return <dynamic>[];
    });
  }

  // ---- Live TV ----------------------------------------------------------

  static Future<List<dynamic>> liveTvChannels() => LibraryCache.instance.fetch(
        _liveTvChannelsKey,
        () async => List<dynamic>.from(await MediaService.getLiveTvChannels()),
        persist: false,
      );

  /// "Now + next" guide window for [channelIds], same 3-hour window the
  /// Live TV screen always used.
  static Future<List<dynamic>> liveTvGuide(List<String> channelIds) =>
      LibraryCache.instance.fetch(
        _liveTvGuideKey,
        () => MediaService.getGuide(
          end: DateTime.now().add(const Duration(hours: 3)),
          channelIds: channelIds,
        ),
        persist: false,
      );

  /// Groups a flat guide list by channel id (the shape LiveTvScreen and its
  /// persisted cache use).
  static Map<String, dynamic> groupGuide(List<dynamic> guide) {
    final programs = <String, dynamic>{};
    for (final program in guide) {
      final channelId = program["ChannelId"];
      programs.putIfAbsent(channelId, () => []);
      programs[channelId].add(program);
    }
    return programs;
  }
}

/// Warms the data behind the Movies, Music and Live TV tabs in the
/// background shortly after launch, so by the time one of those tabs is
/// tapped its content is already in memory and paints in the first frame.
///
/// Deliberately DATA ONLY — it never builds a tab's widget tree (MainNavScreen
/// builds tabs lazily on purpose, to keep Home's first paint and rotation
/// cheap). Requests run strictly one at a time with a short pause between
/// them, JSON decoding is done off the UI thread (Dio's background
/// transformer for the network, compute() for the disk cache), so this never
/// competes with scrolling or animations.
class LibraryPrefetcher {
  LibraryPrefetcher._();

  // Which account + cache generation the current warm-up belongs to, so
  // signing in as someone else, or clearing the cache, warms again.
  static String? _startedFor;

  /// Call once when the main shell appears. Immediately loads the copies
  /// persisted by the previous session into memory (cheap: local files,
  /// decoded off the UI thread), so even a tab tapped in the first seconds
  /// paints from them; then, a few seconds later (after Home has settled),
  /// refreshes everything from the server one request at a time.
  /// Safe to call repeatedly; it only does anything once per account (and
  /// again after the cache is cleared).
  static Future<void> start() async {
    final scope = '${JellyfinClient.serverUrl}|${JellyfinClient.userId}|'
        '${LibraryCache.instance.generation}';
    if (_startedFor == scope) return;
    _startedFor = scope;

    try {
      await _loadPersistedCopies();
    } catch (e) {
      debugPrint('LibraryPrefetcher.disk: $e');
    }

    await Future<void>.delayed(const Duration(seconds: 3));
    await _warmFromServer();
  }

  static Future<void> _loadPersistedCopies() async {
    final cache = LibraryCache.instance;
    final keys = <String>[
      LibraryFeeds.librariesKey,
      LibraryFeeds.movieKey(mode: 'movies', libraryId: null, sort: 'DateCreated'),
      LibraryFeeds.movieKey(mode: 'tvshows', libraryId: null, sort: 'DateCreated'),
      LibraryFeeds.musicLibraryKey,
      for (final tab in _musicPrefetchTabs) LibraryFeeds.musicKey(tab, 'az'),
    ];

    // One at a time: each is a file read + a background-isolate decode, and
    // there's no hurry that justifies decoding them all at once.
    for (final key in keys) {
      await cache.read(key);
    }
  }

  static const List<String> _musicPrefetchTabs = [
    'albums',
    'artists',
    'playlists',
    'songs',
  ];

  static Future<void> _warmFromServer() async {
    final cache = LibraryCache.instance;

    String moviesKey(String mode) =>
        LibraryFeeds.movieKey(mode: mode, libraryId: null, sort: 'DateCreated');

    await _step(
      LibraryFeeds.librariesKey,
      () => LibraryFeeds.libraries(),
    );
    await _step(
      moviesKey('movies'),
      () => LibraryFeeds.movies(
        mode: 'movies',
        library: null,
        sort: 'DateCreated',
      ),
    );

    await _step(LibraryFeeds.liveTvKey, _warmLiveTv);

    await _step(LibraryFeeds.musicLibraryKey, () => LibraryFeeds.musicLibrary());

    // The id comes from whichever copy is current by now (fresh or
    // persisted) — same value the Music screen resolves.
    String? musicLibraryId;
    final lib = cache.peek(LibraryFeeds.musicLibraryKey);
    if (lib is List && lib.isNotEmpty) {
      musicLibraryId = lib.first["Id"]?.toString();
    }

    // Default A–Z view of every music tab, cheapest first. Songs last: it's
    // the biggest list.
    for (final tab in _musicPrefetchTabs) {
      await _step(
        LibraryFeeds.musicKey(tab, 'az'),
        () => LibraryFeeds.musicTab(
          tab: tab,
          sort: 'az',
          libraryId: musicLibraryId,
          sortQuery: MediaService.musicSortToQuery('az'),
        ),
      );
    }

    await _step(
      moviesKey('tvshows'),
      () => LibraryFeeds.movies(
        mode: 'tvshows',
        library: null,
        sort: 'DateCreated',
      ),
    );
  }

  static Future<void> _warmLiveTv() async {
    final channels = await LibraryFeeds.liveTvChannels();

    // Show channels immediately for a screen opened while the (slow) guide
    // is still loading; it's replaced by the full payload below.
    LibraryCache.instance.putMemory(LibraryFeeds.liveTvKey, {
      'channels': channels,
      'programs': <String, dynamic>{},
      'guideLoaded': false,
    });

    final channelIds = channels
        .map((channel) => channel["Id"]?.toString())
        .whereType<String>()
        .toList();

    final guide = await LibraryFeeds.liveTvGuide(channelIds);

    LibraryCache.instance.putMemory(LibraryFeeds.liveTvKey, {
      'channels': channels,
      'programs': LibraryFeeds.groupGuide(guide),
      'guideLoaded': true,
    });
  }

  /// Runs [job] unless [cacheKey] was already loaded from the server during
  /// this session (a screen got there first), then pauses briefly so the
  /// requests never run back to back.
  static Future<void> _step(
    String cacheKey,
    Future<void> Function() job,
  ) async {
    if (LibraryCache.instance.isFresh(cacheKey)) return;

    try {
      await job();
    } catch (e) {
      // Prefetching is best-effort — a failure here just means the screen
      // does its own load when opened, exactly like before.
      debugPrint('LibraryPrefetcher: $e');
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
}
