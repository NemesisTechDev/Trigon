import 'package:flutter/material.dart';

import '../../player/player_manager.dart';
import 'progress_logo.dart';

class LoadingOverlay extends StatelessWidget {
  const LoadingOverlay({
    super.key,
    required this.loading,
  });

  final bool loading;

  @override
  Widget build(BuildContext context) {
    if (!loading) {
      return const SizedBox.shrink();
    }

    final manager = PlayerManager.instance;
    // Listens to the item too, so a logo that is found a moment after the
    // loading screen opened appears without waiting for anything else.
    return ValueListenableBuilder(
      valueListenable: manager.currentItemNotifier,
      builder: (context, item, _) => _build(item),
    );
  }

  Widget _build(dynamic item) {
    if (item == null) {
      // Never a bare black screen while loading.
      return Container(
        color: Colors.black,
        child: const Center(child: CircularProgressIndicator()),
      );
    }

    // This overlay is opaque on purpose: while a title is first loading
    // nothing underneath it (controls, gestures) should react. Once playback
    // has really started `loading` goes false and everything is usable.
    return Container(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Live channels don't have real backdrop art — keep it a
          // plain dark screen instead of showing a broken image.
          if (!item.live && item.backdrop != null)
            Image.network(
              item.backdrop!,
              fit: BoxFit.cover,
              // Default (low) filtering makes an upscaled backdrop look soft.
              filterQuality: FilterQuality.high,
              gaplessPlayback: true,
              frameBuilder: (context, child, frame, sync) => AnimatedOpacity(
                opacity: (frame == null && !sync) ? 0 : 1,
                duration: const Duration(milliseconds: 250),
                child: child,
              ),
              errorBuilder: (_, __, ___) => const SizedBox(),
            ),
          if (!item.live)
            Container(
              color: Colors.black54,
            ),
          // The pulsing logo: dim until a source is chosen, then filling
          // with real loading progress. With no logo artwork the title
          // takes its place and behaves the same. No key on purpose: the
          // item is swapped (preview -> playable) while loading, and the
          // pulse and fill must carry on across that swap.
          Center(
            child: ProgressLogo(
              logoUrl: item.logo as String?,
              title: item.title as String,
              width: 250,
            ),
          ),
        ],
      ),
    );
  }
}
