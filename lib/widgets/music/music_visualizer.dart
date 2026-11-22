import 'package:flutter/material.dart';

import '../../casting/cast_manager.dart';
import '../../casting/models/cast_session.dart';
import '../../casting/models/cast_states.dart';
import '../../player/player_manager.dart';

const _gold = Color(0xffD4AF37);

/// Small pulsing bar-equalizer shown next to the title of whichever
/// row represents the currently playing track (song lists, downloads,
/// etc.). When playback pauses, the bars ease down into three small
/// dots resting at the bottom of the same footprint — and back up
/// into bars again on resume — instead of instantly swapping.
///
/// Fully self-contained: it owns its own animation controllers. It used
/// to only ever listen to [PlayerManager.instance.playing] — the
/// *local* player's own notifier — which is why it stayed frozen in its
/// paused/collapsed-dots state for the entire time a song was cast to a
/// Google Cast/Jellyfin Remote/Nemesis Native device: handing a song off
/// to a cast session pauses local playback (see `PlaybackCoordinator`),
/// so `PlayerManager.instance.playing` legitimately stays `false` for as
/// long as the cast session is the one actually playing.
///
/// CASTING FIX: now mirrors the same branching pattern
/// `PlayerControlsBar`/`CastTransportControls` already use —
/// `CastManager.instance.activeSession` is the source of truth whenever
/// a session is connected, and only falls back to the local player's
/// `playing` notifier otherwise. Callers still only need to mount it
/// when their row is the one actually playing, same as before.
class MusicVisualizer extends StatefulWidget {
  const MusicVisualizer({super.key});

  @override
  State<MusicVisualizer> createState() => _MusicVisualizerState();
}

class _MusicVisualizerState extends State<MusicVisualizer>
    with TickerProviderStateMixin {
  // Drives the pulsing bar heights while the song is actually playing.
  late final AnimationController _pulseController;

  // 0 = full equalizer bars (playing), 1 = fully collapsed into three
  // dots resting at the bottom of the visualizer (paused).
  late final AnimationController _collapseController;

  // The cast session this widget currently has its own listener
  // attached to, if any — tracked so a session change (connect,
  // disconnect, switch device) can move the listener across without
  // ever double-attaching or leaking it on a session that's gone.
  CastSession? _observedSession;

  static const double _dotSize = 3;
  static const double _maxBarHeight = 12;

  /// CASTING FIX: while a cast session is connected, it — not the local
  /// player — is the thing actually producing sound, so its
  /// `playbackState` is what this widget needs to reflect. Matches
  /// `PlayerControlsBar`'s own `casting = session?.isConnected ?? false`
  /// branch exactly.
  bool get _isPlaying {
    final session = CastManager.instance.activeSession.value;
    if (session != null && session.isConnected) {
      return session.playbackState.value == CastPlaybackState.playing;
    }
    return PlayerManager.instance.playing.value;
  }

  @override
  void initState() {
    super.initState();
    final isPlaying = _isPlaying;

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _collapseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 380),
      value: isPlaying ? 0.0 : 1.0,
    );

    if (isPlaying) _pulseController.repeat();

    PlayerManager.instance.playing.addListener(_onPlaybackStateChanged);
    CastManager.instance.activeSession.addListener(_onActiveSessionChanged);
    _observeSession(CastManager.instance.activeSession.value);
  }

  // Moves this widget's playbackState listener onto whichever
  // CastSession is current (or detaches it entirely once casting ends),
  // so a device switch/disconnect can't leave a listener attached to a
  // disposed session hanging around.
  void _observeSession(CastSession? session) {
    if (identical(session, _observedSession)) return;
    _observedSession?.playbackState.removeListener(_onPlaybackStateChanged);
    _observedSession = session;
    _observedSession?.playbackState.addListener(_onPlaybackStateChanged);
  }

  void _onActiveSessionChanged() {
    _observeSession(CastManager.instance.activeSession.value);
    _onPlaybackStateChanged();
  }

  // Steps the bars and dots in and out of sync with actual playback:
  // pausing freezes the bar heights right where they are and eases them
  // down into three dots; resuming reverses that and kicks the pulse
  // back off.
  void _onPlaybackStateChanged() {
    if (!mounted) return;
    if (_isPlaying) {
      _collapseController.reverse();
      _pulseController.repeat();
    } else {
      _pulseController.stop();
      _collapseController.forward();
    }
  }

  @override
  void dispose() {
    PlayerManager.instance.playing.removeListener(_onPlaybackStateChanged);
    CastManager.instance.activeSession.removeListener(_onActiveSessionChanged);
    _observedSession?.playbackState.removeListener(_onPlaybackStateChanged);
    _pulseController.dispose();
    _collapseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 14,
      height: _maxBarHeight,
      child: AnimatedBuilder(
        animation: Listenable.merge([_pulseController, _collapseController]),
        builder: (context, _) {
          // 0 = playing (full bars), 1 = paused (collapsed into dots).
          final collapse = Curves.easeOutCubic.transform(
            _collapseController.value,
          );

          return Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: List.generate(3, (i) {
              final t = (_pulseController.value + i * 0.33) % 1.0;
              final barHeight =
                  _dotSize + (9 * (0.5 - (t - 0.5).abs()) * 2);

              // Bars shrink down toward a same-size dot as `collapse`
              // goes to 1, so they settle at the bottom of the box
              // rather than disappearing or jumping.
              final height = barHeight + (_dotSize - barHeight) * collapse;

              // Rounds fully into a circle once fully collapsed, and
              // stays a soft pill shape while still a bar.
              final radius = 1 + (0.5 * _dotSize - 1) * collapse;

              return Container(
                width: _dotSize,
                height: height,
                decoration: BoxDecoration(
                  color: _gold,
                  borderRadius: BorderRadius.circular(radius),
                ),
              );
            }),
          );
        },
      ),
    );
  }
}
