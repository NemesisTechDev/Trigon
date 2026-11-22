import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'jellyfin_services/jellyfin_client.dart';
import 'jellyfin_services/media_service.dart';
import 'local_music_service.dart';

/// Playlist membership for "On This Device" songs.
///
/// ROOT CAUSE this exists: a Jellyfin playlist can only hold items that
/// exist in the Jellyfin library. An on-device song has a synthetic id
/// ("local_<mediaStoreId>", see LocalMusicService) that the server has
/// never heard of, so it can never be sent to `POST /Playlists` or
/// `POST /Playlists/{id}/Items`. Everything about on-device songs in
/// playlists therefore has to live in this app's own storage, which is
/// also exactly what makes them correctly disappear on another device:
/// SharedPreferences is per-install, so a fresh login elsewhere has no
/// record of them at all.
///
/// Two shapes are stored:
///
///  • OVERLAY — on-device song ids attached to an existing *server*
///    playlist (keyed by that playlist's Jellyfin id). The server
///    playlist keeps its server songs; this adds the local ones on top
///    at display time. That is what makes a playlist with app songs and
///    on-device songs in the same playlist possible.
///
///  • LOCAL-ONLY PLAYLISTS — a playlist that holds nothing but on-device
///    songs is never created on the server at all (otherwise it would
///    show up as an empty playlist on every other device). It gets a
///    "localpl_<timestamp>" id and lives entirely here. The moment a
///    server song is added to one, it is promoted to a real server
///    playlist (see [addSongsToPlaylist]) and its on-device songs move
///    into the overlay above.
///
/// Storage is keyed by the signed-in Jellyfin user id, so a different
/// account signing in on the same phone doesn't inherit these.
class LocalPlaylistService extends ChangeNotifier {
  LocalPlaylistService._();
  static final LocalPlaylistService instance = LocalPlaylistService._();

  static const _kPrefix = 'local_playlists_v1_';

  /// Id prefix of playlists that exist only on this device.
  static const localIdPrefix = 'localpl_';

  static bool isLocalPlaylistId(String? id) =>
      id != null && id.startsWith(localIdPrefix);

  static bool isLocalSong(Map song) => song['IsLocal'] == true;

  // serverPlaylistId -> ordered on-device song ids attached to it.
  final Map<String, List<String>> _overlay = {};

  // localPlaylistId -> {name, songIds, createdAt}. Insertion-ordered.
  final Map<String, Map<String, dynamic>> _playlists = {};

  String? _loadedFor;
  String? _loadingFor;
  Future<void>? _loading;

  /// Loads persisted data for the current user. Safe to call repeatedly
  /// and concurrently; re-loads only if the signed-in user changed.
  Future<void> ensureLoaded() {
    final uid = JellyfinClient.userId;
    if (_loadedFor == uid) return Future.value();
    if (_loadingFor == uid && _loading != null) return _loading!;
    _loadingFor = uid;
    return _loading = _load(uid);
  }

  Future<void> _load(String uid) async {
    _overlay.clear();
    _playlists.clear();

    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('$_kPrefix$uid');
      if (raw != null) {
        final decoded = json.decode(raw) as Map<String, dynamic>;

        final overlay = decoded['overlay'] as Map<String, dynamic>? ?? {};
        overlay.forEach((key, value) {
          _overlay[key] = List<String>.from(value as List);
        });

        for (final entry in (decoded['playlists'] as List? ?? const [])) {
          final map = Map<String, dynamic>.from(entry as Map);
          _playlists[map['id'].toString()] = {
            'name': map['name']?.toString() ?? '',
            'songIds': List<String>.from(map['songIds'] as List? ?? const []),
            'createdAt': (map['createdAt'] as num?)?.toInt() ?? 0,
          };
        }
      }
    } catch (e) {
      debugPrint('LocalPlaylistService load failed: $e');
    }

    _loadedFor = uid;
    notifyListeners();
  }

  Future<void> _save() async {
    final uid = _loadedFor;
    if (uid == null) return;

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        '$_kPrefix$uid',
        json.encode({
          'overlay': _overlay,
          'playlists': [
            for (final e in _playlists.entries)
              {
                'id': e.key,
                'name': e.value['name'],
                'songIds': e.value['songIds'],
                'createdAt': e.value['createdAt'],
              },
          ],
        }),
      );
    } catch (e) {
      debugPrint('LocalPlaylistService save failed: $e');
    }
  }

  // ───────────────────────────── Reading ─────────────────────────────

  /// Stored on-device song ids for [playlistId] — a local-only
  /// playlist's whole tracklist, or a server playlist's overlay.
  List<String> songIdsFor(String playlistId) {
    if (isLocalPlaylistId(playlistId)) {
      return List<String>.from(
        (_playlists[playlistId]?['songIds'] as List?) ?? const [],
      );
    }
    return List<String>.from(_overlay[playlistId] ?? const []);
  }

  String? nameOf(String localPlaylistId) =>
      _playlists[localPlaylistId]?['name'] as String?;

  /// How many of the stored ids can actually be shown right now. Uses
  /// the scan cache when it's warm so a song whose file has vanished
  /// isn't counted; falls back to the stored length when it isn't.
  int _visibleCount(List<String> ids) {
    final cache = LocalMusicService.instance.cachedSongs;
    if (cache.isEmpty) return ids.length;
    final present = {for (final s in cache) s['Id'].toString()};
    return ids.where(present.contains).length;
  }

  /// Turns stored ids back into full song maps via the on-device scan.
  /// Ids the scan can't find (file deleted outside the app, storage
  /// unmounted, Local Files switched off) are simply not shown — they
  /// are deliberately NOT pruned from storage, since a temporarily
  /// missing volume shouldn't permanently cost the person their
  /// playlist membership.
  Future<List<Map<String, dynamic>>> resolveSongs(List<String> ids) async {
    if (ids.isEmpty) return [];

    final local = LocalMusicService.instance;
    if (!local.enabled) return [];

    var pool = local.cachedSongs;
    final known = {for (final s in pool) s['Id'].toString()};
    if (pool.isEmpty || ids.any((id) => !known.contains(id))) {
      pool = await local.scanAndGetSongs();
    }

    final byId = {for (final s in pool) s['Id'].toString(): s};
    return [
      for (final id in ids)
        if (byId[id] != null) byId[id]!,
    ];
  }

  Future<List<Map<String, dynamic>>> songsFor(String playlistId) async {
    await ensureLoaded();
    return resolveSongs(songIdsFor(playlistId));
  }

  /// Jellyfin-shaped playlist maps for every local-only playlist, so
  /// PlaylistCard / MusicDetailScreen can treat them like any other
  /// playlist item. `IsLocalPlaylist` is what tells the rest of the app
  /// not to make server calls for them.
  List<Map<String, dynamic>> localOnlyPlaylistItems() {
    return [
      for (final e in _playlists.entries)
        {
          'Id': e.key,
          'Name': e.value['name'],
          'Type': 'Playlist',
          'IsLocalPlaylist': true,
          'ChildCount': _visibleCount(
            List<String>.from(e.value['songIds'] as List),
          ),
          'DateCreated': DateTime.fromMillisecondsSinceEpoch(
            e.value['createdAt'] as int,
            isUtc: true,
          ).toIso8601String(),
          'UserData': {'IsFavorite': false},
        },
    ];
  }

  /// Merges local-only playlists into a server playlist list (as the
  /// Music tab's Playlists grid needs) and adds each server playlist's
  /// on-device overlay to its song count. Server order is preserved —
  /// local playlists are slotted in with a merge, not a re-sort, so the
  /// server's own SortName rules (e.g. ignoring a leading "The") still
  /// decide the order of everything it returned.
  List<dynamic> mergePlaylists(
    List<dynamic> serverPlaylists, {
    required bool newestFirst,
  }) {
    final server = <Map<String, dynamic>>[
      for (final p in serverPlaylists)
        () {
          final map = Map<String, dynamic>.from(p as Map);
          final extra = _overlay[map['Id']?.toString()];
          if (extra != null && extra.isNotEmpty) {
            map['ChildCount'] =
                ((map['ChildCount'] as num?)?.toInt() ?? 0) +
                    _visibleCount(extra);
          }
          return map;
        }(),
    ];

    final local = localOnlyPlaylistItems();
    if (local.isEmpty) return server;

    int cmp(Map a, Map b) => newestFirst
        ? (b['DateCreated'] ?? '').toString().compareTo(
              (a['DateCreated'] ?? '').toString(),
            )
        : (a['Name'] ?? '').toString().toLowerCase().compareTo(
              (b['Name'] ?? '').toString().toLowerCase(),
            );

    local.sort(cmp);

    final merged = <Map<String, dynamic>>[];
    var i = 0, j = 0;
    while (i < server.length && j < local.length) {
      merged.add(cmp(server[i], local[j]) <= 0 ? server[i++] : local[j++]);
    }
    merged
      ..addAll(server.skip(i))
      ..addAll(local.skip(j));
    return merged;
  }

  // ───────────────────────────── Writing ─────────────────────────────

  List<String> _localIds(Iterable<Map> songs) => [
        for (final s in songs)
          if (isLocalSong(s)) s['Id'].toString(),
      ];

  List<String> _serverIds(Iterable<Map> songs) => [
        for (final s in songs)
          if (!isLocalSong(s)) s['Id'].toString(),
      ];

  // Duplicates are skipped: rows are selected/removed by song id, so
  // the same on-device song twice in one list would select and remove
  // as a pair.
  void _appendUnique(List<String> target, List<String> ids) {
    for (final id in ids) {
      if (!target.contains(id)) target.add(id);
    }
  }

  /// Creates a playlist from a possibly mixed selection and returns its
  /// id. Only on-device songs → a local-only playlist, no network at
  /// all. Otherwise a real server playlist for the server songs, with
  /// the on-device ones attached as its overlay. Throws (before touching
  /// any local state) if the server rejects the create.
  Future<String> createPlaylistFromSongs(String name, List<Map> songs) async {
    await ensureLoaded();

    final localIds = _localIds(songs);
    final serverIds = _serverIds(songs);

    if (serverIds.isEmpty) {
      final id = '$localIdPrefix${DateTime.now().microsecondsSinceEpoch}';
      _playlists[id] = {
        'name': name,
        'songIds': localIds.toSet().toList(),
        'createdAt': DateTime.now().millisecondsSinceEpoch,
      };
      await _save();
      notifyListeners();
      return id;
    }

    final serverId = await MediaService.createPlaylist(name, serverIds);

    if (localIds.isNotEmpty) {
      _overlay[serverId] = localIds.toSet().toList();
      await _save();
      notifyListeners();
    }
    return serverId;
  }

  /// Adds a possibly mixed selection to [playlistId] (server or
  /// local-only) and returns the playlist's id afterwards — which
  /// differs from [playlistId] only when a local-only playlist had to
  /// be promoted to a server playlist to accept a server song. Server
  /// calls run first so a failure leaves local state untouched.
  Future<String> addSongsToPlaylist(String playlistId, List<Map> songs) async {
    await ensureLoaded();

    final localIds = _localIds(songs);
    final serverIds = _serverIds(songs);

    if (isLocalPlaylistId(playlistId)) {
      final record = _playlists[playlistId];
      if (record == null) throw Exception('Playlist no longer exists.');
      final existing = List<String>.from(record['songIds'] as List);

      if (serverIds.isEmpty) {
        _appendUnique(existing, localIds);
        record['songIds'] = existing;
        await _save();
        notifyListeners();
        return playlistId;
      }

      // PROMOTION: a server song can't live in a local-only playlist,
      // so it becomes a real server playlist (same name) holding the
      // server songs, and everything on-device it already had — plus
      // the new on-device songs — moves into that playlist's overlay.
      final serverId = await MediaService.createPlaylist(
        record['name'] as String,
        serverIds,
      );
      final overlay = List<String>.from(existing);
      _appendUnique(overlay, localIds);
      _overlay[serverId] = overlay;
      _playlists.remove(playlistId);
      await _save();
      notifyListeners();
      return serverId;
    }

    if (serverIds.isNotEmpty) {
      await MediaService.addManyToPlaylist(playlistId, serverIds);
    }
    if (localIds.isNotEmpty) {
      final overlay = _overlay.putIfAbsent(playlistId, () => []);
      _appendUnique(overlay, localIds);
      await _save();
      notifyListeners();
    }
    return playlistId;
  }

  /// Removes on-device songs from [playlistId]'s local storage (a
  /// local-only playlist's tracklist, or a server playlist's overlay).
  Future<void> removeSongs(String playlistId, Iterable<String> ids) async {
    await ensureLoaded();
    final drop = ids.toSet();

    if (isLocalPlaylistId(playlistId)) {
      final record = _playlists[playlistId];
      if (record == null) return;
      record['songIds'] = [
        for (final id in record['songIds'] as List)
          if (!drop.contains(id)) id as String,
      ];
    } else {
      _overlay[playlistId]?.removeWhere(drop.contains);
      if (_overlay[playlistId]?.isEmpty ?? false) _overlay.remove(playlistId);
    }

    await _save();
    notifyListeners();
  }

  /// Forgets a deleted playlist's local data. Safe to call for a server
  /// playlist that never had an overlay.
  Future<void> deletePlaylist(String playlistId) async {
    await ensureLoaded();
    final removed = isLocalPlaylistId(playlistId)
        ? _playlists.remove(playlistId) != null
        : _overlay.remove(playlistId) != null;
    if (!removed) return;
    await _save();
    notifyListeners();
  }

  /// "Remove from App" on an on-device song must take it out of every
  /// playlist too, otherwise the ids would linger in storage forever.
  Future<void> removeSongEverywhere(Iterable<String> ids) async {
    await ensureLoaded();
    final drop = ids.toSet();

    for (final list in _overlay.values) {
      list.removeWhere(drop.contains);
    }
    _overlay.removeWhere((_, list) => list.isEmpty);

    for (final record in _playlists.values) {
      record['songIds'] = [
        for (final id in record['songIds'] as List)
          if (!drop.contains(id)) id as String,
      ];
    }

    await _save();
    notifyListeners();
  }

  /// Turning Local Files off wipes what the app tracks about on-device
  /// songs (see LocalMusicService.disable) — that includes which
  /// playlists they were in, and any playlist that only held them.
  Future<void> clearAll() async {
    await ensureLoaded();
    _overlay.clear();
    _playlists.clear();
    await _save();
    notifyListeners();
  }
}
