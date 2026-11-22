import 'dart:async';

import 'package:flutter/material.dart';

import '../../player/models/media_item.dart';
import '../../player/playback_service.dart';
import '../../player/player_manager.dart';
import '../../player/screens/audio_player_screen.dart';
import '../../player/services/playback_queue.dart';
import '../../services/download_manager.dart';
import '../../services/favorite_service.dart';
import '../../services/jellyfin_services/media_service.dart';
import '../../services/jellyfin_services/music_service.dart';
import '../../services/local_music_service.dart';
import '../../utils/bottom_clearance.dart';
import '../../utils/responsive.dart';
import '../../widgets/common/collapsing_screen_label.dart';
import '../../widgets/common/empty_state.dart';
import '../../widgets/common/fade_scrollbar.dart';
import '../../widgets/common/resistive_refresh.dart';
import '../../widgets/music/artist_card.dart';
import '../../widgets/music/playlist_card.dart';
import '../../widgets/music/song_multi_select.dart';
import '../../widgets/music/song_row.dart';
import '../../widgets/music/song_selection_bar.dart';
import '../../widgets/music/song_selection_actions.dart';
import '../../widgets/music/playlist_picker_sheet.dart';
import '../../widgets/shared/selector_dropdown.dart';
import '../cast_crew/cast_crew_detail_screen.dart';
import '../collection_details/collection_details_screen.dart';
import '../movie_details/movie_details_screen.dart';
import '../movie_details/widgets/cast_row.dart';
import '../movies/widgets/movie_grid.dart';
import '../movies/widgets/sort_chips.dart';
import '../music/music_detail_screen.dart';
import '../music/widgets/album_grid.dart';

const _gold = Color(0xffD4AF37);
const _bg = Color(0xff161616);

/// Which favorites list a [FavoriteItemsScreen] shows. (TV channels have
/// no entry: "See all" there just opens the existing favorite-channels
/// page.)
enum FavoriteKind {
  movies,
  shows,
  collections,
  albums,
  artists,
  playlists,
  people,
  songs,
}

/// Full-screen "See all" grid behind the gold "See all" link on each
/// Favorites section. Re-uses the layout of [TagItemsScreen] (back
/// button + label, then a sort-chip row with the search field on the
/// right, then the scrolling grid) and the same cards the Favorites page
/// itself uses for that section — only the data source (this user's
/// favorites of one kind) and the sort options differ.
class FavoriteItemsScreen extends StatefulWidget {
  final FavoriteKind kind;

  const FavoriteItemsScreen({super.key, required this.kind});

  @override
  State<FavoriteItemsScreen> createState() => _FavoriteItemsScreenState();
}

class _FavoriteItemsScreenState extends State<FavoriteItemsScreen> {
  static const _sortAz = "az";
  static const _sortAdded = "added";
  static const _sortRating = "rating";

  bool loading = true;
  List<dynamic> items = [];

  /// Newest-favorited-first is the order the Favorites page rows use, so
  /// the grid opens in that same order.
  String selectedSort = _sortAdded;

  String search = "";
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  final ScrollController _scrollController = ScrollController();
  Timer? _searchDebounce;

  /// id -> favorited-at (ms since epoch). See FavoritesScreen: Jellyfin
  /// has no "date favorited", so this local/synced record is the only
  /// source for "time added". Items without one sort after those with.
  Map<String, int> _favoritedAt = {};

  // Hold-to-multi-select, songs only (same as the Songs tab).
  final SongMultiSelect _songSelect = SongMultiSelect();

  bool get _hasRating =>
      widget.kind == FavoriteKind.movies || widget.kind == FavoriteKind.shows;

  String get _label {
    switch (widget.kind) {
      case FavoriteKind.movies:
        return "Favorite movies";
      case FavoriteKind.shows:
        return "Favorite TV shows";
      case FavoriteKind.collections:
        return "Favorite collections";
      case FavoriteKind.albums:
        return "Favorite albums";
      case FavoriteKind.artists:
        return "Favorite artists";
      case FavoriteKind.playlists:
        return "Favorite playlists";
      case FavoriteKind.people:
        return "Favorite cast & crew";
      case FavoriteKind.songs:
        return "Favorite songs";
    }
  }

  IconData get _emptyIcon {
    switch (widget.kind) {
      case FavoriteKind.movies:
      case FavoriteKind.shows:
        return Icons.movie_outlined;
      case FavoriteKind.collections:
        return Icons.collections_bookmark_outlined;
      case FavoriteKind.albums:
        return Icons.album_outlined;
      case FavoriteKind.artists:
      case FavoriteKind.people:
        return Icons.person_outline;
      case FavoriteKind.playlists:
        return Icons.queue_music;
      case FavoriteKind.songs:
        return Icons.music_note;
    }
  }

  String get _emptyNoun => _label.replaceFirst("Favorite ", "");

  /// Movies/TV shows offer A-Z, Time added and Rating; everything else
  /// has no rating to sort by, so just A-Z and Time added.
  List<Map<String, String>> get _sortOptions => [
        {"label": "A-Z", "value": _sortAz},
        {"label": "Time added", "value": _sortAdded},
        if (_hasRating) {"label": "Rating", "value": _sortRating},
      ];

  @override
  void initState() {
    super.initState();
    _load();

    // Reload when a favorite changes elsewhere while this grid is open
    // underneath another screen (e.g. hearting the playing song from the
    // full-screen audio player) — see FavoriteService.changes.
    FavoriteService.changes.addListener(_onFavoritesChanged);
  }

  Timer? _changeDebounce;

  void _onFavoritesChanged() {
    _changeDebounce?.cancel();
    _changeDebounce = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      _load(silent: true);
    });
  }

  @override
  void dispose() {
    FavoriteService.changes.removeListener(_onFavoritesChanged);
    _changeDebounce?.cancel();
    _searchDebounce?.cancel();
    _searchController.dispose();
    _searchFocusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------
  // Loading + sorting
  // ---------------------------------------------------------------------

  Future<List<dynamic>> _fetch() async {
    switch (widget.kind) {
      case FavoriteKind.movies:
        return (await MediaService.getFavoriteItems(includeItemTypes: "Movie"))
            .toList();
      case FavoriteKind.shows:
        return (await MediaService.getFavoriteItems(
          includeItemTypes: "Series",
        ))
            .toList();
      case FavoriteKind.collections:
        return (await MediaService.getFavoriteItems(
          includeItemTypes: "BoxSet",
        ))
            .toList();
      case FavoriteKind.albums:
        return (await MediaService.getFavoriteItems(
          includeItemTypes: "MusicAlbum",
        ))
            .toList();
      case FavoriteKind.artists:
        return (await MusicService.getFavoriteArtists()).toList();
      case FavoriteKind.playlists:
        return (await MediaService.getFavoriteItems(
          includeItemTypes: "Playlist",
        ))
            .toList();
      case FavoriteKind.people:
        // The Favorites page row caps at the API default (50); the full
        // grid asks for everything.
        return (await MediaService.getFavoritePeople(limit: 5000)).toList();
      case FavoriteKind.songs:
        // Server favorites plus on-device favorites, same merge the
        // Favorites page's Songs section does.
        final server = await MediaService.getFavoriteSongs();
        List<dynamic> local = [];
        try {
          local = await LocalMusicService.instance.getFavoritedSongs();
        } catch (e) {
          debugPrint(e.toString());
        }
        return [...server, ...local];
    }
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) {
      setState(() => loading = true);
    }

    try {
      _songSelect.clear();

      // Same merge FavoritesScreen does: on-device songs keep their own
      // local-only timestamp map, merged into one lookup here.
      _favoritedAt = {
        ...await FavoriteService.getFavoritedTimestamps(),
        ...LocalMusicService.instance.favoritedAtTimestamps,
      };

      final data = await _fetch();

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

  /// Sort key for A-Z. Prefers the server's SortName; the favorites
  /// queries don't request that field, so otherwise falls back to the
  /// display name minus a leading "The "/"A "/"An ", which is how the
  /// server builds SortName and how the Movies tab already orders.
  String _nameOf(dynamic item) {
    final map = item as Map;
    final sortName = map["SortName"]?.toString();
    if (sortName != null && sortName.isNotEmpty) return sortName.toLowerCase();

    final name = (map["Name"] ?? "").toString().toLowerCase().trim();
    for (final article in const ["the ", "an ", "a "]) {
      if (name.startsWith(article) && name.length > article.length) {
        return name.substring(article.length);
      }
    }
    return name;
  }

  /// When [item] was favorited. The item's own time (the built-in catalog
  /// stamps movies, shows and cast & crew with FavoritedAtMs, and it syncs
  /// with the account) wins; otherwise the device's record in
  /// [_favoritedAt] (channels, on-device songs).
  int? _addedAtOf(dynamic item) {
    final map = item as Map;
    final own = map["FavoritedAtMs"];
    if (own is num) return own.toInt();
    return _favoritedAt[map["Id"]?.toString()];
  }

  /// Applies the selected sort to [list] (already search-filtered).
  List<dynamic> _sorted(List<dynamic> list) {
    final result = List<dynamic>.from(list);

    switch (selectedSort) {
      case _sortAz:
        result.sort((a, b) => _nameOf(a).compareTo(_nameOf(b)));
        break;

      case _sortRating:
        result.sort((a, b) {
          final ar = ((a as Map)["CommunityRating"] as num?)?.toDouble();
          final br = ((b as Map)["CommunityRating"] as num?)?.toDouble();
          if (ar == null && br == null) return _nameOf(a).compareTo(_nameOf(b));
          if (ar == null) return 1;
          if (br == null) return -1;
          final byRating = br.compareTo(ar);
          return byRating != 0 ? byRating : _nameOf(a).compareTo(_nameOf(b));
        });
        break;

      case _sortAdded:
      default:
        // Latest favorited first, farthest last. Items with no recorded
        // time (favorited before the app tracked it, or elsewhere) go
        // after the timestamped ones, and keep the order they arrived in
        // (the built-in catalog lists favorites newest first). They used
        // to be put in alphabetical order, which made this sort come out
        // identical to A-Z whenever no times were known.
        final arrival = Map<dynamic, int>.identity();
        for (var i = 0; i < list.length; i++) {
          arrival[list[i]] = i;
        }
        result.sort((a, b) {
          final at = _addedAtOf(a);
          final bt = _addedAtOf(b);
          if (at != null && bt != null) {
            final byTime = bt.compareTo(at);
            if (byTime != 0) return byTime;
          } else if (at == null && bt != null) {
            return 1;
          } else if (at != null && bt == null) {
            return -1;
          }
          return arrival[a]!.compareTo(arrival[b]!);
        });
        break;
    }

    return result;
  }

  List<dynamic> get _visibleItems {
    Iterable<dynamic> list = items;

    if (search.isNotEmpty) {
      final query = search.toLowerCase();
      list = list.where((item) {
        final name = ((item as Map)["Name"] ?? "").toString().toLowerCase();
        return name.contains(query);
      });
    }

    return _sorted(list.toList());
  }

  void _changeSort(String sort) {
    if (sort == selectedSort) return;
    setState(() => selectedSort = sort);
  }

  void _onSearchChanged(String value) {
    search = value;

    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      setState(() {});
    });
  }

  // ---------------------------------------------------------------------
  // Navigation
  // ---------------------------------------------------------------------

  /// Opens a detail screen, then quietly refreshes — the person may have
  /// un-favorited the item over there, and it should drop out of here.
  Future<void> _open(Widget screen) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
    if (!mounted) return;
    await _load(silent: true);
  }

  void _openCollection(dynamic item) => _open(
        CollectionDetailsScreen(
          collectionId: item["Id"],
          initialItem: Map<String, dynamic>.from(item),
        ),
      );

  void _openMovieOrShow(dynamic item) => _open(
        MovieDetailsScreen(
          itemId: item["Id"],
          initialItem: Map<String, dynamic>.from(item),
        ),
      );

  void _openMusicDetail(dynamic item) => _open(
        MusicDetailScreen(
          itemId: item["Id"],
          initialItem: Map<String, dynamic>.from(item),
        ),
      );

  // ---------------------------------------------------------------------
  // Songs: playback + multi-select (same behavior as the Favorites page)
  // ---------------------------------------------------------------------

  // Per-song local/server branch (shared with the other song lists) —
  // this list interleaves server favorites and on-device ones.
  static List<MediaItem> _mediaItemsFromSongs(List songList) =>
      mediaItemsFromMixedSongs(songList);

  Future<void> _playSongs(List songList, {int startIndex = 0}) async {
    if (songList.isEmpty) return;

    final wasAlreadyPlaying = PlayerManager.instance.currentItem != null;
    final queue = _mediaItemsFromSongs(songList);

    if (!wasAlreadyPlaying) {
      PlayerManager.instance.showLoadingPreview(queue[startIndex]);

      Navigator.of(context, rootNavigator: true).push(
        MaterialPageRoute(builder: (_) => const AudioPlayerScreen()),
      );

      await PlaybackService.playQueue(
        queue,
        startIndex: startIndex,
        source: PlaybackSource.unknown,
        title: "Favorites",
      );
      return;
    }

    await PlaybackService.playQueue(
      queue,
      startIndex: startIndex,
      source: PlaybackSource.unknown,
      title: "Favorites",
    );

    if (!mounted) return;

    final error = PlayerManager.instance.lastError.value;
    if (error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error)),
      );
    }
  }

  void _enterSongSelection(String id) => setState(() => _songSelect.enter(id));
  void _toggleSongSelection(String id) =>
      setState(() => _songSelect.toggle(id));
  void _exitSongSelection() => setState(() => _songSelect.clear());

  List<Map<String, dynamic>> get _selectedSongs => items
      .whereType<Map>()
      .where((s) => _songSelect.selectedIds.contains(s["Id"].toString()))
      .map((s) => Map<String, dynamic>.from(s))
      .toList();

  Future<void> _bulkAddSelectedSongsToQueue() async {
    final selected = _selectedSongs;
    if (selected.isEmpty) return;

    final messenger = ScaffoldMessenger.maybeOf(context);

    if (PlayerManager.instance.currentItem == null) {
      _exitSongSelection();
      messenger?.showSnackBar(
        const SnackBar(
          content: Text("Play something first to add songs to the queue"),
        ),
      );
      return;
    }

    final queueItems = _mediaItemsFromSongs(selected);
    for (final mediaItem in queueItems) {
      PlaybackQueue.instance.addToQueue(mediaItem);
    }

    _exitSongSelection();
    messenger?.showSnackBar(
      SnackBar(
        content: Text(
          '${queueItems.length} song${queueItems.length == 1 ? '' : 's'} added to queue',
        ),
      ),
    );
  }

  /// "Play selected": a brand-new queue of exactly the selected songs,
  /// in list order (same action as the Favorites page's Songs section).
  Future<void> _playSelectedSongs() async {
    final selected = _selectedSongs;
    if (selected.isEmpty) return;

    final queue = _mediaItemsFromSongs(selected);

    _exitSongSelection();
    await playSelectionAsQueue(context, queue);
  }

  /// Bulk "Remove from App" for the on-device rows among the selection
  /// (server rows selected alongside them are left alone — a server
  /// favorite is removed by un-favoriting it). Drops the removed rows
  /// from the list immediately rather than waiting on a reload.
  Future<void> _bulkRemoveSelectedLocalSongs() async {
    final removed =
        await confirmRemoveLocalSongsFromApp(context, _selectedSongs);
    if (removed == null || !mounted) return;

    final removedSet = removed.toSet();
    setState(() {
      items = items
          .where((s) => !(s is Map && removedSet.contains(s["Id"].toString())))
          .toList();
      _songSelect.clear();
    });

    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(
          removed.length == 1
              ? 'Removed 1 song from the app'
              : 'Removed ${removed.length} songs from the app',
        ),
      ),
    );
  }

  Future<void> _bulkDownloadSelectedSongs() async {
    final selected = _selectedSongs;
    if (selected.isEmpty) return;

    setState(() => _songSelect.busy = true);

    for (final song in selected) {
      try {
        await DownloadManager.instance.downloadSong(song);
      } catch (e) {
        debugPrint(e.toString());
      }
    }

    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    _exitSongSelection();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          '${selected.length} song${selected.length == 1 ? '' : 's'} downloaded',
        ),
      ),
    );
  }

  void _bulkAddSelectedSongsToPlaylist() {
    final selected = _selectedSongs;
    if (selected.isEmpty) return;

    showPlaylistPickerSheetMulti(context, selected);
    _exitSongSelection();
  }

  // ---------------------------------------------------------------------
  // Header (identical structure to TagItemsScreen)
  // ---------------------------------------------------------------------

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

  Widget _buildPortraitHeader() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        children: [
          Expanded(
            child: SortChips(
              selected: selectedSort,
              options: _sortOptions,
              onSelected: _changeSort,
            ),
          ),

          const SizedBox(width: 8),

          SizedBox(
            width: 150,
            height: 36,
            child: _buildSearchField(),
          ),
        ],
      ),
    );
  }

  Widget _buildLandscapeHeader() {
    final options = _sortOptions;
    final sortLabel = options.firstWhere(
      (s) => s["value"] == selectedSort,
      orElse: () => options.first,
    )["label"]!;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        children: [
          SelectorDropdown<String>(
            label: sortLabel,
            leadingIcon: Icons.sort_rounded,
            selectedValue: selectedSort,
            options: options
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

  // ---------------------------------------------------------------------
  // Grids
  // ---------------------------------------------------------------------

  String get _emptyTitle =>
      search.isNotEmpty ? "No results found" : "No favorite $_emptyNoun";

  String get _emptySubtitle => search.isNotEmpty
      ? "Try a different title or check your spelling."
      : "Tap the heart on something to save it here.";

  Widget _loadingGrid(SliverGridDelegate delegate) {
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      sliver: SliverGrid(
        gridDelegate: delegate,
        delegate: SliverChildBuilderDelegate(
          (_, __) => Container(
            decoration: BoxDecoration(
              color: const Color(0xFF242424),
              borderRadius: BorderRadius.circular(14),
            ),
          ),
          childCount: 12,
        ),
      ),
    );
  }

  Widget _emptySliver() {
    return SliverFillRemaining(
      hasScrollBody: false,
      child: Center(
        child: EmptyState(
          icon: _emptyIcon,
          title: _emptyTitle,
          subtitle: _emptySubtitle,
        ),
      ),
    );
  }

  /// Square cover + 48px label block (title + subtitle) — the same
  /// sizing AlbumGrid and the Music tab use for albums/playlists.
  Widget _squareCardGrid(
    List<dynamic> visible,
    Widget Function(dynamic item, double cellWidth) builder,
  ) {
    const crossAxisSpacing = 12.0;
    const labelHeight = 48.0;

    final crossAxisCount =
        Responsive.gridColumnsForType(context, GridContentType.album);
    final cellWidth = (Responsive.gridContentWidth(context) -
            crossAxisSpacing * (crossAxisCount - 1)) /
        crossAxisCount;

    final delegate = SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: crossAxisCount,
      mainAxisExtent: cellWidth + labelHeight,
      crossAxisSpacing: crossAxisSpacing,
      mainAxisSpacing: 12,
    );

    if (loading) return _loadingGrid(delegate);
    if (visible.isEmpty) return _emptySliver();

    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      sliver: SliverGrid(
        gridDelegate: delegate,
        delegate: SliverChildBuilderDelegate(
          (context, index) => builder(visible[index], cellWidth),
          childCount: visible.length,
        ),
      ),
    );
  }

  Widget _artistGrid(List<dynamic> visible) {
    // Same 0.8 cell ratio + spacing the Music tab's Artists grid uses.
    final delegate = SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount:
          Responsive.gridColumnsForType(context, GridContentType.album),
      childAspectRatio: .8,
      crossAxisSpacing: 12,
      mainAxisSpacing: 20,
    );

    if (loading) return _loadingGrid(delegate);
    if (visible.isEmpty) return _emptySliver();

    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      sliver: SliverGrid(
        gridDelegate: delegate,
        delegate: SliverChildBuilderDelegate(
          (context, index) {
            final artist = visible[index] as Map;
            return ArtistCard(
              artist: artist,
              onTap: () => _openMusicDetail(artist),
            );
          },
          childCount: visible.length,
        ),
      ),
    );
  }

  Widget _peopleGrid(List<dynamic> visible) {
    const crossAxisSpacing = 12.0;
    const mainAxisSpacing = 14.0;

    final crossAxisCount =
        Responsive.gridColumnsForType(context, GridContentType.poster);
    final cellWidth = (Responsive.gridContentWidth(context) -
            crossAxisSpacing * (crossAxisCount - 1)) /
        crossAxisCount;

    // Portrait image + 10 gap + name (max 2 lines) + small rounding
    // buffer — same allowance CastRow makes for its own cards.
    final delegate = SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: crossAxisCount,
      mainAxisExtent: CastPersonCard.imageHeightFor(cellWidth) +
          10 +
          CastPersonCard.nameBlockHeight(context, cellWidth) +
          6,
      crossAxisSpacing: crossAxisSpacing,
      mainAxisSpacing: mainAxisSpacing,
    );

    if (loading) return _loadingGrid(delegate);
    if (visible.isEmpty) return _emptySliver();

    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      sliver: SliverGrid(
        gridDelegate: delegate,
        delegate: SliverChildBuilderDelegate(
          (context, index) {
            final person = visible[index];
            return CastPersonCard(
              person: person,
              showRole: false,
              width: cellWidth,
              onTap: () => _open(
                CastCrewDetailScreen(
                  personId: person["Id"],
                  initialItem: Map<String, dynamic>.from(person),
                ),
              ),
            );
          },
          childCount: visible.length,
        ),
      ),
    );
  }

  Widget _songList(List<dynamic> visible) {
    if (loading) {
      return SliverList(
        delegate: SliverChildBuilderDelegate(
          (_, __) => Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 3),
            child: Container(
              height: 65,
              decoration: BoxDecoration(
                color: const Color(0xFF242424),
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
          childCount: 10,
        ),
      );
    }

    if (visible.isEmpty) return _emptySliver();

    // Same rows, same padding as the Songs tab (10px sides).
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      sliver: SliverList(
        delegate: SliverChildBuilderDelegate(
          (context, index) {
            final song = visible[index] as Map;
            final id = song["Id"].toString();

            return ValueListenableBuilder<MediaItem?>(
              valueListenable: PlayerManager.instance.currentItemNotifier,
              builder: (context, currentItem, _) {
                return SongRow(
                  song: song,
                  playing: currentItem != null && currentItem.id == song["Id"],
                  showDownloadStatus: true,
                  onRemovedFromApp: () => setState(() {
                    items = items
                        .where((s) => !(s is Map && s["Id"].toString() == id))
                        .toList();
                  }),
                  selectionMode: _songSelect.active,
                  selected: _songSelect.isSelected(id),
                  onLongPress: _songSelect.active
                      ? null
                      : () => _enterSongSelection(id),
                  onTap: _songSelect.active
                      ? () => _toggleSongSelection(id)
                      : () => _playSongs(visible, startIndex: index),
                );
              },
            );
          },
          childCount: visible.length,
        ),
      ),
    );
  }

  Widget _buildBodySliver(List<dynamic> visible) {
    switch (widget.kind) {
      case FavoriteKind.movies:
      case FavoriteKind.shows:
        return MovieGrid(
          loading: loading,
          items: visible,
          onItemTap: _openMovieOrShow,
          emptyIcon: _emptyIcon,
          emptyTitle: _emptyTitle,
          emptySubtitle: _emptySubtitle,
        );

      case FavoriteKind.collections:
        return MovieGrid(
          loading: loading,
          items: visible,
          onItemTap: _openCollection,
          emptyIcon: _emptyIcon,
          emptyTitle: _emptyTitle,
          emptySubtitle: _emptySubtitle,
        );

      case FavoriteKind.albums:
        return AlbumGrid(
          loading: loading,
          items: visible,
          onItemTap: _openMusicDetail,
          emptyIcon: _emptyIcon,
          emptyTitle: _emptyTitle,
          emptySubtitle: _emptySubtitle,
        );

      case FavoriteKind.playlists:
        return _squareCardGrid(
          visible,
          (item, cellWidth) => PlaylistCard(
            playlist: item as Map,
            onTap: () => _openMusicDetail(item),
          ),
        );

      case FavoriteKind.artists:
        return _artistGrid(visible);

      case FavoriteKind.people:
        return _peopleGrid(visible);

      case FavoriteKind.songs:
        return _songList(visible);
    }
  }

  // ---------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final landscape = Responsive.isLandscape(context);
    final visible = _visibleItems;

    return Scaffold(
      backgroundColor: _bg,
      // Tapping anywhere outside the search field dismisses its focus.
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => FocusScope.of(context).unfocus(),
        child: SafeArea(
          bottom: false,
          // Back button + label fixed above the pinned sort/search row;
          // only the grid scrolls. The label slides away on scroll down
          // and returns on scroll up (see collapsing_screen_label.dart).
          child: LabelCollapseScope(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: kCollapsedLabelTopGap),

                CollapsibleLabel(
                  bottomPadding: 10,
                  // While songs are being multi-selected, the selection
                  // bar takes the label's slot and must stay visible.
                  enabled: !_songSelect.active,
                  child: _songSelect.active
                      ? SongSelectionBar(
                          count: _songSelect.count,
                          busy: _songSelect.busy,
                          onClose: _exitSongSelection,
                          onPlaySelected: _playSelectedSongs,
                          onAddToQueue: _bulkAddSelectedSongsToQueue,
                          // An on-device song is already on the phone
                          // (nothing to download), so as soon as any
                          // selected row is one, Download is dropped
                          // and Remove appears instead.
                          onDownload: songsContainLocal(_selectedSongs)
                              ? null
                              : _bulkDownloadSelectedSongs,
                          onAddToPlaylist: _bulkAddSelectedSongsToPlaylist,
                          onDelete: songsContainLocal(_selectedSongs)
                              ? _bulkRemoveSelectedLocalSongs
                              : null,
                          deleteLabel: "Remove from App",
                        )
                      : Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: Row(
                            children: [
                              IconButton(
                                onPressed: () =>
                                    Navigator.of(context).maybePop(),
                                icon: const Icon(
                                  Icons.arrow_back,
                                  color: Colors.white,
                                ),
                              ),

                              const SizedBox(width: 4),

                              Expanded(
                                child: Text(
                                  _label,
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

                if (landscape)
                  _buildLandscapeHeader()
                else
                  _buildPortraitHeader(),

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
                        physics: const AlwaysScrollableScrollPhysics(),
                        // Build rows (and so start their artwork) a
                        // screen-height ahead of the viewport so art is
                        // ready before a row scrolls into view instead
                        // of arriving after its text.
                        cacheExtent: MediaQuery.sizeOf(context).height,
                        slivers: [
                          _buildBodySliver(visible),

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
