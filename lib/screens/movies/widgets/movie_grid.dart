import 'package:flutter/material.dart';

import '../../../utils/responsive.dart';
import '../../../widgets/common/empty_state.dart';
import '../../../widgets/music/song_multi_select.dart';
import '../../movie_details/movie_details_screen.dart';
import 'loading_card.dart';
import 'movie_card.dart';
import 'title_selection_actions.dart';

class MovieGrid extends StatelessWidget {
  final bool loading;
  final List<dynamic> items;
  final ValueChanged<dynamic>? onItemTap;

  // Press-and-hold a poster to start a multi-select (Movies and TV Shows
  // screens), then tap more posters to add / remove them. The owning
  // screen holds this object (so it can show the selection bar) and
  // rebuilds when [onSelectionChanged] fires. Null elsewhere, so other
  // grids behave as before.
  final SongMultiSelect? selection;
  final VoidCallback? onSelectionChanged;

  // Lets callers tailor the empty state to what's actually being shown
  // (Movies vs TV Shows vs a specific library) instead of the one
  // generic "No movies found" message every mode used to share.
  final IconData emptyIcon;
  final String emptyTitle;
  final String? emptySubtitle;

  // True when the selected library is blocked by Parental Controls: shown
  // instead of the loading skeleton / empty state / posters.
  final bool blocked;

  const MovieGrid({
    super.key,
    required this.loading,
    required this.items,
    this.onItemTap,
    this.selection,
    this.onSelectionChanged,
    this.emptyIcon = Icons.movie_outlined,
    this.emptyTitle = "No movies found",
    this.emptySubtitle,
    this.blocked = false,
  });

  void _toggleSelected(String id) {
    final sel = selection!;
    if (sel.busy) return;
    if (sel.active) {
      sel.toggle(id);
    } else {
      sel.enter(id);
    }
    onSelectionChanged?.call();
  }

  @override
  Widget build(BuildContext context) {
    // Centralized, rail-aware column rule (Phase 2) — was previously a
    // hand-rolled breakpoint ladder here that read raw MediaQuery width
    // and never accounted for the landscape NavigationRail. Standardized
    // on Responsive.gridColumns' own breakpoints (560/700/900/1100/1400
    // -> 4/5/6/7/8), which DownloadsScreen already used, rather than the
    // slightly different set this file used to hand-roll.
    final crossAxisCount =
        Responsive.gridColumnsForType(context, GridContentType.poster);

    final gridDelegate =
    SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: crossAxisCount,
      crossAxisSpacing: 10,
      mainAxisSpacing: 14,
      childAspectRatio: 2 / 3,
    );

    /// Blocked library
    if (blocked) {
      return const SliverFillRemaining(
        hasScrollBody: false,
        child: Center(
          child: EmptyState(
            icon: Icons.block,
            title: "Library blocked",
            subtitle: "This library is blocked by Parental Controls.",
          ),
        ),
      );
    }

    /// Loading
    if (loading) {
      return SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        sliver: SliverGrid(
          gridDelegate: gridDelegate,
          delegate: SliverChildBuilderDelegate(
                (_, index) => const LoadingCard(),
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

    /// Movies
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      sliver: SliverGrid(
        gridDelegate: gridDelegate,
        delegate: SliverChildBuilderDelegate(
              (context, index) {
            final item = items[index];
            final id = (item["Id"] ?? "").toString();
            final sel = selection;

            // Collections and other non-movie/show items can't be
            // favorited, so they never take part in a selection.
            final selectable = sel != null && titleFavoriteState(id) != null;
            final selecting = selectable && sel!.active;

            return MovieCard(
              item: item,
              selectionMode: selecting,
              selected: selecting && sel!.isSelected(id),
              onLongPress: selectable ? () => _toggleSelected(id) : null,
              onTap: () {
                // While a selection is active, tapping toggles instead
                // of opening the title.
                if (sel != null && sel.active) {
                  if (selectable) _toggleSelected(id);
                  return;
                }

                if (onItemTap != null) {
                  onItemTap!(item);
                  return;
                }

                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => MovieDetailsScreen(
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
