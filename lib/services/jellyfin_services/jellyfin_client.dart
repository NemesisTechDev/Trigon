import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'storage_service.dart';
import '../../virtual/virtual_adapter.dart';
import '../../virtual/virtual_catalog.dart';

/// Shared Dio instance that automatically attaches the server URL,
/// auth token, and required Jellyfin headers to every request.
class JellyfinClient {
  // Previously a hardcoded literal identical across every install, which
  // meant Jellyfin's /Sessions couldn't reliably tell two different
  // Nemesis installs (e.g. a phone and a paired Nemesis Native TV) apart.
  // Now generated once per install and persisted — see
  // StorageService.getOrCreateDeviceId. Cached here (not re-read from
  // storage on every request) since it never changes for the lifetime of
  // an install.
  static String? _deviceId;

  static Dio? _dio;
  static String? _cachedServerUrl;
  static String? _cachedToken;
  static String? _cachedUserId;

  /// Call this once after login (or app start) to prime the client.
  static Future<void> init() async {
    // NAMESIS PRIME: there is no Jellyfin server. A virtual one, backed by
    // TMDB (see lib/virtual), answers every request, so a fixed address and
    // user id are used when nothing has been saved yet.
    final savedServer = await StorageService.getServerUrl();
    _cachedServerUrl = (savedServer == null || savedServer.isEmpty)
        ? 'http://namesis.local'
        : savedServer;
    _cachedToken = await StorageService.getToken();
    final savedUser = await StorageService.getUserId();
    _cachedUserId = (savedUser == null || savedUser.isEmpty)
        ? VirtualCatalog.userId
        : savedUser;
    _deviceId = await StorageService.getOrCreateDeviceId();

    _dio = Dio(
      BaseOptions(
        baseUrl: _cachedServerUrl ?? "",
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 15),
        validateStatus: (_) => true,
        headers: {
          "Content-Type": "application/json",
          "X-Emby-Authorization": _authHeader(),
        },
      ),
    );
    _dio!.httpClientAdapter = VirtualJellyfinAdapter();
  }

  static String _authHeader() {
    final tokenPart =
    _cachedToken != null ? ', Token="$_cachedToken"' : "";
    return 'MediaBrowser Client="Project Nemesis", Device="Android", '
        'DeviceId="${_deviceId ?? ''}", Version="1.0.0"$tokenPart';
  }

  static Dio get dio {
    if (_dio == null) {
      throw Exception(
          "JellyfinClient not initialized. Call JellyfinClient.init() first.");
    }
    return _dio!;
  }

  static String get serverUrl => _cachedServerUrl ?? "";
  static String get userId => _cachedUserId ?? "";
  static String get token => _cachedToken ?? "";

  /// This install's stable Jellyfin DeviceId. Empty until [init] has run
  /// at least once (same lazily-populated contract as [serverUrl]/[token]
  /// above) — every real call site runs after main()'s startup sequence,
  /// which already awaits [init]-adjacent setup before anything touches
  /// the network.
  static String get deviceId => _deviceId ?? "";

  /// Call after login succeeds, or if the token changes, to refresh
  /// the cached values and rebuild headers without a full app restart.
  static Future<void> refresh() async {
    await init();
  }

  /// Root cause of "app stops responding after being backgrounded/idle
  /// for a while, fixed only by logging in again":
  ///
  /// [_dio]'s underlying HttpClient (via dio's IOHttpClientAdapter) keeps
  /// HTTP/1.1 keep-alive connections open and reuses them across calls —
  /// that's normal and desirable while the app is active. But once
  /// Android freezes the app's process in the background (screen off,
  /// Doze, app-standby, or just enough idle time), those sockets can be
  /// silently dropped by the OS, the router's NAT table, or — since
  /// Ben's server sits behind a Cloudflare Tunnel — the tunnel's own
  /// idle-connection timeout, with no FIN/RST ever delivered to the
  /// frozen isolate. dart:io's own connection-idle eviction can't run
  /// either, since its timer needs the isolate scheduled to fire.
  ///
  /// The result: on resume, the very first request reuses a connection
  /// that *looks* alive to Dio but is actually dead, so the request just
  /// hangs (or times out slowly) instead of failing fast — reading as
  /// "not responding". Logging in again "fixes" it only as a side
  /// effect: AuthService.login() calls [init], which builds a brand-new
  /// Dio/HttpClient with fresh sockets. Server setup isn't needed
  /// because the stale connection, not the saved server URL or token,
  /// was the actual problem.
  ///
  /// This forcibly closes every open connection on the current Dio's
  /// adapter (dropping any dead ones) so the next request always opens
  /// a fresh socket — the same effect as re-logging in, without needing
  /// the user to do it. Call this whenever the app resumes from being
  /// backgrounded (see MainNavScreen.didChangeAppLifecycleState).
  static void closeIdleConnections() {
    final adapter = _dio?.httpClientAdapter;
    if (adapter is IOHttpClientAdapter) {
      adapter.close(force: true);
    }
  }
}