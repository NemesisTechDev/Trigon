import 'package:flutter/material.dart';

import '../../player/models/media_item.dart';
import '../../player/services/trickplay_service.dart';
import '../../player/widgets/trickplay_preview.dart';
import '../../widgets/common/start_wait_label.dart';
import '../models/cast_states.dart';
import '../cast_manager.dart';
import '../models/cast_capability.dart';
import '../models/cast_session.dart';
import 'cast_ui.dart';

/// The seek slider + position/duration row shown above
/// [CastTransportControls] on both `CastingActivePanel`'s fullscreen
/// panel and the connected-session sheet. Pulled out of both files
/// (Casting Phase 12) since they carried byte-for-byte identical copies
/// of this widget — one shared implementation now, rather than two
/// copies that can silently drift apart.
///
/// SMOOTH-SEEK-BAR FIX: this used to call `manager.seek()` from
/// `onChanged`, which fires on every pixel of drag movement — that
/// spammed a network seek command at the TV dozens of times per drag
/// gesture and fought with `CastSession`'s position interpolator (each
/// in-flight command's eventual authoritative reply would yank the bar
/// toward wherever it had landed, not where the finger currently was),
/// which is exactly what read as "seeking feels laggy". Now a drag only
/// updates local, in-widget state (`_dragValue`) for instant visual
/// feedback, and a single seek is committed via `onChangeEnd` once the
/// person actually releases the thumb.
///
/// TRICKPLAY SCRUB PREVIEW: while dragging, this shows the same
/// sprite-sheet scrub thumbnail `PlayerSeekBar` shows for local playback
/// (via the shared `TrickplayService`/`TrickplayPreview`), positioned
/// above the thumb — the person driving playback on a TV from across the
/// room has no other way to see what a given point in the timeline
/// actually looks like before committing to it. Offered for all three
/// transports, including Google Cast: every transport's `currentItem`
/// is a real Jellyfin library item, and `CastManager._augmentCastItem`
/// (wired to `session.currentItem`'s listener at connect time,
/// regardless of transport) backfills `MediaStreams`/`Trickplay` the
/// same way for all of them, so the data this preview needs is already
/// there by the time anything is actually playing.
///
/// GOOGLE CAST FIX: this used to explicitly exclude
/// `CastTransportKind.googleCast` on the theory that the Default Media
/// Receiver's own on-TV scrub preview covered the need — but that
/// preview only ever shows on the TV itself, not on the phone doing the
/// actual dragging, which is exactly the "no thumbnails to help with
/// seeking" gap for Google Cast. Nothing else about how the preview is
/// resolved/prefetched/rendered needed to change: it was already
/// transport-agnostic, keyed only off `session.currentItem`.
///
/// SEEK-THUMBNAIL SCOPE FIX: this preview is meant to live on
/// `CastingActivePanel`'s fullscreen panel only — the connected-session
/// sheet is a small bottom sheet, not the dedicated casting video player
/// screen, and showing a 160x90 scrub thumbnail there crowded the sheet
/// and duplicated a feature that belongs to the fullscreen surface.
/// [enableTrickplayPreview] defaults to true (the fullscreen panel's
/// behavior) and the connected-session sheet passes false to suppress it
/// — the rest of the bar (slider, position/duration labels) is
/// unaffected either way.
class CastSeekBar extends StatefulWidget {
  const CastSeekBar({
    super.key,
    required this.session,
    required this.capability,
    this.enableTrickplayPreview = true,
  });

  final CastSession session;
  final CastCapability capability;

  /// Whether this bar is allowed to show the trickplay scrub preview at
  /// all. See the class doc's SEEK-THUMBNAIL SCOPE FIX note.
  final bool enableTrickplayPreview;

  @override
  State<CastSeekBar> createState() => _CastSeekBarState();
}

class _CastSeekBarState extends State<CastSeekBar> {
  /// Non-null only while the person is actively dragging the thumb —
  /// the slider shows this instead of the live (interpolated) position
  /// so the drag itself feels immediate, without touching the network
  /// or the session's position notifier until release.
  double? _dragValue;

  /// Same caching pattern as `PlayerSeekBar._trickplayRes`/
  /// `_trickplayResItemId`/`_trickplayResSourceMap`: `TrickplayService.resolve()`
  /// walks/sorts the item's trickplay map, which is cheap once but
  /// shouldn't re-run on every rebuild a drag triggers. Re-resolved when
  /// the cast session's `currentItem` changes to a different item, OR
  /// when the same item's trickplay map is replaced with a new one.
  ///
  /// SEEK-THUMBNAIL FIX (this was the actual stuck-thumbnail bug): this
  /// used to key off `item.id` alone, matching only the *first* half of
  /// `PlayerSeekBar`'s fix. `CastManager._augmentCastItem`/
  /// `_ensureFullMediaItem` backfill a freshly-copyWith'd `MediaItem`
  /// (new trickplay map, same id) onto `session.currentItem.value` once
  /// the real Trickplay data is available — which correctly makes the
  /// `ValueListenableBuilder` below rebuild, but an id-only check here
  /// then saw "same id" and skipped re-resolving, permanently pinning
  /// `_trickplayRes` to whatever the very first build for that item
  /// resolved: null for most TV episodes (episode lists are fetched
  /// without Trickplay by design) or an incomplete resolution for a
  /// movie whose details-screen snapshot predated generation finishing.
  /// That's what made scrubbing a cast title look "stuck on one image"
  /// even after the equivalent fix already shipped for local playback.
  /// Tracking the map's own identity, same as `PlayerSeekBar`, is what
  /// actually closes it.
  TrickplayResolution? _trickplayRes;
  String? _trickplayResItemId;
  Map<String, dynamic>? _trickplayResSourceMap;

  /// Mirrors `PlayerSeekBar._trickplayPrefetchedItemId` — makes sure the
  /// sprite-sheet tiles for a given cast item are only ever warmed into
  /// the shared image cache once, right when this bar first sees that
  /// item, rather than re-firing on every drag-triggered rebuild. Also
  /// tracks the trickplay map's identity for the same reason
  /// `_trickplayResSourceMap` above does: without it, a backfilled
  /// resolution (better than whatever this bar first saw) would never
  /// get its own tiles prefetched — they'd still render correctly (via
  /// `_trickplayRes` above) once fixed, just without the warm cache, so
  /// every tile past what the stale snapshot covered would fetch live
  /// on first scrub instead of being ready ahead of time.
  String? _trickplayPrefetchedItemId;
  Map<String, dynamic>? _trickplayPrefetchedSourceMap;

  @override
  Widget build(BuildContext context) {
    final manager = CastManager.instance;

    // GOOGLE CAST FIX: all three transports cast a real Jellyfin library
    // item through `CastSession.currentItem`, backfilled with
    // `Trickplay` metadata the same way regardless of transport (see
    // this widget's class doc comment) — so trickplay is no longer
    // scoped to just Jellyfin Remote/Nemesis Native here. Still gated on
    // `enableTrickplayPreview` — false for the connected-session sheet,
    // which never resolves or prefetches trickplay tiles at all (see
    // SEEK-THUMBNAIL SCOPE FIX above).
    final supportsTrickplay = widget.enableTrickplayPreview;

    return ValueListenableBuilder<MediaItem?>(
      valueListenable: widget.session.currentItem,
      builder: (context, item, __) {
        if (supportsTrickplay &&
            (item?.id != _trickplayResItemId ||
                !identical(item?.trickplay, _trickplayResSourceMap))) {
          _trickplayResItemId = item?.id;
          _trickplayResSourceMap = item?.trickplay;
          _trickplayRes = item != null ? TrickplayService.resolve(item) : null;

          // DIAGNOSTIC (trickplay stuck-thumbnail investigation): see
          // the matching log in PlayerSeekBar — fires only on a genuine
          // item/data change, filter logcat for "TRICKPLAY" to compare
          // the two.
          final res = _trickplayRes;
          if (res != null) {
            final coveredMs = res.thumbnailCount * res.intervalMs;
            debugPrint(
              'TRICKPLAY (cast): item=${item?.id} title="${item?.title}" '
              'chosenWidth=${res.width} thumbnailCount=${res.thumbnailCount} '
              'intervalMs=${res.intervalMs} tileGrid=${res.tileWidth}x${res.tileHeight} '
              'coveredMs=$coveredMs runtimeMs=${item?.runtime.inMilliseconds} '
              'mediaSourceId=${res.mediaSourceId}',
            );
          } else if (item != null) {
            debugPrint(
              'TRICKPLAY (cast): item=${item.id} title="${item.title}" '
              'resolve() -> null (no usable trickplay data yet)',
            );
          }
        } else if (!supportsTrickplay) {
          _trickplayRes = null;
        }

        final trickplayRes = _trickplayRes;

        // Warm the sprite-sheet cache as soon as this item shows up on
        // the seek bar, well before any drag — same reasoning as
        // `PlayerSeekBar`: by the time the person actually scrubs, the
        // tile they land on is far more likely to already be decoded
        // and sitting in `NemesisImageCache` than to trigger a live
        // fetch mid-gesture, which is what would otherwise read as a
        // stall on a slow connection to the TV.
        if (item != null &&
            trickplayRes != null &&
            (item.id != _trickplayPrefetchedItemId ||
                !identical(item.trickplay, _trickplayPrefetchedSourceMap))) {
          _trickplayPrefetchedItemId = item.id;
          _trickplayPrefetchedSourceMap = item.trickplay;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              TrickplayService.prefetchAll(
                context,
                item.id,
                trickplayRes,
                priorityPosition: widget.session.position.value,
              );
            }
          });
        }

        return ValueListenableBuilder<Duration>(
          valueListenable: widget.session.position,
          builder: (context, position, __) {
            return ValueListenableBuilder<Duration>(
              valueListenable: widget.session.duration,
              builder: (context, duration, __) {
                final liveRatio = duration.inMilliseconds > 0
                    ? (position.inMilliseconds / duration.inMilliseconds)
                        .clamp(0.0, 1.0)
                    : 0.0;
                final ratio = _dragValue ?? liveRatio;
                final displayedPosition =
                    _dragValue != null ? duration * _dragValue! : position;

                // Only worth showing mid-drag — any other time it would
                // just be a frozen, stale thumbnail sitting above the
                // bar, exactly as `PlayerSeekBar` reasons for local
                // playback. SEEK-THUMBNAIL FIX (part 5): no longer also
                // gated on a metadata-based "has data" check — see
                // `TrickplayService.frameFor`'s doc comment for why
                // `thumbnailCount` turned out not to be trustworthy
                // enough for that; `TrickplayPreview` now finds out by
                // actually requesting the tile and hides itself on a
                // real failure instead.
                final showTrickplay =
                    _dragValue != null && trickplayRes != null;

                return LayoutBuilder(
                  builder: (context, constraints) {
                    const previewWidth = 160.0;
                    const previewHeight = 90.0;

                    final previewLeft = showTrickplay
                        ? (ratio * constraints.maxWidth - previewWidth / 2)
                            .clamp(
                              0.0,
                              (constraints.maxWidth - previewWidth)
                                  .clamp(0.0, double.infinity),
                            )
                        : 0.0;

                    return Column(
                      children: [
                        // POP-UP TIMING FIX: this used to wrap the
                        // preview in `AnimatedSize` with a 260ms
                        // easeOutCubic ease — a "cinematic" slow expand
                        // that made the preview feel laggy compared to
                        // the local player's seek bar. Reverted to the
                        // same plain `if (showTrickplay) Padding(...)`
                        // list entry `PlayerSeekBar` uses: Flutter just
                        // inserts/removes it outright, so it now pops up
                        // instantly, identically to the normal video
                        // player screen.
                        if (showTrickplay)
                          Padding(
                            // Explicit key for the same reason
                            // `PlayerSeekBar` gives one to its own
                            // trickplay Padding: without it, Flutter can
                            // match this newly-inserted sibling against
                            // the SliderTheme below by type alone and
                            // reuse *its* Element instead, tearing the
                            // live Slider down mid-drag.
                            key: const ValueKey('cast_trickplay_preview'),
                            padding: const EdgeInsets.only(bottom: 8),
                            child: SizedBox(
                              width: constraints.maxWidth,
                              height: previewHeight,
                              child: Stack(
                                children: [
                                  Positioned(
                                    left: previewLeft,
                                    child: TrickplayPreview(
                                      itemId: item!.id,
                                      resolution: trickplayRes,
                                      position: displayedPosition,
                                      width: previewWidth,
                                      height: previewHeight,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            trackHeight: 2.5,
                            thumbShape: const RoundSliderThumbShape(
                                enabledThumbRadius: 6),
                            activeTrackColor: castGold,
                            inactiveTrackColor: Colors.white12,
                            thumbColor: castGold,
                          ),
                          child: Slider(
                            value: ratio,
                            onChanged: widget.capability.seek &&
                                    duration > Duration.zero
                                ? (v) => setState(() => _dragValue = v)
                                : null,
                            onChangeEnd: widget.capability.seek
                                ? (v) {
                                    final target = duration * v;
                                    setState(() => _dragValue = null);
                                    runCastCommand(
                                      context,
                                      () => manager.seek(target),
                                    );
                                  }
                                : null,
                          ),
                        ),
                        Padding(
                          padding:
                              const EdgeInsets.symmetric(horizontal: 4),
                          child: Row(
                            mainAxisAlignment:
                                MainAxisAlignment.spaceBetween,
                            children: [
                              // The TV was told to play but its seconds
                              // are not running yet (loading/buffering at
                              // 0:00): a small gold spinner instead of a
                              // frozen "0:00".
                              ValueListenableBuilder<CastPlaybackState>(
                                valueListenable:
                                    widget.session.playbackState,
                                builder: (context, state, __) {
                                  final waitingToStart = _dragValue == null &&
                                      displayedPosition <
                                          const Duration(seconds: 1) &&
                                      (state == CastPlaybackState.loading ||
                                          state ==
                                              CastPlaybackState.buffering);
                                  return StartWaitLabel(
                                    waiting: waitingToStart,
                                    fontSize: 11,
                                    child: Text(
                                      formatCastDuration(displayedPosition),
                                      style: const TextStyle(
                                          color: Colors.white54,
                                          fontSize: 11),
                                    ),
                                  );
                                },
                              ),
                              Text(
                                formatCastDuration(duration),
                                style: const TextStyle(
                                    color: Colors.white54, fontSize: 11),
                              ),
                            ],
                          ),
                        ),
                      ],
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
}
