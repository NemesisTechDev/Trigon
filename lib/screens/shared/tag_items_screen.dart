import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/jellyfin_services/media_service.dart';
import '../../utils/responsive.dart';
import '../../utils/bottom_clearance.dart';
import '../../widgets/common/collapsing_screen_label.dart';
import '../../widgets/common/fade_scrollbar.dart';
import '../../widgets/common/resistive_refresh.dart';
import '../../widgets/music/song_multi_select.dart';
import '../../widgets/music/song_selection_bar.dart';
import '../../widgets/shared/selector_dropdown.dart';
import '../movies/widgets/title_selection_actions.dart';
import '../movies/widgets/movie_grid.dart';
import '../movies/widgets/sort_chips.dart';
import '../music/widgets/album_grid.dart';

const _gold = Color(0xffD4AF37);
const _bg = Color(0xff161616);

/// Reusable "titles that share this facet" grid screen. Opened from
/// the gold tag chips on the movie/show detail screen (TagsRow), from
/// the Studio row (StudioRow), and from the genre chips on both the
/// movie/show and music (album/artist/playlist) detail screens — kept
/// generic — a Jellyfin `Tags`, `StudioIds`, or `Genres` filter value,
/// plus a label — so any other clickable facet added later can reuse
/// it as-is by just passing a different [tag]/[studioId]/[genre]/
/// [title].
///
/// Deliberately mirrors the Movies tab's own screen almost exactly: a
/// fixed, non-scrolling header (top-left title, then sort chips + a
/// search field in portrait, or a single sort dropdown + search field
/// in landscape — same SelectorDropdown the Movies tab's landscape
/// header uses) sitting above a scrollable, pull-to-refresh grid. Only
/// the mode/library selectors are dropped, since a facet like this has
/// nothing else to switch between.
class TagItemsScreen extends StatefulWidget {
  /// Jellyfin `Tags` filter value. Exactly one of [tag]/[studioId]/
  /// [genre] must be provided.
  final String? tag;

  /// Jellyfin studio item id (`StudioIds` filter value). Exactly one
  /// of [tag]/[studioId]/[genre] must be provided.
  final String? studioId;

  /// Jellyfin `Genres` filter value. Exactly one of [tag]/[studioId]/
  /// [genre] must be provided. Paired with [includeItemTypes] to
  /// decide what it's a genre *of* — "Movie,Series" from the
  /// movie/show detail screen, "MusicAlbum" from the album/artist/
  /// playlist detail screens.
  final String? genre;

  /// Header label — defaults to [tag]/[genre] itself (e.g. "Heist" or
  /// "Jazz") when either is used, but is required (there's no
  /// sensible default) when filtering by [studioId], since the id
  /// itself isn't presentable.
  final String? title;

  /// Jellyfin `IncludeItemTypes` filter value. Only meaningful
  /// alongside [genre] — [tag]/[studioId] are only ever used from the
  /// movie/show detail screen and hardcode "Movie,Series" themselves.
  final String includeItemTypes;

  const TagItemsScreen({
    super.key,
    this.tag,
    this.studioId,
    this.genre,
    this.title,
    this.includeItemTypes = "Movie,Series",
  }) : assert(
          (tag != null ? 1 : 0) +
                  (studioId != null ? 1 : 0) +
                  (genre != null ? 1 : 0) ==
              1,
          "Provide exactly one of tag/studioId/genre",
        );

  @override
  State<TagItemsScreen> createState() => _TagItemsScreenState();
}

class _TagItemsScreenState extends State<TagItemsScreen> {
  bool loading = true;
  List<dynamic> items = [];
  String selectedSort = "DateCreated";

  // Hold-to-multi-select for title posters — same SongMultiSelect +
  // SongSelectionBar as the Music tab and the Movies / TV Shows tabs,
  // with Favorite as the only action.
  final SongMultiSelect _titleSelect = SongMultiSelect();

  void _exitTitleSelection() {
    setState(() => _titleSelect.clear());
  }

  Future<void> _favoriteSelectedTitles() => toggleFavoriteForSelection(
        context: context,
        selection: _titleSelect,
        setState: setState,
      );

  // Same "filter the already-loaded list as you type", 300ms-debounced
  // approach the Movies/Music screens use — there's no server round
  // trip for search here, so this stays instant either way.
  String search = "";
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  final ScrollController _scrollController = ScrollController();
  Timer? _searchDebounce;

  List<dynamic> get _filteredItems {
    if (search.isEmpty) return items;

    final query = search.toLowerCase();
    return items.where((item) {
      final name = (item["Name"] ?? "").toString().toLowerCase();
      return name.contains(query);
    }).toList();
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    _searchFocusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) {
      setState(() => loading = true);
    }

    try {
      final data = await MediaService.getItems(
        tags: widget.tag,
        studioIds: widget.studioId,
        genres: widget.genre,
        includeItemTypes: widget.includeItemTypes,
        sortBy: selectedSort,
        sortOrder: selectedSort == "SortName" ? "Ascending" : "Descending",
      );

      if (!mounted) return;
      setState(() {
        items = data;
        loading = false;
      });
    } catch (e) {
      debugPrint(e.toString());
      if (!mounted) return;
      setState(() => loading = false);
    }
  }

  Future<void> _changeSort(String sort) async {
    if (sort == selectedSort) return;
    setState(() {
      _titleSelect.clear();
      selectedSort = sort;
    });
    await _load();
  }

  void _onSearchChanged(String value) {
    search = value;

    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      setState(() {});
    });
  }

  Widget _buildSearchField() {
    return TextField(
      controller: _searchController,
      focusNode: _searchFocusNode,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 13,
      ),
      decoration: InputDecoration(
        isDense: true,
        hintText: "Search...",
        hintStyle: const TextStyle(
          color: Colors.white54,
          fontSize: 13,
        ),
        prefixIcon: const Icon(
          Icons.search,
          color: Colors.white70,
          size: 18,
        ),
        prefixIconConstraints: const BoxConstraints(
          minWidth: 32,
          minHeight: 32,
        ),
        filled: true,
        fillColor: const Color(0xff252525),
        contentPadding: const EdgeInsets.symmetric(vertical: 8),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(30),
          borderSide: BorderSide.none,
        ),
      ),
      onChanged: _onSearchChanged,
    );
  }

  /// Portrait header row: SortChips (scrollable pill row) + a compact
  /// search field — identical layout to the Movies tab's own portrait
  /// sort row.
  Widget _buildPortraitHeader() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      // The search field's width follows the row (same clamp as the Movies
      // tab) so the four sort chips keep enough room on narrow screens.
      child: LayoutBuilder(
        builder: (context, constraints) {
          final searchWidth =
              (constraints.maxWidth * 0.28).clamp(96.0, 150.0).toDouble();
          return Row(
            children: [
              Expanded(
                child: SortChips(
                  selected: selectedSort,
                  onSelected: _changeSort,
                ),
              ),

              const SizedBox(width: 8),

              SizedBox(
                width: searchWidth,
                height: 36,
                child: _buildSearchField(),
              ),
            ],
          );
        },
      ),
    );
  }

  /// Landscape header row: SortChips collapses into a single
  /// SelectorDropdown pill sharing the row with the search field —
  /// same widget and animation the Movies tab's landscape header uses
  /// for its own mode/library/sort dropdowns.
  Widget _buildLandscapeHeader() {
    final sortLabel = SortChips.sorts.firstWhere(
      (s) => s["value"] == selectedSort,
      orElse: () => SortChips.sorts.first,
    )["label"]!;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        children: [
          SelectorDropdown<String>(
            label: sortLabel,
            leadingIcon: Icons.sort_rounded,
            selectedValue: selectedSort,
            options: SortChips.sorts
                .map(
                  (s) => DropdownOption(
                    value: s["value"]!,
                    label: s["label"]!,
                  ),
                )
                .toList(),
            onSelected: _changeSort,
          ),

          const Spacer(),

          SizedBox(
            width: 180,
            height: 34,
            child: _buildSearchField(),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final label = widget.title ?? widget.tag ?? widget.genre ?? "";
    final isMusic = widget.includeItemTypes == "MusicAlbum";
    final landscape = Responsive.isLandscape(context);

    return Scaffold(
      backgroundColor: _bg,
      // Tapping anywhere outside the search field dismisses its focus —
      // same treatment as the Movies tab.
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => FocusScope.of(context).unfocus(),
        child: SafeArea(
          bottom: false,
          // Back button + top-left tag label, then the sort/search row,
          // both fixed in place — only the grid below scrolls, matching
          // the Movies tab's fixed-header/scrolling-grid split.
          // LabelCollapseScope: the back button + label row slides away on
          // scroll down and returns on scroll up (see
          // collapsing_screen_label.dart); the sort/search row stays pinned.
          child: LabelCollapseScope(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Stays above the pinned sort/search row even while the
              // label is collapsed.
              const SizedBox(height: kCollapsedLabelTopGap),

              // Label-to-first-row gap is 10 everywhere (portrait and
              // landscape alike), matching Movies/Music — part of the
              // collapsing block.
              if (!isMusic && _titleSelect.active) ...[
                SongSelectionBar(
                  count: _titleSelect.count,
                  busy: _titleSelect.busy,
                  onClose: _exitTitleSelection,
                  onFavorite: _favoriteSelectedTitles,
                  favoriteActive: selectionAllFavorited(_titleSelect),
                ),
                const SizedBox(height: 10),
              ] else
              CollapsibleLabel(
                bottomPadding: 10,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Row(
                    children: [
                      IconButton(
                        onPressed: () => Navigator.of(context).maybePop(),
                        icon: const Icon(
                          Icons.arrow_back,
                          color: Colors.white,
                        ),
                      ),

                      const SizedBox(width: 4),

                      Expanded(
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 26,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              if (landscape) _buildLandscapeHeader() else _buildPortraitHeader(),

              // Sort/search row to grid: 5 portrait, 8 landscape —
              // matching Movies/Music.
              SizedBox(height: landscape ? 8 : 5),

              Expanded(
                child: ResistiveRefresh(
                  onRefresh: () => _load(silent: true),
                  color: _gold,
                  backgroundColor: const Color(0xff232323),
                  child: FadeScrollbar(
                    controller: _scrollController,
                    child: CustomScrollView(
                    controller: _scrollController,
                    // Keeps pull-to-refresh live even when a tag only
                    // matches a handful of titles and doesn't fill the
                    // viewport.
                    physics: const AlwaysScrollableScrollPhysics(),
                    slivers: [
                      if (isMusic)
                        AlbumGrid(
                          loading: loading,
                          items: _filteredItems,
                          emptyTitle: search.isNotEmpty
                              ? "No results found"
                              : "No albums found",
                          emptySubtitle: search.isNotEmpty
                              ? "Try a different title or check your spelling."
                              : "Nothing else on the server is in this genre yet.",
                        )
                      else
                        MovieGrid(
                          loading: loading,
                          selection: _titleSelect,
                          onSelectionChanged: () => setState(() {}),
                          items: _filteredItems,
                          emptyIcon: Icons.sell_outlined,
                          emptyTitle: search.isNotEmpty
                              ? "No results found"
                              : "No titles found",
                          emptySubtitle: search.isNotEmpty
                              ? "Try a different title or check your spelling."
                              : widget.studioId != null
                                  ? "Nothing else on the server is from this studio yet."
                                  : widget.genre != null
                                      ? "Nothing else on the server is in this genre yet."
                                      : "Nothing else on the server shares this tag yet.",
                        ),

                      SliverToBoxAdapter(
                        child: BottomClearanceBuilder(
                          builder: (context, bottomClearance) => SizedBox(
                            height: 20 +
                                MediaQuery.paddingOf(context).bottom +
                                bottomClearance,
                          ),
                        ),
                      ),
                    ],
                    ),
                  ),
                ),
              ),
            ],
          ),
          ),
        ),
      ),
    );
  }
}
