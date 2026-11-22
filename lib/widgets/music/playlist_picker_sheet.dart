import 'package:flutter/material.dart';

import '../../services/jellyfin_services/media_service.dart';
import '../../services/local_playlist_service.dart';
import '../common/keyboard_safe_dialog.dart';
import '../shared/nemesis_bottom_sheet.dart'
    show kNemesisSheetLandscapeAutoFraction;

const _gold = Color(0xffD4AF37);

/// Shows the "which playlist?" sheet used by the song options menu's
/// "Add to Playlist" action — lists the user's existing playlists plus a
/// "New Playlist" entry, and adds the song to whichever is picked.
///
/// Stacked on top of the caller's own sheet route (same pattern as
/// SubtitleSheet stacking OpenSubtitlesSheet) rather than replacing it,
/// so this file doesn't need to know whether it was opened from a sheet
/// or a plain screen.
void showPlaylistPickerSheet(BuildContext context, Map song) {
  showPlaylistPickerSheetMulti(context, [song]);
}

/// Same sheet, but adds every song in [songs] to whichever playlist is
/// picked (or seeds a brand new playlist with all of them) — used by
/// song multi-select's "Add to Playlist" bulk action. A single-song call
/// just goes through this with a one-item list, so there's only one
/// implementation to keep in sync.
///
/// [songs] may mix server songs and "On This Device" songs. On-device
/// songs can't exist on the Jellyfin server, so they're recorded in the
/// app's own storage instead (see LocalPlaylistService) — which is what
/// lets one playlist hold both kinds, and keeps the on-device ones from
/// following the account to another device.
void showPlaylistPickerSheetMulti(BuildContext context, List<Map> songs) {
  if (songs.isEmpty) return;

  showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    backgroundColor: const Color(0xff1c1c1c),
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (sheetContext) => _PlaylistPickerSheet(songs: songs),
  );
}

class _PlaylistPickerSheet extends StatefulWidget {
  const _PlaylistPickerSheet({required this.songs});

  final List<Map> songs;

  @override
  State<_PlaylistPickerSheet> createState() => _PlaylistPickerSheetState();
}

class _PlaylistPickerSheetState extends State<_PlaylistPickerSheet> {
  late Future<List<dynamic>> _future;

  @override
  void initState() {
    super.initState();
    _future = _loadPlaylists();
  }

  /// Server playlists plus the device-only ones. A failing server call
  /// (offline, server down) no longer empties the list — device-only
  /// playlists don't need the server, so they stay pickable.
  Future<List<dynamic>> _loadPlaylists() async {
    await LocalPlaylistService.instance.ensureLoaded();

    List<dynamic> server = const [];
    try {
      server = await MediaService.getPlaylists();
    } catch (_) {}

    return LocalPlaylistService.instance.mergePlaylists(
      server,
      newestFirst: false,
    );
  }

  // "<Name>" for a single song, "N songs" for a batch — matches how the
  // rest of the app (e.g. playlist child counts) phrases pluralized
  // song counts.
  String get _label => widget.songs.length == 1
      ? '"${widget.songs.first["Name"] ?? ""}"'
      : '${widget.songs.length} songs';

  Future<void> _createNew() async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => KeyboardSafeDialog(child: _NamePlaylistDialog()),
    );

    if (name == null || name.trim().isEmpty) return;
    if (!mounted) return;

    final messenger = ScaffoldMessenger.maybeOf(context);
    Navigator.pop(context);

    try {
      // Only on-device songs → a playlist that lives on this device
      // alone and never touches the server.
      final onlyLocal = widget.songs.every(LocalPlaylistService.isLocalSong);
      await LocalPlaylistService.instance.createPlaylistFromSongs(
        name.trim(),
        widget.songs,
      );
      messenger?.showSnackBar(
        SnackBar(
          content: Text(
            onlyLocal
                ? 'Added $_label to new playlist "${name.trim()}" '
                    '(on this device only)'
                : 'Added $_label to new playlist "${name.trim()}"',
          ),
        ),
      );
    } catch (_) {
      messenger?.showSnackBar(
        const SnackBar(content: Text("Couldn't create playlist.")),
      );
    }
  }

  Future<void> _addTo(Map playlist) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    Navigator.pop(context);

    try {
      final targetId = playlist["Id"].toString();
      final resultId = await LocalPlaylistService.instance.addSongsToPlaylist(
        targetId,
        widget.songs,
      );

      // A device-only playlist that just received a server song has
      // been promoted to a real server playlist (a server song can't
      // live in one that only exists here) — worth saying, since it now
      // shows up on the account's other devices too, minus the
      // on-device songs.
      final promoted = resultId != targetId;
      messenger?.showSnackBar(
        SnackBar(
          content: Text(
            promoted
                ? 'Added $_label to ${playlist["Name"] ?? "playlist"}. It is '
                    'now a server playlist; on-device songs stay on this '
                    'device.'
                : 'Added $_label to ${playlist["Name"] ?? "playlist"}',
          ),
        ),
      );
    } catch (_) {
      messenger?.showSnackBar(
        const SnackBar(content: Text("Couldn't add to playlist.")),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    // Portrait: up to 70% of the screen, as before. Landscape: never more
    // than 2/3 of the display (SafeArea's insets included), the list
    // scrolls inside instead.
    final screen = MediaQuery.sizeOf(context);
    final padding = MediaQuery.paddingOf(context);
    final maxSheetHeight = screen.width > screen.height
        ? (screen.height * kNemesisSheetLandscapeAutoFraction -
                padding.top -
                padding.bottom)
            .clamp(120.0, screen.height)
            .toDouble()
        : screen.height * 0.7;

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: maxSheetHeight,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(top: 10, bottom: 8),
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 8, 20, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  "Add to Playlist",
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),

            const Divider(color: Colors.white12, height: 1),

            ListTile(
              leading: const Icon(Icons.add, color: _gold),
              title: const Text(
                "New Playlist",
                style: TextStyle(color: _gold, fontWeight: FontWeight.w600),
              ),
              onTap: _createNew,
            ),

            const Divider(color: Colors.white12, height: 1),

            Flexible(
              child: FutureBuilder<List<dynamic>>(
                future: _future,
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(
                        child: SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: _gold,
                          ),
                        ),
                      ),
                    );
                  }

                  final playlists = snapshot.data ?? [];

                  if (playlists.isEmpty) {
                    return const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        "No playlists yet.",
                        style: TextStyle(color: Colors.white54),
                      ),
                    );
                  }

                  return ListView.builder(
                    shrinkWrap: true,
                    itemCount: playlists.length,
                    itemBuilder: (_, i) {
                      final playlist = Map<String, dynamic>.from(
                        playlists[i],
                      );

                      final deviceOnly = playlist["IsLocalPlaylist"] == true;

                      return ListTile(
                        leading: const Icon(
                          Icons.queue_music,
                          color: Colors.white70,
                        ),
                        title: Text(
                          playlist["Name"] ?? "",
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white),
                        ),
                        subtitle: deviceOnly
                            ? const Text(
                                "On this device only",
                                style: TextStyle(
                                  color: Colors.white38,
                                  fontSize: 12,
                                ),
                              )
                            : null,
                        onTap: () => _addTo(playlist),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NamePlaylistDialog extends StatefulWidget {
  @override
  State<_NamePlaylistDialog> createState() => _NamePlaylistDialogState();
}

class _NamePlaylistDialogState extends State<_NamePlaylistDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      alignment: keyboardSafeDialogAlignment,
      backgroundColor: const Color(0xff222222),
      title: const Text(
        "New Playlist",
        style: TextStyle(color: Colors.white),
      ),
      content: TextField(
        controller: _controller,
        autofocus: true,
        style: const TextStyle(color: Colors.white),
        cursorColor: _gold,
        decoration: const InputDecoration(
          hintText: "Playlist name",
          hintStyle: TextStyle(color: Colors.white38),
          enabledBorder: UnderlineInputBorder(
            borderSide: BorderSide(color: Colors.white24),
          ),
          focusedBorder: UnderlineInputBorder(
            borderSide: BorderSide(color: _gold),
          ),
        ),
        onSubmitted: (value) => Navigator.pop(context, value),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text("Cancel", style: TextStyle(color: Colors.white54)),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, _controller.text),
          child: const Text("Create", style: TextStyle(color: _gold)),
        ),
      ],
    );
  }
}
