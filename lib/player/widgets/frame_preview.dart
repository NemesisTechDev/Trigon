import 'package:flutter/material.dart';

import '../services/frame_grabber.dart';

/// The seek-bar preview for addon titles: the frame [FrameGrabber] has for
/// [position] (a nearby one while the exact one is still being fetched).
/// Same look as the Jellyfin [TrickplayPreview].
class FramePreview extends StatelessWidget {
  const FramePreview({
    super.key,
    required this.position,
    this.width = 160,
    this.height = 90,
  });

  final Duration position;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.white, width: 1.5),
        boxShadow: const [
          BoxShadow(
            color: Colors.black54,
            blurRadius: 12,
            offset: Offset(0, 4),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: ValueListenableBuilder<int>(
        valueListenable: FrameGrabber.instance.revision,
        builder: (_, __, ___) {
          final bytes = FrameGrabber.instance.frameFor(position);
          if (bytes == null) {
            return const Center(
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white54,
                ),
              ),
            );
          }
          return Image.memory(
            bytes,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            width: width,
            height: height,
          );
        },
      ),
    );
  }
}
