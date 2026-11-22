import 'dart:async';

import 'package:flutter/material.dart';
import '../../services/analytics_service.dart';

import '../../services/jellyfin_services/media_service.dart';
import '../../services/parental/parental_controls.dart';
import '../profile/parental/parental_prompts.dart';
import '../../services/download_manager.dart';
import '../../services/offline_progress_store.dart';

import 'widgets/action_buttons.dart';
import 'widgets/trailer_sheet.dart';
import 'widgets/backdrop_header.dart';
import 'widgets/overview_section.dart';
import 'widgets/tags_row.dart';
import 'widgets/season_selector.dart';
import 'widgets/episode_list.dart';
import 'widgets/episode_row.dart';
import 'widgets/content_row.dart';
import 'widgets/cast_row.dart';
import 'widgets/studio_row.dart';
import '../../utils/responsive.dart';
import '../../utils/logo_trimmer.dart';
import 'widgets/landscape_backdrop_bg.dart';
import 'widgets/landscape_scroll_bar.dart';
import '../cast_crew/cast_crew_detail_screen.dart';
import '../../player/playback_service.dart';
import '../../player/player_manager.dart';
import '../../player/screens/player_navigation.dart';
import '../../widgets/common/resistive_refresh.dart';
import '../../widgets/common/artwork_ready_spinner.dart';
import '../../widgets/common/rating_badges.dart';
import '../../widgets/music/expandable_genre_chips.dart';
import '../../services/ratings_service.dart';
import '../../services/external_metadata/cast_crew_service.dart';
import '../../services/external_metadata/studio_service.dart';
import '../shared/tag_items_screen.dart';
import '../../utils/bottom_clearance.dart';
import '../../virtual/virtual_catalog.dart';

/// Opens [TagItemsScreen] filtered to [genre] — shared by the portrait
/// (BackdropHeader) and landscape (_LandscapeMetaRow) genre chips
/// below, both of which only ever show genres for a Movie/Series item.
void _openGenre(BuildContext context, String genre) {
  Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => TagItemsScreen(genre: genre),
    ),
  );
}

/// Caps OverviewSection to a comfortable reading width, left-aligned
/// within whatever space is actually available. On phones/tablets this
/// is a no-op (the available width is already well under the cap); on
/// a 1920/3840-wide TV or an ultra-wide tablet landscape split, an
/// uncapped paragraph would stretch into an unreadably long line with
/// nothing else sharing the row.
///
/// Left-aligned rather than centered: TagsRow renders directly beneath
/// this (both in the portrait layout above and _LandscapeBody below)
/// as a left-aligned paragraph with its own 20px padding, and the two
/// are meant to read as one continuous block of text sharing a left
/// edge. Centering the capped-width box — the previous behavior —
/// only coincidentally lined up with TagsRow on narrow screens where
/// the 700px cap never actually engaged; anywhere wider (landscape,
/// tablets, TV) it left the overview paragraph adrift in the middle of
/// the row while Tags stayed pinned to the left edge.
Widget _readableOverviewWidth(Widget child) {
  return Align(
    alignment: Alignment.centerLeft,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 700),
      child: child,
    ),
  );
}

class MovieDetailsScreen extends StatefulWidget {
  final String itemId;
  final VoidCallback? onBack;

  /// Whatever the tapped card/row already had in memory (poster, title,
  /// overview, etc.). When present, the screen paints with this
  /// immediately instead of a blank spinner, then silently swaps in the
  /// authoritative full record once it loads.
  final Map<String, dynamic>? initialItem;

  /// True when this screen was opened from the Downloads page. Forces
  /// the season selector and episode list to only ever reflect what's
  /// actually been downloaded for this series — even if the Jellyfin
  /// server happens to be reachable — since a downloaded title's detail
  /// screen is meant to show "what I have offline", not the full
  /// catalog. Has no effect on movies (there's no season/episode list
  /// to filter).
  final bool downloadedOnly;

  const MovieDetailsScreen({
    super.key,
    required this.itemId,
    this.onBack,
    this.initialItem,
    this.downloadedOnly = false,
  });

  @override
  State<MovieDetailsScreen> createState() =>
      _MovieDetailsScreenState();
}

class _MovieDetailsScreenState
    extends State<MovieDetailsScreen> {
  Map<String, dynamic>? item;

  List<dynamic> similar = [];
  List<dynamic> seasons = [];
  List<dynamic> episodes = [];
  Map<String, dynamic>? collection;
  List<dynamic> collectionItems = [];

  // Cast & crew and studio logos both start out populated instantly
  // from whatever the Jellyfin server itself already has (no network
  // wait — see loadMovie()'s setState), then get silently upgraded in
  // the background once CastCrewService/StudioService resolve TMDB
  // data, exactly like Similar/Collection below. A TMDB failure or a
  // title with nothing configured just leaves these as the Jellyfin
  // values — never blank.
  List<dynamic> castCrew = [];
  List<Map<String, dynamic>> studios = [];

  bool loading = true;
  bool loadingEpisodes = false;
  bool favorite = false;

  // Drives the crossfade for everything below the backdrop header (the
  // stuff that isn't in `initialItem`). Starts false so overview/cast/
  // rows aren't drawn at all until they have real data, then flips true
  // once the fetch settles — so instead of each section popping in on
  // its own, the whole block fades in together in one smooth motion.
  bool contentReady = false;

  /// Which episode a Series' Play button will start (and whether the show
  /// is mid-way through). Null for movies, and until it has been resolved.
  /// Drives the "Start Watching Episode 1" / "Continue Watching Episode 4"
  /// button text.
  SeriesPlayTarget? _seriesTarget;

  /// Text of the main play button: movies say "Start Watching" /
  /// "Continue Watching"; series add the episode that will actually play.
  String _playLabelFor(Map<String, dynamic> it, bool resume) {
    if (it["Type"] == "Series") {
      final t = _seriesTarget;
      final base = (t?.inProgress ?? resume)
          ? "Continue Watching"
          : "Start Watching";
      final ep = t?.episodeLabel;
      return ep == null ? base : "$base $ep";
    }
    return resume ? "Continue Watching" : "Start Watching";
  }

  /// Works out the series' play target in the background (one request, or
  /// the downloaded episodes when opened from Downloads / offline) and
  /// updates the button text once known.
  Future<void> _loadSeriesPlayTarget(Map<String, dynamic> series) async {
    if (series["Type"] != "Series") return;
    final seriesId = series["Id"]?.toString();
    if (seriesId == null) return;

    Future<SeriesPlayTarget?> fromDownloads() async {
      final raw = DownloadManager.instance
          .episodesForSeries(seriesId)
          .map((e) => e.raw)
          .toList();
      if (raw.isEmpty) return null;
      final withProgress = await OfflineProgressStore.applyToRawList(raw);
      return PlaybackService.pickSeriesTarget(withProgress);
    }

    SeriesPlayTarget? target;
    if (widget.downloadedOnly) {
      target = await fromDownloads();
    } else {
      target = await PlaybackService.resolveSeriesTarget(series) ??
          await fromDownloads();
    }

    if (!mounted) return;
    setState(() => _seriesTarget = target);
  }

  /// The series' own IMDb id (movies don't need this — RatingsRow
  /// resolves those directly from `item`'s own ProviderIds) — used to
  /// look up each episode's individual rating via
  /// RatingsService.fetchEpisode, since Jellyfin's metadata providers
  /// essentially never tag individual episodes with their own IMDb id
  /// the way they do the series itself.
  String? get _seriesImdbId {
    final providerIds = item?["ProviderIds"];
    if (providerIds is! Map) return null;
    final id = providerIds["Imdb"] ?? providerIds["IMDB"] ?? providerIds["imdb"];
    return id?.toString();
  }

  // The "which collection is this movie part of" lookup can be slow on
  // some servers (see _loadCollectionInBackground below), so it's kept
  // out of the main load and revealed on its own once it's ready,
  // instead of making the rest of the page wait on it.
  bool collectionReady = false;

  // "Similar" is a supplementary row, not core detail content — it's
  // fetched alongside the main item but no longer gates contentReady,
  // so a slow Similar endpoint can't hold up the overview/cast/action
  // buttons from appearing. It fades in on its own once it lands.
  bool similarReady = false;

  String? selectedSeasonId;

  // Raw scroll offset of the landscape layout's left column, fed to
  // LandscapeScrollBar so its tinted bar + small logo can fade in once
  // the person scrolls past the hero logo, the same way BackdropHeader's
  // collapsed bar appears in portrait. Tracked as a ValueNotifier rather
  // than setState so scrolling doesn't rebuild the whole screen.
  final ValueNotifier<double> _scrollOffset = ValueNotifier(0);
  late final ScrollController _scrollController;

  /// Opens the Trailers popup (TrailerSheet) for this title. Entirely
  /// self-contained — see TrailerSheet/TrailerService's doc comments
  /// for why this deliberately never touches PlayerManager,
  /// CastManager, or PlaybackQueue.
  void _openTrailers() {
    TrailerSheet.show(context, item!);
  }

  void _handleBack() {
    if (widget.onBack != null) {
      widget.onBack!();
      return;
    }

    final navigator = Navigator.of(context);
    if (navigator.canPop()) {
      navigator.pop();
    }
  }

  @override
  void initState() {
    super.initState();
    AnalyticsService.screen('movie_details');
    _scrollController = ScrollController()
      ..addListener(() {
        _scrollOffset.value = _scrollController.offset;
      });
    // Paint immediately with the preview from whatever list/row got us
    // here; loadMovie() below fetches the authoritative record and
    // silently replaces it (no spinner) once it's ready.
    item = widget.initialItem;
    favorite = widget.initialItem?["UserData"]?["IsFavorite"] ?? false;
    loading = widget.initialItem == null;
    loadMovie();
    unawaited(_ensureLogo());
  }

  /// A title opened from a list may not have its logo yet: look it up and
  /// redraw once it is there.
  Future<void> _ensureLogo() async {
    final id = item?["Id"]?.toString();
    if (id == null) return;
    if (!MediaService.getLogoUrl(id).contains('/no-image/')) return;
    final url = await VirtualCatalog.ensureLogo(id);
    if (url != null && mounted && item?["Id"]?.toString() == id) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _scrollOffset.dispose();
    super.dispose();
  }

  Future<void> loadEpisodes(
      String seasonId,
      ) async {
    if (item == null) return;

    setState(() {
      loadingEpisodes = true;
      selectedSeasonId = seasonId;
    });

    // Same reasoning as loadMovie() above — a downloads-page open never
    // hits the network for episodes, so switching seasons here stays
    // scoped to whatever's actually downloaded for this series.
    if (widget.downloadedOnly) {
      final downloaded = DownloadManager.instance
          .episodesForSeries(item!["Id"])
          .where((e) => e.seasonId == seasonId)
          .map((e) => e.raw)
          .toList();

      // Offline-progress overlay — see OfflineProgressStore.applyToRawList.
      final withProgress =
          await OfflineProgressStore.applyToRawList(downloaded);

      setState(() {
        episodes = withProgress;
        loadingEpisodes = false;
      });
      return;
    }

    try {
      final data = await MediaService.getEpisodes(
        item!["Id"],
        seasonId,
      );

      setState(() {
        episodes = data;
      });
      unawaited(RatingsService.prefetchEpisodes(_seriesImdbId, data));
    } catch (_) {
      // Offline fallback — show whichever downloaded episodes of this
      // season we actually have on disk instead of leaving the list
      // stuck on the previous season's episodes.
      final downloaded = DownloadManager.instance
          .episodesForSeries(item!["Id"])
          .where((e) => e.seasonId == seasonId)
          .map((e) => e.raw)
          .toList();

      final withProgress =
          await OfflineProgressStore.applyToRawList(downloaded);

      setState(() {
        episodes = withProgress;
      });
    } finally {
      setState(() {
        loadingEpisodes = false;
      });
    }
  }

  /// Re-fetches just the currently selected season's episodes — used
  /// after closing the player from the episode list, which only ever
  /// needs that season's watched/resume state refreshed rather than a
  /// full loadMovie() re-fetch.
  void _refreshCurrentSeasonEpisodes() {
    final seasonId = selectedSeasonId;
    if (seasonId == null) return;
    unawaited(loadEpisodes(seasonId));
    if (item != null) unawaited(_loadSeriesPlayTarget(item!));
  }

  Future<void> loadMovie() async {
    // Parental Controls: a blocked title (reachable only from the Downloads
    // page, which opens with a saved copy) shows the block, not the page.
    final pc = ParentalControls.instance;
    if (pc.contentFilterActive) {
      final d = widget.initialItem != null
          ? await pc.checkItemJson(widget.initialItem!)
          : await pc.checkId(widget.itemId);
      if (!d.allowed) {
        final base = ParentalControls.baseIdOf(widget.itemId);
        final ok = await ParentalPrompts.showBlocked(d, titleId: base);
        if (!ok) {
          if (mounted) Navigator.of(context).maybePop();
          return;
        }
        if (base != null) pc.allowOnce(base);
      }
    }

    if (item == null) {
      setState(() {
        loading = true;
      });
    }

    // The "what collection is this in" lookup can fall back to scanning
    // every BoxSet on the server (see MediaService.getItemCollection) —
    // slow enough on some servers that it shouldn't hold up everything
    // else. Kick it off in parallel but let it resolve on its own time;
    // it reveals its own row independently once it's ready.
    _loadCollectionInBackground();

    // Same reasoning for "Similar" — it's a single extra network call
    // that has nothing to do with the movie's own overview/cast, so it
    // shouldn't be the thing standing between contentReady and the rest
    // of the page painting. It resolves independently and fades in its
    // own row whenever it lands.
    _loadSimilarInBackground();

    try {
      // Only the movie's own record gates the primary content now —
      // that's the single fast call the overview/cast/action buttons
      // actually depend on, so it's no longer bundled with Similar
      // behind one Future.wait.
      //
      // Falls back to the initialItem we were handed (e.g. from the
      // Downloads page, which always supplies one) when the network is
      // unreachable, so an offline open of a downloaded title still
      // renders instead of getting stuck mid-load.
      var movie = await MediaService.getItem(widget.itemId)
          .catchError((_) {
        if (widget.initialItem != null) return widget.initialItem!;
        throw Exception('offline and no cached item available');
      });

      // Overlays this item's locally-saved offline progress (see
      // OfflineProgressStore) onto whatever UserData it already
      // carries, whenever the local one is further along — a no-op
      // for anything that was never downloaded, or that hasn't been
      // watched offline since its last server sync. This is what
      // makes the Resume button below reflect progress made while
      // playing this download with no network at all.
      movie = await OfflineProgressStore.applyToRaw(movie);

      // Seasons/episodes only depend on the movie's Type, so they can
      // run right after — no reason to wait on the collection lookup.
      //
      // downloadedOnly (opened from the Downloads page) skips the live
      // /Seasons and /Episodes calls entirely and goes straight to the
      // downloaded-only builder below, regardless of whether the
      // server is reachable right now.
      final seasonResult = movie["Type"] == "Series"
          ? (widget.downloadedOnly
              ? await _offlineSeasonResult(widget.itemId)
              : await _loadSeasonsAndEpisodes(widget.itemId))
          : const _SeasonResult(
        seasons: [],
        episodes: [],
        selectedSeasonId: null,
      );

      // NAMESIS PRIME: the user may have left while the network call ran.
      if (!mounted) return;
      setState(() {
        item = movie;
        seasons = seasonResult.seasons;
        episodes = seasonResult.episodes;
        selectedSeasonId = seasonResult.selectedSeasonId;

        // Instant, zero-network defaults — CastCrewService/StudioService
        // upgrade these in the background right below.
        castCrew = CastCrewService.jellyfinCast(movie);
        studios = StudioService.jellyfinFallback(movie);

        favorite =
            movie["UserData"]?["IsFavorite"] ??
                false;
      });

      // Same "resolve in the background, swap in silently once ready"
      // approach as Similar/Collection above — a slow or unconfigured
      // TMDB lookup should never hold up the page, and the Jellyfin
      // defaults set just above already cover the screen in the
      // meantime.
      unawaited(_loadCastCrewInBackground(movie));
      unawaited(_loadStudiosInBackground(movie));
      unawaited(_loadSeriesPlayTarget(movie));
      unawaited(_ensureLogo());

      // Same "warm the cache before the row that needs it builds" idea
      // HomeScreen uses for its hero carousel — kicks off the movie's
      // own rating lookup, plus every episode already loaded for the
      // initially-selected season, right when they're known rather
      // than waiting for each RatingsRow to discover them one at a
      // time on its own initState. Episodes go through
      // prefetchEpisodes (keyed by the series' own IMDb id + each
      // episode's season/number) rather than prefetchAll, matching how
      // RatingsRow itself resolves them — see
      // RatingsService.fetchEpisode's doc for why.
      unawaited(RatingsService.prefetchAll([movie]));
      unawaited(
        RatingsService.prefetchEpisodes(_seriesImdbId, seasonResult.episodes),
      );
      // Beyond just the initially-selected season above — warms every
      // other season's episode ratings too, in the background, so
      // switching seasons feels as instant as the first one instead of
      // only the season that happened to load first getting the head
      // start. Low priority: runs after the screen is already usable,
      // one season at a time (each one internally batched by
      // prefetchEpisodes already), and is skipped entirely offline —
      // no point queuing OMDb calls that can't succeed.
      if (movie["Type"] == "Series" && !widget.downloadedOnly) {
        unawaited(_prefetchRemainingSeasonsRatings(
          seasonResult.seasons,
          seasonResult.selectedSeasonId,
        ));
      }
    } finally {
      if (mounted) {
        setState(() {
          loading = false;
          contentReady = true;
        });
      }
    }
  }

  /// Runs independently of loadMovie() so a slow Similar-items response
  /// can't delay the overview, cast, or seasons from appearing. Sets its
  /// own `similarReady` flag so the row fades in on its own once its
  /// data actually arrives.
  Future<void> _loadSimilarInBackground() async {
    try {
      final results = await MediaService.getSimilarItems(widget.itemId);

      if (!mounted) return;

      setState(() {
        similar = results;
        similarReady = true;
      });
    } catch (_) {
      if (!mounted) return;

      setState(() {
        similarReady = true;
      });
    }
  }

  /// Runs independently of loadMovie() so a slow server-side collection
  /// scan can't delay the overview, cast, or similar-movies rows. Sets
  /// its own `collectionReady` flag when done so the collection row can
  /// fade in on its own whenever its data actually arrives.
  Future<void> _loadCollectionInBackground() async {
    final result = await _loadCollection(widget.itemId);

    if (!mounted) return;

    setState(() {
      collection = result.collection;
      collectionItems = result.items;
      collectionReady = true;
    });
  }

  /// Upgrades `castCrew` from the Jellyfin default (set synchronously
  /// in loadMovie()) to TMDB's cast/crew — real photos, accurate
  /// character/job credits — once CastCrewService resolves. A no-op
  /// swap (same Jellyfin list) whenever TMDB is unconfigured,
  /// unreachable, or has nothing for this title.
  Future<void> _loadCastCrewInBackground(Map<String, dynamic> movie) async {
    final resolved = await CastCrewService.resolve(movie);
    if (!mounted) return;
    setState(() => castCrew = resolved);
  }

  /// Same idea for `studios` — upgrades from name-only entries to
  /// ones carrying a resolved logo URL once StudioService resolves.
  Future<void> _loadStudiosInBackground(Map<String, dynamic> movie) async {
    final resolved = await StudioService.resolve(movie);
    if (!mounted || resolved.isEmpty) return;
    setState(() => studios = resolved);
  }

  /// See the call site in loadMovie() above — warms RatingsService's
  /// cache for every season besides [alreadyLoadedSeasonId] (already
  /// covered by the prefetch alongside the initial load), one season
  /// at a time so this background work doesn't compete for bandwidth
  /// with anything the person is actually looking at right now.
  Future<void> _prefetchRemainingSeasonsRatings(
    List<dynamic> allSeasons,
    String? alreadyLoadedSeasonId,
  ) async {
    final seriesImdbId = _seriesImdbId;
    if (seriesImdbId == null || seriesImdbId.isEmpty) return;

    for (final season in allSeasons) {
      if (season is! Map) continue;
      final seasonId = season["Id"];
      if (seasonId == null || seasonId == alreadyLoadedSeasonId) continue;

      try {
        final seasonEpisodes = await MediaService.getEpisodes(
          widget.itemId,
          seasonId,
        );
        await RatingsService.prefetchEpisodes(seriesImdbId, seasonEpisodes);
      } catch (_) {
        // A season that fails to load here just doesn't get a head
        // start — its episodes still resolve normally (if more
        // slowly) the first time that season is actually opened.
      }
    }
  }

  Future<_SeasonResult> _loadSeasonsAndEpisodes(
      String itemId,
      ) async {
    try {
      var loadedSeasons = await MediaService.getSeasons(itemId);

      // NAMESIS PRIME: an empty answer usually means TMDB hiccupped, so
      // ask again a couple of times before giving up.
      for (var i = 0;
          i < 2 && loadedSeasons.isEmpty && !widget.downloadedOnly;
          i++) {
        await Future<void>.delayed(const Duration(seconds: 2));
        if (!mounted) break;
        loadedSeasons = await MediaService.getSeasons(itemId);
      }

      if (loadedSeasons.isEmpty) {
        return await _offlineSeasonResult(itemId);
      }

      final firstSeasonId = loadedSeasons.first["Id"];
      var loadedEpisodes = await MediaService.getEpisodes(
        itemId,
        firstSeasonId,
      );
      if (loadedEpisodes.isEmpty && mounted) {
        await Future<void>.delayed(const Duration(seconds: 2));
        loadedEpisodes = await MediaService.getEpisodes(
          itemId,
          firstSeasonId,
        );
      }

      return _SeasonResult(
        seasons: loadedSeasons,
        episodes: loadedEpisodes,
        selectedSeasonId: firstSeasonId,
      );
    } catch (_) {
      // No network (or the server is unreachable) — fall back to
      // whatever episodes of this series have actually been downloaded,
      // so a show opened from the Downloads page still shows its
      // episode list instead of an empty screen.
      return await _offlineSeasonResult(itemId);
    }
  }

  /// Builds a season/episode list purely from locally downloaded
  /// episodes for [itemId] (a series id) — used when the real
  /// season/episode endpoints can't be reached.
  Future<_SeasonResult> _offlineSeasonResult(String itemId) async {
    final downloaded = DownloadManager.instance.episodesForSeries(itemId);

    if (downloaded.isEmpty) {
      return const _SeasonResult(
        seasons: [],
        episodes: [],
        selectedSeasonId: null,
      );
    }

    // Synthesize a minimal season list from whatever season ids/names
    // the downloaded episodes carry, in first-seen order.
    final seasons = <Map<String, dynamic>>[];
    final seenSeasonIds = <String>{};
    for (final e in downloaded) {
      final seasonId = e.seasonId ?? '';
      if (seasonId.isEmpty || seenSeasonIds.contains(seasonId)) continue;
      seenSeasonIds.add(seasonId);
      seasons.add({
        "Id": seasonId,
        "Name": e.seasonName ?? "Season",
      });
    }

    final firstSeasonId = seasons.isNotEmpty ? seasons.first["Id"] : null;

    final episodesForFirstSeason = downloaded
        .where((e) => firstSeasonId == null || e.seasonId == firstSeasonId)
        .map((e) => e.raw)
        .toList();

    // Same offline-progress overlay as the movie item above, applied
    // to every episode in this season at once — see
    // OfflineProgressStore.applyToRawList's doc comment. This is what
    // feeds the already-existing per-episode "watched"/progress-bar
    // UI (episode_card_compact.dart/episode_card_horizontal.dart) real
    // data for downloaded episodes instead of a stale download-time
    // snapshot.
    final withProgress =
        await OfflineProgressStore.applyToRawList(episodesForFirstSeason);

    return _SeasonResult(
      seasons: seasons,
      episodes: withProgress,
      selectedSeasonId: firstSeasonId,
    );
  }

  Future<_CollectionResult> _loadCollection(
      String itemId,
      ) async {
    try {
      final loadedCollection = await MediaService.getItemCollection(itemId);

      if (loadedCollection == null) {
        return const _CollectionResult(collection: null, items: []);
      }

      final items = await MediaService.getItems(
        parentId: loadedCollection["Id"],
        includeItemTypes: "Movie,Series",
        sortBy: "SortName",
        sortOrder: "Ascending",
        limit: 5000,
      );

      // "Other movies in its collection" — the collection's own item
      // list includes this movie itself, which would otherwise show up
      // as a card linking right back to the page you're already on.
      items.removeWhere((collectionItem) => collectionItem["Id"] == itemId);

      return _CollectionResult(collection: loadedCollection, items: items);
    } catch (_) {
      // A missing or inaccessible collection should not block the details.
      return const _CollectionResult(collection: null, items: []);
    }
  }

  @override
  Widget build(BuildContext context) {
    final current = item;
    final dataReady = !(loading || current == null);
    // A small spinner over the page until its data and at least one picture
    // (backdrop, poster or logo) are ready. It only shows if that takes a
    // moment, so a fast network or an already cached page never shows it.
    return ArtworkReadySpinner(
      dataReady: dataReady,
      urls: (dataReady && current != null)
          ? _artworkUrls(current)
          : const <String>[],
      child: _buildPage(context),
    );
  }

  /// The pictures whose arrival ends the loading spinner: any one is enough.
  /// The small backdrop is first so a slow connection is released early.
  List<String> _artworkUrls(Map<String, dynamic> it) {
    final id = it["Id"]?.toString();
    if (id == null || id.isEmpty) return const <String>[];
    return [
      MediaService.getBackdropPreviewUrl(id),
      MediaService.getBackdropUrl(id),
      MediaService.getImageUrl(id, maxWidth: 500),
      MediaService.getLogoUrl(id),
    ];
  }

  Widget _buildPage(BuildContext context) {
    if (loading || item == null) {
      // Nothing to draw yet. ArtworkReadySpinner (see build) puts the
      // spinner on top of this after a short delay.
      return const Scaffold(
        backgroundColor: Color(0xff101010),
        body: SizedBox.expand(),
      );
    }

    final backdrop = MediaService.getBackdropUrl(item!["Id"]);

    // castCrew/studios are resolved state fields (see loadMovie() +
    // CastCrewService/StudioService) rather than computed inline here
    // — this used to filter item!["People"] directly, but that only
    // ever showed whatever handful of people the Jellyfin server
    // itself had tagged (often just one or two). The row/design below
    // is unchanged; only where its data comes from is different.
    final cast = castCrew;
    final playbackTicks = item!["UserData"]?["PlaybackPositionTicks"] ?? 0;

    final resume = playbackTicks > 0;

    if (Responsive.isLandscape(context)) {
      return _buildLandscapeScaffold(
        context,
        backdrop: backdrop,
        cast: cast,
        resume: resume,
      );
    }

    return _buildPortraitScaffold(
      context,
      backdrop: backdrop,
      cast: cast,
      resume: resume,
    );
  }

  /// The historical single-column portrait layout — untouched.
  Widget _buildPortraitScaffold(
    BuildContext context, {
    required String backdrop,
    required List cast,
    required bool resume,
  }) {
    return Scaffold(
      backgroundColor: const Color(0xff111111),
      body: ResistiveRefresh(
        onRefresh: loadMovie,
        color: const Color(0xffD4AF37),
        backgroundColor: const Color(0xff232323),
        child: CustomScrollView(
        // A movie/show with a short cast/similar list doesn't overflow
        // the viewport, which otherwise leaves the pull gesture with
        // nothing to grab onto.
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          /// Backdrop
          BackdropHeader(
            backdropUrl: backdrop,
            posterUrl: MediaService.getImageUrl(
              item!["Id"],
              maxWidth: 500,
            ),
            logoUrl: MediaService.getLogoUrl(
              item!["Id"],
            ),
            item: item!,
            onBack: _handleBack,
            onGenreTap: (genre) => _openGenre(context, genre),
            // Portrait detail header: drop the poster card and center
            // the logo where it + the metadata used to sit, matching
            // the landscape layout's centered logo/metadata treatment.
            centerLogoNoIcon: true,
            // Chips-to-buttons gap: this inset IS that gap (the buttons
            // sliver begins right at the header's bottom edge). Tightened
            // from the default 30 to 14.
            infoBottomInset: 14,
          ),

          /// Page Content — fades in as one unit once loadMovie() settles,
          /// instead of overview/cast/rows popping in individually the
          /// moment each becomes available.
          SliverToBoxAdapter(
            child: AnimatedOpacity(
              opacity: contentReady ? 1 : 0,
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOut,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  /// Play/Favorite buttons
                  ///
                  /// SPACING: there is deliberately no SizedBox above this
                  /// row any more. BackdropHeader (centerLogoNoIcon) already
                  /// anchors its logo/metadata/genre-chip group 30dp above
                  /// its own bottom edge (infoRowBottom), which is exactly
                  /// where this sliver begins — so that 30dp IS the
                  /// chips-to-buttons gap. A leftover SizedBox(height: 28)
                  /// stacked on top of it made that gap 58dp, nearly double
                  /// the 30dp SizedBox below that separates the buttons from
                  /// the overview. With it gone the chips-to-buttons gap is
                  /// just the header's own infoBottomInset, which this
                  /// screen now sets to 14 (see the BackdropHeader above) —
                  /// deliberately tighter than the buttons-to-overview gap.
                  ///
                  /// centered: true — portrait used to leave the group flush
                  /// left (the widget's default); the header above it is
                  /// centered, so the buttons now line up with it.
                  ActionButtons(
                    favorite: favorite,
                    resume: resume,
                    stacked: true,
                    playLabel: _playLabelFor(item!, resume),
                    centered: true,
                    item: item,
                    onTrailers: _openTrailers,
                    onPlay: () async {
                      // A Series item itself has no media source to play
                      // — "playing" the series id directly (the old
                      // behavior) just spun the loading overlay forever
                      // since Jellyfin has nothing to stream for it. Route
                      // through PlaybackService.playLibraryItem instead,
                      // which resolves a Series to an actual episode (the
                      // one already in progress, otherwise the first
                      // unwatched one, otherwise S1E1) and queues it the
                      // same way tapping an episode card does.
                      if (item!["Type"] == "Series") {
                        PlayerManager.instance.showLoadingPreview(
                          MediaService.mediaItemFromJellyfin(item!),
                        );
                        unawaited(PlaybackService.playLibraryItem(item!));

                        if (!context.mounted) return;
                        await PlayerNavigation.open(context);

                        // Refreshes the series' record (and its episode
                        // list) so the next Play/Resume tap reflects
                        // whatever position/watched-state the session
                        // that just closed actually left behind, instead
                        // of replaying from whatever was loaded before
                        // playback started.
                        if (!context.mounted) return;
                        unawaited(loadMovie());
                        return;
                      }

                      // Movies: uses the local file automatically when
                      // this item has been downloaded, so Play works the
                      // same way whether the device is online or not.
                      final media =
                      DownloadManager.instance.mediaItemFor(item!);

                      // Show the player screen (with its own loading
                      // overlay) immediately instead of waiting on the
                      // network call to resolve first — see
                      // PlayerManager.showLoadingPreview.
                      PlayerManager.instance.showLoadingPreview(media);
                      unawaited(PlaybackService.playItem(media));

                      if (!context.mounted) return;

                      await PlayerNavigation.open(context);

                      if (!context.mounted) return;
                      unawaited(loadMovie());
                    },
                    onFavorite: () {
                      // Flip the icon immediately — same optimistic
                      // pattern as play/pause — instead of waiting on
                      // the Jellyfin round-trip. Roll back only if the
                      // request actually fails.
                      final previous = favorite;
                      setState(() {
                        favorite = !favorite;
                      });

                      unawaited(
                        MediaService.toggleFavorite(item!["Id"], previous)
                            .catchError((_) {
                          if (!context.mounted) return;
                          setState(() {
                            favorite = previous;
                          });
                        }),
                      );
                    },
                  ),

                  const SizedBox(
                    height: 30,
                  ),

                  /// Overview
                  _readableOverviewWidth(
                    OverviewSection(
                      overview: item!["Overview"] ?? "",
                    ),
                  ),

                  /// Tags — clickable gold chips that open a grid of
                  /// other titles sharing the same tag (TagItemsScreen).
                  if ((item!["Tags"] as List?)?.isNotEmpty ?? false) ...[
                    const SizedBox(height: 24),
                    TagsRow(
                      tags: List<String>.from(
                        (item!["Tags"] as List).map((t) => t.toString()),
                      ),
                    ),
                  ],

                  /// Studio(s) — logo(s) resolved by StudioService,
                  /// falling back to the studio's name when no artwork
                  /// is found anywhere.
                  if (studios.isNotEmpty) ...[
                    const SizedBox(height: 24),
                    StudioRow(studios: studios),
                  ],

                  /// Seasons
                  if (item!["Type"] == "Series" &&
                      seasons.isNotEmpty) ...[
                    const SizedBox(height: 40),

                    // Chips scroll edge to edge: the 20px inset lives inside
                    // the scroll view instead of clipping it.
                    SeasonSelector(
                      seriesId: item!["Id"],
                      seasons: seasons,
                      selectedSeasonId: selectedSeasonId,
                      onSeasonSelected: loadEpisodes,
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                    ),

                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Was 25 — each episode row already carries its
                          // own 10px top padding (EpisodeCardCompact), so
                          // the visible gap under the season chips was
                          // effectively 25+10=35px, reading as a much
                          // bigger jump than the ~16px used everywhere
                          // else a label sits above its content (see
                          // SeasonSelector's own "Seasons" -> chip row
                          // gap, which is 16). Tightened to match.
                          const SizedBox(height: 14),

                          EpisodeList(
                            episodes: episodes,
                            loading: loadingEpisodes,
                            seriesTitle: item?["Name"] ?? "",
                            seriesImdbId: _seriesImdbId,
                            seasonTitle: seasons.firstWhere(
                                  (s) => s["Id"] == selectedSeasonId,
                              // `seasons` can be a real
                              // `List<Map<String, dynamic>>` at runtime
                              // (built by _offlineSeasonResult() for a
                              // downloads-page open) rather than
                              // `List<dynamic>` — in that case `orElse`
                              // must return `Map<String, dynamic>
                              // Function()`, and a bare `() => {}`
                              // infers as `Map<dynamic, dynamic>
                              // Function()`, which throws a type error
                              // at runtime (the red screen when opening
                              // a downloaded episode). Typing the
                              // literal explicitly fixes it for both
                              // the online and offline paths.
                              orElse: () => <String, dynamic>{},
                            )["Name"],
                            onPlaybackClosed: _refreshCurrentSeasonEpisodes,
                          ),
                        ],
                      ),
                    ),
                  ],

                  /// Cast & Crew
                  if (cast.isNotEmpty) ...[
                    // Was 40 — every other section-to-section gap on
                    // this screen (Cast -> Collection, Collection ->
                    // Similar) is 36; this one was the odd one out and,
                    // stacked on top of EpisodeCardCompact's own 10px
                    // bottom padding on the last row, read as a
                    // noticeably bigger jump than the others. Brought
                    // in line with the rest.
                    const SizedBox(height: 26),

                    CastRow(
                      cast: cast,
                      onTap: (person) {
                        // TMDB-sourced entries (see CastCrewService) only
                        // carry a Jellyfin person id when the same person
                        // is also tagged server-side. Without one,
                        // CastCrewDetailScreen still opens and paints from
                        // initialItem + a name-based Jellyfin lookup —
                        // it just falls back to an empty id for the
                        // favorite calls that genuinely require one.
                        // sourceItem (this movie/show) is passed
                        // regardless, so it always shows up in their
                        // filmography row even when Jellyfin's own People
                        // metadata for it never listed this person at all.
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => CastCrewDetailScreen(
                              personId: person["Id"]?.toString() ?? "",
                              initialItem: Map<String, dynamic>.from(person),
                              sourceItem: item,
                            ),
                          ),
                        );
                      },
                    ),
                  ],

                  /// Collection — loaded separately in the background
                  /// (see _loadCollectionInBackground), so it fades in
                  /// on its own schedule instead of blocking everything
                  /// above it.
                  if (collection != null && collectionItems.isNotEmpty) ...[
                    const SizedBox(height: 40),

                    AnimatedOpacity(
                      opacity: collectionReady ? 1 : 0,
                      duration: const Duration(milliseconds: 250),
                      curve: Curves.easeOut,
                      child: ContentRow(
                        title: collection!["Name"] ?? "Collection",
                        items: collectionItems,
                      ),
                    ),
                  ],

                  /// Similar Movies — loaded separately in the
                  /// background (see _loadSimilarInBackground), so it
                  /// fades in on its own schedule instead of blocking
                  /// everything above it.
                  if (similar.isNotEmpty) ...[
                    const SizedBox(height: 40),

                    AnimatedOpacity(
                      opacity: similarReady ? 1 : 0,
                      duration: const Duration(milliseconds: 250),
                      curve: Curves.easeOut,
                      child: ContentRow(
                        title: "More Like This",
                        items: similar,
                      ),
                    ),
                  ],

                  const SizedBox(height: 40),

                  // Same reasoning as the home screen's trailing
                  // SizedBox — the main nav's bottom bar floats over
                  // this screen in a plain Stack (not a real
                  // Scaffold.extendBody — see MainNavScreen's own doc
                  // comment), so MediaQuery's bottom padding here is
                  // only the safe-area inset. BottomClearance.of adds
                  // the bar's actual height (mini player + tab bar)
                  // back in, reactively, so this trailing row can
                  // actually scroll clear of it.
                  BottomClearanceBuilder(
                    builder: (context, bottomClearance) => SizedBox(
                      height: MediaQuery.paddingOf(context).bottom +
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
    );
  }

  /// Single-page landscape layout: a blurred full-bleed backdrop
  /// behind everything, and one scroll column on top of it — logo,
  /// metadata, action buttons, overview, seasons + a horizontal
  /// episode row (series) or nothing (movie), cast, collection, and
  /// "More Like This" — in that order, same as the portrait layout.
  /// The back button + tinted identity bar stay pinned exactly like
  /// BackdropHeader's collapsed state does in portrait.
  Widget _buildLandscapeScaffold(
    BuildContext context, {
    required String backdrop,
    required List cast,
    required bool resume,
  }) {
    final topPadding = MediaQuery.paddingOf(context).top;
    final isSeries = item!["Type"] == "Series";
    final logoUrl = MediaService.getLogoUrl(item!["Id"]);

    return Scaffold(
      backgroundColor: const Color(0xff111111),
      body: Stack(
        children: [
          LandscapeBackdropBackground(backdropUrl: backdrop),

          AnimatedOpacity(
            opacity: contentReady ? 1 : 0,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
            child: ResistiveRefresh(
              onRefresh: loadMovie,
              color: const Color(0xffD4AF37),
              backgroundColor: const Color(0xff232323),
              child: CustomScrollView(
                controller: _scrollController,
                // A short cast/similar list doesn't overflow the
                // viewport, which otherwise leaves the pull gesture
                // with nothing to grab onto.
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  LandscapeScrollBar(
                    logoUrl: logoUrl,
                    accentImageUrl: backdrop,
                    onBack: _handleBack,
                    scrollOffset: _scrollOffset,
                    topPadding: topPadding,
                  ),
                  SliverToBoxAdapter(
                    // BottomClearanceBuilder rather than reading
                    // PlayerManager once at this build() call — this
                    // whole screen only rebuilds when loadMovie() (or
                    // similar) explicitly calls setState, so without
                    // its own listener the trailing spacer inside
                    // _LandscapeBody could stay stuck at whatever the
                    // mini player's height was the last time that
                    // happened to fire.
                    child: BottomClearanceBuilder(
                      builder: (context, bottomClearance) => _LandscapeBody(
                      item: item!,
                      logoUrl: logoUrl,
                      cast: cast,
                      studios: studios,
                      favorite: favorite,
                      resume: resume,
                      playLabel: _playLabelFor(item!, resume),
                      isSeries: isSeries,
                      seriesId: item!["Id"],
                      seriesTitle: item?["Name"] ?? "",
                      seasons: seasons,
                      selectedSeasonId: selectedSeasonId,
                      episodes: episodes,
                      loadingEpisodes: loadingEpisodes,
                      onSeasonSelected: loadEpisodes,
                      onEpisodesPlaybackClosed: _refreshCurrentSeasonEpisodes,
                      onTrailers: _openTrailers,
                      onPlay: () async {
                        // See the portrait onPlay above for why Series
                        // needs to route through playLibraryItem
                        // instead of trying to play the series id
                        // directly.
                        if (item!["Type"] == "Series") {
                          PlayerManager.instance.showLoadingPreview(
                            MediaService.mediaItemFromJellyfin(item!),
                          );
                          unawaited(
                              PlaybackService.playLibraryItem(item!));

                          if (!context.mounted) return;
                          await PlayerNavigation.open(context);

                          if (!context.mounted) return;
                          unawaited(loadMovie());
                          return;
                        }

                        final media =
                            DownloadManager.instance.mediaItemFor(item!);

                        PlayerManager.instance.showLoadingPreview(media);
                        unawaited(PlaybackService.playItem(media));

                        if (!context.mounted) return;

                        await PlayerNavigation.open(context);

                        if (!context.mounted) return;
                        unawaited(loadMovie());
                      },
                      onFavorite: () {
                        // Flip the icon immediately — same optimistic
                        // pattern as play/pause — instead of waiting on
                        // the Jellyfin round-trip. Roll back only if
                        // the request actually fails.
                        final previous = favorite;
                        setState(() {
                          favorite = !favorite;
                        });

                        unawaited(
                          MediaService.toggleFavorite(item!["Id"], previous)
                              .catchError((_) {
                            if (!context.mounted) return;
                            setState(() {
                              favorite = previous;
                            });
                          }),
                        );
                      },
                      onCastTap: (person) {
                        // See the matching CastRow.onTap above — TMDB
                        // and Jellyfin-sourced entries both open the
                        // detail screen now; one without a Jellyfin
                        // person id just falls back to an empty id, and
                        // sourceItem (this movie/show) is passed
                        // regardless.
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => CastCrewDetailScreen(
                              personId: person["Id"]?.toString() ?? "",
                              initialItem:
                                  Map<String, dynamic>.from(person),
                              sourceItem: item,
                            ),
                          ),
                        );
                      },
                      collection: collection,
                      collectionItems: collectionItems,
                      collectionReady: collectionReady,
                      similar: similar,
                      similarReady: similarReady,
                      bottomInset: MediaQuery.paddingOf(context).bottom +
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
    );
  }
}

/// Single scroll column for the landscape detail layout: no poster,
/// no title text — just the movie/series logo centered up top
/// (falling back to nothing if the title has none, per the design),
/// then the same metadata/action-buttons/overview stack portrait
/// uses, left-aligned underneath it, followed by seasons + a
/// horizontal episode row (series only), cast, collection, and
/// "More Like This" — one flowing page instead of a two-column split.
class _LandscapeBody extends StatelessWidget {
  final Map<String, dynamic> item;

  /// Same lookup as _MovieDetailsScreenState._seriesImdbId — see that
  /// getter's doc for why episodes need the series' id rather than
  /// their own.
  String? get _seriesImdbId {
    final providerIds = item["ProviderIds"];
    if (providerIds is! Map) return null;
    final id = providerIds["Imdb"] ?? providerIds["IMDB"] ?? providerIds["imdb"];
    return id?.toString();
  }
  final String? logoUrl;
  final List cast;
  final List<Map<String, dynamic>> studios;
  final bool favorite;
  final bool resume;
  final String playLabel;
  final VoidCallback onPlay;
  final VoidCallback onFavorite;
  final VoidCallback onTrailers;
  final void Function(dynamic person) onCastTap;

  final bool isSeries;
  final String seriesId;
  final String seriesTitle;
  final List<dynamic> seasons;
  final String? selectedSeasonId;
  final List<dynamic> episodes;
  final bool loadingEpisodes;
  final ValueChanged<String> onSeasonSelected;
  final VoidCallback? onEpisodesPlaybackClosed;

  final Map<String, dynamic>? collection;
  final List<dynamic> collectionItems;
  final bool collectionReady;
  final List<dynamic> similar;
  final bool similarReady;

  final double bottomInset;

  const _LandscapeBody({
    required this.item,
    required this.logoUrl,
    required this.cast,
    required this.studios,
    required this.favorite,
    required this.resume,
    required this.playLabel,
    required this.onPlay,
    required this.onFavorite,
    required this.onTrailers,
    required this.onCastTap,
    required this.isSeries,
    required this.seriesId,
    required this.seriesTitle,
    required this.seasons,
    required this.selectedSeasonId,
    required this.episodes,
    required this.loadingEpisodes,
    required this.onSeasonSelected,
    this.onEpisodesPlaybackClosed,
    required this.collection,
    required this.collectionItems,
    required this.collectionReady,
    required this.similar,
    required this.similarReady,
    required this.bottomInset,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 20),

        /// Logo only — no icon, no title text next to/under it.
        if (logoUrl != null)
          Center(
            child: SizedBox(
              height: 84,
              width: double.infinity,
              child: TrimmedLogo(
                url: logoUrl!,
                alignment: Alignment.center,
                targetArea: 84 * 260,
                maxWidth: 280,
                maxHeight: 84,
                fallbackText: item["Name"]?.toString(),
              ),
            ),
          ),

        const SizedBox(height: 22),

        /// Duration / year / rating and genre chips, centered as one
        /// wrapping block underneath the logo.
        _LandscapeMetaRow(item: item),

        const SizedBox(height: 12),

        ActionButtons(
          favorite: favorite,
          resume: resume,
          stacked: true,
          playLabel: playLabel,
          item: item,
          onPlay: onPlay,
          onFavorite: onFavorite,
          onTrailers: onTrailers,
          centered: true,
        ),

        const SizedBox(height: 26),

        _readableOverviewWidth(
          OverviewSection(
            overview: item["Overview"] ?? "",
          ),
        ),

        /// Tags — same inline "Tags: a, b, c" line as the portrait
        /// layout, left-aligned like OverviewSection just above it
        /// rather than centered with the rest of this split layout's
        /// blocks (logo/meta/actions), since it reads as a paragraph
        /// of text, not a standalone widget block.
        if ((item["Tags"] as List?)?.isNotEmpty ?? false) ...[
          const SizedBox(height: 18),
          TagsRow(
            tags: List<String>.from(
              (item["Tags"] as List).map((t) => t.toString()),
            ),
          ),
        ],

        /// Studio(s) — same as the portrait layout.
        if (studios.isNotEmpty) ...[
          const SizedBox(height: 22),
          StudioRow(studios: studios),
        ],

        if (isSeries && seasons.isNotEmpty) ...[
          const SizedBox(height: 40),

          SeasonSelector(
            seriesId: seriesId,
            seasons: seasons,
            selectedSeasonId: selectedSeasonId,
            onSeasonSelected: onSeasonSelected,
            padding: const EdgeInsets.symmetric(horizontal: 20),
          ),

          const SizedBox(height: 20),

          EpisodeRow(
            episodes: episodes,
            loading: loadingEpisodes,
            seriesTitle: seriesTitle,
            seriesImdbId: _seriesImdbId,
            seasonTitle: seasons.firstWhere(
              (s) => s["Id"] == selectedSeasonId,
              // See the matching comment on the portrait layout's
              // identical lookup above — same fix, same reason.
              orElse: () => <String, dynamic>{},
            )["Name"],
            onPlaybackClosed: onEpisodesPlaybackClosed,
          ),
        ],

        if (cast.isNotEmpty) ...[
          const SizedBox(height: 36),
          CastRow(
            cast: cast,
            onTap: onCastTap,
          ),
        ],

        if (collection != null && collectionItems.isNotEmpty) ...[
          const SizedBox(height: 36),
          AnimatedOpacity(
            opacity: collectionReady ? 1 : 0,
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOut,
            child: ContentRow(
              title: collection!["Name"] ?? "Collection",
              items: collectionItems,
            ),
          ),
        ],

        if (similar.isNotEmpty) ...[
          const SizedBox(height: 36),
          AnimatedOpacity(
            opacity: similarReady ? 1 : 0,
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOut,
            child: ContentRow(
              title: "More Like This",
              items: similar,
            ),
          ),
        ],

        SizedBox(height: 40 + bottomInset),
      ],
    );
  }
}

/// Duration / year / official rating / community rating, centered as
/// one wrapping block — with genre chips (ExpandableGenreChips, same
/// widget the music detail screens use) in their own centered row
/// underneath, rather than sharing the metadata line off to the side.
/// The metadata line for the landscape split layout (movie and series
/// alike).
class _LandscapeMetaRow extends StatelessWidget {
  final Map<String, dynamic> item;

  const _LandscapeMetaRow({required this.item});

  /// Whether [item] is likely to have an IMDb/Rotten Tomatoes rating to
  /// show — used only to decide whether the separating dot before
  /// RatingsRow renders, since RatingsRow itself resolves
  /// asynchronously (or synchronously from cache) and quietly renders
  /// nothing when it comes back empty.
  bool _hasRatingSignal(Map<String, dynamic> item) {
    final providerIds = item["ProviderIds"];
    return providerIds is Map &&
        (providerIds["Imdb"] ?? providerIds["IMDB"] ?? providerIds["imdb"]) !=
            null;
  }

  @override
  Widget build(BuildContext context) {
    // A Series item's RunTimeTicks reflects a single (often arbitrary)
    // episode's duration, not the show as a whole, so it's misleading
    // to show it here — only movies get a duration readout.
    final runtime = item["Type"] == "Series"
        ? ""
        : MediaService.formatRuntime(item["RunTimeTicks"]);
    final year = item["ProductionYear"]?.toString() ?? "";
    final official = item["OfficialRating"] ?? "";
    final genres = List<String>.from(
      (item["Genres"] as List? ?? []).map((g) => g.toString()),
    );

    final infoParts = <Widget>[];
    void addDot() {
      if (infoParts.isNotEmpty) {
        infoParts.add(
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              "•",
              style: TextStyle(color: Colors.white54, fontSize: 14),
            ),
          ),
        );
      }
    }

    if (runtime.isNotEmpty) {
      addDot();
      infoParts.add(
        Text(
          runtime,
          style: const TextStyle(color: Colors.white70, fontSize: 14),
        ),
      );
    }

    if (year.isNotEmpty) {
      addDot();
      infoParts.add(
        Text(
          year,
          style: const TextStyle(color: Colors.white70, fontSize: 14),
        ),
      );
    }

    if (official.isNotEmpty) {
      addDot();
      infoParts.add(
        Text(
          official,
          style: const TextStyle(color: Colors.white70, fontSize: 14),
        ),
      );
    }

    if (_hasRatingSignal(item)) {
      addDot();
      infoParts.add(
        RatingsRow(
          item: item,
          fontSize: 14,
          textColor: Colors.white,
          badgeHeight: 15,
        ),
      );
    }

    if (infoParts.isEmpty && genres.isEmpty) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Metadata line — when it fits within the available width
          // it's centered as a single block; if it's too wide, it
          // becomes horizontally slidable instead of wrapping, so
          // runtime/year/rating/ratings-row stay one unbroken line.
          if (infoParts.isNotEmpty)
            LayoutBuilder(
              builder: (context, constraints) {
                return SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: ConstrainedBox(
                    constraints:
                        BoxConstraints(minWidth: constraints.maxWidth),
                    child: Center(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: infoParts,
                      ),
                    ),
                  ),
                );
              },
            ),

          // Genre chips now sit on their own centered row below the
          // metadata line instead of sharing it off to the right — same
          // ExpandableGenreChips widget (with its wrap + "Show more"
          // overflow handling) the music detail screens already use,
          // rather than the fixed-8/no-wrap chip row this used to be.
          if (genres.isNotEmpty) ...[
            if (infoParts.isNotEmpty) const SizedBox(height: 14),
            ExpandableGenreChips(
              genres: genres,
              alignment: WrapAlignment.center,
              onGenreTap: (genre) => _openGenre(context, genre),
            ),
          ],
        ],
      ),
    );
  }
}

class _SeasonResult {
  final List<dynamic> seasons;
  final List<dynamic> episodes;
  final String? selectedSeasonId;

  const _SeasonResult({
    required this.seasons,
    required this.episodes,
    required this.selectedSeasonId,
  });
}

class _CollectionResult {
  final Map<String, dynamic>? collection;
  final List<dynamic> items;

  const _CollectionResult({
    required this.collection,
    required this.items,
  });
}
