import 'dart:async';
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../services/cache/nemesis_image_cache.dart';

/// A heavily blurred copy of the network image at [url], for the soft
/// full-bleed backdrops behind the landscape detail screens.
///
/// The blur is applied ONCE, to a thumbnail, and the result is kept as a
/// plain texture — instead of wrapping the full-size image in an
/// `ImageFiltered(ImageFilter.blur(sigma: 32..36))`. A live filter like
/// that is re-run by the GPU on every frame the screen is redrawn, over
/// the whole (landscape-sized) backdrop, which is exactly what made
/// scrolling and page transitions stutter in landscape: the page behind
/// the scrolling content never changes, yet it was being re-blurred
/// every frame. Here the per-frame cost is just drawing one texture.
///
/// While the image loads (or if it fails) [placeholder] is shown, and the
/// blurred result fades in over it.
class BlurredBackdropImage extends StatefulWidget {
  const BlurredBackdropImage({
    super.key,
    required this.url,
    required this.placeholder,
  });

  final String url;

  /// Shown until the blurred image is ready, and kept if loading fails.
  final Widget placeholder;

  /// Width, in pixels, the image is decoded and blurred at. The result
  /// is stretched to fill the screen, so it only needs to hold broad
  /// colour — more pixels would just make the one-off bake slower.
  static const int bakeWidth = 160;

  /// Blur radius in [bakeWidth]-pixel space. About what a sigma-32..36
  /// blur over a full-width landscape backdrop works out to at this
  /// size.
  static const double bakeSigma = 6.5;

  @override
  State<BlurredBackdropImage> createState() => _BlurredBackdropImageState();
}

class _BlurredBackdropImageState extends State<BlurredBackdropImage> {
  ImageStream? _stream;
  ImageStreamListener? _listener;
  ui.Image? _baked;

  // True once the blurred image has finished fading in, at which point
  // the placeholder underneath is fully covered and no longer built.
  bool _placeholderCovered = false;

  // Bumped on every (re)load so a bake that finishes after the url
  // changed — or after dispose — is thrown away instead of shown.
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant BlurredBackdropImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _load();
    }
  }

  @override
  void dispose() {
    _generation++;
    _detach();
    _baked?.dispose();
    _baked = null;
    super.dispose();
  }

  void _detach() {
    final stream = _stream;
    final listener = _listener;
    if (stream != null && listener != null) {
      stream.removeListener(listener);
    }
    _stream = null;
    _listener = null;
  }

  void _load() {
    final generation = ++_generation;
    _detach();

    final provider = ResizeImage(
      CachedNetworkImageProvider(
        widget.url,
        cacheManager: NemesisImageCache.instance,
      ),
      width: BlurredBackdropImage.bakeWidth,
    );

    final stream = provider.resolve(ImageConfiguration.empty);
    final listener = ImageStreamListener(
      (info, _) {
        if (generation != _generation) return;
        unawaited(_bake(info.image, generation));
      },
      onError: (Object error, StackTrace? stackTrace) {
        // Keep showing the placeholder.
        debugPrint('BlurredBackdropImage: load failed: $error');
      },
    );
    stream.addListener(listener);
    _stream = stream;
    _listener = listener;
  }

  Future<void> _bake(ui.Image source, int generation) async {
    try {
      final width = source.width;
      final height = source.height;
      if (width == 0 || height == 0) return;

      final bounds = Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble());
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder, bounds);
      canvas.saveLayer(
        bounds,
        Paint()
          ..imageFilter = ui.ImageFilter.blur(
            sigmaX: BlurredBackdropImage.bakeSigma,
            sigmaY: BlurredBackdropImage.bakeSigma,
          ),
      );
      canvas.drawImage(source, Offset.zero, Paint());
      canvas.restore();

      final picture = recorder.endRecording();
      final baked = await picture.toImage(width, height);
      picture.dispose();

      if (!mounted || generation != _generation) {
        baked.dispose();
        return;
      }

      final previous = _baked;
      setState(() {
        _baked = baked;
        _placeholderCovered = false;
      });
      // After the frame that stops using it.
      if (previous != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) => previous.dispose());
      }
    } catch (e) {
      debugPrint('BlurredBackdropImage: bake failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final baked = _baked;

    return Stack(
      fit: StackFit.expand,
      children: [
        // Dropped once covered, so an expensive placeholder (e.g. a
        // caller's blurred artwork fallback) isn't painted for nothing
        // underneath an opaque image on every frame.
        if (!_placeholderCovered) widget.placeholder,
        if (baked != null)
          _FadeIn(
            key: ObjectKey(baked),
            onEnd: () {
              if (mounted && identical(_baked, baked) && !_placeholderCovered) {
                setState(() => _placeholderCovered = true);
              }
            },
            child: RawImage(
              image: baked,
              fit: BoxFit.cover,
              filterQuality: FilterQuality.medium,
            ),
          ),
      ],
    );
  }
}

/// Fades its child in once when first built.
class _FadeIn extends StatelessWidget {
  const _FadeIn({super.key, required this.child, this.onEnd});

  final Widget child;
  final VoidCallback? onEnd;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: const Duration(milliseconds: 250),
      onEnd: onEnd,
      builder: (context, value, child) => Opacity(opacity: value, child: child),
      child: child,
    );
  }
}
