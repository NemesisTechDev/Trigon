import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../services/proxy_config.dart';
import 'tmdb_catalog_service.dart';

/// Fallback source for title logos (the transparent title artwork shown on
/// the details screens) for when TMDB has none: Fanart.tv.
///
/// Fanart.tv is a free, community-run artwork database. It needs an API key
/// (free: https://fanart.tv/get-an-api-key), configured like the TMDB key:
///
///  1. **Direct** — build with `--dart-define=FANART_API_KEY=<your key>`.
///  2. **Proxy** — leave it empty and requests go to `<proxy>/fanart/...`
///     (the Cloudflare Worker must forward `/fanart/*` to
///     `https://webservice.fanart.tv/v3/*` and add the key itself).
///
/// With neither, [logoFor] does nothing and returns "no logo", so the app
/// behaves exactly as before.
///
/// Movies are looked up by TMDB id; series by TVDB id (read from TMDB's
/// `external_ids`).
class FanartLogoService {
  FanartLogoService._();

  static const String _apiKey = String.fromEnvironment('FANART_API_KEY');
  static const String _directBase = 'https://webservice.fanart.tv/v3';

  static bool get _direct => _apiKey.isNotEmpty;
  static bool get isConfigured => _direct || ProxyConfig.isConfigured;

  static String get _base =>
      _direct ? _directBase : '${ProxyConfig.baseUrl}/fanart';

  static final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 12),
      validateStatus: (_) => true,
    ),
  );

  /// The best Fanart.tv logo URL for the title, or null. [failed] is true
  /// when the lookup could not be completed (network / server trouble), so
  /// the caller retries soon instead of remembering "no logo exists".
  static Future<({String? url, bool failed})> logoFor({
    required bool isMovie,
    required int tmdbId,
  }) async {
    if (!isConfigured) return (url: null, failed: false);
    try {
      final String lookupId;
      if (isMovie) {
        lookupId = '$tmdbId';
      } else {
        final ext = await TmdbCatalogService.raw('/tv/$tmdbId/external_ids');
        if (ext == null) return (url: null, failed: true);
        final tvdb = ext['tvdb_id'];
        if (tvdb is! num || tvdb <= 0) return (url: null, failed: false);
        lookupId = '${tvdb.toInt()}';
      }

      final resp = await _dio.get(
        '$_base/${isMovie ? 'movies' : 'tv'}/$lookupId',
        queryParameters: {if (_direct) 'api_key': _apiKey},
        options: Options(headers: _direct ? null : ProxyConfig.headers),
      );
      // 404 = Fanart.tv has nothing for this title.
      if (resp.statusCode == 404) return (url: null, failed: false);
      // 503 = the Worker has no FANART_API_KEY set: nothing to retry.
      if (resp.statusCode == 503) return (url: null, failed: false);
      if (resp.statusCode != 200 || resp.data is! Map) {
        return (url: null, failed: true);
      }
      final data = resp.data as Map;
      final url = isMovie
          ? _best(data['hdmovielogo']) ?? _best(data['movielogo'])
          : _best(data['hdtvlogo']) ?? _best(data['clearlogo']);
      return (url: url, failed: false);
    } catch (e) {
      debugPrint('[FanartLogo] lookup failed: $e');
      return (url: null, failed: true);
    }
  }

  /// English first, then language-less, then any other; most-liked first.
  static String? _best(dynamic list) {
    if (list is! List) return null;
    int rank(String? lang) {
      final l = (lang ?? '').toLowerCase();
      if (l == 'en') return 0;
      if (l.isEmpty || l == '00') return 1;
      return 2;
    }

    Map? best;
    var bestRank = 3;
    var bestLikes = -1;
    for (final e in list.whereType<Map>()) {
      final url = e['url'];
      if (url is! String || !url.startsWith('http')) continue;
      final lower = url.toLowerCase();
      if (lower.endsWith('.svg')) continue;
      final r = rank(e['lang']?.toString());
      final likes = int.tryParse('${e['likes']}') ?? 0;
      if (best == null || r < bestRank || (r == bestRank && likes > bestLikes)) {
        best = e;
        bestRank = r;
        bestLikes = likes;
      }
    }
    return best?['url'] as String?;
  }
}
