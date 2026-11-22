import 'dart:async';
import 'dart:convert';

import '../catalog/catalog_models.dart';
import '../catalog/tmdb_catalog_service.dart';
import '../services/app_settings.dart';
import 'anime_mal_map.dart';

/// What the embed web player loads for one title / episode.
class EmbedTarget {
  const EmbedTarget({
    required this.url,
    this.malId,
    this.malNumber,
  });

  /// The embed URL the wrapper page puts in its iframe.
  final String url;

  /// Set only when VidLink is playing an anime through MyAnimeList: the MAL id
  /// and the episode number inside that MAL entry (which restarts at 1 for
  /// every MAL season, so it is NOT the TMDB episode number).
  final int? malId;
  final int? malNumber;

  /// True when the page is keyed by MyAnimeList instead of TMDB. Then the
  /// season / episode the player reports are MAL's, not TMDB's.
  bool get viaMal => malId != null;
}

/// Builds what the embed web player loads: the server's embed URL for a
/// title, and the small local page that hosts it.
///
/// The embed servers publish an iframe player, not stream links, so the
/// screen loads a local page that contains the documented iframe. That page
/// also forwards the player's `PLAYER_EVENT` messages (play / pause / seeked /
/// timeupdate / ended, with the season and episode) to Flutter, which is how
/// resume, watch progress and the episode label stay in sync.
class EmbedUrls {
  EmbedUrls._();

  /// Origins the player events may come from (the Vidfast docs list these,
  /// and VidLink's docs name https://vidlink.pro).
  static const List<String> _eventOrigins = [
    'https://vidfast.pro',
    'https://vidfast.in',
    'https://vidfast.io',
    'https://vidfast.me',
    'https://vidfast.net',
    'https://vidfast.pm',
    'https://vidfast.xyz',
    'https://vidfast.vc',
    'https://vidfast.bz',
    'https://vidlink.pro',
  ];

  /// Base URL the local wrapper page is loaded under, so the iframe sees a
  /// normal https parent (origin + Referer) instead of an opaque one.
  static const String pageBaseUrl = 'https://localhost/';

  /// Name shown for [server] in the app.
  static String label(EmbedServer server) {
    switch (server) {
      case EmbedServer.vidfast:
        return 'Vidfast';
      case EmbedServer.vidsrc:
        return 'Vidsrc';
      case EmbedServer.vidlink:
        return 'VidLink';
    }
  }

  /// Embed URL for [title] (and [episode] for a series) on [server], using
  /// the TMDB id, which every catalog title has.
  ///
  /// Only Vidfast and VidLink document `startAt` (resume) and the options for
  /// colours / hiding their own title and poster. For anime on VidLink use
  /// [resolve], which can switch to the MyAnimeList URL.
  static String build({
    required EmbedServer server,
    required CatalogTitle title,
    CatalogEpisode? episode,
    int startAtSeconds = 0,
  }) {
    final ep = title.type == CatalogType.series ? episode : null;
    switch (server) {
      case EmbedServer.vidfast:
        final path = ep != null
            ? '/tv/${title.tmdbId}/${ep.season}/${ep.number}'
            : '/movie/${title.tmdbId}';
        return Uri.https('vidfast.vc', path, {
          'autoPlay': 'true',
          'theme': 'D4AF37', // the app's gold
          'title': 'false',
          'poster': 'false',
          'fullscreenButton': 'false', // the screen is already fullscreen
          'chromecast': 'false',
          if (startAtSeconds > 0) 'startAt': '$startAtSeconds',
          if (ep != null) ...{'nextButton': 'true', 'autoNext': 'true'},
        }).toString();
      case EmbedServer.vidsrc:
        return ep != null
            ? 'https://vidsrc.mov/embed/tv/${title.tmdbId}/${ep.season}/${ep.number}'
            : 'https://vidsrc.mov/embed/movie/${title.tmdbId}';
      case EmbedServer.vidlink:
        return _vidlinkUrl(
          ep != null
              ? '/tv/${title.tmdbId}/${ep.season}/${ep.number}'
              : '/movie/${title.tmdbId}',
          startAtSeconds: startAtSeconds,
          nextButton: ep != null,
        );
    }
  }

  /// Same as [build], but VidLink plays anime through MyAnimeList ids:
  /// `/anime/{malId}/{number}/{sub|dub}`. Movies, every other show, and any
  /// anime the lookup can't place all keep the normal TMDB URL, and every
  /// other server is untouched.
  static Future<EmbedTarget> resolve({
    required EmbedServer server,
    required CatalogTitle title,
    CatalogEpisode? episode,
    int startAtSeconds = 0,
    bool dub = false,
  }) async {
    final ep = title.type == CatalogType.series ? episode : null;
    if (server == EmbedServer.vidlink && ep != null) {
      final match = await _animeMatch(title, ep);
      if (match != null) {
        return EmbedTarget(
          url: _vidlinkUrl(
            '/anime/${match.malId}/${match.number}/${dub ? 'dub' : 'sub'}',
            startAtSeconds: startAtSeconds,
            // The app's own Next button / auto-advance moves between
            // episodes, so MAL numbering never has to be mapped back.
            nextButton: false,
            audioFallback: true,
          ),
          malId: match.malId,
          malNumber: match.number,
        );
      }
    }
    return EmbedTarget(
      url: build(
        server: server,
        title: title,
        episode: episode,
        startAtSeconds: startAtSeconds,
      ),
    );
  }

  /// The MAL entry for [ep] of [title], or null when it is not an anime or
  /// can't be placed (then the caller uses the TMDB URL).
  static Future<AnimeMalMatch?> _animeMatch(
    CatalogTitle title,
    CatalogEpisode ep,
  ) async {
    try {
      // Cheap, offline: nothing to look up for shows MAL doesn't have.
      if (!AnimeMalMap.contains(title.tmdbId)) return null;

      var t = title;
      // Saved snapshots (Continue Watching, Favorites, downloads) carry no
      // genres / language / seasons, so ask TMDB (cached) when they're missing.
      Future<void> fillIn() async {
        final full = await TmdbCatalogService.details(
                CatalogType.series, title.tmdbId)
            .timeout(const Duration(seconds: 8));
        if (full != null) t = full;
      }

      if (t.genreIds.isEmpty || t.originalLanguage == null) await fillIn();
      if (!AnimeMalMap.isAnime(t)) return null;

      int? absolute;
      if (AnimeMalMap.needsAbsolute(t.tmdbId)) {
        if (t.seasons.isEmpty) await fillIn();
        absolute = AnimeMalMap.absoluteEpisode(t.seasons, ep.season, ep.number);
      }
      return AnimeMalMap.resolve(
        t.tmdbId,
        ep.season,
        ep.number,
        absoluteEpisode: absolute,
      );
    } catch (_) {
      return null; // network / parse problem: TMDB URL still plays
    }
  }

  /// VidLink's customisation parameters, set so the page matches the native
  /// player: the app's gold for the sliders, white icons, solid icon set,
  /// and no VidLink title / poster (the app draws its own top bar and cover).
  static String _vidlinkUrl(
    String path, {
    required int startAtSeconds,
    required bool nextButton,
    bool audioFallback = false,
  }) {
    return Uri.https('vidlink.pro', path, {
      // If the chosen sub / dub doesn't exist, play the other one.
      if (audioFallback) 'fallback': 'true',
      'primaryColor': 'D4AF37', // the app's gold
      'secondaryColor': '8A8A8A', // track behind the sliders (white54)
      'iconColor': 'FFFFFF',
      'icons': 'vid',
      'title': 'false',
      'poster': 'false',
      'autoplay': 'true',
      if (nextButton) 'nextbutton': 'true',
      if (startAtSeconds > 0) 'startAt': '$startAtSeconds',
    }).toString();
  }

  /// The local page that hosts the iframe and relays player events through
  /// the `Bridge` JavaScript channel.
  static String wrapperHtml(String url) => '''
<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>html,body{margin:0;height:100%;background:#000;overflow:hidden}
iframe{position:absolute;top:0;left:0;width:100%;height:100%;border:0}</style></head>
<body><iframe id="p" allowfullscreen
 allow="autoplay; fullscreen; encrypted-media; picture-in-picture"></iframe>
<script>
var O=${jsonEncode(_eventOrigins)};
document.getElementById('p').src=${jsonEncode(url)};
window.addEventListener('message',function(e){
  if(O.indexOf(e.origin)<0||!e.data)return;
  if(e.data.type==='PLAYER_EVENT'){Bridge.postMessage(JSON.stringify(e.data));}
});
</script></body></html>''';
}
