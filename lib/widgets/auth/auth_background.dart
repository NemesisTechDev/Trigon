import 'package:flutter/material.dart';

/// The shared backdrop for the setup (server connection) and login
/// screens: a vertical wash from a darkened gold accent at the top
/// down into black, using the same accent-to-black gradient shape as
/// PlayerAccentBackground on the audio player screen (top color ->
/// darkened blend -> black, weighted toward the top of the screen) so
/// the auth flow reads as part of the same design language.
class AuthBackground extends StatelessWidget {
  const AuthBackground({super.key, required this.child});

  final Widget child;

  static const Color _gold = Color(0xFFD4AF37);

  @override
  Widget build(BuildContext context) {
    final hsl = HSLColor.fromColor(_gold);
    final rawTopColor = hsl
        .withLightness((hsl.lightness * 0.45).clamp(0.10, 0.42))
        .withSaturation((hsl.saturation * 0.9).clamp(0.0, 0.75))
        .toColor();

    // Same gradient shape (colors/stops/direction untouched below) —
    // just blended a bit further toward black so the whole wash reads
    // slightly darker overall.
    final topColor = Color.lerp(rawTopColor, Colors.black, 0.18)!;

    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            topColor,
            Color.lerp(topColor, Colors.black, 0.85)!,
            Colors.black,
          ],
          // Full black now hits by 60% down the screen instead of
          // 100%, so the dark portion covers noticeably more of the
          // layout beneath the gold wash.
          stops: const [0.0, 0.55, 1.0],
        ),
      ),
      child: child,
    );
  }
}
