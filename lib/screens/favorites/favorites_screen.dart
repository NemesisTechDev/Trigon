import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../utils/responsive.dart';
import '../../services/favorite_service.dart';
import '../../services/local_music_service.dart';
import '../../widgets/music/song_selection_actions.dart';
import '../../services/jellyfin_services/media_service.dart';
import '../../services/jellyfin_services/music_service.dart';
import '../../services/jellyfin_services/storage_service.dart';
import '../../player/playback_service.dart';
import '../../player/player_manager.dart';
import '../../player/services/playback_queue.dart';
import '../../player/screens/audio_player_screen.dart';
import '../../player/models/media_item.dart';
import '../../widgets/live_tv/live_channel_card.dart';
import '../../widgets/music/album_card.dart';
import '../../widgets/music/artist_card.dart';
import '../../widgets/music/playlist_card.dart';
import '../../widgets/music/song_row.dart';
import '../cast_crew/cast_crew_detail_screen.dart';
import '../collection_details/collection_details_screen.dart';
import '../live_tv/all_channels_screen.dart';
import '../live_tv/live_tv_detail_screen.dart';
import '../movie_details/movie_details_screen.dart';
import '../movie_details/widgets/cast_row.dart';
import '../movies/widgets/movie_card.dart';
import '../music/music_detail_screen.dart';
import '../../services/download_manager.dart';
import '../../widgets/music/song_selection_bar.dart';
import '../../widgets/music/song_multi_select.dart';
import '../../widgets/music/playlist_picker_sheet.dart';
import '../../widgets/common/empty_state.dart';
import '../../widgets/common/see_all_controls.dart';
import '../../widgets/common/resistive_refresh.dart';
import '../../widgets/common/collapsing_screen_label.dart';
import '../../utils/bottom_clearance.dart';
import 'favorite_items_screen.dart';

const _gold = Color(0xffD4AF37);
const _bg = Color(0xff161616);

class FavoritesScreen extends StatefulWidget {
  const FavoritesScreen({super.key});

  @override
  State<FavoritesScreen> createState() => _FavoritesScreenState();
}

class _FavoritesScreenState extends State<FavoritesScreen> {
  String? error;

  /// True once every one of the 6 favorite-type fetches in [_load] has
  /// settled (succeeded or failed) — used to hold off the empty-state
  /// message until there's been a real chance for every section to
  /// report in, since sections now arrive independently instead of all
  /// at once. See [_isEmpty] usage in [build].
  bool _allSettled = false;

  // True until the first section header of the current build has been
  // laid out — that one skips its top padding so "Movies" (or whichever
  // section is first) sits right under the app bar's own spacing.
  bool _firstHeaderPending = true;

  /// Incremented at the start of every [_load]. A load only applies its
  /// results if it's still the newest one, so a slow, older load can
  /// never overwrite (or prematurely "settle") a newer one — which can
  /// now happen since a favorite toggled elsewhere triggers a reload
  /// while an earlier load may still be in flight.
  int _loadGeneration = 0;

  Timer? _changeDebounce;

  /// One "loaded" flag per fetch group (movies/shows/collections share
  /// a single fetch, so they share a flag). The page always lays its
  /// sections out in the same fixed order below — these flags decide
  /// whether a given slot shows a skeleton placeholder row or its real
  /// content, instead of the section only appearing once data exists.
  /// That fixed ordering is what stops sections from jumping around as
  /// each fetch resolves at its own pace: previously a slower section
  /// (say, Movies) would insert itself above a faster one (say, Albums)
  /// the moment it arrived, shoving everything below it down the page
  /// mid-scroll. Now every slot is always present from the first frame,
  /// in the same position, and just swaps its own content in place.
  bool _moviesGroupLoaded = false;
  bool _albumsLoaded = false;
  bool _artistsLoaded = false;
  bool _playlistsLoaded = false;
  bool _songsLoaded = false;
  bool _peopleLoaded = false;
  bool _channelsLoaded = false;

  List<dynamic> movies = [];
  List<dynamic> shows = [];
  List<dynamic> collections = [];
  List<dynamic> albums = [];
  List<dynamic> artists = [];
  List<dynamic> playlists = [];
  List<dynamic> songs = [];
  List<dynamic> people = [];
  List<dynamic> channels = [];

  /// id -> favorited-at (ms since epoch), read once per [_load] from
  /// FavoriteService. Jellyfin itself has no "date favorited" field, so
  /// this local record — written by MediaService.toggleFavorite and
  /// FavoriteService.toggle whenever this app favorites something — is
  /// the only source for "most recently favorited" ordering. An id
  /// missing from this map was favorited before this feature existed or
  /// from outside the app; [_sortByFavoritedAt] pushes those to the end
  /// of their section instead of guessing a recency for them.
  Map<String, int> _favoritedAt = {};

  /// Sorts a favorites section newest-favorited-first using
  /// [_favoritedAt], falling back to each item's existing (alphabetical,
  /// from the server's SortBy=SortName) position when neither side has a
  /// recorded timestamp, and pushing timestamp-less items after ones
  /// with a known timestamp. Mirrors "recently added" rows elsewhere in
  /// the app, just ordered by favorite time instead of add time, and
  /// with the latest item leftmost the same way those rows put the
  /// newest item leftmost.
  List<dynamic> _sortByFavoritedAt(List<dynamic> items) {
    final indexed = items.asMap().entries.toList();
    indexed.sort((a, b) {
      final aTs = _addedAtOf(a.value);
      final bTs = _addedAtOf(b.value);
      if (aTs == null && bTs == null) return a.key.compareTo(b.key);
      if (aTs == null) return 1;
      if (bTs == null) return -1;
      final byTime = bTs.compareTo(aTs);
      return byTime != 0 ? byTime : a.key.compareTo(b.key);
    });
    return indexed.map((e) => e.value).toList();
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

  // Hold-to-multi-select for the Songs section.
  final SongMultiSelect _songSelect = SongMultiSelect();

  void _enterSongSelection(String id) {
    setState(() => _songSelect.enter(id));
  }

  void _toggleSongSelection(String id) {
    setState(() => _songSelect.toggle(id));
  }

  void _exitSongSelection() {
    setState(() => _songSelect.clear());
  }

  List<Map<String, dynamic>> get _selectedSongs => songs
      .whereType<Map>()
      .where((s) => _songSelect.selectedIds.contains(s["Id"].toString()))
      .map((s) => Map<String, dynamic>.from(s))
      .toList();

  Future<void> _bulkAddSelectedSongsToQueue() async {
    final selected = _selectedSongs;
    if (selected.isEmpty) return;

    final messenger = ScaffoldMessenger.maybeOf(context);

    // Same reasoning as the single-song "Add to Queue" action — nothing
    // playing means there's no "current song" for these to queue up
    // after, so tell the user to start playback first instead of
    // silently starting it on their behalf.
    if (PlayerManager.instance.currentItem == null) {
      _exitSongSelection();
      messenger?.showSnackBar(
        const SnackBar(
          content: Text("Play something first to add songs to the queue"),
        ),
      );
      return;
    }

    // Same on-device-favorites fix as _playSongs/_mediaItemsFromFavoriteSongs
    // above — `selected` is drawn from this same mixed local/server list.
    final items = _mediaItemsFromFavoriteSongs(selected);
    for (final mediaItem in items) {
      PlaybackQueue.instance.addToQueue(mediaItem);
    }

    _exitSongSelection();
    messenger?.showSnackBar(
      SnackBar(
        content: Text(
          '${items.length} song${items.length == 1 ? '' : 's'} added to queue',
        ),
      ),
    );
  }

  /// "Play selected": a brand-new queue of exactly the selected songs,
  /// in list order. `selected` is drawn from the same interleaved
  /// server/on-device list as everything else here, so the queue is
  /// built per song (see mediaItemsFromMixedSongs).
  Future<void> _playSelectedSongs() async {
    final selected = _selectedSongs;
    if (selected.isEmpty) return;

    final queue = mediaItemsFromMixedSongs(selected);

    _exitSongSelection();
    await playSelectionAsQueue(context, queue);
  }

  /// Bulk "Remove from App" for the on-device rows among the selection
  /// (any server rows selected alongside them are left alone — a
  /// server favorite is removed by un-favoriting it). Drops the removed
  /// rows from the list immediately rather than waiting on a reload.
  Future<void> _bulkRemoveSelectedLocalSongs() async {
    final removed =
        await confirmRemoveLocalSongsFromApp(context, _selectedSongs);
    if (removed == null || !mounted) return;

    final removedSet = removed.toSet();
    setState(() {
      songs = songs
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

  @override
  void initState() {
    super.initState();
    _load();

    // This screen stays mounted underneath other screens (a tab in the
    // main nav's IndexedStack, or a route under the full-screen audio
    // player), so its initState load goes stale the moment anything is
    // favorited/unfavorited elsewhere — e.g. the heart on the audio
    // player. Reload whenever that happens.
    FavoriteService.changes.addListener(_onFavoritesChanged);
  }

  @override
  void dispose() {
    FavoriteService.changes.removeListener(_onFavoritesChanged);
    _changeDebounce?.cancel();
    super.dispose();
  }

  /// Short debounce so rapid toggles (or a toggle that fires both a
  /// server and a local notification) collapse into a single reload.
  void _onFavoritesChanged() {
    _changeDebounce?.cancel();
    _changeDebounce = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      _load(silent: true);
    });
  }

  /// Runs one favorite-type fetch in isolation — a failure here (e.g. a
  /// server with Live TV or Persons unsupported/misconfigured) used to
  /// take the whole page down via Future.wait's fail-fast behavior, even
  /// though the other five sections had loaded fine. Mirrors the same
  /// per-section safety wrapper SearchScreen already uses for exactly
  /// this reason.
  Future<List<dynamic>> _safe(Future<List<dynamic>> future) async {
    try {
      return await future;
    } catch (e) {
      debugPrint(e.toString());
      return [];
    }
  }

  /// [silent] reloads in the background without resetting the sections
  /// back to skeletons: the current lists stay on screen and each
  /// section swaps in its fresh data as it arrives. Used when a
  /// favorite changed elsewhere in the app (see
  /// [_onFavoritesChanged]); pull-to-refresh and the first load use the
  /// normal (non-silent) path.
  Future<void> _load({bool silent = false}) async {
    final generation = ++_loadGeneration;

    if (!silent) {
      _songSelect.clear();
      setState(() {
        error = null;
        _allSettled = false;
        _moviesGroupLoaded = false;
        _albumsLoaded = false;
        _artistsLoaded = false;
        _playlistsLoaded = false;
        _songsLoaded = false;
        _peopleLoaded = false;
        _channelsLoaded = false;
      });
    }

    // Read once, up front — a local SharedPreferences read, so it's
    // effectively instant next to the seven network fetches below — so
    // every section's sort below sees the same snapshot instead of each
    // one re-reading (and each potentially seeing a different map if a
    // favorite is toggled elsewhere mid-load).
    //
    // LocalMusicService's map is merged in here too: on-device songs
    // have no Jellyfin id to key a server-synced timestamp on, so they
    // keep their own local-only map (never pushed to
    // DisplayPreferences), but merging it into the same lookup lets
    // _sortByFavoritedAt place them newest-first right alongside every
    // server-favorited item without needing to know they came from a
    // different source at all.
    final favoritedAt = {
      ...await FavoriteService.getFavoritedTimestamps(),
      ...LocalMusicService.instance.favoritedAtTimestamps,
    };

    // A newer load started (or the screen went away) while the
    // timestamps were being read — that one owns the page now.
    if (!mounted || generation != _loadGeneration) return;
    _favoritedAt = favoritedAt;

    // The seven favorite-type fetches used to all sit behind one
    // Future.wait, so every section — including the fast, single-query
    // ones like Movies/Shows/Collections — waited on whichever was
    // slowest (Channels, which needs two sequential requests: local
    // favorite ids, then the full channel list). Now each section
    // updates the page the moment its own fetch resolves, so the fast
    // sections appear immediately and the slow one just fills in after
    // — in its own fixed slot (see the flags above), not by jumping
    // ahead of slower sections above it.
    var pending = 7;

    void section<T>(
      Future<T> future,
      void Function(T value) apply,
      void Function() markLoaded,
    ) {
      future.then((value) {
        if (!mounted || generation != _loadGeneration) return;
        setState(() {
          apply(value);
          markLoaded();
        });
      }).whenComplete(() {
        pending--;
        if (pending == 0 && mounted && generation == _loadGeneration) {
          setState(() => _allSettled = true);
        }
      });
    }

    // Movie + Series + BoxSet all come back from the same IsFavorite
    // query and get split here — one round trip instead of three.
    section<List<dynamic>>(
      _safe(MediaService.getFavoriteItems(
        includeItemTypes: "Movie,Series,BoxSet",
      )),
      (libraryItems) {
        movies = _sortByFavoritedAt(
          libraryItems.where((i) => i["Type"] == "Movie").toList(),
        );
        shows = _sortByFavoritedAt(
          libraryItems.where((i) => i["Type"] == "Series").toList(),
        );
        collections = _sortByFavoritedAt(
          libraryItems.where((i) => i["Type"] == "BoxSet").toList(),
        );
      },
      () => _moviesGroupLoaded = true,
    );

    section<List<dynamic>>(
      _safe(MediaService.getFavoriteItems(includeItemTypes: "MusicAlbum")),
      (value) => albums = _sortByFavoritedAt(value),
      () => _albumsLoaded = true,
    );

    section<List<dynamic>>(
      _safe(MusicService.getFavoriteArtists()),
      (value) => artists = _sortByFavoritedAt(value),
      () => _artistsLoaded = true,
    );

    section<List<dynamic>>(
      _safe(MediaService.getFavoriteItems(includeItemTypes: "Playlist")),
      (value) => playlists = _sortByFavoritedAt(value),
      () => _playlistsLoaded = true,
    );

    // Local ("On This Device") favorited songs are folded in here too.
    // They come from a local MediaStore scan rather than a network
    // call, so pulling them in alongside the server fetch costs
    // nothing extra — the section still only appears once both settle,
    // same as before, and the merged list sorts through the same
    // _favoritedAt map (see above) so local and server favorites
    // interleave correctly by the moment each was actually favorited.
    section<List<dynamic>>(
      _safe(MediaService.getFavoriteSongs()).then((serverSongs) async {
        final localSongs = await _safe(LocalMusicService.instance.getFavoritedSongs());
        return [...serverSongs, ...localSongs];
      }),
      (value) => songs = _sortByFavoritedAt(value),
      () => _songsLoaded = true,
    );

    section<List<dynamic>>(
      _safe(MediaService.getFavoritePeople()),
      (value) => people = _sortByFavoritedAt(value),
      () => _peopleLoaded = true,
    );

    section<List<dynamic>>(
      _safe(_loadFavoriteChannels()),
      (value) => channels = _sortByFavoritedAt(value),
      () => _channelsLoaded = true,
    );
  }

  /// TV channel favorites are tracked locally (see FavoriteService), not
  /// through Jellyfin's IsFavorite on the item itself — same split the
  /// rest of the Live TV screens already follow — so this resolves the
  /// saved ids against the live channel list to get displayable data.
  Future<List<dynamic>> _loadFavoriteChannels() async {
    final ids = (await FavoriteService.getFavorites()).toSet();
    if (ids.isEmpty) return [];

    final all = await MediaService.getLiveTvChannels();
    return all.where((c) => ids.contains(c["Id"])).toList();
  }

  bool get _isEmpty =>
      movies.isEmpty &&
      shows.isEmpty &&
      collections.isEmpty &&
      albums.isEmpty &&
      artists.isEmpty &&
      playlists.isEmpty &&
      songs.isEmpty &&
      people.isEmpty &&
      channels.isEmpty;

  @override
  Widget build(BuildContext context) {
    // LabelCollapseScope: the "Favorites" app bar slides away on scroll
    // down and returns on scroll up (see collapsing_screen_label.dart).
    // While songs are being multi-selected the bar holds the selection
    // actions, so it's kept fully shown (enabled: false) until the
    // selection ends.
    return LabelCollapseScope(
      child: Scaffold(
      backgroundColor: _bg,
      // primary: false — CollapsibleAppBar supplies the status-bar inset
      // itself so the bar can collapse down to just that inset.
      appBar: CollapsibleAppBar(
        enabled: !_songSelect.active,
        child: AppBar(
          primary: false,
          // 48 (instead of the default 56) leaves ~10 of space under
          // the title, matching the 10 label-to-first-row gap on the
          // Movies/Music screens. Left at the default while the song
          // selection bar occupies the title slot.
          toolbarHeight: _songSelect.active ? null : 48,
          backgroundColor: _bg,
          automaticallyImplyLeading: !_songSelect.active,
          titleSpacing: _songSelect.active ? 0 : null,
          title: _songSelect.active
              ? SongSelectionBar(
                  count: _songSelect.count,
                  busy: _songSelect.busy,
                  onClose: _exitSongSelection,
                  onPlaySelected: _playSelectedSongs,
                  onAddToQueue: _bulkAddSelectedSongsToQueue,
                  // This list interleaves server and on-device
                  // favorites. An on-device song is already on the
                  // phone (nothing to download), so as soon as any
                  // selected row is one, Download is dropped and
                  // Remove appears instead.
                  onDownload: songsContainLocal(_selectedSongs)
                      ? null
                      : _bulkDownloadSelectedSongs,
                  onAddToPlaylist: _bulkAddSelectedSongsToPlaylist,
                  onDelete: songsContainLocal(_selectedSongs)
                      ? _bulkRemoveSelectedLocalSongs
                      : null,
                  deleteLabel: "Remove from App",
                )
              : const Text(
                  "Favorites",
                  style: TextStyle(color: Colors.white),
                ),
        ),
      ),
      body: ResistiveRefresh(
        onRefresh: _load,
        color: _gold,
        backgroundColor: const Color(0xff232323),
        child: error != null
            ? _buildError()
            : (_isEmpty && _allSettled)
                ? _buildEmptyState()
                : _buildContent(),
      ),
      ),
    );
  }

  Widget _buildError() {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        SizedBox(
          height: Responsive.emptyStateHeight(context, fraction: 0.6),
          child: Center(
            child: Text(
              error!,
              style: const TextStyle(color: Colors.white54),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildEmptyState() {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        SizedBox(
          height: Responsive.emptyStateHeight(context, fraction: 0.65),
          child: const Center(
            child: EmptyState(
              icon: Icons.favorite_border,
              title: "Nothing favorited yet",
              subtitle: "Tap the heart on any movie, show, collection, "
                  "album, artist, playlist, cast/crew member, or channel "
                  "to save it here.",
            ),
          ),
        ),
      ],
    );
  }

  /// Every slot below is always present, in this same fixed order, on
  /// every build — whether or not its data has arrived yet. A slot
  /// whose group hasn't loaded shows a skeleton placeholder row; once
  /// loaded, it either shows its real content or collapses to nothing
  /// if that particular list is empty. This is what keeps sections from
  /// reordering/jumping as fetches resolve at different speeds — the
  /// vertical position of "Songs", say, never changes, so nothing above
  /// it can suddenly shove it around mid-scroll.
  Widget _buildContent() {
    return BottomClearanceBuilder(
      builder: (context, bottomClearance) {
        // The first section header on screen sits flush under the app
        // bar's own bottom space (see _sectionHeader); reset per build.
        _firstHeaderPending = true;
        return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: EdgeInsets.only(
        top: 0,
        bottom: 32 + MediaQuery.paddingOf(context).bottom + bottomClearance,
      ),
      children: [
        _sectionSlot(
          loaded: _moviesGroupLoaded,
          isEmpty: movies.isEmpty,
          skeleton: () => _skeletonPosterRow("Movies"),
          content: () => _posterSection(
            title: "Movies",
            items: movies,
            onSeeAll: () => _seeAll(FavoriteKind.movies),
            onTap: (item) => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => MovieDetailsScreen(
                  itemId: item["Id"],
                  initialItem: Map<String, dynamic>.from(item),
                ),
              ),
            ),
          ),
        ),
        _sectionSlot(
          loaded: _moviesGroupLoaded,
          isEmpty: shows.isEmpty,
          skeleton: () => _skeletonPosterRow("TV Shows"),
          content: () => _posterSection(
            title: "TV Shows",
            items: shows,
            onSeeAll: () => _seeAll(FavoriteKind.shows),
            onTap: (item) => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => MovieDetailsScreen(
                  itemId: item["Id"],
                  initialItem: Map<String, dynamic>.from(item),
                ),
              ),
            ),
          ),
        ),
        _sectionSlot(
          loaded: _moviesGroupLoaded,
          isEmpty: collections.isEmpty,
          skeleton: () => _skeletonPosterRow("Collections"),
          content: () => _posterSection(
            title: "Collections",
            items: collections,
            onSeeAll: () => _seeAll(FavoriteKind.collections),
            onTap: (item) => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => CollectionDetailsScreen(
                  collectionId: item["Id"],
                  initialItem: Map<String, dynamic>.from(item),
                ),
              ),
            ),
          ),
        ),
        _sectionSlot(
          loaded: _albumsLoaded,
          isEmpty: albums.isEmpty,
          skeleton: () => _skeletonPosterRow(
            "Albums",
            height: 174,
            icon: Icons.album_outlined,
          ),
          content: _albumSection,
        ),
        _sectionSlot(
          loaded: _artistsLoaded,
          isEmpty: artists.isEmpty,
          skeleton: () => _skeletonPosterRow(
            "Artists",
            height: 166,
            icon: Icons.person_outline,
          ),
          content: _artistSection,
        ),
        _sectionSlot(
          loaded: _playlistsLoaded,
          isEmpty: playlists.isEmpty,
          skeleton: () => _skeletonPosterRow(
            "Playlists",
            height: 174,
            icon: Icons.queue_music,
          ),
          content: _playlistSection,
        ),
        _sectionSlot(
          loaded: _peopleLoaded,
          isEmpty: people.isEmpty,
          skeleton: () => _skeletonPosterRow(
            "Cast & Crew",
            icon: Icons.person_outline,
          ),
          content: _peopleSection,
        ),
        _sectionSlot(
          loaded: _channelsLoaded,
          isEmpty: channels.isEmpty,
          skeleton: () => _skeletonPosterRow(
            "TV Channels",
            width: 160,
            height: 230,
            icon: Icons.live_tv_outlined,
          ),
          content: _channelSection,
        ),
        // Unlike the other rows above (a handful of cards), a favorited
        // song library can realistically run into the hundreds — so
        // instead of one ever-growing vertical list (which used to make
        // this page arbitrarily long), songs are chunked into columns of
        // up to _songsPerColumn rows and laid out in a horizontally
        // paged row, same "swipe for more" interaction as the rows
        // above it just turned sideways. This keeps the section's
        // height fixed regardless of how many songs are favorited.
        _sectionSlot(
          loaded: _songsLoaded,
          isEmpty: songs.isEmpty,
          skeleton: _skeletonSongRow,
          content: _songSection,
        ),
      ],
        );
      },
    );
  }

  /// Picks between a skeleton placeholder and real content for one
  /// fixed section slot, without ever changing whether the slot itself
  /// is present in the list — only its content swaps in place.
  Widget _sectionSlot({
    required bool loaded,
    required bool isEmpty,
    required Widget Function() skeleton,
    required Widget Function() content,
  }) {
    if (!loaded) return skeleton();
    if (isEmpty) return const SizedBox.shrink();
    return content();
  }

  /// Opens the full grid for one favorites section (the gold "See all"
  /// on each section header).
  void _seeAll(FavoriteKind kind) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => FavoriteItemsScreen(kind: kind)),
    );
  }

  bool _openingChannels = false;

  /// TV channels' "See all" opens the same favorite-channels page the
  /// Live TV tab's Favorites chip opens (AllChannelsScreen, titled
  /// "Favorites"). That page also shows each channel's now/next program,
  /// so the guide data Live TV last cached is handed over too (instant;
  /// no network) — without it the page still works, just without the
  /// program info.
  Future<void> _seeAllChannels() async {
    if (_openingChannels) return;
    _openingChannels = true;

    try {
      var programs = <String, dynamic>{};

      try {
        final cached = await StorageService.getLiveTvCache();
        if (cached != null) {
          final decoded = jsonDecode(cached) as Map<String, dynamic>;
          final all = decoded["programs"] as Map<String, dynamic>? ?? {};
          programs = {
            for (final channel in channels)
              if (all[channel["Id"]?.toString()] != null)
                channel["Id"].toString(): all[channel["Id"].toString()],
          };
        }
      } catch (e) {
        debugPrint(e.toString());
      }

      if (!mounted) return;

      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => AllChannelsScreen(
            title: "Favorites",
            channels: channels,
            programs: programs,
          ),
        ),
      );
    } finally {
      _openingChannels = false;
    }
  }

  /// Rows (everything except Songs) show at most this many items. Once a
  /// row reaches it, a gold chevron tile follows the last item and opens
  /// the same page as the section's "See all".
  static const int _rowCap = 20;

  bool _hasSeeAllTile(int total) => total >= _rowCap;

  int _rowItemCount(int total) =>
      (total < _rowCap ? total : _rowCap) + (_hasSeeAllTile(total) ? 1 : 0);

  bool _isSeeAllTileIndex(int index, int total) =>
      _hasSeeAllTile(total) && index == _rowCap;

  /// The "View all" item at the end of a full row: gold chevron disc
  /// with a caption beneath it, no card behind it (see [ViewAllRowTile]).
  Widget _seeAllTile({required double height, required VoidCallback onTap}) {
    return ViewAllRowTile(height: height, onTap: onTap);
  }

  Widget _sectionHeader(String title, int? count, {VoidCallback? onSeeAll}) {
    final topPadding = _firstHeaderPending ? 0.0 : 12.0;
    _firstHeaderPending = false;

    return Padding(
      padding: EdgeInsets.fromLTRB(20, topPadding, 20, 12),
      child: Row(
        children: [
          Text(
            title,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (count != null) ...[
            const SizedBox(width: 8),
            Text(
              "$count",
              style: const TextStyle(
                color: Colors.white38,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
          if (onSeeAll != null) ...[
            const Spacer(),
            // Gold chevron disc on the right edge of the label row
            // (replaces the old "See all" text).
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: SeeAllChevronButton(onTap: onSeeAll),
            ),
          ],
        ],
      ),
    );
  }

  /// Skeleton row for the poster/card-style sections (Movies, TV Shows,
  /// Collections, Albums, Artists, Cast & Crew, TV Channels) — same
  /// dark placeholder fill + muted icon the real cards themselves show
  /// while their artwork is still lazily loading in (see MovieCard's
  /// `placeholder:`), just applied at the section level so the whole
  /// row reads as "loading" instead of popping into existence once its
  /// fetch resolves.
  Widget _skeletonPosterRow(
    String title, {
    double width = 130,
    double height = 195,
    IconData icon = Icons.image_outlined,
    int count = 5,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeader(title, null),
        SizedBox(
          height: height,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            physics: const NeverScrollableScrollPhysics(),
            itemCount: count,
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (_, __) => Container(
              width: width,
              height: height,
              decoration: BoxDecoration(
                color: const Color(0xff252525),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Center(
                child: Icon(icon, color: Colors.white24, size: 32),
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
      ],
    );
  }

  /// Skeleton for the Songs row-list-of-columns layout — same idea as
  /// [_skeletonPosterRow] but shaped like a couple of SongRow columns
  /// (square art placeholder + two text bars) instead of poster cards.
  Widget _skeletonSongRow() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeader("Songs", null),
        SizedBox(
          height: _songRowHeight * 4,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            physics: const NeverScrollableScrollPhysics(),
            itemCount: 2,
            separatorBuilder: (_, __) => const SizedBox(width: 16),
            itemBuilder: (_, __) => SizedBox(
              width: 260,
              child: Column(
                children: List.generate(
                  4,
                  (_) => Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 3,
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 65,
                          height: 65,
                          decoration: BoxDecoration(
                            color: const Color(0xff252525),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Icon(
                            Icons.music_note,
                            color: Colors.white24,
                            size: 22,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Container(
                                height: 12,
                                width: 140,
                                decoration: BoxDecoration(
                                  color: const Color(0xff252525),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                              ),
                              const SizedBox(height: 8),
                              Container(
                                height: 10,
                                width: 90,
                                decoration: BoxDecoration(
                                  color: const Color(0xff232323),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
      ],
    );
  }

  /// Shared row shape for Movies/TV Shows — same 130×(2:3) MovieCard
  /// treatment the Home screen's own poster rows use.
  Widget _posterSection({
    required String title,
    required List<dynamic> items,
    required void Function(dynamic item) onTap,
    VoidCallback? onSeeAll,
  }) {
    const width = 130.0;
    const aspect = 2 / 3;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeader(title, items.length, onSeeAll: onSeeAll),
        SizedBox(
          height: width / aspect,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            itemCount: _rowItemCount(items.length),
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (context, index) {
              if (_isSeeAllTileIndex(index, items.length)) {
                return _seeAllTile(
                  height: width / aspect,
                  onTap: onSeeAll ?? () {},
                );
              }
              final item = items[index];
              return SizedBox(
                width: width,
                child: MovieCard(
                  item: item,
                  onTap: () => onTap(item),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 12),
      ],
    );
  }

  Widget _albumSection() {
    const width = 130.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeader(
          "Albums",
          albums.length,
          onSeeAll: () => _seeAll(FavoriteKind.albums),
        ),
        SizedBox(
          // width + 48 matches the Music screen's own album grid
          // (_squareCardLabelHeight in music_screen.dart) — the exact
          // allowance AlbumCard's two-line label (title + artist)
          // needs on top of its square cover, tuned to avoid both the
          // dead space a looser height leaves and the overflow a
          // tighter one causes.
          height: width + 48,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            itemCount: _rowItemCount(albums.length),
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (context, index) {
              if (_isSeeAllTileIndex(index, albums.length)) {
                return _seeAllTile(
                  height: width,
                  onTap: () => _seeAll(FavoriteKind.albums),
                );
              }
              final album = albums[index] as Map;
              return SizedBox(
                width: width,
                child: AlbumCard(
                  album: album,
                  decodeWidth: width,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => MusicDetailScreen(
                        itemId: album["Id"],
                        initialItem: Map<String, dynamic>.from(album),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 12),
      ],
    );
  }

  /// Same square PlaylistCard used in the Music screen's playlists tab
  /// — cover art + name + song count, no hold-to-select here since
  /// favorites doesn't offer playlist deletion.
  Widget _playlistSection() {
    const width = 130.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeader(
          "Playlists",
          playlists.length,
          onSeeAll: () => _seeAll(FavoriteKind.playlists),
        ),
        SizedBox(
          // Same tuned +48 label allowance as Albums above — this
          // section keeps PlaylistCard's default two-line label (name
          // + song count), so it needs the same two-line height as
          // AlbumCard, not the shorter one-line allowance used for the
          // name-only "Recommended Playlists" row on the playlist
          // detail screen.
          height: width + 48,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            itemCount: _rowItemCount(playlists.length),
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (context, index) {
              if (_isSeeAllTileIndex(index, playlists.length)) {
                return _seeAllTile(
                  height: width,
                  onTap: () => _seeAll(FavoriteKind.playlists),
                );
              }
              final playlist = playlists[index] as Map;
              return SizedBox(
                width: width,
                child: PlaylistCard(
                  playlist: playlist,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => MusicDetailScreen(
                        itemId: playlist["Id"],
                        initialItem: Map<String, dynamic>.from(playlist),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 12),
      ],
    );
  }

  Widget _artistSection() {
    const width = 130.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeader(
          "Artists",
          artists.length,
          onSeeAll: () => _seeAll(FavoriteKind.artists),
        ),
        SizedBox(
          height: width + 36,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            itemCount: _rowItemCount(artists.length),
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (context, index) {
              if (_isSeeAllTileIndex(index, artists.length)) {
                return _seeAllTile(
                  height: width,
                  onTap: () => _seeAll(FavoriteKind.artists),
                );
              }
              final artist = artists[index] as Map;
              return SizedBox(
                width: width,
                child: ArtistCard(
                  artist: artist,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => MusicDetailScreen(
                        itemId: artist["Id"],
                        initialItem: Map<String, dynamic>.from(artist),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 12),
      ],
    );
  }

  /// Same CastRow used on the detail screens, so favorited people show
  /// up as the rectangular poster-style cards rather than the circle
  /// avatars — CastRow already renders its own "Cast & Crew" header
  /// and count-free label, so the shared `_sectionHeader` (with its
  /// count badge) is skipped here to avoid a duplicate title.
  Widget _peopleSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CastRow(
          cast: people,
          showRole: false,
          onSeeAll: () => _seeAll(FavoriteKind.people),
          maxItems: _rowCap,
          onTap: (person) => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => CastCrewDetailScreen(
                personId: person["Id"],
                initialItem: Map<String, dynamic>.from(person),
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
      ],
    );
  }

  /// Same LiveChannelCard used in the Live TV screen's rows. No guide
  /// data is loaded here, so program/nextProgram are always null —
  /// LiveChannelCard already handles that gracefully (just image +
  /// name, no "LIVE" badge or progress bar).
  Widget _channelSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeader(
          "TV Channels",
          channels.length,
          onSeeAll: _seeAllChannels,
        ),
        SizedBox(
          height: 230,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            itemCount: _rowItemCount(channels.length),
            separatorBuilder: (_, __) => const SizedBox(width: 14),
            itemBuilder: (context, index) {
              if (_isSeeAllTileIndex(index, channels.length)) {
                return _seeAllTile(
                  height: 230,
                  onTap: _seeAllChannels,
                );
              }
              final channel = channels[index];
              return LiveChannelCard(
                channel: channel,
                program: null,
                nextProgram: null,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => LiveTvDetailScreen(
                      channelId: channel["Id"],
                      initialItem: Map<String, dynamic>.from(channel),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 12),
      ],
    );
  }

  /// Converts raw song maps into playable MediaItems, routing each one
  /// through the right converter individually rather than assuming the
  /// whole list is one kind or the other.
  ///
  /// ON-DEVICE FAVORITES NOT PLAYING FIX: `songs` (built above) merges
  /// server (Jellyfin) and local on-device favorites into one
  /// newest-favorited-first list, unlike the Music tab's "On This
  /// Device" view, which only ever shows one kind at a time and can get
  /// away with music_screen.dart's single whole-list `IsLocal` check.
  /// A local song's `Id` is a synthetic "local_<mediaStoreId>" string
  /// with no `Type`/`MediaType` field of its own — running it through
  /// MediaService.mediaItemFromJellyfin (as this screen used to,
  /// unconditionally, for every song) built a broken Jellyfin stream
  /// URL against that fake id instead of ever reading the song's real
  /// on-device `LocalUri`, so tapping a favorited on-device song here
  /// silently failed to play. Checking `IsLocal` per song, the same
  /// flag music_screen.dart already keys off of, is what lets the two
  /// kinds sit side by side in this one list and still each resolve to
  /// a working stream.
  static List<MediaItem> _mediaItemsFromFavoriteSongs(List songList) {
    return songList.map((song) {
      final map = Map<String, dynamic>.from(song as Map);
      return map['IsLocal'] == true
          ? LocalMusicService.mediaItemFromLocalSong(map)
          : MediaService.mediaItemFromJellyfin(map);
    }).toList();
  }

  /// Same "was something already playing" pattern used on the Music
  /// tab and album/artist/playlist detail screens — only jumps into the
  /// full player automatically on a fresh session, otherwise lets the
  /// mini player just switch tracks in place.
  Future<void> _playSongs(List songList, {int startIndex = 0}) async {
    if (songList.isEmpty) return;

    final wasAlreadyPlaying = PlayerManager.instance.currentItem != null;
    final queue = _mediaItemsFromFavoriteSongs(songList);

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

  /// Approximate rendered height of one SongRow: a 65px square cover
  /// plus the row's 3px top/bottom padding. Two-line title/artist text
  /// comfortably fits within that same 65px, so this is the tallest
  /// element and drives the row height.
  static const double _songRowHeight = 71;
  static const int _songsPerColumn = 10;
  static const int _songsPerColumnLandscape = 6;

  /// Chunks the favorited songs into columns of up to [_songsPerColumn]
  /// rows each, laid out as a horizontally-paged row (swipe sideways for
  /// the next batch) rather than one long vertical list — see the
  /// comment where this is called from [_buildContent] for why.
  Widget _songSection() {
    final isLandscape = Responsive.isLandscape(context);
    final perColumn = isLandscape ? _songsPerColumnLandscape : _songsPerColumn;

    final chunks = <List<dynamic>>[];
    for (var i = 0; i < songs.length; i += perColumn) {
      final end = (i + perColumn < songs.length)
          ? i + perColumn
          : songs.length;
      chunks.add(songs.sublist(i, end));
    }

    // Full column width with a peek of the next one, same "there's more
    // to swipe to" affordance as the reference layout — measured off
    // the space actually available for content (screen width minus the
    // landscape NavigationRail), not raw screen width, so the "peek"
    // still reads correctly once the rail is showing. Reuses
    // Responsive.availableContentWidth instead of hand-rolling the same
    // rail subtraction this file used to do independently.
    final availableWidth = Responsive.availableContentWidth(context);
    final columnWidth = availableWidth * (isLandscape ? 0.6 : 0.86);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeader(
          "Songs",
          songs.length,
          onSeeAll: () => _seeAll(FavoriteKind.songs),
        ),
        SizedBox(
          height: _songRowHeight * perColumn,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            // Build the next song column (and so start its artwork) a
            // full column ahead of the viewport so art is ready before
            // a column swipes into view instead of arriving after its
            // text.
            cacheExtent: columnWidth,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            itemCount: chunks.length,
            separatorBuilder: (_, __) => const SizedBox(width: 16),
            itemBuilder: (context, columnIndex) {
              final chunk = chunks[columnIndex];
              final baseIndex = columnIndex * perColumn;

              return SizedBox(
                width: columnWidth,
                child: Column(
                  // Column defaults to CrossAxisAlignment.center, which
                  // hands each child an UNBOUNDED width — fine for the
                  // SizedBox itself, but SongRow's internal Row relies
                  // on Expanded for its title/artist text, and Expanded
                  // inside an unbounded-width Row throws a layout
                  // exception. That exception is what was silently
                  // eating every row here (header + horizontal scroller
                  // still rendered fine, just nothing inside each
                  // column) — stretch forces a real, bounded width
                  // (columnWidth) down to each row so Expanded has
                  // something finite to divide up.
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var rowInChunk = 0;
                        rowInChunk < chunk.length;
                        rowInChunk++)
                      _songRowTile(
                        chunk[rowInChunk] as Map,
                        globalIndex: baseIndex + rowInChunk,
                      ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _songRowTile(Map song, {required int globalIndex}) {
    final id = song["Id"].toString();
    final selected = _songSelect.isSelected(id);

    return SizedBox(
      height: _songRowHeight,
      child: ValueListenableBuilder<MediaItem?>(
        valueListenable: PlayerManager.instance.currentItemNotifier,
        builder: (context, currentItem, _) {
          return SongRow(
            song: song,
            playing: currentItem != null && currentItem.id == song["Id"],
            showDownloadStatus: true,
            selectionMode: _songSelect.active,
            selected: selected,
            onLongPress:
                _songSelect.active ? null : () => _enterSongSelection(id),
            onTap: _songSelect.active
                ? () => _toggleSongSelection(id)
                : () => _playSongs(songs, startIndex: globalIndex),
          );
        },
      ),
    );
  }
}
