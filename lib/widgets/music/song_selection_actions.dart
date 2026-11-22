import 'package:flutter/material.dart';

import '../../player/models/media_item.dart';
import '../../player/playback_service.dart';
import '../../player/player_manager.dart';
import '../../player/screens/audio_player_screen.dart';
import '../../player/services/playback_queue.dart';
import '../../services/download_manager.dart';
import '../../services/jellyfin_services/media_service.dart';
import '../../services/local_music_service.dart';

/// Bulk-action helpers shared by every screen that offers song
/// multi-select (Music tab, Favorites, Search, playlist/album/artist
/// detail, Downloads), so "Play selected" and the on-device rules behave
/// identically everywhere instead of being re-derived per screen.

/// True if any of [songs] is an "On This Device" file. Used to hide the
/// Download action — an on-device song is already on the phone and has
/// no Jellyfin item to download — and to offer Remove instead.
bool songsContainLocal(Iterable songs) =>
    songs.any((s) => s is Map && s['IsLocal'] == true);

/// Builds a playable MediaItem per song, branching on each song's own
/// `IsLocal` flag. ROOT CAUSE this exists: a local song's map has a
/// synthetic `local_<id>` Id and no Type/MediaType, so running it
/// through the Jellyfin builders produces a stream URL against an id the
/// server has never heard of (see LocalMusicService.mediaItemFromLocalSong).
/// Lists that can mix both kinds — Favorites, and now playlists — can't
/// use a whole-list check, so the decision has to be per song.
///
/// [preferDownloads] picks how *server* songs are built, so each screen
/// keeps doing exactly what its own tap-to-play already does: false →
/// always the Jellyfin stream (Music tab, Favorites), true →
/// DownloadManager.mediaItemFor, which plays a downloaded copy from
/// disk when one exists (album/artist/playlist detail, Search).
List<MediaItem> mediaItemsFromMixedSongs(
  Iterable songs, {
  bool preferDownloads = false,
}) {
  return songs.map((s) {
    final map = Map<String, dynamic>.from(s as Map);
    if (map['IsLocal'] == true) {
      return LocalMusicService.mediaItemFromLocalSong(map);
    }
    return preferDownloads
        ? DownloadManager.instance.mediaItemFor(map)
        : MediaService.mediaItemFromJellyfin(map);
  }).toList();
}

/// Starts playback of [queue] as a brand-new queue containing exactly
/// those items, in that order — the "Play selected" action. Same
/// "was something already playing" handling as every other play entry
/// point: a fresh session opens the full player straight away, otherwise
/// the mini player just switches tracks in place.
///
/// (If the person has "auto-queue recommendations" switched on in
/// settings, PlayerManager still appends similar songs once this queue
/// runs out — that is an app-wide setting, not something specific to
/// this queue.)
Future<void> playSelectionAsQueue(
  BuildContext context,
  List<MediaItem> queue,
) async {
  if (queue.isEmpty) return;

  final wasAlreadyPlaying = PlayerManager.instance.currentItem != null;

  if (!wasAlreadyPlaying) {
    PlayerManager.instance.showLoadingPreview(queue.first);

    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute(builder: (_) => const AudioPlayerScreen()),
    );
  }

  final messenger = ScaffoldMessenger.maybeOf(context);

  await PlaybackService.playQueue(
    queue,
    startIndex: 0,
    source: PlaybackSource.unknown,
  );

  // With the full player already pushed, a failure shows on its own
  // error overlay; otherwise there's no screen for it, so a SnackBar.
  if (wasAlreadyPlaying) {
    final error = PlayerManager.instance.lastError.value;
    if (error != null) {
      messenger?.showSnackBar(SnackBar(content: Text(error)));
    }
  }
}

/// Confirms, then removes every on-device song among [selected] from the
/// app (same effect as the three-dot menu's "Remove from App": hidden
/// from the app and out of its playlists, the actual files untouched).
/// Server songs in a mixed selection are ignored. Returns the ids that
/// were removed, or null if there was nothing to remove or the person
/// cancelled.
Future<List<String>?> confirmRemoveLocalSongsFromApp(
  BuildContext context,
  Iterable selected,
) async {
  final localIds = [
    for (final s in selected)
      if (s is Map && s['IsLocal'] == true) s['Id'].toString(),
  ];
  if (localIds.isEmpty) return null;

  final otherCount = selected.length - localIds.length;
  final n = localIds.length;

  // Built outside the dialog so no quote-escaping is needed inside a
  // string interpolation.
  final otherNote = otherCount == 1
      ? "The other selected song isn't affected."
      : "The other $otherCount selected songs aren't affected.";

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: const Color(0xff232323),
      title: Text(
        'Remove from app?',
        style: const TextStyle(color: Colors.white),
      ),
      content: Text(
        (n == 1
                ? '1 on-device song will be removed from the app and from '
                    'any playlists it is in. The file stays on your device.'
                : '$n on-device songs will be removed from the app and from '
                    'any playlists they are in. The files stay on your '
                    'device.') +
            (otherCount > 0 ? ' $otherNote' : ''),
        style: const TextStyle(color: Colors.white70),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Cancel', style: TextStyle(color: Colors.white70)),
        ),
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('Remove', style: TextStyle(color: Colors.redAccent)),
        ),
      ],
    ),
  );

  if (confirmed != true) return null;

  for (final id in localIds) {
    await LocalMusicService.instance.removeFromApp(id);
  }
  return localIds;
}
