import 'jellyfin_client.dart';
import '../favorite_service.dart';
import '../../virtual/virtual_images.dart';
import '../../player/models/media_item.dart';
import '../../player/models/skip_segment.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

class MediaService {
  /// Fetches the full current-user object from the server, including its
  /// `Policy` block — this is where Jellyfin stores every parental-control
  /// provision (max parental rating, blocked tags, blocked unrated types,
  /// access schedules, etc). The app never re-implements any of this logic
  /// itself; it only ever reflects back whatever the server enforces.
  static Future<Map<String, dynamic>> getCurrentUser() async {
    final response = await JellyfinClient.dio.get(
      "/Users/${JellyfinClient.userId}",
    );

    if (response.statusCode != 200) {
      throw Exception("Failed to load user: ${response.statusCode}");
    }

    return Map<String, dynamic>.from(response.data ?? {});
  }

  /// Convenience wrapper around [getCurrentUser] that returns just the
  /// `Policy` block (parental controls + permissions), or an empty map if
  /// the server didn't return one.
  static Future<Map<String, dynamic>> getCurrentUserPolicy() async {
    final user = await getCurrentUser();
    return Map<String, dynamic>.from(user["Policy"] ?? {});
  }

  /// Fetches the the server's parental rating scale (e.g. "G", "PG-13",
  /// "R") so a numeric `MaxParentalRating`/`ParentalRating` value from a
  /// user's Policy or an item can be shown as the label an admin actually
  /// configured, instead of a bare number.
  static Future<List<dynamic>> getParentalRatings() async {
    final response = await JellyfinClient.dio.get(
      "/Localization/ParentalRatings",
    );

    if (response.statusCode != 200) return [];
    return response.data ?? [];
  }

  /// Fetches the user's library views (Movies, TV Shows, Music, etc.)
  static Future<List<dynamic>> getLibraries() async {
    final response = await JellyfinClient.dio.get(
      "/Users/${JellyfinClient.userId}/Views",
    );

    if (response.statusCode != 200) {
      throw Exception(
        "Failed to load libraries: ${response.statusCode}",
      );
    }

    return response.data["Items"] ?? [];
  }

  /// Continue Watching
  static Future<List<dynamic>> getResume({
    int limit = 30,
  }) async {
    final response = await JellyfinClient.dio.get(
      "/Users/${JellyfinClient.userId}/Items/Resume",
      queryParameters: {
        "Limit": limit,
        "Fields":
        "PrimaryImageAspectRatio,"
            "UserData,"
            "RunTimeTicks,"
            "Overview,"
            "CommunityRating,"
            "MediaSources,"
            "MediaStreams,"
            "Trickplay",
        "MediaTypes": "Video",
      },
    );

    if (response.statusCode != 200) {
      throw Exception(
        "Failed to load resume items: ${response.statusCode}",
      );
    }

    return response.data["Items"] ?? [];
  }

  /// Latest items
  static Future<List<dynamic>> getLatest({
    String? parentId,
    int limit = 20,
  }) async {
    final response = await JellyfinClient.dio.get(
      "/Users/${JellyfinClient.userId}/Items/Latest",
      queryParameters: {
        if (parentId != null) "ParentId": parentId,
        "Limit": limit,
        "Fields":
        "PrimaryImageAspectRatio,BasicSyncInfo",
      },
    );

    if (response.statusCode != 200) {
      throw Exception(
        "Failed to load latest items: ${response.statusCode}",
      );
    }

    return response.data ?? [];
  }

  static Future<List<dynamic>> getGuide({
    DateTime? start,
    DateTime? end,
    List<String>? channelIds,
  }) async {
    final startDate = (start ?? DateTime.now()).toUtc().toIso8601String();
    final endDate = (end ?? DateTime.now().add(const Duration(hours: 12)))
        .toUtc()
        .toIso8601String();

    // A full day's guide across many channels can add up to well over a
    // thousand programs. Rather than trust a single large Limit (which
    // silently truncates if the real total is even bigger), page through
    // the full result set using StartIndex/TotalRecordCount so every
    // program is guaranteed to be fetched.
    const pageSize = 1000;

    // Scoping every request to a chunk's channel IDs (instead of one
    // request with every ID, or none at all) is what actually solves
    // this endpoint being slow: some Jellyfin Live TV backends —
    // IPTV/Xtream-style tuners especially — compute EPG data by walking
    // every configured channel for any unscoped request, so an
    // unfiltered call's cost scales with total channel count rather
    // than the date window requested. But a channel-heavy install's IDs
    // (GUIDs) all joined into one query string can just as easily blow
    // past a server/proxy's URL length limit (HTTP 414) — so those IDs
    // are split into chunks small enough to keep each request's URL a
    // safe length, each chunk fetched (and paginated, if that chunk's
    // own window still somehow exceeds one page) independently.
    const channelChunkSize = 40;

    Future<Response> fetchPage(List<String>? scopedChannelIds, int startIndex) {
      return JellyfinClient.dio.get(
        "/LiveTv/Programs",
        queryParameters: {
          "UserId": JellyfinClient.userId,
          "StartDate": startDate,
          "EndDate": endDate,
          "StartIndex": startIndex,
          "Limit": pageSize,
          "SortBy": "StartDate",
          if (scopedChannelIds != null && scopedChannelIds.isNotEmpty)
            "ChannelIds": scopedChannelIds.join(","),
          // Deliberately NOT requesting "Fields": "Overview" here. This
          // endpoint returns every program for every channel across the
          // whole fetch window (easily thousands of items for a full
          // day), and Overview text is the single biggest contributor to
          // payload size/parse time of any field on a program — it's
          // also only ever shown for the one program the user taps on.
          // Overview is fetched on demand (see GuideProgramTile) instead
          // of bloating this bulk call for every program that's never
          // opened.
        },
      );
    }

    // Fetches every page for one channel-ID chunk (or the whole
    // unscoped window when [scopedChannelIds] is null) — this is the
    // same "first page tells us the total, then batch through the
    // rest" logic as before, just scoped to a single chunk's worth of
    // channels at a time.
    Future<List<dynamic>> fetchChunk(List<String>? scopedChannelIds) async {
      final first = await fetchPage(scopedChannelIds, 0);

      // `validateStatus: (_) => true` means a failed request lands here
      // as a Response with a non-200 statusCode instead of throwing,
      // and `.data` on that Response is frequently not a Map at all.
      if (first.statusCode != 200) {
        throw Exception("Failed to load guide: ${first.statusCode}");
      }

      final firstItems = (first.data["Items"] as List?) ?? [];
      final rawTotalRecordCount =
          first.data["TotalRecordCount"] as int? ?? firstItems.length;

      // Some Jellyfin servers misreport TotalRecordCount for this
      // endpoint (far higher than the real number of programs in the
      // window). Capping keeps a single bad count from blowing up the
      // request count; one chunk's window realistically never has
      // anywhere near this many programs.
      const maxTotalRecordCount = 20000;
      final totalRecordCount = rawTotalRecordCount > maxTotalRecordCount
          ? maxTotalRecordCount
          : rawTotalRecordCount;

      final chunkItems = <dynamic>[...firstItems];

      if (firstItems.isNotEmpty && chunkItems.length < totalRecordCount) {
        final startIndexes = <int>[
          for (var startIndex = chunkItems.length;
              startIndex < totalRecordCount;
              startIndex += pageSize)
            startIndex,
        ];

        // Fetched in small concurrent batches rather than all at once —
        // firing every remaining page simultaneously competes for the
        // same handful of sockets a mobile client actually has
        // available, so a large page count ends up serialized anyway,
        // just with every request also fighting for the connection
        // pool at the same time.
        const batchSize = 4;
        for (var i = 0; i < startIndexes.length; i += batchSize) {
          final batch = startIndexes.skip(i).take(batchSize);
          final responses = await Future.wait(
            batch.map((startIndex) => fetchPage(scopedChannelIds, startIndex)),
          );
          for (final response in responses) {
            if (response.statusCode != 200) continue;
            chunkItems.addAll((response.data["Items"] as List?) ?? []);
          }
        }
      }

      return chunkItems;
    }

    if (channelIds == null || channelIds.isEmpty) {
      return fetchChunk(null);
    }

    if (channelIds.length <= channelChunkSize) {
      return fetchChunk(channelIds);
    }

    final chunks = <List<String>>[
      for (var i = 0; i < channelIds.length; i += channelChunkSize)
        channelIds.sublist(
          i,
          i + channelChunkSize > channelIds.length
              ? channelIds.length
              : i + channelChunkSize,
        ),
    ];

    // Same reasoning as the page-batching above — a channel-heavy
    // install could mean dozens of chunks, so these run a few at a time
    // rather than all simultaneously.
    const chunkBatchSize = 4;
    final allItems = <dynamic>[];
    for (var i = 0; i < chunks.length; i += chunkBatchSize) {
      final batch = chunks.skip(i).take(chunkBatchSize);
      final results = await Future.wait(batch.map(fetchChunk));
      for (final result in results) {
        allItems.addAll(result);
      }
    }
    return allItems;
  }

  /// Featured carousel
  static Future<List<dynamic>> getFeaturedItems({
    int limit = 10,
  }) async {
    final response = await JellyfinClient.dio.get(
      "/Users/${JellyfinClient.userId}/Items",
      queryParameters: {
        "IncludeItemTypes": "Movie,Series",
        "SortBy": "Random",
        "Recursive": true,
        "Limit": limit,
        "Fields":
        "Genres,CommunityRating,CriticRating,ProviderIds,ProductionYear,Overview,"
            "PrimaryImageAspectRatio,MediaSources,MediaStreams,Trickplay",
        "ImageTypes": "Backdrop",
      },
    );

    if (response.statusCode != 200) {
      throw Exception(
        "Failed to load featured items: ${response.statusCode}",
      );
    }

    return response.data["Items"] ?? [];
  }

  /// Generic item fetch
  /// Fields for the Movies / TV Shows poster grid. Just what a poster card
  /// and the detail screen's instant first paint need. getItems' default
  /// list additionally requests MediaSources + MediaStreams (every audio /
  /// video / subtitle track of every title) plus Album / AlbumArtist /
  /// ArtistItems — none of which a movie or series poster uses, and which
  /// made a 500-title response many times larger than it needed to be.
  /// MovieDetailsScreen / CollectionDetailsScreen fetch the authoritative
  /// full record themselves (MediaService.getItem), so nothing downstream
  /// of the grid relied on those fields.
  static const String movieGridFields =
      "PrimaryImageAspectRatio,"
      "Overview,"
      "Genres,"
      "ProductionYear,"
      "CommunityRating,"
      "RunTimeTicks,"
      "UserData,"
      "BackdropImageTags,"
      "ImageTags";

  /// Fields for the Music tabs' Albums / Playlists grids. Same root cause
  /// the Movies grid had: getItems' default list asks for MediaSources +
  /// MediaStreams, which makes the server look up the streams of every one
  /// of up to 5000 items and balloons the response. Nothing in an album /
  /// playlist card or its detail screen's first paint reads them.
  static const String musicGridFields =
      "PrimaryImageAspectRatio,"
      "Overview,"
      "Genres,"
      "ProductionYear,"
      "CommunityRating,"
      "RunTimeTicks,"
      "UserData,"
      "BackdropImageTags,"
      "ImageTags,"
      "Album,"
      "AlbumArtist,"
      "ArtistItems";

  /// Fields for the Music tabs' Songs / Most Played lists (up to 5000
  /// rows). A song row only needs title/artist/album, duration, user data
  /// (favorite, play count) and image tags. File size / container details
  /// (MediaSources) are fetched lazily where they are needed — the download
  /// sheets and DownloadManager already do that, as do playback and casting.
  static const String musicSongListFields =
      "PrimaryImageAspectRatio,"
      "Genres,"
      "ProductionYear,"
      "RunTimeTicks,"
      "UserData,"
      "ImageTags,"
      "Album,"
      "AlbumArtist,"
      "ArtistItems";

  static Future<List<dynamic>> getItems({
    String? parentId,
    String? searchTerm,
    String? includeItemTypes,
    String? ids,
    // Pipe-delimited list of tags to filter by (Jellyfin's own
    // delimiter for this param — matches items carrying ANY of the
    // listed tags). Used by TagItemsScreen to pull "other titles that
    // share this tag" for the movie/show detail screen's tag chips.
    String? tags,
    // Comma-delimited list of studio (production company) item ids to
    // filter by — Jellyfin's own delimiter for this param. Used by
    // TagItemsScreen to pull "other titles from this studio" for the
    // movie/show detail screen's studio row.
    String? studioIds,
    // Pipe-delimited list of genre names to filter by — Jellyfin's own
    // delimiter for this param (matches Tags' convention above). Used
    // by TagItemsScreen to pull "other titles/albums in this genre"
    // for the movie/show and album/artist/playlist detail screens'
    // genre chips.
    String? genres,
    String sortBy = "DateCreated",
    String sortOrder = "Descending",
    bool recursive = true,
    int limit = 500,
    String? fields,
  }) async {
    final response = await JellyfinClient.dio.get(
      "/Users/${JellyfinClient.userId}/Items",
      queryParameters: {
        if (parentId != null)
          "ParentId": parentId,
        if (searchTerm != null &&
            searchTerm.isNotEmpty)
          "SearchTerm": searchTerm,
        if (includeItemTypes != null)
          "IncludeItemTypes": includeItemTypes,
        if (ids != null)
          "Ids": ids,
        if (tags != null && tags.isNotEmpty)
          "Tags": tags,
        if (studioIds != null && studioIds.isNotEmpty)
          "StudioIds": studioIds,
        if (genres != null && genres.isNotEmpty)
          "Genres": genres,
        "SortBy": sortBy,
        "SortOrder": sortOrder,
        "Recursive": recursive,
        "Limit": limit,
        "Fields": fields ??
        "PrimaryImageAspectRatio,"
            "Overview,"
            "Genres,"
            "ProductionYear,"
            "CommunityRating,"
            "RunTimeTicks,"
            "UserData,"
            "MediaSources,"
            "MediaStreams,"
            "BackdropImageTags,"
            "ImageTags,"
            "Album,"
            "AlbumArtist,"
            "ArtistItems",
      },
    );

    if (response.statusCode != 200) {
      throw Exception(
        "Failed to load items: ${response.statusCode}",
      );
    }

    return response.data["Items"] ?? [];
  }

  /// Fetch full details for one movie/show
  ///
  /// SEEK-THUMBNAIL FIX (defense-in-depth): explicit `Cache-Control:
  /// no-cache` on this specific request. `dio`/`dart:io` don't cache
  /// responses themselves, so this is aimed at anything sitting *between*
  /// this app and the server — a reverse proxy, CDN, or carrier-level
  /// data-saver proxy — that might otherwise serve back a copy of this
  /// exact URL's response from whenever it was first requested (e.g.
  /// while a title's Trickplay was still mid-generation), regardless of
  /// how many times `_augmentWithPlaybackFields`/`_ensureFullMediaItem`
  /// re-fetch it afterwards looking for fresh data.
  ///
  /// SEEK-THUMBNAIL FIX (part 4 — cache-busting query param): the header
  /// above turned out not to be enough on its own. Confirmed against a
  /// real report: "Fury" kept coming back with the exact same stale
  /// `ThumbnailCount: 9` from this app on every single refetch (each one
  /// logged and genuinely fired — this isn't the silent-catch swallowing
  /// a failed request further down), while the *same server*, hit as
  /// `http://localhost:8096` from a browser on the machine actually
  /// running Jellyfin, showed complete scrub thumbnails for the same
  /// title the whole way through. Same backend, same database, two
  /// different answers for the same item — the one variable that
  /// actually differs between those two paths is the network hop this
  /// app's requests take that the localhost browser tab never does
  /// (`http://10.208.88.85:8096`, i.e. through whatever sits in front of
  /// that LAN address — a reverse proxy / port-forward / tunnel is the
  /// common setup here). A `Cache-Control: no-cache` *request* header is
  /// only a request; plenty of reverse-proxy setups cache GETs by URL
  /// alone and never consult it, especially ones fronting a LAN address
  /// rather than proxying api.anthropic.com-style public traffic. Once
  /// that layer has cached this URL's body from whenever "Fury" was
  /// first opened mid-generation, every later hit to the *identical* URL
  /// — including this app's own "let me refetch to get the freshest
  /// Trickplay" calls — can keep being served straight back out of that
  /// cache, never actually reaching Jellyfin again, no matter how
  /// correct the refetch-triggering logic upstream of this call is.
  ///
  /// This is the exact same failure mode `tileImageUrl` already works
  /// around by folding `tc`/`iv` into the sprite-sheet URL so a
  /// completed (re)generation mints a new cache key instead of resolving
  /// to a stale one — the fix here is the same idea applied to this
  /// endpoint: an otherwise-inert `_` query param that changes on every
  /// call, so a URL-keyed cache (however it's configured, whatever it
  /// does or doesn't do with request headers) never sees the same URL
  /// twice for this endpoint and has nothing to serve back except a
  /// forwarded, fresh hit to the server.
  static Future<Map<String, dynamic>> getItem(String id,) async {
    final response = await JellyfinClient.dio.get(
      "/Users/${JellyfinClient.userId}/Items/$id",
      queryParameters: {
        "Fields":
        "Genres,People,Overview,CommunityRating,CriticRating,ProviderIds,"
            "ProductionYear,RunTimeTicks,"
            "OfficialRating,ImageTags,"
            "BackdropImageTags,Studios,"
            "Taglines,ParentId,ChildCount,"
            // MediaStreams is its own ItemFields value, distinct from
            // MediaSources (each MediaSource carries its own nested
            // MediaStreams array, but the top-level convenience field
            // BaseItemDto.MediaStreams — what MediaStreamParser reads
            // for audio/subtitle tracks — is only populated when asked
            // for explicitly). Without it here, DownloadManager's
            // subtitle-sidecar extraction silently found zero tracks
            // for every movie/series downloaded via this call.
            "MediaSources,MediaStreams,Trickplay,Tags",
        "_": DateTime.now().millisecondsSinceEpoch.toString(),
      },
      options: Options(
        headers: const {
          'Cache-Control': 'no-cache, no-store',
          'Pragma': 'no-cache',
        },
      ),
    );

    if (response.statusCode != 200) {
      throw Exception(
        "Failed to load item: ${response.statusCode}",
      );
    }

    return Map<String, dynamic>.from(
      response.data,
    );
  }

  /// CAST START DELAY FIX: lightweight, BATCHED fetch of only the two
  /// fields casting needs to pick a receiver-safe URL/content type for a
  /// song (`MediaSources` for the container, `MediaStreams` for the
  /// codec) - one request for up to 50 ids instead of one full-field
  /// [getItem] per song. [getItem] asks for people, studios, taglines,
  /// trickplay etc. with no-cache headers, and the Google Cast queue
  /// handoff used to fire up to 50 of them and wait for every one before
  /// sending anything to the TV.
  ///
  /// Returns a map of item id -> raw item JSON. Never throws: a failed
  /// chunk just leaves its ids out of the map, and the caller falls back
  /// to its own per-item path for them.
  static Future<Map<String, Map<String, dynamic>>> getItemsPlaybackFields(
    List<String> ids,
  ) async {
    const batchChunk = 50;
    final result = <String, Map<String, dynamic>>{};
    final unique = ids.toSet().toList();

    for (var i = 0; i < unique.length; i += batchChunk) {
      final chunk = unique.sublist(
        i,
        (i + batchChunk) > unique.length ? unique.length : i + batchChunk,
      );
      try {
        final response = await JellyfinClient.dio.get(
          "/Users/${JellyfinClient.userId}/Items",
          queryParameters: {
            "Ids": chunk.join(','),
            "Fields": "MediaSources,MediaStreams",
          },
        );
        if (response.statusCode != 200) continue;
        final items = response.data?["Items"];
        if (items is! List) continue;
        for (final entry in items) {
          if (entry is Map && entry["Id"] != null) {
            result[entry["Id"].toString()] = Map<String, dynamic>.from(entry);
          }
        }
      } catch (_) {
        // Leave this chunk's ids out; caller falls back per item.
      }
    }

    return result;
  }

  /// Fetches real Intro/Outro timing for [itemId] from Jellyfin's Media
  /// Segments feature (server 10.10+): `GET /Items/{itemId}/MediaSegments`.
  /// This is the same data source the official web client uses for its
  /// own Skip Intro/Outro buttons, so once a segment-providing plugin
  /// (e.g. the official "Chapter Segments Provider", or a fan-made intro-
  /// detection one) has scanned the library, the timings this returns
  /// are exactly what that plugin measured for *this specific* file —
  /// not a guess. Requires either a segment-providing plugin (e.g.
  /// intro-skipper's successors, chapter-segments) to have actually run
  /// a scan, or a server older than 10.9 (before Media Segments existed
  /// in core at all) — either of those comes back empty/404 and is
  /// treated as "no segments for this item" rather than an error — the
  /// skip buttons simply don't show, same as a title with genuinely no
  /// intro/outro to skip.
  static Future<List<SkipSegment>> getSkipSegments(String itemId) async {
    try {
      // NOT `/Items/{id}/MediaSegments` — that was the endpoint's shape
      // during early development of this feature, but it was renamed to
      // a top-level MediaSegmentsController before release. The current
      // (10.9+) route is `/MediaSegments/{itemId}`; the old path 404s on
      // every modern server regardless of version, which is exactly what
      // was masking as "no plugin installed" here. Response shape is
      // unchanged — still `{ "Items": [...] }` of the same segment DTOs.
      final response = await JellyfinClient.dio.get(
        "/MediaSegments/$itemId",
      );

      if (response.statusCode != 200) {
        debugPrint(
          "getSkipSegments($itemId): unexpected status "
          "${response.statusCode}",
        );
        return const [];
      }

      final items = List<dynamic>.from(response.data?["Items"] ?? const []);

      // Temporary visibility while this feature settles — confirms
      // whether the server actually has a Media Segments provider
      // installed/scanned at all, since an empty (but 200 OK) response
      // here means "genuinely nothing to skip" is indistinguishable
      // from "no plugin ever ran" without seeing the raw count.
      debugPrint(
        "getSkipSegments($itemId): server returned ${items.length} "
        "raw segment(s)",
      );

      final segments = <SkipSegment>[];

      for (final raw in items) {
        final map = Map<String, dynamic>.from(raw as Map);

        final typeString = (map["Type"] as String?)?.toLowerCase();

        // Recap/Preview/Commercial/Unknown segments exist in the same
        // feed but nothing in this app's UI acts on them yet — only
        // Intro (Skip Intro) and Outro (Skip Outro, and the cue for the
        // Next Episode overlay) are surfaced here.
        final type = switch (typeString) {
          "intro" => SkipSegmentType.intro,
          "outro" => SkipSegmentType.outro,
          "recap" => SkipSegmentType.recap,
          _ => null,
        };

        if (type == null) continue;

        final startTicks = map["StartTicks"];
        final endTicks = map["EndTicks"];

        if (startTicks == null || endTicks == null) continue;

        final start = Duration(microseconds: (startTicks as num) ~/ 10);
        final end = Duration(microseconds: (endTicks as num) ~/ 10);

        // A malformed/zero-length segment can't be skipped into or out
        // of meaningfully — drop it rather than showing a button that
        // does nothing.
        if (end <= start) continue;

        segments.add(SkipSegment(start: start, end: end, type: type));
      }

      debugPrint(
        "getSkipSegments($itemId): parsed ${segments.length} usable "
        "intro/outro segment(s)",
      );

      return segments;
    } catch (e) {
      // No plugin installed, server too old, or a transient network
      // error — any of these should look like "nothing to skip" rather
      // than surfacing an error over what's otherwise a fully working
      // playback session.
      debugPrint("getSkipSegments($itemId): failed — $e");
      return const [];
    }
  }

  /// Similar movies
  static Future<List<dynamic>>
  getSimilarItems(String id, {
    int limit = 12,
  }) async {
    final response = await JellyfinClient.dio.get(
      "/Items/$id/Similar",
      queryParameters: {
        "UserId": JellyfinClient.userId,
        "Limit": limit,
        "Fields":
        "PrimaryImageAspectRatio,CommunityRating,ProductionYear",
      },
    );

    if (response.statusCode != 200) {
      throw Exception(
        "Failed to load similar items.",
      );
    }

    return response.data["Items"] ?? [];
  }

  /// In-memory index built once per session — see [_ensureCollectionIndex].
  /// Every getItemCollection() call after the very first one hits this
  /// instead of repeating the same expensive scan, which is what used
  /// to make "part of a collection" so much slower to appear than the
  /// rest of a movie/show detail screen.
  static Future<void>? _collectionIndexFuture;
  static Map<String, String>? _itemToCollectionId;
  static Map<String, Map<String, dynamic>>? _collectionsById;

  /// Forgets in-memory indexes built from the previous profile's library
  /// view (BoxSet membership can differ per user). Called when switching
  /// profiles; the next lookup simply rebuilds them.
  static void resetUserCaches() {
    _collectionIndexFuture = null;
    _itemToCollectionId = null;
    _collectionsById = null;
  }

  /// Builds a complete item->BoxSet index in one pass: fetch every
  /// BoxSet once, fetch each one's children once (in parallel, same as
  /// before), then record every membership found — not just the one
  /// item that happened to trigger the build. That's what lets every
  /// *other* movie/show's getItemCollection() call, for the rest of the
  /// session, skip the network entirely. Concurrent callers (e.g. two
  /// detail screens opened close together) all await this same build
  /// rather than kicking off duplicate scans.
  static Future<void> _ensureCollectionIndex() {
    if (_itemToCollectionId != null) return Future.value();
    return _collectionIndexFuture ??= _buildCollectionIndex();
  }

  static Future<void> _buildCollectionIndex() async {
    try {
      final collections = await getItems(
        includeItemTypes: "BoxSet",
        sortBy: "SortName",
        sortOrder: "Ascending",
        limit: 500,
        // This call only needs enough to identify the collections
        // themselves, not the heavy per-item field set (MediaSources,
        // MediaStreams, etc.) — trims the response for what's
        // otherwise a fixed cost on every single movie/show detail
        // page.
        fields: "PrimaryImageAspectRatio",
      );

      // For each collection, fetch its children and record who's in
      // it client-side.
      //
      // NOTE: this used to pass `ParentId` + `Ids` together in a
      // single request, on the theory that the server would return
      // the item only if it actually lived under that ParentId. It
      // doesn't — Jellyfin treats `Ids` as a direct by-ID lookup, so
      // it returns the item as long as it exists *anywhere* on the
      // server, regardless of `ParentId`. That made every collection's
      // "membership check" come back non-empty and the loop below
      // always matched the first (alphabetical) BoxSet on the server
      // for every single movie. Dropping `Ids` and checking the
      // returned children's `Id` fields ourselves is what actually
      // scopes the check to that collection.
      final membershipChecks = await Future.wait(
        collections.map(
          (collection) => getItems(
            parentId: collection["Id"],
            limit: 200,
            fields: "",
          ),
        ),
      );

      final index = <String, String>{};
      final byId = <String, Map<String, dynamic>>{};

      for (var i = 0; i < collections.length; i++) {
        final collection = Map<String, dynamic>.from(collections[i]);
        final collectionId = collection["Id"].toString();
        byId[collectionId] = collection;

        for (final member in membershipChecks[i]) {
          // First (alphabetically-ordered) collection an item turns up
          // in wins, same as the old first-match loop did.
          index.putIfAbsent(member["Id"].toString(), () => collectionId);
        }
      }

      _itemToCollectionId = index;
      _collectionsById = byId;
    } catch (e) {
      // Don't cache a failed build — let the next call retry from
      // scratch instead of getting stuck with an empty index forever.
      _collectionIndexFuture = null;
      rethrow;
    }
  }

  /// In-memory index built once per session, mapping "movie:<tmdbId>" /
  /// "tv:<tmdbId>" to the matching local library item. Same lazy,
  /// session-cached scan pattern as [_ensureCollectionIndex] — every
  /// call after the first hits this instead of re-scanning the whole
  /// library. Built the first time a TMDB-only filmography needs to be
  /// checked against what this server actually has (see
  /// [filterTmdbItemsInLibrary] / CastCrewDetailScreen).
  static Future<void>? _tmdbIndexFuture;
  static Map<String, Map<String, dynamic>>? _tmdbIndex;

  /// Starts building the TMDB index in the background without waiting
  /// on it (failures are swallowed — [filterTmdbItemsInLibrary] retries
  /// the build itself when it actually needs the index). The first
  /// build scans the whole library, so a screen that already knows it
  /// will need [filterTmdbItemsInLibrary] (CastCrewDetailScreen, for a
  /// TMDB-sourced person) calls this the moment it opens, letting the
  /// scan overlap its other network calls instead of running after
  /// them.
  static void prewarmTmdbIndex() {
    _ensureTmdbIndex().then<void>((_) {}, onError: (_) {});
  }

  static Future<Map<String, Map<String, dynamic>>> _ensureTmdbIndex() async {
    if (_tmdbIndex != null) return _tmdbIndex!;
    await (_tmdbIndexFuture ??= _buildTmdbIndex());
    return _tmdbIndex!;
  }

  static Future<void> _buildTmdbIndex() async {
    try {
      final items = await getItems(
        includeItemTypes: "Movie,Series",
        limit: 5000,
        fields:
            "ProviderIds,PrimaryImageAspectRatio,Overview,Genres,"
            "ProductionYear,CommunityRating,RunTimeTicks,UserData,"
            "BackdropImageTags,ImageTags",
      );

      final index = <String, Map<String, dynamic>>{};
      for (final raw in items) {
        final item = Map<String, dynamic>.from(raw);
        final tmdbId = item["ProviderIds"]?["Tmdb"]?.toString();
        if (tmdbId == null || tmdbId.isEmpty) continue;
        final mediaType = item["Type"] == "Series" ? "tv" : "movie";
        index["$mediaType:$tmdbId"] = item;
      }
      _tmdbIndex = index;
    } catch (e) {
      // Don't cache a failed build — let the next call retry from
      // scratch instead of getting stuck with an empty index forever.
      _tmdbIndexFuture = null;
      rethrow;
    }
  }

  /// Filters a TMDB `combined_credits`-derived filmography (see
  /// CastCrewDetailScreen._tmdbFilmography, which stamps each entry
  /// with "TmdbId") down to just the titles that actually exist in
  /// this server's library, swapping each match for its real Jellyfin
  /// item. TMDB's combined credits list *everything* a person has ever
  /// been in, world-wide — without this filter, a cast/crew member
  /// with no Jellyfin-indexed credits ends up showing their entire
  /// career instead of just what's on this server. A match also comes
  /// back as a normal, fully-populated Jellyfin item (real "Id",
  /// server poster/backdrop, own UserData), so it opens and displays
  /// exactly like any other library title instead of the placeholder
  /// TMDB-only entries this replaces.
  static Future<List<Map<String, dynamic>>> filterTmdbItemsInLibrary(
    List<Map<String, dynamic>> tmdbItems,
  ) async {
    final index = await _ensureTmdbIndex();
    final result = <Map<String, dynamic>>[];
    for (final item in tmdbItems) {
      final tmdbId = item["TmdbId"]?.toString();
      if (tmdbId == null || tmdbId.isEmpty) continue;
      final mediaType = item["Type"] == "Series" ? "tv" : "movie";
      final match = index["$mediaType:$tmdbId"];
      if (match != null) result.add(match);
    }
    return result;
  }

  /// Finds the Jellyfin Box Set containing an item, using the
  /// session-cached index built by [_ensureCollectionIndex]. See that
  /// method for why this is a full scan only the first time it's ever
  /// called, and an in-memory lookup every time after.
  static Future<Map<String, dynamic>?> getItemCollection(String itemId) async {
    // NAMESIS PRIME: the TMDB-backed catalog answers this directly (a movie
    // knows its own collection), so no scan of every collection is needed.
    // A real Jellyfin server has no such route and falls through to the
    // index below.
    try {
      final response = await JellyfinClient.dio.get(
        "/Items/$itemId/ParentCollection",
      );
      final data = response.data;
      if (response.statusCode == 200 &&
          data is Map &&
          data.containsKey("Collection")) {
        final collection = data["Collection"];
        return collection is Map
            ? Map<String, dynamic>.from(collection)
            : null;
      }
      // The catalog knows the route but failed (e.g. TMDB unreachable):
      // no collection row, rather than falling back to a full scan.
      final status = response.statusCode;
      if (status != null && status != 404 && status != 405) return null;
    } catch (_) {}

    await _ensureCollectionIndex();

    final collectionId = _itemToCollectionId?[itemId];
    if (collectionId == null) return null;

    final collection = _collectionsById?[collectionId];
    return collection == null ? null : Map<String, dynamic>.from(collection);
  }

  /// TV Seasons
  static Future<List<dynamic>> getSeasons(String seriesId,) async {
    final response = await JellyfinClient.dio.get(
      "/Shows/$seriesId/Seasons",
      queryParameters: {
        "UserId": JellyfinClient.userId,
      },
    );

    if (response.statusCode != 200) {
      throw Exception(
        "Failed to load seasons.",
      );
    }

    return response.data["Items"] ?? [];
  }

  /// Episodes
  static Future<List<dynamic>> getEpisodes(String seriesId,
      String seasonId,) async {
    final response = await JellyfinClient.dio.get(
      "/Shows/$seriesId/Episodes",
      queryParameters: {
        "SeasonId": seasonId,
        "UserId": JellyfinClient.userId,
        // Deliberately NOT requesting MediaSources/MediaStreams/
        // Trickplay here. Jellyfin has to resolve/probe each episode's
        // actual media source to fill those in, and doing that for
        // every episode in a season at once (rather than just the one
        // the person is about to watch) is what made both the initial
        // episode list and every season switch feel slow — the season
        // chip and episode-row UI itself never needed that data, only
        // playback does. See PlayerManager._augmentWithPlaybackFields,
        // which fetches those three fields for a single episode right
        // before it actually plays.
        // ProviderIds added so RatingsService can resolve a rating for
        // the episode itself (a metadata provider that tags episodes
        // with their own IMDb id, distinct from the series' id) —
        // still just a plain metadata field on the same response, not
        // the MediaSources/MediaStreams/Trickplay probe the comment
        // above is about, so it doesn't reintroduce the slowdown that
        // was deliberately avoided there.
        "Fields":
        "PrimaryImageAspectRatio,"
            "Overview,"
            "RunTimeTicks,"
            "UserData,"
            "ProviderIds,"
            "ImageTags",
      },
    );

    if (response.statusCode != 200) {
      throw Exception(
        "Failed to load episodes.",
      );
    }

    return response.data["Items"] ?? [];
  }

  /// Every downloadable episode of [seriesId], across all seasons, in
  /// season/episode order.
  ///
  /// Used by the TV show Download button. With [withSources] (the default)
  /// each episode also carries its `MediaSources` — file size, container
  /// and resolution — which is what the quality sheet totals per quality
  /// and what DownloadManager reads to name the file with its real
  /// extension. [getEpisodes] deliberately leaves that out to keep season
  /// lists fast; this is only ever called when the person actually taps
  /// Download (pass `withSources: false` for a cheap id-only listing).
  ///
  /// Placeholder ("missing"/unaired) episodes have no file to download, so
  /// they're excluded both server-side and, defensively, here.
  static Future<List<Map<String, dynamic>>> getSeriesEpisodesForDownload(
    String seriesId, {
    bool withSources = true,
  }) async {
    final response = await JellyfinClient.dio.get(
      "/Shows/$seriesId/Episodes",
      queryParameters: {
        "UserId": JellyfinClient.userId,
        "IsMissing": false,
        "Fields": "PrimaryImageAspectRatio,"
            "Overview,"
            "RunTimeTicks,"
            "UserData,"
            "ProviderIds,"
            "ImageTags"
            "${withSources ? ',MediaSources' : ''}",
      },
    );

    if (response.statusCode != 200) {
      throw Exception(
        "Failed to load episodes.",
      );
    }

    final items = response.data["Items"];
    if (items is! List) return [];

    return items
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .where((e) => e["LocationType"] != "Virtual")
        .toList();
  }

  /// Synced (or plain) lyrics for a track, straight from Jellyfin's
  /// built-in lyrics provider. Returns null when the server has no
  /// lyrics for this item (a 404) rather than throwing, since "no
  /// lyrics" is an expected, common outcome — not an error.
  static Future<List<dynamic>?> getLyrics(String itemId) async {
    try {
      final response = await JellyfinClient.dio.get(
        "/Audio/$itemId/Lyrics",
      );

      if (response.statusCode != 200) {
        return null;
      }

      final lyrics = response.data?["Lyrics"];

      return lyrics != null ? List<dynamic>.from(lyrics) : null;
    } catch (_) {
      return null;
    }
  }

  /// Every favorited item across arbitrary types (Movie, Series,
  /// MusicAlbum, etc.) via Jellyfin's IsFavorite filter — powers the
  /// Favorites page. Artists don't live under this endpoint (they're
  /// their own virtual collection in Jellyfin), so MusicService.
  /// getFavoriteArtists() covers those separately.
  /// Favorited songs for the Favorites page. This used to skip the
  /// server-side `Filters=IsFavorite` that [getFavoriteItems] relies on
  /// for every other type, on the theory that the filter came back
  /// empty/incomplete for `IncludeItemTypes=Audio` — and instead pulled
  /// the *entire* Audio library (up to 5000 tracks, every time) just to
  /// filter for favorites client-side. That full-library fetch was the
  /// actual bug: it's what made the Songs section load far slower than
  /// every other section on this page (which all get a small,
  /// server-filtered result set), and it got slower the larger the
  /// library was. `Filters=IsFavorite` combined with
  /// `IncludeItemTypes=Audio` and `Recursive=true` is standard, working
  /// Jellyfin API usage — the same filter this file already trusts for
  /// Movie/Series/BoxSet/MusicAlbum/Playlist — so there's no need to
  /// scan the whole library at all.
  static Future<List<dynamic>> getFavoriteSongs() async {
    final response = await JellyfinClient.dio.get(
      "/Users/${JellyfinClient.userId}/Items",
      queryParameters: {
        "IncludeItemTypes": "Audio",
        "Filters": "IsFavorite",
        "Recursive": true,
        "SortBy": "SortName",
        // Trimmed down from the Movie/Series-oriented field set
        // [getFavoriteItems] requests (Overview, Genres, ProductionYear,
        // CommunityRating, BackdropImageTags) — none of those are ever
        // read for a song: SongRow/song_options_sheet only use Album,
        // AlbumArtist, ArtistItems, image tags, and UserData, and
        // MusicService.getSongs() (the Music tab's own song list) never
        // requested those fields either, so player screens like
        // info_sheet.dart already handle songs without them. Now that
        // the server only returns the favorited handful, this trimming
        // matters far less than it used to, but there's no reason to
        // pay for fields nothing reads.
        "Fields":
        "PrimaryImageAspectRatio,"
            "RunTimeTicks,"
            "UserData,"
            "ImageTags,"
            "Album,"
            "AlbumArtist,"
            "ArtistItems",
      },
    );

    if (response.statusCode != 200) {
      throw Exception(
        "Failed to load favorite songs: ${response.statusCode}",
      );
    }

    return List<dynamic>.from(response.data["Items"] ?? []);
  }

  static Future<List<dynamic>> getFavoriteItems({
    String? includeItemTypes,
  }) async {
    final response = await JellyfinClient.dio.get(
      "/Users/${JellyfinClient.userId}/Items",
      queryParameters: {
        "Filters": "IsFavorite",
        "Recursive": true,
        if (includeItemTypes != null) "IncludeItemTypes": includeItemTypes,
        "SortBy": "SortName",
        "Fields":
        "PrimaryImageAspectRatio,"
            "Overview,"
            "Genres,"
            "ProductionYear,"
            "CommunityRating,"
            "RunTimeTicks,"
            "UserData,"
            "BackdropImageTags,"
            "ImageTags,"
            "Album,"
            "AlbumArtist,"
            "ArtistItems",
      },
    );

    if (response.statusCode != 200) {
      throw Exception(
        "Failed to load favorites: ${response.statusCode}",
      );
    }

    return response.data["Items"] ?? [];
  }

  /// Favorited cast/crew — same /Persons endpoint as searchPeople(),
  /// with Jellyfin's IsFavorite filter instead of a search term. Powers
  /// the Favorites page's Cast & Crew section.
  static Future<List<dynamic>> getFavoritePeople({int limit = 50}) async {
    final response = await JellyfinClient.dio.get(
      "/Persons",
      queryParameters: {
        "Filters": "IsFavorite",
        "UserId": JellyfinClient.userId,
        "Limit": limit,
      },
    );

    if (response.statusCode != 200) {
      throw Exception(
        "Failed to load favorite people: ${response.statusCode}",
      );
    }

    return response.data["Items"] ?? [];
  }

  /// People (cast & crew) matching a search term — a separate endpoint
  /// from the regular Items tree, since Person isn't a library item the
  /// way a Movie or Series is.
  static Future<List<dynamic>> searchPeople(
    String query, {
    int limit = 30,
  }) async {
    if (query.trim().isEmpty) return [];

    final response = await JellyfinClient.dio.get(
      "/Persons",
      queryParameters: {
        "SearchTerm": query,
        "UserId": JellyfinClient.userId,
        "Limit": limit,
      },
    );

    if (response.statusCode != 200) {
      throw Exception(
        "Failed to search people: ${response.statusCode}",
      );
    }

    return response.data["Items"] ?? [];
  }

  /// Fetches a Person's own record — bio (Overview), birth date
  /// (PremiereDate), and birthplace (ProductionLocations) all live on
  /// the Person item itself, same BaseItemDto shape as a movie or show,
  /// just with a different set of fields actually populated.
  ///
  /// Person entities aren't part of the regular library Items tree (see
  /// searchPeople/getFavoritePeople above) — `/Users/.../Items/{id}`
  /// only resolves for a person if the server happens to already have
  /// them materialized as a browsable item, which is why this used to
  /// work for some cast/crew members and silently fail for others.
  /// `/Persons/{name}` is Jellyfin's actual single-person lookup, so
  /// that's tried first whenever a name is available (every caller in
  /// this app has one, from the cast/crew card that was tapped); the
  /// id-based Items lookup is kept as a fallback for the rare case a
  /// screen doesn't have a name yet.
  static Future<Map<String, dynamic>> getPerson(
    String personId, {
    String? name,
  }) async {
    Map<String, dynamic>? nameResult;

    if (name != null && name.isNotEmpty) {
      try {
        final response = await JellyfinClient.dio.get(
          "/Persons/${Uri.encodeComponent(name)}",
          queryParameters: {
            "UserId": JellyfinClient.userId,
            "Fields":
                "Overview,ProductionLocations,PremiereDate,EndDate,ProviderIds",
          },
        );

        if (response.statusCode == 200) {
          nameResult = Map<String, dynamic>.from(response.data);
        }
      } catch (_) {
        // Falls through to the id-based lookup below.
      }
    }

    // `/Persons/{name}` above doesn't reliably honor the `Fields` query
    // param the way `/Items` does — it can come back 200 with a fully
    // populated record but a blank `Overview` even when the server
    // does have a bio for this person, which is why the biography
    // section was showing "No biography available." across the board.
    // Skip the id-based fallback entirely only when the name lookup
    // both succeeded *and* actually carried a bio.
    final overview = nameResult?["Overview"]?.toString() ?? "";
    if (nameResult != null && overview.isNotEmpty) {
      return nameResult;
    }

    // A TMDB-sourced cast/crew card arrives with no Jellyfin id at all
    // (personId == ""). The id-based lookup below would then hit
    // `/Users/{id}/Items/` with nothing after it — not a person lookup
    // but the plain items-list route, which can answer 200 with a
    // huge, unpaginated library dump (or fail), either way an extra
    // serial round trip before the screen can show anything. There's
    // nothing to look up by id, so return what the name lookup found.
    if (personId.isEmpty) {
      if (nameResult != null) return nameResult;
      throw Exception("Failed to load person");
    }

    try {
      final response = await JellyfinClient.dio.get(
        "/Users/${JellyfinClient.userId}/Items/$personId",
        queryParameters: {
          "Fields":
              "Overview,ProductionLocations,PremiereDate,EndDate,ProviderIds",
        },
      );

      if (response.statusCode == 200) {
        final idResult = Map<String, dynamic>.from(response.data);
        if (nameResult == null) return idResult;
        // Merge rather than replace — the name-based record is
        // otherwise the richer/more reliable one; this only needs to
        // borrow the bio the name-based lookup didn't have. (Can't
        // just spread nameResult last — its own blank "Overview"
        // would clobber the populated one from idResult.)
        return {
          ...idResult,
          ...nameResult,
          "Overview": idResult["Overview"],
        };
      }
    } catch (_) {
      // Both lookups failed to produce a bio — fall through below.
    }

    if (nameResult != null) return nameResult;

    throw Exception("Failed to load person");
  }

  /// Everything a given cast/crew member appears in — powers tapping a
  /// person in search results through to their filmography.
  ///
  /// [personId] is tried first (Jellyfin's `PersonIds` filter) since
  /// it's exact — but for a person who was originally resolved via
  /// getPerson()'s name-based `/Persons/{name}` lookup (see
  /// CastCrewDetailScreen — this covers a TMDB-sourced cast/crew card,
  /// and is exactly the id every favorited person from the Favorites
  /// screen carries), that id can still come back with zero results
  /// here even though the person genuinely has credits in the
  /// library: `/Persons/{name}` and the `PersonIds` item filter don't
  /// always agree on a person's id when the library has more than one
  /// Person record for the same name, so an id that's "exact" by
  /// Jellyfin's own `/Persons` catalog can still miss every item that
  /// actually credits a *different* same-named Person id. When that
  /// happens, [name] is retried via Jellyfin's `Person` filter, which
  /// matches by name across the whole library instead of one id, so
  /// it still finds those credits. Only retried when the id-based
  /// query truly came back empty, to avoid a redundant round trip for
  /// the common case where the id already matches correctly.
  static Future<List<dynamic>> getItemsByPerson(
    String personId, {
    String? name,
    int limit = 100,
  }) async {
    final byId = personId.isNotEmpty;
    final hasName = name != null && name.isNotEmpty;
    if (!byId && !hasName) return [];

    Future<List<dynamic>> query(String filterKey, String filterValue) async {
      final response = await JellyfinClient.dio.get(
        "/Users/${JellyfinClient.userId}/Items",
        queryParameters: {
          filterKey: filterValue,
          "Recursive": true,
          "IncludeItemTypes": "Movie,Series",
          "SortBy": "SortName",
          "Limit": limit,
          "Fields":
          "PrimaryImageAspectRatio,"
              "Overview,"
              "Genres,"
              "ProductionYear,"
              "CommunityRating,"
              "RunTimeTicks,"
              "UserData,"
              "BackdropImageTags,"
              "ImageTags",
        },
      );

      if (response.statusCode != 200) {
        throw Exception(
          "Failed to load person's titles: ${response.statusCode}",
        );
      }

      return response.data["Items"] ?? [];
    }

    List<dynamic> items = [];
    if (byId) {
      items = await query("PersonIds", personId);
    }

    if (items.isEmpty && hasName) {
      items = await query("Person", name);
    }

    return items;
  }

  /// Favorite / Unfavorite
  ///
  /// Also records (or clears) a local favorited-at timestamp via
  /// FavoriteService — Jellyfin's UserData has no "date favorited"
  /// field of its own, so this is the only way the Favorites page can
  /// order a section newest-favorited-first. `currentlyFavorite` is
  /// the state *before* this call, so `!currentlyFavorite` means the
  /// item is being favorited (not unfavorited) by this call.
  static Future<void> toggleFavorite(String itemId,
      bool currentlyFavorite,) async {
    final response = currentlyFavorite
        ? await JellyfinClient.dio.delete(
      "/Users/${JellyfinClient.userId}/FavoriteItems/$itemId",
    )
        : await JellyfinClient.dio.post(
      "/Users/${JellyfinClient.userId}/FavoriteItems/$itemId",
    );

    if (response.statusCode != 200 &&
        response.statusCode != 204) {
      throw Exception(
        "Failed to update favorite.",
      );
    }

    // The server call above is what actually changed the favorite. The
    // local favorited-at bookkeeping is best-effort ordering data only,
    // so a failure there must never surface as a failed toggle (callers
    // like PlayerManager.toggleFavorite roll their heart back on any
    // exception, which would leave the UI saying "not favorited" for an
    // item the server now has favorited).
    try {
      if (currentlyFavorite) {
        await FavoriteService.clearFavoritedTimestamp(itemId);
      } else {
        await FavoriteService.recordFavoritedTimestamp(itemId);
      }
    } catch (e) {
      debugPrint("Failed to record favorited-at timestamp: $e");
    }

    // Tell any live favorites list (Favorites page, its "See all"
    // grids) to reload now that the server has the new state.
    FavoriteService.notifyChanged();
  }

  /// Clears an item's saved resume position, which is what actually
  /// drops it out of the Home screen's Continue Watching row (that row
  /// is just everything with `PlaybackPositionTicks > 0` and `Played
  /// == false`). Deliberately NOT the same as marking it watched
  /// (`/PlayedItems`) — that would also flip the item's "Played" badge
  /// everywhere else in the app even though the user never actually
  /// finished it, just wanted it off this row.
  static Future<void> removeFromContinueWatching(String itemId) async {
    final response = await JellyfinClient.dio.post(
      "/Users/${JellyfinClient.userId}/Items/$itemId/UserData",
      data: {
        "PlaybackPositionTicks": 0,
      },
    );

    if (response.statusCode != 200 && response.statusCode != 204) {
      throw Exception(
        "Failed to remove from Continue Watching.",
      );
    }
  }

  /// Builds image URLs
  static String getImageUrl(String itemId, {
    String type = "Primary",
    int? maxWidth,
  }) {
    // NAMESIS PRIME: pictures come from TMDB, looked up by the paths the
    // virtual server registered for this id. An id with nothing registered
    // gets an address that fails instantly, so the screens' own placeholder
    // / error widgets show.
    final tmdbUrl = VirtualImages.urlFor(itemId, type, maxWidth: maxWidth);
    if (tmdbUrl != null) return tmdbUrl;
    return "http://127.0.0.1:9/no-image/$itemId/$type";
  }

  /// Current user's profile image (falls back gracefully — the caller
  /// should still show a placeholder icon on load error, since not
  /// every Jellyfin user has an avatar set).
  static String getUserImageUrl(String userId, {int? maxWidth}) {
    final params = <String, String>{
      "quality": "90",
      "api_key": JellyfinClient.token,
    };

    if (maxWidth != null) {
      params["maxWidth"] = maxWidth.toString();
    }

    final query = Uri(queryParameters: params).query;

    return "${JellyfinClient.serverUrl}/Users/$userId/Images/Primary?$query";
  }

  /// Backdrop image
  static String getBackdropUrl(String itemId,) {
    return getImageUrl(
      itemId,
      type: "Backdrop",
      maxWidth: 1600,
    );
  }

  /// Tiny backdrop (TMDB w300) for instant first paint / blurred or tinted
  /// uses. Falls back to the normal backdrop URL when nothing is known.
  static String getBackdropPreviewUrl(String itemId,) {
    return VirtualImages.backdropPreviewUrl(itemId) ?? getBackdropUrl(itemId);
  }

  /// A much smaller backdrop render, meant only for feeding
  /// ArtworkAccentExtractor (which internally downsamples to a coarse
  /// 50x50 grid anyway) rather than for on-screen display. Requesting
  /// the full 1600px backdrop just to average its colors was the main
  /// reason the collection screen's collapsed-bar accent/logo took so
  /// long to appear after each scroll-triggered identity change.
  static String getAccentSampleUrl(String itemId,) {
    return getImageUrl(
      itemId,
      type: "Backdrop",
      maxWidth: 200,
    );
  }

  /// Episode thumbnail
  static String getEpisodeThumbUrl(String itemId,) {
    return getImageUrl(
      itemId,
      maxWidth: 500,
    );
  }

  /// Transparent logo
  static String getLogoUrl(String itemId,) {
    return getImageUrl(
      itemId,
      type: "Logo",
      maxWidth: 700,
    );
  }

  /// Converts Jellyfin ticks to "1h 38m"
  static String formatRuntime(int? ticks,) {
    if (ticks == null) {
      return "";
    }

    final minutes =
        (ticks ~/ 10000000) ~/ 60;

    final hours = minutes ~/ 60;
    final mins = minutes % 60;

    if (hours == 0) {
      return "${mins}m";
    }

    return "${hours}h ${mins}m";
  }

  /// Returns the Music library.
  static Future<Map<String, dynamic>?> getMusicLibrary() async {
    final libraries = await getLibraries();

    try {
      return Map<String, dynamic>.from(
        libraries.firstWhere(
              (lib) => lib["CollectionType"] == "music",
        ),
      );
    } catch (_) {
      return null;
    }
  }

  /// Album Artists
  static Future<List<dynamic>> getAlbumArtists({
    String? parentId,
    String sortBy = "SortName",
    String sortOrder = "Ascending",
  }) async {
    final response = await JellyfinClient.dio.get(
      "/Artists/AlbumArtists",
      queryParameters: {
        if (parentId != null) "ParentId": parentId,
        "UserId": JellyfinClient.userId,
        "SortBy": sortBy,
        "SortOrder": sortOrder,
        "Recursive": true,
      },
    );

    if (response.statusCode != 200) {
      throw Exception("Failed to load artists.");
    }

    return response.data["Items"] ?? [];
  }

  static Future<List<dynamic>> getRecommendedArtists({
    required String currentArtistId,
    int limit = 20,
  }) async {

    final response = await JellyfinClient.dio.get(
      "/Artists/AlbumArtists",
      queryParameters: {
        "UserId": JellyfinClient.userId,
        "Recursive": true,
        "SortBy": "SortName",
      },
    );

    if (response.statusCode != 200) {
      throw Exception("Failed to load artists.");
    }

    final artists =
    List<Map<String, dynamic>>.from(
      response.data["Items"] ?? [],
    );

    artists.removeWhere(
          (artist) => artist["Id"] == currentArtistId,
    );

    artists.shuffle();

    return artists.take(limit).toList();
  }

  /// Music Albums
  static Future<List<dynamic>> getMusicAlbums({
    String? parentId,
    String sortBy = "SortName",
    String sortOrder = "Ascending",
  }) async {
    return getItems(
      parentId: parentId,
      includeItemTypes: "MusicAlbum",
      sortBy: sortBy,
      sortOrder: sortOrder,
      recursive: true,
      limit: 5000,
      fields: musicGridFields,
    );
  }

  /// Songs
  static Future<List<dynamic>> getSongs({
    String? parentId,
    String sortBy = "SortName",
    String sortOrder = "Ascending",
  }) async {
    return getItems(
      parentId: parentId,
      includeItemTypes: "Audio",
      sortBy: sortBy,
      sortOrder: sortOrder,
      recursive: true,
      limit: 5000,
      fields: musicSongListFields,
    );
  }

  static Future<List<dynamic>> getMostPlayedSongs({
    String? parentId,
  }) async {
    return getItems(
      parentId: parentId,
      includeItemTypes: "Audio",
      sortBy: "PlayCount",
      sortOrder: "Descending",
      recursive: true,
      limit: 5000,
      fields: musicSongListFields,
    );
  }

  /// Playlists
  static Future<List<dynamic>> getPlaylists({
    String sortBy = "SortName",
    String sortOrder = "Ascending",
  }) async {
    return getItems(
      includeItemTypes: "Playlist",
      sortBy: sortBy,
      sortOrder: sortOrder,
      recursive: true,
      limit: 5000,
      fields: musicGridFields,
    );
  }

  /// Creates a new playlist containing the given item, returning the new
  /// playlist's id. Jellyfin's `POST /Playlists` doubles as both "create
  /// an empty playlist" and "create with initial items" depending on
  /// whether `Ids` is supplied — passing the song's id here means the
  /// user never sees a newly-made playlist that's confusingly empty.
  static Future<String> createPlaylist(
      String name,
      List<String> itemIds,
      ) async {
    final response = await JellyfinClient.dio.post(
      "/Playlists",
      data: {
        "Name": name,
        "Ids": itemIds,
        "UserId": JellyfinClient.userId,
        "MediaType": "Audio",
      },
    );

    if (response.statusCode != 200 && response.statusCode != 204) {
      throw Exception("Failed to create playlist.");
    }

    return response.data["Id"].toString();
  }

  /// Permanently deletes a playlist (the playlist item itself, not just
  /// its contents) via Jellyfin's generic item-delete endpoint — a
  /// playlist is just an Item server-side, so there's no separate
  /// "/Playlists/{id}" delete route.
  static Future<void> deletePlaylist(String playlistId) async {
    final response = await JellyfinClient.dio.delete(
      "/Items/$playlistId",
    );

    if (response.statusCode != 200 && response.statusCode != 204) {
      throw Exception("Failed to delete playlist.");
    }
  }

  /// Appends an item to an existing playlist. Thin wrapper around
  /// [addManyToPlaylist] for the common single-song call sites.
  static Future<void> addToPlaylist(
      String playlistId,
      String itemId,
      ) => addManyToPlaylist(playlistId, [itemId]);

  /// Appends several items to an existing playlist in one request —
  /// Jellyfin's Ids param already accepts a comma-separated list, so a
  /// bulk "Add to Playlist" from song multi-select doesn't need one
  /// round-trip per song.
  static Future<void> addManyToPlaylist(
      String playlistId,
      List<String> itemIds,
      ) async {
    if (itemIds.isEmpty) return;

    final response = await JellyfinClient.dio.post(
      "/Playlists/$playlistId/Items",
      queryParameters: {
        "Ids": itemIds.join(","),
        "UserId": JellyfinClient.userId,
      },
    );

    if (response.statusCode != 200 && response.statusCode != 204) {
      throw Exception("Failed to add to playlist.");
    }
  }

  /// Removes an entry from a playlist. [entryId] is the playlist-specific
  /// "PlaylistItemId" for that track (not the song's own item id) — using
  /// the song's id instead would remove the wrong copy, or fail outright,
  /// if the same song appears in the playlist more than once.
  static Future<void> removeFromPlaylist(
      String playlistId,
      String entryId,
      ) => removeManyFromPlaylist(playlistId, [entryId]);

  /// Removes several entries from a playlist in one request — same
  /// "PlaylistItemId, not song Id" caveat as [removeFromPlaylist], just
  /// batched for a multi-select "Remove from Playlist" bulk action.
  static Future<void> removeManyFromPlaylist(
      String playlistId,
      List<String> entryIds,
      ) async {
    if (entryIds.isEmpty) return;

    final response = await JellyfinClient.dio.delete(
      "/Playlists/$playlistId/Items",
      queryParameters: {
        "EntryIds": entryIds.join(","),
      },
    );

    if (response.statusCode != 200 && response.statusCode != 204) {
      throw Exception("Failed to remove from playlist.");
    }
  }

  /// Returns album art URL.
  static String getMusicImage(String id, {
    int size = 400,
  }) {
    return getImageUrl(
      id,
      maxWidth: size,
    );
  }

  static String getPrimaryImage(
      String id, {
        int size = 600,
      }) {
    return getImageUrl(
      id,
      maxWidth: size,
    );
  }

  static String getItemImage(
      String id, {
        String type = "Primary",
        String? tag,
        int size = 1200,
      }) {
    // NAMESIS PRIME: see getImageUrl.
    final tmdbUrl = VirtualImages.urlFor(id, type, maxWidth: size);
    if (tmdbUrl != null) return tmdbUrl;
    return "http://127.0.0.1:9/no-image/$id/$type";
  }

  /// Movie/episode/live-TV stream URL. This intentionally uses the same
  /// `/Videos/{id}/stream` direct-stream endpoint for both rather than
  /// `/Videos/{id}/master.m3u8`. The HLS master-playlist endpoint requires
  /// proper transcoding negotiation (DeviceId, MediaSourceId, codec
  /// profiles, a PlaySessionId, etc.) to produce a playlist whose segments
  /// actually resolve — without that negotiation the server can't build a
  /// working playlist, so the player just sits there waiting on segments
  /// that never arrive (looks like it's "loading forever"). `static=true`
  /// asks the server for the source file directly, and is the only mode
  /// this used to support at all.
  ///
  /// The Quality selector (and Data Saver / Default / Max Quality mode)
  /// needs a *second* mode on top of that, though: capped-resolution
  /// transcoding. That's [maxHeight]/[videoBitrateKbps] below — passing
  /// either switches to `static=false` plus a `.ts` (MPEG-TS) progressive
  /// HTTP stream, which is a completely different, much simpler Jellyfin
  /// capability than the `master.m3u8` approach ruled out above: it's a
  /// single flat response, not a playlist of segment URLs the client has
  /// to keep re-requesting, so mpv can open it exactly like the
  /// `static=true` URL with no extra negotiation. Leaving both params null
  /// (the default) reproduces the exact original `static=true` URL this
  /// app has always used — nothing changes for anyone who never touches
  /// the Quality selector or sets a Data Usage mode other than Default.
  ///
  /// [audioStreamIndex] matters only in the transcoded branch: Jellyfin
  /// can only encode one audio track into a capped-resolution output, so
  /// this pins *which* of the item's tracks that should be (see
  /// PlayerManager.selectAudioTrack for what happens when someone changes
  /// tracks while a capped quality is active).
  ///
  /// [startTimeTicks] (.NET ticks — 10,000,000 per second) tells the
  /// transcoder to start encoding from that position rather than from
  /// 0:00. This matters specifically for the transcoded branch: unlike
  /// the plain `static=true` file (an ordinary HTTP resource that
  /// supports Range requests, so seeking into it after opening works
  /// fine), a capped-quality stream is being encoded live as it's
  /// requested — asking mpv to seek into an already-running transcode
  /// via an HTTP Range request isn't reliably supported and can leave
  /// the player waiting on data that never arrives (looks exactly like
  /// "stuck on loading"). Passing this instead means the transcode
  /// already starts at the right spot, so PlayerManager can skip the
  /// client-side seek entirely for this branch — see
  /// `_reopenStreamPreservingState`'s `seekAfterOpen` parameter.
  static String getVideoStreamUrl(
    String itemId, {
    String? mediaSourceId,
    int? maxHeight,
    int? videoBitrateKbps,
    int? audioStreamIndex,
    int? startTimeTicks,
  }) {
    if (maxHeight == null) {
      return "${JellyfinClient.serverUrl}"
          "/Videos/$itemId/stream"
          "?static=true"
          "&api_key=${JellyfinClient.token}";
    }

    final params = <String, String>{
      "static": "false",
      "maxHeight": "$maxHeight",
      "VideoCodec": "h264",
      "AudioCodec": "aac",
      "DeviceId": JellyfinClient.deviceId,
      "api_key": JellyfinClient.token,
      "PlaySessionId": "${itemId}_${DateTime.now().millisecondsSinceEpoch}",
    };

    if (videoBitrateKbps != null) {
      params["VideoBitRate"] = "${videoBitrateKbps * 1000}";
    }
    if (mediaSourceId != null) {
      params["MediaSourceId"] = mediaSourceId;
    }
    if (audioStreamIndex != null) {
      params["AudioStreamIndex"] = "$audioStreamIndex";
    }
    if (startTimeTicks != null && startTimeTicks > 0) {
      params["StartTimeTicks"] = "$startTimeTicks";
    }

    final query =
        params.entries.map((e) => "${e.key}=${e.value}").join("&");

    return "${JellyfinClient.serverUrl}/Videos/$itemId/stream.ts?$query";
  }

  /// Movie/episode stream URL at the original, unconstrained quality —
  /// kept as a thin wrapper so every existing caller (mediaItemFromJellyfin,
  /// DownloadManager) keeps working untouched. See [getVideoStreamUrl] for
  /// the capped-quality transcoding path PlayerManager uses instead when a
  /// Quality selector pick or Data Usage mode calls for it.
  static String getPlaybackUrl(String itemId) => getVideoStreamUrl(itemId);

  /// Audio stream URL. Audio items must go through the `/Audio` endpoint,
  /// not `/Videos/.../master.m3u8` — that endpoint expects a video item and
  /// will fail (or return nothing playable) for pure audio tracks, which is
  /// why songs were silently failing to play.
  ///
  /// [maxBitrateKbps] is the automatic-adaptive-quality hook: it maps
  /// straight onto Jellyfin's own `MaxStreamingBitrate` parameter on this
  /// same universal-audio endpoint, so capping quality for Data Saver mode
  /// (or Default mode reacting to a slow connection) is entirely a
  /// server-side transcoding decision — no new endpoint, no change to how
  /// audio has always been streamed here. Leaving it null (the default)
  /// reproduces the exact original URL.
  ///
  /// QUALITY-SWITCH FIX (music stopped dead when the quality changed
  /// mid-song): `TranscodingProtocol` is the video `.ts` branch's problem
  /// in audio form. A capped bitrate is the only thing that makes this
  /// endpoint actually transcode — every common library format is already
  /// in the direct-play `Container` list above — and under HLS that
  /// transcode comes back as a playlist Jellyfin is generating live. mpv
  /// can open it, but the client-side seek that a mid-song quality change
  /// performs right afterward (to get back to where the song was) has
  /// nothing to seek within yet, and the call simply never returns. So
  /// the capped case now asks for a progressive HTTP stream and carries
  /// its resume point server-side in [startTimeTicks] instead, exactly
  /// mirroring what `getVideoStreamUrl`'s transcode branch already does
  /// with `StartTimeTicks`.
  ///
  /// The uncapped URL is deliberately left byte-identical to what it has
  /// always been — that path direct-plays, works, and has no reason to
  /// change.
  ///
  /// [startTimeTicks] is .NET ticks (100ns units, 10,000,000 per second)
  /// and is only meaningful alongside [maxBitrateKbps]; there is nothing
  /// to tell the server about a start position when it is handing back
  /// the source file untouched.
  static String getAudioStreamUrl(
    String itemId, {
    int? maxBitrateKbps,
    int? startTimeTicks,
  }) {
    var url = "${JellyfinClient.serverUrl}"
        "/Audio/$itemId/universal"
        "?UserId=${JellyfinClient.userId}"
        "&DeviceId=${JellyfinClient.deviceId}"
        "&api_key=${JellyfinClient.token}"
        "&Container=mp3,aac,m4a,flac,wav,ogg,opus"
        "&TranscodingContainer=aac"
        "&TranscodingProtocol=${maxBitrateKbps == null ? "hls" : "http"}"
        "&AudioCodec=aac";

    if (maxBitrateKbps != null) {
      url += "&MaxStreamingBitrate=${maxBitrateKbps * 1000}";

      if (startTimeTicks != null && startTimeTicks > 0) {
        url += "&StartTimeTicks=$startTimeTicks";
      }
    }

    return url;
  }

  /// Static (non-transcoded) audio download URL — used by DownloadManager
  /// to pull the actual source file bytes for offline playback. Deliberately
  /// mirrors getPlaybackUrl's `static=true` direct-stream approach rather
  /// than getAudioStreamUrl's HLS negotiation above: HLS only ever returns
  /// a playlist manifest, never a single downloadable file, so saving that
  /// response to disk would just save text, not audio.
  static String getAudioDownloadUrl(String itemId) {
    return "${JellyfinClient.serverUrl}"
        "/Audio/$itemId/stream"
        "?static=true"
        "&api_key=${JellyfinClient.token}";
  }

  /// Progressive MP3 *transcode* at a fixed bitrate — a deliberately
  /// plainer alternative to [getAudioStreamUrl]'s capped AAC branch.
  /// Used by PlayerManager's music-stream recovery when the capped AAC
  /// stream gets cut short: MP3 is the one transcode target this app
  /// already relies on elsewhere (see [getAudioCastTranscodeUrl]) and
  /// the simplest thing Jellyfin's transcoder produces, so it's the
  /// first thing worth trying when the AAC one isn't surviving.
  ///
  /// [startTimeTicks] (.NET ticks, 10,000,000 per second) makes the
  /// server begin the encode at that point, so a resumed stream needs no
  /// client-side seek into a live transcode (which can't be done — see
  /// [getAudioStreamUrl]).
  ///
  /// [playSessionId] ties this transcode to the playback reports the
  /// app sends for the same song (see PlaybackProgressService): Jellyfin
  /// matches a transcoding job to a client's progress reports by this id,
  /// and uses those reports to decide when to pause/resume the encoder
  /// and when the job is still wanted. Without it the server has no way
  /// to know the client is still listening to the stream it is producing.
  static String getAudioMp3TranscodeUrl(
    String itemId, {
    required int maxBitrateKbps,
    int? startTimeTicks,
    String? playSessionId,
  }) {
    var url = "${JellyfinClient.serverUrl}"
        "/Audio/$itemId/stream.mp3"
        "?static=false"
        "&AudioCodec=mp3"
        "&AudioBitRate=${maxBitrateKbps * 1000}"
        "&DeviceId=${JellyfinClient.deviceId}"
        "&api_key=${JellyfinClient.token}";

    if (playSessionId != null && playSessionId.isNotEmpty) {
      url += "&PlaySessionId=${Uri.encodeQueryComponent(playSessionId)}";
    }

    if (startTimeTicks != null && startTimeTicks > 0) {
      url += "&StartTimeTicks=$startTimeTicks";
    }

    return url;
  }

  /// MP3 *download* at a fixed bitrate — what DownloadManager requests
  /// when a song is saved at anything other than "Original". The server
  /// re-encodes the song and streams the result back as one plain file
  /// (a progressive transcode, so no Content-Length and no Range
  /// support — see DownloadManager._runSongTask for how that's handled).
  /// Same request shape as [getAudioMp3TranscodeUrl], without a start
  /// offset: a download always wants the whole song.
  static String getAudioDownloadTranscodeUrl(
    String itemId,
    int bitrateKbps,
  ) =>
      getAudioMp3TranscodeUrl(itemId, maxBitrateKbps: bitrateKbps);

  /// Progressive (non-HLS) audio *transcode* — the audio-side counterpart
  /// to [getVideoStreamUrl]'s `maxHeight`-triggered `.ts` branch. Needed
  /// for Google Cast: the Default Media Receiver's officially supported
  /// container list is only MP2T/MP3/MP4/OGG/WAV/WebM
  /// (https://developers.google.com/cast/docs/media) — FLAC (and, in
  /// principle, anything else outside that list) isn't on it, so handing
  /// the receiver [getAudioDownloadUrl]'s raw FLAC file directly never
  /// plays, the same "unsupported container" failure
  /// `GoogleCastTransport._containerNeedsTranscodeForCast` already fixed
  /// for video. `stream.mp3` + `static=false` + `AudioCodec=mp3` mirrors
  /// the video branch's own reasoning for deliberately avoiding
  /// `/Audio/{id}/universal`'s `TranscodingProtocol=hls` path (see that
  /// method's own doc comment on why HLS never worked for Cast) — this
  /// is a single flat progressively-transcoded response, not a playlist
  /// the receiver has to negotiate segments for. MP3 specifically:
  /// explicitly on Google's supported list, and Jellyfin's simplest,
  /// most broadly-supported transcode target — no container-muxing
  /// ambiguity the way an AAC-in-MP4 target would have.
  static String getAudioCastTranscodeUrl(String itemId) {
    return "${JellyfinClient.serverUrl}"
        "/Audio/$itemId/stream.mp3"
        "?static=false"
        "&AudioCodec=mp3"
        "&DeviceId=${JellyfinClient.deviceId}"
        "&api_key=${JellyfinClient.token}";
  }

  /// HLS (seekable) audio *transcode* for Google Cast -- replaces
  /// [getAudioCastTranscodeUrl] as what `GoogleCastTransport` hands the
  /// receiver for songs it can't play as a raw file (FLAC, ALAC, WMA, ...).
  ///
  /// SEEK-RESTART FIX (root cause): [getAudioCastTranscodeUrl] is a single
  /// progressive `stream.mp3` transcode. Jellyfin answers that with a
  /// chunked response -- no `Content-Length`, no `Accept-Ranges` -- i.e. a
  /// stream the receiver can only ever read front to back. A Cast `SEEK`
  /// on such a stream has nothing to jump within, so the receiver
  /// re-opens it and plays from 0:00: exactly "dragging/tapping the seek
  /// bar restarts the song", and only for the songs that take the
  /// transcode path (direct-streamed mp3/m4a/aac/ogg/wav songs, and
  /// on-device songs served by LocalCastServer, both honor byte ranges
  /// and seek fine).
  ///
  /// `/Audio/{id}/master.m3u8` is Jellyfin's HLS audio endpoint -- the
  /// same mechanism [getVideoCastTranscodeUrl] already uses successfully
  /// for video. The playlist is a full-length VOD list of TS segments, so
  /// the receiver knows the real duration and can jump to any segment;
  /// Jellyfin (re)starts the transcode at whichever segment is requested.
  /// `MediaSourceId` is required by the endpoint (see
  /// [getVideoCastTranscodeUrl]'s doc comment on what omitting it does).
  /// AAC in MPEG-TS is decodable by every receiver generation, and
  /// adaptive bitrate is turned off for the same reason as the video
  /// URL: a single LAN receiver has no use for lower-bitrate variants.
  /// The receiver must be told `application/x-mpegurl` for this URL.
  static String getAudioCastHlsUrl(String itemId, {String? mediaSourceId}) {
    final params = <String, String>{
      'MediaSourceId': mediaSourceId ?? itemId,
      'AudioCodec': 'aac',
      'SegmentContainer': 'ts',
      'TranscodingMaxAudioChannels': '2',
      'EnableAdaptiveBitrateStreaming': 'false',
      'DeviceId': JellyfinClient.deviceId,
      'api_key': JellyfinClient.token,
      'PlaySessionId': '${itemId}_${DateTime.now().millisecondsSinceEpoch}',
    };
    final query = params.entries
        .map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}')
        .join('&');
    return '${JellyfinClient.serverUrl}/Audio/$itemId/master.m3u8?$query';
  }

  /// HLS remux for Google Cast — the container-only counterpart to
  /// [getVideoStreamUrl]'s codec-transcode `.ts` branch. Fixes MKV (and
  /// any other Cast-unsupported container) failing to cast even when its
  /// video/audio codecs are already Cast-compatible (h264/aac): Google's
  /// Default Media Receiver only demuxes MP2T/MP3/MP4/OGG/WAV/WebM
  /// (https://developers.google.com/cast/docs/media) — Matroska was never
  /// on that list, so declaring an accurate `video/x-matroska`
  /// Content-Type for it (see GoogleCastTransport._resolveCastMedia's
  /// default direct-stream branch) just lets the receiver correctly
  /// recognize, and correctly refuse to open, the container.
  ///
  /// Deliberately hits `/Videos/{id}/master.m3u8` — Jellyfin's HLS
  /// endpoint — rather than routing through [getVideoStreamUrl]'s
  /// progressive `.ts` transcode branch. That branch forces a full
  /// re-encode starting from byte zero regardless of whether the source
  /// codec already matches what's requested, which is a needless
  /// multi-second re-encode startup delay for the common case here (an
  /// MKV that's already h264/aac and only has the wrong container).
  /// Jellyfin's HLS transcoder does a per-track *stream copy* instead
  /// whenever the requested [VideoCodec]/[AudioCodec] already matches the
  /// source — exactly true for everything routed here by
  /// `GoogleCastTransport._needsContainerTranscodeForCast` (which only
  /// fires when the codecs are already Cast-compatible and only the
  /// container is the problem) — so this remuxes into MPEG-TS segments
  /// with no re-encoding at all in the common case, avoiding the
  /// startup-latency failure that sank the progressive `.ts` branch for
  /// this use case.
  /// CASTING FIX (MKV still never played, *and* MP4s that used to work
  /// stopped once anything routed them here): the first version of this
  /// URL left out `MediaSourceId`. That parameter isn't optional on
  /// Jellyfin's `/Videos/{id}/master.m3u8` — `DynamicHlsController
  /// .GetMasterHlsVideoPlaylist` declares it `[Required]`, so every
  /// request built without it was answered with a 400 before the
  /// transcoder was ever consulted. The receiver therefore got a URL that
  /// returns an error page instead of a playlist, accepted the load
  /// request, and then never reached a real `playing` status — exactly
  /// the same silent-failure signature an undecodable codec produces,
  /// which is why it read as "the remux fix didn't work" rather than as a
  /// malformed request. [mediaSourceId] now always ends up in the query:
  /// the caller's real `MediaSources[0].Id` when it has one, otherwise
  /// [itemId] itself (which is what Jellyfin's media source id is for a
  /// single-source library item anyway).
  ///
  /// [allowVideoStreamCopy]/[allowAudioStreamCopy] are what let this one
  /// endpoint serve both jobs `GoogleCastTransport._resolveCastMedia`
  /// used to split across two different URLs. Jellyfin decides per track
  /// whether to stream-copy or re-encode; these flags let the caller veto
  /// a copy for the specific track it already knows the receiver can't
  /// decode (see `_needsVideoTranscodeForCast`/
  /// `_needsAudioTranscodeForCast`) while leaving the other track free to
  /// be copied. So a Cast-incompatible container with good codecs is a
  /// pure remux, and a file with (say) DTS audio in an MKV re-encodes
  /// just the audio and copies the H.264 video — instead of the
  /// everything-from-scratch re-encode [getVideoStreamUrl]'s progressive
  /// `.ts` branch forces, whose startup latency routinely outran the
  /// receiver's own load timeout.
  ///
  /// `RequireAvc` keeps the output AVC. The `h264-profile`/`h264-level`
  /// constraints and an explicit bitrate are sent *only* when
  /// [allowVideoStreamCopy] is already false — see the comment on that
  /// block for why sending them on the copy path silently turned every
  /// remux into a full re-encode.
  static String getVideoCastTranscodeUrl(
    String itemId, {
    String? mediaSourceId,
    int? audioStreamIndex,
    bool allowVideoStreamCopy = true,
    bool allowAudioStreamCopy = true,
  }) {
    final params = <String, String>{
      // Required by Jellyfin — see this method's doc comment. Falls back
      // to the item id rather than being omitted, since omitting it is
      // what broke this endpoint outright.
      'MediaSourceId': mediaSourceId ?? itemId,
      'VideoCodec': 'h264',
      // Both are carryable in MPEG-TS and decodable by every receiver
      // generation, so listing both lets Jellyfin stream-copy an MP3
      // soundtrack instead of re-encoding it for no reason. When a real
      // transcode is needed it takes the first entry, AAC.
      'AudioCodec': 'aac,mp3',
      'SegmentContainer': 'ts',
      'AllowVideoStreamCopy': allowVideoStreamCopy ? 'true' : 'false',
      'AllowAudioStreamCopy': allowAudioStreamCopy ? 'true' : 'false',
      // Only applies when a track actually is re-encoded — leaving it at
      // 2 keeps a transcoded soundtrack inside what every generation of
      // receiver handles, without forcing a multichannel track that
      // could have been copied into a needless re-encode.
      'TranscodingMaxAudioChannels': '2',
      'RequireAvc': 'true',
      // QUALITY FIX (MKV cast at visibly worse quality than the source):
      // Jellyfin's master playlist offers lower-bitrate variants by
      // default, and a Cast receiver will happily settle on one of them
      // — most visibly right at startup, before it has measured the
      // link. Nothing here wants adaptive switching: the receiver is on
      // the same LAN as the server, and the whole point of this URL is
      // to hand it the source quality in a container it can open.
      'EnableAdaptiveBitrateStreaming': 'false',
      'DeviceId': JellyfinClient.deviceId,
      'api_key': JellyfinClient.token,
      'PlaySessionId': '${itemId}_${DateTime.now().millisecondsSinceEpoch}',
    };

    // QUALITY FIX, second half — and the bigger of the two. These
    // constraints used to be sent unconditionally, as a safety net
    // against Jellyfin stream-copying something the receiver can't
    // decode. They did the opposite of what was wanted whenever a copy
    // was actually possible: `CanStreamCopyVideo` refuses the copy
    // outright when a profile or level is requested and the source
    // stream doesn't *report* one (`videoStream.Profile` empty, or
    // `Level` null), which is common for MKV remuxes. So a file that
    // needed nothing but a container change was being fully re-encoded,
    // at whatever bitrate the server picked on its own — which is
    // exactly what "casts fine now, but looks worse than the file does
    // locally" is.
    //
    // They're now sent only when the copy has already been vetoed by
    // `allowVideoStreamCopy: false`, where they cost nothing (a
    // re-encode is happening regardless) and still do their real job of
    // pinning the output to a profile/level every receiver generation
    // decodes. The generous `VideoBitRate` goes with them for the same
    // reason: it only applies to a re-encode, and left unset Jellyfin
    // picks a conservative default. It is deliberately *not* sent on the
    // copy path — `CanStreamCopyVideo` also refuses a copy when a
    // bitrate is requested and the source stream's own bitrate is
    // unknown, so sending one there would re-break the exact thing this
    // is fixing.
    if (!allowVideoStreamCopy) {
      params['h264-profile'] = 'high,main,baseline';
      params['h264-level'] = '51';
      params['VideoBitRate'] = '20000000';
    }
    if (audioStreamIndex != null) {
      params['AudioStreamIndex'] = '$audioStreamIndex';
    }

    final query = params.entries
        .map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}')
        .join('&');
    return '${JellyfinClient.serverUrl}/Videos/$itemId/master.m3u8?$query';
  }

  /// DLNA / UPnP TVs (LG webOS, Samsung Tizen, Sony, ...) can't be
  /// relied on to play HLS, and have no Cast-style receiver that can
  /// negotiate it. What every one of them does handle is a single
  /// progressive MPEG-TS over plain HTTP, so this asks Jellyfin for
  /// exactly that: `/Videos/{id}/stream.ts`.
  ///
  /// Used by `DlnaTransport` in three situations, all of which need the
  /// *server* to do something a TV can't be told to do itself:
  ///   * the TV rejected the direct file (unsupported codec/container),
  ///   * a specific audio track was picked ([audioStreamIndex]) — DLNA has
  ///     no "switch audio track" command, so the stream itself has to
  ///     carry the chosen track,
  ///   * a seek on that progressive stream ([startTimeTicks]) — a
  ///     transcode isn't byte-seekable, so the stream is simply restarted
  ///     at the new position.
  ///
  /// Copy/re-encode flags follow the same rule as
  /// [getVideoCastTranscodeUrl]: H.264 / AAC / MP3 / AC3 are copied
  /// untouched when allowed, and the h264 profile/level/bitrate pins are
  /// only sent when a re-encode is already happening.
  static String getVideoDlnaStreamUrl(
    String itemId, {
    String? mediaSourceId,
    int? audioStreamIndex,
    bool allowVideoStreamCopy = true,
    bool allowAudioStreamCopy = true,
    int startTimeTicks = 0,
  }) {
    final params = <String, String>{
      'static': 'false',
      'MediaSourceId': mediaSourceId ?? itemId,
      'VideoCodec': 'h264',
      'AudioCodec': 'aac,ac3,mp3',
      'AllowVideoStreamCopy': allowVideoStreamCopy ? 'true' : 'false',
      'AllowAudioStreamCopy': allowAudioStreamCopy ? 'true' : 'false',
      'TranscodingMaxAudioChannels': '6',
      'RequireAvc': 'true',
      'DeviceId': JellyfinClient.deviceId,
      'api_key': JellyfinClient.token,
      'PlaySessionId': '${itemId}_${DateTime.now().millisecondsSinceEpoch}',
    };
    if (!allowVideoStreamCopy) {
      params['h264-profile'] = 'high,main,baseline';
      params['h264-level'] = '41';
      params['VideoBitRate'] = '20000000';
    }
    if (audioStreamIndex != null) {
      params['AudioStreamIndex'] = '$audioStreamIndex';
    }
    if (startTimeTicks > 0) {
      params['StartTimeTicks'] = '$startTimeTicks';
    }
    final query = params.entries
        .map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}')
        .join('&');
    return '${JellyfinClient.serverUrl}/Videos/$itemId/stream.ts?$query';
  }

  /// Converts a MusicSort into Jellyfin SortBy/SortOrder.
  static Map<String, String> musicSortToQuery(dynamic sort) {
    switch (sort.toString().split('.').last) {
      case "newest":
        return {
          "sortBy": "DateCreated",
          "sortOrder": "Descending",
        };

      case "rating":
        return {
          "sortBy": "CommunityRating",
          "sortOrder": "Descending",
        };

      case "year":
        return {
          "sortBy": "ProductionYear",
          "sortOrder": "Descending",
        };

      case "album":
        return {
          "sortBy": "Album",
          "sortOrder": "Ascending",
        };

      case "az":
      default:
        return {
          "sortBy": "SortName",
          "sortOrder": "Ascending",
        };
    }
  }static Future<Map<String, dynamic>> getMusicItem(String id) async {
    final response = await JellyfinClient.dio.get(
      "/Users/${JellyfinClient.userId}/Items/$id",
      queryParameters: {
        "Fields":
        "Overview,Genres,People,ProductionYear,"
            "RunTimeTicks,AlbumArtists,ArtistItems,"
            "CommunityRating,ImageTags,BackdropImageTags,"
            "UserData",
      },
    );

    return Map<String, dynamic>.from(response.data);
  }
  static Future<List<dynamic>> getAlbumTracks(
      String albumId,
      ) async {
    return getItems(
      parentId: albumId,
      includeItemTypes: "Audio",
      sortBy: "IndexNumber",
      sortOrder: "Ascending",
      recursive: false,
      limit: 1000,
    );
  }
  static Future<List<dynamic>> getArtistSongs(
      String artistId,
      ) async {

    final response = await JellyfinClient.dio.get(
      "/Users/${JellyfinClient.userId}/Items",
      queryParameters: {
        "ArtistIds": artistId,
        "IncludeItemTypes": "Audio",
        "Recursive": true,
        "SortBy": "SortName",
        "Limit": 1000,
      },
    );

    return response.data["Items"] ?? [];
  }

  /// Fetches the rest of an artist's discography for the album detail
  /// screen's "Other Albums by <Artist>" row — newest first, same as a
  /// normal discography listing, with [excludeAlbumId] (the album
  /// currently being viewed) filtered out client-side since Jellyfin
  /// has no server-side "not this id" query param.
  static Future<List<dynamic>> getArtistAlbums(
      String artistId, {
        String? excludeAlbumId,
        int limit = 20,
      }) async {
    final response = await JellyfinClient.dio.get(
      "/Users/${JellyfinClient.userId}/Items",
      queryParameters: {
        "ArtistIds": artistId,
        "IncludeItemTypes": "MusicAlbum",
        "Recursive": true,
        "SortBy": "PremiereDate,SortName",
        "SortOrder": "Descending",
        "Fields": "PrimaryImageAspectRatio",
        "Limit": limit,
      },
    );

    final items = List<dynamic>.from(response.data["Items"] ?? []);

    if (excludeAlbumId != null) {
      items.removeWhere((a) => a["Id"] == excludeAlbumId);
    }

    return items;
  }
  /// Fetches a playlist's tracks via the dedicated Playlists endpoint
  /// (not the generic Items?ParentId= lookup) — this is the only
  /// endpoint Jellyfin actually attaches a "PlaylistItemId" to each
  /// returned song. That field is what removeFromPlaylist() needs to
  /// delete the correct entry; fetching via ParentId returned plain
  /// library items with no PlaylistItemId at all, so every "Remove
  /// from Playlist" tap was silently falling back to the song's own
  /// item id, which the server doesn't recognize as a playlist entry —
  /// removal always failed with "Failed to remove from playlist"
  /// regardless of which song was picked.
  ///
  /// Fields requested are deliberately narrower than the generic
  /// getItems() set — Overview/Genres/ProductionYear/CommunityRating/
  /// BackdropImageTags/ImageTags/PrimaryImageAspectRatio are all
  /// movie/show-oriented fields nothing in the music UI ever reads off
  /// an individual song, but Jellyfin was still populating (and this
  /// app parsing) one full copy of each per track. That's negligible
  /// for a 12-track album, but playlists routinely run into the
  /// hundreds — this was consistently the slowest-loading detail
  /// screen in the app, and trimming the per-track payload down to
  /// only what's actually displayed (Album/AlbumArtist/ArtistItems,
  /// RunTimeTicks for the total-duration readout, UserData for
  /// favorite/play-count) or needed for playback (MediaSources/
  /// MediaStreams, for audio/subtitle track syncing) is most of why.
  static Future<List<dynamic>> getPlaylistTracks(
      String playlistId,
      ) async {
    final response = await JellyfinClient.dio.get(
      "/Playlists/$playlistId/Items",
      queryParameters: {
        "UserId": JellyfinClient.userId,
        "Fields":
        "RunTimeTicks,"
            "UserData,"
            "MediaSources,"
            "MediaStreams,"
            "Album,"
            "AlbumArtist,"
            "ArtistItems,"
            // Needed so the playlist detail screen can show the set of
            // genres actually present across its tracks (playlists
            // themselves don't carry a Genres field of their own).
            "Genres",
      },
    );

    if (response.statusCode != 200) {
      throw Exception("Failed to load playlist tracks: ${response.statusCode}");
    }

    return response.data["Items"] ?? [];
  }
  /// Jellyfin's own "Instant Mix" engine — the same recommendation logic
  /// that powers the "Instant Mix" action in the official apps, seeded
  /// from a single song. This is the primary signal source for Nemesis's
  /// auto-queue continuation (see MusicRecommendationService); rather than
  /// trust any one seed's mix alone, several of these calls (one per
  /// recently-played song) get fused together into a single ranked list.
  static Future<List<dynamic>> getInstantMix(
      String itemId, {
        int limit = 20,
      }) async {
    final response = await JellyfinClient.dio.get(
      "/Items/$itemId/InstantMix",
      queryParameters: {
        "UserId": JellyfinClient.userId,
        "Limit": limit,
        "Fields": "Genres,ArtistItems,Album,AlbumArtist,UserData",
      },
    );

    if (response.statusCode != 200) return [];
    return response.data["Items"] ?? [];
  }

  static Future<List<dynamic>> getSimilarMusic(
      String itemId, {
        int limit = 12,
      }) async {    final response = await JellyfinClient.dio.get(
      "/Items/$itemId/Similar",
      queryParameters: {
        "UserId": JellyfinClient.userId,
        "Limit": limit,
        "Fields": "PrimaryImageAspectRatio",
      },
    );

    if (response.statusCode != 200) {
      return [];
    }

    return response.data["Items"] ?? [];


}


  static Future<List> getSimilarArtists(
      String artistId,
      ) async {
    final response = await JellyfinClient.dio.get(
      "/Items/$artistId/Similar",
      queryParameters: {
        "Limit": 20,
        "Recursive": true,
      },
    );
    final items = response.data["Items"] ?? [];

    return items.where((item) {

      return item["Type"] == "MusicArtist";

    }).toList();
  }

  static Future<List> getLiveTvChannels() async {
    final response = await JellyfinClient.dio.get(
      "/LiveTv/Channels",
      // Jellyfin defaults AddCurrentProgram to true, which makes the server
      // look up the on-air program for EVERY channel before it can answer
      // (slow with large IPTV channel lists). Nothing in the app reads a
      // channel's embedded CurrentProgram — "now / next" always comes from
      // the guide call (getGuide) — so skip it.
      queryParameters: {"AddCurrentProgram": false},
    );

    // The client's Dio instance is configured with `validateStatus: (_)
    // => true`, so a 401/500/etc never throws here — it comes back as a
    // normal Response with that statusCode and a body that's often not
    // even JSON (an auth error page, plain text, ...). Indexing
    // `response.data["Items"]` without checking the status first meant
    // that on anything but a real success, `response.data` was a
    // String, and `aString["Items"]` throws "type 'String' is not a
    // subtype of type 'int' of 'index'" (String's [] operator wants an
    // int character index, not a key) — which the caller then swallows
    // and quietly leaves the Live TV screen spinning forever with no
    // channels and no error shown.
    if (response.statusCode != 200) {
      throw Exception(
        "Failed to load live tv channels: ${response.statusCode}",
      );
    }

    return response.data["Items"] ?? [];
  }

  static Future<List> getPrograms({
    required String channelId,
  }) async {

    // Same StartDate/EndDate window params as getGuide() above — that
    // endpoint is proven to work (it's what powers the whole TV Guide
    // screen) and, crucially, Jellyfin treats them as an *overlap*
    // filter: any program whose EndDate is after StartDate(param) and
    // whose StartDate is before EndDate(param) is included, which is
    // exactly what lets a program that started before "now" but is
    // still airing show up as the current one. A previous attempt here
    // swapped these for "MinEndDate"/"MaxStartDate", believing
    // StartDate/EndDate weren't recognized on this endpoint — they are
    // (see getGuide), and those unrecognized replacement params are
    // what caused this call to come back empty instead.
    final now = DateTime.now();

    final response = await JellyfinClient.dio.get(
      "/LiveTv/Programs",
      queryParameters: {
        "ChannelIds": channelId,
        "UserId": JellyfinClient.userId,
        "StartDate": now.toUtc().toIso8601String(),
        "EndDate": now.add(const Duration(hours: 24)).toUtc().toIso8601String(),
        "Limit": 10,
        "SortBy": "StartDate",
        "Fields": "Overview",
      },
    );

    return response.data["Items"] ?? [];
  }

  static Future<Map<String, dynamic>> getLiveTvChannel(
      String id,
      ) async {

    final response = await JellyfinClient.dio.get(
      "/LiveTv/Channels/$id",
    );

    return Map<String, dynamic>.from(
      response.data,
    );
  }

  /// Live TV channel stream URL at the original, unconstrained quality —
  /// see [getVideoStreamUrl], which this now shares with movie/episode
  /// playback (both hit the same `/Videos/{id}/stream` endpoint).
  static String getLiveTvStreamUrl(
      String channelId,
      ) => getVideoStreamUrl(channelId);

  static MediaItem mediaItemFromJellyfin(
      Map<String, dynamic> item,
      ) {

    // (Two debugPrint calls used to sit here — once per item. Tapping a
    // song in a 5000-song list builds the whole list's MediaItems, so that
    // was ~10,000 log lines on the UI thread per tap.)
    final type = item["Type"] ?? "";
    final mediaType = item["MediaType"] ?? "";

    final isAudio = type == "Audio" || mediaType == "Audio";

    String streamUrl;
    if (type == "TvChannel") {
      streamUrl = getLiveTvStreamUrl(item["Id"]);
    } else if (isAudio) {
      streamUrl = getAudioStreamUrl(item["Id"]);
    } else {
      streamUrl = getPlaybackUrl(item["Id"]);
    }

    // Jellyfin's most reliable per-track artist field is `Artists` (a
    // list — a song can have more than one) — prefer its first entry,
    // then the older singular `Artist` field some servers still send,
    // and only fall back to `AlbumArtist` (which can be a compilation's
    // "Various Artists" rather than who actually performed this track)
    // as a last resort. Never falls through to Album/SeriesName the way
    // `subtitle` above deliberately does for display purposes — this is
    // specifically for callers (LRCLIB matching) that need a real
    // artist name or nothing.
    final artistsList = item["Artists"];
    final artistName = (artistsList is List && artistsList.isNotEmpty)
        ? artistsList.first.toString()
        : (item["Artist"] as String?) ?? (item["AlbumArtist"] as String?) ?? "";

    // ARTIST DISPLAY FIX (feature/collab tracks showing only one name):
    // mirrors the fix already applied to song_row.dart — `AlbumArtist`
    // is a per-*album* field, not per-track, so a multi-artist song
    // used to show only the primary/album artist (or the literal
    // "Various Artists" on a compilation) in the audio player screen,
    // lyrics screen, and mini player (normal + casting), since all
    // three just render this MediaItem's `subtitle` and none of them
    // had their own artist logic to fix separately. `Artists`/
    // `ArtistItems` carry the full per-track credit list, so they're
    // joined in full and preferred over `AlbumArtist` for audio items
    // specifically — non-audio subtitle behavior (Album/SeriesName
    // fallbacks for episodes etc.) is untouched.
    String joinedArtists = "";
    if (artistsList is List && artistsList.isNotEmpty) {
      joinedArtists = artistsList.join(", ");
    } else if (item["ArtistItems"] is List &&
        (item["ArtistItems"] as List).isNotEmpty) {
      joinedArtists = (item["ArtistItems"] as List)
          .map((a) => a["Name"] ?? "")
          .where((name) => name.toString().isNotEmpty)
          .join(", ");
    }

    // Episodes almost never have their own Backdrop/Logo art uploaded in
    // Jellyfin — that art lives on the parent Series instead. Building
    // these URLs from the episode's own Id 404s for most shows, which is
    // why the player's loading screen was showing a plain black screen
    // (both the backdrop and the logo silently disappear on a failed
    // load) for episodes even though the same code worked fine for
    // movies. Fall back to the series' art for episodes, same as the
    // Thumb-image fallback already used for Continue Watching above.
    final backdropLogoId = (type == "Episode" && item["SeriesId"] != null)
        ? item["SeriesId"].toString()
        : item["Id"];

    return MediaItem(
      id: item["Id"],
      title: item["Name"] ?? "",
        subtitle: isAudio && joinedArtists.isNotEmpty
            ? joinedArtists
            : (item["AlbumArtist"] ??
                item["Album"] ??
                item["SeriesName"] ??
                item["Artist"] ??
                ""),
      streamUrl: streamUrl,
        image: getPrimaryImage(item["Id"]),
      // Episodes' own Primary image is the episode thumbnail, not a
      // poster — see MediaItem.seriesImage's doc comment. Only fetched
      // for episodes (mirrors the backdropLogoId fallback just above);
      // getPrimaryImage is a pure URL builder (no network call itself),
      // so this costs nothing extra beyond the one field being present.
      seriesImage: (type == "Episode" && item["SeriesId"] != null)
          ? getPrimaryImage(item["SeriesId"].toString())
          : null,
      backdrop: getBackdropUrl(backdropLogoId),
      // TV channels only ever have a Primary image in Jellyfin (their
      // channel icon) — they never have a Logo-type image the way movies/
      // shows do. Requesting getLogoUrl() for a channel 404s, which
      // PulsingLogo's errorBuilder silently swallows, so the loading/
      // buffering overlays fell back to a plain black screen with no
      // logo at all for live TV. Every other screen that shows a channel
      // "logo" (live_tv_detail_screen, channel_card, channel_logo_card,
      // guide_channel_tile, ...) already reads it from getPrimaryImage()
      // instead — matching that here is what makes the channel icon
      // actually show up, using the exact same LoadingOverlay/
      // BufferingOverlay/PulsingLogo code path movies already use.
      logo: type == "TvChannel"
          ? getPrimaryImage(item["Id"])
          : getLogoUrl(backdropLogoId),
      seriesId: item["SeriesId"],
      seasonId: item["SeasonId"],
      seasonNumber: item["ParentIndexNumber"] is int
          ? item["ParentIndexNumber"]
          : int.tryParse(item["ParentIndexNumber"]?.toString() ?? ""),
      episodeNumber: item["IndexNumber"] is int
          ? item["IndexNumber"]
          : int.tryParse(item["IndexNumber"]?.toString() ?? ""),
      live: type == "TvChannel",
        audioOnly: isAudio,
      artistName: artistName,

      playbackPosition:
      item["UserData"]?["PlaybackPositionTicks"] != null
          ? Duration(
        microseconds:
        (item["UserData"]["PlaybackPositionTicks"] ~/ 10),
      )
          : null,

      played: item["UserData"]?["Played"] == true,

      // Jellyfin's own authoritative total length for this item — never
      // actually wired up here before now, so `MediaItem.runtime`
      // silently defaulted to `Duration.zero` for every single item
      // regardless of what the server actually reported. That's the
      // real reason PlayerManager's "prefer Jellyfin's metadata over
      // mpv's own duration" fix (needed specifically because a
      // capped-quality `.ts` transcode may never report a usable
      // duration from mpv at all — see PlayerManager._waitForDuration's
      // doc comment) never actually did anything: the fallback it was
      // supposed to avoid was the ONLY path ever taken, since there was
      // never a real value here to prefer in the first place.
      runtime: item["RunTimeTicks"] != null
          ? Duration(microseconds: (item["RunTimeTicks"] as num) ~/ 10)
          : Duration.zero,

      // Real Intro/Outro timestamps aren't available synchronously here
      // (they need their own network round trip) — PlayerManager fetches
      // them via getSkipSegments() right as playback starts and grafts
      // them onto this item with MediaItem.copyWith once they land. This
      // used to be a pair of hardcoded placeholder windows (a flat 5s-80s
      // intro and 41-45min "credits") applied to every single video
      // regardless of its actual length or content, which is exactly why
      // the skip buttons were showing up at the wrong moment — a 20-
      // minute sitcom episode doesn't have anything happening at the
      // 41-minute mark. Starting empty and filling in the real per-item
      // segments once fetched is what makes the timing correct instead
      // of coincidentally right only for videos that happen to be ~45
      // minutes long.
      skipSegments: const [],

      mediaStreams: item["MediaStreams"] != null
          ? List<dynamic>.from(item["MediaStreams"])
          : null,

      mediaSources: item["MediaSources"] != null
          ? List<dynamic>.from(item["MediaSources"])
          : null,

      trickplay: item["Trickplay"] != null
          ? Map<String, dynamic>.from(item["Trickplay"])
          : null,

      raw: item,
    );
  }

  static List<MediaItem> mediaItemsFromList(
      List<dynamic> items,
      ) {
    return items
        .map(
          (e) => mediaItemFromJellyfin(
        Map<String, dynamic>.from(e),
      ),
    )
        .toList();
  }

}


