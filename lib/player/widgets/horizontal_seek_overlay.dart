import 'package:flutter/material.dart';

class HorizontalSeekOverlay extends StatelessWidget {
  const HorizontalSeekOverlay({
    super.key,
    required this.visible,
    required this.position,
    this.forward = true,
  });

  final bool visible;
  final Duration position;

  /// True when the drag is moving the position forward, false when it's
  /// rewinding. Drives which icon is shown — without this the overlay
  /// always displayed a forward icon even while the user was dragging
  /// backward, making rewind look broken even though the seek itself
  /// worked.
  final bool forward;

  String format(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);

    if (h > 0) {
      return "$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}";
    }

    return "$m:${s.toString().padLeft(2, '0')}";
  }

  @override
  Widget build(BuildContext context) {

    if (!visible) {
      return const SizedBox.shrink();
    }

    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: 24,
          vertical: 16,
        ),
        decoration: BoxDecoration(
          color: Colors.black87,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [

            Icon(
              forward ? Icons.fast_forward : Icons.fast_rewind,
              color: Colors.white,
              size: 42,
            ),

            const SizedBox(height: 12),

            Text(
              format(position),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 26,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }
}