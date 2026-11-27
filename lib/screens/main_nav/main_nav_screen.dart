import '../../widgets/profile/switch_profile_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../home_screen/home_screen.dart';
import '../movies/movies_screen.dart';
import '../movies/movies_screen.dart';
import '../live_tv/live_tv_screen.dart';
import '../downloads/downloads_screen.dart';
import '../search/search_screen.dart';
import '../favorites/favorites_screen.dart';
import '../../services/parental/parental_models.dart' show LockedArea;
import '../../widgets/parental/parental_lock_gate.dart';
import '../profile/profile_settings_screen.dart';
import '../../player/widgets/mini_player.dart';
import '../../services/jellyfin_services/jellyfin_client.dart';
import '../../services/jellyfin_services/media_service.dart';
import '../../services/jellyfin_services/storage_service.dart';
import '../../services/library_prefetcher.dart';
import '../../virtual/virtual_images.dart';
import '../../services/profile_name_service.dart';
import '../../widgets/common/pressable.dart';
import '../../utils/responsive.dart';

import 'navigation_controller.dart';
import '../../services/cache/nemesis_image_cache.dart';
import '../../widgets/shared/selector_dropdown.dart' show selectorDropdownRouteObserver;
import '../../casting/cast_manager.dart';
import '../../casting/models/cast_session.dart';
import '../../casting/ui/device_picker_sheet.dart';
import '../../casting/ui/connected_session_sheet.dart';
import '../../utils/bottom_clearance.dart';
import '../../widgets/profile/profile_avatar.dart';
import '../../widgets/common/measure_size.dart';

class MainNavScreen extends StatefulWidget {
  const MainNavScreen({super.key});

  @override
  State<MainNavScreen> createState() => _MainNavScreenState();
}

class _MainNavScreenState extends State<MainNavScreen>
    with WidgetsBindingObserver {
  final GlobalKey<NavigatorState> _contentNavigatorKey =
      GlobalKey<NavigatorState>();

  static const Color gold = Color(0xFFD4AF37);
  static const Color navBg = Color(0xFF141414);

  // Matches HomeScreen's own Scaffold background (nemesisBg) exactly —
  // the landscape shell and its glass rail need to share this precise
  // value, not just something close, or the rail reads as sitting on
  // a different surface than the content behind it.
  static const Color screenBg = Color(0xFF161616);

  /// All 8 sidebar destinations, in [NavTabs] order. Search, Favorites,
  /// and Profile used to be pushed on top of the tabs as separate
  /// routes with their own fade transition; they live in the same
  /// IndexedStack as the main tabs now — the IndexedStack matches
  /// children up by position, so each tab's State is preserved once it
  /// has been built. That's what makes switching between visited tabs
  /// instant and stateful.
  ///
  /// A tab is only *built* once it has been shown ([_builtTabs]); until
  /// then its slot holds an empty placeholder. Building all 8 up front
  /// meant every tab's initState, network fetches and timers ran at
  /// launch (competing with Home's first paint), and every one of the 8
  /// trees — visible or not — was rebuilt and re-laid-out on each
  /// rotation and each app-wide change.
  List<Widget> _screens(int currentIndex) {
    _builtTabs.add(currentIndex);

    Widget tab(int index, Widget Function() build) =>
        _builtTabs.contains(index) ? build() : const SizedBox.shrink();

    return [
      tab(NavTabs.home, () => const HomeScreen()),
      tab(NavTabs.movies, () => const MoviesScreen()),
      tab(NavTabs.tvShows, () => const MoviesScreen(mode: "tvshows")),
      tab(
        NavTabs.search,
        () => SearchScreen(onBack: () => _selectTab(NavTabs.home)),
      ),
      // Downloads / Favorites can be locked behind the parental PIN (see
      // ParentalLockGate): asked on every entry, locked again on leaving.
      tab(
        NavTabs.downloads,
        () => const ParentalLockGate(
          area: LockedArea.downloads,
          tabIndex: NavTabs.downloads,
          child: DownloadsScreen(),
        ),
      ),
      tab(NavTabs.liveTv, () => const LiveTvScreen()),
      tab(
        NavTabs.favorites,
        () => const ParentalLockGate(
          area: LockedArea.favorites,
          tabIndex: NavTabs.favorites,
          child: FavoritesScreen(),
        ),
      ),
      tab(NavTabs.profile, () => const ProfileSettingsScreen()),
    ];
  }

  late final VoidCallback _navigationListener;

  String? _username;

  // Tabs that have been shown at least once. Only these are built inside
  // the content IndexedStack (see [_content]); the rest are empty
  // placeholders until first visited, so a tab nobody has opened yet costs
  // nothing — no widget tree, no network calls, no timers, and no
  // rebuild/relayout on rotation. Home (the start tab) is built from the
  // first frame; the current tab is always added in [build] too, so a cold
  // start straight onto another tab (download notification) still works.
  final Set<int> _builtTabs = {NavTabs.home};

  // Tracks the previous lifecycle state so the reconnect below only
  // fires for a genuine return from the background (paused -> resumed),
  // not every transient `inactive` blip (app-switcher gesture, a system
  // dialog, pulling down the notification shade) that also passes
  // through `resumed`. See JellyfinClient.closeIdleConnections's doc
  // comment for why this is needed at all.
  AppLifecycleState? _lastLifecycleState;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // Lets callers outside this Navigator's own subtree (the full-screen
    // player's "Go to Album/Artist", see NavigationController's doc
    // comment on contentNavigatorKey) push onto it too.
    NavigationController.instance.contentNavigatorKey = _contentNavigatorKey;

    _navigationListener = () {
      if (mounted) setState(() {});
    };
    NavigationController.instance.addListener(_navigationListener);

    // Only needed for the landscape sidebar's profile block (the
    // portrait top bar reads its own state independently), but cheap
    // enough to just fetch once up front regardless of orientation.
    StorageService.getUsername().then((username) {
      if (mounted) setState(() => _username = username);
    });
    // Picks up a name changed on the Edit Profile page.
    ProfileNameService.instance.addListener(_onProfileNameChanged);

    // Warms the data behind Movies / Music / Live TV in the background
    // (data only — no widget trees are built) so those tabs open with
    // their content already there. See LibraryPrefetcher.
    LibraryPrefetcher.start();
    // Lets the Movies / TV Shows tabs read their remembered library chip
    // synchronously, so it is already selected when the tab first opens.
    MoviesScreen.warmUp();
  }

  void _onProfileNameChanged() {
    StorageService.getUsername().then((username) {
      if (mounted) setState(() => _username = username);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    ProfileNameService.instance.removeListener(_onProfileNameChanged);
    NavigationController.instance.removeListener(_navigationListener);
    if (identical(NavigationController.instance.contentNavigatorKey,
        _contentNavigatorKey)) {
      NavigationController.instance.contentNavigatorKey = null;
    }

    // Don't leave the app stuck in immersive mode if this screen is
    // ever removed while still in landscape (e.g. hot restart mid-tab).
    super.dispose();
  }

  // Restarts the shared Jellyfin Dio's HTTP connections whenever the app
  // comes back from actually being backgrounded — see
  // JellyfinClient.closeIdleConnections for the full root-cause writeup.
  // `paused` is the reliable "actually left the app" signal; `inactive`
  // also passes through here on the way to resumed but happens on
  // every trivial interruption (system dialog, notification shade,
  // app-switcher preview), where the connections are still perfectly
  // fine and force-closing them would just cost the next request a
  // needless fresh TCP handshake.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    if (state == AppLifecycleState.paused) {
      VirtualImages.flush(); // fire-and-forget; best effort
    }
    if (state == AppLifecycleState.resumed &&
        _lastLifecycleState == AppLifecycleState.paused) {
      JellyfinClient.closeIdleConnections();
    }
    _lastLifecycleState = state;
  }

  /// Switches to any of the 8 sidebar destinations — the five main tabs
  /// plus Search/Favorites/Profile, all indices into the same
  /// IndexedStack (see [_screens]/[_content]) so every one of them
  /// swaps in instantly and keeps its state, exactly the same way.
  void _selectTab(int index) {
    // Movie/music details (and anything else pushed on top of a tab,
    // e.g. Collection details) are real routes on the content
    // navigator — popping back to the root page here clears all of
    // them out in one go before switching tabs.
    _contentNavigatorKey.currentState?.popUntil((route) => route.isFirst);

    NavigationController.instance.goToTab(index);
  }

  /// Single source of truth for what "back" means anywhere under
  /// MainNavScreen — hardware back button, OS back gesture, or a
  /// predictive-back swipe all land here the same way, since tabs are
  /// an IndexedStack with no route of their own. Movie/music/collection
  /// details are real pushed routes on the content navigator now, so
  /// they're handled by the ordinary canPop()/pop() below along with
  /// everything else — no separate overlay bookkeeping needed. Only
  /// when there's truly nowhere left to go — Home tab, nothing pushed
  /// on the content navigator — does this fall through to asking
  /// whether to exit.
  Future<void> _handleBackPressed() async {
    // A modal sheet shown with useRootNavigator: true (song options,
    // playlist picker, program details, etc.) lands on this same root
    // Navigator, above MainNavScreen's own route. Without this check,
    // the PopScope below swallows every back event unconditionally and
    // routes it straight into the tab/content-navigator logic further
    // down — so pressing back while one of those sheets is open used
    // to navigate the page underneath it instead of just closing the
    // sheet. canPop() here reports true exactly when one of these
    // sheets is the topmost route, so popping it just dismisses the
    // sheet with its normal slide-down animation, same as tapping
    // outside it would.
    final rootNavigator = Navigator.of(context, rootNavigator: true);
    if (rootNavigator.canPop()) {
      rootNavigator.pop();
      return;
    }

    final controller = NavigationController.instance;

    final contentNavigator = _contentNavigatorKey.currentState;
    if (contentNavigator != null && contentNavigator.canPop()) {
      contentNavigator.pop();
      return;
    }

    if (controller.tabIndex != NavTabs.home) {
      controller.goToTab(NavTabs.home);
      return;
    }

    final shouldExit = await _confirmExit();
    if (shouldExit) {
      SystemNavigator.pop();
    }
  }

  Future<bool> _confirmExit() async {
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: navBg,
        title: const Text(
          "Exit app?",
          style: TextStyle(color: Colors.white),
        ),
        content: const Text(
          "Are you sure you want to exit?",
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text("Cancel"),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text(
              "Exit",
              style: TextStyle(color: gold),
            ),
          ),
        ],
      ),
    );

    return result ?? false;
  }

  static const List<_TabSpec> _tabs = [
    _TabSpec(Icons.home_outlined, Icons.home, "Home"),
    _TabSpec(Icons.movie_outlined, Icons.movie, "Movies"),
    _TabSpec(Icons.tv_outlined, Icons.tv, "TV Shows"),
    _TabSpec(Icons.search, Icons.search, "Search"),
    _TabSpec(Icons.download_outlined, Icons.download, "Downloads"),
  ];

  Widget _content(int currentIndex) {
    // Content routes (tabs, plus anything pushed on top of them like
    // movie/music/collection details) stay inside this single
    // navigation shell so the rail/bottom nav + mini player remain
    // visible underneath detail screens.
    return Navigator(
      key: _contentNavigatorKey,
      // Movies/Music/TV Guide/All Channels (and anything else pushed
      // on top of a tab) all live under *this* Navigator, not the
      // root MaterialApp one — so this is where SelectorDropdown's
      // RouteObserver needs to be registered for its didPushNext hook
      // to fire and close a dropdown left open when a new screen is
      // pushed over it.
      observers: [selectorDropdownRouteObserver],
      pages: [
        MaterialPage<void>(
          key: const ValueKey('main-tabs'),
          child: IndexedStack(
            index: currentIndex,
            children: _screens(currentIndex),
          ),
        ),
      ],
      onPopPage: (route, result) => route.didPop(result),
    );
  }

  /// Bottom bar content for portrait: full tab bar + mini player.
  /// Landscape's equivalent slot ([_buildLandscapeBottomBar]) only ever
  /// holds the mini player, since destinations live in the rail
  /// instead. Both are swapped into the *same* bottomNavigationBar slot
  /// on the *same* Scaffold — see [build] for why that matters.
  Widget _buildPortraitBottomBar(BuildContext context, int currentIndex) {
    // The portrait bar only has the five main tabs. Search / Favorites
    // / Profile (indices 5-7) live in the landscape rail instead, so
    // rotating to portrait while one of them is showing hands this bar
    // an index past the end of its items — BottomNavigationBar asserts
    // on that (red screen in debug, grey screen in release). While one
    // of those is showing, keep the bar valid but with nothing
    // highlighted: same colour and outline icon for every item, and
    // the label size unselected labels use.
    final onBarTab = currentIndex >= 0 && currentIndex < _tabs.length;

    return Column(
      key: const ValueKey('portrait-bottom-bar'),
      mainAxisSize: MainAxisSize.min,
      children: [
        // Notification tray already shows the download progress/queue
        // (see DownloadNotificationService), so the in-app Liquid Glass
        // pill duplicated that same information — removed to avoid
        // showing the same progress twice.
        const MiniPlayer(),

        // Transparent, gradient-scrimmed bar (matches the reference
        // look): no blur, no solid fill or top border — just a
        // transparent-to-black gradient so tab content is fully
        // visible scrolling up behind the icons, fading to dark
        // right where the icons/labels sit so they stay legible.
        Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.transparent,
                Color(0xE0000000),
                Color(0xFA000000),
              ],
              stops: [0.0, 0.55, 1.0],
            ),
          ),
          // NAV-HEIGHT FIX: no manual bottom Padding here anymore.
          // `BottomNavigationBar` already reserves `MediaQuery.of
          // (context).padding.bottom` itself internally (it's grown its
          // own height by that inset since the iPhone-X-safe-area patch
          // landed in the framework, and Android's gesture-nav inset
          // goes through the exact same `padding.bottom` value) — so
          // wrapping it in another Padding using that same value, like
          // this used to, applied the gesture-bar inset twice. That's
          // what was actually reading as "the nav sits higher than other
          // apps'": the icon row was floating a full inset's-height
          // above where it needed to be, leaving a visible gap of empty
          // gradient between the labels and the system gesture bar
          // instead of sitting flush just above it like every other
          // app's bottom nav. Removing the outer Padding lets
          // BottomNavigationBar reserve that space exactly once, in its
          // own internal layout — the gradient Container above still
          // paints all the way down through that reserved space either
          // way, so the background still extends behind the gesture bar
          // exactly as before, just without the doubled gap on top of
          // it.
          child: Theme(
            data: Theme.of(context).copyWith(
              splashFactory: NoSplash.splashFactory,
              splashColor: Colors.transparent,
              highlightColor: Colors.transparent,
            ),
            child: BottomNavigationBar(
              currentIndex: onBarTab ? currentIndex : 0,
              onTap: _selectTab,
              type: BottomNavigationBarType.fixed,
              backgroundColor: Colors.transparent,
              selectedItemColor: onBarTab ? gold : Colors.white54,
              unselectedItemColor: Colors.white54,
              selectedFontSize: onBarTab ? 14.0 : 12.0,
              unselectedFontSize: 12.0,
              showUnselectedLabels: true,
              elevation: 0,
              items: [
                for (final tab in _tabs)
                  BottomNavigationBarItem(
                    icon: Icon(tab.icon),
                    activeIcon: Icon(onBarTab ? tab.activeIcon : tab.icon),
                    label: tab.label,
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// Landscape's bottomNavigationBar slot — just the mini player, full
  /// width, since destinations moved to the rail. See
  /// [_buildPortraitBottomBar].
  Widget _buildLandscapeBottomBar() {
    // Same fix as above: Padding + aspect-scoped MediaQuery.paddingOf
    // instead of SafeArea, so the mini player doesn't rebuild on every
    // keyboard-animation frame.
    return Padding(
      key: const ValueKey('landscape-bottom-bar'),
      padding: EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom),
      child: const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Notification tray already covers download progress — see
          // the matching removal in _buildPortraitBottomBar above.
          MiniPlayer(),
        ],
      ),
    );
  }

  /// The glass sidebar itself — logo, tab destinations, search,
  /// favorites, profile. Broken out of [build] so it can be dropped
  /// into a constant-shaped [Positioned] slot that's always present in
  /// the tree (just faded/cross-faded, never mounted/unmounted), the
  /// same reasoning as the content Navigator below.
  Widget _buildRail(
    BuildContext context,
    int currentIndex,
    double topInset,
    double bottomInset,
  ) {
    final content = _buildRailContent(context, currentIndex, topInset, bottomInset);

    // A flat fill, not a BackdropFilter blur. In landscape the content
    // area is padded in by the rail's width (see build()), so nothing
    // ever scrolls *behind* the rail — the only thing a blur could see is
    // the flat screenBg behind it, which blurs to... the same flat
    // screenBg. The blur therefore changed nothing visible, but it forces
    // an extra off-screen render pass of the whole rail strip on every
    // single frame the screen repaints, i.e. all through every scroll in
    // landscape. 0.97 matches the fill the rail used while rotating, when
    // the content is briefly sliding under it.
    return ClipRect(
      key: const ValueKey('landscape-rail'),
      child: Container(
        width: Responsive.railWidth,
        color: screenBg.withValues(alpha: 0.97),
        child: content,
      ),
    );
  }

  /// The rail's actual logo/tabs/search/favorites/profile column,
  /// wrapped by [_buildRail].
  Widget _buildRailContent(
    BuildContext context,
    int currentIndex,
    double topInset,
    double bottomInset,
  ) {
    return Theme(
      data: Theme.of(context).copyWith(
        splashFactory: NoSplash.splashFactory,
        splashColor: Colors.transparent,
        highlightColor: Colors.transparent,
      ),
      child: Column(
        children: [
          SizedBox(height: 16 + topInset),

          Image.asset(
            'assets/images/nemesis_logo.png',
            width: 30,
            height: 30,
            fit: BoxFit.contain,
          ),

          const SizedBox(height: 20),

          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 4),
              children: [
                for (var i = 0; i < _tabs.length; i++)
                  _RailActionButton(
                    icon: currentIndex == i
                        ? _tabs[i].activeIcon
                        : _tabs[i].icon,
                    label: _tabs[i].label,
                    selected: currentIndex == i,
                    onTap: () => _selectTab(i),
                  ),

                const SizedBox(height: 8),
                _RailActionButton(
                  icon: currentIndex == NavTabs.favorites
                      ? Icons.favorite
                      : Icons.favorite_border,
                  label: "Favorites",
                  selected: currentIndex == NavTabs.favorites,
                  onTap: () => _selectTab(NavTabs.favorites),
                ),
                const SizedBox(height: 8),
                // Global Cast entry — the landscape counterpart to
                // HomeScreen's portrait-only top-bar Cast button (see
                // HomeScreen._buildTopBar's own comment on why it skips
                // this in landscape). Not a NavTabs destination — it
                // opens the device picker/connected-session sheet
                // in-place over whatever tab is already showing, the
                // same "unified Cast control" every other surface uses.
                const _RailCastButton(),
              ],
            ),
          ),

          const SizedBox(height: 12),

          Pressable(
            // Same _selectTab path as every other rail
            // item now, so Profile switches instantly and
            // keeps its state exactly like the rest of
            // the 8 destinations.
            onTap: () => _selectTab(NavTabs.profile),
            // Long-press = quick profile switch.
            onLongPress: () => SwitchProfileSheet.show(context),
            child: Column(
              children: [
                _buildRailProfileAvatar(
                  selected: currentIndex == NavTabs.profile,
                ),
                const SizedBox(height: 6),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                  ),
                  child: Text(
                    _username ?? "Profile",
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: currentIndex == NavTabs.profile
                          ? gold
                          : Colors.white70,
                      fontSize: 10,
                      fontWeight: currentIndex == NavTabs.profile
                          ? FontWeight.w600
                          : FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(height: 14 + bottomInset),
        ],
      ),
    );
  }

  /// Same avatar-with-fallback logic as HomeScreen's own profile icon,
  /// just sized for the sidebar instead of the top bar. Takes the same
  /// `selected` treatment as [_RailActionButton] — a gold ring — so
  /// Profile visually confirms it's the active destination exactly the
  /// same way every other rail item does.
  ///
  /// The ring sits in its own reserved gap around the photo (rather
  /// than a border drawn tight against the image edge) so it reads as
  /// a distinct surrounding boundary — the same "ring/circle boundary"
  /// treatment SortChips uses for its selected state — instead of
  /// blending into a soft highlight against a bright avatar photo. The
  /// gap is always reserved, selected or not, and only the ring's
  /// color animates between transparent and gold, so selecting/
  /// deselecting Profile never nudges the avatar's size or the
  /// "Profile" label underneath it.
  Widget _buildRailProfileAvatar({required bool selected}) {
    final userId = JellyfinClient.userId;
    final imageUrl =
        userId.isNotEmpty ? MediaService.getUserImageUrl(userId, maxWidth: 76) : null;

    const avatarSize = 36.0;
    const ringWidth = 2.0;
    const ringGap = 2.5;
    const outerSize = avatarSize + 2 * (ringWidth + ringGap);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      width: outerSize,
      height: outerSize,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: selected ? gold : Colors.transparent,
          width: ringWidth,
        ),
      ),
      child: Container(
        width: avatarSize,
        height: avatarSize,
        clipBehavior: Clip.antiAlias,
        decoration: const BoxDecoration(
          color: Colors.black45,
          shape: BoxShape.circle,
        ),
        child: ProfileAvatarBody(
          fallback: imageUrl == null
              ? const Icon(Icons.person_outline, color: Colors.white, size: 18)
              : CachedNetworkImage(
                  cacheManager: NemesisImageCache.instance,
                  imageUrl: imageUrl,
                  fit: BoxFit.cover,
                  placeholder: (context, url) => const Icon(
                      Icons.person_outline,
                      color: Colors.white,
                      size: 18),
                  errorWidget: (context, url, error) => const Icon(
                      Icons.person_outline,
                      color: Colors.white,
                      size: 18),
                ),
        ),
      ),
    );
  }

  /// Root shell. This used to pick between two *completely separate*
  /// Scaffold trees (_buildPortraitScaffold / _buildLandscapeScaffold)
  /// depending on orientation — different depth, different ancestor
  /// types, different everything. The GlobalKey'd content Navigator
  /// (see [_content]) lived inside both, so flipping orientation forced
  /// Flutter to tear it out of one structurally different tree and
  /// reattach it inside another, all within a single rebuild. That
  /// reparenting — not the OS rotation animation — is what produced the
  /// stuck, squished-into-a-strip frame on rotation: neither
  /// ROTATION_ANIMATION_SEAMLESS nor JUMPCUT touched it because the OS
  /// transition was never the problem.
  ///
  /// This version keeps exactly one tree shape, always: Scaffold ->
  /// SafeArea -> LandscapeContentWidth -> Stack ->
  /// Positioned.fill -> AnimatedPadding -> inner Scaffold -> body ->
  /// _content(...). Rotation now only ever changes *values* inside that
  /// fixed shape (a padding amount, a bar's height/content, a rail's
  /// opacity) via implicit animations — nothing is ever added, removed,
  /// or moved to a different ancestor, so there's no reparenting left
  /// to glitch.
  @override
  Widget build(BuildContext context) {
    final controller = NavigationController.instance;
    final currentIndex = controller.tabIndex;
    final isLandscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    final viewPadding = MediaQuery.paddingOf(context);
    final topInset = viewPadding.top;
    final bottomInset = viewPadding.bottom;

    return PopScope(
      canPop: false,
      onPopInvoked: (didPop) {
        if (didPop) return;
        _handleBackPressed();
      },
      child: Scaffold(
        // Always screenBg now (previously portrait left this unset and
        // relied on content covering the screen immediately). Harmless
        // in portrait — content still covers it the same way — and
        // means the rail's landing strip never needs its own separate
        // background color guess.
        backgroundColor: screenBg,
        // false — this Scaffold (and the nav-shell one nested inside it
        // below) wrap the ENTIRE chrome: rail, bottom bar, and content
        // all live inside the same Stack/body they'd otherwise resize.
        // A Scaffold claims the keyboard inset for itself by zeroing
        // MediaQuery.viewInsets.bottom for everything below it — so
        // with this left at the default `true`, whichever screen is
        // currently pushed on the content Navigator (e.g. Search, with
        // its own text field) never actually saw the keyboard inset
        // itself; this outermost Scaffold ate it first and resized its
        // whole body instead. That's why the keyboard opening used to
        // drag the rail's profile button up in landscape and the whole
        // bottom nav bar up in portrait, rather than just overlaying
        // the content underneath — the entire chrome was shrinking as
        // a unit, the same way it would if the rail or nav bar
        // themselves had a text field in them.
        //
        // Turning it off here (and below) lets the inset pass through
        // untouched to whichever screen is actually showing a
        // keyboard, so that screen's own Scaffold — SearchScreen's,
        // same as everywhere else in the app — is the one that
        // resizes, and only its own body does. The rail/nav bar/rest
        // of the shell stay completely still, with the keyboard
        // simply overlaying them, same as every other keyboard popup
        // in the app already behaves.
        resizeToAvoidBottomInset: false,
        // Was a SafeArea here (top/bottom false, left/right: isLandscape).
        // SafeArea's own build() calls the *unscoped* `MediaQuery.of(context)`
        // internally, which subscribes it to every field of MediaQueryData —
        // not just padding. That includes `viewInsets.bottom`, which the
        // framework updates on every single frame while the keyboard is
        // sliding in or out. Each of those frames marked this SafeArea
        // dirty and forced it to rebuild its *entire* child — the rail,
        // and every tab in the content IndexedStack — from scratch, ~60
        // times a second, purely to reproduce the exact same left/right
        // padding it already had (the keyboard doesn't change device
        // padding at all). That's what was surfacing as the rail's
        // profile tab "bumping" in landscape and the keyboard itself
        // feeling sluggish in both orientations: the keyboard's own slide
        // animation was competing every frame with a full rebuild of the
        // blurred glass rail plus whichever heavy, image-laden tab
        // happened to be mounted underneath it.
        //
        // A plain Padding using the *aspect-scoped* `MediaQuery.paddingOf`
        // gets the identical left/right values but only rebuilds when
        // device padding itself actually changes (rotation, notch/gesture
        // area changes) — never on keyboard insets — so this subtree is
        // completely inert while the keyboard animates.
        body: Padding(
          padding: EdgeInsets.only(
            left: isLandscape ? viewPadding.left : 0,
            right: isLandscape ? viewPadding.right : 0,
          ),
          // Was a LayoutBuilder here. LandscapeContentWidth only ever
          // needs a width *number* — it's a plain InheritedWidget, not
          // anything layout-dependent — so it doesn't need real
          // constraints. LayoutBuilder rebuilds its child through a
          // separate, layout-phase BuildOwner.buildScope rather than
          // the normal widget build pass, and mounting a GlobalKey'd,
          // stateful widget (the content Navigator below, keyed by
          // _contentNavigatorKey) inside that scope is not safe: on
          // every resize (window resize on desktop, every rotation)
          // the framework tried to re-mount/re-attach the same
          // Navigator/observer through that scope before the previous
          // one had cleanly torn down, producing the
          // 'observer.navigator == null' and '_elements.contains
          // (element)' assertions. Computing the width directly from
          // MediaQuery keeps this entire subtree — Navigator included
          // — inside the normal build pass, where GlobalKeys are
          // handled correctly.
          child: Builder(
            builder: (context) {
              final availableWidth = MediaQuery.sizeOf(context).width -
                  (isLandscape ? viewPadding.left + viewPadding.right : 0);
              return LandscapeContentWidth(
                width: availableWidth,
                child: Stack(
                  children: [
                    // The content Navigator's permanent slot. Only
                    // `padding.left` changes on rotation, tweened over
                    // 320ms instead of snapping — see the class-level
                    // doc comment above for why this fixed position is
                    // the actual fix, not just a nicety.
                    Positioned.fill(
                      child: AnimatedPadding(
                        duration: const Duration(milliseconds: 320),
                        curve: Curves.easeInOutCubic,
                        padding: EdgeInsets.only(
                          left: isLandscape ? Responsive.railWidth : 0,
                        ),
                        //
                        // NOTE: this used to be a Scaffold with
                        // extendBody: true (body = the content Navigator,
                        // bottomNavigationBar = the bar below). Scaffold
                        // internally wraps `body` in its own LayoutBuilder
                        // whenever extendBody is true (to compute how far
                        // the body should extend under the bar) — which
                        // silently reintroduced the exact
                        // '_elements.contains(element)' /
                        // 'observer.navigator == null' GlobalKey
                        // reactivation crash documented above for the
                        // (now-removed) explicit LayoutBuilder: the
                        // GlobalKey'd content Navigator (_contentNavigatorKey)
                        // was being built inside Scaffold's own
                        // layout-time build pass instead of the normal
                        // top-down one. Confirmed via the Windows debug
                        // stack trace: the assertion fires inside
                        // _RenderLayoutBuilder.performLayout, invoked
                        // from _ScaffoldLayout.performLayout — Scaffold's
                        // own internals, not anything we wrote directly.
                        //
                        // A plain Stack gives the identical visual —
                        // content fills the whole slot, the bar sits on
                        // top of it at the bottom, both transparent/
                        // scrimmed so content shows through underneath —
                        // without Scaffold ever getting a chance to wrap
                        // the Navigator in a LayoutBuilder. No keyboard
                        // handling is lost either: this Stack doesn't
                        // participate in Scaffold's resize-avoidance
                        // machinery at all, same net effect as the
                        // resizeToAvoidBottomInset: false this replaced.
                        child: Stack(
                          children: [
                            // The outer Scaffold above already consumed
                            // `viewPadding.left/right` once, via the
                            // Padding wrapping this whole subtree,
                            // to make room for the rail. Every individual
                            // tab (Movies, Music, Downloads, Search, Live
                            // TV, and Favorites' AppBar) also wraps itself
                            // in a SafeArea for its own reasons — good on
                            // its own, since screens need to be safe-area
                            // aware when previewed/tested outside this
                            // shell too — but MediaQuery.paddingOf is
                            // unscoped by that outer Padding, so those
                            // per-tab SafeAreas were reading the exact
                            // same left/right device padding again and
                            // re-adding it on top, shoving their content
                            // an extra notch/cutout-width further right
                            // than Home (which never wraps itself in a
                            // SafeArea) sits beside the rail. Zeroing
                            // padding.left/right here — exactly the
                            // amount already spent above — means any
                            // SafeArea further down reads "nothing left
                            // to account for" and lines up flush with
                            // Home instead of double-counting it.
                            Positioned.fill(
                              child: MediaQuery.removePadding(
                                context: context,
                                removeLeft: isLandscape,
                                removeRight: isLandscape,
                                child: _content(currentIndex),
                              ),
                            ),
                            // AnimatedSize tweens the bar's own height as
                            // it swaps between the full portrait tab bar
                            // and the landscape mini-player-only strip;
                            // AnimatedSwitcher crossfades the content
                            // inside that resizing box. Together they're
                            // the same "glide instead of jump-cut" idea
                            // as the home hero, applied to the nav chrome.
                            Positioned(
                              left: 0,
                              right: 0,
                              bottom: 0,
                              child: AnimatedSize(
                                duration: const Duration(milliseconds: 280),
                                curve: Curves.easeInOutCubic,
                                alignment: Alignment.topCenter,
                                // Publishes this bar's real, laid-out
                                // height to BottomClearance on every
                                // frame it changes — content-scale
                                // (larger text/display-size settings),
                                // mini player show/hide, and the
                                // portrait<->landscape swap all change
                                // this bar's actual height, and every
                                // other screen's reserved bottom
                                // padding needs to track the real
                                // number instead of a fixed guess (see
                                // BottomClearance's own doc comment on
                                // tabBarHeight/miniPlayerHeight for why
                                // the guess was wrong on a device with
                                // a larger text scale).
                                child: MeasureSize(
                                  onChange: (size) {
                                    BottomClearance.reportChromeHeight(
                                      size.height,
                                      isLandscape: isLandscape,
                                    );
                                  },
                                  child: AnimatedSwitcher(
                                    duration: const Duration(milliseconds: 200),
                                    switchInCurve: Curves.easeOut,
                                    switchOutCurve: Curves.easeIn,
                                    child: isLandscape
                                        ? _buildLandscapeBottomBar()
                                        : _buildPortraitBottomBar(
                                            context,
                                            currentIndex,
                                          ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),

                    // Rail's own slot is always present at a constant
                    // position/width; only its content crossfades in
                    // and out (and isn't hit-testable while hidden).
                    // This one isn't load-bearing for the reparenting
                    // fix — the rail never held a GlobalKey — it's just
                    // consistent with the same "animate values, not
                    // tree shape" approach for a smoother look.
                    Positioned(
                      left: 0,
                      top: 0,
                      bottom: 0,
                      width: Responsive.railWidth,
                      child: IgnorePointer(
                        ignoring: !isLandscape,
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 260),
                          child: isLandscape
                              ? _buildRail(
                                  context,
                                  currentIndex,
                                  topInset,
                                  bottomInset,
                                )
                              : const SizedBox.shrink(
                                  key: ValueKey('rail-hidden'),
                                ),
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _TabSpec {
  final IconData icon;
  final IconData activeIcon;
  final String label;

  const _TabSpec(this.icon, this.activeIcon, this.label);
}

/// A single icon+label item in the landscape sidebar — used for both
/// the plain actions (Search, Favorites) and the main tab destinations,
/// so all of them share the same look/spacing/tap target.
class _RailActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool selected;

  const _RailActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.selected = false,
  });

  static const Color _gold = _MainNavScreenState.gold;

  @override
  Widget build(BuildContext context) {
    final color = selected ? _gold : Colors.white54;

    return Pressable(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 22),
            const SizedBox(height: 4),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: color,
                fontSize: 10.5,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The landscape sidebar's Cast entry — same [Pressable] + icon/label
/// shape as [_RailActionButton], but reflects live
/// [CastManager.instance] state (gold + "connected" glyph while
/// casting) instead of a fixed icon, and opens the device picker /
/// connected-session sheet directly rather than switching tabs.
class _RailCastButton extends StatelessWidget {
  const _RailCastButton();

  static const Color _gold = _MainNavScreenState.gold;

  Future<void> _handleTap(BuildContext context) async {
    if (CastManager.instance.isCasting) {
      await showConnectedCastSheet(context);
    } else {
      await showCastDevicePicker(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<CastSession?>(
      valueListenable: CastManager.instance.activeSession,
      builder: (context, session, __) {
        final connected = session?.isConnected ?? false;
        final color = connected ? _gold : Colors.white54;

        return Pressable(
          onTap: () => _handleTap(context),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  connected ? Icons.cast_connected_rounded : Icons.cast_rounded,
                  color: color,
                  size: 22,
                ),
                const SizedBox(height: 4),
                Text(
                  "Cast",
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: color,
                    fontSize: 10.5,
                    fontWeight: connected ? FontWeight.w600 : FontWeight.w400,
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
