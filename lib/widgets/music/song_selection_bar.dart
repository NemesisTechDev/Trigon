import 'package:flutter/material.dart';
import '../common/dustbin_icon.dart';

const _gold = Color(0xffD4AF37);

// 40dp instead of IconButton's default 48dp hit area, so up to five
// actions plus the close button and the count still fit a narrow phone.
const _actionConstraints = BoxConstraints(minWidth: 40, minHeight: 40);

/// Header bar shown in place of a screen's normal title/controls while a
/// multi-select (songs, or movie / TV show cards) is active — a close (X) button, a live "N selected"
/// count, and whichever bulk actions the calling screen wires up.
///
/// Each action is its own nullable callback rather than a fixed set,
/// since not every list supports every action — e.g. only a playlist's
/// own tracklist gets "Remove from Playlist", and the Downloads screen
/// has no use for "Download" since everything shown there already is
/// one. Passing null for an action just omits its icon.
class SongSelectionBar extends StatelessWidget {
  final int count;
  final bool busy;
  final VoidCallback onClose;

  // Starts a fresh queue made of only the selected songs.
  final VoidCallback? onPlaySelected;
  final VoidCallback? onAddToQueue;
  final VoidCallback? onDownload;
  final VoidCallback? onAddToPlaylist;
  final VoidCallback? onDelete;

  // Movie / TV show multi-select: the only action there. [favoriteActive]
  // is true when every selected title is already a favorite, in which
  // case the button reads (and acts as) "Remove from Favorites".
  final VoidCallback? onFavorite;
  final bool favoriteActive;

  // "Remove" reads right for a playlist's own tracklist, "Delete" for
  // downloaded songs — the calling screen picks whichever fits.
  final String deleteLabel;
  final IconData deleteIcon;

  const SongSelectionBar({
    super.key,
    required this.count,
    required this.onClose,
    this.busy = false,
    this.onPlaySelected,
    this.onAddToQueue,
    this.onDownload,
    this.onAddToPlaylist,
    this.onDelete,
    this.onFavorite,
    this.favoriteActive = false,
    this.deleteLabel = "Remove",
    this.deleteIcon = Icons.delete_outline,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          IconButton(
            onPressed: busy ? null : onClose,
            icon: const Icon(Icons.close, color: Colors.white),
          ),
          // FittedBox(scaleDown): with Play added there can be five
          // action icons next to this label (a playlist page offers
          // Play, Queue, Download, Add to Playlist, Remove), which on a
          // narrow phone leaves less width than "12 selected" needs at
          // 18sp — it used to wrap onto two lines. Scaling the label
          // down keeps it on one line without dropping any action.
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  "$count selected",
                  maxLines: 1,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ),
          if (busy)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: _gold,
                ),
              ),
            )
          else ...[
            if (onPlaySelected != null)
              IconButton(
                tooltip: "Play selected",
                constraints: _actionConstraints,
                padding: EdgeInsets.zero,
                onPressed: count == 0 ? null : onPlaySelected,
                icon: const Icon(Icons.play_arrow_rounded, color: _gold),
              ),
            if (onAddToQueue != null)
              IconButton(
                tooltip: "Add to Queue",
                constraints: _actionConstraints,
                padding: EdgeInsets.zero,
                onPressed: count == 0 ? null : onAddToQueue,
                icon: const Icon(Icons.queue_music, color: Colors.white70),
              ),
            if (onDownload != null)
              IconButton(
                tooltip: "Download",
                constraints: _actionConstraints,
                padding: EdgeInsets.zero,
                onPressed: count == 0 ? null : onDownload,
                icon: const Icon(
                  Icons.download_outlined,
                  color: Colors.white70,
                ),
              ),
            if (onAddToPlaylist != null)
              IconButton(
                tooltip: "Add to Playlist",
                constraints: _actionConstraints,
                padding: EdgeInsets.zero,
                onPressed: count == 0 ? null : onAddToPlaylist,
                icon: const Icon(Icons.playlist_add, color: Colors.white70),
              ),
            if (onFavorite != null)
              IconButton(
                tooltip: favoriteActive
                    ? "Remove from Favorites"
                    : "Add to Favorites",
                constraints: _actionConstraints,
                padding: EdgeInsets.zero,
                onPressed: count == 0 ? null : onFavorite,
                icon: Icon(
                  favoriteActive ? Icons.favorite : Icons.favorite_border,
                  color: favoriteActive ? Colors.redAccent : Colors.white70,
                ),
              ),
            if (onDelete != null)
              IconButton(
                tooltip: deleteLabel,
                constraints: _actionConstraints,
                padding: EdgeInsets.zero,
                onPressed: count == 0 ? null : onDelete,
                icon: deleteIcon == Icons.delete_outline
                    ? const DustbinIcon(color: Colors.redAccent)
                    : Icon(deleteIcon, color: Colors.redAccent),
              ),
          ],
        ],
      ),
    );
  }
}
