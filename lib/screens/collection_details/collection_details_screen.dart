import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../services/cache/nemesis_image_cache.dart';
import '../../services/jellyfin_services/media_service.dart';
import '../../utils/responsive.dart';
import '../movie_details/movie_details_screen.dart';
import '../movie_details/widgets/action_buttons.dart';
import '../movie_details/widgets/backdrop_header.dart';
import '../movie_details/widgets/content_row.dart';
import '../movie_details/widgets/overview_section.dart';
import '../../player/player_manager.dart';
import '../../player/services/playback_queue.dart';
import '../../player/screens/player_navigation.dart';
import '../../widgets/common/centered_landscape_header.dart';
import '../../widgets/common/resistive_refresh.dart';
import '../shared/tag_items_screen.dart';
import '../../utils/bottom_clearance.dart';

/// Opens [TagItemsScreen] filtered to [genre] — same destination the
/// movie/series detail screen's genre chips use, wired up separately
/// here since that screen's own `_openGenre` helper is file-private.
void _openGenre(BuildContext context, String genre) {
  Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => TagItemsScreen(genre: genre),
    ),
  );
}

class CollectionDetailsScreen extends StatefulWidget {
  final String collectionId;

  /// Whatever the tapped card already had in memory (poster, title,
  /// etc). When present, the screen paints with this immediately
  /// instead of a blank spinner, then silently swaps in the
  /// authoritative full record once it loads.
  final Map<String, dynamic>? initialItem;

  const CollectionDetailsScreen({
    super.key,
    required this.collectionId,
    this.initialItem,
  });

  @override
  State<CollectionDetailsScreen> createState() =>
      _CollectionDetailsScreenState();
}

class _CollectionDetailsScreenState extends State<CollectionDetailsScreen> {
  Map<String, dynamic>? collection;
  List<dynamic> collectionItems = [];
  List<dynamic> similar = [];
  bool loading = true;
  bool favorite = false;
  String? error;

  // Raw scroll offset of the page, fed to BackdropHeader so its
  // collapsed bar can cycle through the collection's own movies the
  // further down the person scrolls (see BackdropAlternate). Tracked
  // as a ValueNotifier rather than setState so scrolling doesn't
  // rebuild the whole screen — only the small collapsed-bar widget
  // listens to it.
  final ValueNotifier<double> _scrollOffset = ValueNotifier(0);
  late final ScrollController _scrollController;

  // See MovieDetailsScreen for the reasoning: everything below the
  // header fades in as one unit once the fetch settles, instead of
  // popping in piece by piece.
  bool contentReady = false;

  // "Similar" is a supplementary row — it no longer gates contentReady,
  // so a slow Similar endpoint can't hold up the collection's own item
  // grid from appearing. It fades in on its own once it lands.
  bool similarReady = false;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController()
      ..addListener(() {
        _scrollOffset.value = _scrollController.offset;
      });
    // Paint immediately with the preview from whatever grid/row got us
    // here; _loadCollection() below fetches the authoritative record
    // and silently replaces it (no spinner) once it's ready.
    collection = widget.initialItem;
    favorite = widget.initialItem?['UserData']?['IsFavorite'] ?? false;
    loading = widget.initialItem == null;
    _loadCollection();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _scrollOffset.dispose();
    super.dispose();
  }

  Future<void> _loadCollection() async {
    final hadPreview = collection != null;

    if (!hadPreview) {
      setState(() {
        loading = true;
        error = null;
      });
    }

    // Similar is a single extra call that has nothing to do with the
    // collection's own item grid, so it's fetched independently and no
    // longer bundled into the Future.wait that gates contentReady — a
    // slow Similar response can't hold up the rest of the page.
    // Similar only starts once the collection's own fetch settles, so its
    // many small requests never compete with the header art and the
    // collection record for bandwidth.
    final similarGate = Completer<void>();
    _loadSimilarInBackground(similarGate.future);

    try {
      // These two depend on each other's result — only on
      // widget.collectionId — so fire them together instead of
      // waiting on each in turn.
      final results = await Future.wait([
        MediaService.getItem(widget.collectionId),
        MediaService.getItems(
          parentId: widget.collectionId,
          includeItemTypes: 'Movie,Series',
          sortBy: 'SortName',
          sortOrder: 'Ascending',
        ),
      ]);

      final loadedCollection = results[0] as Map<String, dynamic>;
      final items = results[1] as List<dynamic>;

      if (!mounted) return;

      setState(() {
        collection = loadedCollection;
        collectionItems = items;
        favorite = loadedCollection['UserData']?['IsFavorite'] ?? false;
        loading = false;
        contentReady = true;
      });
    } catch (exception) {
      if (!mounted) return;
      // A refresh failing shouldn't blank out a screen that's already
      // showing good preview content.
      if (hadPreview) {
        setState(() => contentReady = true);
        return;
      }
      setState(() {
        error = exception.toString();
        loading = false;
      });
    } finally {
      if (!similarGate.isCompleted) similarGate.complete();
    }
  }

  /// Runs independently of _loadCollection() so a slow Similar-items
  /// response can't delay the collection's own item grid from
  /// appearing. Sets its own `similarReady` flag so the row fades in on
  /// its own once its data actually arrives.
  Future<void> _loadSimilarInBackground(Future<void> after) async {
    try {
      // Never wait more than a few seconds for the main fetch.
      await after.timeout(const Duration(seconds: 4), onTimeout: () {});
      if (!mounted) return;
      // Similar items are not available on every Jellyfin collection.
      final related = await MediaService.getSimilarItems(widget.collectionId)
          .catchError((_) => <dynamic>[]);

      if (!mounted) return;

      setState(() {
        similar = related;
        similarReady = true;
      });
    } catch (_) {
      if (!mounted) return;

      setState(() {
        similarReady = true;
      });
    }
  }

  void _openItem(dynamic item) {
    if (item['Type'] == 'BoxSet') {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => CollectionDetailsScreen(
            collectionId: item['Id'],
            initialItem: Map<String, dynamic>.from(item),
          ),
        ),
      );
      return;
    }

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MovieDetailsScreen(
          itemId: item['Id'],
          initialItem: Map<String, dynamic>.from(item),
          onBack: () => Navigator.of(context).pop(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Scaffold(
        backgroundColor: Color(0xff111111),
        body: Center(
          child: CircularProgressIndicator(
            color: Color(0xffD4AF37),
          ),
        ),
      );
    }

    if (error != null || collection == null) {
      return Scaffold(
        backgroundColor: const Color(0xff111111),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  error ?? 'Collection not found.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70),
                ),
                const SizedBox(height: 16),
                OutlinedButton(
                  onPressed: _loadCollection,
                  child: const Text('Retry'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final currentCollection = collection!;
    final isLandscape = Responsive.isLandscape(context);

    // One alternate identity per movie/series in the collection, used
    // to cycle the collapsed bar's logo + tint as the person scrolls
    // further down — falls back to the collection's own (often
    // logo-less) identity until there's at least one real item.
    final alternates = collectionItems
        .whereType<Map>()
        .map(
          (movie) => BackdropAlternate(
            logoUrl: MediaService.getLogoUrl(movie['Id']),
            accentImageUrl: MediaService.getAccentSampleUrl(movie['Id']),
          ),
        )
        .toList();

    return Scaffold(
      backgroundColor: const Color(0xff111111),
      body: Stack(
        children: [
          // Landscape only: full-bleed backdrop sitting behind the
          // *entire* page (header + scrolling content alike), so the
          // header blends straight into the rest of the screen with no
          // seam between them. Loaded sharp (no blur, no low-res
          // stand-in), dimmed only enough to keep the text readable.
          // Portrait keeps its own BackdropHeader below.
          if (isLandscape)
            Positioned.fill(
              child: RepaintBoundary(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    CachedNetworkImage(
                      cacheManager: NemesisImageCache.instance,
                      imageUrl: MediaService.getBackdropUrl(
                          currentCollection['Id']),
                      fit: BoxFit.cover,
                      fadeInDuration: const Duration(milliseconds: 200),
                      placeholder: (_, __) =>
                          Container(color: const Color(0xff111111)),
                      errorWidget: (_, __, ___) =>
                          Container(color: const Color(0xff111111)),
                    ),
                    Container(color: Colors.black.withValues(alpha: .45)),
                  ],
                ),
              ),
            ),
          ResistiveRefresh(
        onRefresh: _loadCollection,
        color: const Color(0xffD4AF37),
        backgroundColor: const Color(0xff232323),
        child: CustomScrollView(
        controller: _scrollController,
        // A short collection (a couple of movies) doesn't overflow the
        // viewport, which otherwise leaves the pull gesture with nothing
        // to grab onto.
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          /// Landscape swaps in a centered poster/name header over a
          /// blurred backdrop (matching the movie detail screen's
          /// landscape background) instead of BackdropHeader's
          /// bottom-left poster+logo layout with its collapsed-bar
          /// alternation between the collection's own movies.
          if (isLandscape)
            CenteredLandscapeHeader(
              backdropUrl:
                  MediaService.getBackdropUrl(currentCollection['Id']),
              // The page-wide backdrop added above the scroll view
              // already covers this header, so painting another copy
              // (or fading down to a flat page color) here would just
              // recreate the seam between header and content that this
              // was meant to remove.
              showBackground: false,
              // Same alternation the portrait BackdropHeader uses for
              // its collapsed bar — keeps the collapsed top bar's
              // behavior identical across orientations instead of
              // just fading to a blank bar here.
              alternateItems: alternates.isEmpty ? null : alternates,
              scrollOffset: _scrollOffset,
              // A bit taller than a plain fraction-of-screen would give
              // — the icon/title block here is centered within this
              // header (unlike the movie/cast & crew screens' thin
              // fixed bar with content below it), so it needs more
              // reserved height for that centered block to land at the
              // same gap-from-top those screens show.
              expandedHeight: Responsive.heroHeight(
                context,
                portraitHeight: 620,
                landscapeFraction: 0.85,
                landscapeMin: 260,
                landscapeMax: 330,
              ),
              onBack: () => Navigator.of(context).pop(),
              title: currentCollection['Name'] ?? '',
              // Same year / PG rating / rating-badges / genre-chips row
              // BackdropHeader shows in portrait — collections do carry
              // this metadata (e.g. a curated year range, an aggregate
              // rating), it just wasn't wired up on the landscape header.
              item: currentCollection,
              onGenreTap: (genre) => _openGenre(context, genre),
              baseIconSize: 130,
              // Static during scroll — matches the album detail
              // screen's landscape header, which keeps its icon at a
              // fixed size instead of shrinking as the header collapses.
              iconShrink: 0,
              iconBuilder: (size) => ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: CachedNetworkImage(
                  cacheManager: NemesisImageCache.instance,
                  imageUrl: MediaService.getImageUrl(
                    currentCollection['Id'],
                    maxWidth: 500,
                  ),
                  width: size * 0.72,
                  height: size,
                  fit: BoxFit.cover,
                  fadeInDuration: const Duration(milliseconds: 200),
                  // The grid card's own cached image, shown at once.
                  placeholder: (_, __) => CachedNetworkImage(
                    cacheManager: NemesisImageCache.instance,
                    imageUrl: MediaService.getImageUrl(
                      currentCollection['Id'],
                      maxWidth: 300,
                    ),
                    width: size * 0.72,
                    height: size,
                    fit: BoxFit.cover,
                    memCacheWidth: 260,
                    fadeInDuration: Duration.zero,
                    fadeOutDuration: Duration.zero,
                    placeholder: (_, __) => Container(
                      width: size * 0.72,
                      height: size,
                      color: const Color(0xff2A2A2A),
                    ),
                    errorWidget: (_, __, ___) => Container(
                      width: size * 0.72,
                      height: size,
                      color: const Color(0xff2A2A2A),
                    ),
                  ),
                  errorWidget: (_, __, ___) => Container(
                    width: size * 0.72,
                    height: size,
                    color: const Color(0xff2A2A2A),
                    child: const Icon(
                      Icons.video_library,
                      color: Colors.white38,
                      size: 32,
                    ),
                  ),
                ),
              ),
            )
          else
            BackdropHeader(
              // No low-res preview underneath: the full backdrop loads
              // directly instead of sharpening up from a blurry copy.
              backdropUrl: MediaService.getBackdropUrl(currentCollection['Id']),
              posterUrl: MediaService.getImageUrl(
                currentCollection['Id'],
                maxWidth: 500,
              ),
              // Exactly what MovieCard loads in the grid (w342), so it is
              // already on disk and paints instantly.
              posterPreviewUrl: MediaService.getImageUrl(
                currentCollection['Id'],
                maxWidth: 300,
              ),
              logoUrl: MediaService.getLogoUrl(currentCollection['Id']),
              item: currentCollection,
              onBack: () => Navigator.of(context).pop(),
              onGenreTap: (genre) => _openGenre(context, genre),
              alternateItems: alternates.isEmpty ? null : alternates,
              scrollOffset: _scrollOffset,
              // Stacks the icon above a centered title, with the
              // genre chips centered underneath, instead of the
              // side-by-side poster+text row — matches the buttons
              // row below, which is already centered (ActionButtons'
              // `centered: true`).
              centerIcon: true,
              // Same fix as the movie/series detail screen's portrait
              // header (see its own infoBottomInset comment): without
              // this, infoBottomInset defaults to 30 in portrait, and
              // the SizedBox(height: 28) that used to follow this
              // header stacked on top of it for a 58dp chips-to-buttons
              // gap — nearly double what it should be. 14 here plus
              // removing that SizedBox below gives the same tight gap
              // the movie/series screen settled on.
              infoBottomInset: 14,
            ),
          SliverToBoxAdapter(
            child: AnimatedOpacity(
              opacity: contentReady ? 1 : 0,
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOut,
              child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // No SizedBox here any more — see the comments on the
                // two headers above. Landscape's CenteredLandscapeHeader
                // already bottom-anchors its genre chips with its own
                // fixed 16dp inset, and portrait's BackdropHeader now
                // does the same via infoBottomInset: 14 — a SizedBox
                // here on top of either was doubling the chips-to-
                // buttons gap (32dp landscape / 58dp portrait).
                ActionButtons(
                  favorite: favorite,
                  resume: false,
                  // Keeps the enclosed (circled) buttons but names them:
                  // "Start Watching" on the gold button and a "Favorite"
                  // label to the right of the heart.
                  enclosedLabels: true,
                  playLabel: "Start Watching",
                  // Centered in both orientations, matching the
                  // movie/series and music detail screens. This used
                  // to be `centered: isLandscape`, which left the
                  // portrait layout's button group flush left.
                  centered: true,
                  onPlay: () async {
                    final mediaItems =
                    MediaService.mediaItemsFromList(collectionItems);

                    if (mediaItems.isEmpty) return;

                    // Show the player immediately with a loading
                    // overlay instead of waiting on the stream to open
                    // before navigating there.
                    PlayerManager.instance.showLoadingPreview(mediaItems.first);

                    unawaited(PlayerManager.instance.playQueue(
                      mediaItems,
                      source: PlaybackSource.collection,
                      title: currentCollection["Name"],
                      artwork: MediaService.getImageUrl(
                        currentCollection["Id"],
                      ),
                    ));

                    if (!mounted) return;

                    await PlayerNavigation.open(context);
                  },
                  onFavorite: () {
                    // Flip the icon immediately — same optimistic
                    // pattern as play/pause — instead of waiting on
                    // the Jellyfin round-trip. Roll back only if the
                    // request actually fails.
                    final previous = favorite;
                    setState(() => favorite = !favorite);

                    unawaited(
                      MediaService.toggleFavorite(
                        currentCollection['Id'],
                        previous,
                      ).catchError((_) {
                        if (!mounted) return;
                        setState(() => favorite = previous);
                      }),
                    );
                  },
                ),
                const SizedBox(height: 30),
                OverviewSection(
                  overview: currentCollection['Overview'] ?? '',
                ),
                if (collectionItems.isNotEmpty) ...[
                  const SizedBox(height: 40),
                  ContentRow(
                    title: 'In This Collection',
                    items: collectionItems,
                    onItemTap: _openItem,
                  ),
                ],
                if (similar.isNotEmpty) ...[
                  const SizedBox(height: 40),
                  AnimatedOpacity(
                    opacity: similarReady ? 1 : 0,
                    duration: const Duration(milliseconds: 250),
                    curve: Curves.easeOut,
                    child: ContentRow(
                      title: 'More Like This',
                      items: similar,
                      onItemTap: _openItem,
                    ),
                  ),
                ],
                const SizedBox(height: 40),

                // The main nav's bottom bar (mini player + tab bar)
                // floats over this screen in a plain Stack, not a real
                // Scaffold.extendBody (see MainNavScreen's own doc
                // comment) — MediaQuery's bottom padding here is only
                // the safe-area inset. BottomClearance.of adds the
                // bar's actual current height back in, reactively, so
                // the last row's content can clear it instead of
                // stopping behind it.
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
        ],
      ),
    );
  }
}
