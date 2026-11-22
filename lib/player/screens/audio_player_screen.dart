import 'package:flutter/material.dart';

import '../../casting/playback_coordinator.dart';
import '../../casting/ui/cast_button.dart';
import '../../casting/ui/casting_active_panel.dart';
import '../../casting/ui/cast_volume_control.dart';
import '../../player/player_manager.dart';
import '../models/media_item.dart';
import 'player_screen_registry.dart';

import '../widgets/player_accent_background.dart';
import '../widgets/player_controls_bar.dart';
import '../widgets/marquee_text.dart';
import '../screens/queue_screen.dart';
import '../screens/lyrics_screen.dart';
import '../../utils/app_fonts.dart';
import '../../utils/responsive.dart';
import '../../widgets/music/song_options_sheet.dart';
import '../../widgets/common/artwork_image.dart';

class AudioPlayerScreen extends StatefulWidget {
  const AudioPlayerScreen({
    super.key,
  });

  @override
  State<AudioPlayerScreen> createState() => _AudioPlayerScreenState();
}

class _AudioPlayerScreenState extends State<AudioPlayerScreen> {
  // This screen's own route, registered with PlayerScreenRegistry so an
  // Open With/Play With video replaces it instead of stacking on top.
  Route<dynamic>? _registeredRoute;

  // Gap between the album label's scroll area and the icon buttons on
  // either side of it in the portrait header: 3 logical px from the
  // back button's edge on the left, and 3 from the cast button's edge
  // on the right. The label's area is exactly what's left between
  // those two buttons.
  static const double _headerLabelGap = 3;

  // With the label area now sitting between the back button (one 48dp
  // button on its left) and the cast button (cast + menu = two 48dp
  // buttons on its right), the area's center is 24dp left of the
  // screen's center ((96 - 48) / 2). Short names that fit are nudged
  // back by this much so they stay centered on the screen, as before;
  // long names use the whole area and scroll.
  static const double _headerCenterShift = 24;

  // Landscape has only the back button in its header, so both sides
  // reserve a single 48dp target (plus a little breathing room) to keep
  // the album label centered on the screen.
  static const double _landscapeHeaderSideWidth = 64;

  @override
  void initState() {
    super.initState();
    PlayerManager.instance.currentItemNotifier.addListener(_onItemChanged);

    // Flips the mini player "on" once this screen has safely finished
    // its own first frame, rather than waiting for the pop to actually
    // happen (see the old comment that used to live where
    // onPopInvoked now sits below). That old timing worked fine for an
    // instant pop — the down-chevron or hardware back both fire their
    // pop synchronously, so there was time left for the Hero flight to
    // play out afterward. But an interactive back gesture (iOS-style
    // swipe, or Android's predictive-back) doesn't count as "popped"
    // until the drag is released, and by then the transition it was
    // meant to animate has already finished — so the mini player's
    // Hero-tagged artwork had nothing to fly into and just popped into
    // existence with no drop-down effect. Turning it on early instead
    // means the mini player (fully hidden behind this opaque, full-
    // screen scaffold either way) is already mounted with a matching
    // Hero well before any pop — button, hardware back, or gesture —
    // ever begins, so the same drop-down flight plays every time.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (PlayerManager.instance.currentItem != null) {
        PlayerManager.instance.showMiniPlayer.value = true;
      }
    });
  }

  @override
  void dispose() {
    PlayerScreenRegistry.unregister(_registeredRoute);
    PlayerManager.instance.currentItemNotifier
        .removeListener(_onItemChanged);
    super.dispose();
  }

  void _onItemChanged() {
    final item = PlayerManager.instance.currentItem;
    _exitIfQueueEnded(item);
  }

  // Re-checked any time this screen's "am I the visible route" status
  // changes — not just when the queue actually ends. Without this, a
  // screen that was covered by Lyrics/Queue at the exact moment the
  // queue ended would correctly skip popping itself (per the isCurrent
  // guard below), but then never got asked again once it *became*
  // current after the screen on top of it closed — leaving it stuck
  // showing its empty state instead of also closing in turn.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _registeredRoute ??= ModalRoute.of(context);
    PlayerScreenRegistry.register(_registeredRoute, PlayerScreenKind.audio);
    _exitIfQueueEnded(PlayerManager.instance.currentItem);
  }

  // The queue ran out on its own (repeat off, last song finished) —
  // PlayerManager.stop() has already deactivated the mini player, so
  // exit this screen too rather than leaving it sitting on an empty
  // black scaffold with nothing playing. Only pops if this screen is
  // still the one actually visible; if something (e.g. the queue
  // list) was pushed on top in the meantime, its own back button
  // handles getting back here instead.
  void _exitIfQueueEnded(MediaItem? item) {
    if (item != null || !mounted) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;

      final route = ModalRoute.of(context);

      if (route != null && route.isCurrent && Navigator.canPop(context)) {
        Navigator.pop(context);
      }
    });
  }

  // Opens the same three-dot menu song rows use (favorite, add to
  // playlist, add to queue, download, go to album/artist) for
  // whatever's currently playing. That sheet operates on the raw
  // Jellyfin map rather than the typed MediaItem, so this prefers
  // `item.raw` (present for anything loaded normally through
  // MediaService/DownloadManager) and only falls back to a
  // reconstructed minimal map — Id/Name/UserData.IsFavorite, enough
  // for favoriting/queueing/downloading even if "Go to Album/Artist"
  // and "Add to Playlist" have nothing extra to work with — for the
  // rare item that wasn't.
  void _openSongOptions(BuildContext context, MediaItem item) {
    final song = item.raw ??
        {
          "Id": item.id,
          "Name": item.title,
          "Album": item.subtitle,
          "UserData": {
            "IsFavorite": PlayerManager.instance.isFavorite.value,
          },
        };

    // This screen is itself a route stacked on the ROOT Navigator (see
    // MiniPlayer's tap handler), entirely above MainNavScreen and its
    // nav bar/mini player — captured here, before the sheet does
    // anything, so "Go to Album/Artist" can put this exact screen back
    // once the user backs out of wherever it sends them. See
    // showSongOptionsSheet's restoreFullScreenPlayer doc comment for
    // the full reasoning.
    final rootNavigator = Navigator.of(context, rootNavigator: true);

    showSongOptionsSheet(
      context,
      song,
      showSleepTimer: true,
      restoreFullScreenPlayer: () {
        rootNavigator.push(
          MaterialPageRoute(builder: (_) => const AudioPlayerScreen()),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final manager = PlayerManager.instance;

    return PopScope(
      // Fires for every way this screen can be popped — the down-chevron
      // button, an iOS-style edge swipe, or the OS back button/gesture —
      // since they all go through the same enclosing route's pop
      // machinery that PopScope hooks into. This runs as an ordinary
      // callback (safe timing), unlike setting the notifier from
      // dispose(), which runs mid-teardown of the popped route and can
      // silently fail to schedule the mini player's rebuild until
      // something else forces one.
      //
      // showMiniPlayer is normally already true by now (see initState),
      // this is just a safety net for the rare case this screen closes
      // before its first post-frame callback ran. Also drops focus one
      // more time on the way out — _BackGestureFocusObserver already
      // does this the instant a swipe/predictive-back gesture starts,
      // but an instant pop (button tap, hardware back) has no such
      // "gesture start" moment, so this is the equivalent guard for
      // those paths.
      onPopInvoked: (didPop) {
        if (!didPop) return;

        FocusManager.instance.primaryFocus?.unfocus();

        if (PlayerManager.instance.currentItem != null) {
          PlayerManager.instance.showMiniPlayer.value = true;
        }
      },
      child: Scaffold(
      backgroundColor: Colors.black,
      // This screen has no text field of its own, so it never needs to
      // shift for the keyboard. Without this, if the screen you
      // navigated from still has the keyboard open (or mid-close-
      // animation) when this screen is pushed, the Scaffold briefly
      // shrinks its body by the keyboard's height for a frame. The
      // Column below is non-scrolling (two Spacers sandwiching several
      // fixed-height children: artwork, title/subtitle, controls,
      // icon rows) so that momentary shrink is enough to overflow it —
      // producing the instant flash-and-recover render overflow you're
      // seeing, which clears itself once the keyboard finishes closing.
      resizeToAvoidBottomInset: false,

      body: Stack(
        children: [
          ValueListenableBuilder(
        valueListenable: manager.currentItemNotifier,
        builder: (context, item, _) {

          if (item == null) {
            return const SizedBox.shrink();
          }

          final isLandscape = Responsive.isLandscape(context);

          return PlayerAccentBackground(
            imageUrl: item.image,
            child: SafeArea(
              child: isLandscape
                  ? _buildLandscapeBody(context, item, manager)
                  : _buildPortraitBody(context, item, manager),
            ),
          );
        },
      ),

          // Surfaces playback failures (e.g. the stream failing to open)
          // right on this screen instead of a SnackBar back on whichever
          // screen the user tapped a song from — now that starting
          // playback pushes this screen immediately rather than waiting
          // on the network call to succeed first, this is the only place
          // left that reliably knows something went wrong.
          ValueListenableBuilder<String?>(
            valueListenable: manager.lastError,
            builder: (_, error, __) {
              if (error == null) return const SizedBox.shrink();

              return _AudioPlaybackErrorOverlay(
                message: error,
                onBack: () {
                  manager.lastError.value = null;
                  Navigator.of(context).pop();
                },
              );
            },
          ),
        ],
      ),
      ),
    );
  }

  // Artwork stacked above the title/artist block, seek bar, transport
  // controls, and the lyrics/queue row.
  //
  // FIT-TO-SCREEN (replaces the old CROP FIX / BLACK SCREEN FIX
  // scroll-based approach — read this before reintroducing a
  // SingleChildScrollView here): everything below the fixed header used
  // to be a `ConstrainedBox(minHeight: viewport) + Center` wrapped in a
  // `SingleChildScrollView`, so a short phone (or a taller phone with
  // larger display-size text inflating the title/controls) made the
  // whole block taller than the viewport and required scrolling past
  // the artwork just to reach the transport controls and the lyrics/
  // queue row pinned at the bottom of that block.
  //
  // The fix is to never let the content need more height than is
  // available in the first place, rather than to accommodate it
  // overflowing by scrolling. The artwork is the only element with
  // genuine room to give: it now sits in an `Expanded` flex slot whose
  // actual pixel size is measured via a nested `LayoutBuilder` and
  // clamped to whichever is smaller of the remaining width and the
  // remaining height, so it shrinks (rather than the Column overflowing)
  // on a short or small-height display. Every fixed-height element below
  // it — title/artist, favorite row, transport controls, lyrics/queue
  // row — keeps its natural size, and the vertical gaps between them
  // scale down together via `_scaledGap`, keyed off how much height this
  // screen actually has to work with, so a cramped display tightens up
  // uniformly instead of the artwork alone absorbing every constraint.
  // A generously tall screen gets the original spacing back unchanged
  // (the scale factor is clamped to 1.0 at the top end).
  Widget _buildPortraitBody(
    BuildContext context,
    MediaItem item,
    PlayerManager manager,
  ) {
    // The header's album label scrolls in the space between the back
    // button and the cast button — see the Row below.
    final albumName = item.raw?['Album']?.toString().trim() ?? '';

    return Column(
      children: [
        // Fixed header — pinned directly under SafeArea regardless of
        // whether the content below needs to scroll. This was already
        // effectively true before (it was the Column's first,
        // non-flexible child, with the leading Spacer() only ever
        // pushing whatever came AFTER it) — pulling it out into its own
        // always-visible slot here just makes that explicit instead of
        // implicit in a Spacer's behavior.
        const SizedBox(height: 10),

        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: SizedBox(
            height: 48,
            // The label's scroll area is exactly the space between the
            // back button and the cast button, with a 3px gap
            // (_headerLabelGap) to each. Long names auto-scroll inside
            // it (clipped at those edges, so they can never run under
            // either button); short names stay centered on the screen.
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(
                    Icons.keyboard_arrow_down,
                    color: Colors.white,
                    size: 30,
                  ),
                  onPressed: () {
                    Navigator.pop(context);
                  },
                ),

                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: _headerLabelGap,
                    ),
                    child: albumName.isEmpty
                        ? const SizedBox.shrink()
                        : Center(
                            child: MarqueeText(
                              albumName,
                              centered: true,
                              centerShift: _headerCenterShift,
                              style: const TextStyle(
                                color: Colors.white70,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                  ),
                ),

                // Cast button sits immediately to the left of the
                // three-dot song-options menu — same left-of-
                // more_vert placement used in the landscape
                // layout below.
                const CastButton(),

                IconButton(
                  icon: const Icon(
                    Icons.more_vert,
                    color: Colors.white,
                  ),
                  onPressed: () => _openSongOptions(context, item),
                ),
              ],
            ),
          ),
        ),

        // FIT-TO-SCREEN: the content below the header no longer scrolls
        // — it's sized to exactly fill whatever's left under the header,
        // every time. `_scaledGap` shrinks the fixed vertical gaps in
        // proportion to how little height this screen actually has, and
        // the artwork (the one element with real room to give) lives in
        // the `Expanded` below, sized down to whatever's left after
        // everything else claims its natural height. See the doc
        // comment above this method for the full reasoning.
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final gap = _scaledGap(constraints.maxHeight);

              return Column(
                children: [
                  Expanded(
                    flex: 5,
                    child: LayoutBuilder(
                      builder: (context, artConstraints) {
                        // Clearance on each side keeps the artwork off
                        // the true screen edges, same as the old fixed
                        // horizontal Padding did. The edge length is now
                        // whichever is smaller of the padded width and
                        // the height this flex slot actually got, so the
                        // artwork shrinks to fit a short screen instead
                        // of staying pinned to full width and pushing
                        // everything below it off-screen.
                        const horizontalPadding = 32.0;
                        final availableWidth =
                            artConstraints.maxWidth - horizontalPadding * 2;
                        final artSize = availableWidth < artConstraints.maxHeight
                            ? availableWidth
                            : artConstraints.maxHeight;
                        final clampedArtSize = artSize < 0 ? 0.0 : artSize;

                        return Center(
                          child: Hero(
                            tag: item.id,
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(20),
                              child: SizedBox(
                                width: clampedArtSize,
                                height: clampedArtSize,
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    item.image == null
                                        ? Container(
                                      color: Colors.grey.shade900,
                                      child: const Icon(
                                        Icons.music_note,
                                        size: 90,
                                        color: Colors.white,
                                      ),
                                    )
                                        : ArtworkImage(
                                      path: item.image!,
                                      fit: BoxFit.cover,
                                      errorBuilder: (_, __, ___) => Container(
                                        color: Colors.grey.shade900,
                                        child: const Icon(
                                          Icons.music_note,
                                          size: 90,
                                          color: Colors.white,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),

                  SizedBox(height: gap(30)),

                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Row(
                      // SPACE-BETWEEN-ARTIST-AND-SEEK-BAR FIX: the
                      // favorite heart used to live in its own dedicated Row below this block (Padding
                      // + Row(mainAxisAlignment.end) + a leading
                      // SizedBox(gap(20))) — a whole separate ~48dp-tall
                      // slot whose only content was the heart icon
                      // parked over on the right, empty everywhere else.
                      // That slot's height doesn't come from anything
                      // the title/artist text actually needs (there's no
                      // reservation for a long artist name — item.subtitle
                      // is a plain unconstrained Text that already just
                      // wraps to 2 lines and takes the real height that
                      // costs, same as any other text), so its ~48dp +
                      // gap(20) was a fixed tax on the vertical budget
                      // this Column hands out to its non-Expanded
                      // children before the artwork's Expanded(flex: 5)
                      // slot gets whatever's left over. On a larger
                      // display-size setting the title/subtitle text
                      // grows and eats more of that budget, the artwork
                      // shrinks to compensate, but this fixed slot never
                      // shrinks with it — so relatively more of the
                      // remaining band above the seek bar reads as
                      // "empty" the smaller the artwork gets.
                      //
                      // Folding the heart into THIS row instead — same
                      // title/subtitle Column, favorite button riding
                      // alongside it — is exactly the pattern
                      // _buildLandscapeBody already uses further down
                      // this file (see its own title/artist Row). A Row
                      // sizes to the taller of its two children, and the
                      // title+subtitle column is already taller than a
                      // single icon button, so the heart effectively
                      // adds ~0 extra height instead of a whole second
                      // dedicated row — reclaiming that fixed slot for
                      // the artwork's Expanded slot unconditionally,
                      // every device, not just a display-size-dependent
                      // nudge. The artwork's own `artSize = min
                      // (availableWidth, artConstraints.maxHeight)` cap
                      // (above) is untouched, so once freed height pushes
                      // the artwork up against the horizontal padding
                      // limit, it still stops growing there exactly as
                      // it always has.
                      //
                      // Row defaults to spanning the full available
                      // width on its own (mainAxisSize.max), so the
                      // SizedBox(width: double.infinity) the old Column-
                      // only version needed just to keep the left-aligned
                      // text flush against the padding edge (rather than
                      // shrink-wrapped and re-centered by this method's
                      // outer Column) isn't needed here.
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment:
                            CrossAxisAlignment.start,
                            children: [

                              // Long titles that can't fit on one line
                              // auto-scroll right-to-left in a loop
                              // instead of wrapping/truncating — see
                              // MarqueeText. Titles that already fit are
                              // left completely static.
                              MarqueeText(
                                item.title,
                                style: AppFonts.dosis(
                                  fontSize: 26,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),

                              SizedBox(height: gap(6)),

                              // Long artist name(s) auto-scroll the same
                              // way the title does, and the way the
                              // mini player already does — was a plain
                              // Text that wrapped to 2 lines instead.
                              MarqueeText(
                                item.subtitle,
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 17,
                                ),
                              ),
                            ],
                          ),
                        ),

                        ValueListenableBuilder<bool>(
                          valueListenable: manager.isFavorite,
                          builder: (_, isFavorite, __) {
                            return IconButton(
                              icon: Icon(
                                isFavorite
                                    ? Icons.favorite
                                    : Icons.favorite_border,
                                color: isFavorite
                                    ? Colors.red
                                    : Colors.white,
                              ),
                              onPressed: () {
                                manager.toggleFavorite();
                              },
                            );
                          },
                        ),
                      ],
                    ),
                  ),

                  SizedBox(height: gap(20)),

                  const PlayerControlsBar(),

                  // Casting Phase 8: a compact "Casting to X" banner once this
                  // item has been handed off to a TV (see PlaybackCoordinator).
                  // PlayerControlsBar above now switches itself to cast-driven
                  // seek/transport controls whenever a session is connected (it
                  // used to keep driving local (paused) playback here, which was
                  // the actual source of double local+cast audio, not just a
                  // stale-UI inconsistency — fixed in PlayerControlsBar itself).
                  // This banner stays as the quick glance/"which device" indicator
                  // and the entry point into the full connected-session sheet.
                  ValueListenableBuilder<bool>(
                    valueListenable: PlaybackCoordinator.instance.isHandoffActive,
                    builder: (_, handoffActive, __) {
                      if (!handoffActive) return const SizedBox.shrink();

                      return Padding(
                        padding: EdgeInsets.fromLTRB(24, gap(12), 24, 0),
                        child: CastingActivePanel(fullscreen: false),
                      );
                    },
                  ),

                  SizedBox(height: gap(20)),

                  // While casting, a TV-volume button sits between Lyrics
                  // and Queue (see CastVolumeButton); it's left out of the
                  // row entirely otherwise so spacing is unchanged.
                  CastVolumeAvailability(
                    builder: (context, volumeAvailable) => Row(
                      mainAxisAlignment:
                      MainAxisAlignment.spaceEvenly,
                      children: [
                        IconButton(
                          icon: const Icon(
                            Icons.lyrics_outlined,
                            color: Colors.white,
                          ),
                          onPressed: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) =>
                                const LyricsScreen(),
                              ),
                            );
                          },
                        ),

                        if (volumeAvailable) const CastVolumeButton(),

                        IconButton(
                          icon: const Icon(
                            Icons.queue_music,
                            color: Colors.white,
                          ),
                          onPressed: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) =>
                                const QueueScreen(),
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                  ),

                  SizedBox(height: gap(20)),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  // Scales the fixed vertical gaps in the portrait body down together
  // on a short screen, so the handful of fixed-height rows (title/
  // artist, favorite row, transport controls, lyrics/queue row) leave
  // more of the available height for the artwork's `Expanded` slot to
  // work with instead of the artwork alone absorbing every constraint.
  // 620 is comfortably below a typical phone's content height under the
  // header, so this is a no-op (factor 1.0) on essentially every real
  // device and only tightens spacing on a genuinely short viewport
  // (a small-height phone, a multi-window/split-screen strip, or a
  // large display-size text setting eating into the same space). Never
  // shrinks past half the original gap — spacing that thin reads as
  // cramped rather than adaptive, and by that point the artwork's own
  // Expanded flex is doing the rest of the work.
  double Function(double) _scaledGap(double availableHeight) {
    final scale = (availableHeight / 620).clamp(0.5, 1.0);
    return (double base) => base * scale;
  }

  // Landscape layout: artwork on the left, everything else — title,
  // artist, seek bar, transport controls, and the favorite/lyrics/
  // queue buttons — stacked on the right, following the vertical
  // gradient background straight through both halves. No control that
  // doesn't already exist in the portrait layout above is added here;
  // this only rearranges where each one sits.
  Widget _buildLandscapeBody(
    BuildContext context,
    MediaItem item,
    PlayerManager manager,
  ) {
    final albumName = item.raw?['Album']?.toString().trim() ?? '';

    return Column(
      children: [
        // Album name centered across the top of the screen, same as
        // portrait: symmetric padding on both sides (matching the back
        // button's reserved width) keeps it truly centered, and a long
        // name auto-scrolls inside that padded area.
        SizedBox(
          height: 48,
          child: Stack(
            children: [
              Positioned.fill(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: _landscapeHeaderSideWidth,
                  ),
                  child: albumName.isEmpty
                      ? const SizedBox.shrink()
                      : Center(
                          child: MarqueeText(
                            albumName,
                            centered: true,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                ),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: IconButton(
                  icon: const Icon(
                    Icons.keyboard_arrow_down,
                    color: Colors.white,
                    size: 28,
                  ),
                  onPressed: () {
                    Navigator.pop(context);
                  },
                ),
              ),
            ],
          ),
        ),

        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // Artwork, left half.
              Expanded(
                flex: 5,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 36),
                  child: Center(
                    child: Hero(
                      tag: item.id,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(20),
                        child: AspectRatio(
                          aspectRatio: 1,
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              item.image == null
                                  ? Container(
                                color: Colors.grey.shade900,
                                child: const Icon(
                                  Icons.music_note,
                                  size: 72,
                                  color: Colors.white,
                                ),
                              )
                                  : ArtworkImage(
                                path: item.image!,
                                fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) => Container(
                                  color: Colors.grey.shade900,
                                  child: const Icon(
                                    Icons.music_note,
                                    size: 72,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),

              // Title/artist, seek bar, transport controls, and the
              // favorite/lyrics/queue buttons, right half.
              Expanded(
                flex: 6,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment:
                              CrossAxisAlignment.start,
                              children: [
                                MarqueeText(
                                  item.title,
                                  style: AppFonts.dosis(
                                    fontSize: 22,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                // Same auto-scroll as the title and the
                                // mini player, instead of wrapping.
                                MarqueeText(
                                  item.subtitle,
                                  style: const TextStyle(
                                    color: Colors.white70,
                                    fontSize: 14,
                                  ),
                                ),
                              ],
                            ),
                          ),

                          ValueListenableBuilder<bool>(
                            valueListenable: manager.isFavorite,
                            builder: (_, isFavorite, __) {
                              return IconButton(
                                icon: Icon(
                                  isFavorite
                                      ? Icons.favorite
                                      : Icons.favorite_border,
                                  color: isFavorite
                                      ? Colors.red
                                      : Colors.white,
                                ),
                                onPressed: () {
                                  manager.toggleFavorite();
                                },
                              );
                            },
                          ),

                          // Cast button sits immediately to the left of
                          // the three-dot song-options menu — same
                          // left-of-more_vert placement used in the
                          // portrait layout above.
                          const CastButton(),

                          IconButton(
                            icon: const Icon(
                              Icons.more_vert,
                              color: Colors.white,
                            ),
                            onPressed: () => _openSongOptions(context, item),
                          ),
                        ],
                      ),

                      const SizedBox(height: 12),

                      const PlayerControlsBar(compact: true),

                      // Casting Phase 8 — same compact banner as the
                      // portrait layout above, just placed in this
                      // layout's own column instead.
                      ValueListenableBuilder<bool>(
                        valueListenable:
                            PlaybackCoordinator.instance.isHandoffActive,
                        builder: (_, handoffActive, __) {
                          if (!handoffActive) return const SizedBox.shrink();

                          return const Padding(
                            padding: EdgeInsets.only(bottom: 12),
                            child: CastingActivePanel(fullscreen: false),
                          );
                        },
                      ),

                      const SizedBox(height: 12),

                      CastVolumeAvailability(
                        builder: (context, volumeAvailable) => Row(
                          mainAxisAlignment:
                          MainAxisAlignment.spaceEvenly,
                          children: [
                            IconButton(
                              icon: const Icon(
                                Icons.lyrics_outlined,
                                color: Colors.white,
                              ),
                              onPressed: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) =>
                                    const LyricsScreen(),
                                  ),
                                );
                              },
                            ),

                            if (volumeAvailable) const CastVolumeButton(),

                            IconButton(
                              icon: const Icon(
                                Icons.queue_music,
                                color: Colors.white,
                              ),
                              onPressed: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) =>
                                    const QueueScreen(),
                                  ),
                                );
                              },
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _AudioPlaybackErrorOverlay extends StatelessWidget {
  const _AudioPlaybackErrorOverlay({
    required this.message,
    required this.onBack,
  });

  final String message;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black,
      alignment: Alignment.center,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.error_outline,
              color: Colors.white70,
              size: 42,
            ),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 16),
            ),
            const SizedBox(height: 24),
            OutlinedButton(
              onPressed: onBack,
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                side: const BorderSide(color: Colors.white54),
              ),
              child: const Text("Go Back"),
            ),
          ],
        ),
      ),
    );
  }
}
