import 'package:flutter/material.dart';

import '../../utils/artwork_accent_extractor.dart';

/// Replaces the old blurred-artwork background with a Spotify-style
/// dynamic accent: a vertical gradient that fades from a color pulled
/// out of the current artwork, down into black. Wrap the rest of the
/// audio player screen's content in this so it always sits on a tint
/// that matches whatever's playing, instead of a smeared blurred photo.
class PlayerAccentBackground extends StatefulWidget {
  const PlayerAccentBackground({
    super.key,
    required this.imageUrl,
    required this.child,
    this.useGradient = true,
  });

  final String? imageUrl;
  final Widget child;

  // The lyrics screen reuses this same artwork-derived accent so it
  // feels like a continuation of the player, but explicitly without the
  // fade-to-black gradient (which would make long lyric text hard to
  // read once it scrolls into the darker lower portion of the screen).
  // Setting this to false renders the top accent color as a flat fill
  // instead.
  final bool useGradient;

  @override
  State<PlayerAccentBackground> createState() =>
      _PlayerAccentBackgroundState();
}

class _PlayerAccentBackgroundState extends State<PlayerAccentBackground> {
  // A dark neutral rather than pure black so tracks with no artwork (or
  // while the accent is still being extracted) don't flash to a harsher
  // black-on-black than the rest of the UI.
  static const _fallback = Color(0xff121212);

  Color _accent = _fallback;

  @override
  void initState() {
    super.initState();
    _loadAccent();
  }

  @override
  void didUpdateWidget(covariant PlayerAccentBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageUrl != widget.imageUrl) {
      _loadAccent();
    }
  }

  Future<void> _loadAccent() async {
    final url = widget.imageUrl;

    if (url == null) {
      if (mounted) setState(() => _accent = _fallback);
      return;
    }

    final color = await ArtworkAccentExtractor.extractFromUrl(url);

    // The track may have changed again while the extraction was in
    // flight — bail out rather than applying a now-stale color.
    if (!mounted || widget.imageUrl != url) return;

    setState(() => _accent = color ?? _fallback);
  }

  @override
  Widget build(BuildContext context) {
    // The raw extracted color is often too bright/saturated to sit
    // behind white text at full strength, so it's darkened before being
    // used as the gradient's top stop — this keeps the hue but grounds
    // it, matching the moody wash in apps like Spotify rather than a
    // bright color block.
    final hsl = HSLColor.fromColor(_accent);
    final topColor = hsl
        .withLightness((hsl.lightness * 0.55).clamp(0.12, 0.42))
        .withSaturation((hsl.saturation * 0.9).clamp(0.0, 0.85))
        .toColor();

    return AnimatedContainer(
      duration: const Duration(milliseconds: 700),
      curve: Curves.easeOut,
      decoration: BoxDecoration(
        color: widget.useGradient ? null : topColor,
        gradient: widget.useGradient
            ? LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            topColor,
            Color.lerp(topColor, Colors.black, 0.75)!,
            Colors.black,
          ],
          stops: const [0.0, 0.55, 1.0],
        )
            : null,
      ),
      child: widget.child,
    );
  }
}
