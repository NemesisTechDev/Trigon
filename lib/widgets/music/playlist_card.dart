import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import '../../services/jellyfin_services/media_service.dart';
import '../../services/local_playlist_service.dart';
import '../common/pressable.dart';
import '../../services/cache/nemesis_image_cache.dart';

/// The single square cover art tile used to represent a playlist —
/// its own Jellyfin-provided image if it has one, otherwise a plain
/// placeholder box. Shared by [PlaylistCard] (the playlist grid) and
/// the playlist detail screen's header, so a playlist looks the same
/// wherever it's shown, instead of the detail screen trying to build
/// its own 4-way collage out of individual track art client-side
/// (that always looked like mismatched, cropped fragments — Jellyfin's
/// own playlist image, when present, is already a proper single cover).
class PlaylistCoverArt extends StatelessWidget {
  final String playlistId;
  final double? size;
  final double borderRadius;

  const PlaylistCoverArt({
    super.key,
    required this.playlistId,
    this.size,
    this.borderRadius = 14,
  });

  /// The server-provided cover (Jellyfin builds it from the playlist's
  /// own items). Split out of build() so a device-only playlist can swap
  /// in a cover made from its songs' on-device artwork instead.
  Widget _serverCover(BuildContext context) {
    final image = MediaService.getMusicImage(
      playlistId,
      size: 400,
    );

    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final dpr = MediaQuery.devicePixelRatioOf(context);
          return CachedNetworkImage(
            cacheManager: NemesisImageCache.instance,
            imageUrl: image,
            fit: BoxFit.cover,
            memCacheWidth: constraints.maxWidth.isFinite
                ? (constraints.maxWidth * dpr).round()
                : null,
            memCacheHeight: constraints.maxHeight.isFinite
                ? (constraints.maxHeight * dpr).round()
                : null,
            fadeInDuration: const Duration(milliseconds: 250),
            placeholder: (_, __) => Container(
              color: const Color(0xff252525),
            ),
            errorWidget: (_, __, ___) {
              return Container(
                color: const Color(0xff252525),
                child: const Icon(
                  Icons.queue_music,
                  color: Colors.white24,
                ),
              );
            },
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // A playlist that only exists on this device has no Jellyfin item,
    // so asking the server for its image can only 404 — its cover is
    // built from its own songs' on-device artwork instead.
    Widget content = LocalPlaylistService.isLocalPlaylistId(playlistId)
        ? ClipRRect(
            borderRadius: BorderRadius.circular(borderRadius),
            child: _LocalPlaylistCover(playlistId: playlistId),
          )
        : _serverCover(context);

    if (size != null) {
      content = SizedBox(width: size, height: size, child: content);
    } else {
      content = AspectRatio(aspectRatio: 1, child: content);
    }

    return content;
  }
}

/// Cover for a device-only playlist: up to four distinct pieces of
/// on-device artwork from its songs (a single full-bleed image if only
/// one exists), or the same music-note placeholder a server playlist
/// with no image shows. Re-resolves whenever [LocalPlaylistService]
/// changes so adding/removing songs updates the cover.
class _LocalPlaylistCover extends StatefulWidget {
  final String playlistId;

  const _LocalPlaylistCover({required this.playlistId});

  @override
  State<_LocalPlaylistCover> createState() => _LocalPlaylistCoverState();
}

class _LocalPlaylistCoverState extends State<_LocalPlaylistCover> {
  late Future<List<String>> _future = _artPaths();

  @override
  void initState() {
    super.initState();
    LocalPlaylistService.instance.addListener(_onChanged);
  }

  @override
  void dispose() {
    LocalPlaylistService.instance.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (!mounted) return;
    setState(() => _future = _artPaths());
  }

  Future<List<String>> _artPaths() async {
    final songs =
        await LocalPlaylistService.instance.songsFor(widget.playlistId);
    final seen = <String>{};
    final paths = <String>[];
    for (final song in songs) {
      final path = song['ArtworkPath'] as String?;
      if (path != null && seen.add(path)) {
        paths.add(path);
        if (paths.length == 4) break;
      }
    }
    return paths;
  }

  Widget _placeholder() => Container(
        color: const Color(0xff252525),
        child: const Center(
          child: Icon(Icons.queue_music, color: Colors.white24),
        ),
      );

  Widget _tile(String path) => Image.file(
        File(path),
        fit: BoxFit.cover,
        cacheWidth: 300,
        errorBuilder: (_, __, ___) => Container(color: const Color(0xff2A2A2A)),
      );

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<String>>(
      future: _future,
      builder: (context, snapshot) {
        final paths = snapshot.data ?? const <String>[];
        if (paths.isEmpty) return _placeholder();
        if (paths.length == 1) return _tile(paths.first);

        return GridView.builder(
          physics: const NeverScrollableScrollPhysics(),
          padding: EdgeInsets.zero,
          itemCount: 4,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            crossAxisSpacing: 2,
            mainAxisSpacing: 2,
          ),
          itemBuilder: (_, i) => _tile(paths[i % paths.length]),
        );
      },
    );
  }
}

class PlaylistCard extends StatelessWidget {
  final Map playlist;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  // Hold-to-select: when [selectionMode] is true, the cover art dims
  // slightly and shows a checkbox in the corner instead of navigating
  // on tap. Mirrors the pattern used for downloads/library multi-select
  // elsewhere in the app, scoped here to the playlists grid.
  final bool selectionMode;
  final bool selected;

  // Whether the "N songs" line under the name is shown. Off for
  // recommendation-style rows (e.g. "Recommended Playlists" on the
  // playlist detail page) where the card is meant to read as just a
  // name, matching the same "name-only" treatment PersonCard/CastRow
  // use for their own recommendation contexts.
  final bool showSongCount;

  const PlaylistCard({
    super.key,
    required this.playlist,
    this.onTap,
    this.onLongPress,
    this.selectionMode = false,
    this.selected = false,
    this.showSongCount = true,
  });

  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: onTap,
      onLongPress: onLongPress,
      borderRadius: BorderRadius.circular(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Stack(
            children: [
              AnimatedOpacity(
                duration: const Duration(milliseconds: 150),
                opacity: selectionMode && !selected ? 0.5 : 1,
                child: Container(
                  decoration: selected
                      ? BoxDecoration(
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: const Color(0xffD4AF37),
                            width: 2,
                          ),
                        )
                      : null,
                  padding: selected ? const EdgeInsets.all(2) : EdgeInsets.zero,
                  child: PlaylistCoverArt(
                    playlistId: playlist["Id"],
                    borderRadius: 12,
                  ),
                ),
              ),
              if (selectionMode)
                Positioned(
                  top: 8,
                  right: 8,
                  child: Container(
                    width: 22,
                    height: 22,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: selected
                          ? const Color(0xffD4AF37)
                          : Colors.black54,
                      border: Border.all(
                        color: selected
                            ? const Color(0xffD4AF37)
                            : Colors.white70,
                        width: 1.5,
                      ),
                    ),
                    child: selected
                        ? const Icon(
                            Icons.check,
                            size: 15,
                            color: Colors.black,
                          )
                        : null,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            playlist["Name"] ?? "",
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white),
          ),
          if (showSongCount)
            Text(
              "${playlist["ChildCount"] ?? 0} songs",
              style: const TextStyle(
                color: Colors.white54,
                fontSize: 12,
              ),
            ),
        ],
      ),
    );
  }
}