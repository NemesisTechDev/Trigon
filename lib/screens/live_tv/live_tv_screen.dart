import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'live_tv_detail_screen.dart';
import 'tv_guide_screen.dart';
import 'all_channels_screen.dart';
import '../../widgets/live_tv/live_tv_header.dart';
import '../../widgets/common/empty_state.dart';
import '../../utils/channel_categories.dart';
import '../../services/favorite_service.dart';
import '../../widgets/live_tv/featured_channel.dart';
import '../../widgets/live_tv/live_section.dart';
import '../../utils/responsive.dart';

import '../../services/jellyfin_services/media_service.dart';
import '../../services/jellyfin_services/storage_service.dart';
import '../../services/cache/library_cache.dart';
import '../../services/library_prefetcher.dart';
import '../../player/playback_service.dart';
import '../../player/player_manager.dart';
import '../../player/screens/player_navigation.dart';
import '../../widgets/common/resistive_refresh.dart';
import '../../widgets/common/collapsing_screen_label.dart';
import '../../utils/bottom_clearance.dart';
import '../main_nav/navigation_controller.dart';

class LiveTvScreen extends StatefulWidget {
  const LiveTvScreen({super.key});

  /// Hero height for the featured-channel carousel. Portrait keeps its
  /// existing screen-height-based sizing untouched. Landscape used to
  /// hand this straight to [Responsive.heroHeight] with the same
  /// 292-396 range phone landscape uses everywhere else — but that
  /// range was tuned for an ~411dp-tall phone screen, and a TV is
  /// landscape too without being that. Feeding a 1080p/4K TV through
  /// the phone-landscape numbers would leave a huge, unused gap below
  /// a hero that has real room to spend, so TV gets its own taller
  /// range instead — the exact distinction Home's hero carousel
  /// already makes for the same reason (see home_screen.dart's isTV
  /// branch). A static method on the public widget (rather than left
  /// inline in the private State's build, or on the State itself) so
  /// it's directly testable via a bare BuildContext, without needing
  /// to mount the whole network-backed screen.
  @visibleForTesting
  static double heroHeightFor(BuildContext context) {
    if (!Responsive.isLandscape(context)) {
      // Aspect-scoped (MediaQuery.sizeOf) instead of the unscoped
      // MediaQuery.of(context) this used to call — that subscribed this
      // hero-height calculation to *every* MediaQueryData field, including
      // viewInsets.bottom, which flips on every frame while any keyboard
      // animates anywhere in the app (every bottom-nav tab is kept alive
      // together in an IndexedStack). sizeOf only rebuilds when the actual
      // screen size changes (rotation, foldable, etc.), which is the only
      // thing this calculation cares about.
      return (MediaQuery.sizeOf(context).height * 0.5).clamp(360.0, 460.0);
    }
    if (Responsive.isTV) {
      return Responsive.heroHeight(
        context,
        portraitHeight: 420,
        landscapeFraction: 0.5,
        landscapeMin: 450,
        landscapeMax: 900,
      );
    }
    return Responsive.heroHeight(
      context,
      portraitHeight: 420,
      landscapeFraction: 0.97,
      landscapeMin: 292,
      landscapeMax: 396,
    );
  }

  @override
  State<LiveTvScreen> createState() => _LiveTvScreenState();
}

class _LiveTvScreenState extends State<LiveTvScreen> {

  List channels = [];

  List favoriteChannels = [];

  List sportsChannels = [];
  List movieChannels = [];
  List newsChannels = [];
  List kidsChannels = [];
  List musicChannels = [];
  List documentaryChannels = [];
  List entertainmentChannels = [];

  List featuredChannels = [];

  Timer? _heroTimer;

  // Set when loadChannels()'s catch block fires with no channels to
  // fall back on (neither a fresh load nor a warm cache). Previously
  // a failure here just left `channels` empty with no signal to the
  // UI, so the screen sat on its loading spinner forever with no way
  // to retry — indistinguishable from "still loading" even after the
  // request had already failed.
  bool loadFailed = false;

  // Set once the first load cycle (cache or network) has actually
  // finished, success or failure. Without this, a server that's simply
  // never had any Live TV channels configured looked identical to
  // "still loading" — channels stayed empty and loadFailed stayed
  // false, so the screen sat on its spinner forever instead of ever
  // showing a genuine empty state.
  bool _loadAttempted = false;

  int currentHero = 0;

  // Same pair of flags as Home's hero carousel (see home_screen.dart for
  // the fuller rationale): _heroDirection records which way the hero is
  // moving so the backdrop's crossfade can slide the right direction,
  // and _heroHeld pauses the autoplay timer for as long as the user is
  // pressing and holding the hero.
  int _heroDirection = 1;
  bool _heroHeld = false;

  Map<String, dynamic> programs = {};

  // Drives the hero backdrop's parallax lag + zoom, same mechanism as
  // Home's hero carousel (see FeaturedChannel's _buildParallaxBackdrop):
  // a dedicated ScrollController feeds a ValueNotifier<double> so the
  // backdrop's Transform.scale/translate rebuilds on its own each
  // scroll frame instead of the whole screen doing so via setState.
  final ScrollController _scrollController = ScrollController();
  final ValueNotifier<double> _heroScrollOffset = ValueNotifier<double>(0);

  @override
  void initState() {
    super.initState();

    _scrollController.addListener(() {
      _heroScrollOffset.value = _scrollController.offset;
    });

    // If the background prewarm already loaded the channels (+ guide), the
    // very first frame shows them — no empty state, no waiting.
    _seedFromMemory();

    _bootstrap();
  }

  /// Synchronous (runs from initState, before the first build): applies the
  /// channels/guide LibraryPrefetcher — or an earlier visit — left in
  /// memory. Favorites need an async SharedPreferences read, so that row
  /// follows a moment later from _bootstrap.
  void _seedFromMemory() {
    final payload = LibraryCache.instance.peek(LibraryFeeds.liveTvKey);
    if (payload is! Map) return;

    final cachedChannels = payload["channels"];
    if (cachedChannels is! List || cachedChannels.isEmpty) return;

    channels = List<dynamic>.from(cachedChannels);

    final cachedPrograms = payload["programs"];
    if (cachedPrograms is Map) {
      programs
        ..clear()
        ..addAll(Map<String, dynamic>.from(cachedPrograms));
    }

    classifyChannels();
    buildFeaturedChannels();
  }

  /// Paints instantly from the last cached channel list + guide (if any)
  /// while a fresh copy loads underneath, the same stale-while-revalidate
  /// pattern Home uses. Without this, every visit to the tab sat behind a
  /// full round trip to the slowest endpoint in the app.
  Future<void> _bootstrap() async {
    // Already painted from the in-memory copy (see _seedFromMemory), which
    // is at least as new as the persisted one — don't re-read/re-decode it.
    final seededFromMemory = channels.isNotEmpty;

    String? cached;
    if (!seededFromMemory) {
      try {
        cached = await StorageService.getLiveTvCache();
      } catch (_) {
        cached = null;
      }
    } else {
      try {
        final favoriteIds = await FavoriteService.getFavorites();
        favoriteChannels = channels.where((channel) {
          return favoriteIds.contains(channel["Id"]);
        }).toList();
        if (mounted) setState(() {});
      } catch (_) {
        // Favorites row just stays empty until loadChannels fills it.
      }
    }

    if (cached != null && mounted) {
      try {
        // ROOT CAUSE of the lag on first tap: this jsonDecode of the whole
        // persisted channels+guide blob ran synchronously on the UI thread
        // the moment the tab opened. It's decoded in a background isolate
        // now (the decoded result is handed back without copying).
        final decoded = await compute(_decodeLiveTvCache, cached);
        if (!mounted) return;

        channels = List<dynamic>.from(decoded["channels"] ?? []);

        final decodedPrograms =
            decoded["programs"] as Map<String, dynamic>? ?? {};
        programs
          ..clear()
          ..addAll(decodedPrograms);

        classifyChannels();
        buildFeaturedChannels();

        final favoriteIds = await FavoriteService.getFavorites();
        favoriteChannels = channels.where((channel) {
          return favoriteIds.contains(channel["Id"]);
        }).toList();

        if (mounted) setState(() {});
      } catch (_) {
        // Corrupt/old-shape cache — ignore and fall through to a normal load.
      }
    }

    // Always refresh from the network. If cache already painted, this
    // happens silently underneath (no spinner reset).
    await loadChannels(silent: cached != null || seededFromMemory);
  }

  Future<void> loadChannels({bool silent = false}) async {
    try {
      loadFailed = false;
      // Channels and favorites are cheap — fetch them first and paint
      // immediately instead of gating the whole screen (hero, sections,
      // channel art) behind the guide, which is by far the slowest call
      // this screen makes. The guide then fills in "now + next" info on
      // top of a channel list that's already on screen.
      // Via LibraryFeeds so that if the background prewarm is already
      // downloading these (it starts a few seconds after launch), this
      // joins that request instead of issuing a second identical one.
      final channelsResult = await LibraryFeeds.liveTvChannels();
      final favoriteIds = await FavoriteService.getFavorites();

      channels = channelsResult;

      classifyChannels();
      buildFeaturedChannels();

      favoriteChannels = channels.where((channel) {
        return favoriteIds.contains(channel["Id"]);
      }).toList();

      if (mounted) {
        setState(() {});
      }

      // Guide window trimmed from a full 12 hours down to 3 — this screen
      // only ever shows "now + next" per channel, so there's no reason to
      // page through a much bigger result set than that just to sit on it.
      // Also scoped to this screen's own channel IDs — some Jellyfin Live
      // TV backends (IPTV/Xtream-style tuners especially) compute EPG
      // data by walking every configured channel for any unscoped
      // request, so an unfiltered call's cost scales with total channel
      // count rather than the date window requested.
      final channelIds = channels
          .map((channel) => channel["Id"]?.toString())
          .whereType<String>()
          .toList();
      final guide = await LibraryFeeds.liveTvGuide(channelIds);

      programs
        ..clear()
        ..addAll(LibraryFeeds.groupGuide(guide));

      // Remembered in memory too, so reopening this tab (or a rebuilt
      // screen) paints instantly with the guide already attached.
      LibraryCache.instance.putMemory(LibraryFeeds.liveTvKey, {
        "channels": channels,
        "programs": Map<String, dynamic>.from(programs),
        "guideLoaded": true,
      });

      try {
        await StorageService.saveLiveTvCache(jsonEncode({
          "channels": channels,
          "programs": programs,
        }));
      } catch (_) {
        // Non-fatal — just means next launch won't have a warm cache.
      }

    } catch (e, stackTrace) {

      debugPrint(e.toString());
      debugPrint(stackTrace.toString());

      // Only surface the error state if there's genuinely nothing to
      // show (no cache, no previous successful load) — a background
      // refresh failing shouldn't rip away channels that are already
      // on screen.
      if (channels.isEmpty) {
        loadFailed = true;
      }

    }

    _loadAttempted = true;

    if (mounted) {
      setState(() {});
    }
  }

  void classifyChannels() {
    sportsChannels.clear();
    movieChannels.clear();
    newsChannels.clear();
    kidsChannels.clear();
    musicChannels.clear();
    documentaryChannels.clear();
    entertainmentChannels.clear();

    for (final channel in channels) {
      final name = (channel["Name"] ?? "").toString();

      // Each channel lands in exactly one bucket now — ChannelCategories
      // .classify() picks the most specific match (see priority order
      // there), so a channel can't be miscategorized by an earlier,
      // overly-generic keyword grabbing it first.
      switch (ChannelCategories.classify(name)) {
        case "Sports":
          sportsChannels.add(channel);
          break;
        case "News":
          newsChannels.add(channel);
          break;
        case "Movies":
          movieChannels.add(channel);
          break;
        case "Kids":
          kidsChannels.add(channel);
          break;
        case "Music":
          musicChannels.add(channel);
          break;
        case "Documentaries":
          documentaryChannels.add(channel);
          break;
        case "Entertainment":
        default:
          entertainmentChannels.add(channel);
          break;
      }
    }
  }

  void buildFeaturedChannels() {
    featuredChannels.clear();
    currentHero = 0;

    featuredChannels.addAll(sportsChannels.take(3));
    featuredChannels.addAll(kidsChannels.take(2));
    featuredChannels.addAll(movieChannels.take(1));
    featuredChannels.addAll(documentaryChannels.take(2));
    featuredChannels.addAll(newsChannels.take(1));
    featuredChannels.addAll(musicChannels.take(1));
    featuredChannels.addAll(entertainmentChannels.take(1));

    if (featuredChannels.length < 10) {
      for (final channel in channels) {
        if (!featuredChannels.any((c) => c["Id"] == channel["Id"])) {
          featuredChannels.add(channel);

          if (featuredChannels.length == 10) {
            break;
          }
        }
      }
    }

    startHeroCarousel();
  }



  void startHeroCarousel() {
    _heroTimer?.cancel();

    if (featuredChannels.length <= 1) return;

    _heroTimer = Timer.periodic(
      const Duration(seconds: 6),
          (Timer timer) {
        if (!mounted) return;
        // Don't advance out from under an active press-and-hold.
        if (_heroHeld) return;
        // Nobody can see the hero while another tab is selected or a
        // screen is pushed over this one, so don't rebuild this whole
        // screen (and start loading the next hero image) behind them —
        // that landed mid-scroll/mid-transition elsewhere in the app.
        if (NavigationController.instance.tabIndex != NavTabs.liveTv ||
            !(ModalRoute.of(context)?.isCurrent ?? true)) {
          return;
        }

        setState(() {
          _heroDirection = 1;
          currentHero = (currentHero + 1) % featuredChannels.length;
        });
      },
    );
  }

  /// Steps the hero forward (`delta == 1`) or backward (`delta == -1`),
  /// wrapping at either end, and records the direction so the backdrop
  /// crossfade slides the right way. Restarts the autoplay timer
  /// afterwards so a manual swipe isn't immediately undone by an
  /// autoplay tick already in flight.
  void _stepHero(int delta) {
    final length = featuredChannels.length;
    if (length == 0) return;
    setState(() {
      _heroDirection = delta.sign == 0 ? 1 : delta.sign;
      currentHero = ((currentHero + delta) % length + length) % length;
    });
    startHeroCarousel();
  }

  /// Interprets a completed horizontal drag on the hero as a swipe to
  /// the previous/next featured channel. Only a fling with enough
  /// horizontal velocity counts; a slow drag released near where it
  /// started is ignored.
  void _onHeroHorizontalDragEnd(DragEndDetails details) {
    if (featuredChannels.length <= 1) return;
    final velocity = details.primaryVelocity ?? 0;
    const flingThreshold = 150.0;
    if (velocity <= -flingThreshold) {
      _stepHero(1);
    } else if (velocity >= flingThreshold) {
      _stepHero(-1);
    }
  }

  // Not a setState — nothing needs to visibly change when a hold
  // starts/ends, this flag is only read by the autoplay timer above.
  void _setHeroHeld(bool held) {
    _heroHeld = held;
  }

  /// Shared transitionBuilder for the featured-channel hero backdrop —
  /// same mechanism as Home's hero (see home_screen.dart's
  /// _buildHeroSlideTransition). Purely a crossfade now — entering and
  /// leaving backdrops fade in/out in place with no horizontal motion.
  /// `_heroDirection` is still set by the swipe handler and autoplay to
  /// pick which item comes up next (left swipe => previous, right swipe
  /// => next, hold => stay on the current one) — it just no longer
  /// drives a slide offset here.
  Widget _buildHeroSlideTransition(Widget child, Animation<double> animation) {
    final curved = CurvedAnimation(parent: animation, curve: Curves.easeInOut);
    return FadeTransition(opacity: curved, child: child);
  }

  Future<void> loadFavorites() async {

    final ids = await FavoriteService.getFavorites();

    favoriteChannels = channels.where((channel) {
      return ids.contains(channel["Id"]);
    }).toList();

  }
  /// A category row's "See all" / gold chevron tile: opens the All
  /// Channels page with that category's chip already selected — same
  /// page (and same refresh-favorites-on-return) as the Live TV header's
  /// "All Channels" button.
  Future<void> _openCategory(String category) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => AllChannelsScreen(
          title: "All Channels",
          channels: channels,
          programs: programs,
          initialCategory: category,
        ),
      ),
    );

    await loadFavorites();

    if (mounted) {
      setState(() {});
    }
  }

  Future<void> openChannel(Map channel) async {

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => LiveTvDetailScreen(
          channelId: channel["Id"],
          initialItem: Map<String, dynamic>.from(channel),
          allChannels: channels,
          initialPrograms: programs[channel["Id"]] as List?,
        ),
      ),
    );

    await loadFavorites();

    if (mounted) {
      setState(() {});
    }
  }

  /// Starts the channel's playback immediately, used by the "Watch Live"
  /// button on the featured channel hero card. Unlike [openChannel], this
  /// doesn't just navigate to the channel's detail screen — it starts the
  /// stream right away and takes the user straight into the player.
  Future<void> playChannel(Map channel) async {
    final media = MediaService.mediaItemFromJellyfin(
      Map<String, dynamic>.from(channel),
    );

    // Show the player immediately with a loading overlay instead of
    // waiting on the stream to open before navigating there.
    PlayerManager.instance.showLoadingPreview(media);
    unawaited(PlaybackService.playItem(media));

    if (!mounted) return;

    await PlayerNavigation.open(context);
  }

  @override
  void dispose() {
    _heroTimer?.cancel();
    _scrollController.dispose();
    _heroScrollOffset.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Aspect-scoped — only rebuilds this screen when device padding
    // itself changes (rotation, notch/gesture-area changes), never on
    // keyboard insets (this screen's own, or — since every bottom-nav
    // tab is kept alive together in an IndexedStack — one open on a
    // completely different tab). See the `viewPadding` swap below.
    final viewPadding = MediaQuery.paddingOf(context);

    return Scaffold(
      backgroundColor: const Color(0xff161616),

      // No bottom padding is added below (see the Padding replacing
      // SafeArea further down) — otherwise this CustomScrollView gets
      // pushed away from the bottom edge entirely, leaving nothing for
      // the glass bottom nav bar's BackdropFilter to blur (it'd just
      // read as a flat solid color). The trailing SliverToBoxAdapter
      // below adds dynamic clearance instead, so content still stops
      // above the bar.
      //
      // Was SafeArea(bottom: false) here. SafeArea's own build() calls
      // the *unscoped* MediaQuery.of(context) internally, which
      // subscribes it to every MediaQueryData field — including
      // viewInsets.bottom, which the framework updates every single
      // frame while any keyboard is sliding open or closed anywhere in
      // the app (every tab stays mounted in the same IndexedStack). That
      // forced this whole hero/sections tree to rebuild from scratch in
      // lockstep with the keyboard's own animation — the same
      // app-wide stutter fixed the same way on Music/Movies. A plain
      // Padding using the aspect-scoped `viewPadding` above gets the
      // identical top/left/right safe-area values (bottom was already
      // excluded) but only rebuilds when device padding itself actually
      // changes.
      body: Padding(
        padding: EdgeInsets.only(
          top: viewPadding.top,
          left: viewPadding.left,
          right: viewPadding.right,
        ),
        child: channels.isEmpty && loadFailed
            ? Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.live_tv_outlined,
                  color: Colors.white38, size: 48),
              const SizedBox(height: 16),
              const Text(
                "Couldn't load Live TV",
                style: TextStyle(color: Colors.white70, fontSize: 16),
              ),
              const SizedBox(height: 20),
              OutlinedButton(
                onPressed: () => loadChannels(),
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xffD4AF37),
                  side: const BorderSide(color: Color(0xffD4AF37)),
                ),
                child: const Text("Retry"),
              ),
            ],
          ),
        )
            : channels.isEmpty && !_loadAttempted
            ? const Center(
          child: CircularProgressIndicator(
            color: Color(0xffD4AF37),
          ),
        )
            : channels.isEmpty
            ? const Center(
          child: EmptyState(
            icon: Icons.live_tv_outlined,
            title: "No live TV content fetched",
            subtitle: "Channels from your server will show up here once "
                "Live TV is configured.",
          ),
        )
            // LabelCollapseScope: the "Live TV" label (inside LiveTvHeader)
            // slides away on scroll down and returns on scroll up; the
            // All Channels/Favorites chips stay pinned.
            : LabelCollapseScope(
          child: Column(
          children: [

            /// Header — title + All Channels/Favorites chips stay fixed
            /// in place, matching the Music screen, instead of
            /// scrolling away with the hero banner and sections below.
            LiveTvHeader(
              onGuidePressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => TvGuideScreen(
                      initialChannels:
                          List<Map<String, dynamic>>.from(channels),
                    ),
                  ),
                );
              },

              onAllChannels: () async {

                await Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => AllChannelsScreen(
                      title: "All Channels",
                      channels: channels,
                      programs: programs,
                    ),
                  ),
                );

                await loadFavorites();

                if (mounted) {
                  setState(() {});
                }

              },

              onFavorites: () async {

                await loadFavorites();

                if (!context.mounted) return;

                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => AllChannelsScreen(
                      title: "Favorites",
                      channels: favoriteChannels,
                      programs: programs,
                    ),
                  ),
                );
              },

              onRecent: () {},
            ),

            Expanded(
              child: ResistiveRefresh(
                onRefresh: () => loadChannels(silent: true),
                color: const Color(0xffD4AF37),
                backgroundColor: const Color(0xff232323),
                child: CustomScrollView(
                  controller: _scrollController,
                  // Keeps pull-to-refresh working even when the channel
                  // list is short enough that the content doesn't
                  // overflow the viewport (same fix as Home/Downloads).
                  physics: const AlwaysScrollableScrollPhysics(),
                  slivers: [

                  /// Hero Banner

                  SliverToBoxAdapter(
                    child: Builder(
                      builder: (context) {
                        // Sized like Home's hero carousel now that this
                        // is a full-bleed hero rather than a compact
                        // floating card — portrait scales off screen
                        // height, landscape off Responsive.heroHeight
                        // (TV gets its own taller range — see
                        // heroHeightFor's doc comment). Computed once
                        // here (rather than inline on the SizedBox) so
                        // the same value can also be handed to
                        // FeaturedChannel as the clamp bound for its
                        // parallax backdrop.
                        final heroHeight = LiveTvScreen.heroHeightFor(context);

                        return SizedBox(
                          height: heroHeight,
                          child: featuredChannels.isEmpty
                              ? const SizedBox()
                              : GestureDetector(
                            // translucent so drags/holds are still
                            // recognized over the hero's transparent
                            // gradient areas, while taps on the
                            // FeaturedChannel content underneath still
                            // reach it.
                            behavior: HitTestBehavior.translucent,
                            onHorizontalDragEnd: _onHeroHorizontalDragEnd,
                            onLongPressStart: (_) => _setHeroHeld(true),
                            onLongPressEnd: (_) => _setHeroHeld(false),
                            onLongPressCancel: () => _setHeroHeld(false),
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
                            child: Builder(
                              key: ValueKey(featuredChannels[currentHero]["Id"]),
                              builder: (context) {
                                final channel = featuredChannels[currentHero];

                                return FeaturedChannel(
                                  channel: channel,
                                  program: (programs[channel["Id"]] as List?)?.first,
                                  onTap: () => playChannel(channel),
                                  heroHeight: heroHeight,
                                  scrollOffset: _heroScrollOffset,
                                );
                              },
                            ),
                          ),
                          ),
                        );
                      },
                    ),
                  ),

                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: List.generate(
                          featuredChannels.length,
                              (index) => AnimatedContainer(
                            duration: const Duration(milliseconds: 250),
                            margin: const EdgeInsets.symmetric(horizontal: 4),
                            width: currentHero == index ? 24 : 8,
                            height: 8,
                            decoration: BoxDecoration(
                              color: currentHero == index
                                  ? const Color(0xffD4AF37)
                                  : Colors.white24,
                              borderRadius: BorderRadius.circular(20),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SliverToBoxAdapter(
                    child: SizedBox(height: 25),
                  ),

                  SliverList(
                    delegate: SliverChildListDelegate(
                      [
                        if (favoriteChannels.isNotEmpty)
                          LiveSection(
                            title: "Favorites",
                            channels: favoriteChannels,
                            programs: programs,
                            onTap: openChannel,
                          ),

                        if (favoriteChannels.isNotEmpty)
                          const SizedBox(height: 35),

                        if (channels.isEmpty)
                          const Padding(
                            padding: EdgeInsets.all(40),
                            child: Center(
                              child: Text(
                                "No Live TV channels found",
                                style: TextStyle(
                                  color: Colors.white54,
                                  fontSize: 18,
                                ),
                              ),
                            ),
                          ),

                        LiveSection(
                          title: "Recently Watched",
                          channels: channels.take(8).toList(),
                          programs: programs,
                          onTap: openChannel,
                        ),

                        const SizedBox(height: 35),

                        LiveSection(
                          title: "Sports",
                          channels: sportsChannels,
                          programs: programs,
                          onTap: openChannel,
                          onSeeAll: () => _openCategory("Sports"),
                        ),

                        const SizedBox(height: 35),

                        LiveSection(
                          title: "Movies",
                          channels: movieChannels,
                          programs: programs,
                          onTap: openChannel,
                          onSeeAll: () => _openCategory("Movies"),
                        ),

                        const SizedBox(height: 35),

                        LiveSection(
                          title: "News",
                          channels: newsChannels,
                          programs: programs,
                          onTap: openChannel,
                          onSeeAll: () => _openCategory("News"),
                        ),

                        const SizedBox(height: 35),

                        LiveSection(
                          title: "Kids",
                          channels: kidsChannels,
                          programs: programs,
                          onTap: openChannel,
                          onSeeAll: () => _openCategory("Kids"),
                        ),

                        const SizedBox(height: 35),

                        LiveSection(
                          title: "Music",
                          channels: musicChannels,
                          programs: programs,
                          onTap: openChannel,
                          onSeeAll: () => _openCategory("Music"),
                        ),

                        const SizedBox(height: 35),

                        LiveSection(
                          title: "Documentaries",
                          channels: documentaryChannels,
                          programs: programs,
                          onTap: openChannel,
                          onSeeAll: () => _openCategory("Documentaries"),
                        ),

                        const SizedBox(height: 35),

                        LiveSection(
                          title: "Entertainment",
                          channels: entertainmentChannels,
                          programs: programs,
                          onTap: openChannel,
                          onSeeAll: () => _openCategory("Entertainment"),
                        ),

                        const SizedBox(height: 40),

                      ],
                    ),
                  ),

                  SliverToBoxAdapter(
                    child: BottomClearanceBuilder(
                      builder: (context, bottomClearance) => SizedBox(
                        // Aspect-scoped — same reasoning as the viewPadding swap
                      // above: MediaQuery.of(context) here would subscribe this
                      // trailing spacer (and, since InheritedWidget notifies
                      // whole-object, everything else in this same build
                      // method) to keyboard-driven viewInsets changes it
                      // never needed.
                      height: 30 +
                            MediaQuery.paddingOf(context).bottom +
                            bottomClearance,
                      ),
                    ),
                  ),

                ],
              ),
              ),
            ),
          ],
        ),
        ),
      ),
    );
  }
}

// Top-level so compute() can run it in a background isolate.
Map<String, dynamic> _decodeLiveTvCache(String text) =>
    jsonDecode(text) as Map<String, dynamic>;
