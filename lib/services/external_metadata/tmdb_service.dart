import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../jellyfin_services/storage_service.dart';
import '../proxy_config.dart';

/// Thin client for the TMDB API (api.themoviedb.org) — the "proper"
/// external service behind CastCrewService (cast & crew photos/roles)
/// and StudioService (production-company logos).
///
/// Requests go through the Nemesis Worker (see ProxyConfig), which holds
/// the TMDB key server-side — no key is stored or entered on the device.
/// Every lookup here is keyed off the TMDB id Jellyfin
/// already carries in a title's ProviderIds.Tmdb (populated by
/// Jellyfin's own TheMovieDb metadata plugin, which almost every
/// install already has enabled for movies/series), so no separate
/// title search/matching step is needed — the id is exact.
///
/// With no proxy configured (or the Worker unreachable), every method below returns whatever's
/// already cached (even if stale) and otherwise null/empty —
/// CastCrewService/StudioService both treat that as "fall back to the
/// Jellyfin server's own data", never as an error.
class TmdbService {
  TmdbService._();

  static String get _baseUrl => '${ProxyConfig.baseUrl}/tmdb';
  static const String _imageBaseUrl = 'https://image.tmdb.org/t/p';

  static bool get isConfigured => ProxyConfig.isConfigured;

  static final Dio _dio = Dio(
    BaseOptions(
      baseUrl: _baseUrl,
      headers: ProxyConfig.headers,
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 10),
      // Handled explicitly below (unmatched id, Worker error) — TMDB
      // returns a normal JSON body with a status_message on most
      // failures anyway.
      validateStatus: (_) => true,
    ),
  );

  // Cast/crew credits and production-company info are essentially
  // static for a released title — nowhere near the churn ratings have
  // — so this can sit far longer than RatingsService's 7-day TTL
  // without ever showing stale data in practice.
  static const Duration _ttl = Duration(days: 30);

  static Map<String, dynamic>? _memCache;
  static Future<void>? _loading;

  static Future<void> _ensureLoaded() async {
    if (_memCache != null) return;
    if (_loading != null) return _loading;

    _loading = () async {
      final raw = await StorageService.getTmdbMetadataCache();
      if (raw == null || raw.isEmpty) {
        _memCache = {};
        return;
      }
      try {
        _memCache = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      } catch (_) {
        _memCache = {};
      }
    }();

    await _loading;
  }

  /// Loads the on-disk cache into memory if it isn't already — same
  /// "warm it before anything needs it" idea as RatingsService.
  /// warmCache, called once from AppSettings.load() at startup.
  static Future<void> warmCache() => _ensureLoaded();

  static Future<void> _persist() async {
    final cache = _memCache;
    if (cache == null) return;
    try {
      await StorageService.saveTmdbMetadataCache(jsonEncode(cache));
    } catch (e) {
      debugPrint('[TmdbService] failed to persist cache: $e');
    }
  }

  static bool _isFresh(dynamic entry) {
    if (entry is! Map) return false;
    final ts = entry['ts'] as int? ?? 0;
    return DateTime.now().millisecondsSinceEpoch - ts < _ttl.inMilliseconds;
  }

  static Map<String, dynamic>? _dataOf(dynamic entry) {
    if (entry is! Map) return null;
    final data = entry['data'];
    if (data is! Map) return null;
    return Map<String, dynamic>.from(data);
  }

  /// Shared cached-GET helper — every TMDB endpoint below is a plain
  /// `GET /path`, so this is the one place that actually
  /// touches the network, checks freshness, and persists a hit. The Worker
  /// adds the API key.
  static Future<Map<String, dynamic>?> _cachedGet(
    String cacheKey,
    String path,
  ) async {
    await _ensureLoaded();
    final cache = _memCache!;
    final cached = cache[cacheKey];

    if (_isFresh(cached)) {
      return _dataOf(cached);
    }

    if (!isConfigured) {
      // Proxy URL not set for this build — the only thing left to offer
      // is a stale hit, if one exists.
      return _dataOf(cached);
    }

    try {
      final response = await _dio.get(path);

      if (response.statusCode != 200 || response.data is! Map) {
        debugPrint(
          '[TmdbService] $path -> ${response.statusCode}: ${response.data}',
        );
        return _dataOf(cached);
      }

      final data = Map<String, dynamic>.from(response.data as Map);
      cache[cacheKey] = {
        'data': data,
        'ts': DateTime.now().millisecondsSinceEpoch,
      };
      unawaited(_persist());
      return data;
    } catch (e) {
      debugPrint('[TmdbService] fetch failed for $path: $e');
      return _dataOf(cached);
    }
  }

  /// Full cast + crew for a movie or series. [type] is `"movie"` or
  /// `"tv"`. TV uses `/aggregate_credits`, which rolls a person's
  /// character/job up across every season instead of just whichever
  /// season TMDB happens to consider "current" — the right shape for
  /// a show's overall Cast & Crew section rather than one season's.
  static Future<Map<String, dynamic>?> getCredits(
    String type,
    String tmdbId,
  ) {
    final path = type == 'tv'
        ? '/tv/$tmdbId/aggregate_credits'
        : '/movie/$tmdbId/credits';
    return _cachedGet('credits:$type:$tmdbId', path);
  }

  /// The production companies TMDB has attached to this exact title —
  /// used for studio logos (StudioService). Matching against this
  /// title's own company list (rather than a separate fuzzy
  /// name-search against TMDB's company database) means the logo
  /// StudioService finds is guaranteed to be the same studio Jellyfin
  /// is naming, not a same-named-but-different company.
  static Future<List<Map<String, dynamic>>> getProductionCompanies(
    String type,
    String tmdbId,
  ) async {
    final path = type == 'tv' ? '/tv/$tmdbId' : '/movie/$tmdbId';
    final data = await _cachedGet('details:$type:$tmdbId', path);
    final companies = data?['production_companies'];
    if (companies is! List) return [];
    return companies
        .whereType<Map>()
        .map((c) => Map<String, dynamic>.from(c))
        .toList();
  }

  /// Builds a full image URL from one of TMDB's own relative paths
  /// (a `profile_path` or `logo_path`). `w300` comfortably covers both
  /// the ~105px-wide cast thumbnails and the studio logo row without
  /// paying for TMDB's `original` size.
  static String imageUrl(String path, {String size = 'w300'}) {
    final clean = path.startsWith('/') ? path : '/$path';
    return '$_imageBaseUrl/$size$clean';
  }

  /// Raw `/videos` payload for a movie or series. [type] is `"movie"`
  /// or `"tv"` — same convention as [getCredits]. Callers (TrailerService)
  /// do the Trailer/Teaser filtering; this just fetches and caches the
  /// unfiltered `results` list TMDB returns.
  static Future<List<Map<String, dynamic>>> getVideos(
    String type,
    String tmdbId,
  ) async {
    final path = type == 'tv' ? '/tv/$tmdbId/videos' : '/movie/$tmdbId/videos';
    final data = await _cachedGet('videos:$type:$tmdbId', path);
    final results = data?['results'];
    if (results is! List) return [];
    return results
        .whereType<Map>()
        .map((v) => Map<String, dynamic>.from(v))
        .toList();
  }

  /// Bio, birthday/deathday, and place of birth for a person —
  /// CastCrewDetailScreen's fallback whenever Jellyfin has no Person
  /// entity by that name (a guest actor never credited on anything in
  /// the local library, say). Keyed off the same TMDB person id
  /// CastCrewService already tags cast/crew entries with.
  static Future<Map<String, dynamic>?> getPersonDetails(String personId) {
    return _cachedGet('person:$personId', '/person/$personId');
  }

  /// Every movie/show this person has a cast or crew credit on —
  /// CastCrewDetailScreen's fallback for the Movies/TV Shows rows
  /// whenever Jellyfin's own People data doesn't have this person
  /// credited on anything in the local library at all (see
  /// MediaService.getItemsByPerson). That's the normal case for a
  /// TMDB-sourced cast/crew card (CastCrewService) — it exists in the
  /// first place because Jellyfin's own metadata for the title never
  /// listed this person, so the same gap shows up again here. Keyed
  /// off the same TMDB person id as getPersonDetails. `cast` and
  /// `crew` are combined into one list — CastCrewDetailScreen only
  /// cares about "movies/shows this person appears in", not their
  /// role on each.
  static Future<List<Map<String, dynamic>>> getPersonCredits(
    String personId,
  ) async {
    final data = await _cachedGet(
      'person_credits:$personId',
      '/person/$personId/combined_credits',
    );
    if (data == null) return [];

    final cast = (data['cast'] as List?) ?? const [];
    final crew = (data['crew'] as List?) ?? const [];
    return [...cast, ...crew]
        .whereType<Map>()
        .map((c) => Map<String, dynamic>.from(c))
        .toList();
  }
}
