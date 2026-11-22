import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

/// Starts Firebase (Auth + App Check) once, at app launch.
///
/// Designed to fail closed but never crash: if Firebase can't start (for
/// example google-services.json is missing from a build), [ready] stays
/// false, the app still opens, and sign-in shows a clear "unavailable"
/// message instead of letting anyone in.
class AuthBootstrap {
  AuthBootstrap._();

  static bool ready = false;

  static Future<void> init() async {
    if (ready) return;

    try {
      // No options needed on Android: the Google Services Gradle plugin
      // turns android/app/google-services.json into the app's config.
      await Firebase.initializeApp().timeout(const Duration(seconds: 10));
      ready = true;
    } catch (e) {
      debugPrint('[Auth] Firebase failed to start: $e');
      return;
    }

    // App Check proves requests come from the genuine, Play-distributed app
    // (Play Integrity) rather than a script or a repackaged APK. Debug
    // builds use the debug provider (its token is printed in logcat and must
    // be registered in the Firebase console). It is in "monitor" mode until
    // enforcement is turned on in the console - see SETUP.md.
    try {
      await FirebaseAppCheck.instance
          .activate(
            providerAndroid: kReleaseMode
                ? AndroidPlayIntegrityProvider()
                : AndroidDebugProvider(),
          )
          .timeout(const Duration(seconds: 10));
    } catch (e) {
      debugPrint('[Auth] App Check failed to activate: $e');
    }
  }
}
