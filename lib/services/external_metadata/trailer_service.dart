import 'tmdb_service.dart';

/// A single playable trailer/teaser, resolved from TMDB's `/videos`
/// endpoint down to just what TrailerCard/TrailerSheet need.
class TrailerInfo {
  final String title;
  final String youtubeKey;
  final String type;

  const TrailerInfo({
    required this.title,
    required this.youtubeKey,
    required this.type,
  });

  String get thumbnailUrl =>
      'https://img.youtube.com/vi/$youtubeKey/hqdefault.jpg';

  String get youtubeUrl => 'https://www.youtube.com/watch?v=$youtubeKey';
}

/// Resolves the Movies/TV Shows detail screens' "Trailers" popup.
///
/// Deliberately the only thing this touches is TmdbService — nothing
/// here talks to PlayerManager, CastManager, PlaybackQueue, or
/// MediaService. Trailers are a standalone, isolated feature: no
/// PlaybackSource, no resume position, no next-episode overlay, no
/// cast handoff. That's on purpose, not an oversight — trying to
/// route trailer playback through the same state machine the real
/// player/casting system uses would only add coupling for a feature
/// that never needs any of it.
class TrailerService {
  TrailerService._();

  /// Only actual trailers count — TMDB's /videos endpoint also returns
  /// teasers, behind-the-scenes clips, featurettes, bloopers, etc.,
  /// none of which belong in a "Trailers" button. Teasers are
  /// deliberately excluded even as a fallback — a title with only a
  /// teaser attached shows "No trailers available" rather than one.
  static const _preferredTypes = ['Trailer'];

  /// Resolves the playable trailer list for [item] (a movie or series
  /// detail record). Returns an empty list — never throws — when
  /// there's no TMDB id, no API key configured, or TMDB has nothing
  /// for this title; TrailerSheet treats that as "no trailers
  /// available" rather than an error.
  static Future<List<TrailerInfo>> resolve(Map<String, dynamic> item) async {
    final tmdbId = item['ProviderIds']?['Tmdb']?.toString();
    if (tmdbId == null || tmdbId.isEmpty || !TmdbService.isConfigured) {
      return const [];
    }

    try {
      final type = item['Type'] == 'Series' ? 'tv' : 'movie';
      final videos = await TmdbService.getVideos(type, tmdbId);

      // YouTube only — TMDB occasionally lists trailers hosted on
      // Vimeo, which the YouTube IFrame player obviously can't play.
      final youtubeVideos =
          videos.where((v) => v['site'] == 'YouTube').toList();

      var matches = youtubeVideos
          .where((v) => _preferredTypes.contains(v['type']))
          .toList();

      // Falls back to whatever else TMDB has (Clip, Featurette, ...)
      // rather than showing an empty popup just because a title only
      // has non-Trailer videos attached — but teasers stay excluded
      // even here, per the note above.
      if (matches.isEmpty) {
        matches =
            youtubeVideos.where((v) => v['type'] != 'Teaser').toList();
      }

      // Official trailers first, then TMDB's own list order.
      matches.sort((a, b) {
        final aOfficial = a['official'] == true ? 0 : 1;
        final bOfficial = b['official'] == true ? 0 : 1;
        return aOfficial.compareTo(bOfficial);
      });

      return matches
          .where((v) => v['key'] is String && (v['key'] as String).isNotEmpty)
          .map((v) => TrailerInfo(
                title: (v['name'] as String?)?.trim().isNotEmpty == true
                    ? v['name'] as String
                    : (v['type'] as String? ?? 'Trailer'),
                youtubeKey: v['key'] as String,
                type: (v['type'] as String?) ?? 'Trailer',
              ))
          .toList();
    } catch (_) {
      return const [];
    }
  }
}
