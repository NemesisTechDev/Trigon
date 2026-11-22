import 'package:flutter/material.dart';

import '../shared/nemesis_bottom_sheet.dart';
import 'dustbin_icon.dart';

/// The pop-up opened by tapping a finished download's [DeviceCheckBadge]
/// on a movie row or a TV episode row (see DownloadedMovieTile and
/// DownloadedEpisodeTile) — title, overview, and the only two actions
/// that make sense for something already fully on disk: play it, or
/// delete it. Mirrors the "Play Download / Delete Download" pattern
/// other streaming apps use for this exact badge.
///
/// Both movies and episodes reuse this one sheet — the calling tile just
/// hands it whichever title/overview/callbacks apply, so this stays a
/// dumb, kind-agnostic content sheet. Actions render as ListTile rows
/// below a divider — same chrome showDownloadedSongOptionsSheet uses for
/// music's version of this same badge tap — so every downloaded item's
/// options sheet reads the same way across the app.
void showDownloadInfoSheet(
  BuildContext context, {
  required String title,
  required String overview,
  required VoidCallback onPlay,
  required VoidCallback onDelete,
}) {
  showNemesisBottomSheet<void>(
    context,
    initialChildSize: overview.isEmpty ? 0.3 : 0.45,
    minChildSize: 0.25,
    maxChildSize: 0.8,
    builder: (sheetContext, scrollController) => ListView(
      controller: scrollController,
      children: [
        const NemesisSheetDragHandle(topMargin: 10, bottomMargin: 14),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (overview.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(
                  overview,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 13,
                    height: 1.4,
                  ),
                ),
              ],
            ],
          ),
        ),

        const SizedBox(height: 14),
        const Divider(color: Colors.white12, height: 1),

        ListTile(
          leading: const Icon(Icons.play_arrow_rounded, color: Colors.white70),
          title: const Text(
            "Play Download",
            style: TextStyle(color: Colors.white),
          ),
          onTap: () {
            Navigator.pop(sheetContext);
            onPlay();
          },
        ),

        ListTile(
          leading: const DustbinIcon(color: Colors.redAccent),
          title: const Text(
            "Delete Download",
            style: TextStyle(color: Colors.redAccent),
          ),
          onTap: () {
            Navigator.pop(sheetContext);
            onDelete();
          },
        ),

        const SizedBox(height: 8),
      ],
    ),
  );
}
