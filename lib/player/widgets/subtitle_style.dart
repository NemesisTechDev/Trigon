import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../models/subtitle_appearance.dart';

/// Single source of truth for subtitle text styling, shared between the
/// built-in `SubtitleView` (used on every platform except Android, see
/// `VideoSurface`) and `CustomSubtitleOverlay` (Android only) — using
/// the same style object in both places guarantees they're
/// pixel-identical instead of two numbers that could quietly drift
/// apart over time.
///
/// Deliberately no `shadows`/`backgroundColor` — plain flat text, no
/// glow or highlight behind it.
const kSubtitleTextStyle = TextStyle(
  color: Colors.white,
  fontSize: 24,
  // Regular weight by default — the "Bold text" switch in Subtitle Style
  // is the only thing that makes subtitles bold.
  fontWeight: FontWeight.w400,
  height: 1.4,
  letterSpacing: 0,
);

/// SUBTITLE SIZE RATIOS (Android `CustomSubtitleOverlay`): subtitle size
/// is a fixed fraction of the *visible video height* (the letterboxed
/// picture itself, not the screen or window), the way VLC sizes it, so
/// it reads the same proportion in portrait, landscape and inside a PiP
/// window — and grows/shrinks with the PiP window as it is resized.
/// Calibrated against a VLC portrait reference (text ≈ 5.5% of the
/// picture height).
const double kSubtitleHeightRatio = 0.055;

/// Gap between the subtitle block and the video's bottom/side edges, as
/// a fraction of the visible video height (was a fixed 24px, which is
/// far too large inside a small PiP window).
const double kSubtitleEdgeMarginRatio = 0.05;

/// Sanity bounds on the resulting font size (logical px) so a tiny PiP
/// window stays legible and a huge tablet/desktop surface stays sane.
const double kSubtitleMinFontSize = 6;
const double kSubtitleMaxFontSize = 48;

/// Largest system text-scale the subtitles will honor. The rest of the
/// UI follows the user's font-size setting fully, but subtitles are drawn
/// *on top of the video*, so at e.g. 1.5-2x they used to swallow the whole
/// portrait screen (or half the picture in landscape). Up to this factor
/// they still grow with the setting; beyond it they stop.
const double kSubtitleMaxTextScale = 1.15;

/// The system text scaler, clamped to [kSubtitleMaxTextScale].
TextScaler clampedSubtitleScaler(BuildContext context) {
  final scaler = MediaQuery.textScalerOf(context);
  final factor = scaler.scale(100) / 100;
  return factor <= kSubtitleMaxTextScale
      ? scaler
      : const TextScaler.linear(kSubtitleMaxTextScale);
}

/// Builds the actual subtitle [TextStyle] for a user-chosen
/// [SubtitleAppearance] — shared by the player overlay, the non-Android
/// built-in `SubtitleView`, and the Subtitle Style screen's preview so
/// all three are guaranteed identical. With
/// [SubtitleAppearance.defaults] this returns [kSubtitleTextStyle]
/// unchanged (apart from [fontSize]).
TextStyle subtitleTextStyleFor(
  SubtitleAppearance a, {
  double? fontSize,
}) {
  final size = fontSize ?? kSubtitleTextStyle.fontSize!;
  // Edge offset scales with the text so it looks the same at any size.
  final o = (size * 0.06).clamp(1.0, 3.0);
  final edge = a.edgeColor;

  final List<Shadow>? shadows = switch (a.edgeStyle) {
    SubtitleEdgeStyle.none => null,
    SubtitleEdgeStyle.outline => [
        for (final d in const [
          Offset(-1, -1),
          Offset(0, -1),
          Offset(1, -1),
          Offset(-1, 0),
          Offset(1, 0),
          Offset(-1, 1),
          Offset(0, 1),
          Offset(1, 1),
        ])
          Shadow(color: edge, offset: d * o * 0.8, blurRadius: 1),
      ],
    SubtitleEdgeStyle.dropShadow => [
        Shadow(color: edge, offset: Offset(o, o), blurRadius: o * 2),
      ],
    SubtitleEdgeStyle.raised => [
        Shadow(color: edge, offset: Offset(o, o), blurRadius: 0),
      ],
    SubtitleEdgeStyle.depressed => [
        Shadow(color: edge, offset: Offset(-o, -o), blurRadius: 0),
      ],
  };

  final weight = a.bold ? FontWeight.w700 : FontWeight.w400;

  final base = kSubtitleTextStyle.copyWith(
    // ROOT CAUSE (subtitles still bold at defaults despite fontWeight
    // w400): with "App font" selected, flutterFamily is null, so the
    // style used to INHERIT its fontFamily from whatever DefaultTextStyle
    // sat above the subtitle Text. The app font is google_fonts' Chivo,
    // which bakes the weight into the family NAME (Chivo_regular,
    // Chivo_700, ...) and registers one font file per name — so an
    // inherited heavier family name wins and fontWeight: w400 is only a
    // hint that can't pull it back to the regular file. inherit: false
    // cuts every ambient leak (family, fontStyle, decoration, variations)
    // so the subtitle's look depends solely on SubtitleAppearance.
    inherit: false,
    color: a.textColor,
    fontSize: size,
    fontFamily: a.fontFamily.flutterFamily,
    // Unchecked = regular weight (matches the switch being off); checked = bold.
    fontWeight: weight,
    backgroundColor: a.backgroundOpacity > 0 ? a.effectiveBackground : null,
    shadows: shadows,
  );

  // "App font": resolve Chivo explicitly for the exact weight, so the
  // family name and the weight always agree (Chivo_regular for w400,
  // Chivo_700 for the Bold switch) regardless of the ambient style.
  if (a.fontFamily.flutterFamily == null) {
    return GoogleFonts.chivo(textStyle: base, fontWeight: weight);
  }
  return base;
}
