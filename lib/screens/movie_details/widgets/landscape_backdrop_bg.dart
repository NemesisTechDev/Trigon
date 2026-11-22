import 'dart:ui';

import 'package:flutter/material.dart';
import '../../../widgets/common/blurred_backdrop_image.dart';

const Color _pageBg = Color(0xff111111);

/// Full-bleed, heavily blurred backdrop used behind the landscape
/// split detail layout (movie/series). Unlike [BackdropHeader]'s
/// sharp hero image, this sits behind *both* columns for the whole
/// screen, so it's blurred and dimmed up front rather than relying on
/// a gradient fade to keep foreground text legible.
///
/// [backdropUrl] can change across rebuilds (e.g. the playlist detail
/// screen's rotating artwork) — an [AnimatedSwitcher] crossfades
/// between the old and new image instead of popping straight to the
/// new one, the same treatment used for the playlist header's own
/// cycling backdrop in portrait. Screens that pass a fixed URL are
/// unaffected — the switcher just never has anything to animate.
///
/// [fallback] is shown in place of a flat page-color panel while
/// [backdropUrl] loads or if it fails/doesn't exist — used by the
/// artist/album detail screens' landscape layout so a missing
/// dedicated backdrop still shows *something* (song/album artwork),
/// matching the same fallback those screens already use in portrait.
/// Screens that don't pass one keep the plain dark panel.
class LandscapeBackdropBackground extends StatelessWidget {
  final String backdropUrl;
  final Widget? fallback;

  const LandscapeBackdropBackground({
    super.key,
    required this.backdropUrl,
    this.fallback,
  });

  @override
  Widget build(BuildContext context) {
    // SCROLL/TRANSITION STUTTER FIX: this sits as a plain Stack sibling
    // next to each landscape detail screen's own scrolling column (and,
    // on some screens, a scroll-linked progress/identity element beside
    // it) — same class of problem as CenteredLandscapeHeader's own
    // RepaintBoundary fix (see that file's doc comment for the full
    // explanation): without one here, this sigma-36 blur has no
    // isolation from whatever nearby sibling legitimately needs to
    // repaint on a given frame, so the engine can't safely reuse its
    // cached output and ends up redoing this expensive blur far more
    // often than the backdrop image itself ever actually changes.
    return Positioned.fill(
      child: RepaintBoundary(
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Scaled up slightly so the blurred image's own soft edges
            // never reveal the plain page background.
            Transform.scale(
              scale: 1.15,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 800),
                switchInCurve: Curves.easeInOut,
                switchOutCurve: Curves.easeInOut,
                layoutBuilder: (currentChild, previousChildren) {
                  return Stack(
                    fit: StackFit.expand,
                    children: [
                      ...previousChildren,
                      ?currentChild,
                    ],
                  );
                },
                transitionBuilder: (child, animation) => FadeTransition(
                  opacity: CurvedAnimation(
                    parent: animation,
                    curve: Curves.easeInOut,
                  ),
                  child: child,
                ),
                // Blurred once up front (see BlurredBackdropImage), not
                // by a live full-screen ImageFilter on every frame.
                child: BlurredBackdropImage(
                  key: ValueKey(backdropUrl),
                  url: backdropUrl,
                  // A caller-supplied fallback (song/album artwork) is shown
                  // blurred, as it always was; the plain panel needs no
                  // blur at all.
                  placeholder: fallback != null
                      ? ImageFiltered(
                          imageFilter: ImageFilter.blur(sigmaX: 36, sigmaY: 36),
                          child: fallback!,
                        )
                      : Container(color: _pageBg),
                ),
              ),
            ),

            // Dark scrim so the two columns of text/content stay legible
            // over the blurred art regardless of how bright it is.
            Container(color: Colors.black.withValues(alpha: .58)),
            Container(color: _pageBg.withValues(alpha: .35)),
          ],
        ),
      ),
    );
  }
}
