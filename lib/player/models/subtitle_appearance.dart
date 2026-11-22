import 'dart:convert';

import 'package:flutter/material.dart';

/// Font choices for subtitles. [app] is the app's own font (Chivo) — the
/// default, i.e. exactly what subtitles looked like before this was
/// customizable. The rest map to Android's generic system families.
enum SubtitleFontFamily {
  app('App font', null, 'SANS_SERIF'),
  sansSerif('Sans Serif', 'sans-serif', 'SANS_SERIF'),
  serif('Serif', 'serif', 'SERIF'),
  monospace('Monospace', 'monospace', 'MONOSPACED_SANS_SERIF'),
  casual('Casual', 'casual', 'CASUAL'),
  cursive('Cursive', 'cursive', 'CURSIVE');

  final String label;

  /// Flutter `fontFamily` — null means "inherit the app theme font".
  final String? flutterFamily;

  /// Google Cast `TextTrackStyle.fontGenericFamily` value.
  final String castGenericFamily;

  const SubtitleFontFamily(this.label, this.flutterFamily, this.castGenericFamily);
}

/// Text edge (outline/shadow) styles — same set Android's own caption
/// settings and the Cast SDK's `TextTrackStyle.edgeType` offer.
enum SubtitleEdgeStyle {
  none('None', 'NONE'),
  outline('Outline', 'OUTLINE'),
  dropShadow('Drop shadow', 'DROP_SHADOW'),
  raised('Raised', 'RAISED'),
  depressed('Depressed', 'DEPRESSED');

  final String label;
  final String castEdgeType;

  const SubtitleEdgeStyle(this.label, this.castEdgeType);
}

/// Swatches shown in every color row of the subtitle style screen
/// (same 14 colors as Android's caption settings).
const List<Color> kSubtitleSwatches = [
  Color(0xFF000000),
  Color(0xFFFFFFFF),
  Color(0xFF607D8B),
  Color(0xFF795548),
  Color(0xFFE91E1E),
  Color(0xFFFF9800),
  Color(0xFFFFFF00),
  Color(0xFF2A9D2A),
  Color(0xFF009688),
  Color(0xFF00BCD4),
  Color(0xFF03A9F4),
  Color(0xFF3F51B5),
  Color(0xFF9C27B0),
  Color(0xFFE91E63),
];

/// Multipliers applied on top of the default subtitle size
/// (`kSubtitleHeightRatio`). Index [kSubtitleDefaultSizeIndex] is 1.0 —
/// today's size.
const List<double> kSubtitleSizeScales = [0.6, 0.8, 1.0, 1.3, 1.6, 2.0];
const int kSubtitleDefaultSizeIndex = 2;

/// Default gap between the subtitle and the bottom edge of the picture,
/// as a fraction of the visible video height (was
/// `kSubtitleEdgeMarginRatio` before heights were customizable).
const double kSubtitleDefaultBottomOffset = 0.05;

/// Highest bottom offset the height slider allows.
const double kSubtitleMaxBottomOffset = 0.45;

/// Every user-customizable subtitle property. The default instance is
/// *exactly* the previous hard-coded look: app font, default size, white
/// text, no background, default height, no edge, regular (non-bold) weight.
@immutable
class SubtitleAppearance {
  final Color textColor;
  final Color backgroundColor;

  /// 0 = no background (default), 1 = fully opaque.
  final double backgroundOpacity;
  final SubtitleFontFamily fontFamily;

  /// Index into [kSubtitleSizeScales].
  final int sizeIndex;

  /// Distance of the subtitle above the picture's bottom edge, as a
  /// fraction of the visible video height.
  final double bottomOffset;
  final SubtitleEdgeStyle edgeStyle;
  final Color edgeColor;
  final bool bold;

  const SubtitleAppearance({
    this.textColor = const Color(0xFFFFFFFF),
    this.backgroundColor = const Color(0xFF000000),
    this.backgroundOpacity = 0.0,
    this.fontFamily = SubtitleFontFamily.app,
    this.sizeIndex = kSubtitleDefaultSizeIndex,
    this.bottomOffset = kSubtitleDefaultBottomOffset,
    this.edgeStyle = SubtitleEdgeStyle.none,
    this.edgeColor = const Color(0xFF000000),
    this.bold = false,
  });

  static const SubtitleAppearance defaults = SubtitleAppearance();

  double get sizeScale => kSubtitleSizeScales[
      sizeIndex.clamp(0, kSubtitleSizeScales.length - 1)];

  bool get isDefault => this == defaults;

  /// Background color with the opacity slider folded into its alpha.
  Color get effectiveBackground =>
      backgroundColor.withValues(alpha: backgroundOpacity.clamp(0.0, 1.0));

  SubtitleAppearance copyWith({
    Color? textColor,
    Color? backgroundColor,
    double? backgroundOpacity,
    SubtitleFontFamily? fontFamily,
    int? sizeIndex,
    double? bottomOffset,
    SubtitleEdgeStyle? edgeStyle,
    Color? edgeColor,
    bool? bold,
  }) {
    return SubtitleAppearance(
      textColor: textColor ?? this.textColor,
      backgroundColor: backgroundColor ?? this.backgroundColor,
      backgroundOpacity: backgroundOpacity ?? this.backgroundOpacity,
      fontFamily: fontFamily ?? this.fontFamily,
      sizeIndex: sizeIndex ?? this.sizeIndex,
      bottomOffset: bottomOffset ?? this.bottomOffset,
      edgeStyle: edgeStyle ?? this.edgeStyle,
      edgeColor: edgeColor ?? this.edgeColor,
      bold: bold ?? this.bold,
    );
  }

  Map<String, dynamic> toJson() => {
        'textColor': textColor.toARGB32(),
        'backgroundColor': backgroundColor.toARGB32(),
        'backgroundOpacity': backgroundOpacity,
        'fontFamily': fontFamily.name,
        'sizeIndex': sizeIndex,
        'bottomOffset': bottomOffset,
        'edgeStyle': edgeStyle.name,
        'edgeColor': edgeColor.toARGB32(),
        'bold': bold,
      };

  String encode() => jsonEncode(toJson());

  /// Tolerant decode: any missing/garbled field falls back to its default
  /// so a bad or older stored blob can never break subtitles.
  factory SubtitleAppearance.fromJson(Map<String, dynamic> json) {
    const d = SubtitleAppearance.defaults;
    Color color(String key, Color fallback) {
      final v = json[key];
      return v is int ? Color(v) : fallback;
    }

    T enumByName<T extends Enum>(List<T> values, String key, T fallback) {
      final v = json[key];
      for (final e in values) {
        if (e.name == v) return e;
      }
      return fallback;
    }

    final opacity = json['backgroundOpacity'];
    final size = json['sizeIndex'];
    final offset = json['bottomOffset'];
    return SubtitleAppearance(
      textColor: color('textColor', d.textColor),
      backgroundColor: color('backgroundColor', d.backgroundColor),
      backgroundOpacity:
          opacity is num ? opacity.toDouble().clamp(0.0, 1.0) : d.backgroundOpacity,
      fontFamily:
          enumByName(SubtitleFontFamily.values, 'fontFamily', d.fontFamily),
      sizeIndex: size is int
          ? size.clamp(0, kSubtitleSizeScales.length - 1)
          : d.sizeIndex,
      bottomOffset: offset is num
          ? offset.toDouble().clamp(0.0, kSubtitleMaxBottomOffset)
          : d.bottomOffset,
      edgeStyle: enumByName(SubtitleEdgeStyle.values, 'edgeStyle', d.edgeStyle),
      edgeColor: color('edgeColor', d.edgeColor),
      bold: json['bold'] is bool ? json['bold'] as bool : d.bold,
    );
  }

  static SubtitleAppearance? tryDecode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return SubtitleAppearance.fromJson(Map<String, dynamic>.from(decoded));
      }
    } catch (_) {}
    return null;
  }

  /// Wire/Cast representation used for the TV: Google Cast
  /// `TextTrackStyle` field names (also reused as the Nemesis Native
  /// `setSubtitleStyle` payload, plus `bottomOffset` which only the
  /// Nemesis receiver can honor).
  Map<String, dynamic> toCastStyleJson() {
    String hex(Color c) {
      String h(double v) =>
          (v * 255).round().clamp(0, 255).toRadixString(16).padLeft(2, '0');
      return '#${h(c.r)}${h(c.g)}${h(c.b)}${h(c.a)}'.toUpperCase();
    }

    return {
      'foregroundColor': hex(textColor),
      'backgroundColor': hex(effectiveBackground),
      'edgeType': edgeStyle.castEdgeType,
      'edgeColor': hex(edgeColor),
      'fontScale': sizeScale,
      'fontStyle': bold ? 'BOLD' : 'NORMAL',
      'fontGenericFamily': fontFamily.castGenericFamily,
      'bottomOffset': bottomOffset,
    };
  }

  /// Payload for the Android Cast SDK bridge (`MainActivity.kt`'s
  /// `com.nemesis.app/cast_subtitle_style` channel), which fills a native
  /// `TextTrackStyle` from it. Colors are plain ARGB ints (what
  /// `TextTrackStyle.setForegroundColor` etc. take — NOT the `#RRGGBBAA`
  /// strings of [toCastStyleJson]); enum-like fields are the Cast SDK's own
  /// integer constants:
  ///   edgeType: NONE=0 OUTLINE=1 DROP_SHADOW=2 RAISED=3 DEPRESSED=4
  ///   fontGenericFamily: SANS_SERIF=0 SERIF=1 MONOSPACED_SANS_SERIF=2
  ///                      CASUAL=4 CURSIVE=5
  ///   fontStyle: NORMAL=0 BOLD=1
  /// `windowType` is pinned to NONE (0) with a transparent window so the
  /// receiver never draws its own box behind the text — the in-app default
  /// has no background either.
  Map<String, dynamic> toAndroidCastStyle() {
    final int edge = switch (edgeStyle) {
      SubtitleEdgeStyle.none => 0,
      SubtitleEdgeStyle.outline => 1,
      SubtitleEdgeStyle.dropShadow => 2,
      SubtitleEdgeStyle.raised => 3,
      SubtitleEdgeStyle.depressed => 4,
    };
    final int family = switch (fontFamily) {
      // The receiver can't load the app's Chivo, so "App font" falls
      // back to the generic sans-serif on the TV (same as Sans Serif).
      SubtitleFontFamily.app => 0,
      SubtitleFontFamily.sansSerif => 0,
      SubtitleFontFamily.serif => 1,
      SubtitleFontFamily.monospace => 2,
      SubtitleFontFamily.casual => 4,
      SubtitleFontFamily.cursive => 5,
    };
    // ROOT CAUSE (TV subtitles keep the receiver's black box at the
    // untouched defaults): the Cast SDK's TextTrackStyle treats
    // COLOR_UNSPECIFIED == 0 as "not set" and leaves that field out of
    // the message it sends. The app default background is "black at 0%
    // opacity" == ARGB 0x00000000 == exactly 0, so it was dropped and the
    // Default Media Receiver fell back to its own opaque black caption
    // box. A fully transparent color is therefore sent as a NON-zero
    // value whose alpha is still 0 (0x00000001) — see [_sdkColor].
    return {
      'foregroundColor': _sdkColor(textColor),
      'backgroundColor': _sdkColor(effectiveBackground),
      'edgeType': edge,
      'edgeColor': _sdkColor(edgeColor),
      'fontScale': sizeScale,
      'fontStyle': bold ? 1 : 0,
      'fontGenericFamily': family,
      'windowType': 0,
      'windowColor': _sdkColor(const Color(0x00000000)),
    };
  }

  /// ARGB for the Android Cast SDK: never exactly 0 (the SDK's
  /// "unspecified" sentinel, which it leaves out of the message), and
  /// normalized to a signed 32-bit int like every Android color. A fully
  /// transparent black becomes 0x00000001 — alpha is still 0, so it
  /// renders as nothing.
  static int _sdkColor(Color c) {
    var v = c.toARGB32();
    if (v == 0) v = 0x00000001;
    return v.toSigned(32);
  }

  @override
  bool operator ==(Object other) =>
      other is SubtitleAppearance &&
      other.textColor.toARGB32() == textColor.toARGB32() &&
      other.backgroundColor.toARGB32() == backgroundColor.toARGB32() &&
      other.backgroundOpacity == backgroundOpacity &&
      other.fontFamily == fontFamily &&
      other.sizeIndex == sizeIndex &&
      other.bottomOffset == bottomOffset &&
      other.edgeStyle == edgeStyle &&
      other.edgeColor.toARGB32() == edgeColor.toARGB32() &&
      other.bold == bold;

  @override
  int get hashCode => Object.hash(
        textColor.toARGB32(),
        backgroundColor.toARGB32(),
        backgroundOpacity,
        fontFamily,
        sizeIndex,
        bottomOffset,
        edgeStyle,
        edgeColor.toARGB32(),
        bold,
      );
}
