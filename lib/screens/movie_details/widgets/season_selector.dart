import 'package:flutter/material.dart';

/// The season chips (detail screen and the player's episode panel). Like the
/// Movies / TV Shows library chips, the row scrolls so the chip that was just
/// selected glides to the middle.
class SeasonSelector extends StatefulWidget {
  final String seriesId;
  final List<dynamic> seasons;
  final String? selectedSeasonId;
  final ValueChanged<String> onSeasonSelected;
  final EdgeInsets padding;

  const SeasonSelector({
    super.key,
    required this.seriesId,
    required this.seasons,
    required this.selectedSeasonId,
    required this.onSeasonSelected,
    this.padding = EdgeInsets.zero,
  });

  @override
  State<SeasonSelector> createState() => _SeasonSelectorState();
}

class _SeasonSelectorState extends State<SeasonSelector> {
  final Map<String, GlobalKey> _chipKeys = {};
  final ScrollController _scrollController = ScrollController();

  GlobalKey _keyFor(String id) => _chipKeys.putIfAbsent(id, () => GlobalKey());

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
  void didUpdateWidget(covariant SeasonSelector oldWidget) {
    super.didUpdateWidget(oldWidget);
    final id = widget.selectedSeasonId;
    if (id != null &&
        (id != oldWidget.selectedSeasonId ||
            widget.seasons.length != oldWidget.seasons.length)) {
      _scrollToSelectedAfterFrame();
    }
  }

  void _scrollToSelectedAfterFrame() {
    final id = widget.selectedSeasonId;
    if (id == null) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final targetContext = _chipKeys[id]?.currentContext;
      if (targetContext == null) return;

      // Moves only this chip row. (Scrollable.ensureVisible also scrolls
      // every scrollable around it, which dragged the whole detail page
      // down to the episodes whenever the screen opened.)
      if (!_scrollController.hasClients) return;
      final chip = targetContext.findRenderObject();
      final viewport =
          _scrollController.position.context.storageContext.findRenderObject();
      if (chip is! RenderBox ||
          viewport is! RenderBox ||
          !chip.attached ||
          !viewport.attached) {
        return;
      }
      final chipLeft = chip.localToGlobal(Offset.zero, ancestor: viewport).dx;
      final position = _scrollController.position;
      final target = (position.pixels +
              chipLeft +
              chip.size.width / 2 -
              viewport.size.width / 2)
          .clamp(position.minScrollExtent, position.maxScrollExtent)
          .toDouble();
      if ((target - position.pixels).abs() < 1) return;
      _scrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOutCubic,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final seasons = widget.seasons;
    if (seasons.isEmpty) {
      return const SizedBox.shrink();
    }

    return SizedBox(
      height: 42,
      child: SingleChildScrollView(
        controller: _scrollController,
        padding: widget.padding,
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final season in seasons)
              Padding(
                padding: const EdgeInsets.only(right: 10),
                child: ChoiceChip(
                  key: _keyFor((season["Id"] ?? "").toString()),
                  label: Text(season["Name"] ?? ""),
                  selected: season["Id"] == widget.selectedSeasonId,
                  onSelected: season["Id"] == null
                      ? null
                      : (_) => widget.onSeasonSelected(season["Id"]),
                  // Chip's default Material tap-target padding adds
                  // invisible slack around the shape to hit the 48dp
                  // minimum touch size — that pushed the first chip's
                  // visible pill in from the left edge, off from the
                  // rest of the page's content. Shrink-wrapping removes
                  // that invisible margin so the chip row sits flush
                  // with the left edge.
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
