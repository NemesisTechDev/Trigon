import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../catalog/tmdb_catalog_service.dart';
import '../services/parental/parental_controls.dart';
import 'virtual_catalog.dart';
import 'virtual_images.dart';

/// NAMESIS PRIME: everything the Collections grid and a collection's
/// "More Like This" row need beyond what [VirtualCatalog] answers by itself.
///
/// 1. BIGGER GRID. The Collections library used to be only the ~110 names in
///    VirtualCatalog's curated list. [_extraNames] adds more franchises
///    after them (looked up by name exactly like the curated ones; a name
///    TMDB does not know is simply skipped), so the grid is no longer
///    limited to the first screenful of "famous" collections.
/// 2. WORKING SORTS. "New", "Popular" and "Rating" used to return the very
///    same list (always the curated "most popular first" order — only A-Z
///    was honoured). Now:
///      * Popular -> curated order, then the extra names;
///      * New     -> the collection whose latest released movie is newest;
///      * Rating  -> average TMDB rating of the collection's movies;
///      * A-Z     -> by name (unchanged).
///    New / Rating need each collection's movies, so they are read once per
///    session ([_facts]) from the same /collection/{id} call the detail
///    screen uses (cached by TmdbCatalogService on disk as well).
/// 3. MORE LIKE THIS for a collection: other collections whose movies share
///    genres with this one's, best match first. VirtualCatalog.similar only
///    knew movies and shows, so a collection's row was always empty.
class VirtualCollectionDiscovery {
  VirtualCollectionDiscovery._();

  /// Names looked up in parallel (same size VirtualCatalog uses).
  static const int _nameChunk = 12;

  /// Collections whose movies are read in parallel for sorting / matching.
  static const int _factsChunk = 16;

  /// How long one request may keep reading collections' movies before it
  /// answers with what it has (the rest keeps loading for the next request).
  /// Keeps a slow connection from stalling the grid or the row forever.
  static const Duration _factsBudget = Duration(seconds: 9);

  /// Most collections one "More Like This" row holds.
  static const int _similarMax = 20;

  /// More franchises, after VirtualCatalog's curated list (which stays first
  /// in the "Popular" order). TMDB collection names; the lookup ignores a
  /// leading "The" and the word "Collection".
  static const List<String> _extraNames = [
    'The Amazing Spider-Man Collection',
    'Spider-Man: Spider-Verse Collection',
    'Wolverine Collection',
    'Fantastic Four Collection',
    'Blade Collection',
    'Ghost Rider Collection',
    'Kick-Ass Collection',
    'Shazam! Collection',
    'The Mask Collection',
    'The Mummy Collection',
    'The Scorpion King Collection',
    'Tomb Raider Collection',
    'National Treasure Collection',
    'Sherlock Holmes Collection',
    'Johnny English Collection',
    'xXx Collection',
    'The Equalizer Collection',
    'Sicario Collection',
    'Now You See Me Collection',
    'Jack Ryan Collection',
    'Riddick Collection',
    'Tron Collection',
    'RoboCop Collection',
    'Independence Day Collection',
    'Pacific Rim Collection',
    'G.I. Joe Collection',
    'Teenage Mutant Ninja Turtles Collection',
    'Power Rangers Collection',
    'Gladiator Collection',
    '300 Collection',
    'Kill Bill Collection',
    'Knives Out Collection',
    'Enola Holmes Collection',
    'Universal Soldier Collection',
    'Ip Man Collection',
    'Police Story Collection',
    'Death Wish Collection',
    'The Pink Panther Collection',
    'Mortal Kombat Collection',
    'Cloverfield Collection',
    'A Quiet Place Collection',
    'Jumanji Collection',
    'Gremlins Collection',
    'Stargate Collection',
    'Speed Collection',
    'Highlander Collection',
    'Crocodile Dundee Collection',
    '21 Jump Street Collection',
    'Ride Along Collection',
    'Horrible Bosses Collection',
    'Ted Collection',
    'Anchorman Collection',
    'Dumb and Dumber Collection',
    'Ace Ventura Collection',
    'Bill & Ted Collection',
    'Police Academy Collection',
    'The Naked Gun Collection',
    'Scary Movie Collection',
    'Harold & Kumar Collection',
    'Neighbors Collection',
    'Grown Ups Collection',
    'Jackass Collection',
    'Mr. Bean Collection',
    'Wallace & Gromit Collection',
    'The Muppets Collection',
    'The Addams Family Collection',
    'Peter Rabbit Collection',
    'Stuart Little Collection',
    'Babe Collection',
    'Air Bud Collection',
    'Free Willy Collection',
    'Beethoven Collection',
    'Dr. Dolittle Collection',
    'Cheaper by the Dozen Collection',
    'The Mighty Ducks Collection',
    'The Santa Clause Collection',
    'Diary of a Wimpy Kid Collection',
    'Spy Kids Collection',
    'High School Musical Collection',
    'Mamma Mia! Collection',
    'Magic Mike Collection',
    'The Princess Diaries Collection',
    'Legally Blonde Collection',
    'Father of the Bride Collection',
    'My Big Fat Greek Wedding Collection',
    'Sister Act Collection',
    'Fifty Shades Collection',
    'After Collection',
    'The Purge Collection',
    'Insidious Collection',
    'Paranormal Activity Collection',
    'Annabelle Collection',
    "Child's Play Collection",
    'The Evil Dead Collection',
    'The Texas Chainsaw Massacre Collection',
    'Hostel Collection',
    'Poltergeist Collection',
    'The Ring Collection',
    'The Grudge Collection',
    'Jeepers Creepers Collection',
    'Hellraiser Collection',
    'Wrong Turn Collection',
    'The Omen Collection',
    'Candyman Collection',
    'I Know What You Did Last Summer Collection',
    'Sinister Collection',
    'Happy Death Day Collection',
    'The Strangers Collection',
    'Ouija Collection',
    'Escape Room Collection',
    'Pet Sematary Collection',
    '28 Days Later Collection',
    'Anaconda Collection',
    'Starship Troopers Collection',
    'Tremors Collection',
    'Pokémon Collection',
    'Dragon Ball Z Collection',
    'Detective Conan Collection',
    'Doraemon Collection',
    'The Lego Movie Collection',
    'Sonic the Hedgehog Collection',
    'Angry Birds Collection',
    'Inside Out Collection',
    'Puss in Boots Collection',
    'Rio Collection',
    'Happy Feet Collection',
    'Open Season Collection',
    'The Croods Collection',
    'Trolls Collection',
    'The Smurfs Collection',
    'Alvin and the Chipmunks Collection',
    'Garfield Collection',
    'Scooby-Doo Collection',
    'Tom and Jerry Collection',
    'Planes Collection',
    'Cloudy with a Chance of Meatballs Collection',
    'Aladdin Collection',
    'The Little Mermaid Collection',
    'Beauty and the Beast Collection',
    'Cinderella Collection',
    '101 Dalmatians Collection',
    'Mulan Collection',
    'The Jungle Book Collection',
    'Winnie the Pooh Collection',
    'Tinker Bell Collection',
    'Maleficent Collection',
    'Alice in Wonderland Collection',
    'PAW Patrol Collection',
    'Before Collection',
  ];

  // ---------------------------------------------------------------------
  // Routing helpers (used by VirtualJellyfinAdapter)
  // ---------------------------------------------------------------------

  /// True for the request this class answers: the Collections library grid
  /// (BoxSets, or anything under the Collections library) with no search
  /// word, ids, favorites filter or parent collection. Mirrors the branch
  /// order of [VirtualCatalog.items]; every other request stays with it.
  static bool handles(Map<String, String> q) {
    final ids = q['Ids'];
    if (ids != null && ids.isNotEmpty) return false;

    final term = q['SearchTerm'];
    if (term != null && term.trim().isNotEmpty) return false;

    final parentId = q['ParentId'];
    if (parentId != null && VId.parse(parentId).kind == 'collection') {
      return false;
    }

    if ((q['Filters'] ?? '').toLowerCase().contains('isfavorite')) {
      return false;
    }

    final include = (q['IncludeItemTypes'] ?? '').toLowerCase();
    final wantsMovie = include.contains('movie');
    final wantsSeries = include.contains('series');
    final wantsBoxSet = include.contains('boxset');
    if (include.isNotEmpty && !wantsMovie && !wantsSeries && !wantsBoxSet) {
      return false;
    }

    return (wantsBoxSet && !wantsMovie && !wantsSeries) ||
        parentId == VirtualCatalog.collectionsLib.id;
  }

  // ---------------------------------------------------------------------
  // The Collections grid
  // ---------------------------------------------------------------------

  /// `GET /Users/{id}/Items` for the Collections library, in the sort the
  /// grid asked for. Same reply shape as [VirtualCatalog.items].
  static Future<Map<String, dynamic>> grid(Map<String, String> q) async {
    final limit = int.tryParse(q['Limit'] ?? '') ?? 100;
    // 500 is the grid's "show everything" request; anything smaller (the
    // first-screenful request is 60) only needs that many collections.
    final int? max = limit >= 500 ? null : limit;
    final sortBy = (q['SortBy'] ?? '').toLowerCase();
    final descending =
    !(q['SortOrder'] ?? '').toLowerCase().startsWith('asc');

    var items = await _pool(max: max);

    if (sortBy.contains('sortname')) {
      items = [...items]..sort(
            (a, b) => '${a['SortName']}'.compareTo('${b['SortName']}'),
      );
      if (descending) items = items.reversed.toList();
    } else if (_isRatingSort(sortBy) || _isDateSort(sortBy)) {
      items = await _rankByFacts(
        items,
        byRating: _isRatingSort(sortBy),
        descending: descending,
      );
    } else if (!descending) {
      // Popularity, least popular first.
      items = items.reversed.toList();
    }

    if (max != null && items.length > max) items = items.take(max).toList();

    return {
      'Items': items,
      'TotalRecordCount': items.length,
      'StartIndex': 0,
    };
  }

  static bool _isRatingSort(String sortBy) =>
      sortBy.contains('communityrating') || sortBy.contains('criticrating');

  /// "New" (DateCreated) plus the other date-like keys, which all mean
  /// "most recent release first" for a collection.
  static bool _isDateSort(String sortBy) =>
      sortBy.contains('datecreated') ||
          sortBy.contains('premieredate') ||
          sortBy.contains('productionyear') ||
          sortBy.contains('datelastcontentadded');

  /// Orders [items] by newest release or by rating. A collection whose
  /// movies could not be read goes last, in its popularity position.
  static Future<List<Map<String, dynamic>>> _rankByFacts(
      List<Map<String, dynamic>> items, {
        required bool byRating,
        required bool descending,
      }) async {
    final ids = <int>[
      for (final item in items) VId.parse('${item['Id']}').tmdbId,
    ];
    await _warmFacts(ids);

    final rows = <_Ranked>[];
    for (var i = 0; i < items.length; i++) {
      // Already loaded by _warmFacts, so this does not wait; one that was
      // skipped when the time budget ran out is simply "unknown" here.
      final facts = _factsLoaded(ids[i]);
      _decorate(items[i], facts);
      rows.add(_Ranked(items[i], i, facts));
    }

    rows.sort((a, b) {
      final af = a.facts;
      final bf = b.facts;
      if ((af == null) != (bf == null)) return af == null ? 1 : -1;
      if (af != null && bf != null) {
        var c = byRating
            ? af.rating.compareTo(bf.rating)
            : af.latestRelease.compareTo(bf.latestRelease);
        if (c == 0) {
          // Equal rating -> newer first; equal date -> better rated first.
          c = byRating
              ? af.latestRelease.compareTo(bf.latestRelease)
              : af.rating.compareTo(bf.rating);
        }
        if (c != 0) return descending ? -c : c;
      }
      return a.index.compareTo(b.index);
    });

    return [for (final row in rows) row.item];
  }

  /// Puts the facts the grid card can show (first year, rating, movie
  /// count) on a collection item that does not have them yet.
  static void _decorate(Map<String, dynamic> item, _CollectionFacts? facts) {
    if (facts == null) return;
    final year = facts.firstYear;
    if (year != null && item['ProductionYear'] == null) {
      item['ProductionYear'] = year;
    }
    if (facts.rating > 0 && item['CommunityRating'] == null) {
      item['CommunityRating'] = facts.rating;
    }
    if (item['ChildCount'] == null) item['ChildCount'] = facts.movieCount;
  }

  // ---------------------------------------------------------------------
  // More Like This
  // ---------------------------------------------------------------------

  /// Most popular collections considered for one "More Like This" row. The
  /// first 60 are exactly what the Collections grid's first screen already
  /// looked up, so this needs no extra name searches.
  static const int _similarPool = 60;

  /// How long a row waits for collections' movies before answering with
  /// what it has; the rest keeps loading and improves the next answer.
  static const Duration _similarDeadline = Duration(milliseconds: 3500);

  /// Collections' movies read at the same time.
  static const int _factsWorkers = 12;

  static final Map<String, List<Map<String, dynamic>>> _similarDone = {};
  static final Map<String, Future<List<Map<String, dynamic>>>> _similarRuns =
      {};

  static List<Map<String, dynamic>> _copyRows(
          List<Map<String, dynamic>> rows) =>
      (jsonDecode(jsonEncode(rows)) as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();

  /// Collections that share genres with [collectionId], best match first
  /// (empty when its movies are unknown or nothing overlaps). A finished
  /// row is remembered, so reopening a collection shows it at once.
  static Future<List<Map<String, dynamic>>> similar(String collectionId) async {
    final self = VId.parse(collectionId);
    if (self.kind != 'collection') return const [];
    _syncRevision();

    final done = _similarDone[collectionId];
    if (done != null) return _copyRows(done);

    final rows = await (_similarRuns[collectionId] ??=
        _computeSimilar(collectionId, self.tmdbId).whenComplete(() {
      _similarRuns.remove(collectionId);
    }));
    return _copyRows(rows);
  }

  static Future<List<Map<String, dynamic>>> _computeSimilar(
      String collectionId, int selfId) async {
    final revision = _factsRevision;
    final source = await _factsFor(selfId);
    if (source == null || source.genreShare.isEmpty) return const [];

    final pool = <Map<String, dynamic>>[
      ...await VirtualCatalog.popularCollectionItems(max: _similarPool),
    ];
    // Extra franchises only when an earlier request already looked them up.
    final have = <String>{for (final item in pool) '${item['Id']}'};
    for (final item in _extrasCache ?? const <Map<String, dynamic>>[]) {
      if (have.add('${item['Id']}')) pool.add(item);
    }

    final candidates = <Map<String, dynamic>>[];
    final ids = <int>[];
    for (final item in pool) {
      final id = VId.parse('${item['Id']}').tmdbId;
      if (id == selfId) continue;
      candidates.add(item);
      ids.add(id);
    }

    var finished = false;
    final warm = _warmPool(ids).then((_) => finished = true);
    await warm.timeout(_similarDeadline, onTimeout: () => false);

    final scored = <_Scored>[];
    for (var i = 0; i < candidates.length; i++) {
      final facts = _factsLoaded(ids[i]);
      if (facts == null) continue;
      final score = _similarity(source, facts);
      if (score <= 0) continue;
      scored.add(_Scored(candidates[i], i, score, facts));
    }

    scored.sort((a, b) {
      final c = b.score.compareTo(a.score);
      if (c != 0) return c;
      return a.index.compareTo(b.index);
    });

    final out = <Map<String, dynamic>>[];
    for (final row in scored.take(_similarMax)) {
      _decorate(row.item, row.facts);
      out.add(row.item);
    }

    if (finished && out.isNotEmpty && revision == _factsRevision) {
      _similarDone[collectionId] = _copyRows(out);
    }
    return out;
  }

  /// Reads the movies of [ids] with a pool of workers (no waiting for the
  /// slowest of a batch). Keeps going after a caller stops waiting.
  static Future<void> _warmPool(List<int> ids) async {
    var next = 0;
    Future<void> worker() async {
      while (true) {
        final i = next++;
        if (i >= ids.length) return;
        await _factsFor(ids[i]);
      }
    }

    await Future.wait([
      for (var w = 0; w < math.min(_factsWorkers, ids.length); w++) worker(),
    ]);
  }

  /// Weighted Jaccard overlap of two collections' genres: each genre counts
  /// by the share of the collection's movies that carry it, so a franchise
  /// that is mostly Horror matches other Horror franchises more than one
  /// that has a single Horror entry. 0 = nothing in common, 1 = identical.
  static double _similarity(_CollectionFacts a, _CollectionFacts b) {
    var shared = 0.0;
    var total = 0.0;
    final genres = <String>{...a.genreShare.keys, ...b.genreShare.keys};
    for (final genre in genres) {
      final x = a.genreShare[genre] ?? 0.0;
      final y = b.genreShare[genre] ?? 0.0;
      shared += math.min(x, y);
      total += math.max(x, y);
    }
    return total == 0 ? 0.0 : shared / total;
  }

  // ---------------------------------------------------------------------
  // Which collections exist
  // ---------------------------------------------------------------------

  /// The Collections library as BoxSet items, parental controls applied:
  /// VirtualCatalog's curated list first (most popular first), then
  /// [_extraNames]. With [max] only that many (and, when the curated list
  /// already fills it, no extra lookups at all).
  static Future<List<Map<String, dynamic>>> _pool({int? max}) async {
    // On the full list the extra lookups start now, so they overlap the
    // curated ones instead of waiting for them.
    final Future<List<Map<String, dynamic>>>? early =
    max == null ? _extraItems() : null;

    final curated = await VirtualCatalog.popularCollectionItems(max: max);
    if (max != null && curated.length >= max) {
      return curated.length > max ? curated.take(max).toList() : curated;
    }

    final extras = await (early ?? _extraItems());
    final merged = <Map<String, dynamic>>[...curated];
    final have = <String>{for (final item in curated) '${item['Id']}'};
    for (final item in extras) {
      if (have.add('${item['Id']}')) merged.add(item);
    }
    return max != null && merged.length > max
        ? merged.take(max).toList()
        : merged;
  }

  /// Name -> TMDB search result (id, name, poster_path, backdrop_path,
  /// overview). A name TMDB has no collection for is remembered as null; a
  /// failed request is forgotten so a later call retries it.
  static final Map<String, Future<Map<String, dynamic>?>> _lookups = {};

  static Future<Map<String, dynamic>?> _resolve(String name) =>
      _lookups[name] ??= _lookup(name);

  static Future<Map<String, dynamic>?> _lookup(String name) async {
    Map<String, dynamic>? data;
    try {
      data = await TmdbCatalogService.raw('/search/collection', {'query': name});
    } catch (e) {
      debugPrint('[VirtualCollectionDiscovery] lookup "$name" failed: $e');
    }

    final results = data?['results'];
    if (results is! List) {
      // The request itself failed (not "no such collection"): retry later.
      _lookups.remove(name);
      return null;
    }

    final want = _key(name);
    Map<String, dynamic>? prefix;
    for (final r in results.whereType<Map>()) {
      if (r['id'] is! num || r['poster_path'] == null) continue;
      final got = _key((r['name'] ?? '').toString());
      if (got == want) return Map<String, dynamic>.from(r);
      if (prefix == null && got.startsWith('$want ')) {
        prefix = Map<String, dynamic>.from(r);
      }
    }
    return prefix;
  }

  /// Lower-case words of a collection name without "collection" or a leading
  /// "the" ("The Hunger Games Collection" == "Hunger Games").
  static String _key(String name) {
    var n = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();
    n = n.replaceAll(RegExp(r'\bcollection\b'), ' ');
    n = n.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (n.startsWith('the ')) n = n.substring(4);
    return n;
  }

  /// The last finished [_extraItems] answer (null until one has finished).
  static List<Map<String, dynamic>>? _extrasCache;

  /// [_extraNames] as BoxSet items, parental controls applied. Never throws:
  /// a failure just means no extra collections this time.
  static Future<List<Map<String, dynamic>>> _extraItems() async {
    try {
      final found = <Map<String, dynamic>>[];
      final seen = <int>{};
      for (var i = 0; i < _extraNames.length; i += _nameChunk) {
        final slice = _extraNames.sublist(
          i,
          math.min(i + _nameChunk, _extraNames.length),
        );
        final results = await Future.wait(slice.map(_resolve));
        for (final r in results) {
          if (r == null) continue;
          final id = (r['id'] as num).toInt();
          if (seen.add(id)) found.add(r);
        }
      }
      final items = <Map<String, dynamic>>[
        for (final r in found) _boxSet(r),
      ];
      final allowed = await VirtualCatalog.filterCollectionMaps(items);
      _extrasCache = allowed;
      return allowed;
    } catch (e) {
      debugPrint('[VirtualCollectionDiscovery] extra collections failed: $e');
      return const [];
    }
  }

  /// A BoxSet item from a TMDB collection search result — the same shape
  /// VirtualCatalog gives the curated ones.
  static Map<String, dynamic> _boxSet(Map<String, dynamic> r) {
    final id = (r['id'] as num).toInt();
    final cid = VId.collectionOf(id);
    final poster = r['poster_path'] as String?;
    final backdrop = r['backdrop_path'] as String?;
    VirtualImages.register(cid, primary: poster, backdrop: backdrop);

    final name = (r['name'] ?? '').toString();
    return {
      'Id': cid,
      'ServerId': VirtualCatalog.serverId,
      'Name': name,
      'OriginalTitle': name,
      'SortName': name.toLowerCase(),
      'Type': 'BoxSet',
      'IsFolder': true,
      'Overview': (r['overview'] ?? '').toString(),
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

  // ---------------------------------------------------------------------
  // What a collection's movies say about it
  // ---------------------------------------------------------------------

  static final Map<int, Future<_CollectionFacts?>> _facts = {};
  static final Map<int, _CollectionFacts> _loaded = {};
  static int _factsRevision = -1;

  /// Forgets everything read so far when the Parental Controls rules change
  /// (the movies a collection shows, and so its facts, depend on them).
  static void _syncRevision() {
    final revision = ParentalControls.instance.revision.value;
    if (_factsRevision == revision) return;
    _factsRevision = revision;
    _facts.clear();
    _loaded.clear();
    _similarDone.clear();
    _similarRuns.clear();
    _extrasCache = null;
  }

  static Future<_CollectionFacts?> _factsFor(int id) {
    _syncRevision();
    final known = _facts[id];
    if (known != null) return known;

    final revision = _factsRevision;
    final future = _loadFacts(id).then((facts) {
      if (revision == _factsRevision) {
        if (facts != null) {
          _loaded[id] = facts;
        } else {
          // Not read (or no released movie): try again on a later request.
          _facts.remove(id);
        }
      }
      return facts;
    });
    _facts[id] = future;
    return future;
  }

  static _CollectionFacts? _factsLoaded(int id) {
    _syncRevision();
    return _loaded[id];
  }

  static Future<_CollectionFacts?> _loadFacts(int id) async {
    try {
      return _CollectionFacts.fromParts(await VirtualCatalog.collectionParts(id));
    } catch (e) {
      debugPrint('[VirtualCollectionDiscovery] movies of c$id failed: $e');
      return null;
    }
  }

  /// Reads the movies of every collection in [ids], [_factsChunk] at a time,
  /// until done or [_factsBudget] has passed (what was not reached stays
  /// unread and is picked up by the next request).
  static Future<void> _warmFacts(List<int> ids) async {
    final clock = Stopwatch()..start();
    for (var i = 0; i < ids.length; i += _factsChunk) {
      if (clock.elapsed > _factsBudget) break;
      final slice = ids.sublist(i, math.min(i + _factsChunk, ids.length));
      await Future.wait(slice.map(_factsFor));
    }
  }
}

/// What the grid sorts by and "More Like This" matches on, from a
/// collection's released movies.
class _CollectionFacts {
  final int movieCount;
  final int? firstYear;

  /// Newest release date among the movies, "YYYY-MM-DD" ("" if unknown).
  final String latestRelease;

  /// Average TMDB rating of the rated movies (0 when none is rated).
  final double rating;

  /// Genre name -> share (0..1) of the movies that carry it.
  final Map<String, double> genreShare;

  const _CollectionFacts({
    required this.movieCount,
    required this.firstYear,
    required this.latestRelease,
    required this.rating,
    required this.genreShare,
  });

  /// [parts] are movie items as VirtualCatalog.collectionParts returns them.
  static _CollectionFacts? fromParts(List<Map<String, dynamic>> parts) {
    if (parts.isEmpty) return null;

    int? firstYear;
    var latest = '';
    var ratingSum = 0.0;
    var rated = 0;
    final genreCounts = <String, int>{};

    for (final part in parts) {
      final year = part['ProductionYear'];
      if (year is num) {
        final y = year.toInt();
        if (firstYear == null || y < firstYear) firstYear = y;
      }

      final premiere = part['PremiereDate'];
      if (premiere is String && premiere.length >= 10) {
        final day = premiere.substring(0, 10);
        if (day.compareTo(latest) > 0) latest = day;
      }

      final rating = part['CommunityRating'];
      if (rating is num && rating > 0) {
        ratingSum += rating.toDouble();
        rated++;
      }

      final genres = part['Genres'];
      if (genres is List) {
        for (final genre in genres.map((g) => g.toString()).toSet()) {
          genreCounts[genre] = (genreCounts[genre] ?? 0) + 1;
        }
      }
    }

    return _CollectionFacts(
      movieCount: parts.length,
      firstYear: firstYear,
      latestRelease: latest,
      rating: rated == 0 ? 0.0 : (ratingSum / rated * 10).round() / 10,
      genreShare: {
        for (final e in genreCounts.entries) e.key: e.value / parts.length,
      },
    );
  }
}

class _Ranked {
  final Map<String, dynamic> item;
  final int index;
  final _CollectionFacts? facts;
  const _Ranked(this.item, this.index, this.facts);
}

class _Scored {
  final Map<String, dynamic> item;
  final int index;
  final double score;
  final _CollectionFacts facts;
  const _Scored(this.item, this.index, this.score, this.facts);
}