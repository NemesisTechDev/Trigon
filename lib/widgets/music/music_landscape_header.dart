import 'package:flutter/material.dart';

import 'expandable_genre_chips.dart';

/// Centered identity block used by the music detail screens (album,
/// artist, playlist) in landscape mode.
///
/// Portrait keeps its historical "art on the left, text on the right"
/// row untouched — this widget is only swapped in for landscape,
/// replacing that row with everything (icon, title, subtitle,
/// metadata line, genre chips, action buttons) centered in a column,
/// capped to a comfortable reading width so it doesn't stretch
/// edge-to-edge on a wide screen. Everything below this block
/// (overview, tracklist, recommendation rows, and the pinned
/// collapsing top bar above it) stays exactly as portrait renders it.
class MusicLandscapeHeader extends StatelessWidget {
  /// The album cover / artist photo, already fully built (shadow,
  /// rounded corners, fallback icon) by the caller.
  final Widget icon;

  /// Shown to the right of [icon], both centered together as one
  /// unit — used for the artist page's own logo image when the
  /// artist actually has one uploaded.
  final Widget? secondaryIcon;

  final String title;

  /// Optional tappable artist-name link shown under the title (album
  /// page only — the artist page's title already *is* the artist).
  final Widget? subtitle;

  /// e.g. "2024 • 12 Songs • 45 min".
  final String? metadataLine;

  final List<String> genres;

  /// Forwarded to ExpandableGenreChips — see its own doc. Left null
  /// leaves the genre chips non-interactive.
  final ValueChanged<String>? onGenreTap;

  /// The Play/Shuffle/Favorite/Download row — passed in prebuilt so
  /// this widget doesn't need to know which buttons a given page
  /// shows.
  final Widget actions;

  /// True when [actions] is a full-width stacked bar (StackedActionBar)
  /// that wants the header's whole width, instead of a compact row that
  /// gets centered and scaled down.
  final bool stackedActions;

  const MusicLandscapeHeader({
    super.key,
    required this.icon,
    this.secondaryIcon,
    required this.title,
    this.subtitle,
    this.metadataLine,
    this.genres = const [],
    this.onGenreTap,
    required this.actions,
    this.stackedActions = false,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            if (secondaryIcon != null)
              Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  icon,
                  const SizedBox(width: 18),
                  secondaryIcon!,
                ],
              )
            else
              icon,

            const SizedBox(height: 20),

            Text(
              title,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 26,
                fontWeight: FontWeight.bold,
              ),
            ),

            if (subtitle != null) ...[
              const SizedBox(height: 6),
              subtitle!,
            ],

            if (metadataLine != null && metadataLine!.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                metadataLine!,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white54,
                  fontSize: 14,
                ),
              ),
            ],

            if (genres.isNotEmpty) ...[
              const SizedBox(height: 14),
              ExpandableGenreChips(
                genres: genres,
                alignment: WrapAlignment.center,
                onGenreTap: onGenreTap,
              ),
            ],

            const SizedBox(height: 22),

            // scaleDown shrinks the whole action row together if it's
            // ever too wide for the available space, instead of
            // overflowing or scrolling — same fix as the movie/series
            // detail screen's action row.
            if (stackedActions)
              SizedBox(width: double.infinity, child: actions)
            else
              Center(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: actions,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
