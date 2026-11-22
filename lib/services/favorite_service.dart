import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'jellyfin_services/jellyfin_client.dart';

/// Account-based favorites state that Jellyfin itself doesn't track:
///
/// 1. Favorited-at timestamps for every favorited item (channels,
///    movies, shows, albums, songs, artists, playlists, cast/crew),
///    used to order the Favorites page newest-first. Jellyfin's
///    UserData only exposes the current IsFavorite boolean, never
///    *when* it was set.
/// 2. The favorited TV channel set itself. Unlike every other item
///    type, Live TV channels have no IsFavorite flag of their own on
///    Jellyfin's side to begin with (see the note on [toggle] below),
///    so without this, "favoriting" a channel was never anything more
///    than a note-to-self on one phone.
///
/// Both are synced through Jellyfin's `/DisplayPreferences` endpoint,
/// which the server keys by (Id, UserId, Client) — not by device — so
/// every device signed into the same Jellyfin account sees the same
/// favorited channels and the same favorite ordering, not just the
/// device a favorite was made on.
///
/// The local SharedPreferences copies are a fast read and an offline
/// fallback, never the source of truth on their own: reads merge the
/// server's copy with only the ids this device has changed since its
/// last successful push (tracked in [_touchedKey]) — so a favorite (or
/// unfavorite) made on this device shows correctly right away, even
/// before its push confirms, without a slightly-stale server fetch
/// resurrecting something this device just removed, or hiding something
/// this device just added, while offline. An id this app has never
/// touched always defers to the server's value.
class FavoriteService {
  static const _channelsKey = "favorite_channels";
  static const _timestampsKey = "favorite_timestamps_v1";

  // ids with a local change (add/remove/re-timestamp) not yet confirmed
  // by a successful server push. Cleared, per id, only once that id's
  // value has actually round-tripped to the server successfully.
  static const _touchedKey = "favorite_pending_sync_v1";

  // DisplayPreferences documents are keyed by (Id, UserId, Client) on
  // the server — not by device — which is exactly what makes this
  // account-based instead of per-install. "Project Nemesis" matches the
  // Client name JellyfinClient already sends in its auth header, so
  // this shows up as this app's own preferences document rather than
  // colliding with Jellyfin Web's or another client's.
  static const _prefsId = "NemesisFavorites";
  static const _prefsClient = "Project Nemesis";

  // Chains every server push onto the previous one so two
  // near-simultaneous favorites (e.g. rapid taps) don't both read the
  // same pre-update document and race each other on the follow-up
  // write — each push now waits for the last one to finish first.
  static Future<void> _syncChain = Future.value();

  /// Bumped every time ANY item's favorite state changes anywhere in the
  /// app (a song hearted from the full-screen audio player or the
  /// notification, a movie from its details page, a channel, an
  /// on-device song...). Screens that show a favorites list and stay
  /// alive underneath other screens (the Favorites page lives in the
  /// main nav's IndexedStack / sits under the full-screen player's
  /// route, so its initState never runs again) listen to this to know
  /// they need to reload instead of showing a stale snapshot.
  ///
  /// Always bumped AFTER the change has been applied (server call
  /// succeeded / local state written), so a listener that reloads right
  /// away sees the new state.
  static final ValueNotifier<int> changes = ValueNotifier<int>(0);

  static void notifyChanged() {
    changes.value++;
  }

  /// Drops this device's LOCAL copies of favorites state (channel set,
  /// favorited-at timestamps, pending-sync marks). Used when switching
  /// profiles: those SharedPreferences keys are per-device, not
  /// per-user, so without this the previous profile's favorites would
  /// show up (and get pushed) under the new one. The server's
  /// DisplayPreferences copy stays the source of truth and is simply
  /// re-read on next access.
  static Future<void> resetLocalState() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_channelsKey);
    await prefs.remove(_timestampsKey);
    await prefs.remove(_touchedKey);
    notifyChanged();
  }

  // ---------------------------------------------------------------
  // TV channel favorites
  // ---------------------------------------------------------------

  /// The current favorited channel ids. Tries the account's synced
  /// list first (merged with any of this device's own not-yet-pushed
  /// changes — see the class doc); falls back to whatever's cached
  /// locally if the server can't be reached.
  static Future<List<String>> getFavorites() async {
    final local = await _readLocalChannels();
    final touched = await _readTouchedIds();

    List<String>? remote;
    try {
      remote = (await _fetchServerDocument())?.channels;
    } catch (_) {
      remote = null;
    }

    if (remote == null) return local;

    final merged = <String>{
      for (final id in remote)
        if (!touched.contains(id)) id,
      for (final id in local)
        if (touched.contains(id)) id,
    }.toList();

    await _writeLocalChannels(merged);
    if (touched.isNotEmpty) _queueServerSync();
    return merged;
  }

  static Future<bool> isFavorite(String id) async {
    final favorites = await getFavorites();

    return favorites.contains(id);
  }

  /// Live TV channels have no IsFavorite flag of their own on
  /// Jellyfin's side — unlike movies, songs, etc., which flip a real
  /// server field via MediaService.toggleFavorite — so membership in
  /// this locally/account-tracked list IS the favorite state for a
  /// channel, not just its timestamp.
  static Future<void> toggle(String id) async {
    final channels = await _readLocalChannels();

    if (channels.contains(id)) {
      channels.remove(id);
      await _writeLocalChannels(channels);
      await clearFavoritedTimestamp(id);
    } else {
      channels.add(id);
      await _writeLocalChannels(channels);
      await recordFavoritedTimestamp(id);
    }

    notifyChanged();
  }

  // ---------------------------------------------------------------
  // Favorited-at timestamps (all item types, including channels)
  // ---------------------------------------------------------------

  /// All known favorited-at timestamps, id -> milliseconds since epoch.
  /// Used by the Favorites page to sort each section newest-first. Same
  /// merge/fallback behavior as [getFavorites] above.
  static Future<Map<String, int>> getFavoritedTimestamps() async {
    final local = await _readLocalTimestamps();
    final touched = await _readTouchedIds();

    Map<String, int>? remote;
    try {
      remote = (await _fetchServerDocument())?.timestamps;
    } catch (_) {
      remote = null;
    }

    if (remote == null) return local;

    final merged = <String, int>{
      for (final entry in remote.entries)
        if (!touched.contains(entry.key)) entry.key: entry.value,
      for (final entry in local.entries)
        if (touched.contains(entry.key)) entry.key: entry.value,
    };

    await _writeLocalTimestamps(merged);
    if (touched.isNotEmpty) _queueServerSync();
    return merged;
  }

  /// Records "now" as the favorited-at time for [id], locally and
  /// (best-effort, in the background) on the account. Called whenever
  /// any item type is marked as favorited.
  static Future<void> recordFavoritedTimestamp(String id) async {
    final map = await _readLocalTimestamps();
    map[id] = DateTime.now().millisecondsSinceEpoch;
    await _writeLocalTimestamps(map);
    await _markTouched(id);
    _queueServerSync();
  }

  /// Clears the favorited-at time for [id], locally and on the account,
  /// called when an item is unfavorited.
  static Future<void> clearFavoritedTimestamp(String id) async {
    final map = await _readLocalTimestamps();
    if (map.remove(id) != null) {
      await _writeLocalTimestamps(map);
    }
    await _markTouched(id);
    _queueServerSync();
  }

  // ---------------------------------------------------------------
  // Local cache (fast reads, offline fallback)
  // ---------------------------------------------------------------

  static Future<List<String>> _readLocalChannels() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_channelsKey) ?? [];
  }

  static Future<void> _writeLocalChannels(List<String> ids) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_channelsKey, ids);
  }

  static Future<Map<String, int>> _readLocalTimestamps() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_timestampsKey);
    if (raw == null) return {};

    try {
      final decoded = json.decode(raw) as Map<String, dynamic>;
      return decoded.map((key, value) => MapEntry(key, value as int));
    } catch (_) {
      return {};
    }
  }

  static Future<void> _writeLocalTimestamps(Map<String, int> map) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_timestampsKey, json.encode(map));
  }

  static Future<Set<String>> _readTouchedIds() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(_touchedKey) ?? []).toSet();
  }

  static Future<void> _writeTouchedIds(Set<String> ids) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_touchedKey, ids.toList());
  }

  static Future<void> _markTouched(String id) async {
    final touched = await _readTouchedIds();
    if (touched.add(id)) {
      await _writeTouchedIds(touched);
    }
  }

  // ---------------------------------------------------------------
  // Server sync (Jellyfin DisplayPreferences)
  // ---------------------------------------------------------------

  /// Fire-and-forget: pushes the current local channel list and
  /// timestamp map to the account in one combined request. Chained onto
  /// [_syncChain] so overlapping calls (two favorites toggled
  /// back-to-back) serialize instead of both reading a stale
  /// pre-update document. Errors (no connection, server briefly
  /// unreachable) are swallowed — the local record is never lost, only
  /// the sync attempt is; the ids stay marked touched, so the next
  /// toggle or the next read retries them.
  static void _queueServerSync() {
    _syncChain = _syncChain.then((_) async {
      try {
        // Captured right before the push so only ids actually included
        // in *this* push's payload are cleared afterward — anything
        // touched later (mid-flight) stays marked and rides the next
        // push instead of being wrongly marked as confirmed early.
        final touchedSnapshot = await _readTouchedIds();
        final channels = await _readLocalChannels();
        final timestamps = await _readLocalTimestamps();

        await _pushServerDocument(channels: channels, timestamps: timestamps);

        if (touchedSnapshot.isNotEmpty) {
          final stillTouched = await _readTouchedIds();
          await _writeTouchedIds(stillTouched.difference(touchedSnapshot));
        }
      } catch (_) {
        // Best-effort — see doc comment above.
      }
    });
  }

  static Future<_FavoriteDocument?> _fetchServerDocument() async {
    final userId = JellyfinClient.userId;
    if (userId.isEmpty) return null;

    final response = await JellyfinClient.dio.get(
      "/DisplayPreferences/$_prefsId",
      queryParameters: {
        "userId": userId,
        "client": _prefsClient,
      },
    );

    // A brand-new account (or one that's never favorited anything from
    // this app before) simply has no document yet — treat that the
    // same as "nothing synced yet", not as an error.
    if (response.statusCode == 404) return _FavoriteDocument.empty();
    if (response.statusCode != 200 || response.data is! Map) return null;

    // No document of ours here yet (this app's built-in catalog has no
    // server-side DisplayPreferences at all and answers with an unrelated
    // empty reply). That is "nothing synced", NOT "the account has no
    // favorites": returning an empty document would make the merge in
    // getFavorites / getFavoritedTimestamps drop every id the device has
    // already pushed (their pending marks are cleared after the push), so
    // favorited channels and every favorited-at time vanished and "Time
    // added" fell back to A-Z. Null makes the callers keep the local copy.
    final customPrefs = response.data["CustomPrefs"];
    if (customPrefs is! Map ||
        (!customPrefs.containsKey(_channelsKey) &&
            !customPrefs.containsKey(_timestampsKey))) {
      return null;
    }

    return _FavoriteDocument(
      channels: _decodeStringList(customPrefs[_channelsKey]),
      timestamps: _decodeIntMap(customPrefs[_timestampsKey]),
    );
  }

  /// Reads-merges-writes the whole DisplayPreferences document rather
  /// than assuming it only ever holds our two keys, so a future feature
  /// that adds another CustomPrefs entry under this same client/id
  /// doesn't get clobbered by this write.
  static Future<void> _pushServerDocument({
    required List<String> channels,
    required Map<String, int> timestamps,
  }) async {
    final userId = JellyfinClient.userId;
    if (userId.isEmpty) return;

    final queryParameters = {
      "userId": userId,
      "client": _prefsClient,
    };

    Map<String, dynamic> doc;
    final getResponse = await JellyfinClient.dio.get(
      "/DisplayPreferences/$_prefsId",
      queryParameters: queryParameters,
    );

    if (getResponse.statusCode == 200 && getResponse.data is Map) {
      doc = Map<String, dynamic>.from(getResponse.data as Map);
    } else {
      doc = {};
    }

    final customPrefs = <String, dynamic>{
      ...((doc["CustomPrefs"] is Map)
          ? Map<String, dynamic>.from(doc["CustomPrefs"] as Map)
          : <String, dynamic>{}),
      _channelsKey: json.encode(channels),
      _timestampsKey: json.encode(timestamps),
    };

    doc["Id"] = _prefsId;
    doc["Client"] = _prefsClient;
    doc["CustomPrefs"] = customPrefs;

    final postResponse = await JellyfinClient.dio.post(
      "/DisplayPreferences/$_prefsId",
      queryParameters: queryParameters,
      data: doc,
    );

    if (postResponse.statusCode != 200 && postResponse.statusCode != 204) {
      throw Exception(
        "Failed to sync favorites: ${postResponse.statusCode}",
      );
    }
  }

  static List<String> _decodeStringList(dynamic raw) {
    if (raw is! String) return [];
    try {
      return List<String>.from(json.decode(raw) as List);
    } catch (_) {
      return [];
    }
  }

  static Map<String, int> _decodeIntMap(dynamic raw) {
    if (raw is! String) return {};
    try {
      final decoded = json.decode(raw) as Map<String, dynamic>;
      return decoded.map((key, value) => MapEntry(key, value as int));
    } catch (_) {
      return {};
    }
  }
}

/// The two pieces of favorites state held in the account's
/// DisplayPreferences document.
class _FavoriteDocument {
  final List<String> channels;
  final Map<String, int> timestamps;

  _FavoriteDocument({required this.channels, required this.timestamps});

  factory _FavoriteDocument.empty() =>
      _FavoriteDocument(channels: [], timestamps: {});
}
