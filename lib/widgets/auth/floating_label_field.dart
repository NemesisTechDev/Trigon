import 'package:flutter/material.dart';

/// A text field that can render either as a classic floating-label
/// input (label rests inside the field, then floats up into a caption
/// on focus/typing) or, with [floating] set to false, as a plain
/// static placeholder that sits inline exactly where the cursor types
/// and disappears once there's text — no animation, no caption above
/// the border.
class FloatingLabelField extends StatefulWidget {
  const FloatingLabelField({
    super.key,
    required this.label,
    required this.controller,
    required this.focusNode,
    this.obscureText = false,
    this.keyboardType,
    this.prefixIcon,
    this.suffixIcon,
    this.floating = true,
    this.autofillHints,
  });

  final String label;
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool obscureText;
  final TextInputType? keyboardType;
  final IconData? prefixIcon;
  final Widget? suffixIcon;

  // Passed straight through to the underlying TextField so a parent
  // screen can opt this field into the OS-level Autofill framework
  // (device password manager) via AutofillHints.username/password —
  // null (the default) leaves autofill untouched, matching every
  // existing call site that doesn't pass it.
  final Iterable<String>? autofillHints;

  // Set to false for a plain static placeholder (sits inline at the
  // cursor position, no float-to-caption animation).
  final bool floating;

  @override
  State<FloatingLabelField> createState() => _FloatingLabelFieldState();
}

class _FloatingLabelFieldState extends State<FloatingLabelField>
    with SingleTickerProviderStateMixin {
  late final AnimationController _float;
  late final CurvedAnimation _curve;
  bool _focused = false;

  static const Color gold = Color(0xFFD4AF37);

  bool get _shouldFloat => _focused || widget.controller.text.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _float = AnimationController(
      vsync: this,
      // Slower, more visible float so the motion up to the border
      // reads clearly rather than snapping.
      duration: const Duration(milliseconds: 320),
      value: _shouldFloat ? 1 : 0,
    );
    _curve = CurvedAnimation(parent: _float, curve: Curves.easeOutCubic);

    widget.focusNode.addListener(_onFocusChange);
    widget.controller.addListener(_onTextChange);
  }

  void _onFocusChange() {
    setState(() => _focused = widget.focusNode.hasFocus);
    _sync();
  }

  void _onTextChange() => _sync();

  void _sync() {
    if (!widget.floating) return;
    if (_shouldFloat) {
      _float.forward();
    } else {
      _float.reverse();
    }
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_onFocusChange);
    widget.controller.removeListener(_onTextChange);
    _float.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.floating) return _buildStatic();

    // Horizontal inset of the label lines up with the prefix icon (if
    // any) so the floated caption still reads as "belonging" to the
    // field beneath it.
    final leftInset = widget.prefixIcon != null ? 44.0 : 16.0;

    return AnimatedBuilder(
      animation: _curve,
      builder: (context, child) {
        final t = _curve.value;

        return Container(
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: _focused
                  ? gold.withValues(alpha: 0.7)
                  : Colors.white.withValues(alpha: 0.14),
              width: _focused ? 1.4 : 1,
            ),
          ),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              // The real input, padded to make room for the label
              // above it once floated.
              Padding(
                padding: EdgeInsets.only(top: 10 * t),
                child: TextField(
                  controller: widget.controller,
                  focusNode: widget.focusNode,
                  obscureText: widget.obscureText,
                  keyboardType: widget.keyboardType,
                  autofillHints: widget.autofillHints,
                  style: const TextStyle(color: Colors.white, fontSize: 15),
                  cursorColor: gold,
                  decoration: InputDecoration(
                    prefixIcon: widget.prefixIcon != null
                        ? Icon(
                            widget.prefixIcon,
                            color: _focused
                                ? gold
                                : Colors.white.withValues(alpha: 0.4),
                            size: 20,
                          )
                        : null,
                    suffixIcon: widget.suffixIcon,
                    border: InputBorder.none,
                    isCollapsed: false,
                    contentPadding: EdgeInsets.only(
                      left: widget.prefixIcon != null ? 0 : 16,
                      right: 16,
                      top: 22 - (6 * t),
                      bottom: 14 + (6 * t),
                    ),
                  ),
                ),
              ),

              // The floating label itself: starts centered inside the
              // field at body-text size, eases upward and shrinks to a
              // small caption sitting just above the border.
              IgnorePointer(
                child: Positioned(
                  left: leftInset - (6 * t),
                  top: _lerp(18, -8, t),
                  child: Container(
                    padding: EdgeInsets.symmetric(horizontal: 6 * t),
                    decoration: BoxDecoration(
                      // Only masks the border once it's actually sitting
                      // on top of it (t near 1); fully transparent while
                      // resting inside the field as a normal placeholder.
                      color: Colors.black.withValues(alpha: 0.55 * t),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      widget.label,
                      style: TextStyle(
                        // Resting (inside the field, untouched): clearly
                        // faded, reading as a placeholder. Once floated
                        // it brightens — fully gold only while actively
                        // focused, a softer white if it floated just
                        // because the field already has text.
                        color: Color.lerp(
                          Colors.white.withValues(alpha: 0.38),
                          _focused ? gold : Colors.white.withValues(alpha: 0.6),
                          t,
                        ),
                        fontSize: _lerp(15, 11.5, t),
                        fontWeight:
                            t > 0.5 ? FontWeight.w700 : FontWeight.w400,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // Plain static placeholder: sits inline exactly at the text cursor's
  // position (Flutter's normal hintText behavior — vertically centered,
  // left-aligned at the caret) and simply disappears once typing
  // starts, rather than floating up into a caption above the border.
  Widget _buildStatic() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: _focused
              ? gold.withValues(alpha: 0.7)
              : Colors.white.withValues(alpha: 0.14),
          width: _focused ? 1.4 : 1,
        ),
      ),
      child: TextField(
        controller: widget.controller,
        focusNode: widget.focusNode,
        obscureText: widget.obscureText,
        keyboardType: widget.keyboardType,
        autofillHints: widget.autofillHints,
        style: const TextStyle(color: Colors.white, fontSize: 15),
        cursorColor: gold,
        decoration: InputDecoration(
          hintText: widget.label,
          hintStyle: TextStyle(
            color: Colors.white.withValues(alpha: 0.38),
            fontSize: 15,
          ),
          prefixIcon: widget.prefixIcon != null
              ? Icon(
                  widget.prefixIcon,
                  color: _focused ? gold : Colors.white.withValues(alpha: 0.4),
                  size: 20,
                )
              : null,
          suffixIcon: widget.suffixIcon,
          border: InputBorder.none,
          isCollapsed: false,
          contentPadding: EdgeInsets.symmetric(
            horizontal: widget.prefixIcon != null ? 0 : 16,
            vertical: 18,
          ),
        ),
      ),
    );
  }

  double _lerp(double a, double b, double t) => a + (b - a) * t;
}
