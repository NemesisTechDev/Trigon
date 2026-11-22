import 'dart:async';

import 'package:flutter/material.dart';

import '../../widgets/common/artwork_image.dart';
import '../../widgets/common/pressable.dart';

/// "Up Next" card shown near the end of an episode, styled to match
/// [SkipSegmentButton] (same dark translucent card, white12 border,
/// drop shadow, 14px radius, gold accent) so the two read as a matched
/// pair rather than unrelated controls.
///
/// Layout: a dimmed episode thumbnail, "Next episode on {seriesName}"
/// with the "S02E06 · Episode Name" code/title beneath it, then a
/// Dismiss / Play Now button pair inside the bottom of the card.
/// Auto-plays the next episode after a short countdown unless the user
/// dismisses or taps "Play Now" first.
class NextEpisodeOverlay extends StatefulWidget {
  /// The episode's own name, e.g. "Ozymandias".
  final String title;

  /// The parent show's name, e.g. "Breaking Bad" — rendered as "Next
  /// episode on Breaking Bad".
  final String? seriesName;

  /// Pre-formatted "S02E06"-style code. Null/empty when season/episode
  /// numbers aren't known, in which case the code line is omitted.
  final String? episodeCode;

  final String? image;
  final VoidCallback onPlayNow;
  final VoidCallback onCancel;

  /// How many seconds to count down before auto-playing.
  final int countdownSeconds;

  /// Real available width/height from PlayerOverlayLayer's LayoutBuilder
  /// (screen size minus the bottom bar and margins), not a guess. Null
  /// falls back to the old fixed behavior (360 wide, unconstrained
  /// height) — only relevant if this widget is ever used somewhere
  /// that doesn't compute these, e.g. a future preview/test harness.
  final double? maxWidth;
  final double? maxHeight;

  /// Landscape layout: thumbnail on the left, text + buttons on the
  /// right. The stacked (portrait) card is ~340 tall at its 360 design
  /// width, far taller than the strip between the top bar and the seek
  /// bar in landscape, so FittedBox shrank it to under half size. This
  /// layout is ~140 tall, so it stays close to (or at) full size there.
  final bool horizontal;

  const NextEpisodeOverlay({
    super.key,
    required this.title,
    required this.onPlayNow,
    required this.onCancel,
    this.seriesName,
    this.episodeCode,
    this.image,
    this.countdownSeconds = 10,
    this.maxWidth,
    this.maxHeight,
    this.horizontal = false,
  });

  @override
  State<NextEpisodeOverlay> createState() => _NextEpisodeOverlayState();
}

class _NextEpisodeOverlayState extends State<NextEpisodeOverlay> {
  static const _gold = Color(0xffD4AF37);

  late int secondsLeft = widget.countdownSeconds;

  Timer? timer;

  @override
  void initState() {
    super.initState();

    timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (secondsLeft <= 1) {
        t.cancel();
        widget.onPlayNow();
        return;
      }

      setState(() {
        secondsLeft--;
      });
    });
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  Widget _horizontalCard({required bool hasSeries, required bool hasCode}) {
    Widget placeholder() => Container(
          color: Colors.white10,
          child: const Icon(
            Icons.movie_outlined,
            color: Colors.white24,
            size: 32,
          ),
        );

    return Container(
      width: 420,
      decoration: BoxDecoration(
        color: const Color(0xF0121212),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white12),
        boxShadow: const [
          BoxShadow(
            color: Colors.black54,
            blurRadius: 20,
            offset: Offset(0, 8),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Thumbnail column: every child is positioned, so it takes
            // its height from the text column beside it.
            SizedBox(
              width: 176,
              child: Stack(
                children: [
                  Positioned.fill(
                    // ROOT CAUSE (offline "Up Next" thumbnail missing):
                    // widget.image is a local file path when the queue
                    // came from Downloads (DownloadManager sets it to
                    // episodeThumbPath/posterPath, not a Jellyfin URL —
                    // see download_manager.dart), but this was always
                    // rendering it with Image.network, which can only
                    // ever load http(s) URLs. ArtworkImage is the same
                    // remote-vs-local-path switch every other artwork
                    // call site in the app already uses (mini_player,
                    // queue_screen, casting UI) — see artwork_source.dart's
                    // isRemoteArtwork.
                    child: widget.image != null
                        ? ArtworkImage(
                            path: widget.image!,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => placeholder(),
                          )
                        : placeholder(),
                  ),
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.45),
                      ),
                    ),
                  ),
                  Positioned(
                    top: 8,
                    left: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: Colors.white24),
                      ),
                      child: const Text(
                        "Up Next",
                        style: TextStyle(
                          color: _gold,
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.6,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      hasSeries
                          ? "Next episode on ${widget.seriesName}"
                          : "Next episode",
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),

                    const SizedBox(height: 3),

                    Text(
                      hasCode
                          ? "${widget.episodeCode} \u00b7 ${widget.title}"
                          : widget.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),

                    const SizedBox(height: 3),

                    Text(
                      "Playing in ${secondsLeft}s",
                      style: const TextStyle(
                        color: _gold,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),

                    const SizedBox(height: 8),

                    Row(
                      children: [
                        Expanded(
                          child: _CardButton(
                            label: "Dismiss",
                            filled: false,
                            onTap: widget.onCancel,
                          ),
                        ),

                        const SizedBox(width: 8),

                        Expanded(
                          child: _CardButton(
                            label: "Play Now",
                            filled: true,
                            onTap: widget.onPlayNow,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasSeries =
        widget.seriesName != null && widget.seriesName!.isNotEmpty;

    final hasCode =
        widget.episodeCode != null && widget.episodeCode!.isNotEmpty;

    // Built at its full design width/height, unconstrained — FittedBox
    // below scales the whole thing (layout footprint and paint
    // together) down to whatever real room is available, so nothing
    // here needs to guess at a shrink factor or cap its own height.
    final card = widget.horizontal
        ? _horizontalCard(hasSeries: hasSeries, hasCode: hasCode)
        : Container(
      width: 360,
      decoration: BoxDecoration(
        color: const Color(0xF0121212),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white12),
        boxShadow: const [
          BoxShadow(
            color: Colors.black54,
            blurRadius: 20,
            offset: Offset(0, 8),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Dimmed thumbnail
          Stack(
            children: [
              AspectRatio(
                aspectRatio: 16 / 9,
                child: widget.image != null
                    ? ArtworkImage(
                        path: widget.image!,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Container(
                          color: Colors.white10,
                          child: const Icon(
                            Icons.movie_outlined,
                            color: Colors.white24,
                            size: 32,
                          ),
                        ),
                      )
                    : Container(
                        color: Colors.white10,
                        child: const Icon(
                          Icons.movie_outlined,
                          color: Colors.white24,
                          size: 32,
                        ),
                      ),
              ),

              // Uniform dim over the whole thumbnail (not just a bottom
              // gradient) — the card no longer relies on the image for
              // legible text, since the title/code now live below it,
              // but the episode art should still read as a preview
              // rather than full-brightness artwork.
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.45),
                  ),
                ),
              ),

              Positioned(
                top: 8,
                left: 10,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: Colors.white24),
                  ),
                  child: const Text(
                    "Up Next",
                    style: TextStyle(
                      color: _gold,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.6,
                    ),
                  ),
                ),
              ),
            ],
          ),

          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  hasSeries
                      ? "Next episode on ${widget.seriesName}"
                      : "Next episode",
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white54,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),

                const SizedBox(height: 4),

                Text(
                  hasCode
                      ? "${widget.episodeCode} \u00b7 ${widget.title}"
                      : widget.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),

                const SizedBox(height: 4),

                Text(
                  "Playing in ${secondsLeft}s",
                  style: const TextStyle(
                    color: _gold,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),

                const SizedBox(height: 12),

                Row(
                  children: [
                    Expanded(
                      child: _CardButton(
                        label: "Dismiss",
                        filled: false,
                        onTap: widget.onCancel,
                      ),
                    ),

                    const SizedBox(width: 10),

                    Expanded(
                      child: _CardButton(
                        label: "Play Now",
                        filled: true,
                        onTap: widget.onPlayNow,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );

    if (widget.maxWidth == null || widget.maxHeight == null) {
      // No real measured room to fit into (e.g. a preview/test harness
      // that doesn't compute these) — render at the card's natural
      // design size, same as the old fallback behavior.
      return card;
    }

    // Scale the WHOLE card — layout footprint and paint together —
    // down to whatever room PlayerOverlayLayer actually measured, so
    // it always fits regardless of display size. This replaces a
    // fixed 0.85 Transform.scale: Transform.scale only repaints, it
    // never shrinks the box the layout system reserves, so the
    // card's real footprint stayed at its full un-scaled height no
    // matter the 0.85 factor. That factor was tuned against the
    // Pixel 6's "smallest" Android Display size setting (an inflated
    // logical dp canvas) — at the "default" Display size setting the
    // real canvas is smaller, so 0.85 wasn't always enough room, and
    // the SingleChildScrollView that used to wrap this card's content
    // silently scrolled the Dismiss/Play Now row out of view, with no
    // way to discover a scrollbar on a ~10s auto-dismissing overlay.
    //
    // ConstrainedBox (not a fixed-size SizedBox) so this widget's own
    // footprint shrink-wraps the card's actual size, capped at
    // maxWidth/maxHeight as a ceiling rather than reserved as a
    // fixed floor. A SizedBox pinned at the full maxWidth/maxHeight
    // reserved everything from just under the status bar down to the
    // seek bar as this widget's box — PlayerOverlayLayer's
    // Align(bottomRight) then had that whole tall box to place, not
    // the small card inside it, so on a short screen or with the
    // control bar hidden (where maxHeight is nearly the full player
    // height) the card itself could end up sitting well above the
    // seek bar instead of right against it, overlapping the top-right
    // controls. FittedBox still only ever shrinks (never grows past
    // the design size), so the full card — buttons included — always
    // fits, exactly as before.
    if (widget.horizontal) {
      // Landscape: scale the short, wide card UP (not just down) to fill
      // the measured strip between the top bar and the seek bar, limited
      // by whichever of width/height runs out first. Bottom-right aligned
      // so it stays pinned just above the seek bar.
      return SizedBox(
        width: widget.maxWidth!,
        height: widget.maxHeight!,
        child: FittedBox(
          fit: BoxFit.contain,
          alignment: Alignment.bottomRight,
          child: card,
        ),
      );
    }

    return ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: widget.maxWidth!,
        maxHeight: widget.maxHeight!,
      ),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.bottomRight,
        child: card,
      ),
    );
  }
}

/// Shared button styling for the card's bottom action row — a filled
/// gold "Play Now" and an outlined white12 "Dismiss", both built from
/// the same Pressable used across the rest of the player UI rather than
/// default Material buttons, to stay visually consistent with
/// [SkipSegmentButton].
class _CardButton extends StatelessWidget {
  static const _gold = Color(0xffD4AF37);

  final String label;
  final bool filled;
  final VoidCallback onTap;

  const _CardButton({
    required this.label,
    required this.filled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: filled ? _gold : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: filled ? null : Border.all(color: Colors.white24),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: filled ? Colors.black : Colors.white70,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
