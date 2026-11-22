import 'dart:async';

import 'package:flutter/material.dart';

import 'episode_card_horizontal.dart';
import '../../../player/services/playback_queue.dart';
import '../../../player/playback_service.dart';
import '../../../player/player_manager.dart';
import '../../../player/screens/player_navigation.dart';
import '../../../services/download_manager.dart';

/// Horizontal, single-row rendering of a season's episodes for the
/// landscape detail screen — same tap/playback wiring as EpisodeList
/// (still used by the portrait layout's vertical list), just laid out
/// as a scrolling row of poster-style cards instead.
class EpisodeRow extends StatelessWidget {
  final List<dynamic> episodes;
  final bool loading;
  final String? seriesTitle;
  final String? seasonTitle;

  /// The series' IMDb id, threaded down to each EpisodeCardHorizontal
  /// so it can resolve its own episode-specific rating — see
  /// EpisodeCardHorizontal.seriesImdbId / RatingsService.fetchEpisode.
  final String? seriesImdbId;

  /// Called once the player screen closes after a tap here started
  /// playback, so the parent can re-fetch fresh watched/resume state
  /// for this season.
  final VoidCallback? onPlaybackClosed;

  const EpisodeRow({
    super.key,
    required this.episodes,
    required this.loading,
    this.seriesTitle,
    this.seasonTitle,
    this.seriesImdbId,
    this.onPlaybackClosed,
  });

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 40),
        child: Center(
          child: CircularProgressIndicator(),
        ),
      );
    }

    if (episodes.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 30),
        child: Center(
          child: Text(
            "No episodes available",
            style: TextStyle(
              color: Colors.white54,
              fontSize: 16,
            ),
          ),
        ),
      );
    }

    // Was 305 — the card's actual content (thumbnail + episode number
    // + name + 2-line overview + download button) only runs to about
    // 250px tall, so the extra ~55px of unused box below the cards
    // was stacking on top of the SizedBox gap that follows this row,
    // making the gap before the next section read as much bigger than
    // intended. Tightened to hug the real content height instead.
    //
    // (That 250px estimate assumed the download button was its 20px
    // icon size, but IconButton claims Material's 48dp minimum tap
    // target regardless — the real overflow culprit, now fixed at the
    // card level in EpisodeCardHorizontal, so 258 has proper headroom
    // again.)
    return SizedBox(
      height: 258,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        scrollDirection: Axis.horizontal,
        itemCount: episodes.length,
        separatorBuilder: (_, __) => const SizedBox(width: 16),
        itemBuilder: (context, index) {
          return EpisodeCardHorizontal(
            episode: episodes[index],
            seriesImdbId: seriesImdbId,
            onTap: () async {
              // Plays from the local file automatically for any
              // episode that's been downloaded — same queue either
              // way, so next/previous episode controls keep working
              // when mixing downloaded and streamed episodes.
              final queue = episodes
                  .map((e) => DownloadManager.instance
                      .mediaItemFor(Map<String, dynamic>.from(e)))
                  .toList();

              // Show the player immediately with a loading overlay for
              // the tapped episode, rather than waiting on playQueue()
              // (which opens the stream) before ever navigating there.
              PlayerManager.instance.showLoadingPreview(queue[index]);

              unawaited(PlaybackService.playQueue(
                queue,
                startIndex: index,
                source: PlaybackSource.season,
                title: seasonTitle,
              ));

              if (!context.mounted) return;

              await PlayerNavigation.open(context);

              onPlaybackClosed?.call();
            },
          );
        },
      ),
    );
  }
}
