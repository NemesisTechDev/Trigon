/// Where the app reaches its third-party metadata providers (MDBList, OMDb,
/// TMDB, OpenSubtitles). The real API keys live only on the Cloudflare
/// Worker (see /nemesis-proxy) — nothing secret ships in the APK, and there
/// are no key fields in Settings any more.
///
/// Set [_defaultBaseUrl] to your deployed Worker URL, or override per build:
///   flutter build apk --release \
///     --dart-define=NEMESIS_PROXY_URL=https://nemesis-proxy.<you>.workers.dev \
///     --dart-define=NEMESIS_APP_TOKEN=<same value as the Worker's APP_TOKEN>
class ProxyConfig {
  ProxyConfig._();

  static const String _defaultBaseUrl =
      'https://nemesis-proxy.nemesis-apps.workers.dev';

  static const String baseUrl = String.fromEnvironment(
    'NEMESIS_PROXY_URL',
    defaultValue: _defaultBaseUrl,
  );

  /// Optional shared token sent as `X-Nemesis-Token`. It only keeps casual
  /// scrapers off the Worker (anything in an APK can be extracted); the
  /// real protection is the Worker's route allowlist, caching and rate limit.
  static const String appToken = String.fromEnvironment(
    'NEMESIS_APP_TOKEN',
    defaultValue: '',
  );

  /// False until [baseUrl] has been pointed at a real Worker, so a build
  /// with the placeholder URL skips the network calls (and falls back to
  /// Jellyfin's own data) instead of failing on every request.
  static bool get isConfigured =>
      baseUrl.isNotEmpty && !baseUrl.contains('YOUR-SUBDOMAIN');

  static Map<String, String> get headers => {
        if (appToken.isNotEmpty) 'X-Nemesis-Token': appToken,
      };
}
