import 'package:flutter/material.dart';

class PlayPauseAnimation extends StatelessWidget {
  final bool visible;
  final bool playing;

  const PlayPauseAnimation({
    super.key,
    required this.visible,
    required this.playing,
  });

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: const Duration(milliseconds: 250),
        child: Center(
          child: Container(
            width: 90,
            height: 90,
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.55),
              shape: BoxShape.circle,
            ),
            child: Icon(
              playing
                  ? Icons.pause
                  : Icons.play_arrow,
              color: Colors.white,
              size: 56,
            ),
          ),
        ),
      ),
    );
  }
}