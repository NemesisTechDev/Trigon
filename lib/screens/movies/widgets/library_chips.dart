import 'package:flutter/material.dart';
import '../../../virtual/virtual_catalog.dart';
import '../../../widgets/common/pressable.dart';

class LibraryChips extends StatefulWidget {
  final List<dynamic> libraries;
  final dynamic selected;
  final ValueChanged<dynamic> onSelected;

  /// Horizontal padding carried by the ListView itself (rather than by
  /// an outer padded container around this widget) — that's what lets
  /// the row scroll all the way to the true screen edge instead of
  /// stopping wherever an outer padding would otherwise sit. Matches
  /// the Music screen's tab row, and defaults to that screen's usual
  /// 20px page margin.
  final EdgeInsets padding;

  const LibraryChips({
    super.key,
    required this.libraries,
    required this.selected,
    required this.onSelected,
    this.padding = const EdgeInsets.symmetric(horizontal: 20),
  });

  @override
  State<LibraryChips> createState() => _LibraryChipsState();
}

class _LibraryChipsState extends State<LibraryChips> {
  // One GlobalKey per library, keyed by library id so a chip's own
  // render box can be found and scrolled into view — used to bring the
  // selected chip on screen whenever the selection changes, not just
  // when the user manually scrolls this row. That covers both tapping
  // a chip directly and landing on a library from somewhere that sets
  // the selection programmatically, e.g. tapping a library icon on the
  // Home screen, which jumps straight to that library's grid here
  // without the chip row having been scrolled to match.
  final Map<String, GlobalKey> _chipKeys = {};
  final ScrollController _scrollController = ScrollController();

  GlobalKey _keyFor(String id) =>
      _chipKeys.putIfAbsent(id, () => GlobalKey());

  @override
  void initState() {
    super.initState();
    // First build: the selected chip is brought into view without the
    // slide animation, so opening the screen shows it already in place.
    _scrollToSelectedAfterFrame(animate: false);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant LibraryChips oldWidget) {
    super.didUpdateWidget(oldWidget);

    final oldId = oldWidget.selected?["Id"];
    final newId = widget.selected?["Id"];

    if (newId != null && newId != oldId) {
      _scrollToSelectedAfterFrame();
    }
  }

  void _scrollToSelectedAfterFrame({bool animate = true}) {
    final id = widget.selected?["Id"];
    if (id == null) return;

    // The chip for `id` may not exist yet on this first frame (e.g. the
    // libraries list itself is still loading in), so this just quietly
    // no-ops via the key lookup below rather than needing to know that
    // up front.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;

      final key = _chipKeys[id];
      final targetContext = key?.currentContext;
      if (targetContext == null) return;

      Scrollable.ensureVisible(
        targetContext,
        // Centers the chip in the row rather than just nudging it to
        // the nearest edge, so it reads as a deliberate "slide to the
        // selected library" instead of a minimal scroll correction.
        alignment: 0.5,
        duration: animate ? const Duration(milliseconds: 350) : Duration.zero,
        curve: Curves.easeOutCubic,
      );
    });
  }

  IconData _getIcon(String? type) {
    switch ((type ?? "").toLowerCase()) {
      case "movies":
        return Icons.movie;

      case "tvshows":
        return Icons.tv;

      case "boxsets":
        return Icons.collections_bookmark;

      case "playlists":
        return Icons.favorite;

      case "homevideos":
        return Icons.video_library;

      case "music":
        return Icons.music_note;

      default:
        return Icons.folder;
    }
  }

  @override
  Widget build(BuildContext context) {
    final libraries = widget.libraries;
    final selected = widget.selected;

    if (libraries.isEmpty) {
      return const SizedBox.shrink();
    }

    // A plain Row inside a SingleChildScrollView, not a lazy
    // ListView.separated — library counts are always small (a handful
    // of tiles at most), and building them all up front means every
    // chip's GlobalKey has a live context from the first frame. That's
    // what [_scrollToSelectedAfterFrame] needs to reliably scroll to a
    // chip that starts out off-screen; a lazy list would only build
    // (and give a findable context to) whichever chips already happen
    // to be within the viewport/cache extent, silently no-oping the
    // auto-scroll for anything further along the row.
    // IntrinsicHeight (was `SizedBox(height: 42)`): a fixed pixel height
    // here assumed a fixed text scale. Once a device's font/display-size
    // setting is larger, the chip's actual content (icon + text row,
    // 10px vertical padding above and below) grows taller than 42px and
    // gets clipped top/bottom instead of the row simply being taller.
    // IntrinsicHeight sizes this to whatever the content actually
    // measures at, so it can't drift out of sync with the real text
    // scale again. Safe specifically because this wraps a
    // SingleChildScrollView (not a sliver-backed ListView) — SingleChild-
    // ScrollView answers intrinsic-height queries by forwarding to its
    // child; a real ListView/CustomScrollView would assert instead (see
    // sort_chips.dart, which used a ListView and needed a different fix).
    return IntrinsicHeight(
      child: SingleChildScrollView(
        controller: _scrollController,
        padding: widget.padding,
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (var index = 0; index < libraries.length; index++) ...[
              if (index > 0) const SizedBox(width: 8),
              Builder(
                builder: (context) {
                  final lib = libraries[index];

                  final active =
                      selected != null &&
                          selected["Id"] == lib["Id"];

                  // A library Parental Controls block shows a blocked
                  // icon in place of its usual one.
                  final blocked = VirtualCatalog.isLibraryBlocked(
                      lib["Id"]?.toString());
                  final icon = blocked
                      ? Icons.block
                      : _getIcon(lib["CollectionType"]);

                  return Pressable(
                    key: _keyFor(lib["Id"]),
                    borderRadius: BorderRadius.circular(30),
                    onTap: () => widget.onSelected(lib),
                    child: AnimatedContainer(
                      duration:
                      const Duration(milliseconds: 250),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: active
                            ? const Color(0xFFFFC107)
                            : const Color(0xff2A2A2A),
                        borderRadius:
                        BorderRadius.circular(30),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            icon,
                            size: 16,
                            color: active
                                ? Colors.black
                                : Colors.white70,
                          ),

                          const SizedBox(width: 6),

                          Text(
                            lib["Name"],
                            style: TextStyle(
                              color: active
                                  ? Colors.black
                                  : Colors.white70,
                              fontWeight: FontWeight.w600,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ],
          ],
        ),
      ),
    );
  }
}