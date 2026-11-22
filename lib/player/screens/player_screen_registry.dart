import 'package:flutter/material.dart';

/// Which full-screen player a registered route is showing.
enum PlayerScreenKind { audio, video }

/// Keeps track of which full-screen player routes ([AudioPlayerScreen] /
/// [VideoPlayerScreen]) are currently open on the root navigator, so a new
/// player can REPLACE the one already on screen instead of stacking on top.
///
/// ROOT CAUSE this exists for (Open With / Play With): every player screen
/// is pushed with a plain `Navigator.push`. Opening a video through
/// "Open With" while the audio player screen was up (or an audio file while
/// the video player was up) therefore left the old player route sitting
/// underneath the new one. Backing out of the new player then revealed the
/// stale player for a moment — until its own listeners noticed there was
/// nothing left to show (`_exitIfQueueEnded` / `playbackFinished`) and it
/// popped itself too, which read as a screen flashing in and vanishing.
///
/// Screens register their own route from `didChangeDependencies` and
/// unregister in `dispose`, so this needs no changes at any existing push
/// site and no NavigatorObserver wiring in main.dart.
class PlayerScreenRegistry {
  PlayerScreenRegistry._();

  static final Map<Route<dynamic>, PlayerScreenKind> _open = {};

  static void register(Route<dynamic>? route, PlayerScreenKind kind) {
    if (route == null) return;
    _open[route] = kind;
  }

  static void unregister(Route<dynamic>? route) {
    if (route == null) return;
    _open.remove(route);
  }

  /// Pushes [route] (a player screen of [kind]) onto [navigator] while making
  /// sure at most one full-screen player route is ever open:
  ///
  ///  - no player open            -> plain push
  ///  - same kind already open    -> nothing is pushed; the open screen is
  ///    already driven by PlayerManager.currentItemNotifier, so it simply
  ///    shows the new item. Anything stacked above it (queue, lyrics, a
  ///    sheet) is popped so the player is what the person sees.
  ///  - other kind already open   -> pushReplacement, so the old player is
  ///    swapped out rather than left underneath the new one.
  static Future<T?> openExclusive<T>(
    NavigatorState navigator,
    PlayerScreenKind kind,
    Route<T> route,
  ) {
    if (_open.isEmpty) return navigator.push(route);

    // Pop whatever sits above the topmost open player route. `isFirst` is a
    // safety stop so a stale registry entry can never pop the app's root.
    Route<dynamic>? topPlayer;
    navigator.popUntil((r) {
      if (_open.containsKey(r)) {
        topPlayer = r;
        return true;
      }
      return r.isFirst;
    });

    final found = topPlayer;
    if (found == null) return navigator.push(route);
    if (_open[found] == kind) return Future<T?>.value(null);
    return navigator.pushReplacement(route);
  }
}
