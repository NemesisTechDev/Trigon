import 'package:flutter/material.dart';
import '../../player/player_manager.dart';
import '../../player/helpers/pip_helper.dart';
import '../../player/helpers/display_helper.dart';
import '../models/media_item.dart';
import '../services/playback_queue.dart';
import '../../utils/responsive.dart';
import '../../casting/cast_manager.dart';
import '../../casting/models/cast_session.dart';
import '../../casting/ui/cast_button.dart';
import '../../widgets/common/measure_size.dart';


class PlayerTopBar extends StatefulWidget {
  const PlayerTopBar({
    super.key,
  });

  @override
  State<PlayerTopBar> createState() => _PlayerTopBarState();
}

class _PlayerTopBarState extends State<PlayerTopBar> {
  // Whether PiP is actually wired up on this platform/build. Checked
  // once and cached — PlayerTopBar rebuilds frequently (every time
  // controls toggle, lock state changes, etc.), and this shouldn't
  // re-query the platform channel on every one of those.
  bool _pipSupported = false;

  @override
  void initState() {
    super.initState();

    PiPHelper.isSupported.then((supported) {
      if (mounted) {
        setState(() => _pipSupported = supported);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final manager = PlayerManager.instance;

    // No SafeArea here: DisplayHelper already forces immersive
    // fullscreen for this screen, but SafeArea still pads against
    // MediaQuery's reported insets — which some Android devices keep
    // non-zero (a reserved gesture-nav "swipe to reveal" zone) even
    // while those bars are hidden. That was adding a second inset on
    // top of the video's own letterbox bars, making the controls look
    // boxed into a smaller frame instead of reaching the true screen
    // edges. A small fixed padding gives the same breathing room
    // without depending on that.
    //
    // Only true while actually fullscreen, though — in windowed
    // portrait mode the system status bar is back (edgeToEdge), and
    // that same small fixed padding let the controls sit right under
    // it/the notch. There, pad down by the real status bar height on
    // top of the usual breathing room instead.
    return ValueListenableBuilder<bool>(
      valueListenable: manager.isFullscreen,
      builder: (_, fullscreenForPadding, __) {
        // Aspect-scoped (MediaQuery.paddingOf) instead of the unscoped
        // MediaQuery.of(context) this used to call — that subscribed
        // this bar to every MediaQueryData field, including
        // viewInsets.bottom, which flips on every frame while any
        // keyboard animates (most commonly the "Search online" subtitle
        // sheet opened from this same player screen). paddingOf only
        // rebuilds when the actual top safe-area inset changes.
        final topPadding = fullscreenForPadding
            ? 16.0
            : (MediaQuery.paddingOf(context).top - 8.0).clamp(0.0, double.infinity);

        // TV is remote-navigated, not touched — every icon button in
        // this bar and the title text get a deliberate bump rather than
        // the phone-tuned IconButton default (~24px), same
        // Responsive.isTV pattern used across the rest of the player
        // control surface. Phone/tablet keep the original numbers.
        final iconSize = Responsive.isTV ? 34.0 : 24.0;
        final titleFontSize = Responsive.isTV ? 24.0 : 18.0;

        // Reports this bar's real rendered height (top padding + the
        // icon/title row + bottom padding, all together) so
        // PlayerOverlayLayer can reserve exactly that much room above
        // the Next Episode/Next Movie card in landscape instead of a
        // guessed constant — see PlayerManager.topBarHeight's doc
        // comment for why a fixed value couldn't track this.
        return MeasureSize(
          onChange: (size) {
            manager.topBarHeight.value = size.height;
          },
          child: Container(
      padding: EdgeInsets.only(
        left: 12,
        right: 12,
        top: topPadding,
        bottom: 10,
      ),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.black.withValues(alpha: 0.85),
              Colors.transparent,
            ],
          ),
        ),
        // Overflow fix: with enough buttons showing (PiP, episode list,
        // cast, fullscreen, lock) the fixed 48dp tap targets outgrew a
        // narrow/enlarged-display screen and the title's Expanded
        // collapsed to nothing. The right-hand action group now scales
        // down (never past what leaves a sliver for the title) instead
        // of overflowing.
        child: LayoutBuilder(
          builder: (context, constraints) {
            final actionsMaxWidth =
                (constraints.maxWidth - 48 - 72).clamp(0.0, double.infinity);

            return Row(
          children: [

            IconButton(
              iconSize: iconSize,
              onPressed: () {
                // maybePop: PlayerExitScope turns the phone to portrait first,
                // then pops (see PlayerOrientation).
                Navigator.maybePop(context);
              },
              icon: const Icon(
                Icons.arrow_back,
                color: Colors.white,
              ),
            ),

            // Casting fix: this used to read `manager.currentItemNotifier`
            // unconditionally, which is local playback's own (paused,
            // frozen-at-handoff-time) current item. PlaybackCoordinator
            // deliberately doesn't mirror that notifier for a video cast
            // (see its own isMirroringAudio doc comment) — so the title
            // just sat on whatever was last playing locally no matter what
            // changed on the TV afterward (a new episode picked from the
            // episode panel, CastTransportControls' next/previous, or the
            // receiver advancing its own queue). Reading the cast
            // session's own `currentItem` instead whenever a video is
            // actively being cast keeps this in sync with whatever's
            // really on screen on the TV, regardless of how it got there.
            Expanded(
              child: ValueListenableBuilder<CastSession?>(
                valueListenable: CastManager.instance.activeSession,
                builder: (_, session, __) {
                  return ValueListenableBuilder<MediaItem?>(
                    valueListenable: manager.currentItemNotifier,
                    builder: (_, localItem, __) {
                      if (session != null) {
                        return ValueListenableBuilder<MediaItem?>(
                          valueListenable: session.currentItem,
                          builder: (_, castItem, __) {
                            final castingVideo = session.isConnected &&
                                castItem != null &&
                                !castItem.audioOnly;

                            final title = castingVideo
                                ? castItem.title
                                : (localItem?.title ?? "");

                            return Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: titleFontSize,
                              ),
                            );
                          },
                        );
                      }

                      return Text(
                        localItem?.title ?? "",
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: titleFontSize,
                        ),
                      );
                    },
                  );
                },
              ),
            ),

            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: actionsMaxWidth),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerRight,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [

            // Hidden rather than shown-disabled when PiP isn't wired up
            // on this platform/build — a button that looks tappable but
            // silently does nothing is worse than no button at all.
            if (_pipSupported)
              IconButton(
                iconSize: iconSize,
                onPressed: () async {
                  await PiPHelper.enterPiP();
                },
                icon: const Icon(
                  Icons.picture_in_picture_alt,
                  color: Colors.white,
                ),
              ),

            // Rebuilds off the queue itself (rather than reading
            // PlaybackQueue.instance.source once at build time) so the
            // button reflects reality even when playback was kicked off
            // from Continue Watching/the hero carousel — those start
            // this screen immediately, then fill in the real season
            // queue (and its `source`) a moment later once the network
            // call resolves. Reading `source` only on the first build
            // meant the button could permanently miss appearing for
            // whichever shows happened to still be loading their queue
            // at that point, while shows whose queue was already ready
            // showed it fine — hence the inconsistency.
            ValueListenableBuilder<List<MediaItem>>(
              valueListenable: PlaybackQueue.instance.queueNotifier,
              builder: (_, __, ___) {
                final isEpisodeContent =
                    PlaybackQueue.instance.source == PlaybackSource.season ||
                        PlaybackQueue.instance.source == PlaybackSource.series;

                if (!isEpisodeContent) {
                  return const SizedBox.shrink();
                }

                return ValueListenableBuilder<bool>(
                  valueListenable: manager.showEpisodeList,
                  builder: (_, open, __) {
                    return IconButton(
                      iconSize: iconSize,
                      onPressed: () {
                        manager.showEpisodeList.value = !open;
                      },
                      icon: Icon(
                        open ? Icons.menu_open : Icons.playlist_play,
                        color: Colors.white,
                      ),
                    );
                  },
                );
              },
            ),

            // Channel-list toggle — only shown while a live channel is
            // playing, mirroring how the episode-list button above only
            // appears for season/series playback.
            ValueListenableBuilder<MediaItem?>(
              valueListenable: manager.currentItemNotifier,
              builder: (_, item, __) {
                if (item == null || !item.live) {
                  return const SizedBox.shrink();
                }

                return ValueListenableBuilder<bool>(
                  valueListenable: manager.showChannelList,
                  builder: (_, open, __) {
                    return IconButton(
                      iconSize: iconSize,
                      onPressed: () {
                        manager.showChannelList.value = !open;
                      },
                      icon: Icon(
                        open ? Icons.close_fullscreen : Icons.live_tv,
                        color: Colors.white,
                      ),
                    );
                  },
                );
              },
            ),

            // Cast — primary location per the casting master prompt.
            // Sits here rather than after Fullscreen/Lock so it's not
            // the last thing a thumb reaches while the bar is mid-hide;
            // reflects live connect/casting state itself (see
            // CastButton), so this doesn't need its own
            // ValueListenableBuilder wrapper the way the buttons above
            // do for their own state.
            CastButton(iconSize: iconSize),

            ValueListenableBuilder<bool>(
              valueListenable: manager.isFullscreen,
              builder: (_, isFullscreen, __) {
                return IconButton(
                  iconSize: iconSize,
                  onPressed: () async {
                    if (isFullscreen) {
                      // Leaving fullscreen should also drop the forced
                      // landscape lock and return to portrait, not just
                      // bring the system bars back.
                      await DisplayHelper.exitFullscreen();
                    } else {
                      await DisplayHelper.enterFullscreen();
                    }

                    manager.isFullscreen.value = !isFullscreen;
                  },
                  icon: Icon(
                    isFullscreen
                        ? Icons.fullscreen_exit
                        : Icons.fullscreen,
                    color: Colors.white,
                  ),
                );
              },
            ),

            IconButton(
              iconSize: iconSize,
              onPressed: () {
                manager.isLocked.value = true;
              },
              icon: const Icon(
                Icons.lock_open,
                color: Colors.white,
              ),
            ),
                  ],
                ),
              ),
            ),
          ],
            );
          },
        ),
        ),
        );
      },
    );
  }
}
