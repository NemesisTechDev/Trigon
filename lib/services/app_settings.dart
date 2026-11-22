import 'dart:async';

import 'package:flutter/foundation.dart';

import 'jellyfin_services/storage_service.dart';
import 'ratings_service.dart';
import 'external_metadata/tmdb_service.dart';
import 'subtitle_appearance_settings.dart';
import 'equalizer_service.dart';

/// Global data-usage policy for both video and music playback — set
/// once in Settings, applied everywhere PlayerManager decides what
/// quality to stream at (see PlayerManager._autoVideoTarget/
/// _autoAudioTarget).
///
///  - [dataSaver]: always the second-lowest rung of whichever ladder
///    applies (video: 480p out of 360/480/720/1080; audio: the second-
///    lowest bitrate tier) — regardless of how good the network
///    actually is right now.
///  - [standard]: adaptive — picks a rung based on live network
///    conditions (see NetworkQualityService), stepping down
///    automatically on a poor/unstable connection and back up once
///    things improve.
///  - [maxQuality]: always the best available — for video this means
///    no transcoding constraint at all (the original file, exactly
///    like this app's pre-existing default behavior), and for audio
///    the top bitrate tier.
///
/// In the video player, the in-scene Quality selector can always
/// override whatever this resolves to for the current title (see
/// PlayerManager.setVideoQuality) — that override is session-scoped
/// and ends the moment the video player screen is exited.
enum PlaybackQualityMode { dataSaver, standard, maxQuality }

/// Where catalog titles (TMDB movies / shows) get their video from:
///  - [addons]: the person's installed addons; plays in the native media_kit
///    player (the original behaviour, and the default).
///  - [embed]: an embed server; plays in the web-based EmbedPlayerScreen.
/// Downloads, Jellyfin items, live TV and music are never affected.
enum PlaybackSourceMode { addons, embed }

/// Which embed server [PlaybackSourceMode.embed] uses by default. The choice
/// is stored by `.name`, so new servers are only ever added at the end.
enum EmbedServer { vidfast, vidsrc, vidlink }

/// In-memory, synchronously-readable cache of app-wide settings that get
/// persisted to disk via [StorageService]. Non-UI code (e.g. PlayerManager
/// deciding whether to auto-queue recommendations right as a song
/// finishes) needs to read these instantly rather than awaiting
/// SharedPreferences mid-playback, so everything is loaded once at
/// startup and kept in sync from here on — the Settings screen updates
/// these notifiers directly instead of writing to disk and hoping readers
/// notice.
class AppSettings {
  AppSettings._();

  /// Whether finishing a queue with nothing queued after it should
  /// automatically pull in similar content and keep playing, instead of
  /// just stopping. Covers both music (a finished queue pulls in similar
  /// songs) and movies (a finished movie with nothing next shows a "Next
  /// Movie" recommendation card, keyed off the same server-side
  /// Similar-items signal) — one setting for "keep the recommendations
  /// coming" rather than a separate toggle per media type. Off by
  /// default — this only ever turns on for someone who's explicitly
  /// opted in from Settings.
  static final ValueNotifier<bool> autoQueueRecommendations =
      ValueNotifier(true);

  /// Data Saver / Default / Max Quality — see [PlaybackQualityMode].
  /// Defaults to [PlaybackQualityMode.standard] (adaptive), matching
  /// this app's existing "just play the best sensible thing" behavior
  /// for anyone who's never touched this setting.
  static final ValueNotifier<PlaybackQualityMode> playbackQualityMode =
      ValueNotifier(PlaybackQualityMode.standard);

  /// Addons (native player) or Embed servers (web player). See
  /// [PlaybackSourceMode]. Defaults to addons so nothing changes for anyone
  /// who never opens this setting.
  static final ValueNotifier<PlaybackSourceMode> playbackSourceMode =
      ValueNotifier(PlaybackSourceMode.addons);

  /// Default embed server when [playbackSourceMode] is embed.
  static final ValueNotifier<EmbedServer> embedServer =
      ValueNotifier(EmbedServer.vidfast);

  /// Auto-link selection: when on, pressing Play skips the link list and
  /// plays the best link for the Streaming Quality setting (Default 720p,
  /// Max Quality 1080p, Data Saver 360p/480p, each the one with the most
  /// seeders/peers). See AutoLinkSelector. On by default; turn it off to be
  /// shown the link list every time.
  static final ValueNotifier<bool> autoLinkSelection = ValueNotifier(true);

  /// Blocks the ads the Embed servers' own pages load (their ad networks'
  /// scripts, frames and images) inside the embed web player. Affects only
  /// that player; the rest of the app is never filtered. On by default.
  static final ValueNotifier<bool> embedAdBlock = ValueNotifier(true);

  /// Downloads (movies, episodes, songs, addon files) only transfer over
  /// Wi-Fi or ethernet; on mobile data they wait and continue by themselves
  /// when Wi-Fi is back. On by default.
  static final ValueNotifier<bool> downloadWifiOnly = ValueNotifier(true);

  /// Sends anonymous usage statistics (screens opened, plays, downloads) to
  /// Firebase Analytics so the developer can see how the app is used. Off =
  /// nothing is collected. On by default.
  static final ValueNotifier<bool> shareUsageData = ValueNotifier(true);

  /// Call once at app startup (works whether or not the person is logged
  /// in yet — this doesn't touch the server).
  static Future<void> load() async {
    autoQueueRecommendations.value =
        await StorageService.getAutoQueueRecommendations();
    // Older builds stored typed-in API keys on the device; they now live
    // on the Worker, so remove any leftover copies.
    unawaited(StorageService.clearLegacyApiKeys());

    // Warms RatingsService's in-memory cache from disk as early as
    // possible (well before any screen that shows ratings has even
    // fetched its item list), so RatingsService.peek() can answer
    // synchronously on the very first build of a rating row instead of
    // every row's first frame always missing the cache. Fire-and-forget
    // — nothing here needs to block startup.
    unawaited(RatingsService.warmCache());

    // Same reasoning — warms TmdbService's on-disk cast/crew + studio
    // logo cache from disk as early as possible, so the movie/show
    // detail screen's background TMDB enrichment (see
    // CastCrewService/StudioService) never pays for a disk read that
    // could've already finished during app startup.
    unawaited(TmdbService.warmCache());

    // User's subtitle style (player overlay + casting) — see
    // SubtitleAppearanceSettings.
    unawaited(SubtitleAppearanceSettings.load());

    // Saved equalizer curve — re-applied to mpv's audio filter chain as soon
    // as it's read, so it's already active before the first track plays.
    unawaited(EqualizerService.instance.load());

    final storedMode = await StorageService.getPlaybackQualityMode();
    playbackQualityMode.value = PlaybackQualityMode.values.firstWhere(
      (m) => m.name == storedMode,
      orElse: () => PlaybackQualityMode.standard,
    );

    final storedSource = await StorageService.getPlaybackSourceMode();
    playbackSourceMode.value = PlaybackSourceMode.values.firstWhere(
      (m) => m.name == storedSource,
      orElse: () => PlaybackSourceMode.addons,
    );
    final storedServer = await StorageService.getEmbedServer();
    embedServer.value = EmbedServer.values.firstWhere(
      (m) => m.name == storedServer,
      orElse: () => EmbedServer.vidfast,
    );

    autoLinkSelection.value = await StorageService.getAutoLinkSelection();
    embedAdBlock.value = await StorageService.getEmbedAdBlock();
    downloadWifiOnly.value = await StorageService.getDownloadWifiOnly();
    shareUsageData.value = await StorageService.getShareUsageData();
  }

  static Future<void> setAutoQueueRecommendations(bool value) async {
    autoQueueRecommendations.value = value;
    await StorageService.setAutoQueueRecommendations(value);
  }

  static Future<void> setPlaybackQualityMode(PlaybackQualityMode value) async {
    playbackQualityMode.value = value;
    await StorageService.setPlaybackQualityMode(value.name);
  }

  static Future<void> setPlaybackSourceMode(PlaybackSourceMode value) async {
    playbackSourceMode.value = value;
    await StorageService.setPlaybackSourceMode(value.name);
  }

  static Future<void> setEmbedServer(EmbedServer value) async {
    embedServer.value = value;
    await StorageService.setEmbedServer(value.name);
  }

  static Future<void> setAutoLinkSelection(bool value) async {
    autoLinkSelection.value = value;
    await StorageService.setAutoLinkSelection(value);
  }

  static Future<void> setEmbedAdBlock(bool value) async {
    embedAdBlock.value = value;
    await StorageService.setEmbedAdBlock(value);
  }

  static Future<void> setShareUsageData(bool value) async {
    shareUsageData.value = value;
    await StorageService.setShareUsageData(value);
  }

  static Future<void> setDownloadWifiOnly(bool value) async {
    downloadWifiOnly.value = value;
    await StorageService.setDownloadWifiOnly(value);
  }
}
