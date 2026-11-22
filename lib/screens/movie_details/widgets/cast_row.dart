import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../services/jellyfin_services/media_service.dart';
import '../../../widgets/common/pressable.dart';
import '../../../widgets/common/see_all_controls.dart';
import '../../../services/cache/nemesis_image_cache.dart';

class CastRow extends StatelessWidget {
  final List<dynamic> cast;
  final void Function(dynamic person)? onTap;

  // The favorites page reuses this exact card (same shape, same 105x140
  // image) for its "Cast & Crew" section, but a favorited person's role
  // there is specific to whichever title they were favorited from —
  // showing it would be misleading outside that title's own detail
  // screen, so favorites passes showRole: false to drop just the
  // second text line while keeping everything else identical.
  final bool showRole;
  final String title;

  /// When set, a gold "See all" is shown on the right edge of the title.
  final VoidCallback? onSeeAll;

  /// When set (with [onSeeAll]), the row shows at most this many people;
  /// once the list reaches it, a gold chevron tile follows the last card
  /// and calls [onSeeAll]. Null (the default) shows everyone, as on the
  /// detail screens.
  final int? maxItems;

  const CastRow({
    super.key,
    required this.cast,
    this.onTap,
    this.showRole = true,
    this.title = "Cast & Crew",
    this.onSeeAll,
    this.maxItems,
  });

  // Chivo, not the TextStyle default (Roboto) — this app sets Chivo as
  // its ambient DefaultTextStyle in main.dart, so that's what the Text
  // widgets below actually render with. _measuredHeight() below feeds
  // these same styles into a TextPainter, which has no ambient theme
  // to inherit from, so without an explicit fontFamily here it would
  // measure Roboto's (narrower) metrics while Chivo (wider/taller) is
  // what actually paints — under-measuring the card height and
  // overflowing whenever a name/role wraps differently under the two
  // fonts (e.g. a name that wraps to 2 lines only in Chivo).
  static final _nameStyle = GoogleFonts.chivo(
    fontSize: 13,
    fontWeight: FontWeight.w600,
  );
  static final _roleStyle = GoogleFonts.chivo(fontSize: 12);

  // Was a flat 210, then a flat 232/196 — both hardcoded for the worst
  // case of a name AND role that each wrap to their 2-line max, so
  // that case wouldn't overflow. But most cast lists never hit that
  // worst case, and a fixed height sized for it leaves the difference
  // as dead space below the cards (visible as an oversized gap before
  // whatever section follows). Measuring this specific `cast` list's
  // actual name/role text — capped at 2 lines each, same as the
  // Text widgets below — gives a height that's exactly as tall as
  // this data needs, while still growing back to the old worst-case
  // height for any list that genuinely has a 2-line name or role.
  double _measuredHeight(BuildContext context) {
    final textScaler = MediaQuery.textScalerOf(context);
    double maxTextHeight = 0;

    // Only the people actually shown count toward the row height.
    final shown = maxItems == null ? cast : cast.take(maxItems!);

    for (final person in shown) {
      final namePainter = TextPainter(
        text: TextSpan(text: person["Name"] ?? "", style: _nameStyle),
        textDirection: TextDirection.ltr,
        maxLines: 2,
        textScaler: textScaler,
      )..layout(maxWidth: 105);

      double blockHeight = namePainter.height;

      if (showRole) {
        final role = person["Role"] ??
            person["Character"] ??
            person["Type"] ??
            "";
        final rolePainter = TextPainter(
          text: TextSpan(text: role, style: _roleStyle),
          textDirection: TextDirection.ltr,
          maxLines: 2,
          textScaler: textScaler,
        )..layout(maxWidth: 105);

        blockHeight += 4 /* name->role gap */ + rolePainter.height;
      }

      if (blockHeight > maxTextHeight) maxTextHeight = blockHeight;
    }

    // image height (140) + image->text gap (10) + tallest text block
    // this list actually needs, plus a small rounding buffer for
    // font-metric variance across devices. This buffer was 4, which
    // measured 2.0px short of what the real Text widgets render at
    // (TextPainter.height doesn't perfectly match RenderParagraph's
    // actual painted height) — every card's Column overflowed its
    // SizedBox by that same 2.0px. Bumped by just the amount needed
    // to clear it, not padded out further, so the row stays as
    // tightly measured as before.
    return 140 + 10 + maxTextHeight + 8; // +2: show the full role line
  }

  bool get _showsSeeAllTile =>
      maxItems != null && onSeeAll != null && cast.length >= maxItems!;

  int get _rowItemCount {
    final max = maxItems;
    if (max == null) return cast.length;
    return (cast.length < max ? cast.length : max) +
        (_showsSeeAllTile ? 1 : 0);
  }

  @override
  Widget build(BuildContext context) {
    if (cast.isEmpty) {
      return const SizedBox();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              // Optional gold chevron disc on the right edge of the label —
              // used by the Favorites page to open the full grid.
              if (onSeeAll != null)
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: SeeAllChevronButton(onTap: onSeeAll!),
                ),
            ],
          ),
        ),

        const SizedBox(height: 18),

        SizedBox(
          height: _measuredHeight(context),
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            scrollDirection: Axis.horizontal,
            itemCount: _rowItemCount,
            separatorBuilder: (_, __) => const SizedBox(width: 14),
            itemBuilder: (context, index) {
              if (_showsSeeAllTile && index == maxItems) {
                return ViewAllRowTile(
                  height: CastPersonCard.imageHeightFor(105),
                  onTap: onSeeAll!,
                );
              }

              final person = cast[index];

              return CastPersonCard(
                person: person,
                showRole: showRole,
                width: 105,
                onTap: onTap == null ? null : () => onTap!(person),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// One cast/crew card — rounded 3:4 portrait, name (max 2 lines) and an
/// optional role line. Shared by [CastRow] (fixed 105-wide horizontal
/// row) and the Favorites "See all" grid (width = grid cell width), so
/// a person looks identical in both.
class CastPersonCard extends StatelessWidget {
  final dynamic person;
  final bool showRole;
  final double width;
  final VoidCallback? onTap;

  const CastPersonCard({
    super.key,
    required this.person,
    this.showRole = true,
    this.width = 105,
    this.onTap,
  });

  /// Portrait image height for a given card width (105 -> 140).
  static double imageHeightFor(double width) => width * 4 / 3;

  /// Height of the name block for a card that shows no role line, at
  /// its 2-line maximum — used to size grid cells so they never
  /// overflow, whatever the text scale.
  static double nameBlockHeight(BuildContext context, double width) {
    final painter = TextPainter(
      text: TextSpan(text: "A\nA", style: CastRow._nameStyle),
      textDirection: TextDirection.ltr,
      maxLines: 2,
      textScaler: MediaQuery.textScalerOf(context),
    )..layout(maxWidth: width);
    final h = painter.height;
    painter.dispose();
    return h;
  }

  @override
  Widget build(BuildContext context) {
    final imageHeight = imageHeightFor(width);

    Widget placeholder({bool icon = false}) => Container(
          width: width,
          height: imageHeight,
          color: const Color(0xff252525),
          child: icon
              ? const Icon(Icons.person, color: Colors.white30, size: 42)
              : null,
        );

    return Pressable(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: SizedBox(
        width: width,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: Builder(
                builder: (context) {
                  // TMDB-sourced cast/crew (see CastCrewService) carry a
                  // resolved ImageUrl directly; plain Jellyfin People
                  // entries don't, and fall back to the server's own
                  // per-person image.
                  final imageUrl = person["ImageUrl"] as String? ??
                      (person["Id"] != null
                          ? MediaService.getImageUrl(
                              person["Id"],
                              type: "Primary",
                              maxWidth: 250,
                            )
                          : null);

                  if (imageUrl == null || imageUrl.isEmpty) {
                    return placeholder(icon: true);
                  }

                  return CachedNetworkImage(
                    cacheManager: NemesisImageCache.instance,
                    imageUrl: imageUrl,
                    width: width,
                    height: imageHeight,
                    fit: BoxFit.cover,
                    // Cap decode to the actual on-screen size (2x for
                    // retina) rather than the full source resolution.
                    memCacheWidth: (width * 2).round(),
                    memCacheHeight: (imageHeight * 2).round(),
                    placeholder: (_, __) => placeholder(),
                    errorWidget: (_, __, ___) => placeholder(icon: true),
                  );
                },
              ),
            ),

            const SizedBox(height: 10),

            Text(
              person["Name"] ?? "",
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: CastRow._nameStyle.copyWith(color: Colors.white),
            ),

            if (showRole) ...[
              const SizedBox(height: 4),
              Text(
                person["Role"] ?? person["Character"] ?? person["Type"] ?? "",
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: CastRow._roleStyle.copyWith(color: Colors.white54),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
