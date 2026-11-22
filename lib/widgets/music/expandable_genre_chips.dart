import 'package:flutter/material.dart';

import '../common/pressable.dart';

const _gold = Color(0xffD4AF37);

/// Drop-in replacement for a plain genre-chip `Wrap` that caps itself
/// to [maxRows] rows (3 by default) and, only when the chips would
/// actually need more room than that, appends a small "Show more" /
/// "Show less" toggle instead of just letting the block run on
/// indefinitely.
///
/// Some items (an album with 3-4 genres) never come close to
/// overflowing, so this renders byte-for-byte like the original bare
/// `Wrap` in that case — no extra chrome, no behavior change. Others
/// (an aggregated playlist genre list, which can run 30+ deep — see
/// `_playlistGenres()` on the music detail screen) would otherwise
/// push everything below it — actions, overview, tracklist — many
/// screens down, which is what this exists to fix.
///
/// Row-wrapping is computed with the same greedy line-break math
/// `Wrap` itself uses, driven off each label's actual measured text
/// width via [TextPainter] — not an approximation — so the collapsed
/// cut lands exactly at the true end of the third row for whatever
/// width this happens to render at (landscape's centered 460-wide
/// column vs. portrait's full-bleed column both "just work" without
/// needing separate tuning).
class ExpandableGenreChips extends StatefulWidget {
  final List<String> genres;
  final WrapAlignment alignment;
  final double spacing;
  final double runSpacing;
  final double chipHorizontalPadding;
  final double chipVerticalPadding;
  final TextStyle chipTextStyle;
  final int maxRows;

  /// When provided, each chip becomes tappable (Pressable + ripple)
  /// and invokes this with its own genre name on tap — e.g. opening
  /// TagItemsScreen filtered to that genre. Left null wherever a
  /// genre list is purely informational and shouldn't be clickable.
  final ValueChanged<String>? onGenreTap;

  const ExpandableGenreChips({
    super.key,
    required this.genres,
    this.alignment = WrapAlignment.start,
    this.spacing = 8,
    this.runSpacing = 8,
    this.chipHorizontalPadding = 14,
    this.chipVerticalPadding = 7,
    this.chipTextStyle = const TextStyle(
      color: Colors.white,
      fontSize: 12,
    ),
    this.maxRows = 3,
    this.onGenreTap,
  });

  @override
  State<ExpandableGenreChips> createState() => _ExpandableGenreChipsState();
}

class _ExpandableGenreChipsState extends State<ExpandableGenreChips> {
  bool _expanded = false;

  @override
  void didUpdateWidget(covariant ExpandableGenreChips oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A different item (e.g. navigating from one album to another
    // while this screen's State is preserved) shouldn't inherit the
    // previous item's expanded state.
    if (oldWidget.genres != widget.genres) {
      _expanded = false;
    }
  }

  Widget _chip(String genre) {
    final chip = Container(
      padding: EdgeInsets.symmetric(
        horizontal: widget.chipHorizontalPadding,
        vertical: widget.chipVerticalPadding,
      ),
      decoration: BoxDecoration(
        color: const Color(0xff2A2A2A),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(genre, style: widget.chipTextStyle),
    );

    if (widget.onGenreTap == null) return chip;

    return Pressable(
      onTap: () => widget.onGenreTap!(genre),
      borderRadius: BorderRadius.circular(20),
      child: chip,
    );
  }

  /// Measures each chip's rendered width (text + horizontal padding)
  /// and simulates `Wrap`'s own left-to-right, top-to-bottom
  /// line-breaking to find exactly which chip index ends each row.
  /// Returns the exclusive end index of every row, e.g. `[5, 9, 13]`
  /// means row 0 is genres[0:5], row 1 is genres[5:9], etc.
  List<int> _rowEndIndices(double maxWidth) {
    final widths = widget.genres.map((g) {
      final painter = TextPainter(
        text: TextSpan(text: g, style: widget.chipTextStyle),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout();
      return painter.width + widget.chipHorizontalPadding * 2;
    }).toList();

    final ends = <int>[];
    double currentRowWidth = 0;
    int rowStart = 0;

    for (int i = 0; i < widths.length; i++) {
      final needed = (i == rowStart)
          ? widths[i]
          : currentRowWidth + widget.spacing + widths[i];

      // Always keep at least one chip per row (i == rowStart), even if
      // a single label is wider than maxWidth on its own — otherwise
      // an unusually long genre name could spin this into an infinite
      // "always overflows" state.
      if (needed <= maxWidth || i == rowStart) {
        currentRowWidth = needed;
      } else {
        ends.add(i);
        rowStart = i;
        currentRowWidth = widths[i];
      }
    }

    if (widths.isNotEmpty) ends.add(widths.length);
    return ends;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.genres.isEmpty) return const SizedBox.shrink();

    return LayoutBuilder(
      builder: (context, constraints) {
        final rowEnds = _rowEndIndices(constraints.maxWidth);
        final overflowing = rowEnds.length > widget.maxRows;

        final visible = (!overflowing || _expanded)
            ? widget.genres
            : widget.genres.sublist(0, rowEnds[widget.maxRows - 1]);

        return Column(
          crossAxisAlignment: widget.alignment == WrapAlignment.center
              ? CrossAxisAlignment.center
              : CrossAxisAlignment.start,
          children: [
            Wrap(
              alignment: widget.alignment,
              spacing: widget.spacing,
              runSpacing: widget.runSpacing,
              children: [for (final genre in visible) _chip(genre)],
            ),
            if (overflowing) ...[
              SizedBox(height: widget.runSpacing),
              Pressable(
                onTap: () => setState(() => _expanded = !_expanded),
                borderRadius: BorderRadius.circular(20),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _expanded ? "Show less" : "Show more",
                        style: const TextStyle(
                          color: _gold,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Icon(
                        _expanded
                            ? Icons.keyboard_arrow_up
                            : Icons.keyboard_arrow_down,
                        color: _gold,
                        size: 16,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}
