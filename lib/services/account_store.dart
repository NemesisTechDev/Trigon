import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../casting/cast_manager.dart';
import '../player/player_manager.dart';
import '../screens/main_nav/navigation_controller.dart';
import 'favorite_service.dart';
import 'jellyfin_services/jellyfin_client.dart';
import 'jellyfin_services/media_service.dart';
import 'jellyfin_services/storage_service.dart';

/// One signed-in Jellyfin profile this device can switch to without
/// typing a password again.
class SavedAccount {
  final String serverUrl;
  final String userId;
  final String username;
  final String token;
  final int lastUsedMs;

  const SavedAccount({
    required this.serverUrl,
    required this.userId,
    required this.username,
    required this.token,
    required this.lastUsedMs,
  });

  bool get isCurrent =>
      userId == JellyfinClient.userId && serverUrl == JellyfinClient.serverUrl;

  /// Built from THIS account's own server + token (not the active
  /// session's), so avatars for non-active profiles resolve correctly.
  String get avatarUrl =>
      '$serverUrl/Users/$userId/Images/Primary?quality=90&maxWidth=120&api_key=$token';

  Map<String, dynamic> toJson() => {
        's': serverUrl,
        'i': userId,
        'n': username,
        't': token,
        'l': lastUsedMs,
      };

  factory SavedAccount.fromJson(Map<String, dynamic> j) => SavedAccount(
        serverUrl: j['s'] as String,
        userId: j['i'] as String,
        username: (j['n'] ?? '') as String,
        token: j['t'] as String,
        lastUsedMs: (j['l'] ?? 0) as int,
      );
}

enum SwitchOutcome { ok, expired, unreachable }

/// Quick profile switching.
///
/// Design notes (why it works the way it does):
///  - A Jellyfin AccessToken is already a long-lived credential for one
///    user, so "switching" is just swapping which saved token the app
///    treats as current — no password is stored, ever. Tokens live in
///    Keystore-backed secure storage, the same place StorageService
///    keeps the active one.
///  - The token is validated against the server BEFORE anything on the
///    device changes. A revoked/expired token (admin signed the device
///    out, password changed) must never leave the app half-switched
///    into a session that 401s on every call.
///  - Per-user local state is reset on a successful switch: playback and
///    any cast session (otherwise the old profile keeps streaming under
///    the new identity and reports progress to the wrong user), the
///    Home/Live TV/library caches, this device's local favorites copy,
///    and MediaService's in-memory collection indexes. The app is then
///    rebuilt from "/home" with every earlier route removed — exactly
///    how a fresh login already does it — so no screen keeps stale
///    widgets from the previous profile.
///  - Log Out / Delete Account / Disconnect Server remove the matching
///    saved entries: signing out has to actually forget the token.
class AccountStore {
  AccountStore._();

  static const _key = 'saved_accounts_v1';
  static const _secure = FlutterSecureStorage(aOptions: AndroidOptions());

  /// Set when a switch hits an expired token so the login screen can
  /// pre-fill that profile's username. Consumed once.
  static String? _pendingLoginUsername;
  static String? takePendingLoginUsername() {
    final v = _pendingLoginUsername;
    _pendingLoginUsername = null;
    return v;
  }

  static Future<List<SavedAccount>> all() async {
    try {
      final raw = await _secure.read(key: _key);
      if (raw == null || raw.isEmpty) return [];
      final list = (jsonDecode(raw) as List)
          .map((e) => SavedAccount.fromJson(Map<String, dynamic>.from(e)))
          .toList();
      list.sort((a, b) => b.lastUsedMs.compareTo(a.lastUsedMs));
      return list;
    } catch (_) {
      return []; // corrupt blob: treat as "nothing saved", never crash UI.
    }
  }

  static Future<void> _write(List<SavedAccount> list) => _secure.write(
        key: _key,
        value: jsonEncode(list.map((a) => a.toJson()).toList()),
      );

  /// Saves (or refreshes) whichever session is active right now. Called
  /// after every successful login and whenever the switcher opens, which
  /// also picks up sessions that existed before this feature shipped.
  static Future<void> rememberCurrent() async {
    try {
      final server = await StorageService.getServerUrl();
      final token = await StorageService.getToken();
      final userId = await StorageService.getUserId();
      final name = await StorageService.getUsername();
      if ([server, token, userId].any((v) => v == null || v.isEmpty)) return;

      final list = await all();
      list.removeWhere((a) => a.userId == userId && a.serverUrl == server);
      list.add(SavedAccount(
        serverUrl: server!,
        userId: userId!,
        username: name ?? '',
        token: token!,
        lastUsedMs: DateTime.now().millisecondsSinceEpoch,
      ));
      await _write(list);
    } catch (e) {
      debugPrint('AccountStore.rememberCurrent failed: $e');
    }
  }

  static Future<void> remove(String userId, String serverUrl) async {
    final list = await all();
    list.removeWhere((a) => a.userId == userId && a.serverUrl == serverUrl);
    await _write(list);
  }

  static Future<void> removeAllForServer(String serverUrl) async {
    final list = await all();
    list.removeWhere((a) => a.serverUrl == serverUrl);
    await _write(list);
  }

  /// Asks the server whether [a]'s token still works. `/Users/Me` needs
  /// only the token, so this doubles as the "is this profile still
  /// signed in" check.
  static Future<SwitchOutcome> _validate(SavedAccount a) async {
    try {
      final deviceId = await StorageService.getOrCreateDeviceId();
      final res = await Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 8),
        receiveTimeout: const Duration(seconds: 8),
        validateStatus: (_) => true,
      )).get(
        '${a.serverUrl}/Users/Me',
        options: Options(headers: {
          'X-Emby-Authorization':
              'MediaBrowser Client="Project Nemesis", Device="Android", '
                  'DeviceId="$deviceId", Version="1.0.0", Token="${a.token}"',
        }),
      );
      final code = res.statusCode ?? 0;
      if (code == 401 || code == 403) return SwitchOutcome.expired;
      if (code == 200) return SwitchOutcome.ok;
      return SwitchOutcome.unreachable;
    } catch (_) {
      return SwitchOutcome.unreachable;
    }
  }

  /// Switches to [a]. On [SwitchOutcome.ok] the app has already been
  /// rebuilt from "/home" on the root navigator; on anything else
  /// nothing on the device was changed.
  static Future<SwitchOutcome> switchTo(
    SavedAccount a,
    NavigatorState rootNavigator,
  ) async {
    if (a.isCurrent) return SwitchOutcome.ok;

    final outcome = await _validate(a);
    if (outcome == SwitchOutcome.expired) {
      // Dead token: forget it, and let the login screen pre-fill the name.
      await remove(a.userId, a.serverUrl);
      _pendingLoginUsername = a.username;
      return outcome;
    }
    if (outcome != SwitchOutcome.ok) return outcome;

    // Keep the outgoing profile's token fresh before we overwrite it.
    await rememberCurrent();

    // Stop the old identity's playback/cast first (each guarded: a
    // failure to stop must not block the switch).
    try {
      if (CastManager.instance.activeSession.value != null) {
        await CastManager.instance.disconnect();
      }
    } catch (_) {}
    try {
      await PlayerManager.instance.stop();
    } catch (_) {}

    await StorageService.saveServerUrl(a.serverUrl);
    await StorageService.saveToken(a.token);
    await StorageService.saveUser(a.userId, a.username);

    // Per-user caches/state — see class doc.
    await StorageService.clearAppDataCache();
    await FavoriteService.resetLocalState();
    MediaService.resetUserCaches();

    await JellyfinClient.init();
    await rememberCurrent(); // bumps lastUsed for the new active profile

    NavigationController.instance.goToTab(NavTabs.home);
    rootNavigator.pushNamedAndRemoveUntil('/home', (route) => false);
    return SwitchOutcome.ok;
  }
}
