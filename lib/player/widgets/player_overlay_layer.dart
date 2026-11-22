import 'package:flutter/material.dart';

import '../../casting/cast_skip_controller.dart';
import '../../casting/ui/cast_ui.dart' show runCastCommand;
import '../../player/player_manager.dart';
import '../../utils/responsive.dart';
import '../models/skip_segment.dart';
import '../services/playback_queue.dart';

import '/widgets/player/loading_overlay.dart';
import 'next_episode_overlay.dart';
import 'next_movie_overlay.dart';
import 'next_show_overlay.dart';
import 'skip_segment_button.dart';
import 'still_watching_overlay.dart';

class PlayerOverlayLayer extends StatelessWidget {
  const PlayerOverlayLayer({
    super.key,
  });

  /// Builds a "S02E06"-style code from an episode's season/episode
  /// numbers, or null if either is missing.
  static String? _episodeCode(int? season, int? episode) {
    if (season == null || episode == null) return null;

    final s = season.toString().padLeft(2, '0');
    final e = episode.toString().padLeft(2, '0');

    return "S${s}E$e";
  }

  @override
  Widget build(BuildContext context) {
    final manager = PlayerManager.instance;

    return LayoutBuilder(
      builder: (context, playerConstraints) {
        return Stack(
      children: [

        /// Loading
        ValueListenableBuilder<bool>(
          valueListenable: manager.loading,
          builder: (_, loading, __) {
            return LoadingOverlay(loading: loading);
          },
        ),

        /// Buffering is NOT drawn here any more. It used to sit on top of
        /// the controls, and its dim layer swallowed every touch, so the
        /// controls and gestures were dead while the video buffered.
        /// VideoPlayerScreen now stacks BufferingOverlay beneath
        /// PlayerControlsLayer and it ignores pointers. (It still only shows
        /// once playback has started: the initial load is LoadingOverlay's.)

        /// Skip Intro / Credits + Next Episode + Next Show + Next Movie
        ///
        /// All anchor bottom-right, just above PlayerBottomBar's seek
        /// bar (the top-most row of that bar), tracking its real
        /// measured height via `manager.bottomBarHeight` rather than a
        /// hard-coded margin — see MeasureSize in PlayerBottomBar.
        /// Mutually exclusive, checked in priority order: Next Episode
        /// (episode queues with another episode still queued), then
        /// Next Show (episode queues with nothing left queued — the
        /// last episode of a series — when recommendations are on and
        /// one was found), then Next Movie (everything else, same
        /// recommendations gate), then the plain Skip Intro/Credits
        /// button. Next Episode and Next Show can never both apply to
        /// the same finished episode (one requires `queue.hasNext`, the
        /// other requires it to be false), and Next Show/Next Movie are
        /// likewise mutually exclusive on `isEpisodeQueue`. Dismissing
        /// any overlay falls through to the next check on the very next
        /// rebuild — e.g. dismissing Next Show while still inside the
        /// Outro segment reveals the ordinary Skip Credits button
        /// underneath it, exactly as if the recommendation had never
        /// been offered.
        ValueListenableBuilder<double>(
          valueListenable: manager.bottomBarHeight,
          builder: (_, barHeight, __) {

            const gap = 14.0;
            const sideMargin = 20.0;

            // In landscape, the top edge that matters is PlayerTopBar's
            // real bottom edge, not a guessed constant — the bar's
            // height moves with the safe-area inset, TV mode's larger
            // icon size, and fullscreen vs windowed padding (see
            // PlayerManager.topBarHeight's doc comment). A fixed 16
            // only ever matched that bar's own internal top padding,
            // not its full height, so a card tall enough to use most of
            // its allotted room could render up under/behind the top
            // bar's icons instead of clearing them. Portrait keeps the
            // original fixed breathing-room margin unchanged — this
            // widget isn't laid out against the top bar the same way
            // there, and only landscape was reported as clipping.
            final isLandscape = Responsive.isLandscape(context);

            // Landscape only: much tighter clearance above the seek bar
            // and below the top bar than the shared 14, so the (now
            // upscaled) horizontal card can use that space instead of
            // leaving visible gaps. Portrait keeps `gap` unchanged.
            final cardGap = isLandscape ? 5.0 : gap;

            return ValueListenableBuilder<double>(
              valueListenable: manager.topBarHeight,
              builder: (_, topBarHeight, __) {

            final topMargin =
                isLandscape ? (topBarHeight + cardGap) : 16.0;

            // The card used to just assume 300px of width and however
            // tall its content naturally came out to would always fit.
            // On a short landscape screen (a smaller phone) — or the
            // same phone with a larger text-scale setting inflating
            // the title/button text — that assumption breaks: the card
            // pushes past the top of the screen and/or overlaps the
            // bottom bar it's supposed to sit above. These two limits
            // are the actual room available right now, computed from
            // this Stack's real measured size rather than guessed.
            //
            // The upper bound below is this cap, not the card's own
            // native design width (360, see NextEpisodeOverlay/
            // NextMovieOverlay) — below it, FittedBox's scaleDown
            // shrinks the card to fit; above it, scaleDown never
            // enlarges past the design size, so this cap is what
            // actually decides the card's real on-screen size whenever
            // there's more room than that.
            //
            // Landscape has a lot of width to spare (the video fills
            // it, but the card only needs to share the strip above the
            // seek bar), so it's allowed up to the full design width
            // of the short, wide horizontal card, which is scaled UP to
            // fill the available strip (up to 350 wide) — the stacked
            // portrait card is too tall for that strip and got shrunk
            // to under half size.
            // Portrait is narrow enough that the same cap made the
            // card read as a nearly-full-width banner instead of a
            // small "up next" chip tucked to the right, so it gets a
            // much tighter cap — small but still legible.
            final maxCardWidth =
                (playerConstraints.maxWidth - sideMargin * 2)
                    .clamp(0.0, isLandscape ? 350.0 : 190.0);
            final maxCardHeight =
                (playerConstraints.maxHeight - barHeight - cardGap - topMargin)
                    .clamp(0.0, double.infinity);

            return Padding(
              padding: EdgeInsets.only(
                right: sideMargin,
                bottom: barHeight + cardGap,
              ),
              child: Align(
                alignment: Alignment.bottomRight,
                child: ValueListenableBuilder<bool>(
                  valueListenable: manager.showNextEpisode,
                  builder: (_, showNext, __) {

                    if (showNext) {
                      return _NextEpisodeCard(
                        manager: manager,
                        maxWidth: maxCardWidth,
                        maxHeight: maxCardHeight,
                        horizontal: isLandscape,
                      );
                    }

                    return ValueListenableBuilder<bool>(
                      valueListenable: manager.showNextShow,
                      builder: (_, showNextShow, __) {

                        if (showNextShow) {
                          return _NextShowCard(
                            manager: manager,
                            maxWidth: maxCardWidth,
                            maxHeight: maxCardHeight,
                            horizontal: isLandscape,
                          );
                        }

                        return ValueListenableBuilder<bool>(
                          valueListenable: manager.showNextMovie,
                          builder: (_, showNextMovie, __) {

                            if (showNextMovie) {
                              return _NextMovieCard(
                                manager: manager,
                                maxWidth: maxCardWidth,
                                maxHeight: maxCardHeight,
                                horizontal: isLandscape,
                              );
                            }

                            return ValueListenableBuilder<SkipSegment?>(
                              valueListenable: manager.activeSkipSegment,
                              builder: (_, segment, __) {

                                if (segment == null) {
                                  return const SizedBox.shrink();
                                }

                                return SkipSegmentButton(
                                  segment: segment,

                                  onPressed: () async {

                                    // While a video is being cast the TV is
                                    // what must skip, not local mpv (which is
                                    // paused/unopened) — CastSkipController
                                    // seeks the cast session instead.
                                    final castSkip = CastSkipController.instance;
                                    if (castSkip.isDriving) {
                                      await runCastCommand(
                                        context,
                                        () => castSkip.skip(segment),
                                      );
                                      return;
                                    }

                                    manager.skipPressed = true;

                                    await manager.seekTo(segment.manual
                                        ? manager.position.value +
                                            const Duration(seconds: 85)
                                        : segment.end);

                                    manager.activeSkipSegment.value = null;

                                    manager.skipPressed = false;
                                  },
                                );
                              },
                            );
                          },
                        );
                      },
                    );
                  },
                ),
              ),
            );
              },
            );
          },
        ),

        /// Still Watching (idle safety) prompt
        ///
        /// Deliberately the last child in this Stack so it paints above
        /// everything else here — controls, skip pill, next episode/movie
        /// cards — matching how VideoPlayerScreen's own
        /// _PlaybackErrorOverlay takes over the whole screen for its own
        /// full-attention moment.
        ValueListenableBuilder<bool>(
          valueListenable: manager.showStillWatching,
          builder: (_, show, __) {
            if (!show) return const SizedBox.shrink();

            return StillWatchingOverlay(
              onContinue: () {
                manager.registerActivity();
              },
              onExpired: () {
                manager.showStillWatching.value = false;
                Navigator.of(context).maybePop();
              },
            );
          },
        ),
      ],
        );
      },
    );
  }
}

class _NextEpisodeCard extends StatelessWidget {
  final PlayerManager manager;
  final double maxWidth;
  final double maxHeight;
  final bool horizontal;

  const _NextEpisodeCard({
    required this.manager,
    required this.maxWidth,
    required this.maxHeight,
    this.horizontal = false,
  });

  @override
  Widget build(BuildContext context) {
    final episode = manager.nextEpisode.value;

    if (episode == null) {
      return const SizedBox.shrink();
    }

    final queue = PlaybackQueue.instance;

    final isEpisodeQueue = queue.source == PlaybackSource.season ||
        queue.source == PlaybackSource.series;

    // `episode.subtitle` resolves to the series name for an Episode
    // item (see MediaService.mediaItemFromJellyfin), which is exactly
    // what "Next episode on {series}" needs.
    final seriesName = isEpisodeQueue ? episode.subtitle : null;

    final episodeCode = isEpisodeQueue
        ? PlayerOverlayLayer._episodeCode(
            episode.seasonNumber,
            episode.episodeNumber,
          )
        : null;

    return NextEpisodeOverlay(
      title: episode.title,
      seriesName: seriesName,
      episodeCode: episodeCode,
      image: episode.image,
      maxWidth: maxWidth,
      maxHeight: maxHeight,
      horizontal: horizontal,

      onCancel: () {
        manager.showNextEpisode.value = false;
      },

      onPlayNow: () async {

        manager.showNextEpisode.value = false;

        await manager.playNext();
      },
    );
  }
}

class _NextShowCard extends StatelessWidget {
  final PlayerManager manager;
  final double maxWidth;
  final double maxHeight;
  final bool horizontal;

  const _NextShowCard({
    required this.manager,
    required this.maxWidth,
    required this.maxHeight,
    this.horizontal = false,
  });

  @override
  Widget build(BuildContext context) {
    final firstEpisode = manager.nextShowRecommendation.value;

    if (firstEpisode == null) {
      return const SizedBox.shrink();
    }

    // `firstEpisode.subtitle`/`.backdrop`/`.logo` already resolve to the
    // parent series' own name/art (see MediaService.mediaItemFromJellyfin),
    // so this card reads as "recommended show", not "next episode" —
    // see NextShowOverlay's doc comment.
    return NextShowOverlay(
      title: firstEpisode.subtitle,
      backdrop: firstEpisode.backdrop,
      logo: firstEpisode.logo,
      maxWidth: maxWidth,
      maxHeight: maxHeight,
      horizontal: horizontal,

      onCancel: () {
        manager.showNextShow.value = false;
        manager.dismissNextShowRecommendation();
      },

      onPlayNow: () async {

        manager.showNextShow.value = false;

        // Casting: same queue move as below, but guaranteed to reach the TV
        // even when the queue doesn't hold the pick right after the
        // current item — see CastSkipController.playRecommendation.
        if (CastSkipController.instance.isDriving) {
          await CastSkipController.instance.playRecommendation(firstEpisode);
          return;
        }

        await manager.playNext();
      },
    );
  }
}

class _NextMovieCard extends StatelessWidget {
  final PlayerManager manager;
  final double maxWidth;
  final double maxHeight;
  final bool horizontal;

  const _NextMovieCard({
    required this.manager,
    required this.maxWidth,
    required this.maxHeight,
    this.horizontal = false,
  });

  @override
  Widget build(BuildContext context) {
    final movie = manager.nextMovieRecommendation.value;

    if (movie == null) {
      return const SizedBox.shrink();
    }

    return NextMovieOverlay(
      title: movie.title,
      backdrop: movie.backdrop,
      logo: movie.logo,
      maxWidth: maxWidth,
      maxHeight: maxHeight,
      horizontal: horizontal,

      onCancel: () {
        manager.showNextMovie.value = false;
        manager.dismissNextMovieRecommendation();
      },

      onPlayNow: () async {

        manager.showNextMovie.value = false;

        // Casting: see _NextShowCard — a direct "Cast to" has no queue to
        // advance, so the pick is played on the TV directly.
        if (CastSkipController.instance.isDriving) {
          await CastSkipController.instance.playRecommendation(movie);
          return;
        }

        await manager.playNext();
      },
    );
  }
}