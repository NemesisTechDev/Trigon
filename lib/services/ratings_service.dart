import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'jellyfin_services/storage_service.dart';
import 'proxy_config.dart';

/// Resolved rating triple for a single title. Any field can be null on
/// its own (a title can have an IMDb score with no Rotten Tomatoes
/// entry at all, or a critic score but no audience score yet) —
/// [isEmpty] is only true when none of the three are available.
///
/// All three fields are always resolved from the *same* provider
/// response for a given title (see RatingsService) rather than being
/// mixed from independent sources — earlier versions of this app used
/// Jellyfin's own item["CriticRating"] as a zero-network fallback for
/// Rotten Tomatoes specifically, which meant RT could show up
/// instantly while IMDb (which only ever came from a network lookup)
/// was still resolving or missing an API key — an asymmetric,
/// confusing result. Sourcing every field from one response means
/// they always appear together, or not at all.
class RatingsResult {
  final double? imdbRating; // 0.0 – 10.0
  final int? rtCriticScore; // 0 – 100 (Tomatometer)
  final int? rtAudienceScore; // 0 – 100 (Popcornmeter)

  const RatingsResult({
    this.imdbRating,
    this.rtCriticScore,
    this.rtAudienceScore,
  });

  bool get isEmpty =>
      imdbRating == null && rtCriticScore == null && rtAudienceScore == null;
}

/// Resolves IMDb + Rotten Tomatoes (critic and audience) ratings for a
/// title, keyed off the IMDb id Jellyfin already carries in
/// ProviderIds.Imdb for every movie/series/episode.
///
/// Two providers are used, both reached through the Nemesis Worker (see
/// ProxyConfig) — the API keys live on the Worker, never on the device:
///
///  - MDBList (mdblist.com) — tried first. A single request returns IMDb,
///    Rotten Tomatoes critic *and* audience scores together, and its
///    Rotten Tomatoes coverage for TV series is far more complete than
///    OMDb's (OMDb's own API only ever returns Rotten Tomatoes data for
///    movies, never for TV series — a known limitation of OMDb itself).
///  - OMDb (omdbapi.com) — fallback when MDBList fails or has no data for
///    a title, and the only source for per-episode ratings. Gives IMDb +
///    Rotten Tomatoes critic; has no audience score field at all.
///
/// A lookup only reaches OMDb when MDBList came back empty or errored —
/// all three fields for a title always come from the same provider's
/// response, never mixed.
///
/// If the proxy isn't configured for this build (or the Worker is
/// unreachable), [fetch] falls back to whatever's already cached (even if
/// stale) and otherwise returns null — callers should treat that as
/// "hide the rating", not as an error.
class RatingsService {
  RatingsService._();

  // Both providers are reached through the Nemesis Worker (see
  // ProxyConfig) — it holds the MDBList/OMDb keys, so none are stored
  // or entered on the device.
  static final Dio _proxyDio = Dio(
    BaseOptions(
      baseUrl: ProxyConfig.baseUrl,
      headers: ProxyConfig.headers,
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 10),
      // Handle non-200s ourselves (the Worker passes the provider's
      // status through, and returns 503 if a provider isn't configured).
      validateStatus: (_) => true,
    ),
  );

  // Ratings drift slowly enough that a week-old cached value is still
  // perfectly reasonable, and this is what keeps day-to-day scrolling
  // well under either provider's free-tier quota.
  static const Duration _ttl = Duration(days: 7);

  static Map<String, dynamic>? _memCache;
  static Future<void>? _loading;

  static Future<void> _ensureLoaded() async {
    if (_memCache != null) return;
    if (_loading != null) return _loading;

    _loading = () async {
      final raw = await StorageService.getRatingsCache();
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

  /// Loads the on-disk cache into memory if it isn't already, so
  /// [peek] can answer synchronously as soon as possible. Called once
  /// from AppSettings.load() at startup — safe to call again from
  /// anywhere else too, it's a no-op once loaded.
  static Future<void> warmCache() => _ensureLoaded();

  static Future<void> _persist() async {
    final cache = _memCache;
    if (cache == null) return;
    try {
      await StorageService.saveRatingsCache(jsonEncode(cache));
    } catch (e) {
      debugPrint('[RatingsService] failed to persist cache: $e');
    }
  }

  static num? _num(dynamic value) {
    if (value is num) return value;
    if (value is String) return num.tryParse(value);
    return null;
  }

  /// Reads a cache entry written by either the current schema (imdb /
  /// rtc / rta) or the older, RT-critic-only schema (imdb / rt) a
  /// handful of installs may still have on disk — read as rtc so
  /// nothing already cached gets silently dropped on upgrade.
  static RatingsResult? _fromCacheEntry(dynamic entry) {
    if (entry is! Map) return null;
    final imdb = (entry['imdb'] as num?)?.toDouble();
    final rtc = (entry['rtc'] as num?)?.toInt() ?? (entry['rt'] as num?)?.toInt();
    final rta = (entry['rta'] as num?)?.toInt();
    if (imdb == null && rtc == null && rta == null) return null;
    return RatingsResult(imdbRating: imdb, rtCriticScore: rtc, rtAudienceScore: rta);
  }

  static bool _isFresh(dynamic entry) {
    if (entry is! Map) return false;
    final ts = entry['ts'] as int? ?? 0;
    final age = DateTime.now().millisecondsSinceEpoch - ts;
    return age < _ttl.inMilliseconds;
  }

  /// Synchronous, no-network read of whatever's already cached for
  /// [imdbId] — returns null if nothing's cached yet, the cache hasn't
  /// finished loading from disk, or the entry is past [_ttl]. Callers
  /// (RatingsRow) use this to paint a rating on the very first frame
  /// when it's available, instead of always starting blank and popping
  /// the value in a moment later.
  static RatingsResult? peek(String? imdbId) {
    if (imdbId == null || imdbId.isEmpty) return null;
    final cache = _memCache;
    if (cache == null) return null;
    final entry = cache[imdbId];
    if (!_isFresh(entry)) return null;
    return _fromCacheEntry(entry);
  }

  static String? _imdbIdOf(dynamic item) {
    if (item is! Map) return null;
    final providerIds = item["ProviderIds"];
    if (providerIds is! Map) return null;
    final id = providerIds["Imdb"] ?? providerIds["IMDB"] ?? providerIds["imdb"];
    final str = id?.toString();
    return (str == null || str.isEmpty) ? null : str;
  }

  /// Cache/lookup key for a specific episode, distinct from the plain
  /// IMDb-id keys [fetch] uses — composite so it can never collide
  /// with a real "tt..." id.
  static String _episodeKey(String seriesImdbId, int season, int episode) =>
      "$seriesImdbId:S${season}E$episode";

  /// Kicks off ratings lookups for every item in [items] that carries
  /// an IMDb id, so that by the time a list/carousel/episode row
  /// actually builds and each RatingsRow calls [peek], the value is
  /// typically already sitting in cache — the same "warm the cache
  /// ahead of the UI that needs it" idea HomeScreen already uses for
  /// hero backdrop images (see _precacheHeroBackdrops).
  ///
  /// Fire-and-forget from the caller's side; runs a handful of lookups
  /// at a time rather than all at once so a long list (a full season
  /// of episodes, say) doesn't fire 20+ simultaneous requests.
  static Future<void> prefetchAll(Iterable<dynamic> items) async {
    final ids = <String>{};
    for (final item in items) {
      final id = _imdbIdOf(item);
      if (id != null) ids.add(id);
    }
    if (ids.isEmpty) return;

    await _ensureLoaded();

    const batchSize = 5;
    final list = ids.toList();
    for (var i = 0; i < list.length; i += batchSize) {
      final batch = list.skip(i).take(batchSize);
      await Future.wait(
        batch.map((id) => fetch(id).catchError((_) => null)),
      );
    }
  }

  /// Returns ratings for [imdbId] (Jellyfin's ProviderIds.Imdb, e.g.
  /// "tt1234567"), or null if there's nothing to show — no id, no
  /// provider configured and no cached value, or neither provider has
  /// data for this title.
  static Future<RatingsResult?> fetch(String? imdbId) async {
    if (imdbId == null || imdbId.isEmpty) return null;

    await _ensureLoaded();
    final cache = _memCache!;

    final cachedEntry = cache[imdbId];
    if (_isFresh(cachedEntry)) {
      return _fromCacheEntry(cachedEntry);
    }

    if (!ProxyConfig.isConfigured) {
      // Proxy URL not set for this build — still surface a stale cached
      // value rather than nothing.
      return _fromCacheEntry(cachedEntry);
    }

    // MDBList first; _fetchFromMdblist falls through to OMDb on any
    // failure or "no data" answer.
    return _fetchFromMdblist(imdbId, cachedEntry);
  }

  static Future<RatingsResult?> _fetchFromMdblist(
    String imdbId,
    dynamic cachedEntry,
  ) async {
    try {
      final response = await _proxyDio.get(
        '/mdblist',
        queryParameters: {'i': imdbId},
      );

      if (response.statusCode != 200) {
        debugPrint('[RatingsService] MDBList ${response.statusCode}');
        return _fetchFromOmdb(imdbId, cachedEntry);
      }

      final body = response.data;
      if (body is! Map || body['response'] == false || body['error'] != null) {
        return _fetchFromOmdb(imdbId, cachedEntry);
      }

      double? imdbRating;
      int? rtCritic;
      int? rtAudience;

      final ratings = body['ratings'];
      if (ratings is List) {
        for (final entry in ratings) {
          if (entry is! Map) continue;
          final source = entry['source']?.toString();
          // "score" is the 0-100 normalized figure MDBList computes
          // for every source (including IMDb, where it's just the
          // 0-10 "value" ×10); "value" is that source's native scale.
          // Prefer the one that's actually on the 0-100/0-10 scale
          // this app wants for each field rather than assuming both
          // are always populated the same way.
          switch (source) {
            case 'imdb':
              imdbRating = _num(entry['value'])?.toDouble() ??
                  ((_num(entry['score'])?.toDouble() ?? 0) / 10);
              break;
            case 'tomatoes':
              rtCritic = (_num(entry['score']) ?? _num(entry['value']))?.round();
              break;
            case 'tomatoesaudience':
              rtAudience = (_num(entry['score']) ?? _num(entry['value']))?.round();
              break;
          }
        }
      }

      if (imdbRating == null && rtCritic == null && rtAudience == null) {
        // A clean "nothing to show" response is still worth caching —
        // otherwise a title MDBList genuinely has no ratings for would
        // get re-requested on every single fetch instead of respecting
        // the TTL like everything else.
        _memCache![imdbId] = {
          'imdb': null,
          'rtc': null,
          'rta': null,
          'ts': DateTime.now().millisecondsSinceEpoch,
        };
        unawaited(_persist());
        return null;
      }

      _memCache![imdbId] = {
        'imdb': imdbRating,
        'rtc': rtCritic,
        'rta': rtAudience,
        'ts': DateTime.now().millisecondsSinceEpoch,
      };
      unawaited(_persist());

      return RatingsResult(
        imdbRating: imdbRating,
        rtCriticScore: rtCritic,
        rtAudienceScore: rtAudience,
      );
    } catch (e) {
      debugPrint('[RatingsService] MDBList fetch failed for $imdbId: $e');
      return _fetchFromOmdb(imdbId, cachedEntry);
    }
  }

  static Future<RatingsResult?> _fetchFromOmdb(
    String imdbId,
    dynamic cachedEntry,
  ) async {
    try {
      final response = await _proxyDio.get(
        '/omdb',
        queryParameters: {'i': imdbId},
      );

      if (response.statusCode != 200) {
        debugPrint('[RatingsService] OMDb ${response.statusCode}');
        return _fromCacheEntry(cachedEntry);
      }

      final body = response.data;
      if (body is! Map || body['Response'] == 'False') {
        return _fromCacheEntry(cachedEntry);
      }

      double? imdbRating;
      final imdbRatingStr = body['imdbRating']?.toString();
      if (imdbRatingStr != null && imdbRatingStr != 'N/A') {
        imdbRating = double.tryParse(imdbRatingStr);
      }

      // OMDb has no audience-score field at all — only ever critic
      // (Tomatometer), and (see the class doc) only for movies, never
      // TV series, regardless of what's requested here.
      int? rtCritic;
      final ratings = body['Ratings'];
      if (ratings is List) {
        for (final entry in ratings) {
          if (entry is Map && entry['Source'] == 'Rotten Tomatoes') {
            final value = entry['Value']?.toString() ?? '';
            rtCritic = int.tryParse(value.replaceAll('%', '').trim());
            break;
          }
        }
      }

      if (imdbRating == null && rtCritic == null) {
        return null;
      }

      _memCache![imdbId] = {
        'imdb': imdbRating,
        'rtc': rtCritic,
        'rta': null,
        'ts': DateTime.now().millisecondsSinceEpoch,
      };
      unawaited(_persist());

      return RatingsResult(imdbRating: imdbRating, rtCriticScore: rtCritic);
    } catch (e) {
      debugPrint('[RatingsService] OMDb fetch failed for $imdbId: $e');
      return _fromCacheEntry(cachedEntry);
    }
  }

  /// Synchronous, no-network read of whatever's already cached for a
  /// specific episode — same idea as [peek], keyed by the series'
  /// IMDb id + season + episode number rather than the episode's own
  /// id, since (per [fetchEpisode]'s doc) individual episodes usually
  /// aren't tagged with one of their own.
  static RatingsResult? peekEpisode(
    String? seriesImdbId,
    int? season,
    int? episode,
  ) {
    if (seriesImdbId == null ||
        seriesImdbId.isEmpty ||
        season == null ||
        episode == null) {
      return null;
    }
    final cache = _memCache;
    if (cache == null) return null;
    final entry = cache[_episodeKey(seriesImdbId, season, episode)];
    if (!_isFresh(entry)) return null;
    return _fromCacheEntry(entry);
  }

  /// Resolves a rating for one specific episode.
  ///
  /// Deliberately doesn't look at the episode item's own ProviderIds:
  /// most Jellyfin metadata providers only ever tag the *series* with
  /// an IMDb id, not each individual episode, so keying off the
  /// episode's own id (as an earlier version of this did) came back
  /// empty for most libraries. Instead this uses OMDb's documented
  /// Season/Episode lookup — passing a series' IMDb id together with
  /// `Season=`/`Episode=` query parameters returns that specific
  /// episode's own IMDb id and rating, without ever needing Jellyfin
  /// to have tagged the episode itself. This is an OMDb-specific
  /// feature with no MDBList equivalent that's been found, so episode
  /// ratings need an OMDb key configured even when MDBList is set and
  /// handling every other rating in the app.
  static Future<RatingsResult?> fetchEpisode(
    String? seriesImdbId,
    int? season,
    int? episode,
  ) async {
    if (seriesImdbId == null ||
        seriesImdbId.isEmpty ||
        season == null ||
        episode == null) {
      return null;
    }

    await _ensureLoaded();
    final cache = _memCache!;
    final key = _episodeKey(seriesImdbId, season, episode);

    final cachedEntry = cache[key];
    if (_isFresh(cachedEntry)) {
      return _fromCacheEntry(cachedEntry);
    }

    if (!ProxyConfig.isConfigured) {
      return _fromCacheEntry(cachedEntry);
    }

    try {
      final response = await _proxyDio.get(
        '/omdb',
        queryParameters: {
          'i': seriesImdbId,
          'Season': season,
          'Episode': episode,
        },
      );

      if (response.statusCode != 200) {
        debugPrint(
          '[RatingsService] OMDb episode lookup ${response.statusCode}',
        );
        return _fromCacheEntry(cachedEntry);
      }

      final body = response.data;
      if (body is! Map || body['Response'] == 'False') {
        return _fromCacheEntry(cachedEntry);
      }

      double? imdbRating;
      final imdbRatingStr = body['imdbRating']?.toString();
      if (imdbRatingStr != null && imdbRatingStr != 'N/A') {
        imdbRating = double.tryParse(imdbRatingStr);
      }

      // Individual episodes are essentially never Tomatometer-scored,
      // but check anyway on the off chance OMDb's Ratings array has
      // one for this particular episode — same field this app already
      // reads for movies/series.
      int? rtCritic;
      final ratings = body['Ratings'];
      if (ratings is List) {
        for (final entry in ratings) {
          if (entry is Map && entry['Source'] == 'Rotten Tomatoes') {
            final value = entry['Value']?.toString() ?? '';
            rtCritic = int.tryParse(value.replaceAll('%', '').trim());
            break;
          }
        }
      }

      if (imdbRating == null && rtCritic == null) {
        // Cache the empty result too, same reasoning as the MDBList
        // path above — an episode OMDb has nothing for shouldn't be
        // re-requested every time it's scrolled past.
        cache[key] = {
          'imdb': null,
          'rtc': null,
          'rta': null,
          'ts': DateTime.now().millisecondsSinceEpoch,
        };
        unawaited(_persist());
        return null;
      }

      cache[key] = {
        'imdb': imdbRating,
        'rtc': rtCritic,
        'rta': null,
        'ts': DateTime.now().millisecondsSinceEpoch,
      };
      unawaited(_persist());

      return RatingsResult(imdbRating: imdbRating, rtCriticScore: rtCritic);
    } catch (e) {
      debugPrint(
        '[RatingsService] OMDb episode lookup failed for '
        '$seriesImdbId S${season}E$episode: $e',
      );
      return _fromCacheEntry(cachedEntry);
    }
  }

  /// Same "warm the cache before the row builds" idea as [prefetchAll],
  /// for a season's worth of episodes at once. [seriesImdbId] is the
  /// *series'* IMDb id (already on the series item Jellyfin loaded for
  /// the details screen) — each episode's own IndexNumber/
  /// ParentIndexNumber supplies the season/episode numbers.
  static Future<void> prefetchEpisodes(
    String? seriesImdbId,
    Iterable<dynamic> episodes,
  ) async {
    if (seriesImdbId == null || seriesImdbId.isEmpty) return;

    await _ensureLoaded();

    const batchSize = 5;
    final list = episodes.toList();
    for (var i = 0; i < list.length; i += batchSize) {
      final batch = list.skip(i).take(batchSize);
      await Future.wait(batch.map((ep) {
        if (ep is! Map) return Future.value();
        final season = (ep["ParentIndexNumber"] as num?)?.toInt();
        final episode = (ep["IndexNumber"] as num?)?.toInt();
        if (season == null || episode == null) return Future.value();
        return fetchEpisode(seriesImdbId, season, episode)
            .catchError((_) => null);
      }));
    }
  }
}
