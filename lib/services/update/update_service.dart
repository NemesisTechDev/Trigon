import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../download_keepalive.dart';
import 'update_config.dart';
import 'update_models.dart';

/// Where the in-app update flow currently is (what the update popup shows).
enum UpdatePhase {
  /// Nothing to show.
  idle,

  /// An update exists; waiting for the person to start it.
  available,

  /// Android's "Install unknown apps" switch is off for Trigon.
  needsPermission,

  /// Downloading the APK.
  downloading,

  /// Checking the downloaded file.
  verifying,

  /// Downloaded and checked; the installer has not been opened (or was closed).
  readyToInstall,

  /// The system installer is open.
  installing,

  /// Something failed; [UpdateService.errorMessage] says what.
  error,
}

enum UpdateCheckOutcome { upToDate, available, failed, notConfigured, unsupported }

class UpdateCheckResult {
  const UpdateCheckResult(this.outcome, [this.message]);

  final UpdateCheckOutcome outcome;
  final String? message;
}

class _UpdateFailure implements Exception {
  _UpdateFailure(this.message, {this.retryable = true});

  final String message;
  final bool retryable;
}

class _Cancelled implements Exception {}

/// The in-app updater: finds the newest GitHub release, downloads its APK,
/// hands it to the Android installer, and decides when the installed version
/// is too old to keep running.
///
/// The UI is [UpdateGate] (lib/widgets/update/update_gate.dart); this class
/// holds all of the state and logic. See update_config.dart for how to publish
/// an update and for the "3 major updates behind = must update" rule.
class UpdateService extends ChangeNotifier with WidgetsBindingObserver {
  UpdateService._();

  static final UpdateService instance = UpdateService._();

  static const MethodChannel _native = MethodChannel('com.nemesis.app/app_update');

  static const String _kIgnored = 'update.ignored_version';
  static const String _kRequired = 'update.required_cache';
  static const String _kLastCheck = 'update.last_check_ms';

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 20),
      receiveTimeout: const Duration(seconds: 45),
      headers: const {'User-Agent': 'Trigon-Updater'},
    ),
  );

  bool _initialized = false;
  AppVersion? _current;
  String _currentLabel = '';

  UpdatePhase _phase = UpdatePhase.idle;
  UpdateInfo? _info;
  bool _checking = false;
  Future<UpdateCheckResult>? _checkFuture;

  bool _promptVisible = false;
  bool _sessionDismissed = false;
  bool _uiReady = false;
  String _ignoredVersion = '';
  DateTime? _lastCheck;

  int _received = 0;
  int _total = 0;
  String? _errorMessage;
  bool _errorRetryable = true;
  CancelToken? _cancelToken;
  DateTime? _installLaunchedAt;
  bool _continuing = false;

  // ───────────────────────────── what the UI reads ─────────────────────────────

  UpdatePhase get phase => _phase;
  UpdateInfo? get info => _info;

  /// True while a version check is running.
  bool get checking => _checking;

  /// The update popup is on screen.
  bool get promptVisible => _promptVisible;

  /// The installed version may not be used any more until it is updated.
  bool get mandatory => _info?.mandatory ?? false;

  bool get updateAvailable => _info != null;

  /// The installed version, e.g. `1.0.0` (empty until [init] has run).
  String get currentVersion => _currentLabel;

  int get receivedBytes => _received;
  int get totalBytes => _total;

  /// 0..1, or null while the size is not known.
  double? get progress => _total > 0 ? (_received / _total).clamp(0.0, 1.0) : null;

  String? get errorMessage => _errorMessage;
  bool get errorRetryable => _errorRetryable;

  bool get busy =>
      _phase == UpdatePhase.downloading ||
      _phase == UpdatePhase.verifying ||
      _phase == UpdatePhase.installing;

  // ───────────────────────────── start-up ─────────────────────────────

  /// Reads the installed version and restores a "must update" block that was
  /// already known (so going offline can not be used to get around it). Never
  /// throws.
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    WidgetsBinding.instance.addObserver(this);
    if (!Platform.isAndroid) return;

    try {
      final v = await _native
          .invokeMapMethod<String, dynamic>('getVersionInfo')
          .timeout(const Duration(seconds: 3));
      _currentLabel = v?['versionName']?.toString() ?? '';
      _current = AppVersion.tryParse(_currentLabel);
      if (_current != null) _currentLabel = _current.toString();
    } catch (e) {
      debugPrint('Updater: could not read the installed version: $e');
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      _ignoredVersion = prefs.getString(_kIgnored) ?? '';
      final last = prefs.getInt(_kLastCheck);
      if (last != null) _lastCheck = DateTime.fromMillisecondsSinceEpoch(last);

      final cached = UpdateInfo.fromJsonString(prefs.getString(_kRequired));
      final current = _current;
      if (cached != null &&
          current != null &&
          cached.mandatory &&
          cached.current == current &&
          cached.latest.version > current) {
        _info = cached;
        _phase = UpdatePhase.available;
        _promptVisible = true;
      } else if (cached != null) {
        await prefs.remove(_kRequired); // stale: the app was updated since
      }
    } catch (e) {
      debugPrint('Updater: could not restore saved state: $e');
    }

    unawaited(_cleanUpOldFiles());
  }

  /// Called once the first real screen is about to show. Until then an
  /// optional update popup waits, so it never lands on top of the splash.
  void markUiReady() {
    if (_uiReady) return;
    _uiReady = true;
    Future<void>.delayed(const Duration(milliseconds: 900), _maybeAutoPrompt);
  }

  /// The automatic check done when the app is entered.
  Future<void> checkOnLaunch() async {
    await check();
  }

  // ───────────────────────────── checking ─────────────────────────────

  /// Looks for a newer release. [manual] is true for the Settings button: an
  /// available update then always opens the popup, even one that was
  /// dismissed or set to "don't remind".
  Future<UpdateCheckResult> check({bool manual = false}) {
    final running = _checkFuture;
    if (running != null) {
      return running.then((r) {
        if (manual && r.outcome == UpdateCheckOutcome.available) _showPrompt();
        return r;
      });
    }
    final f = _doCheck(manual: manual).whenComplete(() => _checkFuture = null);
    _checkFuture = f;
    return f;
  }

  Future<UpdateCheckResult> _doCheck({required bool manual}) async {
    if (!Platform.isAndroid) {
      return const UpdateCheckResult(
        UpdateCheckOutcome.unsupported,
        'In-app updates are only available on Android.',
      );
    }
    if (!UpdateConfig.isConfigured) {
      return const UpdateCheckResult(
        UpdateCheckOutcome.notConfigured,
        'Updates are not set up in this build yet.',
      );
    }
    final current = _current;
    if (current == null) {
      return const UpdateCheckResult(
        UpdateCheckOutcome.failed,
        "Couldn't read the installed version of Trigon.",
      );
    }
    if (busy) {
      // Mid-download: nothing to re-check.
      return const UpdateCheckResult(UpdateCheckOutcome.available);
    }

    _checking = true;
    notifyListeners();
    try {
      final releases = await _fetchReleases();
      _lastCheck = DateTime.now();
      unawaited(_saveString(_kLastCheck, '${_lastCheck!.millisecondsSinceEpoch}'));

      final info = evaluateUpdate(current: current, releases: releases);
      await _applyCheck(info, manual: manual);
      return UpdateCheckResult(
        info == null ? UpdateCheckOutcome.upToDate : UpdateCheckOutcome.available,
      );
    } catch (e) {
      debugPrint('Updater: check failed: $e');
      // A failed check never blocks the app (a saved "must update" state, if
      // there is one, stays in force).
      return UpdateCheckResult(UpdateCheckOutcome.failed, _describe(e));
    } finally {
      _checking = false;
      notifyListeners();
    }
  }

  Future<List<ReleaseInfo>> _fetchReleases() async {
    final url =
        'https://api.github.com/repos/${UpdateConfig.githubRepo}/releases?per_page=100';
    final res = await _dio.get<dynamic>(
      url,
      options: Options(
        headers: const {
          'Accept': 'application/vnd.github+json',
          'X-GitHub-Api-Version': '2022-11-28',
        },
        responseType: ResponseType.json,
        receiveTimeout: const Duration(seconds: 20),
      ),
    );
    final raw = res.data;
    final data = raw is String ? jsonDecode(raw) : raw;
    if (data is! List) {
      throw _UpdateFailure('The update server sent an unexpected answer.');
    }
    final out = <ReleaseInfo>[];
    for (final item in data) {
      final r = ReleaseInfo.fromGithub(item);
      if (r != null) out.add(r);
    }
    return out;
  }

  Future<void> _applyCheck(UpdateInfo? info, {required bool manual}) async {
    if (info == null) {
      _info = null;
      if (!busy) {
        _phase = UpdatePhase.idle;
        _errorMessage = null;
      }
      _promptVisible = false;
      await _remove(_kRequired);
      notifyListeners();
      return;
    }

    final changed = _info?.latest.version != info.latest.version;
    _info = info;
    if (changed || _phase == UpdatePhase.idle || _phase == UpdatePhase.error) {
      _phase = UpdatePhase.available;
      _errorMessage = null;
    }

    if (info.mandatory) {
      await _saveString(_kRequired, info.toJsonString());
    } else {
      await _remove(_kRequired);
    }

    if (manual) {
      _showPrompt();
    } else {
      _maybeAutoPrompt();
    }
    notifyListeners();
  }

  void _showPrompt() {
    _sessionDismissed = false;
    if (_info == null) return;
    _promptVisible = true;
    notifyListeners();
  }

  /// Opens the popup by itself - the entering-the-app prompt - when there is
  /// something to show and the person has not already said "later" / "don't
  /// remind" for it. A mandatory update always shows.
  void _maybeAutoPrompt() {
    final info = _info;
    if (info == null || _promptVisible) return;
    if (info.mandatory) {
      _promptVisible = true;
      notifyListeners();
      return;
    }
    if (!_uiReady || _sessionDismissed) return;
    if (_ignoredVersion == info.latest.version.toString()) return;
    _promptVisible = true;
    notifyListeners();
  }

  // ───────────────────────────── popup actions ─────────────────────────────

  /// "Later" / back / tap outside: hides the popup until the next launch.
  /// Does nothing for a mandatory update or while the update is working.
  void dismissLater() {
    if (mandatory || busy) return;
    if (_phase == UpdatePhase.error ||
        _phase == UpdatePhase.needsPermission ||
        _phase == UpdatePhase.readyToInstall) {
      _phase = UpdatePhase.available;
      _errorMessage = null;
    }
    _promptVisible = false;
    _sessionDismissed = true;
    notifyListeners();
  }

  /// "Don't remind": no automatic popup for this version any more (the
  /// Settings button still shows it).
  void dontRemind() {
    final info = _info;
    if (mandatory || busy || info == null) return;
    _ignoredVersion = info.latest.version.toString();
    unawaited(_saveString(_kIgnored, _ignoredVersion));
    dismissLater();
  }

  /// The Exit button of the mandatory popup.
  void exitApp() {
    SystemNavigator.pop();
  }

  /// "Download & Install" / "Update".
  Future<void> startUpdate() async {
    if (_info == null || busy) return;
    try {
      if (!await _canInstall()) {
        _phase = UpdatePhase.needsPermission;
        notifyListeners();
        return;
      }
    } on _UpdateFailure catch (e) {
      _fail(e);
      return;
    }
    await _downloadAndInstall();
  }

  /// Opens Android's "Install unknown apps" screen for Trigon. The update goes
  /// on by itself when the person comes back with the switch on.
  Future<void> openInstallSettings() async {
    try {
      await _native.invokeMethod<bool>('openInstallSettings');
    } on PlatformException catch (e) {
      _fail(_UpdateFailure(
        e.message ?? "Couldn't open Android's settings. Open Settings > Apps > "
            'Trigon > Install unknown apps yourself.',
      ));
    } on MissingPluginException {
      _fail(_UpdateFailure(_noInstallerMessage, retryable: false));
    }
  }

  /// "Install" after a download that was not installed yet, or "Retry".
  Future<void> retry() async {
    if (_info == null || busy) return;
    _errorMessage = null;
    await startUpdate();
  }

  /// "Cancel" while downloading: stops and throws the partial file away.
  void cancelDownload() {
    if (_phase != UpdatePhase.downloading) return;
    _cancelToken?.cancel('cancelled');
  }

  // ───────────────────────────── permission ─────────────────────────────

  Future<bool> _canInstall() async {
    try {
      return await _native.invokeMethod<bool>('canInstallPackages') ?? false;
    } on MissingPluginException {
      throw _UpdateFailure(_noInstallerMessage, retryable: false);
    } on PlatformException catch (e) {
      throw _UpdateFailure(e.message ?? _noInstallerMessage, retryable: false);
    }
  }

  static const String _noInstallerMessage =
      "This build of Trigon can't install updates by itself. Please install "
      'the latest version manually.';

  Future<void> _continueAfterPermission() async {
    if (_continuing) return;
    _continuing = true;
    try {
      if (await _canInstall()) {
        await _downloadAndInstall();
      }
    } on _UpdateFailure catch (e) {
      _fail(e);
    } finally {
      _continuing = false;
    }
  }

  // ───────────────────────────── download + install ─────────────────────────────

  Future<void> _downloadAndInstall() async {
    final info = _info;
    if (info == null) return;
    final release = info.latest;

    _errorMessage = null;
    _received = 0;
    _total = release.apkSize;
    _phase = UpdatePhase.downloading;
    final token = CancelToken();
    _cancelToken = token;
    notifyListeners();

    DownloadKeepAlive.beginExternal('Downloading the Trigon update');
    File? apk;
    try {
      apk = await _obtainApk(release, token);
    } on _Cancelled {
      _phase = UpdatePhase.available;
      notifyListeners();
      return;
    } on _UpdateFailure catch (e) {
      _fail(e);
      return;
    } catch (e) {
      _fail(_UpdateFailure(_describe(e)));
      return;
    } finally {
      DownloadKeepAlive.endExternal();
      _cancelToken = null;
    }

    await _install(apk);
  }

  Future<String> _updateDir() async {
    try {
      final dir = await _native.invokeMethod<String>('getUpdateDir');
      if (dir != null && dir.isNotEmpty) return dir;
    } on MissingPluginException {
      throw _UpdateFailure(_noInstallerMessage, retryable: false);
    } on PlatformException catch (e) {
      throw _UpdateFailure(e.message ?? _noInstallerMessage, retryable: false);
    }
    throw _UpdateFailure(_noInstallerMessage, retryable: false);
  }

  /// Returns the verified APK of [release], downloading it (or finishing an
  /// interrupted download) when it is not on the device yet.
  Future<File> _obtainApk(ReleaseInfo release, CancelToken token) async {
    final dirPath = await _updateDir();
    final dir = Directory(dirPath);
    if (!await dir.exists()) await dir.create(recursive: true);

    final name = 'trigon-${release.version}.apk';
    final done = File('$dirPath/$name');
    final part = File('$dirPath/$name.part');

    // Already downloaded earlier (installer was cancelled): reuse it.
    if (await done.exists()) {
      _phase = UpdatePhase.verifying;
      notifyListeners();
      if (await _matches(done, release)) return done;
      await _deleteQuietly(done);
      _phase = UpdatePhase.downloading;
      notifyListeners();
    }

    await _removeOtherFiles(dir, keep: {name, '$name.part'});

    for (var attempt = 0; attempt < 2; attempt++) {
      var existing = await part.exists() ? await part.length() : 0;
      if (release.apkSize > 0 && existing > release.apkSize) {
        await _deleteQuietly(part);
        existing = 0;
      }

      try {
        if (release.apkSize > 0 && existing == release.apkSize) {
          // The previous run had received everything.
          _received = existing;
        } else {
          await _streamTo(release, part, existing, token);
        }
        break;
      } on DioException catch (e) {
        if (CancelToken.isCancel(e)) throw _Cancelled();
        // 416: the partial file does not fit what the server has - start over once.
        if (e.response?.statusCode == 416 && attempt == 0) {
          await _deleteQuietly(part);
          continue;
        }
        throw _UpdateFailure(_describe(e));
      }
    }

    if (token.isCancelled) throw _Cancelled();

    _phase = UpdatePhase.verifying;
    notifyListeners();
    if (!await _matches(part, release)) {
      await _deleteQuietly(part);
      throw _UpdateFailure(
        'The downloaded update is damaged. Please try again.',
      );
    }
    await part.rename(done.path);
    return done;
  }

  Future<void> _streamTo(
    ReleaseInfo release,
    File part,
    int existing,
    CancelToken token,
  ) async {
    final res = await _dio.get<ResponseBody>(
      release.apkUrl,
      cancelToken: token,
      options: Options(
        responseType: ResponseType.stream,
        headers: {if (existing > 0) 'Range': 'bytes=$existing-'},
        validateStatus: (s) => s == 200 || s == 206,
      ),
    );

    // 206 = the server continues where we stopped; 200 = it sent everything.
    final resumed = res.statusCode == 206 && existing > 0;
    var received = resumed ? existing : 0;

    if (_total <= 0) {
      final len = int.tryParse(res.headers.value(Headers.contentLengthHeader) ?? '');
      if (len != null && len > 0) _total = resumed ? len + existing : len;
    }

    final sink = part.openWrite(mode: resumed ? FileMode.append : FileMode.write);
    var sinceFlush = 0;
    var lastNotify = DateTime.fromMillisecondsSinceEpoch(0);
    try {
      await for (final chunk in res.data!.stream) {
        sink.add(chunk);
        received += chunk.length;
        sinceFlush += chunk.length;
        _received = received;

        if (sinceFlush >= 4 * 1024 * 1024) {
          sinceFlush = 0;
          await sink.flush(); // keeps memory flat and surfaces disk errors early
        }
        final now = DateTime.now();
        if (now.difference(lastNotify).inMilliseconds >= 120) {
          lastNotify = now;
          notifyListeners();
        }
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    _received = received;
    notifyListeners();

    if (_total > 0 && received < _total) {
      throw _UpdateFailure(
        'The download was interrupted. Check your connection and try again '
        '- it will continue where it stopped.',
      );
    }
  }

  Future<bool> _matches(File file, ReleaseInfo release) async {
    try {
      final len = await file.length();
      if (len <= 0) return false;
      if (release.apkSize > 0 && len != release.apkSize) return false;
      final expected = release.sha256;
      if (expected != null) {
        final digest = await sha256.bind(file.openRead()).first;
        if (digest.toString().toLowerCase() != expected) return false;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _install(File apk) async {
    _phase = UpdatePhase.installing;
    _installLaunchedAt = DateTime.now();
    notifyListeners();
    try {
      await _native.invokeMethod<bool>('installApk', {'path': apk.path});
      // The system installer is open now. If the update goes through, Android
      // restarts the app on the new version; if the person backs out,
      // [didChangeAppLifecycleState] returns to readyToInstall.
    } on PlatformException catch (e) {
      switch (e.code) {
        case 'install_permission':
          _phase = UpdatePhase.needsPermission;
          notifyListeners();
          return;
        case 'signature_mismatch':
          await _deleteQuietly(apk);
          _fail(_UpdateFailure(
            'This update was signed with a different key than the app that is '
            'installed, so Android refuses to install it over it. The developer '
            'needs to publish a build signed with the original key.',
            retryable: false,
          ));
          return;
        case 'downgrade':
          await _deleteQuietly(apk);
          _fail(_UpdateFailure(
            'The downloaded update is older than the installed version.',
            retryable: false,
          ));
          return;
        case 'invalid_apk':
        case 'wrong_package':
        case 'missing_file':
          await _deleteQuietly(apk);
          _fail(_UpdateFailure(
            "The downloaded file isn't a valid Trigon update. Please try again.",
          ));
          return;
        case 'no_installer':
          _fail(_UpdateFailure(
            "This device doesn't have an app installer available.",
            retryable: false,
          ));
          return;
        default:
          _fail(_UpdateFailure(
            e.message ?? "Couldn't open the installer. Please try again.",
          ));
          return;
      }
    } on MissingPluginException {
      _fail(_UpdateFailure(_noInstallerMessage, retryable: false));
    }
  }

  void _fail(_UpdateFailure failure) {
    _phase = UpdatePhase.error;
    _errorMessage = failure.message;
    _errorRetryable = failure.retryable;
    _promptVisible = true; // an error must not happen unseen behind a closed popup
    notifyListeners();
  }

  // ───────────────────────────── app lifecycle / back ─────────────────────────────

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;

    if (_phase == UpdatePhase.needsPermission) {
      // Back from Android's settings: carry on if the switch is on now.
      unawaited(_continueAfterPermission());
    } else if (_phase == UpdatePhase.installing) {
      final launched = _installLaunchedAt;
      if (launched != null &&
          DateTime.now().difference(launched) > const Duration(milliseconds: 1500)) {
        // Back from the installer without the app being replaced: cancelled.
        _phase = UpdatePhase.readyToInstall;
        notifyListeners();
      }
    } else if (!_checking && !busy && Platform.isAndroid) {
      final last = _lastCheck;
      if (last == null || DateTime.now().difference(last) > UpdateConfig.recheckAfter) {
        unawaited(check());
      }
    }
  }

  @override
  Future<bool> didPopRoute() async {
    if (!_promptVisible) return false;
    if (mandatory || busy) return true; // the popup swallows Back
    dismissLater();
    return true;
  }

  // ───────────────────────────── helpers ─────────────────────────────

  String _describe(Object e) {
    if (e is _UpdateFailure) return e.message;
    if (e is DioException) {
      if (e.type == DioExceptionType.badResponse) {
        final code = e.response?.statusCode;
        if (code == 403 || code == 429) {
          return 'The update server is busy right now. Please try again in a few minutes.';
        }
        if (code == 404) {
          return "The update couldn't be found on the server.";
        }
        return 'The update server returned an error ($code).';
      }
      if (e.type == DioExceptionType.badCertificate) {
        return "Couldn't make a secure connection to the update server.";
      }
      return "Couldn't reach the update server. Check your internet connection and try again.";
    }
    if (e is FileSystemException) {
      if (e.osError?.errorCode == 28) {
        return 'Not enough free storage to download the update.';
      }
      return "Couldn't save the update on this device (${e.message}).";
    }
    if (e is SocketException || e is TimeoutException || e is HandshakeException) {
      return "Couldn't reach the update server. Check your internet connection and try again.";
    }
    return 'Something went wrong while updating. Please try again.';
  }

  /// Removes downloaded updates that are not needed any more: the ones for
  /// the installed version or older (left over after a successful update).
  Future<void> _cleanUpOldFiles() async {
    try {
      final current = _current;
      if (current == null) return;
      final dir = Directory(await _updateDir());
      if (!await dir.exists()) return;
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        final base = entity.uri.pathSegments.last;
        final v = AppVersion.tryParse(base.replaceFirst('trigon-', ''));
        if (v == null || v < current || v == current) {
          await _deleteQuietly(entity);
        }
      }
    } catch (_) {
      // Housekeeping only.
    }
  }

  Future<void> _removeOtherFiles(Directory dir, {required Set<String> keep}) async {
    try {
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        if (!keep.contains(entity.uri.pathSegments.last)) {
          await _deleteQuietly(entity);
        }
      }
    } catch (_) {}
  }

  Future<void> _deleteQuietly(File f) async {
    try {
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  Future<void> _saveString(String key, String value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(key, value);
    } catch (_) {}
  }

  Future<void> _remove(String key) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(key);
    } catch (_) {}
  }
}
