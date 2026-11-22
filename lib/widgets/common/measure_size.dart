import 'package:flutter/material.dart';

/// Wraps [child] and calls [onChange] with its rendered [Size] after
/// every layout in which that size actually changed. Used where a
/// sibling widget needs to position itself relative to another widget's
/// real, measured height (e.g. anchoring the Skip Intro/Credits pill
/// just above [PlayerBottomBar]) instead of a hard-coded value that
/// would drift out of sync whenever that widget's content changes.
class MeasureSize extends StatefulWidget {
  final Widget child;
  final ValueChanged<Size> onChange;

  const MeasureSize({
    super.key,
    required this.onChange,
    required this.child,
  });

  @override
  State<MeasureSize> createState() => _MeasureSizeState();
}

class _MeasureSizeState extends State<MeasureSize> {
  final GlobalKey _key = GlobalKey();
  Size? _lastSize;

  @override
  Widget build(BuildContext context) {
    // Scheduled for after this frame's layout/paint rather than read
    // synchronously here — mid-build, the RenderBox for `_key` hasn't
    // necessarily settled into its final size yet.
    WidgetsBinding.instance.addPostFrameCallback((_) => _report());

    return Container(key: _key, child: widget.child);
  }

  void _report() {
    if (!mounted) return;

    final size = _key.currentContext?.size;

    if (size == null || size == _lastSize) return;

    _lastSize = size;
    widget.onChange(size);
  }
}
