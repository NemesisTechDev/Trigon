import '../models/media_item.dart';
import '../../services/jellyfin_services/media_service.dart';
import '../../services/download_manager.dart';

/// Finds the single best "watch next" show once the last episode of a
/// series with nothing else queued after it reaches its Outro segment,
/// if the person has opted into auto-queued recommendations (see
/// AppSettings.autoQueueRecommendations — off by default, shared with
/// the equivalent Next Movie/music features).
///
/// Mirrors [MovieRecommendationService] closely (same Similar-items
/// lookup, same unwatched filter, same downloaded-library fallback),
/// but a Series item itself isn't something that can be played —
/// [recommendNext]/[recommendNextDownloaded] resolve all the way down
/// to that show's actual first episode, so what they return is already
/// directly playable. That also happens to be exactly what
/// [NextShowOverlay] needs to display: episodes inherit their
/// backdrop/logo art and `subtitle` from the parent series (see
/// MediaService.mediaItemFromJellyfin's backdropLogoId fallback), so
/// the returned MediaItem reads as "this show", not "S01E01", without
/// any extra fetch.
class ShowRecommendationService {
  ShowRecommendationService._();

  static final ShowRecommendationService instance =
      ShowRecommendationService._();

  /// Returns the first episode of the best next-show pick for
  /// [finishedEpisode]'s series, or null if nothing suitable came back.
  /// [exclude] can carry extra ids to keep out (e.g. anything already
  /// sitting in the queue).
  Future<MediaItem?> recommendNext(
    MediaItem finishedEpisode, {
    Set<String> exclude = const {},
  }) async {
    final seriesId = finishedEpisode.seriesId;
    if (seriesId == null) return null;

    final raw = await MediaService.getSimilarItems(seriesId, limit: 10)
        .catchError((_) => <dynamic>[]);

    for (final item in raw) {
      if (item is! Map) continue;

      final map = Map<String, dynamic>.from(item);

      // Similar can return the occasional non-series for a mixed-content
      // library — this widget is specifically "next show", not "next
      // anything".
      if (map["Type"] != "Series") continue;

      final id = map["Id"]?.toString();
      if (id == null || id == seriesId || exclude.contains(id)) continue;

      // A "next show" prompt recommending something already fully
      // watched isn't useful the way an unwatched pick is.
      if (map["UserData"]?["Played"] == true) continue;

      final episode = await _firstEpisode(id).catchError((_) => null);
      if (episode != null) return episode;
    }

    return null;
  }

  /// Fetches the show's very first episode (earliest season, earliest
  /// episode within it) — the same episode a person starting the show
  /// fresh from its own detail screen would land on.
  Future<MediaItem?> _firstEpisode(String seriesId) async {
    final episodes = await _firstSeasonEpisodesRaw(seriesId);
    if (episodes.isEmpty) return null;

    return MediaService.mediaItemFromJellyfin(
      Map<String, dynamic>.from(episodes.first as Map),
    );
  }

  /// Every episode of [seriesId]'s first season, sorted by episode
  /// number — used to re-root the playback queue onto the recommended
  /// show once its first episode actually starts playing (see
  /// PlayerManager._reRootQueueOnShow), so PlaybackQueue — and
  /// everything that reads it, like EpisodeListPanel's episode rows —
  /// reflects the new show's own season instead of a single item
  /// tacked onto the end of the series that just finished.
  Future<List<MediaItem>> firstSeasonEpisodes(String seriesId) async {
    final episodes = await _firstSeasonEpisodesRaw(seriesId);
    if (episodes.isEmpty) return [];

    return MediaService.mediaItemsFromList(episodes);
  }

  /// Shared season-lookup behind [_firstEpisode] and
  /// [firstSeasonEpisodes]: the earliest season by IndexNumber, then
  /// every one of its episodes sorted the same way, as raw Jellyfin
  /// maps.
  Future<List<Map<String, dynamic>>> _firstSeasonEpisodesRaw(
    String seriesId,
  ) async {
    final seasons = await MediaService.getSeasons(seriesId);
    if (seasons.isEmpty) return [];

    final sortedSeasons = List<dynamic>.from(seasons)
      ..sort((a, b) {
        final ai = (a as Map)["IndexNumber"];
        final bi = (b as Map)["IndexNumber"];
        return (ai is num ? ai : 0).compareTo(bi is num ? bi : 0);
      });

    final firstSeasonId = (sortedSeasons.first as Map)["Id"]?.toString();
    if (firstSeasonId == null) return [];

    final episodes = await MediaService.getEpisodes(seriesId, firstSeasonId);
    if (episodes.isEmpty) return [];

    final sortedEpisodes = List<dynamic>.from(episodes)
      ..sort((a, b) {
        final ai = (a as Map)["IndexNumber"];
        final bi = (b as Map)["IndexNumber"];
        return (ai is num ? ai : 0).compareTo(bi is num ? bi : 0);
      });

    return sortedEpisodes
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  /// Local counterpart to [recommendNext] for an episode playing from an
  /// on-device download — a server-Similar pick isn't actually watchable
  /// without a connection, which would defeat the entire point of
  /// having downloaded this show in the first place. Looks at the
  /// downloaded episode library instead
  /// (DownloadManager.instance.episodesBySeries): another downloaded
  /// show's earliest downloaded episode, preferring whichever other
  /// series has the most episodes downloaded (a rough stand-in for
  /// "most likely to actually have that show's first episode downloaded
  /// too"). Synchronous — DownloadManager's records are already in
  /// memory, so there's no network round trip to await the way
  /// [recommendNext] has.
  MediaItem? recommendNextDownloaded(
    MediaItem finishedEpisode, {
    Set<String> exclude = const {},
  }) {
    final bySeries = DownloadManager.instance.episodesBySeries;
    final currentSeriesId = finishedEpisode.seriesId;

    final candidates = bySeries.entries
        .where((e) => e.key != currentSeriesId && e.value.isNotEmpty)
        .toList()
      ..sort((a, b) => b.value.length.compareTo(a.value.length));

    for (final entry in candidates) {
      final firstEpisode = entry.value.first;
      if (exclude.contains(firstEpisode.id)) continue;
      return DownloadManager.instance.mediaItemForRecord(firstEpisode);
    }

    return null;
  }
}
