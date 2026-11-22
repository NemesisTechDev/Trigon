import 'package:flutter/material.dart';

/// A horizontally scrolling chip row that mirrors the Movies screen's
/// [LibraryChips] auto-scroll behavior (see
/// lib/screens/movies/widgets/library_chips.dart): whenever the selected
/// category changes -- whether from a tap on one of these chips or a
/// selection set from elsewhere -- the newly-selected chip is scrolled
/// into view and centered, instead of leaving a tapped chip clipped at
/// the scrollable edge with the user having to scroll manually to see
/// it highlighted.
///
/// Used by the Live TV category-chip rows: the All Channels screen (and
/// Favorites, which is the same screen/widget with a different title),
/// and the TV Guide screen's category row. The day-chip row on the TV
/// Guide screen is intentionally left as a plain ListView -- only the
/// category chips were asked to gain this behavior.
///
/// This widget only owns the scrolling/auto-scroll mechanics; each
/// screen keeps building its own chip visuals (and selection state) via
/// [chipBuilder], the same way it already did with its previous plain
/// ListView -- so existing chip styling, colors, and tap handling are
/// untouched.
class CategoryChipsRow extends StatefulWidget {
  final List<String> categories;
  final String selected;
  final Widget Function(String category, bool selected) chipBuilder;
  final EdgeInsets padding;

  const CategoryChipsRow({
    super.key,
    required this.categories,
    required this.selected,
    required this.chipBuilder,
    this.padding = EdgeInsets.zero,
  });

  @override
  State<CategoryChipsRow> createState() => _CategoryChipsRowState();
}

class _CategoryChipsRowState extends State<CategoryChipsRow> {
  // One GlobalKey per category so that category's chip render box can be
  // found and scrolled into view -- same approach as LibraryChips.
  final Map<String, GlobalKey> _chipKeys = {};
  final ScrollController _scrollController = ScrollController();

  GlobalKey _keyFor(String category) =>
      _chipKeys.putIfAbsent(category, () => GlobalKey());

  @override
  void initState() {
    super.initState();
    _scrollToSelectedAfterFrame();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant CategoryChipsRow oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.selected != oldWidget.selected) {
      _scrollToSelectedAfterFrame();
    }
  }

  void _scrollToSelectedAfterFrame() {
    // The chip for the selected category may not exist yet on this
    // first frame (e.g. the category list is still being built out), so
    // this just quietly no-ops via the key lookup below rather than
    // needing to know that up front.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;

      final key = _chipKeys[widget.selected];
      final targetContext = key?.currentContext;
      if (targetContext == null) return;

      Scrollable.ensureVisible(
        targetContext,
        // Centers the chip in the row rather than just nudging it to
        // the nearest edge, so it reads as a deliberate "slide to the
        // selected category" instead of a minimal scroll correction.
        alignment: 0.5,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOutCubic,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      controller: _scrollController,
      scrollDirection: Axis.horizontal,
      padding: widget.padding,
      child: Row(
        children: [
          for (final category in widget.categories)
            KeyedSubtree(
              key: _keyFor(category),
              child: widget.chipBuilder(
                category,
                category == widget.selected,
              ),
            ),
        ],
      ),
    );
  }
}
