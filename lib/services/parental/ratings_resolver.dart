import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../catalog/tmdb_catalog_service.dart';
import 'parental_models.dart';

/// A title's age rating as far as we could read it.
class RatingInfo {
  /// "PG-13", "TV-MA", ... null when the title has none we understand.
  final String? label;
  final int? level;

  /// False only when the lookup itself failed (offline, TMDB error).
  final bool known;
  const RatingInfo(this.label, this.level, {this.known = true});
  const RatingInfo.unknown()
      : label = null,
        level = null,
        known = false;
}

/// Finds and remembers age ratings (TMDB `release_dates` for movies,
/// `content_ratings` for shows).
///
/// Lists from TMDB carry no rating, so judging a list means one small request
/// per title the first time. Answers are kept on disk (60 days for rated
/// titles, 7 days for unrated ones) so each title is only ever looked up
/// once, and the requests run a handful at a time under a deadline.
class RatingResolver {
  RatingResolver._();
  static final RatingResolver instance = RatingResolver._();

  static const String _kCache = 'parental_ratings_v1';
  static const int _maxEntries = 6000;
  static const int _ratedTtlDays = 60;
  static const int _unratedTtlDays = 7;

  /// id -> [label ("" = none), level (-1 = none), epochDay]
  final Map<String, List<Object>> _cache = {};
  final Map<String, Future<RatingInfo>> _inflight = {};
  bool _loaded = false;
  Timer? _saveTimer;

  static int _today() =>
      DateTime.now().millisecondsSinceEpoch ~/ Duration.millisecondsPerDay;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kCache);
      if (raw == null) return;
      final j = jsonDecode(raw);
      if (j is! Map) return;
      for (final e in j.entries) {
        final v = e.value;
        if (v is List && v.length == 3) {
          _cache[e.key.toString()] = [
            v[0].toString(),
            (v[1] as num).toInt(),
            (v[2] as num).toInt(),
          ];
        }
      }
    } catch (e) {
      debugPrint('[RatingResolver] cache unreadable: ${e.runtimeType}');
    }
  }

  RatingInfo? _fromEntry(List<Object> e) {
    final label = e[0] as String;
    final level = e[1] as int;
    final age = _today() - (e[2] as int);
    final ttl = label.isEmpty ? _unratedTtlDays : _ratedTtlDays;
    if (age > ttl || age < 0) return null;
    return RatingInfo(label.isEmpty ? null : label, level < 0 ? null : level);
  }

  /// Instant answer from memory/disk, or null when we have none.
  RatingInfo? peek(String id) {
    final e = _cache[id];
    return e == null ? null : _fromEntry(e);
  }

  /// Teach the resolver a rating that was learned elsewhere (a details call).
  void remember(String id, String? cert) {
    if (cert == null || cert.isEmpty) return;
    final level = RatingScale.levelOf('US', cert);
    if (level == null) return;
    _store(id, RatingInfo(cert, level));
  }

  void _store(String id, RatingInfo r) {
    _cache[id] = [r.label ?? '', r.level ?? -1, _today()];
    _scheduleSave();
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 3), _save);
  }

  Future<void> _save() async {
    try {
      if (_cache.length > _maxEntries) {
        final sorted = _cache.entries.toList()
          ..sort((a, b) => (a.value[2] as int).compareTo(b.value[2] as int));
        for (final e in sorted.take(_cache.length - _maxEntries + 500)) {
          _cache.remove(e.key);
        }
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kCache, jsonEncode(_cache));
    } catch (_) {}
  }

  /// The rating of movie `m123` / show `s123`.
  Future<RatingInfo> resolve(String id) {
    final hit = peek(id);
    if (hit != null) return Future.value(hit);
    return _inflight[id] ??= _fetch(id).whenComplete(() {
      _inflight.remove(id);
    });
  }

  Future<RatingInfo> _fetch(String id) async {
    final isMovie = id.startsWith('m');
    final tmdbId = int.tryParse(id.substring(1));
    if (tmdbId == null || (!isMovie && !id.startsWith('s'))) {
      return const RatingInfo(null, null);
    }
    try {
      final data = await TmdbCatalogService.raw(
        isMovie ? '/movie/$tmdbId/release_dates' : '/tv/$tmdbId/content_ratings',
      );
      if (data == null || data['results'] is! List) {
        return const RatingInfo.unknown(); // not stored: try again later
      }
      final r = _parse(data['results'] as List, isMovie);
      _store(id, r);
      return r;
    } catch (e) {
      debugPrint('[RatingResolver] $id failed: ${e.runtimeType}');
      return const RatingInfo.unknown();
    }
  }

  static RatingInfo _parse(List results, bool isMovie) {
    for (final country in RatingScale.countries) {
      for (final c in results.whereType<Map>()) {
        if (c['iso_3166_1'] != country) continue;
        if (isMovie) {
          final dates = (c['release_dates'] is List)
              ? (c['release_dates'] as List).whereType<Map>().toList()
              : <Map>[];
          // Theatrical (3) first, then every other release type.
          dates.sort((a, b) {
            int rank(Map m) => m['type'] == 3 ? 0 : 1;
            return rank(a).compareTo(rank(b));
          });
          for (final d in dates) {
            final cert = (d['certification'] ?? '').toString().trim();
            final level = RatingScale.levelOf(country, cert);
            if (level != null) return RatingInfo(_label(country, cert), level);
          }
        } else {
          final cert = (c['rating'] ?? '').toString().trim();
          final level = RatingScale.levelOf(country, cert);
          if (level != null) return RatingInfo(_label(country, cert), level);
        }
      }
    }
    return const RatingInfo(null, null);
  }

  static String _label(String country, String cert) =>
      country == 'US' ? cert : '$cert ($country)';

  /// Looks up many ids a few at a time. Whatever has not finished by
  /// [deadline] comes back as [RatingInfo.unknown] (and keeps loading in the
  /// background for next time).
  Future<Map<String, RatingInfo>> resolveMany(
    Iterable<String> ids, {
    int concurrency = 10,
    Duration deadline = const Duration(seconds: 25),
  }) async {
    final out = <String, RatingInfo>{};
    final todo = <String>[];
    for (final id in ids.toSet()) {
      final hit = peek(id);
      if (hit != null) {
        out[id] = hit;
      } else {
        todo.add(id);
      }
    }
    if (todo.isEmpty) return out;

    final queue = List<String>.from(todo);
    final stop = DateTime.now().add(deadline);

    Future<void> worker() async {
      while (queue.isNotEmpty && DateTime.now().isBefore(stop)) {
        final id = queue.removeLast();
        out[id] = await resolve(id);
      }
    }

    final workers = [
      for (var i = 0; i < concurrency && i < todo.length; i++) worker(),
    ];
    await Future.wait(workers).timeout(
      deadline + const Duration(seconds: 5),
      onTimeout: () => const [],
    );
    for (final id in todo) {
      out.putIfAbsent(id, () => const RatingInfo.unknown());
    }
    return out;
  }
}
