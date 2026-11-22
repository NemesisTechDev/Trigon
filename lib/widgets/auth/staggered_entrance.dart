import 'dart:ui';
import 'package:flutter/material.dart';

/// Fades + slides [child] up into place while also easing out of a soft
/// blur, its portion of [controller]'s timeline running from [start] to
/// [end] (both 0–1). Used to cascade the logo/headline/card/button in
/// on the auth screens one after another with a cinematic, camera-focus
/// feel instead of a flat fade/slide.
class StaggeredEntrance extends StatelessWidget {
  const StaggeredEntrance({
    super.key,
    required this.controller,
    required this.start,
    required this.end,
    required this.child,
    this.fadeOnly = false,
  });

  final Animation<double> controller;
  final double start;
  final double end;
  final Widget child;

  /// When true, [child] only fades in: no upward slide and no blur.
  /// Use this for subtrees that hold live text inputs. Android's
  /// Autofill (device password manager) anchors its saved-credential
  /// suggestion to the focused field's on-screen rectangle, and the
  /// slide + blur variant keeps that rectangle moving and the field
  /// smeared for the whole entrance — and leaves a blur ImageFilter
  /// layer (sigma 0 at rest, but still an offscreen layer) wrapped
  /// around the fields for the life of the screen. FadeTransition keeps
  /// the field geometry fixed from the first frame and, once fully
  /// opaque, adds no layer at all. Default false: every other call
  /// site keeps the original fade + slide + blur look unchanged.
  final bool fadeOnly;

  @override
  Widget build(BuildContext context) {
    final curved = CurvedAnimation(
      parent: controller,
      curve: Interval(start, end, curve: Curves.easeOutCubic),
    );

    if (fadeOnly) {
      return FadeTransition(opacity: curved, child: child);
    }

    return AnimatedBuilder(
      animation: curved,
      builder: (context, childWidget) {
        final t = curved.value.clamp(0.0, 1.0);
        // Blur sharpens from ~6px down to 0 as t approaches 1, so each
        // element resolves into focus rather than just fading in.
        final blur = (1 - t) * 6;

        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, (1 - t) * 18),
            child: ImageFiltered(
              imageFilter: ImageFilter.blur(
                sigmaX: blur,
                sigmaY: blur,
                tileMode: TileMode.decal,
              ),
              child: childWidget,
            ),
          ),
        );
      },
      child: child,
    );
  }
}
