import 'package:flutter/material.dart';

import '../../../widgets/common/pressable.dart';

/// Overview/description text with the app's gold accent border. When the
/// text runs longer than [maxLines] it collapses to that many lines with
/// an ellipsis and shows a gold "Show more" toggle beneath it; tapping
/// expands to the full text and swaps the toggle to "Show less".
class OverviewSection extends StatefulWidget {
  final String overview;

  /// Screens that already apply their own horizontal padding around this
  /// section (e.g. Music detail) pass 0 here so it isn't doubled up.
  final double horizontalPadding;
  final double? fontSize;
  final int maxLines;

  const OverviewSection({
    super.key,
    required this.overview,
    this.horizontalPadding = 20,
    this.fontSize = 15,
    this.maxLines = 5,
  });

  @override
  State<OverviewSection> createState() => _OverviewSectionState();
}

class _OverviewSectionState extends State<OverviewSection> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    if (widget.overview.isEmpty) {
      return const SizedBox();
    }

    final style = TextStyle(
      color: Colors.white,
      fontSize: widget.fontSize,
      height: 1.7,
    );

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: widget.horizontalPadding),
      child: Container(
        padding: const EdgeInsets.only(
          left: 14,
        ),
        decoration: const BoxDecoration(
          border: Border(
            left: BorderSide(
              color: Color(0xffD4AF37),
              width: 3,
            ),
          ),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            // Only the actual paragraph width (constraints minus the
            // border's own left padding) matters for deciding whether it
            // really overflows maxLines — measuring against the full
            // section width would under-count how much text fits per
            // line and could show the toggle when the text wouldn't
            // actually be clipped.
            final painter = TextPainter(
              text: TextSpan(text: widget.overview, style: style),
              maxLines: widget.maxLines,
              textDirection: TextDirection.ltr,
            )..layout(maxWidth: constraints.maxWidth);
            final overflows = painter.didExceedMaxLines;

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  widget.overview,
                  style: style,
                  maxLines: _expanded ? null : widget.maxLines,
                  overflow:
                      _expanded ? TextOverflow.visible : TextOverflow.ellipsis,
                ),
                if (overflows)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Pressable(
                      onTap: () => setState(() => _expanded = !_expanded),
                      borderRadius: BorderRadius.circular(4),
                      child: Text(
                        _expanded ? 'Show less' : 'Show more',
                        style: const TextStyle(
                          color: Color(0xffD4AF37),
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}