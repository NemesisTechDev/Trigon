import 'package:flutter/material.dart';

/// A Row that never overflows: when its children fit, it behaves exactly
/// like a normal full-width Row with the given [mainAxisAlignment]; when
/// they don't (enlarged display size, small/narrow window, extra buttons
/// showing), the whole row scales down uniformly and stays centered on
/// screen instead of running off the right edge.
class FitRow extends StatelessWidget {
  const FitRow({
    super.key,
    required this.children,
    this.mainAxisAlignment = MainAxisAlignment.center,
    this.crossAxisAlignment = CrossAxisAlignment.center,
  });

  final List<Widget> children;
  final MainAxisAlignment mainAxisAlignment;
  final CrossAxisAlignment crossAxisAlignment;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final minWidth =
            constraints.maxWidth.isFinite ? constraints.maxWidth : 0.0;

        return FittedBox(
          fit: BoxFit.scaleDown,
          child: ConstrainedBox(
            constraints: BoxConstraints(minWidth: minWidth),
            child: Row(
              mainAxisAlignment: mainAxisAlignment,
              crossAxisAlignment: crossAxisAlignment,
              children: children,
            ),
          ),
        );
      },
    );
  }
}
