import 'package:flutter/foundation.dart';

import 'tmdb_service.dart';

/// Resolves the movie/show detail screen's "Cast & Crew" row.
///
/// TMDB (via TmdbService) is the primary, reliable source — real
/// headshot photos and accurate character/job credits for essentially
/// any released movie or series, searched by the exact TMDB id
/// Jellyfin already carries in ProviderIds.Tmdb rather than a fuzzy
/// name search. The Jellyfin server's own People data (whatever its
/// metadata provider populated) is always the fallback: used directly
/// when no TMDB id is available, no API key is configured, or the
/// TMDB lookup fails or comes back empty for any reason — so this
/// section never goes blank just because TMDB is unreachable or
/// unconfigured.
class CastCrewService {
  CastCrewService._();

  // Jellyfin already orders People with actors first — this just
  // narrows down to the roles actually worth showing a face for,
  // mirrored from the movie detail screen's own original filter.
  static const _includedTypes = {
    'Actor',
    'Director',
    'Writer',
    'Producer',
    'Composer',
  };

  // TMDB cast lists for a long-running series can run into the
  // hundreds once every guest actor across every season is counted
  // (aggregate_credits rolls up the whole show) — capped to keep the
  // horizontal row a "cast", not a full credits roll.
  static const _maxCast = 25;

  /// The Jellyfin server's own People, filtered + reshaped into the
  /// same {Id, Name, Role, Type} shape [resolve] returns for a TMDB
  /// hit — shared by the always-available default and the
  /// TMDB-unavailable fallback path so there's exactly one place that
  /// does this filtering.
  static List<Map<String, dynamic>> jellyfinCast(Map<String, dynamic> item) {
    final people = (item['People'] as List?) ?? const [];
    return people
        .whereType<Map>()
        .where((p) => _includedTypes.contains(p['Type']))
        .map((p) => Map<String, dynamic>.from(p))
        .toList();
  }

  /// Maps a TMDB crew credit's `job`/`department` onto the same
  /// Director/Writer/Producer/Composer buckets Jellyfin's own People
  /// data uses, so both sources render through the exact same CastRow
  /// styling/filtering. Returns null for jobs outside those buckets
  /// (TMDB crew lists include dozens of departments — casting,
  /// editing, sound — that were never shown here even from Jellyfin).
  static String? _crewType(String? job) {
    if (job == null) return null;
    final j = job.toLowerCase();
    if (j.contains('director')) return 'Director';
    if (j == 'writer' || j == 'screenplay' || j == 'story' || j == 'novel') {
      return 'Writer';
    }
    if (j == 'producer' || j == 'executive producer') return 'Producer';
    if (j.contains('music')) return 'Composer';
    return null;
  }

  /// Resolves the full cast & crew list for [item] (a movie or series
  /// detail record, as returned by MediaService.getItem). Always
  /// returns *some* list — the Jellyfin fallback — even when TMDB is
  /// unconfigured, unreachable, or has nothing for this title.
  static Future<List<Map<String, dynamic>>> resolve(
    Map<String, dynamic> item,
  ) async {
    final fallback = jellyfinCast(item);

    final tmdbId = item['ProviderIds']?['Tmdb']?.toString();
    if (tmdbId == null || tmdbId.isEmpty || !TmdbService.isConfigured) {
      return fallback;
    }

    try {
      final type = item['Type'] == 'Series' ? 'tv' : 'movie';
      final credits = await TmdbService.getCredits(type, tmdbId);
      if (credits == null) return fallback;

      // Name -> Jellyfin person id, so a TMDB-sourced card can still
      // open CastCrewDetailScreen (which needs a real Jellyfin person
      // id for its own filmography lookup) whenever the same person is
      // also tagged server-side — which, in practice, is almost always
      // the case since Jellyfin's own metadata provider is usually
      // TMDB-backed too.
      final jellyfinIdByName = <String, String>{
        for (final p in fallback)
          if (p['Name'] is String && p['Id'] != null)
            (p['Name'] as String).toLowerCase(): p['Id'].toString(),
      };

      final result = <Map<String, dynamic>>[];

      final castList = (credits['cast'] as List?) ?? const [];
      for (final raw in castList.take(_maxCast)) {
        if (raw is! Map) continue;
        final name = raw['name']?.toString() ?? '';
        if (name.isEmpty) continue;

        // Movie credits carry `character` directly; tv aggregate_credits
        // carries a `roles` array (one entry per distinct character
        // that actor played across the show) — the first is the
        // character most associated with them.
        String? character;
        final roles = raw['roles'];
        if (roles is List && roles.isNotEmpty && roles.first is Map) {
          character = (roles.first as Map)['character']?.toString();
        } else {
          character = raw['character']?.toString();
        }

        final profilePath = raw['profile_path']?.toString();
        result.add({
          'Id': jellyfinIdByName[name.toLowerCase()],
          'TmdbPersonId': raw['id']?.toString(),
          'Name': name,
          'Role': (character == null || character.isEmpty) ? 'Actor' : character,
          'Type': 'Actor',
          'ImageUrl': (profilePath == null || profilePath.isEmpty)
              ? null
              : TmdbService.imageUrl(profilePath),
        });
      }

      final crewList = (credits['crew'] as List?) ?? const [];
      final seenCrew = <String>{};
      for (final raw in crewList) {
        if (raw is! Map) continue;
        final name = raw['name']?.toString() ?? '';
        if (name.isEmpty) continue;

        // Movie crew carries `job` directly; tv aggregate_credits
        // carries a `jobs` array (every job that person held across
        // the show) — the first is enough to classify them.
        String? job;
        final jobs = raw['jobs'];
        if (jobs is List && jobs.isNotEmpty && jobs.first is Map) {
          job = (jobs.first as Map)['job']?.toString();
        } else {
          job = raw['job']?.toString();
        }

        final mappedType = _crewType(job);
        if (mappedType == null) continue;

        // The same person often shows up under multiple jobs (writer
        // + director, say) — keep just the first/most senior credit
        // rather than duplicating their card.
        if (!seenCrew.add('$name|$mappedType')) continue;

        final profilePath = raw['profile_path']?.toString();
        result.add({
          'Id': jellyfinIdByName[name.toLowerCase()],
          'TmdbPersonId': raw['id']?.toString(),
          'Name': name,
          'Role': mappedType,
          'Type': mappedType,
          'ImageUrl': (profilePath == null || profilePath.isEmpty)
              ? null
              : TmdbService.imageUrl(profilePath),
        });
      }

      return result.isEmpty ? fallback : result;
    } catch (e) {
      debugPrint('[CastCrewService] TMDB resolve failed: $e');
      return fallback;
    }
  }
}
