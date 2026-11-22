import 'dart:async';

import 'package:flutter/material.dart';

import 'episode_card_compact.dart';
import '../../../player/services/playback_queue.dart';
import '../../../player/playback_service.dart';
import '../../../player/player_manager.dart';
import '../../../player/screens/player_navigation.dart';
import '../../../services/download_manager.dart';

class EpisodeList extends StatelessWidget {
  final List<dynamic> episodes;
  final bool loading;
  final String? seriesTitle;
  final String? seasonTitle;

  /// The series' IMDb id, threaded down to each EpisodeCardCompact so
  /// it can resolve its own episode-specific rating — see
  /// EpisodeCardCompact.seriesImdbId / RatingsService.fetchEpisode.
  final String? seriesImdbId;

  /// Called once the player screen closes after a tap here started
  /// playback. Lets the parent (which owns the episode list's data)
  /// re-fetch fresh watched/resume state for this season, so the next
  /// tap reflects wherever the session that just closed actually left
  /// off instead of replaying from whatever was loaded before playback
  /// started.
  final VoidCallback? onPlaybackClosed;

  const EpisodeList({
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

    // Portrait layout: thumbnail on the left, episode number / name /
    // preview / download button to its right (EpisodeCardCompact),
    // rather than the poster-style stack the landscape row uses.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListView.separated(
      // Without an explicit `padding`, ScrollView auto-injects the
      // device's MediaQuery safe-area insets (status-bar height above
      // the first item, home-indicator height below the last one) —
      // that's what was showing up as the oversized gaps above/below
      // this list in portrait. EpisodeRow (landscape) already sets its
      // own `padding` for the same reason and never hit this.
      padding: EdgeInsets.zero,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: episodes.length,
      separatorBuilder: (_, __) => const SizedBox(height: 4),
      itemBuilder: (context, index) {
        return EpisodeCardCompact(
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

            // Show the player immediately with a loading overlay
            // for the tapped episode, rather than waiting on
            // playQueue() (which opens the stream) before ever
            // navigating there.
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
      ],
    );
  }
}