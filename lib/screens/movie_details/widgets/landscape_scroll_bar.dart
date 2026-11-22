import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'backdrop_header.dart' show AccentTintedBar;

/// Slim pinned header for the left column of the landscape split
/// detail layout (movie/series).
///
/// It starts fully transparent — the blurred [LandscapeBackdropBackground]
/// behind it shows straight through — and cross-fades in the same
/// tinted-gradient + small-logo treatment [BackdropHeader] collapses
/// to in portrait, once the column has scrolled past a short
/// threshold. The back button is always visible, independent of that
/// fade, exactly like the portrait header.
class LandscapeScrollBar extends StatelessWidget {
  final String? logoUrl;
  final String accentImageUrl;
  final VoidCallback onBack;
  final ValueListenable<double> scrollOffset;
  final double topPadding;

  const LandscapeScrollBar({
    super.key,
    required this.logoUrl,
    required this.accentImageUrl,
    required this.onBack,
    required this.scrollOffset,
    required this.topPadding,
  });

  @override
  Widget build(BuildContext context) {
    return SliverPersistentHeader(
      pinned: true,
      delegate: _LandscapeScrollBarDelegate(
        logoUrl: logoUrl,
        accentImageUrl: accentImageUrl,
        onBack: onBack,
        scrollOffset: scrollOffset,
        topPadding: topPadding,
      ),
    );
  }
}

class _LandscapeScrollBarDelegate extends SliverPersistentHeaderDelegate {
  final String? logoUrl;
  final String accentImageUrl;
  final VoidCallback onBack;
  final ValueListenable<double> scrollOffset;
  final double topPadding;

  _LandscapeScrollBarDelegate({
    required this.logoUrl,
    required this.accentImageUrl,
    required this.onBack,
    required this.scrollOffset,
    required this.topPadding,
  });

  double get _barHeight => topPadding + 56;

  // How far the column needs to scroll before the tinted bar is fully
  // shown — short enough that it reads as an immediate response to
  // scrolling rather than something you have to scroll a long way to
  // trigger.
  static const double _fadeInDistance = 90;

  @override
  double get minExtent => _barHeight;

  @override
  double get maxExtent => _barHeight;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    return ValueListenableBuilder<double>(
      valueListenable: scrollOffset,
      builder: (context, offset, _) {
        final t = (offset / _fadeInDistance).clamp(0.0, 1.0);

        return Stack(
          fit: StackFit.expand,
          children: [
            IgnorePointer(
              child: Opacity(
                opacity: t,
                child: AccentTintedBar(
                  key: ValueKey(accentImageUrl),
                  accentImageUrl: accentImageUrl,
                  logoUrl: logoUrl,
                  barHeight: _barHeight,
                ),
              ),
            ),

            // Fixed position, always visible — same treatment as the
            // portrait/collapsed BackdropHeader's back button.
            Positioned(
              top: topPadding + 6,
              left: 18,
              child: CircleAvatar(
                radius: 22,
                backgroundColor: Colors.black45,
                child: IconButton(
                  onPressed: onBack,
                  icon: const Icon(Icons.arrow_back, color: Colors.white),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  @override
  bool shouldRebuild(covariant _LandscapeScrollBarDelegate oldDelegate) {
    return oldDelegate.logoUrl != logoUrl ||
        oldDelegate.accentImageUrl != accentImageUrl ||
        oldDelegate.scrollOffset != scrollOffset ||
        oldDelegate.topPadding != topPadding;
  }
}
