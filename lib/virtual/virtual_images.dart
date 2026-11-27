import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Top level so compute() can run it in a background isolate (`Object`, not a
// typed Map: generics are lost across an isolate boundary).
String _encodePaths(Object paths) => jsonEncode(paths);

/// Maps a virtual item id + Jellyfin image type to a TMDB image path.
///
/// The original screens build image URLs synchronously from just an item id
/// (`MediaService.getImageUrl(id, type: ...)`). A TMDB poster needs a file
/// path that only the API response knows, so every item the virtual server
/// returns registers its paths here first, and `MediaService.getImageUrl`
/// looks them up. The registry is saved to disk so cached home-screen data
/// from a previous launch still has pictures.
class VirtualImages {
  VirtualImages._();

  static const String _prefsKey = 'namesis_vimages_v1';
  /// How many ids are written to disk (the most recently registered).
  static const int _maxEntries = 4000;

  /// How many ids are kept in memory. This used to be the same 4000 and the
  /// OLDEST ids were deleted from memory on every save, so after browsing a
  /// few big grids the home screen's own ids were gone: returning to it built
  /// "no image" addresses and every card went blank until a refresh
  /// re-registered them.
  static const int _maxMemoryEntries = 40000;
  static const String _cdn = 'https://image.tmdb.org/t/p';

  /// id -> {Primary: '/x.jpg', Backdrop: '/y.jpg', Logo: '/z.png',
  ///        Thumb: '/y.jpg', kind: 'poster' | 'still' | 'profile'}
  static final Map<String, Map<String, String>> _paths = {};
  static bool _loaded = false;
  static Timer? _saveTimer;

  static Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw == null) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      decoded.forEach((k, v) {
        if (v is Map) {
          _paths.putIfAbsent(
            k.toString(),
            () => v.map((a, b) => MapEntry(a.toString(), b.toString())),
          );
        }
      });
    } catch (e) {
      debugPrint('[VirtualImages] load failed: $e');
    }
  }

  /// [kind] decides which TMDB size family `Primary` uses.
  static void register(
    String id, {
    String? primary,
    String? backdrop,
    String? logo,
    String kind = 'poster',
  }) {
    if (id.isEmpty) return;
    final existing = _paths[id] ?? <String, String>{};
    final next = Map<String, String>.from(existing);
    if (primary != null && primary.isNotEmpty) next['Primary'] = primary;
    if (backdrop != null && backdrop.isNotEmpty) {
      next['Backdrop'] = backdrop;
      next['Thumb'] = backdrop;
    }
    if (logo != null && logo.isNotEmpty) next['Logo'] = logo;
    next['kind'] = kind;
    if (mapEquals(existing, next)) return;
    // Re-insert so the most recently used ids are the newest.
    _paths.remove(id);
    _paths[id] = next;
    if (_paths.length > _maxMemoryEntries) {
      final drop =
          _paths.keys.take(_paths.length - _maxMemoryEntries).toList();
      for (final k in drop) {
        _paths.remove(k);
      }
    }
    _scheduleSave();
  }

  static void _scheduleSave() {
    _saveTimer?.cancel();
    // Browsing a big grid registers new ids constantly; a short debounce
    // re-encoded the whole (up to 4000 entry) table every few seconds
    // mid-scroll. [flush] saves it when the app is backgrounded instead.
    _saveTimer = Timer(const Duration(seconds: 12), _save);
  }

  /// Saves right away if a save is pending (call when the app is paused).
  static Future<void> flush() async {
    final t = _saveTimer;
    if (t == null || !t.isActive) return;
    t.cancel();
    await _save();
  }

  static Future<void> _save() async {
    try {
      // Only the saved copy is trimmed; memory keeps everything it has seen.
      final Map<String, Map<String, String>> toSave;
      if (_paths.length > _maxEntries) {
        final keep = _paths.keys.skip(_paths.length - _maxEntries);
        toSave = {for (final k in keep) k: _paths[k]!};
      } else {
        toSave = _paths;
      }
      final prefs = await SharedPreferences.getInstance();
      String encoded;
      try {
        encoded = await compute(_encodePaths, toSave);
      } catch (_) {
        encoded = jsonEncode(toSave);
      }
      await prefs.setString(_prefsKey, encoded);
    } catch (e) {
      debugPrint('[VirtualImages] save failed: $e');
    }
  }

  /// A TMDB image URL for [id], or null if nothing is registered for it (the
  /// caller then falls back to an unreachable URL, which the screens already
  /// handle with their placeholder / error widgets).
  ///
  /// [type] is a Jellyfin image type: Primary, Backdrop, Thumb, Logo, Banner.
  static String? urlFor(String id, String type, {int? maxWidth}) {
    final entry = _paths[id];
    if (entry == null) return null;

    final t = type == 'Banner' ? 'Backdrop' : type;
    final path = entry[t];
    if (path == null) return null;
    // A fallback logo (Fanart.tv) is stored as a complete URL, not a TMDB path.
    if (path.startsWith('http')) return path;

    final String size;
    if (t == 'Primary') {
      final kind = entry['kind'] ?? 'poster';
      if (kind == 'still') {
        size = (maxWidth ?? 0) > 400 ? 'w780' : 'w300';
      } else if (kind == 'profile') {
        size = 'w185';
      } else if (kind == 'backdrop') {
        // Library cards: a landscape image.
        size = (maxWidth ?? 0) > 500 ? 'w780' : 'w500';
      } else {
        size = (maxWidth ?? 0) > 400 ? 'w500' : 'w342';
      }
    } else if (t == 'Logo') {
      size = 'w500';
    } else {
      // Backdrop / Thumb
      final w = maxWidth ?? 0;
      size = w >= 1100 ? 'w1280' : (w >= 600 ? 'w780' : 'w500');
    }
    return '$_cdn/$size${path.startsWith('/') ? path : '/$path'}';
  }

  /// A small (w300) copy of [id]'s backdrop, for a near-instant first paint
  /// while the full-size one downloads. Null when no TMDB path is known.
  static String? backdropPreviewUrl(String id) {
    final path = _paths[id]?['Backdrop'];
    if (path == null || path.isEmpty || path.startsWith('http')) return null;
    return '$_cdn/w300${path.startsWith('/') ? path : '/$path'}';
  }

  static bool has(String id) => _paths.containsKey(id);
}
