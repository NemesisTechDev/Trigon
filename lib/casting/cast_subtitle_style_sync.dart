import 'dart:async';

import 'package:flutter/foundation.dart';

import '../player/models/subtitle_appearance.dart';
import '../services/subtitle_appearance_settings.dart';
import 'cast_manager.dart';
import 'models/cast_session.dart';
import 'models/cast_states.dart';

/// Keeps the TV's subtitle style in step with the user's subtitle style
/// setting — *always*, including the untouched defaults, so subtitles on
/// the TV look like the app's own default (white, regular weight, no
/// background box) instead of the receiver's built-in style (black box,
/// its own font). Pushed:
///  - whenever the setting changes (live, debounced),
///  - when a session becomes connected,
///  - shortly after each new item loads (some receivers reset caption
///    styling per load, and a receiver can't be styled before its media
///    session exists), and
///  - once more when playback actually starts for each item, which is the
///    first moment a slow load is guaranteed to have a media session.
class CastSubtitleStyleSync {
  CastSubtitleStyleSync._();
  static final CastSubtitleStyleSync instance = CastSubtitleStyleSync._();

  bool _started = false;
  Timer? _debounce;
  Timer? _afterLoad;
  Timer? _afterLoadLate;
  Timer? _afterPlay;
  Timer? _afterTrack;
  Timer? _retry;
  int _retries = 0;
  CastSession? _bound;

  /// Last playback state seen, to spot a FRESH load (idle/loading ->
  /// playing) as opposed to a pause/seek/buffer blip.
  CastPlaybackState? _lastPlayback;

  /// Id of the item the "playback started" push already ran for.
  String? _styledItemId;

  void init() {
    if (_started) return;
    _started = true;
    SubtitleAppearanceSettings.notifier.addListener(_onStyleChanged);
    CastManager.instance.activeSession.addListener(_onSessionChanged);
    _onSessionChanged();
  }

  void _onSessionChanged() {
    final next = CastManager.instance.activeSession.value;
    if (identical(next, _bound)) return;
    _unbind();
    _bound = next;
    _styledItemId = null;
    if (next == null) return;
    next.connectionState.addListener(_onConnectionChanged);
    next.currentItem.addListener(_onItemChanged);
    next.playbackState.addListener(_onPlaybackChanged);
    next.activeSubtitleTrackId.addListener(_onSubtitleTrackChanged);
    _lastPlayback = next.playbackState.value;
    _onConnectionChanged();
  }

  void _unbind() {
    final s = _bound;
    if (s == null) return;
    // The session may already be disposed during teardown.
    try {
      s.connectionState.removeListener(_onConnectionChanged);
      s.currentItem.removeListener(_onItemChanged);
      s.playbackState.removeListener(_onPlaybackChanged);
      s.activeSubtitleTrackId.removeListener(_onSubtitleTrackChanged);
    } catch (_) {}
    _bound = null;
    _lastPlayback = null;
    _afterLoad?.cancel();
    _afterLoadLate?.cancel();
    _afterPlay?.cancel();
    _afterTrack?.cancel();
    _retry?.cancel();
  }

  void _onConnectionChanged() {
    if (_bound?.connectionState.value == CastConnectionState.connected) {
      _push();
    }
  }

  void _onItemChanged() {
    _styledItemId = null;
    _afterLoad?.cancel();
    _afterLoadLate?.cancel();
    _afterLoad = Timer(const Duration(milliseconds: 1500), _push);
    // Slow loads (transcodes, big local files) may not have a media
    // session yet at 1.5s.
    _afterLoadLate = Timer(const Duration(milliseconds: 4500), _push);
  }

  void _onPlaybackChanged() {
    final s = _bound;
    if (s == null) return;
    final now = s.playbackState.value;
    final prev = _lastPlayback;
    _lastPlayback = now;
    if (now != CastPlaybackState.playing) return;

    final id = s.currentItem.value?.id;

    // Re-push on the first "playing" of every item AND whenever playback
    // comes back from idle/loading/stopped/ended/error. Those are fresh
    // loads of the receiver's media session — including RELOADS of the
    // same item (audio-track switch, a subtitle added mid-cast, a load
    // retry), which never change `currentItem` and so used to be skipped
    // by the once-per-item guard, leaving the receiver on its own
    // default style (black box) after the reload. Pause/seek/buffering
    // blips are deliberately excluded to avoid needless traffic.
    final freshLoad = prev == null ||
        prev == CastPlaybackState.idle ||
        prev == CastPlaybackState.loading ||
        prev == CastPlaybackState.stopped ||
        prev == CastPlaybackState.ended ||
        prev == CastPlaybackState.error;
    final newItem = id != null && id != _styledItemId;
    if (!freshLoad && !newItem) return;

    if (id != null) _styledItemId = id;
    _afterPlay?.cancel();
    _afterPlay = Timer(const Duration(milliseconds: 400), _push);
  }

  /// Selecting/switching the active subtitle track can make the receiver
  /// rebuild its caption renderer with default styling, so re-apply the
  /// user's style right after it changes.
  void _onSubtitleTrackChanged() {
    _afterTrack?.cancel();
    _afterTrack = Timer(const Duration(milliseconds: 300), _push);
  }

  void _onStyleChanged() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 120), _push);
  }

  /// Sends the current style. A push can legitimately fail right after a
  /// load (the receiver has no media session yet, or hasn't accepted the
  /// style), so a failure schedules a few retries with growing delays
  /// instead of leaving the TV on its own default style.
  void _push({bool isRetry = false}) {
    if (!isRetry) {
      _retry?.cancel();
      _retries = 0;
    }
    final SubtitleAppearance a = SubtitleAppearanceSettings.notifier.value;
    unawaited(CastManager.instance.applySubtitleStyle(a).then((_) {
      _retries = 0;
    }).catchError((Object e) {
      debugPrint('CastSubtitleStyleSync: push failed: $e');
      _scheduleRetry();
    }));
  }

  void _scheduleRetry() {
    if (_bound == null || _retries >= 5) return;
    _retries++;
    _retry?.cancel();
    _retry = Timer(
      Duration(milliseconds: 700 * _retries),
      () => _push(isRetry: true),
    );
  }
}
