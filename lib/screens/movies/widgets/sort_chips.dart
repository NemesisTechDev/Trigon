import 'package:flutter/material.dart';
import '../../../widgets/common/pressable.dart';
import '../../../widgets/common/scaling_chip_row.dart';

class SortChips extends StatelessWidget {
  final String selected;
  final ValueChanged<String> onSelected;

  /// Overrides the default [sorts] list — e.g. the Favorites "See all"
  /// grids, which offer A-Z / Time added / Rating instead. Each entry is
  /// {"label": ..., "value": ...}, same shape as [sorts].
  final List<Map<String, String>>? options;

  const SortChips({
    super.key,
    required this.selected,
    required this.onSelected,
    this.options,
  });

  static const List<Map<String, String>> sorts = [
    {
      "label": "New",
      "value": "DateCreated",
    },
    // "Popular" = TMDB's own popularity ranking (what's trending right now);
    // the virtual server turns the "Popularity" value into sort_by=popularity.desc.
    {
      "label": "Popular",
      "value": "Popularity",
    },
    {
      "label": "A-Z",
      "value": "SortName",
    },
    {
      "label": "Rating",
      "value": "CommunityRating",
    },
    // "Year" (ProductionYear) was removed: it ordered the grid the same way
    // as "New", so it was a duplicate chip.
  ];

  @override
  Widget build(BuildContext context) {
    // ScalingChipRow (FittedBox(scaleDown) under the hood) instead of
    // the old IntrinsicHeight + SingleChildScrollView: a scrollable row
    // only ever *looked* right at the Pixel 6 "smallest" Display size
    // this screen was tuned against, which reported enough logical
    // width for all 3 chips + the search field to sit side by side with
    // room to spare. At Android's default Display size the same screen
    // reports less logical width, and the fixed-width search field next
    // to it (see movies_screen.dart's _buildPortraitSelectors) left too
    // little room for the chips — the row still "worked" via scrolling,
    // but the last chip sat cropped at rest, which reads as broken for
    // a 3-option filter row. Scaling the whole row down instead keeps
    // every chip fully visible without requiring a scroll; see
    // ScalingChipRow's doc comment for the full rationale.
    final sorts = options ?? SortChips.sorts;
    // With four or more chips the row would otherwise have to scale down a
    // lot on narrow screens, so each chip gets slimmer side padding.
    final chipPadding = sorts.length > 3 ? 12.0 : 16.0;

    return ScalingChipRow(
      children: [
        for (var index = 0; index < sorts.length; index++) ...[
          if (index > 0) const SizedBox(width: 8),
          Builder(
            builder: (context) {
              final item = sorts[index];

              final active = selected == item["value"];

              return Pressable(
                borderRadius: BorderRadius.circular(30),
                onTap: () => onSelected(item["value"]!),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 250),
                  padding: EdgeInsets.symmetric(
                    horizontal: chipPadding,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: active
                        ? const Color(0x22FFC107)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(30),
                    border: Border.all(
                      color: active
                          ? const Color(0xFFFFC107)
                          : Colors.white12,
                    ),
                  ),
                  child: Center(
                    child: Text(
                      item["label"]!,
                      style: TextStyle(
                        color: active
                            ? const Color(0xFFFFC107)
                            : Colors.white70,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ],
      ],
    );
  }
}