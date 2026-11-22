import 'dart:async';

import 'package:flutter/foundation.dart';

import '../casting/cast_manager.dart';
import '../player/player_manager.dart';

/// What the active sleep timer is waiting for.
enum SleepTimerMode { duration, endOfTrack }

/// Snapshot of a running sleep timer — [endsAt] is only set for
/// [SleepTimerMode.duration].
@immutable
class SleepTimerState {
  final SleepTimerMode mode;
  final DateTime? endsAt;
  final Duration? length;

  const SleepTimerState._(this.mode, this.endsAt, this.length);

  Duration get remaining {
    final end = endsAt;
    if (end == null) return Duration.zero;
    final left = end.difference(DateTime.now());
    return left.isNegative ? Duration.zero : left;
  }
}

/// Music sleep timer: pauses playback after a chosen time, or once the
/// current track has finished. Works the same for local playback and
/// while casting (pause goes through whichever one is actually playing).
///
/// One shared ticker (500 ms, only alive while a timer is set) handles
/// both modes, so nothing here has to hook into PlayerManager's or the
/// cast session's internals:
///  * duration: pauses when [SleepTimerState.endsAt] passes.
///  * end of track: pauses the moment the playing item changes (the queue
///    advanced) or wraps back to the start (repeat-one).
/// After firing, playback is re-paused for a few seconds if the player
/// starts the next song anyway (it opens the next item asynchronously and
/// would otherwise override a pause issued a moment too early).
class SleepTimerService {
  SleepTimerService._();
  static final SleepTimerService instance = SleepTimerService._();

  /// null = no timer running. Updates when set/cancelled and once per
  /// second while counting down (so a visible countdown stays live).
  final ValueNotifier<SleepTimerState?> state = ValueNotifier(null);

  Timer? _ticker;
  String? _trackIdAtStart;
  Duration _lastPosition = Duration.zero;
  int _lastShownSecond = -1;

  // Post-fire guard: keep pausing until this moment.
  DateTime? _guardUntil;

  bool get active => state.value != null;

  void startDuration(Duration length) {
    _begin(SleepTimerState._(
      SleepTimerMode.duration,
      DateTime.now().add(length),
      length,
    ));
  }

  void startEndOfTrack() {
    _begin(const SleepTimerState._(SleepTimerMode.endOfTrack, null, null));
  }

  void cancel() {
    _ticker?.cancel();
    _ticker = null;
    _guardUntil = null;
    state.value = null;
  }

  void _begin(SleepTimerState next) {
    _ticker?.cancel();
    _guardUntil = null;
    _trackIdAtStart = _currentId();
    _lastPosition = _currentPosition();
    _lastShownSecond = -1;
    state.value = next;
    _ticker = Timer.periodic(const Duration(milliseconds: 500), (_) => _tick());
  }

  // ---- sources: casting session when connected, local player otherwise

  bool get _casting => CastManager.instance.isCasting;

  String? _currentId() => _casting
      ? CastManager.instance.activeSession.value?.currentItem.value?.id
      : PlayerManager.instance.currentItem?.id;

  Duration _currentPosition() => _casting
      ? CastManager.instance.activeSession.value?.position.value ??
          Duration.zero
      : PlayerManager.instance.position.value;

  Duration _currentDuration() => _casting
      ? CastManager.instance.activeSession.value?.duration.value ??
          Duration.zero
      : PlayerManager.instance.duration.value;

  bool get _isPlaying => _casting
      ? CastManager.instance.activeSession.value?.playbackState.value.name ==
          'playing'
      : PlayerManager.instance.playing.value;

  Future<void> _pause() async {
    try {
      if (_casting) {
        await CastManager.instance.pause();
      } else {
        await PlayerManager.instance.player.pause();
      }
    } catch (e) {
      debugPrint('SleepTimerService: pause failed: $e');
    }
  }

  void _tick() {
    final s = state.value;
    if (s == null) return;

    // Post-fire guard phase: re-pause if the next song started anyway.
    final guard = _guardUntil;
    if (guard != null) {
      if (DateTime.now().isAfter(guard)) {
        cancel();
      } else if (_isPlaying) {
        unawaited(_pause());
      }
      return;
    }

    if (s.mode == SleepTimerMode.duration) {
      if (DateTime.now().isBefore(s.endsAt!)) {
        // Refresh listeners once per displayed second.
        final sec = s.remaining.inSeconds;
        if (sec != _lastShownSecond) {
          _lastShownSecond = sec;
          state.value = SleepTimerState._(s.mode, s.endsAt, s.length);
        }
        return;
      }
      _fire();
      return;
    }

    // End of track.
    final id = _currentId();
    final pos = _currentPosition();
    final dur = _currentDuration();
    final changed =
        _trackIdAtStart != null && id != null && id != _trackIdAtStart;
    // Repeat-one restarts the same item: position jumps from near the end
    // back to the start.
    final wrapped = dur > const Duration(seconds: 10) &&
        _lastPosition > dur - const Duration(seconds: 8) &&
        pos + const Duration(seconds: 10) < _lastPosition;
    _lastPosition = pos;
    // The timer was set with nothing loaded: adopt the first track seen.
    if (_trackIdAtStart == null && id != null) _trackIdAtStart = id;
    if (changed || wrapped) _fire();
  }

  void _fire() {
    _guardUntil = DateTime.now().add(const Duration(seconds: 5));
    unawaited(_pause());
  }
}
