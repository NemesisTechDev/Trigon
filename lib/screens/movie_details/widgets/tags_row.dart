import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../shared/tag_items_screen.dart';

const _gold = Color(0xffD4AF37);

/// Below-overview tags line, styled to match the reference client:
/// a plain "Tags: " label followed by the tags themselves rendered
/// inline as comma-separated text — not pill/chip badges — left-
/// aligned and wrapping like an ordinary paragraph. Each tag stays
/// individually tappable (via TapGestureRecognizer, since this is one
/// run of text rather than discrete widgets) and opens
/// [TagItemsScreen], a grid of every other title on the server that
/// shares that tag.
class TagsRow extends StatefulWidget {
  final List<String> tags;

  /// Screens that already apply their own horizontal padding around
  /// this section (matches OverviewSection's identical knob) pass 0
  /// here so it isn't doubled up.
  final double horizontalPadding;

  const TagsRow({
    super.key,
    required this.tags,
    this.horizontalPadding = 20,
  });

  @override
  State<TagsRow> createState() => _TagsRowState();
}

class _TagsRowState extends State<TagsRow> {
  final List<TapGestureRecognizer> _recognizers = [];

  @override
  void initState() {
    super.initState();
    _buildRecognizers();
  }

  @override
  void didUpdateWidget(covariant TagsRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A different item (navigating from one title straight to
    // another while this screen's State is preserved) needs fresh
    // recognizers bound to the new tag list, not the old one.
    if (oldWidget.tags != widget.tags) {
      _disposeRecognizers();
      _buildRecognizers();
    }
  }

  void _buildRecognizers() {
    for (final tag in widget.tags) {
      _recognizers.add(
        TapGestureRecognizer()
          ..onTap = () {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => TagItemsScreen(tag: tag),
              ),
            );
          },
      );
    }
  }

  void _disposeRecognizers() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers.clear();
  }

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.tags.isEmpty) return const SizedBox.shrink();

    const labelStyle = TextStyle(
      color: Colors.white,
      fontSize: 14,
      fontWeight: FontWeight.bold,
      height: 1.7,
    );
    const tagStyle = TextStyle(
      color: _gold,
      fontSize: 14,
      fontWeight: FontWeight.w600,
      height: 1.7,
    );
    const sepStyle = TextStyle(
      color: Colors.white70,
      fontSize: 14,
      height: 1.7,
    );

    final spans = <InlineSpan>[
      const TextSpan(text: "Tags: ", style: labelStyle),
    ];

    for (var i = 0; i < widget.tags.length; i++) {
      spans.add(
        TextSpan(
          text: widget.tags[i],
          style: tagStyle,
          recognizer: _recognizers[i],
        ),
      );
      if (i != widget.tags.length - 1) {
        spans.add(const TextSpan(text: ", ", style: sepStyle));
      }
    }

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: widget.horizontalPadding),
      child: Text.rich(TextSpan(children: spans)),
    );
  }
}
