/// Catalog types, mapped from TMDB's JSON. "series" is TMDB's "tv".
library;

enum CatalogType {
  movie,
  series;

  /// TMDB's path segment: `movie` or `tv`.
  String get tmdb => this == CatalogType.movie ? 'movie' : 'tv';

  /// The addon protocol's type name: `movie` or `series`.
  String get addon => name;

  static CatalogType? fromTmdb(String? v) {
    switch (v) {
      case 'movie':
        return CatalogType.movie;
      case 'tv':
        return CatalogType.series;
    }
    return null;
  }
}

/// Image URL builders for TMDB's CDN.
class TmdbImages {
  TmdbImages._();
  static const String _base = 'https://image.tmdb.org/t/p';

  static String? poster(String? path, {String size = 'w342'}) =>
      _build(path, size);
  static String? backdrop(String? path, {String size = 'w780'}) =>
      _build(path, size);
  static String? still(String? path, {String size = 'w300'}) =>
      _build(path, size);
  static String? profile(String? path, {String size = 'w185'}) =>
      _build(path, size);

  static String? _build(String? path, String size) {
    if (path == null || path.isEmpty) return null;
    return '$_base/$size${path.startsWith('/') ? path : '/$path'}';
  }
}

class CatalogGenre {
  final int id;
  final String name;
  const CatalogGenre(this.id, this.name);
}

class CatalogCast {
  final String name;
  final String character;
  final String? profilePath;
  const CatalogCast(this.name, this.character, this.profilePath);
}

class CatalogSeason {
  final int number;
  final String name;
  final int episodeCount;
  final String? posterPath;
  const CatalogSeason({
    required this.number,
    required this.name,
    required this.episodeCount,
    this.posterPath,
  });
}

class CatalogEpisode {
  final int season;
  final int number;
  final String name;
  final String overview;
  final String? stillPath;
  final int? runtime;
  final String? airDate;
  const CatalogEpisode({
    required this.season,
    required this.number,
    required this.name,
    required this.overview,
    this.stillPath,
    this.runtime,
    this.airDate,
  });

  factory CatalogEpisode.fromTmdb(Map<String, dynamic> j, int fallbackSeason) =>
      CatalogEpisode(
        season: (j['season_number'] as num?)?.toInt() ?? fallbackSeason,
        number: (j['episode_number'] as num?)?.toInt() ?? 0,
        name: (j['name'] ?? 'Episode ${j['episode_number']}').toString(),
        overview: (j['overview'] ?? '').toString(),
        stillPath: j['still_path'] as String?,
        runtime: (j['runtime'] as num?)?.toInt(),
        airDate: j['air_date'] as String?,
      );
}

class CatalogTitle {
  final int tmdbId;
  final CatalogType type;
  final String title;
  final String overview;
  final String? posterPath;
  final String? backdropPath;
  final String? releaseDate;
  final double rating;
  final List<int> genreIds;

  /// TMDB's `original_language` (e.g. `ja`). Present on list and details
  /// calls, but not kept in saved snapshots (history, watchlist, downloads).
  final String? originalLanguage;

  // Only filled in by a details call:
  final List<String> genres;
  final int? runtime;
  final String tagline;
  final String? imdbId;
  final String? status;
  final List<CatalogSeason> seasons;
  final List<CatalogCast> cast;
  final List<CatalogTitle> similar;

  const CatalogTitle({
    required this.tmdbId,
    required this.type,
    required this.title,
    required this.overview,
    this.posterPath,
    this.backdropPath,
    this.releaseDate,
    this.rating = 0,
    this.genreIds = const [],
    this.originalLanguage,
    this.genres = const [],
    this.runtime,
    this.tagline = '',
    this.imdbId,
    this.status,
    this.seasons = const [],
    this.cast = const [],
    this.similar = const [],
  });

  int? get year {
    final d = releaseDate;
    if (d == null || d.length < 4) return null;
    return int.tryParse(d.substring(0, 4));
  }

  String? get posterUrl => TmdbImages.poster(posterPath);
  String? get backdropUrl => TmdbImages.backdrop(backdropPath);

  /// The id an addon is asked about. IMDb ids are what the Stremio ecosystem
  /// keys on, so prefer that; fall back to `tmdb:{id}`, which addons you
  /// write yourself can also understand.
  ///
  /// For series, pass [season] and [episode] to get `ttXXXX:S:E`.
  String addonId({int? season, int? episode}) {
    final base = (imdbId != null && imdbId!.isNotEmpty) ? imdbId! : 'tmdb:$tmdbId';
    if (type == CatalogType.series && season != null && episode != null) {
      return '$base:$season:$episode';
    }
    return base;
  }

  static String? _language(dynamic v) {
    final s = v?.toString().trim().toLowerCase();
    return (s == null || s.isEmpty) ? null : s;
  }

  /// Parses both list results (search/trending/discover) and full details.
  factory CatalogTitle.fromTmdb(Map<String, dynamic> j, {CatalogType? type}) {
    final resolved =
        type ?? CatalogType.fromTmdb(j['media_type'] as String?) ??
            (j.containsKey('first_air_date') || j.containsKey('name')
                ? CatalogType.series
                : CatalogType.movie);

    final isMovie = resolved == CatalogType.movie;

    List<String> genreNames = const [];
    final g = j['genres'];
    if (g is List) {
      genreNames = g
          .whereType<Map>()
          .map((e) => e['name']?.toString() ?? '')
          .where((s) => s.isNotEmpty)
          .toList();
    }

    List<int> ids = const [];
    final gi = j['genre_ids'];
    if (gi is List) {
      ids = gi.whereType<num>().map((e) => e.toInt()).toList();
    } else if (g is List) {
      ids = g
          .whereType<Map>()
          .map((e) => (e['id'] as num?)?.toInt())
          .whereType<int>()
          .toList();
    }

    // IMDb id lives in different places depending on endpoint.
    String? imdb = j['imdb_id'] as String?;
    final ext = j['external_ids'];
    if ((imdb == null || imdb.isEmpty) && ext is Map) {
      imdb = ext['imdb_id'] as String?;
    }
    if (imdb != null && imdb.isEmpty) imdb = null;

    final seasons = <CatalogSeason>[];
    final rawSeasons = j['seasons'];
    if (rawSeasons is List) {
      for (final s in rawSeasons.whereType<Map>()) {
        final n = (s['season_number'] as num?)?.toInt() ?? 0;
        seasons.add(CatalogSeason(
          number: n,
          name: (s['name'] ?? 'Season $n').toString(),
          episodeCount: (s['episode_count'] as num?)?.toInt() ?? 0,
          posterPath: s['poster_path'] as String?,
        ));
      }
    }

    final cast = <CatalogCast>[];
    final credits = j['credits'];
    if (credits is Map && credits['cast'] is List) {
      for (final c in (credits['cast'] as List).whereType<Map>().take(20)) {
        cast.add(CatalogCast(
          (c['name'] ?? '').toString(),
          (c['character'] ?? '').toString(),
          c['profile_path'] as String?,
        ));
      }
    }

    final similar = <CatalogTitle>[];
    final sim = j['similar'];
    if (sim is Map && sim['results'] is List) {
      for (final r in (sim['results'] as List).whereType<Map>().take(20)) {
        similar.add(CatalogTitle.fromTmdb(
          Map<String, dynamic>.from(r),
          type: resolved,
        ));
      }
    }

    int? runtime = (j['runtime'] as num?)?.toInt();
    if (runtime == null && j['episode_run_time'] is List) {
      final l = (j['episode_run_time'] as List).whereType<num>().toList();
      if (l.isNotEmpty) runtime = l.first.toInt();
    }

    return CatalogTitle(
      tmdbId: (j['id'] as num).toInt(),
      type: resolved,
      title: (j[isMovie ? 'title' : 'name'] ?? j['title'] ?? j['name'] ?? '')
          .toString(),
      overview: (j['overview'] ?? '').toString(),
      posterPath: j['poster_path'] as String?,
      backdropPath: j['backdrop_path'] as String?,
      releaseDate:
          (isMovie ? j['release_date'] : j['first_air_date']) as String?,
      rating: (j['vote_average'] as num?)?.toDouble() ?? 0,
      genreIds: ids,
      originalLanguage: _language(j['original_language']),
      genres: genreNames,
      runtime: runtime,
      tagline: (j['tagline'] ?? '').toString(),
      imdbId: imdb,
      status: j['status'] as String?,
      seasons: seasons,
      cast: cast,
      similar: similar,
    );
  }
}
