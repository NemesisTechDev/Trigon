import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'display_helper.dart';

/// One owner for everything that happens to the screen orientation while a
/// full-screen video player (the native [VideoPlayerScreen] or the web based
/// EmbedPlayerScreen) is open, and when it closes.
///
/// ROOT CAUSES this fixes:
///
/// 1. Embed servers did not rotate to landscape. With "Embed servers" on, a
///    Play tap first opens the native player screen (it is pushed before the
///    app knows which source is used), which rotates to landscape. Right
///    after, the app closes it and opens the embed screen. The native
///    screen's dispose() runs only when its closing animation has finished,
///    i.e. AFTER the embed screen had already locked landscape, and it
///    released the lock again, so the phone turned back to portrait under the
///    embed player. [beginHandoff] / the open-screen counter stop that:
///    a player screen that closes while another one is open, or about to
///    open, never touches the orientation.
///
/// 2. Rotating back to portrait on exit was late. The orientation used to be
///    reset in dispose(), after the route's pop animation, so the screen
///    underneath (a details screen) was drawn in landscape first and only
///    then turned. [PlayerExitScope] now turns the phone to portrait FIRST,
///    behind a black cover, and pops the route once the window really is
///    portrait. When the phone is physically held in landscape with
///    auto-rotate on (the system keeps landscape anyway) there is nothing to
///    wait for and it pops at once, exactly as before.
class PlayerOrientation {
  PlayerOrientation._();

  /// Native helper in MainActivity.kt: the phone's physical tilt and the
  /// system auto-rotate switch. Optional: without it exits fall back to the
  /// previous behaviour.
  static const MethodChannel _native =
      MethodChannel('com.nemesis.app/orientation');

  /// Player screens currently open (created, not yet disposed).
  static int _screens = 0;

  /// A player screen was closed on purpose to open another one right after
  /// (native loading screen -> embed player). Orientation is left alone.
  static bool _handoff = false;
  static Timer? _handoffTimer;

  /// An exit is under way (the screen is turning to portrait / about to pop).
  static bool _leaving = false;

  /// The exit already put the orientation where it belongs, so the dispose()
  /// that follows must not touch it again.
  static bool _settled = false;

  /// True while a player screen is on its way out.
  static bool get isLeaving => _leaving;

  /// True when the window is currently taller than wide.
  static bool get viewIsPortrait => _viewIsPortrait();

  // ------------------------------------------------------------------ enter

  /// Called from a player screen's initState: immersive + landscape lock.
  static void enter() {
    _screens++;
    _clearHandoff();
    _leaving = false;
    _settled = false;
    unawaited(_track(true));
    unawaited(DisplayHelper.enterFullscreen());
  }

  /// Puts the landscape lock back (it is idempotent). Used by the embed
  /// screen after the first frame, when the page has loaded, on resume and
  /// whenever the window turns out to be portrait while it should not be.
  static void ensureLandscape() {
    if (_leaving || _handoff || _screens == 0) return;
    unawaited(DisplayHelper.enterFullscreen());
  }

  // ---------------------------------------------------------------- handoff

  /// The player screen that is open is about to be closed so that another
  /// player screen can take its place. Keeps the orientation as it is.
  static void beginHandoff() {
    _handoff = true;
    _handoffTimer?.cancel();
    // Safety net: if the next screen never shows up, restore after a while.
    _handoffTimer = Timer(const Duration(seconds: 10), cancelHandoff);
  }

  /// The hand-over did not happen (blocked, unsupported...). Restores the
  /// orientation when no player screen is open.
  static void cancelHandoff() {
    final was = _handoff;
    _clearHandoff();
    if (was && _screens == 0) {
      unawaited(DisplayHelper.showSystemBars());
      unawaited(DisplayHelper.unlockOrientation());
    }
  }

  static void _clearHandoff() {
    _handoff = false;
    _handoffTimer?.cancel();
    _handoffTimer = null;
  }

  // ------------------------------------------------------------------ close

  /// Called from a player screen's dispose().
  ///
  /// [fullscreen]: the screen was still in its (forced landscape) fullscreen
  /// state, not toggled back to windowed.
  static void screenClosed({required bool fullscreen}) {
    if (_screens > 0) _screens--;
    _leaving = false;

    // Another player screen is open (or about to open): it owns the
    // orientation now.
    if (_screens > 0 || _handoff) return;

    unawaited(_track(false));

    // The exit already did all of it before the pop.
    if (_settled) {
      _settled = false;
      return;
    }

    // Closed by some other route (not through PlayerExitScope): same rules as
    // always. Still fullscreen -> only release the lock and let the system
    // decide; otherwise back to portrait.
    if (fullscreen) {
      unawaited(DisplayHelper.showSystemBars());
      unawaited(DisplayHelper.unlockOrientation());
    } else {
      unawaited(DisplayHelper.exitFullscreen());
    }
  }

  // ------------------------------------------------------------------- exit

  static bool _beginLeave() {
    if (_leaving) return false;
    _leaving = true;
    return true;
  }

  /// Gets the orientation right BEFORE the player route is popped, so the
  /// screen underneath is never shown in the wrong orientation.
  static Future<void> _settleBeforePop({
    required bool fullscreen,
    required VoidCallback showCover,
  }) async {
    // Handing over to another player: leave everything as it is.
    if (_handoff) return;

    // Windowed (portrait) playback: already portrait, dispose() keeps the
    // portrait lock like before.
    if (!fullscreen) return;

    // The window is already portrait (nothing rotated it): just release.
    if (_viewIsPortrait()) {
      await _release();
      _settled = true;
      return;
    }

    // Held in landscape with auto-rotate on: the system keeps landscape once
    // the lock is released, so there is no rotation to wait for.
    if (await _staysLandscape()) {
      await _release();
      _settled = true;
      return;
    }

    // Otherwise the system is about to turn to portrait. Do it now, hidden
    // behind a black cover, and pop only when the window is portrait.
    showCover();
    // Let the black frame reach the screen first: Android freezes the last
    // drawn frame for its rotation animation, which must not be the player.
    WidgetsBinding.instance.scheduleFrame();
    await WidgetsBinding.instance.endOfFrame;
    await SystemChrome.setPreferredOrientations(
      const [DeviceOrientation.portraitUp],
    );
    await DisplayHelper.showSystemBars();
    await _waitForPortrait();
    // Free rotation again, same as everywhere else in the app. The phone is
    // already portrait, so nothing moves.
    await DisplayHelper.unlockOrientation();
    _settled = true;
  }

  static Future<void> _release() async {
    await DisplayHelper.showSystemBars();
    await DisplayHelper.unlockOrientation();
  }

  /// Would the system stay in landscape when the lock is released?
  /// Needs auto-rotate on and the phone physically held on its side.
  static Future<bool> _staysLandscape() async {
    try {
      final r = await _native
          .invokeMapMethod<String, dynamic>('exitPlan')
          .timeout(const Duration(milliseconds: 250));
      if (r == null) return false;
      if (r['autoRotate'] == false) return false;
      final deg = (r['degrees'] as num?)?.toInt() ?? -1;
      // Unknown / lying flat: the system keeps the current rotation.
      if (deg < 0) return true;
      return (deg >= 45 && deg < 135) || (deg >= 225 && deg < 315);
    } on MissingPluginException {
      // MainActivity.kt without the orientation channel: previous behaviour.
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<void> _track(bool on) async {
    try {
      await _native.invokeMethod<void>('track', on);
    } catch (_) {}
  }

  static bool _viewIsPortrait() {
    final views = WidgetsBinding.instance.platformDispatcher.views;
    if (views.isEmpty) return false;
    final size = views.first.physicalSize;
    return size.height >= size.width;
  }

  static Future<void> _waitForPortrait() async {
    if (!_viewIsPortrait()) {
      final done = Completer<void>();
      final watcher = _MetricsWatcher(() {
        if (_viewIsPortrait() && !done.isCompleted) done.complete();
      });
      WidgetsBinding.instance.addObserver(watcher);
      try {
        await done.future.timeout(
          const Duration(milliseconds: 700),
          onTimeout: () {},
        );
      } finally {
        WidgetsBinding.instance.removeObserver(watcher);
      }
    }
    // Let the portrait layout be drawn once before the route goes away.
    WidgetsBinding.instance.scheduleFrame();
    await WidgetsBinding.instance.endOfFrame;
  }
}

class _MetricsWatcher with WidgetsBindingObserver {
  _MetricsWatcher(this.onChanged);

  final VoidCallback onChanged;

  @override
  void didChangeMetrics() => onChanged();
}

/// Wrap a full-screen player screen in this. Every way of leaving it (back
/// arrow, system back button / gesture, auto-exit at the end, error screen,
/// "Still watching?") goes through `Navigator.maybePop` and ends up here, so
/// the phone is turned to portrait before the player route is popped.
class PlayerExitScope extends StatefulWidget {
  const PlayerExitScope({
    super.key,
    required this.child,
    required this.isFullscreen,
    this.onExitStart,
    this.onBack,
  });

  final Widget child;

  /// Whether the screen is in its forced-landscape fullscreen state.
  final bool Function() isFullscreen;

  /// Runs as soon as leaving starts (stop the sound, stop sensors...).
  final VoidCallback? onExitStart;

  /// Gets the back action first; return true when it was used up (for
  /// example to leave a web page's own fullscreen) and nothing should close.
  final bool Function()? onBack;

  @override
  State<PlayerExitScope> createState() => _PlayerExitScopeState();
}

class _PlayerExitScopeState extends State<PlayerExitScope> {
  bool _covered = false;

  Future<void> _leave() async {
    if (!PlayerOrientation._beginLeave()) return;

    final navigator = Navigator.of(context);
    final route = ModalRoute.of(context);

    try {
      widget.onExitStart?.call();
    } catch (_) {}

    try {
      await PlayerOrientation._settleBeforePop(
        fullscreen: widget.isFullscreen(),
        showCover: () {
          if (mounted) setState(() => _covered = true);
        },
      );
    } catch (_) {}

    // Already gone some other way meanwhile (dispose reset the flags).
    if (!mounted) return;

    if (route != null && route.isActive) {
      if (route.isCurrent) {
        navigator.pop();
      } else {
        navigator.removeRoute(route);
      }
    } else {
      PlayerOrientation._leaving = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (widget.onBack?.call() ?? false) return;
        unawaited(_leave());
      },
      child: Stack(
        fit: StackFit.passthrough,
        children: [
          widget.child,
          if (_covered)
            const Positioned.fill(
              child: AbsorbPointer(
                child: ColoredBox(color: Colors.black),
              ),
            ),
        ],
      ),
    );
  }
}
