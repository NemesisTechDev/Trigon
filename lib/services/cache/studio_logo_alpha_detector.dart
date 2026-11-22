import 'dart:ui' as ui;

import 'nemesis_image_cache.dart';

/// Detects whether a studio-logo PNG is a flattened, fully-opaque
/// raster — alpha ≈ 255 across the whole canvas, not just the mark —
/// as opposed to a normal cutout with a real alpha shape.
///
/// StudioRow's portrait silhouette (`BlendMode.srcIn`) treats alpha as
/// the shape mask: it recolors every opaque pixel to white and keeps
/// the source's own alpha as-is. On a flattened source there's no
/// shape left to preserve, so the whole bounding box paints solid
/// white — the "blank white square" bug. TMDB doesn't expose which
/// logo variant is which up front.
///
/// This used to be covered by a hand-maintained set of studio names
/// (`_opaqueLogoStudios`) — only studios someone had already noticed
/// and typed in by name. Anything added afterward, e.g. by manually
/// matching a studio outside TMDB's own catalog, silently fell
/// through to the same bug because it was never on the list. This
/// inspects each logo's actual pixels instead, so detection is
/// automatic and covers every studio regardless of how its logo/id
/// was matched.
class StudioLogoAlphaDetector {
  StudioLogoAlphaDetector._();

  // Memoized by URL, caching the in-flight Future itself rather than
  // just the eventual bool — this both skips re-decoding a logo
  // already classified and collapses concurrent lookups for the same
  // URL (e.g. the same studio appearing in more than one row/screen
  // at once) into a single decode.
  static final Map<String, Future<bool>> _cache = {};

  /// Downscaled decode target. Studio marks are simple flat-color
  /// shapes, so this is plenty of resolution to tell "real
  /// transparent background" apart from "opaque rectangle" while
  /// keeping every decode cheap regardless of the source PNG's
  /// native size.
  static const int _sampleSize = 64;

  /// Fraction of sampled pixels that must be ~fully opaque for a logo
  /// to be classified as a flattened raster. Kept well under 100% —
  /// genuine cutouts almost always have visible transparent margin
  /// around the mark, but this tolerates the occasional logo whose
  /// mark genuinely fills most of the canvas without misfiring.
  static const double _opaqueThreshold = 0.95;

  /// Resolves to `true` if [logoUrl]'s image has no meaningful alpha
  /// transparency (flattened/opaque) and should skip the portrait
  /// silhouette, `false` for a normal cutout that silhouettes safely.
  /// Never throws — any failure (decode error, network hiccup)
  /// resolves to `false` so the logo just falls back to the existing
  /// silhouette treatment rather than blocking render.
  static Future<bool> isFlattened(String logoUrl) {
    return _cache.putIfAbsent(logoUrl, () => _detect(logoUrl));
  }

  static Future<bool> _detect(String logoUrl) async {
    try {
      final file = await NemesisImageCache.instance.getSingleFile(logoUrl);
      final bytes = await file.readAsBytes();

      final codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: _sampleSize,
      );
      final frame = await codec.getNextFrame();
      final image = frame.image;
      final byteData = await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      image.dispose();
      if (byteData == null) return false;

      final pixels = byteData.buffer.asUint8List();
      final totalPixels = pixels.length ~/ 4;
      if (totalPixels == 0) return false;

      var opaqueCount = 0;
      for (var i = 0; i < totalPixels; i++) {
        final alpha = pixels[i * 4 + 3];
        if (alpha >= 250) opaqueCount++;
      }

      return (opaqueCount / totalPixels) >= _opaqueThreshold;
    } catch (_) {
      return false;
    }
  }
}
