import 'package:flutter/material.dart';

import '../../screens/main_nav/navigation_controller.dart';

const _gold = Color(0xFFFFC107);
const _pillBg = Color(0xff2A2A2A);
const _menuBg = Color(0xff232323);

/// Registered as a `navigatorObservers` entry on the root `MaterialApp`
/// (see `main.dart`). `SelectorDropdown`'s menu is an `OverlayEntry`
/// inserted into the nearest `Overlay` — which, for every screen that
/// uses this widget, is the app-root `Overlay` the `Navigator` itself
/// paints into. That overlay sits *above* the Navigator's own routes,
/// so an entry left open there stays visible on top of whatever gets
/// pushed next, and pushing/popping doesn't dispose the `State` that
/// owns it (only removing it from an `IndexedStack`-style tab switch
/// would, and that doesn't happen either — see the `NavigationController`
/// listener below). `RouteAware.didPushNext` is the hook for "a new
/// route now covers mine" and is used to force the menu closed then.
final RouteObserver<ModalRoute<void>> selectorDropdownRouteObserver =
    RouteObserver<ModalRoute<void>>();

class DropdownOption<T> {
  final T value;
  final String label;
  final IconData? icon;

  const DropdownOption({
    required this.value,
    required this.label,
    this.icon,
  });
}

/// Landscape-only replacement for horizontal chip rows (mode/tab,
/// library/category, and sort chips): a single compact pill that opens
/// a premium animated dropdown menu, so several filters can share one
/// row alongside the search field instead of stacking multiple
/// scrollable chip rows. Selection behavior mirrors the chips it
/// replaces exactly — same values, same callbacks — this only changes
/// how the option is presented and how the menu animates in.
///
/// Used by the Movies, Music, and Live TV (All Channels / Favorites)
/// landscape headers so every dropdown in the app looks and animates
/// identically.
class SelectorDropdown<T> extends StatefulWidget {
  final String label;
  final IconData? leadingIcon;
  final List<DropdownOption<T>> options;
  final T? selectedValue;
  final ValueChanged<T> onSelected;

  /// Caps how wide the pill (and its text) is allowed to grow — set by
  /// callers that sit inside a Flexible so long names ellipsize instead
  /// of pushing the search field off screen.
  final double? maxWidth;

  const SelectorDropdown({
    super.key,
    required this.label,
    required this.options,
    required this.selectedValue,
    required this.onSelected,
    this.leadingIcon,
    this.maxWidth,
  });

  @override
  State<SelectorDropdown<T>> createState() => _SelectorDropdownState<T>();
}

class _SelectorDropdownState<T> extends State<SelectorDropdown<T>>
    with SingleTickerProviderStateMixin, RouteAware {
  final LayerLink _link = LayerLink();
  final GlobalKey _pillKey = GlobalKey();

  OverlayEntry? _entry;
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
    reverseDuration: const Duration(milliseconds: 140),
  );

  bool _open = false;
  ModalRoute<void>? _subscribedRoute;

  @override
  void initState() {
    super.initState();
    // Movies/Music live inside the bottom-nav's IndexedStack, so
    // switching tabs never disposes this State (IndexedStack keeps
    // every tab's widget tree alive) — without this, a dropdown left
    // open on one tab would keep floating above whichever tab you
    // switch to next, since its OverlayEntry sits in the app-root
    // Overlay above the whole tab stack.
    NavigationController.instance.addListener(_closeMenuImmediately);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Covers the other case: TV Guide / All Channels / a detail
    // screen gets pushed *on top* of this screen. That doesn't
    // dispose this State either (it's just no longer the top route),
    // so RouteAware.didPushNext is what tells us to close.
    final route = ModalRoute.of(context);
    if (route != _subscribedRoute) {
      if (_subscribedRoute != null) {
        selectorDropdownRouteObserver.unsubscribe(this);
      }
      if (route != null) {
        selectorDropdownRouteObserver.subscribe(this, route);
      }
      _subscribedRoute = route;
    }
  }

  @override
  void didPushNext() {
    // A new screen now covers this one — close instantly rather than
    // in the normal reverse-animated way; nobody can see this screen's
    // pill to watch it animate closed anyway, and animating it while
    // hidden just leaves the entry lingering a little longer.
    _closeMenuImmediately();
  }

  void _closeMenuImmediately() {
    if (!_open && _entry == null) return;
    _controller.stop();
    _entry?.remove();
    _entry = null;
    if (mounted) {
      setState(() => _open = false);
    } else {
      _open = false;
    }
  }

  @override
  void dispose() {
    NavigationController.instance.removeListener(_closeMenuImmediately);
    selectorDropdownRouteObserver.unsubscribe(this);
    _entry?.remove();
    _controller.dispose();
    super.dispose();
  }

  void _toggle() {
    if (_open) {
      _closeMenu();
    } else {
      _openMenu();
    }
  }

  void _openMenu() {
    final box = _pillKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;

    final screenSize = MediaQuery.sizeOf(context);
    final pillSize = box.size;
    final pillTopLeft = box.localToGlobal(Offset.zero);

    // Menu width matches the pill's natural width but never shrinks
    // below a comfortable minimum, and is capped so long option lists
    // (e.g. many libraries) don't stretch edge to edge.
    final menuWidth = pillSize.width.clamp(180.0, 280.0);

    // If the pill sits close enough to the right edge that a
    // left-anchored menu would overflow, grow the menu leftward from
    // the pill's right edge instead — keeps every dropdown fully on
    // screen regardless of where it sits in the filter row.
    final wouldOverflowRight =
        pillTopLeft.dx + menuWidth > screenSize.width - 12;

    final targetAnchor =
        wouldOverflowRight ? Alignment.bottomRight : Alignment.bottomLeft;
    final followerAnchor =
        wouldOverflowRight ? Alignment.topRight : Alignment.topLeft;

    // The menu hangs 8px below the pill with a fixed 340px max height.
    // In landscape the screen is short, so pill-bottom + 8 + 340 ran
    // past the bottom edge: the menu's own scroll view was fine, but its
    // lower part sat off-screen, so the last options could never be
    // reached. Cap the height to the room actually left below the pill
    // (minus the bottom inset and a small margin) so the menu ends on
    // screen and its scroll view reveals every option.
    final mq = MediaQuery.of(context);
    final spaceBelow = screenSize.height -
        (pillTopLeft.dy + pillSize.height) -
        8 -
        mq.viewPadding.bottom -
        12;
    final menuMaxHeight = spaceBelow.clamp(120.0, 340.0);

    _entry = OverlayEntry(
      builder: (overlayContext) {
        return _DropdownOverlay<T>(
          maxHeight: menuMaxHeight,
          link: _link,
          controller: _controller,
          targetAnchor: targetAnchor,
          followerAnchor: followerAnchor,
          menuWidth: menuWidth,
          options: widget.options,
          selectedValue: widget.selectedValue,
          onDismiss: _closeMenu,
          onSelected: (value) {
            widget.onSelected(value);
            _closeMenu();
          },
        );
      },
    );

    Overlay.of(context).insert(_entry!);
    setState(() => _open = true);
    _controller.forward(from: 0);
  }

  Future<void> _closeMenu() async {
    if (!_open) return;
    setState(() => _open = false);
    await _controller.reverse();
    _entry?.remove();
    _entry = null;
  }

  @override
  Widget build(BuildContext context) {
    return CompositedTransformTarget(
      link: _link,
      child: GestureDetector(
        key: _pillKey,
        behavior: HitTestBehavior.opaque,
        onTap: _toggle,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          height: 36,
          constraints: widget.maxWidth != null
              ? BoxConstraints(maxWidth: widget.maxWidth!)
              : null,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: _pillBg,
            borderRadius: BorderRadius.circular(30),
            border: Border.all(
              color: _open ? _gold.withOpacity(.55) : Colors.transparent,
              width: 1.2,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.leadingIcon != null) ...[
                Icon(
                  widget.leadingIcon,
                  size: 15,
                  color: _open ? _gold : Colors.white70,
                ),
                const SizedBox(width: 6),
              ],
              Flexible(
                child: Text(
                  widget.label,
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                  style: TextStyle(
                    color: _open ? _gold : Colors.white,
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              AnimatedRotation(
                turns: _open ? 0.5 : 0,
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOut,
                child: Icon(
                  Icons.keyboard_arrow_down_rounded,
                  size: 18,
                  color: _open ? _gold : Colors.white70,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The actual overlay content: a full-screen transparent barrier (to
/// catch outside taps and dismiss) plus the animated menu itself,
/// composited to follow the pill via [LayerLink].
class _DropdownOverlay<T> extends StatelessWidget {
  final LayerLink link;
  final AnimationController controller;
  final Alignment targetAnchor;
  final Alignment followerAnchor;
  final double menuWidth;
  final double maxHeight;
  final List<DropdownOption<T>> options;
  final T? selectedValue;
  final VoidCallback onDismiss;
  final ValueChanged<T> onSelected;

  const _DropdownOverlay({
    required this.maxHeight,
    required this.link,
    required this.controller,
    required this.targetAnchor,
    required this.followerAnchor,
    required this.menuWidth,
    required this.options,
    required this.selectedValue,
    required this.onDismiss,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    // Scale grows from the anchor edge (top-left/top-right, matching
    // whichever corner the menu is hinging from) rather than the
    // center, so it reads as "unfolding from the pill" instead of
    // ballooning outward — the kind of directional detail premium
    // pickers (Spotify's filter sheets, Linear's dropdowns) get right.
    final scaleAlignment = followerAnchor == Alignment.topRight
        ? Alignment.topRight
        : Alignment.topLeft;

    final curved = CurvedAnimation(
      parent: controller,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeIn,
    );

    return Stack(
      children: [
        // Transparent full-screen barrier — dismisses the menu on any
        // tap outside it without visually dimming the screen, matching
        // how the rest of the app's pickers behave.
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onDismiss,
          ),
        ),
        CompositedTransformFollower(
          link: link,
          targetAnchor: targetAnchor,
          followerAnchor: followerAnchor,
          offset: const Offset(0, 8),
          child: AnimatedBuilder(
            animation: curved,
            builder: (context, child) {
              return Opacity(
                opacity: curved.value.clamp(0.0, 1.0),
                child: Transform.scale(
                  scale: 0.90 + (0.10 * curved.value),
                  alignment: scaleAlignment,
                  child: child,
                ),
              );
            },
            child: Material(
              type: MaterialType.transparency,
              child: Container(
                width: menuWidth,
                constraints: BoxConstraints(maxHeight: maxHeight),
                decoration: BoxDecoration(
                  color: _menuBg,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.white12),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(.45),
                      blurRadius: 24,
                      offset: const Offset(0, 12),
                    ),
                  ],
                ),
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (var i = 0; i < options.length; i++)
                          _DropdownMenuItem<T>(
                            option: options[i],
                            active: options[i].value == selectedValue,
                            index: i,
                            controller: controller,
                            onTap: () => onSelected(options[i].value),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// A single menu row with its own slight staggered fade/slide-in,
/// offset a few milliseconds later per index, so the list cascades
/// open rather than appearing all at once.
class _DropdownMenuItem<T> extends StatelessWidget {
  final DropdownOption<T> option;
  final bool active;
  final int index;
  final AnimationController controller;
  final VoidCallback onTap;

  const _DropdownMenuItem({
    required this.option,
    required this.active,
    required this.index,
    required this.controller,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    // Cap how many items get a staggered delay so a very long list
    // (e.g. many libraries) doesn't leave the last rows waiting on a
    // long, sluggish-feeling cascade.
    final delaySteps = index.clamp(0, 6);
    final start = (delaySteps * 0.05).clamp(0.0, 0.5);
    final end = (start + 0.5).clamp(0.0, 1.0);

    final itemAnim = CurvedAnimation(
      parent: controller,
      curve: Interval(start, end, curve: Curves.easeOut),
    );

    return AnimatedBuilder(
      animation: itemAnim,
      builder: (context, child) {
        return Opacity(
          opacity: itemAnim.value.clamp(0.0, 1.0),
          child: Transform.translate(
            offset: Offset(0, (1 - itemAnim.value) * 6),
            child: child,
          ),
        );
      },
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: Container(
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            color: active ? _gold.withOpacity(.08) : Colors.transparent,
            child: Row(
              children: [
                if (option.icon != null) ...[
                  Icon(
                    option.icon,
                    size: 16,
                    color: active ? _gold : Colors.white70,
                  ),
                  const SizedBox(width: 10),
                ],
                Expanded(
                  child: Text(
                    option.label,
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                    style: TextStyle(
                      color: active ? _gold : Colors.white,
                      fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                      fontSize: 13,
                    ),
                  ),
                ),
                if (active)
                  const Icon(Icons.check_rounded, size: 16, color: _gold),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
