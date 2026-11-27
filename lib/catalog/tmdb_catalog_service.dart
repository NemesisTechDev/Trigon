import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../services/proxy_config.dart';
import 'catalog_models.dart';

/// Browse/search/detail data from TMDB — the "what exists" half of the app.
/// (The "how to play it" half is the addon layer.)
///
/// ### Access modes
/// 1. **Direct** — build with `--dart-define=TMDB_API_KEY=<key>`. A v3 key is
///    sent as `?api_key=`, a v4 "read access token" (long, starts `eyJ`) as a
///    Bearer header. Fine for development. A key compiled into an APK can be
///    extracted, so prefer mode 2 for anything you distribute.
/// 2. **Proxy** — leave TMDB_API_KEY empty and the service goes through
///    [ProxyConfig] (`<proxy>/tmdb/...`) exactly like the existing
///    TmdbService does. The Worker must allow the routes used below:
///    `/trending/*`, `/movie/*`, `/tv/*`, `/discover/*`, `/genre/*`,
///    `/search/*`.
class TmdbCatalogService {
  TmdbCatalogService._();

  static const String _apiKey = String.fromEnvironment('TMDB_API_KEY');
  static const String _directBase = 'https://api.themoviedb.org/3';

  static bool get _direct => _apiKey.isNotEmpty;
  static bool get isConfigured => _direct || ProxyConfig.isConfigured;

  static String get _base =>
      _direct ? _directBase : '${ProxyConfig.baseUrl}/tmdb';

  static final Dio _dio = Dio(
    BaseOptions(
      // NAMESIS PRIME: generous timeouts. Slow DNS / mobile-style links
      // were timing out at 8s and leaving detail screens half-filled.
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 25),
      validateStatus: (_) => true,
    ),
  );

  static const Duration _ttl = Duration(minutes: 10);
  static final Map<String, _Cached> _cache = {};
  static final Map<String, Future<Map<String, dynamic>?>> _inflight = {};

  static Future<Map<String, dynamic>?> _get(
    String path, [
    Map<String, dynamic> query = const {},
  ]) {
    final merged = <String, dynamic>{
      'language': 'en-US',
      'include_adult': 'false',
      ...query,
    };
    final key = '$path?${(merged.entries.toList()..sort((a, b) => a.key.compareTo(b.key))).map((e) => '${e.key}=${e.value}').join('&')}';

    final hit = _cache[key];
    // Title/season details barely change; lists change more often.
    final isDetail = RegExp(r'^/(movie|tv|collection)/\d+').hasMatch(path);
    final ttl = isDetail ? const Duration(hours: 6) : _ttl;
    if (hit != null && DateTime.now().difference(hit.at) < ttl) {
      return Future.value(hit.data);
    }
    // Collapse duplicate concurrent requests (several rows asking for the
    // same list at once).
    return _inflight[key] ??=
        _resolve(path, merged, key, ttl, isDetail).whenComplete(() {
      _inflight.remove(key);
    });
  }

  static final Set<String> _refreshing = {};

  /// NAMESIS PRIME: stale-while-revalidate on disk. Anything fetched before
  /// (even in an earlier launch) is shown instantly; if it is older than
  /// [ttl] a fresh copy is fetched in the background for next time. Only a
  /// title never seen before waits for the network.
  static Future<Map<String, dynamic>?> _resolve(
    String path,
    Map<String, dynamic> merged,
    String key,
    Duration ttl,
    bool isDetail,
  ) async {
    final disk = await _TmdbDisk.read(key);
    if (disk != null) {
      final age = DateTime.now().difference(disk.at);
      final maxAge =
          isDetail ? const Duration(days: 7) : const Duration(hours: 12);
      if (age < maxAge) {
        _cache[key] = _Cached(disk.data, disk.at);
        if (age >= ttl && _refreshing.add(key)) {
          unawaited(_fetch(path, merged, key)
              .whenComplete(() => _refreshing.remove(key)));
        }
        return disk.data;
      }
    }
    return _fetch(path, merged, key);
  }

  static Future<Map<String, dynamic>?> _fetch(
    String path,
    Map<String, dynamic> query,
    String cacheKey,
  ) async {
    if (!isConfigured) {
      debugPrint('[TmdbCatalog] not configured (no TMDB_API_KEY, no proxy)');
      return _cache[cacheKey]?.data;
    }

    final params = Map<String, dynamic>.from(query);
    final headers = <String, String>{};
    if (_direct) {
      if (_apiKey.length > 40) {
        headers['Authorization'] = 'Bearer $_apiKey';
      } else {
        params['api_key'] = _apiKey;
      }
    } else {
      headers.addAll(ProxyConfig.headers);
    }

    // NAMESIS PRIME: up to 3 attempts. Network hiccups (DNS, timeouts),
    // 429 and 5xx are retried; 4xx answers (bad key, not found) are not.
    const maxAttempts = 3;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      final clock = Stopwatch()..start();
      try {
        final res = await _dio.get(
          '$_base$path',
          queryParameters: params,
          // Plain text on purpose: the body is decoded below (off the UI
          // thread when large) and the very same text is written to the
          // disk cache, so nothing is ever re-encoded on the UI thread.
          options: Options(headers: headers, responseType: ResponseType.plain),
        );
        if (clock.elapsedMilliseconds > 2000) {
          debugPrint('[TmdbCatalog] slow: $path took '
              '${clock.elapsedMilliseconds} ms (attempt $attempt)');
        }
        final code = res.statusCode ?? 0;
        final raw = res.data;
        if (code == 200 && raw is String) {
          final decoded = raw.length > _isolateDecodeThreshold
              ? await compute(_decodeJsonText, raw)
              : _decodeJsonText(raw);
          if (decoded is Map) {
            final data = Map<String, dynamic>.from(decoded);
            _cache[cacheKey] = _Cached(data, DateTime.now());
            unawaited(_TmdbDisk.writeRaw(cacheKey, raw));
            return data;
          }
        }
        final retryable = code == 429 || code >= 500;
        if (retryable && attempt < maxAttempts) {
          await Future<void>.delayed(Duration(milliseconds: 500 * attempt));
          continue;
        }
        debugPrint('[TmdbCatalog] $path -> $code');
        return _cache[cacheKey]?.data; // stale beats nothing
      } catch (e) {
        if (attempt < maxAttempts) {
          await Future<void>.delayed(Duration(milliseconds: 500 * attempt));
          continue;
        }
        debugPrint('[TmdbCatalog] $path failed after $attempt tries: $e');
        return _cache[cacheKey]?.data;
      }
    }
    return _cache[cacheKey]?.data;
  }


  /// Raw TMDB access for the virtual-server layer (lib/virtual), which needs
  /// endpoints and parameters beyond the typed helpers above.
  static Future<Map<String, dynamic>?> raw(
    String path, [
    Map<String, dynamic> query = const {},
  ]) =>
      _get(path, query);

  // ---------- lists ----------

  static List<CatalogTitle> _titles(
    Map<String, dynamic>? data, {
    CatalogType? type,
    bool requirePoster = true,
  }) {
    final results = data?['results'];
    if (results is! List) return const [];
    final out = <CatalogTitle>[];
    for (final r in results.whereType<Map>()) {
      final m = Map<String, dynamic>.from(r);
      // Trending/search-multi mix in people; skip them.
      final mt = m['media_type'] as String?;
      if (mt != null && CatalogType.fromTmdb(mt) == null) continue;
      if (m['id'] is! num) continue;
      // Rows look broken without artwork (but a search must still find
      // titles TMDB has no poster for).
      if (requirePoster && m['poster_path'] == null) continue;
      out.add(CatalogTitle.fromTmdb(m, type: type));
    }
    return out;
  }

  /// `window` is `day` or `week`.
  static Future<List<CatalogTitle>> trending(
    CatalogType type, {
    String window = 'week',
    int page = 1,
  }) async =>
      _titles(
        await _get('/trending/${type.tmdb}/$window', {'page': page}),
        type: type,
      );

  static Future<List<CatalogTitle>> popular(CatalogType type,
          {int page = 1}) async =>
      _titles(await _get('/${type.tmdb}/popular', {'page': page}), type: type);

  static Future<List<CatalogTitle>> topRated(CatalogType type,
          {int page = 1}) async =>
      _titles(await _get('/${type.tmdb}/top_rated', {'page': page}),
          type: type);

  /// Movies: now playing. Series: airing this week.
  static Future<List<CatalogTitle>> newReleases(CatalogType type,
      {int page = 1}) async {
    final path = type == CatalogType.movie ? '/movie/now_playing' : '/tv/on_the_air';
    return _titles(await _get(path, {'page': page}), type: type);
  }

  static Future<List<CatalogGenre>> genres(CatalogType type) async {
    final data = await _get('/genre/${type.tmdb}/list');
    final list = data?['genres'];
    if (list is! List) return const [];
    return list
        .whereType<Map>()
        .map((g) => CatalogGenre((g['id'] as num).toInt(), g['name'].toString()))
        .toList();
  }

  static Future<List<CatalogTitle>> byGenre(
    CatalogType type,
    int genreId, {
    int page = 1,
    String sortBy = 'popularity.desc',
  }) async =>
      _titles(
        await _get('/discover/${type.tmdb}', {
          'with_genres': genreId,
          'sort_by': sortBy,
          'page': page,
          // Avoids a pile of unreleased/obscure entries with 1 vote.
          'vote_count.gte': 50,
        }),
        type: type,
      );

  /// Movies and series together.
  static Future<List<CatalogTitle>> search(String query, {int page = 1}) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    // NAMESIS PRIME: /search/multi mixes people in and returns only 20
    // rows, which pushed real movies/shows off the page. Ask for movies
    // and shows separately (two pages each) and interleave them.
    final pages = <int>[page * 2 - 1, page * 2];
    final responses = await Future.wait([
      for (final p in pages)
        _get('/search/movie', {'query': q, 'page': p}),
      for (final p in pages)
        _get('/search/tv', {'query': q, 'page': p}),
    ]);
    final movies = <CatalogTitle>[
      ..._titles(responses[0],
          type: CatalogType.movie, requirePoster: false),
      ..._titles(responses[1],
          type: CatalogType.movie, requirePoster: false),
    ];
    final shows = <CatalogTitle>[
      ..._titles(responses[2],
          type: CatalogType.series, requirePoster: false),
      ..._titles(responses[3],
          type: CatalogType.series, requirePoster: false),
    ];
    debugPrint('[TmdbCatalog] search "$q": ${movies.length} movies, '
        '${shows.length} shows'
        '${responses.every((r) => r == null) ? ' (every request failed - '
            'network or Worker problem)' : ''}');
    final out = <CatalogTitle>[];
    final seen = <String>{};
    final n = movies.length > shows.length ? movies.length : shows.length;
    for (var i = 0; i < n; i++) {
      for (final t in <CatalogTitle?>[
        i < movies.length ? movies[i] : null,
        i < shows.length ? shows[i] : null,
      ]) {
        if (t != null && seen.add('${t.type}-${t.tmdbId}')) out.add(t);
      }
    }
    return out;
  }

  // ---------- details ----------

  /// Full details, including the IMDb id (needed to ask addons), cast and
  /// similar titles, in one request.
  static Future<CatalogTitle?> details(CatalogType type, int tmdbId) async {
    final data = await _get('/${type.tmdb}/$tmdbId', {
      'append_to_response': 'external_ids,credits,similar',
    });
    if (data == null || data['id'] is! num) return null;
    return CatalogTitle.fromTmdb(data, type: type);
  }

  static Future<List<CatalogEpisode>> episodes(
    int tvId,
    int seasonNumber,
  ) async {
    final data = await _get('/tv/$tvId/season/$seasonNumber');
    final list = data?['episodes'];
    if (list is! List) return const [];
    return list
        .whereType<Map>()
        .map((e) => CatalogEpisode.fromTmdb(
            Map<String, dynamic>.from(e), seasonNumber))
        .toList();
  }
}

class _Cached {
  final Map<String, dynamic> data;
  final DateTime at;
  _Cached(this.data, this.at);
}

/// Bodies larger than this are decoded in a background isolate (the same
/// threshold Dio's own BackgroundTransformer uses).
const int _isolateDecodeThreshold = 40000;

// Top level so compute() can run it in a background isolate.
Object? _decodeJsonText(String text) => jsonDecode(text);

/// Small on-disk store for TMDB answers (one JSON file per request).
class _TmdbDisk {
  static Future<Directory?>? _dirFuture;
  static int _writes = 0;
  static const int _maxFiles = 1500;

  static Future<Directory?> _directory() => _dirFuture ??= () async {
        try {
          final base = await getApplicationSupportDirectory();
          final d = Directory('${base.path}/tmdb_cache_v1');
          await d.create(recursive: true);
          return d;
        } catch (e) {
          debugPrint('[TmdbCatalog] disk cache unavailable: $e');
          return null;
        }
      }();

  static String _name(String key) {
    var h1 = 0x811c9dc5;
    var h2 = 0x2545F491;
    for (final c in key.codeUnits) {
      h1 = ((h1 ^ c) * 0x01000193) & 0xFFFFFFFF;
      h2 = ((h2 * 31) + c) & 0xFFFFFFFF;
    }
    return '${h1.toRadixString(16).padLeft(8, '0')}'
        '${h2.toRadixString(16).padLeft(8, '0')}.json';
  }

  static Future<({Map<String, dynamic> data, DateTime at})?> read(
      String key) async {
    try {
      final dir = await _directory();
      if (dir == null) return null;
      final file = File('${dir.path}/${_name(key)}');
      if (!await file.exists()) return null;
      final text = await file.readAsString();
      final j = text.length > _isolateDecodeThreshold
          ? await compute(_decodeJsonText, text)
          : _decodeJsonText(text);
      if (j is! Map || j['k'] != key || j['d'] is! Map) return null;
      return (
        data: Map<String, dynamic>.from(j['d'] as Map),
        at: DateTime.fromMillisecondsSinceEpoch((j['t'] as num).toInt()),
      );
    } catch (_) {
      return null;
    }
  }

  /// Writes an already-serialised TMDB body. Same file shape as [write]
  /// produces ({"k","t","d"}), built by string concatenation so the body is
  /// not jsonEncode'd again on the UI thread.
  static Future<void> writeRaw(String key, String rawJson) async {
    try {
      final dir = await _directory();
      if (dir == null) return;
      final file = File('${dir.path}/${_name(key)}');
      await file.writeAsString(
          '{"k":${jsonEncode(key)},"t":${DateTime.now().millisecondsSinceEpoch},"d":$rawJson}');
      if (++_writes % 200 == 0) await _prune(dir);
    } catch (_) {}
  }

  static Future<void> write(String key, Map<String, dynamic> data) async {
    try {
      final dir = await _directory();
      if (dir == null) return;
      final file = File('${dir.path}/${_name(key)}');
      await file.writeAsString(jsonEncode({
        'k': key,
        't': DateTime.now().millisecondsSinceEpoch,
        'd': data,
      }));
      if (++_writes % 200 == 0) await _prune(dir);
    } catch (_) {}
  }

  static Future<void> _prune(Directory dir) async {
    try {
      final files = await dir.list().where((e) => e is File).cast<File>().toList();
      if (files.length <= _maxFiles) return;
      final stats = <MapEntry<File, DateTime>>[];
      for (final f in files) {
        stats.add(MapEntry(f, (await f.stat()).modified));
      }
      stats.sort((a, b) => a.value.compareTo(b.value));
      for (final e in stats.take(files.length - _maxFiles + 300)) {
        try {
          await e.key.delete();
        } catch (_) {}
      }
    } catch (_) {}
  }
}
