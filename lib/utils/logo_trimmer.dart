import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../services/cache/nemesis_image_cache.dart';

/// Many Jellyfin/TMDB "clear logo" images aren't tightly cropped — some
/// have a lot of transparent padding baked right into the canvas, often
/// unevenly (more margin on one side than the other, or more on top
/// than bottom). Rendered with a plain `BoxFit.contain` + alignment,
/// that padding only locks the *bounding box* in place — the actual
/// visible glyph still lands in a different spot for every title, so
/// logos that should all sit flush against the same edge instead look
/// like they're floating at inconsistent distances from it (or even
/// appear to hop from a centered-looking spot to the edge once a wider
/// title's logo loads in next to a narrower one).
///
/// This scans each logo's alpha channel once, crops out the transparent
/// margin, and caches the trimmed image per URL — so every logo can be
/// aligned edge-to-edge for real, consistently, regardless of how the
/// source asset was exported.
class LogoTrimmer {
  LogoTrimmer._();

  static final Map<String, Future<ui.Image?>> _cache = {};

  /// Returns a tightly-cropped copy of the logo at [url] with its
  /// transparent margins removed, or null if it can't be loaded/decoded
  /// (caller should fall back to rendering the source image directly).
  /// Cached per URL — repeat requests for the same logo are instant.
  static Future<ui.Image?> trimmed(String url) {
    final existing = _cache[url];
    if (existing != null) return existing;
    final future = _trim(url);
    _cache[url] = future;
    // NAMESIS PRIME: never remember a failure. A single network hiccup used
    // to leave this logo blank until the app restarted, while other screens
    // (which use the disk cache) still showed it.
    unawaited(future.then((image) {
      if (image == null && identical(_cache[url], future)) {
        _cache.remove(url);
      }
    }));
    return future;
  }

  static Future<ui.Image?> _trim(String url) async {
    try {
      final image = await _loadImage(url);
      if (image == null) return null;

      final bounds = _visibleBounds(await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ), image.width, image.height);

      if (bounds == null) {
        // Nothing to trim (fully opaque canvas or fully transparent) —
        // just use the source image as-is.
        return image;
      }

      final cropped = await _crop(image, bounds);
      image.dispose();
      return cropped;
    } catch (_) {
      // Network hiccups or an undecodable image just fall back to the
      // source image — this is a purely cosmetic touch-up.
      return null;
    }
  }

  static Future<ui.Image?> _loadImage(String url) {
    final completer = Completer<ui.Image?>();
    // NAMESIS PRIME: same provider + disk cache the carousel and the
    // collapsed header use, so a logo downloaded once shows everywhere.
    final stream = CachedNetworkImageProvider(
      url,
      cacheManager: NemesisImageCache.instance,
    ).resolve(const ImageConfiguration());

    late ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, _) {
        stream.removeListener(listener);
        completer.complete(info.image.clone());
      },
      onError: (error, stackTrace) {
        stream.removeListener(listener);
        if (!completer.isCompleted) completer.complete(null);
      },
    );

    stream.addListener(listener);
    // Never wait forever on a stalled download.
    Timer(const Duration(seconds: 25), () {
      if (!completer.isCompleted) {
        stream.removeListener(listener);
        completer.complete(null);
      }
    });
    return completer.future;
  }

  static Rect? _visibleBounds(ByteData? byteData, int width, int height) {
    if (byteData == null || width == 0 || height == 0) return null;

    final bytes = byteData.buffer.asUint8List();

    int minX = width, minY = height, maxX = -1, maxY = -1;

    // Treat near-transparent pixels as margin too — logo exports often
    // have a faint anti-aliased fringe rather than a hard alpha cutoff.
    const alphaThreshold = 12;

    for (int y = 0; y < height; y++) {
      final rowStart = y * width * 4;
      for (int x = 0; x < width; x++) {
        final a = bytes[rowStart + x * 4 + 3];
        if (a <= alphaThreshold) continue;
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
      }
    }

    if (maxX < minX || maxY < minY) return null;

    // Already tight — skip the crop entirely.
    if (minX == 0 && minY == 0 && maxX == width - 1 && maxY == height - 1) {
      return null;
    }

    return Rect.fromLTRB(
      minX.toDouble(),
      minY.toDouble(),
      (maxX + 1).toDouble(),
      (maxY + 1).toDouble(),
    );
  }

  static Future<ui.Image> _crop(ui.Image image, Rect bounds) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawImageRect(
      image,
      bounds,
      Rect.fromLTWH(0, 0, bounds.width, bounds.height),
      Paint(),
    );
    final picture = recorder.endRecording();
    final cropped = await picture.toImage(
      bounds.width.round().clamp(1, 4096),
      bounds.height.round().clamp(1, 4096),
    );
    picture.dispose();
    return cropped;
  }
}

/// Renders a trimmed logo flush against [alignment], falling back to
/// the plain source image (untrimmed) while the trim is still loading
/// or if trimming fails outright — the logo is never left blank.
///
/// When [targetArea] is supplied, the logo is additionally scaled so
/// its rendered width × height lands on that constant footprint
/// (clamped to [maxWidth]/[maxHeight]) instead of just being fit into
/// whatever box it's given — otherwise a bold, blocky logo and a thin
/// single-line wordmark logo can occupy wildly different amounts of
/// visual space next to each other even though both technically "fit".
class TrimmedLogo extends StatefulWidget {
  final String url;
  final Alignment alignment;
  final BoxFit fit;
  final double? targetArea;
  final double maxWidth;
  final double maxHeight;

  /// NAMESIS PRIME: shown instead of the logo when the title has no logo
  /// (or it can't be downloaded), so the header is never left blank.
  final String? fallbackText;

  const TrimmedLogo({
    super.key,
    required this.url,
    this.alignment = Alignment.centerRight,
    this.fit = BoxFit.contain,
    this.targetArea,
    this.maxWidth = double.infinity,
    this.maxHeight = double.infinity,
    this.fallbackText,
  });

  @override
  State<TrimmedLogo> createState() => _TrimmedLogoState();
}

class _TrimmedLogoState extends State<TrimmedLogo> {
  ui.Image? _image;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant TrimmedLogo oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _image = null;
      _failed = false;
      _load();
    }
  }

  Future<void> _load() async {
    final url = widget.url;
    // The "no logo registered" placeholder URL can never succeed.
    final retryable = !url.contains('/no-image/');
    final attempts = retryable ? 4 : 1;
    for (var attempt = 0; attempt < attempts; attempt++) {
      final image = await LogoTrimmer.trimmed(url);
      if (!mounted || url != widget.url) return;
      if (image != null) {
        setState(() {
          _image = image;
          _failed = false;
        });
        return;
      }
      if (attempt < attempts - 1) {
        await Future<void>.delayed(Duration(seconds: 2 * (attempt + 1)));
        if (!mounted || url != widget.url) return;
      }
    }
    setState(() => _failed = true);
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    final targetArea = widget.targetArea;

    if (image != null) {
      if (targetArea != null) {
        final w0 = image.width.toDouble();
        final h0 = image.height.toDouble();

        // Scale so width × height hits targetArea, then clamp back
        // down if that would overflow the space actually available —
        // preserves the equal-footprint feel for normal logos while
        // still never spilling out of bounds for extreme aspect
        // ratios (a very wide banner-style logo, say).
        var scale = math.sqrt(targetArea / (w0 * h0));
        scale = math.min(scale, widget.maxWidth / w0);
        scale = math.min(scale, widget.maxHeight / h0);

        final renderWidth = w0 * scale;
        final renderHeight = h0 * scale;

        return Align(
          alignment: widget.alignment,
          child: SizedBox(
            width: renderWidth,
            height: renderHeight,
            child: RawImage(image: image, fit: BoxFit.fill),
          ),
        );
      }

      return Align(
        alignment: widget.alignment,
        child: RawImage(
          image: image,
          fit: widget.fit,
          alignment: widget.alignment,
        ),
      );
    }

    // Trim still in flight (or genuinely failed). In area-normalized
    // mode there's no size to normalize against yet, so staying blank
    // for this brief moment (results are cached, so it's effectively
    // one-time per logo) beats flashing an inconsistently-sized logo
    // right before the correctly-sized one pops in.
    if (targetArea != null) {
      final text = widget.fallbackText;
      if (_failed && text != null && text.trim().isNotEmpty) {
        final x = widget.alignment.x;
        return Align(
          alignment: widget.alignment,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: widget.alignment,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: widget.maxWidth.isFinite ? widget.maxWidth : 300,
              ),
              child: Text(
                text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: x < 0
                    ? TextAlign.left
                    : (x > 0 ? TextAlign.right : TextAlign.center),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 26,
                  fontWeight: FontWeight.w800,
                  height: 1.1,
                  shadows: [Shadow(blurRadius: 8, color: Colors.black54)],
                ),
              ),
            ),
          ),
        );
      }
      return const SizedBox.shrink();
    }

    // Trim still in flight (or genuinely failed) — show the source
    // image untrimmed rather than nothing, so there's never a gap.
    return CachedNetworkImage(
      cacheManager: NemesisImageCache.instance,
      imageUrl: widget.url,
      fit: widget.fit,
      alignment: widget.alignment,
      fadeInDuration: const Duration(milliseconds: 200),
      errorWidget: (_, __, ___) => const SizedBox.shrink(),
    );
  }
}
