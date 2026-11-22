import 'package:flutter/material.dart';

/// Centered "tap to play" glyph for a video thumbnail — a solid white
/// circle with a dark play triangle, matching the reference episode-
/// card look used on the TV show detail screen and the Downloads
/// screen's episode rows. Purely decorative: the whole card already
/// has its own Pressable/onTap handling the actual tap, so this never
/// intercepts touches (IgnorePointer) and is safe to stack over any
/// existing thumbnail content.
class PlayIconOverlay extends StatelessWidget {
  /// Diameter of the white circle.
  final double size;

  const PlayIconOverlay({super.key, this.size = 36});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Center(
        child: Container(
          width: size,
          height: size,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.white,
          ),
          child: Padding(
            // Slight right shift so the triangle reads as optically
            // centered inside the circle rather than dead-center
            // (which looks left-heavy for a play glyph).
            padding: EdgeInsets.only(left: size * 0.05),
            child: Icon(
              Icons.play_arrow_rounded,
              color: const Color(0xff141414),
              size: size * 0.62,
            ),
          ),
        ),
      ),
    );
  }
}
