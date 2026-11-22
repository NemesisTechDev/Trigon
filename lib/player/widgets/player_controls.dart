import 'package:flutter/material.dart';

import '../../casting/cast_manager.dart';
import '../../casting/models/cast_session.dart';
import '../../casting/playback_coordinator.dart';
import '../../casting/ui/casting_active_panel.dart';
import '../../utils/responsive.dart';
import '../models/media_item.dart';
import 'player_top_bar.dart';
import 'player_bottom_bar.dart';
import 'center_controls.dart';

class PlayerControls extends StatelessWidget {
  const PlayerControls({
    super.key,
    required this.visible,
  });

  final bool visible;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
        child: Stack(
          children: [
            // Casting Phase 14: CenterControls and PlayerBottomBar are
            // now cast-aware in their own right (each branches on
            // CastManager.instance.activeSession itself, the same
            // pattern PlayerControlsBar already uses for the audio
            // player) rather than being swapped out wholesale for
            // CastingActivePanel's fullscreen panel. That panel's flat
            // black backdrop + generic media card is gone from this
            // screen entirely — CastingBackdrop (painted behind
            // PlayerControls, back in VideoPlayerScreen) takes over
            // showing something on screen, and these two keep
            // rendering the real control chrome (episode list toggle,
            // Fit/Audio/Subtitle/Speed/Info, seek bar) throughout,
            // exactly as they do for local playback.
            const Align(
              alignment: Alignment.center,
              child: CenterControls(),
            ),

            // The compact "Casting to X" banner — device name + entry
            // point into the full connected-session sheet — same widget
            // AudioPlayerScreen already shows under its own controls bar
            // for the identical reason: PlayerTopBar's Cast button
            // already reflects *that* something is casting, but not
            // *what device*, and CenterControls/PlayerBottomBar no
            // longer show a dedicated casting surface of their own now
            // that they render the normal controls throughout.
            //
            // Z-ORDER FIX (seek thumbnail drew BEHIND this banner): the
            // trickplay preview floats up out of PlayerBottomBar's seek
            // bar, so the banner has to be painted BEFORE the bottom bar
            // for the preview to land in front of it.
            const _CastingConnectedBanner(),

            const Align(
              alignment: Alignment.bottomCenter,
              child: PlayerBottomBar(),
            ),

            // PlayerTopBar (back button, and the Cast button itself for
            // reaching "switch device"/"disconnect") always paints last —
            // and therefore stays visible and tappable/D-pad-focusable —
            // on top of everything above, since leaving this screen or
            // managing the session are both still meaningful while
            // casting.
            const Align(
              alignment: Alignment.topCenter,
              child: PlayerTopBar(),
            ),
          ],
        ),
      ),
    );
  }
}

/// The compact "Casting to X" banner shown while this screen is casting.
///
/// VISIBILITY FIX ("Connected to X" bar not appearing consistently): this
/// used to gate purely on `PlaybackCoordinator.instance.isHandoffActive`,
/// which is only ever true for a cast that *started as a local->TV
/// handoff*. A direct "Cast to" opened from a details screen
/// (CastToButton) lands here with an already-connected session and never
/// sets that flag at all — `VideoPlayerScreen._isCastingVideoActive()`
/// already had to work around this exact gap for the top bar/
/// tap-to-toggle-controls logic, via the same broader check this widget
/// now uses: visible whenever a handoff is active OR there's a connected
/// cast session with a real (non-audio-only) item loaded. That's what
/// made the banner read as "sometimes doesn't appear" — it depended
/// entirely on *how* this screen ended up casting, not on whether it
/// actually was.
///
/// PORTRAIT POSITION FIX: in portrait, `PlayerTopBar`'s back button/title
/// row (plus the real status bar inset it pads for — see its own doc
/// comment) sits taller than the fixed `top: 72` this banner used
/// everywhere, so the two overlapped and the top bar drew over/behind
/// this banner. Landscape/fullscreen keeps the original offset (the top
/// bar there uses its fixed 16 + safe-area-free padding, which `top: 72`
/// already clears); portrait pushes the banner down further so it always
/// sits below the top bar instead of under it.
class _CastingConnectedBanner extends StatelessWidget {
  const _CastingConnectedBanner();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: PlaybackCoordinator.instance.isHandoffActive,
      builder: (_, handoffActive, __) {
        return ValueListenableBuilder<CastSession?>(
          valueListenable: CastManager.instance.activeSession,
          builder: (_, session, __) {
            if (session == null) {
              return handoffActive
                  ? _buildBanner(context)
                  : const SizedBox.shrink();
            }

            // A direct "Cast to" connects the session first and only
            // gets a `currentItem` a moment later (see this widget's own
            // doc comment) — rebuilding on it means the banner appears
            // the instant that item lands, without needing
            // `isHandoffActive` to ever flip for that path.
            return ValueListenableBuilder<MediaItem?>(
              valueListenable: session.currentItem,
              builder: (_, item, __) {
                final showForDirectCast =
                    session.isConnected && item != null && !item.audioOnly;

                if (!handoffActive && !showForDirectCast) {
                  return const SizedBox.shrink();
                }

                return _buildBanner(context);
              },
            );
          },
        );
      },
    );
  }

  Widget _buildBanner(BuildContext context) {
    final portrait = !Responsive.isLandscape(context);

    return Align(
      alignment: Alignment.topCenter,
      child: Padding(
        padding: EdgeInsets.only(
          top: portrait ? 108 : 72,
          left: 24,
          right: 24,
        ),
        child: const CastingActivePanel(fullscreen: false),
      ),
    );
  }
}