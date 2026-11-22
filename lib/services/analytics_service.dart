import 'dart:async';

import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import 'app_settings.dart';
import 'auth/auth_bootstrap.dart';
import 'jellyfin_services/storage_service.dart';

/// Usage statistics through Google Analytics for Firebase: how many people
/// use the app, how often they come back, which screens they open, and a few
/// key actions (play, download).
///
/// - Switched by Settings > "Share Usage Data" (on by default). Off means
///   nothing is collected or sent.
/// - Never throws and never slows the app: if Firebase did not start, or any
///   call fails, it quietly does nothing.
/// - Only anonymous app activity plus the Firebase account id (no email, no
///   name, no titles) is attached. Keep it that way when adding events.
class AnalyticsService {
  AnalyticsService._();

  static bool _started = false;
  static bool _on = false;

  /// Starts collection according to the saved setting. Call after Firebase
  /// has been initialised (AuthBootstrap.init); does nothing if it failed.
  static Future<void> init() async {
    if (_started || !AuthBootstrap.ready) return;
    _started = true;
    try {
      await _apply(await StorageService.getShareUsageData(), changed: false);
      AppSettings.shareUsageData.addListener(() {
        unawaited(_apply(AppSettings.shareUsageData.value, changed: true));
      });
      // Ties activity to the signed-in account (its Firebase id only).
      FirebaseAuth.instance.authStateChanges().listen((user) {
        if (!_on) return;
        _run(() => FirebaseAnalytics.instance.setUserId(id: user?.uid));
      });
    } catch (e) {
      debugPrint('Analytics: could not start: $e');
    }
  }

  static Future<void> _apply(bool enabled, {required bool changed}) async {
    try {
      final analytics = FirebaseAnalytics.instance;
      await analytics.setAnalyticsCollectionEnabled(enabled);
      _on = enabled;
      if (enabled) {
        await analytics.setUserId(id: FirebaseAuth.instance.currentUser?.uid);
      } else {
        await analytics.setUserId(id: null);
        // Opting out also clears what was kept on the device for this install.
        if (changed) await analytics.resetAnalyticsData();
      }
    } catch (e) {
      debugPrint('Analytics: could not apply the setting: $e');
    }
  }

  /// A screen came to the front. [name]: short, lower-case, underscores.
  static void screen(String name) {
    if (!_on) return;
    _run(() => FirebaseAnalytics.instance.logScreenView(screenName: name));
  }

  /// A key action happened. [name]: letters, digits and underscores only
  /// (max 40 characters). Parameter values must be text or numbers.
  static void event(String name, [Map<String, Object>? parameters]) {
    if (!_on) return;
    _run(() => FirebaseAnalytics.instance
        .logEvent(name: name, parameters: parameters));
  }

  static void _run(Future<void> Function() call) {
    try {
      unawaited(call().catchError((Object e) {
        debugPrint('Analytics: $e');
      }));
    } catch (e) {
      debugPrint('Analytics: $e');
    }
  }
}
