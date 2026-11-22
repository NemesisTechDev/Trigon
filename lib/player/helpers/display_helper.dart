import 'package:flutter/services.dart';

class DisplayHelper {
  DisplayHelper._();

  static Future<void>enterFullscreen() async {
    await SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.immersiveSticky,
    );

    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  }

  static Future<void> enterFullscreenLandscape() async {
    await enterFullscreen();
  }

  static Future<void> exitFullscreen() async {
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
    ]);

    await SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.edgeToEdge,
    );
  }

  /// Releases the orientation lock entirely — portrait and landscape
  /// both become fair game again, same as everywhere else in the app
  /// outside the player (the manifest declares `unspecified`) — instead
  /// of narrowing it down to one specific orientation the way
  /// [exitFullscreen] does. Used when leaving the video player while
  /// still in fullscreen/landscape: the device stays in landscape (its
  /// current physical orientation) rather than snapping to portrait,
  /// while the user can still rotate freely afterward.
  static Future<void> unlockOrientation() async {
    await SystemChrome.setPreferredOrientations([]);
  }

  /// Hides the status/navigation bars without touching orientation lock.
  /// Used by the player's manual fullscreen toggle button, as opposed to
  /// [enterFullscreen]/[exitFullscreen] which are driven by the device
  /// rotation sensor via OrientationService.
  static Future<void> hideSystemBars() async {
    await SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.immersiveSticky,
    );
  }

  /// Shows the status/navigation bars again without touching orientation
  /// lock. Pairs with [hideSystemBars].
  static Future<void> showSystemBars() async {
    await SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.edgeToEdge,
    );
  }
}