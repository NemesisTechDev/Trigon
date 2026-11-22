import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import '../models/media_item.dart';
import '../player_manager.dart';
import '../services/trickplay_service.dart';
import '../widgets/trickplay_preview.dart';
import '../widgets/frame_preview.dart';
import '../services/frame_grabber.dart';
import '../../widgets/common/pressable.dart';
import '../../widgets/common/start_wait_label.dart';
import '../../utils/responsive.dart';

class PlayerSeekBar extends StatefulWidget {
  const PlayerSeekBar({
    super.key,
    required this.player,
    this.activeColor,
  });

  final Player player;

  // Lets a specific screen override the active track/thumb color — the
  // audio player uses white now that the background carries a dynamic
  // artwork-derived accent, while the video/live-TV bottom bar keeps the
  // original gold since it still sits on a plain scrim.
  final Color? activeColor;

  @override
  State<PlayerSeekBar> createState() => _PlayerSeekBarState();
}

class _PlayerSeekBarState extends State<PlayerSeekBar> {
  // While the user is actively dragging the thumb, the slider's value
  // must come from local state, not from `player.stream.position`.
  // Binding the Slider's `value` straight to the live position stream
  // (the previous implementation) meant that every frame during a drag
  // could get overwritten by whatever the *player* currently reports —
  // which lags behind a fast finger swipe and doesn't reflect any
  // seek-while-dragging at all — so the thumb visually snapped back and
  // fought the user's touch instead of following it. Tracking the drag
  // position locally and only committing the seek on release fixes
  // that; the stream drives the thumb again as soon as the drag ends.
  double? _dragValue;

  // Live TV's "live edge" — the furthest point the stream has actually
  // reached, i.e. how much of the channel's rolling buffer (starting
  // from the moment playback began) is currently available to seek
  // into. mpv/the server don't reliably report a `duration` for an
  // actively-growing live proxy stream, so this is tracked locally as a
  // running high-water mark of position/buffer instead — it only ever
  // moves forward while a given channel plays, and is reset whenever the
  // channel changes.
  Duration _liveEdge = Duration.zero;
  String? _liveEdgeItemId;

  // Tracks which item's trickplay tiles have already been kicked off
  // for prefetch, so it only happens once per item (right when the
  // seek bar first sees it, i.e. as playback starts) rather than
  // re-firing on every rebuild while dragging.
  String? _trickplayPrefetchedItemId;

  // SEEK-THUMBNAIL FIX (prefetch latch): mirrors `_trickplayResSourceMap`
  // below for the exact same reason. Before this, the prefetch gate
  // above only checked `item.id`, so if this widget's very first build
  // for an item happened to see a non-null but INCOMPLETE trickplay map
  // (e.g. a movie's details-screen snapshot taken mid-generation), it
  // latched onto that id and warmed the cache with only those few
  // tiles — then never re-fired once PlayerManager._augmentWithPlaybackFields
  // backfilled the real, complete map moments later, even though
  // `_trickplayRes` itself (the one actually used to render the
  // preview) *did* pick up the fresh data via the check below. Net
  // effect: correct tiles, just never prefetched — every tile past
  // what the stale snapshot covered had to be fetched live on first
  // scrub instead of being ready in advance. Tracking the map
  // reference here too means a fresh backfill re-triggers prefetch for
  // whatever the old, smaller resolution never warmed.
  Map<String, dynamic>? _trickplayPrefetchedSourceMap;

  // `TrickplayService.resolve()` walks/sorts the item's trickplay map —
  // cheap once, but `_buildBar` used to call it on every single rebuild,
  // including every pixel of a drag (each `onChanged` calls `setState`).
  // Resolving once per item and reusing the cached result keeps drag
  // rebuilds down to just re-reading a field.
  TrickplayResolution? _trickplayRes;
  String? _trickplayResItemId;

  // The exact `trickplay` map reference `_trickplayRes` was last
  // resolved from. Caching purely on item id (the old behavior) meant
  // that once this widget's very first build for an item happened to
  // see `currentItem.trickplay == null` — which for every TV episode is
  // guaranteed, since episodes are deliberately fetched without
  // Trickplay up front and only get it backfilled by
  // PlayerManager._augmentWithPlaybackFields a moment later (see that
  // method's doc comment) — the id-only check above never saw a reason
  // to recompute again: the id hadn't changed, so the stale `null`
  // result stuck for the rest of that item's playback even after the
  // backfill landed and `currentItem.trickplay` had real data sitting
  // right there. Tracking the map reference alongside the id means a
  // fresh (non-identical) `trickplay` map — exactly what the backfill's
  // `copyWith` hands back — is recognized as new data and triggers a
  // re-resolve, instead of the preview staying stuck on whatever was
  // (or wasn't) available at that very first synchronous build.
  Map<String, dynamic>? _trickplayResSourceMap;

  // Bumped on every onChangeEnd so a slow/in-flight seek that finishes
  // late (e.g. after the user has already started a second drag) can
  // tell it's been superseded and bail out instead of stomping on the
  // newer interaction's state.
  int _seekToken = 0;

  static const _gold = Color(0xffD4AF37);

  String format(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);

    if (h > 0) {
      return "$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}";
    }

    return "${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}";
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<MediaItem?>(
      valueListenable: PlayerManager.instance.currentItemNotifier,
      builder: (context, item, __) {
        final isLive = item?.live ?? false;

        // A new channel starts its own rolling buffer from zero — carry
        // over the previous channel's high-water mark would make the
        // bar look like it already has a huge, mostly-unwatched buffer.
        if (item?.id != _liveEdgeItemId) {
          _liveEdge = Duration.zero;
          _liveEdgeItemId = item?.id;
        }

        // Warm the trickplay tile cache as soon as this item's seek bar
        // appears — well before the user drags — so scrubbing later
        // hits an already-decoded cache entry instead of triggering a
        // live fetch+decode. Scheduled for after this frame since it's
        // a side effect (network + cache writes) that shouldn't run
        // during build.
        if (!isLive &&
            item != null &&
            (item.id != _trickplayPrefetchedItemId ||
                !identical(item.trickplay, _trickplayPrefetchedSourceMap))) {
          final res = TrickplayService.resolve(item);
          // Only latch `_trickplayPrefetchedItemId`/`_trickplayPrefetchedSourceMap`
          // once resolve() actually finds trickplay data. This build can
          // easily land before PlayerManager._augmentWithPlaybackFields'
          // backfill has arrived (guaranteed for every TV episode, which
          // starts with no Trickplay by design) — marking the item
          // "handled" regardless meant a `null` result here permanently
          // skipped prefetching for it, even once real data showed up
          // moments later. Leaving the id unmarked on a null result lets
          // this retry on the next rebuild instead.
          if (res != null) {
            _trickplayPrefetchedItemId = item.id;
            _trickplayPrefetchedSourceMap = item.trickplay;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) {
                // Wherever playback currently sits is the far more
                // likely spot for the user's *first* scrub than tile
                // zero — prioritizing it means the very first drag
                // usually hits an already-decoded image instead of a
                // live network+decode stall, even if the rest of the
                // sheets are still trickling in behind it.
                TrickplayService.prefetchAll(
                  context,
                  item.id,
                  res,
                  priorityPosition: PlayerManager.instance.position.value,
                );
              }
            });
          }
        }

        // Position/duration/buffer are read from PlayerManager's own
        // ValueNotifiers (kept in sync by the single canonical listener
        // set up once in PlayerManager.initialize(), reset to zero at
        // the start of every playMedia() call) rather than this widget
        // opening its own separate subscriptions directly to
        // `widget.player.stream.*`. Those raw streams only emit on
        // *change* — e.g. duration never refires if two items back to
        // back happen to share the same runtime — so a second,
        // independent subscription here could drift out of sync with
        // what actually happened (a fresh item, a resume seek) instead
        // of always reflecting PlayerManager's single source of truth,
        // which is the same one the mini player already relies on.
        return ValueListenableBuilder<Duration>(
          valueListenable: PlayerManager.instance.position,
          builder: (context, position, __) {
            return ValueListenableBuilder<Duration>(
              valueListenable: PlayerManager.instance.bufferedPosition,
              builder: (context, buffer, __) {
                return ValueListenableBuilder<Duration>(
                  valueListenable: PlayerManager.instance.duration,
                  builder: (context, reportedDuration, __) {
                    if (isLive) {
                      final observed = _maxDuration(
                        _maxDuration(position, buffer),
                        reportedDuration,
                      );

                      if (observed > _liveEdge) {
                        _liveEdge = observed;
                      }

                      return _buildBar(
                        position: position,
                        buffer: buffer,
                        maxDuration: _liveEdge,
                        live: true,
                      );
                    }

                    return _buildBar(
                      position: position,
                      buffer: buffer,
                      // `PlayerManager.instance.duration` only updates
                      // once mpv itself has parsed far enough into the
                      // file to know its runtime — for most files
                      // that's near-instant, but for some it lags a
                      // couple of seconds behind `loading` clearing
                      // and the seek bar becoming interactive. Until
                      // it arrives, this fell through to `_buildBar`'s
                      // own maxMs=1.0 fallback, which made the *first*
                      // tap compute a target of essentially 0ms — a
                      // no-op that looked exactly like the seek bar
                      // not responding, "fixed" only once mpv's real
                      // duration had shown up by the second tap.
                      // Jellyfin already hands over the real runtime
                      // up front, so falling back to `item.runtime`
                      // here (same fallback the mini player/audio
                      // handler already uses — see
                      // NemesisAudioHandler) keeps the bar correctly
                      // scaled from the very first frame instead of
                      // waiting on mpv to confirm it independently.
                      maxDuration: reportedDuration > Duration.zero
                          ? reportedDuration
                          : (item?.runtime ?? Duration.zero),
                      live: false,
                    );
                  },
                );
              },
            );
          },
        );
      },
    );
  }

  Duration _maxDuration(Duration a, Duration b) => a > b ? a : b;

  Widget _buildBar({
    required Duration position,
    required Duration buffer,
    required Duration maxDuration,
    required bool live,
  }) {
    final maxMs = maxDuration.inMilliseconds == 0
        ? 1.0
        : maxDuration.inMilliseconds.toDouble();

    final bufferedPercent = maxDuration.inMilliseconds == 0
        ? 0.0
        : buffer.inMilliseconds / maxDuration.inMilliseconds;

    // Only fall back to the live stream position when the user isn't
    // actively dragging the thumb.
    final sliderValue = (_dragValue ?? position.inMilliseconds.toDouble())
        .clamp(0.0, maxMs)
        .toDouble();

    final displayedPosition = _dragValue != null
        ? Duration(milliseconds: _dragValue!.round())
        : position;

    // On a live channel, "at the live edge" means the thumb is
    // (approximately) tracking the furthest available point rather than
    // rewound into the buffer — a few seconds of slack avoids the LIVE
    // indicator flickering to "behind" from ordinary decode/render lag.
    final atLiveEdge = !live ||
        (maxDuration - displayedPosition) <= const Duration(seconds: 5);

    final activeColor = widget.activeColor ?? _gold;

    // Trickplay preview only makes sense for VOD (Jellyfin doesn't
    // generate scrub tiles for live channels) and only while the user
    // is actually dragging the thumb — showing it any other time would
    // just be a frozen, stale thumbnail sitting above the bar.
    final currentItem = PlayerManager.instance.currentItem;

    if (currentItem?.id != _trickplayResItemId ||
        !identical(currentItem?.trickplay, _trickplayResSourceMap)) {
      _trickplayResItemId = currentItem?.id;
      _trickplayResSourceMap = currentItem?.trickplay;
      _trickplayRes = (!live && currentItem != null)
          ? TrickplayService.resolve(currentItem)
          : null;

      // DIAGNOSTIC (trickplay stuck-thumbnail investigation): fires only
      // when this widget actually adopts a new item or a newly-arrived
      // trickplay map for the same item — never per drag frame, never
      // per position tick. If a title is still stuck after this pass of
      // fixes, this line (filter logcat for "TRICKPLAY") shows exactly
      // what data the scrub preview picked for it, so the next session
      // has real numbers instead of another guess: compare
      // thumbnailCount/intervalMs here against what Jellyfin's own
      // `/Items/{id}?Fields=Trickplay` response reports for the same
      // item and mediaSourceId.
      final res = _trickplayRes;
      if (res != null) {
        final coveredMs = res.thumbnailCount * res.intervalMs;
        debugPrint(
          'TRICKPLAY (local): item=${currentItem?.id} '
          'title="${currentItem?.title}" chosenWidth=${res.width} '
          'thumbnailCount=${res.thumbnailCount} intervalMs=${res.intervalMs} '
          'tileGrid=${res.tileWidth}x${res.tileHeight} coveredMs=$coveredMs '
          'runtimeMs=${currentItem?.runtime.inMilliseconds} '
          'mediaSourceId=${res.mediaSourceId}',
        );
      } else if (currentItem != null && !live) {
        debugPrint(
          'TRICKPLAY (local): item=${currentItem.id} '
          'title="${currentItem.title}" resolve() -> null '
          '(no usable trickplay data yet)',
        );
      }
    }
    final trickplayRes = _trickplayRes;
    // SEEK-THUMBNAIL FIX (part 5): no longer gated on a position/
    // metadata check here (see TrickplayService.frameFor's doc comment
    // for why `thumbnailCount` turned out not to be trustworthy enough
    // to pre-emptively decide this) — TrickplayPreview itself now finds
    // out whether real data exists at `displayedPosition` by actually
    // requesting it, and hides itself on a genuine failure.
    final showTrickplay = _dragValue != null && trickplayRes != null;
    // Addon titles have no Jellyfin thumbnail sheets: preview frames are
    // grabbed on demand instead (see FrameGrabber).
    final showGrab = _dragValue != null &&
        trickplayRes == null &&
        FrameGrabber.supports(currentItem);

    // TV is remote-navigated at a 10-foot viewing distance, not
    // touched at arm's length — the track/thumb/overlay and the
    // time-remaining text get a deliberate bump, same Responsive.isTV
    // pattern used across the rest of the player control surface.
    // Phone/tablet keep the exact original numbers (the touch-target
    // height fix below stays 44 regardless — that one is about a small
    // hit box being hard to *tap*, not hard to *see*, so it doesn't
    // need the same TV treatment).
    final trackHeight = Responsive.isTV ? 6.0 : 3.0;
    final thumbRadius = Responsive.isTV ? 10.0 : 6.0;
    final overlayRadius = Responsive.isTV ? 24.0 : 16.0;
    final timeFontSize = Responsive.isTV ? 17.0 : 13.0;
    final hitTargetHeight = Responsive.isTV ? 56.0 : 44.0;

    return RepaintBoundary(
      child: LayoutBuilder(
      builder: (context, constraints) {
        const previewWidth = 160.0;
        const previewHeight = 90.0;

        final fraction =
            maxMs == 0 ? 0.0 : (sliderValue / maxMs).clamp(0.0, 1.0);

        // Centers the preview over the thumb, but keeps it fully on
        // screen by clamping to the track's own bounds rather than
        // letting it overhang the left/right edges near the extremes.
        final previewLeft = (fraction * constraints.maxWidth -
                previewWidth / 2)
            .clamp(0.0, (constraints.maxWidth - previewWidth).clamp(
              0.0,
              double.infinity,
            ));

        return Column(
          children: [

            if (showTrickplay || showGrab)
              Padding(
                // Both this and the seek-track Padding below are bare
                // `Padding` widgets, and this one only exists in the
                // tree while `showTrickplay` is true — inserted right
                // as a drag/tap starts. Without keys, Flutter's list
                // reconciliation can't distinguish "a new sibling was
                // inserted at the front" from "the existing sibling
                // changed" — since both are keyless Paddings, it
                // matched by type alone and reused the seek track's
                // *existing* Element (mid-gesture, actively holding
                // the Slider's pointer route) to represent this
                // preview instead, tearing the real Slider down and
                // rebuilding it before it ever got to fire
                // onChangeEnd. That's what made the first tap/drag
                // move the thumb and show the thumbnail but never
                // actually seek. Explicit keys make identity
                // unambiguous so the Slider's Element — and the
                // gesture it's mid-way through handling — survives
                // this insertion untouched.
                key: const ValueKey('trickplay_preview'),
                padding: const EdgeInsets.only(bottom: 10),
                child: SizedBox(
                  width: constraints.maxWidth,
                  height: previewHeight,
                  child: Stack(
                    children: [
                      Positioned(
                        left: previewLeft,
                        child: showGrab
                            ? FramePreview(
                                position: displayedPosition,
                                width: previewWidth,
                                height: previewHeight,
                              )
                            : TrickplayPreview(
                          // Safe: showTrickplay is only true when
                          // trickplayRes is non-null, which itself is
                          // only computed when currentItem is non-null
                          // (see above) — the analyzer just can't carry
                          // that promotion this far, so assert it here.
                          itemId: currentItem!.id,
                          resolution: trickplayRes!,
                          position: displayedPosition,
                          width: previewWidth,
                          height: previewHeight,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

        // A small clearance on each side keeps the thumb and track from
        // crowding the true screen edges — full edge-to-edge looked
        // flush with the bezel and made the thumb hard to grab right at
        // the boundary.
        Padding(
          key: const ValueKey('seek_track'),
          padding: const EdgeInsets.symmetric(
            horizontal: 12,
          ),
          child: SizedBox(
            // Was 20 — well under Android's ~48dp recommended minimum
            // touch target. The Slider's own hit-test area is bounded
            // by this box, so taps landing anywhere off-center (very
            // easy on a thin 3px track) missed it entirely and fell
            // through to the full-screen gesture layer behind it,
            // which is what made tapping the seek bar feel unreliable.
            // The visual track/thumb stay exactly as thin as before —
            // `Alignment.centerLeft` on the Stack just centers them
            // within a taller, more forgiving tap target.
            height: hitTargetHeight,
            child: Stack(
              alignment: Alignment.centerLeft,
              children: [

                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 2,
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: bufferedPercent,
                      minHeight: trackHeight,
                      backgroundColor: Colors.white24,
                      valueColor: const AlwaysStoppedAnimation(
                        Colors.white54,
                      ),
                    ),
                  ),
                ),

                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: trackHeight,
                    activeTrackColor: activeColor,
                    inactiveTrackColor: Colors.transparent,
                    thumbColor: activeColor,
                    overlayColor: activeColor.withValues(alpha: 0.2),
                    trackShape: const _EdgeToEdgeTrackShape(),
                    thumbShape: RoundSliderThumbShape(
                      enabledThumbRadius: thumbRadius,
                    ),
                    overlayShape: RoundSliderOverlayShape(
                      overlayRadius: overlayRadius,
                    ),
                  ),
                  // A live channel's slider can only scrub within its
                  // already-buffered window (0 -> current live edge) —
                  // `max` here IS that live edge, so dragging the thumb
                  // can never seek past "now" into content that hasn't
                  // arrived yet.
                  child: Slider(
                    value: sliderValue,
                    max: maxMs,
                    onChangeStart: (value) {
                      PlayerManager.instance.isSeeking.value = true;

                      setState(() {
                        _dragValue = value;
                      });
                      if (currentItem != null) {
                        FrameGrabber.instance.request(currentItem,
                            Duration(milliseconds: value.round()));
                      }
                    },
                    onChanged: (value) {
                      setState(() {
                        _dragValue = value;
                      });
                      if (currentItem != null) {
                        FrameGrabber.instance.request(currentItem,
                            Duration(milliseconds: value.round()));
                      }
                    },
                    onChangeEnd: (value) async {
                      final target = Duration(milliseconds: value.round());
                      final token = ++_seekToken;

                      // Hold the thumb at the tapped/dragged position
                      // instead of releasing `_dragValue` right away.
                      // Releasing it immediately fell back to
                      // `PlayerManager.instance.position`, which is
                      // still whatever it was *before* this seek — the
                      // player.stream.position update for the new spot
                      // hasn't arrived yet, since seek() is async. That
                      // made the thumb visually snap back to the old
                      // position for a beat, looking exactly like the
                      // tap/drag had done nothing (and on a slower
                      // network/transcoded stream, "a beat" could be
                      // long enough that a user gave up and re-tapped).
                      // Awaiting the seek here and then setting
                      // `position.value` directly — the same pattern
                      // already used for the resume-playback seek in
                      // PlayerManager.playMedia() — means the bar goes
                      // straight from "held at the target" to "at the
                      // target", with no stale-position flash in
                      // between.
                      // Through PlayerManager: at Data Saver / Default the
                      // movie is a live transcode that can't be seeked in
                      // place, so it reopens at the target instead (see
                      // PlayerManager.seekTo). Plain seek everywhere else.
                      await PlayerManager.instance.seekTo(target);

                      if (!mounted || token != _seekToken) return;

                      PlayerManager.instance.position.value = target;

                      setState(() {
                        _dragValue = null;
                      });

                      PlayerManager.instance.isSeeking.value = false;
                    },
                  ),
                ),
              ],
            ),
          ),
        ),

        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: 16,
          ),
          child: Row(
            children: [

              // Playback was asked to start but the seconds are not
              // running yet (still loading / buffering at 00:00): a small
              // gold spinner instead of a frozen "00:00".
              AnimatedBuilder(
                animation: Listenable.merge([
                  PlayerManager.instance.playing,
                  PlayerManager.instance.buffering,
                  PlayerManager.instance.loading,
                ]),
                builder: (context, _) {
                  final manager = PlayerManager.instance;
                  final waitingToStart = !live &&
                      _dragValue == null &&
                      displayedPosition < const Duration(seconds: 1) &&
                      (manager.playing.value ||
                          manager.buffering.value ||
                          manager.loading.value);
                  return StartWaitLabel(
                    waiting: waitingToStart,
                    fontSize: timeFontSize,
                    child: Text(
                      format(displayedPosition),
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: timeFontSize,
                        fontFeatures: const [
                          FontFeature.tabularFigures(),
                        ],
                      ),
                    ),
                  );
                },
              ),

              const Spacer(),

              if (live)
                _LiveIndicator(
                  atLiveEdge: atLiveEdge,
                  onTap: () {
                    widget.player.seek(maxDuration);
                  },
                )
              else
                Text(
                  format(maxDuration),
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: timeFontSize,
                    fontFeatures: const [
                      FontFeature.tabularFigures(),
                    ],
                  ),
                ),
            ],
          ),
        ),
          ],
        );
      },
      ),
    );
  }
}

/// Removes the default Slider inset (normally reserved so the thumb never
/// overhangs the edge) so the track runs flush to both edges of its
/// parent, matching the full-width seek bars in apps like Netflix.
class _EdgeToEdgeTrackShape extends RoundedRectSliderTrackShape {
  const _EdgeToEdgeTrackShape();

  @override
  Rect getPreferredRect({
    required RenderBox parentBox,
    Offset offset = Offset.zero,
    required SliderThemeData sliderTheme,
    bool isEnabled = false,
    bool isDiscrete = false,
  }) {
    final trackHeight = sliderTheme.trackHeight ?? 3;
    final trackLeft = offset.dx;
    final trackTop =
        offset.dy + (parentBox.size.height - trackHeight) / 2;
    final trackWidth = parentBox.size.width;

    return Rect.fromLTWH(
      trackLeft,
      trackTop,
      trackWidth,
      trackHeight,
    );
  }
}

/// Right-hand side indicator for the live seek bar, in place of the VOD
/// bar's total-duration text. Solid gold (matching the app's theme,
/// same as the VOD seek bar) while the thumb is at the live edge; an
/// outlined, tappable "GO LIVE" once the user has rewound into the
/// buffer, so they always have a one-tap way back to the live edge —
/// mirroring how DVR-style live TV seek bars behave in apps like
/// YouTube TV or Hulu.
class _LiveIndicator extends StatelessWidget {
  final bool atLiveEdge;
  final VoidCallback onTap;

  static const _gold = Color(0xffD4AF37);

  const _LiveIndicator({
    required this.atLiveEdge,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    // Same TV bump reasoning as the rest of this file's seek bar.
    final dotSize = Responsive.isTV ? 11.0 : 8.0;
    final fontSize = Responsive.isTV ? 15.0 : 12.0;
    final horizontalPadding = Responsive.isTV ? 14.0 : 10.0;
    final verticalPadding = Responsive.isTV ? 6.0 : 4.0;

    return Pressable(
      onTap: atLiveEdge ? null : onTap,
      borderRadius: BorderRadius.circular(4),
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: horizontalPadding,
          vertical: verticalPadding,
        ),
        decoration: BoxDecoration(
          color: atLiveEdge ? _gold : Colors.transparent,
          border: atLiveEdge
              ? null
              : Border.all(color: Colors.white54, width: 1),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.circle,
              color: atLiveEdge ? Colors.black : Colors.white54,
              size: dotSize,
            ),
            const SizedBox(width: 6),
            Text(
              atLiveEdge ? "LIVE" : "GO LIVE",
              style: TextStyle(
                color: atLiveEdge ? Colors.black : Colors.white70,
                fontSize: fontSize,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
