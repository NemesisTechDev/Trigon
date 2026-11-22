import 'dart:async';

import 'package:flutter/material.dart';

import '../../casting/playback_coordinator.dart';
import '../../services/media_extras_cache_service.dart';
import '../../widgets/shared/nemesis_bottom_sheet.dart';
import '../models/media_item.dart';
import '../player_manager.dart';
import '../services/open_subtitles_service.dart';

/// Search OpenSubtitles by title and download a result directly into
/// playback. Opened from [SubtitleSheet]'s "Search online" entry.
class OpenSubtitlesSheet extends StatefulWidget {
  const OpenSubtitlesSheet({
    super.key,
    this.scrollController,
    this.castItem,
  });

  final ScrollController? scrollController;

  /// Set when the sheet was opened for a Jellyfin-server movie/episode
  /// that is playing on a Google Cast TV. The download then goes to the
  /// TV (PlaybackCoordinator.addOnlineSubtitleToServerCast) instead of the
  /// phone's own player, which is paused or not even holding this item.
  final MediaItem? castItem;

  @override
  State<OpenSubtitlesSheet> createState() => _OpenSubtitlesSheetState();
}

class _OpenSubtitlesSheetState extends State<OpenSubtitlesSheet> {
  late final TextEditingController _queryController = TextEditingController(
    text: _defaultQuery(widget.castItem ?? PlayerManager.instance.currentItem),
  );

  /// What to search for first. An episode's own title ("Pilot") finds
  /// nothing useful, so episodes search "Show S01E02"; movies add the year.
  static String _defaultQuery(MediaItem? it) {
    if (it == null) return '';
    final s = it.seasonNumber;
    final e = it.episodeNumber;
    final show = it.raw?['SeriesName']?.toString() ?? '';
    if (s != null && e != null && show.isNotEmpty) {
      return '$show S${s.toString().padLeft(2, '0')}E${e.toString().padLeft(2, '0')}';
    }
    final year = it.raw?['ProductionYear'];
    return year != null ? '${it.title} $year' : it.title;
  }

  bool _loading = false;
  // Set once a specific result starts downloading, so only that row
  // shows a spinner instead of the whole list locking up.
  int? _downloadingFileId;
  String? _error;
  List<OpenSubtitleResult> _results = const [];

  Future<void> _search() async {
    final query = _queryController.text.trim();
    if (query.isEmpty) return;

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final results = await OpenSubtitlesService.search(query: query);

      if (!mounted) return;
      setState(() {
        _results = results;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = 'Search failed: $error';
        _loading = false;
      });
    }
  }

  Future<void> _download(OpenSubtitleResult result) async {
    setState(() => _downloadingFileId = result.fileId);

    try {
      final content = await OpenSubtitlesService.download(result.fileId);

      final castItem = widget.castItem;
      if (castItem != null) {
        // Awaited: the TV reloads with the subtitle declared, and the
        // row spinner should stay up until it has it. Throws a message
        // safe to show if the TV can't take it.
        await PlaybackCoordinator.instance.addOnlineSubtitleToServerCast(
          content: content,
          displayTitle: result.releaseName,
          language: result.language,
        );
      } else {
        await PlayerManager.instance.loadDownloadedSubtitle(
          content: content,
          displayTitle: result.releaseName,
          language: result.language,
        );
      }

      // Cache this pick against the item that's actually playing, so
      // the next time this exact video plays it's applied automatically
      // (see PlayerManager._reapplyCachedSubtitleIfAny) instead of
      // needing this search + download repeated.
      final itemId = castItem?.id ?? PlayerManager.instance.currentItem?.id;
      if (itemId != null) {
        unawaited(
          MediaExtrasCacheService.saveSubtitle(
            itemId: itemId,
            content: content,
            displayTitle: result.releaseName,
            language: result.language,
          ),
        );
      }

      if (!mounted) return;

      // The sheet closing on its own used to be the only feedback —
      // easy to read as "did that actually do anything?" since it's the
      // same thing that happens on a plain dismiss. A snackbar on the
      // screen underneath makes the success explicit. Grabbed before
      // the pop, since `context` here still knows this sheet's
      // navigator; the messenger itself lives on the page below.
      final messenger = ScaffoldMessenger.maybeOf(context);
      Navigator.pop(context);
      messenger?.showSnackBar(
        SnackBar(
          content: Text(
            castItem != null
                ? '"${result.releaseName}" downloaded and sent to the TV'
                : '"${result.releaseName}" downloaded and selected',
          ),
          duration: const Duration(seconds: 3),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _downloadingFileId = null;
        _error = 'Download failed: $error';
      });
    }
  }

  @override
  void dispose() {
    _queryController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Bottom sheets don't get unbounded height for free — without an
    // explicit ceiling here, the Column below (title + search row +
    // error text + results list) can end up taller than what's left of
    // the screen once the keyboard is up, which is exactly what was
    // causing the ~54px bottom overflow.
    final maxSheetHeight = MediaQuery.sizeOf(context).height * 0.9;

    return ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxSheetHeight),
        child: SingleChildScrollView(
          controller: widget.scrollController,
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 10,
            // Keeps the search field/results clear of the keyboard
            // instead of being covered by it.
            bottom: 16 + MediaQuery.of(context).viewInsets.bottom,
          ),
          child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
              const NemesisSheetDragHandle(bottomMargin: 12),
              const Text(
                "Search OpenSubtitles",
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                ),
              ),

              const SizedBox(height: 16),

              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _queryController,
                      style: const TextStyle(color: Colors.white),
                      onSubmitted: (_) => _search(),
                      decoration: InputDecoration(
                        hintText: "Movie or show title",
                        hintStyle: const TextStyle(color: Colors.white38),
                        filled: true,
                        fillColor: Colors.white10,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    onPressed: _loading ? null : _search,
                    icon: const Icon(Icons.search, color: Colors.white),
                  ),
                ],
              ),

              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: const TextStyle(color: Colors.redAccent),
                ),
              ],

              const SizedBox(height: 8),

              if (_loading)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Center(
                    child: CircularProgressIndicator(color: Colors.white54),
                  ),
                )
              else
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.sizeOf(context).height * 0.5,
                  ),
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: _results.length,
                    itemBuilder: (_, i) {
                      final result = _results[i];
                      final downloading =
                          _downloadingFileId == result.fileId;

                      return ListTile(
                        title: Text(
                          result.releaseName,
                          style: const TextStyle(color: Colors.white),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          "${result.language.toUpperCase()} • "
                          "${result.downloadCount} downloads"
                          "${result.hearingImpaired ? ' • HI' : ''}",
                          style: const TextStyle(color: Colors.white54),
                        ),
                        trailing: downloading
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white54,
                                ),
                              )
                            : const Icon(
                                Icons.download,
                                color: Colors.white54,
                              ),
                        onTap: _downloadingFileId != null
                            ? null
                            : () => _download(result),
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
