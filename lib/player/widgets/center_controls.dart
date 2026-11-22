import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import '../player_manager.dart';
import '../models/media_item.dart';
import '../services/playback_queue.dart';
import '../../utils/responsive.dart';
import 'fit_row.dart';
import '../../casting/cast_manager.dart';
import '../../casting/models/cast_capability.dart';
import '../../casting/models/cast_session.dart';
import '../../casting/ui/cast_transport_controls.dart';

const _gold = Color(0xffD4AF37);

class CenterControls extends StatelessWidget {
  const CenterControls({super.key});

  @override
  Widget build(BuildContext context) {
    final manager = PlayerManager.instance;
    final player = manager.player;

    // Casting fix (Phase 14): this row used to always drive the local
    // player unconditionally, even once PlaybackCoordinator had paused
    // it and handed playback to a TV — tapping play here would have
    // resumed local playback right alongside the cast session, the
    // exact "double playback" bug PlayerControlsBar's own doc comment
    // already describes fixing for the audio player. Branches on
    // CastManager.instance.activeSession the same way that bar (and
    // MiniPlayer's play/pause button) already does: connected -> render
    // CastTransportControls (Casting Phase 12's own per-content-type
    // transport row, already wired to CastManager) instead of the local
    // rows below.
    return ValueListenableBuilder<CastSession?>(
      valueListenable: CastManager.instance.activeSession,
      builder: (context, session, __) {
        final casting = session?.isConnected ?? false;

        if (casting) {
          return ValueListenableBuilder<CastCapability>(
            valueListenable: session!.capabilityNotifier,
            builder: (context, capability, __) {
              return CastTransportControls(
                session: session,
                capability: capability,
                fullscreen: true,
              );
            },
          );
        }

        // Live channels get their own previous/next-CHANNEL row instead
        // of the on-demand seek/episode-skip row below — rebuilding on
        // both the current item (channel switched) and the channel
        // lineup (finished loading) so the skip buttons enable/fade
        // correctly.
        return ValueListenableBuilder<MediaItem?>(
          valueListenable: manager.currentItemNotifier,
          builder: (_, item, __) {
            if (item?.live ?? false) {
              return ValueListenableBuilder<List<Map<String, dynamic>>>(
                valueListenable: manager.liveChannels,
                builder: (_, __, ___) => _buildLiveRow(manager, player),
              );
            }

            final queue = PlaybackQueue.instance;

            // Next/previous EPISODE controls only make sense when
            // playing through a series/season queue — a standalone
            // movie or a single item has nothing to skip to.
            final isEpisodeContent =
                queue.source == PlaybackSource.season ||
                    queue.source == PlaybackSource.series ||
                    PlayerManager.isAddonEpisode(item);

            // Rebuild when the queue position changes so the
            // next/previous buttons correctly disappear at the
            // first/last episode instead of only updating on the next
            // unrelated rebuild.
            return ValueListenableBuilder<int>(
              valueListenable: queue.currentIndexNotifier,
              builder: (_, __, ___) =>
                  _buildRow(manager, player, isEpisodeContent),
            );
          },
        );
      },
    );
  }

  Widget _buildLiveRow(PlayerManager manager, Player player) {
    final hasPrevious = manager.hasPreviousChannel;
    final hasNext = manager.hasNextChannel;

    // TV is D-pad/remote-navigated, not touched, so the whole control
    // row gets a deliberate bump (icon sizes + spacing) rather than
    // keeping phone-tuned touch-target sizes — same Responsive.isTV
    // pattern used elsewhere (Home's row cards, the skip-segment
    // button). Phone/tablet keep the exact original numbers.
    final skipIconSize = Responsive.isTV ? 56.0 : 40.0;
    final playIconSize = Responsive.isTV ? 92.0 : 64.0;
    final spacing = Responsive.isTV ? 42.0 : 30.0;

    // Scales down instead of overflowing on an enlarged display.
    return FitRow(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton(
          iconSize: skipIconSize,
          color: hasPrevious ? _gold : _gold.withValues(alpha: 0.3),
          onPressed: hasPrevious ? manager.playPreviousChannel : null,
          icon: const Icon(Icons.skip_previous),
        ),

        SizedBox(width: spacing),

        ValueListenableBuilder(
          valueListenable: manager.playing,
          builder: (_, playing, _) {
            return IconButton(
              iconSize: playIconSize,
              color: Colors.white,
              onPressed: () {
                if (playing) {
                  player.pause();
                } else {
                  player.play();
                }
              },
              icon: Icon(
                playing ? Icons.pause_circle : Icons.play_circle,
              ),
            );
          },
        ),

        SizedBox(width: spacing),

        IconButton(
          iconSize: skipIconSize,
          color: hasNext ? _gold : _gold.withValues(alpha: 0.3),
          onPressed: hasNext ? manager.playNextChannel : null,
          icon: const Icon(Icons.skip_next),
        ),
      ],
    );
  }

  Widget _buildRow(
    PlayerManager manager,
    Player player,
    bool isEpisodeContent,
  ) {
    // Same TV-vs-touch reasoning as _buildLiveRow above.
    final seekIconSize = Responsive.isTV ? 58.0 : 42.0;
    final episodeIconSize = Responsive.isTV ? 50.0 : 36.0;
    final playIconSize = Responsive.isTV ? 92.0 : 64.0;
    final wideSpacing = Responsive.isTV ? 42.0 : 30.0;
    final narrowSpacing = Responsive.isTV ? 28.0 : 20.0;

    // Scales down instead of overflowing on an enlarged display.
    return FitRow(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [

        IconButton(
          iconSize: seekIconSize,
          color: Colors.white,
          onPressed: () {
            // Via PlayerManager so it also works on a transcoded
            // (Data Saver / Default) stream — see PlayerManager.seekTo.
            manager.seekBy(const Duration(seconds: -10));
          },
          icon: const Icon(Icons.replay_10),
        ),

        if (isEpisodeContent && manager.hasPrevious) ...[
          SizedBox(width: narrowSpacing),

          IconButton(
            iconSize: episodeIconSize,
            color: Colors.white,
            onPressed: manager.playPrevious,
            icon: const Icon(Icons.skip_previous),
          ),
        ],

        SizedBox(width: wideSpacing),

        ValueListenableBuilder(
          valueListenable: manager.playing,
          builder: (_, playing, _) {

            return IconButton(
              iconSize: playIconSize,
              color: Colors.white,
              onPressed: () {

                if (playing) {
                  player.pause();
                } else {
                  player.play();
                }

              },
              icon: Icon(
                playing
                    ? Icons.pause_circle
                    : Icons.play_circle,
              ),
            );

          },
        ),

        SizedBox(width: wideSpacing),

        if (isEpisodeContent && manager.hasNext) ...[
          IconButton(
            iconSize: episodeIconSize,
            color: Colors.white,
            onPressed: manager.playNext,
            icon: const Icon(Icons.skip_next),
          ),

          SizedBox(width: narrowSpacing),
        ],

        IconButton(
          iconSize: seekIconSize,
          color: Colors.white,
          onPressed: () {
            manager.seekBy(const Duration(seconds: 10));
          },
          icon: const Icon(Icons.forward_10),
        ),
      ],
    );
  }
}