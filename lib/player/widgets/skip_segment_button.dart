import 'package:flutter/material.dart';

import '../models/skip_segment.dart';
import '../../widgets/common/pressable.dart';
import '../../utils/responsive.dart';

/// Skip pill, deliberately built from the same visual language as
/// [NextEpisodeOverlay] (dark translucent card, white12 border, drop
/// shadow, gold circular icon button) so the two overlays read as a
/// matched pair rather than unrelated controls.
///
/// This widget only renders the card itself — positioning (bottom-right,
/// just above the seek bar) is handled once, centrally, by
/// [PlayerOverlayLayer] so both this and [NextEpisodeOverlay] always
/// stay aligned to the same anchor rather than each hard-coding its own
/// margin.
class SkipSegmentButton extends StatelessWidget {
  static const _gold = Color(0xffD4AF37);

  final SkipSegment segment;

  final VoidCallback onPressed;

  const SkipSegmentButton({
    super.key,
    required this.segment,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    // "Outro" is Jellyfin's/this app's internal name for the segment
    // (matching the server's own MediaSegment type), but "Skip Credits"
    // is the more natural label for what the user actually sees at that
    // point in a movie — the end credits rolling.
    final label = segment.manual
        ? "Skip 85s"
        : switch (segment.type) {
            SkipSegmentType.intro => "Skip Intro",
            SkipSegmentType.recap => "Skip Recap",
            SkipSegmentType.outro => "Skip Credits",
          };

    // TV is D-pad/remote-navigated rather than touched, so the circular
    // icon (36px — below the ~48dp touch-target guideline even for
    // phone touch) and its label get a deliberate bump on TV, the same
    // Responsive.isTV pattern Home Screen's row cards use. Phone/tablet
    // keep the exact original numbers.
    final circleSize = Responsive.isTV ? 52.0 : 36.0;
    final iconSize = Responsive.isTV ? 28.0 : 20.0;
    final fontSize = Responsive.isTV ? 19.0 : 15.0;

    return Pressable(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xF0121212),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white12),
          boxShadow: const [
            BoxShadow(
              color: Colors.black54,
              blurRadius: 20,
              offset: Offset(0, 8),
            ),
          ],
        ),
        padding: const EdgeInsets.fromLTRB(10, 10, 18, 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              key: const ValueKey('skip_segment_icon_circle'),
              width: circleSize,
              height: circleSize,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: _gold,
              ),
              child: Icon(
                Icons.fast_forward_rounded,
                color: Colors.black,
                size: iconSize,
              ),
            ),

            const SizedBox(width: 12),

            Text(
              label,
              style: TextStyle(
                color: Colors.white,
                fontSize: fontSize,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
