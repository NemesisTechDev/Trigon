import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../player/models/media_item.dart';
import 'cast_capability.dart';
import 'cast_device.dart';
import 'cast_states.dart';

/// A live connection to one [CastDevice] over one specific transport.
///
/// This is intentionally a plain state holder — it has no behavior of its
/// own (no play()/pause()/seek() methods). Commands always go through
/// CastManager, which forwards them to the owning CastTransport
/// implementation along with this session; that keeps every piece of
/// actual protocol logic inside the transports (Phases 4-6) rather than
/// leaking into a model class every UI widget also holds a reference to.
///
/// Every piece of mutable state is a ValueNotifier, matching the pattern
/// PlayerManager and NetworkQualityService already use app-wide — widgets
/// (PlayerTopBar, MiniPlayer, a future connected-session panel) consume
/// these directly via ValueListenableBuilder rather than the session
/// itself being a ChangeNotifier the whole object rebuilds on.
class CastSession {
  final CastDevice device;
  final CastTransportKind transportKind;

  final ValueNotifier<CastConnectionState> connectionState;

  /// Raw transport-level playback state. Writes go through
  /// [_GuardedPlaybackState], which drops a stale, contradicting
  /// play/pause/buffering push for a short window right after the person
  /// taps play/pause — see [reportOptimisticPlaybackState]. UI that draws a
  /// play/pause icon should listen to [showsPlaying] instead of comparing
  /// this against `.playing` itself.
  final ValueNotifier<CastPlaybackState> playbackState;

  /// PLAY/PAUSE FLICKER FIX. What a play/pause *icon* should show: `true` =
  /// pause icon (playing), `false` = play icon. Unlike a raw
  /// `playbackState == playing` comparison it does not flip on the
  /// transient `buffering`/`loading` blips receivers emit around a
  /// play/pause/seek (those keep whatever was showing), and it debounces
  /// the brief `idle`/`stopped`/`ended` dip between two tracks. An explicit
  /// `paused` (or `error`) applies immediately. [CastManager.togglePlayPause]
  /// reads this too, so what is drawn and what a tap does always agree.
  final ValueNotifier<bool> showsPlaying = ValueNotifier(false);
  Timer? _showsPlayingDebounce;

  /// How long a transient idle-ish state must persist before the icon
  /// follows it (covers the idle gap while the next track loads).
  static const _idleDisplayDebounce = Duration(milliseconds: 700);

  /// PLAY/PAUSE FLICKER FIX. The state a tap just asked for, and until when
  /// a contradicting transport push is treated as stale. Cleared the moment
  /// the transport confirms (reports the same state), on any other state
  /// (idle/error/...), or when the window runs out. See
  /// [reportOptimisticPlaybackState] and [_shouldDropIncomingState].
  CastPlaybackState? _optimisticTarget;
  DateTime? _optimisticUntil;

  /// Longer than [_playbackCommandSettleWindow] on purpose: a Jellyfin
  /// Remote receiver only reports its state to the server every few
  /// seconds and the app polls the server every 3s on top of that, so a
  /// stale pre-tap sample can still arrive several seconds after the tap.
  static const _optimisticStateWindow = Duration(seconds: 6);

  final ValueNotifier<MediaItem?> currentItem;

  /// SEEK-RESTART FIX (root cause). Set by a transport that can tell
  /// *why* [playbackState] just landed on `idle`/`stopped`/`ended` — see
  /// [CastIdleReason]'s own doc comment for the full reasoning. `null`
  /// means "no transport-reported reason available" (Jellyfin
  /// Remote/Nemesis Native, or a Google Cast session that hasn't gone
  /// idle since it was last actively playing/paused/buffering/loading);
  /// [PlaybackCoordinator] treats `null` as "fall back to the old
  /// isSeekPending timing guard" rather than as any particular reason.
  final ValueNotifier<CastIdleReason?> idleReason = ValueNotifier(null);

  /// SMOOTH-SEEK-BAR FIX. [position] used to be a raw passthrough that
  /// each transport wrote to directly on its own reporting cadence —
  /// JellyfinRemoteTransport's 3s poll, Google Cast's ~1s
  /// `playerPositionStream`, Nemesis Native's receiver-pushed state
  /// messages. Every one of those is far coarser than mpv's own
  /// continuous local position stream, so a seek bar/duration label bound
  /// directly to this notifier visibly hopped forward every update
  /// instead of gliding the way local playback does.
  ///
  /// [position] is now locally interpolated: transports report an
  /// authoritative sample via [reportPosition] instead of writing here
  /// directly, and this notifier is advanced by an internal ticker
  /// between samples (see [_estimatePositionAt]/[_ensureTicker]) so it
  /// reads exactly like local playback's continuously-advancing position
  /// regardless of which transport is connected. No UI widget needed to
  /// change to pick this up — CastSeekBar/CastTransportControls/etc.
  /// already just listen to this same notifier.
  ///
  /// [duration] stays a plain passthrough — it's effectively constant
  /// for a session's lifetime, so it never exhibited this stutter and
  /// doesn't need interpolating.
  final ValueNotifier<Duration> position;
  final ValueNotifier<Duration> duration;

  /// Wall-clock anchor for [_estimatePositionAt]: the most recent
  /// authoritative sample (from [reportPosition] or [reportOptimisticSeek])
  /// and when it arrived. Extrapolated forward at 1x between samples
  /// while [playbackState] is `.playing`; frozen otherwise.
  Duration _lastKnownPosition = Duration.zero;
  DateTime _lastKnownAt = DateTime.now();
  Timer? _positionTicker;

  static const _positionTickInterval = Duration(milliseconds: 200);

  /// Drift beyond this is treated as a real desync (reconnect, another
  /// device seeking, session resume) and snapped to immediately. Below
  /// it, normal poll-cadence jitter is left for the ticker to glide into
  /// on its own next tick rather than visibly jumping.
  static const _snapThreshold = Duration(milliseconds: 1500);

  /// SEEK-REVERT FIX. Set by [reportOptimisticSeek], cleared once an
  /// authoritative sample actually corroborates it (or [_seekGracePeriod]
  /// elapses without one).
  ///
  /// The bug this guards against: every transport's authoritative
  /// position — JellyfinRemoteTransport's 3s session-sync poll, Google
  /// Cast's ~1s `playerPositionStream`, Nemesis Native's receiver-pushed
  /// state — can still report the *pre-seek* position for one more
  /// sample after `CastManager.seek()` fires. The TV/receiver hasn't
  /// necessarily finished processing the seek by the time that in-flight
  /// poll/query was made (Jellyfin) or by the time its next scheduled
  /// push happens to land (Google Cast, Nemesis Native). Without this
  /// guard, that stale sample reaches [reportPosition], which compares
  /// it against our optimistic target, sees a huge drift, and "corrects"
  /// by snapping the displayed position backward to the old value — then
  /// the *next* sample (which does reflect the seek) snaps forward again.
  /// That two-step snap-back-then-forward is exactly the "returns to its
  /// previous position, then comes back to the released/clicked point"
  /// glitch reported on CastSeekBar (used both in the connected-session
  /// sheet and, since Casting Phase 14, PlayerBottomBar's seek bar while
  /// casting) — on all three transports, since they all funnel through
  /// this one shared session.
  ///
  /// While a seek is pending, a sample that doesn't land within
  /// [_snapThreshold] of the target is treated as stale and dropped
  /// entirely (not even used to update [_lastKnownPosition]) rather than
  /// trusted immediately, for as long as [_seekGracePeriod] allows.
  Duration? _pendingSeekTarget;
  DateTime? _pendingSeekAt;

  /// SEEK-STICK FIX: where the device was (best estimate) at the moment
  /// each still-pending seek began — one anchor per seek, so rapid
  /// back-to-back seeks are all covered. A sample that still sits on one
  /// of these anchors' own trajectory (anchor position, advancing at 1x
  /// since it was taken) is, by definition, the device describing its
  /// PRE-seek state: it simply hasn't processed the seek yet. See
  /// [_looksLikePreSeekSample] and [_staleSampleGracePeriod].
  final List<_SeekAnchor> _preSeekAnchors = <_SeekAnchor>[];

  /// SEEK-RESTART FIX: whether a seek's optimistic target is still
  /// waiting on an authoritative sample to corroborate it (see the doc
  /// comment above). Exposed read-only so callers outside this class —
  /// [PlaybackCoordinator]'s auto-advance watcher, specifically — can
  /// tell "we just sought and the receiver is still settling" apart from
  /// a genuine, un-prompted playback-state change, without duplicating
  /// this class's own pending-seek bookkeeping.
  bool get isSeekPending => _pendingSeekTarget != null;

  /// Comfortably covers JellyfinRemoteTransport's 3s poll cadence (one
  /// full missed cycle) as well as Google Cast/Nemesis Native's ~1s push
  /// cadence (several cycles) — long enough that a stale pre-seek sample
  /// almost always gets superseded by a real one inside this window, but
  /// short enough that a seek to an unsupported/out-of-range point still
  /// resolves to *something* on screen at a bounded delay rather than
  /// hanging on the optimistic value forever.
  static const _seekGracePeriod = Duration(seconds: 4);

  /// SEEK-STICK FIX: the longer window during which a sample that still
  /// matches the PRE-seek trajectory keeps being dropped.
  ///
  /// [_seekGracePeriod] alone was too short for the slow reporters: a
  /// Jellyfin Remote client only reports its position to the server every
  /// several seconds (and the app polls the server every 3s on top of
  /// that), and a Google Cast/DLNA seek that has to restart a transcode
  /// can take longer than 4s to land. Once the 4s ran out the next stale
  /// pre-seek sample was trusted, snapping the bar back to where it was
  /// before the seek — then forward again when the real sample finally
  /// arrived. Samples that are clearly NOT the pre-seek position (the
  /// seek landed, or the device is somewhere else entirely) are never
  /// held for longer than [_seekGracePeriod], so a seek that genuinely
  /// failed still resolves — just later, once this longer window ends.
  static const _staleSampleGracePeriod = Duration(seconds: 15);

  /// PLAY/PAUSE LAG FIX. Set by [reportOptimisticPlaybackState] the
  /// instant an explicit play/pause command is sent; cleared once this
  /// deadline passes.
  ///
  /// The bug this guards against: `CastManager.play()/pause()/
  /// togglePlayPause()` set [playbackState] optimistically, the instant
  /// the person taps, for exactly the reason `reportOptimisticSeek`'s doc
  /// comment gives for seeking — otherwise the button sits unchanged
  /// until the transport's round trip completes. But `reportPosition`'s
  /// own "STUCK PLAY/PAUSE-ICON FIX" below watches for forward position
  /// movement to *promote* a stale non-playing state back to `.playing`,
  /// for a completely different, legitimate reason (a transport's status
  /// channel failing to report a `playing` transition at all). Those two
  /// fixes fight each other in exactly one window: the ~1 authoritative-
  /// sample-long gap between tapping **pause** and the receiver actually
  /// having paused. The optimistic tap sets `.paused`; the TV, still
  /// finishing the last bit of audio it already had buffered before the
  /// pause command arrived, reports one more position sample that's
  /// slightly ahead of the last one — genuine forward motion, which the
  /// stuck-icon fix reads as proof `.paused` must be stale and flips it
  /// back to `.playing`. The button visually un-presses itself a beat
  /// after being tapped, then (once the real pause confirmation lands a
  /// moment later) flips to paused again — exactly the "delays to
  /// respond"/"buggy" symptom reported on cast play/pause. Suppressing
  /// the stuck-icon promotion for a short window right after an explicit
  /// command closes that race without weakening the stuck-icon fix for
  /// the case it actually exists for (a stale state with *no* recent
  /// explicit command behind it).
  DateTime? _pendingPlaybackCommandUntil;

  /// Comfortably covers Google Cast's ~1s `playerPositionStream` cadence
  /// (one full cycle, so the single stale in-flight sample a pause/play
  /// command can race against is suppressed) without being so long that
  /// a genuinely stuck state stays hidden from the promotion fix for
  /// long after a real command.
  static const _playbackCommandSettleWindow = Duration(milliseconds: 1500);

  final ValueNotifier<double> volume;
  final ValueNotifier<int?> activeAudioTrackId;
  final ValueNotifier<int?> activeSubtitleTrackId;

  /// Live TV: whether closed captions were switched on for the TV (see
  /// ClosedCaptionCapableTransport). Reset by CastManager whenever a new
  /// channel is loaded, since a fresh stream starts without them.
  final ValueNotifier<bool> closedCaptionsOn = ValueNotifier(false);

  /// Casting Phase 12 — queue shuffle/repeat state for the audio
  /// transport row (`CastTransportControls`). [shuffleNotifier] is set
  /// optimistically by `CastManager.toggleShuffle()` the moment the
  /// command is sent (no transport here can reliably push a confirmed
  /// shuffle state back) — matches the "optimistic, corrected on the
  /// next real update" approach [capabilityNotifier] already documents
  /// for Google Cast. [repeatModeNotifier] gets the same optimistic set,
  /// but JellyfinRemoteTransport's session-sync poll also corrects it
  /// from the server's own `PlayState.RepeatMode` on every tick, same as
  /// `position`/`duration` above.
  final ValueNotifier<bool> shuffleNotifier;
  final ValueNotifier<CastRepeatMode> repeatModeNotifier;

  /// Casting playback-rate fix. Mirrors [shuffleNotifier]'s reasoning:
  /// set optimistically by `CastManager.setPlaybackRate()` the moment the
  /// command is sent, since Google Cast has no dedicated rate-change
  /// event stream this app currently listens to and Nemesis Native's
  /// state-push cadence would otherwise leave the sheet's checkmark
  /// lagging a beat behind what was tapped. Nemesis Native's
  /// receiver-pushed state (`_applyState`) still corrects this from the
  /// TV's own reported `playbackRate` on every state message, same as
  /// `position`/`activeSubtitleTrackId` above, so a dropped/rejected
  /// command there self-heals within one state push.
  final ValueNotifier<double> playbackRateNotifier;

  /// Surfaced for the UI to show something concrete on a CastConnectionState
  /// or CastPlaybackState of `.error` (e.g. "Living Room TV lost
  /// connection" vs. a generic failure message), without every transport
  /// needing its own bespoke error-plumbing back to the UI.
  final ValueNotifier<String?> lastError;

  /// The session's live capability, seeded from `device.capabilityFor
  /// (transportKind)` at construction and otherwise identical to what
  /// `capability` always resolved to before this field existed — for
  /// JellyfinRemoteTransport and any future NemesisNativeTransport
  /// session, nothing ever writes to this, so `capability` behaves
  /// exactly as it did in Phase 3/4 (device.transports is only ever
  /// replaced via CastDevice.copyWith, never mutated in place, and
  /// `device` itself is `final` here — so the old getter was already
  /// effectively constant for a session's lifetime; this is a snapshot
  /// of that same constant, not a behavior change).
  ///
  /// GoogleCastTransport (Phase 5) is the first thing that actually
  /// writes to this: the Phase 2 architecture doc flags Google Cast's
  /// capability as computed **per loaded item**, not per device (audio/
  /// subtitle track selection depends on what the Cast receiver actually
  /// loaded), so a session's real capability can legitimately change
  /// after `load()` in a way the other two transports' device-level
  /// CastCapability never does. This notifier is the seam that lets a
  /// transport push that kind of update without CastManager or any UI
  /// widget needing to know which transport it's talking to.
  final ValueNotifier<CastCapability> capabilityNotifier;

  CastSession({
    required this.device,
    required this.transportKind,
    CastConnectionState initialConnectionState = CastConnectionState.connecting,
  })  : connectionState = ValueNotifier(initialConnectionState),
        playbackState = _GuardedPlaybackState(CastPlaybackState.idle),
        currentItem = ValueNotifier(null),
        position = ValueNotifier(Duration.zero),
        duration = ValueNotifier(Duration.zero),
        volume = ValueNotifier(1.0),
        activeAudioTrackId = ValueNotifier(null),
        activeSubtitleTrackId = ValueNotifier(null),
        shuffleNotifier = ValueNotifier(false),
        repeatModeNotifier = ValueNotifier(CastRepeatMode.off),
        playbackRateNotifier = ValueNotifier(1.0),
        lastError = ValueNotifier(null),
        capabilityNotifier =
            ValueNotifier(device.capabilityFor(transportKind)) {
    // Re-baseline extrapolation on every play/pause/buffering transition
    // so the ticker freezes/resumes exactly from "now" instead of
    // jumping — e.g. without this, pausing would leave _lastKnownAt
    // stale, and resuming later would extrapolate as if playback had
    // kept advancing the whole time it was actually paused.
    playbackState.addListener(_recalibrate);
    (playbackState as _GuardedPlaybackState).shouldDrop =
        _shouldDropIncomingState;
    playbackState.addListener(_updateShowsPlaying);
    _updateShowsPlaying();
  }

  CastCapability get capability => capabilityNotifier.value;

  bool get isConnected => connectionState.value == CastConnectionState.connected;

  // ---------------------------------------------------------------------
  // Position interpolation (SMOOTH-SEEK-BAR FIX)
  // ---------------------------------------------------------------------

  /// Called by a transport whenever it receives an authoritative position
  /// sample (Jellyfin's session-sync poll, Google Cast's
  /// `playerPositionStream`, Nemesis Native's receiver state message) —
  /// replaces what used to be a direct `session.position.value = ...`
  /// write at each of those call sites.
  ///
  /// Small drift from where the ticker had already extrapolated to (the
  /// normal case — this is just the next scheduled sample confirming
  /// we're roughly on track) is absorbed silently: [position] is left
  /// alone and the ticker's next tick converges onto the corrected
  /// trajectory on its own, which reads as smooth motion rather than a
  /// hop. Only a real desync — reconnect, another device seeking,
  /// session resume after the app was backgrounded — snaps immediately,
  /// since gliding slowly across a multi-second gap would look wrong in
  /// the other direction.
  void reportPosition(Duration position) {
    final now = DateTime.now();

    // SEEK-REVERT FIX: while a seek is still settling, decide whether
    // this sample corroborates it before doing anything else with it —
    // see the doc comment on `_pendingSeekTarget` for why a stale sample
    // landing here is the expected common case, not the exception.
    if (_pendingSeekTarget != null) {
      final seekTarget = _pendingSeekTarget!;
      final seekAge = now.difference(_pendingSeekAt!);

      // Landed on the target — or, while playing, somewhere just past it
      // (the device reached the target some moments ago and has been
      // playing on from there since).
      final matchesSeek = (position - seekTarget).abs() <= _snapThreshold ||
          (playbackState.value == CastPlaybackState.playing &&
              position > seekTarget &&
              position <= seekTarget + seekAge + _snapThreshold);

      if (matchesSeek) {
        // The device has caught up — resume normal tracking below using
        // this now-trustworthy sample.
        _clearPendingSeek();
      } else if (seekAge < _seekGracePeriod ||
          (seekAge < _staleSampleGracePeriod &&
              _looksLikePreSeekSample(position, now))) {
        // Still within the grace window and this sample doesn't
        // corroborate the seek yet — almost certainly a stale, in-flight
        // pre-seek report. Drop it on the floor rather than snapping the
        // displayed position back to it; the optimistic target set by
        // reportOptimisticSeek keeps showing until a real sample arrives.
        //
        // SEEK-STICK FIX: past the short grace window, a sample is still
        // dropped for as long as it is recognisably the PRE-seek position
        // (see [_staleSampleGracePeriod]).
        return;
      } else {
        // Grace period elapsed and the device still isn't reporting
        // anywhere near our target — the seek likely didn't actually
        // take (dropped command, seek past what the device will honor,
        // etc). Stop waiting and fall through to trust the device again.
        _clearPendingSeek();
      }
    }

    final estimatedNow = _estimatePositionAt(now);
    final drift = (position - estimatedNow).abs();

    // STUCK PLAY/PAUSE-ICON FIX: a transport's playback-state channel
    // (most notably Google Cast's `mediaStatusStream`, which pushes far
    // less reliably than its own ~1s `playerPositionStream`) can leave
    // [playbackState] parked on a stale non-playing value — `loading`,
    // `buffering`, or even `paused` — even though the receiver is
    // demonstrably advancing through the content. That's exactly what
    // two authoritative position samples arriving here, one strictly
    // ahead of the last, prove: nothing "paused" produces forward
    // motion on its own. Every play/pause button in the app
    // (CastTransportControls, CastingActivePanel's compact banner,
    // MiniPlayer) reads straight off [playbackState], so leaving it
    // stuck meant those buttons — and MusicVisualizer, once it's wired
    // to this same notifier — looked permanently paused while audio was
    // audibly running.
    //
    // Correcting it here, rather than only inside each transport's own
    // status handler, means the fix applies no matter *why* that
    // transport's own channel failed to report the transition — a
    // dropped push, a receiver that only reports state on request, or
    // any other side-channel flakiness — instead of chasing each one
    // individually. Deliberately one-directional: this only ever
    // promotes a stale state to `.playing`, never the reverse. A lack of
    // forward movement is ambiguous (a slow poll cycle isn't the same
    // as a real pause), so `.playing` -> anything-else stays owned
    // entirely by each transport's own explicit state push — this can't
    // make a genuinely paused session look like it's playing, only stop
    // a genuinely playing one from looking paused.
    final previousPosition = _lastKnownPosition;
    final previousAt = _lastKnownAt;
    final advancedByRealTime = now.difference(previousAt);
    // PLAY/PAUSE LAG FIX: don't let this promotion fight a play/pause
    // command that was just sent — see `_pendingPlaybackCommandUntil`'s
    // doc comment for exactly which race this avoids.
    final settlingFromExplicitCommand = _pendingPlaybackCommandUntil != null &&
        now.isBefore(_pendingPlaybackCommandUntil!);
    if (!settlingFromExplicitCommand &&
        playbackState.value != CastPlaybackState.playing &&
        playbackState.value != CastPlaybackState.error &&
        playbackState.value != CastPlaybackState.stopped &&
        playbackState.value != CastPlaybackState.ended &&
        position - previousPosition > const Duration(milliseconds: 400) &&
        advancedByRealTime > Duration.zero &&
        advancedByRealTime < const Duration(seconds: 10)) {
      playbackState.value = CastPlaybackState.playing;
    }

    _lastKnownPosition = position;
    _lastKnownAt = now;

    if (drift > _snapThreshold) {
      this.position.value = position;
    }

    _ensureTicker();
  }

  /// Called the instant the person commits a seek — releasing the seek
  /// bar thumb, tapping ±10s — BEFORE the transport's seek command
  /// round-trip to the TV completes. Without this, the displayed position
  /// would sit at the pre-seek value (or whatever the ticker last
  /// extrapolated to) until the next authoritative sample arrived,
  /// reading as a laggy, unresponsive seek.
  void reportOptimisticSeek(Duration target) {
    final now = DateTime.now();
    // SEEK-STICK FIX: remember where the device is RIGHT NOW (before the
    // optimistic target below overwrites our estimate) so late pre-seek
    // samples can be recognised as stale later on.
    _preSeekAnchors.add(_SeekAnchor(_estimatePositionAt(now), now));
    if (_preSeekAnchors.length > 4) _preSeekAnchors.removeAt(0);
    _lastKnownPosition = target;
    _lastKnownAt = now;
    // SEEK-REVERT FIX: arm the pending-seek guard so the next one (or
    // few) authoritative samples — which are likely still describing the
    // pre-seek state — get filtered by reportPosition() instead of
    // yanking the bar back before the device catches up.
    _pendingSeekTarget = target;
    _pendingSeekAt = now;
    position.value = target;
    _ensureTicker();
  }

  void _clearPendingSeek() {
    _pendingSeekTarget = null;
    _pendingSeekAt = null;
    _preSeekAnchors.clear();
  }

  /// Whether [sample] still lies on the trajectory of a position the
  /// device was at when a pending seek began (anchor position, plus up to
  /// the real time elapsed since — playback may have advanced — with the
  /// usual jitter tolerance either side).
  bool _looksLikePreSeekSample(Duration sample, DateTime now) {
    for (final anchor in _preSeekAnchors) {
      final age = now.difference(anchor.at);
      if (sample >= anchor.position - _snapThreshold &&
          sample <= anchor.position + age + _snapThreshold) {
        return true;
      }
    }
    return false;
  }

  /// PLAY/PAUSE LAG FIX. Called by `CastManager.play()/pause()/
  /// togglePlayPause()` instead of writing `playbackState.value` directly
  /// — sets the new state immediately (same instant-feedback contract
  /// `reportOptimisticSeek` already gives seeking) and arms the settle
  /// window that keeps `reportPosition`'s stuck-icon promotion from
  /// undoing it. See `_pendingPlaybackCommandUntil`'s doc comment for the
  /// exact race this closes.
  void reportOptimisticPlaybackState(CastPlaybackState state) {
    final now = DateTime.now();
    _pendingPlaybackCommandUntil = now.add(_playbackCommandSettleWindow);
    // PLAY/PAUSE FLICKER FIX: drop any guard left over from an earlier tap
    // first, so this write itself can never be filtered, then arm the guard
    // for THIS tap. From here until the transport confirms (or
    // [_optimisticStateWindow] elapses) a stale push that contradicts the
    // tapped state is ignored instead of flipping the button back and then
    // forward again — the "button clicks and unclicks itself" symptom.
    _optimisticTarget = null;
    _optimisticUntil = null;
    playbackState.value = state;
    if (state == CastPlaybackState.playing ||
        state == CastPlaybackState.paused) {
      _optimisticTarget = state;
      _optimisticUntil = now.add(_optimisticStateWindow);
    }
  }

  /// Called by [_GuardedPlaybackState] for every write to [playbackState].
  /// Returns true when the write is a stale push that contradicts a tap
  /// still waiting for confirmation and must be dropped.
  bool _shouldDropIncomingState(CastPlaybackState incoming) {
    final target = _optimisticTarget;
    if (target == null) return false;
    final until = _optimisticUntil;
    if (until == null || !DateTime.now().isBefore(until)) {
      _optimisticTarget = null;
      _optimisticUntil = null;
      return false;
    }
    if (incoming == target) {
      // The transport confirmed what was tapped.
      _optimisticTarget = null;
      _optimisticUntil = null;
      return false;
    }
    switch (incoming) {
      case CastPlaybackState.playing:
      case CastPlaybackState.paused:
      case CastPlaybackState.buffering:
        // Opposite play/pause, or a buffering blip, while the tap is still
        // unconfirmed: almost certainly a stale pre-tap report.
        return true;
      case CastPlaybackState.idle:
      case CastPlaybackState.loading:
      case CastPlaybackState.stopped:
      case CastPlaybackState.ended:
      case CastPlaybackState.error:
        // A genuinely different situation (track change, stop, failure):
        // let it through and stop guarding.
        _optimisticTarget = null;
        _optimisticUntil = null;
        return false;
    }
  }

  /// Keeps [showsPlaying] in step with [playbackState] — see its doc
  /// comment for the rules.
  void _updateShowsPlaying() {
    switch (playbackState.value) {
      case CastPlaybackState.playing:
        _showsPlayingDebounce?.cancel();
        _showsPlayingDebounce = null;
        if (!showsPlaying.value) showsPlaying.value = true;
        break;
      case CastPlaybackState.paused:
      case CastPlaybackState.error:
        _showsPlayingDebounce?.cancel();
        _showsPlayingDebounce = null;
        if (showsPlaying.value) showsPlaying.value = false;
        break;
      case CastPlaybackState.buffering:
      case CastPlaybackState.loading:
        // Transient: keep whatever is showing; a pending idle-debounce
        // is cancelled because playback is clearly (re)starting.
        _showsPlayingDebounce?.cancel();
        _showsPlayingDebounce = null;
        break;
      case CastPlaybackState.idle:
      case CastPlaybackState.stopped:
      case CastPlaybackState.ended:
        if (!showsPlaying.value) break;
        _showsPlayingDebounce?.cancel();
        _showsPlayingDebounce = Timer(_idleDisplayDebounce, () {
          _showsPlayingDebounce = null;
          switch (playbackState.value) {
            case CastPlaybackState.idle:
            case CastPlaybackState.stopped:
            case CastPlaybackState.ended:
              if (showsPlaying.value) showsPlaying.value = false;
              break;
            default:
              break;
          }
        });
        break;
    }
  }

  /// PHASE 4 (DLNA play/pause flipped back): a transport that confirms a
  /// play/pause command slowly (AirScreen-style receivers report the new
  /// state several seconds late, while their position still advances) asks
  /// for a longer settle window than the default, so the stuck-icon
  /// promotion in [reportPosition] cannot undo the tap in between. Never
  /// shortens a window that is already running.
  void holdPlaybackCommand(Duration window) {
    final until = DateTime.now().add(window);
    final current = _pendingPlaybackCommandUntil;
    if (current == null || until.isAfter(current)) {
      _pendingPlaybackCommandUntil = until;
    }
    // Keep the stale-push guard alive at least as long (never shortens it).
    final guardUntil = _optimisticUntil;
    if (_optimisticTarget != null &&
        (guardUntil == null || until.isAfter(guardUntil))) {
      _optimisticUntil = until;
    }
  }

  /// PHASE 4: the transport saw the TV confirm the command (or gave up on
  /// it) — the stuck-icon promotion may work normally again.
  void settlePlaybackCommand() {
    _pendingPlaybackCommandUntil = null;
    // The transport has confirmed or given up: whatever it reports next is
    // authoritative again.
    _optimisticTarget = null;
    _optimisticUntil = null;
  }

  /// PHASE 4: a seek the TV demonstrably did not perform. Drops the
  /// optimistic target so the bar goes back to what the TV really reports
  /// instead of waiting out the grace windows on a position that will never
  /// arrive.
  void cancelPendingSeek() {
    _clearPendingSeek();
  }

  void _recalibrate() {
    final now = DateTime.now();
    _lastKnownPosition = _estimatePositionAt(now);
    _lastKnownAt = now;
  }

  Duration _estimatePositionAt(DateTime now) {
    if (playbackState.value != CastPlaybackState.playing) {
      // Paused, buffering, idle, stopped, ended, or error — nothing is
      // actually advancing on the TV right now, so don't extrapolate
      // forward or the bar would keep crawling while playback is frozen.
      return _lastKnownPosition;
    }
    final elapsed = now.difference(_lastKnownAt);
    final estimated = _lastKnownPosition + elapsed;
    final total = duration.value;
    return (total > Duration.zero && estimated > total) ? total : estimated;
  }

  void _ensureTicker() {
    _positionTicker ??= Timer.periodic(_positionTickInterval, (_) {
      position.value = _estimatePositionAt(DateTime.now());
    });
  }

  /// Disposes every ValueNotifier this session owns. Must be called by
  /// whatever ends the session (CastManager.disconnect()) — these are
  /// plain ValueNotifiers, not tied to a widget's lifecycle, so nothing
  /// else disposes them automatically.
  void dispose() {
    _positionTicker?.cancel();
    _showsPlayingDebounce?.cancel();
    playbackState.removeListener(_recalibrate);
    playbackState.removeListener(_updateShowsPlaying);
    showsPlaying.dispose();
    connectionState.dispose();
    playbackState.dispose();
    currentItem.dispose();
    idleReason.dispose();
    position.dispose();
    duration.dispose();
    volume.dispose();
    activeAudioTrackId.dispose();
    activeSubtitleTrackId.dispose();
    closedCaptionsOn.dispose();
    shuffleNotifier.dispose();
    repeatModeNotifier.dispose();
    playbackRateNotifier.dispose();
    lastError.dispose();
    capabilityNotifier.dispose();
  }

  @override
  String toString() =>
      'CastSession(${device.displayName} via $transportKind, '
      '${connectionState.value}/${playbackState.value})';
}

/// [ValueNotifier] whose writes can be vetoed by [shouldDrop]. Used for
/// [CastSession.playbackState] so a stale transport push never reaches the
/// UI between a play/pause tap and the receiver's confirmation, no matter
/// which transport (or `reportPosition`'s icon-promotion) wrote it.
class _GuardedPlaybackState extends ValueNotifier<CastPlaybackState> {
  _GuardedPlaybackState(CastPlaybackState initial) : super(initial);

  bool Function(CastPlaybackState incoming)? shouldDrop;

  @override
  set value(CastPlaybackState newValue) {
    if (shouldDrop?.call(newValue) ?? false) return;
    super.value = newValue;
  }
}

/// A device position captured at the instant a seek was issued — see
/// [CastSession._preSeekAnchors].
class _SeekAnchor {
  const _SeekAnchor(this.position, this.at);

  final Duration position;
  final DateTime at;
}
