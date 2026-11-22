import 'package:flutter/material.dart';

/// Shared "nothing here yet" indicator — icon in a soft circle, a title,
/// and an optional supporting line. Matches the look Downloads and
/// Favorites already established; every tab's empty/no-results state
/// should go through this rather than a one-off Text widget, so they all
/// read as the same app-wide pattern.
///
/// Always wrap this in a [Center] (directly, or via
/// `SliverFillRemaining(hasScrollBody: false, child: Center(...))` for
/// sliver-based screens) so it sits in the middle of the available
/// space rather than pinned near the top under fixed vertical padding.
class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;

  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 40),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 84,
            height: 84,
            alignment: Alignment.center,
            decoration: const BoxDecoration(
              color: Color(0xff1E1E1E),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: Colors.white24, size: 36),
          ),
          const SizedBox(height: 20),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 17,
              fontWeight: FontWeight.w700,
            ),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 8),
            Text(
              subtitle!,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white54,
                fontSize: 13,
                height: 1.4,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
