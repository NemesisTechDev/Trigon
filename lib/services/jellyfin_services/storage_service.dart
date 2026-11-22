import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../cache/library_cache.dart';

class StorageService {
  static const _serverUrl = "server_url";
  static const _token = "auth_token";
  static const _userId = "user_id";
  static const _username = "username";
  static const _homeCache = "home_cache_v1";
  static const _liveTvCache = "live_tv_cache_v1";
  static const _autoQueueRecommendations = "auto_queue_recommendations_v1";
  static const _playbackQualityMode = "playback_quality_mode_v1";
  static const _playbackSourceMode = "playback_source_mode_v1";
  static const _autoLinkSelection = "auto_link_selection_v1";
  static const _embedAdBlock = "embed_ad_block_v1";
  static const _downloadWifiOnly = "download_wifi_only_v1";
  static const _shareUsageData = "share_usage_data_v1";
  static const _embedServer = "embed_server_v1";
  static const _omdbApiKey = "omdb_api_key";
  static const _mdblistApiKey = "mdblist_api_key";
  static const _ratingsCache = "ratings_cache_v1";
  static const _tmdbApiKey = "tmdb_api_key";
  static const _tmdbMetadataCache = "tmdb_metadata_cache_v1";
  static const _deviceId = "nemesis_device_id_v1";
  static const _nativePairings = "nemesis_native_pairings_v1";

  // Token and user ID are bearer-credential-adjacent — whoever has the
  // token can act as that user against the server — so they live in
  // Keystore-backed secure storage instead of plaintext SharedPreferences.
  // flutter_secure_storage v10+ defaults AndroidOptions() to RSA-OAEP +
  // AES-GCM automatically (the old `encryptedSharedPreferences: true`
  // flag from v9 was removed as a parameter entirely — this is its
  // direct, and stronger, replacement). Existing installs upgrading from
  // v9 are migrated automatically (migrateOnAlgorithmChange defaults to
  // true), so no separate migration step is needed here.
  static const _secureStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(),
  );

  /// NAMESIS PRIME: secure-storage reads/writes can throw on Android when
  /// the saved data no longer matches the phone's Keystore key (typical
  /// after a reinstall or restored backup). That used to leave the app
  /// frozen on the splash. Now unreadable data is wiped once and treated as
  /// "not signed in yet".
  static Future<String?> _safeRead(String key) async {
    try {
      return await _secureStorage.read(key: key);
    } catch (e) {
      debugPrint('[Storage] secure read failed ($key): $e - resetting');
      try {
        await _secureStorage.deleteAll();
      } catch (_) {}
      return null;
    }
  }

  static Future<void> _safeWrite(String key, String value) async {
    try {
      await _secureStorage.write(key: key, value: value);
    } catch (e) {
      debugPrint('[Storage] secure write failed ($key): $e - resetting');
      try {
        await _secureStorage.deleteAll();
        await _secureStorage.write(key: key, value: value);
      } catch (_) {}
    }
  }

  static Future<void> saveServerUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_serverUrl, url);
  }

  static Future<String?> getServerUrl() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_serverUrl);
  }

  static Future<void> saveToken(String token) async {
    await _safeWrite(_token, token);
  }

  static Future<String?> getToken() async {
    await _migrateLegacyAuthIfNeeded();
    return _safeRead(_token);
  }

  static Future<void> saveUser(String id, String username) async {
    await _safeWrite(_userId, id);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_username, username);
  }

  /// Changes only the saved display name (the user id stays as it is).
  /// Used by the Edit Profile page.
  static Future<void> saveUsername(String username) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_username, username);
  }

  static Future<String?> getUserId() async {
    await _migrateLegacyAuthIfNeeded();
    return _safeRead(_userId);
  }

  static Future<String?> getUsername() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_username);
  }

  /// Stable per-install identifier Jellyfin uses (as `DeviceId` in the
  /// `X-Emby-Authorization` header — see JellyfinClient) to tell one
  /// client apart from another in things like `/Sessions`. Previously a
  /// hardcoded literal shared by every single install of the app, which
  /// worked fine as long as Jellyfin only ever needed to distinguish
  /// "Nemesis" from other client apps — but casting (Jellyfin Remote
  /// Session control, and a paired Nemesis Native TV registering its own
  /// session) needs to tell *which* physical device is which, so this is
  /// now generated once per install and persisted.
  ///
  /// Plain (non-secure) storage is intentional: this is a stable client
  /// identifier, not a credential — nothing sensitive is exposed if it
  /// leaks, unlike the auth token/user ID above.
  static Future<String> getOrCreateDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getString(_deviceId);
    if (existing != null && existing.isNotEmpty) {
      return existing;
    }

    final generated = _generateUuidV4();
    await prefs.setString(_deviceId, generated);
    return generated;
  }

  // Hand-rolled RFC 4122 v4 UUID rather than pulling in `package:uuid` for
  // a single call site — Random.secure() is already part of dart:math, so
  // this avoids an otherwise-unnecessary dependency for one string.
  static String _generateUuidV4() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));

    // Set the version (4) and variant (RFC 4122) bits per the spec.
    bytes[6] = (bytes[6] & 0x0F) | 0x40;
    bytes[8] = (bytes[8] & 0x3F) | 0x80;

    String hex(int start, int end) => bytes
        .sublist(start, end)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();

    return '${hex(0, 4)}-${hex(4, 6)}-${hex(6, 8)}-${hex(8, 10)}-${hex(10, 16)}';
  }

  // Nemesis Native casting (Phase 6): per-TV pairing session tokens.
  //
  // This is NOT a Jellyfin credential -- the paired TV gets its own,
  // separate Jellyfin AccessToken via Quick Connect (see
  // NemesisNativeTransport.submitPairingCode), and this phone never
  // learns that token either. What's stored here is purely this
  // install's own Nemesis-protocol session token for one specific TV --
  // it only ever lets NemesisNativeTransport skip re-showing the
  // on-screen pairing code on a future reconnect (the "resume" message
  // in nemesis_native_protocol.dart) via whatever local WebSocket
  // connection this phone happens to make to that TV next. Treated as
  // an authorization credential (whoever holds it can skip pairing and
  // start issuing playback commands to that TV) rather than a plain
  // identifier like [_deviceId] above, so -- unlike the device id -- it
  // lives in the same Keystore-backed secure storage as the auth
  // token/user id, not plain SharedPreferences.
  //
  // Stored as a single JSON blob (tvDeviceId -> sessionToken) under one
  // secure-storage key rather than one key per TV, since there's no
  // secure-storage equivalent of SharedPreferences.getKeys() to enumerate
  // "every TV this install has ever paired with" if each got its own key
  // -- a single blob keeps forgetting/listing pairings simple.
  static Future<Map<String, String>> _readNativePairings() async {
    final raw = await _safeRead(_nativePairings);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      return decoded.map((key, value) => MapEntry(key.toString(), value.toString()));
    } catch (_) {
      // Corrupt/unreadable blob (shouldn't happen, but this is a cache
      // of convenience, not the source of truth for whether a TV is
      // reachable) -- treat as "no saved pairings" rather than crashing
      // discovery/connect.
      return {};
    }
  }

  static Future<void> _writeNativePairings(Map<String, String> pairings) async {
    await _secureStorage.write(key: _nativePairings, value: jsonEncode(pairings));
  }

  /// Persists the session token [NemesisNativeTransport] received back
  /// from a successful `pairResult`, keyed by the TV's own stable
  /// `tvDeviceId` (from its mDNS TXT record / `helloAck`) -- NOT by
  /// [CastDevice.id], which is namespaced per-transport and only a
  /// thin wrapper around this same id.
  static Future<void> saveNativePairing(String tvDeviceId, String sessionToken) async {
    final pairings = await _readNativePairings();
    pairings[tvDeviceId] = sessionToken;
    await _writeNativePairings(pairings);
  }

  /// Null if this phone has never paired with this TV, or has since
  /// forgotten it (see [forgetNativePairing]) -- either way,
  /// NemesisNativeTransport.connect() falls back to requiring the
  /// on-screen pairing code again.
  static Future<String?> getNativePairingToken(String tvDeviceId) async {
    final pairings = await _readNativePairings();
    return pairings[tvDeviceId];
  }

  /// Called when a TV rejects a `resume` attempt (token revoked, TV
  /// factory-reset, or an explicit "forget this TV" action in a future
  /// settings UI -- not built as of Phase 6) so a stale token doesn't
  /// keep getting retried forever.
  static Future<void> forgetNativePairing(String tvDeviceId) async {
    final pairings = await _readNativePairings();
    if (pairings.remove(tvDeviceId) != null) {
      await _writeNativePairings(pairings);
    }
  }

  // One-time migration for anyone who had a token/user ID saved under the
  // old plaintext SharedPreferences keys before secure storage was added.
  // Without this, existing installs would silently get logged out on
  // update instead of carrying their session over. Safe to call
  // repeatedly — it's a no-op once the legacy keys are gone.
  static Future<void> _migrateLegacyAuthIfNeeded() async {
    final prefs = await SharedPreferences.getInstance();

    final legacyToken = prefs.getString(_token);
    if (legacyToken != null) {
      await _safeWrite(_token, legacyToken);
      await prefs.remove(_token);
    }

    final legacyUserId = prefs.getString(_userId);
    if (legacyUserId != null) {
      await _safeWrite(_userId, legacyUserId);
      await prefs.remove(_userId);
    }
  }

  static Future<void> clear() async {
    await _secureStorage.delete(key: _token);
    await _secureStorage.delete(key: _userId);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_token);
    await prefs.remove(_userId);
    await prefs.remove(_username);
    await prefs.remove(_homeCache);
    await prefs.remove(_liveTvCache);
    await LibraryCache.instance.clearAll();
  }

  /// Signs the current user out while keeping the configured server URL,
  /// so the person lands back on the login screen for the same server
  /// instead of being sent through server setup again.
  static Future<void> logoutUser() async {
    await clear();
  }

  /// Clears everything, including the configured server URL, so the
  /// person is sent all the way back to server setup — used when
  /// disconnecting from / switching away from the current server.
  static Future<void> logoutServer() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_serverUrl);
    await clear();
  }

  /// Stale-while-revalidate cache for the Home screen's payload (libraries,
  /// resume items, featured items, latest-by-library) so Home can paint
  /// instantly from disk on app launch while a fresh copy loads underneath.
  static Future<void> saveHomeCache(String json) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_homeCache, json);
  }

  static Future<String?> getHomeCache() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_homeCache);
  }

  /// Same stale-while-revalidate pattern for Live TV (channels + the
  /// current guide window), since /LiveTv/Programs is the slowest call
  /// in the app and there's no reason to stare at a spinner for it on
  /// every single visit to the tab.
  static Future<void> saveLiveTvCache(String json) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_liveTvCache, json);
  }

  static Future<String?> getLiveTvCache() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_liveTvCache);
  }

  /// Whether finishing a music queue with nothing after it should
  /// auto-queue similar songs instead of just stopping. Off by default.
  static Future<void> setAutoQueueRecommendations(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autoQueueRecommendations, value);
  }

  static Future<bool> getAutoQueueRecommendations() async {
    final prefs = await SharedPreferences.getInstance();
    // NAMESIS PRIME: on unless the person turned it off, so the Next Movie /
    // Next Show cards appear without a trip to Settings.
    return prefs.getBool(_autoQueueRecommendations) ?? true;
  }

  /// Data Saver / Default / Max Quality — stored as the plain string
  /// name of AppSettings' PlaybackQualityMode enum (via `.name`) rather
  /// than this file depending on that enum directly, since
  /// StorageService sits "below" AppSettings in the dependency graph
  /// (AppSettings already imports this file; the reverse would be
  /// circular). AppSettings.load()/setPlaybackQualityMode() do the
  /// string<->enum conversion on their side.
  static Future<void> setPlaybackQualityMode(String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_playbackQualityMode, value);
  }

  static Future<String?> getPlaybackQualityMode() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_playbackQualityMode);
  }

  /// Addons (native player) / Embed servers (web player) — stored as the
  /// plain `.name` of AppSettings' PlaybackSourceMode, same reasoning as
  /// the playback quality mode above.
  static Future<void> setPlaybackSourceMode(String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_playbackSourceMode, value);
  }

  static Future<String?> getPlaybackSourceMode() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_playbackSourceMode);
  }

  /// Auto-link selection (skip the link list and play the best link for the
  /// Streaming Quality setting). On unless the person turned it off.
  static Future<void> setAutoLinkSelection(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autoLinkSelection, value);
  }

  static Future<bool> getAutoLinkSelection() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_autoLinkSelection) ?? true;
  }

  /// Anonymous usage statistics (Firebase Analytics). On unless turned off.
  static Future<void> setShareUsageData(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_shareUsageData, value);
  }

  static Future<bool> getShareUsageData() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_shareUsageData) ?? true;
  }

  /// Downloads only run on Wi-Fi / ethernet. On unless turned off.
  static Future<void> setDownloadWifiOnly(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_downloadWifiOnly, value);
  }

  static Future<bool> getDownloadWifiOnly() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_downloadWifiOnly) ?? true;
  }

  /// Ad blocker for the Embed servers' web player. On unless turned off.
  static Future<void> setEmbedAdBlock(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_embedAdBlock, value);
  }

  static Future<bool> getEmbedAdBlock() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_embedAdBlock) ?? true;
  }

  /// Default embed server — `.name` of AppSettings' EmbedServer.
  static Future<void> setEmbedServer(String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_embedServer, value);
  }

  static Future<String?> getEmbedServer() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_embedServer);
  }

  /// Clears just the app's locally-persisted data caches (Home + Live TV
  /// payloads) without touching auth/session state — used by the
  /// Profile & Settings "Clear Cache" action. Login stays intact.
  static Future<void> clearAppDataCache() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_homeCache);
    await prefs.remove(_liveTvCache);
    // Movies / Music / Live TV list cache (LibraryCache).
    await LibraryCache.instance.clearAll();
  }

  /// One-time cleanup: API keys used to be typed into Settings and stored
  /// here in plaintext. They now live only on the Nemesis Worker, so wipe
  /// any copies left on devices that used an older build.
  static Future<void> clearLegacyApiKeys() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_omdbApiKey);
    await prefs.remove(_mdblistApiKey);
    await prefs.remove(_tmdbApiKey);
  }

  /// Local cache of resolved IMDb/Rotten Tomatoes ratings, keyed by
  /// IMDb id, so RatingsService doesn't re-hit the configured ratings
  /// API's quota for the same title on every app open — see
  /// RatingsService for the JSON shape and TTL.
  static Future<void> saveRatingsCache(String json) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_ratingsCache, json);
  }

  static Future<String?> getRatingsCache() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_ratingsCache);
  }

  /// Local cache of resolved TMDB credits + production-company lookups,
  /// keyed by "credits:<type>:<tmdbId>" / "details:<type>:<tmdbId>" —
  /// see TmdbService for the JSON shape and TTL. Separate from
  /// [_ratingsCache] since it's a different provider with a much
  /// longer TTL (cast/crew and studio logos essentially never change,
  /// unlike ratings).
  static Future<void> saveTmdbMetadataCache(String json) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_tmdbMetadataCache, json);
  }

  static Future<String?> getTmdbMetadataCache() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_tmdbMetadataCache);
  }
}