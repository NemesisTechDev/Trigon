import 'package:flutter/material.dart';

import '../../services/analytics_service.dart';

/// Bottom navigation tab indices, matching the order of `_screens` in
/// MainNavScreen (Home, Movies, Music, Live TV, Downloads, Search,
/// Favorites, Profile). The last three only ever get selected from the
/// landscape sidebar (there's no portrait bottom-bar item for them),
/// but they live in the same IndexedStack as the first five so every
/// destination in the sidebar switches instantly and keeps its state,
/// exactly like the five main tabs already did.
class NavTabs {
  static const int home = 0;
  static const int movies = 1;
  static const int tvShows = 2;
  // Music has no tab any more; anything that still asks for it lands on Home.
  static const int music = home;
  static const int search = 3;
  static const int downloads = 4;
  // Live TV has no bar/rail entry any more; its screen stays at index 5.
  static const int liveTv = 5;
  static const int favorites = 6;
  static const int profile = 7;
}

class NavigationController extends ChangeNotifier {
  NavigationController._();

  static final NavigationController instance =
  NavigationController._();

  /// The currently selected bottom nav tab. MainNavScreen treats this as
  /// the source of truth so other screens can request a tab switch.
  int tabIndex = NavTabs.home;

  /// Id of a library that MoviesScreen should select as soon as it's
  /// able to (e.g. a "Collections"/boxsets library tapped from Home).
  /// MoviesScreen clears this once it's applied the selection.
  String? pendingLibraryId;

  /// "movies" or "tvshows" — set when a generic Movies/TV Shows library
  /// tile is tapped on Home, since those aren't selectable libraries
  /// inside MoviesScreen (they're its top tabs instead).
  String? pendingMode;

  /// A MusicTab (by name, e.g. "playlists") that MusicScreen should
  /// switch to as soon as it's able to. MusicScreen clears this once
  /// it's applied the selection.
  String? pendingMusicTab;

  /// Set alongside a pending library/mode/music-tab request when the
  /// destination should land on its "New" sort (Home's Recently Added
  /// "See all"). MoviesScreen / MusicScreen clear it once applied.
  bool pendingNewestSort = false;

  /// Set by the Downloads "Browse Movies / Browse TV Shows" buttons: the
  /// destination should only come to the front and KEEP whichever library
  /// chip is already selected, instead of resetting to the all-titles view.
  /// MoviesScreen clears it once handled.
  bool pendingKeepLibrary = false;

  /// A DownloadsTab (by name: "movies", "shows" or "music") that
  /// DownloadsScreen should switch to as soon as it's able to. Set by
  /// [openDownloads] (i.e. a tap on a download notification);
  /// DownloadsScreen clears it once it's applied the selection.
  String? pendingDownloadsTab;

  /// MainNavScreen's own content Navigator — the nested one that holds
  /// the tab pages plus anything pushed on top of them (movie/music/
  /// collection details), underneath the persistent bottom nav bar/rail
  /// and mini player (see MainNavScreen._content's doc comment). Set
  /// once by MainNavScreen itself in initState.
  ///
  /// Exists so callers that aren't inside that Navigator's own widget
  /// subtree — most notably the full-screen audio player and its
  /// three-dot menu, which live on the app's ROOT Navigator, entirely
  /// above MainNavScreen — can still push a detail screen (e.g. "Go to
  /// Album"/"Go to Artist") onto the content Navigator instead of
  /// stacking it on the root one, so the nav bar/mini player stay
  /// visible underneath it exactly like they do for every other detail
  /// screen already pushed from inside a tab.
  GlobalKey<NavigatorState>? contentNavigatorKey;

  /// Pushes [route] onto the content Navigator (see
  /// [contentNavigatorKey]) rather than whichever Navigator happens to
  /// be nearest to the caller's own BuildContext. Silently does nothing
  /// if MainNavScreen isn't mounted yet, which shouldn't happen in
  /// practice since nothing that calls this can be on screen before it.
  Future<T?> pushOnContent<T>(Route<T> route) async {
    final navigator = contentNavigatorKey?.currentState;
    if (navigator == null) return null;
    return navigator.push(route);
  }

  /// Brings the Downloads tab to the front INSIDE the main nav shell
  /// (so the rail/bottom bar and mini player stay visible), optionally
  /// landing on one of its own Movies / TV Shows / Music sub-tabs.
  ///
  /// Same shape as MainNavScreen._selectTab: anything pushed on top of
  /// a tab on the content Navigator (e.g. a show's episode list) is
  /// popped first, then the tab is switched. Safe to call before
  /// MainNavScreen has mounted (cold start from a notification) — the
  /// content Navigator just doesn't exist yet, and the tab index +
  /// pending sub-tab are picked up when MainNavScreen/DownloadsScreen
  /// first build.
  void openDownloads({String? tab}) {
    pendingDownloadsTab = tab;
    contentNavigatorKey?.currentState?.popUntil((route) => route.isFirst);
    goToTab(NavTabs.downloads);
  }

  void goToTab(int index) {
    // One screen view per real tab change (not for a tap on the open tab).
    if (index != tabIndex) AnalyticsService.screen(_tabName(index));
    tabIndex = index;
    notifyListeners();
  }

  static String _tabName(int index) {
    switch (index) {
      case NavTabs.home:
        return 'home';
      case NavTabs.movies:
        return 'movies';
      case NavTabs.tvShows:
        return 'tv_shows';
      case NavTabs.search:
        return 'search';
      case NavTabs.downloads:
        return 'downloads';
      case NavTabs.liveTv:
        return 'live_tv';
      case NavTabs.favorites:
        return 'favorites';
      case NavTabs.profile:
        return 'profile';
      default:
        return 'tab_$index';
    }
  }

  /// Routes to the right screen for a library tile tapped on Home,
  /// based on the library's CollectionType.
  ///
  /// [newest] additionally asks the destination to activate its "New"
  /// sort (used by the Recently Added rows' "See all").
  void openLibrary(dynamic library, {bool newest = false}) {
    // Clear any earlier pending request that hasn't been applied yet —
    // otherwise a stale one left over from a previous tap could get
    // applied after this one and clobber the selection.
    pendingMode = null;
    pendingLibraryId = null;
    pendingMusicTab = null;
    pendingKeepLibrary = false;
    pendingNewestSort = newest;

    final type = (library["CollectionType"] ?? "").toString().toLowerCase();

    switch (type) {
      case "livetv":
        goToTab(NavTabs.liveTv);
        return;

      case "playlists":
        pendingMusicTab = "playlists";
        goToTab(NavTabs.music);
        return;

      case "music":
        pendingMusicTab = "albums";
        goToTab(NavTabs.music);
        return;

      case "movies":
        // pendingMode is the fallback for the generic "Movies" library
        // tile itself (which MoviesScreen filters out of its own chip
        // list, since it's already the default view) — but a named
        // library of this type, like "Kids", DOES have a chip, so pass
        // its id along too and let MoviesScreen prefer that when a
        // matching chip exists.
        pendingMode = "movies";
        pendingLibraryId = library["Id"];
        goToTab(NavTabs.movies);
        return;

      case "tvshows":
        pendingMode = "tvshows";
        pendingLibraryId = library["Id"];
        goToTab(NavTabs.tvShows);
        return;

      default:
        // Collections (boxsets), Home Videos, Mixed, etc. all live
        // inside the Movies tab as a selectable library.
        pendingLibraryId = library["Id"];
        goToTab(NavTabs.movies);
        return;
    }
  }
}