import 'package:flutter/material.dart';

import '../../../utils/responsive.dart';
import '../../../widgets/common/empty_state.dart';
import '../../../widgets/music/album_card.dart';
import '../music_detail_screen.dart';

/// Sliver album grid — the music-genre counterpart to MovieGrid, used
/// by TagItemsScreen when it's showing "albums in this genre" rather
/// than "titles with this tag/studio". Deliberately mirrors the Music
/// tab's own Albums grid (same AlbumCard, same square-cover-plus-
/// label sizing math) so a genre grid looks identical to the regular
/// Albums tab instead of borrowing MovieGrid's poster-shaped cards.
///
/// Column count and cell sizing are computed via [Responsive] (which
/// reads a published InheritedWidget width, not a LayoutBuilder) rather
/// than a LayoutBuilder directly — this is used inside a
/// CustomScrollView's slivers list, and a LayoutBuilder there causes
/// element-reparenting crashes (see MovieGrid, which takes the same
/// approach for the same reason).
class AlbumGrid extends StatelessWidget {
  final bool loading;
  final List<dynamic> items;
  final ValueChanged<dynamic>? onItemTap;

  final IconData emptyIcon;
  final String emptyTitle;
  final String? emptySubtitle;

  const AlbumGrid({
    super.key,
    required this.loading,
    required this.items,
    this.onItemTap,
    this.emptyIcon = Icons.album_outlined,
    this.emptyTitle = "No albums found",
    this.emptySubtitle,
  });

  // AlbumCard is a square cover followed by an 8px gap + two label
  // lines (title, artist) — same fixed label-block height the Music
  // tab's own grid computes its cell extent from (see
  // _squareCardMainAxisExtent in music_screen.dart).
  static const double _labelHeight = 48;

  double _cellWidth(BuildContext context, int crossAxisCount) {
    // Responsive.gridContentWidth already subtracts this grid's own
    // SliverPadding (20 left + 20 right = 40, its default) and is
    // rail-aware in landscape — previously this method took a raw
    // MediaQuery width and hardcoded the same 40px assumption locally,
    // which (like the old column count below) never accounted for the
    // landscape NavigationRail eating into the real available width.
    const crossAxisSpacing = 12.0;
    final usableWidth = Responsive.gridContentWidth(context) -
        crossAxisSpacing * (crossAxisCount - 1);
    return usableWidth / crossAxisCount;
  }

  double _mainAxisExtent(BuildContext context, int crossAxisCount) {
    return _cellWidth(context, crossAxisCount) + _labelHeight;
  }

  @override
  Widget build(BuildContext context) {
    // Centralized, rail-aware column rule (Phase 2) — was previously a
    // hand-rolled 480/700/1000 breakpoint ladder duplicated across this
    // file, music_screen.dart, and all_channels_screen.dart, none of
    // which accounted for the landscape NavigationRail.
    final crossAxisCount =
        Responsive.gridColumnsForType(context, GridContentType.album);
    final cellWidth = _cellWidth(context, crossAxisCount);

    final gridDelegate = SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: crossAxisCount,
      mainAxisExtent: _mainAxisExtent(context, crossAxisCount),
      crossAxisSpacing: 12,
      mainAxisSpacing: 12,
    );

    /// Loading
    if (loading) {
      return SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        sliver: SliverGrid(
          gridDelegate: gridDelegate,
          delegate: SliverChildBuilderDelegate(
            (_, __) => Container(
              decoration: BoxDecoration(
                color: const Color(0xFF242424),
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            childCount: 12,
          ),
        ),
      );
    }

    /// Empty
    if (items.isEmpty) {
      return SliverFillRemaining(
        hasScrollBody: false,
        child: Center(
          child: EmptyState(
            icon: emptyIcon,
            title: emptyTitle,
            subtitle: emptySubtitle,
          ),
        ),
      );
    }

    /// Albums
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      sliver: SliverGrid(
        gridDelegate: gridDelegate,
        delegate: SliverChildBuilderDelegate(
          (context, index) {
            final item = items[index];

            return AlbumCard(
              album: item,
              decodeWidth: cellWidth,
              onTap: () {
                if (onItemTap != null) {
                  onItemTap!(item);
                  return;
                }

                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => MusicDetailScreen(
                      itemId: item["Id"],
                      initialItem: Map<String, dynamic>.from(item),
                    ),
                  ),
                );
              },
            );
          },
          childCount: items.length,
        ),
      ),
    );
  }
}
