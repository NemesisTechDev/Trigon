import 'package:flutter/material.dart';

import '../../main_nav/navigation_controller.dart';

const _gold = Color(0xffD4AF37);

/// Phase 3 of the Downloads redesign: Downloads' own empty-state look,
/// no longer routed through the shared [EmptyState] widget (that widget
/// is also used by Movies/TV Shows/Music/Live TV/Favorites, so changing
/// it there would have changed all of those too — this is a standalone
/// widget instead, scoped to Downloads only).
///
/// Adds a bigger plain icon in place of a flat grey circle, an
/// optional supporting line, and an optional "Browse ___" button that
/// jumps straight to the matching main tab via [NavigationController]
/// — turning a dead end into a next step.
class DownloadsEmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;

  /// Button label, e.g. "Browse Movies". Omit to render without a CTA.
  final String? ctaLabel;

  /// Main-tab index (see [NavTabs]) the CTA jumps to. Required whenever
  /// [ctaLabel] is set.
  final int? ctaTargetTab;

  /// Optional: sets [NavigationController.pendingMode] ("movies" or
  /// "tvshows") before switching tabs, the same mechanism Home's
  /// library tiles use — lets the CTA land directly on the Movies
  /// screen's TV Shows sub-tab rather than just its Movies sub-tab.
  final String? ctaPendingMode;

  const DownloadsEmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.ctaLabel,
    this.ctaTargetTab,
    this.ctaPendingMode,
  }) : assert(
          ctaLabel == null || ctaTargetTab != null,
          'ctaTargetTab is required whenever ctaLabel is set',
        );

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 40),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white38, size: 52),

          const SizedBox(height: 24),

          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 19,
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

          if (ctaLabel != null) ...[
            const SizedBox(height: 24),
            DownloadsBrowseMoreButton(
              label: ctaLabel!,
              targetTab: ctaTargetTab!,
              pendingMode: ctaPendingMode,
            ),
          ],
        ],
      ),
    );
  }
}

/// The pill-shaped "Browse ___" CTA, factored out of [DownloadsEmptyState]
/// so the same button can also sit at the bottom of an already-populated
/// list — Downloads keeps a way to find more to download even once a tab
/// isn't empty, rather than that CTA only ever appearing on the way in.
class DownloadsBrowseMoreButton extends StatelessWidget {
  final String label;

  /// Main-tab index (see [NavTabs]) this jumps to.
  final int targetTab;

  /// Optional: sets [NavigationController.pendingMode] ("movies" or
  /// "tvshows") before switching tabs — see [DownloadsEmptyState.ctaPendingMode].
  final String? pendingMode;

  const DownloadsBrowseMoreButton({
    super.key,
    required this.label,
    required this.targetTab,
    this.pendingMode,
  });

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      onPressed: () {
        if (pendingMode != null) {
          NavigationController.instance.pendingMode = pendingMode;
          NavigationController.instance.pendingKeepLibrary = true;
        }
        NavigationController.instance.goToTab(targetTab);
      },
      style: OutlinedButton.styleFrom(
        foregroundColor: _gold,
        side: const BorderSide(color: _gold),
        padding: const EdgeInsets.symmetric(
          horizontal: 24,
          vertical: 12,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(30),
        ),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
