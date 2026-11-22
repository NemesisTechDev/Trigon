import '../../widgets/profile/switch_profile_sheet.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import '../../services/parental/parental_controls.dart';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:google_fonts/google_fonts.dart';

import '../main_nav/navigation_controller.dart';
import '../favorites/favorites_screen.dart';
import '../search/search_screen.dart';
import '../music/music_detail_screen.dart';
import '../movie_details/movie_details_screen.dart';
import '../movies/widgets/movie_card.dart';
import '../../services/jellyfin_services/jellyfin_client.dart';
import '../../services/jellyfin_services/media_service.dart';
import '../../services/jellyfin_services/storage_service.dart';
import '../../utils/app_fonts.dart';
import '../../utils/responsive.dart';
import '../profile/profile_settings_screen.dart';
import '../../widgets/music/album_card.dart';
import '../../player/playback_service.dart';
import '../../player/player_manager.dart';
import '../../player/screens/player_navigation.dart';
import '../../embed/embed_player_screen.dart' show EmbedPlayerScreen;
import '../../library/watch_history_service.dart';
import '../../widgets/common/pressable.dart';
import '../../widgets/common/auto_logo.dart';
import '../../widgets/common/landscape_art_image.dart';
import '../../widgets/common/see_all_controls.dart';
import '../../widgets/common/resistive_refresh.dart';
import '../../widgets/common/rating_badges.dart';
import '../../services/ratings_service.dart';
import '../../virtual/virtual_catalog.dart';
import '../../services/parental/parental_models.dart' show LockedArea;
import '../../widgets/parental/parental_lock_gate.dart';
import '../../services/cache/nemesis_image_cache.dart';
import '../../casting/ui/cast_button.dart';
import '../../utils/bottom_clearance.dart';
import '../../widgets/profile/profile_avatar.dart';
import '../../widgets/shared/nemesis_bottom_sheet.dart';
import '../../widgets/common/dustbin_icon.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<dynamic> libraries = [];
  List<dynamic> resumeItems = [];

  // Continue Watching live-refresh: debounce timer + a sequence number so a
  // slow, older fetch can never overwrite a newer one.
  Timer? _resumeDebounce;
  int _resumeSeq = 0;
  List<dynamic> featuredItems = [];
  Map<String, List<dynamic>> latestByLibrary = {};

  // NAMESIS PRIME: the two "trending" rows that sit between Continue
  // Watching and the per-library rows.
  List<dynamic> trendingMovies = [];
  List<dynamic> trendingShows = [];

  // Library IDs whose "recently added" row is still being fetched. Lets
  // each section render independently — as a skeleton while pending, as
  // real cards once its own fetch resolves — instead of every row on the
  // page waiting on the single slowest library.
  Set<String> _pendingLatestLibraries = {};

  // A ValueNotifier (not a plain field + setState) so hero autoplay
  // ticks only rebuild the hero subtree — see the ValueListenableBuilder
  // wrapped around _buildHeroCarousel in build(). Previously this was a
  // setState'd field, which meant every 6-second autoplay tick (and every
  // async per-library "recently added" load completing at launch, which
  // also setState's) rebuilt the *entire* HomeScreen — hero, library row,
  // every Recently Added section — instead of just the hero. That's
  // unnecessary main-thread work landing on top of whatever the user is
  // doing, most visibly as stutter right after launch (several of these
  // async loads land in quick succession) and around the hero (autoplay).
  final ValueNotifier<int> _heroIndexNotifier = ValueNotifier<int>(0);
  Timer? _heroTimer;

  // +1 when the hero is advancing "forward" (autoplay tick, or a manual
  // swipe from right-to-left), -1 when a manual swipe goes the other way
  // (left-to-right, i.e. "previous"). Read by the backdrop's
  // AnimatedSwitcher transitionBuilder (_buildHeroCarouselPortrait /
  // _buildHeroCarouselLandscape) to decide which side the incoming image
  // slides in from and which side the outgoing one slides out toward —
  // see the transitionBuilder comments there for how one direction value
  // produces opposite motion for the entering vs. leaving child.
  int _heroDirection = 1;

  // True for as long as the user is pressing and holding the hero
  // carousel. Checked by the autoplay timer below so the current item
  // stays on screen for the whole hold instead of autoplay swapping it
  // out mid-press — cleared on lift/cancel in the GestureDetector wired
  // up in build().
  bool _heroHeld = false;

  // Drives the hero backdrop's parallax lag + zoom (see
  // _buildParallaxBackdrop). Kept as its own ScrollController (rather
  // than reading CustomScrollView's default PrimaryScrollController)
  // so we have an explicit listenable to attach to, and as a separate
  // ValueNotifier<double> rather than calling setState from the scroll
  // listener — a ValueListenableBuilder scoped to just the backdrop
  // transform means scrolling only repaints that one small subtree,
  // not the whole HomeScreen, on every frame.
  final ScrollController _scrollController = ScrollController();
  final ValueNotifier<double> _heroScrollOffset = ValueNotifier<double>(0);

  bool loading = true;
  String? error;

  static const Color gold = Color(0xFFD4AF37);
  static const Color nemesisBg = Color(0xFF161616);
  // Matches the gold used for pull-to-refresh on Favorites/Filmography/Movies.
  static const Color _gold = Color(0xffD4AF37);
  static const Color placeholderBg = Color(0xFF242424);

  // Tuning for the hero backdrop's scroll-tied motion (see
  // _buildParallaxBackdrop): the backdrop only travels at
  // _heroParallaxFactor of the actual scroll distance — i.e. it lags
  // behind the logo/metadata/buttons (which scroll normally at 1:1) —
  // while gaining up to _heroParallaxMaxZoom extra scale the further
  // it's scrolled through, and losing that zoom again as it scrolls
  // back. Both are plain functions of the current scroll offset, so
  // scrolling back up reverses them automatically — no separate
  // "scrolling up" code path needed.
  static const double _heroParallaxFactor = 0.5;
  static const double _heroParallaxMaxZoom = 0.08;

  // How far the landscape hero's base background fill bleeds past its
  // own bottom edge — see the Positioned/Clip.none comment in
  // _buildHeroCarouselLandscape for why.
  static const double _heroSeamOverscan = 6.0;

  // How far short of its own box the parallax backdrop's clip stops,
  // at the bottom edge — see _buildParallaxBackdrop for why. Kept
  // comfortably inside the zone _buildHeroGradients/
  // _buildHeroGradientsLandscape already paint fully opaque nemesisBg
  // over (their last stop starts at 94% of heroHeight), so trimming
  // this sliver of image never removes anything that was visible
  // anyway.
  static const double _heroClipBottomInset = 4.0;

  // Landscape only: how far the backdrop image's clip stops short of
  // its own LEFT edge. The landscape backdrop starts at 14% of the
  // content width, which on larger phones lands on a fractional
  // physical pixel; the image's edge column and the gradient's edge
  // column then cover that pixel by different amounts, leaving a thin
  // vertical hairline of raw image colour where the image should have
  // faded fully into nemesisBg. Trimming the image a few px in, and
  // holding the gradient fully opaque past that (see
  // _buildHeroGradientsLandscape), puts the edge inside solid
  // background so no sliver of image can ever show there.
  static const double _heroClipLeftInset = 6.0;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(() {
      _heroScrollOffset.value = _scrollController.offset;
    });
    // Continue Watching follows the watch history: any change (progress
    // saved, title removed, episode finished) and every player exit
    // refreshes the row.
    WatchHistoryService.instance.continueWatching
        .addListener(_onWatchHistoryChanged);
    PlayerNavigation.closeSignal.addListener(_onPlayerClosed);
    _bootstrap();
  }

  /// Paints instantly from yesterday's cached payload (if any) while a
  /// fresh copy loads underneath, instead of showing a blank spinner on
  /// every cold start. Falls back to the normal loading state when
  /// there's nothing cached yet (first-ever launch).
  Future<void> _bootstrap() async {
    String? cached;
    try {
      cached = await StorageService.getHomeCache();
    } catch (_) {
      cached = null;
    }
    // Parental Controls: the saved payload may predate the current rules,
    // so it is never painted while they are on.
    if (ParentalControls.instance.isActive) cached = null;

    if (cached != null && mounted) {
      try {
        final decoded = jsonDecode(cached) as Map<String, dynamic>;
        setState(() {
          libraries = List<dynamic>.from(decoded["libraries"] ?? [])
              .where((l) =>
                  l is Map && VirtualCatalog.isHomeLibrary(l["Id"]?.toString()))
              .toList();
          resumeItems = List<dynamic>.from(decoded["resumeItems"] ?? []);
          featuredItems = List<dynamic>.from(decoded["featuredItems"] ?? []);
          latestByLibrary = {
            for (final entry
                in (decoded["latestByLibrary"] as Map<String, dynamic>? ?? {})
                    .entries)
              entry.key: List<dynamic>.from(entry.value ?? []),
          };
          trendingMovies = List<dynamic>.from(decoded["trendingMovies"] ?? []);
          trendingShows = List<dynamic>.from(decoded["trendingShows"] ?? []);
          loading = false;
        });
        _startHeroAutoPlay();
        _precacheHeroBackdrops();
        unawaited(RatingsService.prefetchAll(featuredItems));
      } catch (_) {
        // Corrupt/old-shape cache — ignore and fall through to a normal load.
      }
    }

    // Always refresh from the network. If we already painted from cache
    // above, do this silently (no spinner, no flicker).
    _loadData(silent: cached != null);
  }

  @override
  void dispose() {
    _resumeDebounce?.cancel();
    WatchHistoryService.instance.continueWatching
        .removeListener(_onWatchHistoryChanged);
    PlayerNavigation.closeSignal.removeListener(_onPlayerClosed);
    _heroTimer?.cancel();
    _scrollController.dispose();
    _heroScrollOffset.dispose();
    _heroIndexNotifier.dispose();
    super.dispose();
  }

  void _startHeroAutoPlay() {
    _heroTimer?.cancel();
    if (featuredItems.length <= 1) return;
    _heroTimer = Timer.periodic(const Duration(seconds: 6), (_) {
      if (!mounted) return;
      // Autoplay is the single worst freeze cluster in the scroll
      // recording (six drops in under a second, up to 277ms) — every
      // one landed on the user scrolling back up to the hero at almost
      // exactly the moment autoplay crossfaded to a new item. Skipping
      // the tick while the hero isn't at rest (offset > 0 means it's
      // either fully or partially scrolled away) means a crossfade can
      // never fire mid-scroll or land right as the hero comes back into
      // view — it only ever advances while the user is actually looking
      // at it and not actively scrolling. Nothing is lost: a tick that's
      // skipped here just means the current item stays up a little
      // longer, not that a rotation is dropped.
      if (_heroScrollOffset.value > 0) return;
      // Same idea while Home itself isn't showing (another tab selected,
      // or a detail screen pushed over it): the hero is invisible, and
      // swapping it kicks off an image load and rebuild right in the
      // middle of whatever the user is doing on the other screen — most
      // noticeably the push/pop transition animation.
      if (NavigationController.instance.tabIndex != NavTabs.home ||
          !(ModalRoute.of(context)?.isCurrent ?? true)) {
        return;
      }
      // Also skip while the user is actively pressing/holding the hero
      // — same idea as the scroll-offset check above, just for a touch
      // hold instead of a scroll: don't let the current item get swapped
      // out from under a press.
      if (_heroHeld) return;
      _heroDirection = 1;
      _heroIndexNotifier.value =
          (_heroIndexNotifier.value + 1) % featuredItems.length;
    });
  }

  /// Steps the hero forward (`delta == 1`) or backward (`delta == -1`)
  /// by one item, wrapping at either end, and records the direction so
  /// the backdrop's crossfade slides the right way. Also restarts the
  /// autoplay timer so a manual swipe gets the full 6 seconds before
  /// autoplay would otherwise advance again, rather than potentially
  /// being immediately undone by an autoplay tick already in flight.
  void _stepHero(int delta) {
    final length = featuredItems.length;
    if (length == 0) return;
    _heroDirection = delta.sign == 0 ? 1 : delta.sign;
    _heroIndexNotifier.value =
        ((_heroIndexNotifier.value + delta) % length + length) % length;
    _startHeroAutoPlay();
  }

  /// Interprets a completed horizontal drag on the hero as a swipe to
  /// the previous/next featured item. A fling with enough horizontal
  /// velocity in either direction steps the hero; anything slower
  /// (a slow drag released near where it started) is ignored rather
  /// than guessing at intent.
  void _onHeroHorizontalDragEnd(DragEndDetails details) {
    if (featuredItems.length <= 1) return;
    final velocity = details.primaryVelocity ?? 0;
    const flingThreshold = 150.0;
    if (velocity <= -flingThreshold) {
      // Dragged right-to-left ("swiped left") — advance to next.
      _stepHero(1);
    } else if (velocity >= flingThreshold) {
      // Dragged left-to-right ("swiped right") — go back to previous.
      _stepHero(-1);
    }
  }

  // Deliberately not a setState — nothing on screen needs to visibly
  // change when a hold starts/ends, this flag is only ever read by the
  // autoplay timer above. A plain field write here avoids rebuilding the
  // whole HomeScreen (library rows, Recently Added sections, etc.) on
  // every press/release, matching the "only rebuild what actually needs
  // it" approach the rest of the hero already follows.
  void _setHeroHeld(bool held) {
    _heroHeld = held;
  }

  /// Kicks off a decode for every featured item's backdrop as soon as
  /// the list is known, instead of leaving each one to decode for the
  /// first time exactly when autoplay crossfades to it. That first-time
  /// decode was the other half of the autoplay freeze cluster above —
  /// even with the crossfade itself skipped mid-scroll, advancing to an
  /// item whose image has never been requested still pays a real decode
  /// cost on the frame it appears. Precaching them all up front (they're
  /// typically ~10 items, each already capped at 1200px wide server-side)
  /// means every item autoplay could ever land on is already sitting in
  /// NemesisImageCache by the time its crossfade actually happens. Fire-
  /// and-forget and individually guarded — one bad URL/network error
  /// shouldn't stop the rest from precaching.
  void _precacheHeroBackdrops() {
    if (!mounted) return;
    for (final item in featuredItems) {
      final itemId = item["Id"];
      if (itemId == null) continue;
      final url = MediaService.getImageUrl(itemId, type: "Backdrop", maxWidth: 1200);
      unawaited(
        precacheImage(
          CachedNetworkImageProvider(url, cacheManager: NemesisImageCache.instance),
          context,
        ).catchError((_) {}),
      );
    }
  }

  /// Loads everything Home needs. `silent` skips the loading spinner and
  /// swallows errors, keeping whatever's already on screen (cached or
  /// previously loaded) — used for background refreshes and pull-to-refresh.
  Future<void> _loadData({bool silent = false}) async {
    if (!silent) {
      setState(() {
        loading = true;
        error = null;
      });
    }

    try {
      // Libraries, resume, and featured items don't depend on each other —
      // fire them off together instead of waiting on each in turn.
      final results = await Future.wait([
        MediaService.getLibraries(),
        MediaService.getResume(),
        MediaService.getFeaturedItems(limit: 10),
      ]);

      final libs = results[0];
      final resume = results[1];
      final featured = results[2];

      // NAMESIS PRIME: only the genre libraries get a "recent & top rated"
      // row; Movies and TV Shows are covered by the trending rows above.
      final librariesToFetch = libs.where((lib) {
        return lib["Id"] != null &&
            lib["CollectionType"] != "livetv" &&
            VirtualCatalog.isGenreLibrary(lib["Id"].toString());
      }).toList();

      if (!mounted) return;

      // Paint the hero, library row, and continue-watching as soon as
      // this fast batch lands — don't hold the whole page hostage to
      // whichever library's "recently added" fetch happens to be
      // slowest. Each one below fills in its own section independently.
      setState(() {
        libraries = libs
            .where((l) => VirtualCatalog.isHomeLibrary(l["Id"]?.toString()))
            .toList();
        resumeItems = resume;
        featuredItems = featured;
        loading = false;
        error = null;
        _pendingLatestLibraries = {
          for (final lib in librariesToFetch) lib["Id"].toString(),
        };
      });

      _startHeroAutoPlay();
      _precacheHeroBackdrops();
      // Same "warm it before the UI needs it" idea as the backdrop
      // precache just above — kicks off ratings lookups for every
      // featured item right when the list is known, so by the time
      // RatingsRow actually builds for whichever item is
      // showing, RatingsService.peek() usually already has an answer
      // instead of the rating popping in a moment after the rest of
      // the hero has already painted.
      unawaited(RatingsService.prefetchAll(featured));

      unawaited(_loadTrendingRows());

      for (final lib in librariesToFetch) {
        unawaited(_loadLatestForLibrary(lib));
      }
    } catch (e) {
      if (!mounted) return;
      // A silent (background) refresh failing shouldn't blank out or
      // error-out a screen that's already showing good cached content.
      if (silent) return;
      setState(() {
        error = e.toString();
        loading = false;
      });
    }
  }

  /// Trending movies and trending TV shows (this week), for their own rows.
  Future<void> _loadTrendingRows() async {
    try {
      final results = await Future.wait([
        MediaService.getItems(
          parentId: VirtualCatalog.trendingMoviesId,
          includeItemTypes: "Movie",
          limit: 20,
          fields: MediaService.movieGridFields,
        ),
        MediaService.getItems(
          parentId: VirtualCatalog.trendingShowsId,
          includeItemTypes: "Series",
          limit: 20,
          fields: MediaService.movieGridFields,
        ),
      ]);
      if (!mounted) return;
      setState(() {
        trendingMovies = results[0];
        trendingShows = results[1];
      });
      unawaited(_saveCache());
    } catch (_) {
      // Best-effort: the rest of Home does not depend on these rows.
    }
  }

  /// Fetches a single library's "recently added" items and updates just
  /// that section — used so a slow library can't delay every other row
  /// on the page, and each row shows its skeleton only until its own
  /// data (not everyone else's) is ready.
  Future<void> _loadLatestForLibrary(dynamic lib) async {
    final id = lib["Id"].toString();

    try {
      final items = await MediaService.getLatest(
        parentId: lib["Id"],
        limit: 20,
      );

      if (!mounted) return;

      setState(() {
        _pendingLatestLibraries.remove(id);
        if (items.isNotEmpty) {
          latestByLibrary[id] = items;
        } else {
          latestByLibrary.remove(id);
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _pendingLatestLibraries.remove(id);
      });
    }

    // Persist once every in-flight fetch has settled, rather than once
    // per library (which would mean writing to disk N times per load).
    if (_pendingLatestLibraries.isEmpty) {
      unawaited(_saveCache());
    }
  }

  /// Re-fetches just Continue Watching after a play session closes, so
  /// its cards (and the resume position used the next time one of them
  /// is tapped) reflect wherever that session actually left off instead
  /// of whatever was loaded the last time Home fetched from the network
  /// (app launch or pull-to-refresh). Cheap and silent — a background
  /// refresh of one endpoint, no spinner, errors swallowed the same way
  /// a silent _loadData() does.
  Future<void> _refreshResumeItems() async {
    final seq = ++_resumeSeq;
    try {
      final resume = await MediaService.getResume(limit: 30);
      // A newer refresh started while this one was in flight: drop this
      // result so the older data can't overwrite the newer.
      if (!mounted || seq != _resumeSeq) return;
      setState(() {
        resumeItems = resume;
      });
      unawaited(_saveCache());
    } catch (_) {
      // Best-effort — leave whatever Continue Watching already had.
    }
  }

  /// The watch history changed. While a player is on screen it changes every
  /// few seconds and Home is hidden underneath, so those are skipped — the
  /// player-closed signal (and the final save that follows the close) bring
  /// the row up to date once the player is gone.
  void _onWatchHistoryChanged() {
    if (PlayerNavigation.isOpen || EmbedPlayerScreen.isOpen) return;
    _scheduleResumeRefresh(const Duration(milliseconds: 300));
  }

  /// A video player (native or embed) was just closed. The delay lets the
  /// close animation finish and the player's last "save where I stopped"
  /// run before the row is re-read.
  void _onPlayerClosed() {
    _scheduleResumeRefresh(const Duration(milliseconds: 700));
  }

  void _scheduleResumeRefresh(Duration delay) {
    _resumeDebounce?.cancel();
    _resumeDebounce = Timer(delay, () {
      if (!mounted) return;
      unawaited(_refreshResumeItems());
    });
  }

  Future<void> _saveCache() async {
    try {
      final payload = jsonEncode({
        "libraries": libraries,
        "resumeItems": resumeItems,
        "featuredItems": featuredItems,
        "latestByLibrary": latestByLibrary,
        "trendingMovies": trendingMovies,
        "trendingShows": trendingShows,
      });
      await StorageService.saveHomeCache(payload);
    } catch (_) {
      // Caching is a best-effort optimization; never let it disrupt Home.
    }
  }

  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.sizeOf(context).height;
    final isLandscape = Responsive.isLandscape(context);
    // Portrait keeps its historical sizing untouched. Landscape screen
    // height on a phone is roughly half of portrait height, so the old
    // fixed 420 minimum would eat the entire viewport (and clip the
    // hero's own title/button content against the bottom edge) — scale
    // off actual screen height instead, capped to a range that still
    // comfortably fits the logo + meta row + button row stacked at the
    // bottom of the hero.
    final heroHeight = isLandscape
        ? (Responsive.isTV
            ? Responsive.heroHeight(
                context,
                portraitHeight: 420,
                // TV is landscape too, but treating it like phone
                // landscape (whose 292-396 range was tuned for an
                // ~411dp-tall screen) would leave a huge, unused gap
                // below a spacious 1080p/4K TV screen. A TV has real
                // room to spend, so it gets its own, taller range
                // instead of inheriting the phone-landscape numbers.
                landscapeFraction: 0.5,
                landscapeMin: 450,
                landscapeMax: 900,
              )
            : Responsive.heroHeight(
                context,
                portraitHeight: 420,
                landscapeFraction: 0.97,
                landscapeMin: 292,
                landscapeMax: 396,
              ))
        : (screenHeight * 0.72).clamp(420.0, 620.0);

    // Built once per HomeScreen rebuild (i.e. only when hero content
    // actually changes — autoplay tick, data load, etc.). Wrapped in
    // its own RepaintBoundary so its paint layer (backdrop image +
    // gradient + text) stays isolated from the rest of the scrolling
    // column instead of getting swept up in the same repaint whenever
    // sibling content changes.
    // Rotation used to hard-cut the hero straight from the portrait
    // layout to the landscape one (or vice versa) the instant MediaQuery
    // reported the new orientation — a single-frame jump, since Flutter
    // only gets an old-size/new-size pair on rotation, not the stream of
    // in-between sizes a native view gets during a window resize. The
    // AnimatedContainer below tweens `height` itself over each rebuild
    // instead of snapping to it, and AnimatedSwitcher crossfades+scales
    // between the portrait/landscape carousel widgets (they're genuinely
    // different widget trees, not just a resized version of each other,
    // so there's nothing to tween *between* them directly — a fade+scale
    // is the honest way to bridge two different layouts). Together this
    // is what stands in for the "continuous relayout" a native view gets
    // for free: not pixel-identical to it, but the same *impression* of
    // gliding into the new layout rather than jump-cutting to it.
    final heroCarousel = featuredItems.isEmpty
        ? null
        : RepaintBoundary(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 320),
              curve: Curves.easeInOutCubic,
              height: heroHeight,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 320),
                switchInCurve: Curves.easeOut,
                switchOutCurve: Curves.easeIn,
                transitionBuilder: (child, animation) => FadeTransition(
                  opacity: animation,
                  child: ScaleTransition(
                    scale: Tween<double>(
                      begin: 0.97,
                      end: 1.0,
                    ).animate(animation),
                    child: child,
                  ),
                ),
                // Keyed on orientation (not on heroHeight, which changes
                // every rebuild) so AnimatedSwitcher only triggers the
                // crossfade when portrait<->landscape actually flips,
                // not on every minor height recompute.
                // Scoped to just this subtree: an autoplay tick (or any
                // other _heroIndexNotifier update) only rebuilds the hero
                // carousel from here down, not the Column of rows below it.
                child: ValueListenableBuilder<int>(
                  valueListenable: _heroIndexNotifier,
                  builder: (context, heroIndex, _) => KeyedSubtree(
                    key: ValueKey(isLandscape),
                    child: GestureDetector(
                      // translucent so this still recognizes drags/holds
                      // over the hero's transparent gradient areas, while
                      // letting hit-testing continue through to the
                      // buttons/backdrop underneath for their own taps.
                      behavior: HitTestBehavior.translucent,
                      onHorizontalDragEnd: _onHeroHorizontalDragEnd,
                      onLongPressStart: (_) => _setHeroHeld(true),
                      onLongPressEnd: (_) => _setHeroHeld(false),
                      onLongPressCancel: () => _setHeroHeld(false),
                      child: _buildHeroCarousel(heroHeight, heroIndex),
                    ),
                  ),
                ),
              ),
            ),
          );

    return Scaffold(
      backgroundColor: nemesisBg,
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : error != null
          ? SafeArea(child: _buildError())
          : Stack(
        children: [
          ResistiveRefresh(
        onRefresh: () => _loadData(silent: true),
        color: _gold,
        backgroundColor: const Color(0xff232323),
        child: CustomScrollView(
          controller: _scrollController,
          // A CustomScrollView whose content doesn't overflow the
          // viewport (e.g. right after a fresh install, before Home has
          // much to show) isn't "scrollable" by default, so the pull
          // gesture ResistiveRefresh listens for never fires. This keeps
          // pull-to-refresh live regardless of how much content Home has.
          physics: const AlwaysScrollableScrollPhysics(),
          // Default cacheExtent (~250px) only starts decoding a row's
          // images once it's nearly on screen, so scrolling into a new
          // row can hitch right as its cards' CachedNetworkImages kick
          // off. A full screen-height of runway gives that work a chance
          // to happen before the row is actually visible.
          cacheExtent: MediaQuery.sizeOf(context).height,
          slivers: [
            // The hero is a plain, non-pinned sliver — it scrolls away
            // with the rest of the content exactly like an ordinary
            // list item instead of staying pinned to the top and
            // clip-shrinking in place. Since the backdrop image sits at
            // the top of the hero's fixed-height Stack and the title/
            // meta/button/dots sit at the bottom, this rigid translation
            // naturally reveals the image scrolling away first while
            // the text lingers a little longer, then the whole block
            // clears and the rest of Home continues underneath — the
            // simple floating-with-your-finger motion, not a shrink.
            if (heroCarousel != null) SliverToBoxAdapter(child: heroCarousel),

            SliverToBoxAdapter(
              child: Column(
                // ListView (used before the hero became a sliver header)
                // stretches its children to full width by default; a
                // plain Column doesn't — it centers them. Without this,
                // the section titles/rows below shrink-wrap and end up
                // visually centered instead of left-aligned like before.
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 24),

                  if (libraries.isNotEmpty) _bleedRowUnderRail(_buildLibraryRow()),

                  if (resumeItems.isNotEmpty) ...[
                    const SizedBox(height: 28),
                    _buildSectionTitle("Continue Watching"),
                    _bleedRowUnderRail(_buildContinueWatchingRow()),
                  ],

                  if (trendingMovies.isNotEmpty) ...[
                    const SizedBox(height: 28),
                    _buildSectionTitle("Trending Movies"),
                    _bleedRowUnderRail(_buildRecentlyAddedRow(trendingMovies)),
                  ],

                  if (trendingShows.isNotEmpty) ...[
                    const SizedBox(height: 28),
                    _buildSectionTitle("Trending TV Shows"),
                    _bleedRowUnderRail(_buildRecentlyAddedRow(trendingShows)),
                  ],

                  for (final lib in libraries)
                    if (VirtualCatalog.isGenreLibrary(lib["Id"]?.toString()) &&
                        (latestByLibrary[lib["Id"]] != null ||
                            _pendingLatestLibraries
                                .contains(lib["Id"].toString())))
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const SizedBox(height: 28),
                          _buildSectionTitle(
                            "Recent & Top Rated in ${(lib["Name"] ?? "").toString().toUpperCase()}",
                            onSeeAll: latestByLibrary[lib["Id"]] != null
                                ? () => _openLibraryNewest(lib)
                                : null,
                          ),
                          _bleedRowUnderRail(
                            latestByLibrary[lib["Id"]] != null
                                ? (lib["CollectionType"] == "music"
                                    ? _buildRecentlyAddedMusicRow(
                                        latestByLibrary[lib["Id"]]!,
                                        onSeeAll: () => _openLibraryNewest(lib),
                                      )
                                    : _buildRecentlyAddedRow(
                                        latestByLibrary[lib["Id"]]!,
                                        onSeeAll: () => _openLibraryNewest(lib),
                                      ))
                                : (lib["CollectionType"] == "music"
                                    ? _buildRecentlyAddedMusicRowSkeleton()
                                    : _buildRecentlyAddedRowSkeleton()),
                          ),
                        ],
                      ),

                  // The main nav's bottom bar (mini player + tab bar) floats
                  // on top of this screen in a plain Stack, not a real
                  // Scaffold.extendBody (see MainNavScreen's own doc comment
                  // for why), so MediaQuery's bottom padding here is only
                  // the device safe-area inset — it does NOT know about the
                  // bar's own height. BottomClearance.of adds that back in,
                  // reactively, so the last row's content clears the mini
                  // player and/or tab bar instead of scrolling to a stop
                  // partly hidden behind them.
                  BottomClearanceBuilder(
                    builder: (context, bottomClearance) => SizedBox(
                      height: 40 +
                          MediaQuery.paddingOf(context).bottom +
                          bottomClearance,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
          ),
          _buildTopBar(),
        ],
      ),
    );
  }

  Widget _buildError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, color: Colors.redAccent, size: 48),
            const SizedBox(height: 12),
            Text(
              error!,
              style: const TextStyle(color: Colors.white70),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: () => _loadData(),
              child: const Text("Retry"),
            ),
          ],
        ),
      ),
    );
  }

  /// Picks the hero layout by orientation. Portrait keeps the original
  /// full-bleed-backdrop-with-overlaid-content treatment untouched;
  /// landscape gets its own BBC iPlayer-style split layout (backdrop
  /// on the right, logo/metadata/buttons on the left, sitting on the
  /// plain app background rather than over the image) — see
  /// [_buildHeroCarouselLandscape].
  /// Wraps a backdrop widget (already sized to [heroHeight]) so it lags
  /// behind and slowly zooms with the page's scroll offset, instead of
  /// scrolling rigidly at the same rate as the logo/metadata/buttons
  /// stacked on top of it.
  ///
  /// The backdrop sits inside a normal (non-pinned) sliver, so it
  /// already scrolls at 1:1 like everything else by default. To make
  /// it lag, we push it back down by `offset * (1 - parallaxFactor)`
  /// on every scroll frame — since that's always <= the sliver's own
  /// upward translation (`offset`), the backdrop's top edge never pulls
  /// short of the box's visible region, so no gap is ever exposed at
  /// the top; only its unseen bottom overhang grows, which is simply
  /// clipped. The zoom is a plain scale around the center driven by the
  /// same offset, clamped to the hero's own height so it settles once
  /// the hero has fully scrolled past (it's invisible by then anyway).
  ///
  /// Scoped to its own ValueListenableBuilder (rather than reading
  /// scroll offset via setState higher up) so only this small transform
  /// subtree rebuilds per scroll frame — the backdrop image itself is
  /// passed in as the builder's `child` and is never rebuilt.
  // Plain ClipRect anti-aliases its cut — it doesn't crop the image
  // with a hard binary edge, it blends a thin sliver of the clipped-
  // away content in at reduced opacity so the boundary doesn't look
  // jagged. That sliver's color is whatever the image actually looks
  // like right at that pixel: invisible against nemesisBg on a dark
  // scene, a visible translucent smear of the image's own color on a
  // bright/saturated one (e.g. the reddish tint from a knife or a
  // neon sign). It shows specifically while scrolling because that's
  // the only time this backdrop's scale/translate are non-identity —
  // both animate every scroll frame, so that thin edge is animating
  // too instead of sitting still. No amount of painting something
  // solid *behind* the backdrop fixes this, since the smear paints on
  // top of whatever's behind it, not in place of it.
  //
  // The actual fix: clip a few px short of the box at the bottom
  // (_heroClipBottomInset), landing inside the zone the hero's own
  // gradient (_buildHeroGradients/_buildHeroGradientsLandscape) has
  // already darkened to fully opaque nemesisBg. Whatever bleeds at
  // the new edge is bleeding from already near-black, gradient-
  // darkened pixels — not raw image color — so it disappears
  // regardless of what the backdrop itself looks like.
  Widget _buildParallaxBackdrop({
    required double heroHeight,
    required Widget child,
    double leftInset = 0.0,
  }) {
    // The comment above claims this transform "lives inside its own
    // RepaintBoundary/GPU layer" — it didn't actually have one. A bare
    // Transform doesn't get its own compositor layer; without a
    // RepaintBoundary directly around it, every scroll-frame update to
    // this widget's transform bubbles up and repaints the *entire*
    // nearest RepaintBoundary ancestor instead of just this subtree. The
    // hero only had one RepaintBoundary total, wrapping the whole carousel
    // (backdrop + gradients + title + buttons + dots) — so every scroll
    // frame while the parallax offset is active (i.e. whenever the raw
    // scroll offset is between 0 and heroHeight; it's clamped/idle outside
    // that band) was repainting the whole hero, not just the image. That
    // band is exactly "scrolling to/past the hero", which is why the
    // stutter is concentrated there and nowhere else. This RepaintBoundary
    // makes the transform an actual GPU-only compositor operation, scoped
    // to just the backdrop image+clip — the gradients/title/buttons/dots
    // sitting alongside it never repaint on scroll at all now.
    return RepaintBoundary(
      child: ClipRect(
        clipper: _HeroBackdropClipper(_heroClipBottomInset, leftInset: leftInset),
        child: ValueListenableBuilder<double>(
          valueListenable: _heroScrollOffset,
          builder: (context, rawOffset, backdropChild) {
            final offset = rawOffset.clamp(0.0, heroHeight);
            final t = heroHeight <= 0 ? 0.0 : offset / heroHeight;
            final lag = offset * (1 - _heroParallaxFactor);
            final scale = 1.0 + t * _heroParallaxMaxZoom;
            return Transform.scale(
              scale: scale,
              alignment: Alignment.center,
              child: Transform.translate(
                offset: Offset(0, lag),
                child: backdropChild,
              ),
            );
          },
          child: child,
        ),
      ),
    );
  }

  /// Shared transitionBuilder for both hero backdrops (portrait and
  /// landscape). Purely a crossfade now — the entering backdrop fades in
  /// in place and the outgoing one fades out in place, no horizontal
  /// motion. `_heroDirection` is kept (still set by the swipe handler
  /// below and by autoplay) purely to decide *which* item comes up next
  /// — left swipe still goes to the previous item, right swipe still
  /// goes to the next, and holding still freezes on the current one —
  /// it just no longer drives any slide offset here.
  Widget _buildHeroSlideTransition(Widget child, Animation<double> animation) {
    final curved = CurvedAnimation(parent: animation, curve: Curves.easeInOut);
    return FadeTransition(opacity: curved, child: child);
  }

  Widget _buildHeroCarousel(double heroHeight, int heroIndex) {
    return Responsive.isLandscape(context)
        ? _buildHeroCarouselLandscape(heroHeight, heroIndex)
        : _buildHeroCarouselPortrait(heroHeight, heroIndex);
  }

  Widget _buildHeroCarouselPortrait(double heroHeight, int heroIndex) {
    final currentItem = featuredItems[heroIndex];

    return SizedBox(
      height: heroHeight,
      child: Stack(
        // Clip.none only matters for the overscanned base fill just
        // below — every other child here still sizes to exactly
        // heroHeight, so nothing else visibly changes.
        clipBehavior: Clip.none,
        children: [
          // Base fill painted _heroSeamOverscan px taller than the hero
          // box itself (bleeding past its bottom edge into the sliver
          // below, which clipBehavior: Clip.none above allows). Same
          // fix as the landscape hero (see _buildHeroCarouselLandscape):
          // the parallax backdrop's Transform.scale/translate lives
          // inside its own RepaintBoundary/GPU layer, and its bottom
          // edge can land on a different physical pixel than the
          // sliver below it while scrolling — showing a hairline seam
          // of whatever's directly behind (here, the backdrop image
          // itself, hence the reddish line). Painting matching
          // background a few pixels past the "official" edge means
          // that seam lands on top of matching color instead of
          // exposing the image underneath.
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            height: heroHeight + _heroSeamOverscan,
            child: Container(color: nemesisBg),
          ),

          _buildParallaxBackdrop(
            heroHeight: heroHeight,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 800),
              switchInCurve: Curves.easeInOut,
              switchOutCurve: Curves.easeInOut,
              layoutBuilder: (currentChild, previousChildren) {
                return Stack(
                  fit: StackFit.expand,
                  children: [
                    ...previousChildren,
                    ?currentChild,
                  ],
                );
              },
              transitionBuilder: (child, animation) =>
                  _buildHeroSlideTransition(child, animation),
              child: _buildHeroBackdrop(
                currentItem,
                heroHeight,
                key: ValueKey("backdrop-${currentItem["Id"]}"),
              ),
            ),
          ),

          // Painted as a sibling of the parallax-transformed image
          // (not inside it) so it scrolls at the same 1:1 rate as the
          // logo/metadata/buttons below instead of lagging and
          // zooming along with the photo.
          Positioned.fill(child: _buildHeroGradients()),

          Positioned(
            left: 20,
            right: 20,
            bottom: 40,
            child: Align(
              // Explicit left alignment instead of relying on the
              // Column's own crossAxisAlignment to keep it flush left
              // — this pins the whole logo/meta/buttons block to the
              // left edge of the padded area regardless of how wide
              // any individual child (e.g. the buttons row) ends up
              // being, rather than leaving it dependent on the
              // Column stretching to exactly the right width.
              alignment: Alignment.centerLeft,
              // AnimatedSize is what turns width changes between items
              // (a longer/shorter genre-and-rating combo on the meta
              // row, or the buttons row's FittedBox scaling by a
              // different factor) into a smooth premium-feeling resize
              // instead of an instant snap. Left-aligned to match the
              // Align above — the block only ever grows/shrinks toward
              // the right, never moving its left edge.
              child: AnimatedSize(
                duration: const Duration(milliseconds: 340),
                curve: Curves.easeOutCubic,
                alignment: Alignment.centerLeft,
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 500),
                  switchInCurve: Curves.easeOut,
                  switchOutCurve: Curves.easeIn,
                  // Without this, AnimatedSwitcher falls back to its
                  // default layoutBuilder, which stacks the outgoing
                  // and incoming children with Alignment.center — but
                  // every layer around this block (the Align above,
                  // this Column's crossAxisAlignment.start, the meta/
                  // button rows' FittedBox(alignment: centerLeft)) is
                  // built left-anchored. Two items with different meta
                  // row widths (a longer genre/rating string vs. a
                  // shorter one) then get center-stacked at different
                  // widths during the crossfade — visible as two
                  // slightly offset "ghost" copies of the buttons — and
                  // the instant the wider outgoing child is removed,
                  // the box's reported width drops and the remaining
                  // (already left-anchored) content appears to jump
                  // left in a single frame. Matching the alignment here
                  // keeps both children pinned to the same left edge
                  // throughout the crossfade, so there's nothing left
                  // to snap.
                  layoutBuilder: (currentChild, previousChildren) {
                    return Stack(
                      alignment: Alignment.centerLeft,
                      children: [
                        ...previousChildren,
                        ?currentChild,
                      ],
                    );
                  },
                  transitionBuilder: (child, animation) {
                    final slide = Tween<Offset>(
                      begin: const Offset(0, 0.03),
                      end: Offset.zero,
                    ).animate(animation);
                    return FadeTransition(
                      opacity: animation,
                      child: SlideTransition(position: slide, child: child),
                    );
                  },
                  child: _buildHeroContent(
                    currentItem,
                    key: ValueKey("content-${currentItem["Id"]}"),
                  ),
                ),
              ),
            ),
          ),

          _buildHeroDots(heroIndex),
        ],
      ),
    );
  }

  /// BBC iPlayer-style landscape hero: backdrop confined to the right
  /// side of the row instead of running full-bleed behind everything,
  /// logo/metadata/buttons on the left sitting on the plain app
  /// background. The two are stitched together by
  /// [_buildHeroBackdropLandscape]'s left-edge gradient, which fades
  /// the backdrop's own left edge into `nemesisBg` so it reads as one
  /// continuous surface rather than an image dropped next to a solid
  /// panel.
  ///
  /// The backdrop and the text column are no longer split by a single
  /// Row (where widening one always narrows the other and shifts the
  /// text's centered position). Instead each is independently
  /// fraction-sized and Align'd within the same Stack: the text column
  /// keeps the exact width/position it's always had, while the
  /// backdrop's width can grow past that boundary independently. Where
  /// the two now overlap, the backdrop (painted first) simply sits
  /// behind the text column (painted after) — its own left-edge
  /// gradient still fades it into `nemesisBg` under the overlap, so the
  /// text reads as sitting on top of the blend rather than the image
  /// stopping short of it.
  Widget _buildHeroCarouselLandscape(double heroHeight, int heroIndex) {
    final currentItem = featuredItems[heroIndex];

    // Text column width from the left edge. The backdrop is
    // independently sized wider (82% from the right edge — Align'd
    // separately, not sharing a Row with this column — see the class
    // doc above), so it now extends under part of the text column
    // rather than stopping at its boundary; widening this column does
    // not steal any width from the backdrop.
    //
    // Was 0.30, with a 260px floor. That floor's own comment below
    // explains it was only ever meant as a *transient* guard against
    // a single tiny mid-rotation frame — but at steady state, on a
    // typical phone, 30% of the full landscape width lands barely
    // above that floor (e.g. ~270px on a ~915dp-wide screen), not
    // meaningfully bigger than the "transient" guard value itself.
    // That's well short of what the meta row (year/genres/rating) and
    // especially the two-button row need at their natural size
    // (~300-320px combined), so _buildHeroMetaRow/_buildHeroButtons'
    // FittedBox(scaleDown) — meant as a last-resort safety net for
    // genuinely tight cases — was instead engaging on every normal
    // landscape frame, shrinking both rows well below their intended
    // size. 0.38/320 gives the steady-state column enough room that
    // FittedBox stops actively scaling on typical phone widths, while
    // still growing further on tablets/TV and still protecting narrow
    // transient frames exactly as before.
    const double textWidthFraction = 0.38;
    const double backdropWidthFraction = 0.86;

    return SizedBox(
      height: heroHeight,
      child: Stack(
        // Clip.none only matters for the overscanned base fill just
        // below — every other child here still sizes to exactly
        // heroHeight via Positioned.fill/FractionallySizedBox, so
        // nothing else visibly changes.
        clipBehavior: Clip.none,
        children: [
          // Base fill so the left column is guaranteed to be plain
          // app background even for the first frame before either
          // AnimatedSwitcher child has laid out. Deliberately painted
          // _heroSeamOverscan px taller than the hero box itself
          // (bleeding past its bottom edge into the sliver below,
          // which Clip.none above allows): this hero is wrapped in
          // its own RepaintBoundary for scroll performance, and that
          // isolated GPU layer can show a hairline seam against the
          // content sliver right below it while scrolling, on some
          // devices/GPUs, if their edges don't land on the same
          // physical pixel. Painting matching background a few
          // pixels past the "official" edge means that seam — if it
          // shows at all — lands on top of matching color instead of
          // exposing whatever's underneath.
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            height: heroHeight + _heroSeamOverscan,
            child: Container(color: nemesisBg),
          ),

          // Backdrop — painted first so the text column (below) sits
          // on top of it in the overlap region.
          Align(
            alignment: Alignment.centerRight,
            child: FractionallySizedBox(
              widthFactor: backdropWidthFraction,
              heightFactor: 1,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _buildParallaxBackdrop(
                    heroHeight: heroHeight,
                    leftInset: _heroClipLeftInset,
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 800),
                      switchInCurve: Curves.easeInOut,
                      switchOutCurve: Curves.easeInOut,
                      layoutBuilder: (currentChild, previousChildren) {
                        return Stack(
                          fit: StackFit.expand,
                          children: [
                            ...previousChildren,
                            ?currentChild,
                          ],
                        );
                      },
                      transitionBuilder: (child, animation) =>
                          _buildHeroSlideTransition(child, animation),
                      child: _buildHeroBackdropLandscape(
                        currentItem,
                        heroHeight,
                        key: ValueKey("backdrop-landscape-${currentItem["Id"]}"),
                      ),
                    ),
                  ),

                  // Sibling of the parallax-transformed image, same
                  // reasoning as the portrait hero above — scrolls at
                  // 1:1 with the logo/metadata/button column instead
                  // of lagging/zooming with the photo.
                  Positioned.fill(child: _buildHeroGradientsLandscape()),
                ],
              ),
            ),
          ),

          // Logo / metadata / buttons column — fixed width/position,
          // painted after the backdrop so it stays on top wherever the
          // wider backdrop now reaches underneath it.
          Align(
            alignment: Alignment.centerLeft,
            // Was FractionallySizedBox(widthFactor: textWidthFraction) —
            // during the mid-rotation resize this Align's incoming width
            // briefly reports something far narrower than the settled
            // landscape content width (the MainNavScreen LayoutBuilder/
            // AnimatedPadding chain above hasn't caught up to the real
            // width for a frame or two), and a fraction of that transient
            // tiny width squeezed the logo/meta row/buttons down to ~60-100px
            // for a frame — which threw a hard RenderFlex overflow in
            // _buildHeroMetaRow. That exception (and Flutter building the
            // debug overflow banner for it) is itself real main-thread
            // work stacked on top of an already-janky rotation frame, and
            // was very likely a meaningful chunk of the multi-second
            // stall Android was covering for by holding/stretching the
            // last rendered frame. LayoutBuilder + an explicit floor
            // guarantees this column never gets narrower than it can
            // actually lay out its content in, regardless of what the
            // ancestor chain transiently reports.
            child: LayoutBuilder(
              builder: (context, constraints) {
                final rawWidth = constraints.maxWidth.isFinite
                    ? constraints.maxWidth * textWidthFraction
                    : 320.0;
                final width = math.max(rawWidth, 320.0);
                final height =
                    constraints.maxHeight.isFinite ? constraints.maxHeight : null;
                return SizedBox(
                  width: width,
                  height: height,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 28),
                    child: Center(
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 500),
                        switchInCurve: Curves.easeOut,
                        switchOutCurve: Curves.easeIn,
                        transitionBuilder: (child, animation) {
                          final slide = Tween<Offset>(
                            begin: const Offset(0, 0.03),
                            end: Offset.zero,
                          ).animate(animation);
                          return FadeTransition(
                            opacity: animation,
                            child: SlideTransition(position: slide, child: child),
                          );
                        },
                        child: _buildHeroContentLandscape(
                          currentItem,
                          key: ValueKey("content-landscape-${currentItem["Id"]}"),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),

          _buildHeroDots(heroIndex),
        ],
      ),
    );
  }

  /// Page-indicator dots shared by both the portrait and landscape
  /// hero layouts — identical position/behavior in each, just pulled
  /// out once rather than duplicated between the two Stacks.
  Widget _buildHeroDots(int heroIndex) {
    return Positioned(
      bottom: 12,
      left: 0,
      right: 0,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: List.generate(featuredItems.length, (index) {
          final active = index == heroIndex;
          return AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            margin: const EdgeInsets.symmetric(horizontal: 3),
            width: active ? 20 : 6,
            height: 6,
            decoration: BoxDecoration(
              color: active ? gold : Colors.white.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(3),
            ),
          );
        }),
      ),
    );
  }

  Widget _buildTopBar() {
    final isLandscape = Responsive.isLandscape(context);

    // In landscape, the logo/branding, search, favorites, and the
    // profile icon all live in the sidebar (MainNavScreen), which is
    // always on screen there — keeping them here too would just be
    // duplicated chrome. So the whole top bar collapses to nothing in
    // landscape; it only appears in portrait.
    if (isLandscape) return const SizedBox.shrink();

    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      // Was SafeArea here. SafeArea's own build() calls the *unscoped*
      // MediaQuery.of(context) internally, which subscribes it to every
      // MediaQueryData field — including viewInsets.bottom, which the
      // framework updates every single frame while any keyboard is
      // sliding open or closed anywhere in the app (every bottom-nav tab
      // is kept alive together in an IndexedStack). That forced this
      // small top bar to rebuild every such frame too, adding to the
      // same app-wide keyboard-animation stutter fixed the same way on
      // Music/Movies/Live TV/Downloads/Search. A plain Padding using the
      // aspect-scoped `MediaQuery.paddingOf` below gets the identical
      // safe-area values but only rebuilds when device padding itself
      // actually changes.
      child: Padding(
        padding: MediaQuery.paddingOf(context),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              // Wrapped in Flexible (was a plain Row, unconstrained on
              // both sides): on a narrower screen, or with a larger
              // device text-scale setting inflating "Project Nemesis"
              // past its Pixel-6-reference width, this branding group's
              // natural width plus the icon group's on the right no
              // longer both fit — without a Flexible boundary here,
              // Flutter just let the overflow run past the right edge
              // of the screen, which is what was clipping the profile
              // icon (the last, right-most item) instead of shrinking
              // the text that's actually causing the squeeze.
              Flexible(
                child: Row(
                  children: [
                    Image.asset(
                      'assets/images/nemesis_logo.png',
                      width: 28,
                      height: 28,
                      fit: BoxFit.contain,
                    ),
                    const SizedBox(width: 8),
                    // Flexible + maxLines/overflow so the text is what
                    // gives way (ellipsis) under pressure, instead of
                    // the icons on the right being pushed off-screen.
                    Flexible(
                      child: Text.rich(
                        const TextSpan(
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                          children: [
                            TextSpan(
                              text: "Trigon",
                              style: TextStyle(color: gold),
                            ),
                          ],
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              Row(
                children: [
                  Pressable(
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const ParentalLockGate(
                          area: LockedArea.favorites,
                          child: FavoritesScreen(),
                        ),
                      ),
                    ),
                    borderRadius: BorderRadius.circular(19),
                    child: _circleIcon(Icons.favorite_border),
                  ),
                  const SizedBox(width: 10),
                  // Global Cast button — per the casting master prompt's
                  // "Home App Bar" location. Landscape doesn't need this
                  // (the sidebar has its own, always-visible one — see
                  // MainNavScreen._buildRailContent), matching how
                  // Search/Favorites/Profile already only live here in
                  // portrait too. CastButton is a plain IconButton with
                  // its own ripple, so — unlike the other icons in this
                  // row — it isn't wrapped in a second Pressable, which
                  // would just fight it for the same tap.
                  SizedBox(
                    width: 38,
                    height: 38,
                    child: DecoratedBox(
                      decoration: const BoxDecoration(
                        color: Colors.black45,
                        shape: BoxShape.circle,
                      ),
                      child: CastButton(iconSize: 18),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Pressable(
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const ProfileSettingsScreen(),
                      ),
                    ),
                    // Long-press = quick profile switch.
                    onLongPress: () => SwitchProfileSheet.show(context),
                    borderRadius: BorderRadius.circular(19),
                    child: _buildProfileIcon(),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _circleIcon(IconData icon) {
    return Container(
      width: 38,
      height: 38,
      decoration: const BoxDecoration(
        color: Colors.black45,
        shape: BoxShape.circle,
      ),
      child: Icon(icon, color: Colors.white, size: 18),
    );
  }

  /// Same size/shape as [_circleIcon], but shows the signed-in user's
  /// avatar when one is available, falling back to the plain person
  /// icon while it loads or if the user has no avatar set.
  Widget _buildProfileIcon() {
    final userId = JellyfinClient.userId;
    final imageUrl =
        userId.isNotEmpty ? MediaService.getUserImageUrl(userId, maxWidth: 76) : null;

    return Container(
      width: 38,
      height: 38,
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
    );
  }

  /// Decode-width bound for the hero backdrop, shared by portrait and
  /// landscape. Matches the actual on-screen pixel width at this device's
  /// DPR rather than always decoding the full 1200px the URL requests from
  /// the server — clamped to 1200 since that's the most the network
  /// request itself will ever return anyway.
  int _heroBackdropCacheWidth(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return (MediaQuery.sizeOf(context).width * dpr).round().clamp(0, 1200);
  }

  Widget _buildHeroBackdrop(dynamic item, double height, {Key? key}) {
    final itemId = item["Id"];
    final backdropUrl = MediaService.getImageUrl(
      itemId,
      type: "Backdrop",
      maxWidth: 1200,
    );

    return SizedBox(
      key: key,
      height: height,
      width: double.infinity,
      child: Stack(
        fit: StackFit.expand,
        children: [
          CachedNetworkImage(
            cacheManager: NemesisImageCache.instance,
            imageUrl: backdropUrl,
            fit: BoxFit.cover,
            alignment: Alignment.center,
            // Unlike every other image in the app, this one had no decode
            // bound — meaning it decoded at whatever resolution the server
            // sent (up to 1200px wide, full native height) regardless of
            // how large it's actually painted. It's also the one image the
            // parallax scale/translate transforms every scroll frame, so
            // an oversized bitmap here is a direct scroll-jank cost. Bound
            // it to the real on-screen size at this device's pixel ratio.
            memCacheWidth: _heroBackdropCacheWidth(context),
            memCacheHeight: (height * MediaQuery.devicePixelRatioOf(context))
                .round(),
            placeholder: (context, url) => Container(color: nemesisBg),
            errorWidget: (context, url, error) =>
                Container(color: placeholderBg),
          ),

          // Smooth, gradual multi-stop gradient — no single stretch where
          // the darkening rate changes abruptly, so there's no visible
          // "edge" where it meets the page background below.
          Container(color: Colors.black.withValues(alpha: 0.22)),
        ],
      ),
    );
  }

  /// The portrait hero's gradient overlays, split out of
  /// [_buildHeroBackdrop] so they can be painted *outside* of
  /// [_buildParallaxBackdrop]'s lag/zoom transform. They're purely
  /// static decoration (not tied to which item is showing), so unlike
  /// the backdrop image itself they scroll rigidly at 1:1 with the
  /// sliver — same as the logo/metadata/buttons — instead of lagging
  /// and zooming with the photo underneath them.
  Widget _buildHeroGradients() {
    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  nemesisBg.withValues(alpha: 0.0),
                  nemesisBg.withValues(alpha: 0.0),
                  nemesisBg.withValues(alpha: 0.67),
                  nemesisBg,
                  nemesisBg,
                ],
                stops: const [
                  0.0,
                  0.45,
                  0.75,
                  0.94,
                  1.0,
                ],
              ),
            ),
          ),
        ),

        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: [
                  nemesisBg.withValues(alpha: 0.6),
                  nemesisBg.withValues(alpha: 0.0),
                  nemesisBg.withValues(alpha: 0.3),
                ],
                stops: const [0.0, 0.5, 1.0],
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// Landscape-only backdrop, confined to the right-hand column of
  /// [_buildHeroCarouselLandscape] rather than running full-bleed like
  /// [_buildHeroBackdrop]. Modeled on the BBC iPlayer hero: the image
  /// doesn't carry any text over it at all here (that's the whole
  /// point of the split layout — logo/metadata/buttons live on the
  /// plain background to the left), so this only needs a left-edge
  /// gradient to blend into that background, plus the same bottom
  /// fade the portrait version uses so the hero still hands off
  /// cleanly into the page content below it.
  Widget _buildHeroBackdropLandscape(dynamic item, double height, {Key? key}) {
    final itemId = item["Id"];
    final backdropUrl = MediaService.getImageUrl(
      itemId,
      type: "Backdrop",
      maxWidth: 1200,
    );

    return SizedBox(
      key: key,
      height: height,
      width: double.infinity,
      child: Stack(
        fit: StackFit.expand,
        children: [
          CachedNetworkImage(
            cacheManager: NemesisImageCache.instance,
            imageUrl: backdropUrl,
            fit: BoxFit.cover,
            // Biased toward the top rather than dead-center: cover
            // crops symmetrically top/bottom to fill the box, and on
            // this narrower/taller landscape hero that was cutting
            // into faces/heads near the top of the source backdrop.
            // Shifting the alignment up keeps that region in frame at
            // the cost of a bit more crop off the bottom instead.
            alignment: const Alignment(0, -0.6),
            // See the matching comment in _buildHeroBackdrop — same
            // missing-decode-bound issue, same fix.
            memCacheWidth: _heroBackdropCacheWidth(context),
            memCacheHeight: (height * MediaQuery.devicePixelRatioOf(context))
                .round(),
            placeholder: (context, url) => Container(color: nemesisBg),
            errorWidget: (context, url, error) =>
                Container(color: placeholderBg),
          ),

          Container(color: Colors.black.withValues(alpha: 0.18)),
        ],
      ),
    );
  }

  /// The landscape hero's gradient overlays, split out of
  /// [_buildHeroBackdropLandscape] for the same reason as
  /// [_buildHeroGradients]: painted outside [_buildParallaxBackdrop]'s
  /// transform so they scroll rigidly at 1:1 with the logo/metadata/
  /// button column instead of lagging and zooming with the photo.
  Widget _buildHeroGradientsLandscape() {
    return Stack(
      fit: StackFit.expand,
      children: [
        // The gradient the person asked for: fades the backdrop's
        // own left edge into nemesisBg so the interface between the
        // image and the logo/metadata/button column reads as one
        // continuous background rather than an image butted up
        // against a solid panel.
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                // Slowed down and smoothed out: the old two-stop fade
                // (opaque -> transparent by 0.55) finished blending
                // into the backdrop too abruptly. Adding a mid stop
                // and pushing the fully-transparent point out to 0.8
                // spreads the transition over more of the column
                // width and eases it in rather than fading linearly
                // start-to-finish.
                // Extra fully-opaque stop at 0.04 (~30px): holds solid
                // nemesisBg across the image's left edge (and its
                // _heroClipLeftInset trim) so a fractional-pixel edge
                // can't expose a hairline of image. Rest of the curve
                // is unchanged.
                colors: [
                  nemesisBg,
                  nemesisBg,
                  nemesisBg.withValues(alpha: 0.85),
                  nemesisBg.withValues(alpha: 0.35),
                  nemesisBg.withValues(alpha: 0.0),
                ],
                stops: const [0.0, 0.04, 0.28, 0.55, 0.8],
              ),
            ),
          ),
        ),

        // Same bottom fade _buildHeroBackdrop (portrait) uses, so the
        // landscape hero hands off into the page content scrolling in
        // underneath it instead of ending on a hard image edge. This
        // now matches portrait's stops exactly, including going fully
        // opaque (alpha 1.0, not 0.9) over the last stretch — the
        // previous alpha-0.9 ceiling left a faint see-through band at
        // the very bottom that read as "no gradient" against the page
        // background.
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  nemesisBg.withValues(alpha: 0.0),
                  nemesisBg.withValues(alpha: 0.0),
                  nemesisBg.withValues(alpha: 0.67),
                  nemesisBg,
                  nemesisBg,
                ],
                stops: const [
                  0.0,
                  0.45,
                  0.75,
                  0.94,
                  1.0,
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildHeroContent(dynamic item, {Key? key}) {
    final itemId = item["Id"];
    final name = item["Name"] ?? "";

    return Column(
      key: key,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Fixed bounding box (height AND width) so every logo occupies
        // the same footprint regardless of its native aspect ratio.
        SizedBox(
          height: 80,
          width: 300,
          // No text placeholder while loading on purpose (it would flash
          // right before the logo pops in); AutoLogo also looks the logo up
          // and retries if it is missing or fails to load.
          child: AutoLogo(
            itemId: itemId.toString(),
            alignment: Alignment.centerLeft,
            fallback: () => Align(
              alignment: Alignment.centerLeft,
              child: Text(
                name,
                style: AppFonts.dosis(fontSize: 34, fontWeight: FontWeight.bold),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ),

        const SizedBox(height: 10),

        _buildHeroMetaRow(item),

        const SizedBox(height: 18),

        _buildHeroButtons(item),
      ],
    );
  }

  /// Landscape counterpart to [_buildHeroContent]: same logo/metadata/
  /// buttons stack, just sized and spaced to fit comfortably inside
  /// the shorter landscape hero and the narrower left column
  /// [_buildHeroCarouselLandscape] gives it, and centered vertically
  /// in that column rather than pinned to the bottom.
  Widget _buildHeroContentLandscape(dynamic item, {Key? key}) {
    final itemId = item["Id"];
    final name = item["Name"] ?? "";

    return Column(
      key: key,
      mainAxisSize: MainAxisSize.min,
      // Center, not start: the buttons row is the widest element in
      // this column (it no longer stretches, see _buildHeroButtons),
      // so with center alignment the logo and meta row line up on the
      // buttons' horizontal center instead of hugging the left edge of
      // whatever the column's width happens to be.
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          height: 56,
          width: 230,
          child: AutoLogo(
            itemId: itemId.toString(),
            alignment: Alignment.center,
            fallback: () => Align(
              alignment: Alignment.center,
              child: Text(
                name,
                style: AppFonts.dosis(fontSize: 22, fontWeight: FontWeight.bold),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ),

        const SizedBox(height: 12),

        _buildHeroMetaRow(item),

        const SizedBox(height: 12),

        _buildHeroButtons(item),
      ],
    );
  }

  /// Year · genres · community rating row — shared as-is by both the
  /// portrait (overlaid on the backdrop) and landscape (sitting on
  /// plain background) hero layouts.
  Widget _buildHeroMetaRow(dynamic item) {
    final year = item["ProductionYear"]?.toString() ?? "";
    final genres =
    (item["Genres"] as List<dynamic>? ?? []).take(3).join(" · ");

    // Same FittedBox(scaleDown) guard _buildHeroButtons already uses for
    // this column — shrinks instead of throwing a RenderFlex overflow if
    // the column is ever narrower than this row's natural width (e.g.
    // the transient width during rotation the LayoutBuilder fix above
    // now guards against, or simply a long genre/rating combination on
    // a narrower device). scaleDown only ever shrinks, never enlarges,
    // so the normal, already-fits case renders pixel-identical to
    // before.
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (year.isNotEmpty)
          Text(year,
              style: const TextStyle(
                  color: Colors.white, fontSize: 14)),
        if (year.isNotEmpty && genres.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Container(
              width: 4,
              height: 4,
              decoration: const BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
              ),
            ),
          ),
        // Was Flexible(fit: FlexFit.loose, ...) — a Flexible/Expanded
        // child requires bounded constraints from its Row, but this Row
        // now sits inside FittedBox (see the class-level comment above),
        // which measures its child under unbounded constraints before
        // scaling. Flexible + unbounded constraints throws
        // "RenderFlex children have non-zero flex but incoming width
        // constraints are unbounded". Plain Text sizes to its own
        // intrinsic width instead (genres is already capped to 3 via
        // .take(3) above, so that width is always reasonable), and
        // FittedBox's scaleDown now shrinks the whole row — including
        // this text — together if the column is ever too narrow, rather
        // than this text ellipsizing on its own.
        if (genres.isNotEmpty)
          Text(
            genres,
            style: const TextStyle(
                color: Colors.white, fontSize: 14),
          ),
        if (_hasRatingSignal(item)) ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Container(
              width: 4,
              height: 4,
              decoration: const BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
              ),
            ),
          ),
          RatingsRow(
            item: Map<String, dynamic>.from(item),
            fontSize: 14,
            textColor: Colors.white,
            badgeHeight: 14,
          ),
        ],
      ],
      ),
    );
  }

  /// Whether [item] is likely to have an IMDb/Rotten Tomatoes rating to
  /// show — used only to decide whether the separating dot before
  /// RatingsRow renders, since RatingsRow itself resolves
  /// asynchronously (or synchronously from cache) and quietly renders
  /// nothing when it comes back empty.
  bool _hasRatingSignal(dynamic item) {
    final providerIds = item["ProviderIds"];
    return providerIds is Map &&
        (providerIds["Imdb"] ?? providerIds["IMDB"] ?? providerIds["imdb"]) !=
            null;
  }

  /// "Watch Now" / "More Details" button row — shared the same way
  /// [_buildHeroMetaRow] is, by both hero layouts.
  Widget _buildHeroButtons(dynamic item) {
    final itemId = item["Id"];

    // FittedBox(scaleDown) so this row shrinks to fit whatever width
    // its column actually has instead of overflowing — the landscape
    // left column is narrow enough on some devices that the two
    // buttons at full size don't fit side by side. scaleDown only
    // ever shrinks (never enlarges), so portrait — which already has
    // plenty of room — renders at identical size to before; this only
    // engages when space is actually tight.
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: Row(
      // MainAxisSize.min so this row's width matches its buttons'
      // combined width instead of stretching to fill whatever it's
      // given. Without this, the landscape hero's left column (which
      // sizes itself off its widest child) inherits the full column
      // width from this row alone, making the Center() wrapped around
      // the whole logo/meta/buttons block a no-op — everything ends up
      // pinned to the left edge instead of centered as a group.
      mainAxisSize: MainAxisSize.min,
      children: [
        ElevatedButton.icon(
          onPressed: () async {
            final libraryItem = Map<String, dynamic>.from(item);

            // Show the player immediately with a loading overlay
            // built from what we already have for this item, rather
            // than waiting on playLibraryItem() — which may still
            // need to fetch a season/series' episodes over the
            // network before anything is playable — before ever
            // navigating there.
            PlayerManager.instance.showLoadingPreview(
              MediaService.mediaItemFromJellyfin(libraryItem),
            );

            unawaited(PlaybackService.playLibraryItem(libraryItem));

            if (!context.mounted) return;

            await PlayerNavigation.open(context);

            unawaited(_refreshResumeItems());
          },
          style: ElevatedButton.styleFrom(
            backgroundColor: gold,
            foregroundColor: Colors.black,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(30),
            ),
            padding:
            const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
          ),
          icon: const Icon(Icons.play_arrow, size: 20),
          label: const Text(
            "Watch Now",
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
        const SizedBox(width: 12),
        OutlinedButton.icon(
          onPressed: () {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => MovieDetailsScreen(
                  itemId: itemId,
                  initialItem: Map<String, dynamic>.from(item),
                ),
              ),
            );
          },
          style: OutlinedButton.styleFrom(
            foregroundColor: Colors.white,
            side: BorderSide(color: Colors.white.withValues(alpha: 0.2)),
            backgroundColor: Colors.white.withValues(alpha: 0.1),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(30),
            ),
            padding:
            const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          ),
          icon: const Icon(Icons.info_outline, size: 18),
          label: const Text("More Details"),
        ),
      ],
      ),
    );
  }

  Widget _buildSectionTitle(String title, {VoidCallback? onSeeAll}) {
    final label = Text(
      title,
      style: AppFonts.dosis(fontSize: 18, fontWeight: FontWeight.w600),
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
      child: onSeeAll == null
          ? label
          : Row(
              children: [
                Expanded(child: label),
                // Gold chevron disc on the right edge of the label row
                // (replaces the old "See all" text) — same treatment as
                // the Favorites screen's sections.
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: SeeAllChevronButton(onTap: onSeeAll),
                ),
              ],
            ),
    );
  }

  /// Recently Added rows show at most this many items; a full row is
  /// followed by a gold chevron tile that opens the same destination as
  /// the row's "See all" (see [_openLibraryNewest]).
  static const int _latestRowCap = 20;

  /// Opens [lib] exactly like tapping its card in the library row, but
  /// with the destination's "New" sort activated.
  void _openLibraryNewest(dynamic lib) {
    NavigationController.instance.openLibrary(lib, newest: true);
  }

  /// The "View all" item at the end of a full row: gold chevron disc
  /// with a caption beneath it, no card behind it (see [ViewAllRowTile]).
  Widget _seeAllTile({required double height, required VoidCallback onTap}) {
    return ViewAllRowTile(height: height, onTap: onTap);
  }

  /// Lets a horizontal row escape the page's ambient left inset (the
  /// landscape rail's width, applied by MainNavScreen so every other
  /// section — titles, grids — lines up beside the rail same as
  /// always) and scroll all the way under the rail instead of just
  /// stopping short of it. Portrait is untouched.
  ///
  /// The rail floats *over* content rather than reserving its own
  /// column, so a row that reaches x=0 is genuinely running behind
  /// it — that's what makes the rail's transparency show: at rest
  /// it's just dimmed background, but a card sliding underneath is
  /// visible, blurred, through it.
  ///
  /// Deliberately NOT a LayoutBuilder — this section rebuilds whenever
  /// a "recently added" fetch resolves, and wrapping each row in its
  /// own LayoutBuilder inside this SliverToBoxAdapter's Column tripped
  /// a Flutter element-reparenting assertion ('slot == null' in
  /// layout_builder.dart) when that rebuild landed mid-layout. A flat
  /// MediaQuery read has no element of its own, so there's nothing to
  /// reparent.
  ///
  /// OverflowBox (not a negative Padding — current Flutter's
  /// RenderPadding rejects negative insets outright) widens the row's
  /// own box out to the true screen edges while reporting the normal,
  /// rail-inset width up to its parent, so nothing above this in the
  /// Column has to change. `alignment: centerRight` pins the widened
  /// box's right edge to the true right edge and lets it spill exactly
  /// [Responsive.railWidth] past the left edge — under the rail. The
  /// row's *resting* position still lands beside the rail rather than
  /// under it because the ListView's own leading padding (see
  /// [_rowScrollPadding]) reserves that same width; scrolling just
  /// carries that padding away like any other scrollable content,
  /// letting cards slide the rest of the way under the rail.
  Widget _bleedRowUnderRail(Widget row) {
    if (!Responsive.isLandscape(context)) return row;

    // OverflowBox reports its own size directly from the incoming
    // height constraint (not the child's) — inside this sliver Column
    // that constraint is unbounded, so left as-is it tries to become
    // infinitely tall. Every row passed in here is already a
    // fixed-height SizedBox; pulling that height back out gives the
    // wrapper (and therefore OverflowBox) a real, bounded height to
    // report instead. If a future row isn't shaped that way, just skip
    // the bleed rather than risk another infinite-height crash.
    final rowHeight = row is SizedBox ? row.height : null;
    if (rowHeight == null) return row;

    // Previously re-derived from MediaQuery.sizeOf(width) minus
    // MediaQuery.viewPaddingOf().left/right, on the assumption that
    // always cancels out to exactly Responsive.railWidth of bleed. On
    // Windows desktop that held (both report zero) — but on a real
    // Pixel 6 in landscape, padding and viewPadding don't agree closely
    // enough (display-cutout/nav-bar accounting), so the row
    // over-widened and the first card ended up underneath/behind the
    // rail instead of beside it. Reading the real, already-measured
    // Stack width that MainNavScreen publishes sidesteps the mismatch
    // entirely — see Responsive.contentAreaWidth.
    final effectiveWidth = Responsive.contentAreaWidth(context);

    return SizedBox(
      height: rowHeight,
      child: OverflowBox(
        minWidth: 0,
        maxWidth: effectiveWidth,
        alignment: Alignment.centerRight,
        child: SizedBox(width: effectiveWidth, child: row),
      ),
    );
  }

  /// Horizontal scroll padding for every bled row (library icons,
  /// Continue Watching, Recently Added). Portrait is the original,
  /// untouched 20px gutter on both sides. Landscape adds
  /// [Responsive.railWidth] to the *left* only — that's what holds the
  /// first card beside the rail at rest (matching [_bleedRowUnderRail]
  /// widening the row leftward by exactly that much) — and drops the
  /// right side to 0 so the last card can scroll all the way to the
  /// true screen edge with nothing held back, instead of stopping
  /// short the way the old fixed-width layout did.
  EdgeInsets _rowScrollPadding() {
    if (Responsive.isLandscape(context)) {
      // On a real TV, the true screen edge isn't safely visible (a few
      // percent of the picture commonly clips at the edges), so the
      // last card resting flush against it — the whole point of the
      // right:0 gutter below on phone/tablet — could end up partially
      // cut off. TV alone gets a small trailing margin back; phone and
      // tablet landscape keep the exact 0 they've always had.
      final trailing = Responsive.isTV ? Responsive.contentPadding(context) : 0.0;
      return EdgeInsets.only(left: Responsive.railWidth + 20, right: trailing);
    }
    return const EdgeInsets.symmetric(horizontal: 20);
  }

  Widget _buildLibraryRow() {
    // TV alone gets a larger card — a 170dp-wide card meant for arm's-
    // length phone/tablet viewing reads as "absurdly tiny" at 10-foot
    // TV viewing distance on a 1080p/4K screen. Phone/tablet (isTV
    // false) keep the exact same 170/96 they've always had.
    final cardWidth = Responsive.isTV ? 230.0 : 170.0;
    final cardHeight = Responsive.isTV ? 130.0 : 96.0;

    return SizedBox(
      height: cardHeight,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: _rowScrollPadding(),
        itemCount: libraries.length,
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemBuilder: (context, index) {
          final lib = libraries[index];
          final libId = lib["Id"];
          final isLiveTv = lib["CollectionType"] == "livetv";

          final imageUrl = MediaService.getImageUrl(
            libId,
            type: "Primary",
            maxWidth: (cardWidth * 2).toInt(),
          );

          // Live TV's own server artwork tends to be a generic/plain image,
          // so it gets a bold "LIVE TV" label overlaid on top (with a
          // gradient scrim for legibility) rather than just the bare image
          // other library cards use. Other libraries keep their plain
          // image-only treatment.
          final fallbackLabel = isLiveTv
              ? "LIVE TV"
              : (lib["Name"] ?? "").toString().toUpperCase();

          return Pressable(
            borderRadius: BorderRadius.circular(14),
            onTap: () => NavigationController.instance.openLibrary(lib),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: Container(
                width: cardWidth,
                height: cardHeight,
                color: placeholderBg,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    CachedNetworkImage(
                      cacheManager: NemesisImageCache.instance,
                      imageUrl: imageUrl,
                      fit: BoxFit.cover,
                      placeholder: (context, url) => Container(
                        color: placeholderBg,
                      ),
                      // The label below is drawn over every card, so a
                      // failed image just leaves the plain background.
                      errorWidget: (context, url, error) => Container(
                        color: placeholderBg,
                      ),
                    ),
                    // NAMESIS PRIME: every library card is dimmed and
                    // carries its name in bold capitals, as in Jellyfin.
                    DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.black.withValues(alpha: 0.45),
                            Colors.black.withValues(alpha: 0.70),
                          ],
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      child: Align(
                        alignment: Alignment.center,
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            fallbackLabel,
                            maxLines: 1,
                            style: GoogleFonts.montserrat(
                              color: Colors.white,
                              fontWeight: FontWeight.w800,
                              fontSize: 22,
                              letterSpacing: 0.5,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildContinueWatchingRow() {
    final width = Responsive.isTV ? 280.0 : 200.0;
    const aspect = 16 / 9;

    return SizedBox(
      height: width / aspect,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: _rowScrollPadding(),
        itemCount: resumeItems.length,
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemBuilder: (context, index) {
          final item = resumeItems[index];
          final itemId = item["Id"];
          final isEpisode = item["Type"] == "Episode";

          final userData = item["UserData"] ?? {};
          final ticks = userData["PlaybackPositionTicks"] ?? 0;
          final runtimeTicks = item["RunTimeTicks"] ?? 1;
          final progress =
          runtimeTicks > 0 ? (ticks / runtimeTicks).clamp(0.0, 1.0) : 0.0;
          final remainingTicks = (runtimeTicks - ticks) > 0
              ? runtimeTicks - ticks
              : 0;
          final timeLeft = MediaService.formatRuntime(remainingTicks);

          // Episodes rarely carry their own Thumb artwork — Jellyfin's own
          // clients fall back to the parent series' image for continue
          // watching, so mirror that instead of showing a blank thumbnail.
          final imageId = isEpisode ? (item["SeriesId"] ?? itemId) : itemId;

          // Movies: skip the Thumb request when the item's own tags say
          // it has none (episodes use the series' art, whose tags we
          // don't have, so LandscapeArtImage just tries Thumb first).
          final lacksThumb =
              !isEpisode && LandscapeArtImage.itemLacksThumb(item);

          final seasonNumber = item["ParentIndexNumber"];
          final episodeNumber = item["IndexNumber"];
          final episodeLabel = (seasonNumber != null && episodeNumber != null)
              ? "S$seasonNumber E$episodeNumber"
              : null;
          final seriesName = item["SeriesName"]?.toString();
          final title = isEpisode
              ? (seriesName ?? item["Name"]?.toString() ?? "")
              : (item["Name"]?.toString() ?? "");

          return SizedBox(
            width: width,
            child: Pressable(
              borderRadius: BorderRadius.circular(10),
              onLongPress: () => _showContinueWatchingOptions(
                context,
                item,
                index,
              ),
              onTap: () async {
                // Tapping a Continue Watching card always resumes
                // playback of the tapped item directly — for episodes
                // that means the episode itself (queued alongside its
                // sibling episodes so the in-player episode list and
                // track selectors work exactly as they do from the
                // series detail screen), not the parent series detail
                // screen.
                final libraryItem = Map<String, dynamic>.from(item);

                // Show the player immediately with a loading overlay
                // built from what we already have for this item, rather
                // than waiting on playLibraryItem() — which may still
                // need to fetch a season/series' episodes over the
                // network before anything is playable — before ever
                // navigating there.
                PlayerManager.instance.showLoadingPreview(
                  MediaService.mediaItemFromJellyfin(libraryItem),
                );

                unawaited(PlaybackService.playLibraryItem(libraryItem));

                if (!context.mounted) return;

                await PlayerNavigation.open(context);

                unawaited(_refreshResumeItems());
              },
              child: Stack(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: AspectRatio(
                    aspectRatio: aspect,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        // Thumb, falling back to Backdrop (like Jellyfin's
                        // own clients) so the card is never blank.
                        LandscapeArtImage(
                          imageId: imageId.toString(),
                          maxWidth: (width * 2).toInt(),
                          knownNoThumb: lacksThumb,
                          placeholder: Container(color: placeholderBg),
                          errorWidget: Container(
                            color: placeholderBg,
                            child: const Icon(
                              Icons.movie_outlined,
                              color: Colors.white24,
                            ),
                          ),
                        ),

                        // Bottom scrim so the title stays readable over
                        // whatever's in the artwork.
                        const Positioned.fill(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                                  Colors.transparent,
                                  Colors.transparent,
                                  Color(0xD9000000),
                                ],
                                stops: [0.0, 0.4, 1.0],
                              ),
                            ),
                          ),
                        ),

                        if (timeLeft.isNotEmpty)
                          Positioned(
                            top: 8,
                            right: 8,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.6),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                "$timeLeft left",
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),

                        Positioned(
                          left: 10,
                          right: 10,
                          bottom: 16,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (isEpisode && episodeLabel != null)
                                Text(
                                  episodeLabel,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              Text(
                                title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 14,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              if (isEpisode)
                                Text(
                                  item["Name"]?.toString() ?? "",
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white70,
                                    fontSize: 11,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Positioned(
                  left: 6,
                  right: 6,
                  bottom: 6,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: progress,
                      minHeight: 4,
                      backgroundColor: Colors.white24,
                      valueColor: const AlwaysStoppedAnimation<Color>(gold),
                    ),
                  ),
                ),
              ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// Long-press menu for a Continue Watching card — "Remove from
  /// Continue Watching" (clears the saved resume position so it drops
  /// out of this row) and "More Details" (the item's/parent series'
  /// full detail screen, same destination the "info" button on the
  /// hero section already uses).
  void _showContinueWatchingOptions(
    BuildContext context,
    Map item,
    int index,
  ) {
    final itemId = item["Id"].toString();
    final isEpisode = item["Type"] == "Episode";

    // For an episode, "more details" means the parent series' page —
    // there's no standalone episode detail screen, and jumping to the
    // series is what every other "info" entry point in the app does
    // for episodes (e.g. the hero section's own info button).
    final detailId = isEpisode
        ? (item["SeriesId"]?.toString() ?? itemId)
        : itemId;

    final detailInitialItem = isEpisode
        ? <String, dynamic>{
            "Id": detailId,
            "Name": item["SeriesName"] ?? item["Name"],
            "Type": "Series",
          }
        : Map<String, dynamic>.from(item);

    // Same chrome as the video player's Info sheet (see
    // showNemesisBottomSheet's doc comment) — rounded top corners, drag
    // handle, drag up/down to resize, tap-outside/back-gesture/drag-down
    // to close. Small fractions since this sheet only ever holds two
    // rows (Remove from Continue Watching, More Details).
    showNemesisBottomSheet<void>(
      context,
      initialChildSize: 0.3,
      minChildSize: 0.18,
      maxChildSize: 0.55,
      builder: (sheetContext, scrollController) {
        return ListView(
          controller: scrollController,
          children: [
            const NemesisSheetDragHandle(topMargin: 10, bottomMargin: 8),
            ListTile(
                leading: const DustbinIcon(color: Colors.white70),
                title: const Text(
                  "Remove from Continue Watching",
                  style: TextStyle(color: Colors.white),
                ),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _removeFromContinueWatching(itemId, index);
                },
              ),
              ListTile(
                leading: const Icon(
                  Icons.info_outline,
                  color: Colors.white70,
                ),
                title: const Text(
                  "More Details",
                  style: TextStyle(color: Colors.white),
                ),
                onTap: () {
                  Navigator.pop(sheetContext);
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => MovieDetailsScreen(
                        itemId: detailId,
                        initialItem: detailInitialItem,
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(height: 8),
          ],
        );
      },
    );
  }

  /// Optimistically drops the card from the row immediately, then
  /// clears its resume position server-side — putting it back (and
  /// surfacing an error) if that call fails, rather than leaving the
  /// UI showing it gone while the server still has it in progress.
  Future<void> _removeFromContinueWatching(String itemId, int index) async {
    final removedIndex = index.clamp(0, resumeItems.length - 1);
    final removedItem = resumeItems[removedIndex];

    setState(() {
      resumeItems = List<dynamic>.from(resumeItems)
        ..removeAt(removedIndex);
    });

    try {
      await MediaService.removeFromContinueWatching(itemId);
      unawaited(_saveCache());
      // Pull in the next most-recent in-progress title to take the removed
      // card's place (when more than 30 are stored).
      if (mounted) _scheduleResumeRefresh(const Duration(milliseconds: 100));
    } catch (e) {
      if (!mounted) return;

      setState(() {
        resumeItems = List<dynamic>.from(resumeItems)
          ..insert(removedIndex.clamp(0, resumeItems.length), removedItem);
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Couldn't remove from Continue Watching"),
        ),
      );
    }
  }

  Widget _buildRecentlyAddedRow(List<dynamic> items, {VoidCallback? onSeeAll}) {
    final width = Responsive.isTV ? 190.0 : 130.0;
    const aspect = 2 / 3;

    final shown = items.length < _latestRowCap ? items.length : _latestRowCap;
    final hasSeeAllTile = onSeeAll != null && items.length >= _latestRowCap;

    return SizedBox(
      height: width / aspect,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: _rowScrollPadding(),
        itemCount: shown + (hasSeeAllTile ? 1 : 0),
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemBuilder: (context, index) {
          if (hasSeeAllTile && index == shown) {
            return _seeAllTile(height: width / aspect, onTap: onSeeAll);
          }
          final item = items[index];

          // /Items/Latest for a TV Shows library returns the newest
          // *episodes*, not the series itself — so `item` here can be
          // an Episode with its own Id, and pushing straight through
          // with that Id/item opened the episode as if it were the
          // show's own detail page instead of the series (which is
          // what browsing the library itself always resolves to,
          // since library grids only ever show Series items). Same
          // Episode -> parent series resolution the Continue Watching
          // row's "More Details" already uses.
          final itemId = item["Id"];
          final isEpisode = item["Type"] == "Episode";
          final detailId = isEpisode
              ? (item["SeriesId"]?.toString() ?? itemId)
              : itemId;
          final detailInitialItem = isEpisode
              ? <String, dynamic>{
                  "Id": detailId,
                  "Name": item["SeriesName"] ?? item["Name"],
                  "Type": "Series",
                }
              : Map<String, dynamic>.from(item);

          // Render with the series-resolved item (not the raw episode)
          // so the card shows the series' portrait poster — same shape
          // as every poster in the Movies/TV Shows grid — instead of
          // the episode's own widescreen still, which is what made
          // these cards look like a different shape than the Movies
          // screen's.
          final cardItem = isEpisode ? detailInitialItem : item;

          return SizedBox(
            width: width,
            child: MovieCard(
              item: cardItem,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => MovieDetailsScreen(
                    itemId: detailId,
                    initialItem: detailInitialItem,
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// Shown in place of [_buildRecentlyAddedRow] while that library's
  /// items are still loading — same size/shape as the real poster
  /// cards, just flat grey blocks instead of artwork.
  Widget _buildRecentlyAddedRowSkeleton() {
    final width = Responsive.isTV ? 190.0 : 130.0;
    const aspect = 2 / 3;

    return SizedBox(
      height: width / aspect,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: _rowScrollPadding(),
        physics: const NeverScrollableScrollPhysics(),
        itemCount: 6,
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemBuilder: (_, __) => SizedBox(
          width: width,
          child: AspectRatio(
            aspectRatio: aspect,
            child: Container(
              decoration: BoxDecoration(
                color: placeholderBg,
                borderRadius: BorderRadius.circular(16),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRecentlyAddedMusicRow(List<dynamic> items,
      {VoidCallback? onSeeAll}) {
    final width = Responsive.isTV ? 190.0 : 130.0;

    final shown = items.length < _latestRowCap ? items.length : _latestRowCap;
    final hasSeeAllTile = onSeeAll != null && items.length >= _latestRowCap;

    return SizedBox(
      height: width,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: _rowScrollPadding(),
        itemCount: shown + (hasSeeAllTile ? 1 : 0),
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemBuilder: (context, index) {
          if (hasSeeAllTile && index == shown) {
            return _seeAllTile(height: width, onTap: onSeeAll);
          }
          final album = items[index] as Map;
          return SizedBox(
            width: width,
            child: AlbumCard(
              album: album,
              showLabels: false,
              decodeWidth: width,
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => MusicDetailScreen(
                      itemId: album["Id"],
                      initialItem: Map<String, dynamic>.from(album),
                    ),
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }

  /// Shown in place of [_buildRecentlyAddedMusicRow] while that
  /// library's albums are still loading — same square shape as
  /// [AlbumCard]'s own artwork, just a flat grey block instead.
  Widget _buildRecentlyAddedMusicRowSkeleton() {
    final width = Responsive.isTV ? 190.0 : 130.0;

    return SizedBox(
      height: width,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: _rowScrollPadding(),
        physics: const NeverScrollableScrollPhysics(),
        itemCount: 6,
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemBuilder: (_, __) => Container(
          width: width,
          height: width,
          decoration: BoxDecoration(
            color: placeholderBg,
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
    );
  }
}

/// Clips to its full box on every side except the bottom, which stops
/// [bottomInset] px short. Used by [_HomeScreenState._buildParallaxBackdrop]
/// to keep the hero backdrop's anti-aliased clip edge landing inside the
/// zone the hero's own gradient has already darkened to fully opaque
/// nemesisBg, instead of right at the box boundary where a translucent
/// sliver of the raw image color can bleed through while the backdrop's
/// scale/translate are animating during scroll.
class _HeroBackdropClipper extends CustomClipper<Rect> {
  const _HeroBackdropClipper(this.bottomInset, {this.leftInset = 0.0});

  final double bottomInset;

  /// Left-edge trim (landscape hero only; 0 for portrait).
  final double leftInset;

  @override
  Rect getClip(Size size) {
    final height = (size.height - bottomInset).clamp(0.0, size.height);
    final left = leftInset.clamp(0.0, size.width);
    return Rect.fromLTWH(left, 0, size.width - left, height);
  }

  @override
  bool shouldReclip(covariant _HeroBackdropClipper oldClipper) =>
      oldClipper.bottomInset != bottomInset ||
      oldClipper.leftInset != leftInset;
}
