import 'package:flutter/material.dart';
import '../../services/analytics_service.dart';
import 'dart:async';
import '../widgets/seek_indicator.dart';
import 'package:media_kit_video/media_kit_video.dart';
import '../../player/player_manager.dart';
import '../../player/helpers/display_helper.dart';
import '../../player/helpers/player_orientation.dart';
import '../widgets/volume_boost_indicator.dart';
import '../../casting/ui/cast_volume_control.dart';
import '../../player/services/orientation_service.dart';
import 'package:native_device_orientation/native_device_orientation.dart';
import '../widgets/horizontal_seek_overlay.dart';
import '../widgets/play_pause_animation.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:volume_controller/volume_controller.dart';
import '../widgets/video_surface.dart';
import '../widgets/player_gesture_layer.dart';
import '../widgets/player_overlay_layer.dart';
import '../../widgets/player/buffering_overlay.dart';
import '../widgets/player_controls_layer.dart';
import '../widgets/episode_list_panel.dart';
import '../widgets/live_channel_list_panel.dart';
import '../widgets/player_lock_overlay.dart';
import '../helpers/pip_helper.dart';
import 'package:simple_pip_mode/pip_widget.dart';
import 'package:simple_pip_mode/actions/pip_action.dart';
import 'package:simple_pip_mode/actions/pip_actions_layout.dart';
import '../models/media_item.dart';
import 'player_screen_registry.dart';
import '../../casting/playback_coordinator.dart';
import '../../casting/cast_manager.dart';
import '../../casting/models/cast_session.dart';
import '../../casting/ui/casting_backdrop.dart';

class VideoPlayerScreen extends StatefulWidget {
  const VideoPlayerScreen({
    super.key,
  });

  @override
  State<VideoPlayerScreen> createState() =>
      _VideoPlayerScreenState();
}

class _VideoPlayerScreenState
    extends State<VideoPlayerScreen> {
  final VolumeController volumeController = VolumeController.instance;


  // This screen's own route, registered with PlayerScreenRegistry so an
  // Open With/Play With audio file replaces it instead of stacking on top.
  Route<dynamic>? _registeredRoute;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _registeredRoute ??= ModalRoute.of(context);
    PlayerScreenRegistry.register(_registeredRoute, PlayerScreenKind.video);
  }

  bool controlsVisible = true;

  bool showSeekLeft = false;
  bool showSeekRight = false;

  double brightnessValue = 0.5;
  double volumeValue = 0.5;

  bool showBrightness = false;
  bool showVolume = false;

  // VLC-style volume boost (local playback only — never while casting).
  // [_volumeLevel] is one combined 0.0–2.0 scale: 0.0–1.0 is the device's
  // own volume, 1.0–2.0 is mpv software gain on top of a maxed device
  // volume (see PlayerManager.setVolumeGain). [volumeValue] above stays
  // the plain 0–1 device volume, which the casting path still uses.
  static const double _maxVolumeLevel = 2.0;
  double _volumeLevel = 0.5;
  // Like VLC, a single swipe stops at 100%; a swipe has to START at
  // 100% to continue into the boost range.
  bool _gestureAllowsBoost = false;
  bool _volumeUpdatedInGesture = false;
  double _lastSentSystemVolume = -1;
  bool showBoostHint = false;
  Timer? _boostHintTimer;

  // While casting a video, the right-side swipe controls the TV's
  // volume (0–100%, no boost) instead of the phone's. [_castVolumeLevel]
  // is the gesture's own running value — seeded from the session at the
  // start of each swipe so a poll landing mid-drag can't make it jump.
  final CastVolumeSender _castVolumeSender = CastVolumeSender();
  double _castVolumeLevel = 0.5;
  bool _castVolumeTouchedInGesture = false;

  bool showPlayPause = false;

  Timer? controlsTimer;

  bool isHorizontalSeeking = false;

  // Edge strip, in logical pixels, reserved for the OS's own edge
  // gestures (status bar reveal at the top; home/PiP swipe at the
  // bottom) — kept free of this screen's own swipe gestures so they
  // don't fight each other. Used as the top exclusion always, and as
  // the bottom exclusion whenever the controls (and therefore the seek
  // bar) aren't currently visible.
  static const _edgeGestureExclusion = 32.0;

  Duration horizontalSeekPosition = Duration.zero;

  // Position at the start of the current horizontal drag, so we can
  // tell whether the drag is currently moving forward or backward (used
  // to pick the correct fast-forward/fast-rewind icon).
  Duration horizontalSeekStartPosition = Duration.zero;

  // Whether the small unlock button is currently shown while controls
  // are locked. Tapping the screen while locked toggles this instead of
  // the normal control bars.
  bool showLockButton = false;

  Timer? lockButtonTimer;

  // Debounce timers for the brightness/volume/seek indicators. Each is
  // cancelled and restarted on every new update so a fast run of
  // gesture events doesn't hide the indicator mid-gesture — previously
  // every call scheduled its own independent hide, so the earliest one
  // could fire and hide the indicator while the user was still dragging.
  Timer? brightnessHideTimer;
  Timer? volumeHideTimer;
  Timer? seekLeftHideTimer;
  Timer? seekRightHideTimer;

  // Casting-video mini-player bug fix: mirrors CastManager's own active
  // session so we know when to detach the `currentItem` listener below
  // (a straight `==` check on CastSession isn't meaningful — this just
  // tracks *which* session, if any, this screen is currently listening
  // to, the same way `oldWidget` comparisons work elsewhere).
  CastSession? _trackedCastSession;

  // Reuse PlayerManager's singleton VideoController instead of creating a
  // new one here. It's created once at app startup (before playback ever
  // starts) so the native player always has a video output attached in
  // time; creating a fresh one per-screen was too late, since by the time
  // this screen exists, playMedia() has already called player.open().
  VideoController get controller =>
      PlayerManager.instance.videoController;

  @override
  void initState() {
    super.initState();
    AnalyticsService.screen('video_player');

    // Immersive + landscape lock. PlayerOrientation also keeps count of the
    // open player screens, so this screen closing late (after another
    // player has already opened) can never undo that player's orientation.
    PlayerOrientation.enter();

    // Lets the native side know it's OK to auto-enter PiP if the user
    // leaves the app (home button/recents) while this screen is up —
    // see PiPHelper's doc comment. Turned back off in dispose() so
    // leaving the app from anywhere else in the app never triggers it.
    PiPHelper.setAutoEnterEnabled(true);

    // Set this immediately rather than waiting on the orientation
    // sensor callback below to eventually report landscape — the
    // screen should read as fullscreen the instant it opens, not
    // whenever the sensor gets around to confirming it.
    PlayerManager.instance.isFullscreen.value = true;

    // While the user is dragging the seek bar thumb, cancel the
    // auto-hide timer and keep controls visible — otherwise a drag
    // that takes longer than the hide delay gets cut short mid-gesture
    // (the Slider is removed from the tree before onChangeEnd can fire,
    // so the seek never actually commits).
    PlayerManager.instance.isSeeking.addListener(_handleSeekingChanged);

    PlayerManager.instance.isLocked.addListener(_handleLockChanged);

    // Casting Phase 8: once PlaybackCoordinator hands this screen's
    // playback off to a TV, force the control chrome visible (and stop
    // it auto-hiding) so CastingActivePanel — swapped in by
    // PlayerControls itself — is never left sitting invisible behind a
    // timed-out `controlsVisible`. Reverting the handoff (session ended,
    // or the load failed and PlaybackCoordinator handed control back to
    // local playback) resumes the normal auto-hide behavior.
    PlaybackCoordinator.instance.isHandoffActive
        .addListener(_handleCastVisibilityStateChanged);

    // MiniPlayer bug fix: a "Cast to" started straight from a details
    // screen (CastToButton) never sets `isHandoffActive` — that flag
    // only ever goes true for a handoff that *began* as local playback
    // (see PlaybackCoordinator). Reopening this screen from the
    // video-casting mini player for a direct "Cast to" session used to
    // fall through to the plain 4-second auto-hide timer below with
    // nothing listening to force the chrome back — CastingBackdrop has
    // no controls of its own, so once the timer hid PlayerControls there
    // was nothing left on screen to tap back into (PlayerGestureLayer
    // still worked, but toggling `controlsVisible` back to true just got
    // silently re-hidden 4 seconds later with no cast-aware exemption to
    // stop it, reading as "gone for good"). Listening to the session
    // itself — not just the handoff flag — and re-running the same
    // force-visible/cancel-timer logic covers that direct-cast case too.
    CastManager.instance.activeSession.addListener(_handleCastSessionChanged);

    // Video finished with nothing left to continue to (no next episode
    // queued, no next-movie recommendation) — see the `completed` stream
    // listener in PlayerManager for exactly when this fires.
    PlayerManager.instance.playbackFinished.addListener(_handlePlaybackFinished);

    // Starts the 4-hour "Still watching?" idle clock fresh for this
    // session — see registerActivity()'s doc comment for what counts as
    // activity and resets it.
    PlayerManager.instance.registerActivity();

    // The orientation sensor reports the phone's actual physical
    // orientation — which is still portrait the instant this screen
    // opens (most people tap Play holding the phone upright) even
    // though enterFullscreen() above just forced the UI into
    // landscape. Starting to listen immediately raced that forced
    // landscape lock against the sensor's stale portrait reading:
    // depending on exactly when each settled, playback could open
    // fullscreen and stay there, drop straight to windowed, or flip
    // full → windowed → full as the sensor caught up — the
    // inconsistency this delay fixes. Waiting a moment for the
    // physical rotation (and the sensor) to catch up first means only
    // genuine rotations *after* this screen has settled ever get
    // acted on.
    Future.delayed(const Duration(milliseconds: 600), () {
      if (!mounted) return;

      OrientationService.start((orientation) async {
        // Leaving: PlayerOrientation is already turning the phone to
        // portrait, this callback must not fight it.
        if (PlayerOrientation.isLeaving) return;
        switch (orientation) {
          case NativeDeviceOrientation.landscapeLeft:
          case NativeDeviceOrientation.landscapeRight:
            await DisplayHelper.enterFullscreen();
            PlayerManager.instance.isFullscreen.value = true;
            break;

          case NativeDeviceOrientation.portraitUp:
          case NativeDeviceOrientation.portraitDown:
            await DisplayHelper.exitFullscreen();
            PlayerManager.instance.isFullscreen.value = false;
            break;

          default:
            break;
        }
      });
    });

    startControlsTimer();

    // Picks up a cast session that's already active/casting-video by the
    // time this screen opens (the normal mini-player-tap case) and, if
    // so, immediately cancels the plain timer just started above in
    // favor of the cast-aware force-visible behavior — see the doc
    // comment on the `activeSession.addListener` call above for why this
    // needs checking in addition to `isHandoffActive`.
    _handleCastSessionChanged();

    ScreenBrightness().application.then((value) {
      brightnessValue = value;
    });

    VolumeController.instance.getVolume().then((value) {
      volumeValue = value;

      // Re-opening this screen with a boost still applied (e.g. coming
      // back from a different screen mid-session) must show/continue it.
      final gain = PlayerManager.instance.volumeGain;
      _volumeLevel =
          (value >= 0.999 && gain > 100) ? 1.0 + (gain - 100) / 100 : value;
      _lastSentSystemVolume = value;
    });
  }


  void _handleSeekingChanged() {
    if (!mounted) return;

    // Dragging the seek bar thumb is real activity, same as any other
    // gesture on this screen — resets the "Still watching?" idle clock.
    PlayerManager.instance.registerActivity();

    if (PlayerManager.instance.isSeeking.value) {
      controlsTimer?.cancel();
      if (!controlsVisible) {
        setState(() => controlsVisible = true);
      }
    } else {
      startControlsTimer();
    }
  }

  void toggleControls() {

    setState(() {
      controlsVisible = !controlsVisible;
    });

    if (controlsVisible) {
      startControlsTimer();
    } else {
      controlsTimer?.cancel();
    }

  }

  // Fires whenever PlayerManager.instance.isLocked changes — from either
  // the lock button in the top bar or the unlock button in
  // PlayerLockOverlay. Keeping this centralized (rather than threading
  // callbacks through the top bar) matches how the rest of the screen
  // reacts to PlayerManager state.
  void _handleLockChanged() {
    if (!mounted) return;

    // Locking/unlocking is a deliberate tap on the lock button itself,
    // which never reaches PlayerGestureLayer's own handlers below — count
    // it as activity here instead.
    PlayerManager.instance.registerActivity();

    if (PlayerManager.instance.isLocked.value) {
      controlsTimer?.cancel();

      setState(() {
        controlsVisible = false;
        showLockButton = true;
      });

      startLockButtonTimer();
    } else {
      lockButtonTimer?.cancel();

      setState(() {
        showLockButton = false;
        controlsVisible = true;
      });

      // CASTING FIX (unlock leaves the screen with no controls and no
      // way to bring them back): this used to call startControlsTimer()
      // unconditionally, which arms a plain 4-second timer that hides
      // the chrome again regardless of what's on screen. That's correct
      // for local playback (tapping the backdrop toggles it right back),
      // but while casting, handleScreenTap() deliberately returns early
      // for any tap and never calls toggleControls() — see its own
      // "Casting Phase 8" doc comment — because CastingActivePanel/the
      // cast transport controls are meant to just stay visible, with no
      // tap-to-reveal at all. So the timer fired anyway, hid everything
      // 4 seconds after unlocking, and left nothing on screen able to
      // bring it back — reading as "unlocking hides all the controls,
      // including the lock button." Every other place this screen
      // forces controls visible during a cast session
      // (_handleCastVisibilityStateChanged) already skips arming this
      // same timer for exactly that reason; unlocking now matches.
      if (!_isCastingVideoActive()) {
        startControlsTimer();
      }
    }
  }

  // Whether this screen should be treated as "showing a cast" for the
  // purposes of forcing the control chrome visible — true for either a
  // genuine local->TV handoff, or a direct "Cast to" session that never
  // touched local playback (see the doc comment on the
  // `activeSession.addListener` call in initState for why both need
  // covering, not just the handoff flag).
  bool _isCastingVideoActive() {
    if (PlaybackCoordinator.instance.isHandoffActive.value) return true;

    final session = CastManager.instance.activeSession.value;
    final item = session?.currentItem.value;
    return (session?.isConnected ?? false) && item != null && !item.audioOnly;
  }

  // Fires whenever PlaybackCoordinator.instance.isHandoffActive changes,
  // or whenever the active cast session's own connection/currentItem
  // changes (see the two listener registrations in initState) — either
  // can flip whether this screen is currently "showing a cast" per
  // [_isCastingVideoActive].
  void _handleCastVisibilityStateChanged() {
    if (!mounted) return;

    final active = _isCastingVideoActive();

    controlsTimer?.cancel();

    setState(() {
      controlsVisible = true;
    });

    if (!active) {
      startControlsTimer();
    }
  }

  // Keeps this screen listening to whichever CastSession is currently
  // active so a direct "Cast to" — which sets `currentItem` sometime
  // *after* the session itself connects, not atomically with it — is
  // still caught (see CastToButton: device picker connects first, the
  // actual item loads a moment later). Re-runs the same force-visible
  // check on every relevant change either notifier could produce.
  void _handleCastSessionChanged() {
    final session = CastManager.instance.activeSession.value;

    if (!identical(session, _trackedCastSession)) {
      _trackedCastSession?.currentItem
          .removeListener(_handleCastVisibilityStateChanged);
      _trackedCastSession = session;
      _trackedCastSession?.currentItem
          .addListener(_handleCastVisibilityStateChanged);
    }

    _handleCastVisibilityStateChanged();
  }

  // Fires when PlayerManager.instance.playbackFinished flips true — pops
  // this screen, same as tapping back. dispose() below takes care of the
  // actual PlayerManager.stop() call, exactly like every other way of
  // leaving this screen.
  void _handlePlaybackFinished() {
    if (!mounted) return;
    if (!PlayerManager.instance.playbackFinished.value) return;

    // maybePop: goes through PlayerExitScope, which turns the phone to
    // portrait before the route is popped.
    Navigator.of(context).maybePop();
  }

  /// Runs the moment the screen starts closing (see PlayerExitScope): no
  /// sound while the phone turns, and the sensor listener stops so it can't
  /// fight the rotation.
  void _prepareToLeave() {
    OrientationService.stop();
    if (!_isCastingVideoActive()) {
      try {
        unawaited(PlayerManager.instance.player.pause());
      } catch (_) {}
    }
  }

  void startLockButtonTimer() {
    lockButtonTimer?.cancel();

    lockButtonTimer = Timer(
      const Duration(seconds: 3),
      () {
        if (!mounted) return;
        setState(() => showLockButton = false);
      },
    );
  }

  // Routes a screen tap depending on whether controls are locked: while
  // locked, a tap only reveals/hides the small unlock button rather than
  // the full control bars.
  void handleScreenTap() {
    final manager = PlayerManager.instance;

    // Any tap on the screen is real activity, whether or not it goes on
    // to do anything else below — resets the "Still watching?" idle
    // clock and dismisses the prompt if it's already showing.
    manager.registerActivity();

    // While the INITIAL loading screen is up, a tap should do nothing at
    // all — the control bars have no business responding to touches (or
    // toggling on, only to sit behind that overlay) until real playback is
    // actually on screen. See the ValueListenableBuilder around
    // PlayerControlsLayer below, which enforces the same thing on the
    // visual side.
    //
    // Buffering is deliberately NOT part of this check: once playback has
    // started, a stall must leave the player fully usable (show/hide the
    // controls, pause, seek, back out), exactly like any other player.
    if (manager.loading.value) {
      return;
    }

    // CASTING FIX (lock button unreachable once tapped): the lock check
    // below now runs *before* the casting early-return underneath it —
    // see that branch's own doc comment for why. In short: locking
    // hides `PlayerControlsLayer` entirely (see the
    // `!manager.isLocked.value` clause its `visible` is gated on back
    // in build()), and `CastingActivePanel` lives inside that same
    // layer — so while locked, there is no panel left on screen to
    // "intercept" a tap the way the casting branch's comment assumes.
    // With the old ordering, every tap while casting returned here
    // immediately regardless of lock state, so the small unlock button
    // (PlayerLockOverlay) — shown only for a few seconds after locking,
    // or after a tap toggles it back on — could never be brought back
    // once its own timer hid it again: locking, waiting out the timer,
    // then tapping the screen to unlock did nothing at all, leaving no
    // way to unlock short of leaving the screen. Checking lock state
    // first fixes that without changing non-locked casting behavior at
    // all — a tap while casting and unlocked still falls through to
    // the branch below exactly as before.
    if (manager.isLocked.value) {
      setState(() => showLockButton = !showLockButton);

      if (showLockButton) {
        startLockButtonTimer();
      } else {
        lockButtonTimer?.cancel();
      }

      return;
    }

    // Casting Phase 8: controls are forced visible for the duration of a
    // handoff (see _handleCastHandoffChanged) — CastingActivePanel
    // occupies the full controls area and handles its own taps, so a
    // tap reaching this far (in principle it shouldn't, since the panel
    // sits on top and intercepts pointer events first) should never be
    // able to toggle the chrome away underneath it.
    //
    // CASTING FIX ("Casting to X" / cast button intermittently missing):
    // this used to check `isHandoffActive` only, which is exclusively
    // true for a handoff that *started with local playback*. A direct
    // "Cast to" from a details screen (CastToButton) — which opens this
    // screen straight into CastingBackdrop with a live cast session and
    // never sets `isHandoffActive` at all, see _isCastingVideoActive's
    // own doc comment — fell straight through to toggleControls() below
    // on any tap on the backdrop. That could flip the top bar (title +
    // CastButton) invisible, and since this branch never re-forces it
    // back and no auto-hide timer was ever started to begin with, it
    // just stayed hidden until the cast session's own state changed
    // again — reading as "sometimes doesn't appear" depending entirely
    // on whether the session was a handoff or a direct cast-to.
    // `_isCastingVideoActive()` covers both cases the same way
    // `_handleCastVisibilityStateChanged` already does, so this now
    // matches that.
    if (_isCastingVideoActive()) {
      return;
    }

    toggleControls();
  }

  void startControlsTimer() {

    controlsTimer?.cancel();

    controlsTimer = Timer(
      const Duration(seconds: 4),
          () {

        if (!mounted) return;

        // Never auto-hide out from under an active seek-bar drag.
        if (PlayerManager.instance.isSeeking.value) return;

        setState(() {
          controlsVisible = false;
        });

      },
    );

  }

  // GESTURE CASTING FIX: double-tap rewind/forward and the horizontal
  // drag-to-seek gesture below all used to call `player.seek()` directly
  // on the local mpv player unconditionally — harmless-looking while
  // casting since CastingBackdrop is what's actually on screen at that
  // point, but the seek itself silently did nothing to the TV (mpv is
  // paused/frozen for the duration of a handoff, so seeking it doesn't
  // even move the paused frame). Reusing the same `_isCastingVideoActive()`
  // check this screen already has (for forcing the control chrome
  // visible during a handoff) routes these three gestures through
  // `CastManager.instance.seek()` instead whenever a video is actively
  // being cast, exactly like every other cast-aware seek control
  // (CastSeekBar, CenterControls' ±10 buttons via CastTransportControls)
  // already does.
  Future<void> rewind10() async {
    if (_isCastingVideoActive()) {
      final session = CastManager.instance.activeSession.value;
      if (session == null || !session.capability.seek) return;

      final target = session.position.value - const Duration(seconds: 10);

      await CastManager.instance.seek(
        target.isNegative ? Duration.zero : target,
      );
    } else {
      // Via PlayerManager: a Data Saver / Default transcode can't be
      // seeked in place (see PlayerManager.seekTo).
      await PlayerManager.instance.seekBy(const Duration(seconds: -10));
    }

    setState(() => showSeekLeft = true);

    seekLeftHideTimer?.cancel();
    seekLeftHideTimer = Timer(
      const Duration(milliseconds: 700),
          () {
        if (mounted) {
          setState(() => showSeekLeft = false);
        }
      },
    );
  }

  Future<void> forward10() async {
    if (_isCastingVideoActive()) {
      final session = CastManager.instance.activeSession.value;
      if (session == null || !session.capability.seek) return;

      final duration = session.duration.value;
      final target = session.position.value + const Duration(seconds: 10);

      await CastManager.instance.seek(
        (duration > Duration.zero && target > duration) ? duration : target,
      );
    } else {
      await PlayerManager.instance.seekBy(const Duration(seconds: 10));
    }

    setState(() => showSeekRight = true);

    seekRightHideTimer?.cancel();
    seekRightHideTimer = Timer(
      const Duration(milliseconds: 700),
          () {
        if (mounted) {
          setState(() => showSeekRight = false);
        }
      },
    );
  }

  Future<void> updateBrightness(double delta) async {

    brightnessValue += delta;

    brightnessValue =
        brightnessValue.clamp(0.0, 1.0);

    await ScreenBrightness()
        .setApplicationScreenBrightness(
        brightnessValue);

    setState(() {
      showBrightness = true;
    });

    // Cancel any previously scheduled hide before starting a new one —
    // otherwise a fast run of drag-update events during one continuous
    // swipe would each schedule their own hide, and the earliest of
    // those could fire while the user was still actively adjusting
    // brightness, making the indicator flicker off mid-gesture.
    brightnessHideTimer?.cancel();
    brightnessHideTimer = Timer(
      const Duration(milliseconds: 1500),
          () {

        if (!mounted) return;

        setState(() {
          showBrightness = false;
        });

      },
    );

  }

  // Called when a vertical swipe begins. Decides whether THIS swipe is
  // allowed to continue past 100% (only if it starts at 100%), and
  // quietly re-syncs with the device volume in case it was changed
  // outside this screen (hardware volume buttons) since the last swipe.
  void _beginVolumeGesture() {
    if (PlayerManager.instance.isLocked.value) return;

    if (_isCastingVideoActive()) {
      _beginCastVolumeGesture();
      return;
    }

    _volumeUpdatedInGesture = false;
    _gestureAllowsBoost = _volumeLevel >= 0.999;

    VolumeController.instance.getVolume().then((system) {
      if (!mounted || _volumeUpdatedInGesture) return;

      final expected = _volumeLevel > 1.0 ? 1.0 : _volumeLevel;
      if ((system - expected).abs() <= 0.02) return;

      volumeValue = system;
      _volumeLevel = system;
      _lastSentSystemVolume = system;
      _gestureAllowsBoost = system >= 0.999;

      // Device volume dropped below max while boosted: the boost no
      // longer makes sense on top of it.
      if (system < 0.999 && PlayerManager.instance.volumeGain > 100) {
        unawaited(PlayerManager.instance.setVolumeGain(100));
      }
    }).catchError((_) {});
  }

  // Casting: start from the TV's current volume.
  void _beginCastVolumeGesture() {
    final session = CastManager.instance.activeSession.value;
    if (session == null) return;

    _castVolumeTouchedInGesture = false;
    _castVolumeLevel = session.volume.value;

    // Google Cast only reports the TV's volume on request.
    CastManager.instance.syncVolume().then((_) {
      if (!mounted || _castVolumeTouchedInGesture) return;
      _castVolumeLevel = session.volume.value;
    }).catchError((_) {});
  }

  void _showBoostHint() {
    if (!mounted) return;

    if (!showBoostHint) {
      setState(() => showBoostHint = true);
    }

    _boostHintTimer?.cancel();
    _boostHintTimer = Timer(
      const Duration(milliseconds: 2000),
      () {
        if (!mounted) return;
        setState(() => showBoostHint = false);
      },
    );
  }

  Future<void> updateVolume(double delta) async {
    // Casting: boost never applies — behaves exactly as before
    // (plain device volume, 0–100%).
    if (_isCastingVideoActive()) {
      _updateCastVolume(delta);
      return;
    }

    _volumeUpdatedInGesture = true;

    var next = (_volumeLevel + delta).clamp(0.0, _maxVolumeLevel).toDouble();

    if (next > 1.0 && !_gestureAllowsBoost) {
      // Hold at 100% and tell the user to slide again, like VLC.
      next = 1.0;
      if (delta > 0) _showBoostHint();
    }

    _volumeLevel = next;
    volumeValue = next > 1.0 ? 1.0 : next;

    final gain = next > 1.0 ? 100 + (next - 1.0) * 100 : 100.0;

    if (!mounted) return;

    setState(() {
      showVolume = true;
    });

    if ((volumeValue - _lastSentSystemVolume).abs() > 0.0005) {
      _lastSentSystemVolume = volumeValue;
      // Our own indicator is the feedback — don't also pop up the
      // system volume panel on top of it.
      VolumeController.instance.showSystemUI = false;
      unawaited(VolumeController.instance.setVolume(volumeValue));
    }

    if ((gain - PlayerManager.instance.volumeGain).abs() > 0.5 ||
        (gain == 100.0 && PlayerManager.instance.volumeGain != 100)) {
      unawaited(PlayerManager.instance.setVolumeGain(gain));
    }

    volumeHideTimer?.cancel();
    volumeHideTimer = Timer(
      const Duration(milliseconds: 1500),
          () {

        if (!mounted) return;

        setState(() {
          showVolume = false;
        });

      },
    );
  }

  // Casting: adjusts the TV's volume through the active cast session
  // (Google Cast, Jellyfin Remote/DLNA, Nemesis Native alike), never the
  // phone's own volume.
  void _updateCastVolume(double delta) {
    final session = CastManager.instance.activeSession.value;
    if (session == null || !session.capability.volume) return;

    _castVolumeTouchedInGesture = true;
    _castVolumeLevel = (_castVolumeLevel + delta).clamp(0.0, 1.0).toDouble();
    volumeValue = _castVolumeLevel;

    _castVolumeSender.send(_castVolumeLevel);

    if (!mounted) return;

    setState(() {
      showVolume = true;
    });

    volumeHideTimer?.cancel();
    volumeHideTimer = Timer(
      const Duration(milliseconds: 1500),
          () {

        if (!mounted) return;

        setState(() {
          showVolume = false;
        });

      },
    );
  }

  @override
  void dispose() {
    PlayerScreenRegistry.unregister(_registeredRoute);

    OrientationService.stop();

    PiPHelper.setAutoEnterEnabled(false);

    PlayerManager.instance.isSeeking.removeListener(_handleSeekingChanged);

    PlayerManager.instance.isLocked.removeListener(_handleLockChanged);

    PlaybackCoordinator.instance.isHandoffActive
        .removeListener(_handleCastVisibilityStateChanged);

    CastManager.instance.activeSession
        .removeListener(_handleCastSessionChanged);
    _trackedCastSession?.currentItem
        .removeListener(_handleCastVisibilityStateChanged);

    PlayerManager.instance.playbackFinished.removeListener(_handlePlaybackFinished);

    // Cancels the "Still watching?" idle clock and hides the prompt so it
    // can never fire into an empty screen after this one is gone.
    PlayerManager.instance.stopActivityMonitor();

    // Whether to snap back to portrait or stay in landscape depends on
    // how playback was left, not on how it started:
    //  - Still fullscreen (played fullscreen and never rotated/toggled
    //    back to windowed) — leave the device in landscape. Only the
    //    orientation *lock* itself is released (back to free rotation,
    //    same as the rest of the app), not the current physical
    //    orientation, so the screen underneath opens in landscape too.
    //  - Already out of fullscreen (rotated back to portrait, or the
    //    fullscreen toggle was switched off manually) — always return
    //    to portrait, regardless of what orientation playback started
    //    in. This is the one case that should behave the same no
    //    matter how landscape it was a moment ago.
    //
    // PlayerOrientation applies exactly these rules, and also: does nothing
    // when another player screen (the embed player) is open or about to
    // open, and does nothing when PlayerExitScope already settled the
    // orientation before the pop (so the screen underneath was never drawn
    // in the wrong orientation).
    PlayerOrientation.screenClosed(
      fullscreen: PlayerManager.instance.isFullscreen.value,
    );

    controlsTimer?.cancel();
    lockButtonTimer?.cancel();
    brightnessHideTimer?.cancel();
    volumeHideTimer?.cancel();
    _boostHintTimer?.cancel();
    _castVolumeSender.dispose();

    // The boost belongs to this screen only: back to 100% so music and
    // the next video never start boosted, and restore the system volume
    // panel behaviour changed while swiping.
    unawaited(PlayerManager.instance.resetVolumeGain());
    VolumeController.instance.showSystemUI = true;

    seekLeftHideTimer?.cancel();
    seekRightHideTimer?.cancel();

    // Stop playback whenever this screen goes away, no matter how it
    // happens (back button, system back gesture/button, swipe-to-pop) —
    // UNLESS a video is actively being cast. Local mpv is already
    // paused for the duration of a handoff (see PlaybackCoordinator
    // ._handleSessionConnected) and the video is genuinely still
    // playing on the TV, not stuck running invisibly in the background
    // the way the comment below originally warned about — so stopping
    // it here would only tear down currentItemNotifier/PlaybackQueue
    // (and the rest of local playback state) out from under a session
    // that's still live. MiniPlayer's own casting-aware video bar needs
    // that state intact to keep showing/controlling what's on the TV
    // after backing out of this screen, and to be able to reopen
    // straight back into this same session on tap instead of a blank
    // reload. PlaybackCoordinator's own REMOTE -> LOCAL resume path
    // (_resumeLocally) already handles putting local mpv back the way
    // stop() otherwise would, once the cast session itself actually
    // ends.
    //
    // CASTING FIX (backing out drops the queue/mini player until you
    // tap Play again): this used to only check `isHandoffActive`,
    // which is exclusively true for a session that *began* as local
    // playback. A session that started as a direct "Cast to" from a
    // details screen, or one that was switched to a different
    // movie/episode via a Play tap elsewhere while already casting
    // (PlaybackService._castVideo — never itself a "handoff"), left
    // `isHandoffActive` false the entire time despite a video being
    // very much still actively cast. Backing out of this screen for
    // either of those called `stop()` anyway, wiping
    // `PlaybackQueue`/`currentItemNotifier` — the exact state the
    // episode-list toggle, the video-casting mini player's backdrop
    // fallback, and a subsequent redirect all depend on — out from
    // under a session that never actually stopped anywhere. Checking
    // `_isCastingVideoActive()` instead (already used elsewhere in this
    // screen for exactly this "handoff OR direct/redirected cast"
    // distinction) covers all three ways a video cast session can be
    // live, not just the one that happens to have touched local
    // playback first.
    //
    // OPEN WITH FIX: also skipped when an audio track has taken over
    // playback while this screen was still on its way out (an Open With
    // audio file replaces this route via PlayerScreenRegistry). This
    // dispose runs after that replacement's transition, by which point the
    // new song is already the current item — stop() here would wipe it and
    // the new player screen would end up empty.
    final currentItem = PlayerManager.instance.currentItem;
    final replacedByAudio = currentItem != null && currentItem.audioOnly;

    if (!_isCastingVideoActive() && !replacedByAudio) {
      PlayerManager.instance.stop();
    }

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {

    final manager = PlayerManager.instance;

    // PipWidget (from simple_pip_mode) handles swapping the UI itself
    // once the OS actually enters/exits PiP — none of our own touch
    // controls are usable at that tiny size anyway, and pipLayout below
    // gets real play/pause/seek buttons drawn by the OS on the PiP
    // window itself, wired to _handlePipAction.
    return ValueListenableBuilder<MediaItem?>(
      valueListenable: manager.currentItemNotifier,
      builder: (_, item, __) {
        return PlayerExitScope(
          isFullscreen: () => PlayerManager.instance.isFullscreen.value,
          onExitStart: _prepareToLeave,
          child: PipWidget(
          // Rewind/forward-10 buttons for both VOD and live — live TV
          // already supports seeking backward/forward within its rolling
          // buffer via the in-app seek bar (see PlayerSeekBar), so the
          // same two actions work here too. mediaLive's next/previous
          // buttons skipped to the next/previous channel, which doesn't
          // map to anything the PiP window itself can show progress
          // for, and read as regular track-skip controls at a glance —
          // rewind/forward are the more useful, less ambiguous pair for
          // a tiny floating window either way.
          pipLayout: PipActionsLayout.mediaWithSeek10,
          onPipAction: _handlePipAction,
          pipChild: Scaffold(
            backgroundColor: Colors.black,
            body: ValueListenableBuilder<BoxFit>(
              valueListenable: manager.videoFit,
              builder: (_, fit, __) {
                return VideoSurface(
                  controller: controller,
                  manager: manager,
                  fit: fit,
                  // Subtitles now scale with the visible video height
                  // (CustomSubtitleOverlay), so they no longer dominate
                  // a small PiP window and grow as it is enlarged.
                  showSubtitles: true,
                );
              },
            ),
          ),
          child: _buildFullPlayer(context, manager),
          ),
        );
      },
    );
  }

  /// Handles the media control buttons the OS draws directly on the
  /// PiP window chrome (play/pause/seek, or next/previous channel for
  /// live content) — there's no touch access to our own controls at
  /// that size, so these are the only way to control playback while
  /// the app is shrunk into PiP.
  void _handlePipAction(PipAction action) {
    final manager = PlayerManager.instance;

    switch (action) {
      case PipAction.play:
        manager.player.play();
        break;
      case PipAction.pause:
        manager.player.pause();
        break;
      case PipAction.rewind:
        rewind10();
        break;
      case PipAction.forward:
        forward10();
        break;
      case PipAction.next:
        if (manager.currentItem?.live ?? false) {
          manager.playNextChannel();
        } else {
          manager.playNext();
        }
        break;
      case PipAction.previous:
        if (manager.currentItem?.live ?? false) {
          manager.playPreviousChannel();
        } else {
          manager.playPrevious();
        }
        break;
      default:
        break;
    }
  }

  Widget _buildFullPlayer(BuildContext context, PlayerManager manager) {
    // Bottom exclusion for the gesture layer: while controls are shown,
    // sized to the actual measured seek-bar/bottom-bar height (plus a
    // little slack) so that whole area sits outside the swipe layer's
    // hit-test rect entirely; otherwise it's just the small edge strip
    // reserved for the OS's own bottom gesture.
    final bottomExclusion = controlsVisible
        ? (manager.bottomBarHeight.value + 12)
            .clamp(_edgeGestureExclusion, double.infinity)
        : _edgeGestureExclusion;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [

        // Always full-screen regardless of the gesture layer's
        // top/bottom exclusion insets — those only shrink where
        // gestures are recognised, never the picture itself.
        //
        // Casting Phase 14: once PlaybackCoordinator hands this screen's
        // playback off to a TV, the local player is paused and this
        // surface would otherwise just show that last, frozen frame
        // sitting behind the controls for as long as the cast session
        // lasts. Swapping in CastingBackdrop instead — the same
        // movie/show backdrop (or, for a live channel, the same
        // stretched channel image) the detail screens already use —
        // means the screen still looks alive and on-brand rather than a
        // static paused frame, while the real video keeps playing on
        // the TV untouched.
        Positioned.fill(
          child: ValueListenableBuilder<CastSession?>(
            valueListenable: CastManager.instance.activeSession,
            builder: (_, castSession, __) {
              return ValueListenableBuilder<bool>(
                valueListenable: PlaybackCoordinator.instance.isHandoffActive,
                builder: (_, handoffActive, __) {
                  // MiniPlayer follow-up: a "Cast to" started straight
                  // from a details screen (CastToButton) never touches
                  // local playback at all, so `isHandoffActive` alone —
                  // true only once a handoff that began with local
                  // playback — misses that case entirely. Reopening
                  // this screen (from the video-casting mini player,
                  // in particular) while one of those sessions is live
                  // used to fall through to the VideoSurface branch
                  // below with nothing actually loaded in local mpv.
                  // Any connected session casting a non-audio item
                  // shows the same casting backdrop regardless of
                  // which of the two ways it started.
                  final castItem = castSession?.currentItem.value;
                  final castingVideo = (castSession?.isConnected ?? false) &&
                      castItem != null &&
                      !castItem.audioOnly;

                  if (handoffActive || castingVideo) {
                    return ValueListenableBuilder<MediaItem?>(
                      valueListenable: manager.currentItemNotifier,
                      builder: (_, item, __) => CastingBackdrop(
                        // CASTING FIX (switching titles while casting
                        // looks stale until dismiss+reopen): this used
                        // to be `item ?? castItem` — local state took
                        // priority over the session's own, live
                        // `currentItem` whenever local had anything at
                        // all, even a stale snapshot from before the
                        // session moved on to something else (a
                        // different movie/episode picked from Home/a
                        // detail screen/Continue Watching while this
                        // screen was already open elsewhere, or the
                        // receiver advancing its own queue on its own).
                        // The cast session's `currentItem` is the
                        // actual source of truth for what's playing
                        // once a video is being cast — same principle
                        // PlayerTopBar's title already follows
                        // correctly — so it needs to win whenever it's
                        // available, falling back to local `item` only
                        // for the local-playback branch this same
                        // builder still has to cover (a handoff whose
                        // session hasn't finished connecting yet).
                        item: castItem ?? item,
                      ),
                    );
                  }

                  return ValueListenableBuilder<BoxFit>(
                    valueListenable: manager.videoFit,
                    builder: (_, fit, __) {
                      return VideoSurface(
                        controller: controller,
                        manager: manager,
                        fit: fit,
                      );
                    },
                  );
                },
              );
            },
          ),
        ),

        PlayerGestureLayer(
        topExclusion: _edgeGestureExclusion,
        bottomExclusion: bottomExclusion,

        onTap: handleScreenTap,

        onDoubleTapDown: (details) {
          manager.registerActivity();

          if (manager.isLocked.value) return;

          final width = MediaQuery.sizeOf(context).width;

          if (details.localPosition.dx < width / 2) {
            rewind10();
          } else {
            forward10();
          }
        },

        onHorizontalDragStart: (_) {
          manager.registerActivity();

          if (manager.isLocked.value) return;

          isHorizontalSeeking = true;

          // GESTURE CASTING FIX: seed the drag from the cast session's
          // own reported position/duration while a video is actively
          // being cast, instead of local mpv's (paused, and often
          // sitting on an entirely different item's position once the
          // TV has moved on to something else — e.g. after an episode
          // change made via the episode panel or the TV's own remote).
          final castSession = _isCastingVideoActive()
              ? CastManager.instance.activeSession.value
              : null;

          horizontalSeekPosition = castSession != null
              ? castSession.position.value
              : manager.absolutePosition;

          horizontalSeekStartPosition =
              horizontalSeekPosition;
        },

        onHorizontalDragUpdate: (details) {
          if (manager.isLocked.value) return;

          final delta =
          (details.delta.dx * 120).round();

          horizontalSeekPosition +=
              Duration(milliseconds: delta);

          if (horizontalSeekPosition.isNegative) {
            horizontalSeekPosition = Duration.zero;
          }

          final castSession = _isCastingVideoActive()
              ? CastManager.instance.activeSession.value
              : null;

          final duration = castSession != null
              ? castSession.duration.value
              : (manager.duration.value > Duration.zero
                  ? manager.duration.value
                  : manager.player.state.duration);

          if (horizontalSeekPosition > duration) {
            horizontalSeekPosition = duration;
          }

          setState(() {});
        },

        onHorizontalDragEnd: (_) async {
          if (manager.isLocked.value) return;

          final castSession = _isCastingVideoActive()
              ? CastManager.instance.activeSession.value
              : null;

          if (castSession != null) {
            if (castSession.capability.seek) {
              await CastManager.instance.seek(horizontalSeekPosition);
            }
          } else {
            await manager.seekTo(horizontalSeekPosition);
          }

          setState(() {
            isHorizontalSeeking = false;
          });
        },

        onVerticalDragStart: (details) {
          if (details.localPosition.dx >= MediaQuery.sizeOf(context).width / 2) {
            _beginVolumeGesture();
          }
        },

        onVerticalDragUpdate: (details) {
          manager.registerActivity();

          if (manager.isLocked.value) return;

          final width =
              MediaQuery.sizeOf(context).width;

          final dx = details.localPosition.dx;

          final delta =
              -details.delta.dy / 400;

          if (dx < width / 2) {
            updateBrightness(delta);
          } else {
            updateVolume(delta);
          }
        },
      ),

      ValueListenableBuilder<bool>(
        valueListenable: manager.playing,
        builder: (_, playing, __) {
          return PlayPauseAnimation(
            visible: showPlayPause,
            playing: playing,
          );
        },
      ),

          SeekIndicator(
            seconds: 10,
            left: true,
            visible: showSeekLeft,
          ),

          SeekIndicator(
            seconds: 10,
            left: false,
            visible: showSeekRight,
          ),

          // The "slide up again to go beyond 100%" hint is local-only
          // (casting has no boost). The volume and brightness side
          // indicators themselves are painted further down, above the
          // controls — see the comment after PlayerOverlayLayer.
          VolumeBoostHint(
            visible: showBoostHint && !_isCastingVideoActive(),
          ),

          HorizontalSeekOverlay(
            visible: isHorizontalSeeking,
            position: horizontalSeekPosition,
            forward: horizontalSeekPosition >=
                horizontalSeekStartPosition,
          ),

          // Buffering logo (a stall AFTER playback started). Stacked
          // beneath the controls and blind to touches, so the controls and
          // gestures keep working while it pulses; it fades back while the
          // controls are showing so the two don't fight for the centre.
          BufferingOverlay(
            controlsVisible: controlsVisible && !manager.isLocked.value,
          ),

          // The INITIAL loading overlay (PlayerOverlayLayer, stacked right
          // below) sits centered on screen — the same spot CenterControls
          // occupies — and isn't fully opaque, so without this check the
          // control bars could still show (or partially show through)
          // underneath it whenever `controlsVisible` happened to be true,
          // including right as a tap set it so. Gating visibility on
          // `loading` directly, rather than only guarding the tap handler
          // above, keeps them hidden regardless of how `controlsVisible`
          // got set. Buffering is NOT gated: controls stay usable then.
          ValueListenableBuilder<bool>(
            valueListenable: manager.loading,
            builder: (_, loading, __) {
              return PlayerControlsLayer(
                visible: controlsVisible &&
                    !manager.isLocked.value &&
                    !loading,
              );
            },
          ),

      const PlayerOverlayLayer(),

      // Volume (left edge) and brightness (right edge) side indicators —
      // the same VLC-style design for local playback AND casting, so the
      // two screens match (the centre popups are gone). Casting has no
      // volume boost: it shows the TV's 0–100% on the full bar, with no
      // gold boost range. These used to sit earlier in this Stack, i.e.
      // BENEATH PlayerControlsLayer, so while the controls were showing
      // they could be painted over; after the controls/overlay layer they
      // sit on top instead. Both ignore pointers, so they never block
      // taps on the controls under them.
      VolumeBoostIndicator(
        visible: showVolume,
        level: _isCastingVideoActive() ? volumeValue : _volumeLevel,
        allowBoost: !_isCastingVideoActive(),
      ),

      BrightnessIndicator(
        visible: showBrightness,
        level: brightnessValue,
      ),

      const EpisodeListPanel(),

      const LiveChannelListPanel(),

      // Surfaces playback failures (e.g. the stream failing to open)
      // right on this screen instead of a SnackBar back on whichever
      // screen the user tapped "Play" from — now that every "Play"
      // tap pushes this screen immediately rather than waiting on the
      // network call to succeed first, this is the only place left
      // that reliably knows something went wrong.
      ValueListenableBuilder<String?>(
        valueListenable: manager.lastError,
        builder: (_, error, __) {
          if (error == null) return const SizedBox.shrink();

          return _PlaybackErrorOverlay(
            message: error,
            onBack: () {
              manager.lastError.value = null;
              Navigator.of(context).maybePop();
            },
          );
        },
      ),

          ValueListenableBuilder<bool>(
            valueListenable: manager.isLocked,
            builder: (_, locked, __) {
              if (!locked) return const SizedBox.shrink();

              return PlayerLockOverlay(
                visible: showLockButton,
                onUnlock: () {
                  manager.isLocked.value = false;
                },
              );
            },
          ),
      ],
          ),
    );
  }
}

class _PlaybackErrorOverlay extends StatelessWidget {
  const _PlaybackErrorOverlay({
    required this.message,
    required this.onBack,
  });

  final String message;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black,
      alignment: Alignment.center,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.error_outline,
              color: Colors.white70,
              size: 42,
            ),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 16),
            ),
            const SizedBox(height: 24),
            OutlinedButton(
              onPressed: onBack,
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                side: const BorderSide(color: Colors.white54),
              ),
              child: const Text("Go Back"),
            ),
          ],
        ),
      ),
    );
  }
}