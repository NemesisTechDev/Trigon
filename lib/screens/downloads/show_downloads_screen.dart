import 'dart:async';

import 'package:flutter/material.dart';

import '../../player/player_manager.dart';
import '../../player/playback_service.dart';
import '../../player/screens/player_navigation.dart';
import '../../player/services/playback_queue.dart';
import '../../services/download_manager.dart';
import '../../utils/bottom_clearance.dart';
import '../movie_details/widgets/season_selector.dart';
import 'widgets/downloaded_episode_tile.dart';

const _bg = Color(0xff161616);

/// The page a downloaded show's row (DownloadedShowTile) opens into —
/// deliberately not the full MovieDetailsScreen(downloadedOnly: true)
/// this used to push. That screen carries a hero backdrop, overview,
/// cast/crew, "More Like This", etc. — none of it means anything for
/// a device's own downloaded episodes. This is just the three things
/// that view actually needs: the show's name, a season selector, and
/// the episode list itself, each row reading whether that episode is
/// finished, still transferring, or queued straight from
/// DownloadManager's own live state rather than a network fetch.
class ShowDownloadsScreen extends StatefulWidget {
  final String seriesId;
  final String seriesName;

  const ShowDownloadsScreen({
    super.key,
    required this.seriesId,
    required this.seriesName,
  });

  @override
  State<ShowDownloadsScreen> createState() => _ShowDownloadsScreenState();
}

class _ShowDownloadsScreenState extends State<ShowDownloadsScreen> {
  String? _selectedSeasonId;

  Future<bool> _confirmDelete(String title) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xff1E1E1E),
        title: const Text(
          'Remove download?',
          style: TextStyle(color: Colors.white),
        ),
        content: Text(
          '"$title" will be deleted from your device.',
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
    return result ?? false;
  }

  Future<void> _deleteEpisode(DownloadRecord record) async {
    if (await _confirmDelete(record.title)) {
      await DownloadManager.instance.deleteDownload(record.id);
    }
  }

  Future<void> _playFromSeason(
    List<DownloadRecord> seasonEpisodes,
    int index,
  ) async {
    final queue = seasonEpisodes
        .map((r) => DownloadManager.instance.mediaItemForRecord(r))
        .toList();

    PlayerManager.instance.showLoadingPreview(queue[index]);

    unawaited(PlaybackService.playQueue(
      queue,
      startIndex: index,
      source: PlaybackSource.season,
      title: widget.seriesName,
    ));

    if (!mounted) return;
    await PlayerNavigation.open(context);
    // Back from the player: rebuild so the episode cards re-read what was
    // just watched (watched badge / progress bar).
    if (mounted) setState(() {});
  }

  /// Every season this series has anything downloaded (or downloading)
  /// for — synthesized from what's actually on disk / in flight, the
  /// same approach MovieDetailsScreen's own offline path already takes
  /// (there's no live /Seasons call to fall back on here either).
  List<Map<String, dynamic>> _seasons(
    List<DownloadRecord> episodes,
    List<DownloadTask> tasks,
  ) {
    final seasons = <Map<String, dynamic>>[];
    final seen = <String>{};

    void addSeason(String? id, String? name, num? number) {
      final seasonId = id ?? '';
      if (seasonId.isEmpty || seen.contains(seasonId)) return;
      seen.add(seasonId);
      seasons.add(<String, dynamic>{
        "Id": seasonId,
        "Name": (name != null && name.isNotEmpty)
            ? name
            : (number != null ? "Season ${number.toInt()}" : "Season"),
        "Number": number,
      });
    }

    for (final e in episodes) {
      addSeason(e.seasonId, e.seasonName, e.raw["ParentIndexNumber"] as num?);
    }
    for (final t in tasks) {
      addSeason(
        t.item["SeasonId"]?.toString(),
        t.item["SeasonName"]?.toString(),
        t.item["ParentIndexNumber"] as num?,
      );
    }

    seasons.sort((a, b) {
      final an = a["Number"] as num?;
      final bn = b["Number"] as num?;
      if (an != null && bn != null) return an.compareTo(bn);
      return 0;
    });

    return seasons;
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: DownloadManager.instance,
      builder: (context, _) {
        final episodes =
            DownloadManager.instance.episodesForSeries(widget.seriesId);
        final tasks =
            DownloadManager.instance.activeTasksForSeries(widget.seriesId);

        // Every episode of this series was removed (deleted here, or
        // from another surface) while this screen was open — nothing
        // left to show, so back out rather than sit on a blank page.
        if (episodes.isEmpty && tasks.isEmpty) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) Navigator.of(context).maybePop();
          });
        }

        final seasons = _seasons(episodes, tasks);
        final selectedSeasonId =
            seasons.any((s) => s["Id"] == _selectedSeasonId)
                ? _selectedSeasonId
                : (seasons.isNotEmpty ? seasons.first["Id"] as String : null);

        final seasonEpisodes = episodes
            .where((e) => e.seasonId == selectedSeasonId)
            .toList()
          ..sort(
              (a, b) => (a.episodeIndex ?? 0).compareTo(b.episodeIndex ?? 0));
        final seasonTasks = tasks
            .where((t) => t.item["SeasonId"]?.toString() == selectedSeasonId)
            .toList();

        // One combined, episode-number-ordered list — a task not yet
        // turned into a record sits wherever its own episode number
        // places it among the finished ones either side of it.
        final rows = <_EpisodeRow>[
          ...seasonEpisodes.map(_EpisodeRow.record),
          ...seasonTasks.map(_EpisodeRow.task),
        ]..sort((a, b) => a.number.compareTo(b.number));

        final seriesArtPath = episodes.isNotEmpty
            ? (episodes.first.thumbPath ?? episodes.first.posterPath)
            : null;

        final viewPadding = MediaQuery.paddingOf(context);

        return Scaffold(
          backgroundColor: _bg,
          body: Padding(
            padding: EdgeInsets.only(
              top: viewPadding.top,
              left: viewPadding.left,
              right: viewPadding.right,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Row(
                    children: [
                      IconButton(
                        onPressed: () => Navigator.of(context).maybePop(),
                        icon:
                            const Icon(Icons.arrow_back, color: Colors.white),
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          widget.seriesName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 26,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                if (seasons.isNotEmpty)
                  SeasonSelector(
                    seriesId: widget.seriesId,
                    seasons: seasons,
                    selectedSeasonId: selectedSeasonId,
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    onSeasonSelected: (id) =>
                        setState(() => _selectedSeasonId = id),
                  ),
                const SizedBox(height: 14),
                Expanded(
                  child: rows.isEmpty
                      ? const Center(
                          child: Text(
                            "No episodes in this season",
                            style: TextStyle(color: Colors.white54),
                          ),
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                          itemCount: rows.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 4),
                          itemBuilder: (context, index) {
                            final row = rows[index];
                            final record = row.record;

                            return DownloadedEpisodeTile(
                              record: record,
                              task: row.task,
                              seriesArtPath: seriesArtPath,
                              onTap: record == null
                                  ? null
                                  : () => _playFromSeason(
                                        seasonEpisodes,
                                        seasonEpisodes.indexOf(record),
                                      ),
                              onDeleteRequested: record == null
                                  ? null
                                  : () => _deleteEpisode(record),
                            );
                          },
                        ),
                ),
                BottomClearanceBuilder(
                  builder: (context, clearance) => SizedBox(
                    height: 12 +
                        MediaQuery.paddingOf(context).bottom +
                        clearance,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Either a finished [DownloadRecord] or a still-active [DownloadTask]
/// for one episode — whichever DownloadManager actually has for it
/// right now — tagged with the episode number the combined list sorts
/// by.
class _EpisodeRow {
  final DownloadRecord? record;
  final DownloadTask? task;

  const _EpisodeRow._(this.record, this.task);

  factory _EpisodeRow.record(DownloadRecord record) =>
      _EpisodeRow._(record, null);
  factory _EpisodeRow.task(DownloadTask task) => _EpisodeRow._(null, task);

  num get number =>
      record?.episodeIndex ?? (task?.item["IndexNumber"] as num?) ?? 0;
}
