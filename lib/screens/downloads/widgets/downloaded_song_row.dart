import 'dart:io';

import 'package:flutter/material.dart';

import '../../../services/download_manager.dart';
import '../../../widgets/common/device_check_badge.dart';
import '../../../widgets/common/pressable.dart';
import '../../../widgets/music/music_visualizer.dart';
import 'downloaded_song_options_sheet.dart';

const _gold = Color(0xffD4AF37);

class DownloadedSongRow extends StatelessWidget {
  final DownloadRecord record;
  final bool playing;
  final VoidCallback onTap;

  /// Starts playback of this song — same action [onTap] triggers
  /// outside selection mode, handed separately so the trailing
  /// [DeviceCheckBadge]'s sheet (see [showDownloadedSongOptionsSheet])
  /// has a plain "Play" action that isn't tangled up with [onTap]'s
  /// selection-mode toggling.
  final VoidCallback onPlay;

  final VoidCallback onDelete;

  // Long-press-to-multi-select — same trio as SongRow/PlaylistCard: the
  // artwork dims and grows a corner checkbox, the per-row delete button
  // hides in favor of a screen-level bulk delete, and the caller
  // repurposes [onTap] to toggle membership while active.
  final bool selectionMode;
  final bool selected;
  final VoidCallback? onLongPress;

  const DownloadedSongRow({
    super.key,
    required this.record,
    required this.onTap,
    required this.onPlay,
    required this.onDelete,
    this.playing = false,
    this.selectionMode = false,
    this.selected = false,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    // No card enclosure — the row sits flush on the Downloads screen's
    // own background, matching the reference design. Only spacing
    // between rows remains; Pressable still supplies its own ripple.
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
      child: Pressable(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          children: [
            Stack(
              children: [
                AnimatedOpacity(
                  duration: const Duration(milliseconds: 150),
                  opacity: selectionMode && !selected ? 0.5 : 1,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: SizedBox(
                      width: 56,
                      height: 56,
                      child: record.posterPath != null
                          ? Image.file(
                              File(record.posterPath!),
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => _placeholder(),
                            )
                          : _placeholder(),
                    ),
                  ),
                ),
                if (selectionMode)
                  Positioned(
                    top: 4,
                    right: 4,
                    child: Container(
                      width: 20,
                      height: 20,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: selected ? _gold : Colors.black54,
                        border: Border.all(
                          color: selected ? _gold : Colors.white70,
                          width: 1.5,
                        ),
                      ),
                      child: selected
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
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Row(
                    children: [
                      if (playing) ...[
                        const MusicVisualizer(),
                        const SizedBox(width: 6),
                      ],
                      Expanded(
                        child: Text(
                          record.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: playing ? _gold : Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    record.artistName.isNotEmpty
                        ? record.artistName
                        : record.subtitle,
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
            if (!selectionMode)
              Pressable(
                unconstrained: true,
                onTap: () => showDownloadedSongOptionsSheet(
                  context,
                  record,
                  onPlay: onPlay,
                  onDelete: onDelete,
                ),
                child: const DeviceCheckBadge(size: 28),
              ),
          ],
        ),
      ),
      ),
    );
  }

  Widget _placeholder() => Container(
        color: const Color(0xff252525),
        child: const Icon(Icons.music_note, color: Colors.white24, size: 26),
      );
}
