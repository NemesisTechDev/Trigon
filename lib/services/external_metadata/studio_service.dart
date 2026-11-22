import 'package:flutter/foundation.dart';

import '../jellyfin_services/media_service.dart';
import 'tmdb_service.dart';

/// Resolves logo artwork for the movie/show detail screen's "Studio"
/// row.
///
/// The studio *list itself* (names + Jellyfin item ids) always comes
/// straight from the server — item["Studios"], already populated by
/// whatever metadata provider Jellyfin is using — this only resolves
/// the artwork for each one:
///
///  1. TMDB's production-company logo for this exact title (matched
///     by name against item["Studios"], see [resolve]) — reliable,
///     official logos for essentially any studio TMDB has an entry
///     for.
///  2. The Jellyfin server's own `/Items/{studioId}/Images/Logo` —
///     used whenever a studio isn't in TMDB's result (or TMDB is
///     unconfigured/unreachable). This is a speculative URL — it's
///     not verified with a network call up front; StudioRow's
///     CachedNetworkImage naturally shows its errorWidget (the studio
///     name as text, matching the reference client's link-style
///     Studio row) if the server has no such image, so there's no
///     third network round trip needed just to check.
class StudioService {
  StudioService._();

  /// Returns one entry per studio in item["Studios"], each with a
  /// best-effort `LogoUrl` (nullable) attached. Never throws — a TMDB
  /// failure just means every entry falls back to the Jellyfin-image
  /// guess instead.
  static Future<List<Map<String, dynamic>>> resolve(
    Map<String, dynamic> item,
  ) async {
    final studios = ((item['Studios'] as List?) ?? const [])
        .whereType<Map>()
        .map((s) => Map<String, dynamic>.from(s))
        .where((s) => (s['Name']?.toString() ?? '').isNotEmpty)
        .toList();

    if (studios.isEmpty) return [];

    Map<String, String> tmdbLogoByName = const {};

    final tmdbId = item['ProviderIds']?['Tmdb']?.toString();
    if (tmdbId != null && tmdbId.isNotEmpty && TmdbService.isConfigured) {
      try {
        final type = item['Type'] == 'Series' ? 'tv' : 'movie';
        final companies = await TmdbService.getProductionCompanies(
          type,
          tmdbId,
        );
        tmdbLogoByName = {
          for (final c in companies)
            if (c['name'] is String && c['logo_path'] is String)
              (c['name'] as String).toLowerCase():
                  TmdbService.imageUrl(c['logo_path'] as String),
        };
      } catch (e) {
        debugPrint('[StudioService] TMDB company lookup failed: $e');
      }
    }

    return studios.map((studio) {
      final name = studio['Name'].toString();
      final id = studio['Id']?.toString();

      final logoUrl = tmdbLogoByName[name.toLowerCase()] ??
          (id == null
              ? null
              : MediaService.getImageUrl(id, type: 'Logo', maxWidth: 400));

      return {'Name': name, 'Id': id, 'LogoUrl': logoUrl};
    }).toList();
  }

  /// Zero-network default shown the instant a title loads — just the
  /// server's own studio names/ids, no logo yet. [resolve] upgrades
  /// this in the background once TMDB (or the Jellyfin image guess)
  /// has had a chance to resolve.
  static List<Map<String, dynamic>> jellyfinFallback(
    Map<String, dynamic> item,
  ) {
    return ((item['Studios'] as List?) ?? const [])
        .whereType<Map>()
        .map((s) => {
              'Name': s['Name']?.toString() ?? '',
              'Id': s['Id']?.toString(),
              'LogoUrl': null,
            })
        .where((s) => (s['Name'] as String).isNotEmpty)
        .toList();
  }
}
