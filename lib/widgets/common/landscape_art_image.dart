import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../services/cache/nemesis_image_cache.dart';
import '../../services/jellyfin_services/media_service.dart';

/// 16:9 card art that mirrors Jellyfin's own clients: the item's
/// landscape `Thumb` image when it has one, otherwise its `Backdrop`
/// (also landscape), so a Continue Watching / downloads card never shows
/// up empty just because nobody uploaded a dedicated Thumb.
///
/// Fallback order is Thumb -> Backdrop -> [errorWidget].
///
/// Jellyfin answers 404 for a missing image type, and
/// CachedNetworkImage doesn't cache failures — so without help every
/// rebuild of a scrolled-back-in card would re-request (and re-404) the
/// Thumb before falling through. [_noThumbIds] remembers, for the life
/// of the process, which ids already 404'd so they go straight to the
/// Backdrop afterwards. [knownNoThumb] lets a caller that already has
/// the item's `ImageTags` skip even the first 404.
class LandscapeArtImage extends StatelessWidget {
  const LandscapeArtImage({
    super.key,
    required this.imageId,
    required this.maxWidth,
    required this.placeholder,
    required this.errorWidget,
    this.knownNoThumb = false,
    this.fit = BoxFit.cover,
  });

  /// Item (or, for episodes, parent series) id the art is requested for.
  final String imageId;
  final int maxWidth;

  /// Shown while loading.
  final Widget placeholder;

  /// Shown only when neither Thumb nor Backdrop exists.
  final Widget errorWidget;

  /// True when the caller already knows this item has no Thumb image.
  final bool knownNoThumb;

  final BoxFit fit;

  static final Set<String> _noThumbIds = <String>{};

  /// Reads an item's own `ImageTags` (when the list endpoint returned
  /// them) to tell whether it has a Thumb. Returns true only when the
  /// tags are present AND lack a Thumb — unknown stays false so the
  /// widget simply tries Thumb first.
  static bool itemLacksThumb(Map<dynamic, dynamic> item) {
    final tags = item['ImageTags'];
    if (tags is! Map) return false;
    return tags['Thumb'] == null;
  }

  Widget _backdrop() {
    return CachedNetworkImage(
      cacheManager: NemesisImageCache.instance,
      imageUrl: MediaService.getImageUrl(
        imageId,
        type: 'Backdrop',
        maxWidth: maxWidth,
      ),
      fit: fit,
      placeholder: (_, __) => placeholder,
      errorWidget: (_, __, ___) => errorWidget,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (knownNoThumb || _noThumbIds.contains(imageId)) return _backdrop();

    return CachedNetworkImage(
      cacheManager: NemesisImageCache.instance,
      imageUrl: MediaService.getImageUrl(
        imageId,
        type: 'Thumb',
        maxWidth: maxWidth,
      ),
      fit: fit,
      placeholder: (_, __) => placeholder,
      errorWidget: (_, __, ___) {
        _noThumbIds.add(imageId);
        return _backdrop();
      },
    );
  }
}
