import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/cache/library_cache.dart';
import '../../services/library_prefetcher.dart';
import '../collection_details/collection_details_screen.dart';
import '../main_nav/navigation_controller.dart';
import '../../virtual/virtual_catalog.dart';
import '../movie_details/movie_details_screen.dart';

import '../../utils/responsive.dart';

import 'widgets/library_chips.dart';
import 'widgets/movie_grid.dart';
import '../../widgets/shared/selector_dropdown.dart';
import 'widgets/sort_chips.dart';
import '../../widgets/common/resistive_refresh.dart';
import '../../widgets/common/fade_scrollbar.dart';
import '../../widgets/common/category_swipe_switcher.dart';
import '../../widgets/common/collapsing_screen_label.dart';
import '../../utils/bottom_clearance.dart';
import '../../widgets/music/song_multi_select.dart';
import '../../widgets/music/song_selection_bar.dart';
import 'widgets/title_selection_actions.dart';

// Matches the gold used for pull-to-refresh on Favorites/Filmography.
const _gold = Color(0xffD4AF37);

class MoviesScreen extends StatefulWidget {
  /// "movies" (the Movies tab) or "tvshows" (the TV Shows tab). The two
  /// tabs are the same screen; only the content and the library chips differ.
  const MoviesScreen({super.key, this.mode = "movies"});

  final String mode;

  /// Loads SharedPreferences ahead of time (called once from the main
  /// navigation, long before either tab is opened) so a tab's remembered
  /// library chip can be read synchronously in initState and is already
  /// selected on the very first frame, instead of selecting itself a moment
  /// after the tab opens.
  static Future<void> warmUp() => _MoviesScreenState.warmUp();

  @override
  State<MoviesScreen> createState() => _MoviesScreenState();
}

class _MoviesScreenState extends State<MoviesScreen> {
  /// Filled by [warmUp] (or the first screen's own load). While it is null
  /// the remembered chip can only be read asynchronously.
  static SharedPreferences? _prefsCache;

  static Future<void> warmUp() async {
    if (_prefsCache != null) return;
    try {
      _prefsCache = await SharedPreferences.getInstance();
    } catch (e) {
      debugPrint(e.toString());
    }
  }

  bool loading = true;

  // One ScrollController per swipe "lane" (see _categoryKey) rather
  // than a single shared one — CategorySwipeSwitcher keeps the lane
  // that's animating out mounted alongside the incoming one for the
  // length of the swipe transition, so two lanes sharing one
  // controller would mean two live Scrollables attached to the same
  // controller at once. Same fix already applied to Music's tabs
  // (_contentScrollControllers) for the identical crash.
  final Map<String, ScrollController> _gridScrollControllers = {};

  ScrollController _scrollControllerFor(String key) =>
      _gridScrollControllers.putIfAbsent(key, () => ScrollController());

  // Hold-to-multi-select for movie / TV show posters — the same
  // SongMultiSelect + SongSelectionBar the Music tab uses, with Favorite
  // as the only action.
  final SongMultiSelect _titleSelect = SongMultiSelect();

  void _exitTitleSelection() {
    setState(() => _titleSelect.clear());
  }

  Future<void> _favoriteSelectedTitles() => toggleFavoriteForSelection(
        context: context,
        selection: _titleSelect,
        setState: setState,
      );

  List<dynamic> libraries = [];
  List<dynamic> movies = [];

  dynamic selectedLibrary;

  // FIRST VISIT DEFAULT: with no chip picked the screen used to sit on an
  // "all libraries" view with every chip unselected. Now the first chip is
  // selected automatically the first time the chips are known — unless a
  // chip was picked here before (remembered per tab), or something else
  // (Home's library row, a mode request) already chose a view.
  bool _initialLibraryHandled = false;
  bool _savedLibraryLoaded = false;
  String? _savedLibraryId;
  String get _savedLibraryKey => 'movies_screen_last_library_${widget.mode}';

  // Stored in place of a library id when the person turned every chip off to
  // see all titles, so that choice is remembered too: without it the next
  // visit (or a rotation / app restart that rebuilds this screen) put the
  // first chip back on by itself and "all" could never stick.
  static const String _kAllLibraries = '__all__';

  String selectedMode = "movies";
  String selectedSort = "DateCreated";

  // Caches the results of every (mode, library, sort) combination the user
  // has already loaded this session. Tapping a chip for a view we've seen
  // before renders instantly from cache instead of waiting on the network
  // again; a fresh copy is still fetched silently in the background so the
  // cache doesn't go stale.
  final Map<String, List<dynamic>> _cache = {};

  // Bumped on every chip tap so a slow, now-stale request can't clobber the
  // UI after the user has already moved on to a different selection.
  int _requestId = 0;

  // Search filters whatever grid is currently on screen (All Movies, TV
  // Shows, or a specific library like Kids) — same "search-as-you-type
  // over the already-loaded list" approach as the Music screen, debounced
  // the same way (300ms) since there's no network round trip involved.
  String search = "";
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  Timer? _searchDebounce;

  List<dynamic> get _filteredMovies {
    if (search.isEmpty) return movies;

    final query = search.toLowerCase();
    return movies.where((item) {
      final name = (item["Name"] ?? "").toString().toLowerCase();
      return name.contains(query);
    }).toList();
  }

  String _cacheKeyFor({
    required String mode,
    required dynamic library,
    required String sort,
  }) {
    return "${mode}_${library?["Id"] ?? "all"}_$sort";
  }

  @override
  void initState() {
    super.initState();
    selectedMode = widget.mode;
    NavigationController.instance.addListener(_onNavigationChanged);
    // The remembered chip is read synchronously when preferences are already
    // loaded (see warmUp), so it can be selected before the first frame.
    final warmPrefs = _prefsCache;
    if (warmPrefs != null) {
      _savedLibraryId = warmPrefs.getString(_savedLibraryKey);
      _savedLibraryLoaded = true;
    }
    // Paint the last-known grid + library chips in the very first frame
    // (see _seedFromCache), then refresh from the server underneath.
    _seedFromCache();
    if (!_savedLibraryLoaded) unawaited(_loadSavedLibrary());
    // Select the remembered / first chip NOW (when the chip list is already
    // known from the cache) rather than after the first frame: otherwise the
    // chips are drawn unselected and the selection animates in on its own.
    _maybeApplyInitialLibrary();
    loadLibraries();
  }

  Future<void> _loadSavedLibrary() async {
    try {
      final prefs = _prefsCache ?? await SharedPreferences.getInstance();
      _prefsCache = prefs;
      _savedLibraryId = prefs.getString(_savedLibraryKey);
    } catch (e) {
      debugPrint(e.toString());
    }
    if (!mounted) return;
    _savedLibraryLoaded = true;
    _maybeApplyInitialLibrary();
  }

  Future<void> _saveLibraryId(String id) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_savedLibraryKey, id);
    } catch (e) {
      debugPrint(e.toString());
    }
  }

  /// Selects the remembered chip (or the first one) once, as soon as both
  /// the chip list and the remembered choice are known. A pending request
  /// from elsewhere in the app is applied first and wins.
  void _maybeApplyInitialLibrary() {
    if (!mounted || _initialLibraryHandled) return;
    if (!_savedLibraryLoaded || libraries.isEmpty) return;

    _applyPendingLibrarySelection();
    if (_initialLibraryHandled) return;
    _initialLibraryHandled = true;

    final savedId = _savedLibraryId;
    // Chips were turned off last time: stay on the all-titles view, which
    // is already the one on screen (nothing is selected yet).
    if (savedId == _kAllLibraries) return;

    dynamic target;
    if (savedId != null) {
      for (final lib in libraries) {
        if (lib["Id"]?.toString() == savedId) {
          target = lib;
          break;
        }
      }
    }
    target ??= libraries.first;

    unawaited(_setLibrary(target));
  }

  @override
  void dispose() {
    NavigationController.instance.removeListener(_onNavigationChanged);
    _searchDebounce?.cancel();
    _searchController.dispose();
    _searchFocusNode.dispose();
    for (final controller in _gridScrollControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  // Closes the keyboard/cursor the moment another screen opens, rather
  // than leaving the search field focused underneath the pushed route —
  // otherwise the keyboard can stay up and interfere with the new
  // screen's layout, and (since nothing re-requests focus on pop) it
  // stays deactivated until the search field is tapped again.
  void _openDetail(Widget page) {
    _searchFocusNode.unfocus();
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => page),
    );
  }

  void _onSearchChanged(String value) {
    search = value;

    // Debounced exactly like the Music screen's search field, for the
    // same feel even though this filters an already-loaded in-memory
    // list instead of re-querying the server.
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      setState(() {});
    });
  }

  void _onNavigationChanged() {
    _applyPendingLibrarySelection();
  }

  /// Applies a pending navigation request from Home's library row, if
  /// one is waiting: either a specific library selection (Kids,
  /// Collections, Home Videos, etc — anything with a chip in this
  /// screen, via pendingLibraryId) or, failing that, a plain top-level
  /// mode switch (Movies/TV Shows, via pendingMode — used for the
  /// generic Movies/TV Shows library tile, which doesn't have its own
  /// chip here since it's already the default view). Clears whichever
  /// request it applies so it isn't re-applied on later, unrelated
  /// navigation changes.
  void _applyPendingLibrarySelection() {
    final pendingId = NavigationController.instance.pendingLibraryId;

    if (pendingId != null) {
      // Libraries haven't loaded yet — wait for the next call (loadLibraries
      // re-triggers this once they have) instead of dropping the request.
      if (libraries.isEmpty) return;

      final match = libraries.where((lib) => lib["Id"] == pendingId).toList();

      if (match.isEmpty) {
        // Not one of this tab's chips: leave the request for the other tab
        // unless it is a generic Movies/TV tile this tab owns (handled by
        // the mode check below).
        if (NavigationController.instance.pendingMode != widget.mode) return;
      } else {
        NavigationController.instance.pendingLibraryId = null;
      }

      if (match.isNotEmpty) {
        // A specific library match supersedes any pending mode switch —
        // selectLibrary below sets the correct mode itself — so clear it
        // too rather than letting it fire afterwards and override the
        // more specific selection.
        NavigationController.instance.pendingMode = null;
        // "See all" from a Recently Added row also wants the "New" sort;
        // _setLibrary reads selectedSort, so reset it before selecting.
        if (NavigationController.instance.pendingNewestSort) {
          NavigationController.instance.pendingNewestSort = false;
          selectedSort = "DateCreated";
        }
        // Force-select rather than changeLibrary's toggle behavior: this
        // request came from tapping a library icon elsewhere (e.g. Home),
        // not from tapping the chip in this screen, so it should always
        // land on that library — even if it's already selected — instead
        // of being interpreted as "tap the same chip again to deselect".
        selectLibrary(match.first);
        return;
      }
      // No chip for this id (e.g. the generic Movies/TV Shows library
      // tile, which is filtered out of this screen's chip list) — fall
      // through to a plain mode switch below instead.
    }

    final pendingMode = NavigationController.instance.pendingMode;
    if (pendingMode != null && pendingMode == widget.mode) {
      final keepLibrary = NavigationController.instance.pendingKeepLibrary;
      NavigationController.instance.pendingMode = null;
      NavigationController.instance.pendingLibraryId = null;
      NavigationController.instance.pendingKeepLibrary = false;
      // changeMode already lands on the "New" sort.
      NavigationController.instance.pendingNewestSort = false;
      // Coming from Downloads' Browse button: just show this tab as the
      // person left it, with its selected library chip still selected.
      if (keepLibrary && selectedLibrary != null) return;
      changeMode(widget.mode);
    }
  }

  /// Library chips that belong in this screen (see the filters below).
  /// Extracted from loadLibraries so the cached copy used by
  /// _seedFromCache goes through exactly the same filtering.
  List<dynamic> _usableLibraries(List<dynamic> libs) {
    return libs.where((library) {
        final type = (library["CollectionType"] ?? "")
            .toString()
            .toLowerCase();

        final name = (library["Name"] ?? "")
            .toString()
            .toLowerCase();

        // Each tab shows only its own kind of library.
        if ((type == "movies" || type == "tvshows") && type != widget.mode) {
          return false;
        }
        if (widget.mode == "tvshows" && type != "tvshows") return false;

        // Remove unsupported libraries
        if (type == "music" ||
            type == "livetv" ||
            type == "channels") {
          return false;
        }

        // Hide Movies and TV Shows because they already exist as top tabs
        if (name == "movies" ||
            name == "movie" ||
            name == "tv shows" ||
            name == "tvshows" ||
            name == "series" ||
            name == "playlists" ||
            name == "playlist" ||
            type == "playlists") {
          return false;
        }

        return true;
    }).toList();
  }

  /// Paints whatever was last seen — straight from memory when the
  /// background prewarm (LibraryPrefetcher) already has it, otherwise from
  /// the copy persisted by the previous session — so the grid and library
  /// chips are on screen the moment this tab opens instead of a skeleton
  /// followed by a full server round trip. The real request in
  /// loadLibraries/loadMovies still runs underneath and replaces it.
  ///
  /// Called from initState, before the first build, so the in-memory path
  /// assigns fields directly (no setState needed yet).
  void _seedFromCache() {
    final cache = LibraryCache.instance;

    final memoryLibraries = cache.peek(LibraryFeeds.librariesKey);
    if (memoryLibraries is List) {
      libraries = _usableLibraries(memoryLibraries);
    }

    final key = _cacheKeyFor(
      mode: selectedMode,
      library: selectedLibrary,
      sort: selectedSort,
    );
    final memoryMovies = cache.peek(LibraryFeeds.movieKey(
      mode: selectedMode,
      libraryId: null,
      sort: selectedSort,
    ));
    if (memoryMovies is List) {
      _cache[key] = memoryMovies;
      movies = memoryMovies;
      loading = false;
      return;
    }

    unawaited(_seedFromDisk());
  }

  Future<void> _seedFromDisk() async {
    final cache = LibraryCache.instance;
    final mode = selectedMode;
    final sort = selectedSort;

    final results = await Future.wait<Object?>([
      cache.read(LibraryFeeds.librariesKey),
      cache.read(LibraryFeeds.movieKey(
        mode: mode,
        libraryId: null,
        sort: sort,
      )),
    ]);
    if (!mounted) return;

    final persistedLibraries = results[0];
    final persistedMovies = results[1];
    var changed = false;

    if (persistedLibraries is List && libraries.isEmpty) {
      libraries = _usableLibraries(persistedLibraries);
      changed = true;
    }

    // Only apply it if nothing newer has happened meanwhile: the network
    // result hasn't landed (it would have filled _cache) and the person
    // hasn't already moved on to a different view.
    final key = _cacheKeyFor(mode: mode, library: null, sort: sort);
    if (persistedMovies is List &&
        _cache[key] == null &&
        selectedLibrary == null &&
        selectedMode == mode &&
        selectedSort == sort) {
      _cache[key] = persistedMovies;
      movies = persistedMovies;
      loading = false;
      changed = true;
    }

    if (changed) setState(() {});
    _maybeApplyInitialLibrary();
  }

  /// The grid for this view if it's already known: this screen's own
  /// session cache first, then whatever the prewarm/previous session left
  /// in LibraryCache's memory. Lets switching to TV Shows / a library chip
  /// / another sort paint instantly instead of showing the skeleton.
  List<dynamic>? _cachedFor({
    required String mode,
    required dynamic library,
    required String sort,
  }) {
    final key = _cacheKeyFor(mode: mode, library: library, sort: sort);
    final known = _cache[key];
    if (known != null) return known;

    final persisted = LibraryCache.instance.peek(LibraryFeeds.movieKey(
      mode: mode,
      libraryId: library?["Id"]?.toString(),
      sort: sort,
    ));
    if (persisted is List) {
      _cache[key] = persisted;
      return persisted;
    }
    return null;
  }

  Future<void> loadLibraries() async {
    setState(() {
      // Nothing to show yet -> skeleton; something seeded -> keep it up.
      loading = movies.isEmpty;
    });

    // ROOT CAUSE of the slow grid: the movies request used to start only
    // AFTER the libraries request had finished (two network round trips
    // back to back, over a tunnel). The default view (Movies, all
    // libraries) doesn't depend on the library list at all, so both now go
    // out at the same time; the chips appear as soon as theirs lands.
    final moviesFuture = loadMovies(silent: movies.isNotEmpty);
    final startedRequest = _requestId;

    try {
      final libs = await LibraryFeeds.libraries();
      if (mounted) {
        setState(() {
          libraries = _usableLibraries(libs);
        });
        _maybeApplyInitialLibrary();
      }
    } catch (e) {
      debugPrint(e.toString());
    }

    // loadMovies has its own try/catch, so this never throws.
    await moviesFuture;

    if (!mounted) return;
    // A newer request (e.g. the first chip being selected) owns the
    // loading state; clearing it here would flash an empty grid.
    if (_requestId == startedRequest) {
      setState(() {
        loading = false;
      });
    }

    _applyPendingLibrarySelection();
  }

  Future<void> loadMovies({bool silent = false}) async {
    final mode = selectedMode;
    final library = selectedLibrary;
    final sort = selectedSort;
    final cacheKey = _cacheKeyFor(mode: mode, library: library, sort: sort);

    final requestId = ++_requestId;

    // Instant path: we've already fetched this exact view before, so show
    // it immediately with no spinner/skeleton at all. We still kick off a
    // background refresh below to keep the cache current.
    final cached = _cachedFor(mode: mode, library: library, sort: sort);
    if (cached != null && !silent) {
      setState(() {
        movies = cached;
        loading = false;
      });
    }

    // NAMESIS PRIME: nothing cached for this view yet -> paint the first 60
    // titles as soon as they arrive, while the full list keeps loading.
    var fullDone = false;
    if (cached == null && !silent) {
      unawaited(() async {
        try {
          final first = await LibraryFeeds.moviesQuick(
            mode: mode,
            library: library,
            sort: sort,
          );
          if (!mounted || requestId != _requestId || fullDone) return;
          if (first.isNotEmpty) {
            setState(() {
              movies = first;
              loading = false;
            });
          }
        } catch (_) {}
      }());
    }

    try {
      // The request itself (lean Fields, cache key, de-duplication with the
      // background prewarm, persisting for next launch) lives in
      // LibraryFeeds.movies.
      final data = await LibraryFeeds.movies(
        mode: mode,
        library: library,
        sort: sort,
      );

      fullDone = true;
      _cache[cacheKey] = data;

      // A newer request has since been fired (user tapped another chip
      // before this one finished) — drop this now-stale result instead of
      // overwriting whatever the user is currently looking at.
      if (!mounted || requestId != _requestId) return;

      setState(() {
        movies = data;
        loading = false;
      });
    } catch (e) {
      debugPrint(e.toString());
      if (requestId != _requestId) return;
      setState(() {
        loading = false;
      });
    }
  }

  /// Identifies which "swipe lane" the grid is currently showing:
  /// either the active library chip, or (while no library is selected)
  /// the active top-tab mode. Doubles as this lane's ScrollController
  /// key, so a lane kept alive mid-swipe by CategorySwipeSwitcher never
  /// shares a controller with whichever lane is animating out — see
  /// _gridScrollControllers' doc comment.
  String get _categoryKey => selectedLibrary != null
      ? "lib_${selectedLibrary["Id"]}"
      : "mode_$selectedMode";

  /// Swipe axis, per Ben's spec: while a library chip is selected,
  /// left-right moves between library chips; otherwise it toggles the
  /// Movies/TV Shows top tabs. delta is +1 for a "next" (leftward)
  /// swipe, -1 for "previous". Clamped at either end rather than
  /// wrapping around.
  void _swipeCategory(int delta) {
    if (selectedLibrary != null) {
      final index = libraries.indexWhere(
        (lib) => lib["Id"] == selectedLibrary["Id"],
      );
      if (index == -1) return;

      final nextIndex = index + delta;
      if (nextIndex < 0 || nextIndex >= libraries.length) return;

      _setLibrary(libraries[nextIndex]);
      return;
    }

    // No Movies/TV Shows top tabs any more: with no chip selected, a swipe
    // moves into the first (or last) library chip.
    if (libraries.isEmpty) return;
    _setLibrary(delta > 0 ? libraries.first : libraries.last);
  }

  Future<void> changeMode(String mode) async {
    _initialLibraryHandled = true;
    // Lands on the all-titles view (no chip), so remember that too.
    _savedLibraryId = _kAllLibraries;
    unawaited(_saveLibraryId(_kAllLibraries));
    final cached = _cachedFor(
      mode: mode,
      library: null,
      sort: "DateCreated",
    );

    setState(() {
      _titleSelect.clear();
      selectedMode = mode;
      selectedLibrary = null;
      selectedSort = "DateCreated";
      // Uncached: clear the old grid and show the skeleton right away
      // instead of leaving stale items on screen during the fetch.
      // Cached: paint the cached result immediately, no waiting at all.
      movies = cached ?? [];
      loading = cached == null;
    });

    await loadMovies(silent: cached != null);
  }

  /// The selected library chip is blocked by Parental Controls (its genre
  /// is a blocked genre): the grid shows "Library blocked".
  bool get _selectedLibraryBlocked =>
      selectedLibrary != null &&
      VirtualCatalog.isLibraryBlocked(selectedLibrary["Id"]?.toString());

  Future<void> changeLibrary(dynamic library) async {
    // Re-tapping the already-selected chip does nothing: a selected chip
    // stays selected (it no longer toggles off to the all-titles view).
    if (selectedLibrary != null && selectedLibrary["Id"] == library["Id"]) {
      return;
    }

    await _setLibrary(library);
  }

  /// Always selects [library], regardless of what's currently selected —
  /// unlike changeLibrary (used by directly tapping a chip in this
  /// screen), which ignores a repeat tap on the selected chip. Used for
  /// programmatic navigation into a specific library (e.g. tapping a
  /// library icon on Home), where a second tap on the same icon should
  /// land on that library again (reloading it).
  Future<void> selectLibrary(dynamic library) async {
    await _setLibrary(library);
  }

  /// Landscape dropdown equivalent of tapping a LibraryChip — always
  /// force-selects (like selectLibrary). "All Libraries" is represented
  /// as a null libraryId (the dropdown's own explicit option).
  Future<void> _onLibraryDropdownSelected(String? libraryId) async {
    if (libraryId == null) {
      await _setLibrary(null);
      return;
    }

    final matches = libraries.where((lib) => lib["Id"] == libraryId);
    if (matches.isEmpty) return;

    await _setLibrary(matches.first);
  }

  IconData _libraryIcon(String? type) {
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

  Future<void> _setLibrary(dynamic nextLibrary) async {
    _initialLibraryHandled = true;
    // A chip's id, or "all" when the chip was turned off (null library).
    final nextId = nextLibrary?["Id"]?.toString() ?? _kAllLibraries;
    _savedLibraryId = nextId;
    unawaited(_saveLibraryId(nextId));
    // Library chips filter movie libraries, so picking one while "TV Shows"
    // is selected would otherwise silently return no results (querying
    // that library for Series items). Switch back to Movies mode so the
    // selection actually takes effect.
    final nextMode = widget.mode;

    final cached = _cachedFor(
      mode: nextMode,
      library: nextLibrary,
      sort: selectedSort,
    );

    setState(() {
      _titleSelect.clear();
      selectedLibrary = nextLibrary;
      selectedMode = nextMode;
      movies = cached ?? [];
      loading = cached == null;
    });

    await loadMovies(silent: cached != null);
  }

  Future<void> changeSort(String sort) async {
    final cached = _cachedFor(
      mode: selectedMode,
      library: selectedLibrary,
      sort: sort,
    );

    setState(() {
      _titleSelect.clear();
      selectedSort = sort;
      movies = cached ?? [];
      loading = cached == null;
    });

    await loadMovies(silent: cached != null);
  }

  // Search field width in the SortChips+search row, as a fraction of
  // the row's own available width (clamped) rather than the flat
  // 150dp this used to be. A flat width assumed the Pixel 6 "smallest"
  // Display size canvas the screen was tuned against — at the default
  // Display size the same physical row reports less logical width, so
  // the fixed 150dp field left too little room for the sort chips.
  // SortChips now scales itself down to fit whatever's left (see
  // ScalingChipRow), but keeping the field's own width tunable and
  // slightly narrower on average means it doesn't need to lean on that
  // shrink as hard. Tune these three to change how the row splits
  // width between chips and search.
  static const double _kSearchWidthFraction = 0.28;
  static const double _kMinSearchWidth = 96;
  static const double _kMaxSearchWidth = 150;
  static const double _kChipsSearchGap = 8;

  double _searchFieldWidth(double rowWidth) {
    // Same clamp() shape Responsive.emptyStateHeight already uses.
    return (rowWidth * _kSearchWidthFraction)
        .clamp(_kMinSearchWidth, _kMaxSearchWidth);
  }

  /// Portrait header: the original stacked chip rows — TopTabs, the
  /// horizontally-scrolling LibraryChips, and the SortChips+search row.
  /// The separate "All Movies"/library-name subheading that used to sit
  /// between LibraryChips and the sort row was removed: LibraryChips
  /// already auto-scrolls the selected chip into view and highlights it
  /// gold, so the label was telling the user something the chip row
  /// already showed. Returned as a List so it can be spread directly
  /// into the outer Column's children.
  List<Widget> _buildPortraitSelectors() {
    return [
      // No outer horizontal Padding here — LibraryChips carries its
      // own 20px padding on the ListView itself (default), which is
      // what lets the row scroll all the way to the true screen edge
      // instead of stopping wherever an outer padding used to sit.
      // Matches the Music screen's tab row.
      LibraryChips(
        libraries: libraries,
        selected: selectedLibrary,
        onSelected: changeLibrary,
      ),

      const SizedBox(height: 8),

      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        // LayoutBuilder so the search field's width (and, in turn, how
        // much room SortChips has left) is derived from this row's
        // *actual* available width on this device/Display-size setting
        // instead of a flat constant — see _searchFieldWidth's doc
        // comment above.
        child: LayoutBuilder(
          builder: (context, constraints) {
            final searchWidth = _searchFieldWidth(constraints.maxWidth);

            return Row(
              children: [
                Expanded(
                  child: SortChips(
                    selected: selectedSort,
                    onSelected: changeSort,
                  ),
                ),

                const SizedBox(width: _kChipsSearchGap),

                SizedBox(
                  width: searchWidth,
                  height: 36,
                  child: _buildSearchField(),
                ),
              ],
            );
          },
        ),
      ),
    ];
  }

  /// Landscape header: mode / library / sort chips collapse into three
  /// dropdown pills sharing a single row with the search field — same
  /// state and change-handlers as the portrait chips above, just a
  /// more compact control so the grid gets the vertical space back.
  Widget _buildLandscapeSelectorsRow() {
    final sortLabel = SortChips.sorts.firstWhere(
      (s) => s["value"] == selectedSort,
      orElse: () => SortChips.sorts.first,
    )["label"]!;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        children: [
          Flexible(
            child: SelectorDropdown<String?>(
              label: selectedLibrary?["Name"] ?? "All Libraries",
              leadingIcon: selectedLibrary != null
                  ? (_selectedLibraryBlocked
                      ? Icons.block
                      : _libraryIcon(selectedLibrary["CollectionType"]))
                  : Icons.video_library,
              selectedValue: selectedLibrary?["Id"],
              maxWidth: 170,
              options: [
                const DropdownOption<String?>(
                  value: null,
                  label: "All Libraries",
                  icon: Icons.video_library,
                ),
                ...libraries.map(
                  (lib) => DropdownOption<String?>(
                    value: lib["Id"] as String?,
                    label: lib["Name"] ?? "",
                    icon: VirtualCatalog.isLibraryBlocked(
                            lib["Id"]?.toString())
                        ? Icons.block
                        : _libraryIcon(lib["CollectionType"]),
                  ),
                ),
              ],
              onSelected: _onLibraryDropdownSelected,
            ),
          ),

          const SizedBox(width: 10),

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
            onSelected: changeSort,
          ),

          const Spacer(),

          // Fixed, compact width instead of Expanded — three dropdown
          // pills already communicate "these are filters", so a search
          // field stretched across the rest of the row read as
          // oversized next to them. A smaller pill matching the
          // portrait width keeps the row visually balanced.
          SizedBox(
            width: 180,
            height: 34,
            child: _buildSearchField(),
          ),
        ],
      ),
    );
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

  @override
  Widget build(BuildContext context) {
    // Aspect-scoped — only rebuilds this screen when device padding
    // itself changes (rotation, notch/gesture-area changes), never on
    // keyboard insets. See the `viewPadding` swap below for why that
    // distinction matters.
    final viewPadding = MediaQuery.paddingOf(context);

    return Scaffold(
      // Matches the app-wide page background every other bottom-nav tab
      // (Home, Live TV, Music) uses — this was still on the older,
      // darker 0xff111111 shade used by the movie/collection *detail*
      // screens, so switching tabs into Movies visibly shifted the
      // background color.
      backgroundColor: const Color(0xff161616),
      // No bottom padding is added below (see the Padding replacing
      // SafeArea further down) — the glass bottom nav bar needs actual
      // scrolled content behind it to blur (via BackdropFilter sampling
      // whatever extendBody lets paint underneath it). A full SafeArea
      // here would pad the CustomScrollView away from the bottom edge
      // entirely, so nothing would ever be visible/blurred behind the
      // bar — it'd just read as a flat solid color instead of frosted
      // glass. The actual "don't get hidden behind the bar" clearance is
      // handled below via the trailing SliverPadding instead.
      // Tapping anywhere outside the search field dismisses its focus
      // (and the keyboard) so it deactivates until tapped again — the
      // opaque GestureDetector catches taps that land on empty space
      // between/around widgets, not just on other tappable ones.
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => FocusScope.of(context).unfocus(),
        // Was SafeArea(bottom: false) here. SafeArea's own build() calls
        // the *unscoped* MediaQuery.of(context) internally, which
        // subscribes it to every MediaQueryData field — including
        // viewInsets.bottom, which the framework updates on every single
        // frame while any keyboard (this screen's own search field, or
        // — since every bottom-nav tab is kept alive together in an
        // IndexedStack — even one open on a completely different tab)
        // is sliding open or closed. Each of those frames marked this
        // SafeArea dirty and forced its *entire* child — the title, mode
        // tabs, library chips, sort/search row, and the movie grid
        // itself — to rebuild from scratch in lockstep with the
        // keyboard's own animation, which is what was surfacing app-wide
        // as the keyboard dragging/stuttering instead of gliding
        // cleanly. A plain Padding using the aspect-scoped `viewPadding`
        // above gets the identical top/left/right safe-area values
        // (bottom was already excluded) but only rebuilds when device
        // padding itself actually changes, so this subtree is completely
        // inert while any keyboard animates — same fix applied to
        // MusicScreen for the identical symptom.
        child: Padding(
        padding: EdgeInsets.only(
          top: viewPadding.top,
          left: viewPadding.left,
          right: viewPadding.right,
        ),
        // Title, mode tabs, library chips, and the sort/search row stay
        // fixed in place (a plain Column) — only the grid below scrolls,
        // in its own nested CustomScrollView. Matches the Music screen's
        // fixed header instead of everything scrolling together.
        // LabelCollapseScope: the "Movies" label slides away on scroll
        // down and returns on scroll up (see collapsing_screen_label.dart);
        // the mode/library/sort/search rows below it stay pinned. The
        // resetKey brings the label back whenever a different lane
        // (mode or library chip) becomes visible.
        child: LabelCollapseScope(
        resetKey: _categoryKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 8 stays above the pinned rows even while the label is
            // collapsed; the other 7 of the old 15 top margin collapses
            // with the label, so the expanded layout is unchanged.
            const SizedBox(height: kCollapsedLabelTopGap),

            // Label-to-first-row gap (15, matching the other screens)
            // is part of the collapsing block too.
            if (_titleSelect.active) ...[
              const SizedBox(height: 7),
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
              topPadding: 7,
              bottomPadding: 10,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Text(
                  widget.mode == "tvshows" ? "TV Shows" : "Movies",
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 30,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),

            if (Responsive.isLandscape(context))
              // Landscape: chips collapse into three dropdown selectors
              // (mode / library / sort) sharing a single row with the
              // search field, instead of stacking four separate rows —
              // frees up vertical space for the grid. Same underlying
              // state and callbacks as the portrait chips, just a
              // different control for picking the same values.
              _buildLandscapeSelectorsRow()
            else
              ..._buildPortraitSelectors(),

            SizedBox(height: Responsive.isLandscape(context) ? 8 : 5),

            Expanded(
              child: CategorySwipeSwitcher(
                categoryKey: _categoryKey,
                onSwipeNext: () => _swipeCategory(1),
                onSwipePrevious: () => _swipeCategory(-1),
                child: ResistiveRefresh(
                onRefresh: loadMovies,
                color: _gold,
                backgroundColor: const Color(0xff232323),
                child: FadeScrollbar(
                  controller: _scrollControllerFor(_categoryKey),
                  child: CustomScrollView(
                  controller: _scrollControllerFor(_categoryKey),
                  // Keeps pull-to-refresh live even when a filtered
                  // library/tab (e.g. a small TV Shows library, or a
                  // narrow search result) doesn't fill the viewport.
                  physics: const AlwaysScrollableScrollPhysics(),
                  slivers: [
                    MovieGrid(
                      loading: loading,
                      blocked: _selectedLibraryBlocked,
                      selection: _titleSelect,
                      onSelectionChanged: () => setState(() {}),
                      items: _filteredMovies,
                      emptyIcon: selectedMode == "tvshows"
                          ? Icons.live_tv_outlined
                          : Icons.movie_outlined,
                      emptyTitle: search.isNotEmpty
                          ? "No results found"
                          : selectedMode == "tvshows"
                              ? "No TV shows found"
                              : "No movies found",
                      emptySubtitle: search.isNotEmpty
                          ? "Try a different title or check your spelling."
                          : selectedLibrary != null
                              ? "This library doesn't have any titles yet."
                              : null,
                      onItemTap: (item) {
                        if (item["Type"] == "BoxSet") {
                          _openDetail(
                            CollectionDetailsScreen(
                              collectionId: item["Id"],
                              initialItem: Map<String, dynamic>.from(item),
                            ),
                          );
                          return;
                        }

                        _openDetail(
                          MovieDetailsScreen(
                            itemId: item["Id"],
                            initialItem: Map<String, dynamic>.from(item),
                          ),
                        );
                      },
                    ),

                    // Genuinely dynamic: BottomClearance.of tracks the
                    // glass bar's actual current height (mini player +,
                    // in portrait, the tab bar) reactively, so the last
                    // row of movies clears it exactly, no more and no
                    // less — MediaQuery's own bottom padding here is only
                    // ever the device safe-area inset, not the bar.
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
            ),
          ],
        ),
        ),
        ),
      ),
    );
  }
}
