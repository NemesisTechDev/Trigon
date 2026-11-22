import 'dart:async';

import 'package:flutter/material.dart';

import '../../utils/responsive.dart';
import '../../player/playback_service.dart';
import '../../player/player_manager.dart';
import '../../player/screens/audio_player_screen.dart';
import '../../player/services/playback_queue.dart';
import '../../services/download_manager.dart';
import '../../services/jellyfin_services/media_service.dart';
import '../../services/jellyfin_services/music_service.dart';
import '../../widgets/live_tv/live_channel_card.dart';
import '../../widgets/music/album_card.dart';
import '../../widgets/music/artist_card.dart';
import '../../widgets/music/song_row.dart';
import '../collection_details/collection_details_screen.dart';
import '../cast_crew/cast_crew_detail_screen.dart';
import '../live_tv/live_tv_detail_screen.dart';
import '../movie_details/movie_details_screen.dart';
import '../movie_details/widgets/cast_row.dart';
import '../movies/widgets/movie_card.dart';
import '../profile/parental/parental_prompts.dart';
import '../music/music_detail_screen.dart';
import '../../widgets/common/pressable.dart';
import '../../widgets/music/song_selection_bar.dart';
import '../../widgets/music/song_multi_select.dart';
import '../../widgets/music/song_selection_actions.dart';
import '../../widgets/music/playlist_picker_sheet.dart';
import '../../utils/bottom_clearance.dart';

const _gold = Color(0xffD4AF37);
const _bg = Color(0xff161616);

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key, this.onBack});

  /// Called when the back arrow in the search bar is tapped. Defaults to
  /// popping the Navigator, which is correct for the normal push-based
  /// usage (e.g. Home's search icon in portrait). When SearchScreen is
  /// embedded as a landscape sidebar tab instead of being pushed,
  /// MainNavScreen passes a callback that switches back to the Home tab,
  /// since there's no route to pop in that case.
  final VoidCallback? onBack;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();

  Timer? _debounce;

  // Hold-to-multi-select for the Songs search results section.
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

    final items = MediaService.mediaItemsFromList(selected);
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

  /// "Play selected": a brand-new queue of exactly the selected search
  /// results, in list order.
  Future<void> _playSelectedSongs() async {
    final selected = _selectedSongs;
    if (selected.isEmpty) return;

    // Same as this screen's tap-to-play: a downloaded copy plays from disk.
    final queue = mediaItemsFromMixedSongs(selected, preferDownloads: true);

    _focusNode.unfocus();
    _exitSongSelection();
    await playSelectionAsQueue(context, queue);
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

  // Incremented on every search kicked off, so a slow earlier search
  // can't land after (and overwrite results from) a faster later one.
  int _generation = 0;

  bool loading = false;
  bool hasSearched = false;
  String _query = "";

  List<dynamic> movies = [];
  List<dynamic> shows = [];
  List<dynamic> collections = [];
  List<dynamic> albums = [];
  List<dynamic> songs = [];
  List<dynamic> artists = [];
  List<dynamic> people = [];
  List<dynamic> channels = [];

  // Fetched once in the background rather than per keystroke — Live TV
  // channel search has no server-side SearchTerm support, so results
  // are filtered client-side against whatever list this holds, same
  // approach the All Channels screen already uses.
  List<dynamic> _allChannels = [];

  @override
  void initState() {
    super.initState();
    _loadChannelsInBackground();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _loadChannelsInBackground() async {
    try {
      final result = await MediaService.getLiveTvChannels();
      if (!mounted) return;
      setState(() {
        _allChannels = result;
        if (_query.isNotEmpty) _applyChannelFilter();
      });
    } catch (_) {
      // Live TV may not be configured on this server — search still
      // works fine for everything else.
    }
  }

  void _applyChannelFilter() {
    final q = _query.toLowerCase();
    channels = _allChannels
        .where((c) => (c["Name"] ?? "").toString().toLowerCase().contains(q))
        .toList();
  }

  void _onQueryChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      _runSearch(value.trim());
    });
  }

  /// Runs one search type in isolation — a failure here (e.g. a server
  /// that doesn't support /Persons) shouldn't blank out every other
  /// section's results.
  Future<List<dynamic>> _safe(Future<List<dynamic>> future) async {
    try {
      return await future;
    } catch (_) {
      return [];
    }
  }

  Future<void> _runSearch(String query) async {
    final generation = ++_generation;

    _songSelect.clear();
    setState(() {
      _query = query;
      hasSearched = query.isNotEmpty;
    });

    if (query.isEmpty) {
      setState(() {
        loading = false;
        movies = [];
        shows = [];
        collections = [];
        albums = [];
        songs = [];
        artists = [];
        people = [];
        channels = [];
      });
      return;
    }

    setState(() => loading = true);

    final results = await Future.wait([
      _safe(MediaService.getItems(
        searchTerm: query,
        includeItemTypes: "Movie,Series,BoxSet,MusicAlbum,Audio",
        limit: 60,
      )),
      _safe(MusicService.searchArtists(query)),
      _safe(MediaService.searchPeople(query)),
    ]);

    if (generation != _generation || !mounted) return;

    final combined = results[0];

    setState(() {
      movies = combined.where((i) => i["Type"] == "Movie").toList();
      shows = combined.where((i) => i["Type"] == "Series").toList();
      collections = combined.where((i) => i["Type"] == "BoxSet").toList();
      albums = combined.where((i) => i["Type"] == "MusicAlbum").toList();
      songs = combined.where((i) => i["Type"] == "Audio").toList();
      artists = results[1];
      people = results[2];
      _applyChannelFilter();
      loading = false;
    });
  }

  bool get _isEmpty =>
      movies.isEmpty &&
      shows.isEmpty &&
      collections.isEmpty &&
      albums.isEmpty &&
      songs.isEmpty &&
      artists.isEmpty &&
      people.isEmpty &&
      channels.isEmpty;

  void _openMovieOrShow(dynamic item) {
    // Closes the keyboard/cursor the moment another screen opens, rather
    // than leaving it focused underneath the pushed route — otherwise the
    // keyboard can stay up and interfere with the new screen's layout,
    // and (since nothing re-requests focus on pop) it stays deactivated
    // until the search field is tapped again.
    _focusNode.unfocus();

    // Parental Controls: a blocked result is never opened from here (its
    // card already explains why; this covers any other route to this method).
    if (item is Map && item["ParentalBlocked"] == true) {
      ParentalPrompts.showTitleBlocked(context, item);
      return;
    }

    if (item["Type"] == "BoxSet") {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => CollectionDetailsScreen(
            collectionId: item["Id"],
            initialItem: Map<String, dynamic>.from(item),
          ),
        ),
      );
      return;
    }

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MovieDetailsScreen(
          itemId: item["Id"],
          initialItem: Map<String, dynamic>.from(item),
        ),
      ),
    );
  }

  void _openMusicItem(dynamic item) {
    _focusNode.unfocus();
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MusicDetailScreen(
          itemId: item["Id"],
          initialItem: Map<String, dynamic>.from(item),
        ),
      ),
    );
  }

  void _openPerson(dynamic person) {
    _focusNode.unfocus();
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CastCrewDetailScreen(
          personId: person["Id"],
          initialItem: Map<String, dynamic>.from(person),
        ),
      ),
    );
  }

  Future<void> _playSong(int index) async {
    _focusNode.unfocus();

    final wasAlreadyPlaying = PlayerManager.instance.currentItem != null;

    final queue = songs
        .map((s) => DownloadManager.instance
            .mediaItemFor(Map<String, dynamic>.from(s)))
        .toList();

    if (!wasAlreadyPlaying) {
      // Pushes the player immediately with a loading preview instead of
      // waiting on playQueue() to actually open the stream first — same
      // pattern the video player already uses for "Play". playQueue()
      // below overwrites the preview with the real resolved item, and
      // any failure surfaces via the error overlay on AudioPlayerScreen
      // itself rather than a SnackBar back here.
      PlayerManager.instance.showLoadingPreview(queue[index]);

      // Flutter's focus system restores the search field's focus (and
      // therefore reopens the keyboard) once this pushed route is
      // popped — the earlier _focusNode.unfocus() call above only
      // clears focus for the push itself, it doesn't survive the round
      // trip back. This is a known Flutter focus-restoration quirk,
      // most noticeable across a rootNavigator push/pop like this one
      // (back gesture and the hardware/OS back button both trigger
      // it). Re-unfocusing once the route actually finishes popping —
      // rather than relying on the earlier call to "stick" — is what
      // actually keeps the keyboard down and avoids the extra
      // input-method churn that was contributing to stutter here.
      unawaited(
        Navigator.of(context, rootNavigator: true)
            .push(MaterialPageRoute(builder: (_) => const AudioPlayerScreen()))
            .then((_) {
          if (mounted) _focusNode.unfocus();
        }),
      );

      await PlaybackService.playQueue(
        queue,
        startIndex: index,
        source: PlaybackSource.unknown,
        title: "Search Results",
      );
      return;
    }

    // Already playing something, so there's no screen being pushed here
    // to show an error overlay on — surface a failure with a SnackBar
    // instead.
    await PlaybackService.playQueue(
      queue,
      startIndex: index,
      source: PlaybackSource.unknown,
      title: "Search Results",
    );

    if (!mounted) return;

    final error = PlayerManager.instance.lastError.value;
    if (error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    // Aspect-scoped — only rebuilds this screen when device padding
    // itself changes (rotation, notch/gesture-area changes), never on
    // keyboard insets — the exact thing this screen's own search field
    // triggers constantly. See the `viewPadding` swap below.
    final viewPadding = MediaQuery.paddingOf(context);

    return Scaffold(
      backgroundColor: _bg,
      // No bottom padding is added below (see the Padding replacing
      // SafeArea further down) — same reasoning as the other tabs: the
      // main nav's transparent-to-black bottom bar (+ mini player)
      // floats over this screen via extendBody on MainNavScreen, so
      // results should keep scrolling underneath it rather than
      // stopping at the safe-area edge. Actual clearance is added
      // manually below.
      //
      // Was SafeArea(bottom: false) here. SafeArea's own build() calls
      // the *unscoped* MediaQuery.of(context) internally, which
      // subscribes it to every MediaQueryData field — including
      // viewInsets.bottom, which the framework updates on every single
      // frame while the keyboard is sliding open or closed (this
      // screen's search field is the most common trigger of exactly
      // that). Each of those frames marked this SafeArea dirty and
      // forced its *entire* child — the search bar and the whole
      // results list — to rebuild from scratch in lockstep with the
      // keyboard's own animation, which is what was surfacing as the
      // keyboard dragging/stuttering instead of gliding cleanly, same
      // as Music/Movies/Live TV/Downloads. A plain Padding using the
      // aspect-scoped `viewPadding` above gets the identical
      // top/left/right safe-area values (bottom was already excluded)
      // but only rebuilds when device padding itself actually changes.
      body: Padding(
        padding: EdgeInsets.only(
          top: viewPadding.top,
          left: viewPadding.left,
          right: viewPadding.right,
        ),
        child: Column(
          children: [
            if (_songSelect.active)
              SongSelectionBar(
                count: _songSelect.count,
                busy: _songSelect.busy,
                onClose: _exitSongSelection,
                onPlaySelected: _playSelectedSongs,
                onAddToQueue: _bulkAddSelectedSongsToQueue,
                onDownload: _bulkDownloadSelectedSongs,
                onAddToPlaylist: _bulkAddSelectedSongsToPlaylist,
              )
            else
              _buildSearchBar(),
            Expanded(child: _buildBody()),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 20, 12),
      child: Row(
        children: [
          // The back arrow only makes sense for the portrait usage,
          // where SearchScreen is pushed as its own route on top of
          // Home. In landscape, SearchScreen is a permanent sidebar
          // tab (MainNavScreen passes onBack to swap back to Home
          // instead of popping) — there's no route to go "back" from,
          // so the arrow is dropped entirely rather than kept around
          // as a redundant, confusing affordance.
          if (widget.onBack == null)
            IconButton(
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.arrow_back, color: Colors.white),
            ),
          Expanded(
            child: Container(
              height: 46,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                color: const Color(0xff232323),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                children: [
                  const Icon(Icons.search, color: Colors.white54, size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      focusNode: _focusNode,
                      onChanged: _onQueryChanged,
                      onSubmitted: (v) {
                        _debounce?.cancel();
                        _runSearch(v.trim());
                      },
                      style: const TextStyle(color: Colors.white, fontSize: 15),
                      decoration: const InputDecoration(
                        hintText:
                            "Movies, TV shows and cast & crew",
                        hintStyle: TextStyle(color: Colors.white38, fontSize: 14),
                        border: InputBorder.none,
                        isCollapsed: true,
                      ),
                    ),
                  ),
                  if (_controller.text.isNotEmpty)
                    Pressable(
                      onTap: () {
                        _controller.clear();
                        _debounce?.cancel();
                        _runSearch("");
                      },
                      borderRadius: BorderRadius.circular(12),
                      child: const Padding(
                        padding: EdgeInsets.all(4),
                        child: Icon(
                          Icons.close,
                          color: Colors.white54,
                          size: 18,
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

  Widget _buildBody() {
    if (!hasSearched) {
      return _buildPrompt();
    }

    if (loading && _isEmpty) {
      return const Center(
        child: CircularProgressIndicator(color: _gold),
      );
    }

    if (_isEmpty) {
      return _buildNoResults();
    }

    return BottomClearanceBuilder(
      builder: (context, bottomClearance) => ListView(
      padding: EdgeInsets.only(
        bottom: 32 + MediaQuery.paddingOf(context).bottom + bottomClearance,
      ),
      children: [
        if (movies.isNotEmpty)
          _posterSection("Movies", movies, _openMovieOrShow),
        if (shows.isNotEmpty)
          _posterSection("TV Shows", shows, _openMovieOrShow),
        // NAMESIS PRIME: Collections right below TV Shows, directly above
        // Cast & Crew.
        if (collections.isNotEmpty)
          _posterSection("Collections", collections, _openMovieOrShow),
        if (people.isNotEmpty) _peopleSection(),
        if (albums.isNotEmpty) _albumSection(),
        if (artists.isNotEmpty) _artistSection(),
        if (songs.isNotEmpty) _songSection(),
        if (channels.isNotEmpty) _channelSection(),
      ],
      ),
    );
  }

  Widget _buildPrompt() {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        SizedBox(
          height: Responsive.emptyStateHeight(context),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 40),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 84,
                    height: 84,
                    alignment: Alignment.center,
                    decoration: const BoxDecoration(
                      color: Color(0xff1E1E1E),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.search,
                      color: Colors.white24,
                      size: 36,
                    ),
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    "Search your library",
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    "Movies, TV shows and cast & crew",
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white54,
                      fontSize: 13,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildNoResults() {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        SizedBox(
          height: Responsive.emptyStateHeight(context),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 40),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.search_off,
                    color: Colors.white24,
                    size: 40,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'No results for "$_query"',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    "Try a different title, artist, or channel name.",
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white54, fontSize: 13),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _sectionHeader(String title, int count) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
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
      ),
    );
  }

  Widget _posterSection(
    String title,
    List<dynamic> items,
    void Function(dynamic) onTap,
  ) {
    const width = 130.0;
    const aspect = 2 / 3;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeader(title, items.length),
        SizedBox(
          height: width / aspect,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (context, index) {
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
      ],
    );
  }

  Widget _albumSection() {
    const width = 130.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeader("Albums", albums.length),
        SizedBox(
          height: width + 44,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            itemCount: albums.length,
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (context, index) {
              final album = albums[index] as Map;
              return SizedBox(
                width: width,
                child: AlbumCard(
                  album: album,
                  decodeWidth: width,
                  onTap: () => _openMusicItem(album),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _artistSection() {
    const width = 130.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeader("Artists", artists.length),
        SizedBox(
          height: width + 36,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            itemCount: artists.length,
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (context, index) {
              final artist = artists[index] as Map;
              return SizedBox(
                width: width,
                child: ArtistCard(
                  artist: artist,
                  onTap: () => _openMusicItem(artist),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  /// Same CastRow used on the detail screens, so search results show up
  /// as the rectangular poster-style cards rather than the circle
  /// avatars — CastRow already renders its own "Cast & Crew" header, so
  /// the shared `_sectionHeader` (with its count badge) is skipped here
  /// to avoid a duplicate title.
  Widget _peopleSection() {
    return CastRow(
      cast: people,
      onTap: (person) => _openPerson(person),
    );
  }

  void _openChannel(dynamic channel) {
    _focusNode.unfocus();
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => LiveTvDetailScreen(
          channelId: channel["Id"],
          initialItem: Map<String, dynamic>.from(channel),
        ),
      ),
    );
  }

  /// Same LiveChannelCard used in the Live TV screen's rows. Search
  /// has no guide data loaded, so program/nextProgram are always null
  /// — LiveChannelCard already handles that gracefully (just image +
  /// name, no "LIVE" badge or progress bar).
  Widget _channelSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeader("TV Channels", channels.length),
        SizedBox(
          height: 230,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            itemCount: channels.length,
            separatorBuilder: (_, __) => const SizedBox(width: 14),
            itemBuilder: (context, index) {
              final channel = channels[index];
              return LiveChannelCard(
                channel: channel,
                program: null,
                nextProgram: null,
                onTap: () => _openChannel(channel),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _songSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeader("Songs", songs.length),
        ListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          itemCount: songs.length,
          itemBuilder: (context, index) {
            final song = songs[index];
            final id = song["Id"].toString();
            final selected = _songSelect.isSelected(id);

            return ValueListenableBuilder(
              valueListenable: PlayerManager.instance.currentItemNotifier,
              builder: (context, current, _) {
                return SongRow(
                  song: song,
                  playing: current != null && current.id == song["Id"],
                  selectionMode: _songSelect.active,
                  selected: selected,
                  onLongPress: _songSelect.active
                      ? null
                      : () => _enterSongSelection(id),
                  onTap: _songSelect.active
                      ? () => _toggleSongSelection(id)
                      : () => _playSong(index),
                );
              },
            );
          },
        ),
      ],
    );
  }
}
