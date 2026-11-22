import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../catalog/catalog_models.dart';
import '../catalog/fanart_logo_service.dart';
import '../catalog/tmdb_catalog_service.dart';
import '../library/watch_entry.dart';
import '../library/watch_history_service.dart';
import '../services/parental/parental_controls.dart';
import '../services/parental/parental_models.dart';
import '../services/parental/ratings_resolver.dart';
import 'virtual_images.dart';

/// A parsed virtual item id. Ids are short strings the original screens just
/// carry around:
///
///   movie `m603`, series `s1399`, season `s1399x2`, episode `s1399x2x5`,
///   library `lib_movies` / `lib_tv` / `lib_g28`, person `p287`,
///   collection `c10` (a TMDB movie collection, shown as a Jellyfin BoxSet).
class VId {
  final String kind; // movie|series|season|episode|library|person|collection|other
  final int tmdbId;
  final int? season;
  final int? episode;
  final String raw;

  const VId._(this.kind, this.raw, {this.tmdbId = 0, this.season, this.episode});

  static final RegExp _movie = RegExp(r'^m(\d+)$');
  static final RegExp _series = RegExp(r'^s(\d+)$');
  static final RegExp _season = RegExp(r'^s(\d+)x(\d+)$');
  static final RegExp _episode = RegExp(r'^s(\d+)x(\d+)x(\d+)$');
  static final RegExp _person = RegExp(r'^p(\d+)$');
  static final RegExp _collection = RegExp(r'^c(\d+)$');

  static VId parse(String id) {
    RegExpMatch? m = _movie.firstMatch(id);
    if (m != null) return VId._('movie', id, tmdbId: int.parse(m.group(1)!));
    m = _episode.firstMatch(id);
    if (m != null) {
      return VId._('episode', id,
          tmdbId: int.parse(m.group(1)!),
          season: int.parse(m.group(2)!),
          episode: int.parse(m.group(3)!));
    }
    m = _season.firstMatch(id);
    if (m != null) {
      return VId._('season', id,
          tmdbId: int.parse(m.group(1)!), season: int.parse(m.group(2)!));
    }
    m = _series.firstMatch(id);
    if (m != null) return VId._('series', id, tmdbId: int.parse(m.group(1)!));
    m = _person.firstMatch(id);
    if (m != null) return VId._('person', id, tmdbId: int.parse(m.group(1)!));
    m = _collection.firstMatch(id);
    if (m != null) {
      return VId._('collection', id, tmdbId: int.parse(m.group(1)!));
    }
    if (id.startsWith('lib_')) return VId._('library', id);
    return VId._('other', id);
  }

  static String collectionOf(int id) => 'c$id';
  static String movieOf(int id) => 'm$id';
  static String seriesOf(int id) => 's$id';
  static String seasonOf(int tv, int n) => 's${tv}x$n';
  static String episodeOf(int tv, int s, int e) => 's${tv}x${s}x$e';
}

/// One of the virtual "libraries" (the cards in the home screen's library row
/// and the chips on the Movies screen).
class VLibrary {
  final String id;
  final String name;
  final String collectionType; // movies | tvshows
  final CatalogType type;
  final int? genreId;

  /// TMDB keyword ids (`|` = any of, `,` = all of). Used where TMDB has no
  /// genre for the idea (Sports everywhere; Horror / Thriller on TV).
  final String? keywords;

  /// TMDB production company ids (`|` = any of). Used for Comics.
  final String? companies;

  /// Original language (ISO 639-1). Used for Anime (ja) and K-Drama (ko).
  final String? language;

  /// TV only: TMDB has ONE genre for "Action & Adventure" (10759), so the
  /// Action and Adventure chips would otherwise send the very same request
  /// and show the very same shows. `'action'` / `'adventure'` splits that
  /// genre in two non-overlapping halves (see [VirtualCatalog._matchesSplit]).
  final String? split;
  const VLibrary(this.id, this.name, this.collectionType, this.type,
      [this.genreId,
      this.keywords,
      this.companies,
      this.language,
      this.split]);
}

/// Builds Jellyfin-shaped JSON out of TMDB data so the original screens, which
/// were written against a Jellyfin server, run unchanged.
class VirtualCatalog {
  VirtualCatalog._();

  static const String userId = 'namesis-user';
  static const String serverId = 'namesis';

  // ---------- libraries ----------

  static const VLibrary moviesLib =
      VLibrary('lib_movies', 'Movies', 'movies', CatalogType.movie);
  static const VLibrary tvLib =
      VLibrary('lib_tv', 'TV Shows', 'tvshows', CatalogType.series);

  /// The "Collections" card / chip: TMDB movie collections (franchises) as
  /// Jellyfin BoxSets. Listed first, so it is the first card of the home
  /// row and the first chip of the Movies screen (the TV Shows screen drops
  /// it, collections only hold movies).
  static const VLibrary collectionsLib =
      VLibrary('lib_collections', 'Collections', 'boxsets', CatalogType.movie);

  /// TMDB's movie genre ids are stable.
  static const List<VLibrary> genreLibs = [
    VLibrary('lib_g28', 'Action', 'movies', CatalogType.movie, 28),
    VLibrary('lib_g12', 'Adventure', 'movies', CatalogType.movie, 12),
    VLibrary('lib_g16', 'Animation', 'movies', CatalogType.movie, 16),
    VLibrary('lib_g35', 'Comedy', 'movies', CatalogType.movie, 35),
    VLibrary('lib_g80', 'Crime', 'movies', CatalogType.movie, 80),
    VLibrary('lib_g99', 'Documentary', 'movies', CatalogType.movie, 99),
    VLibrary('lib_g18', 'Drama', 'movies', CatalogType.movie, 18),
    VLibrary('lib_g10751', 'Family', 'movies', CatalogType.movie, 10751),
    VLibrary('lib_g27', 'Horror', 'movies', CatalogType.movie, 27),
    VLibrary('lib_g10749', 'Romance', 'movies', CatalogType.movie, 10749),
    VLibrary('lib_g878', 'Science Fiction', 'movies', CatalogType.movie, 878),
    VLibrary('lib_g53', 'Thriller', 'movies', CatalogType.movie, 53),
    VLibrary('lib_gsports', 'Sports', 'movies', CatalogType.movie, null,
        _sportsKeywords),
    VLibrary('lib_ganime', 'Anime', 'movies', CatalogType.movie, 16, null,
        null, 'ja'),
    VLibrary('lib_gkdrama', 'K-Drama', 'movies', CatalogType.movie, 18, null,
        null, 'ko'),
    VLibrary('lib_gwar', 'War', 'movies', CatalogType.movie, 10752),
    VLibrary('lib_gcomics', 'Comics', 'movies', CatalogType.movie, null, null,
        _comicsCompanies),
  ];

  /// Comics = adaptations by the comic publishers' studios on TMDB:
  /// 420 Marvel Studios, 7505 Marvel Entertainment, 9993 DC Entertainment,
  /// 429 DC Comics, 128064 DC Films.
  static const String _comicsCompanies = '420|7505|9993|429|128064';

  /// TMDB keywords: 6075 = sport, 159290 = sports documentary.
  static const String _sportsKeywords = '6075|159290';

  /// NAMESIS PRIME: the chips of the TV Shows screen. Same names and order
  /// as the movie chips. TMDB has no TV genre for Horror, Thriller or
  /// Romance, and Action and Adventure share one TV genre, so those use
  /// keywords / the shared genre (see [_genreFor] and [_discoverPage]).
  static const List<VLibrary> tvGenreLibs = [
    VLibrary('lib_tg28', 'Action', 'tvshows', CatalogType.series, 28, null,
        null, null, 'action'),
    VLibrary('lib_tg12', 'Adventure', 'tvshows', CatalogType.series, 12, null,
        null, null, 'adventure'),
    VLibrary('lib_tg16', 'Animation', 'tvshows', CatalogType.series, 16),
    VLibrary('lib_tg35', 'Comedy', 'tvshows', CatalogType.series, 35),
    VLibrary('lib_tg80', 'Crime', 'tvshows', CatalogType.series, 80),
    VLibrary('lib_tg99', 'Documentary', 'tvshows', CatalogType.series, 99),
    VLibrary('lib_tg18', 'Drama', 'tvshows', CatalogType.series, 18),
    VLibrary('lib_tg10751', 'Family', 'tvshows', CatalogType.series, 10751),
    VLibrary('lib_tg27', 'Horror', 'tvshows', CatalogType.series, null,
        '315058'),
    VLibrary('lib_tg10749', 'Romance', 'tvshows', CatalogType.series, 10749),
    VLibrary('lib_tg878', 'Science Fiction', 'tvshows', CatalogType.series, 878),
    VLibrary('lib_tg53', 'Thriller', 'tvshows', CatalogType.series, null,
        '316362'),
    VLibrary('lib_tgsports', 'Sports', 'tvshows', CatalogType.series, null,
        _sportsKeywords),
    VLibrary('lib_tganime', 'Anime', 'tvshows', CatalogType.series, 16, null,
        null, 'ja'),
    VLibrary('lib_tgkdrama', 'K-Drama', 'tvshows', CatalogType.series, 18,
        null, null, 'ko'),
    VLibrary('lib_tgwar', 'War', 'tvshows', CatalogType.series, 10752),
    VLibrary('lib_tgcomics', 'Comics', 'tvshows', CatalogType.series, null,
        null, _comicsCompanies),
  ];

  /// The libraries the app lists. The old all-in-one "Movies" and
  /// "TV Shows" cards are gone (they are the bottom tabs now); [moviesLib]
  /// and [tvLib] stay only so old ids still resolve.
  static List<VLibrary> get libraries =>
      [collectionsLib, ...genreLibs, ...tvGenreLibs];

  /// True for the TV chips above (the home screen does not list these).
  static bool isTvGenreLibrary(String? id) =>
      tvGenreLibs.any((l) => l.id == id);

  /// True for the library cards the home screen's row may show: the movie
  /// genres plus Sports. Not the TV chips and not the removed all-in-one
  /// Movies / TV Shows cards (which an older cached home page may hold).
  static bool isHomeLibrary(String? id) =>
      id != null &&
      id != moviesLib.id &&
      id != tvLib.id &&
      !isTvGenreLibrary(id);

  /// Pseudo-libraries that are never shown as cards; asking for their items
  /// returns this week's trending movies / TV shows (home screen rows).
  static const String trendingMoviesId = 'lib_trending_movies';
  static const String trendingShowsId = 'lib_trending_tv';

  static VLibrary? libraryById(String? id) {
    if (id == null) return null;
    if (id == moviesLib.id) return moviesLib;
    if (id == tvLib.id) return tvLib;
    if (id == collectionsLib.id) return collectionsLib;
    for (final l in libraries) {
      if (l.id == id) return l;
    }
    return null;
  }

  /// Ids of the libraries the home screen should not repeat as a
  /// "recently released" row (the trending rows already cover them).
  static bool isGenreLibrary(String? id) =>
      genreLibs.any((l) => l.id == id);

  /// True when Parental Controls block this chip's whole genre (e.g. the
  /// Horror chip while Horror is a blocked genre), so its grid can say
  /// "Library blocked" instead of showing an ordinary empty state.
  static bool isLibraryBlocked(String? id) {
    final lib = libraryById(id);
    if (lib == null) return false;
    final pc = ParentalControls.instance;
    if (!pc.contentFilterActive) return false;
    final blocked = pc.settings.value.blockedGenres;
    if (blocked.isEmpty) return false;
    final key = _blockableGenreKey(lib);
    return key != null && blocked.contains(key);
  }

  /// The [BlockableGenre.key] a chip belongs to, or null for chips that
  /// are not a genre (Collections, Sports, Comics).
  static String? _blockableGenreKey(VLibrary lib) {
    final g = lib.genreId;
    if (g != null) {
      for (final b in kBlockableGenres) {
        if (b.ids.contains(g)) return b.key;
      }
      return null;
    }
    // TV Horror / Thriller have no TMDB genre; they are keyword chips.
    switch (lib.keywords) {
      case '315058':
        return 'horror';
      case '316362':
        return 'thriller';
    }
    return null;
  }

  // ---------- genre names ----------

  static const Map<int, String> _genreNames = {
    28: 'Action',
    12: 'Adventure',
    16: 'Animation',
    35: 'Comedy',
    80: 'Crime',
    99: 'Documentary',
    18: 'Drama',
    10751: 'Family',
    14: 'Fantasy',
    36: 'History',
    27: 'Horror',
    10402: 'Music',
    9648: 'Mystery',
    10749: 'Romance',
    878: 'Science Fiction',
    10770: 'TV Movie',
    53: 'Thriller',
    10752: 'War',
    37: 'Western',
    10759: 'Action & Adventure',
    10762: 'Kids',
    10763: 'News',
    10764: 'Reality',
    10765: 'Sci-Fi & Fantasy',
    10766: 'Soap',
    10767: 'Talk',
    10768: 'War & Politics',
  };

  static int? _genreIdByName(String name) {
    final n = name.trim().toLowerCase();
    if (n == 'sci-fi' || n == 'scifi') return 878;
    for (final e in _genreNames.entries) {
      if (e.value.toLowerCase() == n) return e.key;
    }
    return null;
  }

  /// TMDB uses different genre ids for a few TV genres.
  static int _genreFor(CatalogType type, int movieGenre) {
    if (type == CatalogType.movie) return movieGenre;
    switch (movieGenre) {
      case 28:
      case 12:
        return 10759;
      case 878:
      case 14:
        return 10765;
      case 10752:
        return 10768;
    }
    return movieGenre;
  }

  /// Genres that make a TMDB "Action & Adventure" (10759) show an
  /// *adventure* rather than an *action* show: fantasy / sci-fi quests,
  /// animation, family and kids' adventures, westerns.
  static const Set<int> _adventureMarkers = {10765, 16, 10751, 10762, 37};

  /// Whether [t] belongs on the chip whose [VLibrary.split] is [split].
  /// With no split every title is kept. Otherwise a title goes to Adventure
  /// when it carries any of [_adventureMarkers] and to Action when it does
  /// not, so the two chips never overlap and never come back identical.
  static bool _matchesSplit(CatalogTitle t, String? split) {
    if (split == null) return true;
    final adventurous = t.genreIds.any(_adventureMarkers.contains);
    return split == 'adventure' ? adventurous : !adventurous;
  }

  // ---------- parental controls ----------

  /// The highest US movie certification TMDB may return, when Parental
  /// Controls has a maturity limit and unrated titles are hidden. Movie
  /// discover calls then filter server-side (no per-title lookups); null
  /// means no server-side filter applies.
  static String? get _movieCeiling {
    final pc = ParentalControls.instance;
    final ps = pc.settings.value;
    if (!pc.contentFilterActive || !ps.hasMaturityLimit || !ps.blockUnrated) {
      return null;
    }
    return RatingScale.tmdbMovieCeiling(ps.maxLevel);
  }

  /// True while a maturity limit is being enforced.
  static bool get _strictRatings {
    final pc = ParentalControls.instance;
    return pc.contentFilterActive && pc.settings.value.hasMaturityLimit;
  }

  // ---------- small helpers ----------

  static int _clampInt(int v, int lo, int hi) => v < lo ? lo : (v > hi ? hi : v);

  static String _today() {
    final d = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }

  static int _ticksFromMinutes(int? minutes) =>
      (minutes ?? 0) * 60 * 10000000;

  static int _ticksFromMs(int ms) => ms * 10000;

  static String? _premiere(String? date) {
    if (date == null || date.length < 10) return null;
    return '${date}T00:00:00.0000000Z';
  }

  static bool _isFuture(String? date) {
    if (date == null || date.isEmpty) return false;
    return date.compareTo(_today()) > 0;
  }

  static String _typeName(CatalogType t) =>
      t == CatalogType.movie ? 'Movie' : 'Series';

  // ---------- extra per-title data learned from detail calls ----------

  static final Map<String, String> _logos = {}; // item id -> logo path

  /// Languages whose logos are accepted. English first (see [_bestLogo]),
  /// but a title that only has e.g. a Japanese or Korean logo still gets one.
  static const String _logoLangs = 'en,null,ja,ko,zh,es,fr,de,it,pt,ru,hi,'
      'th,tr,ar,id,pl,nl,sv,da,no,fi,cs,hu,he,el,uk,vi,ms,ta,te,tl,fa,cn';

  static final Map<String, Future<String?>> _logoInflight = {};
  static final Map<String, DateTime> _logoMiss = {};

  static bool _hasLogo(String id) =>
      _logos[id] != null || VirtualImages.urlFor(id, 'Logo') != null;

  /// The best logo in TMDB's `images.logos` list, or null. SVGs are skipped
  /// (the image CDN cannot resize them and the app cannot draw them), as are
  /// tall, square-ish pictures that are not title art.
  static String? _bestLogo(dynamic logos) {
    if (logos is! List) return null;
    int rank(String? lang) => lang == 'en' ? 0 : (lang == null ? 1 : 2);
    Map? best;
    for (final l in logos.whereType<Map>()) {
      final path = l['file_path'];
      if (path is! String || path.isEmpty) continue;
      if (path.toLowerCase().endsWith('.svg')) continue;
      final ratio = l['aspect_ratio'];
      if (ratio is num && ratio < 1.1) continue;
      if (best == null) {
        best = l;
        continue;
      }
      final a = rank(l['iso_639_1'] as String?);
      final b = rank(best['iso_639_1'] as String?);
      if (a != b) {
        if (a < b) best = l;
        continue;
      }
      final va = (l['vote_average'] is num) ? l['vote_average'] as num : 0;
      final vb =
          (best['vote_average'] is num) ? best['vote_average'] as num : 0;
      if (va != vb) {
        if (va > vb) best = l;
        continue;
      }
      final wa = (l['width'] is num) ? l['width'] as num : 0;
      final wb = (best['width'] is num) ? best['width'] as num : 0;
      if (wa > wb) best = l;
    }
    return best?['file_path'] as String?;
  }

  /// Makes sure the movie / series [id] ("m123" / "s123") has a logo, fetching
  /// it from TMDB when it is not known yet. Returns the logo URL, or null if
  /// the title has none (or the network failed; a failure is retried after a
  /// short pause, "no logo exists" is remembered for the session).
  static Future<String?> ensureLogo(String id) {
    final known = VirtualImages.urlFor(id, 'Logo', maxWidth: 700);
    if (known != null) return Future.value(known);
    final v = VId.parse(id);
    if (v.kind != 'movie' && v.kind != 'series') return Future.value(null);
    final miss = _logoMiss[id];
    if (miss != null && DateTime.now().isBefore(miss)) {
      return Future.value(null);
    }
    return _logoInflight[id] ??= _fetchLogo(id, v).whenComplete(() {
      _logoInflight.remove(id);
    });
  }

  static Future<String?> _fetchLogo(String id, VId v) async {
    try {
      final isMovie = v.kind == 'movie';
      final data = await TmdbCatalogService.raw(
        '/${isMovie ? 'movie' : 'tv'}/${v.tmdbId}/images',
        {'include_image_language': _logoLangs},
      );
      if (data == null) {
        // Network trouble: try again soon.
        _logoMiss[id] = DateTime.now().add(const Duration(seconds: 15));
        return null;
      }
      var pick = _bestLogo(data['logos']);
      if (pick == null) {
        // TMDB has none: try the fallback database (Fanart.tv). Its logos
        // are full URLs, which VirtualImages.urlFor passes through as is.
        final fb = await FanartLogoService.logoFor(
            isMovie: isMovie, tmdbId: v.tmdbId);
        pick = fb.url;
        if (pick == null) {
          // None anywhere: don't ask again this session. A failed fallback
          // lookup is retried soon instead.
          _logoMiss[id] = DateTime.now()
              .add(fb.failed ? const Duration(seconds: 15) : const Duration(hours: 12));
          return null;
        }
      }
      _logos[id] = pick;
      VirtualImages.register(id, logo: pick);
      return VirtualImages.urlFor(id, 'Logo', maxWidth: 700);
    } catch (e) {
      _logoMiss[id] = DateTime.now().add(const Duration(seconds: 15));
      debugPrint('[VirtualCatalog] logo lookup failed: $e');
      return null;
    }
  }
  static final Map<String, String> _certs = {}; // item id -> "PG-13"

  /// Age rating learned from a detail call ("PG-13"), or null.
  static String? certificationFor(String itemId) => _certs[itemId];

  // ---------- parsing TMDB list results ----------

  static List<CatalogTitle> _parseList(
    Map<String, dynamic>? data,
    CatalogType type,
  ) {
    final results = data?['results'];
    if (results is! List) return const [];
    final out = <CatalogTitle>[];
    for (final r in results.whereType<Map>()) {
      final m = Map<String, dynamic>.from(r);
      if (m['id'] is! num) continue;
      if (m['poster_path'] == null) continue;
      out.add(CatalogTitle.fromTmdb(m, type: type));
    }
    return out;
  }

  /// One page of /discover.
  static Future<List<CatalogTitle>> _discoverPage(
    CatalogType type, {
    int page = 1,
    int? genre,
    String? keywords,
    int? company,
    String? companies,
    String? language,
    String sortBy = 'popularity.desc',
    int minVotes = 50,
    double? minRating,
    bool releasedOnly = false,
  }) async {
    final isMovie = type == CatalogType.movie;
    final query = <String, dynamic>{
      'sort_by': sortBy,
      'page': page,
      'vote_count.gte': minVotes,
      if (genre != null) 'with_genres': _genreFor(type, genre),
      if (keywords != null && keywords.isNotEmpty) 'with_keywords': keywords,
      // A genre chip should hold that kind of title: no documentaries or
      // TV movies under Comedy / Thriller / ..., no talk or news shows
      // under TV Comedy / Drama / ... (the Documentary chip keeps its own).
      if (genre != null && genre != 99)
        'without_genres': isMovie ? '99,10770' : '10763,10767',
      if (company != null)
        'with_companies': company
      else if (companies != null)
        'with_companies': companies,
      if (language != null) 'with_original_language': language,
      if (minRating != null) 'vote_average.gte': minRating,
    };
    if (releasedOnly) {
      final dateKey =
          isMovie ? 'primary_release_date.lte' : 'first_air_date.lte';
      query[dateKey] = _today();
    }
    final ceiling = isMovie ? _movieCeiling : null;
    if (ceiling != null) {
      query['certification_country'] = 'US';
      query['certification.lte'] = ceiling;
    }
    final data = await TmdbCatalogService.raw(
        '/discover/${type.tmdb}', query);
    final parsed = _parseList(data, type);
    // TMDB has no Romance genre for TV. If asking for it finds nothing, fall
    // back to romantic-comedy tagged shows rather than an empty chip.
    if (parsed.isEmpty &&
        !isMovie &&
        genre == 10749 &&
        keywords == null &&
        page == 1) {
      final alt = Map<String, dynamic>.from(query)
        ..remove('with_genres')
        ..['with_keywords'] = '9799';
      return _parseList(
          await TmdbCatalogService.raw('/discover/tv', alt), type);
    }
    return parsed;
  }

  /// Several pages, fetched a few at a time, de-duplicated.
  static Future<List<CatalogTitle>> _discoverMany(
    CatalogType type, {
    required int pages,
    int? genre,
    String? keywords,
    int? company,
    String? companies,
    String? language,
    String sortBy = 'popularity.desc',
    int minVotes = 50,
    double? minRating,
    bool releasedOnly = false,
    String? split,
  }) async {
    final seen = <int>{};
    final out = <CatalogTitle>[];
    const chunk = 10;
    for (var start = 1; start <= pages; start += chunk) {
      final end = (start + chunk - 1) > pages ? pages : (start + chunk - 1);
      final batch = await Future.wait([
        for (var p = start; p <= end; p++)
          _discoverPage(
            type,
            page: p,
            genre: genre,
            keywords: keywords,
            company: company,
            companies: companies,
            language: language,
            sortBy: sortBy,
            minVotes: minVotes,
            minRating: minRating,
            releasedOnly: releasedOnly,
          ),
      ]);
      var any = false;
      for (final list in batch) {
        // `any` looks at the raw page, before the split filter, so a page
        // whose titles all fall on the other chip does not end the paging.
        if (list.isNotEmpty) any = true;
        for (final t in list) {
          if (!_matchesSplit(t, split)) continue;
          if (seen.add(t.tmdbId)) out.add(t);
        }
      }
      if (!any) break;
    }
    return out;
  }

  // ---------- item JSON ----------

  static Map<String, dynamic> _userData(CatalogTitle t) {
    final h = WatchHistoryService.instance;
    final entry = h.entryFor(t);
    final isMovie = t.type == CatalogType.movie;
    final finished = isMovie && entry != null && entry.finished;
    final ticks = (isMovie && entry != null && !entry.finished)
        ? _ticksFromMs(entry.positionMs)
        : 0;
    return {
      'IsFavorite': h.isInWatchlist(t),
      'Played': finished,
      'PlayCount': finished ? 1 : 0,
      'PlaybackPositionTicks': ticks,
      'Key': '${t.type.tmdb}:${t.tmdbId}',
    };
  }

  /// The JSON for a movie or series. [people] and [studios] are only supplied
  /// for the full detail record.
  static Map<String, dynamic> titleToItem(
    CatalogTitle t, {
    List<Map<String, dynamic>>? people,
    List<Map<String, dynamic>>? studios,
    int? childCount,
    List<String>? tags,
  }) {
    final isMovie = t.type == CatalogType.movie;
    final id = isMovie ? VId.movieOf(t.tmdbId) : VId.seriesOf(t.tmdbId);

    VirtualImages.register(
      id,
      primary: t.posterPath,
      backdrop: t.backdropPath,
      logo: _logos[id],
    );

    final genres = t.genres.isNotEmpty
        ? t.genres
        : t.genreIds
            .map((g) => _genreNames[g])
            .whereType<String>()
            .toList();

    final cert = _certs[id];
    final year = t.year;

    return {
      'Id': id,
      'ServerId': serverId,
      'Name': t.title,
      'OriginalTitle': t.title,
      'SortName': t.title.toLowerCase(),
      'Type': _typeName(t.type),
      'MediaType': 'Video',
      'IsFolder': !isMovie,
      'LocationType': 'FileSystem',
      'Overview': t.overview,
      if (year != null) 'ProductionYear': year,
      if (_premiere(t.releaseDate) != null)
        'PremiereDate': _premiere(t.releaseDate),
      if (t.rating > 0) 'CommunityRating': t.rating,
      if (cert != null && cert.isNotEmpty) 'OfficialRating': cert,
      'RunTimeTicks': _ticksFromMinutes(t.runtime),
      'Genres': genres,
      'GenreItems': [
        for (final g in genres) {'Name': g, 'Id': 'g_$g'},
      ],
      'ProviderIds': {
        'Tmdb': t.tmdbId.toString(),
        if (t.imdbId != null && t.imdbId!.isNotEmpty) 'Imdb': t.imdbId,
      },
      'ImageTags': {
        if (t.posterPath != null) 'Primary': 'p',
        if (t.backdropPath != null) 'Thumb': 'b',
        if (_hasLogo(id)) 'Logo': 'l',
      },
      'BackdropImageTags': [if (t.backdropPath != null) 'b'],
      'PrimaryImageAspectRatio': 0.6666666667,
      'Taglines': [if (t.tagline.isNotEmpty) t.tagline],
      // TMDB keywords of the title (only known after a details call), shown
      // as the "Tags:" line under the overview.
      'Tags': tags ?? const <String>[],
      'Studios': studios ?? const <Map<String, dynamic>>[],
      'People': people ?? const <Map<String, dynamic>>[],
      'MediaSources': const <Map<String, dynamic>>[],
      'MediaStreams': const <Map<String, dynamic>>[],
      if (t.status != null) 'Status': t.status,
      if (!isMovie) 'ChildCount': childCount ?? _seasonCount(t),
      'UserData': _userData(t),
      'NamesisVirtual': true,
    };
  }

  static int _seasonCount(CatalogTitle t) =>
      t.seasons.where((s) => s.number > 0).length;

  // ---------- details ----------

  static Future<_Detail?> _detail(CatalogType type, int id) async {
    final data = await TmdbCatalogService.raw('/${type.tmdb}/$id', {
      'append_to_response': type == CatalogType.movie
          ? 'external_ids,credits,images,release_dates,similar,keywords'
          : 'external_ids,credits,images,content_ratings,similar,keywords',
      'include_image_language': 'en,null',
    });
    if (data == null || data['id'] is! num) return null;

    final title = CatalogTitle.fromTmdb(data, type: type);
    final itemId = type == CatalogType.movie ? VId.movieOf(id) : VId.seriesOf(id);

    // Logo: English first, then none-language, then any other (never SVG).
    final logos = (data['images'] is Map) ? data['images']['logos'] : null;
    final picked = _bestLogo(logos);
    if (picked != null) {
      _logos[itemId] = picked;
      VirtualImages.register(itemId, logo: picked);
    } else if (!_hasLogo(itemId)) {
      // The detail call only asked for English / no-language logos; this
      // title may have one in another language.
      await ensureLogo(itemId).timeout(const Duration(seconds: 5),
          onTimeout: () => null);
    }

    // US age rating.
    String? cert;
    if (type == CatalogType.movie) {
      final rd = (data['release_dates'] is Map)
          ? data['release_dates']['results']
          : null;
      if (rd is List) {
        for (final c in rd.whereType<Map>()) {
          if (c['iso_3166_1'] != 'US') continue;
          final dates = c['release_dates'];
          if (dates is List) {
            for (final d in dates.whereType<Map>()) {
              final v = (d['certification'] ?? '').toString();
              if (v.isNotEmpty) {
                cert = v;
                break;
              }
            }
          }
        }
      }
    } else {
      final cr = (data['content_ratings'] is Map)
          ? data['content_ratings']['results']
          : null;
      if (cr is List) {
        for (final c in cr.whereType<Map>()) {
          if (c['iso_3166_1'] == 'US') {
            final v = (c['rating'] ?? '').toString();
            if (v.isNotEmpty) cert = v;
          }
        }
      }
    }
    if (cert != null) {
      _certs[itemId] = cert;
      RatingResolver.instance.remember(itemId, cert);
    }

    // People.
    final people = <Map<String, dynamic>>[];
    final credits = data['credits'];
    if (credits is Map) {
      final cast = credits['cast'];
      if (cast is List) {
        for (final c in cast.whereType<Map>().take(20)) {
          final pid = (c['id'] as num?)?.toInt();
          if (pid == null) continue;
          final personId = 'p$pid';
          VirtualImages.register(personId,
              primary: c['profile_path'] as String?, kind: 'profile');
          people.add({
            'Id': personId,
            'Name': (c['name'] ?? '').toString(),
            'Role': (c['character'] ?? '').toString(),
            'Type': 'Actor',
            if (c['profile_path'] != null) 'PrimaryImageTag': 'x',
          });
        }
      }
      final crew = credits['crew'];
      if (crew is List) {
        final seen = <String>{};
        for (final c in crew.whereType<Map>()) {
          final pid = (c['id'] as num?)?.toInt();
          if (pid == null) continue;
          final role = _crewType((c['job'] ?? '').toString());
          if (role == null) continue;
          if (!seen.add('$pid:$role')) continue;
          if (seen.length > 8) break;
          final personId = 'p$pid';
          VirtualImages.register(personId,
              primary: c['profile_path'] as String?, kind: 'profile');
          people.add({
            'Id': personId,
            'Name': (c['name'] ?? '').toString(),
            'Role': (c['job'] ?? '').toString(),
            'Type': role,
            if (c['profile_path'] != null) 'PrimaryImageTag': 'x',
          });
        }
      }
    }

    // Studios / networks.
    final studios = <Map<String, dynamic>>[];
    final companies = data['production_companies'];
    if (companies is List) {
      for (final c in companies.whereType<Map>()) {
        final name = (c['name'] ?? '').toString();
        if (name.isEmpty) continue;
        studios.add({'Name': name, 'Id': (c['id'] ?? '').toString()});
      }
    }

    // The collection (franchise) a movie belongs to, if any. Remembered so
    // the "In this collection" row can find it without another request.
    if (type == CatalogType.movie) {
      final bc = data['belongs_to_collection'];
      _movieCollections[itemId] =
          (bc is Map && bc['id'] is num) ? Map<String, dynamic>.from(bc) : null;
    }

    return _Detail(title, people, studios, _readTags(data));
  }

  // ---------- tags (TMDB keywords) ----------

  /// Most tags shown under one title's overview.
  static const int _maxTags = 15;

  /// Lower-cased keyword name -> TMDB keyword id, learned from details calls
  /// so tapping a tag can search by id without another lookup.
  static final Map<String, int> _keywordIds = {};

  /// The title's TMDB keywords as display names ("Heist"), remembering each
  /// one's id. A movie's keywords come back under `keywords.keywords`, a
  /// show's under `keywords.results`.
  static List<String> _readTags(Map<String, dynamic> data) {
    final kw = data['keywords'];
    if (kw is! Map) return const [];
    final raw = kw['keywords'] ?? kw['results'];
    if (raw is! List) return const [];
    final out = <String>[];
    final seen = <String>{};
    for (final k in raw.whereType<Map>()) {
      final name = (k['name'] ?? '').toString().trim();
      final id = (k['id'] as num?)?.toInt();
      if (name.isEmpty || id == null) continue;
      final lower = name.toLowerCase();
      if (!seen.add(lower)) continue;
      _keywordIds[lower] = id;
      out.add(name[0].toUpperCase() + name.substring(1));
      if (out.length >= _maxTags) break;
    }
    return out;
  }

  /// TMDB keyword id behind a tag name, or null when there is none. Uses
  /// what details calls taught us, else asks TMDB's keyword search (needed
  /// after a restart, when the detail screen came from cache) and only
  /// accepts an exact name match.
  static Future<int?> _keywordIdFor(String tag) async {
    final name = tag.trim().toLowerCase();
    if (name.isEmpty) return null;
    final known = _keywordIds[name];
    if (known != null) return known;

    final data =
        await TmdbCatalogService.raw('/search/keyword', {'query': name});
    final results = data?['results'];
    if (results is! List) return null;
    for (final r in results.whereType<Map>()) {
      final rn = (r['name'] ?? '').toString().trim().toLowerCase();
      final id = (r['id'] as num?)?.toInt();
      if (id != null && rn == name) {
        _keywordIds[name] = id;
        return id;
      }
    }
    return null;
  }

  static String? _crewType(String job) {
    final j = job.toLowerCase();
    if (j == 'director') return 'Director';
    if (j == 'screenplay' || j == 'writer' || j == 'story') return 'Writer';
    if (j == 'producer' || j == 'executive producer') return 'Producer';
    if (j.contains('composer')) return 'Composer';
    return null;
  }

  /// Full item for a movie or series, or null if TMDB has no such title.
  static Future<Map<String, dynamic>?> _fullTitle(
      CatalogType type, int id) async {
    final d = await _detail(type, id);
    if (d == null) return null;
    return titleToItem(d.title,
        people: d.people, studios: d.studios, tags: d.tags);
  }

  // ---------- public: single item ----------

  static Future<Map<String, dynamic>?> item(String id) async {
    // Parental Controls: a blocked title cannot be opened at all.
    final decision = await ParentalControls.instance.checkId(id);
    if (!decision.allowed) throw ParentalBlockedException(decision);

    final v = VId.parse(id);
    switch (v.kind) {
      case 'movie':
        return _fullTitle(CatalogType.movie, v.tmdbId);
      case 'series':
        return _fullTitle(CatalogType.series, v.tmdbId);
      case 'season':
        final seasons = await seasonsOf(VId.seriesOf(v.tmdbId));
        for (final s in seasons) {
          if (s['Id'] == id) return s;
        }
        return null;
      case 'episode':
        final eps = await episodesOf(
            VId.seriesOf(v.tmdbId), VId.seasonOf(v.tmdbId, v.season!));
        for (final e in eps) {
          if (e['Id'] == id) return e;
        }
        return null;
      case 'library':
        final lib = libraryById(id);
        return lib == null ? null : _libraryItem(lib);
      case 'collection':
        final d = await _collectionDetail(v.tmdbId);
        if (d == null) return null;
        if ((await filterCollectionMaps([d])).isEmpty) {
          throw ParentalBlockedException(const Decision.block(
            BlockReason.maturity,
            "This collection isn't available with your Parental Controls.",
          ));
        }
        return _collectionItemFromDetail(d);
      case 'person':
        return _personItem(id, v.tmdbId);
    }
    return null;
  }

  /// NAMESIS PRIME: a cast / crew member's own record, from TMDB
  /// `/person/{id}`: name, biography (Overview), birth date (PremiereDate),
  /// death date (EndDate), birthplace (ProductionLocations) and photo.
  ///
  /// The Cast & Crew screen asks for exactly these fields. This used to
  /// return an empty stub (blank name, no biography), so the biography only
  /// ever showed when the tapped card happened to carry a TMDB id from a
  /// separate lookup - which made it appear and vanish from person to person.
  /// Goes through TmdbCatalogService, so it has the same retries and the same
  /// memory + disk cache as every other TMDB call; a failed call still
  /// returns a usable record (name from favorites, if known) instead of
  /// throwing.
  static Future<Map<String, dynamic>> _personItem(String id, int tmdbId) async {
    await _loadFavPeople();
    final fav = _favPeople[id];

    Map<String, dynamic>? d;
    try {
      d = await TmdbCatalogService.raw('/person/$tmdbId');
    } catch (e) {
      debugPrint('[VirtualCatalog] person $tmdbId failed: $e');
    }

    String text(String key) => (d?[key] ?? '').toString().trim();

    final tmdbName = text('name');
    final name =
        tmdbName.isNotEmpty ? tmdbName : (fav?['Name'] ?? '').toString();
    final tmdbProfile = d?['profile_path'];
    final favProfile = fav?['Profile'];
    final profile = (tmdbProfile is String && tmdbProfile.isNotEmpty)
        ? tmdbProfile
        : (favProfile is String && favProfile.isNotEmpty ? favProfile : null);
    if (profile != null) {
      VirtualImages.register(id, primary: profile, kind: 'profile');
    }

    final bio = text('biography');
    final birthday = text('birthday');
    final deathday = text('deathday');
    final place = text('place_of_birth');

    return {
      'Id': id,
      'Name': name,
      'Type': 'Person',
      'ServerId': serverId,
      if (bio.isNotEmpty) 'Overview': bio,
      if (birthday.isNotEmpty) 'PremiereDate': birthday,
      if (deathday.isNotEmpty) 'EndDate': deathday,
      if (place.isNotEmpty) 'ProductionLocations': [place],
      'ImageTags': {if (profile != null) 'Primary': 'x'},
      'UserData': {'IsFavorite': fav != null},
    };
  }

  // ---------- libraries ----------

  static Map<String, dynamic> _libraryItem(VLibrary lib) => {
        'Id': lib.id,
        'ServerId': serverId,
        'Name': lib.name,
        'Type': 'CollectionFolder',
        'CollectionType': lib.collectionType,
        'IsFolder': true,
        'ImageTags': {'Primary': 'l'},
      };

  /// The library list, with a landscape picture for each card. Each card's
  /// picture is a different, popular and highly rated movie, and the whole
  /// set changes once a week (see [_assignWeeklyArt]).
  static Future<List<Map<String, dynamic>>> views() async {
    final libs = libraries;
    // The cards should not wait for a slow lookup: whatever picture a card
    // had last week shows at once, and the new week's set replaces it as
    // soon as it is ready.
    await Future.wait([
      _assignWeeklyArt(libs)
          .timeout(const Duration(seconds: 8), onTimeout: () {}),
      _assignCollectionsArt()
          .timeout(const Duration(seconds: 8), onTimeout: () {}),
    ]);
    return [for (final lib in libs) _libraryItem(lib)];
  }

  static const String _artWeekKey = 'vc_art_week2';
  static const String _artMapKey = 'vc_art_map2';
  static const String _artHistKey = 'vc_art_hist2';
  static Future<void>? _artRunning;

  /// Whole weeks since a fixed Monday; changes every 7 days.
  static int _weekNumber() => DateTime.now()
      .toUtc()
      .difference(DateTime.utc(2024, 1, 1))
      .inDays ~/
      7;

  static Future<void> _assignWeeklyArt(List<VLibrary> libs) {
    // One run at a time (the home screen and the Movies screens all call
    // views()); later callers wait for the same run.
    return _artRunning ??= _doAssignWeeklyArt(libs).whenComplete(() {
      _artRunning = null;
    });
  }

  /// Popular, well rated movies of [lib]'s own genre / keywords (the genre
  /// the card is named after), best first. Titles whose FIRST listed genre is
  /// the card's genre come before titles that merely include it, so the
  /// Comedy card gets a comedy, not an action film with a joke in it.
  static Future<List<CatalogTitle>> _artCandidates(VLibrary lib) async {
    Future<List<CatalogTitle>> page(int p, int votes, double rating) =>
        _discoverPage(
          CatalogType.movie,
          page: p,
          genre: lib.genreId,
          keywords: lib.keywords,
          companies: lib.companies,
          language: lib.language,
          sortBy: 'popularity.desc',
          minVotes: votes,
          minRating: rating,
          releasedOnly: true,
        ).catchError((_) => <CatalogTitle>[]);

    var found = (await Future.wait([
      page(1, 2000, 7.0),
      page(2, 2000, 7.0),
      page(3, 2000, 7.0),
    ]))
        .expand((l) => l)
        .where((t) => t.backdropPath != null)
        .toList();

    // Small categories (Documentary, Sports, ...) have few titles that
    // strong; relax the bar rather than leave the card empty.
    if (found.length < 8) {
      found = (await Future.wait([
        page(1, 300, 6.5),
        page(2, 300, 6.5),
      ]))
          .expand((l) => l)
          .where((t) => t.backdropPath != null)
          .toList();
    }

    found = await ParentalControls.instance
        .filterTitles(found, ratingChecked: _movieCeiling != null);

    final g = lib.genreId;
    if (g == null) return found;
    final primary = [
      for (final t in found)
        if (t.genreIds.isNotEmpty && t.genreIds.first == g) t,
    ];
    final rest = [
      for (final t in found)
        if (!(t.genreIds.isNotEmpty && t.genreIds.first == g)) t,
    ];
    return [...primary, ...rest];
  }

  static Future<void> _doAssignWeeklyArt(List<VLibrary> allLibs) async {
    // Only the movie cards of the home row show a picture (the TV Shows
    // chips are text).
    final libs = [for (final l in allLibs) if (l.collectionType == 'movies') l];
    try {
      final prefs = await SharedPreferences.getInstance();
      final week = _weekNumber();

      Map<String, String> stored = {};
      try {
        final raw = prefs.getString(_artMapKey);
        if (raw != null) {
          stored = {
            for (final e in (jsonDecode(raw) as Map).entries)
              e.key.toString(): e.value.toString(),
          };
        }
      } catch (_) {
        stored = {};
      }

      // Show what we have right away.
      for (final lib in libs) {
        final b = stored[lib.id];
        if (b != null) {
          VirtualImages.register(lib.id, primary: b, kind: 'backdrop');
        }
      }

      final complete = libs.every((l) => stored.containsKey(l.id)) &&
          stored.values.toSet().length == stored.length;
      if (prefs.getInt(_artWeekKey) == week && complete) return;

      // Each card's own pool, fetched together.
      final pools = await Future.wait([for (final l in libs) _artCandidates(l)]);

      var history = <String>[];
      try {
        history = List<String>.from(prefs.getStringList(_artHistKey) ?? []);
      } catch (_) {}
      final recent = history.toSet();

      final rng = math.Random(week * 7919 + 13);
      final usedArt = <String>{};
      final usedIds = <int>{};
      final next = <String, String>{};

      // Small pools first, so a category with few good titles is not left
      // with nothing after the big ones took theirs.
      final order = List<int>.generate(libs.length, (i) => i)
        ..sort((a, b) => pools[a].length.compareTo(pools[b].length));

      for (final i in order) {
        final pool = pools[i];
        List<CatalogTitle> avail(bool avoidRecent) => [
              for (final t in pool)
                if (!usedArt.contains(t.backdropPath) &&
                    !usedIds.contains(t.tmdbId) &&
                    (!avoidRecent || !recent.contains(t.backdropPath)))
                  t,
            ];
        var cands = avail(true);
        if (cands.isEmpty) cands = avail(false);
        if (cands.isEmpty) continue; // no honest picture: keep the old one
        // Random among the best few, so it differs week to week.
        final pick = cands[rng.nextInt(math.min(8, cands.length))];
        usedArt.add(pick.backdropPath!);
        usedIds.add(pick.tmdbId);
        next[libs[i].id] = pick.backdropPath!;
      }

      if (next.isEmpty) return; // offline: try again next launch

      final merged = {...stored, ...next};
      // A card that kept an older picture must not share it with a new one.
      merged.removeWhere(
          (k, v) => !next.containsKey(k) && next.values.contains(v));
      for (final e in next.entries) {
        VirtualImages.register(e.key, primary: e.value, kind: 'backdrop');
      }
      await prefs.setString(_artMapKey, jsonEncode(merged));
      // Only a complete set counts as this week's; otherwise try again.
      if (libs.every((l) => next.containsKey(l.id))) {
        await prefs.setInt(_artWeekKey, week);
      }
      final newHist = [...next.values, ...history];
      await prefs.setStringList(
          _artHistKey, newHist.take(libs.length * 4).toList());
    } catch (e) {
      debugPrint('[VirtualCatalog] weekly library art failed: $e');
    }
  }

  // ---------- home: featured / latest / resume ----------

  /// Trending movies and shows mixed with what is in cinemas now. Each is
  /// fetched in full so the hero has its logo, genres, runtime, age rating
  /// and IMDb id (which the ratings row needs).
  static Future<List<Map<String, dynamic>>> featured(int limit) async {
    final pc = ParentalControls.instance;
    if (pc.contentFilterActive) {
      // Recent, popular titles that the rules allow (see _safeHeroPicks).
      return _fullItems(await _safeHeroPicks(limit));
    }
    final picked = limit >= 10
        ? await _heroPicks(limit)
        : await _mixedPicks(limit);
    return _fullItems(picked);
  }

  /// The home hero while Parental Controls are filtering content: RECENT,
  /// POPULAR movies and shows only, none of them blocked (title, genre,
  /// word or age-limit rules all apply - the pool is drawn wide so the hero
  /// is still full after they have removed what they block).
  ///
  /// Popular = TMDB's trending lists first, then what is in cinemas / on
  /// air now, then the current popular lists. Movies must also be from the
  /// last three years. Mix: 6 movies + 4 shows for a 10-title hero, shown
  /// alternating.
  static Future<List<CatalogTitle>> _safeHeroPicks(int limit) async {
    final pc = ParentalControls.instance;

    Future<List<CatalogTitle>> safe(Future<List<CatalogTitle>> f) =>
        f.catchError((_) => <CatalogTitle>[]);

    final r = await Future.wait([
      safe(TmdbCatalogService.trending(CatalogType.movie)),
      safe(TmdbCatalogService.trending(CatalogType.movie, page: 2)),
      safe(TmdbCatalogService.trending(CatalogType.movie, page: 3)),
      safe(TmdbCatalogService.newReleases(CatalogType.movie)),
      safe(TmdbCatalogService.newReleases(CatalogType.movie, page: 2)),
      safe(TmdbCatalogService.popular(CatalogType.movie)),
      safe(TmdbCatalogService.popular(CatalogType.movie, page: 2)),
      safe(TmdbCatalogService.trending(CatalogType.series)),
      safe(TmdbCatalogService.trending(CatalogType.series, page: 2)),
      safe(TmdbCatalogService.trending(CatalogType.series, page: 3)),
      safe(TmdbCatalogService.newReleases(CatalogType.series)),
      safe(TmdbCatalogService.popular(CatalogType.series)),
      safe(TmdbCatalogService.popular(CatalogType.series, page: 2)),
    ]);

    final since = DateTime.now().year - 3;
    List<CatalogTitle> pool(List<List<CatalogTitle>> lists,
        {required bool recentOnly, required int cap}) {
      final seen = <int>{};
      final out = <CatalogTitle>[];
      for (final list in lists) {
        for (final t in list) {
          if (t.backdropPath == null) continue;
          if (recentOnly && (t.year ?? 0) < since) continue;
          if (seen.add(t.tmdbId)) out.add(t);
        }
      }
      return out.take(cap).toList();
    }

    final movieWant = (limit * 0.6).round();
    final showWant = limit - movieWant;

    final results = await Future.wait([
      pc.filterTitles(pool(r.sublist(0, 7), recentOnly: true, cap: 45)),
      pc.filterTitles(pool(r.sublist(7), recentOnly: false, cap: 35)),
    ]);
    final movies = results[0];
    final shows = results[1];

    // Alternate movies and shows through the carousel.
    final order = <CatalogTitle>[];
    final m = movies.take(movieWant).toList();
    final s = shows.take(showWant).toList();
    var mi = 0, si = 0;
    const showSlots = {1, 4, 6, 9};
    for (var slot = 0; mi < m.length || si < s.length; slot++) {
      final wantShow = showSlots.contains(slot);
      if ((wantShow && si < s.length) || mi >= m.length) {
        order.add(s[si++]);
      } else {
        order.add(m[mi++]);
      }
    }
    // Not enough of one kind survived the rules: top up with the other.
    for (final t in [...movies.skip(movieWant), ...shows.skip(showWant)]) {
      if (order.length >= limit) break;
      order.add(t);
    }
    return order.take(limit).toList();
  }

  static Future<List<CatalogTitle>> _mixedPicks(int limit) async {
    final lists = await Future.wait([
      TmdbCatalogService.trending(CatalogType.movie, window: 'day'),
      TmdbCatalogService.trending(CatalogType.series, window: 'day'),
      TmdbCatalogService.newReleases(CatalogType.movie),
    ]);

    final picked = <CatalogTitle>[];
    final seen = <String>{};
    final longest = lists.fold<int>(0, (m, l) => l.length > m ? l.length : m);
    for (var i = 0; i < longest && picked.length < limit; i++) {
      for (final l in lists) {
        if (i >= l.length || picked.length >= limit) continue;
        final t = l[i];
        if (t.backdropPath == null) continue;
        if (seen.add('${t.type.tmdb}:${t.tmdbId}')) picked.add(t);
      }
    }
    return picked;
  }

  /// The home hero: 10 titles = 6 movies (4 trending now and well rated,
  /// 2 of the best of all time, picked at random) + 4 shows (3 trending
  /// now and well rated, 1 of the best of all time, picked at random).
  static Future<List<CatalogTitle>> _heroPicks(int limit) async {
    final r = await Future.wait([
      TmdbCatalogService.trending(CatalogType.movie),
      TmdbCatalogService.trending(CatalogType.movie, page: 2),
      TmdbCatalogService.trending(CatalogType.series),
      TmdbCatalogService.trending(CatalogType.series, page: 2),
      TmdbCatalogService.topRated(CatalogType.movie),
      TmdbCatalogService.topRated(CatalogType.movie, page: 2),
      TmdbCatalogService.topRated(CatalogType.movie, page: 3),
      TmdbCatalogService.topRated(CatalogType.series),
      TmdbCatalogService.topRated(CatalogType.series, page: 2),
      TmdbCatalogService.topRated(CatalogType.series, page: 3),
    ].map((f) => f.catchError((_) => <CatalogTitle>[])));

    final trendMovies = [...r[0], ...r[1]];
    final trendShows = [...r[2], ...r[3]];
    final bestMovies = [...r[4], ...r[5], ...r[6]];
    final bestShows = [...r[7], ...r[8], ...r[9]];

    final rng = math.Random();
    final used = <String>{};
    String key(CatalogTitle t) => '${t.type.tmdb}:${t.tmdbId}';

    /// The first [n] of [list] (already in trending order) that are well
    /// rated, relaxing the bar if there are not enough.
    List<CatalogTitle> trending(
        List<CatalogTitle> list, int n, List<double> bars) {
      final out = <CatalogTitle>[];
      for (final bar in bars) {
        for (final t in list) {
          if (out.length >= n) break;
          if (t.backdropPath == null || t.rating < bar) continue;
          if (used.contains(key(t))) continue;
          used.add(key(t));
          out.add(t);
        }
        if (out.length >= n) break;
      }
      return out;
    }

    List<CatalogTitle> classics(List<CatalogTitle> list, int n) {
      final pool = list
          .where((t) => t.backdropPath != null && !used.contains(key(t)))
          .toList()
        ..shuffle(rng);
      final out = pool.take(n).toList();
      for (final t in out) {
        used.add(key(t));
      }
      return out;
    }

    final tm = trending(trendMovies, 4, const [6.8, 6.0, 0]);
    final ts = trending(trendShows, 3, const [7.0, 6.0, 0]);
    final cm = classics(bestMovies, 2);
    final cs = classics(bestShows, 1);

    // Interleaved so movies and shows alternate through the carousel.
    final order = <CatalogTitle>[];
    final movies = [...tm, ...cm];
    final shows = [...ts, ...cs];
    var mi = 0, si = 0;
    const showSlots = {1, 4, 6, 9};
    for (var slot = 0; mi < movies.length || si < shows.length; slot++) {
      final wantShow = showSlots.contains(slot);
      if ((wantShow && si < shows.length) || mi >= movies.length) {
        order.add(shows[si++]);
      } else {
        order.add(movies[mi++]);
      }
    }
    return order.take(limit).toList();
  }

  static Future<List<Map<String, dynamic>>> _fullItems(
      List<CatalogTitle> picked) async {

    final items = await Future.wait(picked.map((t) async {
      try {
        var d = await _detail(t.type, t.tmdbId);
        // One more try: a single dropped request used to leave this hero
        // card without its logo for good.
        d ??= await _detail(t.type, t.tmdbId);
        if (d != null) {
          return titleToItem(d.title,
              people: d.people, studios: d.studios, tags: d.tags);
        }
      } catch (e) {
        debugPrint('[VirtualCatalog] featured detail failed: $e');
      }
      final id = t.type == CatalogType.movie
          ? VId.movieOf(t.tmdbId)
          : VId.seriesOf(t.tmdbId);
      await ensureLogo(id).timeout(const Duration(seconds: 5),
          onTimeout: () => null);
      return titleToItem(t);
    }));
    return items;
  }

  /// "Recently released, highly rated" for one library (or everything).
  static Future<List<Map<String, dynamic>>> latest(
    String? parentId,
    int limit,
  ) async {
    final lib = libraryById(parentId);
    final type = lib?.type ?? CatalogType.movie;
    // With a filter on, ask for more pages so the row is still full.
    final widen = ParentalControls.instance.contentFilterActive ? 3 : 1;
    var titles = await _discoverMany(
      type,
      pages: _clampInt((limit + 19) ~/ 20, 1, 3) * widen,
      genre: lib?.genreId,
      keywords: lib?.keywords,
      companies: lib?.companies,
      language: lib?.language,
      split: lib?.split,
      sortBy: type == CatalogType.movie
          ? 'primary_release_date.desc'
          : 'first_air_date.desc',
      minVotes: type == CatalogType.movie ? 80 : 40,
      minRating: 6.5,
      releasedOnly: true,
    );
    titles = await ParentalControls.instance
        .filterTitles(titles, ratingChecked: _movieCeiling != null);
    return titles.take(limit).map((t) => titleToItem(t)).toList();
  }

  /// Continue Watching, from this device's own history.
  static Future<List<Map<String, dynamic>>> resume(int limit) async {
    final out = <Map<String, dynamic>>[];
    // Every in-progress title, newest first. The cap is applied only AFTER
    // Parental Controls, so a hidden title never leaves the row short while
    // older stored ones could have filled it.
    final entries = WatchHistoryService.instance.allContinueWatching;
    final pc = ParentalControls.instance;

    if (!pc.contentFilterActive) {
      for (final e in entries.take(limit)) {
        out.add(_entryToItem(e));
      }
      return out;
    }

    // Filter in chunks (ratings/genres may need lookups) and stop as soon as
    // the row is full.
    const chunk = 30;
    for (var i = 0; i < entries.length && out.length < limit; i += chunk) {
      final part = entries.skip(i).take(chunk).toList();
      final ok = await pc.filterTitles([for (final e in part) e.title.toTitle()]);
      final allowed = {for (final t in ok) ParentalControls.idOfTitle(t)};
      for (final e in part) {
        if (!allowed.contains(ParentalControls.idOfTitle(e.title.toTitle()))) {
          continue;
        }
        out.add(_entryToItem(e));
        if (out.length >= limit) break;
      }
    }
    return out;
  }

  static Map<String, dynamic> _entryToItem(WatchEntry e) {
    final t = e.title.toTitle();
    final base = titleToItem(t);
    if (!e.isEpisode) {
      final ud = Map<String, dynamic>.from(base['UserData'] as Map);
      if (e.durationMs > 0) base['RunTimeTicks'] = _ticksFromMs(e.durationMs);
      ud['PlaybackPositionTicks'] = e.upNext ? 0 : _ticksFromMs(e.positionMs);
      base['UserData'] = ud;
      return base;
    }

    final season = e.season!;
    final number = e.episode!;
    final epId = VId.episodeOf(t.tmdbId, season, number);
    VirtualImages.register(epId,
        primary: e.episodeStillPath, backdrop: t.backdropPath, kind: 'still');

    final runtimeTicks = e.durationMs > 0
        ? _ticksFromMs(e.durationMs)
        : _ticksFromMinutes(e.episodeRuntime ?? t.runtime);

    return {
      'Id': epId,
      'ServerId': serverId,
      'Name': e.episodeName ?? 'Episode $number',
      'Type': 'Episode',
      'MediaType': 'Video',
      'IsFolder': false,
      'LocationType': 'FileSystem',
      'SeriesId': VId.seriesOf(t.tmdbId),
      'SeriesName': t.title,
      'SeasonId': VId.seasonOf(t.tmdbId, season),
      'ParentIndexNumber': season,
      'IndexNumber': number,
      'RunTimeTicks': runtimeTicks,
      'ProviderIds': const <String, String>{},
      'ImageTags': {if (e.episodeStillPath != null) 'Primary': 'e'},
      'BackdropImageTags': [if (t.backdropPath != null) 'b'],
      'ParentBackdropItemId': VId.seriesOf(t.tmdbId),
      'UserData': {
        'IsFavorite': false,
        'Played': false,
        'PlaybackPositionTicks': e.upNext ? 0 : _ticksFromMs(e.positionMs),
      },
      'NamesisVirtual': true,
    };
  }

  /// Drops a title from Continue Watching.
  static Future<void> removeFromResume(String itemId) async {
    final v = VId.parse(itemId);
    if (v.kind != 'movie' && v.kind != 'episode' && v.kind != 'series') return;
    final key = v.kind == 'movie'
        ? 'movie:${v.tmdbId}'
        : 'tv:${v.tmdbId}';
    final h = WatchHistoryService.instance;
    for (final e in h.allContinueWatching) {
      if (e.key == key) {
        await h.removeFromContinue(e);
        return;
      }
    }
  }

  // ---------- collections (TMDB movie collections as BoxSets) ----------

  /// Movie id -> the collection it belongs to (TMDB `belongs_to_collection`,
  /// null when it is in none). Filled by [_detail].
  static final Map<String, Map<String, dynamic>?> _movieCollections = {};

  /// TMDB has no "list all collections" call, so the Collections library is
  /// built from this list of well known franchises (most popular first),
  /// each looked up by name with /search/collection. A name TMDB does not
  /// know under that wording is simply skipped. Collections that are not
  /// listed here still work: a movie in one shows its "In this collection"
  /// row and opens the collection screen.
  static const List<String> _collectionNames = [
    'Star Wars Collection',
    'The Lord of the Rings Collection',
    'Harry Potter Collection',
    'The Avengers Collection',
    'Iron Man Collection',
    'Spider-Man Collection',
    'The Dark Knight Collection',
    'Jurassic Park Collection',
    'The Fast and the Furious Collection',
    'Pirates of the Caribbean Collection',
    'James Bond Collection',
    'Mission: Impossible Collection',
    'John Wick Collection',
    'The Matrix Collection',
    'Toy Story Collection',
    'Despicable Me Collection',
    'Shrek Collection',
    'Frozen Collection',
    'Avatar Collection',
    'Transformers Collection',
    'X-Men Collection',
    'Guardians of the Galaxy Collection',
    'Thor Collection',
    'Captain America Collection',
    'Black Panther Collection',
    'Doctor Strange Collection',
    'Ant-Man Collection',
    'Deadpool Collection',
    'Planet of the Apes Collection',
    'The Hunger Games Collection',
    'The Twilight Collection',
    'Indiana Jones Collection',
    'The Hobbit Collection',
    'Back to the Future Collection',
    'Terminator Collection',
    'Alien Collection',
    'Predator Collection',
    'Rocky Collection',
    'Creed Collection',
    'Rambo Collection',
    'Die Hard Collection',
    'Lethal Weapon Collection',
    'Mad Max Collection',
    'The Godfather Collection',
    'Ice Age Collection',
    'Kung Fu Panda Collection',
    'How to Train Your Dragon Collection',
    'Madagascar Collection',
    'Cars Collection',
    'Finding Nemo Collection',
    'Monsters, Inc. Collection',
    'The Incredibles Collection',
    'Minions Collection',
    'Hotel Transylvania Collection',
    'Sing Collection',
    'The Secret Life of Pets Collection',
    'Ghostbusters Collection',
    'Jaws Collection',
    'Rush Hour Collection',
    'Men in Black Collection',
    'Bad Boys Collection',
    'Scream Collection',
    'The Conjuring Collection',
    'Saw Collection',
    'Final Destination Collection',
    'Halloween Collection',
    'A Nightmare on Elm Street Collection',
    'Friday the 13th Collection',
    'The Exorcist Collection',
    'Resident Evil Collection',
    'Underworld Collection',
    'The Bourne Collection',
    'Taken Collection',
    "Ocean's Collection",
    'The Expendables Collection',
    'Kingsman Collection',
    'Austin Powers Collection',
    'American Pie Collection',
    'The Hangover Collection',
    'Meet the Parents Collection',
    'Night at the Museum Collection',
    'Pitch Perfect Collection',
    'Step Up Collection',
    'Divergent Collection',
    'The Maze Runner Collection',
    'Percy Jackson Collection',
    'Fantastic Beasts Collection',
    'The Chronicles of Narnia Collection',
    'Dune Collection',
    'Blade Runner Collection',
    'Star Trek Collection',
    'Godzilla Collection',
    'King Kong Collection',
    'The Transporter Collection',
    'Jack Reacher Collection',
    'Hellboy Collection',
    'Venom Collection',
    'Wonder Woman Collection',
    'Aquaman Collection',
    'Batman Collection',
    'Superman Collection',
    'The Karate Kid Collection',
    'Top Gun Collection',
    'Home Alone Collection',
    'Beverly Hills Cop Collection',
    'Paddington Collection',
    'Zootopia Collection',
    'Moana Collection',
    "Wreck-It Ralph Collection",
    'Lilo & Stitch Collection',
    'The Lion King Collection',
    "Bridget Jones's Diary Collection",
  ];

  /// Lower-case words of a collection name, without "collection" or a
  /// leading "the", so "The Hunger Games Collection" and "Hunger Games"
  /// compare equal.
  static String _collectionKey(String name) {
    var n = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();
    n = n.replaceAll(RegExp(r'\bcollection\b'), ' ');
    n = n.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (n.startsWith('the ')) n = n.substring(4);
    return n;
  }

  /// One curated name -> its TMDB search result (id, name, poster_path,
  /// backdrop_path, overview), or null. Looked up once per session; a
  /// failed lookup is forgotten so a later call retries it.
  static final Map<String, Future<Map<String, dynamic>?>> _collectionLookups =
      {};

  static Future<Map<String, dynamic>?> _resolveCollectionName(String name) {
    return _collectionLookups[name] ??= () async {
      Map<String, dynamic>? found;
      try {
        final data =
            await TmdbCatalogService.raw('/search/collection', {'query': name});
        final results = data?['results'];
        if (results is List) {
          final want = _collectionKey(name);
          Map<String, dynamic>? prefix;
          for (final r in results.whereType<Map>()) {
            if (r['id'] is! num || r['poster_path'] == null) continue;
            final got = _collectionKey((r['name'] ?? '').toString());
            if (got == want) {
              found = Map<String, dynamic>.from(r);
              break;
            }
            if (prefix == null && got.startsWith('$want ')) {
              prefix = Map<String, dynamic>.from(r);
            }
          }
          found ??= prefix;
        }
      } catch (e) {
        debugPrint('[VirtualCatalog] collection lookup "$name" failed: $e');
      }
      if (found == null) _collectionLookups.remove(name);
      return found;
    }();
  }

  /// The curated collections, most popular first, as TMDB search maps. With
  /// [max] only enough names are looked up to reach that many.
  static Future<List<Map<String, dynamic>>> _popularCollections(
      {int? max}) async {
    final out = <Map<String, dynamic>>[];
    final seen = <int>{};
    const chunk = 12;
    for (var i = 0; i < _collectionNames.length; i += chunk) {
      final slice = _collectionNames.sublist(
          i, math.min(i + chunk, _collectionNames.length));
      final found = await Future.wait(slice.map(_resolveCollectionName));
      for (final r in found) {
        if (r == null) continue;
        final id = (r['id'] as num).toInt();
        if (seen.add(id)) out.add(r);
      }
      if (max != null && out.length >= max) break;
    }
    return max != null && out.length > max ? out.take(max).toList() : out;
  }

  /// Parental Controls: drops collections (TMDB maps or BoxSet items) that
  /// are not allowed. A collection with no allowed movie is hidden.
  static Future<List<Map<String, dynamic>>> filterCollectionMaps(
      List<Map<String, dynamic>> entries) {
    return ParentalControls.instance.filterCollections(entries, (id) async {
      final d = await _collectionDetail(id);
      return d == null ? const <CatalogTitle>[] : _partsOf(d);
    });
  }

  /// The BoxSet JSON for a collection. [parts] (released movies of it, when
  /// known) add the year and an average rating.
  static Map<String, dynamic> _collectionItem({
    required int id,
    required String name,
    String? overview,
    String? poster,
    String? backdrop,
    List<CatalogTitle>? parts,
  }) {
    final cid = VId.collectionOf(id);
    VirtualImages.register(cid, primary: poster, backdrop: backdrop);

    int? year;
    double rating = 0;
    if (parts != null && parts.isNotEmpty) {
      final years = parts.map((t) => t.year).whereType<int>().toList()..sort();
      if (years.isNotEmpty) year = years.first;
      final rated = parts.where((t) => t.rating > 0).toList();
      if (rated.isNotEmpty) {
        rating = rated.map((t) => t.rating).reduce((a, b) => a + b) /
            rated.length;
        rating = (rating * 10).round() / 10;
      }
    }

    return {
      'Id': cid,
      'ServerId': serverId,
      'Name': name,
      'OriginalTitle': name,
      'SortName': name.toLowerCase(),
      'Type': 'BoxSet',
      'IsFolder': true,
      'Overview': overview ?? '',
      if (year != null) 'ProductionYear': year,
      if (rating > 0) 'CommunityRating': rating,
      if (parts != null) 'ChildCount': parts.length,
      'Genres': const <String>[],
      'GenreItems': const <Map<String, dynamic>>[],
      'ProviderIds': {'Tmdb': id.toString()},
      'ImageTags': {
        if (poster != null) 'Primary': 'p',
        if (backdrop != null) 'Thumb': 'b',
      },
      'BackdropImageTags': [if (backdrop != null) 'b'],
      'PrimaryImageAspectRatio': 0.6666666667,
      'Taglines': const <String>[],
      'Tags': const <String>[],
      'Studios': const <Map<String, dynamic>>[],
      'People': const <Map<String, dynamic>>[],
      'UserData': {
        'IsFavorite': false,
        'Played': false,
        'PlayCount': 0,
        'PlaybackPositionTicks': 0,
      },
      'NamesisVirtual': true,
    };
  }

  /// A BoxSet from a TMDB collection list/search result (no parts yet).
  static Map<String, dynamic>? _collectionItemFromSearch(Map r) {
    final id = (r['id'] as num?)?.toInt();
    if (id == null) return null;
    return _collectionItem(
      id: id,
      name: (r['name'] ?? '').toString(),
      overview: r['overview']?.toString(),
      poster: r['poster_path'] as String?,
      backdrop: r['backdrop_path'] as String?,
    );
  }

  /// The collections of the Collections library as BoxSets: most popular
  /// first, or by name when [sortByName].
  static Future<List<Map<String, dynamic>>> popularCollectionItems({
    int? max,
    bool sortByName = false,
    bool descending = false,
  }) async {
    // With Parental Controls on, look at more so the list is still full.
    final wide = ParentalControls.instance.contentFilterActive;
    var found = await _popularCollections(max: wide && max != null ? max * 3 : max);
    found = await filterCollectionMaps(found);
    if (max != null && found.length > max) found = found.take(max).toList();
    final items = <Map<String, dynamic>>[];
    for (final r in found) {
      final item = _collectionItemFromSearch(r);
      if (item != null) items.add(item);
    }
    if (sortByName) {
      items.sort((a, b) =>
          (a['SortName'] as String).compareTo(b['SortName'] as String));
      if (descending) return items.reversed.toList();
    }
    return items;
  }

  /// Collections whose name matches [term] (TMDB /search/collection).
  static Future<List<Map<String, dynamic>>> searchCollections(
      String term) async {
    final data = await TmdbCatalogService.raw(
        '/search/collection', {'query': term.trim()});
    final results = data?['results'];
    if (results is! List) return const [];
    var usable = <Map<String, dynamic>>[
      for (final r in results.whereType<Map>())
        if (r['poster_path'] != null) Map<String, dynamic>.from(r),
    ];
    usable = await filterCollectionMaps(usable);
    final out = <Map<String, dynamic>>[];
    for (final r in usable) {
      final item = _collectionItemFromSearch(r);
      if (item != null) out.add(item);
    }
    return out;
  }

  /// TMDB /collection/{id}: name, overview, images and `parts` (its movies).
  static Future<Map<String, dynamic>?> _collectionDetail(int id) async {
    final data = await TmdbCatalogService.raw('/collection/$id', {});
    if (data == null || data['id'] is! num) return null;
    return data;
  }

  /// The released movies of a collection, oldest first (franchise order).
  static List<CatalogTitle> _partsOf(Map<String, dynamic> detail) {
    final parts = _parseList({'results': detail['parts']}, CatalogType.movie)
        .where((t) =>
            t.releaseDate != null &&
            t.releaseDate!.isNotEmpty &&
            !_isFuture(t.releaseDate))
        .toList();
    parts.sort((a, b) => a.releaseDate!.compareTo(b.releaseDate!));
    return parts;
  }

  static Map<String, dynamic> _collectionItemFromDetail(
      Map<String, dynamic> d) {
    return _collectionItem(
      id: (d['id'] as num).toInt(),
      name: (d['name'] ?? '').toString(),
      overview: d['overview']?.toString(),
      poster: d['poster_path'] as String?,
      backdrop: d['backdrop_path'] as String?,
      parts: _partsOf(d),
    );
  }

  /// "In this collection": the movies of collection [id], as movie items.
  static Future<List<Map<String, dynamic>>> collectionParts(int id) async {
    final d = await _collectionDetail(id);
    if (d == null) return const [];
    final parts = await ParentalControls.instance.filterTitles(_partsOf(d));
    return parts.map((t) => titleToItem(t)).toList();
  }

  /// The collection a movie belongs to as a BoxSet, or null (not a movie,
  /// or in no collection).
  static Future<Map<String, dynamic>?> collectionForItem(String itemId) async {
    final v = VId.parse(itemId);
    if (v.kind != 'movie') return null;
    if (!_movieCollections.containsKey(itemId)) {
      await _detail(CatalogType.movie, v.tmdbId);
    }
    final c = _movieCollections[itemId];
    if (c == null) return null;
    if ((await filterCollectionMaps([Map<String, dynamic>.from(c)])).isEmpty) {
      return null;
    }
    return _collectionItem(
      id: (c['id'] as num).toInt(),
      name: (c['name'] ?? '').toString(),
      poster: c['poster_path'] as String?,
      backdrop: c['backdrop_path'] as String?,
    );
  }

  static const String _collArtKey = 'vc_coll_art_v1';

  /// The Collections card's picture: the backdrop of a random popular
  /// collection, chosen once a week (like the other cards) and never the
  /// same picture as another card. Last week's shows at once while a new
  /// one is picked.
  static Future<void> _assignCollectionsArt() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final week = _weekNumber();

      String? path;
      int? storedWeek;
      try {
        final raw = prefs.getString(_collArtKey);
        if (raw != null) {
          final m = jsonDecode(raw);
          if (m is Map) {
            path = m['path']?.toString();
            storedWeek = (m['week'] as num?)?.toInt();
          }
        }
      } catch (_) {}

      if (path != null && path.isNotEmpty) {
        VirtualImages.register(collectionsLib.id,
            primary: path, kind: 'backdrop');
      }
      if (storedWeek == week && path != null && path.isNotEmpty) return;

      final used = <String>{};
      try {
        final raw = prefs.getString(_artMapKey);
        if (raw != null) {
          for (final v in (jsonDecode(raw) as Map).values) {
            used.add(v.toString());
          }
        }
      } catch (_) {}

      final found = await filterCollectionMaps(await _popularCollections(max: 24));
      final pool = [
        for (final r in found)
          if (r['backdrop_path'] is String &&
              !used.contains(r['backdrop_path']))
            r['backdrop_path'] as String,
      ];
      if (pool.isEmpty) return;

      final pick = pool[math.Random().nextInt(pool.length)];
      VirtualImages.register(collectionsLib.id,
          primary: pick, kind: 'backdrop');
      await prefs.setString(
          _collArtKey, jsonEncode({'week': week, 'path': pick}));
    } catch (e) {
      debugPrint('[VirtualCatalog] collections art failed: $e');
    }
  }

  // ---------- favorites ----------

  static Future<List<Map<String, dynamic>>> favorites(Set<String> kinds) async {
    final out = <Map<String, dynamic>>[];
    var snaps = [
      for (final s in WatchHistoryService.instance.watchlist.value)
        if (kinds.contains(s.type == CatalogType.movie ? 'Movie' : 'Series')) s,
    ];
    final pc = ParentalControls.instance;
    if (pc.contentFilterActive) {
      final ok = await pc.filterTitles([for (final s in snaps) s.toTitle()]);
      final okIds = {for (final t in ok) ParentalControls.idOfTitle(t)};
      snaps = [
        for (final s in snaps)
          if (okIds.contains(ParentalControls.idOfTitle(s.toTitle()))) s,
      ];
    }
    for (final s in snaps) {
      final t = s.toTitle();
      final item = titleToItem(t);
      // "Time added" for the Favorites grids. Absent on titles favorited
      // before it was recorded; the list itself is newest-first, so the
      // screens fall back to this order for those.
      if (s.addedAtMs != null) item['FavoritedAtMs'] = s.addedAtMs;
      out.add(item);
    }
    return out;
  }

  /// Adds or removes a title from the favorites list.
  static Future<void> setFavorite(String itemId, bool favorite) async {
    final v = VId.parse(itemId);
    if (v.kind == 'person') {
      await _setFavoritePerson(itemId, v.tmdbId, favorite);
      return;
    }
    if (v.kind != 'movie' && v.kind != 'series') return;
    final type = v.kind == 'movie' ? CatalogType.movie : CatalogType.series;
    final h = WatchHistoryService.instance;
    final d = await _detail(type, v.tmdbId);
    if (d == null) return;
    if (h.isInWatchlist(d.title) != favorite) {
      await h.toggleWatchlist(d.title);
    }
  }

  // ---------- favorite cast & crew ----------

  static const String _favPeopleKey = 'vc_fav_people_v1';
  static Map<String, Map<String, dynamic>>? _favLoaded;
  static Map<String, Map<String, dynamic>> get _favPeople =>
      _favLoaded ??= <String, Map<String, dynamic>>{};

  static Future<void> _loadFavPeople() async {
    if (_favLoaded != null) return;
    final loaded = <String, Map<String, dynamic>>{};
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_favPeopleKey);
      if (raw != null) {
        for (final e in (jsonDecode(raw) as Map).entries) {
          if (e.value is Map) {
            loaded[e.key.toString()] = Map<String, dynamic>.from(e.value);
          }
        }
      }
    } catch (_) {}
    // A toggle may have run while we were reading.
    _favLoaded ??= loaded;
  }

  /// Re-reads the favorite cast & crew from disk (account switch / cloud
  /// update). Swaps the map in one step so a favorite being added right now
  /// is never lost.
  static Future<void> reloadFavoritePeople() async {
    final loaded = <String, Map<String, dynamic>>{};
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_favPeopleKey);
      if (raw != null) {
        for (final e in (jsonDecode(raw) as Map).entries) {
          if (e.value is Map) {
            loaded[e.key.toString()] = Map<String, dynamic>.from(e.value);
          }
        }
      }
    } catch (_) {}
    _favLoaded = loaded;
  }

  static Future<void> _saveFavPeople() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_favPeopleKey, jsonEncode(_favPeople));
    } catch (e) {
      debugPrint('[VirtualCatalog] favorite people save failed: $e');
    }
  }

  static Future<void> _setFavoritePerson(
      String id, int tmdbId, bool favorite) async {
    await _loadFavPeople();
    if (!favorite) {
      _favPeople.remove(id);
      await _saveFavPeople();
      return;
    }
    if (_favPeople.containsKey(id)) return;
    // Name, photo and job come from TMDB, so the favorite can be listed
    // later without opening the person again.
    final data = await TmdbCatalogService.raw('/person/$tmdbId');
    final name = (data?['name'] ?? '').toString();
    if (data == null || name.isEmpty) {
      throw Exception('Could not load this person.');
    }
    final dept = data['known_for_department']?.toString();
    _favPeople[id] = {
      'Id': id,
      // When it was favorited (ms since epoch), for "Time added".
      'AddedAt': DateTime.now().millisecondsSinceEpoch,
      'Name': name,
      'Role': dept ?? '',
      'Type': dept == 'Directing'
          ? 'Director'
          : dept == 'Writing'
              ? 'Writer'
              : dept == 'Production'
                  ? 'Producer'
                  : 'Actor',
      if (data['profile_path'] != null) 'Profile': data['profile_path'],
    };
    await _saveFavPeople();
  }

  /// The favorited cast & crew, in cast-card shape.
  static Future<List<Map<String, dynamic>>> favoritePeople(int limit) async {
    await _loadFavPeople();
    // Newest first. The map keeps insertion order (oldest first), so walk
    // it backwards; entries saved with a time are then ordered by it, the
    // older ones without one stay behind them in that reversed order.
    final entries = _favPeople.values.toList().reversed.toList();
    final rank = Map<Map<String, dynamic>, int>.identity();
    for (var i = 0; i < entries.length; i++) {
      rank[entries[i]] = i;
    }
    int? stamp(Map<String, dynamic> f) => (f['AddedAt'] as num?)?.toInt();
    entries.sort((a, b) {
      final at = stamp(a);
      final bt = stamp(b);
      if (at != null && bt != null && at != bt) return bt.compareTo(at);
      if (at != null && bt == null) return -1;
      if (at == null && bt != null) return 1;
      return rank[a]!.compareTo(rank[b]!);
    });

    final out = <Map<String, dynamic>>[];
    for (final f in entries) {
      final id = f['Id'].toString();
      final profile = f['Profile'] as String?;
      VirtualImages.register(id, primary: profile, kind: 'profile');
      out.add({
        'Id': id,
        if (stamp(f) != null) 'FavoritedAtMs': stamp(f),
        'Name': f['Name'],
        'Role': f['Role'] ?? '',
        'Type': f['Type'] ?? 'Actor',
        if (profile != null) 'PrimaryImageTag': 'x',
        'ServerId': serverId,
        'UserData': {'IsFavorite': true},
      });
    }
    return out.take(limit).toList();
  }

  // ---------- similar ----------

  static Future<List<Map<String, dynamic>>> similar(String id) async {
    final v = VId.parse(id);
    if (v.kind != 'movie' && v.kind != 'series') return const [];
    final type = v.kind == 'movie' ? CatalogType.movie : CatalogType.series;
    final d = await _detail(type, v.tmdbId);
    if (d == null) return const [];
    final similar = await ParentalControls.instance.filterTitles(
        [for (final t in d.title.similar) if (t.posterPath != null) t]);
    return similar.map((t) => titleToItem(t)).toList();
  }

  // ---------- people ----------

  static const Set<String> _filmographyCrewJobs = {
    'director', 'writer', 'screenplay', 'story', 'creator', 'novel',
    'characters', 'executive producer', 'producer',
  };

  /// Movies and shows this person took part in, most popular first.
  /// Looks the person up by TMDB id ("p123" or "123") or, failing that,
  /// by name. Talk-show / news appearances are left out.
  /// NAMESIS PRIME: people matching a search word (TMDB /search/person),
  /// shaped like the cast cards of a detail screen. People with a photo come
  /// first; TMDB's own popularity order is kept inside each group.
  static Future<List<Map<String, dynamic>>> searchPeople(
    String query, {
    int limit = 30,
  }) async {
    final data = await TmdbCatalogService.raw(
        '/search/person', {'query': query.trim()});
    final results = data?['results'];
    if (results is! List) return const [];

    String roleType(String? dept) {
      switch (dept) {
        case 'Directing':
          return 'Director';
        case 'Writing':
          return 'Writer';
        case 'Production':
          return 'Producer';
        default:
          return 'Actor';
      }
    }

    final withPhoto = <Map<String, dynamic>>[];
    final withoutPhoto = <Map<String, dynamic>>[];
    for (final r in results.whereType<Map>()) {
      final pid = (r['id'] as num?)?.toInt();
      final name = (r['name'] ?? '').toString();
      if (pid == null || name.isEmpty) continue;
      final profile = r['profile_path'] as String?;
      final personId = 'p$pid';
      VirtualImages.register(personId, primary: profile, kind: 'profile');

      // "Known for" - the best-known title, shown under the name.
      String known = '';
      final kf = r['known_for'];
      if (kf is List) {
        for (final k in kf.whereType<Map>()) {
          final t = (k['title'] ?? k['name'] ?? '').toString();
          if (t.isNotEmpty) {
            known = t;
            break;
          }
        }
      }
      final dept = r['known_for_department']?.toString();
      final item = <String, dynamic>{
        'Id': personId,
        'Name': name,
        'Role': known.isNotEmpty ? known : (dept ?? ''),
        'Type': roleType(dept),
        if (profile != null) 'PrimaryImageTag': 'x',
      };
      (profile != null ? withPhoto : withoutPhoto).add(item);
    }
    return [...withPhoto, ...withoutPhoto].take(limit).toList();
  }

  static Future<List<Map<String, dynamic>>> personTitles({
    String? personId,
    String? name,
    int limit = 100,
  }) async {
    int? pid;
    if (personId != null && personId.isNotEmpty) {
      final v = VId.parse(personId);
      pid = v.kind == 'person' ? v.tmdbId : int.tryParse(personId);
    }
    if (pid == null && name != null && name.trim().isNotEmpty) {
      final found = await TmdbCatalogService.raw(
          '/search/person', {'query': name.trim()});
      final results = found?['results'];
      if (results is List) {
        for (final r in results.whereType<Map>()) {
          final id = (r['id'] as num?)?.toInt();
          if (id != null) {
            pid = id;
            break;
          }
        }
      }
    }
    if (pid == null) return const [];

    final data = await TmdbCatalogService.raw('/person/$pid/combined_credits');
    if (data == null) {
      debugPrint('[VirtualCatalog] credits of person $pid: no data from TMDB');
      return const [];
    }

    final picked = <String, Map<String, dynamic>>{};
    void take(dynamic list, bool crew) {
      if (list is! List) return;
      for (final e in list.whereType<Map>()) {
        final media = e['media_type'];
        if (media != 'movie' && media != 'tv') continue;
        if (e['poster_path'] == null) continue;
        if (crew &&
            !_filmographyCrewJobs
                .contains((e['job'] ?? '').toString().toLowerCase())) {
          continue;
        }
        if (!crew) {
          final g = e['genre_ids'];
          if (g is List && (g.contains(10767) || g.contains(10763))) continue;
        }
        picked.putIfAbsent(
            '$media:${e['id']}', () => Map<String, dynamic>.from(e));
      }
    }

    take(data['cast'], false);
    take(data['crew'], true);

    final sorted = picked.values.toList()
      ..sort((a, b) => ((b['popularity'] as num?) ?? 0)
          .compareTo((a['popularity'] as num?) ?? 0));

    var candidates = <CatalogTitle>[];
    for (final e in sorted) {
      if (candidates.length >= limit) break;
      final t = CatalogTitle.fromTmdb(e,
          type: e['media_type'] == 'tv'
              ? CatalogType.series
              : CatalogType.movie);
      if (t.tmdbId <= 0) continue;
      candidates.add(t);
    }
    candidates = await ParentalControls.instance.filterTitles(candidates);
    return [for (final t in candidates) titleToItem(t)];
  }

  // ---------- seasons and episodes ----------

  /// The series with its season list. If the cached/combined detail call
  /// failed or came back without seasons, asks TMDB once more directly so a
  /// single bad response does not leave the season selector empty.
  static Future<CatalogTitle?> _showWithSeasons(int tmdbId) async {
    final d = await _detail(CatalogType.series, tmdbId);
    if (d != null && d.title.seasons.isNotEmpty) return d.title;
    final again = await TmdbCatalogService.details(CatalogType.series, tmdbId);
    if (again != null && again.seasons.isNotEmpty) return again;
    return d?.title ?? again;
  }

  static Future<List<Map<String, dynamic>>> seasonsOf(String seriesId) async {
    final v = VId.parse(seriesId);
    if (v.kind != 'series') return const [];
    if (!(await ParentalControls.instance.checkId(seriesId)).allowed) {
      return const [];
    }
    final show = await _showWithSeasons(v.tmdbId);
    if (show == null) {
      debugPrint('[VirtualCatalog] seasons of $seriesId: no data from TMDB');
      return const [];
    }
    final out = <Map<String, dynamic>>[];
    for (final s in show.seasons) {
      if (s.number <= 0) continue; // skip "Specials"
      final id = VId.seasonOf(v.tmdbId, s.number);
      VirtualImages.register(id, primary: s.posterPath);
      out.add({
        'Id': id,
        'ServerId': serverId,
        'Name': s.name,
        'Type': 'Season',
        'IsFolder': true,
        'IndexNumber': s.number,
        'SeriesId': seriesId,
        'SeriesName': show.title,
        'ChildCount': s.episodeCount,
        'ImageTags': {if (s.posterPath != null) 'Primary': 'p'},
        'UserData': {'IsFavorite': false, 'Played': false},
        'NamesisVirtual': true,
      });
    }
    out.sort((a, b) =>
        (a['IndexNumber'] as int).compareTo(b['IndexNumber'] as int));
    return out;
  }

  /// Episodes of one season, or of every season when [seasonId] is null.
  /// Episodes that have not aired yet are left out.
  static Future<List<Map<String, dynamic>>> episodesOf(
    String seriesId,
    String? seasonId,
  ) async {
    final v = VId.parse(seriesId);
    if (v.kind != 'series') return const [];
    if (!(await ParentalControls.instance.checkId(seriesId)).allowed) {
      return const [];
    }
    final show = await _showWithSeasons(v.tmdbId);
    if (show == null) {
      debugPrint('[VirtualCatalog] episodes of $seriesId: no data from TMDB');
      return const [];
    }

    List<int> seasonNumbers;
    if (seasonId != null && seasonId.isNotEmpty) {
      final sv = VId.parse(seasonId);
      if (sv.kind != 'season') return const [];
      seasonNumbers = [sv.season!];
    } else {
      seasonNumbers =
          show.seasons.where((s) => s.number > 0).map((s) => s.number).toList()
            ..sort();
    }

    final perSeason = await Future.wait([
      for (final n in seasonNumbers) TmdbCatalogService.episodes(v.tmdbId, n),
    ]);

    final h = WatchHistoryService.instance;
    final entry = h.entryFor(show);
    final cur = (entry != null && entry.isEpisode) ? entry : null;
    final out = <Map<String, dynamic>>[];
    for (var i = 0; i < seasonNumbers.length; i++) {
      final sn = seasonNumbers[i];
      for (final ep in perSeason[i]) {
        if (_isFuture(ep.airDate)) continue;
        final id = VId.episodeOf(v.tmdbId, sn, ep.number);
        VirtualImages.register(id,
            primary: ep.stillPath, backdrop: show.backdropPath, kind: 'still');

        final played = h.isWatched(v.tmdbId, sn, ep.number);
        final ticks = (cur != null &&
                cur.season == sn &&
                cur.episode == ep.number &&
                !cur.finished &&
                !cur.upNext)
            ? _ticksFromMs(cur.positionMs)
            : 0;
        // Partly watched episodes other than the one watched last.
        final prog = played ? null : h.episodeProgress(v.tmdbId, sn, ep.number);
        final shownTicks = ticks > 0
            ? ticks
            : (prog != null ? _ticksFromMs(prog[0]) : 0);
        final runTicks = prog != null
            ? _ticksFromMs(prog[1])
            : _ticksFromMinutes(ep.runtime ?? show.runtime);

        out.add({
          'Id': id,
          'ServerId': serverId,
          'Name': ep.name,
          'Overview': ep.overview,
          'Type': 'Episode',
          'MediaType': 'Video',
          'IsFolder': false,
          'LocationType': 'FileSystem',
          'SeriesId': seriesId,
          'SeriesName': show.title,
          'SeasonId': VId.seasonOf(v.tmdbId, sn),
          'ParentIndexNumber': sn,
          'IndexNumber': ep.number,
          'RunTimeTicks': runTicks,
          if (_premiere(ep.airDate) != null)
            'PremiereDate': _premiere(ep.airDate),
          'ProviderIds': const <String, String>{},
          'ImageTags': {if (ep.stillPath != null) 'Primary': 'e'},
          'BackdropImageTags': [if (show.backdropPath != null) 'b'],
          'ParentBackdropItemId': seriesId,
          'UserData': {
            'IsFavorite': false,
            'Played': played,
            'PlayCount': played ? 1 : 0,
            'PlaybackPositionTicks': shownTicks,
          },
          'NamesisVirtual': true,
        });
      }
    }
    return out;
  }

  // ---------- grids, search, filters ----------

  static String _csvLower(String? s) => (s ?? '').toLowerCase();

  /// Handles every `GET /Users/{id}/Items` the original screens make.
  static Future<Map<String, dynamic>> items(Map<String, String> q) async {
    List<Map<String, dynamic>> result = const [];

    final ids = q['Ids'];
    final term = q['SearchTerm'];
    final filters = _csvLower(q['Filters']);
    final includeRaw = q['IncludeItemTypes'] ?? '';
    final include = _csvLower(includeRaw);
    final sortBy = q['SortBy'] ?? '';
    final limit = int.tryParse(q['Limit'] ?? '') ?? 100;

    final wantsMovie = include.contains('movie');
    final wantsSeries = include.contains('series');
    final parentId = q['ParentId'];
    final nothingVideo = include.isNotEmpty &&
        !wantsMovie &&
        !wantsSeries &&
        !include.contains('boxset');

    final parentKind = parentId == null ? '' : VId.parse(parentId).kind;

    if (ids != null && ids.isNotEmpty) {
      final list = await Future.wait(
        ids.split(',').where((s) => s.trim().isNotEmpty).map((id) async {
          try {
            return await item(id.trim());
          } catch (_) {
            return null;
          }
        }),
      );
      result = list.whereType<Map<String, dynamic>>().toList();
    } else if (parentKind == 'collection') {
      // The movies of one collection ("In this collection").
      result = await collectionParts(VId.parse(parentId!).tmdbId);
      if (limit < result.length) result = result.take(limit).toList();
    } else if (filters.contains('isfavorite')) {
      final kinds = <String>{
        if (wantsMovie || include.isEmpty) 'Movie',
        if (wantsSeries || include.isEmpty) 'Series',
      };
      result = await favorites(kinds);
    } else if (nothingVideo) {
      result = const [];
    } else if ((include.contains('boxset') && !wantsMovie && !wantsSeries) ||
        parentId == collectionsLib.id) {
      // The Collections library / a BoxSet-only query: popular movie
      // collections (or collections matching the search word).
      result = (term != null && term.trim().isNotEmpty)
          ? await searchCollections(term)
          : await popularCollectionItems(
              max: limit >= 500 ? null : limit,
              sortByName: sortBy.toLowerCase().contains('sortname'),
              descending: !_csvLower(q['SortOrder']).startsWith('asc'),
            );
    } else if (term != null && term.trim().isNotEmpty) {
      // Parental Controls: blocked titles are NOT dropped from search. They
      // come back flagged `ParentalBlocked`, and MovieCard shows them blurred
      // and locked: tapping one only explains that it is blocked and never
      // opens it (VirtualCatalog.item still refuses it as well).
      final found = await TmdbCatalogService.search(term);
      final blocked = await ParentalControls.instance.blockedIdsAmong(found);
      result = found
          .where((t) =>
              include.isEmpty ||
              (t.type == CatalogType.movie ? wantsMovie : wantsSeries))
          .map((t) {
        final item = titleToItem(t);
        if (blocked.contains(ParentalControls.idOfTitle(t))) {
          item['ParentalBlocked'] = true;
        }
        return item;
      }).toList();
      // Collections matching the word go alongside the titles when the
      // caller asked for BoxSets too (the Search screen does).
      if (include.contains('boxset')) {
        try {
          final cols = await searchCollections(term);
          result = [...result, ...cols.take(10)];
        } catch (_) {}
      }
    } else if (parentId == trendingMoviesId || parentId == trendingShowsId) {
      final type = parentId == trendingMoviesId
          ? CatalogType.movie
          : CatalogType.series;
      var trending = await TmdbCatalogService.trending(type);
      final pc = ParentalControls.instance;
      if (pc.contentFilterActive) {
        // More pages, so the row is still full after the filter.
        final more = await Future.wait([
          TmdbCatalogService.trending(type, page: 2),
          TmdbCatalogService.trending(type, page: 3),
        ]);
        trending = await pc.filterTitles([...trending, ...more.expand((l) => l)]);
      }
      result = trending.take(limit).map((t) => titleToItem(t)).toList();
    } else if (sortBy.toLowerCase().contains('random')) {
      result = await featured(limit);
    } else if ((q['PersonIds'] ?? '').isNotEmpty ||
        (q['Person'] ?? '').isNotEmpty) {
      // NAMESIS PRIME: a cast/crew member's own filmography (the Cast &
      // Crew screen asks by id first, then by name). Without this the
      // unknown filter was ignored and a generic grid came back instead.
      final personIds = (q['PersonIds'] ?? '').split(',');
      final all = await personTitles(
        personId: personIds.first.trim(),
        name: q['Person'],
        limit: limit,
      );
      result = all
          .where((m) =>
              include.isEmpty ||
              (m['Type'] == 'Movie' ? wantsMovie : wantsSeries))
          .toList();
    } else if ((q['ArtistIds'] ?? '').isNotEmpty) {
      result = const [];
    } else {
      result = await _grid(q, limit);
    }

    return {
      'Items': result,
      'TotalRecordCount': result.length,
      'StartIndex': 0,
    };
  }

  static Future<List<Map<String, dynamic>>> _grid(
    Map<String, String> q,
    int limit,
  ) async {
    final parent = q['ParentId'];
    final lib = libraryById(parent);
    final include = _csvLower(q['IncludeItemTypes']);

    final types = <CatalogType>[];
    if (lib != null) {
      types.add(lib.type);
    } else {
      if (include.isEmpty || include.contains('movie')) {
        types.add(CatalogType.movie);
      }
      if (include.isEmpty || include.contains('series')) {
        types.add(CatalogType.series);
      }
    }
    if (types.isEmpty) return const [];

    // Genre filter: from the library, or from a Genres=Action|Drama query.
    int? genre = lib?.genreId;
    final genreParam = q['Genres'];
    if (genre == null && genreParam != null && genreParam.isNotEmpty) {
      final first = genreParam.split(RegExp(r'[|,]')).first;
      genre = _genreIdByName(first);
      if (genre == null) return const [];
    }

    // Tags=Heist|Time travel (a tag tapped on a detail screen): every title
    // carrying any of those TMDB keywords. A tag TMDB cannot match gives an
    // empty grid rather than an unfiltered one.
    String? tagKeywords;
    final tagParam = q['Tags'];
    if (tagParam != null && tagParam.trim().isNotEmpty) {
      final ids = <int>[];
      for (final tag in tagParam.split('|')) {
        final id = await _keywordIdFor(tag);
        if (id != null) ids.add(id);
      }
      if (ids.isEmpty) return const [];
      tagKeywords = ids.join('|');
    }

    int? company;
    final studio = q['StudioIds'];
    if (studio != null && studio.isNotEmpty) {
      company = int.tryParse(studio.split(',').first.trim());
      if (company == null) return const [];
    }

    final sortBy = (q['SortBy'] ?? 'DateCreated').split(',').first;
    final ascending = _csvLower(q['SortOrder']).startsWith('asc');
    // The Movies / TV screens ask for the default Limit=500 on a single
    // type; that is the "show the whole library" request, so it gets the
    // bigger [gridMax]. Everything else (e.g. the background TMDB index,
    // which asks for 5000 across both types) keeps the old 400 cap so it
    // does not fire hundreds of requests.
    final isGrid = limit >= 500 && types.length == 1;
    // TV has no server-side rating filter, so with a maturity limit every
    // show needs its own (then cached) rating lookup: keep that bounded.
    final showCap = (_strictRatings && types.contains(CatalogType.series))
        ? 300
        : gridMax;
    final want = isGrid ? showCap : _clampInt(limit, 20, 400);
    // A split chip (TV Action / Adventure) keeps only part of every TMDB
    // page, so a short request asks for twice the pages to still fill it.
    final rawWant = (lib?.split != null && !isGrid)
        ? _clampInt(want * 2, 20, 400)
        : want;
    final pages = (rawWant + 19) ~/ 20;

    final lists = await Future.wait([
      for (final type in types)
        _discoverMany(
          type,
          pages: pages,
          genre: genre,
          keywords: tagKeywords ?? lib?.keywords,
          companies: lib?.companies,
          language: lib?.language,
          split: lib?.split,
          company: company,
          sortBy: _tmdbSort(type, sortBy, ascending),
          // A tag (TMDB keyword) narrows the pool a lot, and shows collect
          // far fewer TMDB votes than movies, so the movie vote floor would
          // drop nearly every tagged show. Use a lower floor for shows there.
          minVotes: (tagKeywords != null && type == CatalogType.series)
              ? _clampInt(_minVotes(sortBy) ~/ 5, 5, 100)
              : _minVotes(sortBy),
          releasedOnly: sortBy == 'DateCreated' ||
              sortBy == 'PremiereDate' ||
              sortBy == 'ProductionYear',
        ),
    ]);

    var titles = <CatalogTitle>[for (final l in lists) ...l];
    // Tag grids hold movies AND shows: mix them in the requested order
    // instead of listing every movie first (which, with the cap below,
    // pushed the shows out of the grid).
    if (tagKeywords != null && lists.length > 1) {
      titles = _mixTypes(titles, sortBy, ascending);
    }
    // Parental Controls (after mixing, so the requested order is kept).
    titles = await ParentalControls.instance
        .filterTitles(titles, ratingChecked: _movieCeiling != null);
    if (sortBy == 'SortName') {
      titles.sort((a, b) =>
          a.title.toLowerCase().compareTo(b.title.toLowerCase()));
      if (!ascending) titles = titles.reversed.toList();
    }
    return titles.take(isGrid ? gridMax : limit).map((t) => titleToItem(t)).toList();
  }

  /// Merges movies and shows into one list in the requested sort order. For
  /// sorts that have no comparable field here (popularity, name; name is
  /// sorted by the caller afterwards) the two lists are interleaved.
  static List<CatalogTitle> _mixTypes(
    List<CatalogTitle> titles,
    String sortBy,
    bool ascending,
  ) {
    int Function(CatalogTitle, CatalogTitle)? cmp;
    switch (sortBy) {
      case 'DateCreated':
      case 'PremiereDate':
      case 'ProductionYear':
        cmp = (a, b) => (a.releaseDate ?? '').compareTo(b.releaseDate ?? '');
        break;
      case 'CommunityRating':
        cmp = (a, b) => a.rating.compareTo(b.rating);
        break;
    }

    if (cmp != null) {
      final compare = cmp;
      final order = List<int>.generate(titles.length, (i) => i);
      order.sort((x, y) {
        final c = compare(titles[x], titles[y]);
        if (c != 0) return ascending ? c : -c;
        return x.compareTo(y); // keep TMDB's order on ties
      });
      return [for (final i in order) titles[i]];
    }

    final movies =
        titles.where((t) => t.type == CatalogType.movie).toList();
    final shows =
        titles.where((t) => t.type != CatalogType.movie).toList();
    final out = <CatalogTitle>[];
    for (var i = 0; i < movies.length || i < shows.length; i++) {
      if (i < movies.length) out.add(movies[i]);
      if (i < shows.length) out.add(shows[i]);
    }
    return out;
  }

  /// Most titles a Movies / TV library grid will load (20 per TMDB page, so
  /// 1000 = 50 requests, fetched 10 at a time, then cached). Raise it for
  /// more titles at the cost of a slower first load. TMDB itself stops at
  /// 500 pages (10,000 titles) per list.
  static const int gridMax = 1000;

  static int _minVotes(String sortBy) {
    switch (sortBy) {
      case 'CommunityRating':
        return 300;
      case 'DateCreated':
      case 'PremiereDate':
      case 'ProductionYear':
        return 25;
    }
    return 50;
  }

  static String _tmdbSort(CatalogType type, String sortBy, bool ascending) {
    final dir = ascending ? 'asc' : 'desc';
    final dateField = type == CatalogType.movie
        ? 'primary_release_date'
        : 'first_air_date';
    switch (sortBy) {
      case 'DateCreated':
      case 'PremiereDate':
      case 'ProductionYear':
        return '$dateField.$dir';
      case 'CommunityRating':
        return 'vote_average.$dir';
      case 'Popularity':
        return 'popularity.$dir';
      case 'SortName':
        return 'popularity.desc'; // sorted by name afterwards
    }
    return 'popularity.desc';
  }
}

class _Detail {
  final CatalogTitle title;
  final List<Map<String, dynamic>> people;
  final List<Map<String, dynamic>> studios;
  final List<String> tags;
  _Detail(this.title, this.people, this.studios, this.tags);
}
