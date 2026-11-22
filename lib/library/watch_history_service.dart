import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../catalog/catalog_models.dart';
import '../catalog/next_episode_service.dart';
import '../player/models/media_item.dart';
import '../player/player_manager.dart';
import 'source_preferences.dart';
import 'watch_entry.dart';

/// Local replacement for what Jellyfin used to remember for us: where you
/// stopped (Continue Watching), your list (watchlist) and which episodes you
/// have finished. Everything lives on the device in SharedPreferences, keyed
/// by TMDB id, so it does not depend on any server or addon.
///
/// Progress is read from [PlayerManager] (position / duration), so
/// PlayerManager itself needs no changes. Call [init] once at startup. Which
/// title/episode is playing is read from the MediaItem's `raw` map
/// (`NamesisTitle` / `NamesisEpisode`, written by CatalogPlayback), so it
/// works the same whether the person tapped Play or the next episode
/// auto-started.
class WatchHistoryService {
  WatchHistoryService._();
  static final WatchHistoryService instance = WatchHistoryService._();

  static const String _historyKey = 'namesis_history_v1';
  static const String _watchlistKey = 'namesis_watchlist_v1';
  static const String _watchedKey = 'namesis_watched_v1';
  static const String _epProgKey = 'namesis_epprog_v1';

  /// How many titles are remembered in total (finished ones included). Kept
  /// well above [_maxContinue] so that when a Continue Watching card is
  /// removed there are still older in-progress titles stored to take its
  /// place.
  static const int _maxEntries = 200;

  /// Continue Watching shows at most this many cards.
  static const int _maxContinue = 30;

  /// At or beyond this fraction the title counts as watched.
  static const double _finishedFraction = 0.92;

  /// Positions earlier than this are not worth resuming from.
  static const Duration _minResume = Duration(seconds: 20);

  /// Ticks before this are ignored so the transient 0:00 at the start of an
  /// open can never overwrite a saved resume point.
  static const int _minRecordMs = 3000;

  static const Duration _writeEvery = Duration(seconds: 5);

  /// In-progress titles, most recently watched first (at most
  /// [_maxContinue]).
  final ValueNotifier<List<WatchEntry>> continueWatching =
      ValueNotifier(const []);

  /// EVERY in-progress title, most recently watched first, with no cap.
  /// Callers that filter the list afterwards (Parental Controls) use this and
  /// cap the result themselves, so a hidden title never leaves a gap that a
  /// still-stored older one could have filled.
  List<WatchEntry> get allContinueWatching => _inProgress();

  /// Saved titles, most recently added first.
  final ValueNotifier<List<TitleSnapshot>> watchlist = ValueNotifier(const []);

  final Map<String, WatchEntry> _entries = {};
  final Map<String, Set<String>> _watched = {};

  /// Partly watched episodes: title key -> {"SxE": [positionMs, durationMs]}.
  /// [_entries] only remembers the one episode watched last, so without this
  /// the episode lists could show progress for just that one.
  final Map<String, Map<String, List<int>>> _epProgress = {};

  /// Bumped whenever an episode's progress changes, so open lists repaint.
  final ValueNotifier<int> progressRevision = ValueNotifier(0);

  bool _inited = false;

  _ActivePlayback? _active;
  int _lastPosMs = 0;
  int _lastDurMs = 0;
  DateTime _lastWrite = DateTime.fromMillisecondsSinceEpoch(0);

  // ---------- lifecycle ----------

  Future<void> init() async {
    if (_inited) return;
    _inited = true;
    await _load();

    final pm = PlayerManager.instance;
    pm.position.addListener(_onTick);
    pm.currentItemNotifier.addListener(_onItemChanged);
    pm.playbackFinished.addListener(_onFinishedFlag);
  }

  /// Re-reads everything from disk, replacing what is in memory. Used when
  /// the signed-in account changes or newer data arrives from the cloud.
  Future<void> reloadFromStorage() => _load(replace: true);

  Future<void> _load({bool replace = false}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (replace) {
        _entries.clear();
        _watched.clear();
        _epProgress.clear();
        watchlist.value = const [];
        progressRevision.value++;
      }

      final h = prefs.getString(_historyKey);
      if (h != null && h.isNotEmpty) {
        final decoded = jsonDecode(h);
        if (decoded is List) {
          for (final raw in decoded) {
            final e = WatchEntry.fromJson(raw);
            if (e != null) _entries[e.key] = e;
          }
        }
      }

      final w = prefs.getString(_watchlistKey);
      if (w != null && w.isNotEmpty) {
        final decoded = jsonDecode(w);
        if (decoded is List) {
          watchlist.value = decoded
              .map(TitleSnapshot.fromJson)
              .whereType<TitleSnapshot>()
              .toList();
        }
      }

      final seen = prefs.getString(_watchedKey);
      if (seen != null && seen.isNotEmpty) {
        final decoded = jsonDecode(seen);
        if (decoded is Map) {
          decoded.forEach((k, v) {
            if (v is List) {
              _watched[k.toString()] = v.map((e) => e.toString()).toSet();
            }
          });
        }
      }

      final ep = prefs.getString(_epProgKey);
      if (ep != null && ep.isNotEmpty) {
        final decoded = jsonDecode(ep);
        if (decoded is Map) {
          decoded.forEach((k, v) {
            if (v is! Map) return;
            final m = <String, List<int>>{};
            v.forEach((ek, ev) {
              if (ev is List && ev.length >= 2) {
                m[ek.toString()] = [
                  (ev[0] as num).toInt(),
                  (ev[1] as num).toInt(),
                ];
              }
            });
            if (m.isNotEmpty) _epProgress[k.toString()] = m;
          });
        }
      }
    } catch (e) {
      debugPrint('[WatchHistory] load failed: $e');
    }
    _publish();
  }

  // ---------- playback tracking ----------

  /// Starts tracking [item] if it is an addon stream carrying title metadata.
  void _adopt(MediaItem item) {
    final raw = item.raw;
    if (raw == null || raw['AddonStream'] != true) return;
    final title = TitleSnapshot.fromJson(raw['NamesisTitle']);
    if (title == null) return;
    _active = _ActivePlayback(
      title: title,
      episode: episodeFromRaw(raw['NamesisEpisode']),
      itemId: item.id,
    );
    _lastPosMs = 0;
    _lastDurMs = 0;
  }

  void _onTick() {
    final a = _active;
    if (a == null) return;

    final pm = PlayerManager.instance;
    final item = pm.currentItem;
    if (item == null || item.id != a.itemId) return;
    if (pm.loading.value) return;

    final pos = pm.position.value.inMilliseconds;
    final dur = pm.duration.value.inMilliseconds;
    if (dur <= 0) return;

    if (a.finished) {
      // The same item replayed from the start: track it afresh.
      if (pos < dur * 0.5) {
        a.finished = false;
      } else {
        return;
      }
    }

    _lastPosMs = pos;
    _lastDurMs = dur;

    if (pos >= dur * _finishedFraction) {
      _markFinished(a, dur);
      return;
    }
    if (pos < _minRecordMs) return;
    if (DateTime.now().difference(_lastWrite) < _writeEvery) return;
    _record(a, pos, dur);
  }

  void _onItemChanged() {
    final item = PlayerManager.instance.currentItem;
    final a = _active;
    // Same item (e.g. a metadata refresh of the playing item): nothing to do.
    if (a != null && item != null && item.id == a.itemId) return;

    _flush(); // save wherever the previous item got to
    _active = null;
    _lastPosMs = 0;
    _lastDurMs = 0;
    if (item != null) _adopt(item);
  }

  void _onFinishedFlag() {
    final a = _active;
    if (a == null || a.finished) return;
    if (!PlayerManager.instance.playbackFinished.value) return;
    // Only trust the flag if the person actually got most of the way.
    if (_lastDurMs > 0 && _lastPosMs >= _lastDurMs * 0.7) {
      _markFinished(a, _lastDurMs);
    }
  }

  void _flush() {
    final a = _active;
    if (a == null || a.finished) return;
    if (_lastDurMs > 0 && _lastPosMs >= _minRecordMs) {
      _record(a, _lastPosMs, _lastDurMs);
    }
  }

  WatchEntry _build(_ActivePlayback a, int pos, int dur, bool finished) {
    final ep = a.episode;
    return WatchEntry(
      title: a.title,
      season: ep?.season,
      episode: ep?.number,
      episodeName: ep?.name,
      episodeStillPath: ep?.stillPath,
      episodeRuntime: ep?.runtime,
      positionMs: finished ? 0 : pos,
      durationMs: dur,
      updatedAtMs: DateTime.now().millisecondsSinceEpoch,
      finished: finished,
    );
  }

  void _record(_ActivePlayback a, int pos, int dur) {
    _entries[a.title.key] = _build(a, pos, dur, false);
    final ep = a.episode;
    if (ep != null) {
      _epProgress.putIfAbsent(a.title.key, () => {})['${ep.season}x${ep.number}'] =
          [pos, dur];
      while (_epProgress.length > 80) {
        _epProgress.remove(_epProgress.keys.first);
      }
      unawaited(_persistEpProgress());
      progressRevision.value++;
    }
    _lastWrite = DateTime.now();
    _publish();
    unawaited(_persistHistory());
  }

  void _markFinished(_ActivePlayback a, int dur) {
    a.finished = true;
    _entries[a.title.key] = _build(a, 0, dur, true);

    final ep = a.episode;
    if (ep != null) {
      _watched
          .putIfAbsent(a.title.key, () => <String>{})
          .add('${ep.season}x${ep.number}');
      unawaited(_persistWatched());
      final m = _epProgress[a.title.key];
      if (m != null && m.remove('${ep.season}x${ep.number}') != null) {
        unawaited(_persistEpProgress());
      }
      progressRevision.value++;
    }
    _publish();
    unawaited(_persistHistory());
    if (ep != null) unawaited(_setUpNext(a, ep));
  }

  /// After an episode finishes, put the *next* one on Continue watching as
  /// "Up next".
  Future<void> _setUpNext(_ActivePlayback a, CatalogEpisode finishedEp) async {
    try {
      final next =
          await NextEpisodeService.findNext(a.title.toTitle(), finishedEp);
      if (next == null) return;

      // Only if nothing newer was recorded meanwhile (for example the next
      // episode already auto-started and has its own progress entry).
      final current = _entries[a.title.key];
      if (current == null ||
          !current.finished ||
          current.season != finishedEp.season ||
          current.episode != finishedEp.number) {
        return;
      }

      _entries[a.title.key] = WatchEntry(
        title: a.title,
        season: next.season,
        episode: next.number,
        episodeName: next.name,
        episodeStillPath: next.stillPath,
        episodeRuntime: next.runtime,
        positionMs: 0,
        durationMs: 0,
        updatedAtMs: DateTime.now().millisecondsSinceEpoch,
        upNext: true,
      );
      _publish();
      await _persistHistory();
    } catch (e) {
      debugPrint('[WatchHistory] up-next failed: $e');
    }
  }

  // ---------- embed playback ----------
  //
  // The embed web player (EmbedPlayerScreen) does not go through
  // PlayerManager, so it reports its progress here instead. It uses its own
  // tracker object so it can never interfere with the native one above.

  _ActivePlayback? _embedActive;
  int _embedPos = 0;
  int _embedDur = 0;

  /// Progress report from the embed player: [posMs] into a [durMs] long
  /// movie / episode. Same recording / finished rules as native playback.
  void recordEmbed({
    required CatalogTitle title,
    CatalogEpisode? episode,
    required int posMs,
    required int durMs,
  }) {
    if (durMs <= 0) return;
    final snap = TitleSnapshot.of(title);
    final epKey = episode == null ? '' : '${episode.season}x${episode.number}';

    var a = _embedActive;
    final aEp = a?.episode;
    final aKey = aEp == null ? '' : '${aEp.season}x${aEp.number}';
    if (a == null || a.title.key != snap.key || aKey != epKey) {
      a = _ActivePlayback(
        title: snap,
        episode: episode,
        itemId: 'embed_${snap.key}_$epKey',
      );
      _embedActive = a;
    }

    _embedPos = posMs;
    _embedDur = durMs;

    if (a.finished) {
      // The same item replayed from the start: track it afresh.
      if (posMs < durMs * 0.5) {
        a.finished = false;
      } else {
        return;
      }
    }
    if (posMs >= durMs * _finishedFraction) {
      _markFinished(a, durMs);
      return;
    }
    if (posMs < _minRecordMs) return;
    if (DateTime.now().difference(_lastWrite) < _writeEvery) return;
    _record(a, posMs, durMs);
  }

  /// The embed player closed or moved to another episode: save wherever the
  /// last one got to.
  void endEmbed() {
    final a = _embedActive;
    _embedActive = null;
    if (a != null && !a.finished && _embedDur > 0 && _embedPos >= _minRecordMs) {
      _record(a, _embedPos, _embedDur);
    }
    _embedPos = 0;
    _embedDur = 0;
  }

  // ---------- queries ----------

  WatchEntry? entryFor(CatalogTitle t) => _entries['${t.type.tmdb}:${t.tmdbId}'];

  /// Where to resume [t] (or one specific [e]pisode of it), or null to start
  /// from the beginning.
  Duration? positionFor(CatalogTitle t, [CatalogEpisode? e]) {
    final entry = entryFor(t);
    if (e != null) {
      if (entry != null &&
          !entry.finished &&
          entry.season == e.season &&
          entry.episode == e.number) {
        return entry.position < _minResume ? null : entry.position;
      }
      // Not the episode watched last: its own saved spot, if any.
      final p = episodeProgress(t.tmdbId, e.season, e.number);
      return p == null ? null : Duration(milliseconds: p[0]);
    }
    if (entry == null || entry.finished) return null;
    if (entry.isEpisode) return null;
    if (entry.position < _minResume) return null;
    return entry.position;
  }

  /// The in-progress entry for [t] (or its "Up next" entry), or null if it is
  /// finished or barely started. For a series this is the episode the person
  /// is partway through, or the one to watch next.
  WatchEntry? resumableEntry(CatalogTitle t) {
    final e = entryFor(t);
    if (e == null) return null;
    if (e.upNext) return e;
    if (e.finished || e.position < _minResume) return null;
    return e;
  }

  /// [positionMs, durationMs] of a partly watched episode, or null.
  List<int>? episodeProgress(int tmdbId, int season, int episode) {
    final p = _epProgress['tv:$tmdbId']?['${season}x$episode'];
    if (p == null || p[0] < _minResume.inMilliseconds || p[1] <= 0) return null;
    return p;
  }

  bool isWatched(int tmdbId, int season, int episode) =>
      _watched['tv:$tmdbId']?.contains('${season}x$episode') ?? false;

  // ---------- continue watching ----------

  /// Removes a card from Continue Watching AND wipes what made it resumable,
  /// so the title behaves like it was never started:
  ///  - its history entry (the card itself),
  ///  - the saved spot of the episode on the card (an episode keeps its own
  ///    copy in [_epProgress], which would otherwise still resume it from the
  ///    episode list),
  ///  - the remembered source link, so Play shows the source list again
  ///    instead of auto-picking the old one.
  /// "Watched" marks are left alone: removing a card does not un-watch or
  /// mark anything.
  Future<void> removeFromContinue(WatchEntry entry) async {
    final key = entry.key;
    _entries.remove(key);

    var epChanged = false;
    if (entry.isEpisode) {
      final m = _epProgress[key];
      if (m != null && m.remove('${entry.season}x${entry.episode}') != null) {
        if (m.isEmpty) _epProgress.remove(key);
        epChanged = true;
      }
    }

    // If this very title is playing right now, a late "save where it got to"
    // must not bring the card straight back.
    final a = _active;
    if (a != null && a.title.key == key) {
      _lastPosMs = 0;
      _lastDurMs = 0;
    }

    _publish();
    if (epChanged) progressRevision.value++;

    await _persistHistory();
    if (epChanged) await _persistEpProgress();
    await SourcePreferences.instance.forget(key);
  }

  // ---------- watchlist ----------

  bool isInWatchlist(CatalogTitle t) =>
      watchlist.value.any((s) => s.key == '${t.type.tmdb}:${t.tmdbId}');

  Future<void> toggleWatchlist(CatalogTitle t) async {
    final key = '${t.type.tmdb}:${t.tmdbId}';
    final current = watchlist.value;
    if (current.any((s) => s.key == key)) {
      watchlist.value = current.where((s) => s.key != key).toList();
    } else {
      watchlist.value = [
        TitleSnapshot.of(t,
            addedAtMs: DateTime.now().millisecondsSinceEpoch),
        ...current,
      ];
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _watchlistKey,
        jsonEncode(watchlist.value.map((s) => s.toJson()).toList()),
      );
    } catch (e) {
      debugPrint('[WatchHistory] watchlist save failed: $e');
    }
  }

  // ---------- internals ----------

  List<WatchEntry> _inProgress() {
    return _entries.values
        .where((e) =>
            e.upNext ||
            (!e.finished &&
                e.position >= _minResume &&
                e.progress < _finishedFraction))
        .toList()
      ..sort((a, b) => b.updatedAtMs.compareTo(a.updatedAtMs));
  }

  void _publish() {
    continueWatching.value = _inProgress().take(_maxContinue).toList();
  }

  Future<void> _persistHistory() async {
    try {
      // Newest first, capped so storage can't grow forever.
      final all = _entries.values.toList()
        ..sort((a, b) => b.updatedAtMs.compareTo(a.updatedAtMs));
      final keep = all.take(_maxEntries).toList();
      _entries
        ..clear()
        ..addEntries(keep.map((e) => MapEntry(e.key, e)));
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _historyKey,
        jsonEncode(keep.map((e) => e.toJson()).toList()),
      );
    } catch (e) {
      debugPrint('[WatchHistory] history save failed: $e');
    }
  }

  Future<void> _persistEpProgress() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_epProgKey, jsonEncode(_epProgress));
    } catch (e) {
      debugPrint('[WatchHistory] progress save failed: $e');
    }
  }

  Future<void> _persistWatched() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _watchedKey,
        jsonEncode(_watched.map((k, v) => MapEntry(k, v.toList()))),
      );
    } catch (e) {
      debugPrint('[WatchHistory] watched save failed: $e');
    }
  }
}

class _ActivePlayback {
  final TitleSnapshot title;
  final CatalogEpisode? episode;
  final String itemId;
  bool finished = false;

  _ActivePlayback({
    required this.title,
    required this.episode,
    required this.itemId,
  });
}
