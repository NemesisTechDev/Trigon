import 'dart:async';

import 'package:flutter/material.dart';

const _gold = Color(0xffD4AF37);

/// A thin, auto-hiding, draggable scrollbar overlay used across
/// Nemesis's long lists (Movies, Music, Live TV channel/guide
/// screens, playlist/download screens, favorites, etc.) instead of
/// the platform's default scrollbar.
///
/// Behavior (matches the reference recordings): fades in white while
/// scrolling, turns gold while pressed/dragged, fades back to white
/// on release, and fades out smoothly ~2 seconds after the last
/// vertical scroll activity — never disappears instantly.
///
/// Usage — wrap the existing scroll view, reusing whatever
/// [ScrollController] is already attached to it (create one if the
/// screen doesn't have one yet):
/// ```dart
/// FadeScrollbar(
///   controller: _scrollController,
///   child: ListView(controller: _scrollController, ...),
/// )
/// ```
/// The wrapped [child] is never rebuilt by this widget — only the
/// thumb overlay updates on scroll, via a [ValueNotifier] fed by a
/// listener on [controller], so this adds no extra rebuild cost to
/// whatever scroll view it wraps.
class FadeScrollbar extends StatefulWidget {
  final ScrollController controller;
  final Widget child;

  /// Distance from the trailing edge.
  final double rightPadding;
  final double thickness;
  final double minThumbExtent;

  /// Width of the invisible drag/tap hit area anchored to the trailing
  /// edge, with the visible thumb drawn inset from its right edge by
  /// [rightPadding]. Kept much wider than [thickness] so the thumb
  /// stays thin visually while remaining easy to grab — matches
  /// standard mobile fast-scroll touch targets (~24dp) rather than
  /// requiring a precise hit on the thin bar itself.
  final double touchTargetWidth;

  /// Vertical space, measured from the top of [child], that the thumb
  /// and its track never occupy — e.g. the height of a pinned
  /// [SliverPersistentHeader]'s collapsed bar sitting on top of the
  /// scroll view. The thumb's position still reflects scroll progress
  /// across the *entire* scrollable range; only the visible track is
  /// confined to start after this inset, so the thumb never overlaps
  /// the pinned bar. Defaults to 0 (track spans the full viewport, the
  /// original behavior) for screens with no pinned header to clear.
  final double topInset;

  const FadeScrollbar({
    super.key,
    required this.controller,
    required this.child,
    this.rightPadding = 3,
    this.thickness = 5,
    this.minThumbExtent = 36,
    this.topInset = 0,
    this.touchTargetWidth = 28,
  });

  @override
  State<FadeScrollbar> createState() => _FadeScrollbarState();
}

class _FadeScrollbarState extends State<FadeScrollbar> {
  final ValueNotifier<double> _pixels = ValueNotifier(0);
  bool _visible = false;
  bool _pressed = false;
  Timer? _hideTimer;

  double _dragStartPixels = 0;
  double _dragStartGlobalY = 0;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onScroll);
  }

  @override
  void didUpdateWidget(covariant FadeScrollbar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onScroll);
      widget.controller.addListener(_onScroll);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onScroll);
    _hideTimer?.cancel();
    _pixels.dispose();
    super.dispose();
  }

  // `ScrollController.position` asserts exactly one attached
  // ScrollPosition, and throws (red error screen) if a controller is
  // momentarily attached to two scroll views — e.g. a tab that's
  // fading out under CategorySwipeSwitcher while the same tab is
  // switched back to. This returns the position only when it's
  // unambiguous, otherwise null so the thumb simply hides for a frame.
  ScrollPosition? get _singlePosition {
    final positions = widget.controller.positions;
    return positions.length == 1 ? positions.first : null;
  }

  void _onScroll() {
    final position = _singlePosition;
    if (position == null || !position.hasPixels) return;
    _pixels.value = position.pixels;
    _show();
  }

  void _show() {
    if (!_visible && mounted) setState(() => _visible = true);
    _scheduleHide();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 2), () {
      if (!mounted || _pressed) return;
      setState(() => _visible = false);
    });
  }

  void _setPressed(bool pressed) {
    if (!mounted) return;
    setState(() => _pressed = pressed);
    if (!pressed) _scheduleHide();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewportHeight = constraints.maxHeight;

        return Stack(
          children: [
            widget.child,
            ValueListenableBuilder<double>(
              valueListenable: _pixels,
              builder: (context, pixels, _) {
                final position = _singlePosition;
                if (position == null || !position.hasContentDimensions) {
                  return const SizedBox.shrink();
                }

                final maxExtent = position.maxScrollExtent;
                if (maxExtent <= 0) return const SizedBox.shrink();

                // Track lives only in the area below the pinned header,
                // not the full viewport — the thumb's position still
                // reflects scroll progress across the whole scrollable
                // range, it's just drawn starting further down.
                final trackHeight =
                    (viewportHeight - widget.topInset).clamp(0.0, viewportHeight);
                if (trackHeight <= 0) return const SizedBox.shrink();

                final thumbExtent = (trackHeight *
                        trackHeight /
                        (trackHeight + maxExtent))
                    .clamp(widget.minThumbExtent, trackHeight);
                final trackExtent = trackHeight - thumbExtent;
                final thumbTop = widget.topInset +
                    (trackExtent <= 0
                        ? 0.0
                        : trackExtent * (pixels / maxExtent).clamp(0.0, 1.0));

                return Positioned(
                  right: 0,
                  top: thumbTop,
                  // The hit area is a wide, invisible strip anchored to
                  // the trailing edge; the visible thumb is drawn
                  // inset within it via Align + Padding below, so
                  // dragging/tapping anywhere across the wider strip
                  // moves the thumb, not just a precise hit on the
                  // thin bar itself.
                  child: SizedBox(
                    width: widget.touchTargetWidth,
                    height: thumbExtent,
                    child: GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onVerticalDragStart: (details) {
                        _dragStartPixels = pixels;
                        _dragStartGlobalY = details.globalPosition.dy;
                        _setPressed(true);
                      },
                      onVerticalDragUpdate: (details) {
                        if (trackExtent <= 0) return;
                        final deltaY =
                            details.globalPosition.dy - _dragStartGlobalY;
                        final deltaScroll = deltaY * (maxExtent / trackExtent);
                        final target = (_dragStartPixels + deltaScroll)
                            .clamp(0.0, maxExtent);
                        final active = _singlePosition;
                        if (active == null) return;
                        active.jumpTo(target);
                      },
                      onVerticalDragEnd: (_) => _setPressed(false),
                      onVerticalDragCancel: () => _setPressed(false),
                      onTapDown: (_) => _setPressed(true),
                      onTapUp: (_) => _setPressed(false),
                      onTapCancel: () => _setPressed(false),
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: Padding(
                          padding: EdgeInsets.only(right: widget.rightPadding),
                          child: AnimatedOpacity(
                            opacity: _visible ? 1 : 0,
                            duration:
                                Duration(milliseconds: _visible ? 180 : 600),
                            curve: Curves.easeOut,
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 150),
                              width: widget.thickness,
                              height: thumbExtent,
                              decoration: BoxDecoration(
                                color: _pressed
                                    ? _gold
                                    : Colors.white.withValues(alpha: 0.55),
                                borderRadius:
                                    BorderRadius.circular(widget.thickness / 2),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ],
        );
      },
    );
  }
}
