import 'package:flutter/material.dart';

/// Small checkmark badge overlaid on the top-right corner of a movie
/// poster / episode thumbnail to indicate it has been fully watched.
///
/// Kept as a single shared widget (rather than duplicated per-screen)
/// so the "watched" indicator looks identical everywhere it appears —
/// episode list on the detail screen, in-player episode list panel,
/// and anywhere else it gets added later.
class WatchedBadge extends StatelessWidget {
  final double size;

  const WatchedBadge({
    super.key,
    this.size = 20,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: const Color(0xFF3DDC5C),
        border: Border.all(
          color: Colors.black.withOpacity(0.55),
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.35),
            blurRadius: 3,
          ),
        ],
      ),
      child: Icon(
        Icons.check,
        color: Colors.white,
        size: size * 0.65,
      ),
    );
  }
}
