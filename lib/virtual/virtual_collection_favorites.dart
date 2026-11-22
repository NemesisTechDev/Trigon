import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../catalog/tmdb_catalog_service.dart';
import 'virtual_catalog.dart';
import 'virtual_images.dart';

/// NAMESIS PRIME: favorite collections (TMDB movie collections shown as
/// Jellyfin BoxSets).
///
/// Works like the favorite cast & crew in [VirtualCatalog]: a small map kept
/// in SharedPreferences (and synced with the account by CloudSync under
/// `vc_fav_collections_v1`). A snapshot of the name, overview and artwork is
/// stored when the heart is tapped, so the Favorites page can list the
/// collection later without another TMDB request.
class VirtualCollectionFavorites {
  VirtualCollectionFavorites._();

  static const String storageKey = 'vc_fav_collections_v1';
  static final RegExp _collectionId = RegExp(r'^c(\d+)$');

  static Map<String, Map<String, dynamic>>? _loaded;

  /// True for ids shaped like a virtual collection id (`c10`).
  static bool isCollectionId(String id) => _collectionId.hasMatch(id);

  static Future<Map<String, Map<String, dynamic>>> _read() async {
    final loaded = <String, Map<String, dynamic>>{};
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(storageKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          for (final e in decoded.entries) {
            if (e.value is Map) {
              loaded[e.key.toString()] = Map<String, dynamic>.from(e.value);
            }
          }
        }
      }
    } catch (e) {
      debugPrint('[VirtualCollectionFavorites] read failed: $e');
    }
    return loaded;
  }

  static Future<Map<String, Map<String, dynamic>>> _map() async {
    final current = _loaded;
    if (current != null) return current;
    final loaded = await _read();
    // A toggle may have run while we were reading.
    return _loaded ??= loaded;
  }

  /// Re-reads the favorite collections from disk (account switch / cloud
  /// update). Swaps the map in one step so a favorite being added right now
  /// is never lost.
  static Future<void> reload() async {
    _loaded = await _read();
  }

  static Future<void> _save(Map<String, Map<String, dynamic>> map) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(storageKey, jsonEncode(map));
    } catch (e) {
      debugPrint('[VirtualCollectionFavorites] save failed: $e');
    }
  }

  /// Adds or removes a collection (`c10`) from the favorites.
  static Future<void> setFavorite(String id, bool favorite) async {
    final match = _collectionId.firstMatch(id);
    if (match == null) return;
    final tmdbId = int.parse(match.group(1)!);

    final map = await _map();
    if (!favorite) {
      if (map.remove(id) != null) await _save(map);
      return;
    }
    if (map.containsKey(id)) return;

    // Name and artwork come from TMDB, so the favorite can be listed later
    // without opening the collection again.
    final data = await TmdbCatalogService.raw('/collection/$tmdbId', {});
    final name = (data?['name'] ?? '').toString();
    if (data == null || name.isEmpty) {
      throw Exception('Could not load this collection.');
    }
    final overview = data['overview']?.toString() ?? '';
    final poster = data['poster_path'] as String?;
    final backdrop = data['backdrop_path'] as String?;

    // Another call may have added it while TMDB was answering.
    if (map.containsKey(id)) return;
    map[id] = {
      'Id': id,
      // When it was favorited (ms since epoch), for "Time added".
      'AddedAt': DateTime.now().millisecondsSinceEpoch,
      'Name': name,
      if (overview.isNotEmpty) 'Overview': overview,
      if (poster != null) 'Poster': poster,
      if (backdrop != null) 'Backdrop': backdrop,
    };
    await _save(map);
  }

  /// The favorited collections as BoxSet items, newest first.
  static Future<List<Map<String, dynamic>>> favoriteItems({int? limit}) async {
    final map = await _map();
    final entries = map.values.toList().reversed.toList();
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
      out.add(_item(f));
    }
    return limit != null && out.length > limit ? out.take(limit).toList() : out;
  }

  static Map<String, dynamic> _item(Map<String, dynamic> f) {
    final id = f['Id'].toString();
    final name = (f['Name'] ?? '').toString();
    final poster = f['Poster'] as String?;
    final backdrop = f['Backdrop'] as String?;
    final stamp = (f['AddedAt'] as num?)?.toInt();
    VirtualImages.register(id, primary: poster, backdrop: backdrop);
    return {
      'Id': id,
      'ServerId': VirtualCatalog.serverId,
      'Name': name,
      'OriginalTitle': name,
      'SortName': name.toLowerCase(),
      'Type': 'BoxSet',
      'IsFolder': true,
      'Overview': (f['Overview'] ?? '').toString(),
      if (stamp != null) 'FavoritedAtMs': stamp,
      'Genres': const <String>[],
      'GenreItems': const <Map<String, dynamic>>[],
      'ProviderIds': {'Tmdb': id.substring(1)},
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
        'IsFavorite': true,
        'Played': false,
        'PlayCount': 0,
        'PlaybackPositionTicks': 0,
      },
      'NamesisVirtual': true,
    };
  }

  /// Sets `UserData.IsFavorite` on every BoxSet in a response (a single item,
  /// an `Items` list, or a `{Collection: ...}` reply) so hearts show the real
  /// state. Anything that is not a BoxSet is left alone. Never throws: a
  /// failure here must not break the response it decorates.
  static Future<Object?> markFavorites(Object? result) async {
    if (result is! Map) return result;
    try {
      final map = await _map();

      void mark(Object? item) {
        if (item is! Map || item['Type'] != 'BoxSet') return;
        final id = item['Id']?.toString();
        if (id == null) return;
        final existing = item['UserData'];
        final data = existing is Map
            ? Map<String, dynamic>.from(existing)
            : <String, dynamic>{};
        data['IsFavorite'] = map.containsKey(id);
        item['UserData'] = data;
      }

      mark(result);
      mark(result['Collection']);
      final items = result['Items'];
      if (items is List) {
        for (final item in items) {
          mark(item);
        }
      }
    } catch (e) {
      debugPrint('[VirtualCollectionFavorites] mark failed: $e');
    }
    return result;
  }
}
