import 'package:flutter/material.dart';

import '../../utils/responsive.dart';

/// Detail-screen action area: a wide gold play button with the secondary
/// actions (icon + label, no circle) in a row underneath it.
///
///  • Portrait  — the gold button spans the full width; the actions are
///    spread evenly beneath it.
///  • Landscape — everything is centered and the gold button is only
///    slightly wider (14dp each side) than the action row.
///
/// Build each action with [StackedActionBar.item] so the sizing matches.
class StackedActionBar extends StatelessWidget {
  final String playLabel;
  final VoidCallback onPlay;
  final List<Widget> actions;
  final IconData playIcon;

  /// Side padding in portrait (landscape adds its own small inset). Pass 0
  /// when the parent already pads the content.
  final double horizontalPadding;

  const StackedActionBar({
    super.key,
    required this.playLabel,
    required this.onPlay,
    required this.actions,
    this.playIcon = Icons.play_arrow,
    this.horizontalPadding = 20,
  });

  static const double itemWidth = 84;
  static const double iconBox = 48;

  /// Small light-grey caption under an action icon.
  static Widget labelText(String text) {
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Text(
        text,
        maxLines: 1,
        style: TextStyle(
          color: Colors.white.withOpacity(.72),
          fontSize: 12,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }

  /// One un-circled action: [icon] on top, [label] underneath. The label
  /// is plain text (not tappable) — only the icon reacts.
  static Widget item({required Widget icon, required Widget label}) {
    return SizedBox(
      width: itemWidth,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(height: iconBox, width: iconBox + 16, child: icon),
          const SizedBox(height: 2),
          label,
        ],
      ),
    );
  }

  Widget _playButton() {
    return SizedBox(
      height: 54,
      width: double.infinity,
      child: ElevatedButton(
        onPressed: onPlay,
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xffD4AF37),
          foregroundColor: Colors.black,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 18),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(27),
          ),
        ),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(playIcon, size: 26),
              const SizedBox(width: 8),
              Text(
                playLabel,
                maxLines: 1,
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (Responsive.isLandscape(context)) {
      final rowWidth = actions.length * itemWidth;
      return SizedBox(
        width: double.infinity,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.center,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: SizedBox(
              width: rowWidth + 28,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _playButton(),
                  if (actions.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: actions,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _playButton(),
          if (actions.isNotEmpty) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                for (final a in actions) Expanded(child: Center(child: a)),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
