import 'package:flutter/material.dart';
import '../../../widgets/common/pressable.dart';

enum DownloadsTab { movies, shows, music }

const _gold = Color(0xffD4AF37);

/// Phase 2 of the Downloads redesign: a single continuous track with one
/// gold indicator that slides behind whichever segment is active, in
/// place of three separately-colored pill buttons with gaps between
/// them — reads as one deliberate control instead of three buttons that
/// happen to sit next to each other. Public API (selected/onChanged/
/// counts) is unchanged, so nothing else on the screen needed to change.
class DownloadsTabBar extends StatelessWidget {
  final DownloadsTab selected;
  final ValueChanged<DownloadsTab> onChanged;
  final int movieCount;
  final int showCount;
  final int songCount;

  const DownloadsTabBar({
    super.key,
    required this.selected,
    required this.onChanged,
    required this.movieCount,
    required this.showCount,
    required this.songCount,
  });

  static const List<DownloadsTab> _order = [
    DownloadsTab.movies,
    DownloadsTab.shows,
  ];

  static const double _trackHeight = 44;
  static const double _trackInset = 4;

  @override
  Widget build(BuildContext context) {
    final entries = [
      ("Movies", movieCount, DownloadsTab.movies),
      ("TV Shows", showCount, DownloadsTab.shows),
    ];

    final index = _order.indexOf(selected);

    return Container(
      height: _trackHeight,
      padding: const EdgeInsets.all(_trackInset),
      decoration: BoxDecoration(
        color: const Color(0xff1E1E1E),
        borderRadius: BorderRadius.circular(_trackHeight / 2),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final segmentWidth = constraints.maxWidth / entries.length;
          final segmentHeight = constraints.maxHeight;

          return Stack(
            children: [
              // The one sliding indicator — behind whichever segment is
              // selected. Every segment shares this same track height,
              // so nothing else needs to move when the selection does.
              AnimatedPositioned(
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeInOut,
                left: segmentWidth * index,
                width: segmentWidth,
                top: 0,
                height: segmentHeight,
                child: Container(
                  decoration: BoxDecoration(
                    color: _gold,
                    borderRadius: BorderRadius.circular(segmentHeight / 2),
                  ),
                ),
              ),

              Row(
                children: [
                  for (final (title, count, value) in entries)
                    SizedBox(
                      width: segmentWidth,
                      height: segmentHeight,
                      child: _segment(
                        title: title,
                        count: count,
                        isSelected: value == selected,
                        onTap: () => onChanged(value),
                      ),
                    ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _segment({
    required String title,
    required int count,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return Pressable(
      onTap: onTap,
      borderRadius: BorderRadius.circular(_trackHeight / 2),
      child: Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: isSelected ? Colors.black : Colors.white70,
                ),
              ),
            ),
            if (count > 0) ...[
              const SizedBox(width: 6),
              Text(
                "$count",
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: isSelected
                      ? Colors.black.withValues(alpha: 0.55)
                      : Colors.white38,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
