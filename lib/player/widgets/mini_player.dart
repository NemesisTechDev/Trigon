import 'dart:io';

import 'package:flutter/material.dart';
import '../../player/models/media_item.dart';
import '../../player/player_manager.dart';
import '../../player/services/playback_queue.dart';
import '../screens/audio_player_screen.dart';
import '../screens/player_navigation.dart';
import '../../player/services/playback_progress_service.dart';
import '../../utils/artwork_accent_extractor.dart';
import '../../utils/artwork_source.dart';
import '../../utils/epg_utils.dart';
import '../../services/jellyfin_services/media_service.dart';
import '../../casting/cast_manager.dart';
import '../../casting/models/cast_session.dart';
import '../../casting/ui/cast_button.dart';
import '../../casting/ui/cast_ui.dart';
import '../../casting/ui/connected_session_sheet.dart';
import '../../widgets/common/pressable.dart';
import 'marquee_text.dart';

enum _DragAxis { none, horizontal, vertical }

enum _SwipeDirection { next, previous }

class MiniPlayer extends StatefulWidget {
  const MiniPlayer({super.key});

  @override
  State<MiniPlayer> createState() => _MiniPlayerState();
}

class _MiniPlayerState extends State<MiniPlayer>
    with SingleTickerProviderStateMixin {
  static const double _height = 72;

  // How far (in logical pixels) or how fast (in px/s) a drag has to travel
  // before it's treated as a committed swipe rather than snapping back.
  static const double _swipeThreshold = 90;
  static const double _dismissThreshold = 70;
  static const double _flingVelocity = 600;

  // Fallback used when no artwork accent has been extracted yet (or
  // extraction failed) — matches the app's own gold accent so the bar
  // never looks unstyled.
  static const Color _fallbackAccent = Color(0xFFD4AF37);

  final PlayerManager _manager = PlayerManager.instance;

  // ROOT CAUSE (casting mini player disappearing while a TV is still
  // connected): the casting bar was keyed on `session.currentItem` alone.
  // Any moment that notifier is null (Google Cast's "no media status",
  // a transport clearing it between loads) dropped straight through to the
  // local mini player, which is hidden for a cast-only video — so the bar,
  // and with it the way back into the casting player screen, vanished
  // although the session was alive. The last video item cast on THIS
  // session is remembered and keeps the bar up until the session ends.
  CastSession? _lastCastSession;
  MediaItem? _lastCastVideoItem;

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  )..addListener(_onControllerTick);

  Animation<Offset>? _offsetAnim;
  Animation<double>? _opacityAnim;
  Animation<double>? _heightAnim;

  // Live translation/opacity applied to the whole mini player. Driven
  // directly by finger position while dragging, and by [_controller]
  // whenever a swipe/dismiss/spring-back animation is running.
  Offset _dragOffset = Offset.zero;
  double _opacity = 1;

  // The space this bar actually reserves in the bottom bar's Column —
  // normally just `_height`, always. Only the committed dismiss
  // animation (see _completeDismiss) ever drives this toward 0, and
  // always in lockstep with the same slide/fade — see the build()
  // branch that skips the outer AnimatedSize while that's happening,
  // for why this exists at all.
  double _currentHeight = _height;

  _DragAxis _axis = _DragAxis.none;
  Offset? _panStartGlobal;
  bool _isAnimating = false;

  Color? _accent;
  String? _accentForImage;

  @override
  void initState() {
    super.initState();
    _loadAccent(_manager.currentItem?.image);
    _manager.currentItemNotifier.addListener(_onItemChanged);
  }

  @override
  void dispose() {
    _manager.currentItemNotifier.removeListener(_onItemChanged);
    _controller.dispose();
    super.dispose();
  }

  void _onItemChanged() => _loadAccent(_manager.currentItem?.image);

  void _onControllerTick() {
    if (!mounted) return;
    setState(() {
      if (_offsetAnim != null) _dragOffset = _offsetAnim!.value;
      if (_opacityAnim != null) _opacity = _opacityAnim!.value;
      if (_heightAnim != null) _currentHeight = _heightAnim!.value;
    });
  }

  Future<void> _loadAccent(String? imageUrl) async {
    if (imageUrl == null) {
      _accentForImage = null;
      if (mounted) setState(() => _accent = null);
      return;
    }
    if (_accentForImage == imageUrl) return;
    _accentForImage = imageUrl;

    final color = await ArtworkAccentExtractor.extractFromUrl(imageUrl);

    // The track may have changed again while extraction was in flight.
    if (!mounted || _accentForImage != imageUrl) return;
    setState(() => _accent = color);
  }

  Future<void> _animateTo({
    required Offset offset,
    required Curve curve,
    int durationMs = 220,
    double? opacity,
    double? height,
  }) {
    _controller.duration = Duration(milliseconds: durationMs);

    _offsetAnim = Tween<Offset>(begin: _dragOffset, end: offset).animate(
      CurvedAnimation(parent: _controller, curve: curve),
    );

    _opacityAnim = opacity != null
        ? Tween<double>(begin: _opacity, end: opacity).animate(
            CurvedAnimation(parent: _controller, curve: curve),
          )
        : null;

    _heightAnim = height != null
        ? Tween<double>(begin: _currentHeight, end: height).animate(
            CurvedAnimation(parent: _controller, curve: curve),
          )
        : null;

    _controller.value = 0;
    return _controller.forward();
  }

  void _onPanStart(DragStartDetails details) {
    if (_isAnimating) return;
    _controller.stop();
    _axis = _DragAxis.none;
    _panStartGlobal = details.globalPosition;
  }

  void _onPanUpdate(DragUpdateDetails details) {
    if (_isAnimating || _panStartGlobal == null) return;

    final delta = details.globalPosition - _panStartGlobal!;

    if (_axis == _DragAxis.none) {
      const slop = 8.0;
      if (delta.dx.abs() < slop && delta.dy.abs() < slop) return;

      _axis = delta.dx.abs() > delta.dy.abs()
          ? _DragAxis.horizontal
          : _DragAxis.vertical;
    }

    setState(() {
      if (_axis == _DragAxis.horizontal) {
        var dx = delta.dx;

        // Casting Phase 8: swiping to the next/previous *local* queue
        // item while a cast session has taken over playback (see
        // PlaybackCoordinator) would start that new item playing locally
        // — right alongside whatever's still on the TV — which is
        // exactly the "double playback" the master prompt warns against.
        // Rubber-banding both directions here (and never committing the
        // swipe in _onPanEnd below) keeps the gesture from doing that,
        // without hiding or disabling the mini player itself.
        final castingLocked = CastManager.instance.isCasting;

        // Rubber-band toward an edge with nothing queued in that
        // direction, instead of dragging freely with no payoff.
        if (castingLocked || (dx < 0 && !_manager.hasNext)) dx *= 0.3;
        if (castingLocked || (dx > 0 && !_manager.hasPrevious)) dx *= 0.3;

        _dragOffset = Offset(dx, 0);
        _opacity = 1;
      } else {
        final dy = delta.dy < 0 ? 0.0 : delta.dy;
        _dragOffset = Offset(0, dy);
        _opacity = (1 - dy / 240).clamp(0.35, 1.0);
      }
    });
  }

  void _onPanEnd(DragEndDetails details) {
    if (_isAnimating) return;

    final axis = _axis;
    _axis = _DragAxis.none;
    _panStartGlobal = null;

    if (axis == _DragAxis.horizontal) {
      final vx = details.velocity.pixelsPerSecond.dx;
      final dx = _dragOffset.dx;

      // Casting Phase 8: a fast fling can clear the velocity threshold
      // even with the rubber-banded drag distance from _onPanUpdate, so
      // the commit itself needs its own guard — see that method's doc
      // comment on why swiping to a new local queue item is blocked
      // outright while a cast session is active.
      final castingLocked = CastManager.instance.isCasting;

      if (!castingLocked &&
          (dx <= -_swipeThreshold || vx <= -_flingVelocity) &&
          _manager.hasNext) {
        _completeSwipe(_SwipeDirection.next);
      } else if (!castingLocked &&
          (dx >= _swipeThreshold || vx >= _flingVelocity) &&
          _manager.hasPrevious) {
        _completeSwipe(_SwipeDirection.previous);
      } else {
        _animateTo(offset: Offset.zero, curve: Curves.easeOutCubic, opacity: 1);
      }
    } else if (axis == _DragAxis.vertical) {
      final vy = details.velocity.pixelsPerSecond.dy;
      final dy = _dragOffset.dy;

      // CASTING FIX (music mini player disappears on a swipe-down while
      // still casting): this local bar is also what renders while an
      // *audio* item is being cast — beginCastMirror's whole point is
      // making this branch reflect the session (see its own doc
      // comment) — but unlike the horizontal swipe-to-next/previous
      // case just above, nothing here stopped a vertical swipe from
      // dismissing it. `_completeDismiss()` clears PlaybackQueue, stops
      // local mpv, and hides this bar entirely — none of which touches
      // the actual cast session at all, so the TV kept right on
      // playing with no mini player left on the phone to show or
      // control it, indistinguishable from casting having quietly
      // broken. Rubber-banding back instead (same as the horizontal
      // case) means the only way to make this bar go away while
      // casting is the deliberate one: disconnecting the session
      // itself (via the Cast button here, the connected-session sheet,
      // or the device ending it), which already makes it disappear on
      // its own once `activeSession` goes null.
      final castingLocked = CastManager.instance.isCasting;

      if (!castingLocked && (dy >= _dismissThreshold || vy >= _flingVelocity)) {
        _completeDismiss();
      } else {
        _animateTo(offset: Offset.zero, curve: Curves.easeOutCubic, opacity: 1);
      }
    }
  }

  Future<void> _completeSwipe(_SwipeDirection direction) async {
    _isAnimating = true;

    final width = MediaQuery.sizeOf(context).width;
    final exitDx = direction == _SwipeDirection.next ? -width : width;

    // Phase 1: send the current card the rest of the way off screen.
    await _animateTo(
      offset: Offset(exitDx, 0),
      curve: Curves.easeIn,
      durationMs: 200,
    );

    if (!mounted) return;

    // currentItemNotifier is updated synchronously (before playMedia's
    // first await), so the mini player already reflects the new track
    // by the time phase 2 below starts — playback itself keeps loading
    // in the background.
    if (direction == _SwipeDirection.next) {
      _manager.playNext();
    } else {
      // A deliberate swipe should always land on the previous song, not
      // restart the current one — see playPrevious()'s doc comment for
      // why the plain (tap-driven) Previous convention doesn't fit here.
      _manager.playPrevious(skipRestartThreshold: true);
    }

    if (!mounted) return;

    // Phase 2: bring the new card in from the opposite edge.
    _dragOffset = Offset(-exitDx, 0);
    _opacity = 1;

    await _animateTo(
      offset: Offset.zero,
      curve: Curves.easeOutCubic,
      durationMs: 280,
    );

    _isAnimating = false;
  }

  Future<void> _completeDismiss() async {
    _isAnimating = true;

    // Height now animates down in the same 200ms as the slide/fade
    // (see the `height:` param below) instead of only afterward — see
    // the build() branch that skips the outer AnimatedSize while
    // _isAnimating is true for why this is what actually fixes the
    // pop, not just this call by itself.
    await _animateTo(
      offset: const Offset(0, _height * 3),
      curve: Curves.easeIn,
      durationMs: 200,
      opacity: 0,
      height: 0,
    );

    if (!mounted) return;

    // Hide the bar and reset the drag state right as the slide-off
    // animation finishes, instead of waiting on the network/player-stop
    // cleanup below. Those two awaits can take a variable, sometimes
    // noticeable amount of time, and previously left the (already
    // invisible, fully transparent) mini player still reserving its
    // full height in the bottom bar's layout the whole time they ran —
    // so the bottom nav bar's own collapse into that freed space only
    // kicked off once they finally resolved, well after the user had
    // already watched the slide-down finish. That mismatch is what read
    // as the nav bar "popping" instead of settling in one motion.
    PlaybackQueue.instance.clear();
    _manager.currentItemNotifier.value = null;
    _manager.showMiniPlayer.value = false;

    _dragOffset = Offset.zero;
    _opacity = 1;
    // _currentHeight is already 0 at this point (the animation above
    // finished driving it there) — reset it back to full height now,
    // ready for the next time a track starts and this bar reappears.
    _currentHeight = _height;
    _heightAnim = null;
    _isAnimating = false;

    await PlaybackProgressService.playbackStopped(
      _manager.player.state.position,
    );

    await _manager.player.stop();
  }

  @override
  Widget build(BuildContext context) {
    // A connected cast session casting a VIDEO item (movie, episode, or
    // live channel — anything that isn't `audioOnly`) takes priority over
    // the normal local/audio mini player below. This is deliberately
    // decoupled from PlayerManager's own `currentItem`/`isVideo` (which
    // the local branch below still gates on): a "Cast to" started
    // straight from a details screen never touches local playback at
    // all (see CastToButton), so gating this on local state the same
    // way audio casting does would miss that case entirely. Reading
    // the session's own `currentItem` instead means this bar shows —
    // and can be tapped to reopen VideoPlayerScreen — regardless of
    // whether the cast started as a local handoff (back button on
    // VideoPlayerScreen while casting) or as a direct "Cast to" that
    // never opened a local player screen in the first place.
    //
    // Audio casting keeps going through the local branch below
    // unchanged — PlayerManager.beginCastMirror already mirrors the
    // session's audio state onto the local notifiers this widget
    // already listens to, so `audioOnly` items are deliberately
    // excluded here rather than double-handled by two branches.
    return ValueListenableBuilder<CastSession?>(
      valueListenable: CastManager.instance.activeSession,
      builder: (_, castSession, __) {
        if (!identical(castSession, _lastCastSession)) {
          _lastCastSession = castSession;
          _lastCastVideoItem = null; // never leak an item across sessions
        }
        final castConnected = castSession?.isConnected ?? false;
        if (!castConnected) return _buildLocalMiniPlayer(context);

        return ValueListenableBuilder<MediaItem?>(
          valueListenable: castSession!.currentItem,
          builder: (_, castItem, __) {
            if (castItem != null && !castItem.audioOnly) {
              _lastCastVideoItem = castItem;
            } else if (castItem != null) {
              // An audio item took over: the local (mirrored) bar owns it.
              _lastCastVideoItem = null;
            }
            final shown = castItem ?? _lastCastVideoItem;
            if (shown == null || shown.audioOnly) {
              return _buildLocalMiniPlayer(context);
            }
            return _CastingVideoMiniPlayerBar(
              session: castSession,
              item: shown,
            );
          },
        );
      },
    );
  }

  Widget _buildLocalMiniPlayer(BuildContext context) {
    return ValueListenableBuilder<MediaItem?>(
      valueListenable: _manager.currentItemNotifier,
      builder: (_, item, __) {
        return ValueListenableBuilder<bool>(
          valueListenable: _manager.isVideo,
          builder: (_, isVideo, __) {
            return ValueListenableBuilder<bool>(
              valueListenable: _manager.showMiniPlayer,
              builder: (_, showMiniPlayer, __) {
                // Owns its own height transition instead of leaving it
                // entirely to MainNavScreen's outer AnimatedSize (which
                // exists for the separate job of gliding the whole
                // bottom bar between its portrait/landscape shapes).
                // Without this, the swap between the full-height bar
                // and SizedBox.shrink() below was one instantaneous
                // layout change that the outer AnimatedSize would only
                // pick up on its next frame — reading as the bottom nav
                // bar snapping/"popping" to its new height and then
                // catching up, instead of settling in one continuous
                // motion right as the mini player finishes sliding away.
                if (item == null || isVideo || !showMiniPlayer) {
                  return AnimatedSize(
                    duration: const Duration(milliseconds: 220),
                    curve: Curves.easeOut,
                    alignment: Alignment.topCenter,
                    child: const SizedBox.shrink(
                      key: ValueKey('mini-player-hidden'),
                    ),
                  );
                }

                // While a committed swipe-to-dismiss is running,
                // _currentHeight is already being driven from `_height`
                // to 0 tick-by-tick in lockstep with the same slide/fade
                // (see _completeDismiss/_animateTo) — that's what makes
                // the bar sliding away and the nav bar rising to meet it
                // read as one continuous motion instead of two. Wrapping
                // that in this AnimatedSize too would just add a second,
                // differently-timed interpolation chasing an
                // already-moving target, so it's skipped for exactly
                // that one animation. OverflowBox keeps the bar's own
                // internal Row/Expanded laid out at their normal
                // `_height` throughout (nothing inside it re-flows or
                // squishes as the reserved space shrinks) — ClipRect
                // just crops that fixed-size content to however much of
                // the shrinking window is left, anchored to the top so
                // what's cropped is the bit that's already slid furthest
                // down and faded most.
                if (_isAnimating) {
                  return ClipRect(
                    child: SizedBox(
                      height: _currentHeight,
                      child: OverflowBox(
                        minHeight: _height,
                        maxHeight: _height,
                        alignment: Alignment.topCenter,
                        child: _buildBar(context, item),
                      ),
                    ),
                  );
                }

                return AnimatedSize(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOut,
                  alignment: Alignment.topCenter,
                  child: _buildBar(context, item),
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _buildBar(BuildContext context, MediaItem item) {
            final accent = _accent ?? _fallbackAccent;

            return GestureDetector(
              onPanStart: _onPanStart,
              onPanUpdate: _onPanUpdate,
              onPanEnd: _onPanEnd,
              child: Opacity(
                opacity: _opacity,
                child: Transform.translate(
                  offset: _dragOffset,
                  child: Material(
                    color: const Color(0xff202020),
                    child: InkWell(
                      onTap: () {
                        Navigator.of(context, rootNavigator: true).push(
                          MaterialPageRoute(
                            builder: (_) => const AudioPlayerScreen(),
                          ),
                        );
                      },
                      child: SizedBox(
                        height: _height,
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            Expanded(
                              child: Row(
                                children: [
                                  const SizedBox(width: 12),

                                  Hero(
                                    tag: item.id,
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(6),
                                      child: item.image != null
                                          ? (isRemoteArtwork(item.image!)
                                              ? Image.network(
                                                  item.image!,
                                                  width: 56,
                                                  height: 56,
                                                  fit: BoxFit.cover,
                                                )
                                              : Image.file(
                                                  File(item.image!),
                                                  width: 56,
                                                  height: 56,
                                                  fit: BoxFit.cover,
                                                  errorBuilder: (_, __, ___) =>
                                                      Container(
                                                    width: 56,
                                                    height: 56,
                                                    color: Colors.grey.shade800,
                                                    child: const Icon(
                                                      Icons.music_note,
                                                      color: Colors.white,
                                                    ),
                                                  ),
                                                ))
                                          : Container(
                                              width: 56,
                                              height: 56,
                                              color: Colors.grey.shade800,
                                              child: const Icon(
                                                Icons.music_note,
                                                color: Colors.white,
                                              ),
                                            ),
                                    ),
                                  ),

                                  const SizedBox(width: 12),

                                  Expanded(
                                    child: Column(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        // Long titles that can't fit
                                        // auto-scroll right-to-left in
                                        // a loop instead of truncating
                                        // — see MarqueeText. Titles
                                        // that already fit are left
                                        // completely static.
                                        MarqueeText(
                                          item.title,
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                        // Casting-aware subtitle — per the
                                        // casting master prompt's mini-
                                        // player example ("Movie Title" /
                                        // "Living Room TV"), the normal
                                        // artist/album line is swapped for
                                        // the connected device's name
                                        // while a cast session is active,
                                        // so it's never ambiguous that
                                        // playback is happening remotely.
                                        // Local transport controls below
                                        // are untouched — unifying local/
                                        // remote playback state is Phase
                                        // 8, not this row.
                                        ValueListenableBuilder<CastSession?>(
                                          valueListenable:
                                              CastManager.instance.activeSession,
                                          builder: (_, session, __) {
                                            final connected =
                                                session?.isConnected ?? false;

                                            if (!connected) {
                                              // Was a plain ellipsis
                                              // Text — a long album
                                              // name (this line is
                                              // often the album rather
                                              // than the artist; see
                                              // MediaItem.subtitle's
                                              // own doc comment) could
                                              // stretch visually all
                                              // the way into the
                                              // play/pause and skip
                                              // buttons before it hit
                                              // the ellipsis. MarqueeText
                                              // scrolls instead, and the
                                              // trailing padding keeps
                                              // even the un-scrolled,
                                              // static case from
                                              // butting right up
                                              // against them.
                                              return Padding(
                                                padding: const EdgeInsets
                                                    .only(right: 6),
                                                child: MarqueeText(
                                                  item.subtitle,
                                                  style: const TextStyle(
                                                    color: Colors.white54,
                                                  ),
                                                ),
                                              );
                                            }

                                            // Casting Phase 9 fix: was a
                                            // bare GestureDetector, which
                                            // never gets its own
                                            // FocusNode — on Android TV
                                            // this row would be
                                            // unreachable via D-pad
                                            // (focus would skip straight
                                            // from wherever it was to the
                                            // mini player's own
                                            // whole-bar InkWell below,
                                            // never landing here at all).
                                            // Pressable(unconstrained:
                                            // false, the default) is
                                            // this app's own established
                                            // GestureDetector
                                            // replacement — restores
                                            // focus/D-pad activation via
                                            // its InkWell, same as every
                                            // other tappable row in the
                                            // app already uses.
                                            //
                                            // Text-only, no cast icon: the
                                            // CastButton now sitting to the
                                            // left of the play/pause button
                                            // (below) is the one casting
                                            // indicator/control this bar
                                            // shows — repeating a cast icon
                                            // here too would put two
                                            // casting indicators on the same
                                            // bar for no added information.
                                            return Pressable(
                                              onTap: () =>
                                                  showConnectedCastSheet(
                                                      context),
                                              child: Text(
                                                "Playing on ${session!.device.displayName}",
                                                maxLines: 1,
                                                overflow:
                                                    TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                  color: castGold,
                                                  fontSize: 12,
                                                ),
                                              ),
                                            );
                                          },
                                        ),
                                      ],
                                    ),
                                  ),

                                  // Casting button — appears to the left
                                  // of the play/pause button only while
                                  // a cast session is connected, and
                                  // disappears (SizedBox.shrink, no
                                  // reserved width) the moment casting
                                  // ends. This is the mini player's one
                                  // casting indicator/control; the
                                  // subtitle above is plain "Playing on
                                  // X" text with no icon of its own so
                                  // the two don't duplicate each other.
                                  ValueListenableBuilder<CastSession?>(
                                    valueListenable:
                                        CastManager.instance.activeSession,
                                    builder: (_, session, __) {
                                      final connected =
                                          session?.isConnected ?? false;

                                      if (!connected) {
                                        return const SizedBox.shrink();
                                      }

                                      return const Padding(
                                        padding: EdgeInsets.only(right: 4),
                                        child: CastButton(iconSize: 22),
                                      );
                                    },
                                  ),

                                  // Casting Phase 8: while a session is
                                  // connected, this button (and the
                                  // progress bar below) drive/reflect
                                  // CastManager instead of the local
                                  // player — the local track is paused
                                  // for the duration of the cast session
                                  // (see PlaybackCoordinator), so
                                  // reading/controlling local state here
                                  // would just show a permanently-paused
                                  // button no tap could do anything
                                  // useful with.
                                  ValueListenableBuilder<CastSession?>(
                                    valueListenable:
                                        CastManager.instance.activeSession,
                                    builder: (_, session, __) {
                                      final casting =
                                          session?.isConnected ?? false;

                                      if (!casting) {
                                        return ValueListenableBuilder<bool>(
                                          valueListenable: _manager.playing,
                                          builder: (_, playing, __) {
                                            return IconButton(
                                              icon: AnimatedSwitcher(
                                                duration: const Duration(
                                                  milliseconds: 180,
                                                ),
                                                transitionBuilder:
                                                    (child, anim) =>
                                                        ScaleTransition(
                                                  scale: anim,
                                                  child: child,
                                                ),
                                                child: Icon(
                                                  playing
                                                      ? Icons.pause
                                                      : Icons.play_arrow,
                                                  key: ValueKey(playing),
                                                  color: Colors.white,
                                                ),
                                              ),
                                              onPressed: () {
                                                _manager.player.playOrPause();
                                              },
                                            );
                                          },
                                        );
                                      }

                                      return ValueListenableBuilder<bool>(
                                        valueListenable:
                                            session!.showsPlaying,
                                        builder: (_, playing, __) {
                                          return IconButton(
                                            icon: AnimatedSwitcher(
                                              duration: const Duration(
                                                milliseconds: 180,
                                              ),
                                              transitionBuilder:
                                                  (child, anim) =>
                                                      ScaleTransition(
                                                scale: anim,
                                                child: child,
                                              ),
                                              child: Icon(
                                                playing
                                                    ? Icons.pause
                                                    : Icons.play_arrow,
                                                key: ValueKey(playing),
                                                color: castGold,
                                              ),
                                            ),
                                            onPressed: () {
                                              // Phase 10 hardening: routed
                                              // through runCastCommand so a
                                              // command that fails against
                                              // an unreachable/dropped
                                              // target surfaces a SnackBar
                                              // instead of silently doing
                                              // nothing (see cast_ui.dart's
                                              // doc comment).
                                              runCastCommand(
                                                context,
                                                CastManager.instance
                                                    .togglePlayPause,
                                              );
                                            },
                                          );
                                        },
                                      );
                                    },
                                  ),

                                  const SizedBox(width: 8),
                                ],
                              ),
                            ),

                            // Progress bar — fills left to right with the
                            // artwork's accent color. Casting-aware, same
                            // reasoning as the play/pause button above:
                            // reads the session's TV-reported position/
                            // duration instead of the (paused, unmoving)
                            // local player while a session is connected.
                            ValueListenableBuilder<CastSession?>(
                              valueListenable:
                                  CastManager.instance.activeSession,
                              builder: (_, session, __) {
                                final casting = session?.isConnected ?? false;

                                final positionListenable = casting
                                    ? session!.position
                                    : _manager.position;
                                final durationListenable = casting
                                    ? session!.duration
                                    : _manager.duration;

                                return ValueListenableBuilder<Duration>(
                                  valueListenable: positionListenable,
                                  builder: (_, pos, __) {
                                    return ValueListenableBuilder<Duration>(
                                      valueListenable: durationListenable,
                                      builder: (_, dur, __) {
                                        final ratio = dur.inMilliseconds > 0
                                            ? (pos.inMilliseconds /
                                                    dur.inMilliseconds)
                                                .clamp(0.0, 1.0)
                                            : 0.0;

                                        return LayoutBuilder(
                                          builder: (context, constraints) {
                                            return SizedBox(
                                              height: 2.5,
                                              width: constraints.maxWidth,
                                              child: Stack(
                                                alignment:
                                                    Alignment.centerLeft,
                                                children: [
                                                  Container(
                                                    color: Colors.white12,
                                                  ),
                                                  AnimatedContainer(
                                                    duration: const Duration(
                                                      milliseconds: 250,
                                                    ),
                                                    curve: Curves.linear,
                                                    height: 2.5,
                                                    width:
                                                        constraints.maxWidth *
                                                            ratio,
                                                    color: casting
                                                        ? castGold
                                                        : accent,
                                                  ),
                                                ],
                                              ),
                                            );
                                          },
                                        );
                                      },
                                    );
                                  },
                                );
                              },
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
  }
}

/// The mini player shown app-wide while a connected cast session is
/// casting a VIDEO item (movie, TV episode, or live channel) — the
/// video-casting counterpart to [_MiniPlayerState]'s own local/audio
/// bar above. Appears any time such a session exists, including right
/// after backing out of [VideoPlayerScreen] mid cast-handoff (see that
/// screen's `dispose()`, which now leaves local playback state intact
/// for exactly this reason) and for a "Cast to" sent straight from a
/// details screen that never opened a local player at all.
///
/// Deliberately simpler than the local bar above: no swipe-to-dismiss
/// or swipe-to-skip gestures (that machinery assumes it can stop local
/// playback / advance a local queue, neither of which is what "dismiss"
/// or "skip" would even mean for a session actually playing on a TV).
/// A single tap is the only gesture — it reopens VideoPlayerScreen,
/// which reads the same [CastManager] session this bar does to show
/// the right casting controls, per PlaybackCoordinator/CastingBackdrop.
class _CastingVideoMiniPlayerBar extends StatefulWidget {
  const _CastingVideoMiniPlayerBar({
    required this.session,
    required this.item,
  });

  final CastSession session;
  final MediaItem item;

  @override
  State<_CastingVideoMiniPlayerBar> createState() =>
      _CastingVideoMiniPlayerBarState();
}

class _CastingVideoMiniPlayerBarState
    extends State<_CastingVideoMiniPlayerBar> {
  static const double _height = 72;

  // Only populated for live channels — the currently-airing program,
  // fetched the same way (same endpoint, same EpgUtils picks) as the
  // in-player Info sheet and CastingMediaCard's own `_LiveChannelLines`,
  // so this bar can never show a different "what's on now" than either
  // of those for the same channel.
  Map<String, dynamic>? _currentProgram;

  @override
  void initState() {
    super.initState();
    if (widget.item.live) _loadCurrentProgram();
  }

  @override
  void didUpdateWidget(covariant _CastingVideoMiniPlayerBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.item.live && oldWidget.item.id != widget.item.id) {
      _currentProgram = null;
      _loadCurrentProgram();
    }
  }

  Future<void> _loadCurrentProgram() async {
    try {
      final programs = await MediaService.getPrograms(
        channelId: widget.item.id,
      );
      final picked = EpgUtils.pickCurrentProgram(programs);
      if (!mounted) return;
      setState(() => _currentProgram = picked);
    } catch (_) {
      // Best-effort, same as the Info sheet/CastingMediaCard's own
      // fetch — a failed guide lookup just means no program name, not
      // a broken bar.
    }
  }

  String? get _programName {
    final name = _currentProgram?['Name']?.toString();
    return (name == null || name.isEmpty) ? null : name;
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final session = widget.session;
    final isLive = item.live;
    final isEpisode =
        !isLive && (item.seasonNumber != null || item.episodeNumber != null);
    final deviceName = session.device.displayName;

    return Material(
      color: const Color(0xff202020),
      child: InkWell(
        onTap: () => PlayerNavigation.open(context, force: true),
        child: SizedBox(
          height: _height,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Expanded(
                child: Row(
                  children: [
                    const SizedBox(width: 12),
                    _Artwork(item: item),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Episode: the show's own name sits above the
                          // "S1E2 Episode Name" row instead of being
                          // folded away entirely — matches how a TV
                          // show is identified everywhere else in the
                          // app (detail screen, CastingMediaCard's own
                          // episode lines) rather than only ever
                          // showing the episode's title on its own.
                          // `item.subtitle` is the show name here (see
                          // MediaService.mediaItemFromJellyfin, which
                          // sets it from SeriesName for episodes).
                          if (isEpisode && item.subtitle.isNotEmpty)
                            Text(
                              item.subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white54,
                                fontSize: 11,
                              ),
                            ),
                          // Movie: the movie's own title.
                          // Episode: "S1E2 Episode Name" underneath the
                          // show-name line above.
                          // Live channel: the channel's own name.
                          MarqueeText(
                            isLive
                                ? item.title
                                : isEpisode
                                    ? _episodeLabel(item)
                                    : item.title,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          // Movie/episode: plain "Playing on X".
                          // Live channel: the currently-airing program
                          // folded into the same single line (this bar
                          // only ever reserves one subtitle line, same
                          // as the local mini player above) —
                          // "{Program} • Playing on {Device}", or just
                          // "Playing on {Device}" while the guide
                          // lookup is still in flight/unavailable.
                          Text(
                            isLive
                                ? (_programName != null
                                    ? '$_programName • Playing on $deviceName'
                                    : 'Playing on $deviceName')
                                : 'Playing on $deviceName',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: castGold,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),

                    const Padding(
                      padding: EdgeInsets.only(right: 4),
                      child: CastButton(iconSize: 22),
                    ),

                    ValueListenableBuilder<bool>(
                      valueListenable: session.showsPlaying,
                      builder: (_, playing, __) {
                        return IconButton(
                          icon: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 180),
                            transitionBuilder: (child, anim) =>
                                ScaleTransition(scale: anim, child: child),
                            child: Icon(
                              playing ? Icons.pause : Icons.play_arrow,
                              key: ValueKey(playing),
                              color: castGold,
                            ),
                          ),
                          onPressed: () {
                            runCastCommand(
                              context,
                              CastManager.instance.togglePlayPause,
                            );
                          },
                        );
                      },
                    ),

                    const SizedBox(width: 8),
                  ],
                ),
              ),

              // Progress bar — same shape as the local bar's, reading
              // the session's own (locally-interpolated, see
              // CastSession's own doc comment) position/duration
              // rather than local mpv, which is either paused
              // (handoff) or was never opened at all (a direct
              // "Cast to").
              ValueListenableBuilder<Duration>(
                valueListenable: session.position,
                builder: (_, pos, __) {
                  return ValueListenableBuilder<Duration>(
                    valueListenable: session.duration,
                    builder: (_, dur, __) {
                      final ratio = dur.inMilliseconds > 0
                          ? (pos.inMilliseconds / dur.inMilliseconds)
                              .clamp(0.0, 1.0)
                          : 0.0;

                      return LayoutBuilder(
                        builder: (context, constraints) {
                          return SizedBox(
                            height: 2.5,
                            width: constraints.maxWidth,
                            child: Stack(
                              alignment: Alignment.centerLeft,
                              children: [
                                Container(color: Colors.white12),
                                AnimatedContainer(
                                  duration: const Duration(milliseconds: 250),
                                  curve: Curves.linear,
                                  height: 2.5,
                                  width: constraints.maxWidth * ratio,
                                  color: castGold,
                                ),
                              ],
                            ),
                          );
                        },
                      );
                    },
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _episodeLabel(MediaItem item) {
    final season = item.seasonNumber;
    final episode = item.episodeNumber;
    final code = (season != null && episode != null)
        ? 'S${season}E$episode '
        : '';
    return '$code${item.title}';
  }
}

class _Artwork extends StatelessWidget {
  const _Artwork({required this.item});

  final MediaItem item;

  // Scaled-down movie/show card, not a square thumbnail — same 2:3
  // poster proportions as the card grids elsewhere in the app, just
  // sized to fit this bar's height instead of a full poster card.
  // Live channels are handled separately below (they're never
  // poster-shaped) and keep their own square footprint.
  static const double _posterHeight = 56;
  static const double _posterWidth = _posterHeight * 2 / 3;

  @override
  Widget build(BuildContext context) {
    // Live channels never have a poster-shaped Primary image the way a
    // movie/episode does — `logo` is the channel's own Primary image
    // (see MediaService.mediaItemFromJellyfin). Per the design spec,
    // the channel logo sits on the bar on its own — no rounded card,
    // no background fill behind it, unlike the poster thumbnails
    // below — so it's rendered directly with BoxFit.contain instead of
    // going through the same ClipRRect+cover treatment.
    if (item.live) {
      final logo = item.logo;
      if (logo == null || logo.isEmpty) {
        return const SizedBox(
          width: 56,
          height: 56,
          child: Icon(Icons.live_tv_rounded, color: Colors.white70),
        );
      }
      return SizedBox(
        width: 56,
        height: 56,
        child: isRemoteArtwork(logo)
            ? Image.network(
                logo,
                fit: BoxFit.contain,
                errorBuilder: (_, __, ___) => const Icon(
                  Icons.live_tv_rounded,
                  color: Colors.white70,
                ),
              )
            : Image.file(
                File(logo),
                fit: BoxFit.contain,
                errorBuilder: (_, __, ___) => const Icon(
                  Icons.live_tv_rounded,
                  color: Colors.white70,
                ),
              ),
      );
    }

    final isEpisode = item.seasonNumber != null || item.episodeNumber != null;
    final fallbackIcon = isEpisode ? Icons.tv_rounded : Icons.movie_rounded;

    // Episodes: the show's own poster (MediaItem.seriesImage — the
    // parent series' Primary image), not the episode's own thumbnail.
    // The episode thumbnail is a wide, backdrop-shaped frame from the
    // episode itself, which looked squashed/oddly cropped once this
    // card stopped being forced into a square — the show's poster is
    // the image actually meant to be shown at poster proportions, the
    // same one the show's own detail screen and library grid use.
    // Falls back to the episode thumbnail if the series poster wasn't
    // resolved (e.g. an older cached item built before this field
    // existed), and movies just use their own poster as always.
    final artwork = isEpisode ? (item.seriesImage ?? item.image) : item.image;

    Widget placeholder() => Container(
          width: _posterWidth,
          height: _posterHeight,
          color: Colors.grey.shade800,
          child: Icon(fallbackIcon, color: Colors.white),
        );

    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: artwork == null
          ? placeholder()
          : (isRemoteArtwork(artwork)
              ? Image.network(
                  artwork,
                  width: _posterWidth,
                  height: _posterHeight,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => placeholder(),
                )
              : Image.file(
                  File(artwork),
                  width: _posterWidth,
                  height: _posterHeight,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => placeholder(),
                )),
    );
  }
}
