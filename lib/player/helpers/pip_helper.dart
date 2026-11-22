import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:simple_pip_mode/simple_pip.dart';
import 'package:simple_pip_mode/aspect_ratio.dart';

/// Thin facade over the `simple_pip_mode` plugin, so the rest of the
/// player only ever talks to this one class rather than the plugin's
/// API directly — if the underlying PiP plugin ever needs to change
/// again, only this file (and the native wiring it documents) should
/// need to change.
///
/// ---
/// ### Android setup (required)
/// `simple_pip_mode` needs its PiP callbacks wired up natively. This
/// app's `MainActivity` already has to extend `AudioServiceActivity`
/// (for the lock-screen/notification widget), so it can't also extend
/// `simple_pip_mode`'s `PipCallbackHelperActivityWrapper` — Kotlin only
/// allows one superclass. Use the plugin's documented manual fallback
/// instead:
/// ```kotlin
/// package com.example.nemesis
///
/// import android.content.res.Configuration
/// import cl.puntito.simple_pip_mode.PipCallbackHelper
/// import com.ryanheise.audioservice.AudioServiceActivity
/// import io.flutter.embedding.engine.FlutterEngine
///
/// class MainActivity : AudioServiceActivity() {
///     private val pipCallbackHelper = PipCallbackHelper()
///
///     override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
///         super.configureFlutterEngine(flutterEngine)
///         pipCallbackHelper.configureFlutterEngine(flutterEngine)
///     }
///
///     override fun onPictureInPictureModeChanged(
///         isInPictureInPictureMode: Boolean,
///         newConfig: Configuration
///     ) {
///         super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
///         pipCallbackHelper.onPictureInPictureModeChanged(isInPictureInPictureMode)
///     }
/// }
/// ```
/// `AndroidManifest.xml` already has `android:supportsPictureInPicture`
/// and the matching `android:configChanges` on `MainActivity` — nothing
/// else to add there.
///
/// ### iOS
/// System PiP on iOS is built around `AVPictureInPictureController`,
/// which attaches to an `AVPlayerLayer`. media_kit doesn't render
/// through AVPlayer, so `simple_pip_mode` (Android-only) can't help
/// there either — real iOS PiP would need a dedicated native bridge (or
/// a plugin that already does that bridging for mpv-based renderers).
/// [isSupported] correctly reports `false` on iOS in the meantime.
class PiPHelper {
  PiPHelper._();

  // A single shared instance, created once — its onPipEntered/
  // onPipExited callbacks are what keep [isActive] correct, and the
  // plugin's docs create exactly one of these per app for that reason.
  static final SimplePip _pip = SimplePip(
    onPipEntered: () => isActive.value = true,
    onPipExited: () => isActive.value = false,
  );

  static const AspectRatio _videoAspectRatio = (16, 9);

  /// Whether the app is currently rendered inside the native PiP
  /// window. `VideoPlayerScreen` wraps its content in a `PipWidget`
  /// (which handles swapping the UI itself), so nothing currently
  /// needs to react to this directly — it's kept as a simple source of
  /// truth for anything that does in future (e.g. hiding a PiP button
  /// while already in PiP).
  static final ValueNotifier<bool> isActive = ValueNotifier(false);

  /// Whether entering PiP is expected to do anything on this device —
  /// true only on Android API 26+. Callers can use this to hide the PiP
  /// button entirely rather than show one that silently does nothing.
  static Future<bool> get isSupported async {
    if (!Platform.isAndroid) return false;

    try {
      return await SimplePip.isPipAvailable;
    } catch (e) {
      debugPrint('PiP: availability check failed — $e');
      return false;
    }
  }

  static Future<void> enterPiP() async {
    if (!Platform.isAndroid) return;

    try {
      await _pip.enterPipMode(aspectRatio: _videoAspectRatio);
    } catch (e) {
      debugPrint('PiP: failed to enter — $e');
    }
  }

  /// Tells the OS whether it should auto-enter PiP when the user leaves
  /// the app (home button/recents) — the video player screen calls this
  /// with `true` in initState and `false` in dispose, so leaving the
  /// app from anywhere else (Home, Movies, mid-browse, etc.) never
  /// unexpectedly triggers PiP. Requires Android 12+; silently does
  /// nothing on older versions (they fall back to the PiP button only).
  static Future<void> setAutoEnterEnabled(bool enabled) async {
    if (!Platform.isAndroid) return;

    try {
      await _pip.setAutoPipMode(
        aspectRatio: _videoAspectRatio,
        autoEnter: enabled,
        seamlessResize: enabled,
      );
    } catch (e) {
      debugPrint('PiP: failed to set auto-enter — $e');
    }
  }
}
