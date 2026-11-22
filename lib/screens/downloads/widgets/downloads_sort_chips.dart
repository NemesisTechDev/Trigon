import 'package:flutter/material.dart';

import '../../../widgets/common/pressable.dart';
import '../../../widgets/common/scaling_chip_row.dart';

// This screen's already-unified gold (see downloads_tab_bar.dart's own
// _gold, fixed in Phase 1 of the redesign) — not the brighter
// 0xFFFFC107 Movies' own SortChips (screens/movies/widgets/sort_chips.dart)
// still uses. Downloads shouldn't reintroduce the inconsistency Phase 1
// was written to remove.
const _gold = Color(0xffD4AF37);

/// The three ways the active Downloads tab's items can be ordered.
/// One shared control for the whole screen — same as Movies/Music's own
/// single sort row applying across whichever of their own tabs is
/// selected — rather than a separate remembered sort per Downloads tab.
enum DownloadsSortOption { recent, az, largest }

class DownloadsSortChips extends StatelessWidget {
  final DownloadsSortOption selected;
  final ValueChanged<DownloadsSortOption> onSelected;

  const DownloadsSortChips({
    super.key,
    required this.selected,
    required this.onSelected,
  });

  static const List<Map<String, Object>> options = [
    {"label": "Recent", "value": DownloadsSortOption.recent},
    {"label": "A-Z", "value": DownloadsSortOption.az},
    {"label": "Largest", "value": DownloadsSortOption.largest},
  ];

  @override
  Widget build(BuildContext context) {
    // ScalingChipRow — the same Display-size-baseline-safe FittedBox
    // technique Movies' SortChips already uses (see
    // scaling_chip_row.dart) — so this row can never end up with a
    // chip clipped at Android's default Display size the way an
    // unscaled row would.
    return ScalingChipRow(
      children: [
        for (var index = 0; index < options.length; index++) ...[
          if (index > 0) const SizedBox(width: 8),
          Builder(
            builder: (context) {
              final item = options[index];
              final value = item["value"] as DownloadsSortOption;
              final active = selected == value;

              return Pressable(
                borderRadius: BorderRadius.circular(30),
                onTap: () => onSelected(value),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 250),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color:
                        active ? _gold.withOpacity(.14) : Colors.transparent,
                    borderRadius: BorderRadius.circular(30),
                    border: Border.all(
                      color: active ? _gold : Colors.white12,
                    ),
                  ),
                  child: Center(
                    child: Text(
                      item["label"] as String,
                      style: TextStyle(
                        color: active ? _gold : Colors.white70,
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
