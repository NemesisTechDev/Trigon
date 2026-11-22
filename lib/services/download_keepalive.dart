import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

/// Asks the Android side (DownloadService.kt) to keep the app alive in the
/// background while downloads run. Without it Android freezes or kills the
/// process shortly after the screen turns off or the app leaves the screen,
/// which stopped every download.
///
/// While downloads are only paused the service stays up (so the Resume
/// button on their notification still has a running app to talk to) but
/// without wake/Wi-Fi locks, so a paused download does not drain the battery.
///
/// [sync] is cheap and safe to call as often as the download state changes;
/// it only talks to the platform when something actually needs to change.
class DownloadKeepAlive {
  DownloadKeepAlive._();

  static const MethodChannel _channel =
      MethodChannel('com.nemesis.app/download_service');

  static bool _on = false;
  static bool _hold = true;

  // The in-app updater (lib/services/update) also needs the app kept alive
  // while it downloads a new version. It shares this one foreground service:
  // while [_external] is set the service is never stopped, and when the
  // updater is done it only stops the service if no real download needs it.
  static bool _external = false;
  static int _lastActive = 0;
  static int _lastPaused = 0;
  static String _lastText = '';
  static DateTime _lastSent = DateTime.fromMillisecondsSinceEpoch(0);
  static Timer? _stopTimer;

  /// [active]: downloads running or waiting for a slot. [paused]: paused ones.
  static void sync({
    required int active,
    required int paused,
    required String text,
  }) {
    if (!Platform.isAndroid) return;

    _lastActive = active;
    _lastPaused = paused;

    if (active + paused <= 0) {
      // The updater is still downloading: keep the service up.
      if (_external) return;
      // Wait a moment before stopping: the next queued download starts in the
      // same instant the previous one ends, and the service should not flap.
      _stopTimer ??= Timer(const Duration(seconds: 4), () {
        _stopTimer = null;
        if (_external) return;
        if (!_on) return;
        _on = false;
        _call('stop', text: '', hold: true);
      });
      return;
    }

    _stopTimer?.cancel();
    _stopTimer = null;

    final hold = active > 0;
    final now = DateTime.now();
    final sinceLast = now.difference(_lastSent);

    if (!_on) {
      // Not running yet (or Android refused earlier): try, but not in a loop.
      if (sinceLast < const Duration(seconds: 8)) return;
      _lastSent = now;
      _lastText = text;
      _hold = hold;
      _call('start', text: text, hold: hold).then((ok) => _on = ok);
      // Assume success so the very next sync does not start it twice.
      _on = true;
      return;
    }

    // The native side holds a time-limited wake lock, so renew it regularly
    // even when nothing changed.
    final renew = hold && sinceLast > const Duration(minutes: 10);
    final holdChanged = hold != _hold;
    final changed = text != _lastText && sinceLast > const Duration(seconds: 4);
    if (renew || holdChanged || changed) {
      _lastSent = now;
      _lastText = text;
      _hold = hold;
      _call('update', text: text, hold: hold);
    }
  }

  /// The in-app updater starts downloading: keep the app alive (with wake and
  /// Wi-Fi locks) until [endExternal]. Safe to call when already running.
  static void beginExternal(String text) {
    if (!Platform.isAndroid) return;
    _external = true;
    _stopTimer?.cancel();
    _stopTimer = null;
    _lastSent = DateTime.now();
    _lastText = text;
    _hold = true;
    _on = true;
    _call('start', text: text, hold: true).then((ok) {
      // Android refused (e.g. not allowed right now): the download still
      // runs while the app is on screen, so just remember it is not running.
      if (!ok && _external) _on = false;
    });
  }

  /// The updater finished, failed or was cancelled. The service is stopped
  /// unless real downloads still need it (their next [sync] keeps it going).
  static void endExternal() {
    if (!Platform.isAndroid) return;
    if (!_external) return;
    _external = false;
    if (_lastActive + _lastPaused > 0) {
      // Real downloads are running or paused: hand the notification text back
      // to them on their next sync, and keep the service.
      _lastSent = DateTime.fromMillisecondsSinceEpoch(0);
      return;
    }
    if (!_on) return;
    _on = false;
    _call('stop', text: '', hold: true);
  }

  static Future<bool> _call(
    String method, {
    required String text,
    required bool hold,
  }) async {
    try {
      final r = await _channel.invokeMethod<dynamic>(method, {
        'title': hold ? 'Downloading' : 'Downloads paused',
        'text': text,
        'hold': hold,
      });
      return r != false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    } catch (_) {
      return false;
    }
  }
}
