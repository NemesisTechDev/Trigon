import 'package:flutter/material.dart';

/// The app logo with a slow, continuous "breathing" scale — used on the
/// setup and login screens so the logo reads as quietly alive rather
/// than a static image sitting on the page.
class BreathingLogo extends StatefulWidget {
  const BreathingLogo({super.key, this.size = 84});

  final double size;

  @override
  State<BreathingLogo> createState() => _BreathingLogoState();
}

class _BreathingLogoState extends State<BreathingLogo>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2600),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final breathe = Curves.easeInOut.transform(_controller.value);
        final scale = 0.96 + breathe * 0.06;

        return Transform.scale(
          scale: scale,
          child: SizedBox(
            width: widget.size,
            height: widget.size,
            child: Padding(
              padding: EdgeInsets.all(widget.size * 0.16),
              child: Image.asset(
                'assets/images/nemesis_logo.png',
                fit: BoxFit.contain,
              ),
            ),
          ),
        );
      },
    );
  }
}
