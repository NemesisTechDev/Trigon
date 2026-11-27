import 'package:flutter/foundation.dart';

import '../addons/addon_manager.dart';
import '../addons/addon_models.dart';
import '../addons/stream_rules.dart';
import '../library/source_preferences.dart';
import '../services/app_settings.dart';
import 'auto_link_selector.dart';
import 'catalog_models.dart';
import 'release_gate.dart';
import 'tmdb_catalog_service.dart';

/// Works out which episode comes after another, and which stream to use for
/// it. No UI and no player access: [BingeCoordinator] and
/// [WatchHistoryService] build on this.
class NextEpisodeService {
  NextEpisodeService._();

  /// The episode after [current], or null if there isn't one (last episode,
  /// not aired yet, specials, or TMDB unreachable).
  static Future<CatalogEpisode?> findNext(
    CatalogTitle title,
    CatalogEpisode current,
  ) async {
    if (title.type != CatalogType.series || current.season <= 0) return null;
    try {
      final inSeason =
          await TmdbCatalogService.episodes(title.tmdbId, current.season);

      CatalogEpisode? next;
      for (final e in inSeason) {
        if (e.number > current.number) {
          next = e;
          break;
        }
      }

      // Past the last episode of this season: first episode of the next one.
      if (next == null &&
          inSeason.isNotEmpty &&
          current.number >= inSeason.last.number) {
        final following = await TmdbCatalogService.episodes(
            title.tmdbId, current.season + 1);
        if (following.isNotEmpty) next = following.first;
      }

      if (next == null || _notAiredYet(next)) return null;
      return next;
    } catch (e) {
      debugPrint('[NextEpisode] findNext failed: $e');
      return null;
    }
  }

  /// The episode before [current]: the one before it in its season, else the
  /// last aired episode of the previous season. Null at the very first.
  static Future<CatalogEpisode?> findPrevious(
    CatalogTitle title,
    CatalogEpisode current,
  ) async {
    if (title.type != CatalogType.series || current.season <= 0) return null;
    try {
      final inSeason =
          await TmdbCatalogService.episodes(title.tmdbId, current.season);
      CatalogEpisode? prev;
      for (final e in inSeason) {
        if (e.number < current.number) prev = e;
      }
      if (prev != null) return prev;

      if (current.season > 1) {
        final before = await TmdbCatalogService.episodes(
            title.tmdbId, current.season - 1);
        for (final e in before.reversed) {
          if (!_notAiredYet(e)) return e;
        }
      }
      return null;
    } catch (e) {
      debugPrint('[NextEpisode] findPrevious failed: $e');
      return null;
    }
  }

  /// A missing air date is allowed (older shows often lack one); a date in
  /// the future is not.
  static bool _notAiredYet(CatalogEpisode e) {
    final d = e.airDate;
    if (d == null || d.isEmpty) return false;
    final parsed = DateTime.tryParse(d);
    if (parsed == null) return false;
    return parsed.isAfter(DateTime.now());
  }

  /// Streams for [episode], narrowed to the source the person has been using
  /// for this show, falling back to the best stream available. Null if no
  /// addon has anything.
  static Future<AddonStream?> resolveStream(
    CatalogTitle title,
    CatalogEpisode episode,
  ) async {
    // An episode that has not aired yet has nothing real to play.
    if (ReleaseGate.blockedMessage(title, episode: episode) != null) {
      return null;
    }
    final id = title.addonId(season: episode.season, episode: episode.number);
    // After 15 s whatever has arrived is used (a slow addon does not make the
    // quick addons' links useless).
    final streams = await AddonManager.instance
        .streamsFor(title.type.addon, id, timeout: const Duration(seconds: 15));
    if (streams.isEmpty) return null;

    // Auto-link selection: the next episode follows the same quality rule as
    // the one now playing. Silent (no override message): the person is in the
    // middle of watching something else.
    // Links the never-select rules rule out (HLS, vidlink, CAM, foreign-
    // language dubs) are never used here either, so with nothing left the
    // answer is "no stream" rather than an excluded link.
    if (AppSettings.autoLinkSelection.value) {
      final choice = AutoLinkSelector.selectAlways(
        streams,
        AppSettings.playbackQualityMode.value,
        ctx: LinkContext(
          originalLanguage: title.originalLanguage,
          titleName: title.title,
        ),
      );
      return choice?.stream;
    }

    await SourcePreferences.instance.load();
    final pref =
        SourcePreferences.instance.forTitle('${title.type.tmdb}:${title.tmdbId}');
    return pref?.pickFrom(streams) ?? streams.first;
  }
}
