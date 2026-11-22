/// Where the in-app updater looks for new versions, and when an old version
/// stops being allowed to run.
///
/// ### Publishing an update (what the updater expects)
/// 1. Bump `version:` in pubspec.yaml (e.g. `1.1.0+2`) and build the release
///    APK: `flutter build apk --release`.
/// 2. On GitHub, create a **Release** on [githubRepo] whose tag is the
///    version (`v1.1.0`), attach the APK file, and write the release notes in
///    the description - the updater shows them under "What's New".
/// 3. That is all. Installed apps see it on their next launch (or when the
///    person taps Settings > Check for Updates).
///
/// The repository must be public (the app reads its releases without a login),
/// and every release must be signed with the SAME keystore as the installed
/// app - Android refuses to update an app with a differently signed build.
///
/// Set [githubRepo] below, or override per build:
///   flutter build apk --release --dart-define=UPDATE_GITHUB_REPO=owner/repo
class UpdateConfig {
  UpdateConfig._();

  static const String _defaultRepo = 'YOUR-GITHUB-USER/YOUR-REPO';

  /// GitHub `owner/repo` whose Releases carry the APKs.
  static const String githubRepo = String.fromEnvironment(
    'UPDATE_GITHUB_REPO',
    defaultValue: _defaultRepo,
  );

  /// False until [githubRepo] has been pointed at a real repository, so a
  /// build with the placeholder simply reports "updates not set up" instead
  /// of failing on every launch.
  static bool get isConfigured =>
      githubRepo.contains('/') && !githubRepo.contains('YOUR-');

  /// An installed version that is this many (or more) releases behind the
  /// newest one stops working until it is updated. Every published release
  /// counts, whatever its version number (1.0.0 -> 1.0.1 -> 1.1.0 is 2
  /// releases behind). See `majorUpdatesBehind` in update_models.dart.
  static const int forceAfterMajorUpdates = 3;

  /// Writing this anywhere in a release's description makes that release
  /// mandatory for everyone on an older version, no matter how far behind
  /// they are (for an urgent fix): `[force-update]`.
  static final RegExp forceMarker =
      RegExp(r'\[\s*force[\s_-]*update\s*\]', caseSensitive: false);

  /// How long a silent re-check waits after the last one when the app comes
  /// back to the foreground.
  static const Duration recheckAfter = Duration(hours: 6);
}
