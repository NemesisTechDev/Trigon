import 'package:flutter/material.dart';

/// The shared call-to-action button for the auth screens ("Continue",
/// "Sign In"): gold gradient pill with a tactile scale-down on press,
/// instead of a flat static gradient with only a ripple.
class PremiumGoldButton extends StatefulWidget {
  const PremiumGoldButton({
    super.key,
    required this.onTap,
    required this.loading,
    required this.child,
  });

  final VoidCallback? onTap;
  final bool loading;
  final Widget child;

  static const Color gold = Color(0xFFD4AF37);

  @override
  State<PremiumGoldButton> createState() => _PremiumGoldButtonState();
}

class _PremiumGoldButtonState extends State<PremiumGoldButton> {
  bool _pressed = false;

  bool get _enabled => widget.onTap != null && !widget.loading;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: _enabled ? (_) => setState(() => _pressed = true) : null,
      onTapUp: _enabled ? (_) => setState(() => _pressed = false) : null,
      onTapCancel: _enabled ? () => setState(() => _pressed = false) : null,
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _pressed ? 0.97 : 1.0,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        child: SizedBox(
          width: double.infinity,
          height: 56,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(30),
              // Flat fill in the same gold used for the Play button on
              // movie details and the download buttons, instead of the
              // old two-tone gradient toward 0xFFC49A2A — that warmer
              // second stop (plus the glow this used to have) was what
              // pushed the auth screens' gold noticeably more yellow/
              // orange than the rest of the app.
              color: widget.loading
                  ? PremiumGoldButton.gold.withValues(alpha: 0.35)
                  : PremiumGoldButton.gold,
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(30),
              child: Center(child: widget.child),
            ),
          ),
        ),
      ),
    );
  }
}
