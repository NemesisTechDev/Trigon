import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Background color and corner radius shared by every "Nemesis bottom
/// sheet" pop-up in the app — same values the video player's own Info
/// sheet uses (see `player/widgets/info_sheet.dart`).
const Color kNemesisSheetBg = Color(0xff181818);
const double kNemesisSheetRadius = 20;

/// The one bottom-sheet "chrome" every pop-up tab in the app shares —
/// trailer, cast info, song options, TV guide program info, Continue
/// Watching's long-press options, and every video player control sheet
/// (Audio/Subtitles/Speed/Quality/Search-online).
///
/// Modeled directly on the video player's own Info sheet
/// (`showPlayerInfoSheet` in `player/widgets/info_sheet.dart`) — the
/// reference implementation every other pop-up in the app is meant to
/// match: same rounded top corners, same drag handle, same drag
/// up/down to resize, same tap-anywhere-outside-to-close, same
/// back-gesture-to-close, same drag-down-to-dismiss.
///
/// All of that comes from the same two ingredients info_sheet.dart
/// uses: a transparent, `isScrollControlled`, root-navigator
/// `showModalBottomSheet` (tap-outside and back-gesture dismissal are
/// just what a modal route already gives you for free) wrapping a
/// `DraggableScrollableSheet` (drag up/down to resize, and
/// drag-down-to-dismiss once it's dragged past [minChildSize]).
///
/// [builder] gets that sheet's `ScrollController` — attach it to
/// whatever scrollable actually holds your content (ListView,
/// SingleChildScrollView, ...) the same way info_sheet.dart's own
/// ListView does, or up/down dragging has no scroll position to read
/// and won't resize/dismiss the sheet.
///
/// OPENING SIZE (automatic) vs. DRAGGING SIZE (manual):
///  * Portrait: the sheet opens exactly as tall as its content, so every
///    option is visible with no empty space under the last one. Content
///    taller than the screen opens at the top limit (about 92%) and
///    scrolls. [maxChildSize] (raised if the content needs more) is how
///    far the user can drag it up by hand — extra empty space there is
///    only ever the user's own doing.
///  * Landscape: the sheet never opens taller than 2/3 of the screen,
///    however much content there is. The user can drag it up to the
///    full screen (just under the status bar when it is showing); once
///    it is fully up, the content scrolls to reveal the rest.
///  * [initialChildSize]/[minChildSize] are only fallbacks now
///    (`fitContent: false`, or a body with no scrollable to measure).
///
/// [fitContent] — pass false for a body whose height is deliberately not
/// "its content" (a playing trailer, a search box that raises the
/// keyboard): it then opens at [initialChildSize] (capped to 2/3 in
/// landscape) instead of being measured.
Future<T?> showNemesisBottomSheet<T>(
  BuildContext context, {
  required Widget Function(BuildContext context, ScrollController controller)
      builder,
  double initialChildSize = 0.5,
  double minChildSize = 0.25,
  double maxChildSize = 0.92,
  bool fitContent = true,
}) {
  return showModalBottomSheet<T>(
    context: context,
    // Sheets are opened from screens that live inside the tab's nested
    // content Navigator, underneath the app's floating bottom nav bar/
    // mini player (a separate overlay in the outer Scaffold). Without
    // the root navigator they'd render *behind* those instead of
    // covering them — same reasoning info_sheet.dart's own
    // showPlayerInfoSheet follows.
    useRootNavigator: true,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (_) => _NemesisSheetHost(
      builder: builder,
      initialChildSize: initialChildSize,
      minChildSize: minChildSize,
      maxChildSize: maxChildSize,
      fitContent: fitContent,
    ),
  );
}

/// Largest fraction of the screen a sheet may OPEN at in landscape.
const double kNemesisSheetLandscapeAutoFraction = 2 / 3;

/// Top limit for a sheet that opens by itself in portrait.
const double _kPortraitAutoCap = 0.92;

/// Smallest "dismiss" extent used while fitting, so even a short sheet
/// can open at exactly its content height (see _NemesisSheetHostState).
const double _kFitMinCap = 0.2;

/// Size changes smaller than this are treated as "no change".
const double _kSizeEpsilon = 0.004;

/// The system status-bar height in logical pixels, read from the view
/// itself: showModalBottomSheet strips the top padding out of the
/// MediaQuery its content sees, so MediaQuery would always say 0 here.
double _systemTopInset(BuildContext context) {
  final view = View.maybeOf(context);
  if (view == null) return 0;
  return view.padding.top / view.devicePixelRatio;
}

/// Orientation-aware sizes for the few sheets that run their own
/// [DraggableScrollableSheet] instead of [showNemesisBottomSheet] (cast
/// device picker, playlist pickers): same landscape rule — never open
/// above 2/3 of the screen, draggable up to the full screen. Portrait
/// values pass through unchanged.
({double initial, double min, double max}) nemesisSheetSizes(
  BuildContext context, {
  required double initial,
  required double min,
  required double max,
}) {
  final size = MediaQuery.sizeOf(context);
  if (size.width <= size.height) {
    return (initial: initial, min: min, max: max);
  }
  final i = math.min(initial, kNemesisSheetLandscapeAutoFraction);
  final top = size.height <= 0 ? 0.0 : _systemTopInset(context) / size.height;
  return (
    initial: i,
    min: math.min(min, i - 0.02),
    max: (1.0 - top).clamp(i + 0.05, 1.0).toDouble(),
  );
}

class _NemesisSheetHost extends StatefulWidget {
  const _NemesisSheetHost({
    required this.builder,
    required this.initialChildSize,
    required this.minChildSize,
    required this.maxChildSize,
    required this.fitContent,
  });

  final Widget Function(BuildContext context, ScrollController controller)
      builder;
  final double initialChildSize;
  final double minChildSize;
  final double maxChildSize;
  final bool fitContent;

  @override
  State<_NemesisSheetHost> createState() => _NemesisSheetHostState();
}

class _NemesisSheetHostState extends State<_NemesisSheetHost> {
  final DraggableScrollableController _sheet = DraggableScrollableController();

  ScrollController? _scroll;

  // Latest facts from the layout (written during build, only read later).
  double _height = 0;
  bool _landscape = false;
  bool _hasLayout = false;
  double _bottomInset = 0;
  double _topInset = 0;

  /// False while the first measurement is pending: the content is laid
  /// out (so it can be measured) but invisible, so the user never sees
  /// the sheet at a measuring size.
  late bool _ready = !widget.fitContent;

  /// Size the sheet was last fitted to and the portrait upper limit that
  /// went with it. Null until the first measurement.
  double? _auto;
  late double _portraitMax = math.max(widget.maxChildSize, _kPortraitAutoCap);

  /// Once the user touches the sheet it is theirs: no more auto-fitting.
  bool _userControlled = false;

  /// True while this class itself is resizing the sheet, so its own
  /// size notifications are not mistaken for the user dragging.
  bool _internal = false;
  Timer? _animGuard;

  bool _checkScheduled = false;
  int _attempts = 0;

  @override
  void initState() {
    super.initState();
    if (widget.fitContent) _scheduleCheck();
  }

  @override
  void dispose() {
    _animGuard?.cancel();
    _sheet.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------
  // Sizing
  // ---------------------------------------------------------------

  double get _landscapeMax {
    final top = _height <= 0 ? 0.0 : _topInset / _height;
    return (1.0 - top).clamp(kNemesisSheetLandscapeAutoFraction + 0.05, 1.0)
        .toDouble();
  }

  double get _minSize => math.min(widget.minChildSize, _kFitMinCap);

  ({double initial, double min, double max}) _sizing() {
    final cInit = widget.initialChildSize;
    final cMin = widget.minChildSize;
    final cMax = widget.maxChildSize;

    if (!widget.fitContent) {
      if (_landscape) {
        final init = math.min(cInit, kNemesisSheetLandscapeAutoFraction);
        return (
          initial: init,
          min: math.min(cMin, init - 0.02),
          max: _landscapeMax,
        );
      }
      final init = math.min(cInit, cMax);
      return (initial: init, min: math.min(cMin, init - 0.02), max: cMax);
    }

    final max = _landscape ? _landscapeMax : _portraitMax;
    final auto = _auto;
    if (auto == null) {
      // Measuring size (hidden): big enough for the content to lay out
      // in full when it can fit at all.
      final measure =
          _landscape ? kNemesisSheetLandscapeAutoFraction : _kPortraitAutoCap;
      return (initial: measure, min: _minSize, max: max);
    }
    return (initial: math.min(auto, max), min: _minSize, max: max);
  }

  // ---------------------------------------------------------------
  // Measuring
  // ---------------------------------------------------------------

  void _scheduleCheck() {
    if (_checkScheduled) return;
    _checkScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkScheduled = false;
      if (!mounted || !widget.fitContent) return;
      if (!_userControlled) {
        _refit();
        // Keep following the content (async loads, rows added/removed)
        // until the user takes over. A post-frame callback does not
        // schedule a frame by itself, so this costs nothing while idle.
        if (!_userControlled) _scheduleCheck();
      }
    });
  }

  RenderObject? _findViewport(RenderObject? root) {
    if (root == null) return null;
    RenderObject? found;
    void visit(RenderObject node) {
      if (found != null) return;
      if (node is RenderAbstractViewport) {
        found = node;
        return;
      }
      node.visitChildren(visit);
    }

    visit(root);
    return found;
  }

  /// Full height of the scrollable's content, in pixels, or null when it
  /// can't be read. Only meaningful when the content is NOT longer than
  /// its viewport (then every child is built and laid out, so the
  /// slivers' own extents are exact).
  double? _contentExtent(ScrollPosition position) {
    final root = position.context.storageContext.findRenderObject();
    final viewport = _findViewport(root);
    if (viewport == null) return null;

    if (viewport is RenderViewportBase) {
      if (viewport.axis != Axis.vertical) return null;
      var total = 0.0;
      viewport.visitChildren((child) {
        if (child is RenderSliver) {
          total += child.geometry?.scrollExtent ?? 0.0;
        }
      });
      return total;
    }

    // SingleChildScrollView's viewport: its one child is the content.
    if (viewport is RenderBox) {
      double? height;
      viewport.visitChildren((child) {
        if (height == null && child is RenderBox && child.hasSize) {
          height = child.size.height;
        }
      });
      return height;
    }
    return null;
  }

  void _refit() {
    if (!_hasLayout || _height <= 0 || !_sheet.isAttached) return;

    final scroll = _scroll;
    final position = (scroll != null && scroll.hasClients)
        ? scroll.positions.first
        : null;

    double auto;
    double portraitMax = _portraitMax;
    final min = _minSize;

    if (position == null ||
        !position.hasContentDimensions ||
        !position.hasViewportDimension) {
      // The scrollable has not attached yet — give it a few frames, then
      // fall back to the caller's own sizes.
      if (++_attempts < 5) {
        // Nothing may be repainting (the route's slide-in is over), and a
        // post-frame callback alone never asks for a frame — without
        // this the sheet could stay invisible, waiting.
        WidgetsBinding.instance.scheduleFrame();
        return;
      }
      auto = _fallbackAuto();
      portraitMax = math.max(widget.maxChildSize, auto);
    } else {
      final overflow = position.maxScrollExtent > 0.5;
      final extent = overflow ? null : _contentExtent(position);

      if (!overflow && extent == null) {
        // Nothing measurable (no viewport found): fallback sizes.
        auto = _fallbackAuto();
        portraitMax = math.max(widget.maxChildSize, auto);
      } else {
        // +1px so float noise can never leave the content a hair taller
        // than the viewport (which would flip it to "overflowing").
        final fit = overflow ? 1.0 : (extent! + _bottomInset + 1) / _height;
        if (_landscape) {
          auto = overflow
              ? kNemesisSheetLandscapeAutoFraction
              : fit.clamp(min + 0.01, kNemesisSheetLandscapeAutoFraction)
                  .toDouble();
        } else {
          auto = overflow
              ? _kPortraitAutoCap
              : fit.clamp(min + 0.01, _kPortraitAutoCap).toDouble();
          portraitMax = math.max(widget.maxChildSize, auto);
        }
      }
    }

    final unchanged = _auto != null &&
        (auto - _auto!).abs() < _kSizeEpsilon &&
        (portraitMax - _portraitMax).abs() < _kSizeEpsilon;
    if (unchanged) {
      if (!_ready) setState(() => _ready = true);
      return;
    }

    final first = !_ready;
    // Limits first, size second: jumping/animating clamps to the limits
    // in force at that moment, so a taller limit has to be in place
    // before the sheet is sent up to it.
    setState(() {
      _auto = auto;
      _portraitMax = portraitMax;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _applySize(auto, animate: !first);
      if (first && !_ready) setState(() => _ready = true);
    });
  }

  double _fallbackAuto() {
    final init = widget.initialChildSize;
    return _landscape
        ? math.min(init, kNemesisSheetLandscapeAutoFraction)
        : math.min(init, math.max(widget.maxChildSize, init));
  }

  void _applySize(double target, {required bool animate}) {
    if (!_sheet.isAttached || _userControlled) return;
    final clamped = target.clamp(_minSize + 0.01, 1.0).toDouble();
    if (animate && (_sheet.size - clamped).abs() > 0.01) {
      // Content changed under an open sheet (async load): glide there.
      _animGuard?.cancel();
      _animGuard = Timer(const Duration(milliseconds: 280), () {
        _animGuard = null;
      });
      _sheet.animateTo(
        clamped,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    } else {
      _internal = true;
      try {
        _sheet.jumpTo(clamped);
      } finally {
        _internal = false;
      }
    }
  }

  // ---------------------------------------------------------------
  // User detection
  // ---------------------------------------------------------------

  bool _onSizeNotification(DraggableScrollableNotification n) {
    if (!_internal && _animGuard == null) _userControlled = true;
    // Not consumed: the modal route's own listener closes the sheet when
    // it reaches its minimum extent.
    return false;
  }

  bool _onScrollStart(ScrollStartNotification n) {
    if (n.dragDetails != null) _userControlled = true;
    return false;
  }

  // ---------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final landscape = constraints.maxWidth > constraints.maxHeight;
        final changedLayout = _hasLayout &&
            (landscape != _landscape ||
                (constraints.maxHeight - _height).abs() > 1);

        _height = constraints.maxHeight;
        _landscape = landscape;
        _bottomInset = MediaQuery.paddingOf(context).bottom;
        _topInset = _systemTopInset(context);
        _hasLayout = true;

        if (changedLayout && widget.fitContent) {
          // Rotated (or resized) while open: fit again for the new shape.
          _userControlled = false;
          _attempts = 0;
          _scheduleCheck();
        }

        final sizing = _sizing();

        return NotificationListener<DraggableScrollableNotification>(
          onNotification: _onSizeNotification,
          child: NotificationListener<ScrollStartNotification>(
            onNotification: _onScrollStart,
            child: IgnorePointer(
              ignoring: !_ready,
              child: Opacity(
                opacity: _ready ? 1 : 0,
                child: DraggableScrollableSheet(
                  controller: _sheet,
                  initialChildSize: sizing.initial,
                  minChildSize: sizing.min,
                  maxChildSize: sizing.max,
                  expand: false,
                  builder: (context, scrollController) {
                    _scroll = scrollController;
                    return Container(
                      decoration: const BoxDecoration(
                        color: kNemesisSheetBg,
                        borderRadius: BorderRadius.vertical(
                          top: Radius.circular(kNemesisSheetRadius),
                        ),
                      ),
                      child: SafeArea(
                        top: false,
                        child: widget.builder(context, scrollController),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Same 40x4 white24 pill drawn at the top of every Nemesis bottom
/// sheet (see info_sheet.dart) — drop this in as the first child of
/// whatever scrollable [showNemesisBottomSheet] wraps.
class NemesisSheetDragHandle extends StatelessWidget {
  const NemesisSheetDragHandle({
    super.key,
    this.topMargin = 0,
    this.bottomMargin = 18,
  });

  final double topMargin;
  final double bottomMargin;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 40,
        height: 4,
        margin: EdgeInsets.only(top: topMargin, bottom: bottomMargin),
        decoration: BoxDecoration(
          color: Colors.white24,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }
}
