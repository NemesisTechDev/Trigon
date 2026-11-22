import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// A single line of text that, if it's too wide to fit its available
/// space, auto-scrolls right-to-left in a seamless, endlessly-repeating
/// loop instead of truncating with an ellipsis. Text that already fits
/// is left completely alone — static, centered/left per the parent,
/// no animation running — so this is a safe drop-in wherever a title
/// might occasionally be too long (mini player, Now Playing screen).
///
/// Why the loop is seamless (and used not to be):
///  * The scroll distance is measured with the SAME resolved text style
///    the real [Text] widgets use (ambient [DefaultTextStyle] + text
///    scale + bold-text setting). It used to be measured with only the
///    caller's partial style, so wherever the caller didn't spell out a
///    font family/size (most of the app — it inherits Chivo from the
///    theme) the measured width differed from the drawn width and the
///    text visibly jumped/hitched at every loop point.
///  * The second copy is positioned at exactly the loop distance rather
///    than trusting a Row's natural width, so the wrap point lines up
///    by construction.
///  * Position is derived from a running clock (px = time * speed,
///    modulo distance) rather than a restartable controller, so a
///    rebuild, a changed distance, or a stale delayed callback can no
///    longer restart the pause or change speed mid-scroll.
///  * The moving part is a cached layer that is only translated each
///    frame — no per-frame relayout of the text.
class MarqueeText extends StatefulWidget {
  final String text;
  final TextStyle? style;

  /// Blank space between the end of one loop and the start of the next.
  final double gap;

  /// How long the text sits still before it FIRST starts scrolling —
  /// gives a moment to read the beginning. After that the scroll is
  /// continuous and never pauses again.
  final Duration pauseAtStart;

  /// Scroll speed, in logical pixels per second.
  final double pixelsPerSecond;

  /// When true, text that already fits is centered within the available
  /// width (used by the Now Playing album-name header). Text that's too
  /// long still auto-scrolls across the full available width.
  final bool centered;

  /// Only used with [centered]. Nudges text that already fits this many
  /// logical pixels to the right of the available area's center (never
  /// far enough to leave the area), so a header whose area is off-center
  /// on screen can still keep short names centered on the screen itself.
  final double centerShift;

  const MarqueeText(
    this.text, {
    super.key,
    this.style,
    this.gap = 48,
    this.pauseAtStart = const Duration(seconds: 1),
    this.pixelsPerSecond = 32,
    this.centered = false,
    this.centerShift = 0,
  });

  @override
  State<MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<MarqueeText>
    with SingleTickerProviderStateMixin {
  /// Current scroll offset in logical pixels, 0 <= value < _distance.
  final ValueNotifier<double> _offset = ValueNotifier<double>(0);

  Ticker? _ticker;

  /// Loop length (text width + gap) from the most recent build.
  double _distance = 0;

  @override
  void didUpdateWidget(covariant MarqueeText oldWidget) {
    super.didUpdateWidget(oldWidget);

    // A new song loaded (different text) — go back to the start and let
    // build() restart the clock (with the initial pause) for the new
    // text. A style-only change just changes the measured distance on
    // the next build; the scroll keeps going without a restart.
    if (oldWidget.text != widget.text) {
      _ticker?.stop();
      _offset.value = 0;
    }
  }

  @override
  void dispose() {
    _ticker?.dispose();
    _offset.dispose();
    super.dispose();
  }

  void _onTick(Duration elapsed) {
    final distance = _distance;
    if (distance <= 0) return;

    final scrolled = elapsed - widget.pauseAtStart;
    if (scrolled <= Duration.zero) {
      _offset.value = 0;
      return;
    }

    final px = scrolled.inMicroseconds / 1000000.0 * widget.pixelsPerSecond;
    _offset.value = px % distance;
  }

  void _ensureScrolling() {
    final ticker = _ticker ??= createTicker(_onTick);
    if (ticker.isActive) return;
    _offset.value = 0;
    ticker.start();
  }

  void _ensureStopped() {
    final ticker = _ticker;
    if (ticker != null && ticker.isActive) ticker.stop();
    _distance = 0;
  }

  /// The style the real Text widgets will actually render with — same
  /// resolution Text itself does.
  TextStyle _resolvedStyle(BuildContext context) {
    var style = widget.style;
    if (style == null || style.inherit) {
      style = DefaultTextStyle.of(context).style.merge(style);
    }
    if (MediaQuery.boldTextOf(context)) {
      style = style.merge(const TextStyle(fontWeight: FontWeight.bold));
    }
    return style;
  }

  Widget _line({bool excludeSemantics = false}) {
    final line = Text(
      widget.text,
      style: widget.style,
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.visible,
    );
    return excludeSemantics ? ExcludeSemantics(child: line) : line;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth;

        // Must honor the system text scale, otherwise a larger font/
        // display-size setting makes the real Text wider than this
        // measurement, so long names get ellipsized (and sit
        // off-center) instead of auto-scrolling.
        final painter = TextPainter(
          text: TextSpan(text: widget.text, style: _resolvedStyle(context)),
          maxLines: 1,
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
          locale: Localizations.maybeLocaleOf(context),
        )..layout();
        final textWidth = painter.width;
        final textHeight = painter.height;
        painter.dispose();

        // Fits fine as-is — no animation, no extra widgets, just the
        // text (with a safety-net ellipsis in case measurement and
        // actual layout disagree by a hair, e.g. under font-scaling).
        if (textWidth <= maxWidth || maxWidth <= 0) {
          _ensureStopped();
          if (!widget.centered || !maxWidth.isFinite) {
            return Text(
              widget.text,
              style: widget.style,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            );
          }

          // Keep the text as close to `centerShift` right of the
          // area's center as still fits inside the area.
          final room = (maxWidth - textWidth) / 2;
          final shift =
              room <= 0 ? 0.0 : widget.centerShift.clamp(0.0, room).toDouble();
          return SizedBox(
            width: maxWidth,
            child: Padding(
              padding: EdgeInsets.only(left: shift * 2),
              child: Text(
                widget.text,
                style: widget.style,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
              ),
            ),
          );
        }

        _distance = textWidth + widget.gap;
        _ensureScrolling();

        final distance = _distance;

        return ClipRect(
          child: SizedBox(
            width: maxWidth,
            height: textHeight,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned(
                  left: 0,
                  top: 0,
                  child: AnimatedBuilder(
                    animation: _offset,
                    // Built once; each frame only moves it. The
                    // RepaintBoundary keeps the text's own picture
                    // cached instead of repainting it as it slides.
                    child: RepaintBoundary(
                      child: SizedBox(
                        width: distance + textWidth,
                        height: textHeight,
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            Positioned(left: 0, top: 0, child: _line()),
                            // Second copy exactly one loop away: the
                            // instant the first copy has scrolled a full
                            // `distance`, this one sits where the first
                            // started, so the wrap is invisible.
                            Positioned(
                              left: distance,
                              top: 0,
                              child: _line(excludeSemantics: true),
                            ),
                          ],
                        ),
                      ),
                    ),
                    builder: (context, child) {
                      return Transform.translate(
                        offset: Offset(-_offset.value, 0),
                        child: child,
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
