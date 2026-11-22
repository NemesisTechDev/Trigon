import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show applyBoxFit;
import '../../services/subtitle_appearance_settings.dart';
import '../models/subtitle_appearance.dart';
import '../player_manager.dart';
import 'subtitle_style.dart';

/// Draws the current subtitle text as a plain Flutter `Text` widget,
/// fed directly from [PlayerManager.currentSubtitleLines]. Android-only
/// — see `VideoSurface`'s doc comment for why the built-in
/// `SubtitleView` isn't used there.
///
/// Uses [kSubtitleTextStyle], the exact same style object the built-in
/// overlay uses on other platforms, so the two are guaranteed
/// pixel-identical rather than two hand-copied numbers that could
/// drift apart.
class CustomSubtitleOverlay extends StatelessWidget {
  final PlayerManager manager;

  /// Must match whatever `fit` the sibling `Video` widget is using —
  /// needed to work out where the video's actual visible bottom edge
  /// sits within this (usually larger, letterboxed) container, so text
  /// sits just above the video content itself rather than deep in a
  /// black bar below it.
  final BoxFit fit;

  const CustomSubtitleOverlay({
    super.key,
    required this.manager,
    required this.fit,
  });

  @override
  Widget build(BuildContext context) {
    // Deliberately NOT `Positioned` here — `Positioned` must be a
    // *direct* child of `Stack` in the render tree, and `LayoutBuilder`
    // (needed below, to know the actual container size) creates its
    // own RenderObject that would sit between them, triggering the
    // exact "Incorrect use of ParentDataWidget" bug already documented
    // in `VideoSurface`'s history for the same underlying reason.
    // `Align`/`Padding` have no such restriction, so positioning is
    // done with those instead, nested as deep as needed.
    return IgnorePointer(
      child: ValueListenableBuilder<SubtitleAppearance>(
        valueListenable: SubtitleAppearanceSettings.notifier,
        builder: (context, appearance, _) => LayoutBuilder(
        builder: (context, constraints) {
          final containerSize = Size(
            constraints.maxWidth,
            constraints.maxHeight,
          );

          return AnimatedBuilder(
            animation: Listenable.merge([
              manager.videoWidth,
              manager.videoHeight,
            ]),
            builder: (context, _) {
              // Default: sit near the container's own edges — used
              // until the video's real dimensions are known, or if
              // this container isn't actually bounded yet.
              // Height customization: the default offset reproduces the
              // original 24px / 5% gaps exactly.
              var bottomPadding =
                  24.0 * (appearance.bottomOffset / kSubtitleDefaultBottomOffset);
              var horizontalPadding = 24.0;
              var edgeMargin = 24.0;
              var visibleVideoHeight =
                  containerSize.height.isFinite ? containerSize.height : 300.0;

              final vw = manager.videoWidth.value;
              final vh = manager.videoHeight.value;

              if (vw != null &&
                  vh != null &&
                  vw > 0 &&
                  vh > 0 &&
                  containerSize.width.isFinite &&
                  containerSize.height.isFinite) {
                // Same math the Video widget itself uses internally to
                // fit the decoded frame into its bounds under the
                // current BoxFit — reproducing it here finds exactly
                // where the video's real edges land, instead of
                // guessing with a fixed offset. Covers both
                // letterboxing (bars top/bottom) and pillarboxing
                // (bars left/right — narrower-than-screen content).
                final fitted = applyBoxFit(
                  fit,
                  Size(vw.toDouble(), vh.toDouble()),
                  containerSize,
                );

                final videoTop =
                    (containerSize.height - fitted.destination.height) / 2;
                final videoBottom = (videoTop + fitted.destination.height)
                    .clamp(0.0, containerSize.height);
                visibleVideoHeight = fitted.destination.height
                    .clamp(0.0, containerSize.height);
                // Proportional, not a fixed 24px — see
                // kSubtitleEdgeMarginRatio.
                edgeMargin = visibleVideoHeight * kSubtitleEdgeMarginRatio;
                // Bottom gap is user-adjustable (Settings > Subtitle
                // style); the side margins stay at the fixed ratio.
                bottomPadding = (containerSize.height - videoBottom) +
                    visibleVideoHeight * appearance.bottomOffset;

                final videoLeft =
                    (containerSize.width - fitted.destination.width) / 2;
                horizontalPadding =
                    videoLeft.clamp(0.0, containerSize.width) + edgeMargin;
              }

              return Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: EdgeInsets.only(
                    left: horizontalPadding,
                    right: horizontalPadding,
                    bottom: bottomPadding,
                  ),
                  child: ValueListenableBuilder<List<String>>(
                    valueListenable: manager.currentSubtitleLines,
                    builder: (context, lines, _) {
                      final text = lines
                          .where((line) => line.trim().isNotEmpty)
                          .join('\n');

                      if (text.isEmpty) {
                        return const SizedBox.shrink();
                      }

                      // SIZE: proportional to the visible video height
                      // (see kSubtitleHeightRatio) instead of a fixed
                      // 24px, so portrait matches VLC's proportions and
                      // a PiP window gets the same ratio, scaling as it
                      // is resized. The system font-size setting is
                      // deliberately not applied on top — the size is
                      // already relative to the picture, and stacking
                      // both is what made portrait subtitles oversized.
                      //
                      // SIZE CAP: still shrinks further if the text
                      // wouldn't fit within ~35% of the visible video
                      // height (long lines on a narrow screen), so
                      // subtitles never take over the picture.
                      final scale = appearance.sizeScale;
                      final subtitleStyle = subtitleTextStyleFor(
                        appearance,
                        fontSize: (visibleVideoHeight *
                                kSubtitleHeightRatio *
                                scale)
                            .clamp(kSubtitleMinFontSize,
                                kSubtitleMaxFontSize * scale),
                      );
                      const baseScaler = TextScaler.noScaling;
                      final maxTextWidth = (containerSize.width.isFinite
                              ? containerSize.width - horizontalPadding * 2
                              : 300.0)
                          .clamp(40.0, double.infinity);
                      final maxTextHeight = (containerSize.height.isFinite
                              ? visibleVideoHeight * 0.35
                              : 120.0)
                          .clamp(40.0, double.infinity);

                      var scaler = baseScaler;
                      final baseFactor = baseScaler.scale(100) / 100;
                      var factor = baseFactor;
                      final direction = Directionality.of(context);

                      for (var i = 0; i < 12; i++) {
                        final painter = TextPainter(
                          text: TextSpan(text: text, style: subtitleStyle),
                          textAlign: TextAlign.center,
                          textDirection: direction,
                          textScaler: scaler,
                        )..layout(maxWidth: maxTextWidth);

                        if (painter.height <= maxTextHeight || factor <= 0.55) {
                          break;
                        }

                        factor -= 0.08;
                        scaler = TextScaler.linear(factor);
                      }

                      return Text(
                        text,
                        textAlign: TextAlign.center,
                        style: subtitleStyle,
                        textScaler: scaler,
                      );
                    },
                  ),
                ),
              );
            },
          );
        },
        ),
      ),
    );
  }
}
