import 'dart:async';

import 'package:flutter/material.dart';
import '../../utils/responsive.dart';
import '../../widgets/live_tv/upcoming_program_timeline.dart';
import '../../widgets/live_tv/now_playing_section.dart';
import '../../widgets/live_tv/channel_logo_card.dart';
import '../../widgets/shared/collapsing_detail_header.dart';
import '../../widgets/shared/scroll_linked_detail_backdrop.dart';
import '../../services/favorite_service.dart';
import '../../player/playback_service.dart';
import '../../player/player_manager.dart';
import '../../player/screens/player_navigation.dart';
import '../../utils/channel_categories.dart';
import '../../utils/epg_utils.dart';
import '../../widgets/common/resistive_refresh.dart';
import '../movie_details/widgets/landscape_backdrop_bg.dart';
import '../movie_details/widgets/cast_to_button.dart';
import '../../widgets/music/music_landscape_header.dart';
import '../../utils/logo_trimmer.dart';

import '../../services/jellyfin_services/media_service.dart';
import '../../utils/bottom_clearance.dart';
import '../../widgets/common/stacked_action_bar.dart';
import 'tv_guide_screen.dart';

class LiveTvDetailScreen extends StatefulWidget {
  final String channelId;

  /// Whatever the tapped channel card already had in memory (logo,
  /// name, etc). When present, the screen paints with this immediately
  /// instead of a blank spinner, then silently swaps in the
  /// authoritative full record once it loads.
  final Map<String, dynamic>? initialItem;

  /// The full channel list, if the screen that navigated here already
  /// had it loaded (home screen, All Channels). When present, "More
  /// Channels" renders immediately and the redundant channel-list
  /// network call is skipped entirely.
  final List? allChannels;

  /// This channel's upcoming programs, if the screen that navigated
  /// here already had them loaded from its own guide fetch. When
  /// present, "Now Playing" and "Coming Up" render immediately and the
  /// redundant per-channel programs call is skipped entirely.
  final List? initialPrograms;

  const LiveTvDetailScreen({
    super.key,
    required this.channelId,
    this.initialItem,
    this.allChannels,
    this.initialPrograms,
  });

  @override
  State<LiveTvDetailScreen> createState() =>
      _LiveTvDetailScreenState();
}

class _LiveTvDetailScreenState
    extends State<LiveTvDetailScreen> {
  bool loading = true;

  // Vertical scroll offset of the page's CustomScrollView. Feeds
  // ScrollLinkedDetailBackdrop: in portrait the header backdrop is
  // painted behind the scroll view (so it can reach below the header
  // sliver and sit under the channel logo) and needs the offset to
  // shrink/scroll away in step with the page. Fed by a
  // ScrollOffsetReporter around the CustomScrollView.
  final ValueNotifier<double> _heroScrollOffset = ValueNotifier<double>(0);

  Map<String, dynamic>? channel;

  List programs = [];

  Map<String, dynamic>? currentProgram;

  /// Gates the "Now Playing"/"Coming Up" sections independently of
  /// everything else on the page — see [_loadProgramsInBackground].
  bool programsReady = false;

  // The full channel list this screen knows about (every channel,
  // unfiltered) — kept around so "More Channels" can be re-filtered by
  // category whenever the current channel changes, and so that full
  // pool (not just the narrowed-down subset shown here) gets handed
  // to the next screen when navigating to one of them.
  List allChannelsCache = [];

  List relatedChannels = [];

  /// Channel id -> that channel's programs (now + upcoming), for every
  /// channel in [relatedChannels]. Populated alongside the related
  /// channels list itself (see [_loadRelatedInBackground]) so that
  /// tapping a "More Channels" card can hand the next detail screen its
  /// own initialPrograms — the same fast-paint trick this screen
  /// receives from the Live TV / All Channels screens — instead of
  /// leaving its "Now Playing"/"Coming Up" to fade in from a blank
  /// start every time someone drills from channel to channel.
  Map<String, dynamic> relatedPrograms = {};

  bool isFavorite = false;

  /// Ticks once a minute so the "Now Playing" progress bar (and its
  /// start/end labels, if the program has actually changed) stay live
  /// instead of freezing at whatever [_programProgress] computed the
  /// moment the screen first loaded. `setState` here is a no-op render
  /// cost-wise beyond recomputing that one value — nothing here
  /// re-fetches anything.
  Timer? _progressTicker;

  /// "More Channels" only makes sense as channels from the same
  /// category as the one currently being viewed — otherwise it was
  /// just an unsorted dump of the entire channel list, current
  /// channel's genre notwithstanding.
  List _filterRelated(List all, String? currentName, String currentId) {
    if (currentName == null || currentName.isEmpty) {
      return List.from(all)..removeWhere((c) => c["Id"] == currentId);
    }

    final category = ChannelCategories.classify(currentName);

    return all.where((c) {
      if (c["Id"] == currentId) return false;
      final name = c["Name"] ?? "";
      return ChannelCategories.classify(name) == category;
    }).toList();
  }

  @override
  void initState() {
    super.initState();
    // Paint immediately with the preview from whatever channel card got
    // us here; loadChannel() below fetches the authoritative record
    // and silently replaces it (no spinner) once it's ready.
    channel = widget.initialItem;
    loading = widget.initialItem == null;

    // Same idea for programs and the related-channels list: if the
    // previous screen already had these loaded, use them right away
    // instead of leaving "Coming Up" / "More Channels" blank until a
    // fresh fetch comes back.
    if (widget.initialPrograms != null) {
      programs = widget.initialPrograms!;
      currentProgram = _pickCurrentProgram(programs);
      programsReady = true;
    }
    if (widget.allChannels != null) {
      allChannelsCache = List.from(widget.allChannels!);
      relatedChannels = _filterRelated(
        allChannelsCache,
        widget.initialItem?["Name"],
        widget.channelId,
      );
    }

    loadChannel();

    _progressTicker = Timer.periodic(const Duration(minutes: 1), (_) {
      if (!mounted) return;
      setState(() {});
    });
  }

  @override
  void dispose() {
    _progressTicker?.cancel();
    _heroScrollOffset.dispose();
    super.dispose();
  }

  Future<void> loadChannel() async {
    final hadPreview = channel != null;

    if (!hadPreview) {
      setState(() {
        loading = true;
      });
    }

    // The authoritative channel record is a single, fast lookup — it
    // used to be bundled into the same Future.wait as the programs/EPG
    // fetch below, which is often much heavier. That meant everything
    // (including the header, which could otherwise update the moment
    // this alone resolves) sat waiting on whichever of the two was
    // slower. Splitting them lets the header settle immediately and
    // "Now Playing"/"Coming Up" fade in separately, on their own time,
    // via [programsReady] below.
    final loadedChannel =
        await MediaService.getLiveTvChannel(widget.channelId);

    if (!mounted) return;

    setState(() {
      channel = loadedChannel;
      loading = false;
    });

    // Always refreshed, even when initialPrograms was already supplied.
    // The Live TV / All Channels screens' initialPrograms come from the
    // bulk /LiveTv/Programs guide call, which deliberately omits
    // "Overview" to keep that (potentially thousand-program) payload
    // small — so a preview built from it would show correct names/times
    // instantly but permanently blank descriptions. This per-channel
    // call is cheap (one channel, Limit 10, "Fields": "Overview") and
    // runs silently in the background: programsReady is already true
    // in that case, so nothing hides while it swaps the real, richer
    // data in underneath what's already on screen.
    _loadProgramsInBackground();

    _loadRelatedInBackground(loadedChannel["Name"]?.toString());
  }

  /// Runs independently of loadChannel() so a slow EPG/programs fetch
  /// never holds up the header or the rest of the page — "Now Playing"
  /// and "Coming Up" simply stay hidden (see [programsReady]) until
  /// this resolves, then fade in on their own, the same pattern the
  /// movie details screen uses for its collection row.
  Future<void> _loadProgramsInBackground() async {
    final loadedPrograms =
        await MediaService.getPrograms(channelId: widget.channelId);

    if (!mounted) return;

    setState(() {
      programs = loadedPrograms;
      currentProgram = _pickCurrentProgram(loadedPrograms);
      programsReady = true;
    });
  }

  Future<void> _loadRelatedInBackground(String? channelName) async {
    final needsAllChannels = widget.allChannels == null;

    final results = await Future.wait([
      needsAllChannels
          ? MediaService.getLiveTvChannels()
          : Future.value(widget.allChannels),
      FavoriteService.isFavorite(widget.channelId),
    ]);

    final allChannels = results[0] as List;
    final favoriteStatus = results[1] as bool;

    final loadedRelated = _filterRelated(
      allChannels,
      channelName,
      widget.channelId,
    );

    if (!mounted) return;

    setState(() {
      allChannelsCache = List.from(allChannels);
      relatedChannels = loadedRelated;
      isFavorite = favoriteStatus;
    });

    // A short (3-hour, same window the Live TV screen uses for its own
    // rows) guide fetch scoped to just these related channels' IDs —
    // cheap, and lets each "More Channels" card's onTap hand the next
    // screen real initialPrograms instead of nothing. Kept as a
    // separate call after the setState above so "More Channels" itself
    // always renders as soon as the channel list resolves, whether or
    // not this slightly heavier guide call has come back yet.
    final relatedIds = loadedRelated
        .map((c) => c["Id"]?.toString())
        .whereType<String>()
        .toList();

    if (relatedIds.isEmpty) return;

    final guide = await MediaService.getGuide(
      end: DateTime.now().add(const Duration(hours: 3)),
      channelIds: relatedIds,
    );

    final grouped = <String, List<dynamic>>{};
    for (final program in guide) {
      final channelId = program["ChannelId"]?.toString();
      if (channelId == null) continue;
      grouped.putIfAbsent(channelId, () => []).add(program);
    }

    if (!mounted) return;

    setState(() {
      relatedPrograms = grouped;
    });
  }

  /// Flips [isFavorite] immediately so the heart icon reads as "this
  /// registered" the instant it's tapped, then persists the change in
  /// the background — matching the optimistic pattern already used by
  /// MusicDetailScreen and CastCrewDetailScreen's favorite buttons.
  /// This used to await FavoriteService.toggle() (a chain of several
  /// SharedPreferences reads/writes plus a fire-and-forget server sync)
  /// before flipping the icon, which is what made this button feel
  /// slower to respond than every other detail screen's. Reverts on
  /// failure so the icon never lies about the actually-saved state.
  Future<void> _toggleFavorite() async {
    final wasFavorite = isFavorite;

    setState(() => isFavorite = !wasFavorite);

    try {
      await FavoriteService.toggle(widget.channelId);
    } catch (_) {
      if (!mounted) return;
      setState(() => isFavorite = wasFavorite);
    }
  }

  /// Opens the full TV guide with this channel scrolled into view and
  /// highlighted. Hands over the channel list this screen already holds
  /// (so the guide skips its own channel fetch, like Live TV's screen
  /// does); with none loaded yet the guide fetches its own.
  void _openFullGuide() {
    final channels = allChannelsCache
        .whereType<Map>()
        .map((c) => Map<String, dynamic>.from(c))
        .toList();

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => TvGuideScreen(
          initialChannels: channels.isEmpty ? null : channels,
          focusChannelId: widget.channelId,
        ),
      ),
    );
  }

  String _formatTime(String? value) => EpgUtils.formatTime(value);

  /// Picks the program actually airing right now out of a list sorted
  /// by StartDate, instead of blindly trusting `programs.first` — a
  /// defensive client-side check on top of the server-side StartDate/
  /// EndDate window filter in [MediaService.getPrograms], the same
  /// "don't fully trust server-side filtering" pattern the rest of
  /// this codebase already follows elsewhere. Falls back to the first
  /// (soonest upcoming) entry if nothing in the list is currently
  /// airing — e.g. a gap in the channel's EPG data — so "Now Playing"
  /// still shows something instead of going blank.
  Map<String, dynamic>? _pickCurrentProgram(List programs) =>
      EpgUtils.pickCurrentProgram(programs);

  /// "Coming Up" excludes whichever program [_pickCurrentProgram] chose
  /// as currently airing, matched by Id rather than assuming it's
  /// always `programs[0]` — the common case, now that the fetch window
  /// itself is fixed, but not guaranteed in edge cases (e.g. an EPG gap
  /// falling back to the soonest upcoming entry).
  List get _upcomingPrograms {
    final currentId = currentProgram?["Id"];
    if (currentId == null) return programs;
    return programs.where((p) => p is Map && p["Id"] != currentId).toList();
  }

  double _programProgress() {
    if (currentProgram == null) return 0;
    return EpgUtils.progress(
      currentProgram!["StartDate"],
      currentProgram!["EndDate"],
    );
  }

  /// "1h 30m" for whatever's currently airing — same shared calculation
  /// the in-player Info sheet and channel list panel use, so this label
  /// can never quietly drift out of sync with either of them.
  String _programDuration() {
    if (currentProgram == null) return "";
    return EpgUtils.formatDuration(
      currentProgram!["StartDate"],
      currentProgram!["EndDate"],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Scaffold(
        backgroundColor: Color(0xff161616),
        body: Center(
          child: CircularProgressIndicator(
            color: Color(0xffD4AF37),
          ),
        ),
      );
    }

    return _buildPage(context);
  }

  Widget _buildPage(BuildContext context) {
    final backdrop = MediaService.getPrimaryImage(
      widget.channelId,
      size: 1400,
    );

    // TV channels only ever have a Primary image in Jellyfin (their
    // channel icon) — same one used everywhere else in the app as the
    // channel's "logo" (see MediaService.mediaItemFromJellyfin).
    final logo = MediaService.getPrimaryImage(
      widget.channelId,
      size: 500,
    );

    return Scaffold(
      backgroundColor: const Color(0xff161616),

      body: Stack(
        children: [
          // Landscape only: full-bleed blurred backdrop sitting behind
          // the *entire* page (header + scrolling content alike), same
          // treatment as the movie detail screen's landscape layout —
          // this is what lets the header blend straight into the rest
          // of the screen with no seam between them. Portrait keeps its
          // own per-header backdrop below, untouched.
          if (Responsive.isLandscape(context))
            LandscapeBackdropBackground(backdropUrl: backdrop),
          // Portrait only: the header backdrop is painted here, behind the
          // scroll view, instead of inside CollapsingDetailHeader's
          // expandedBuilder. ROOT CAUSE: the channel logo sits in the
          // content sliver directly under the header, so for it to overlap
          // the backdrop (like the poster on the movie detail screen) the
          // backdrop has to reach below the header's bottom edge — and a
          // viewport paints its first sliver LAST, so a taller/overflowing
          // header would cover the logo rather than sit under it (and a
          // taller header would push all the content down). Behind the
          // scroll view the header keeps its exact height and the content
          // paints on top. See ScrollLinkedDetailBackdrop.
          //
          // collapseFadeRange carries over the header's own collapse
          // scrim: a flat page-color layer whose alpha tracks how
          // collapsed the header is (same t = scroll / (expandedHeight -
          // minExtent) CollapsingDetailHeader computes), so the visible
          // bottom edge heads toward fully opaque throughout the shrink
          // rather than only at one fixed spot of the gradient.
          if (!Responsive.isLandscape(context))
            ScrollLinkedDetailBackdrop(
              scrollOffset: _heroScrollOffset,
              collapseFadeRange:
                  kDetailHeaderHeight - (MediaQuery.paddingOf(context).top + 56),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Image.network(
                    backdrop,
                    fit: BoxFit.cover,
                  ),

                  Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.transparent,
                          Colors.black.withValues(alpha: .55),
                          const Color(0xff161616),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ResistiveRefresh(
        onRefresh: loadChannel,
        color: const Color(0xffD4AF37),
        backgroundColor: const Color(0xff232323),
        child: ScrollOffsetReporter(
        offset: _heroScrollOffset,
        child: CustomScrollView(
        // A channel with few upcoming programs / related channels
        // doesn't overflow the viewport, which otherwise leaves the
        // pull gesture with nothing to grab onto.
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          CollapsingDetailHeader(
            // Landscape has nothing to paint in this header (see
            // expandedBuilder below) — it's just reserving space for
            // the pinned bar/back button, so it's sized like the thin
            // fixed bar the movie/cast & crew screens use there
            // (topPadding + a few pixels of collapse runway) instead
            // of a full portrait-style hero height. That's what keeps
            // the gap to the channel logo below in line with those
            // screens instead of leaving a tall blank reserve above it.
            expandedHeight: Responsive.isLandscape(context)
                ? MediaQuery.paddingOf(context).top + 60
                : kDetailHeaderHeight,
            onBack: () => Navigator.of(context).maybePop(),
            accentImageUrl: logo,
            collapsedLogoUrl: logo,
            // Landscape now stays fully transparent here — the page-wide
            // backdrop added above the scroll view already covers this
            // header, so painting another copy (or a gradient down to a
            // flat page color) would just recreate the seam this was
            // meant to remove. The collapsed top-bar logo above
            // (collapsedLogoUrl) is untouched, so it still fades in on
            // scroll exactly like portrait. Portrait now does the same: its
            // backdrop is ScrollLinkedDetailBackdrop (added above the scroll
            // view), so this header only paints the pinned bar / back
            // button.
            expandedBuilder: (context, t) => const SizedBox.shrink(),
          ),

          SliverToBoxAdapter(
            child: Padding(
              // Left/right are 0 here (was 24/24) — the header block
              // below carries its own horizontal padding, and "Coming
              // Up" / "More Channels" further down carry their own too
              // (on just the title + the ListView), so those rows can
              // scroll all the way to the true screen edge instead of
              // stopping wherever this outer padding used to sit.
              padding: const EdgeInsets.fromLTRB(
                0,
                24,
                0,
                40,
              ),

              child: Column(
                crossAxisAlignment:
                CrossAxisAlignment.start,

                children: [
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: Responsive.contentPadding(context, base: 24)),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                      MusicLandscapeHeader(
                      // Shared by portrait and landscape: bare logo
                      // centered, name + Ch./LIVE under it, then the
                      // buttons — no card/container around the logo, matching how
                      // the movie/series landscape detail screen
                      // (_LandscapeBody) presents its own logo, and
                      // sized identically (84 tall, up to 280 wide)
                      // instead of the smaller boxed-card treatment
                      // used elsewhere for channel tiles.
                      icon: SizedBox(
                        height: 84,
                        width: double.infinity,
                        child: TrimmedLogo(
                          url: logo,
                          alignment: Alignment.center,
                          targetArea: 84 * 260,
                          maxWidth: 280,
                          maxHeight: 84,
                        ),
                      ),
                      title: channel?["Name"] ?? "",
                      // Number directly under the name, with the LIVE
                      // badge underneath it — same info portrait shows,
                      // just centered as a unit instead of sitting next
                      // to the logo.
                      subtitle: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if ((channel?["Number"] ?? "")
                              .toString()
                              .isNotEmpty) ...[
                            Text(
                              "Ch. ${channel?["Number"]}",
                              style: const TextStyle(
                                color: Colors.white54,
                                fontSize: 14,
                              ),
                            ),
                            const SizedBox(height: 10),
                          ],
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.red,
                              borderRadius: BorderRadius.circular(30),
                            ),
                            child: const Text(
                              "LIVE",
                              style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      ),
                      actions: StackedActionBar(
                        horizontalPadding: 0,
                        playLabel: "Watch Live",
                        onPlay: () async {
                          final media =
                              MediaService.mediaItemFromJellyfin(channel!);

                          // Show the player immediately with a loading
                          // overlay instead of waiting on the stream to
                          // open before navigating there.
                          PlayerManager.instance.showLoadingPreview(media);
                          unawaited(PlaybackService.playItem(media));

                          if (!context.mounted) return;

                          await PlayerNavigation.open(context);
                        },
                        actions: [
                          // Cast — same self-contained button Movie/Show
                          // Details uses (device picker when nothing is
                          // connected, connected-session sheet when this
                          // channel is already casting). Casts the real
                          // Jellyfin live stream, same item Watch Live
                          // plays locally.
                          StackedActionBar.item(
                            icon: CastToButton(item: channel!),
                            label: StackedActionBar.labelText("Cast"),
                          ),
                          StackedActionBar.item(
                            icon: Center(
                              child: IconButton(
                                onPressed: _toggleFavorite,
                                icon: AnimatedSwitcher(
                                  duration:
                                      const Duration(milliseconds: 250),
                                  child: Icon(
                                    isFavorite
                                        ? Icons.favorite
                                        : Icons.favorite_border,
                                    key: ValueKey(isFavorite),
                                    color: isFavorite
                                        ? Colors.red
                                        : Colors.white,
                                  ),
                                ),
                              ),
                            ),
                            label: StackedActionBar.labelText("Favorite"),
                          ),
                        ],
                      ),
                      stackedActions: true,
                    ),
                      const SizedBox(height: 30),

                      // Header + hero card now live in NowPlayingSection
                      // (fixed 260px Container replaced by a content-sized
                      // card with a segmented progress bar).
                      NowPlayingSection(
                        program: currentProgram,
                        progress: _programProgress(),
                        ready: programsReady,
                      ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 30),

                  // ROOT CAUSE of the dull/oversized look: "Coming Up" was a
                  // horizontal list of fixed 260px-tall cards, mostly empty
                  // space. Now a compact vertical timeline in portrait and
                  // a horizontal card slider in landscape, with per-programme
                  // reminders, a tap-for-options sheet and a way into the
                  // full TV guide. It pads itself horizontally, like before.
                  AnimatedOpacity(
                    duration: const Duration(milliseconds: 250),
                    opacity: programsReady ? 1 : 0,
                    child: UpcomingProgramTimeline(
                      programs: _upcomingPrograms,
                      channelId: widget.channelId,
                      channelName: (channel?["Name"] ?? "").toString(),
                      onOpenGuide: _openFullGuide,
                    ),
                  ),

                      const SizedBox(height: 35),

                      // Same edge-to-edge treatment as "Coming Up" above.
                      Padding(
                        padding: EdgeInsets.symmetric(horizontal: Responsive.contentPadding(context, base: 24)),
                        child: Text(
                          "More Channels",
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),

                      const SizedBox(height: 18),

                      SizedBox(
                        height: 220,
                        child: ListView.separated(
                          padding: EdgeInsets.symmetric(horizontal: Responsive.contentPadding(context, base: 24)),
                          scrollDirection: Axis.horizontal,
                          itemCount: relatedChannels.length,
                          separatorBuilder: (context, index) =>
                          const SizedBox(width: 8),
                          itemBuilder: (_, index) {

                            final c = relatedChannels[index];

                            return SizedBox(
                                width: 170,
                                // Passes onTap straight into ChannelLogoCard's
                                // own Pressable instead of wrapping it in a
                                // second one — a nested Pressable/InkWell here
                                // was swallowing the tap instead of opening
                                // the channel's detail screen.
                                child: ChannelLogoCard(
                              channel: c,
                              iconSize: 160,
                              onTap: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => LiveTvDetailScreen(
                                      channelId: c["Id"],
                                      initialItem: Map<String, dynamic>.from(c),
                                      allChannels: allChannelsCache.isNotEmpty
                                          ? allChannelsCache
                                          : [
                                              if (channel != null) channel!,
                                              ...relatedChannels,
                                            ],
                                      initialPrograms:
                                          relatedPrograms[c["Id"]] as List?,
                                    ),
                                  ),
                                );
                              },
                            ),
                            );

                          },
                        ),
                      ),

                    // The main nav's bottom bar floats over this screen
                    // in a plain Stack, not a real Scaffold.extendBody
                    // (see MainNavScreen's own doc comment) — without
                    // BottomClearance.of added in, "More Channels" would
                    // only clear the safe-area inset, not the bar's
                    // actual height, and its cards would scroll to a
                    // stop sitting directly behind it.
                    BottomClearanceBuilder(
                      builder: (context, bottomClearance) => SizedBox(
                        height: 24 +
                            MediaQuery.paddingOf(context).bottom +
                            bottomClearance,
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
        ],
      ),
    );
  }
}