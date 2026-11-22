import 'dart:async';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import '../../services/download_manager.dart';
import '../../services/jellyfin_services/media_service.dart';
import '../../player/player_manager.dart';
import '../common/device_check_badge.dart';
import '../common/download_stop_ring.dart';
import '../common/pressable.dart';
import 'song_options_sheet.dart';
import '../../services/cache/nemesis_image_cache.dart';

const _gold = Color(0xffD4AF37);

class SongRow extends StatefulWidget {
  final Map song;
  final VoidCallback? onTap;

  // Highlights this row as the currently-playing track — gold title
  // plus a small pulsing equalizer, matching the queue screen's
  // now-playing row.
  final bool playing;

  // Shows "N listens" under the artist name, Spotify Wrapped-style —
  // only meaningful (and only turned on) for the Most Played tab.
  final bool showPlayCount;

  // Whether the three-dot menu should offer a "Go to Album" tile.
  // Turned off on the album's own detail screen, where the song is
  // already sitting inside that album and the tile would just point
  // back to the page you're already on.
  final bool showGoToAlbum;

  // Hides the "Go to Artist" tile for this artist ID in the three-dot
  // menu. Used on an artist's own detail screen so a song doesn't
  // offer a tile pointing back to the page you're already on — the
  // other artists on the song (if any) still get their own tiles.
  final String? excludeArtistId;

  // The playlist this row is being shown inside of, if any. Passing
  // this turns on a "Remove from Playlist" tile in the three-dot menu
  // — it's only meaningful (and only shown) when the row is actually
  // part of a specific playlist's tracklist.
  final String? playlistId;

  // Called after the song is successfully removed from [playlistId],
  // so the screen showing this row can drop it from its own list.
  final VoidCallback? onRemovedFromPlaylist;

  // Called after a local song is removed from the app (three-dot menu,
  // "Remove from App" — only ever offered for song["IsLocal"] == true
  // rows), so the Local Files list can drop it immediately instead of
  // waiting for the next scan.
  final VoidCallback? onRemovedFromApp;

  // Long-press-to-multi-select, mirroring PlaylistCard's own
  // selectionMode/selected/onLongPress trio: while [selectionMode] is
  // true the artwork dims and shows a checkbox instead of the three-dot
  // menu, [onTap] is repurposed by the caller to toggle membership
  // instead of playing, and [onLongPress] is left null once selection
  // mode is already active (there's nothing further "entering" it needs
  // to do — an already-active tap handles adding more rows).
  final bool selectionMode;
  final bool selected;
  final VoidCallback? onLongPress;

  // Lets the trailing three-dot button double as this song's download
  // indicator: while it transfers it becomes the Downloads screen's
  // progress ring (tap to cancel), while it waits in the queue a muted
  // clock, and once it's on the device the shared "saved to this
  // device" badge — which still opens the same options sheet the three
  // dots do (there, the Download tile reads "Remove download"). A song
  // that isn't downloaded keeps its plain three dots. Turned on by the
  // Favorites songs list, the Music tab's Songs and Most Played lists,
  // and the album / artist / playlist detail screens.
  final bool showDownloadStatus;

  const SongRow({
    super.key,
    required this.song,
    this.onTap,
    this.playing = false,
    this.showPlayCount = false,
    this.showGoToAlbum = true,
    this.excludeArtistId,
    this.playlistId,
    this.onRemovedFromPlaylist,
    this.onRemovedFromApp,
    this.selectionMode = false,
    this.selected = false,
    this.onLongPress,
    this.showDownloadStatus = false,
  });

  @override
  State<SongRow> createState() => _SongRowState();
}

class _SongRowState extends State<SongRow> with TickerProviderStateMixin {
  // Drives the pulsing bar heights while the song is actually playing.
  AnimationController? _pulseController;

  // 0 = full equalizer bars (playing), 1 = fully collapsed into three
  // dots resting at the bottom of the visualizer (paused). Animating
  // this is what makes the bars "drop" into dots instead of popping.
  AnimationController? _collapseController;

  // The artwork URL / decode size this row last warmed into Flutter's
  // in-memory ImageCache (see _precacheArtwork), so a rebuild that
  // changes neither doesn't re-issue the same request.
  String? _precachedUrl;
  int? _precachedPixels;

  @override
  void initState() {
    super.initState();
    if (widget.playing) _startAnimating();
    PlayerManager.instance.playing.addListener(_onPlaybackStateChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _precacheArtwork();
  }

  // SCROLL-SYNC FIX: while a list is flinging fast, Flutter's Image
  // widget (which CachedNetworkImage is built on) deliberately DEFERS
  // resolving any image that isn't already in the in-memory ImageCache
  // until the scroll slows down. The title/artist text has no such
  // deferral, so every row scrolling into view showed its text
  // immediately but an empty grey square where the artwork should be,
  // with the art only appearing (and then fading in) a beat later —
  // which read as the artwork "lagging" behind the text.
  //
  // That deferral is skipped for any image already in (or already being
  // loaded into) the ImageCache, so the moment the row is built — which
  // happens ahead of it becoming visible — its artwork is requested
  // here regardless of scroll speed. The provider is built exactly the
  // way CachedNetworkImage builds its own (same NemesisImageCache
  // manager, same ResizeImage.resizeIfNeeded decode size as the
  // memCacheWidth/memCacheHeight in build), so both resolve to the
  // identical ImageCache key and the widget below gets a ready,
  // already-decoded image instead of starting a second load.
  void _precacheArtwork() {
    final song = widget.song;
    if (song["IsLocal"] == true) return;

    final id = song["Id"];
    if (id == null) return;

    final pixels = (65 * MediaQuery.devicePixelRatioOf(context)).round();
    final url = MediaService.getMusicImage(id, size: 130);

    if (url == _precachedUrl && pixels == _precachedPixels) return;
    _precachedUrl = url;
    _precachedPixels = pixels;

    unawaited(
      precacheImage(
        ResizeImage.resizeIfNeeded(
          pixels,
          pixels,
          CachedNetworkImageProvider(
            url,
            cacheManager: NemesisImageCache.instance,
          ),
        ),
        context,
        onError: (Object _, StackTrace? __) {},
      ),
    );
  }

  @override
  void didUpdateWidget(covariant SongRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.song["Id"] != widget.song["Id"]) _precacheArtwork();
    if (widget.playing && _pulseController == null) {
      _startAnimating();
    } else if (!widget.playing && _pulseController != null) {
      _pulseController!.dispose();
      _collapseController!.dispose();
      _pulseController = null;
      _collapseController = null;
    }
  }

  void _startAnimating() {
    final isPlaying = PlayerManager.instance.playing.value;

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );

    _collapseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 380),
      // Starts already-collapsed (dots) if the row appears while the
      // song happens to be paused, otherwise starts as full bars.
      value: isPlaying ? 0.0 : 1.0,
    );

    if (isPlaying) _pulseController!.repeat();
  }

  // Steps the bars and dots in and out of sync with actual playback:
  // pausing freezes the bar heights right where they are and eases them
  // down into three dots; resuming reverses that and kicks the pulse
  // back off.
  void _onPlaybackStateChanged() {
    if (_pulseController == null || _collapseController == null) return;

    if (PlayerManager.instance.playing.value) {
      _collapseController!.reverse();
      _pulseController!.repeat();
    } else {
      _pulseController!.stop();
      _collapseController!.forward();
    }
  }

  @override
  void dispose() {
    PlayerManager.instance.playing.removeListener(_onPlaybackStateChanged);
    _pulseController?.dispose();
    _collapseController?.dispose();
    super.dispose();
  }

  // Dims the artwork only while multi-select is active. Outside
  // selection mode the artwork is returned as-is — previously it was
  // always wrapped in an AnimatedOpacity, an extra animated-opacity
  // node on the artwork alone (and not on the title/artist text beside
  // it) for every row of every song list, which is one more reason the
  // artwork could fall out of step with the text during a scroll.
  Widget _dimmed(Widget artwork) {
    if (!widget.selectionMode) return artwork;

    return AnimatedOpacity(
      duration: const Duration(milliseconds: 150),
      opacity: widget.selected ? 1 : 0.5,
      child: artwork,
    );
  }

  @override
  Widget build(BuildContext context) {
    final song = widget.song;
    final isLocal = song["IsLocal"] == true;

    // The artwork only ever renders at 65x65 in this row, so there's no
    // need to request (and decode) a 400px image from the server for
    // every single song — that was the main source of slowness in long
    // lists like Most Played, Playlists, and Songs.
    final image = isLocal
        ? null
        : MediaService.getMusicImage(
            song["Id"],
            size: 130,
          );
    final localArtworkPath = isLocal ? song["ArtworkPath"] as String? : null;

    // ARTIST DISPLAY FIX: this used to check `AlbumArtist` first, which
    // is a per-*album* field, not a per-track one — for a normal song
    // it's usually just the primary artist (so a feature/collab track
    // showed only one name even though `Artists`/`ArtistItems` had all
    // of them), and for a compilation album Jellyfin sets it to the
    // literal string "Various Artists", which isn't a real performer at
    // all. `Artists`/`ArtistItems` are the actual per-track artist
    // credits, so they're checked first now and joined in full (not
    // just `[0]`) — `AlbumArtist` is kept only as a last-resort fallback
    // for the rare item that has neither.
    String artist = "";

    if (song["Artists"] is List &&
        (song["Artists"] as List).isNotEmpty) {
      artist = (song["Artists"] as List).join(", ");
    } else if (song["ArtistItems"] is List &&
        (song["ArtistItems"] as List).isNotEmpty) {
      artist = (song["ArtistItems"] as List)
          .map((a) => a["Name"] ?? "")
          .where((name) => name.toString().isNotEmpty)
          .join(", ");
    } else if (song["AlbumArtist"] != null &&
        song["AlbumArtist"].toString().isNotEmpty) {
      artist = song["AlbumArtist"];
    }

    final playCount = (song["UserData"]?["PlayCount"] as num?)?.toInt() ?? 0;
    final showPlayCount = widget.showPlayCount && playCount > 0;

    return Pressable(
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: 10,
          vertical: 3,
        ),
        child: Row(
          children: [

            /// Artwork — dims and grows a corner checkbox in selection
            /// mode, same treatment as PlaylistCard's cover art.
            Stack(
              children: [
                _dimmed(
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: isLocal
                        // Local songs never hit the network for art —
                        // either the file's own embedded artwork
                        // (extracted and cached to disk by
                        // LocalMusicService) or, for songs that don't
                        // have any, a plain music-note placeholder
                        // rather than attempting a Jellyfin image URL
                        // that has no meaning for an on-device file.
                        ? (localArtworkPath != null
                            ? Image.file(
                                File(localArtworkPath),
                                width: 65,
                                height: 65,
                                fit: BoxFit.cover,
                                cacheWidth:
                                    (65 * MediaQuery.devicePixelRatioOf(context))
                                        .round(),
                                errorBuilder: (_, __, ___) => Container(
                                  width: 65,
                                  height: 65,
                                  color: const Color(0xff252525),
                                  child: const Icon(
                                    Icons.music_note,
                                    color: Colors.white24,
                                    size: 30,
                                  ),
                                ),
                              )
                            : Container(
                                width: 65,
                                height: 65,
                                color: const Color(0xff252525),
                                child: const Icon(
                                  Icons.music_note,
                                  color: Colors.white24,
                                  size: 30,
                                ),
                              ))
                        : CachedNetworkImage(
                            cacheManager: NemesisImageCache.instance,
                            imageUrl: image!,
                            width: 65,
                            height: 65,
                            fit: BoxFit.cover,
                            memCacheWidth:
                                (65 * MediaQuery.devicePixelRatioOf(context))
                                    .round(),
                            memCacheHeight:
                                (65 * MediaQuery.devicePixelRatioOf(context))
                                    .round(),
                            // No fade at all: a fading image (and the
                            // placeholder fading out underneath it) is
                            // two animated opacity layers per row while
                            // scrolling, and the artwork visibly arriving
                            // after the text is exactly the "lag" this
                            // row used to have.
                            fadeInDuration: Duration.zero,
                            fadeOutDuration: Duration.zero,
                            placeholder: (_, __) => Container(
                              width: 65,
                              height: 65,
                              color: const Color(0xff252525),
                            ),
                            errorWidget: (_, __, ___) => Container(
                              width: 65,
                              height: 65,
                              color: const Color(0xff252525),
                              child: const Icon(
                                Icons.music_note,
                                color: Colors.white24,
                                size: 30,
                              ),
                            ),
                          ),
                  ),
                ),
                if (widget.selectionMode)
                  Positioned(
                    top: 4,
                    right: 4,
                    child: Container(
                      width: 20,
                      height: 20,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: widget.selected
                            ? _gold
                            : Colors.black54,
                        border: Border.all(
                          color: widget.selected ? _gold : Colors.white70,
                          width: 1.5,
                        ),
                      ),
                      child: widget.selected
                          ? const Icon(
                              Icons.check,
                              size: 14,
                              color: Colors.black,
                            )
                          : null,
                    ),
                  ),
              ],
            ),

            const SizedBox(width: 12),

            /// Song Info
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [

                  Row(
                    children: [
                      if (widget.playing &&
                          _pulseController != null &&
                          _collapseController != null) ...[
                        _MusicVisualizer(
                          pulseController: _pulseController!,
                          collapseController: _collapseController!,
                        ),
                        const SizedBox(width: 6),
                      ],

                      Expanded(
                        child: Text(
                          song["Name"] ?? "",
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: widget.playing ? _gold : Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 4),

                  Text.rich(
                    TextSpan(
                      children: [
                        if (showPlayCount) ...[
                          TextSpan(
                            text: '$playCount listen${playCount == 1 ? '' : 's'}',
                            style: const TextStyle(
                              color: _gold,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const TextSpan(
                            text: ' · ',
                            style: TextStyle(
                              color: Colors.white54,
                              fontSize: 12,
                            ),
                          ),
                        ],
                        TextSpan(text: artist),
                      ],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white54,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),

            if (!widget.selectionMode)
              _SongTrailingAction(
                // Local (on-device) songs have nothing to download, so
                // they always keep the plain three dots.
                songId: (!isLocal && widget.showDownloadStatus)
                    ? (song["Id"]?.toString() ?? "")
                    : "",
                onOpenMenu: () => showSongOptionsSheet(
                  context,
                  song,
                  showGoToAlbum: widget.showGoToAlbum,
                  excludeArtistId: widget.excludeArtistId,
                  playlistId: widget.playlistId,
                  onRemovedFromPlaylist: widget.onRemovedFromPlaylist,
                  onRemovedFromApp: widget.onRemovedFromApp,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The row's trailing control. Normally the three-dot menu button; when
/// [songId] is set it follows that song's download state instead, in the
/// same 48 dp slot so nothing shifts as the state changes:
///
///  • downloading — the Downloads screen's progress ring; tapping it
///    cancels the transfer (it does not open the menu)
///  • queued / paused — a muted clock, opening the menu on tap
///  • downloaded — the shared "saved to this device" badge, opening the
///    same menu on tap (its Download tile reads "Remove download")
///  • anything else — the plain three dots
///
/// Rebuilds off [DownloadManager] alone, so a transfer's ring animates
/// without the row or the screen around it rebuilding.
class _SongTrailingAction extends StatelessWidget {
  final String songId;
  final VoidCallback onOpenMenu;

  const _SongTrailingAction({required this.songId, required this.onOpenMenu});

  Widget _menuButton(Widget icon) {
    return IconButton(
      onPressed: onOpenMenu,
      splashRadius: 20,
      icon: icon,
    );
  }

  @override
  Widget build(BuildContext context) {
    const dots = Icon(Icons.more_vert, color: Colors.white38, size: 22);

    if (songId.isEmpty) return _menuButton(dots);

    return AnimatedBuilder(
      animation: DownloadManager.instance,
      builder: (context, _) {
        final manager = DownloadManager.instance;
        final task = manager.taskFor(songId);

        if (task != null &&
            (task.state == DownloadState.downloading ||
                task.state == DownloadState.paused)) {
          return SizedBox(
            width: 48,
            height: 48,
            child: Center(
              child: DownloadStopRing(
                size: 24,
                progress: task.progress,
                indeterminate: task.totalBytes <= 0,
                downloadId: songId,
                onCancel: () => manager.cancelDownload(songId),
              ),
            ),
          );
        }

        if (task != null && task.state == DownloadState.queued) {
          return _menuButton(
            const Icon(Icons.schedule_rounded, color: Colors.white38, size: 22),
          );
        }

        if (manager.isDownloaded(songId)) {
          return _menuButton(const DeviceCheckBadge(size: 24));
        }

        return _menuButton(dots);
      },
    );
  }
}

/// Small pulsing bar-equalizer next to the title of the currently
/// playing row. When the song pauses, the bars ease down into three
/// small dots resting at the bottom of the same footprint — and back
/// up into bars again on resume — instead of instantly swapping.
class _MusicVisualizer extends StatelessWidget {
  final AnimationController pulseController;
  final AnimationController collapseController;

  const _MusicVisualizer({
    required this.pulseController,
    required this.collapseController,
  });

  static const double _dotSize = 3;
  static const double _maxBarHeight = 12;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 14,
      height: _maxBarHeight,
      child: AnimatedBuilder(
        animation: Listenable.merge([pulseController, collapseController]),
        builder: (context, _) {
          // 0 = playing (full bars), 1 = paused (collapsed into dots).
          final collapse = Curves.easeOutCubic.transform(
            collapseController.value,
          );

          return Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: List.generate(3, (i) {
              final t = (pulseController.value + i * 0.33) % 1.0;
              final barHeight =
                  _dotSize + (9 * (0.5 - (t - 0.5).abs()) * 2);

              // Bars shrink down toward a same-size dot as `collapse`
              // goes to 1, so they settle at the bottom of the box
              // rather than disappearing or jumping.
              final height = barHeight + (_dotSize - barHeight) * collapse;

              // Rounds fully into a circle once fully collapsed, and
              // stays a soft pill shape while still a bar.
              final radius = 1 + (0.5 * _dotSize - 1) * collapse;

              return Container(
                width: _dotSize,
                height: height,
                decoration: BoxDecoration(
                  color: _gold,
                  borderRadius: BorderRadius.circular(radius),
                ),
              );
            }),
          );
        },
      ),
    );
  }
}
