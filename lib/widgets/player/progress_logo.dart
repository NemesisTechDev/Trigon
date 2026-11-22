import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../player/load_progress.dart';
import '../../services/cache/nemesis_image_cache.dart';
import 'pulsing_logo.dart';

/// The logo shown on the loading screen.
///
///  * It always pulsates, with exactly the same beat as the buffering logo
///    (see [kLogoPulseDuration]).
///  * Until a source has been chosen it is dim and uncoloured.
///  * From the moment a source is chosen its colours fill in from left to
///    right. The fill is [PlaybackLoadProgress.value]: real milestones from
///    the player and the torrent engine, not a timer (see that class).
///
/// When no logo artwork is known (yet), [title] is shown in its place and
/// behaves the same way; if the artwork turns up a moment later it simply
/// takes over without restarting the pulse or the fill.
class ProgressLogo extends StatefulWidget {
  const ProgressLogo({
    super.key,
    this.logoUrl,
    required this.title,
    this.width = 250,
  });

  final String? logoUrl;
  final String title;
  final double width;

  @override
  State<ProgressLogo> createState() => _ProgressLogoState();
}

class _ProgressLogoState extends State<ProgressLogo>
    with TickerProviderStateMixin {
  late final AnimationController _intro;
  late final AnimationController _pulse;

  static const _desaturate = ColorFilter.matrix(<double>[
    0.2126, 0.7152, 0.0722, 0, 0,
    0.2126, 0.7152, 0.0722, 0, 0,
    0.2126, 0.7152, 0.0722, 0, 0,
    0, 0, 0, 1, 0,
  ]);

  @override
  void initState() {
    super.initState();
    _intro = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 450),
    )..forward();
    // Pulses from the first frame and never stops while this is on screen.
    _pulse = AnimationController(
      vsync: this,
      duration: kLogoPulseDuration,
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _intro.dispose();
    _pulse.dispose();
    super.dispose();
  }

  Widget _content() {
    final url = widget.logoUrl;
    if (url != null && url.isNotEmpty) {
      return CachedNetworkImage(
        cacheManager: NemesisImageCache.instance,
        imageUrl: url,
        width: widget.width,
        fit: BoxFit.contain,
        fadeInDuration: Duration.zero,
        placeholder: (_, __) => SizedBox(width: widget.width),
        errorWidget: (_, __, ___) => SizedBox(width: widget.width),
      );
    }
    return SizedBox(
      width: widget.width,
      child: Text(
        widget.title,
        textAlign: TextAlign.center,
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 26,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final progress = PlaybackLoadProgress.instance;

    return AnimatedBuilder(
      animation: Listenable.merge([_intro, _pulse]),
      builder: (context, child) {
        final grow = Curves.easeOutBack.transform(_intro.value);
        final beat = kLogoPulseMin + _pulse.value * kLogoPulseRange;
        return Opacity(
          opacity: _intro.value.clamp(0.0, 1.0).toDouble(),
          child: Transform.scale(
            scale: (0.8 + 0.2 * grow) * beat,
            child: child,
          ),
        );
      },
      child: Stack(
        alignment: Alignment.center,
        children: [
          // The part not loaded yet: dim and uncoloured.
          Opacity(
            opacity: 0.32,
            child: ColorFiltered(colorFilter: _desaturate, child: _content()),
          ),
          // The part already loaded: full colour, revealed left to right.
          ValueListenableBuilder<bool>(
            valueListenable: progress.linkChosen,
            builder: (_, chosen, __) => ValueListenableBuilder<double>(
              valueListenable: progress.value,
              builder: (_, fill, __) => TweenAnimationBuilder<double>(
                // Eases between the real readings so the fill glides
                // instead of jumping; it still ends exactly where they say.
                tween: Tween<double>(end: chosen ? fill : 0.0),
                duration: const Duration(milliseconds: 700),
                curve: Curves.easeOut,
                builder: (_, shown, child) => ClipRect(
                  clipper: _FillClipper(shown),
                  child: child,
                ),
                child: _content(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FillClipper extends CustomClipper<Rect> {
  _FillClipper(this.fraction);
  final double fraction;

  @override
  Rect getClip(Size size) => Rect.fromLTWH(
        0,
        0,
        size.width * fraction.clamp(0.0, 1.0).toDouble(),
        size.height,
      );

  @override
  bool shouldReclip(covariant _FillClipper old) => old.fraction != fraction;
}
