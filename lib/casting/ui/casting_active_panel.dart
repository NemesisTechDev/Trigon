import 'package:flutter/material.dart';

import '../cast_manager.dart';
import '../models/cast_capability.dart';
import '../models/cast_session.dart';
import '../models/cast_states.dart';
import '../../widgets/common/pressable.dart';
import 'cast_seek_bar.dart';
import 'cast_transport_controls.dart';
import 'cast_ui.dart';
import 'casting_media_card.dart';
import 'connected_session_sheet.dart';

/// CASTING PHASE 8 — the "casting, tap to control" surface local-playback
/// screens swap in once [PlaybackCoordinator] has handed their content off
/// to a TV, instead of continuing to show controls for a video/audio
/// stream that isn't actually rendering to this screen anymore.
///
/// Purely a display/control widget over [CastManager] — same "no screen
/// imports a concrete transport, everything comes through CastManager"
/// rule every other casting UI file (Phase 7) already follows. Reads
/// `CastManager.instance.activeSession` itself rather than taking one as
/// a constructor parameter, matching `CastButton`'s own self-contained
/// pattern, so callers (`VideoPlayerScreen`) don't need to thread a
/// session through — they only need to know *whether* to show this at
/// all, via `PlaybackCoordinator.instance.isHandoffActive`.
///
/// Two shapes, chosen by [fullscreen]:
/// - `fullscreen: true` (`VideoPlayerScreen`) — occupies the whole
///   controls area: big transport row, seek slider, "Manage" entry into
///   the existing connected-session sheet for switch-device/disconnect.
/// - `fullscreen: false` (`AudioPlayerScreen`) — a compact banner:
///   device name + play/pause only, tapping anywhere opens the full
///   connected-session sheet for everything else. Deliberately not a
///   full transport rewrite of the Now Playing screen — see that
///   screen's own doc comment on why this stays a banner rather than
///   replacing `PlayerControlsBar` there.
class CastingActivePanel extends StatelessWidget {
  const CastingActivePanel({
    super.key,
    this.fullscreen = true,
  });

  final bool fullscreen;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<CastSession?>(
      valueListenable: CastManager.instance.activeSession,
      builder: (context, session, __) {
        // The session ended (TV lost, disconnected elsewhere) while this
        // was showing — PlaybackCoordinator's own isHandoffActive
        // listener will already be flipping the caller back to normal
        // local controls on the same frame; render nothing in the
        // meantime rather than a stale panel for a session that's gone.
        if (session == null) return const SizedBox.shrink();

        return fullscreen
            ? _FullscreenPanel(session: session)
            : _CompactBanner(session: session);
      },
    );
  }
}

class _FullscreenPanel extends StatelessWidget {
  const _FullscreenPanel({required this.session});

  final CastSession session;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black,
      alignment: Alignment.center,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Casting Phase 13: this used to be a generic centered
              // icon + "Casting to X" + item title stack, identical
              // regardless of whether a movie, episode, or live channel
              // was actually on the TV. CastingMediaCard reuses
              // MiniPlayer's own poster/logo + title/subtitle row
              // instead, with per-content-type fields (movie: poster +
              // title; episode: poster + season/episode + show/episode
              // name; live channel: logo + channel name + current
              // program), and folds the casting indicator (icon +
              // device name) into it rather than showing that
              // separately above.
              CastingMediaCard(session: session),
              // Casting Phase 12: a Jellyfin Remote/Nemesis Native target
              // has its own signed-in Jellyfin account, which can
              // genuinely differ from whoever's casting from this phone
              // — worth surfacing here so it's not a surprise which
              // account's watch history/continue-watching this session
              // is actually updating. Null for Google Cast (no Jellyfin
              // identity of its own) and for a session whose transport
              // never reported one.
              if (session.device.userName != null) ...[
                const SizedBox(height: 8),
                Text(
                  'Signed in as ${session.device.userName}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white38, fontSize: 12),
                ),
              ],
              const SizedBox(height: 6),
              ValueListenableBuilder<CastPlaybackState>(
                valueListenable: session.playbackState,
                builder: (_, state, __) => Text(
                  castPlaybackLabel(state),
                  style: const TextStyle(color: Colors.white54, fontSize: 13),
                ),
              ),
              const SizedBox(height: 28),
              ValueListenableBuilder<CastCapability>(
                valueListenable: session.capabilityNotifier,
                builder: (context, capability, __) {
                  return Column(
                    children: [
                      CastSeekBar(session: session, capability: capability),
                      const SizedBox(height: 8),
                      CastTransportControls(
                        session: session,
                        capability: capability,
                      ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 32),
              OutlinedButton.icon(
                onPressed: () => showConnectedCastSheet(context),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: BorderSide(color: Colors.white.withOpacity(.25)),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(24),
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 10,
                  ),
                ),
                icon: const Icon(Icons.tune, size: 18),
                label: const Text('Manage cast session'),
              ),
            ],
          ),
        ),
      ),
    );
  }

}

class _CompactBanner extends StatelessWidget {
  const _CompactBanner({required this.session});

  final CastSession session;

  @override
  Widget build(BuildContext context) {
    final manager = CastManager.instance;

    // Casting Phase 9 fix: this was a bare GestureDetector, which
    // (unlike InkWell/Pressable) never gets a FocusNode of its own — on
    // Android TV, D-pad traversal would skip over this banner entirely,
    // making "open the full session controls" unreachable without a
    // touchscreen. Pressable is this app's own established replacement
    // for exactly this situation (see its doc comment) and, unlike
    // `unconstrained: true`, the default (Material+InkWell) variant used
    // here is what actually restores focus/D-pad activation — the
    // ripple it adds is a strict improvement over the previous
    // no-feedback-at-all GestureDetector, not a redesign of this row.
    return Pressable(
      borderRadius: BorderRadius.circular(14),
      onTap: () => showConnectedCastSheet(context),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: castRowBg,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            Icon(
              castTransportIcon(session.transportKind),
              color: castGold,
              size: 18,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Casting to ${session.device.displayName}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 13),
              ),
            ),
            ValueListenableBuilder<CastCapability>(
              valueListenable: session.capabilityNotifier,
              builder: (context, capability, __) {
                return ValueListenableBuilder<bool>(
                  valueListenable: session.showsPlaying,
                  builder: (context, playing, __) {
                    final canToggle =
                        playing ? capability.pause : capability.play;
                    return IconButton(
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      onPressed: canToggle
                          ? () =>
                              runCastCommand(context, manager.togglePlayPause)
                          : null,
                      icon: Icon(
                        playing ? Icons.pause : Icons.play_arrow,
                        color: canToggle ? castGold : Colors.white24,
                        size: 22,
                      ),
                    );
                  },
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
