import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../../services/cache/nemesis_image_cache.dart';
import '../../../services/cache/studio_logo_alpha_detector.dart';
import '../../../utils/responsive.dart';
import '../../shared/tag_items_screen.dart';

const _gold = Color(0xffD4AF37);

/// Studios confirmed to have opaque/flattened logo rasters but that
/// [StudioLogoAlphaDetector]'s pixel sampling still misses (edge
/// anti-aliasing, a mostly-transparent bounding box around a small
/// opaque mark, etc.) — observed to still render as a blank white
/// square in portrait even with automatic detection on. Matched by
/// exact studio name after normalizing case/punctuation/whitespace,
/// since TMDB doesn't format these consistently (e.g. "Bros" vs.
/// "Bros."). This is a small, explicit exception list sitting on top
/// of the automatic detector, not a replacement for it.
final Set<String> _knownOpaqueLogoNames = {
  'warner animation group',
  'warner bros animation',
  'warner bros pictures',
  'dc',
  'take five',
  'marvel enterprises',
  '1492 pictures',
};

String _normalizeStudioName(String name) {
  return name
      .toLowerCase()
      .replaceAll('.', '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

bool _isKnownOpaqueLogo(String name) =>
    _knownOpaqueLogoNames.contains(_normalizeStudioName(name));

/// "Studio" / "Studios" row shown below Tags on the movie/show detail
/// screen — one logo per production company (see StudioService). In
/// portrait, every logo is recolored to a flat white silhouette (its
/// native colors and dark strokes vary too wildly — plenty of studio
/// marks are pure black — to reliably read against this screen's flat
/// dark background otherwise); in landscape the logo's real colors are
/// kept as-is, since it's laid over a blurred backdrop image there
/// rather than the flat background, giving it enough contrast on its
/// own. Either way, a studio StudioService couldn't find any artwork
/// for (no TMDB match, no server image) falls back to its name as gold
/// link-style text — same treatment TagsRow/genre links use elsewhere
/// on this screen — so the row never just goes blank for that entry.
///
/// Each logo/name is individually tappable — same idea as TagsRow's
/// tag chips — and opens [TagItemsScreen] filtered to that studio's
/// id, reusing the exact same grid with only the header label
/// changed to the studio's name.
class StudioRow extends StatelessWidget {
  /// Each entry: {"Name": String, "Id": String?, "LogoUrl": String?}.
  final List<Map<String, dynamic>> studios;

  /// Screens that already apply their own horizontal padding around
  /// this section (matches OverviewSection/TagsRow's identical knob)
  /// pass 0 here so it isn't doubled up.
  final double horizontalPadding;

  const StudioRow({
    super.key,
    required this.studios,
    this.horizontalPadding = 20,
  });

  @override
  Widget build(BuildContext context) {
    if (studios.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            studios.length > 1 ? "Studios" : "Studio",
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),

          const SizedBox(height: 14),

          Wrap(
            spacing: 28,
            runSpacing: 14,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (final studio in studios) _StudioLogo(studio: studio),
            ],
          ),
        ],
      ),
    );
  }
}

class _StudioLogo extends StatelessWidget {
  final Map<String, dynamic> studio;

  const _StudioLogo({required this.studio});

  void _open(BuildContext context) {
    final id = studio["Id"]?.toString();
    // No id (shouldn't normally happen — StudioService always carries
    // the server's item id through) means there's nothing to filter
    // by, so the tap is silently a no-op rather than opening an
    // unfiltered grid of the entire library.
    if (id == null || id.isEmpty) return;

    final name = (studio["Name"] ?? "").toString();

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TagItemsScreen(studioId: id, title: name),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final name = (studio["Name"] ?? "").toString();
    final logoUrl = studio["LogoUrl"] as String?;
    final landscape = Responsive.isLandscape(context);

    if (logoUrl == null || logoUrl.isEmpty) {
      // AnimatedSize here (and on the logo branch below) isn't just
      // for this text — it's what smooths the *swap* between the two
      // branches. `studios` starts out from StudioService
      // .jellyfinFallback() (name only, no LogoUrl) and this Text
      // branch renders first; once StudioService.resolve() finishes in
      // the background, the parent's setState swaps this same list
      // entry to one with a LogoUrl and this widget rebuilds into the
      // image branch below instead — a completely different subtree,
      // and typically a much wider one (text name vs. up to a 140px
      // logo). Without AnimatedSize that resize (and the CachedNetwork
      // Image placeholder → loaded-image resize inside the other
      // branch) happens in a single frame, snapping every studio's
      // width — and everything the Wrap flows around it — at once,
      // which read as a sudden right-to-left jolt rather than a clean
      // update.
      return AnimatedSize(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
        alignment: Alignment.centerLeft,
        child: GestureDetector(
          onTap: () => _open(context),
          child: Text(
            name,
            style: const TextStyle(
              color: _gold,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      );
    }

    final image = CachedNetworkImage(
      cacheManager: NemesisImageCache.instance,
      imageUrl: logoUrl,
      fit: BoxFit.contain,
      alignment: Alignment.centerLeft,
      memCacheWidth: 280,
      placeholder: (_, __) => const SizedBox(width: 90, height: 40),
      // No logo on the server for this studio either — same gold
      // text fallback as when StudioService found no LogoUrl at
      // all, just discovered a request later (a real 404) instead
      // of up front.
      errorWidget: (_, __, ___) => Text(
        name,
        style: const TextStyle(
          color: _gold,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
    );

    return AnimatedSize(
      // Same fix, same reasoning as the text-fallback branch above —
      // this smooths the CachedNetworkImage placeholder (fixed
      // 90×40 SizedBox) resizing up to its real, loaded dimensions
      // (up to 140×46) instead of snapping straight to it the instant
      // the image finishes decoding.
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
      alignment: Alignment.centerLeft,
      child: GestureDetector(
        onTap: () => _open(context),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 140, maxHeight: 46),
          // Portrait only: BlendMode.srcIn recolors every opaque pixel of
          // the logo to solid white while preserving its original alpha
          // shape — a flat white silhouette regardless of the source
          // logo's real colors. Guarantees contrast against portrait's
          // flat dark background without needing a card/box behind it,
          // and keeps every studio's mark visually consistent instead of
          // some reading fine and others (mostly-black logos especially)
          // vanishing. Landscape sits over a blurred backdrop image
          // instead of the flat background, so its logos keep their real
          // colors unchanged.
          //
          // srcIn only works when the source has a real alpha shape to
          // preserve — some logos are instead flattened, fully-opaque
          // rasters, and run through srcIn the whole bounding box just
          // paints solid white ("blank white square" bug).
          // StudioLogoAlphaDetector inspects each logo's actual pixels
          // (once per URL, cached) to catch that automatically —
          // flattened logos skip the silhouette entirely and render
          // like landscape does: real colors, straight on the
          // background, no filter and no backing chip. While detection
          // is still pending for a not-yet-classified logo, this
          // defaults to the normal silhouette so nothing flashes white
          // first.
          //
          // A handful of studios (_knownOpaqueLogoNames) still slip
          // past the pixel detector, so those are matched by name
          // first and skip straight to the un-silhouetted image
          // without waiting on/depending on the detector at all.
          child: landscape || _isKnownOpaqueLogo(name)
              ? image
              : FutureBuilder<bool>(
                  future: StudioLogoAlphaDetector.isFlattened(logoUrl),
                  builder: (context, snapshot) {
                    if (snapshot.data == true) return image;
                    return ColorFiltered(
                      colorFilter: const ColorFilter.mode(
                        Colors.white,
                        BlendMode.srcIn,
                      ),
                      child: image,
                    );
                  },
                ),
        ),
      ),
    );
  }
}
