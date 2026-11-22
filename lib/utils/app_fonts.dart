import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Dosis, for the app's "hero" display moments only (title/branding
/// text, section headers, now-playing names). Everything else in the
/// app defaults to Chivo via the global ThemeData.textTheme in
/// main.dart, so most widgets never need to touch this file.
///
/// Dosis' thin strokes wash out below ~18px on the app's dark
/// backgrounds, so this intentionally starts at SemiBold/Bold rather
/// than the typeface's default Light weight.
class AppFonts {
  AppFonts._();

  static TextStyle dosis({
    required double fontSize,
    Color color = Colors.white,
    FontWeight fontWeight = FontWeight.w600,
    double? height,
  }) {
    return GoogleFonts.dosis(
      fontSize: fontSize,
      color: color,
      fontWeight: fontWeight,
      height: height,
    );
  }
}
