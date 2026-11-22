import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../player/player_manager.dart';
import '../../player/services/playback_queue.dart';
import '../../screens/main_nav/navigation_controller.dart';
import '../../screens/music/music_detail_screen.dart';
import '../../services/download_manager.dart';
import '../../services/jellyfin_services/media_service.dart';
import '../../services/local_music_service.dart';
import '../../services/local_playlist_service.dart';
import '../../services/sleep_timer_service.dart';
import '../shared/nemesis_bottom_sheet.dart';
import 'playlist_picker_sheet.dart';
import '../../services/cache/nemesis_image_cache.dart';
import '../common/dustbin_icon.dart';

const _gold = Color(0xffD4AF37);

/// Shows the three-dot menu for a song row: add to playlist, add to
/// queue, download, and jump to the song's album/artist(s).
///
/// Uses the root navigator (see guide_program_tile's showProgramDetailsSheet
/// for the same reasoning) since song rows live inside the tab's nested
/// content Navigator, underneath the app's floating bottom nav bar/mini
/// player — without this the sheet would render behind them instead of
/// covering them.
void showSongOptionsSheet(
  BuildContext context,
  Map song, {
  bool showGoToAlbum = true,
  String? excludeArtistId,
  String? playlistId,
  VoidCallback? onRemovedFromPlaylist,
  VoidCallback? onRemovedFromApp,
  // NAV-CHROME FIX: song rows all live somewhere inside MainNavScreen's
  // content Navigator (a tab itself, or a detail screen already pushed
  // onto it), so "Go to Album"/"Go to Artist" pushing onto that same
  // content Navigator is all they ever need — the bottom nav bar/mini
  // player are already part of that Navigator's own chrome, and a
  // normal back pop already lands back exactly where the row was.
  //
  // The full-screen audio player is the one caller that ISN'T inside
  // that subtree — it's a route stacked on the app's root Navigator,
  // above MainNavScreen entirely, which is why its own "Go to Album/
  // Artist" used to open a detail screen with no nav bar/mini player at
  // all. Passing this callback (non-null) tells the sheet to dismiss
  // the full-screen player first — so the content Navigator's chrome
  // has something to actually show underneath the pushed detail screen
  // — and to call this to put the player back exactly where the user
  // left it the moment they back out of that screen, so the round trip
  // is invisible to them.
  VoidCallback? restoreFullScreenPlayer,
  // Sleep timer row — only offered from the full-screen audio player
  // (it controls whatever is playing, not the song this sheet was
  // opened for, so it makes no sense from a song row).
  bool showSleepTimer = false,
}) {
  // Same chrome as the video player's Info sheet (see
  // showNemesisBottomSheet's doc comment) — rounded top corners, drag
  // handle, drag up/down to resize, tap-outside/back-gesture/drag-down
  // to close.
  showNemesisBottomSheet<void>(
    context,
    initialChildSize: 0.5,
    minChildSize: 0.3,
    maxChildSize: 0.9,
    builder: (sheetContext, scrollController) => _SongOptionsSheet(
      song: song,
      showGoToAlbum: showGoToAlbum,
      excludeArtistId: excludeArtistId,
      playlistId: playlistId,
      onRemovedFromPlaylist: onRemovedFromPlaylist,
      onRemovedFromApp: onRemovedFromApp,
      restoreFullScreenPlayer: restoreFullScreenPlayer,
      showSleepTimer: showSleepTimer,
      scrollController: scrollController,
    ),
  );
}

class _SongOptionsSheet extends StatefulWidget {
  const _SongOptionsSheet({
    required this.song,
    this.showGoToAlbum = true,
    this.excludeArtistId,
    this.playlistId,
    this.onRemovedFromPlaylist,
    this.onRemovedFromApp,
    this.restoreFullScreenPlayer,
    this.showSleepTimer = false,
    this.scrollController,
  });

  final Map song;
  final bool showGoToAlbum;
  final String? excludeArtistId;
  final String? playlistId;
  final VoidCallback? onRemovedFromPlaylist;
  final VoidCallback? onRemovedFromApp;
  final VoidCallback? restoreFullScreenPlayer;
  final bool showSleepTimer;
  final ScrollController? scrollController;

  @override
  State<_SongOptionsSheet> createState() => _SongOptionsSheetState();
}

class _SongOptionsSheetState extends State<_SongOptionsSheet> {
  String get _songId => widget.song["Id"].toString();

  String get _songName => widget.song["Name"]?.toString() ?? "";

  bool get _isLocalSong => widget.song["IsLocal"] == true;

  // Local copy of favorite state so the tile can flip immediately on
  // tap without waiting on a round trip, same optimistic-then-confirm
  // pattern PlayerManager.toggleFavorite already uses for the
  // full-player heart button.
  late bool _isFavorite =
      widget.song["UserData"]?["IsFavorite"] == true;

  Future<void> _toggleFavorite(BuildContext context) async {
    final wasFavorite = _isFavorite;
    setState(() => _isFavorite = !wasFavorite);

    // Local songs have no server-side favorite concept — they're
    // tracked entirely in LocalMusicService instead of via
    // MediaService's Jellyfin call, and that toggle can't fail the way
    // a network request can, so there's nothing to roll back here.
    if (_isLocalSong) {
      await LocalMusicService.instance.toggleFavorite(_songId);
      widget.song["UserData"] = {
        ...(widget.song["UserData"] as Map? ?? {}),
        "IsFavorite": !wasFavorite,
      };
      return;
    }

    final messenger = ScaffoldMessenger.maybeOf(context);

    try {
      await MediaService.toggleFavorite(_songId, wasFavorite);

      // Keeps the song's own map in sync so anything else already
      // holding a reference to it (the row this sheet was opened from,
      // an in-memory list on whichever screen pushed it) reflects the
      // change too, rather than only this sheet's local state —
      // without this, closing the sheet and reopening it against the
      // same list would show the old, stale favorite state.
      widget.song["UserData"] = {
        ...(widget.song["UserData"] as Map? ?? {}),
        "IsFavorite": !wasFavorite,
      };
    } catch (e) {
      if (!mounted) return;
      setState(() => _isFavorite = wasFavorite);
      messenger?.showSnackBar(
        const SnackBar(content: Text("Couldn't update favorite")),
      );
    }
  }

  Future<void> _removeFromApp(BuildContext context) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    Navigator.pop(context);

    await LocalMusicService.instance.removeFromApp(_songId);
    widget.onRemovedFromApp?.call();

    messenger?.showSnackBar(
      SnackBar(content: Text('Removed "$_songName" from the app')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final song = widget.song;
    final isLocal = _isLocalSong;
    final artworkPath = isLocal ? song["ArtworkPath"] as String? : null;

    final albumId = song["AlbumId"]?.toString();
    // Local files have no Jellyfin album/artist to jump to at all —
    // "Go to Album"/"Go to Artist" are excluded outright rather than
    // just happening to have nothing to show, since a local song's map
    // never carries AlbumId/ArtistItems in the first place.
    final hasAlbum = !isLocal &&
        widget.showGoToAlbum &&
        albumId != null &&
        albumId.isNotEmpty;

    final artistItems = (!isLocal && song["ArtistItems"] is List)
        ? (song["ArtistItems"] as List)
        .whereType<Map>()
        .where((a) =>
            a["Id"] != null &&
            a["Name"] != null &&
            a["Id"].toString() != widget.excludeArtistId)
        .toList()
        : <Map>[];

    return ListView(
        controller: widget.scrollController,
        children: [
          const NemesisSheetDragHandle(topMargin: 10, bottomMargin: 8),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: isLocal
                      ? (artworkPath != null
                          ? Image.file(
                              File(artworkPath),
                              width: 46,
                              height: 46,
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => Container(
                                width: 46,
                                height: 46,
                                color: const Color(0xff2a2a2a),
                                child: const Icon(
                                  Icons.music_note,
                                  color: Colors.white24,
                                ),
                              ),
                            )
                          : Container(
                              width: 46,
                              height: 46,
                              color: const Color(0xff2a2a2a),
                              child: const Icon(
                                Icons.music_note,
                                color: Colors.white24,
                              ),
                            ))
                      : CachedNetworkImage(
                          cacheManager: NemesisImageCache.instance,
                          imageUrl: MediaService.getMusicImage(_songId, size: 100),
                          width: 46,
                          height: 46,
                          fit: BoxFit.cover,
                          memCacheWidth:
                          (46 * MediaQuery.devicePixelRatioOf(context)).round(),
                          memCacheHeight:
                          (46 * MediaQuery.devicePixelRatioOf(context)).round(),
                          placeholder: (_, __) => Container(
                            width: 46,
                            height: 46,
                            color: const Color(0xff2a2a2a),
                          ),
                          errorWidget: (_, __, ___) => Container(
                            width: 46,
                            height: 46,
                            color: const Color(0xff2a2a2a),
                            child: const Icon(
                              Icons.music_note,
                              color: Colors.white24,
                            ),
                          ),
                        ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _songName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),

          const Divider(color: Colors.white12, height: 1),

          ListTile(
            leading: Icon(
              _isFavorite ? Icons.favorite : Icons.favorite_border,
              color: _isFavorite ? Colors.red : Colors.white70,
            ),
            title: Text(
              _isFavorite ? "Remove from Favorites" : "Add to Favorites",
              style: const TextStyle(color: Colors.white),
            ),
            onTap: () => _toggleFavorite(context),
          ),

          // On-device songs can go into playlists too — a Jellyfin
          // playlist can't hold them, so the picker records them in the
          // app's own storage (see LocalPlaylistService). "Download" is
          // the only action that still has no meaning for something
          // already on the device (handled further down).
          ListTile(
            leading: const Icon(Icons.playlist_add, color: Colors.white70),
            title: const Text(
              "Add to Playlist",
              style: TextStyle(color: Colors.white),
            ),
            onTap: () {
              // Capture the outer (root) navigator before popping this
              // sheet — reusing `context` after pop() risks looking up
              // an ancestor on an about-to-be-deactivated element, so
              // the next sheet is opened via the already-resolved
              // NavigatorState/its context instead.
              final rootNavContext =
                  Navigator.of(context, rootNavigator: true).context;
              Navigator.pop(context);
              showPlaylistPickerSheet(rootNavContext, song);
            },
          ),

          ListTile(
            leading: const Icon(Icons.queue_music, color: Colors.white70),
            title: const Text(
              "Add to Queue",
              style: TextStyle(color: Colors.white),
            ),
            onTap: () => _addToQueue(context, song),
          ),

          if (widget.showSleepTimer) const _SleepTimerTile(),

          if (widget.playlistId != null)
            ListTile(
              leading: const DustbinIcon(color: Colors.white70),
              title: const Text(
                "Remove from Playlist",
                style: TextStyle(color: Colors.white),
              ),
              onTap: () => _removeFromPlaylist(context, song),
            ),

          if (isLocal)
            ListTile(
              leading: const DustbinIcon(color: Colors.redAccent),
              title: const Text(
                "Remove from App",
                style: TextStyle(color: Colors.white),
              ),
              subtitle: const Text(
                "Doesn't delete the file from your device",
                style: TextStyle(color: Colors.white38, fontSize: 12),
              ),
              onTap: () => _removeFromApp(context),
            )
          else
            _DownloadTile(song: song),

          if (hasAlbum || artistItems.isNotEmpty)
            const Divider(color: Colors.white12, height: 1),

          if (hasAlbum)
            ListTile(
              leading: const Icon(Icons.album, color: Colors.white70),
              title: Text(
                "Go to ${song["Album"] ?? "Album"}",
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white),
              ),
              onTap: () => _goToDetail(
                context,
                () => MusicDetailScreen(
                  itemId: albumId,
                  initialItem: {
                    "Id": albumId,
                    "Name": song["Album"],
                    "Type": "MusicAlbum",
                  },
                ),
              ),
            ),

          for (final artist in artistItems)
            ListTile(
              leading: const Icon(Icons.person, color: Colors.white70),
              title: Text(
                "Go to ${artist["Name"]}",
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white),
              ),
              onTap: () => _goToDetail(
                context,
                () => MusicDetailScreen(
                  itemId: artist["Id"].toString(),
                  initialItem: Map<String, dynamic>.from(artist),
                ),
              ),
            ),

          const SizedBox(height: 8),
        ],
      );
  }

  // Shared by "Go to Album" and "Go to Artist" — see
  // showSongOptionsSheet's doc comment on restoreFullScreenPlayer for
  // why the two cases (song row vs. full-screen player) need different
  // handling here.
  void _goToDetail(BuildContext context, Widget Function() buildDetail) {
    final restore = widget.restoreFullScreenPlayer;
    // Only meaningful when restore != null (the full-screen-player
    // case) — captured before popping the sheet since `context` is
    // this sheet's own, and it's about to start deactivating.
    final rootNavigator = Navigator.of(context, rootNavigator: true);

    Navigator.pop(context);

    if (restore != null) {
      // Clears the full-screen player (and anything stacked on top of
      // it, e.g. Lyrics) off the root Navigator so MainNavScreen — and
      // the content Navigator's chrome underneath it — is what's
      // actually on screen when the detail page below gets pushed.
      rootNavigator.popUntil((route) => route.isFirst);
      NavigationController.instance.pushOnContent(
        MaterialPageRoute(
          builder: (_) => _RestoreOnBack(
            onBack: restore,
            child: buildDetail(),
          ),
        ),
      );
    } else {
      NavigationController.instance.pushOnContent(
        MaterialPageRoute(builder: (_) => buildDetail()),
      );
    }
  }

  Future<void> _addToQueue(BuildContext context, Map song) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    Navigator.pop(context);

    // Nothing playing yet — "next song" has no meaning without a current
    // song to follow. Rather than silently starting playback on the
    // user's behalf, tell them to start something first.
    if (PlayerManager.instance.currentItem == null) {
      messenger?.showSnackBar(
        const SnackBar(
          content: Text("Play something first to add songs to the queue"),
        ),
      );
      return;
    }

    final songMap = Map<String, dynamic>.from(song);
    final item = songMap["IsLocal"] == true
        ? LocalMusicService.mediaItemFromLocalSong(songMap)
        : MediaService.mediaItemFromJellyfin(songMap);

    PlaybackQueue.instance.addNext(item);
    messenger?.showSnackBar(
      SnackBar(content: Text('Added "${song["Name"] ?? ""}" to queue')),
    );
  }

  Future<void> _removeFromPlaylist(BuildContext context, Map song) async {
    final playlistId = widget.playlistId;
    if (playlistId == null) return;

    final messenger = ScaffoldMessenger.maybeOf(context);
    Navigator.pop(context);

    // "PlaylistItemId" identifies this specific entry within the
    // playlist (not the song itself) — falling back to the song's own
    // id only if that's somehow missing, since it's the best next
    // guess for a server that doesn't return it.
    final entryId = song["PlaylistItemId"]?.toString() ?? _songId;

    try {
      if (_isLocalSong) {
        // On-device songs were never sent to the server, so there's no
        // PlaylistItemId (or server entry) to delete — they only exist
        // in the app's own playlist storage.
        await LocalPlaylistService.instance.removeSongs(playlistId, [_songId]);
      } else {
        await MediaService.removeFromPlaylist(playlistId, entryId);
      }
      widget.onRemovedFromPlaylist?.call();
      messenger?.showSnackBar(
        SnackBar(content: Text('Removed "${song["Name"] ?? ""}" from playlist')),
      );
    } catch (e) {
      messenger?.showSnackBar(
        const SnackBar(content: Text('Failed to remove from playlist')),
      );
    }
  }
}

/// Wraps a detail screen pushed onto the content Navigator from the
/// full-screen player's "Go to Album"/"Go to Artist" (see
/// _SongOptionsSheetState._goToDetail). A plain back press here would
/// just pop and reveal whatever tab happens to be underneath on the
/// content Navigator — not where the user actually came from — so this
/// intercepts it instead: pop this screen off the content Navigator,
/// then call [onBack] to put the full-screen player back on the root
/// Navigator, restoring exactly what was on screen before "Go to
/// Album/Artist" was tapped.
class _RestoreOnBack extends StatelessWidget {
  const _RestoreOnBack({required this.child, required this.onBack});

  final Widget child;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvoked: (didPop) {
        if (didPop) return;
        Navigator.of(context).pop();
        onBack();
      },
      child: child,
    );
  }
}

class _DownloadTile extends StatefulWidget {
  const _DownloadTile({required this.song});

  final Map song;

  @override
  State<_DownloadTile> createState() => _DownloadTileState();
}

class _DownloadTileState extends State<_DownloadTile> {
  // Whether the quality dropdown under "Download" is open.
  bool _expanded = false;

  // Song lists don't always carry file size/bitrate (MediaSources); when
  // they don't, the full item is fetched once the first time the
  // dropdown opens — nothing is requested for a sheet that's only
  // opened to add something to a playlist.
  bool _loadingDetails = false;
  Map<String, dynamic>? _fetched;

  @override
  void initState() {
    super.initState();
    DownloadManager.instance.addListener(_onChanged);
  }

  @override
  void dispose() {
    DownloadManager.instance.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  bool get _songHasFileInfo {
    final sources = widget.song["MediaSources"];
    return sources is List &&
        sources.isNotEmpty &&
        sources.first is Map &&
        sources.first["Size"] is num;
  }

  /// The song as handed to DownloadManager: the original map, plus the
  /// file details it was missing if they had to be fetched. Besides
  /// feeding the size labels, MediaSources is what DownloadManager reads
  /// to give an original-quality file its real extension (.flac, not a
  /// default .mp3).
  Map<String, dynamic> _songWithFileInfo() {
    final merged = Map<String, dynamic>.from(widget.song);
    final fetched = _fetched;
    if (fetched != null) {
      for (final key in const ["MediaSources", "MediaStreams", "RunTimeTicks"]) {
        if (merged[key] == null && fetched[key] != null) {
          merged[key] = fetched[key];
        }
      }
    }
    return merged;
  }

  Future<void> _toggleOptions() async {
    final opening = !_expanded;
    setState(() => _expanded = opening);

    if (!opening || _songHasFileInfo || _fetched != null || _loadingDetails) {
      return;
    }

    setState(() => _loadingDetails = true);
    try {
      final full = await MediaService.getItem(widget.song["Id"].toString());
      if (!mounted) return;
      _fetched = full;
    } catch (_) {
      // Sizes simply stay unknown; every option still works.
    } finally {
      if (mounted) setState(() => _loadingDetails = false);
    }
  }

  void _startDownload(_QualityOption option) {
    DownloadManager.instance.downloadSong(
      _songWithFileInfo(),
      targetKbps: option.kbps,
    );

    final messenger = ScaffoldMessenger.maybeOf(context);
    final detail =
        option.kbps == null ? "Original" : "${option.kbps} kbps MP3";
    Navigator.pop(context);
    messenger?.showSnackBar(
      SnackBar(
        content: Text('Downloading "${widget.song["Name"] ?? ""}" ($detail)'),
      ),
    );
  }

  Widget _optionRow(_QualityOption option) {
    final details = <String>[
      if (option.bytes != null)
        _formatMb(option.bytes!, estimated: option.estimated),
      option.format,
    ];

    return ListTile(
      dense: true,
      // Lines the text up under "Download" (16 padding + 40 leading
      // width + 16 gap — ListTile's own defaults for the row above).
      contentPadding: const EdgeInsets.only(left: 72, right: 16),
      title: Row(
        children: [
          Flexible(
            child: Text(
              option.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white),
            ),
          ),
          if (option.bestQuality) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: const Color(0x26D4AF37),
                border: Border.all(color: _gold, width: 0.8),
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Text(
                "BEST QUALITY",
                style: TextStyle(
                  color: _gold,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.4,
                ),
              ),
            ),
          ],
        ],
      ),
      subtitle: Text(
        details.join(" · "),
        style: const TextStyle(color: Colors.white54, fontSize: 12),
      ),
      onTap: () => _startDownload(option),
    );
  }

  Widget _optionsPanel() {
    if (!_expanded) {
      return const SizedBox(width: double.infinity, height: 0);
    }

    if (_loadingDetails) {
      return const ListTile(
        dense: true,
        contentPadding: EdgeInsets.only(left: 72, right: 16),
        title: Row(
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2, color: _gold),
            ),
            SizedBox(width: 12),
            Text(
              "Checking file details…",
              style: TextStyle(color: Colors.white54, fontSize: 13),
            ),
          ],
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final option in _buildQualityOptions(_songWithFileInfo()))
          _optionRow(option),
      ],
    );
  }

  /// Same confirmation DownloadButton shows before deleting a finished
  /// download, then removes it from the device and closes the sheet.
  Future<void> _confirmRemove() async {
    final id = widget.song["Id"].toString();
    final name = widget.song["Name"]?.toString() ?? "This song";

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xff1E1E1E),
        title: const Text(
          'Remove download?',
          style: TextStyle(color: Colors.white),
        ),
        content: Text(
          '"$name" will be deleted from your device.',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'Remove',
              style: TextStyle(color: Colors.redAccent),
            ),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    await DownloadManager.instance.deleteDownload(id);

    if (!mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    Navigator.pop(context);
    messenger?.showSnackBar(
      SnackBar(content: Text('Removed download "$name"')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final id = widget.song["Id"].toString();
    final manager = DownloadManager.instance;

    final downloaded = manager.isDownloaded(id);
    final downloading = manager.isDownloading(id);
    final task = manager.taskFor(id);
    final waiting = task != null &&
        (task.state == DownloadState.queued ||
            task.state == DownloadState.paused);

    // A finished download offers "Remove download" instead of the
    // (now pointless) Download / Downloaded states.
    if (downloaded) {
      return ListTile(
        leading: const DustbinIcon(color: Colors.white70),
        title: const Text(
          "Remove download",
          style: TextStyle(color: Colors.white),
        ),
        onTap: _confirmRemove,
      );
    }

    final busy = downloading || waiting;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListTile(
          leading: downloading
              ? const SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: _gold,
            ),
          )
              : const Icon(Icons.download, color: Colors.white70),
          title: Text(
            downloading
                ? "Downloading…"
                : waiting
                ? "Waiting to download…"
                : "Download",
            style: const TextStyle(color: Colors.white),
          ),
          trailing: busy
              ? null
              : Icon(
            _expanded ? Icons.expand_less : Icons.expand_more,
            color: Colors.white54,
          ),
          // Tapping Download opens the quality choices instead of
          // starting immediately; picking one starts the download.
          onTap: busy ? null : _toggleOptions,
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          alignment: Alignment.topCenter,
          child: busy
              ? const SizedBox(width: double.infinity, height: 0)
              : _optionsPanel(),
        ),
      ],
    );
  }
}

/// One row of the download-quality dropdown.
class _QualityOption {
  const _QualityOption({
    required this.kbps,
    required this.title,
    required this.format,
    required this.bytes,
    required this.estimated,
    required this.bestQuality,
  });

  /// Target MP3 bitrate, or null for the original file untouched.
  final int? kbps;
  final String title;
  final String format;
  final int? bytes;

  /// True when [bytes] is a bitrate x duration guess rather than a real
  /// file size (always so for converted MP3s, whose size isn't known
  /// until the server has finished encoding them).
  final bool estimated;

  /// Only the original file, and only when it really is lossless.
  final bool bestQuality;
}

const _lowerQualities = [320, 256, 192, 128];

const _knownAudioFormats = {
  'flac', 'mp3', 'm4a', 'aac', 'ogg', 'opus', 'wav', 'wma', 'alac', //
  'aiff', 'ape', 'wv', 'mka', 'webma',
};

const _losslessCodecs = {'flac', 'alac', 'ape', 'wavpack', 'tta'};

/// Builds the dropdown's rows from whatever Jellyfin told us about the
/// song's file: Original first (real bitrate, size and format), then the
/// MP3 conversions. A lossy original skips conversions at or above its
/// own bitrate — re-encoding a 192 kbps MP3 "to 320" or "to 192" can only
/// make it bigger or worse, never better.
List<_QualityOption> _buildQualityOptions(Map song) {
  final sources = song["MediaSources"];
  final Map? source =
  (sources is List && sources.isNotEmpty && sources.first is Map)
      ? sources.first as Map
      : null;

  Map? audioStream;
  final streams = source?["MediaStreams"] ?? song["MediaStreams"];
  if (streams is List) {
    for (final stream in streams) {
      if (stream is Map && stream["Type"] == "Audio") {
        audioStream = stream;
        break;
      }
    }
  }

  final ticks = (song["RunTimeTicks"] as num?) ??
      (source?["RunTimeTicks"] as num?);
  final seconds = ticks != null ? ticks.toDouble() / 10000000 : 0.0;

  final sizeBytes = (source?["Size"] as num?)?.toInt() ?? 0;
  final hasSize = sizeBytes > 0;

  int? originalKbps;
  final bps = (audioStream?["BitRate"] as num?) ?? (source?["Bitrate"] as num?);
  if (bps != null && bps > 0) {
    originalKbps = (bps / 1000).round();
  } else if (hasSize && seconds > 0) {
    originalKbps = (sizeBytes * 8 / seconds / 1000).round();
  }

  final codec = (audioStream?["Codec"] ?? "").toString().toLowerCase();
  final container = (source?["Container"] ?? "").toString().toLowerCase();

  final lossless = _losslessCodecs.contains(codec) ||
      codec.startsWith("pcm") ||
      const {'flac', 'wav', 'aiff'}.contains(container);

  int? originalBytes;
  var originalBytesEstimated = false;
  if (hasSize) {
    originalBytes = sizeBytes;
  } else if (originalKbps != null && seconds > 0) {
    originalBytes = (originalKbps * 1000 / 8 * seconds).round();
    originalBytesEstimated = true;
  }

  final options = <_QualityOption>[
    _QualityOption(
      kbps: null,
      title: originalKbps != null ? "Original · $originalKbps kbps" : "Original",
      format: _originalFormat(container, codec),
      bytes: originalBytes,
      estimated: originalBytesEstimated,
      bestQuality: lossless,
    ),
  ];

  for (final kbps in _lowerQualities) {
    if (!lossless && originalKbps != null && kbps >= originalKbps) continue;

    options.add(
      _QualityOption(
        kbps: kbps,
        title: "$kbps kbps",
        format: "MP3",
        bytes: seconds > 0 ? (kbps * 1000 / 8 * seconds).round() : null,
        estimated: true,
        bestQuality: false,
      ),
    );
  }

  return options;
}

/// Display name for the original file's format. Jellyfin's `Container`
/// can be a comma-separated list for some files (e.g. an .m4a reports
/// "mov,mp4,m4a,..."), so pick the first entry that's an actual audio
/// format rather than showing the whole list.
String _originalFormat(String container, String codec) {
  final tokens = container
      .split(',')
      .map((t) => t.trim())
      .where((t) => t.isNotEmpty)
      .toList();

  for (final token in tokens) {
    if (_knownAudioFormats.contains(token)) return token.toUpperCase();
  }
  if (_knownAudioFormats.contains(codec)) return codec.toUpperCase();
  if (tokens.isNotEmpty) return tokens.first.toUpperCase();
  if (codec.isNotEmpty) return codec.toUpperCase();
  return "Original file";
}

String _formatMb(int bytes, {bool estimated = false}) {
  final mb = bytes / (1024 * 1024);
  final text = mb >= 100 ? mb.toStringAsFixed(0) : mb.toStringAsFixed(1);
  return "${estimated ? '~' : ''}$text MB";
}


/// "Sleep timer" row with an inline dropdown of choices, same pattern as
/// the Download row's quality dropdown right above it in this sheet.
class _SleepTimerTile extends StatefulWidget {
  const _SleepTimerTile();

  @override
  State<_SleepTimerTile> createState() => _SleepTimerTileState();
}

class _SleepTimerTileState extends State<_SleepTimerTile> {
  bool _expanded = false;

  static const _choices = <(String, Duration?)>[
    ('5 minutes', Duration(minutes: 5)),
    ('10 minutes', Duration(minutes: 10)),
    ('15 minutes', Duration(minutes: 15)),
    ('30 minutes', Duration(minutes: 30)),
    ('45 minutes', Duration(minutes: 45)),
    ('1 hour', Duration(hours: 1)),
    ('End of track', null),
  ];

  String _statusText(SleepTimerState? t) {
    if (t == null) return 'Off';
    if (t.mode == SleepTimerMode.endOfTrack) return 'Stops at end of track';
    final left = t.remaining;
    final h = left.inHours;
    final m = left.inMinutes.remainder(60).toString().padLeft(2, '0');
    final sec = left.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? 'Stops in $h:$m:$sec' : 'Stops in ${left.inMinutes}:$sec';
  }

  void _pick(String label, Duration? length) {
    final service = SleepTimerService.instance;
    if (length == null) {
      service.startEndOfTrack();
    } else {
      service.startDuration(length);
    }
    final messenger = ScaffoldMessenger.maybeOf(context);
    Navigator.pop(context);
    messenger?.showSnackBar(
      SnackBar(
        content: Text(length == null
            ? 'Sleep timer set: pausing at the end of this track'
            : 'Sleep timer set for $label'),
      ),
    );
  }

  void _turnOff() {
    SleepTimerService.instance.cancel();
    final messenger = ScaffoldMessenger.maybeOf(context);
    Navigator.pop(context);
    messenger?.showSnackBar(
      const SnackBar(content: Text('Sleep timer turned off')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<SleepTimerState?>(
      valueListenable: SleepTimerService.instance.state,
      builder: (context, timer, _) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(
                Icons.bedtime_outlined,
                color: timer != null ? _gold : Colors.white70,
              ),
              title: const Text(
                'Sleep timer',
                style: TextStyle(color: Colors.white),
              ),
              subtitle: timer == null
                  ? null
                  : Text(
                      _statusText(timer),
                      style: const TextStyle(color: _gold, fontSize: 12),
                    ),
              trailing: Icon(
                _expanded ? Icons.expand_less : Icons.expand_more,
                color: Colors.white54,
              ),
              onTap: () => setState(() => _expanded = !_expanded),
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
              alignment: Alignment.topCenter,
              child: !_expanded
                  ? const SizedBox(width: double.infinity, height: 0)
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final (label, length) in _choices)
                          ListTile(
                            dense: true,
                            // Lines up under the title like the Download
                            // quality rows (16 + 40 + 16).
                            contentPadding:
                                const EdgeInsets.only(left: 72, right: 16),
                            title: Text(
                              label,
                              style: const TextStyle(color: Colors.white),
                            ),
                            onTap: () => _pick(label, length),
                          ),
                        if (timer != null)
                          ListTile(
                            dense: true,
                            contentPadding:
                                const EdgeInsets.only(left: 72, right: 16),
                            title: const Text(
                              'Turn off timer',
                              style: TextStyle(color: Colors.redAccent),
                            ),
                            onTap: _turnOff,
                          ),
                      ],
                    ),
            ),
          ],
        );
      },
    );
  }
}
