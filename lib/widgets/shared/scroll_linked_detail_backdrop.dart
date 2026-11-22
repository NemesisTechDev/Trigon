import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

const Color _pageBg = Color(0xff161616);

/// Height of the collapsing header sliver (CollapsingDetailHeader's
/// `expandedHeight`) on the portrait album / artist / playlist / Live TV
/// detail screens. Shared so the sliver and the backdrop layer below can
/// never drift apart.
const double kDetailHeaderHeight = 320;

/// How far the portrait backdrop reaches *below* the header sliver, so the
/// icon / logo block that starts right under the header (24px padding, see
/// each screen's first SliverToBoxAdapter) sits on the lower, faded part of
/// the backdrop — same look as the poster on the movie detail screen.
///
/// Sized against the icon itself (155dp art on the music screens, 84dp logo
/// on Live TV), which is also a fixed dp value — so the two scale together on
/// every Display size and the overlap stays the same everywhere.
const double kDetailBackdropExtension = 150;

/// Reports the vertical scroll offset of the scroll view it wraps into
/// [offset] (never rebuilds [child] itself — it only feeds the notifier).
///
/// Only the wrapped view's own vertical notifications count (`depth == 0`);
/// nested horizontal rows (More Like This, More Channels…) bubble through
/// the outer viewport with a higher depth and are ignored. Returns false so
/// ResistiveRefresh / FadeScrollbar and friends still see every notification.
class ScrollOffsetReporter extends StatelessWidget {
  final ValueNotifier<double> offset;
  final Widget child;

  const ScrollOffsetReporter({
    super.key,
    required this.offset,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification.depth == 0 &&
            notification.metrics.axis == Axis.vertical) {
          offset.value = notification.metrics.pixels;
        }
        return false;
      },
      child: child,
    );
  }
}

/// Portrait backdrop for the album / artist / playlist / Live TV detail
/// screens, painted *behind* the CustomScrollView instead of inside the
/// pinned header sliver.
///
/// ROOT CAUSE this exists: the icon block lives in the content slivers right
/// under the header, so to have the icon overlap the backdrop the backdrop
/// has to reach below the header's bottom edge (by
/// [kDetailBackdropExtension]). A viewport paints its FIRST sliver LAST (that
/// is what lets a pinned header sit on top of scrolling content), so a header
/// that simply painted (or was made) taller would cover the icon instead of
/// sitting under it — and making it taller would also push all the content
/// down. Drawing the backdrop in the page Stack below the scroll view fixes
/// both: the header sliver keeps its exact size (so nothing moves) and the
/// content paints on top of the backdrop.
///
/// To behave like the old in-header backdrop it tracks the scroll offset:
/// anchored to the top, its height shrinks 1:1 with the scroll, so its bottom
/// edge stays [kDetailBackdropExtension] below the top of the content and it
/// scrolls away with the page. [child] (image + its linear gradient) is
/// laid out to fill the current height, so the gradient always ends fully
/// opaque page-color at the bottom edge — no seam at any scroll position.
///
/// Must be a direct child of the page's Stack (it returns a Positioned).
class ScrollLinkedDetailBackdrop extends StatelessWidget {
  /// Vertical scroll offset of the page's scroll view — see
  /// [ScrollOffsetReporter].
  final ValueListenable<double> scrollOffset;

  /// The backdrop art plus its gradient, built once to fill whatever height
  /// this widget currently has.
  final Widget child;

  /// When set, a flat page-color scrim fades in over the backdrop as the
  /// scroll offset approaches this distance (0 at rest, fully opaque at
  /// [collapseFadeRange]). Same effect the Live TV header's own `t`-driven
  /// scrim had: pass `kDetailHeaderHeight - (topPadding + 56)`, the header's
  /// collapse distance.
  final double? collapseFadeRange;

  const ScrollLinkedDetailBackdrop({
    super.key,
    required this.scrollOffset,
    required this.child,
    this.collapseFadeRange,
  });

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: IgnorePointer(
        child: ValueListenableBuilder<double>(
          valueListenable: scrollOffset,
          child: child,
          builder: (context, offset, backdrop) {
            // Negative offsets (iOS-style overscroll) are clamped: the
            // backdrop never grows past its resting height.
            final scrolled = math.max(0.0, offset);
            final height = math.max(
              0.0,
              kDetailHeaderHeight + kDetailBackdropExtension - scrolled,
            );
            final fadeRange = collapseFadeRange;

            return SizedBox(
              height: height,
              child: fadeRange == null
                  ? backdrop
                  : Stack(
                      fit: StackFit.expand,
                      children: [
                        backdrop!,
                        Container(
                          color: _pageBg.withValues(
                            alpha:
                                (scrolled / math.max(1.0, fadeRange))
                                    .clamp(0.0, 1.0),
                          ),
                        ),
                      ],
                    ),
            );
          },
        ),
      ),
    );
  }
}
