import 'dart:io';

import 'package:flutter/material.dart';

import '../../../player/player_manager.dart';
import '../../../player/services/playback_queue.dart';
import '../../../services/download_manager.dart';
import '../../../widgets/music/playlist_picker_sheet.dart';
import '../../../widgets/shared/nemesis_bottom_sheet.dart';
import '../../../widgets/common/dustbin_icon.dart';

/// The pop-up opened by tapping a downloaded song row's
/// [DeviceCheckBadge] — the same header-plus-`ListTile` chrome as the
/// three-dot [showSongOptionsSheet] used everywhere else songs are
/// browsed, but with only the four actions that make sense for
/// something already fully on disk: play it, queue it up next, add it
/// to a server playlist, or remove the download. No Favorite/Go to
/// Album/Go to Artist here — those belong to the general song menu,
/// not this badge.
void showDownloadedSongOptionsSheet(
  BuildContext context,
  DownloadRecord record, {
  required VoidCallback onPlay,
  required VoidCallback onDelete,
}) {
  showNemesisBottomSheet<void>(
    context,
    initialChildSize: 0.38,
    minChildSize: 0.28,
    maxChildSize: 0.7,
    builder: (sheetContext, scrollController) => ListView(
      controller: scrollController,
      children: [
        const NemesisSheetDragHandle(topMargin: 10, bottomMargin: 8),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: record.posterPath != null
                    ? Image.file(
                        File(record.posterPath!),
                        width: 46,
                        height: 46,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => _placeholder(),
                      )
                    : _placeholder(),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  record.title,
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
          leading: const Icon(Icons.play_arrow_rounded, color: Colors.white70),
          title: const Text("Play", style: TextStyle(color: Colors.white)),
          onTap: () {
            Navigator.pop(sheetContext);
            onPlay();
          },
        ),

        ListTile(
          leading: const Icon(Icons.queue_music, color: Colors.white70),
          title: const Text(
            "Add to Queue",
            style: TextStyle(color: Colors.white),
          ),
          onTap: () => _addToQueue(sheetContext, record),
        ),

        ListTile(
          leading: const Icon(Icons.playlist_add, color: Colors.white70),
          title: const Text(
            "Add to Playlist",
            style: TextStyle(color: Colors.white),
          ),
          onTap: () {
            // Capture the root-navigator context before popping this
            // sheet — same reasoning as song_options_sheet.dart's own
            // "Add to Playlist": reusing `context` after pop() risks
            // looking up an ancestor on an about-to-be-deactivated
            // element.
            final rootNavContext =
                Navigator.of(sheetContext, rootNavigator: true).context;
            Navigator.pop(sheetContext);
            showPlaylistPickerSheet(rootNavContext, record.raw);
          },
        ),

        ListTile(
          leading: const DustbinIcon(color: Colors.redAccent),
          title: const Text(
            "Remove Download",
            style: TextStyle(color: Colors.redAccent),
          ),
          onTap: () {
            Navigator.pop(sheetContext);
            onDelete();
          },
        ),

        const SizedBox(height: 8),
      ],
    ),
  );
}

Widget _placeholder() => Container(
      width: 46,
      height: 46,
      color: const Color(0xff2a2a2a),
      child: const Icon(Icons.music_note, color: Colors.white24),
    );

// Same "nothing playing yet" guard as song_options_sheet.dart's own
// _addToQueue — there's no "current song" for this one to queue up
// after without something already playing.
Future<void> _addToQueue(
  BuildContext sheetContext,
  DownloadRecord record,
) async {
  final messenger = ScaffoldMessenger.maybeOf(sheetContext);
  Navigator.pop(sheetContext);

  if (PlayerManager.instance.currentItem == null) {
    messenger?.showSnackBar(
      const SnackBar(
        content: Text("Play something first to add songs to the queue"),
      ),
    );
    return;
  }

  // mediaItemForRecord (not MediaService.mediaItemFromJellyfin) so a
  // queued-up download plays from the local file already on disk
  // instead of re-streaming it.
  final item = DownloadManager.instance.mediaItemForRecord(record);
  PlaybackQueue.instance.addNext(item);
  messenger?.showSnackBar(
    SnackBar(content: Text('Added "${record.title}" to queue')),
  );
}
