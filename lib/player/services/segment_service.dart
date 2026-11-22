import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/media_item.dart';
import '../models/skip_segment.dart';
import '../../virtual/virtual_catalog.dart';

/// One chapter of the file being played (from mpv's chapter list).
class ChapterMark {
  final String title;
  final Duration start;
  const ChapterMark(this.title, this.start);
}

/// What the community database knew about one episode / movie.
class CommunitySegments {
  final SkipSegment? intro;
  final SkipSegment? outro;

  /// The "Previously on…" summary (episodes only).
  final SkipSegment? recap;

  /// The community confirmed this episode has no intro / no credits segment,
  /// so no guessing (and no manual skip button) is wanted for it.
  final bool noIntro;
  final bool noOutro;

  const CommunitySegments({
    this.intro,
    this.outro,
    this.recap,
    this.noIntro = false,
    this.noOutro = false,
  });

  static const empty = CommunitySegments();
}

/// Where Skip Intro / Skip Credits (and the Next Episode / Next Movie cue)
/// come from for titles played through addons. Jellyfin's Media Segments no
/// longer exist for those, so three sources are combined:
///
///  1. Community databases: TheIntroDB (api.theintrodb.org, by TMDB id) first,
///     then IntroDB (api.introdb.app, by IMDb id) for whatever it lacks.
///     Both are free, no key for reading.
///  2. Chapter markers inside the file ("Intro", "Opening", "Credits",
///     "Ending", ...), read from the player once the file is open.
///  3. (Off) the old guessed "Skip 85s" button; with no data there is no
///     skip-intro button at all.
///
/// Community data wins over chapters when both exist.
class SegmentService {
  SegmentService._();

  static const String _base = 'https://api.introdb.app/segments';
  static const String _tidbBase = 'https://api.theintrodb.org/v4/media';
  static const String _cacheKey = 'namesis_segments_v3';
  static const int _maxCached = 400;
  static const Duration _hitTtl = Duration(days: 30);
  static const Duration _missTtl = Duration(days: 3);

  /// The manual button: shows between these two points of an episode and
  /// jumps this far ahead.
  static const Duration manualFrom = Duration(seconds: 20);
  static const Duration manualUntil = Duration(minutes: 4);
  static const Duration manualJump = Duration(seconds: 85);

  static Map<String, dynamic>? _cache;
  static final Map<String, Future<CommunitySegments>> _inflight = {};

  // ---------- item helpers ----------

  static bool isEpisode(MediaItem item) => item.raw?['Type'] == 'Episode';

  static String? _imdbOf(MediaItem item) {
    final raw = item.raw;
    if (raw == null) return null;
    final ids = raw['ProviderIds'];
    final fromIds = (ids is Map) ? ids['Imdb']?.toString() : null;
    final id = (fromIds != null && fromIds.isNotEmpty)
        ? fromIds
        : raw['SeriesImdbId']?.toString();
    if (id == null || !RegExp(r'^tt\d{7,8}$').hasMatch(id)) return null;
    return id;
  }

  static int? _tmdbOf(MediaItem item) {
    final raw = item.raw;
    int? n(dynamic v) {
      final i = int.tryParse(v?.toString() ?? '');
      return (i != null && i > 0) ? i : null;
    }

    if (raw != null) {
      final direct = n(raw['TmdbId']);
      if (direct != null) return direct;
      final ids = raw['ProviderIds'];
      if (ids is Map) {
        final p = n(ids['Tmdb']);
        if (p != null) return p;
      }
    }
    for (final id in [item.seriesId, item.id]) {
      if (id == null) continue;
      try {
        final t = VId.parse(id).tmdbId;
        if (t > 0) return t;
      } catch (_) {}
    }
    return null;
  }

  static String? _keyOf(MediaItem item) {
    final imdb = _imdbOf(item);
    final tmdb = _tmdbOf(item);
    final base = tmdb != null ? 't$tmdb' : imdb;
    if (base == null) return null;
    if (isEpisode(item)) {
      final s = item.seasonNumber, e = item.episodeNumber;
      if (s == null || e == null || s < 1 || e < 1) return null;
      return '$base:$s:$e';
    }
    return '$base:movie';
  }

  // ---------- community database ----------

  /// Never throws. Results (including "nothing known") are cached on disk;
  /// a network failure is not cached.
  static Future<CommunitySegments> community(MediaItem item) {
    final key = _keyOf(item);
    if (key == null) return Future.value(CommunitySegments.empty);
    return _inflight[key] ??= _communityUncached(item, key).whenComplete(() {
      _inflight.remove(key);
    });
  }

  static Future<CommunitySegments> _communityUncached(
      MediaItem item, String key) async {
    try {
      final cached = await _readCache(key);
      if (cached != null) return cached;

      // Both databases are asked at the same time (not one after the other,
      // which made a slow TheIntroDB hold back IntroDB's answer), each by
      // the id it uses. A failed request is never cached.
      final tmdb = _tmdbOf(item);
      final imdb = _imdbOf(item);
      final episode = isEpisode(item);

      Future<({dynamic json, bool failed})?> askTidb() async {
        if (tmdb == null) return null;
        final q = <String, String>{'tmdb_id': '$tmdb'};
        if (episode) {
          q['season'] = '${item.seasonNumber}';
          q['episode'] = '${item.episodeNumber}';
        }
        return _fetchJson(_tidbBase, q);
      }

      Future<({dynamic json, bool failed})?> askIntroDb() async {
        if (imdb == null) return null;
        final q = <String, String>{'imdb_id': imdb};
        if (episode) {
          q['season'] = '${item.seasonNumber}';
          q['episode'] = '${item.episodeNumber}';
        } else {
          q['is_movie'] = 'true';
        }
        return _fetchJson(_base, q);
      }

      final answers = await Future.wait([askTidb(), askIntroDb()]);
      final rt = answers[0];
      final ri = answers[1];
      final failed = (rt?.failed ?? false) || (ri?.failed ?? false);
      final CommunitySegments? tidb =
          (rt != null && rt.json != null) ? _parseTidb(rt.json, item) : null;
      final CommunitySegments? idb =
          (ri != null && ri.json != null) ? _parse(ri.json, item) : null;

      // Credits start: TheIntroDB often has no credits at all, IntroDB
      // often does. When both do, trust neither blindly: drop a value that
      // cannot be right for this file's length, and when two plausible ones
      // disagree take the LATER start, so Skip Credits / Next Episode never
      // fire before the credits have really begun.
      final outro = _chooseOutro(
        [tidb?.outro, idb?.outro],
        item.runtime,
        episode,
      );
      debugPrint('[SegmentService] ${item.id}: '
          'theintrodb outro=${_fmt(tidb?.outro)} introdb outro=${_fmt(idb?.outro)} '
          '-> using ${_fmt(outro)} (runtime ${item.runtime.inSeconds}s)');

      final merged = CommunitySegments(
        intro: tidb?.intro ?? idb?.intro,
        outro: outro,
        recap: tidb?.recap ?? idb?.recap,
        noIntro: (tidb?.noIntro ?? false) || (idb?.noIntro ?? false),
        noOutro: (tidb?.noOutro ?? false) || (idb?.noOutro ?? false),
      );
      final knownSomething = merged.intro != null ||
          merged.outro != null ||
          merged.recap != null;
      if (!failed || knownSomething) await _writeCache(key, merged);
      return merged;
    } catch (e) {
      debugPrint('[SegmentService] community lookup failed: $e');
      return CommunitySegments.empty;
    }
  }

  static String _fmt(SkipSegment? s) =>
      s == null ? 'none' : '${s.start.inSeconds}s';

  /// Whether a credits window can be right for a file of length [total]:
  /// it must start before the end, and an episode's credits never run
  /// longer than 8 minutes (a movie's 30). Unknown length (zero) passes.
  static bool plausibleOutro(SkipSegment s, Duration total, bool episode) {
    if (total <= Duration.zero) return true;
    if (s.start >= total - const Duration(seconds: 10)) return false;
    final left = total - s.start;
    return left <= (episode ? const Duration(minutes: 8) : const Duration(minutes: 30));
  }

  static SkipSegment? _chooseOutro(
      List<SkipSegment?> candidates, Duration total, bool episode) {
    SkipSegment? best;
    for (final c in candidates) {
      if (c == null || !plausibleOutro(c, total, episode)) continue;
      if (best == null || c.start > best.start) best = c;
    }
    return best;
  }

  /// GET [base] with [query]. 404 → no data (json null, not failed); any
  /// other problem → failed.
  static Future<({dynamic json, bool failed})> _fetchJson(
      String base, Map<String, String> query) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 6);
    try {
      final req = await client
          .getUrl(Uri.parse(base).replace(queryParameters: query))
          .timeout(const Duration(seconds: 6));
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      req.headers.set(HttpHeaders.userAgentHeader, 'NamesisPrime/1.0');
      final resp = await req.close().timeout(const Duration(seconds: 8));
      final body = await resp
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 8));
      if (resp.statusCode == 404) return (json: null, failed: false);
      if (resp.statusCode != 200) return (json: null, failed: true);
      return (json: jsonDecode(body), failed: false);
    } catch (e) {
      debugPrint('[SegmentService] $base failed: $e');
      return (json: null, failed: true);
    } finally {
      client.close(force: true);
    }
  }

  /// TheIntroDB: `intro` / `credits` are arrays of `{start_ms, end_ms}`;
  /// a null start means "from the beginning", a null end "to the end".
  static CommunitySegments _parseTidb(dynamic json, MediaItem item) {
    if (json is! Map) return CommunitySegments.empty;

    SkipSegment? intro;
    final intros = json['intro'];
    if (intros is List) {
      for (final j in intros) {
        if (j is! Map) continue;
        final s = j['start_ms'], e = j['end_ms'];
        if (e is! num) continue;
        final start = Duration(milliseconds: s is num ? s.toInt() : 0);
        final end = Duration(milliseconds: e.toInt());
        final len = end - start;
        if (len < const Duration(seconds: 5) ||
            len > const Duration(minutes: 6)) {
          continue;
        }
        intro = SkipSegment(
            start: start, end: end, type: SkipSegmentType.intro);
        break;
      }
    }

    // "Previously on…" — episodes only, a few seconds to a few minutes.
    SkipSegment? recap;
    final recaps = json['recap'];
    if (recaps is List && isEpisode(item)) {
      for (final j in recaps) {
        if (j is! Map) continue;
        final s = j['start_ms'], e = j['end_ms'];
        if (e is! num) continue;
        final start = Duration(milliseconds: s is num ? s.toInt() : 0);
        final end = Duration(milliseconds: e.toInt());
        final len = end - start;
        if (len < const Duration(seconds: 5) ||
            len > const Duration(minutes: 5)) {
          continue;
        }
        recap = SkipSegment(
            start: start, end: end, type: SkipSegmentType.recap);
        break;
      }
    }

    SkipSegment? outro;
    final credits = json['credits'];
    if (credits is List) {
      for (final j in credits.reversed) {
        if (j is! Map) continue;
        final s = j['start_ms'], e = j['end_ms'];
        if (s is! num) continue;
        final start = Duration(milliseconds: s.toInt());
        Duration end;
        if (e is num) {
          end = Duration(milliseconds: e.toInt());
        } else {
          end = item.runtime > start
              ? item.runtime
              : start + const Duration(minutes: 30);
        }
        if (end <= start) continue;
        outro = SkipSegment(
            start: start, end: end, type: SkipSegmentType.outro);
        break;
      }
    }
    return CommunitySegments(intro: intro, outro: outro, recap: recap);
  }

  static CommunitySegments _parse(dynamic json, MediaItem item) {
    if (json is! Map) return CommunitySegments.empty;
    return CommunitySegments(
      intro: _segment(json['intro'], SkipSegmentType.intro, item.runtime),
      outro: _segment(json['outro'], SkipSegmentType.outro, item.runtime),
      noIntro: json['no_intro'] == true,
      noOutro: json['no_outro'] == true,
    );
  }

  static SkipSegment? _segment(
      dynamic j, SkipSegmentType type, Duration runtime) {
    if (j is! Map) return null;
    final s = j['start_ms'], e = j['end_ms'];
    final isOutro = type == SkipSegmentType.outro;
    // An intro with no start begins at 0; credits with no end run to the
    // end of the file. (Before, a null end dropped the credits entirely,
    // which left only the early guess.)
    if (s is! num && isOutro) return null;
    if (e is! num && !isOutro) return null;
    final start = Duration(milliseconds: s is num ? s.toInt() : 0);
    final Duration end;
    if (e is num) {
      end = Duration(milliseconds: e.toInt());
    } else {
      end = runtime > start ? runtime : start + const Duration(minutes: 30);
    }
    if (end <= start) return null;
    // An intro is seconds to a few minutes, never longer.
    if (type == SkipSegmentType.intro &&
        (end - start < const Duration(seconds: 5) ||
            end - start > const Duration(minutes: 6))) {
      return null;
    }
    return SkipSegment(start: start, end: end, type: type);
  }

  // ---------- disk cache ----------

  static Future<Map<String, dynamic>> _loadCache() async {
    if (_cache != null) return _cache!;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_cacheKey);
      if (raw != null && raw.isNotEmpty) {
        final d = jsonDecode(raw);
        if (d is Map) return _cache = Map<String, dynamic>.from(d);
      }
    } catch (_) {}
    return _cache = <String, dynamic>{};
  }

  static List<int>? _pair(SkipSegment? s) =>
      s == null ? null : [s.start.inMilliseconds, s.end.inMilliseconds];

  static Future<void> _writeCache(String key, CommunitySegments c) async {
    try {
      final cache = await _loadCache();
      cache.remove(key);
      cache[key] = {
        't': DateTime.now().millisecondsSinceEpoch,
        'i': _pair(c.intro),
        'o': _pair(c.outro),
        'r': _pair(c.recap),
        'ni': c.noIntro,
        'no': c.noOutro,
      };
      while (cache.length > _maxCached) {
        cache.remove(cache.keys.first);
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_cacheKey, jsonEncode(cache));
    } catch (_) {}
  }

  static Future<CommunitySegments?> _readCache(String key) async {
    final cache = await _loadCache();
    final v = cache[key];
    if (v is! Map) return null;
    final t = v['t'];
    if (t is! num) return null;
    final empty = v['i'] == null &&
        v['o'] == null &&
        v['r'] == null &&
        v['ni'] != true &&
        v['no'] != true;
    final age =
        DateTime.now().millisecondsSinceEpoch - t.toInt();
    if (age > (empty ? _missTtl : _hitTtl).inMilliseconds) return null;

    SkipSegment? seg(dynamic p, SkipSegmentType type) {
      if (p is! List || p.length < 2) return null;
      return SkipSegment(
        start: Duration(milliseconds: (p[0] as num).toInt()),
        end: Duration(milliseconds: (p[1] as num).toInt()),
        type: type,
      );
    }

    return CommunitySegments(
      intro: seg(v['i'], SkipSegmentType.intro),
      outro: seg(v['o'], SkipSegmentType.outro),
      recap: seg(v['r'], SkipSegmentType.recap),
      noIntro: v['ni'] == true,
      noOutro: v['no'] == true,
    );
  }

  // ---------- chapters ----------

  static final RegExp _introTitle = RegExp(
    r'(^|\b)(intro(duction)?|opening( credits| sequence| theme| titles)?|'
    r'op\d*|title (sequence|card)|main title|theme song)(\b|$)',
    caseSensitive: false,
  );
  static final RegExp _outroTitle = RegExp(
    r'(^|\b)(end(ing)?( credits| titles| sequence| theme)?|credits?|'
    r'outro|closing( credits)?|ed\d*)(\b|$)',
    caseSensitive: false,
  );
  static final RegExp _recapTitle = RegExp(
    r'(^|\b)(previously( on)?|recap|story so far|last time on)(\b|$)',
    caseSensitive: false,
  );
  static final RegExp _notOutro = RegExp(
    r'(post|after|mid|bonus|preview|next|previously|recap)',
    caseSensitive: false,
  );

  /// Intro / credits windows taken from chapter titles. [total] is the file's
  /// length (zero if unknown).
  static List<SkipSegment> fromChapters(
      List<ChapterMark> chapters, Duration total) {
    if (chapters.length < 2) return const [];
    final sorted = [...chapters]..sort((a, b) => a.start.compareTo(b.start));

    Duration endOf(int i) =>
        i + 1 < sorted.length ? sorted[i + 1].start : total;

    SkipSegment? intro;
    SkipSegment? outro;
    SkipSegment? recap;
    for (var i = 0; i < sorted.length; i++) {
      final title = sorted[i].title.trim();
      if (title.isEmpty) continue;
      final start = sorted[i].start;
      final end = endOf(i);
      if (end <= start) continue;
      final len = end - start;

      if (recap == null &&
          _recapTitle.hasMatch(title) &&
          len >= const Duration(seconds: 8) &&
          len <= const Duration(minutes: 5) &&
          (total <= Duration.zero || start < total * 0.4)) {
        recap = SkipSegment(
            start: start, end: end, type: SkipSegmentType.recap);
      }

      if (intro == null &&
          _introTitle.hasMatch(title) &&
          !_notOutro.hasMatch(title) &&
          len >= const Duration(seconds: 8) &&
          len <= const Duration(minutes: 5) &&
          (total <= Duration.zero || start < total * 0.4)) {
        intro = SkipSegment(
            start: start, end: end, type: SkipSegmentType.intro);
      }

      if (_outroTitle.hasMatch(title) &&
          !_notOutro.hasMatch(title) &&
          !_introTitle.hasMatch(title) &&
          (total <= Duration.zero || start >= total * 0.5)) {
        outro = SkipSegment(
            start: start,
            end: end > Duration.zero ? end : total,
            type: SkipSegmentType.outro);
      }
    }
    return [
      if (recap != null) recap,
      if (intro != null) intro,
      if (outro != null) outro,
    ];
  }

  // ---------- putting it together ----------

  /// The segments to use: community first, chapters for whatever is still
  /// missing, and a manual skip button for episodes with no intro known.
  static List<SkipSegment> compose({
    required MediaItem item,
    required CommunitySegments community,
    List<SkipSegment> chapters = const [],
    // The real length of the file when known: a credits window that cannot
    // fit it (starts far too early, or after the end) is dropped.
    Duration total = Duration.zero,
    // The "Skip 85s" guess is switched off: no data, no skip button.
    bool allowManual = false,
  }) {
    SkipSegment? pick(SkipSegmentType t, SkipSegment? c) {
      if (c != null) return c;
      for (final s in chapters) {
        if (s.type == t) return s;
      }
      return null;
    }

    // Movies never get a Skip Intro button — only Skip Credits / Next Movie,
    // from the credits data of TheIntroDB / IntroDB (or chapter markers).
    final intro = isEpisode(item)
        ? pick(SkipSegmentType.intro, community.intro)
        : null;
    var outro = pick(SkipSegmentType.outro, community.outro);
    if (outro != null && !plausibleOutro(outro, total, isEpisode(item))) {
      // Wrong for this file: better no credits window (the player then
      // estimates from the real length) than a Next Episode far too early.
      debugPrint('[SegmentService] ${item.id}: credits at '
          '${outro.start.inSeconds}s do not fit a ${total.inSeconds}s file; ignored');
      outro = null;
    }
    // "Previously on…" recap: episodes only.
    final recap = isEpisode(item)
        ? pick(SkipSegmentType.recap, community.recap)
        : null;

    final out = <SkipSegment>[
      if (recap != null) recap,
      if (intro != null) intro,
      if (outro != null) outro,
    ];

    if (allowManual &&
        intro == null &&
        !community.noIntro &&
        isEpisode(item)) {
      out.add(const SkipSegment(
        start: manualFrom,
        end: manualUntil,
        type: SkipSegmentType.intro,
        manual: true,
      ));
    }
    return out;
  }
}
