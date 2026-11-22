import 'package:flutter/material.dart';

/// A row of chip-like widgets that shrinks together — padding, font
/// size, everything — to always fit whatever width its parent gives
/// it, instead of clipping or relying on a horizontal scroll to reveal
/// the rest.
///
/// Root cause this addresses: chip rows like Movies' SortChips and
/// Music's sort-button row were built and eyeballed against the
/// Pixel 6 reference device with Android's Display size setting at
/// "smallest", which reports a wider logical (dp) canvas than the same
/// physical screen reports at the default Display size (see
/// nemesis_display_size_baseline_handoff.md). At default settings the
/// row's real available width can be narrower than the chips' designed
/// padding/font size need, so a fixed-size scrollable row leaves the
/// last chip(s) visibly cut off at rest — you'd have to know to scroll
/// to see "Year", which defeats the point of a filter row with only a
/// handful of options.
///
/// [FittedBox] with [BoxFit.scaleDown] scales the whole row's layout
/// and paint together — the same technique already used for the Up
/// Next overlay's button row (next_episode_overlay.dart /
/// next_movie_overlay.dart) — so every chip stays fully visible and
/// proportionally sized instead of being cropped. It only ever
/// shrinks: given plenty of width, the row renders at its natural
/// design size, unchanged from before.
///
/// [height] must be at least the row's natural (unscaled) height, or
/// it becomes the binding constraint instead of width and the row
/// shrinks even when there's ample horizontal space. The default (44)
/// comfortably clears every current chip style (~30-34px tall); bump
/// it if a chip design ever grows taller than that.
class ScalingChipRow extends StatelessWidget {
  final List<Widget> children;
  final double height;
  final Alignment alignment;

  const ScalingChipRow({
    super.key,
    required this.children,
    this.height = 44,
    this.alignment = Alignment.centerLeft,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: alignment,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: children,
        ),
      ),
    );
  }
}
