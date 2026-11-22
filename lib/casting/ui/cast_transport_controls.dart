import 'package:flutter/material.dart';

import '../../player/models/media_item.dart';
import '../../player/services/playback_queue.dart';
import '../cast_manager.dart';
import '../models/cast_capability.dart';
import '../models/cast_session.dart';
import '../playback_coordinator.dart';
import 'cast_ui.dart';

/// Casting Phase 12 — content-aware transport controls for the connected-
/// session UI (`CastingActivePanel`'s fullscreen panel, the connected-
/// session sheet). Both surfaces previously showed the exact same
/// previous/play/next row no matter what was actually casting, which is
/// most of why the controls looked broken: a standalone movie or a live
/// TV channel almost never reports `NextTrack`/`PreviousTrack` support
/// (there's nothing to skip to), so that row rendered as little more
/// than a lone, capability-gated play/pause button — no way to jump
/// forward/back at all, and no shuffle/repeat for music either, since
/// neither existed as a concept anywhere in this file.
///
/// What renders now branches on the casted [MediaItem] itself, mirroring
/// the local player's own per-content-type layout (see
/// `PlayerControlsBar`/`CenterControls` in lib/player/widgets/) instead
/// of one generic row for everything:
/// - **audio** (`MediaItem.audioOnly`): shuffle · previous · play/pause ·
///   next · repeat — the same five controls `PlayerControlsBar` shows
///   locally, wired to `CastManager` instead of `PlaybackQueue`.
/// - **live TV** (`MediaItem.live`): -10s · play/pause · +10s.
/// - **an episode** (`seriesId`/`episodeNumber` set): -10s ·
///   [previous episode] · play/pause · [next episode] · +10s — the
///   episode-skip buttons always render for episode content (never
///   hidden), faded to white24 and disabled at the first/last episode
///   of the season/series queue, exactly like the local player's own
///   `CenterControls` previous/next-episode buttons. Not gated on
///   `capability.previous`/`capability.next`: those reflect whether the
///   *transport* can drive its own loaded queue, but the skip itself
///   goes through `PlaybackCoordinator.castNext`/`castPrevious`, which
///   drives `PlaybackQueue` and sends the sibling episode as a fresh
///   single-item load — see that method's own doc comment for why a
///   transport-native next/previous can't be trusted here.
/// - **anything else** (a standalone movie): -10s · play/pause · +10s.
///
/// Every command actually reaches the connected target: seek±10 goes
/// through `CastManager.seek()` (the same absolute-seek command the
/// seek bar already uses, just computed from the session's own live
/// `position`/`duration` rather than typed in); next/previous for both
/// audio and episode video go through `PlaybackCoordinator.castNext()`/
/// `castPrevious()`, which drive `PlaybackQueue` and send the sibling
/// item as a fresh single-item load rather than trusting the connected
/// target's own queue (falling back to `CastManager.next()`/`previous()`
/// only when there's genuinely nothing in `PlaybackQueue` to advance
/// to); and shuffle/repeat go through `CastManager.toggleShuffle()`/
/// `cycleRepeatMode()`.
///
/// Colors are the same castGold/white pair the local video and audio
/// player screens already use — `CenterControls`/`PlayerControlsBar`'s
/// own `_gold = 0xffD4AF37` is bit-for-bit identical to [castGold] — not
/// a separate, more-translucent "casting UI" palette. A control that
/// genuinely can't run right now (unsupported by the connected target)
/// renders at the same reduced-opacity white24 the local player already
/// uses for its own disabled next/previous, rather than the whole panel
/// reading as vaguely faded because most of it renders as nothing.
class CastTransportControls extends StatelessWidget {
  const CastTransportControls({
    super.key,
    required this.session,
    required this.capability,
    this.fullscreen = true,
  });

  final CastSession session;
  final CastCapability capability;

  /// Bigger icons for `CastingActivePanel`'s fullscreen panel; smaller
  /// for the connected-session sheet — matches the two surfaces' own
  /// previous, separately hand-tuned sizes (56/32 vs 46/28) exactly,
  /// rather than introducing a third scale.
  final bool fullscreen;

  double get _playSize => fullscreen ? 56 : 46;
  double get _navSize => fullscreen ? 32 : 28;

  @override
  Widget build(BuildContext context) {
    final manager = CastManager.instance;

    return ValueListenableBuilder<MediaItem?>(
      valueListenable: session.currentItem,
      builder: (context, item, __) {
        if (item != null && item.audioOnly) {
          return _AudioRow(
            manager: manager,
            session: session,
            capability: capability,
            playSize: _playSize,
            navSize: _navSize,
          );
        }

        final isEpisode = item != null &&
            (item.seriesId != null || item.episodeNumber != null);

        return _VideoRow(
          manager: manager,
          session: session,
          capability: capability,
          showEpisodeSkip: isEpisode,
          playSize: _playSize,
          navSize: _navSize,
        );
      },
    );
  }
}

class _AudioRow extends StatelessWidget {
  const _AudioRow({
    required this.manager,
    required this.session,
    required this.capability,
    required this.playSize,
    required this.navSize,
  });

  final CastManager manager;
  final CastSession session;
  final CastCapability capability;
  final double playSize;
  final double navSize;

  @override
  Widget build(BuildContext context) {
    final shuffleRepeatSize = navSize * 0.75;

    // CASTING FIX (shuffle/repeat looked permanently disabled; next/
    // previous ended playback instead of advancing): all four of these
    // used to be gated on `capability.shuffle/repeat/next/previous` —
    // whether the *connected target itself* reports Jellyfin's
    // `SetShuffleQueue`/`SetRepeatMode` general commands, or
    // `SupportsMediaControl` for next/previous. That's the wrong thing to
    // gate on here: this app already owns the actual queue order (it's
    // what built the list `CastManager.playQueue()`/`loadAndPlay()` sent
    // in the first place), so shuffle/repeat/next/previous for an audio
    // cast session drive `PlaybackQueue.instance` — the exact same queue
    // the Queue screen and local playback already use — directly,
    // through `PlaybackCoordinator`, instead of depending on the
    // receiver's own command support or its own (frequently unreliable —
    // see `PlaybackCoordinator.castNext`'s doc comment) internal queue
    // navigation. That also means these four are never actually disabled
    // for audio: shuffling/repeating the app's own upcoming list, and
    // deciding what "next"/"previous" means, never needed the target's
    // permission to begin with.
    final queue = PlaybackQueue.instance;

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        ValueListenableBuilder<bool>(
          valueListenable: queue.shuffleNotifier,
          builder: (context, shuffled, __) {
            return IconButton(
              onPressed: queue.shuffle,
              icon: Icon(
                Icons.shuffle,
                color: shuffled ? castGold : Colors.white,
                size: shuffleRepeatSize,
              ),
            );
          },
        ),
        // Previous always does something now, matching the local
        // PlayerControlsBar's own "Previous always does something"
        // button — PlaybackCoordinator.castPrevious restarts the current
        // track if there's nowhere earlier to go, so there's no
        // meaningful "disabled" state for it.
        IconButton(
          onPressed: () => runCastCommand(
            context,
            PlaybackCoordinator.instance.castPrevious,
          ),
          icon: Icon(
            Icons.skip_previous,
            color: Colors.white,
            size: navSize,
          ),
        ),
        _PlayPauseButton(
          session: session,
          manager: manager,
          capability: capability,
          size: playSize,
        ),
        AnimatedBuilder(
          animation: Listenable.merge(
              [queue.currentIndexNotifier, queue.queueNotifier]),
          builder: (context, _) {
            final enabled = queue.hasNext;
            return IconButton(
              onPressed: enabled
                  ? () => runCastCommand(
                        context,
                        PlaybackCoordinator.instance.castNext,
                      )
                  : null,
              icon: Icon(
                Icons.skip_next,
                color: enabled ? Colors.white : Colors.white24,
                size: navSize,
              ),
            );
          },
        ),
        ValueListenableBuilder<QueueRepeatMode>(
          valueListenable: queue.repeatModeNotifier,
          builder: (context, mode, __) {
            return IconButton(
              onPressed: queue.cycleRepeatMode,
              icon: Icon(
                mode == QueueRepeatMode.one ? Icons.repeat_one : Icons.repeat,
                color: mode == QueueRepeatMode.off ? Colors.white : castGold,
                size: shuffleRepeatSize,
              ),
            );
          },
        ),
      ],
    );
  }
}

class _VideoRow extends StatelessWidget {
  const _VideoRow({
    required this.manager,
    required this.session,
    required this.capability,
    required this.showEpisodeSkip,
    required this.playSize,
    required this.navSize,
  });

  final CastManager manager;
  final CastSession session;
  final CastCapability capability;
  final bool showEpisodeSkip;
  final double playSize;
  final double navSize;

  void _seekRelative(BuildContext context, int seconds) {
    final duration = session.duration.value;
    final target = session.position.value + Duration(seconds: seconds);
    final clamped = target.isNegative
        ? Duration.zero
        : (duration > Duration.zero && target > duration ? duration : target);
    runCastCommand(context, () => manager.seek(clamped));
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton(
          onPressed:
              capability.seek ? () => _seekRelative(context, -10) : null,
          icon: Icon(
            Icons.replay_10,
            color: capability.seek ? Colors.white : Colors.white24,
            size: navSize,
          ),
        ),
        if (showEpisodeSkip) _PreviousEpisodeButton(navSize: navSize),
        _PlayPauseButton(
          session: session,
          manager: manager,
          capability: capability,
          size: playSize,
        ),
        if (showEpisodeSkip) _NextEpisodeButton(navSize: navSize),
        IconButton(
          onPressed: capability.seek ? () => _seekRelative(context, 10) : null,
          icon: Icon(
            Icons.forward_10,
            color: capability.seek ? Colors.white : Colors.white24,
            size: navSize,
          ),
        ),
      ],
    );
  }
}

/// EPISODE NAV FIX — always rendered for episode content (see this
/// file's own class doc comment for why it's no longer gated on
/// `capability.previous`), faded/disabled via [PlaybackQueue.hasPrevious]
/// rather than hidden when there's no earlier episode to go to. Rebuilds
/// on [PlaybackQueue.currentIndexNotifier] so the fade updates the
/// instant the queue advances — same reactive pattern the local player's
/// `CenterControls` already uses for its own previous/next-episode
/// buttons.
class _PreviousEpisodeButton extends StatelessWidget {
  const _PreviousEpisodeButton({required this.navSize});

  final double navSize;

  @override
  Widget build(BuildContext context) {
    final queue = PlaybackQueue.instance;
    return ValueListenableBuilder<int>(
      valueListenable: queue.currentIndexNotifier,
      builder: (context, __, ___) {
        final enabled = queue.hasPrevious;
        return IconButton(
          onPressed: enabled
              ? () => runCastCommand(
                    context,
                    PlaybackCoordinator.instance.castPrevious,
                  )
              : null,
          icon: Icon(
            Icons.skip_previous,
            color: enabled ? Colors.white : Colors.white24,
            size: navSize,
          ),
        );
      },
    );
  }
}

/// Next-episode counterpart to [_PreviousEpisodeButton] — see that
/// class's doc comment.
class _NextEpisodeButton extends StatelessWidget {
  const _NextEpisodeButton({required this.navSize});

  final double navSize;

  @override
  Widget build(BuildContext context) {
    final queue = PlaybackQueue.instance;
    return ValueListenableBuilder<int>(
      valueListenable: queue.currentIndexNotifier,
      builder: (context, __, ___) {
        final enabled = queue.hasNext;
        return IconButton(
          onPressed: enabled
              ? () => runCastCommand(
                    context,
                    PlaybackCoordinator.instance.castNext,
                  )
              : null,
          icon: Icon(
            Icons.skip_next,
            color: enabled ? Colors.white : Colors.white24,
            size: navSize,
          ),
        );
      },
    );
  }
}

class _PlayPauseButton extends StatelessWidget {
  const _PlayPauseButton({
    required this.session,
    required this.manager,
    required this.capability,
    required this.size,
  });

  final CastSession session;
  final CastManager manager;
  final CastCapability capability;
  final double size;

  @override
  Widget build(BuildContext context) {
    // PLAY/PAUSE FLICKER FIX: bound to `showsPlaying`, not the raw
    // playback state — see CastSession.showsPlaying.
    return ValueListenableBuilder<bool>(
      valueListenable: session.showsPlaying,
      builder: (context, playing, __) {
        final canToggle = playing ? capability.pause : capability.play;
        return IconButton(
          // The primary control a remote's D-pad should land on first
          // when this row appears. Safe unconditionally: this
          // IconButton's Element persists across this
          // ValueListenableBuilder's own rebuilds (same Element reused
          // each time playbackState flips), so `autofocus` only ever
          // actually fires once, the first time this row mounts.
          autofocus: true,
          onPressed: canToggle
              ? () => runCastCommand(context, manager.togglePlayPause)
              : null,
          icon: Icon(
            playing ? Icons.pause_circle_filled : Icons.play_circle_fill,
            color: canToggle ? castGold : Colors.white24,
          ),
          iconSize: size,
        );
      },
    );
  }
}
