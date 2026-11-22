import 'package:flutter/material.dart';

import '../../widgets/common/pressable.dart';

/// "Next Movie" card shown once a movie reaches its Outro/credits segment,
/// if auto-queued recommendations are turned on and the server offered a
/// similar-genre pick. Styled to match [NextEpisodeOverlay] (same card
/// shell, border, shadow, radius, button row) so the two read as the same
/// family of overlay, but the media area itself is deliberately different:
/// a movie doesn't have an episode-style thumbnail to show, so the whole
/// card's backdrop is the recommended movie's own dimmed backdrop image,
/// with its logo (falling back to its title as plain text if it has no
/// logo art) resized to fit and centered on top of it — closer to how a
/// streaming service's "more like this" card reads than a thumbnail-plus-
/// caption.
///
/// Unlike NextEpisodeOverlay, this never auto-plays on a countdown — a
/// movie's credits can carry a post-credits scene worth actually watching,
/// so advancing only happens if the person explicitly taps "Play Now".
class NextMovieOverlay extends StatelessWidget {
  static const _gold = Color(0xffD4AF37);

  /// The recommended movie's title, e.g. "The Dark Knight".
  final String title;

  final String? backdrop;
  final String? logo;

  final VoidCallback onPlayNow;
  final VoidCallback onCancel;

  /// Real available width/height from PlayerOverlayLayer's LayoutBuilder
  /// — see NextEpisodeOverlay's identical fields for the full reasoning.
  final double? maxWidth;
  final double? maxHeight;

  /// Landscape layout: media on the left, text + buttons on the right,
  /// so the card is short and wide. The stacked (portrait) card is ~330
  /// tall at its 360 design width, and the strip between the top bar and
  /// the seek bar in landscape is far shorter than that — FittedBox had
  /// to shrink it to well under half size, which read as tiny. This
  /// layout is ~125 tall, so it stays close to (or at) full size there.
  final bool horizontal;

  const NextMovieOverlay({
    super.key,
    required this.title,
    required this.onPlayNow,
    required this.onCancel,
    this.backdrop,
    this.logo,
    this.maxWidth,
    this.maxHeight,
    this.horizontal = false,
  });

  @override
  Widget build(BuildContext context) {
    // Built at its full design width, unconstrained — FittedBox below
    // scales the whole thing (layout footprint and paint together)
    // down to whatever real room is available. See NextEpisodeOverlay's
    // build() for the full reasoning on why this replaced a fixed
    // Transform.scale(0.85) + SingleChildScrollView.
    final card = horizontal ? _horizontalCard() : Container(
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
          // Dimmed backdrop with the movie's logo centered on top
          Stack(
            children: [
              AspectRatio(
                aspectRatio: 16 / 9,
                child: backdrop != null
                    ? Image.network(
                        backdrop!,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Container(
                          color: Colors.white10,
                          child: const Icon(
                            Icons.local_movies_outlined,
                            color: Colors.white24,
                            size: 32,
                          ),
                        ),
                      )
                    : Container(
                        color: Colors.white10,
                        child: const Icon(
                          Icons.local_movies_outlined,
                          color: Colors.white24,
                          size: 32,
                        ),
                      ),
              ),

              // Same uniform dim treatment as NextEpisodeOverlay's
              // thumbnail, just over the full card-width backdrop here
              // instead of an episode still.
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.5),
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

              // The logo is the whole point of this layout — resized to
              // fit the available area rather than shown at native size,
              // since Jellyfin's logo art comes in wildly varying source
              // dimensions. Falls back to the plain title (still
              // centered) for the common case of a movie with no logo
              // art uploaded, or if the logo image fails to load.
              Positioned.fill(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 28,
                    vertical: 20,
                  ),
                  child: Center(
                    child: logo != null
                        ? Image.network(
                            logo!,
                            fit: BoxFit.contain,
                            errorBuilder: (_, __, ___) => _TitleFallback(
                              title: title,
                            ),
                          )
                        : _TitleFallback(title: title),
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
                const Text(
                  "Recommended to watch",
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white54,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),

                const SizedBox(height: 4),

                Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
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
                        onTap: onCancel,
                      ),
                    ),

                    const SizedBox(width: 10),

                    Expanded(
                      child: _CardButton(
                        label: "Play Now",
                        filled: true,
                        onTap: onPlayNow,
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

    if (maxWidth == null || maxHeight == null) {
      // No real measured room to fit into (e.g. a preview/test harness
      // that doesn't compute these) — render at the card's natural
      // design size, same as the old fallback behavior.
      return card;
    }

    // Scale the whole card to fit the real measured room, and
    // shrink-wrap this widget's own footprint to the card's actual
    // size (capped at maxWidth/maxHeight) rather than reserving the
    // full available box — see NextEpisodeOverlay's build() for the
    // full reasoning on why a fixed-size SizedBox here left the card
    // sitting too high, clear of the seek bar it's meant to pin to.
    if (horizontal) {
      // Landscape: scale the short, wide card UP (not just down) to fill
      // the measured strip between the top bar and the seek bar, limited
      // by whichever of width/height runs out first. Bottom-right aligned
      // so it stays pinned just above the seek bar.
      return SizedBox(
        width: maxWidth!,
        height: maxHeight!,
        child: FittedBox(
          fit: BoxFit.contain,
          alignment: Alignment.bottomRight,
          child: card,
        ),
      );
    }

    return ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: maxWidth!,
        maxHeight: maxHeight!,
      ),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.bottomRight,
        child: card,
      ),
    );
  }

  Widget _horizontalCard() {
    Widget placeholder() => Container(
          color: Colors.white10,
          child: const Icon(
            Icons.local_movies_outlined,
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
            // Media column: every child is positioned, so it takes its
            // height from the text column beside it.
            SizedBox(
              width: 176,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: backdrop != null
                        ? Image.network(
                            backdrop!,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => placeholder(),
                          )
                        : placeholder(),
                  ),
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.5),
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
                  Positioned.fill(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(14, 30, 14, 12),
                      child: Center(
                        child: logo != null
                            ? Image.network(
                                logo!,
                                fit: BoxFit.contain,
                                errorBuilder: (_, __, ___) =>
                                    _TitleFallback(title: title),
                              )
                            : _TitleFallback(title: title),
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
                    const Text(
                      "Recommended to watch",
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white54,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),

                    const SizedBox(height: 3),

                    Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),

                    const SizedBox(height: 10),

                    Row(
                      children: [
                        Expanded(
                          child: _CardButton(
                            label: "Dismiss",
                            filled: false,
                            onTap: onCancel,
                          ),
                        ),

                        const SizedBox(width: 8),

                        Expanded(
                          child: _CardButton(
                            label: "Play Now",
                            filled: true,
                            onTap: onPlayNow,
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
}

/// Centered title text shown in place of the movie's logo, when it has
/// none or the logo image failed to load.
class _TitleFallback extends StatelessWidget {
  final String title;

  const _TitleFallback({required this.title});

  @override
  Widget build(BuildContext context) {
    return Text(
      title,
      textAlign: TextAlign.center,
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 20,
        fontWeight: FontWeight.w700,
        shadows: [
          Shadow(color: Colors.black87, blurRadius: 10),
        ],
      ),
    );
  }
}

/// Same shared button styling as NextEpisodeOverlay's _CardButton — kept
/// as its own private copy here rather than exported/shared, matching how
/// this codebase already treats each overlay's button row as a self-
/// contained detail rather than a shared component.
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
