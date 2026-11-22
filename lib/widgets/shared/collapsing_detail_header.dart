import 'package:flutter/material.dart';

import '../../screens/movie_details/widgets/backdrop_header.dart'
    show AccentTintedBar;

typedef ExpandedHeaderBuilder = Widget Function(BuildContext context, double t);

/// Generic collapsing header for detail screens outside movies/TV shows
/// (music album/artist/playlist, live TV channel) that mirrors the exact
/// collapsed-bar treatment [BackdropHeader] uses there: pinned, a
/// gradient tinted with a color pulled from [accentImageUrl] fades in as
/// the header collapses, with [collapsedLogoUrl] (when given) shown
/// small on the left — same position/size/behavior as the movie and
/// collection detail screens' collapsed logo.
///
/// The expanded (uncollapsed) look is entirely up to [expandedBuilder] —
/// each screen keeps its own backdrop/gradient/big-logo layout exactly
/// as before; this widget only adds the collapsing mechanics, the
/// collapsed identity bar, and the fixed back button on top of it.
class CollapsingDetailHeader extends StatelessWidget {
  final double expandedHeight;
  final ExpandedHeaderBuilder expandedBuilder;
  final VoidCallback onBack;
  final String accentImageUrl;
  final String? collapsedLogoUrl;

  const CollapsingDetailHeader({
    super.key,
    required this.expandedHeight,
    required this.expandedBuilder,
    required this.onBack,
    required this.accentImageUrl,
    this.collapsedLogoUrl,
  });

  @override
  Widget build(BuildContext context) {
    final topPadding = MediaQuery.paddingOf(context).top;

    return SliverPersistentHeader(
      pinned: true,
      delegate: _CollapsingDetailHeaderDelegate(
        expandedHeight: expandedHeight,
        expandedBuilder: expandedBuilder,
        onBack: onBack,
        accentImageUrl: accentImageUrl,
        collapsedLogoUrl: collapsedLogoUrl,
        topPadding: topPadding,
      ),
    );
  }
}

class _CollapsingDetailHeaderDelegate extends SliverPersistentHeaderDelegate {
  final double expandedHeight;
  final ExpandedHeaderBuilder expandedBuilder;
  final VoidCallback onBack;
  final String accentImageUrl;
  final String? collapsedLogoUrl;
  final double topPadding;

  _CollapsingDetailHeaderDelegate({
    required this.expandedHeight,
    required this.expandedBuilder,
    required this.onBack,
    required this.accentImageUrl,
    required this.collapsedLogoUrl,
    required this.topPadding,
  });

  double get _collapsedHeight => topPadding + 56;

  @override
  double get minExtent => _collapsedHeight;

  @override
  double get maxExtent => expandedHeight;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    final range = (maxExtent - minExtent).clamp(1.0, double.infinity);
    final t = (shrinkOffset / range).clamp(0.0, 1.0);

    return SizedBox(
      height: expandedHeight,
      child: Stack(
        fit: StackFit.expand,
        children: [
          expandedBuilder(context, t),

          /// Collapsed identity — gradient tint + small logo, cross-fading
          /// in as the header collapses. Same paint as the movie/
          /// collection detail screens' collapsed bar.
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: minExtent,
            child: IgnorePointer(
              child: Opacity(
                opacity: t,
                child: AccentTintedBar(
                  key: ValueKey(accentImageUrl),
                  accentImageUrl: accentImageUrl,
                  logoUrl: collapsedLogoUrl,
                  barHeight: minExtent,
                ),
              ),
            ),
          ),

          /// Back button — fixed position, always visible, matching the
          /// movie/collection detail screens' back button exactly.
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
      ),
    );
  }

  @override
  bool shouldRebuild(covariant _CollapsingDetailHeaderDelegate oldDelegate) {
    return oldDelegate.expandedHeight != expandedHeight ||
        oldDelegate.accentImageUrl != accentImageUrl ||
        oldDelegate.collapsedLogoUrl != collapsedLogoUrl ||
        oldDelegate.topPadding != topPadding;
  }
}
