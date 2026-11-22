import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../jellyfin_services/jellyfin_client.dart';

/// Persistent (memory + disk) stale-while-revalidate cache for the big list
/// payloads behind the Movies grid, the Music tabs and Live TV.
///
/// ROOT CAUSE this exists for: Movies / Music / Live TV are built lazily the
/// first time their tab is tapped (see MainNavScreen._builtTabs), and until
/// now every one of them started from an EMPTY in-memory cache at that
/// moment — so the person always waited for a full server round trip (for
/// Songs: up to 5000 items) with a spinner/skeleton on screen, on every app
/// launch. Nothing survived between launches except Live TV's single
/// SharedPreferences blob.
///
/// How it behaves:
///   * [peek] returns what's already decoded in memory, synchronously — a
///     screen can paint it in initState, i.e. in its very first frame.
///   * [read] falls back to the copy persisted by a previous session. The
///     file read is async and the JSON decode runs in a background isolate,
///     so it never blocks the UI thread.
///   * [fetch] runs the network loader, de-duplicates concurrent callers of
///     the same key (the background prewarm and a screen opening at the same
///     moment share ONE request), and stores the result for next time.
///   * Everything is scoped to server + user, so switching account/server
///     can never show the previous account's library.
///
/// Disk copies are "slimmed" (see [_slimItem]): the per-stream track dumps
/// that Jellyfin attaches to every media source are dropped because they're
/// the bulk of a song/movie payload and are re-fetched lazily wherever they
/// are actually needed. MediaSources[].Container (needed by Download) stays.
class LibraryCache {
  LibraryCache._();
  static final LibraryCache instance = LibraryCache._();

  final Map<String, Object> _memory = {};
  final Set<String> _freshThisSession = {};
  final Map<String, Future<Object?>> _inflightReads = {};
  final Map<String, Future<List<dynamic>>> _inflightFetches = {};

  Future<void> _writeChain = Future<void>.value();
  Directory? _dir;

  // Bumped by clearAll() so a disk write queued before the clear can't
  // resurrect a file afterwards.
  int _generation = 0;

  /// Changes every time [clearAll] runs (logout, Settings > Clear Cache), so
  /// LibraryPrefetcher knows to warm everything again afterwards.
  int get generation => _generation;

  // ---------------------------------------------------------------------
  // Keys
  // ---------------------------------------------------------------------

  static String _fnv(String s) {
    var h = 0x811c9dc5;
    for (final unit in s.codeUnits) {
      h ^= unit;
      h = (h * 0x01000193) & 0xFFFFFFFF;
    }
    return h.toRadixString(16).padLeft(8, '0');
  }

  String get _scope =>
      _fnv('${JellyfinClient.serverUrl}|${JellyfinClient.userId}');

  String _k(String key) {
    final safe = key.replaceAll(RegExp(r'[^A-Za-z0-9_\-]'), '_');
    return '${_scope}__${safe}_${_fnv(key)}';
  }

  // ---------------------------------------------------------------------
  // Read
  // ---------------------------------------------------------------------

  /// Whatever is already decoded in memory for [key] (a List or a Map), or
  /// null. Synchronous — safe to call from initState.
  Object? peek(String key) => _memory[_k(key)];

  /// True once [key] has been loaded from the network during this app
  /// session (as opposed to only being a copy persisted by an earlier one).
  bool isFresh(String key) => _freshThisSession.contains(_k(key));

  /// [peek], else the copy persisted by an earlier session. Returns null if
  /// there isn't one (or it's unreadable).
  Future<Object?> read(String key) {
    final k = _k(key);
    final inMemory = _memory[k];
    if (inMemory != null) return Future<Object?>.value(inMemory);

    final pending = _inflightReads[k];
    if (pending != null) return pending;

    final future = () async {
      try {
        final dir = await _directory();
        final file = File('${dir.path}/$k.json');
        if (!await file.exists()) return null;

        final text = await file.readAsString();
        final decoded = await compute(_decodeJson, text);
        if (decoded == null) return null;

        // putIfAbsent: if a newer network result landed while we were
        // reading the file, keep that one.
        _memory.putIfAbsent(k, () => decoded);
        return _memory[k];
      } catch (e) {
        debugPrint('LibraryCache.read($key): $e');
        return null;
      }
    }();

    _inflightReads[k] = future;
    future.then<void>(
      (_) {
        if (identical(_inflightReads[k], future)) _inflightReads.remove(k);
      },
      onError: (_) {
        if (identical(_inflightReads[k], future)) _inflightReads.remove(k);
      },
    );
    return future;
  }

  // ---------------------------------------------------------------------
  // Write / fetch
  // ---------------------------------------------------------------------

  /// Keeps [payload] in memory only (never touches disk). Used for data
  /// that already has its own persistent copy elsewhere.
  void putMemory(String key, Object payload) {
    final k = _k(key);
    _memory[k] = payload;
    _freshThisSession.add(k);
  }

  void _store(String k, Object payload, {required bool persist}) {
    _memory[k] = payload;
    _freshThisSession.add(k);
    if (!persist) return;

    final generation = _generation;
    _writeChain = _writeChain.then((_) async {
      if (generation != _generation) return;
      try {
        final text = await _encodeInSlices(payload, generation);
        if (text == null || generation != _generation) return;

        final dir = await _directory();
        final tmp = File('${dir.path}/$k.json.tmp');
        await tmp.writeAsString(text, flush: true);
        await tmp.rename('${dir.path}/$k.json');
      } catch (e) {
        debugPrint('LibraryCache.write($k): $e');
      }
    });
  }

  /// JSON-encodes [payload] (slimming each item) a couple of hundred items at
  /// a time, yielding to the event loop between slices.
  ///
  /// Deliberately NOT done with compute()/Isolate.run: handing a 5000-song
  /// list to another isolate means deep-copying the whole object graph on
  /// the UI thread in one go, which is itself a visible frame hitch. Slices
  /// of ~200 items cost a millisecond or two each, so scrolling and
  /// animations never notice. Returns null if the cache was cleared midway.
  Future<String?> _encodeInSlices(Object payload, int generation) async {
    if (payload is! List) return jsonEncode(payload);

    // Snapshot: the Music screen removes items from its cached lists in
    // place (playlist/local-song deletion) — never iterate the live list
    // across awaits.
    final snapshot = List<dynamic>.of(payload);
    final buffer = StringBuffer('[');
    const slice = 200;

    for (var i = 0; i < snapshot.length; i++) {
      final item = snapshot[i];
      if (i > 0) buffer.write(',');
      buffer.write(jsonEncode(item is Map ? _slimItem(item) : item));

      if ((i + 1) % slice == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
        if (generation != _generation) return null;
      }
    }

    buffer.write(']');
    return buffer.toString();
  }

  /// Runs [loader], stores the result (memory, plus disk when [persist]) and
  /// returns it. Concurrent calls for the same [key] share one request.
  /// A failing [loader] throws to every waiter and caches nothing.
  Future<List<dynamic>> fetch(
    String key,
    Future<List<dynamic>> Function() loader, {
    bool persist = true,
  }) {
    final k = _k(key);

    final existing = _inflightFetches[k];
    if (existing != null) return existing;

    final future = () async {
      final data = await loader();
      _store(k, data, persist: persist);
      return data;
    }();

    _inflightFetches[k] = future;
    future.then<void>(
      (_) {
        if (identical(_inflightFetches[k], future)) _inflightFetches.remove(k);
      },
      onError: (_) {
        if (identical(_inflightFetches[k], future)) _inflightFetches.remove(k);
      },
    );
    return future;
  }

  // ---------------------------------------------------------------------
  // Clear
  // ---------------------------------------------------------------------

  /// Drops every cached payload (memory + disk), for every account. Called
  /// on logout and from Settings' "Clear Cache".
  Future<void> clearAll() async {
    _generation++;
    _memory.clear();
    _freshThisSession.clear();
    try {
      final dir = await _directory();
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (e) {
      debugPrint('LibraryCache.clearAll: $e');
    }
    _dir = null;
  }

  Future<Directory> _directory() async {
    final existing = _dir;
    if (existing != null) return existing;

    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/library_cache');
    if (!await dir.exists()) await dir.create(recursive: true);
    return _dir = dir;
  }
}

// Top-level so compute() can run the decode in a background isolate.

Object? _decodeJson(String text) {
  try {
    return jsonDecode(text) as Object?;
  } catch (_) {
    return null;
  }
}

Map<String, dynamic> _slimItem(Map item) {
  final out = <String, dynamic>{};
  item.forEach((key, value) {
    if (key == 'MediaStreams' || key == 'Trickplay') return;
    if (key == 'MediaSources' && value is List) {
      out[key as String] = value.map((source) {
        if (source is! Map) return source;
        return Map<String, dynamic>.from(source)..remove('MediaStreams');
      }).toList();
      return;
    }
    out[key as String] = value;
  });
  return out;
}
