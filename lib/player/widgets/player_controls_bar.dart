import 'package:flutter/material.dart';

import '../../casting/cast_manager.dart';
import '../../casting/models/cast_capability.dart';
import '../../casting/models/cast_session.dart';
import '../../casting/ui/cast_seek_bar.dart';
import '../../casting/ui/cast_transport_controls.dart';
import '../player_manager.dart';
import '../services/playback_queue.dart';
import 'player_seek_bar.dart';
import '../../utils/responsive.dart';

/// Shared seek bar + shuffle/prev/play/next/repeat transport row for
/// music playback. Used by both the full "Now Playing" screen and the
/// lyrics screen so the two stay in sync without duplicating the wiring.
///
/// Casting fix: this row used to always drive the *local* `PlayerManager`/
/// `PlaybackQueue` unconditionally, even while a song had been handed off
/// to a cast session (`AudioPlayerScreen`'s doc comment on
/// `CastingActivePanel` called this out as a known, deliberately-deferred
/// inconsistency — "this screen's seek bar/shuffle/repeat controlling
/// local (paused) playback while casting"). In practice that meant tapping
/// play here resumed local playback right alongside whatever was already
/// playing on the TV — the actual double-audio bug, not just a stale-UI
/// inconsistency. Now this row itself branches on
/// `CastManager.instance.activeSession`, the same way `MiniPlayer`'s
/// play/pause button already does: connected -> render `CastSeekBar`/
/// `CastTransportControls` (Casting Phase 12's own audio-row widgets,
/// already wired to `CastManager`) instead of the local row below.
class PlayerControlsBar extends StatelessWidget {
  const PlayerControlsBar({
    super.key,
    this.activeColor = Colors.white,
    this.compact = false,
  });

  final Color activeColor;

  // Shrinks spacing and icon sizes for contexts (like the lyrics screen)
  // that want to give more vertical room to the content above the bar.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<CastSession?>(
      valueListenable: CastManager.instance.activeSession,
      builder: (context, session, __) {
        final casting = session?.isConnected ?? false;

        if (casting) {
          return ValueListenableBuilder<CastCapability>(
            valueListenable: session!.capabilityNotifier,
            builder: (context, capability, __) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: CastSeekBar(session: session, capability: capability),
                  ),
                  SizedBox(height: compact ? 4 : 15),
                  CastTransportControls(
                    session: session,
                    capability: capability,
                    fullscreen: !compact,
                  ),
                ],
              );
            },
          );
        }

        return _LocalControlsBar(activeColor: activeColor, compact: compact);
      },
    );
  }
}

class _LocalControlsBar extends StatelessWidget {
  const _LocalControlsBar({
    required this.activeColor,
    required this.compact,
  });

  static const _gold = Color(0xffD4AF37);

  final Color activeColor;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final manager = PlayerManager.instance;
    final player = manager.player;

    final navIconSize = compact ? 32.0 : 40.0;
    final playIconSize = compact ? 56.0 : 72.0;
    // TV is remote-navigated, not touched — the whole transport row
    // (shuffle/prev/play/next/repeat) gets a deliberate additional bump
    // on top of the existing compact/standard sizing, same
    // Responsive.isTV pattern used across the rest of the player
    // control surface. Phone/tablet keep the original numbers.
    final tvBump = Responsive.isTV ? 1.4 : 1.0;
    final shuffleRepeatIconSize = (compact ? 24.0 : 24.0) * tvBump;
    final effectiveNavIconSize = navIconSize * tvBump;
    final effectivePlayIconSize = playIconSize * tvBump;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: PlayerSeekBar(
            player: player,
            activeColor: activeColor,
          ),
        ),

        SizedBox(height: compact ? 4 : 15),

        Padding(
          padding: EdgeInsets.symmetric(horizontal: compact ? 16 : 24),
          // OVERFLOW/CENTERING FIX: this row's five buttons have a fixed
          // natural width (~296dp on phones at default size), so on a
          // narrow effective width (enlarged display size, split-screen,
          // small phone) a bare Row overflowed on the right and the
          // whole cluster read as shifted off-center. The Row now sits
          // in a FittedBox(scaleDown) at a width of max(available,
          // natural): when there's room it spreads exactly as before
          // (spaceBetween across the full width), and when there isn't
          // it scales down uniformly and stays centered in the screen.
          child: LayoutBuilder(
            builder: (context, constraints) {
              double btn(double icon) {
                final minTap = compact ? 40.0 : 48.0;
                final size = icon + 16;
                return size < minTap ? minTap : size;
              }

              final naturalWidth = btn(shuffleRepeatIconSize) * 2 +
                  btn(effectiveNavIconSize) * 2 +
                  btn(effectivePlayIconSize) +
                  2;
              final available = constraints.maxWidth.isFinite
                  ? constraints.maxWidth
                  : naturalWidth;
              final rowWidth = available > naturalWidth ? available : naturalWidth;

              return FittedBox(
                fit: BoxFit.scaleDown,
                child: SizedBox(
                  width: rowWidth,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
              ValueListenableBuilder<bool>(
                valueListenable: PlaybackQueue.instance.shuffleNotifier,
                builder: (_, shuffled, __) {
                  return IconButton(
                    visualDensity: compact
                        ? VisualDensity.compact
                        : VisualDensity.standard,
                    icon: Icon(
                      Icons.shuffle,
                      color: shuffled ? _gold : Colors.white,
                      size: shuffleRepeatIconSize,
                    ),
                    onPressed: () {
                      PlaybackQueue.instance.shuffle();
                    },
                  );
                },
              ),

              // Previous always does something now — restarts the
              // current track if it's already a few seconds in, or
              // there's no earlier one in the queue (see
              // PlayerManager.playPrevious) — so unlike Next it's never
              // actually disabled: plain white icon, always tappable.
              IconButton(
                visualDensity: compact
                    ? VisualDensity.compact
                    : VisualDensity.standard,
                icon: Icon(
                  Icons.skip_previous,
                  color: Colors.white,
                  size: effectiveNavIconSize,
                ),
                onPressed: manager.playPrevious,
              ),

              ValueListenableBuilder(
                valueListenable: manager.playing,
                builder: (_, playing, __) {
                  return IconButton(
                    visualDensity: compact
                        ? VisualDensity.compact
                        : VisualDensity.standard,
                    iconSize: effectivePlayIconSize,
                    color: Colors.white,
                    icon: Icon(
                      playing ? Icons.pause_circle : Icons.play_circle,
                    ),
                    onPressed: () {
                      player.playOrPause();
                    },
                  );
                },
              ),

              ValueListenableBuilder(
                valueListenable: PlaybackQueue.instance.currentIndexNotifier,
                builder: (_, __, ___) {
                  final enabled = manager.hasNext;

                  return IconButton(
                    visualDensity: compact
                        ? VisualDensity.compact
                        : VisualDensity.standard,
                    icon: Icon(
                      Icons.skip_next,
                      color: enabled ? Colors.white : Colors.white30,
                      size: effectiveNavIconSize,
                    ),
                    onPressed: enabled ? manager.playNext : null,
                  );
                },
              ),

              ValueListenableBuilder(
                valueListenable: PlaybackQueue.instance.repeatModeNotifier,
                builder: (_, repeatMode, __) {
                  return IconButton(
                    visualDensity: compact
                        ? VisualDensity.compact
                        : VisualDensity.standard,
                    icon: Icon(
                      switch (repeatMode) {
                        QueueRepeatMode.off => Icons.repeat,
                        QueueRepeatMode.all => Icons.repeat,
                        QueueRepeatMode.one => Icons.repeat_one,
                      },
                      color: repeatMode == QueueRepeatMode.off
                          ? Colors.white
                          : _gold,
                      size: shuffleRepeatIconSize,
                    ),
                    onPressed: () {
                      PlaybackQueue.instance.cycleRepeatMode();
                    },
                  );
                },
              ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
