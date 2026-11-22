import 'dart:async';
import 'dart:math';

import 'package:cached_network_image/cached_network_image.dart';
import '../../widgets/music/playlist_card.dart';
import 'package:flutter/material.dart';
import '../../utils/responsive.dart';

import '../../services/jellyfin_services/media_service.dart';
import '../../widgets/music/album_card.dart';
import '../../widgets/music/song_row.dart';
import '../../player/playback_service.dart';
import '../../player/player_manager.dart';
import '../../player/services/playback_queue.dart';
import '../../player/screens/audio_player_screen.dart';
import '../../player/models/media_item.dart';
import '../../services/download_manager.dart';
import '../../widgets/shared/collapsing_detail_header.dart';
import '../../widgets/shared/scroll_linked_detail_backdrop.dart';
import '../movie_details/widgets/overview_section.dart';
import '../../widgets/common/pressable.dart';
import '../../widgets/common/device_check_badge.dart';
import '../../widgets/common/download_stop_ring.dart';
import '../../widgets/music/song_download_quality_sheet.dart';
import '../../widgets/music/song_selection_bar.dart';
import '../../widgets/music/song_selection_actions.dart';
import '../../services/local_playlist_service.dart';
import '../../widgets/music/song_multi_select.dart';
import '../../widgets/music/playlist_picker_sheet.dart';
import '../../widgets/common/resistive_refresh.dart';
import '../../services/cache/nemesis_image_cache.dart';
import '../movie_details/widgets/landscape_backdrop_bg.dart';
import '../../utils/logo_trimmer.dart';
import '../../widgets/music/music_landscape_header.dart';
import '../shared/tag_items_screen.dart';
import '../../utils/bottom_clearance.dart';
import '../../widgets/common/fade_scrollbar.dart';
import '../../widgets/common/stacked_action_bar.dart';

class MusicDetailScreen extends StatefulWidget {
  final String itemId;

  /// Whatever the tapped card/row already had in memory (artwork,
  /// name, etc). When present, the screen paints with this immediately
  /// instead of a blank spinner, then silently swaps in the
  /// authoritative full record once it loads.
  final Map<String, dynamic>? initialItem;

  const MusicDetailScreen({
    super.key,
    required this.itemId,
    this.initialItem,
  });

  @override
  State<MusicDetailScreen> createState() =>
      _MusicDetailScreenState();
}

class _MusicDetailScreenState
    extends State<MusicDetailScreen> {

  bool loading = true;

  // Only used by _buildPlaylistPage's CustomScrollView — the album
  // and artist pages aren't in scope for the fade scrollbar per the
  // request, so they're left on their default (uncontrolled) scroll
  // views.
  final ScrollController _playlistScrollController = ScrollController();

  // Vertical scroll offset of whichever page's CustomScrollView is
  // showing (album/artist/playlist — only one is ever built). Feeds
  // ScrollLinkedDetailBackdrop: in portrait the header backdrop is
  // painted behind the scroll view (so it can reach below the header
  // sliver and sit under the icon block) and needs the offset to
  // shrink/scroll away in step with the page. Fed by a
  // ScrollOffsetReporter around each CustomScrollView, so the album/
  // artist views stay uncontrolled exactly as before.
  final ValueNotifier<double> _heroScrollOffset = ValueNotifier<double>(0);

  // See MovieDetailsScreen for the reasoning: the tracklist below the
  // header fades in as one unit once loadData() settles, instead of
  // popping in piece by piece.
  bool contentReady = false;

  // "Similar"/"More Like This" is a supplementary row — it no longer
  // gates contentReady, so a slow recommendations endpoint can't hold
  // up the tracklist from appearing. It fades in on its own once it
  // lands.
  bool similarReady = false;

  Map<String, dynamic>? item;

  bool favorite = false;

  List songs = [];
  List similar = [];
  String? backdropId;
  String? logoId;

  // Playlist-only: cycles the header's backdrop through the playlist's
  // own tracks' artwork, crossfading between random picks — playlists
  // never have a single dedicated backdrop image of their own the way
  // a movie/show does, so this is their equivalent. `_playlistArt` is
  // the ordered pool of distinct artwork URLs built once the tracklist
  // loads; `_playlistBackdropUrl` is whichever one is currently shown,
  // swapped out on a timer (see _startPlaylistBackdropCycle).
  Timer? _playlistBackdropTimer;
  final Random _playlistBackdropRandom = Random();
  List<String> _playlistArt = [];
  String? _playlistBackdropUrl;

  // "Other Albums by <Artist>" — album page only, same supplementary
  // loading pattern as `similar`/`similarReady`: fetched independently
  // so a slow request can't hold up the tracklist, and fades in on its
  // own once it lands.
  List otherAlbumsByArtist = [];
  bool otherAlbumsReady = false;
  String? _mainArtistId;
  String? _mainArtistName;

  // Hold-to-multi-select for this page's tracklist — shared across all
  // three page types (album/artist/playlist) since only one is ever
  // showing at a time. The playlist page additionally offers "Remove
  // from Playlist" as a bulk action; the others don't.
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

  // A playlist that exists only on this device (see LocalPlaylistService):
  // it has no Jellyfin item, so nothing about it — the item record, its
  // tracks, its artwork, favoriting, recommendations — can be asked of
  // the server.
  bool get _isLocalPlaylist =>
      LocalPlaylistService.isLocalPlaylistId(widget.itemId);

  // Songs that actually exist on the Jellyfin server. On-device songs
  // (a playlist can now hold them) have no server artwork or download,
  // so every server-URL-building helper below works off this instead.
  List get _serverSongs =>
      songs.where((s) => !(s is Map && s["IsLocal"] == true)).toList();

  /// "Play selected": a brand-new queue of exactly the selected songs,
  /// in list order (as opposed to _playSongs, which queues the whole
  /// page).
  Future<void> _playSelectedSongs() async {
    final selected = _selectedSongs;
    if (selected.isEmpty) return;

    final queue = mediaItemsFromMixedSongs(selected, preferDownloads: true);

    _exitSongSelection();
    await playSelectionAsQueue(context, queue);
  }

  /// Bulk "Remove from App" for on-device songs (album/artist pages
  /// never hold any, so this only ever shows on the playlist page).
  /// Server songs in a mixed selection are left alone.
  Future<void> _bulkRemoveSelectedLocalSongsFromApp() async {
    final removed =
        await confirmRemoveLocalSongsFromApp(context, _selectedSongs);
    if (removed == null || !mounted) return;

    final removedSet = removed.toSet();
    setState(() {
      songs.removeWhere(
        (s) => s is Map && removedSet.contains(s["Id"].toString()),
      );
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

    // Per-song local/server branch — a playlist can now mix both.
    final items = mediaItemsFromMixedSongs(selected);
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

  // Only meaningful on the playlist page (widget.itemId is that
  // playlist's own id there) — uses PlaylistItemId same as the
  // three-dot menu's single "Remove from Playlist", not the song's own
  // id, since a song can appear in a playlist more than once.
  Future<void> _bulkRemoveSelectedSongsFromPlaylist() async {
    final selected = _selectedSongs;
    if (selected.isEmpty) return;

    setState(() => _songSelect.busy = true);

    // On-device songs were never sent to the server, so they have no
    // PlaylistItemId or server entry — they're removed from the app's
    // own playlist storage instead. Server entries go first so a
    // failure there leaves the on-device side untouched too.
    final serverEntryIds = selected
        .where((s) => s["IsLocal"] != true)
        .map((s) => s["PlaylistItemId"]?.toString() ?? s["Id"].toString())
        .toList();
    final localIds = selected
        .where((s) => s["IsLocal"] == true)
        .map((s) => s["Id"].toString())
        .toList();

    final messenger = ScaffoldMessenger.maybeOf(context);

    try {
      if (serverEntryIds.isNotEmpty) {
        await MediaService.removeManyFromPlaylist(widget.itemId, serverEntryIds);
      }
      if (localIds.isNotEmpty) {
        await LocalPlaylistService.instance.removeSongs(widget.itemId, localIds);
      }
      if (!mounted) return;
      final removedIds = selected.map((s) => s["Id"].toString()).toSet();
      setState(() {
        songs.removeWhere((s) => removedIds.contains(s["Id"].toString()));
        _songSelect.clear();
      });
      messenger?.showSnackBar(
        SnackBar(
          content: Text(
            '${selected.length} song${selected.length == 1 ? '' : 's'} removed from playlist',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _songSelect.busy = false);
      messenger?.showSnackBar(
        const SnackBar(content: Text("Couldn't remove songs from playlist.")),
      );
    }
  }

  // Derives backdropId/logoId from whatever item data is on hand — the
  // artist page's logo, and an album's artist-backdrop, don't actually
  // depend on anything the network fetch uniquely provides (an artist's
  // logoId is always just its own itemId; an album's backdrop/logo IDs
  // just need its ArtistItems, which the card that navigated here
  // already had). Calling this from initState() with the preview data
  // means the header paints with its final artwork immediately instead
  // of only resolving once loadData()'s network round trip finishes —
  // which is what made the artist logo take a beat to show up, and made
  // an album's backdrop visibly swap from the album's own artwork to
  // the artist backdrop right after the page appeared.
  void _applyArtworkIds(Map<String, dynamic> source) {
    switch (source["Type"]) {
      case "MusicAlbum":
        final artists = source["ArtistItems"];

        if (artists != null && artists.isNotEmpty) {
          backdropId = artists.first["Id"];
          logoId = artists.first["Id"];
        } else {
          backdropId = widget.itemId;
          logoId = null;
        }
        break;

      case "MusicArtist":
        backdropId = widget.itemId;
        logoId = widget.itemId;
        break;

      case "Playlist":
      default:
        backdropId = widget.itemId;
        logoId = null;
    }
  }

  // Every album/artist/playlist page is now a normal pushed route (tapped
  // from the Music tab, or from a "More Like This" row on another detail
  // page) — so back is just an ordinary pop, the same as MovieDetailsScreen.
  void _handleBack() {
    final navigator = Navigator.of(context);
    if (navigator.canPop()) {
      navigator.pop();
    }
  }

  @override
  void initState() {
    super.initState();
    // Paint immediately with the preview from whatever list/row got us
    // here; loadData() below fetches the authoritative record and
    // silently replaces it (no spinner) once it's ready.
    item = widget.initialItem;
    loading = widget.initialItem == null;
    favorite = widget.initialItem?["UserData"]?["IsFavorite"] ?? false;

    // Resolve artwork IDs from the preview data right away too, instead
    // of leaving them null until loadData() resolves — see
    // _applyArtworkIds for why this is safe to do off preview data
    // alone.
    if (widget.initialItem != null) {
      _applyArtworkIds(widget.initialItem!);
    }

    loadData();
  }

  @override
  void dispose() {
    _playlistBackdropTimer?.cancel();
    _playlistScrollController.dispose();
    _heroScrollOffset.dispose();
    super.dispose();
  }

  /// Builds the distinct-artwork pool from `songs` and starts the
  /// randomized cycle — called once loadData() settles. No-ops for
  /// album/artist pages (empty pool, timer never starts) and for a
  /// playlist with only one distinct cover, where cycling would have
  /// nothing to alternate to anyway.
  void _startPlaylistBackdropCycle() {
    _playlistBackdropTimer?.cancel();

    if (item?["Type"] != "Playlist") return;

    final seen = <String>{};
    final art = <String>[];
    for (final song in _serverSongs) {
      final key = (song["AlbumId"] ?? song["Id"]).toString();
      if (seen.add(key)) {
        art.add(MediaService.getMusicImage(song["Id"], size: 1600));
      }
    }

    _playlistArt = art;
    if (art.isEmpty) return;

    if (_playlistBackdropUrl == null) {
      setState(() => _playlistBackdropUrl = art.first);
    }

    if (art.length < 2) return;

    // Cadence for the playlist backdrop's crossfade cycle.
    _playlistBackdropTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted || _playlistArt.length < 2) return;
      String next;
      do {
        next = _playlistArt[_playlistBackdropRandom.nextInt(_playlistArt.length)];
      } while (next == _playlistBackdropUrl);
      setState(() => _playlistBackdropUrl = next);
    });
  }

  /// Loads a device-only playlist entirely from the app's own storage —
  /// no Jellyfin calls at all (its id isn't a real server item, so
  /// getMusicItem / the tracks endpoint / recommendations would just
  /// fail).
  Future<void> _loadLocalPlaylist() async {
    final service = LocalPlaylistService.instance;
    await service.ensureLoaded();

    final name = service.nameOf(widget.itemId);
    final loaded = name == null
        ? <Map<String, dynamic>>[]
        : await service.songsFor(widget.itemId);

    if (!mounted) return;

    setState(() {
      item = {
        ...?widget.initialItem,
        "Id": widget.itemId,
        "Name": name ?? widget.initialItem?["Name"] ?? "Playlist",
        "Type": "Playlist",
        "IsLocalPlaylist": true,
      };
      songs = loaded;
      loading = false;
      contentReady = true;
      favorite = false;
    });

    _startPlaylistBackdropCycle();
  }

  Future<void> loadData() async {
    if (_isLocalPlaylist) {
      await _loadLocalPlaylist();
      return;
    }

    final hadPreview = item != null;

    if (!hadPreview) {
      setState(() {
        loading = true;
      });
    }

    // Every navigation entry point (album/artist/playlist grids, "More
    // Like This" rows) passes initialItem with the item's own Type
    // already in it, so it's known here before getMusicItem's round
    // trip resolves it. Firing the tracks fetch immediately alongside
    // getMusicItem — instead of waiting for it to finish and only then
    // deciding which tracks endpoint to call — turns what was a
    // sequential two-request waterfall into one concurrent round trip.
    // That waterfall was worst on the playlist page, whose tracks
    // endpoint (routinely hundreds of songs) is also the heaviest of
    // the three — this was consistently the slowest-loading detail
    // screen in the app.
    final knownType = widget.initialItem?["Type"]?.toString();
    final itemFuture = MediaService.getMusicItem(widget.itemId);
    final earlyTracksFuture =
        knownType != null ? _fetchTracks(knownType) : null;

    try {
      final freshItem = await itemFuture;

      _applyArtworkIds(freshItem);

      final type = freshItem["Type"]?.toString();

      // Only reuse the early fetch if the type it guessed from the
      // preview actually matches the authoritative type from the
      // fresh fetch — cheap guard against a stale/incorrect preview.
      final loadedSongs = (earlyTracksFuture != null && knownType == type)
          ? await earlyTracksFuture
          : await _fetchTracks(type);

      // The tracklist itself is already loaded above; these are all
      // supplementary extras kicked off independently so a slow
      // recommendations/discography endpoint can't hold up the
      // tracklist from appearing.
      switch (type) {
        case "MusicAlbum":
          _loadSimilarInBackground(
                () => MediaService.getSimilarMusic(widget.itemId),
          );

          final albumArtists = freshItem["ArtistItems"];
          if (albumArtists != null && albumArtists.isNotEmpty) {
            _mainArtistId = albumArtists.first["Id"]?.toString();
            _mainArtistName = freshItem["AlbumArtist"] ??
                albumArtists.first["Name"];

            if (_mainArtistId != null) {
              _loadOtherAlbumsInBackground(_mainArtistId!);
            }
          }
          break;

        case "MusicArtist":
          _loadSimilarInBackground(
                () => MediaService.getRecommendedArtists(
              currentArtistId: widget.itemId,
            ),
          );
          break;

        case "Playlist":
          _loadSimilarInBackground(
                () => MediaService.getSimilarMusic(widget.itemId),
          );
          break;
      }

      if (!mounted) return;

      setState(() {
        item = freshItem;
        songs = loadedSongs;
        loading = false;
        contentReady = true;
        favorite = freshItem["UserData"]?["IsFavorite"] ?? favorite;
      });

      _startPlaylistBackdropCycle();
    } catch (e) {
      if (!mounted) return;
      // A refresh failing shouldn't blank out a screen that's already
      // showing good preview content.
      if (hadPreview) {
        setState(() => contentReady = true);
        return;
      }
      setState(() {
        loading = false;
      });
    }
  }

  /// The type-specific tracks fetch, pulled out on its own so it can be
  /// kicked off early (see loadData()) using the type the preview
  /// already told us, rather than only after getMusicItem resolves.
  Future<List<dynamic>> _fetchTracks(String? type) {
    switch (type) {
      case "MusicAlbum":
        return MediaService.getAlbumTracks(widget.itemId);
      case "MusicArtist":
        return MediaService.getArtistSongs(widget.itemId);
      case "Playlist":
        return _fetchPlaylistTracks();
      default:
        return Future.value(const []);
    }
  }

  /// A server playlist's tracks plus any on-device songs attached to it
  /// (kept in the app's own storage, since the server can't hold them —
  /// see LocalPlaylistService). Both fetches run concurrently; the
  /// on-device songs follow the server ones, in the order they were
  /// added.
  Future<List<dynamic>> _fetchPlaylistTracks() async {
    final results = await Future.wait([
      MediaService.getPlaylistTracks(widget.itemId),
      LocalPlaylistService.instance.songsFor(widget.itemId),
    ]);
    return [...results[0], ...results[1]];
  }

  /// Runs independently of loadData() so a slow recommendations
  /// response can't delay the tracklist from appearing. Sets its own
  /// `similarReady` flag so the row fades in on its own once its data
  /// actually arrives.
  Future<void> _loadSimilarInBackground(
      Future<List> Function() fetch,
      ) async {
    try {
      final results = await fetch();

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
  /// Same reasoning as [_loadSimilarInBackground] — runs independently
  /// so a slow discography lookup can't delay the tracklist, and fades
  /// its row in on its own once it lands.
  Future<void> _loadOtherAlbumsInBackground(String artistId) async {
    try {
      final results = await MediaService.getArtistAlbums(
        artistId,
        excludeAlbumId: widget.itemId,
      );

      if (!mounted) return;

      setState(() {
        otherAlbumsByArtist = results;
        otherAlbumsReady = true;
      });
    } catch (_) {
      if (!mounted) return;

      setState(() {
        otherAlbumsReady = true;
      });
    }
  }

  Future<void> _toggleFavorite() async {
    // A device-only playlist has no server item to favorite.
    if (_isLocalPlaylist) return;

    final wasFavorite = favorite;

    // Optimistic UI: flip immediately, then reconcile with the server;
    // revert if the request fails.
    setState(() => favorite = !wasFavorite);

    try {
      await MediaService.toggleFavorite(widget.itemId, wasFavorite);
    } catch (_) {
      if (!mounted) return;
      setState(() => favorite = wasFavorite);
    }
  }

  /// The first song row's artwork — used as the collapsed top bar's
  /// color source for artists with no logo, and for playlists (which
  /// never have a logo of their own).
  String? _firstSongArtworkUrl() {
    final pool = _serverSongs;
    if (pool.isEmpty) return null;
    return MediaService.getMusicImage(pool.first["Id"], size: 500);
  }

  /// Deterministically picks between the first two tracks' artwork,
  /// switching once every 24 hours. Used as a backdrop stand-in wherever
  /// a real Backdrop image isn't available — albums/artists with no
  /// backdrop art, and playlists, which never have one of their own.
  String? _dailyAlternatingArtworkUrl() {
    // Server songs only — an on-device song has no server artwork URL.
    final pool = _serverSongs;
    if (pool.isEmpty) return null;

    final dayNumber = DateTime.now().difference(DateTime(2020)).inDays;
    final poolSize = pool.length < 2 ? 1 : 2;
    final song = pool[dayNumber % poolSize];
    return MediaService.getMusicImage(song["Id"], size: 1600);
  }

  /// Stretched song artwork used as a backdrop fallback.
  /// Stretched version of this item's own poster art — the backdrop
  /// fallback for artist/album pages when there's no dedicated Backdrop
  /// image (or, for an album, no artist to source one from). Uses the
  /// item's own artwork directly, which is available immediately with
  /// no dependency on the tracklist having loaded yet — unlike
  /// _buildArtworkBackdrop() below, which picks from `songs` and so
  /// can't resolve to anything until loadData() finishes. Albums and
  /// artists both fall back to this so their "no backdrop" behavior is
  /// identical.
  Widget _buildSelfArtworkBackdrop() {
    return CachedNetworkImage(
      cacheManager: NemesisImageCache.instance,
      imageUrl: MediaService.getMusicImage(widget.itemId, size: 1600),
      fit: BoxFit.cover,
      fadeInDuration: const Duration(milliseconds: 250),
      placeholder: (_, __) => Container(color: const Color(0xff161616)),
      errorWidget: (_, __, ___) => Container(
        color: const Color(0xff161616),
      ),
    );
  }

  /// The artist's own 155x155 rounded photo, shadowed the same way in
  /// both portrait's icon+text row and landscape's centered identity
  /// block — falls back to a plain person icon, matching ArtistCard's
  /// (music grid) fallback treatment.
  Widget _buildArtistPhoto(String poster) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        boxShadow: const [
          BoxShadow(
            color: Colors.black54,
            blurRadius: 25,
            offset: Offset(0, 12),
          ),
        ],
      ),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          boxShadow: const [
            BoxShadow(
              color: Colors.black54,
              blurRadius: 30,
              offset: Offset(0, 15),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: CachedNetworkImage(
            cacheManager: NemesisImageCache.instance,
            imageUrl: poster,
            width: 155,
            height: 155,
            fit: BoxFit.cover,
            fadeInDuration: const Duration(milliseconds: 200),
            placeholder: (_, __) => Container(
              color: const Color(0xff2A2A2A),
            ),
            errorWidget: (_, __, ___) => Container(
              color: const Color(0xff2A2A2A),
              child: const Center(
                child: Icon(
                  Icons.person,
                  color: Colors.white38,
                  size: 60,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildArtworkBackdrop() {
    final artUrl = _dailyAlternatingArtworkUrl();
    if (artUrl == null) {
      return Container(color: const Color(0xff161616));
    }

    return CachedNetworkImage(
      cacheManager: NemesisImageCache.instance,
      imageUrl: artUrl,
      fit: BoxFit.cover,
      fadeInDuration: const Duration(milliseconds: 250),
      placeholder: (_, __) => Container(color: const Color(0xff161616)),
      errorWidget: (_, __, ___) => Container(
        color: const Color(0xff161616),
      ),
    );
  }

  /// Playlist header backdrop — crossfades between the playlist's own
  /// tracks' artwork on a timer (see _startPlaylistBackdropCycle),
  /// using the same AnimatedSwitcher-over-a-Stack + plain fade
  /// treatment the home screen's hero carousel uses to crossfade
  /// between its featured items' backdrops, so the two "art rotating
  /// in the background" moments read as the same behavior app-wide.
  Widget _buildPlaylistArtworkBackdrop() {
    final url = _playlistBackdropUrl ?? _dailyAlternatingArtworkUrl();
    if (url == null) {
      return Container(color: const Color(0xff161616));
    }

    return AnimatedSwitcher(
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
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: CurvedAnimation(parent: animation, curve: Curves.easeInOut),
        child: child,
      ),
      child: CachedNetworkImage(
        key: ValueKey(url),
        cacheManager: NemesisImageCache.instance,
        imageUrl: url,
        fit: BoxFit.cover,
        fadeInDuration: Duration.zero,
        placeholder: (_, __) => Container(color: const Color(0xff161616)),
        errorWidget: (_, __, ___) => Container(
          color: const Color(0xff161616),
        ),
      ),
    );
  }

  String getPlaylistDuration() {
    int totalTicks = 0;

    for (final song in songs) {
      totalTicks += (song["RunTimeTicks"] ?? 0) as int;
    }

    final totalSeconds = totalTicks ~/ 10000000;

    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;

    if (hours > 0) {
      return "$hours hr ${minutes} min";
    }

    return "$minutes min";
  }

  /// Unique genres represented across the playlist's own tracks, in
  /// first-seen order — playlists don't carry a Genres field of their
  /// own (unlike albums/artists), so this is the closest equivalent:
  /// what genres the songs actually in it belong to.
  List<String> _playlistGenres() {
    final seen = <String>{};
    final genres = <String>[];

    for (final song in songs) {
      for (final genre in (song["Genres"] ?? [])) {
        final name = genre.toString();
        if (name.isNotEmpty && seen.add(name)) {
          genres.add(name);
        }
      }
    }

    return genres;
  }

  /// Opens [TagItemsScreen] filtered to [genre], scoped to
  /// MusicAlbum items — shared by the artist/album/playlist genre
  /// chips (both portrait's ExpandableGenreChips and landscape's
  /// MusicLandscapeHeader) below, all of which only ever show music
  /// genres.
  void _openGenre(String genre) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TagItemsScreen(
          genre: genre,
          includeItemTypes: "MusicAlbum",
        ),
      ),
    );
  }

  Future<void> _playSongs({
    int startIndex = 0,
    bool shuffle = false,
  }) async {
    if (songs.isEmpty) return;

    // Whether the mini player was already up and running *before* this
    // tap. If nothing was playing yet, we're starting a fresh session and
    // should take the user straight into the full player. If something
    // was already playing (mini player already active), this tap is just
    // switching tracks — let the mini player update in place instead of
    // popping the full screen open again.
    final wasAlreadyPlaying = PlayerManager.instance.currentItem != null;

    // Plays from the local file automatically for any track that's
    // been downloaded, same as the movie/episode players.
    // Per-song branch: a playlist can hold on-device songs, which need
    // LocalMusicService's builder rather than a Jellyfin stream URL.
    final queue = mediaItemsFromMixedSongs(songs, preferDownloads: true);

    // A device-only playlist has no server cover to hand the player.
    final queueArtwork =
        _isLocalPlaylist ? null : MediaService.getMusicImage(widget.itemId);

    PlaybackSource source;

    switch (item?["Type"]) {
      case "MusicAlbum":
        source = PlaybackSource.album;
        break;

      case "MusicArtist":
        source = PlaybackSource.artist;
        break;

      case "Playlist":
        source = PlaybackSource.playlist;
        break;

      default:
        source = PlaybackSource.unknown;
    }

    if (!wasAlreadyPlaying) {
      // Pushes the player immediately with a loading preview instead of
      // waiting on playQueue() to actually open the stream first — same
      // pattern the video player already uses for "Play". playQueue()
      // below overwrites the preview with the real resolved item, and
      // any failure surfaces via the error overlay on AudioPlayerScreen
      // itself rather than a SnackBar back here.
      PlayerManager.instance.showLoadingPreview(queue[startIndex]);

      Navigator.of(context, rootNavigator: true).push(
        MaterialPageRoute(
          builder: (_) => const AudioPlayerScreen(),
        ),
      );

      await PlaybackService.playQueue(
        queue,
        startIndex: startIndex,
        source: source,
        title: item?["Name"],
        artwork: queueArtwork,
      );

      if (shuffle) {
        PlaybackQueue.instance.shuffle();
      }
      return;
    }

    // Already playing something, so there's no screen being pushed here
    // to show an error overlay on — surface a failure with a SnackBar
    // instead.
    await PlaybackService.playQueue(
      queue,
      startIndex: startIndex,
      source: source,
      title: item?["Name"],
      artwork: queueArtwork,
    );

    // Applied *after* the queue is set (rather than pre-shuffling
    // `queue`/`songs` before the call) so it goes through the same
    // shuffle() used by the audio player's shuffle button — that's
    // what actually flips shuffleNotifier to true (turning the button
    // gold) and records the real pre-shuffle order, so toggling
    // shuffle back off later restores it correctly instead of the
    // button silently disagreeing with what's actually playing.
    if (shuffle) {
      PlaybackQueue.instance.shuffle();
    }

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


    switch (item!["Type"]) {
      case "MusicArtist":
        return _buildArtistPage(context);

      case "MusicAlbum":
        return _buildAlbumPage(context);

      case "Playlist":
        return _buildPlaylistPage(context);

      default:
        return Scaffold(
          backgroundColor: const Color(0xff161616),
          body: Center(
            child: Text(
              "Unknown type: ${item!["Type"]}",
              style: const TextStyle(color: Colors.white),
            ),
          ),
        );
    }
  }

  /// Stacked-bar "Shuffle" action (album / playlist pages).
  Widget _stackedShuffle() {
    return StackedActionBar.item(
      icon: Center(
        child: IconButton(
          onPressed: () {
            _playSongs(shuffle: true);
          },
          icon: const Icon(Icons.shuffle, color: Colors.white),
        ),
      ),
      label: StackedActionBar.labelText("Shuffle"),
    );
  }

  /// Stacked-bar "Favorite" action shared by all three music pages.
  Widget _stackedFavorite() {
    return StackedActionBar.item(
      icon: Center(
        child: IconButton(
          onPressed: _toggleFavorite,
          icon: Icon(
            favorite ? Icons.favorite : Icons.favorite_border,
            color: favorite ? Colors.red : Colors.white,
          ),
        ),
      ),
      label: StackedActionBar.labelText("Favorite"),
    );
  }

  Widget _buildArtistPage(BuildContext context) {
    final poster =
    MediaService.getMusicImage(widget.itemId);

    final backdrop =
    MediaService.getBackdropUrl(
      backdropId ?? widget.itemId,
    );

    // The artist has its own dedicated Logo-type image in Jellyfin only
    // when ImageTags actually carries one — getLogoUrl() always returns
    // *a* URL regardless, so checking ImageTags is what distinguishes
    // "has a real logo" from "would just 404".
    final hasArtistLogo = item?["ImageTags"]?["Logo"] != null;
    final artistLogoUrl =
        hasArtistLogo ? MediaService.getLogoUrl(widget.itemId) : null;
    final collapsedAccentUrl =
        artistLogoUrl ?? _firstSongArtworkUrl() ?? backdrop;

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
            LandscapeBackdropBackground(
              backdropUrl: backdrop,
              // Same "no dedicated backdrop" fallback as portrait's
              // header (see the CachedNetworkImage below) — a song's
              // own stretched artwork instead of a flat dark panel.
              fallback: _buildArtworkBackdrop(),
            ),
          // Portrait only: the header backdrop is painted here, behind the
          // scroll view, instead of inside CollapsingDetailHeader's
          // expandedBuilder. ROOT CAUSE: the icon block sits in the
          // content slivers directly under the header, so for it to
          // overlap the backdrop (like the poster on the movie detail
          // screen) the backdrop has to reach below the header's bottom
          // edge — and a viewport paints its first sliver LAST, so a
          // taller/overflowing header would cover the icon rather than
          // sit under it (and a taller header would push all the content
          // down). Behind the scroll view the header keeps its exact
          // height and the content paints on top. See
          // ScrollLinkedDetailBackdrop.
          if (!Responsive.isLandscape(context))
            ScrollLinkedDetailBackdrop(
              scrollOffset: _heroScrollOffset,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  CachedNetworkImage(
                    cacheManager: NemesisImageCache.instance,
                    imageUrl: backdrop,
                    fit: BoxFit.cover,
                    fadeInDuration: const Duration(milliseconds: 250),
                    // Artists rarely have their own dedicated Backdrop (or
                    // even Primary) art uploaded — unlike an album, whose
                    // own itemId always resolves to real cover art, an
                    // artist's self-image is usually empty too. Falling
                    // back to _buildArtworkBackdrop() (a song's own
                    // stretched artwork, same source the album page's
                    // "no backdrop" case effectively resolves to) instead
                    // of _buildSelfArtworkBackdrop() (the artist's own,
                    // usually-missing photo) is what actually gets a real
                    // image on screen instead of a blank dark panel.
                    placeholder: (_, __) => _buildArtworkBackdrop(),
                    errorWidget: (_, __, ___) => _buildArtworkBackdrop(),
                  ),

                  Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.transparent,
                          Colors.black.withValues(alpha: .45),
                          const Color(0xff161616),
                        ],
                      ),
                    ),
                  ),

                ],
              ),
            ),
          ResistiveRefresh(
            onRefresh: loadData,
            color: const Color(0xffD4AF37),
            backgroundColor: const Color(0xff232323),
            child: ScrollOffsetReporter(
            offset: _heroScrollOffset,
            child: CustomScrollView(
        // A short tracklist/filmography doesn't overflow the
        // viewport, which otherwise leaves the pull gesture with
        // nothing to grab onto.
        physics: const AlwaysScrollableScrollPhysics(),
        // Build song rows (and so start their artwork) a screen-height
        // ahead of the viewport so art is ready before a row scrolls
        // into view instead of arriving after its text.
        cacheExtent: MediaQuery.sizeOf(context).height,
        slivers: [
          CollapsingDetailHeader(
            // Landscape has nothing to paint in this header (see
            // expandedBuilder below) — it's just reserving space for
            // the pinned bar/back button, so it's sized like the thin
            // fixed bar the movie/cast & crew screens use there
            // (topPadding + a few pixels of collapse runway) instead
            // of a full portrait-style hero height. That's what keeps
            // the gap to the icon block below in line with those
            // screens instead of leaving a tall blank reserve above it.
            expandedHeight: Responsive.isLandscape(context)
                ? MediaQuery.paddingOf(context).top + 60
                : kDetailHeaderHeight,
            onBack: _handleBack,
            accentImageUrl: collapsedAccentUrl,
            collapsedLogoUrl: artistLogoUrl,
            // Landscape now stays fully transparent here — the page-wide
            // backdrop added above the scroll view already covers this
            // header, so painting another copy (or a gradient down to a
            // flat page color) would just recreate the seam this was
            // meant to remove. Portrait now does the same: its backdrop is
            // ScrollLinkedDetailBackdrop (added above the scroll view), so
            // all this header paints in portrait is what must stay on top of
            // it — the big logo below (plus the pinned bar / back button).
            expandedBuilder: (context, t) => Responsive.isLandscape(context)
                ? const SizedBox.shrink()
                : Stack(

                fit: StackFit.expand,

                children: [

                  if (logoId != null)
                    Positioned(
                      right: 30,
                      bottom: 35,
                      child: CachedNetworkImage(
                        cacheManager: NemesisImageCache.instance,
                        imageUrl: MediaService.getLogoUrl(logoId!),
                        height: 70,
                        fit: BoxFit.contain,
                        fadeInDuration: const Duration(milliseconds: 250),
                        errorWidget: (_, __, ___) => const SizedBox(),
                      ),
                    ),
                ],

              ),

          ),
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: contentReady ? 1.0 : 0.0),
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
            builder: (context, opacity, _) => SliverOpacity(
              opacity: opacity,
              sliver: SliverMainAxisGroup(
                slivers: [
          SliverToBoxAdapter(

            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                24,
                24,
                24,
                0,
              ),

              child: Column(

                crossAxisAlignment:
                CrossAxisAlignment.start,

                children: [
                  MusicLandscapeHeader(
                      icon: _buildArtistPhoto(poster),
                      // Landscape only, and only when the artist actually
                      // has a real Logo-type image — sits to the right of
                      // the photo, both centered together as one unit.
                      // Portrait keeps the logo in the hero (bottom-right
                      // of the backdrop) instead, so it isn't repeated.
                      secondaryIcon: Responsive.isLandscape(context) &&
                              artistLogoUrl != null
                          ? SizedBox(
                              height: 84,
                              width: 180,
                              child: TrimmedLogo(
                                url: artistLogoUrl,
                                alignment: Alignment.center,
                                targetArea: 84 * 180,
                                maxWidth: 180,
                                maxHeight: 84,
                              ),
                            )
                          : null,
                      title: item?["Name"] ?? "",
                      metadataLine:
                          songs.isNotEmpty ? "${songs.length} Songs" : null,
                      genres: List<String>.from(item?["Genres"] ?? []),
                      onGenreTap: _openGenre,
                      actions: StackedActionBar(
                        horizontalPadding: 0,
                        playLabel: "Start Listening",
                        onPlay: () {
                          _playSongs();
                        },
                        actions: [
                          _stackedFavorite(),
                          _DownloadAllButton(songs: songs, stacked: true),
                        ],
                      ),
                      stackedActions: true,
                    ),
                  const SizedBox(height: 30),
                  if ((item?["Overview"] ?? "")
                      .toString()
                      .isNotEmpty) ...[

                    _readableOverviewWidth(
                      OverviewSection(
                        overview: item!["Overview"],
                        horizontalPadding: 0,
                      ),
                    ),

                    const SizedBox(height: 10),

                  ],
                  const Text(
                    "Songs",
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 26,
                      fontWeight: FontWeight.bold,
                    ),
                  ),

                  const SizedBox(height: 0),
                ],

              ),

            ),

          ),

          /// Song list as a real sliver — only builds rows that are
          /// actually visible, instead of shrink-wrapping the whole list.
          ValueListenableBuilder<MediaItem?>(
            valueListenable: PlayerManager.instance.currentItemNotifier,
            builder: (context, currentItem, _) {
              return SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                sliver: SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      final song = songs[index];
                      final id = song["Id"].toString();
                      final selected = _songSelect.isSelected(id);

                      return Padding(
                        padding: EdgeInsets.only(
                          bottom: index == songs.length - 1 ? 0 : 6,
                        ),
                        child: SongRow(
                          song: song,
                          playing: currentItem != null &&
                              currentItem.id == song["Id"],
                          showDownloadStatus: true,
                          excludeArtistId: widget.itemId,
                          selectionMode: _songSelect.active,
                          selected: selected,
                          onLongPress: _songSelect.active
                              ? null
                              : () => _enterSongSelection(id),
                          onTap: _songSelect.active
                              ? () => _toggleSongSelection(id)
                              : () {
                                  _playSongs(startIndex: index);
                                },
                        ),
                      );
                    },
                    childCount: songs.length,
                  ),
                ),
              );
            },
          ),

          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 40),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (similar.isNotEmpty) ...[
                    AnimatedOpacity(
                      opacity: similarReady ? 1 : 0,
                      duration: const Duration(milliseconds: 250),
                      curve: Curves.easeOut,
                      child: _buildRecommendationRow(
                        title: "More Like This",
                        height: 215,
                        items: similar,
                        itemBuilder: (context, index) {
                          final artist = similar[index];
                          // Portrait keeps the exact tuned 150 card
                          // width; non-TV landscape gets the same slight
                          // widening Home's own rows already apply
                          // (Responsive.rowItemWidth); TV gets the same
                          // dedicated bump Home's rows use instead, so
                          // this row doesn't render noticeably smaller
                          // than Home's on a real TV.
                          final cardWidth = Responsive.isTV
                              ? 210.0
                              : Responsive.rowItemWidth(context, 150);
                          return SizedBox(
                            width: cardWidth,
                            child: Pressable(
                              borderRadius: BorderRadius.circular(18),
                              onTap: () {
                                Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) => MusicDetailScreen(
                                      itemId: artist["Id"],
                                      initialItem:
                                          Map<String, dynamic>.from(artist),
                                    ),
                                  ),
                                );
                              },
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(18),
                                      child: LayoutBuilder(
                                        builder: (context, constraints) {
                                          final dpr = MediaQuery.devicePixelRatioOf(context);
                                          return CachedNetworkImage(
                                            cacheManager: NemesisImageCache.instance,
                                            imageUrl: MediaService.getMusicImage(
                                              artist["Id"],
                                              size: 300,
                                            ),
                                            width: double.infinity,
                                            fit: BoxFit.cover,
                                            memCacheWidth: constraints
                                                .maxWidth.isFinite
                                                ? (constraints.maxWidth * dpr)
                                                .round()
                                                : null,
                                            memCacheHeight: constraints
                                                .maxHeight.isFinite
                                                ? (constraints.maxHeight * dpr)
                                                .round()
                                                : null,
                                            fadeInDuration:
                                            const Duration(milliseconds: 200),
                                            placeholder: (_, __) => Container(
                                              color: const Color(0xff252525),
                                            ),
                                            errorWidget: (_, __, ___) => Container(
                                              color: const Color(0xff252525),
                                              child: const Center(
                                                child: Icon(
                                                  Icons.person,
                                                  color: Colors.white30,
                                                  size: 45,
                                                ),
                                              ),
                                            ),
                                          );
                                        },
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 10),
                                  Text(
                                    artist["Name"] ?? "",
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],

                  const SizedBox(height: 40),

                  if (similar.isNotEmpty) ...[
                  ]

                  ,

                  // The main nav's bottom bar (mini player + tab bar)
                  // floats over this screen in a plain Stack, not a real
                  // Scaffold.extendBody (see MainNavScreen's own doc
                  // comment) — MediaQuery's bottom padding here is only
                  // ever the safe-area inset, so BottomClearance.of adds
                  // the bar's actual current height back in, reactively,
                  // or the last row would scroll to a stop behind it.
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
          ),


        ],

      ),
        ),
        ),

          if (_songSelect.active)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                bottom: false,
                child: Container(
                  color: const Color(0xf2161616),
                  child: SongSelectionBar(
                    count: _songSelect.count,
                    busy: _songSelect.busy,
                    onClose: _exitSongSelection,
                    onPlaySelected: _playSelectedSongs,
                    onAddToQueue: _bulkAddSelectedSongsToQueue,
                    onDownload: _bulkDownloadSelectedSongs,
                    onAddToPlaylist: _bulkAddSelectedSongsToPlaylist,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }


  Widget _buildAlbumPage(BuildContext context) {
    final poster = MediaService.getMusicImage(widget.itemId);

    final backdrop = MediaService.getBackdropUrl(
      backdropId ?? widget.itemId,
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
            LandscapeBackdropBackground(
              backdropUrl: backdrop,
              // Same "no dedicated backdrop" fallback as portrait's
              // header (see the CachedNetworkImage below) — the
              // album's own artwork instead of a flat dark panel.
              fallback: _buildSelfArtworkBackdrop(),
            ),
          // Portrait only: the header backdrop is painted here, behind the
          // scroll view, instead of inside CollapsingDetailHeader's
          // expandedBuilder. ROOT CAUSE: the icon block sits in the
          // content slivers directly under the header, so for it to
          // overlap the backdrop (like the poster on the movie detail
          // screen) the backdrop has to reach below the header's bottom
          // edge — and a viewport paints its first sliver LAST, so a
          // taller/overflowing header would cover the icon rather than
          // sit under it (and a taller header would push all the content
          // down). Behind the scroll view the header keeps its exact
          // height and the content paints on top. See
          // ScrollLinkedDetailBackdrop.
          if (!Responsive.isLandscape(context))
            ScrollLinkedDetailBackdrop(
              scrollOffset: _heroScrollOffset,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  CachedNetworkImage(
                    cacheManager: NemesisImageCache.instance,
                    imageUrl: backdrop,
                    fit: BoxFit.cover,
                    fadeInDuration: const Duration(milliseconds: 250),
                    placeholder: (_, __) => _buildSelfArtworkBackdrop(),
                    errorWidget: (_, __, ___) => _buildSelfArtworkBackdrop(),
                  ),

                  Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.transparent,
                          Colors.black.withValues(alpha: .45),
                          const Color(0xff161616),
                        ],
                      ),
                    ),
                  ),

                ],
              ),
            ),
          ResistiveRefresh(
            onRefresh: loadData,
            color: const Color(0xffD4AF37),
            backgroundColor: const Color(0xff232323),
            child: ScrollOffsetReporter(
            offset: _heroScrollOffset,
            child: CustomScrollView(
        // A short tracklist/filmography doesn't overflow the
        // viewport, which otherwise leaves the pull gesture with
        // nothing to grab onto.
        physics: const AlwaysScrollableScrollPhysics(),
        // Build song rows (and so start their artwork) a screen-height
        // ahead of the viewport so art is ready before a row scrolls
        // into view instead of arriving after its text.
        cacheExtent: MediaQuery.sizeOf(context).height,
        slivers: [

          CollapsingDetailHeader(
            // See the artist page's identical header for why landscape
            // gets this thin, non-hero height instead of a portrait-
            // style hero height.
            expandedHeight: Responsive.isLandscape(context)
                ? MediaQuery.paddingOf(context).top + 60
                : kDetailHeaderHeight,
            onBack: _handleBack,
            // Albums don't carry a logo of their own, so the collapsed
            // bar's tint still comes straight from the album artwork —
            // same idea as the movie detail screen pulling its collapsed
            // bar's tint from the backdrop. The small logo shown over
            // that tint, though, is the album's main artist's logo
            // (logoId resolves to the artist's Id for MusicAlbum — see
            // _applyArtworkIds), same as the artist page itself shows
            // in its collapsed bar.
            accentImageUrl: poster,
            collapsedLogoUrl:
                logoId != null ? MediaService.getLogoUrl(logoId!) : null,
            // Landscape now stays fully transparent here — the page-wide
            // backdrop added above the scroll view already covers this
            // header, so painting another copy (or a gradient down to a
            // flat page color) would just recreate the seam this was
            // meant to remove. Portrait now does the same: its backdrop is
            // ScrollLinkedDetailBackdrop (added above the scroll view), so
            // all this header paints in portrait is what must stay on top of
            // it — the big logo below (plus the pinned bar / back button).
            expandedBuilder: (context, t) => Responsive.isLandscape(context)
                ? const SizedBox.shrink()
                : Stack(

                fit: StackFit.expand,

                children: [

                  if (logoId != null)
                    Positioned(
                      right: 30,
                      bottom: 35,
                      child: CachedNetworkImage(
                        cacheManager: NemesisImageCache.instance,
                        imageUrl: MediaService.getLogoUrl(logoId!),
                        height: 70,
                        fit: BoxFit.contain,
                        fadeInDuration: const Duration(milliseconds: 250),
                        errorWidget: (_, __, ___) => const SizedBox(),
                      ),
                    ),
                ],
              ),
          ),

          TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: contentReady ? 1.0 : 0.0),
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
            builder: (context, opacity, _) => SliverOpacity(
              opacity: opacity,
              sliver: SliverMainAxisGroup(
                slivers: [
          SliverToBoxAdapter(

            child: Padding(

              padding: const EdgeInsets.fromLTRB(
                24,
                24,
                24,
                0,
              ),

              child: Column(

                crossAxisAlignment: CrossAxisAlignment.start,

                children: [

                  MusicLandscapeHeader(
                      icon: ClipRRect(
                        borderRadius: BorderRadius.circular(20),
                        child: CachedNetworkImage(
                          cacheManager: NemesisImageCache.instance,
                          imageUrl: poster,
                          width: 155,
                          height: 155,
                          fit: BoxFit.cover,
                          fadeInDuration: const Duration(milliseconds: 200),
                          placeholder: (_, __) => Container(
                            color: const Color(0xff2A2A2A),
                          ),
                          errorWidget: (_, __, ___) => Container(
                            color: const Color(0xff2A2A2A),
                          ),
                        ),
                      ),
                      title: item?["Name"] ?? "",
                      subtitle: Pressable(
                        onTap: () {
                          final artists = item?["ArtistItems"];

                          if (artists != null && artists.isNotEmpty) {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => MusicDetailScreen(
                                  itemId: artists.first["Id"],
                                  initialItem: Map<String, dynamic>.from(
                                    artists.first,
                                  ),
                                ),
                              ),
                            );
                          }
                        },
                        borderRadius: BorderRadius.circular(4),
                        child: Text(
                          item?["AlbumArtist"] ?? "",
                          style: const TextStyle(
                            color: Color(0xffD4AF37),
                            fontSize: 17,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      metadataLine:
                          "${item?["ProductionYear"] ?? ""} • ${songs.length} Songs • ${getPlaylistDuration()}",
                      genres: List<String>.from(item?["Genres"] ?? []),
                      onGenreTap: _openGenre,
                      actions: StackedActionBar(
                        horizontalPadding: 0,
                        playLabel: "Start Listening",
                        onPlay: () {
                          _playSongs();
                        },
                        actions: [
                          _stackedShuffle(),
                          _stackedFavorite(),
                          _DownloadAllButton(songs: songs, stacked: true),
                        ],
                      ),
                      stackedActions: true,
                    ),
                  const SizedBox(height: 30),

                  if ((item?["Overview"] ?? "")
                      .toString()
                      .isNotEmpty) ...[

                    _readableOverviewWidth(
                      OverviewSection(
                        overview: item!["Overview"],
                        horizontalPadding: 0,
                        fontSize: null,
                      ),
                    ),

                    const SizedBox(height: 32),

                  ],

                  const Text(
                    "Tracks",
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 26,
                      fontWeight: FontWeight.bold,
                    ),
                  ),

                  const SizedBox(height: 8),

                  Text(
                    "${songs.length} songs • ${getPlaylistDuration()}",
                    style: const TextStyle(
                      color: Colors.white54,
                      fontSize: 14,
                    ),
                  ),

                  const SizedBox(height: 6),
                ],

              ),

            ),

          ),

          /// Song list as a real sliver — only builds rows that are
          /// actually visible, instead of shrink-wrapping the whole list.
          ValueListenableBuilder<MediaItem?>(
            valueListenable: PlayerManager.instance.currentItemNotifier,
            builder: (context, currentItem, _) {
              return SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                sliver: SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      final song = songs[index];
                      final id = song["Id"].toString();
                      final selected = _songSelect.isSelected(id);

                      return Padding(
                        padding: EdgeInsets.only(
                          bottom: index == songs.length - 1 ? 0 : 6,
                        ),
                        child: SongRow(
                          song: song,
                          playing: currentItem != null &&
                              currentItem.id == song["Id"],
                          showDownloadStatus: true,
                          showGoToAlbum: false,
                          selectionMode: _songSelect.active,
                          selected: selected,
                          onLongPress: _songSelect.active
                              ? null
                              : () => _enterSongSelection(id),
                          onTap: _songSelect.active
                              ? () => _toggleSongSelection(id)
                              : () {
                                  _playSongs(startIndex: index);
                                },
                        ),
                      );
                    },
                    childCount: songs.length,
                  ),
                ),
              );
            },
          ),

          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 40),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 12),

                  if (otherAlbumsByArtist.isNotEmpty) ...[
                    AnimatedOpacity(
                      opacity: otherAlbumsReady ? 1 : 0,
                      duration: const Duration(milliseconds: 250),
                      curve: Curves.easeOut,
                      child: _buildRecommendationRow(
                        title: "Other Albums by ${_mainArtistName ?? "This Artist"}",
                        // Card width (150) + the same tuned label-block
                        // allowance the Music screen's own album grid
                        // uses (_squareCardLabelHeight = 48: 8px gap +
                        // one title line + one subtitle line) instead
                        // of a flat 250 that left a big empty gap below
                        // every card's label.
                        height: 198,
                        items: otherAlbumsByArtist,
                        itemBuilder: (context, index) {
                          final album = otherAlbumsByArtist[index];
                          // TV gets the same kind of dedicated bump
                          // Home's own rows use (Responsive.isTV ? bigger
                          // : base) instead of only the generic landscape
                          // x1.08 widening rowItemWidth applies — without
                          // this, these rows render visibly smaller than
                          // Home's rows on a real TV for the same kind of
                          // content.
                          final cardWidth = Responsive.isTV
                              ? 210.0
                              : Responsive.rowItemWidth(context, 150);
                          return SizedBox(
                            width: cardWidth,
                            child: AlbumCard(
                              album: album,
                              decodeWidth: cardWidth,
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
                    ),
                    const SizedBox(height: 24),
                  ],

                  if (similar.isNotEmpty) ...[
                    AnimatedOpacity(
                      opacity: similarReady ? 1 : 0,
                      duration: const Duration(milliseconds: 250),
                      curve: Curves.easeOut,
                      child: _buildRecommendationRow(
                        title: "More Like This",
                        // Same tuned card-width(150) + label-block(48)
                        // allowance as the "Other Albums by <Artist>"
                        // row above and the Music screen's own album
                        // grid — no leftover blank space under the
                        // label.
                        height: 198,
                        items: similar,
                        itemBuilder: (context, index) {
                          final album = similar[index];
                          // Same TV-specific bump as the "Other Albums by
                          // <Artist>" row above, for the same reason.
                          final cardWidth = Responsive.isTV
                              ? 210.0
                              : Responsive.rowItemWidth(context, 150);
                          return SizedBox(
                            width: cardWidth,
                            child: AlbumCard(
                              album: album,
                              decodeWidth: cardWidth,
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
                    ),
                  ],

                  const SizedBox(height: 40),

                  // The main nav's bottom bar (mini player + tab bar)
                  // floats over this screen in a plain Stack, not a real
                  // Scaffold.extendBody (see MainNavScreen's own doc
                  // comment) — MediaQuery's bottom padding here is only
                  // ever the safe-area inset, so BottomClearance.of adds
                  // the bar's actual current height back in, reactively,
                  // or the last row would scroll to a stop behind it.
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
          ),

        ],

      ),
        ),
        ),

          if (_songSelect.active)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                bottom: false,
                child: Container(
                  color: const Color(0xf2161616),
                  child: SongSelectionBar(
                    count: _songSelect.count,
                    busy: _songSelect.busy,
                    onClose: _exitSongSelection,
                    onPlaySelected: _playSelectedSongs,
                    onAddToQueue: _bulkAddSelectedSongsToQueue,
                    onDownload: _bulkDownloadSelectedSongs,
                    onAddToPlaylist: _bulkAddSelectedSongsToPlaylist,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }


  Widget _buildPlaylistPage(BuildContext context) {

    final firstSongArt = _firstSongArtworkUrl();

    return Scaffold(

      backgroundColor: const Color(0xff161616),

      body: Stack(
        children: [
          // Landscape only: full-bleed blurred backdrop sitting behind
          // the *entire* page (header + scrolling content alike), same
          // treatment the album/artist detail screens' landscape
          // layouts use — this is what lets the header blend straight
          // into the rest of the screen with no seam between them.
          // Portrait keeps its own per-header backdrop below, untouched.
          if (Responsive.isLandscape(context))
            LandscapeBackdropBackground(
              // Same rotating pool the portrait header's expanded
              // artwork cycles through — falls back to the first
              // song's art (then the playlist's own image) until the
              // pool/timer has kicked in.
              backdropUrl: _playlistBackdropUrl ??
                  firstSongArt ??
                  MediaService.getMusicImage(widget.itemId, size: 500),
            ),
          // Portrait only: the header backdrop is painted here, behind the
          // scroll view, instead of inside CollapsingDetailHeader's
          // expandedBuilder. ROOT CAUSE: the icon block sits in the
          // content slivers directly under the header, so for it to
          // overlap the backdrop (like the poster on the movie detail
          // screen) the backdrop has to reach below the header's bottom
          // edge — and a viewport paints its first sliver LAST, so a
          // taller/overflowing header would cover the icon rather than
          // sit under it (and a taller header would push all the content
          // down). Behind the scroll view the header keeps its exact
          // height and the content paints on top. See
          // ScrollLinkedDetailBackdrop.
          if (!Responsive.isLandscape(context))
            ScrollLinkedDetailBackdrop(
              scrollOffset: _heroScrollOffset,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _buildPlaylistArtworkBackdrop(),

                  Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.transparent,
                          Colors.black.withValues(alpha: .45),
                          const Color(0xff161616),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ResistiveRefresh(
            onRefresh: loadData,
            color: const Color(0xffD4AF37),
            backgroundColor: const Color(0xff232323),
            child: FadeScrollbar(
            controller: _playlistScrollController,
            // Matches CollapsingDetailHeader's own collapsed-bar height
            // (topPadding + 56) so the thumb's track starts right below
            // the pinned top bar instead of running under it.
            topInset: MediaQuery.paddingOf(context).top + 56,
            child: ScrollOffsetReporter(
            offset: _heroScrollOffset,
            child: CustomScrollView(
              controller: _playlistScrollController,

        // A short tracklist/filmography doesn't overflow the
        // viewport, which otherwise leaves the pull gesture with
        // nothing to grab onto.
        physics: const AlwaysScrollableScrollPhysics(),
        // Build song rows (and so start their artwork) a screen-height
        // ahead of the viewport so art is ready before a row scrolls
        // into view instead of arriving after its text.
        cacheExtent: MediaQuery.sizeOf(context).height,
        slivers: [

          CollapsingDetailHeader(
            // See the artist page's identical header for why landscape
            // gets this thin, non-hero height instead of a portrait-
            // style hero height.
            expandedHeight: Responsive.isLandscape(context)
                ? MediaQuery.paddingOf(context).top + 60
                : kDetailHeaderHeight,
            onBack: _handleBack,
            // Playlists never have art of their own — same as the body
            // backdrop below, the collapsed bar's color comes from the
            // first track's artwork.
            accentImageUrl:
                firstSongArt ?? MediaService.getMusicImage(widget.itemId, size: 500),
            // Landscape stays fully transparent here — the page-wide
            // backdrop added above the scroll view already covers this
            // header, so painting another copy (or a gradient down to a
            // flat page color) would just recreate the seam this was
            // meant to remove. Portrait now does the same: its backdrop is
            // ScrollLinkedDetailBackdrop (added above the scroll view), so
            // this header only paints the pinned bar / back button.
            expandedBuilder: (context, t) => const SizedBox.shrink(),
          ),

          TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: contentReady ? 1.0 : 0.0),
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
            builder: (context, opacity, _) => SliverOpacity(
              opacity: opacity,
              sliver: SliverMainAxisGroup(
                slivers: [
          SliverToBoxAdapter(

            child: Padding(

              padding: const EdgeInsets.fromLTRB(
                24,
                24,
                24,
                0,
              ),

              child: Column(

                crossAxisAlignment: CrossAxisAlignment.start,

                children: [

                  MusicLandscapeHeader(
                      icon: PlaylistCoverArt(
                        playlistId: widget.itemId,
                        size: 155,
                        borderRadius: 20,
                      ),
                      title: item?["Name"] ?? "",
                      metadataLine:
                          "${songs.length} Songs • ${getPlaylistDuration()}",
                      genres: _playlistGenres(),
                      onGenreTap: _openGenre,
                      actions: StackedActionBar(
                        horizontalPadding: 0,
                        playLabel: "Start Listening",
                        onPlay: () {
                          _playSongs();
                        },
                        actions: [
                          _stackedShuffle(),
                          // A device-only playlist has no server item to
                          // favorite, and Download All only covers server
                          // songs (on-device ones are already on the phone).
                          if (!_isLocalPlaylist) _stackedFavorite(),
                          if (_serverSongs.isNotEmpty)
                            _DownloadAllButton(
                              songs: _serverSongs,
                              stacked: true,
                            ),
                        ],
                      ),
                      stackedActions: true,
                    ),
                  const SizedBox(height: 30),

                  if ((item?["Overview"] ?? "").toString().isNotEmpty) ...[

                    _readableOverviewWidth(
                      OverviewSection(
                        overview: item!["Overview"],
                        horizontalPadding: 0,
                        fontSize: null,
                      ),
                    ),

                    const SizedBox(height: 32),

                  ]
                  else ...[
                    Text(
                      "A collection of ${songs.length} carefully selected songs ready to play anytime.",
                      style: const TextStyle(
                        color: Colors.white60,
                        height: 1.7,
                        fontSize: 15,
                      ),
                    ),

                    const SizedBox(height: 28),
                  ],



                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      const Text(
                        "Songs",
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 26,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        "${songs.length} songs",
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 2),
                ],

              ),

            ),

          ),

          /// Song list as a real sliver — only builds rows that are
          /// actually visible, instead of shrink-wrapping the whole list.
          /// This is the page most likely to hold hundreds/thousands of
          /// tracks, so this was the worst offender for jank.
          ValueListenableBuilder<MediaItem?>(
            valueListenable: PlayerManager.instance.currentItemNotifier,
            builder: (context, currentItem, _) {
              return SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                sliver: SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      final song = songs[index];
                      final id = song["Id"].toString();
                      final selected = _songSelect.isSelected(id);

                      return Padding(
                        padding: EdgeInsets.only(
                          bottom: index == songs.length - 1 ? 0 : 6,
                        ),
                        child: SongRow(
                          song: song,
                          playing: currentItem != null &&
                              currentItem.id == song["Id"],
                          showDownloadStatus: true,
                          playlistId: widget.itemId,
                          onRemovedFromPlaylist: () {
                            setState(() {
                              songs.remove(song);
                            });
                          },
                          // "Remove from App" on an on-device row in
                          // the three-dot menu: it's gone from every
                          // playlist too, so drop the row right away.
                          onRemovedFromApp: () {
                            setState(() {
                              songs.remove(song);
                            });
                          },
                          selectionMode: _songSelect.active,
                          selected: selected,
                          onLongPress: _songSelect.active
                              ? null
                              : () => _enterSongSelection(id),
                          onTap: _songSelect.active
                              ? () => _toggleSongSelection(id)
                              : () {
                                  _playSongs(startIndex: index);
                                },
                        ),
                      );
                    },
                    childCount: songs.length,
                  ),
                ),
              );
            },
          ),

          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 40),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 12),

                  if (similar.isNotEmpty) ...[
                    AnimatedOpacity(
                      opacity: similarReady ? 1 : 0,
                      duration: const Duration(milliseconds: 250),
                      curve: Curves.easeOut,
                      child: _buildRecommendationRow(
                        title: "Recommended Playlists",
                        // Card width (150) + just enough for the
                        // single name line PlaylistCard shows here
                        // (showSongCount: false drops the second
                        // line/subtitle these recommendation cards
                        // don't need) — same tight-fit approach as the
                        // album rows above, just sized for one line of
                        // label instead of two.
                        height: 180,
                        items: similar,
                        itemBuilder: (context, index) {
                          final playlist = similar[index];
                          // Same TV-specific bump as the album/artist
                          // recommendation rows above.
                          final cardWidth = Responsive.isTV
                              ? 210.0
                              : Responsive.rowItemWidth(context, 150);
                          return SizedBox(
                            width: cardWidth,
                            child: PlaylistCard(
                              playlist: playlist,
                              showSongCount: false,
                              onTap: () {
                                Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) => MusicDetailScreen(
                                      itemId: playlist["Id"],
                                      initialItem: Map<String, dynamic>.from(playlist),
                                    ),
                                  ),
                                );
                              },
                            ),
                          );
                        },
                      ),
                    ),
                  ],

                  const SizedBox(height: 40),

                  // The main nav's bottom bar (mini player + tab bar)
                  // floats over this screen in a plain Stack, not a real
                  // Scaffold.extendBody (see MainNavScreen's own doc
                  // comment) — MediaQuery's bottom padding here is only
                  // ever the safe-area inset, so BottomClearance.of adds
                  // the bar's actual current height back in, reactively,
                  // or the last row would scroll to a stop behind it.
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
          ),

        ],

      
            ),
            ),
          ),
        ),

          if (_songSelect.active)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                bottom: false,
                child: Container(
                  color: const Color(0xf2161616),
                  child: SongSelectionBar(
                    count: _songSelect.count,
                    busy: _songSelect.busy,
                    onClose: _exitSongSelection,
                    onPlaySelected: _playSelectedSongs,
                    onAddToQueue: _bulkAddSelectedSongsToQueue,
                    // Playlists can hold on-device songs, which have
                    // nothing to download — with any of them selected
                    // Download is dropped. The delete slot always means
                    // "Remove from Playlist" here (it handles both
                    // server entries and on-device ones); removing an
                    // on-device song from the app entirely stays a
                    // per-song action in its three-dot menu, so this
                    // bar never shows two different remove buttons.
                    onDownload: songsContainLocal(_selectedSongs)
                        ? null
                        : _bulkDownloadSelectedSongs,
                    onAddToPlaylist: _bulkAddSelectedSongsToPlaylist,
                    onDelete: _bulkRemoveSelectedSongsFromPlaylist,
                    deleteLabel: "Remove from Playlist",
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // Title gets its own horizontal padding, and the ListView carries its
  // *own* `padding` rather than being wrapped by an outer horizontally-
  // padded Column (see the three call sites above). That's what lets the
  // row scroll all the way to the true screen edge — matching how
  // ContentRow ("More Like This" on the movie details screen) already
  // behaves — instead of stopping short at wherever the outer padding
  // used to sit.
  // Overview is a plain paragraph inside a Padding(24,24,24,0) column
  // that otherwise stretches edge-to-edge — fine on phones/tablets
  // (well under this cap already), but on a 1920/3840-wide TV that
  // makes for an unreadably long line length with no other content
  // sharing the row. Capping only kicks in once the available width
  // actually exceeds it, so nothing already tuned for Pixel 6 or
  // tablets changes.
  //
  // Left-aligned rather than centered: the "Songs" heading (and every
  // other block in this column) is left-aligned at the column's own
  // edge. Centering the capped-width box only coincidentally lined up
  // with that edge on narrow screens where the 700px cap never
  // actually engaged; anywhere wider (tablets, TV, landscape) it left
  // the overview paragraph adrift in the middle of the row while
  // everything else stayed pinned to the left.
  Widget _readableOverviewWidth(Widget child) {
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 700),
        child: child,
      ),
    );
  }

  Widget _buildRecommendationRow({
    required String title,
    required double height,
    required List<dynamic> items,
    required Widget Function(BuildContext, int) itemBuilder,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 15),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Text(
            title,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 24,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        const SizedBox(height: 18),
        SizedBox(
          height: height,
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            scrollDirection: Axis.horizontal,
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(width: 14),
            itemBuilder: itemBuilder,
          ),
        ),
      ],
    );
  }

}

/// "Download everything currently shown" control for an artist/album/
/// playlist header — reflects the aggregate state of every song in
/// [songs]: a plain download icon when none are downloaded, a progress
/// ring while a batch is in flight, and a filled checkmark once every
/// track is downloaded. Downloads run one at a time to avoid hammering
/// the server with dozens of simultaneous requests.
class _DownloadAllButton extends StatefulWidget {
  final List songs;

  /// Stacked action bar mode: no circle around the icon, and a state label
  /// ("Download" / "Downloading" / "Downloaded") underneath.
  final bool stacked;

  const _DownloadAllButton({required this.songs, this.stacked = false});

  @override
  State<_DownloadAllButton> createState() => _DownloadAllButtonState();
}

class _DownloadAllButtonState extends State<_DownloadAllButton> {
  /// Opens the "Download Quality" sheet (the same Original / 320 / 256 /
  /// 192 / 128 kbps choices a single song's Download dropdown offers, with
  /// the total size of all [songs] per quality). Picking a row there
  /// enqueues every not-yet-downloaded song in that quality —
  /// DownloadManager's own queue (2 at a time) takes it from there.
  void _downloadAll() {
    showSongsDownloadQualitySheet(context, widget.songs);
  }

  void _cancelAll() {
    for (final song in widget.songs) {
      final id = song["Id"]?.toString();
      if (id == null) continue;
      if (DownloadManager.instance.taskFor(id) != null) {
        DownloadManager.instance.cancelDownload(id);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: DownloadManager.instance,
      builder: (context, _) {
        final songs = widget.songs;
        final ids = songs
            .map((s) => s["Id"]?.toString())
            .whereType<String>()
            .toList();
        final aggregate = DownloadManager.instance.aggregateFor(ids);

        // Same transparent bordered-circle treatment DownloadButton
        // (movie/series/collection detail screens) uses, so the
        // download control looks identical everywhere in the app —
        // only the underlying logic differs (aggregate over several
        // songs here, vs. a single item there). Completed reuses the
        // same DeviceCheckBadge (cellphone + gold tick) DownloadButton
        // and the Downloads screen both show for a finished item.
        final Widget control;
        final String label;

        if (aggregate.isComplete) {
          label = "Downloaded";
          control = _DownloadCircle(
            bordered: !widget.stacked,
            child: const DeviceCheckBadge(size: 26),
          );
        } else if (aggregate.activeOrQueued > 0) {
          final liveFraction = aggregate.activeProgress != null
              ? (aggregate.completed + aggregate.activeProgress!) /
                  aggregate.total
              : aggregate.fraction;

          // The same progress ring (with stop square) song rows and the
          // Downloads screen use for a single transfer, here showing
          // the whole batch's combined progress. Tapping it stops the
          // songs of this list that haven't finished yet; ones already
          // downloaded stay.
          label = "Downloading";
          control = _DownloadCircle(
            bordered: !widget.stacked,
            child: DownloadStopRing(
              size: 26,
              progress: liveFraction.clamp(0.0, 1.0).toDouble(),
              onCancel: _cancelAll,
            ),
          );
        } else {
          label = "Download";
          control = _DownloadCircle(
            bordered: !widget.stacked,
            icon: Icons.download_outlined,
            iconColor: Colors.white,
            onPressed: songs.isEmpty ? null : _downloadAll,
          );
        }

        if (!widget.stacked) return control;
        return StackedActionBar.item(
          icon: Center(child: control),
          label: StackedActionBar.labelText(label),
        );
      },
    );
  }
}

/// Transparent bordered circle used for every state of the "download
/// all" control — same shape/border DownloadButton renders inside on
/// the movie/series/collection detail screens (there, the border
/// comes from the Container action_buttons.dart wraps it in; here
/// the control draws its own, since nothing external wraps it), so
/// the download button looks identical across every detail screen.
/// Pass either [icon]/[iconColor]/[onPressed] for a plain glyph state,
/// or [child] directly for the in-progress ring.
class _DownloadCircle extends StatelessWidget {
  final IconData? icon;
  final Color? iconColor;
  final VoidCallback? onPressed;
  final Widget? child;

  /// False in the stacked action bar, where the icon sits on the page
  /// background with no circle around it.
  final bool bordered;

  const _DownloadCircle({
    this.icon,
    this.iconColor,
    this.onPressed,
    this.child,
    this.bordered = true,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 48,
      height: 48,
      decoration: bordered
          ? BoxDecoration(
              border: Border.all(color: Colors.white.withOpacity(.12)),
              shape: BoxShape.circle,
            )
          : null,
      child: child != null
          ? Center(child: child)
          : IconButton(
              onPressed: onPressed,
              icon: Icon(icon, color: iconColor),
            ),
    );
  }
}
