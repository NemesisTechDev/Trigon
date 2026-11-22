import '../catalog/catalog_models.dart';

/// The minimum copy of a title needed to draw its card and to ask addons
/// about it later with no network call (note the IMDb id).
class TitleSnapshot {
  final int tmdbId;
  final CatalogType type;
  final String title;
  final String overview;
  final String? posterPath;
  final String? backdropPath;
  final String? imdbId;
  final String? releaseDate;
  final int? runtime;
  final double rating;

  /// When the title was added to the watchlist / Favorites (ms since
  /// epoch). Only set on watchlist entries, and only for titles added after
  /// this field existed; older entries have none and keep their list
  /// position (the list is newest-first). Travels with the watchlist
  /// through the saved copy and the cloud sync, which is what lets
  /// "Time added" order favorites on every device.
  final int? addedAtMs;

  const TitleSnapshot({
    required this.tmdbId,
    required this.type,
    required this.title,
    this.overview = '',
    this.posterPath,
    this.backdropPath,
    this.imdbId,
    this.releaseDate,
    this.runtime,
    this.rating = 0,
    this.addedAtMs,
  });

  /// Stable id shared by history and watchlist, e.g. `movie:603`, `tv:1399`.
  String get key => '${type.tmdb}:$tmdbId';

  factory TitleSnapshot.of(CatalogTitle t, {int? addedAtMs}) => TitleSnapshot(
        tmdbId: t.tmdbId,
        type: t.type,
        title: t.title,
        overview: t.overview,
        posterPath: t.posterPath,
        backdropPath: t.backdropPath,
        imdbId: t.imdbId,
        releaseDate: t.releaseDate,
        runtime: t.runtime,
        rating: t.rating,
        addedAtMs: addedAtMs,
      );

  CatalogTitle toTitle() => CatalogTitle(
        tmdbId: tmdbId,
        type: type,
        title: title,
        overview: overview,
        posterPath: posterPath,
        backdropPath: backdropPath,
        imdbId: imdbId,
        releaseDate: releaseDate,
        runtime: runtime,
        rating: rating,
      );

  Map<String, dynamic> toJson() => {
        'tmdbId': tmdbId,
        'type': type.tmdb,
        'title': title,
        'overview': overview,
        'posterPath': posterPath,
        'backdropPath': backdropPath,
        'imdbId': imdbId,
        'releaseDate': releaseDate,
        'runtime': runtime,
        'rating': rating,
        if (addedAtMs != null) 'addedAtMs': addedAtMs,
      };

  static TitleSnapshot? fromJson(dynamic j) {
    if (j is! Map) return null;
    final type = CatalogType.fromTmdb(j['type']?.toString());
    final id = j['tmdbId'];
    if (type == null || id is! num) return null;
    return TitleSnapshot(
      tmdbId: id.toInt(),
      type: type,
      title: (j['title'] ?? '').toString(),
      overview: (j['overview'] ?? '').toString(),
      posterPath: j['posterPath'] as String?,
      backdropPath: j['backdropPath'] as String?,
      imdbId: j['imdbId'] as String?,
      releaseDate: j['releaseDate'] as String?,
      runtime: (j['runtime'] as num?)?.toInt(),
      rating: (j['rating'] as num?)?.toDouble() ?? 0,
      addedAtMs: (j['addedAtMs'] as num?)?.toInt(),
    );
  }
}

/// Where the person is in one movie, or in one show (its latest episode).
/// There is one entry per title, not per episode.
class WatchEntry {
  final TitleSnapshot title;

  // Only for series:
  final int? season;
  final int? episode;
  final String? episodeName;
  final String? episodeStillPath;
  final int? episodeRuntime;

  final int positionMs;
  final int durationMs;
  final int updatedAtMs;

  /// True once the movie/episode was watched to (nearly) the end.
  final bool finished;

  /// True when this is not something already started but the *next* episode
  /// to watch (created when an episode finishes). Shown as "Up next".
  final bool upNext;

  const WatchEntry({
    required this.title,
    this.season,
    this.episode,
    this.episodeName,
    this.episodeStillPath,
    this.episodeRuntime,
    required this.positionMs,
    required this.durationMs,
    required this.updatedAtMs,
    this.finished = false,
    this.upNext = false,
  });

  String get key => title.key;
  bool get isEpisode => season != null && episode != null;
  Duration get position => Duration(milliseconds: positionMs);
  Duration get remaining =>
      Duration(milliseconds: (durationMs - positionMs).clamp(0, durationMs));

  /// 0.0 to 1.0.
  double get progress =>
      durationMs <= 0 ? 0 : (positionMs / durationMs).clamp(0.0, 1.0);

  CatalogEpisode? toEpisode() {
    if (!isEpisode) return null;
    return CatalogEpisode(
      season: season!,
      number: episode!,
      name: episodeName ?? 'Episode $episode',
      overview: '',
      stillPath: episodeStillPath,
      runtime: episodeRuntime,
    );
  }

  Map<String, dynamic> toJson() => {
        'title': title.toJson(),
        'season': season,
        'episode': episode,
        'episodeName': episodeName,
        'episodeStillPath': episodeStillPath,
        'episodeRuntime': episodeRuntime,
        'positionMs': positionMs,
        'durationMs': durationMs,
        'updatedAtMs': updatedAtMs,
        'finished': finished,
        'upNext': upNext,
      };

  static WatchEntry? fromJson(dynamic j) {
    if (j is! Map) return null;
    final title = TitleSnapshot.fromJson(j['title']);
    if (title == null) return null;
    return WatchEntry(
      title: title,
      season: (j['season'] as num?)?.toInt(),
      episode: (j['episode'] as num?)?.toInt(),
      episodeName: j['episodeName'] as String?,
      episodeStillPath: j['episodeStillPath'] as String?,
      episodeRuntime: (j['episodeRuntime'] as num?)?.toInt(),
      positionMs: (j['positionMs'] as num?)?.toInt() ?? 0,
      durationMs: (j['durationMs'] as num?)?.toInt() ?? 0,
      updatedAtMs: (j['updatedAtMs'] as num?)?.toInt() ?? 0,
      finished: j['finished'] == true,
      upNext: j['upNext'] == true,
    );
  }
}

/// Episode details carried inside a MediaItem's `raw` map, so anything that
/// only holds the playing item (history tracking, next-episode queueing) can
/// rebuild the episode without a lookup.
Map<String, dynamic> episodeToRaw(CatalogEpisode e) => {
      'season': e.season,
      'number': e.number,
      'name': e.name,
      'stillPath': e.stillPath,
      'runtime': e.runtime,
      'airDate': e.airDate,
    };

CatalogEpisode? episodeFromRaw(dynamic j) {
  if (j is! Map) return null;
  final season = j['season'];
  final number = j['number'];
  if (season is! num || number is! num) return null;
  return CatalogEpisode(
    season: season.toInt(),
    number: number.toInt(),
    name: (j['name'] ?? 'Episode $number').toString(),
    overview: '',
    stillPath: j['stillPath'] as String?,
    runtime: (j['runtime'] as num?)?.toInt(),
    airDate: j['airDate'] as String?,
  );
}
