import 'package:flutter/material.dart';

import '../player_manager.dart';

/// The only interactive control left on screen while the player is
/// locked. Sits in the same top-right spot the lock button occupies in
/// [PlayerTopBar] so its position stays predictable, but lives outside
/// PlayerControls entirely — the normal control bars are fully hidden
/// while locked, so this can't be nested inside them.
class PlayerLockOverlay extends StatelessWidget {
  const PlayerLockOverlay({
    super.key,
    required this.visible,
    required this.onUnlock,
  });

  final bool visible;
  final VoidCallback onUnlock;

  @override
  Widget build(BuildContext context) {
    // Mirrors PlayerTopBar's own top padding exactly (fixed 16 while
    // fullscreen; the real status bar height + a small gap while
    // windowed) so this stays lined up with where the lock button
    // actually sits instead of drifting away from it whenever that
    // padding changes.
    return ValueListenableBuilder<bool>(
      valueListenable: PlayerManager.instance.isFullscreen,
      builder: (_, isFullscreen, __) {
        // Aspect-scoped, mirroring the same swap in PlayerTopBar — see
        // its comment for why the unscoped MediaQuery.of(context) this
        // used to call was rebuilding this overlay on every frame of
        // any keyboard animation (e.g. the subtitle-search sheet).
        final topPadding = isFullscreen
            ? 16.0
            : (MediaQuery.paddingOf(context).top - 8.0).clamp(0.0, double.infinity);

        return IgnorePointer(
          ignoring: !visible,
          child: AnimatedOpacity(
            opacity: visible ? 1 : 0,
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOut,
            child: Align(
              alignment: Alignment.topRight,
              child: Padding(
                padding: EdgeInsets.only(top: topPadding, right: 12),
                child: Material(
                  color: Colors.black54,
                  shape: const CircleBorder(),
                  child: IconButton(
                    onPressed: onUnlock,
                    icon: const Icon(Icons.lock, color: Colors.white),
                    tooltip: "Unlock",
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
