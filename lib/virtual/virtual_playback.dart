import 'dart:async';

import 'package:flutter/material.dart';

import '../addons/addon_manager.dart';
import '../catalog/binge_coordinator.dart';
import '../catalog/catalog_models.dart';
import '../catalog/catalog_playback.dart';
import '../catalog/link_fallback.dart';
import '../catalog/source_chooser.dart';
import '../catalog/tmdb_catalog_service.dart';
import '../embed/embed_player_screen.dart';
import '../player/helpers/player_orientation.dart';
import '../library/source_preferences.dart';
import '../library/watch_history_service.dart';
import '../player/load_progress.dart';
import '../player/models/media_item.dart';
import '../player/playback_service.dart';
import '../player/services/playback_queue.dart';
import '../casting/cast_manager.dart';
import '../services/app_settings.dart';
import '../services/external_media_handler.dart';
import '../torrent/torrent_engine.dart';
import '../services/parental/parental_controls.dart';
import 'virtual_catalog.dart';
import 'virtual_images.dart';

/// Starts the services the virtual server and the player bridge rely on.
/// Called once from main().
class VirtualBootstrap {
  VirtualBootstrap._();
  static bool _started = false;

  static Future<void> init() async {
    if (_started) return;
    _started = true;
    await VirtualImages.load();
    await AddonManager.instance.load();
    await SourcePreferences.instance.load();
    await WatchHistoryService.instance.init();
    BingeCoordinator.instance.init();
  }
}

/// Turns "play this virtual movie/episode" into "ask the person's addons for
/// a stream and play that".
///
/// The original Play buttons build a Jellyfin MediaItem and hand it to
/// PlaybackService. Items that came from the virtual server carry
/// `NamesisVirtual`, so PlaybackService passes them here instead. By then the
/// caller has already opened the player screen in its loading state.
class VirtualPlayback {
  VirtualPlayback._();

  static bool isVirtual(MediaItem item) =>
      item.raw?['NamesisVirtual'] == true;

  /// [fromPlayer]: the player screen is already open (episode panel, next
  /// show), so cancelling must not close it.
  static Future<void> play(MediaItem item, {bool fromPlayer = false}) async {
    try {
      final v = VId.parse(item.id);

      // Parental Controls: maturity / blocked titles / bedtime / daily limit.
      // Shows its own dialog (and a PIN prompt for a parent) when blocking.
      if (!await ParentalControls.instance.authorizePlayback(titleId: item.id)) {
        _abort(null, fromPlayer: fromPlayer);
        return;
      }

      CatalogTitle? title;
      CatalogEpisode? episode;
      if (v.kind == 'movie') {
        title = await TmdbCatalogService.details(CatalogType.movie, v.tmdbId);
      } else if (v.kind == 'episode') {
        title = await TmdbCatalogService.details(CatalogType.series, v.tmdbId);
        final season = v.season;
        final number = v.episode;
        if (season != null && number != null) {
          final eps = await TmdbCatalogService.episodes(v.tmdbId, season);
          for (final e in eps) {
            if (e.number == number) {
              episode = e;
              break;
            }
          }
          episode ??= CatalogEpisode(
            season: season,
            number: number,
            name: item.title,
            overview: '',
          );
        }
      }

      if (title == null) {
        _abort('Could not load this title. Check your connection.',
            fromPlayer: fromPlayer);
        return;
      }
      // Embed servers: hand over to the web player instead of the addons.
      // The native player screen (loading, or already playing when this came
      // from the episode panel) is closed first. Not while casting: a web
      // embed can't be sent to a TV, so casting always uses the addons.
      if (AppSettings.playbackSourceMode.value == PlaybackSourceMode.embed &&
          !CastManager.instance.isCasting) {
        // The embed player replaces this screen: keep the phone in landscape
        // for it. Without this the closing native screen released the
        // landscape lock after the embed screen had set it, so the embed
        // player ended up in portrait.
        PlayerOrientation.beginHandoff();
        final nav = ExternalMediaHandler.instance.navigatorKey.currentState;
        await nav?.maybePop();
        final embedCtx = _overlayContext();
        if (embedCtx != null && embedCtx.mounted) {
          await EmbedPlayerScreen.open(
            embedCtx,
            title: title,
            episode: episode,
            resumeAt: item.playbackPosition,
          );
        } else {
          PlayerOrientation.cancelHandoff();
        }
        return;
      }

      if (!AddonManager.instance.hasStreamAddons) {
        _abort('No addon installed. Open Profile > Addons to add one.',
            fromPlayer: fromPlayer);
        return;
      }

      final ctx = _overlayContext();
      if (ctx == null) {
        _abort(null, fromPlayer: fromPlayer);
        return;
      }

      final stream = await SourceChooser.choose(
        ctx,
        title: title,
        episode: episode,
      );
      if (stream == null) {
        // Cancelled, or no addon had a stream.
        _abort(null, fromPlayer: fromPlayer);
        return;
      }

      // A source is chosen: the loading logo stops being dim and starts
      // filling. For a torrent its info hash lets the fill follow the
      // engine's real numbers while it prepares the file.
      PlaybackLoadProgress.instance.linkSelected(torrentHash: stream.infoHash);

      unawaited(SourcePreferences.instance
          .remember('${title.type.tmdb}:${title.tmdbId}', stream));

      final resumeAt = item.playbackPosition ??
          WatchHistoryService.instance.positionFor(title, episode);

      // Never waits for subtitles: a direct link is handed to the player at
      // once, and the subtitles are attached once it plays.
      PreparedItem prepared;
      try {
        prepared = await CatalogPlayback.buildItemForStart(
          title: title,
          stream: stream,
          episode: episode,
          resumeAt: resumeAt,
        );
      } on TorrentException catch (e) {
        // The auto selector may have another link to try: the loading
        // screen stays and playback moves on to it.
        if (await LinkFallbackCoordinator.instance.recoverFromResolveFailure(
            title, episode, e.message,
            resumeAt: resumeAt)) {
          return;
        }
        rethrow;
      }

      // An episode is queued as a SEASON from the very start. The player's
      // episode-list button and its Next Episode card only appear for a
      // season queue, and BingeCoordinator used to be the only thing that
      // switched the queue to `season` - after it had found and resolved
      // the next episode's stream, which can take long (or never happen).
      // A title resumed from Continue Watching hit exactly that gap, so
      // those controls were missing until (or unless) it finished. Next /
      // Previous already work for any addon episode on their own.
      await PlaybackService.playQueue(
        [prepared.item],
        source: episode != null
            ? PlaybackSource.season
            : PlaybackSource.unknown,
        title: episode != null ? title.title : null,
        artwork: episode != null ? title.backdropUrl : null,
      );
      CatalogPlayback.attachSubtitlesWhenPlaying(prepared);
    } on TorrentException catch (e) {
      debugPrint('[VirtualPlayback] torrent failed: ${e.message}');
      _abort(e.message, fromPlayer: fromPlayer);
    } catch (e) {
      debugPrint('[VirtualPlayback] play failed: $e');
      _abort('Could not start playback.', fromPlayer: fromPlayer);
    }
  }

  static BuildContext? _overlayContext() =>
      ExternalMediaHandler.instance.navigatorKey.currentState?.overlay
          ?.context;

  /// Closes the player screen that is sitting in its loading state, with an
  /// optional message.
  static void _abort(String? message, {bool fromPlayer = false}) {
    final nav = ExternalMediaHandler.instance.navigatorKey.currentState;
    final ctx = nav?.overlay?.context;
    if (message != null && ctx != null) {
      ScaffoldMessenger.maybeOf(ctx)?.showSnackBar(SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        backgroundColor: const Color(0xff1A1A1A),
      ));
    }
    // While casting the local player screen is never opened, so there is
    // nothing to close.
    if (!fromPlayer && !CastManager.instance.isCasting) nav?.maybePop();
  }
}
