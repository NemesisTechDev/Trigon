import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../services/cache/nemesis_image_cache.dart';
import 'artwork_source.dart';

/// Derives a single "accent" color from an artwork image, the same idea
/// as Spotify's Now Playing background: a color that represents the
/// artwork's overall feel, suitable for tinting a gradient behind it.
///
/// This intentionally avoids pulling in a palette-extraction package —
/// it decodes the already-cached network image via `dart:ui`, samples a
/// coarse grid of pixels (not every pixel, for speed), and averages them
/// with a bias toward saturated/vibrant pixels so the result leans
/// toward "colorful" rather than collapsing to a muddy grey average.
class ArtworkAccentExtractor {
  ArtworkAccentExtractor._();

  static final Map<String, Color> _cache = {};
  static final Map<String, Future<Color?>> _inFlight = {};

  /// Returns the accent color for [url], using a cached result when one
  /// is already available. Returns null if the image can't be loaded or
  /// decoded (caller should fall back to a default color).
  static Future<Color?> extractFromUrl(String url) {
    final cached = _cache[url];
    if (cached != null) {
      return SynchronousFuture(cached);
    }

    final pending = _inFlight[url];
    if (pending != null) {
      return pending;
    }

    final future = _extract(url).then((color) {
      _inFlight.remove(url);
      if (color != null) {
        _cache[url] = color;
      }
      return color;
    });

    _inFlight[url] = future;
    return future;
  }

  static Future<Color?> _extract(String url) async {
    try {
      final image = await _loadImage(url);
      if (image == null) return null;

      final color = await _dominantColor(image);
      image.dispose();
      return color;
    } catch (_) {
      // Network hiccups or an undecodable image just fall back to the
      // default background color — this is a purely cosmetic feature.
      return null;
    }
  }

  static Future<ui.Image?> _loadImage(String url) {
    final completer = Completer<ui.Image?>();
    // CachedNetworkImageProvider instead of a plain NetworkImage — this
    // now shares disk cache with every other CachedNetworkImage in the
    // app, so a repeat visit (even after a full app restart) skips the
    // network fetch entirely instead of re-downloading every time.
    //
    // Local songs' artwork is already a file on disk (extracted once by
    // LocalMusicService), so it's loaded via FileImage instead — there's
    // no network fetch to cache in the first place.
    final ImageProvider source = isRemoteArtwork(url)
        ? CachedNetworkImageProvider(url, cacheManager: NemesisImageCache.instance)
        : FileImage(File(url));
    // Decoded at thumbnail size: the accent only needs a coarse grid of
    // pixels (see _dominantColor), so there's no reason to decode a
    // full-resolution backdrop/cover on the UI thread, copy megabytes of
    // RGBA out of it with toByteData, and keep a second full-size copy in
    // the image cache. This runs when detail screens and the mini player
    // appear, i.e. right in the middle of page transitions. 96px wide
    // still gives _dominantColor thousands of samples.
    final ImageProvider provider = ResizeImage(source, width: 96);
    final stream = provider.resolve(const ImageConfiguration());

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
    return completer.future;
  }

  static Future<Color?> _dominantColor(ui.Image image) async {
    final byteData = await image.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    );
    if (byteData == null) return null;

    final bytes = byteData.buffer.asUint8List();
    final width = image.width;
    final height = image.height;
    if (width == 0 || height == 0) return null;

    // Sample roughly a 50x50 grid regardless of the source resolution —
    // plenty for an average "feel" color while staying fast even on
    // large artwork.
    final stepX = (width / 50).clamp(1, width).floor();
    final stepY = (height / 50).clamp(1, height).floor();

    double rSum = 0, gSum = 0, bSum = 0, weightSum = 0;

    for (int y = 0; y < height; y += stepY) {
      for (int x = 0; x < width; x += stepX) {
        final i = (y * width + x) * 4;
        if (i + 3 >= bytes.length) continue;

        final r = bytes[i];
        final g = bytes[i + 1];
        final b = bytes[i + 2];
        final a = bytes[i + 3];
        if (a < 200) continue;

        final hsl = HSLColor.fromColor(Color.fromARGB(255, r, g, b));

        // Skip near-black / near-white pixels — album borders, white
        // backgrounds, and deep shadows would otherwise drag the
        // average toward grey instead of reflecting the artwork's color.
        if (hsl.lightness < 0.08 || hsl.lightness > 0.92) continue;

        // Weight by saturation so vibrant pixels count for more than
        // washed-out ones, biasing the average toward a usable accent
        // rather than a flat grey-brown.
        final weight = 0.15 + hsl.saturation;

        rSum += r * weight;
        gSum += g * weight;
        bSum += b * weight;
        weightSum += weight;
      }
    }

    if (weightSum == 0) return null;

    return Color.fromARGB(
      255,
      (rSum / weightSum).round().clamp(0, 255).toInt(),
      (gSum / weightSum).round().clamp(0, 255).toInt(),
      (bSum / weightSum).round().clamp(0, 255).toInt(),
    );
  }
}
