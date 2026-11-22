import 'dart:ui';
import 'package:flutter/material.dart';

/// A frosted "liquid glass" card — blurs whatever's behind it, tinted
/// with a faint white gradient and a hairline border. Shared by the
/// setup and login screens so both cards read as the same material.
class GlassCard extends StatelessWidget {
  const GlassCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(28),
    this.borderRadius = 28,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double borderRadius;

  static const Color gold = Color(0xFFD4AF37);

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(borderRadius),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.45),
            blurRadius: 36,
            offset: const Offset(0, 16),
          ),
          BoxShadow(
            color: gold.withValues(alpha: 0.05),
            blurRadius: 40,
            spreadRadius: -8,
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
          child: Container(
            padding: padding,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(borderRadius),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Colors.white.withValues(alpha: 0.09),
                  Colors.white.withValues(alpha: 0.03),
                ],
              ),
              border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
            ),
            // Thin gold hairline tracing the top edge only — a quiet
            // premium accent rather than a full gradient border.
            foregroundDecoration: BoxDecoration(
              borderRadius: BorderRadius.circular(borderRadius),
              border: Border(
                top: BorderSide(
                  color: gold.withValues(alpha: 0.35),
                  width: 1,
                ),
              ),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}
