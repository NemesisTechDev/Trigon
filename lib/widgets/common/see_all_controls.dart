import 'package:flutter/material.dart';

import 'pressable.dart';

const Color _seeAllGold = Color(0xFFD4AF37);

/// The row header's "see all" control: just a bare gold chevron sitting
/// straight on the page background (no disc/circle behind it) — no
/// "See all" text. Used on the Home screen's Recently Added rows, the
/// Favorites screen's section headers and the Live TV sections, at the
/// same right-edge position the text link used to occupy.
class SeeAllChevronButton extends StatelessWidget {
  const SeeAllChevronButton({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'See all',
      child: Pressable(
        // Scale-only press feedback: a Material ripple would flash a
        // circle/box behind the bare icon.
        unconstrained: true,
        onTap: onTap,
        child: const SizedBox(
          width: 24,
          height: 24,
          child: Icon(
            Icons.chevron_right_rounded,
            color: _seeAllGold,
            size: 24,
          ),
        ),
      ),
    );
  }
}

/// The last item of a full row: a bare gold chevron (no disc) with a
/// "View all" caption underneath, sitting straight on the page
/// background (no card/box behind it). The group is vertically centred
/// in [height] — the row's artwork height — so the chevron lines up with
/// the middle of the posters beside it.
class ViewAllRowTile extends StatelessWidget {
  const ViewAllRowTile({
    super.key,
    required this.height,
    required this.onTap,
  });

  final double height;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: Pressable(
        unconstrained: true,
        onTap: onTap,
        child: SizedBox(
          width: 88,
          height: height,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(
                  width: 52,
                  height: 52,
                  child: Icon(
                    Icons.chevron_right_rounded,
                    color: _seeAllGold,
                    size: 44,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'View all',
                  maxLines: 1,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
