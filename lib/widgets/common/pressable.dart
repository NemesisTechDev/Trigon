import 'package:flutter/material.dart';

/// Standard tap feedback for the whole app: a slight scale-down while
/// held (matches the bounce LiveChannelCard originated) plus a normal
/// Material ripple, in one drop-in widget instead of every card/tile
/// re-wiring its own AnimatedScale + onTapDown/onTapUp/onTapCancel.
///
/// Use this in place of a bare `GestureDetector(onTap: ...)` — those
/// give zero visual feedback on tap — and in place of a raw `InkWell`
/// wherever the rest of the app's cards use the scale treatment, so
/// every tappable card/tile/chip reads the same way.
///
/// `unconstrained: true` skips the Material/InkWell ripple and only
/// applies the scale (for spots — like a row already sitting on top of
/// a differently-colored background, e.g. a selected list item — where
/// a ripple would look wrong but a press indication is still wanted).
class Pressable extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final BorderRadius borderRadius;
  final double pressedScale;
  final bool unconstrained;

  const Pressable({
    super.key,
    required this.child,
    required this.onTap,
    this.onLongPress,
    this.borderRadius = BorderRadius.zero,
    this.pressedScale = 0.96,
    this.unconstrained = false,
  });

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed == value) return;
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final body = widget.unconstrained
        ? GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            onLongPress: widget.onLongPress,
            onTapDown: (_) => _setPressed(true),
            onTapUp: (_) => _setPressed(false),
            onTapCancel: () => _setPressed(false),
            child: widget.child,
          )
        : Material(
            type: MaterialType.transparency,
            child: InkWell(
              borderRadius: widget.borderRadius,
              onTap: widget.onTap,
              onLongPress: widget.onLongPress,
              onTapDown: (_) => _setPressed(true),
              onTapUp: (_) => _setPressed(false),
              onTapCancel: () => _setPressed(false),
              child: widget.child,
            ),
          );

    return AnimatedScale(
      duration: const Duration(milliseconds: 120),
      scale: _pressed ? widget.pressedScale : 1,
      child: body,
    );
  }
}
