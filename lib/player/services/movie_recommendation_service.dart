import '../models/media_item.dart';
import '../../services/jellyfin_services/media_service.dart';
import '../../services/download_manager.dart';

/// Finds the single best "watch next" movie once a movie with nothing
/// queued after it reaches its Outro segment, if the person has opted
/// into auto-queued recommendations (see AppSettings.autoQueueRecommendations
/// — off by default, and shared with the equivalent music feature).
///
/// Unlike MusicRecommendationService's multi-seed rank fusion (built to
/// keep a whole listening session going through many tracks), this only
/// ever needs one good next pick, so it leans entirely on Jellyfin's own
/// Similar-items endpoint for the movie that just finished — already
/// genre/people/studio informed server-side, and exactly what "movies
/// with similar genres" is asking for. Results are taken in the server's
/// own ranked order, filtered down to actual unwatched movies.
class MovieRecommendationService {
  MovieRecommendationService._();

  static final MovieRecommendationService instance =
      MovieRecommendationService._();

  /// Returns the best next-movie pick for [finished], or null if nothing
  /// suitable came back. [exclude] can carry extra ids to keep out (e.g.
  /// anything already sitting in the queue).
  Future<MediaItem?> recommendNext(
    MediaItem finished, {
    Set<String> exclude = const {},
  }) async {
    // Addon items carry their own id; the catalog knows the movie by its
    // TMDB-based id, which is what Similar needs.
    final tmdb = finished.raw?['TmdbId'];
    final lookupId = (finished.raw?['AddonStream'] == true && tmdb != null)
        ? 'm$tmdb'
        : finished.id;
    final raw = await MediaService.getSimilarItems(lookupId, limit: 10)
        .catchError((_) => <dynamic>[]);

    for (final item in raw) {
      if (item is! Map) continue;

      final map = Map<String, dynamic>.from(item);

      // Similar can return the occasional non-movie for a mixed-content
      // library (e.g. a documentary series with an overlapping subject)
      // — this widget is specifically "next movie", not "next anything".
      if (map["Type"] != "Movie") continue;

      final id = map["Id"]?.toString();
      if (id == null ||
          id == finished.id ||
          id == lookupId ||
          exclude.contains(id)) {
        continue;
      }

      // A "next movie" prompt recommending something already fully
      // watched isn't useful the way an unwatched pick is.
      if (map["UserData"]?["Played"] == true) continue;

      return MediaService.mediaItemFromJellyfin(map);
    }

    return null;
  }

  /// Local counterpart to [recommendNext] for a movie playing from an
  /// on-device download (DownloadManager.isDownloaded(finished.id)) —
  /// recommending a server-Similar pick the person can't actually watch
  /// without a connection would defeat the entire point of having
  /// downloaded this movie in the first place. Looks at the downloaded
  /// movie library instead (DownloadManager.instance.movies): other
  /// downloaded, not-yet-watched movies, ranked by how many genres they
  /// share with [finished] (server-Similar's own primary signal) —
  /// falling back to just the next available downloaded movie if none
  /// share a genre, or [finished] has no Genres field to compare against
  /// at all. Synchronous — DownloadManager's records are already in
  /// memory, so there's no network round trip to await the way
  /// [recommendNext] has.
  MediaItem? recommendNextDownloaded(
    MediaItem finished, {
    Set<String> exclude = const {},
  }) {
    final finishedGenres = _genresOf(finished.raw);

    final candidates = DownloadManager.instance.movies.where((record) {
      if (record.id == finished.id || exclude.contains(record.id)) {
        return false;
      }

      // Same "don't recommend something already fully watched" rule
      // recommendNext applies above — DownloadRecord.raw only ever
      // reflects whatever UserData snapshot existed at download time
      // rather than live server state, same as everywhere else that
      // reads straight off a DownloadRecord, so this is best-effort.
      return record.raw['UserData']?['Played'] != true;
    }).toList();

    if (candidates.isEmpty) return null;

    candidates.sort((a, b) {
      final aShared = _sharedGenreCount(finishedGenres, _genresOf(a.raw));
      final bShared = _sharedGenreCount(finishedGenres, _genresOf(b.raw));
      return bShared.compareTo(aShared);
    });

    return DownloadManager.instance.mediaItemForRecord(candidates.first);
  }

  List<String> _genresOf(Map<String, dynamic>? raw) {
    final genres = raw?['Genres'];
    if (genres is! List) return const [];
    return genres.map((g) => g.toString()).toList();
  }

  int _sharedGenreCount(List<String> a, List<String> b) {
    if (a.isEmpty || b.isEmpty) return 0;
    final bSet = b.toSet();
    return a.where(bSet.contains).length;
  }
}
