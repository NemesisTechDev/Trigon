import 'package:flutter/material.dart';

import '../../player/player_manager.dart';
import 'pulsing_logo.dart';

/// The pulsing logo shown when playback stalls to buffer (after playback has
/// started; the first load has its own LoadingOverlay).
///
/// It is purely visual: every touch goes straight through it, so the player
/// controls, seek bar and gestures underneath keep working while buffering.
/// VideoPlayerScreen stacks it BENEATH the controls for that reason, and
/// passes [controlsVisible] so the logo fades back while the controls are up
/// instead of fighting them for the centre of the screen.
class BufferingOverlay extends StatelessWidget {
  const BufferingOverlay({
    super.key,
    this.controlsVisible = false,
  });

  final bool controlsVisible;

  @override
  Widget build(BuildContext context) {
    final manager = PlayerManager.instance;

    // Not while the initial-loading overlay is up: `buffering` is already
    // true while a title first loads, and the loading overlay owns that
    // phase (it shows the backdrop and the filling logo).
    return ValueListenableBuilder<bool>(
      valueListenable: manager.loading,
      builder: (_, loading, __) {
        return ValueListenableBuilder<bool>(
          valueListenable: manager.buffering,
          builder: (_, buffering, __) {
            if (!buffering || loading) {
              return const SizedBox.shrink();
            }

            final item = manager.currentItemNotifier.value;

            if (item == null) {
              return const SizedBox.shrink();
            }

            if (item.logo == null) {
              return const SizedBox.shrink();
            }

            // No backdrop here by design — buffering sits on top of the
            // stuck video frame itself, just dimmed slightly.
            return IgnorePointer(
              child: AnimatedOpacity(
                opacity: controlsVisible ? 0.4 : 1.0,
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOut,
                child: ColoredBox(
                  color: Colors.black26,
                  child: Center(
                    child: PulsingLogo(
                      logoUrl: item.logo!,
                      width: 220,
                      fillProgress: false,
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}
