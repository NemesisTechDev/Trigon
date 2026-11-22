import 'package:flutter/material.dart';

/// Gold used by the player and casting controls (same value as the seek
/// bars' own gold).
const Color kStartWaitGold = Color(0xFFD4AF37);

/// Shows [child] (an elapsed-time label such as "00:00") normally, and a
/// small gold spinner in its place while [waiting] is true: playback was
/// asked to start but the seconds are not running yet, so a frozen
/// "00:00" would only look stuck.
///
/// [child] keeps its space while the spinner shows (it is only hidden), so
/// nothing around it shifts when the label comes back.
class StartWaitLabel extends StatelessWidget {
  const StartWaitLabel({
    super.key,
    required this.waiting,
    required this.fontSize,
    required this.child,
  });

  final bool waiting;

  /// The label's font size; the spinner is drawn about this tall.
  final double fontSize;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final size = fontSize.clamp(11.0, 18.0).toDouble();
    return Stack(
      alignment: Alignment.centerLeft,
      children: [
        Visibility(
          visible: !waiting,
          maintainSize: true,
          maintainAnimation: true,
          maintainState: true,
          child: child,
        ),
        if (waiting)
          SizedBox(
            width: size,
            height: size,
            child: const CircularProgressIndicator(
              strokeWidth: 2,
              color: kStartWaitGold,
            ),
          ),
      ],
    );
  }
}
