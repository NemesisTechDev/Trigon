import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import '../../screens/live_tv/live_tv_detail_screen.dart';
import '../../services/favorite_service.dart';
import '../../services/jellyfin_services/media_service.dart';
import '../../utils/channel_categories.dart';
import '../../utils/responsive.dart';
import '../../widgets/common/pressable.dart';
import '../../widgets/shared/selector_dropdown.dart';
import '../../services/cache/nemesis_image_cache.dart';
import '../../utils/bottom_clearance.dart';
import '../../widgets/live_tv/category_chips_row.dart';
import '../../widgets/common/fade_scrollbar.dart';
import '../../widgets/common/category_swipe_switcher.dart';
import '../../widgets/common/collapsing_screen_label.dart';

class AllChannelsScreen extends StatefulWidget {
  final List channels;
  final Map<String, dynamic> programs;
  final String title;

  /// Category chip to have selected on open (one of the chip labels,
  /// e.g. "Sports"). Defaults to "All".
  final String initialCategory;

  const AllChannelsScreen({
    super.key,
    required this.channels,
    required this.programs,
    this.title = "All Channels",
    this.initialCategory = "All",
  });

  @override
  State<AllChannelsScreen> createState() =>
      _AllChannelsScreenState();
}

class _AllChannelsScreenState
    extends State<AllChannelsScreen> {

  // One ScrollController per category rather than a single shared one
  // — CategorySwipeSwitcher keeps the category animating out mounted
  // alongside the incoming one for the length of the swipe transition,
  // so two categories sharing one controller would mean two live
  // Scrollables attached to the same controller at once. Same fix
  // already applied to Music's tabs (_contentScrollControllers) for
  // the identical crash.
  final Map<String, ScrollController> _gridScrollControllers = {};

  ScrollController _scrollControllerFor(String key) =>
      _gridScrollControllers.putIfAbsent(key, () => ScrollController());

  List filteredChannels = [];

  String search = "";

  String selectedCategory = "All";

  // Landscape's category dropdown needs the same list (and a matching
  // icon per option) that the portrait chip row below builds one
  // ChoiceChip at a time via _buildChip.
  static const List<String> _categories = [
    "All",
    "Sports",
    "Movies",
    "News",
    "Kids",
    "Music",
    "Documentaries",
    "Entertainment",
  ];

  static const Map<String, IconData> _categoryIcons = {
    "All": Icons.apps_rounded,
    "Sports": Icons.sports_soccer,
    "Movies": Icons.movie,
    "News": Icons.newspaper,
    "Kids": Icons.child_care,
    "Music": Icons.music_note,
    "Documentaries": Icons.menu_book,
    "Entertainment": Icons.theaters,
  };

  /// Favorite channel IDs loaded once and kept in memory, instead of each
  /// grid card independently hitting SharedPreferences via a FutureBuilder
  /// every time it (re)builds.
  Set<String> favoriteIds = {};

  Timer? _searchDebounce;
  final FocusNode _searchFocusNode = FocusNode();

  @override
  void initState() {
    super.initState();

    filteredChannels = widget.channels;

    if (widget.initialCategory != "All" &&
        _categories.contains(widget.initialCategory)) {
      selectedCategory = widget.initialCategory;
      // Filter synchronously for the first frame so the grid never
      // flashes the unfiltered list; filterChannels() below then applies
      // the favorites-first ordering once favorites have loaded.
      filteredChannels = widget.channels.where((channel) {
        final name = (channel["Name"] ?? "").toString().toLowerCase();
        return ChannelCategories.classify(name) == selectedCategory;
      }).toList();
      filterChannels();
    }

    _loadFavoriteIds();
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchFocusNode.dispose();
    for (final controller in _gridScrollControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _loadFavoriteIds() async {
    final ids = await FavoriteService.getFavorites();
    if (!mounted) return;
    setState(() {
      favoriteIds = ids.toSet();
    });
  }

  // Delegates to the centralized, rail-aware Responsive breakpoints
  // (Phase 2) — this used to hand-roll the same 480/700/1000 ladder
  // duplicated in album_grid.dart and music_screen.dart, reading raw
  // MediaQuery width and never accounting for the landscape
  // NavigationRail. Kept as a thin wrapper (rather than replacing the
  // call site below) so this diff stays scoped to the calculation
  // itself.
  int _getGridColumns(BuildContext context) {
    return Responsive.gridColumnsForType(context, GridContentType.channel);
  }

  Future<void> filterChannels() async {

    final filtered =
        widget.channels.where((channel) {

          final name =
          (channel["Name"] ?? "")
              .toString()
              .toLowerCase();

          final List list =
              widget.programs[channel["Id"]] ?? [];

          final program =
          list.isNotEmpty ? list.first : null;

          final programName =
          (program?["Name"] ?? "")
              .toString()
              .toLowerCase();

          if (search.isNotEmpty) {

            final query =
            search.toLowerCase();

            if (!name.contains(query) &&
                !programName.contains(query)) {

              return false;

            }

          }

          if (selectedCategory == "All") {
            return true;
          }

          return ChannelCategories.classify(name) == selectedCategory;

        }).toList();

    // Make sure we have the latest favorite state before sorting by it.
    final ids = await FavoriteService.getFavorites();
    final idSet = ids.toSet();

    filtered.sort((a, b) {

      final aFavorite =
      idSet.contains(a["Id"]);

      final bFavorite =
      idSet.contains(b["Id"]);

      if (aFavorite == bFavorite) {
        return 0;
      }

      return aFavorite ? -1 : 1;

    });

    if (!mounted) return;
    setState(() {
      filteredChannels = filtered;
      favoriteIds = idSet;
    });
  }

  /// Switches the active category — shared by the portrait chip row,
  /// the landscape category dropdown, and swipe-to-switch, so all
  /// three land on the identical setState+refilter sequence.
  void _selectCategory(String category) {
    setState(() => selectedCategory = category);
    filterChannels();
  }

  /// Swipe axis: the same left-to-right order _categories is already
  /// listed in (and that the chip row/dropdown render it in). Clamped
  /// at either end rather than wrapping around.
  void _swipeCategory(int delta) {
    final index = _categories.indexOf(selectedCategory);
    if (index == -1) return;

    final nextIndex = index + delta;
    if (nextIndex < 0 || nextIndex >= _categories.length) return;

    _selectCategory(_categories[nextIndex]);
  }

  void _onSearchChanged(String value) {
    search = value;

    // Debounce so we're not re-filtering + re-sorting the whole channel
    // list (plus a SharedPreferences read) on every single keystroke.
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 300), filterChannels);
  }

  Future<void> _openChannel(Map channel) async {
    // Closes the keyboard/cursor the moment another screen opens, rather
    // than leaving it focused underneath the pushed route — otherwise the
    // keyboard can stay up and interfere with the new screen's layout,
    // and (since nothing re-requests focus on pop) it stays deactivated
    // until the search field is tapped again.
    _searchFocusNode.unfocus();

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => LiveTvDetailScreen(
          channelId: channel["Id"],
          initialItem: Map<String, dynamic>.from(channel),
          allChannels: widget.channels,
          initialPrograms: widget.programs[channel["Id"]] as List?,
        ),
      ),
    );

    // The detail screen may have toggled favorite status — refresh once,
    // rather than every card checking for itself.
    await _loadFavoriteIds();
  }

  Widget _buildSearchField({String hintText = "Search channels..."}) {
    return TextField(
      focusNode: _searchFocusNode,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 13,
      ),
      decoration: InputDecoration(
        isDense: true,
        hintText: hintText,
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

  /// Landscape header: the category chip row collapses into a single
  /// dropdown pill sharing a row with a compact search field, freeing
  /// up the vertical space the two stacked portrait rows used to take
  /// — same state and handlers as the portrait search field/chips
  /// below. Matches the Movies/Music screens' landscape headers for
  /// consistency, and covers both this screen's "All Channels" and
  /// "Favorites" uses since they're the same widget.
  Widget _buildLandscapeFiltersRow() {
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: Responsive.contentPadding(context),
      ),
      child: Row(
        children: [
          SelectorDropdown<String>(
            label: selectedCategory,
            leadingIcon: _categoryIcons[selectedCategory] ?? Icons.apps_rounded,
            selectedValue: selectedCategory,
            options: _categories
                .map(
                  (c) => DropdownOption(
                    value: c,
                    label: c,
                    icon: _categoryIcons[c],
                  ),
                )
                .toList(),
            onSelected: _selectCategory,
          ),

          const Spacer(),

          SizedBox(
            width: 220,
            height: 34,
            child: _buildSearchField(),
          ),
        ],
      ),
    );
  }

  Widget _buildChip(String title) {

    return Padding(
      padding: const EdgeInsets.only(right: 10),

      child: ChoiceChip(
        showCheckmark: false,
        backgroundColor: const Color(0xff2A2A2A),
        selectedColor: const Color(0xffD4AF37),

        labelStyle: TextStyle(
          color: selectedCategory == title
              ? Colors.black
              : Colors.white,
          fontWeight: FontWeight.bold,
        ),

        label: Text(title),

        selected:
        selectedCategory == title,

        onSelected: (_) => _selectCategory(title),

      ),
    );
  }

  Widget _buildChannelCard(Map channel) {

    final List list =
        widget.programs[channel["Id"]] ?? [];

    final program =
    list.isNotEmpty ? list.first : null;

    final favorite = favoriteIds.contains(channel["Id"]);

    return Pressable(
      borderRadius: BorderRadius.circular(18),
      onTap: () => _openChannel(channel),
      child: Stack(
        children: [
          Container(
            decoration: BoxDecoration(
              color: const Color(0xff222222),
              borderRadius: BorderRadius.circular(18),
            ),
            child: Column(
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: CachedNetworkImage(
                      cacheManager: NemesisImageCache.instance,
                      imageUrl: MediaService.getPrimaryImage(
                        channel["Id"],
                      ),
                      fit: BoxFit.contain,
                      memCacheWidth: 300,
                      fadeInDuration: const Duration(milliseconds: 250),
                      placeholder: (_, __) => Container(
                        decoration: BoxDecoration(
                          color: const Color(0xff2a2a2a),
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      errorWidget: (_, __, ___) => const Icon(
                        Icons.live_tv,
                        color: Colors.white38,
                        size: 55,
                      ),
                    ),
                  ),
                ),

                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Text(
                    channel["Name"],
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),

                const SizedBox(height: 5),

                if (program != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: Text(
                      program["Name"] ?? "",
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 11,
                      ),
                    ),
                  ),

                const SizedBox(height: 10),
              ],
            ),
          ),

          if (favorite)
            const Positioned(
              right: 8,
              top: 8,
              child: Icon(
                Icons.favorite,
                color: Colors.red,
                size: 18,
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // LabelCollapseScope: the app bar (title + back button) slides away on
    // scroll down and returns on scroll up (see
    // collapsing_screen_label.dart); the search field / category chips
    // stay pinned. Covers both "All Channels" and "Favorites" since they
    // share this widget. resetKey brings the bar back on a category switch.
    return LabelCollapseScope(
      resetKey: selectedCategory,
      child: Scaffold(
      backgroundColor: const Color(0xff161616),

      // primary: false — CollapsibleAppBar supplies the status-bar inset
      // itself so the bar can collapse down to just that inset.
      appBar: CollapsibleAppBar(
        child: AppBar(
          primary: false,
          backgroundColor: const Color(0xff161616),
          title: Text(
            widget.title,
            style: const TextStyle(color: Colors.white),
          ),
        ),
      ),
      body: Column(
        children: [

          // App bar to first row: 10, matching Movies/Music.
          const SizedBox(height: 10),

          if (Responsive.isLandscape(context)) ...[
            // Landscape: the search field and category-chip rows
            // collapse into a single row — a category dropdown plus a
            // compact search field — instead of stacking two separate
            // rows, freeing up vertical space for the grid. Matches
            // the Movies/Music screens' landscape headers, and applies
            // to both "All Channels" and "Favorites" since they share
            // this widget.
            _buildLandscapeFiltersRow(),
            const SizedBox(height: 5),
          ] else ...[
            Padding(
              padding: EdgeInsets.symmetric(
                horizontal: Responsive.contentPadding(context),
              ),
              child: TextField(
                focusNode: _searchFocusNode,
                style: const TextStyle(
                  color: Colors.white,
                ),
                decoration: InputDecoration(
                  hintText: "Search channels...",
                  hintStyle: const TextStyle(
                    color: Colors.white54,
                  ),
                  prefixIcon: const Icon(
                    Icons.search,
                    color: Colors.white70,
                  ),
                  filled: true,
                  fillColor: const Color(0xff252525),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(30),
                    borderSide: BorderSide.none,
                  ),
                ),
                onChanged: _onSearchChanged,
              ),
            ),

            const SizedBox(height: 8),

            SizedBox(
              height: 45,
              // Auto-scrolls the tapped/selected chip into view, matching
              // the Movies screen's library chips (see
              // lib/widgets/live_tv/category_chips_row.dart).
              child: CategoryChipsRow(
                categories: _categories,
                selected: selectedCategory,
                padding: EdgeInsets.symmetric(
                  horizontal: Responsive.contentPadding(context),
                ),
                chipBuilder: (category, _) => _buildChip(category),
              ),
            ),

            const SizedBox(height: 5),
          ],

          Expanded(

            child: CategorySwipeSwitcher(
              categoryKey: selectedCategory,
              onSwipeNext: () => _swipeCategory(1),
              onSwipePrevious: () => _swipeCategory(-1),
              child: filteredChannels.isEmpty

                ? const Center(

              child: Text(

                "No channels found",

                style: TextStyle(
                  color: Colors.white54,
                  fontSize: 18,
                ),

              ),

            )

                : BottomClearanceBuilder(
              builder: (context, bottomClearance) => FadeScrollbar(
                controller: _scrollControllerFor(selectedCategory),
                child: GridView.builder(
              controller: _scrollControllerFor(selectedCategory),
              // The main nav's bottom bar (mini player + tab bar) floats
              // over this screen in a plain Stack (not a real
              // Scaffold.extendBody — see MainNavScreen's own doc
              // comment), so MediaQuery's bottom padding here is only
              // the safe-area inset. BottomClearance.of adds the bar's
              // actual height back in, reactively, so the last row of
              // channels can clear it instead of stopping behind it.
              // Aspect-scoped (MediaQuery.paddingOf) instead of the
              // unscoped MediaQuery.of(context) this used to call — that
              // subscribed this whole screen (search field, category
              // chips/dropdown, and the channel grid) to every
              // MediaQueryData field, including viewInsets.bottom, which
              // the framework updates every single frame while this
              // screen's own search field (or — since this is a pushed
              // route sitting on top of the IndexedStack tabs — any
              // keyboard elsewhere) is animating open or closed. Covers
              // both this widget's "All Channels" and "Favorites" uses
              // since they share it. paddingOf only rebuilds when the
              // actual safe-area padding changes.
              padding: EdgeInsets.fromLTRB(
                Responsive.contentPadding(context),
                0,
                Responsive.contentPadding(context),
                20 + MediaQuery.paddingOf(context).bottom + bottomClearance,
              ),

              itemCount: filteredChannels.length,

              gridDelegate:
              SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: _getGridColumns(context),
                crossAxisSpacing: 14,
                mainAxisSpacing: 14,
                childAspectRatio: .72,
              ),

              itemBuilder: (context, index) {

                final channel = filteredChannels[index];

                return _buildChannelCard(channel);

              },
              ),
                ),
            ),
            ),
          ),

        ],
      ),
      ),
    );
  }
}
