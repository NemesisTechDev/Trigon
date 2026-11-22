import 'package:flutter/material.dart';

class SeekIndicator extends StatelessWidget {
  const SeekIndicator({
    super.key,
    required this.seconds,
    required this.left,
    required this.visible,
  });

  final int seconds;
  final bool left;
  final bool visible;

  @override
  Widget build(BuildContext context) {
    if (!visible) {
      return const SizedBox.shrink();
    }

    return Align(
      alignment:
      left ? Alignment.centerLeft : Alignment.centerRight,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: AnimatedOpacity(
          opacity: visible ? 1 : 0,
          duration: const Duration(milliseconds: 150),
          child: Container(
            width: 90,
            height: 90,
            decoration: BoxDecoration(
              color: Colors.black54,
              borderRadius: BorderRadius.circular(45),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  left
                      ? Icons.replay_10
                      : Icons.forward_10,
                  color: Colors.white,
                  size: 34,
                ),
                const SizedBox(height: 6),
                Text(
                  "$seconds sec",
                  style: const TextStyle(
                    color: Colors.white,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}