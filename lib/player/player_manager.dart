import 'dart:async';
import 'dart:convert' show utf8;
import 'dart:io'
    show File, HttpClient, HttpHeaders, InternetAddress, SocketException, HandshakeException;

import 'package:dio/dio.dart' show Dio, BaseOptions, Options, ResponseType;
import '../virtual/virtual_playback.dart';
import '../virtual/virtual_catalog.dart';
import '../services/analytics_service.dart';
import 'playback_service.dart';
import 'load_progress.dart';
import 'services/segment_service.dart';
import 'services/frame_grabber.dart';
import '../catalog/catalog_playback.dart';
import '../catalog/next_episode_service.dart';
import '../library/watch_entry.dart';
import 'package:flutter/material.dart';
// NOTE: not previously a dependency of this project — add
// `audio_session: ^0.1.25` (or whatever's current) to pubspec.yaml.
// media_kit/mpv has no concept of Android audio focus at all — it just
// plays, unconditionally, regardless of what else is making sound. This
// is what makes _configureAudioSession()/_handleAudioInterruption() below
// possible: it's the package audio_service itself defers to for actually
// talking to AudioManager (request focus, listen for loss/duck/regain,
// mirror route changes), independent of whatever's doing the actual
// decoding.
import 'package:audio_session/audio_session.dart';
import '../screens/profile/parental/parental_prompts.dart';
import '../services/parental/parental_controls.dart';
import '../services/sidecar_subtitles.dart';
// NOTE: not previously a dependency of this project — add
// `path_provider: ^2.1.0` (or whatever's current) to pubspec.yaml. Used
// to find a writable temp directory to point mpv's own on-disk demuxer
// cache at (see the `cache-dir` property set in `initialize()`) — mpv
// needs somewhere it's guaranteed to be able to write when it fetches
// a subtitle (or anything else) over http(s), and its build-time
// default isn't reliably writable on Android's sandboxed storage.
import 'package:path_provider/path_provider.dart';
// media_kit ships its own AudioTrack/SubtitleTrack classes (the native
// mpv track descriptors). Those are only used internally, to actually
// switch tracks — everywhere else in this app (the selector UI, track
// lists, etc.) works with the Jellyfin-backed models below instead, so
// the native ones are hidden here and reached through the `mk` prefix.
import 'package:media_kit/media_kit.dart' hide AudioTrack, SubtitleTrack;
import 'package:media_kit/media_kit.dart' as mk
    show AudioTrack, SubtitleTrack;
import 'package:media_kit_video/media_kit_video.dart';
import 'services/playback_queue.dart';
import 'services/media_stream_parser.dart';
import 'services/trickplay_service.dart';
import '../player/services/playback_progress_service.dart';
import '../player/services/offline_progress_service.dart';
import '../services/offline_progress_store.dart';
import 'models/skip_segment.dart';
import 'models/media_item.dart';
import 'models/audio_track.dart';
import 'models/subtitle_track.dart';
import '../casting/default_subtitle.dart';
import '../services/jellyfin_services/media_service.dart';
import '../services/media_extras_cache_service.dart';
import 'services/music_recommendation_service.dart';
import 'services/movie_recommendation_service.dart';
import 'services/show_recommendation_service.dart';
import '../services/app_settings.dart';
import '../services/external_media_handler.dart'; // NAMESIS PRIME: failed-open snackbar
import '../services/subtitle_appearance_settings.dart';
import '../services/download_manager.dart';
import '../services/local_music_service.dart';
import '../services/network_quality_service.dart';
import 'models/quality_levels.dart';

class PlayerManager {
  // Keeps the favorite state in sync with whatever's currently playing
  // as soon as the item changes, so every consumer — the audio player
  // screen, the lock-screen/notification widget, etc. — reads from one
  // canonical place instead of each maintaining its own copy.
  PlayerManager._() {
    currentItemNotifier.addListener(() => loadFavoriteState(currentItem));
    currentItemNotifier.addListener(_recomputeVideoQualityOptions);
  }

  static final PlayerManager instance =
  PlayerManager._();

  final Player player = Player(
    configuration: const PlayerConfiguration(
      // Without this, mpv falls back to a plain built-in renderer for
      // .ass/.ssa subtitles that ignores their styling (fonts, position,
      // karaoke effects) — libass is the renderer that actually honors
      // it, and is what every desktop mpv build uses by default.
      libass: true,
      // Defaults to MPVLogLevel.error, which means mpv itself never
      // even generates a `warn`/`info`-level message natively — no
      // amount of filtering on the Dart side of `player.stream.log`
      // can surface something that was never emitted in the first
      // place. `warn` catches subtitle-relevant non-fatal complaints
      // (e.g. a font substitution, a demuxer warning on a malformed
      // sidecar file) that `error` alone would hide completely, without
      // the sheer volume `info`/`v`/`debug` would dump into the log on
      // every single frame.
      logLevel: MPVLogLevel.warn,
    ),
  );

  // --------------------------------------------------------------------
  // Audio focus (see _configureAudioSession/_handleAudioInterruption,
  // wired in from initialize()). Nothing else in this file touches
  // these — they exist purely to let an interruption event pause the
  // current fade cleanly if a second interruption arrives mid-fade, and
  // to know whether an interruption's *end* should resume playback or
  // leave it paused.
  // --------------------------------------------------------------------
  AudioSession? _audioSession;
  int _fadeToken = 0;
  bool _resumeOnInterruptionEnd = false;

  // --------------------------------------------------------------------
  // Video volume boost (VLC-style "beyond 100%", up to 200%).
  //
  // The device's own volume tops out at 100%; anything above that is
  // software gain applied by mpv itself via its `volume` property
  // (100 = unchanged, 200 = double amplitude). mpv's own `volume-max`
  // defaults to 130, so it is raised to [maxVolumeGain] before the
  // first boosted value is set. Only VideoPlayerScreen ever sets this
  // (and only for local playback — never while casting), and it resets
  // it to 100 on dispose so music/other videos are never boosted.
  //
  // `_volumeGain` is also what the audio-focus fade/restore paths put
  // the player's volume back to afterwards, instead of a hard-coded 100
  // that would silently drop a boost on every pause -> play.
  // --------------------------------------------------------------------
  static const double maxVolumeGain = 200;
  double _volumeGain = 100;
  bool _volumeMaxConfigured = false;

  /// Current mpv volume gain in percent (100 = no boost).
  double get volumeGain => _volumeGain;

  Future<void> setVolumeGain(double percent) async {
    final value = percent.clamp(100.0, maxVolumeGain).toDouble();
    _volumeGain = value;

    try {
      final platform = player.platform;
      if (!_volumeMaxConfigured && platform is NativePlayer) {
        await platform.setProperty('volume-max', maxVolumeGain.toStringAsFixed(0));
        _volumeMaxConfigured = true;
      }
      // Last write wins: a newer call may have landed while awaiting.
      await player.setVolume(_volumeGain);
    } catch (_) {
      // Best-effort — a failed boost must never affect playback itself.
    }
  }

  Future<void> resetVolumeGain() async {
    if (_volumeGain == 100) return;
    _volumeGain = 100;
    try {
      await player.setVolume(100);
    } catch (_) {}
  }

  // Throttle for pushing live position updates into PlaybackQueue (see
  // the position.stream listener below) — the queue's own
  // updateItemProgress() is what keeps EpisodeListPanel's per-row
  // progress bar in sync with actual playback instead of staying
  // frozen at whatever UserData snapshot the queue was fetched with.
  // player.stream.position fires many times a second; pushing a
  // queueNotifier update (and the ListView rebuild that triggers) on
  // every single tick would be wasteful even while the panel is
  // closed, since it stays mounted (just IgnorePointer/opacity-hidden)
  // rather than being torn down.
  DateTime? _lastQueueProgressUpdate;

  static const Duration _queueProgressUpdateInterval = Duration(seconds: 5);

  // The VideoController MUST be created before any media is opened on
  // `player` — creating it is what tells the native player to set up a
  // video output/texture at all. If it's created after `player.open()`
  // has already been called (e.g. lazily inside a screen's initState,
  // which only runs once playback has already started), the player opens
  // "blind": it has no video output attached, so video never renders and
  // playback appears to just hang on a loading screen. Audio-only
  // playback was unaffected by this because it never touches
  // VideoController. Creating it here, alongside the Player itself, at
  // app startup guarantees it's attached before playMedia() ever calls
  // player.open().
  late final VideoController videoController = VideoController(
    player,
  );

  final ValueNotifier<bool> loading =
  ValueNotifier(false);

  final ValueNotifier<bool> buffering =
  ValueNotifier(false);

  final ValueNotifier<bool> playing =
  ValueNotifier(false);

  final ValueNotifier<Duration> position =
  ValueNotifier(Duration.zero);

  final ValueNotifier<Duration> duration =
  ValueNotifier(Duration.zero);

  // How much of the current item mpv has actually buffered ahead of
  // playback — the seek bar's shaded "buffered" track reads this rather
  // than opening its own separate subscription to `player.stream.buffer`,
  // for the same reason [position]/[duration] are centralized here: one
  // canonical listener per stream, kept reliably in sync, instead of
  // every consumer racing its own copy.
  final ValueNotifier<Duration> bufferedPosition =
  ValueNotifier(Duration.zero);

  final ValueNotifier<bool> showMiniPlayer =
  ValueNotifier(false);

  final ValueNotifier<AudioTrack?> selectedAudio =
  ValueNotifier(null);

  final ValueNotifier<SubtitleTrack?> selectedSubtitle =
  ValueNotifier(null);

  /// CLOSED CAPTIONS (live TV only): whether the person has switched the
  /// channel's in-stream captions (CEA-608/708) on. Broadcast captions are
  /// not a Jellyfin subtitle stream — they ride inside the video itself —
  /// so they are not part of [subtitles]; mpv decodes them into a track of
  /// its own (see [_prepareClosedCaptionOption]) and this flag selects /
  /// deselects that track. Kept across channel switches.
  final ValueNotifier<bool> closedCaptionsOn = ValueNotifier(false);

  /// The mpv track id this flag last applied ('no' for off) so
  /// [_applyClosedCaptionChoice] stays idempotent across tracks events.
  String? _ccAppliedTrackId;

  /// The subtitle text currently on screen — feeds `CustomSubtitleOverlay`
  /// (Android only; see `VideoSurface`'s doc comment for why). Updated
  /// from `player.stream.subtitle`, the same stream the built-in
  /// `SubtitleView` reads on other platforms.
  final ValueNotifier<List<String>> currentSubtitleLines =
  ValueNotifier(const []);

  // NAMESIS PRIME - OPENSUBTITLES FIX: a downloaded/sidecar subtitle comes
  // with its full text in hand, so the app shows it from its own parsed
  // cues, driven by the playback position, instead of depending on mpv
  // handing the lines back (with mpv's own painting switched off, a
  // downloaded track showed nothing). While [_ownCues] is non-empty it is
  // the only source of [currentSubtitleLines].
  List<_OwnCue> _ownCues = const [];
  String _ownShownText = '';

  void _startOwnCues(String srt) {
    _ownCues = _parseSrtCues(srt);
    _ownShownText = '';
    currentSubtitleLines.value = const [];
    debugPrint('[Subtitles] own renderer: ${_ownCues.length} cue(s)');
  }

  void _stopOwnCues() {
    if (_ownCues.isEmpty) return;
    _ownCues = const [];
    _ownShownText = '';
    currentSubtitleLines.value = const [];
  }

  void _tickOwnCues(Duration pos) {
    final cues = _ownCues;
    if (cues.isEmpty) return;
    final t = (pos - subtitleDelay.value).inMilliseconds;
    // Last cue starting at or before t, then look back a few for overlaps.
    var lo = 0, hi = cues.length - 1, found = -1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (cues[mid].startMs <= t) {
        found = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    final lines = <String>[];
    for (var i = found; i >= 0 && i > found - 4; i--) {
      if (cues[i].endMs > t) lines.insert(0, cues[i].text);
    }
    final joined = lines.join('\n');
    if (joined == _ownShownText) return;
    _ownShownText = joined;
    currentSubtitleLines.value = lines;
  }

  static List<_OwnCue> _parseSrtCues(String srt) {
    final out = <_OwnCue>[];
    final time = RegExp(
        r'(?:(\d+):)?(\d{1,2}):(\d{2})[,.](\d{1,3})\s*-->\s*(?:(\d+):)?(\d{1,2}):(\d{2})[,.](\d{1,3})');
    int ms(String? h, String m, String s, String f) =>
        (int.tryParse(h ?? '0') ?? 0) * 3600000 +
        int.parse(m) * 60000 +
        int.parse(s) * 1000 +
        int.parse(f.padRight(3, '0'));
    final blocks = srt
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .replaceAll('\uFEFF', '')
        .split(RegExp(r'\n\s*\n'));
    for (final block in blocks) {
      final lines = block.split('\n');
      final ti = lines.indexWhere((l) => l.contains('-->'));
      if (ti < 0) continue;
      final m = time.firstMatch(lines[ti]);
      if (m == null) continue;
      final text = lines
          .sublist(ti + 1)
          .map((l) => l
              .replaceAll(RegExp(r'<[^>]*>'), '')
              .replaceAll(RegExp(r'\{\\[^}]*\}'), '')
              .trim())
          .where((l) => l.isNotEmpty)
          .join('\n');
      if (text.isEmpty) continue;
      out.add(_OwnCue(
        ms(m.group(1), m.group(2)!, m.group(3)!, m.group(4)!),
        ms(m.group(5), m.group(6)!, m.group(7)!, m.group(8)!),
        text,
      ));
    }
    out.sort((a, b) => a.startMs.compareTo(b.startMs));
    return out;
  }

  /// The currently playing video's native pixel dimensions —
  /// `CustomSubtitleOverlay` needs these to work out where the video's
  /// actual visible bottom edge sits within its (usually larger,
  /// letterboxed) container, the same way the built-in `SubtitleView`
  /// positions itself. Null until the first frame's dimensions are
  /// known.
  final ValueNotifier<int?> videoWidth = ValueNotifier(null);
  final ValueNotifier<int?> videoHeight = ValueNotifier(null);

  final ValueNotifier<Duration> subtitleDelay =
  ValueNotifier(Duration.zero);

  final ValueNotifier<List<SubtitleTrack>> subtitles =
  ValueNotifier([]);

  final ValueNotifier<bool> showNextEpisode =
  ValueNotifier(false);

  /// Same idea as [showNextEpisode]/[nextEpisode], but for the "Next
  /// Movie" recommendation card (see MovieRecommendationService and
  /// NextMovieOverlay) — kept as separate notifiers rather than reused
  /// ones since the two cards have different content shapes (an episode
  /// reference vs. a full recommended MediaItem with its own backdrop/
  /// logo) and can't both be showing at once anyway (one requires an
  /// episode queue, the other requires there not to be one).
  final ValueNotifier<bool> showNextMovie =
  ValueNotifier(false);

  final ValueNotifier<MediaItem?> nextMovieRecommendation =
  ValueNotifier(null);

  bool nextMovieShown = false;

  /// Same idea as [showNextMovie]/[nextMovieRecommendation], but for the
  /// last episode of a series with nothing else queued after it (see
  /// ShowRecommendationService and NextShowOverlay) — the same gap Next
  /// Movie fills for movies, just for an exhausted episode queue instead
  /// of a standalone one. [nextShowRecommendation] already holds that
  /// show's playable first episode (not the series itself — see
  /// ShowRecommendationService's doc comment), so it can be queued/played
  /// exactly like any other MediaItem.
  final ValueNotifier<bool> showNextShow =
  ValueNotifier(false);

  final ValueNotifier<MediaItem?> nextShowRecommendation =
  ValueNotifier(null);

  bool nextShowShown = false;

  /// Live-measured height of [PlayerBottomBar] (seek bar + the row of
  /// scale/quality/audio/subtitle/speed buttons beneath it), reported by
  /// that widget after every layout via [MeasureSize]. The Skip Intro/
  /// Credits pill and the Next Episode card anchor themselves just above
  /// this value (see PlayerOverlayLayer) instead of a hard-coded margin,
  /// so they track the bar's real height (which differs for live vs VOD)
  /// rather than drifting out of sync with it. The initial value is a
  /// reasonable estimate for the one frame before the first real
  /// measurement lands.
  final ValueNotifier<double> bottomBarHeight =
  ValueNotifier(120);

  /// Live-measured height of [PlayerTopBar] (back/title/action row,
  /// including its own top padding for the status bar / display
  /// cutout / immersive breathing room), reported by that widget after
  /// every layout via [MeasureSize] — same pattern as [bottomBarHeight]
  /// above. In landscape, PlayerOverlayLayer clamps the Next Episode/
  /// Next Movie card's available height against this instead of a
  /// hard-coded top margin, so the card can never grow tall enough to
  /// sit behind/under the top bar's real bottom edge — which used to
  /// vary with the safe-area inset, TV mode's larger icon size, and
  /// fullscreen vs windowed padding, none of which a fixed constant
  /// could track. The initial value is a reasonable estimate for the
  /// one frame before the first real measurement lands.
  final ValueNotifier<double> topBarHeight =
  ValueNotifier(74);

  /// Controls the right-side "episode list" panel in the video player.
  /// Only relevant for series/season playback — the top bar only shows
  /// the toggle button when [PlaybackQueue.instance.source] is an
  /// episode-based source.
  final ValueNotifier<bool> showEpisodeList =
  ValueNotifier(false);

  /// Controls the center-screen "channel list" panel in the video
  /// player. Only relevant for Live TV playback — the top bar only
  /// shows the toggle button when the currently playing item is live.
  final ValueNotifier<bool> showChannelList =
  ValueNotifier(false);

  /// Full, unfiltered Live TV channel lineup — used to work out the
  /// previous/next channel for the center controls' skip buttons.
  /// Populated lazily the first time a live channel starts playing (and
  /// kept fresh afterwards by [LiveChannelListPanel] each time it's
  /// opened) rather than refetched on every channel switch, since the
  /// lineup itself doesn't change mid-session.
  final ValueNotifier<List<Map<String, dynamic>>> liveChannels =
  ValueNotifier(const []);

  bool _loadingLiveChannels = false;

  final ValueNotifier<MediaItem?> nextEpisode =
  ValueNotifier(null);

  final ValueNotifier<SkipSegment?> activeSkipSegment =
  ValueNotifier(null);

  final ValueNotifier<List<AudioTrack>> audioTracks =
  ValueNotifier([]);

  bool skipPressed = false;

  bool nextEpisodeShown = false;

  /// Gate for the Next Episode / Next Show / Next Movie triggers in the
  /// position listener. Cleared by [playMedia] and only set again once the
  /// listener sees a position tick that really belongs to the NEW item
  /// (see the arming block there). Without it, stale position ticks from
  /// the previous file — which is still what mpv reports for a moment
  /// after Play Now, until the new file is actually open — were compared
  /// against the new item's Outro start / runtime, so the next-up card
  /// for the item AFTER the new one appeared the instant the new one
  /// began loading.
  bool _nextUpArmed = false;

  /// Where the item most recently handed to [playMedia] is expected to
  /// start (its resume position, or zero). A tick near this position is
  /// evidence mpv is reporting the new file, not the previous one.
  Duration _nextUpStartPosition = Duration.zero;

  MediaItem? get currentItem => currentItemNotifier.value;

  final ValueNotifier<MediaItem?> currentItemNotifier =
  ValueNotifier(null);

  // Whether the currently playing item is favorited on the server.
  // Kept here (rather than on MediaItem) so it always reflects live
  // UserData without every code path that builds a MediaItem needing to
  // know about favorites too. See loadFavoriteState/toggleFavorite.
  final ValueNotifier<bool> isFavorite =
  ValueNotifier(false);

  String? _favoriteLoadedForId;

  Future<void> loadFavoriteState(MediaItem? item) async {
    if (item == null) {
      _favoriteLoadedForId = null;
      isFavorite.value = false;
      return;
    }

    if (item.id == _favoriteLoadedForId) return;
    _favoriteLoadedForId = item.id;

    // Local songs have no server UserData to look up — their favorite
    // state lives entirely in LocalMusicService's own persisted set,
    // already known synchronously with nothing to await.
    if (item.isLocal) {
      isFavorite.value = LocalMusicService.instance.isFavorite(item.id);
      return;
    }

    isFavorite.value = false;

    try {
      final data = await MediaService.getMusicItem(item.id);

      // The track may have changed again while this was in flight.
      if (currentItem?.id != item.id) return;

      isFavorite.value = data["UserData"]?["IsFavorite"] ?? false;
    } catch (_) {
      // Leave it as not-favorited if the lookup fails — the button
      // still works, it'll just start from an unfavorited state.
    }
  }

  Future<void> toggleFavorite() async {
    final item = currentItem;
    if (item == null) return;

    final wasFavorite = isFavorite.value;

    // Optimistic update so the icon (and the notification heart)
    // responds instantly.
    isFavorite.value = !wasFavorite;

    if (item.isLocal) {
      // Can't fail the way a network call can, so there's nothing to
      // roll back here.
      await LocalMusicService.instance.toggleFavorite(item.id);
      return;
    }

    try {
      await MediaService.toggleFavorite(item.id, wasFavorite);
    } catch (_) {
      isFavorite.value = wasFavorite;
    }
  }

  final ValueNotifier<bool> isVideo =
  ValueNotifier(true);

  final ValueNotifier<double> playbackSpeed =
  ValueNotifier(1.0);

  /// The Quality selector's current selection label — "Auto" or one of
  /// kVideoQualityLadder's labels ("1080p", "720p", ...). This is what
  /// the selector UI highlights; it is NOT necessarily the resolution
  /// actually streaming right now (see [_activeVideoLevel]) since "Auto"
  /// itself resolves to different things depending on
  /// AppSettings.playbackQualityMode and live network conditions.
  final ValueNotifier<String> videoQuality =
  ValueNotifier("Auto");

  /// Labels the Quality selector should currently offer for the item
  /// that's playing, always headed by "Auto" and narrowed to resolutions
  /// at or below the source's own height (no point offering an upscale
  /// Jellyfin would just clamp anyway). Empty for audio-only items —
  /// per-request, music never shows a manual quality selector at all.
  final ValueNotifier<List<String>> videoQualityOptions =
  ValueNotifier(const []);

  /// The resolution/bitrate constraint actually baked into the stream
  /// that's open right now — null means "Original", i.e. the plain
  /// `static=true` direct-play URL this app has always used. Distinct
  /// from [videoQuality] for the "Auto" reasons described above.
  VideoQualityLevel? _activeVideoLevel;

  /// How far into the real media timeline the currently-open stream's
  /// own position 0 corresponds to. Non-zero exactly when playing a
  /// StartTimeTicks-based transcode (see MediaService.getVideoStreamUrl's
  /// doc comment) — Jellyfin's transcoder produces a brand-new encode
  /// whose own internal timestamps restart at 0 from wherever it was
  /// told to begin, not a byte-continuation of the original file. mpv's
  /// raw `player.state.position`/`player.stream.position` for such a
  /// stream describe that segment alone (e.g. "9 seconds into this
  /// transcode"), not the item's real position — every place that needs
  /// the real position (the `position` notifier, skip-segment/Next
  /// Episode detection, and building a fresh StartTimeTicks for the
  /// *next* reopen) has to add this back in. See [_absolutePosition].
  Duration _streamPositionOffset = Duration.zero;

  /// The item's real, full duration, frozen the first time it's known
  /// (always from a segment opened at offset zero — Original quality
  /// always reports the true length) and never overwritten by a later
  /// transcode segment's own much-shorter "however much is left from
  /// this offset" duration. See the `duration` stream listener.
  Duration? _originalDuration;

  /// The item's real position right now, correcting for
  /// [_streamPositionOffset] — use this (never `player.state.position`
  /// directly) anywhere a fresh reopen needs to know "where are we
  /// really" to preserve across a quality/track change.
  Duration get _absolutePosition =>
      _streamPositionOffset + player.state.position;

  /// Casting Phase 8's REMOTE → LOCAL resume (see PlaybackCoordinator)
  /// needs to seek the *currently still-open* stream to a real-timeline
  /// position reported by a cast session (which only ever deals in real
  /// positions, never a transcode-relative one) — a plain
  /// `player.seek(target)` would be wrong by exactly
  /// [_streamPositionOffset] whenever a StartTimeTicks-based transcode
  /// segment is the one currently open. Every other seek call in this
  /// app targets the currently-open stream in stream-relative terms
  /// (rewind/forward-10s, the seek bar), so this is deliberately the one
  /// place that converts an absolute target back down to raw
  /// stream-relative before calling `player.seek` — see
  /// [_absolutePosition]'s own doc comment for why the correction exists
  /// at all.
  Future<void> seekToAbsolute(Duration target) {
    // A capped (server-transcoded) video can't be seeked in place — see
    // [seekTo].
    if (_needsReopenToSeek(currentItem)) return seekTo(target);

    final raw = target - _streamPositionOffset;
    return player.seek(raw < Duration.zero ? Duration.zero : raw);
  }

  /// The item's real position right now (stream position + the offset of
  /// the transcode segment that's open, if any). Equal to
  /// `player.state.position` whenever the stream starts at zero.
  Duration get absolutePosition => _absolutePosition;

  /// Where the most recent in-flight transcode seek is heading, so rapid
  /// +/-10s taps and drags build on the target instead of on the stale
  /// pre-seek position. Null when no such seek is running.
  Duration? _transcodeSeekTarget;
  int _transcodeSeekId = 0;

  /// ROOT CAUSE of "seeking does nothing at Data Saver / Default": at those
  /// settings a movie/episode is not a file but a LIVE server transcode
  /// (see MediaService.getVideoStreamUrl). A live transcode has no byte
  /// ranges to jump into, so `player.seek()` on it either never completes
  /// or lands back at the old point and the video carries on undisturbed.
  /// (Original quality is the plain static file, which seeks fine — which
  /// is why only the capped settings were affected.)
  ///
  /// The only way to move around such a stream is the one quality changes
  /// and audio-track changes already use: ask the server for a NEW
  /// transcode that starts at the target (StartTimeTicks) and reopen on it,
  /// preserving play/pause state, speed, tracks and subtitles.
  bool _needsReopenToSeek(MediaItem? item) =>
      item != null &&
      !item.live &&
      !item.audioOnly &&
      _activeVideoLevel != null &&
      !_isOfflineFile(item);

  /// Seeks to the ABSOLUTE position [target] in the item, whatever the
  /// quality setting. Everything except a capped-quality movie/episode
  /// behaves exactly as a plain `player.seek(target)` always did.
  Future<void> seekTo(Duration target) async {
    final item = currentItem;
    if (item == null || !_needsReopenToSeek(item)) {
      return player.seek(target);
    }

    var t = target < Duration.zero ? Duration.zero : target;

    // A transcode started at/after the very end has nothing to send. Stop
    // one second short instead; it plays out and finishes normally.
    final total = duration.value;
    const endMargin = Duration(seconds: 1);
    if (total > const Duration(seconds: 2) && t > total - endMargin) {
      t = total - endMargin;
    }

    // Keep the baked-in audio track consistent with what
    // selectAudioTrack/_applyVideoLevel assume.
    final audioIndex = _activeAudioStreamIndex ??
        selectedAudio.value?.index ??
        _defaultAudioStreamIndex(item);
    _activeAudioStreamIndex = audioIndex;

    final id = ++_transcodeSeekId;
    _transcodeSeekTarget = t;

    final url = _resolveVideoUrl(
      item,
      _activeVideoLevel,
      audioStreamIndex: audioIndex,
      startAt: t,
    );

    try {
      await _reopenStreamPreservingState(
        url,
        // The new transcode already begins at [t] server-side; seeking
        // inside it afterwards is exactly what hangs (see
        // _reopenStreamPreservingState's doc comment).
        seekAfterOpen: false,
        newStreamOffset: t,
        resumePosition: t,
        failureMessage: "Couldn't seek — please try again.",
      );
    } finally {
      if (id == _transcodeSeekId) _transcodeSeekTarget = null;
    }
  }

  /// Relative seek (double-tap / +-10s buttons / horizontal drag).
  /// Unchanged behaviour for everything that can seek in place.
  Future<void> seekBy(Duration delta) {
    final item = currentItem;
    if (!_needsReopenToSeek(item)) {
      final total = player.state.duration;
      var t = player.state.position + delta;
      if (t < Duration.zero) t = Duration.zero;
      if (total > Duration.zero && t > total) t = total;
      return player.seek(t);
    }
    return seekTo((_transcodeSeekTarget ?? _absolutePosition) + delta);
  }

  /// Which of the item's Jellyfin audio-track indices is baked into the
  /// current transcode when [_activeVideoLevel] isn't null (a capped
  /// transcode only ever carries the one Jellyfin was told to encode —
  /// see MediaService.getVideoStreamUrl's doc comment). Irrelevant at
  /// Original quality, where every track is embedded and natively
  /// switchable the way it always has been.
  int? _activeAudioStreamIndex;

  /// The audio bitrate constraint (kbps) actually applied to the current
  /// music stream, or null for "no MaxStreamingBitrate cap set" (Max
  /// Quality mode resolves to the ladder's top tier explicitly rather
  /// than null, so in practice this is only null before the first
  /// item's quality has been resolved at all).
  int? _activeAudioBitrateKbps;

  /// True while mpv is configured to pre-buffer a few seconds before
  /// starting (and before resuming after an underrun) — see
  /// [_setAudioPrebuffer]. Only ever on for a server-transcoded music
  /// stream.
  bool _audioPrebufferApplied = false;

  // ── Music stream recovery (see _recoverCutShortAudioStream) ──────────
  /// How many times the current song's capped stream has been rebuilt
  /// after dying early. Reset for every new song. Also read by
  /// `_applyAdaptiveQuality`, which stays out of the way while a
  /// recovery is under way so the two never fight over the stream.
  int _audioStreamRecoveryAttempts = 0;
  bool _audioRecoveryInFlight = false;

  /// Identifies the current server-streamed song to Jellyfin. The same id
  /// goes on the transcode URL and on every playback report
  /// (PlaybackProgressService), which is how the server links "this client
  /// is still listening" to the transcoding job it is running for it.
  /// New for every song; reused across that song's quality/recovery
  /// reopens so the server keeps seeing one continuous session.
  String? _musicPlaySessionId;

  /// The furthest real (absolute) position this song's stream has
  /// reached, kept by the position listener. mpv's own position can read
  /// zero once a stream has ended, which is exactly when the recovery
  /// needs to know where playback got to.
  Duration _lastAbsoluteStreamPosition = Duration.zero;

  /// A stream that ends within this of the song's known length is a
  /// normal ending; anything earlier is treated as the stream dying.
  static const Duration _cutShortTolerance = Duration(seconds: 5);

  /// The user's explicit resolution pick from the in-player Quality
  /// selector for *this* playback session, overriding whatever
  /// AppSettings.playbackQualityMode would otherwise pick for "Auto".
  /// Null means "follow the app-wide Data Usage setting" (the default).
  /// Reset back to null every time playback stops (see [stop]) — per
  /// the person's own spec, this override ends the moment the video
  /// player screen is exited, it never persists to the next title.
  VideoQualityLevel? _manualVideoOverride;

  /// Carried across a quality-change reopen so `_syncTracks` can
  /// re-select the same audio track / subtitle on the new file once its
  /// native track list exists, instead of silently falling back to
  /// whatever mpv/the "pick a default" logic would otherwise choose for
  /// a freshly-opened file. See `_reopenStreamPreservingState`.
  AudioTrack? _pendingAudioReapply;
  SubtitleTrack? _pendingSubtitleReapply;

  /// DEFAULT SUBTITLE: true once the person has explicitly turned subtitles
  /// off for the item that's open. From then on nothing may switch one back
  /// on by itself (later track-list events, quality reopens, ...). Reset for
  /// every new item. Also read by PlaybackCoordinator so a cast handoff
  /// keeps subtitles off on the TV.
  bool _subtitleUserOff = false;
  bool get subtitlesTurnedOffByUser => _subtitleUserOff;

  /// DEFAULT SUBTITLE: the item's default subtitle has been picked (or
  /// deliberately skipped), so `_syncTracks` — which fires on every mpv
  /// track-list change — must not pick again.
  bool _autoSubtitleHandled = false;

  /// DEFAULT SUBTITLE: set once `_reapplyCachedSubtitleIfAny` has finished
  /// for the open item. A remembered OpenSubtitles pick / the sidecar file
  /// next to an Open With video outranks "the first embedded subtitle", so
  /// that fallback waits for this; a file-flagged default/forced track never
  /// did and still doesn't.
  bool _cachedSubtitleCheckDone = false;

  /// BUGFIX (duplicate sidecar subtitle entry), second attempt: a set of
  /// native mpv subtitle ids captured the *very first* time `_syncTracks`
  /// fires for the currently-open item — i.e. before this app has ever
  /// called `sub-add` itself (Open With/Play With sidecar, downloaded-
  /// movie sidecar, OpenSubtitles download, or a fetched Jellyfin
  /// Stream.vtt). Null until that first firing happens, then frozen for
  /// the rest of this item's playback; reset to null per-item in
  /// `playMedia`.
  ///
  /// The first attempt at this fix recorded a `sub-add`'s resulting
  /// native id right after `await player.setSubtitleTrack(...)`
  /// returned, but that raced `_syncTracks` itself: `player.stream.tracks`
  /// is driven by mpv's own property-change notifications, which can —
  /// and did — arrive and run `_syncTracks` *before* the `setSubtitleTrack`
  /// future actually resolved, so the id got recorded too late to matter
  /// for that firing. Snapshotting the real, pre-any-sub-add track list
  /// once, up front, sidesteps that race entirely: it doesn't matter
  /// when a `sub-add`'s own tracks-event lands, because anything not in
  /// this frozen baseline is — by construction — something this app
  /// added itself, never a track mpv found by demuxing the file.
  Set<String>? _baselineNativeSubtitleIds;

  /// Debounces reactions to NetworkQualityService.tier /
  /// AppSettings.playbackQualityMode changes so a flurry of connectivity
  /// events settles for a moment before anything actually interrupts
  /// playback with a reopen.
  Timer? _adaptiveQualityDebounce;

  bool _networkMonitoringActive = false;

  /// True while PlaybackCoordinator has this device's local playback
  /// paused and handed off to a cast session. Auto quality's whole job
  /// is picking a bitrate this *phone's* connection can sustain for a
  /// stream that's actually rendering here — during a handoff neither of
  /// those is true (the local stream is paused/inaudible, and the TV's
  /// connection is what actually matters, which this phone has no way
  /// to measure), so [_onQualityInputsChanged] no-ops entirely while
  /// this is set rather than silently reopening a paused stream nobody
  /// is watching every time the phone's own network conditions shift.
  /// See [suspendAdaptiveQualityForCast]/[resumeAdaptiveQualityAfterCast].
  bool _castSuspended = false;

  final ValueNotifier<String?> lastError =
  ValueNotifier(null);

  /// True while the user has a finger on the seek bar thumb. The video
  /// screen's auto-hide timer watches this so controls never disappear
  /// mid-drag (which used to cut a scrub gesture short before it could
  /// commit a seek).
  final ValueNotifier<bool> isSeeking =
  ValueNotifier(false);

  /// True while playback controls are locked. Only the small unlock
  /// button stays interactive — every other gesture (tap-to-toggle,
  /// double-tap seek, drag-seek, brightness/volume swipes) and the
  /// normal top/bottom/center control bars are disabled while this is
  /// true, so an accidental touch can't disturb playback.
  final ValueNotifier<bool> isLocked =
  ValueNotifier(false);

  /// Tracks whether the system status/navigation bars are currently
  /// hidden, so the top bar's fullscreen button can show the right icon
  /// and toggle between the two states.
  final ValueNotifier<bool> isFullscreen =
  ValueNotifier(true);

  /// How the video frame is scaled inside the player surface. Cycled by
  /// the scaling button in the bottom bar.
  final ValueNotifier<BoxFit> videoFit =
  ValueNotifier(BoxFit.contain);

  /// Flips true once a video (movie or episode) finishes with nothing
  /// left to continue to — no next episode queued, and no next-movie
  /// recommendation found/offered (see the `completed` stream listener
  /// below). VideoPlayerScreen listens for this and pops itself, the
  /// same way it already does for [lastError].
  final ValueNotifier<bool> playbackFinished =
  ValueNotifier(false);

  // "Still watching?" idle safety -----------------------------------------
  //
  // Flips true once no real user interaction has been detected on the
  // video player screen for [stillWatchingIdleThreshold]. VideoPlayerScreen
  // calls [registerActivity] once when it opens and again on every tap/
  // drag/seek it sees, which restarts the clock below and — if the prompt
  // is already showing — dismisses it too, exactly like tapping its own
  // "Yes, I'm still here" button. StillWatchingOverlay (shown by
  // PlayerOverlayLayer whenever this is true) owns the follow-up 10s-grace
  // + 30s-countdown timers itself, the same way NextEpisodeOverlay owns
  // its own auto-play countdown rather than PlayerManager driving it.
  final ValueNotifier<bool> showStillWatching =
  ValueNotifier(false);

  static const Duration stillWatchingIdleThreshold = Duration(hours: 4);

  Timer? _stillWatchingIdleTimer;

  /// (Re)starts the 4-hour idle clock. Call once when the video player
  /// screen opens, then again on every detected interaction — tapping the
  /// screen, double-tap seek, brightness/volume/seek drags, dragging the
  /// seek bar, and toggling the lock all count as "activity".
  void registerActivity() {
    _stillWatchingIdleTimer?.cancel();

    // A real interaction also dismisses the prompt itself if it's already
    // up, the same as tapping its own "Yes, I'm still here" button.
    if (showStillWatching.value) {
      showStillWatching.value = false;
    }

    _stillWatchingIdleTimer = Timer(
      stillWatchingIdleThreshold,
      () => showStillWatching.value = true,
    );
  }

  /// Cancels the idle clock and hides the prompt. Call from
  /// VideoPlayerScreen.dispose() so a closed player can never fire the
  /// prompt into an empty screen after the fact.
  void stopActivityMonitor() {
    _stillWatchingIdleTimer?.cancel();
    _stillWatchingIdleTimer = null;
    showStillWatching.value = false;
  }

  // Bumped by every showLoadingPreview()/playMedia()/stop() call and
  // captured locally at the start of each. stop() in particular awaits
  // a server report + player.stop() before it clears currentItemNotifier/
  // loading — if the user exits a title and immediately starts a new one
  // while that's still in flight (e.g. the fire-and-forget stop() called
  // from VideoPlayerScreen.dispose()), the old stop() call used to
  // resolve *after* the new item's state was already set, wiping
  // currentItemNotifier back to null and loading back to false. That
  // dropped the opaque LoadingOverlay (it renders nothing when the item
  // is null) and exposed the raw, persistent video texture underneath —
  // which was still showing the previous title's last decoded frame —
  // producing a flash of the old movie before the new one's frames
  // caught up. Checking the token after every await lets a stale call
  // detect it's been superseded and bail out without touching state that
  // now belongs to a newer request.
  int _playbackToken = 0;

  void initialize() {
    // Force the lazy `videoController` to be constructed right now, before
    // anything can call playMedia()/player.open(). See the field's doc
    // comment for why the ordering matters.
    // ignore: unnecessary_statements
    videoController;

    // mpv/ffmpeg wraps most things it opens for demuxing — including a
    // subtitle file handed to `sub-add`, local or remote — in an
    // on-disk cache, and by default that cache lives wherever mpv's
    // build-time default `cache-dir` points, which on Android is not
    // guaranteed to be a directory this sandboxed app can actually
    // write to. When it isn't, mpv doesn't fall back to running
    // uncached — it just logs "Failed to create file cache" and drops
    // the load, silently as far as Dart is concerned (see
    // `selectSubtitleTrack`). Pointing it explicitly at the app's own
    // temp dir — the same directory downloaded subtitles are already
    // written to — gives it somewhere it's guaranteed to be able to
    // write. Fire-and-forget: this only needs to land before the first
    // `sub-add`/media open, which is always later than `initialize()`
    // running at app startup.
    unawaited(() async {
      final platform = player.platform;
      if (platform is NativePlayer) {
        final tempDir = await getTemporaryDirectory();
        await platform.setProperty('cache-dir', tempDir.path);
      }
    }());

    // BOLD SUBTITLES FIX (Open With/Play With external subtitles bold at
    // default settings): `libass: true` (see the Player above) makes mpv
    // render subtitles itself, from the subtitle file's OWN style — and
    // styled external files (.ass/.ssa — Aegisub's stock "Default" style
    // is Bold) come out bold no matter what the Flutter overlay's
    // fontWeight says. Keeps mpv's renderer in step with the "Bold text"
    // switch in Subtitle Style (off by default) instead.
    _applyNativeSubtitleBold(SubtitleAppearanceSettings.notifier.value.bold);
    SubtitleAppearanceSettings.notifier.addListener(() {
      _applyNativeSubtitleBold(SubtitleAppearanceSettings.notifier.value.bold);
    });

    // NAMESIS PRIME - SUBTITLE STYLE FIX: with `libass: true` mpv ALSO
    // paints text subtitles itself, onto the video, with the file's own
    // look (or mpv's defaults) - font, size, colour and background chosen
    // in Subtitle Style never reached that copy, and it sat next to the
    // app's own styled copy. Text subtitles are therefore drawn only by
    // the app's overlay (which follows every setting; mpv keeps
    // delivering the plain text either way). Picture subtitles (PGS,
    // DVD/DVB) cannot be restyled or drawn as text, so mpv keeps painting
    // those.
    unawaited(_setNativeSubtitleVisible(false));
    player.stream.track.listen((t) {
      final sub = t.subtitle;
      const bitmapCodecs = {
        'hdmv_pgs_subtitle', 'pgssub', 'dvd_subtitle', 'dvdsub',
        'dvb_subtitle', 'dvbsub', 'xsub',
      };
      final bitmap =
          sub.image == true || bitmapCodecs.contains(sub.codec?.toLowerCase());
      unawaited(_setNativeSubtitleVisible(bitmap));
    });

    // See the doc comment on `_audioSession` above. Fire-and-forget: this
    // only needs to land before the first real playback, which is always
    // later than `initialize()` running at app startup, same reasoning as
    // the cache-dir setup right above.
    unawaited(_configureAudioSession());

    player.stream.position.listen((value) {
      // Correction for a StartTimeTicks-based transcode (see
      // getVideoStreamUrl's doc comment and _streamPositionOffset) —
      // Jellyfin's transcoder produces a brand-new encode whose own
      // internal timestamps restart at 0 from wherever it was told to
      // begin, not a byte-continuation of the original file, so mpv's
      // raw `value` here describes the SEGMENT alone (e.g. "9 seconds
      // into this transcode"), not the movie's real position. Every
      // comparison below needs the real, absolute position, which is
      // why this is computed once up front and used everywhere instead
      // of the raw `value` — skip-segment detection, the 90%-finished
      // check, and Next Episode/Next Movie's "near the end" checks all
      // compare against absolute times (skip segment start/end,
      // RunTimeTicks-derived duration), and silently comparing those
      // against a segment-local position is exactly what made this
      // look like "stuck at/reset to the wrong time" after a quality
      // switch, and made skip-segment/Next-Episode detection unreliable
      // for the rest of that playback session too.
      final absoluteValue = _streamPositionOffset + value;

      position.value = absoluteValue;
      _tickOwnCues(absoluteValue);
      if (absoluteValue > Duration.zero) {
        _lastAbsoluteStreamPosition = absoluteValue;
      }

      final current = currentItem;
      final isLive = current?.live ?? false;

      // Deliberately NOT `player.state.duration` here — that's the raw,
      // one-off value straight from mpv, and this exact file already
      // documents (see _waitForDuration) that it can sit at zero for a
      // stretch after switching items, since `player.stream.duration`
      // only emits on *change* and can go the whole session without
      // firing again if two items happen to share a runtime. `duration`
      // is the ValueNotifier this codebase already keeps correctly
      // resolved for exactly that reason (both the stream listener below
      // and _waitForDuration's polling feed it) — everything past this
      // point (the 90%-finished check, and the Next Episode/Next Movie
      // fallback threshold) needs a value that's actually reliably
      // populated by the time it matters, not whatever mpv's raw
      // property happened to report on this particular tick.
      final total = duration.value;

      // Live TV has no real "end" to reach — the duration mpv reports
      // for the channel's continuously-growing stream is just how much
      // has been written so far, which naturally tracks very close to
      // the current playback position while watching in real time. The
      // "reached 90% of duration" heuristic below is meant for VOD
      // titles; applied to live TV it kept firing as soon as playback
      // caught up to the live edge (i.e. whenever the seek bar reached
      // its right edge), reporting the session as finished/stopped to
      // the server — which tears down the live tuner and is what
      // actually cut playback off.
      if (!isLive &&
          !PlaybackProgressService.reportedFinished &&
          total > Duration.zero &&
          absoluteValue >= total * 0.9) {
        PlaybackProgressService.markFinished();

        PlaybackProgressService.playbackStopped(absoluteValue);

        if (current != null && DownloadManager.instance.isDownloaded(current.id)) {
          OfflineProgressService.markFinished();
        }

        // Mirrors the same "reached 90%, mark watched" moment into the
        // queue itself (see PlaybackQueue.updateItemProgress) — without
        // this, EpisodeListPanel keeps showing the just-finished episode
        // as in-progress/unwatched for the rest of the session, since
        // it never re-fetches on its own the way the TV show detail
        // screen and Downloads page do.
        if (current != null) {
          PlaybackQueue.instance.updateItemProgress(
            current.id,
            played: true,
            position: Duration.zero,
          );
        }
      } else if (current != null &&
          !isLive &&
          (_lastQueueProgressUpdate == null ||
              DateTime.now().difference(_lastQueueProgressUpdate!) >=
                  _queueProgressUpdateInterval)) {
        // Same idea for ordinary in-progress ticks, throttled — keeps
        // the currently-playing row's progress bar advancing if the
        // panel happens to be open, and keeps it accurate for the rest
        // of the session if it isn't.
        _lastQueueProgressUpdate = DateTime.now();

        PlaybackQueue.instance.updateItemProgress(
          current.id,
          position: absoluteValue,
        );
      }

      //--------------------------------------------------
      // NEXT EPISODE OVERLAY
      //--------------------------------------------------

      final queue = PlaybackQueue.instance;

      // Episode queues are actually built with source `season` (see
      // PlaybackService._playEpisodeQueue /
      // _playSeriesFromResumeOrStart) — `series` is never set by any
      // real playback entry point. Checking only `series` here meant
      // this condition could never be true, so the Next Episode
      // overlay never appeared. `season` is the one that actually
      // needs to match; `series` is kept too in case a future queue
      // source uses it.
      final isEpisodeQueue = queue.source == PlaybackSource.season ||
          queue.source == PlaybackSource.series;

      // The real Outro segment for this file, if Jellyfin's Media
      // Segments feature has one (see MediaService.getSkipSegments) —
      // this is what other apps (Netflix, Plex, the Jellyfin web
      // client) actually key "Next Episode" off: the prompt appears
      // the instant the outro/credits segment *starts*, not some fixed
      // countdown from the end of the file. That's also what makes it
      // correct for a cold open or a post-credits scene — the credits
      // can start well before the last 20 seconds, or (for a stinger)
      // resume again after them, and a flat end-of-file countdown gets
      // both wrong.
      SkipSegment? outro;
      if (current != null) {
        for (final s in current.skipSegments) {
          if (s.type == SkipSegmentType.outro) {
            outro = s;
            break;
          }
        }
      }

      // Guard against implausible Outro data — e.g. a fingerprint
      // collision between two episodes' shared end-credits theme, or a
      // "previously on..." recap right after a cold open getting
      // matched against that same theme — reporting an Outro segment
      // that starts near the very beginning of the file. A real
      // end-credits segment is by definition near the end, so one
      // starting before the file's own halfway point is data noise, not
      // a real outro; every prior fix in this listener (the item-id/
      // token guards, the activeSkipSegment/_streamPositionOffset
      // resets) already runs cleanly on transition, so this is what was
      // left to explain Next Episode/Next Movie firing again within
      // moments of the *new* item starting instead of near its end.
      if (outro != null && outro.start < total * 0.5) {
        outro = null;
      }

      // Addon titles often have no credits data anywhere (no community
      // entry, no chapters). Without a guess there would never be a Skip
      // Credits button or a Next Episode / Next Movie cue, so estimate
      // where the credits begin from the file's real length.
      SkipSegment? estimatedOutro;
      if (outro == null &&
          current != null &&
          !isLive &&
          !current.audioOnly &&
          current.raw?['AddonStream'] == true &&
          total > const Duration(minutes: 3)) {
        estimatedOutro = _estimatedOutroFor(current, total);
        outro = estimatedOutro;
      }

      // Arm the next-up triggers only once a tick plausibly comes from the
      // item that is actually playing now. Right after a Play Now (or any
      // item switch) `currentItem` is already the NEW item, but until
      // `player.open()` takes effect mpv keeps emitting the OLD file's
      // positions — near its very end, since that is where Next Episode /
      // Next Movie fired. Those stale values are ≥ the new item's Outro
      // start (its segments often load before the new file opens), so the
      // triggers below fired immediately for the item after the new one.
      // A genuine tick from the new file is always at/near where it
      // starts (zero, or its resume point), never far past it.
      if (!_nextUpArmed &&
          current != null &&
          absoluteValue <=
              _nextUpStartPosition + const Duration(seconds: 10)) {
        _nextUpArmed = true;
      }

      final reachedRealOutro =
          _nextUpArmed && outro != null && absoluteValue >= outro.start;

      // Falls back to an end-of-runtime heuristic (see below)
      // only when this file has no detected Outro segment at all — e.g.
      // no segment-providing plugin installed/scanned on the server yet.
      // Without this fallback, a library with segments not set up would
      // simply never show Next Episode instead of degrading gracefully.
      //
      // The fallback window differs by content type: an episode's
      // Next Episode (and Next Show, which shares its trigger) card
      // appears 25s before the end, while a movie's Next Movie card
      // appears 300s (5 min) before the end, since a movie's credits
      // run far longer than an episode's.
      final reachedFallback = _nextUpArmed &&
          outro == null &&
          total > Duration.zero &&
          absoluteValue >= total - const Duration(seconds: 25);

      final reachedMovieFallback = _nextUpArmed &&
          outro == null &&
          total > Duration.zero &&
          absoluteValue >= total - const Duration(seconds: 300);

      // `!nextShowShown` guards against a race with the Next Show block
      // below: that block fires precisely when `!queue.hasNext` (the
      // last episode of a series, nothing queued after it), then
      // asynchronously appends its recommendation into the queue once
      // found. That append flips `queue.hasNext` to true on the very
      // next position tick, which — without this guard — satisfies
      // every condition here too and fires Next Episode for the
      // recommendation's first episode, stomping the Next Show card
      // with a countdown-driven "next episode" one for what is actually
      // a different, unrelated show. `nextShowShown` is set synchronously
      // the moment that block starts (see below), well before its
      // append resolves, so checking it here closes the window.
      if (isEpisodeQueue &&
          queue.hasNext &&
          !nextEpisodeShown &&
          !nextShowShown &&
          (reachedRealOutro || reachedFallback)) {

        nextEpisodeShown = true;

        nextEpisode.value =
        queue.items[queue.currentIndex + 1];

        showNextEpisode.value = true;
      }

      //--------------------------------------------------
      // NEXT SHOW RECOMMENDATION
      //--------------------------------------------------
      //
      // Same trigger point as Next Episode above (real Outro segment
      // start, or the fallback), but for the *last* episode of a series
      // — i.e. an episode queue with nothing left in it, exactly the
      // case Next Episode's own `queue.hasNext` check above deliberately
      // excludes, and which otherwise just stops outright once the
      // episode ends. Mirrors the Next Movie block below (same
      // recommendations gate, same "nothing queued after this" trigger)
      // but for `isEpisodeQueue` instead of `!isEpisodeQueue`, so the two
      // can never both fire for the same finished item.
      if (isEpisodeQueue &&
          current != null &&
          !isLive &&
          !queue.hasNext &&
          !nextShowShown &&
          AppSettings.autoQueueRecommendations.value &&
          (reachedRealOutro || reachedFallback)) {

        nextShowShown = true;

        unawaited(_maybeShowNextShow(current, _playbackToken));
      }

      //--------------------------------------------------
      // NEXT MOVIE RECOMMENDATION
      //--------------------------------------------------
      //
      // Same trigger point as Skip Credits/Next Episode (real Outro
      // segment start, or the fallback), but for a movie that has
      // nothing already queued after it — i.e. exactly the case that
      // otherwise just stops outright once the file ends. Only offered
      // if the person has opted into auto-queued recommendations (the
      // same setting that gates the equivalent music continuation
      // feature), since fetching + surfacing a recommendation the
      // person didn't ask for isn't something to do by default.
      //
      // `current.audioOnly`/`isLive` guard this out for music and Live
      // TV, both of which already have their own handling elsewhere
      // (repeat/continuation logic, and "no real end" respectively).
      if (!isEpisodeQueue &&
          current != null &&
          !current.audioOnly &&
          !isLive &&
          !queue.hasNext &&
          !nextMovieShown &&
          AppSettings.autoQueueRecommendations.value &&
          (reachedRealOutro || reachedMovieFallback)) {

        // Set immediately, not after the fetch resolves — this listener
        // fires on every position tick, and without setting the guard
        // up front the same window would kick off a duplicate fetch on
        // every tick until the first one finished.
        nextMovieShown = true;

        unawaited(_maybeShowNextMovie(current, _playbackToken));
      }

      if (current != null) {

        SkipSegment? segment;

        for (final s in [
          ...current.skipSegments,
          if (estimatedOutro != null) estimatedOutro,
        ]) {

          if (absoluteValue >= s.start &&
              absoluteValue <= s.end) {

            segment = s;
            break;
          }
        }

        if (!skipPressed) {
          activeSkipSegment.value = segment;
        }

        if (activeSkipSegment.value != null &&
            absoluteValue > activeSkipSegment.value!.end) {

          activeSkipSegment.value = null;
        }
      }
    });

    player.stream.duration.listen((value) {
      if (value > Duration.zero) {
        PlaybackLoadProgress.instance.durationKnown();
      }
      // Jellyfin's own metadata (`item.runtime`) always wins over
      // whatever mpv reports here — a `.ts` progressive transcode (any
      // capped-quality stream — see getVideoStreamUrl's doc comment)
      // may report an incomplete or flatly wrong duration even after
      // "settling" (MPEG-TS has no duration header the way MP4/MKV
      // does, so mpv is only ever estimating from PTS timestamps), and
      // even at offset zero a late, wrong event here would silently
      // clobber a correct value _waitForDuration already established.
      // Only actually falls through to mpv's own value for the rare
      // item Jellyfin hasn't given a runtime for at all.
      final current = currentItem;
      // Addon streams: the metadata runtime comes from TMDB and often
      // differs from the real file by minutes, which put "near the end"
      // (credits, Next Episode / Next Movie) in the wrong place. The
      // player's own reading of the file is the truth there.
      final addon = current?.raw?['AddonStream'] == true;
      final real = (current != null &&
              current.runtime > Duration.zero &&
              !(addon && value > Duration.zero))
          ? current.runtime
          : value;

      // A StartTimeTicks-based transcode segment's OWN duration is
      // "how much is left from wherever it started", not the item's
      // real, full duration (see _streamPositionOffset's doc comment) —
      // accepting that here on every quality-driven reopen is what made
      // the seek bar's total length jump around after switching
      // quality/audio track, the same underlying mistake as Live TV's
      // "duration = how much has streamed so far". Once the real
      // duration is known, it's frozen for the rest of this playback
      // session; only a segment opened at offset zero (or a value that
      // came from Jellyfin's own metadata, which is correct regardless
      // of offset) is ever allowed to update it again.
      if (_streamPositionOffset == Duration.zero || real == current?.runtime) {
        _originalDuration = real;
        duration.value = real;
      }
    });

    player.stream.buffer.listen((value) {
      bufferedPosition.value = value;
    });

    // Audio-switch stall watchdog (see _beginAudioSwitchWatch): every
    // position tick proves frames are moving.
    player.stream.position.listen((_) => _onAudioSwitchPositionTick());

    player.stream.buffering.listen((value) {
      // `_audioSwitchStalled` keeps the indicator up after an audio-track
      // switch until frames are really moving again, even if mpv itself
      // reports `buffering == false` while the frame is frozen.
      buffering.value = value || _audioSwitchStalled;

      // A genuine mid-playback stall is stronger evidence the current
      // quality is too high for this connection than a passing bandwidth
      // probe is that it's fine — feeds Default mode's adaptive
      // downgrade (see NetworkQualityService.reportRebuffer). Only
      // counts once something is actually playing, not the initial
      // buffer-before-first-frame every item goes through on open.
      // (A pause caused by switching audio tracks is not a bad network.)
      if (value &&
          currentItem != null &&
          playing.value &&
          !_inAudioSwitchGrace) {
        NetworkQualityService.instance.reportRebuffer();
      }
    });

    // Default mode's automatic quality reacts here — either the network
    // conditions changed, or the person flipped Data Saver/Default/Max
    // Quality in Settings mid-playback. Registered once for the
    // singleton's lifetime rather than per-item; `_applyAdaptiveQuality`
    // itself is a no-op whenever there's nothing playing or the computed
    // target hasn't actually changed, so this is cheap to leave running.
    //
    // Network readings go through `_onNetworkQualityChanged`, which never
    // lets them touch a song that is already playing (see its doc
    // comment); an explicit mode change in Settings still applies
    // straight away.
    NetworkQualityService.instance.tier.addListener(_onNetworkQualityChanged);
    NetworkQualityService.instance.measured
        .addListener(_onNetworkQualityChanged);
    AppSettings.playbackQualityMode.addListener(_onQualityInputsChanged);

    // mpv reports the tracks it actually demuxed from the file — this
    // fires once playback opens a new item (and again if the container
    // exposes more tracks than it did at first). We use it to attach a
    // real, switchable native track id to each of Jellyfin's own
    // MediaStreams entries. See `_syncTracks` for how the two are paired.
    player.stream.tracks.listen(_syncTracks);

    // `player.stream.subtitle` is the same list of text lines
    // `SubtitleView` subscribes to internally; mirrored here so our
    // own overlay stays in sync.
    player.stream.subtitle.listen((lines) {
      if (_ownCues.isNotEmpty) return; // own renderer is in charge
      currentSubtitleLines.value = lines;
    });

    // Seeded from current state in case a dimension is already known
    // (e.g. re-attaching mid-playback) rather than waiting for the
    // next change.
    videoWidth.value = player.state.width;
    videoHeight.value = player.state.height;
    player.stream.width.listen((w) {
      videoWidth.value = w;
      if ((w ?? 0) > 0) PlaybackLoadProgress.instance.firstFrame();
    });
    player.stream.height.listen((h) => videoHeight.value = h);

    player.stream.playing.listen((value) {
      // NO LOCAL AUDIO WHILE CASTING: mpv must never run while a cast
      // session is connected. Pause it right back and leave `playing`
      // (mirrored from the session) and audio focus alone.
      if (value && _castBlocksLocalAudio) {
        unawaited(player.pause());
        return;
      }
      playing.value = value;

      if (value) {
        // Tells Android/iOS this app now owns the audio output — this is
        // the actual AudioManager.requestAudioFocus() call under the
        // hood. Firing it every time playback (re)starts, rather than
        // once at app startup, means resuming after someone else's audio
        // ends re-asserts focus instead of silently assuming we still
        // have it. Safe to call repeatedly; it's a no-op if focus is
        // already held.
        unawaited(_audioSession?.setActive(true));

        // Safety net for a permanent audio-focus loss (someone else now
        // owns playback indefinitely): the OS never sends a matching
        // "interruption ended" event for that case (see
        // _handleAudioInterruption's doc comment), so _fadeOutThenPause's
        // volume-0 from the fade would otherwise sit there forever until
        // something explicitly restored it. Resetting it here too, on
        // every transition into "playing" for any reason, means a later
        // manual resume from the UI can never come back silent — it's a
        // cheap, idempotent call the rest of the time (already-restored
        // volume just gets set to the same value again).
        unawaited(player.setVolume(_volumeGain));
        // `playing` flips true as soon as the native player accepts
        // the play command — not once a real frame of *this* file has
        // actually been decoded and handed to the video surface (the
        // surface is reused between titles rather than recreated, so
        // it keeps showing whatever the *previous* title's last frame
        // was until the new one's first frame lands). Clearing
        // `loading` right on this event dropped the backdrop+logo
        // overlay early enough to let that stale previous-title frame
        // show through for a beat — the "flash of the last movie"
        // when starting a new one — and, separately, could drop it
        // before the new backdrop's own network image had finished
        // loading, leaving nothing where the backdrop should be for
        // that first title. A short settle delay after this event
        // gives both the video surface and the backdrop image time to
        // actually catch up before the overlay comes down. Guarded by
        // item id so a quick title change during the delay (or a
        // pause/resume blip re-firing this event) can't clear
        // `loading` for the wrong item or reset it early.
        final playedItemId = currentItemNotifier.value?.id;

        Future.delayed(const Duration(milliseconds: 450), () async {
          if (currentItemNotifier.value?.id != playedItemId) return;

          // Nothing to wait for when the loading screen is already down
          // (a pause -> resume blip mid-playback re-fires this event).
          if (!loading.value) return;

          // The settle delay above is usually enough, but on a slow
          // connection (or a resume seek far into a transcoded file)
          // the *initial* buffer fill can still be in progress once it
          // elapses. Clearing `loading` while `buffering` is still true
          // hands the screen straight to BufferingOverlay — which is
          // only ~15% opaque by design, meant to dim the *current*
          // title's own genuinely-stuck frame during a mid-playback
          // rebuffer, not to hide anything. During this initial load
          // that "stuck frame" underneath is actually whatever the
          // *previous* title left on the shared, reused video surface
          // (see the comment above), so handing off to a translucent
          // overlay here let that stale frame show clearly through it —
          // this was the actual source of the "flash of the previous
          // movie" bug, caught on camera as a single frame of the prior
          // title's video sitting behind this title's already-loaded
          // top bar/controls. Waiting here for buffering to genuinely
          // finish keeps the fully-opaque LoadingOverlay up until
          // there's real, current-title video underneath to reveal.
          if (buffering.value) {
            final completer = Completer<void>();

            void onBufferingChange() {
              if (!buffering.value && !completer.isCompleted) {
                completer.complete();
              }
            }

            buffering.addListener(onBufferingChange);

            // Safety net: never block the overlay from coming down
            // forever if `buffering` gets stuck true for some other
            // reason (bad stream, stalled connection, etc.) — the
            // existing 10s safety-net timer further down still applies
            // on top of this as a last resort.
            await completer.future.timeout(
              const Duration(seconds: 8),
              onTimeout: () {},
            );

            buffering.removeListener(onBufferingChange);
          }

          // NAMESIS PRIME: `playing` (and even `buffering == false`) can
          // arrive before mpv is really rolling, mostly with network
          // streams: it has decoded the first frame, then waits on it at
          // 00:00 for its cache to fill. Taking the loading screen down at
          // that point showed a frozen 00:00 for a long moment before the
          // video started. Wait (bounded) until a picture exists AND the
          // position is genuinely moving, so that when the loading screen
          // goes away the video is already playing.
          final waitingItem = currentItemNotifier.value;
          if (waitingItem != null &&
              waitingItem.id == playedItemId &&
              waitingItem.audioOnly != true &&
              !waitingItem.live) {
            final torrent = waitingItem.raw?['IsTorrent'] == true;
            await _waitForRealPlayback(
              waitingItem,
              frameTimeout: Duration(seconds: torrent ? 240 : 60),
              progressTimeout: Duration(seconds: torrent ? 120 : 45),
            );
          }

          if (currentItemNotifier.value?.id == playedItemId) {
            loading.value = false;
          }
        });
      }
    });

    // A capped (server-transcoded) music stream can be dropped by the
    // server partway through. When mpv sees the connection die with an
    // error rather than a clean end of file, `completed` never fires at
    // all, so without this the song simply stops and nothing advances.
    // See _recoverCutShortAudioStream.
    player.stream.error.listen((message) {
      debugPrint("PLAYER ERROR: $message");
      unawaited(_recoverCutShortAudioStream(reason: "error: $message"));
      // NAMESIS PRIME: a video that cannot be opened used to leave the
      // logo loading screen up forever. Close it and say why.
      final failing = currentItem;
      if (failing != null &&
          failing.audioOnly != true &&
          !failing.live &&
          failing.raw?['AddonStream'] == true &&
          loading.value) {
        _scheduleOpenFailureCheck(failing, message);
      }
    });

    // NAMESIS PRIME: mpv's own warnings/errors (HTTP status, TLS, codec
    // problems) were never printed, which made "black screen" impossible
    // to diagnose from a log.
    player.stream.log.listen((log) {
      final level = log.level.toString();
      final isError = level == 'error' || level == 'fatal';
      final interesting = const {
        'stream', 'file', 'demux', 'ffmpeg', 'vo', 'vd', 'cplayer',
        'http', 'tls', 'hwdec',
      }.contains(log.prefix);
      if (isError || (level == 'warn' && interesting)) {
        debugPrint('[mpv $level] ${log.prefix}: ${log.text.trim()}');
      }
    });

    player.stream.completed.listen(
            (completed) async {

          if (!completed) return;

          // A capped music stream that "completes" well before the
          // song's real length was cut short by the server, not
          // finished — rebuild it instead of advancing the queue.
          if (await _recoverCutShortAudioStream(reason: "completed")) {
            return;
          }

          // A live channel reaching "completed" doesn't mean the
          // broadcast ended — it means playback caught up to however
          // much of the channel's stream has been received so far.
          // Falling through to the queue-advance/stop logic below
          // would end the session outright the moment that happened
          // (i.e. right as the seek bar reached its live edge), so
          // just nudge playback to keep going instead of treating it
          // like a finished VOD title.
          if (currentItem?.live ?? false) {
            if (!_castBlocksLocalAudio) await player.play();
            return;
          }

          final queue =
              PlaybackQueue.instance;

          if (queue.repeatMode ==
              QueueRepeatMode.one) {

            await playMedia(
              queue.current!,
              resume: !queue.current!.audioOnly,
            );

            return;
          }

          // Episodes/live-TV-adjacent series queues don't participate
          // in the consume/loop queue behavior below — that's specific
          // to audio (where the Queue screen needs to show played
          // songs disappearing, or the whole thing looping forever on
          // repeat-all). Episodes just advance to the next one if
          // there is one; a movie/show with nothing else queued (which,
          // thanks to _maybeShowNextMovie appending its find straight
          // into PlaybackQueue, also covers "no recommendation was
          // found/offered" — a resolved one would already show up here
          // as `queue.hasNext`) has nothing left to show, so the player
          // screen closes itself instead of sitting on a frozen last
          // frame.
          if (currentItem?.audioOnly != true) {
            if (queue.hasNext) {
              await playNext();
            } else if (_isExternalFile(currentItem)) {
              await _finishExternalFilePlayback();
            } else {
              showNextEpisode.value = false;
              nextEpisode.value = null;
              showNextShow.value = false;
              nextShowRecommendation.value = null;
              showNextMovie.value = false;
              nextMovieRecommendation.value = null;
              playbackFinished.value = true;
            }

            return;
          }

          final finishedItem = currentItem;

          final nextItem = queue.completeCurrent();

          if (nextItem != null) {
            await playMedia(nextItem, resume: false);
            return;
          }

          // A file opened via Open With/Play With (see
          // ExternalMediaHandler) has no library screen underneath the
          // player to fall back into — the person picked this one file
          // specifically, so finishing it naturally shouldn't dismiss
          // the mini player/Now Playing screen the way an ordinary
          // exhausted queue does below. See _finishExternalFilePlayback.
          if (_isExternalFile(finishedItem)) {
            await _finishExternalFilePlayback();
            return;
          }

          // Queue exhausted with repeat off. If auto-queue
          // recommendations is turned on, try to keep the session going
          // with similar songs before giving up and stopping outright.
          if (AppSettings.autoQueueRecommendations.value &&
              finishedItem != null) {
            final tokenBeforeFetch = _playbackToken;

            final recommended = await MusicRecommendationService.instance
                .buildContinuation()
                .catchError((_) => <MediaItem>[]);

            // Bail if something else (a manual skip, a new queue, a
            // stop) has already superseded this completion while the
            // network calls above were in flight.
            if (tokenBeforeFetch != _playbackToken) return;

            if (recommended.isNotEmpty) {
              queue.appendRecommendations(recommended);
              final upNext = queue.current;
              if (upNext != null) {
                await playMedia(upNext);
                return;
              }
            }
          }

          // Nothing left to play (recommendations off, none found, or
          // the person doesn't have enough listening history yet this
          // session to seed from). Fully stop so the mini player
          // deactivates, and so that currentItemNotifier turning null
          // pops the Now Playing/Lyrics screen back out automatically if
          // the user is sitting on either of them (see AudioPlayerScreen
          // and LyricsScreen's currentItemNotifier listeners).
          await stop();
        });
  }

  /// Requests Android/iOS audio focus for "media" playback and starts
  /// listening for interruptions — another app starting its own playback,
  /// a phone call, an alarm/notification sound, headphones being
  /// unplugged. Without this, mpv (via media_kit) has no idea any of that
  /// is happening and just keeps playing straight over it, which is the
  /// "two things play at once" bug this fixes.
  ///
  /// `androidWillPauseWhenDucked: true` tells the OS this app would
  /// rather pause outright than duck (play quietly underneath); that
  /// collapses the "duck" and "pause" interruption types into one
  /// consistent behavior below instead of having to also implement a
  /// separate lowered-volume-while-playing state.
  Future<void> _configureAudioSession() async {
    final session = await AudioSession.instance;
    _audioSession = session;

    await session.configure(const AudioSessionConfiguration(
      avAudioSessionCategory: AVAudioSessionCategory.playback,
      avAudioSessionCategoryOptions:
          AVAudioSessionCategoryOptions.duckOthers,
      avAudioSessionMode: AVAudioSessionMode.defaultMode,
      avAudioSessionRouteSharingPolicy:
          AVAudioSessionRouteSharingPolicy.defaultPolicy,
      avAudioSessionSetActiveOptions: AVAudioSessionSetActiveOptions.none,
      androidAudioAttributes: AndroidAudioAttributes(
        contentType: AndroidAudioContentType.movie,
        usage: AndroidAudioUsage.media,
      ),
      androidAudioFocusGainType: AndroidAudioFocusGainType.gain,
      androidWillPauseWhenDucked: true,
    ));

    session.interruptionEventStream.listen(_handleAudioInterruption);

    // "Becoming noisy" is Android's term for the audio route disappearing
    // out from under active playback — wired headphones/Bluetooth
    // disconnecting being the classic case. Without this, audio keeps
    // playing and suddenly comes out of the phone's speaker at full
    // volume the instant that happens; every OS-native media app pauses
    // on this event for exactly that reason.
    session.becomingNoisyEventStream.listen((_) {
      if (playing.value) {
        unawaited(player.pause());
      }
    });
  }

  /// Fired for every audio-focus interruption: another app starting
  /// playback, a phone call ringing/connecting, an alarm, or a transient
  /// notification/media-button chime. `event.begin == true` is the start
  /// of the interruption, `false` is the OS telling us it's over.
  ///
  /// `AudioInterruptionType.unknown` on the begin/end pair means a
  /// *permanent* loss — something else now owns audio output indefinitely
  /// (the common case: the person picked a different app to actually
  /// listen to) — so playback is faded out and paused, but deliberately
  /// left paused once the interruption "ends"; auto-resuming would mean
  /// Nemesis barging back in over whatever the person actually chose to
  /// play instead. `pause`/`duck` are transient (a short system sound, a
  /// brief call ring before it's declined) and DO resume automatically
  /// once they end, same as Spotify/YouTube Music.
  void _handleAudioInterruption(AudioInterruptionEvent event) {
    final token = ++_fadeToken;

    if (event.begin) {
      if (!playing.value) return;

      _resumeOnInterruptionEnd =
          event.type != AudioInterruptionType.unknown;

      unawaited(_fadeOutThenPause(token));
    } else {
      final shouldResume = _resumeOnInterruptionEnd;
      _resumeOnInterruptionEnd = false;

      // Always restore volume even when not resuming, so a later manual
      // play() doesn't start back up at whatever quiet level the fade
      // left it at.
      unawaited(_restoreVolumeThenMaybeResume(
        token,
        resume: shouldResume,
      ));
    }
  }

  /// Ramps `player`'s own output volume down to 0 over [duration] rather
  /// than cutting it instantly — an abrupt stop reads as a glitch, a
  /// short fade reads as intentional, same reasoning as every other
  /// player's ducking/pause transition. Guarded by [token] (bumped once
  /// per interruption event in `_handleAudioInterruption`) so an
  /// interruption ending — or a second one beginning — mid-fade doesn't
  /// leave two competing volume ramps fighting over the same player.
  Future<void> _fadeOutThenPause(
    int token, {
    Duration duration = const Duration(milliseconds: 400),
    int steps = 8,
  }) async {
    final startVolume = player.state.volume;
    final stepDuration = duration ~/ steps;

    for (var i = 1; i <= steps; i++) {
      if (token != _fadeToken) return;
      final v = startVolume * (1 - (i / steps));
      await player.setVolume(v < 0 ? 0 : v);
      await Future.delayed(stepDuration);
    }

    if (token != _fadeToken) return;
    await player.pause();
    // Restored on resume (or on the next play() call) — see
    // `_restoreVolumeThenMaybeResume`/the playing-listener's
    // `setActive(true)` above. Volume is deliberately left at 0 here
    // rather than reset immediately, so nothing briefly blips back to
    // full volume for the instant between pause() landing and this
    // function returning.
  }

  Future<void> _restoreVolumeThenMaybeResume(
    int token, {
    required bool resume,
  }) async {
    if (token != _fadeToken) return;
    await player.setVolume(_volumeGain);
    if (resume && token == _fadeToken && !_castBlocksLocalAudio) {
      await player.play();
    }
  }

  /// Combines Jellyfin's `MediaStreams` metadata (nice display names,
  /// language, default/forced flags — the "obtained from the Jellyfin
  /// server" part) with the tracks media_kit/mpv actually demuxed from
  /// the currently-open file (the only thing that can actually be passed
  /// back to `Player.setAudioTrack`/`setSubtitleTrack`).
  ///
  /// Playback always uses the server's direct/static stream endpoint
  /// (see `MediaService.getPlaybackUrl`), i.e. mpv is demuxing the exact
  /// same container Jellyfin described — so the order Jellyfin lists a
  /// given stream type in matches the order mpv exposes it in, and the
  /// two lists can be paired positionally.
  void _syncTracks(Tracks tracks) {
    // CAST-ONLY GUARD (Open With/Play With sent straight to an already-
    // connected TV): the audio/subtitle lists belong to the cast item and
    // were seeded by PlaybackCoordinator without mpv (see
    // seedCastOnlySubtitles / _seedLocalCastAudio). mpv's own track list
    // at this point describes whatever it last had open, so a late tracks
    // event must not overwrite the seeded lists with that stale data.
    // `castOnlySubtitles` is cleared the moment anything is opened locally
    // (playMedia) or the cast ends, so normal playback is unaffected.
    if (castOnlySubtitles) return;

    final item = currentItem;

    if (item == null) {
      audioTracks.value = const [];
      subtitles.value = const [];
      return;
    }

    // 'auto'/'no' are pseudo-entries media_kit always injects (meaning
    // "let mpv decide" / "none") — they aren't real selectable tracks,
    // and leaving them in would make even a single-track file look like
    // it had a choice to make.
    final nativeAudio = tracks.audio
        .where((t) => t.id != 'auto' && t.id != 'no')
        .toList();

    final nativeSubs = tracks.subtitle
        .where((t) => t.id != 'auto' && t.id != 'no')
        .toList();

    // Live channel: (re)apply the closed-captions choice now that mpv has
    // listed its tracks (the caption track only exists from this point).
    if (item.live && !item.audioOnly) unawaited(_applyClosedCaptionChoice());

    // BUGFIX (duplicate sidecar subtitle entry) — see
    // _baselineNativeSubtitleIds' own doc comment: freeze which native
    // ids were genuinely demuxed from the file on this item's very first
    // `_syncTracks` firing, before this app has had any chance to
    // `sub-add` anything of its own on top.
    _baselineNativeSubtitleIds ??= nativeSubs.map((t) => t.id).toSet();

    // DIAGNOSTIC (Open With/Play With subtitle investigation): dumps
    // exactly what mpv itself reported for this file's audio/subtitle
    // tracks the moment this listener fires, for an externally-opened
    // file only (this is noisy — every Jellyfin title's normal
    // `_syncTracks` firing would otherwise print the same thing on every
    // track-list change). The audio branch below already lists mpv's
    // native audio tracks directly and that works, built from the exact
    // same `tracks` object — if `nativeSubs` prints empty here while
    // `nativeAudio` doesn't, mpv itself never demuxed a subtitle track
    // out of this file over the content:// input, which is a different
    // fix (further up the stack, at how the file is opened) than
    // anything in this function's own pairing logic below. If both print
    // real entries, the bug is downstream of this point and traceable
    // from here. Remove once this is confirmed either way.
    if (item.raw?['IsExternalFile'] == true) {
      debugPrint('=== EXTERNAL FILE TRACK SYNC ===');
      debugPrint('Raw mpv audio tracks (${tracks.audio.length}):');
      for (final t in tracks.audio) {
        debugPrint(
          '  id=${t.id} title=${t.title} lang=${t.language} '
          'codec=${t.codec}',
        );
      }
      debugPrint('Raw mpv subtitle tracks (${tracks.subtitle.length}):');
      for (final t in tracks.subtitle) {
        debugPrint(
          '  id=${t.id} title=${t.title} lang=${t.language} '
          'codec=${t.codec}',
        );
      }
      debugPrint(
        'Filtered: nativeAudio=${nativeAudio.length} '
        'nativeSubs=${nativeSubs.length}',
      );
      debugPrint('================================');
    }

    final jellyfinAudio = MediaStreamParser.audio(item.mediaStreams);

    // The first (and, for the vast majority of items, only) media source
    // is what actually got opened by playMedia()'s static stream URL, so
    // its id is what the /Subtitles/{index}/Stream.vtt extraction URL
    // needs — falling back to the item id itself covers items Jellyfin
    // reports without a distinct MediaSources entry.
    final mediaSourceId = (item.mediaSources != null &&
            item.mediaSources!.isNotEmpty)
        ? item.mediaSources!.first["Id"] as String? ?? item.id
        : item.id;

    final jellyfinSubs = MediaStreamParser.subtitles(
      item.mediaStreams,
      itemId: item.id,
      mediaSourceId: mediaSourceId,
    );

    // TRANSCODE FIX ("switching quality sometimes kills the audio"):
    // the positional pairing below is only valid for a direct stream,
    // where mpv is demuxing the exact container Jellyfin described, so
    // the Nth audio track in each list is the same track. A capped
    // quality is not that. Jellyfin encodes exactly ONE audio track into
    // a transcode — the one `AudioStreamIndex` asked for — so mpv
    // reports a single track while Jellyfin's `MediaStreams` still lists
    // all of them. Pairing those positionally handed every track except
    // the first a native id that doesn't exist in the open file, and
    // `_pendingAudioReapply` below would then faithfully select it after
    // every quality change. The person had picked, say, the third audio
    // track; the reopen correctly baked that track into the transcode;
    // and then this handed mpv a track id for a stream that wasn't
    // there, so the movie came back silent. It only happened on titles
    // with more than one audio track, and only when the selected one
    // wasn't the first — which is why it looked intermittent.
    final isTranscodedStream = !item.audioOnly &&
        !_isOfflineFile(item) &&
        _activeVideoLevel != null;

    // Which of Jellyfin's tracks the single native one actually is.
    final bakedAudioIndex = isTranscodedStream
        ? (_activeAudioStreamIndex ?? _defaultAudioStreamIndex(item))
        : null;

    final resolvedAudio = <AudioTrack>[
      if (isTranscodedStream)
        for (final track in jellyfinAudio)
          AudioTrack(
            index: track.index,
            language: track.language,
            displayTitle: track.displayTitle,
            isDefault: track.isDefault,
            // Only the baked-in track has a real native counterpart.
            // The others stay listed so they're still pickable — going
            // through `selectAudioTrack` reopens the stream with that
            // index baked in instead, which is the only way to switch
            // tracks on a transcode anyway.
            nativeId: (track.index == bakedAudioIndex && nativeAudio.isNotEmpty)
                ? nativeAudio.first.id
                : track.nativeId,
          )
      else if (jellyfinAudio.isEmpty && item.raw?['IsExternalFile'] == true)
        // Externally-opened files (Open With/Play With — see
        // ExternalMediaHandler) have no Jellyfin item behind them, so
        // `jellyfinAudio` is always empty for one — same reason
        // `jellyfinSubs` is always empty just below. List mpv's own
        // demuxed audio tracks directly, exactly like the subtitle
        // branch does: selection goes straight through `nativeId`,
        // which is all a real embedded track ever needed anyway. This
        // is also always the "instant native switch" path in
        // `selectAudioTrack` (never the transcode-reopen one) — there's
        // no Jellyfin quality/transcode concept for a file that never
        // came from a Jellyfin server in the first place, so
        // `_activeVideoLevel` is never set for one.
        for (var i = 0; i < nativeAudio.length; i++)
          AudioTrack(
            index: i,
            language: nativeAudio[i].language ?? '',
            displayTitle: nativeAudio[i].title ??
                ((nativeAudio[i].language ?? '').isNotEmpty
                    ? nativeAudio[i].language!
                    : 'Track ${i + 1}'),
            isDefault: false,
            nativeId: nativeAudio[i].id,
          )
      else
        for (var i = 0; i < jellyfinAudio.length; i++)
          AudioTrack(
            index: jellyfinAudio[i].index,
            language: jellyfinAudio[i].language,
            displayTitle: jellyfinAudio[i].displayTitle,
            isDefault: jellyfinAudio[i].isDefault,
            nativeId: i < nativeAudio.length
                ? nativeAudio[i].id
                : jellyfinAudio[i].nativeId,
          ),
    ];

    // Paired separately from a plain positional zip against `jellyfinSubs`
    // — mpv's `nativeSubs` only ever contains tracks actually muxed into
    // the file, so whenever Jellyfin's list mixes embedded and external
    // subtitles, a naive same-index pairing drifts out of alignment for
    // every embedded entry that comes after an external one. Tracking a
    // separate counter that only advances for non-external entries keeps
    // each embedded subtitle paired with the right native track
    // regardless of where the external ones fall in the list.
    final resolvedSubs = <SubtitleTrack>[];
    var embeddedIndex = 0;

    // DOWNLOADED SUBTITLES FIX: a downloaded movie/episode already has
    // its own subtitle sidecar files saved right next to it on disk
    // (see DownloadManager._runVideoTask's own doc comment on
    // `subtitlePaths`) — the entire point of downloading them at all is
    // so subtitles keep working with zero network access. `jellyfinSubs`
    // above is still built from this same item's live MediaStreams
    // metadata (DownloadManager keeps the original Jellyfin item around
    // so detail screens still work), but every URL that metadata
    // resolves to (see MediaStreamParser.subtitles) points at this
    // phone's Jellyfin *server* — completely unreachable once the
    // download is actually being played offline. Reading the sidecars
    // straight off disk instead sidesteps that entirely: same
    // `SubtitleTrack.data()` no-network path an OpenSubtitles download
    // already uses, just sourced from a local file instead of an
    // in-memory API response. Checked via DownloadManager directly
    // (same "look the id up in the download records" the lyrics screen
    // already does for a downloaded song) rather than something baked
    // into `item.raw`, since nothing else needs these paths.
    // SIDECAR FIX: the saved list PLUS whatever else sits next to the video
    // with the video's own name (see DownloadManager.subtitlePathsFor), so a
    // subtitle file added to the folder later, or one the record never
    // listed, is detected by name too.
    final downloadedSubtitlePaths =
        DownloadManager.instance.subtitlePathsFor(item.id);

    if (downloadedSubtitlePaths.isNotEmpty) {
      final videoBaseName = _fileBaseNameNoExt(item.streamUrl);

      for (var i = 0; i < downloadedSubtitlePaths.length; i++) {
        final path = downloadedSubtitlePaths[i];
        final fileName = _fileBaseNameNoExt(path);

        // Sidecars are saved as "<video base name>.<lang>.vtt" (see
        // _runVideoTask) — strip the shared prefix back off so the
        // sheet shows just the language/dedup-suffix part rather than
        // repeating the whole movie title on every row.
        var label = (videoBaseName.isNotEmpty &&
                fileName.startsWith('$videoBaseName.'))
            ? fileName.substring(videoBaseName.length + 1)
            : fileName;
        if (label.isEmpty) label = 'Subtitle ${i + 1}';

        resolvedSubs.add(
          SubtitleTrack(
            index: i,
            language: label,
            displayTitle: label.toUpperCase(),
            // No Jellyfin default/forced flag survives into a plain
            // saved file path — left unselected rather than guessing;
            // the person picks the language they want from the sheet,
            // same as they would for an OpenSubtitles search result.
            isDefault: false,
            isForced: false,
            nativeId: 'downloaded-sub-$i',
            isExternal: true,
            localPath: path,
          ),
        );
      }

      // Whatever mpv itself actually demuxed straight out of the
      // downloaded file — a muxed-in image-based PGS/VobSub track, say,
      // the one kind of subtitle DownloadManager's sidecar export can't
      // flatten to a text file (see its own doc comment) — is still
      // real and still selectable by native id. Listed after the
      // sidecar entries above, indexed to continue past them, so a
      // title with both never collides.
      // Skips any native id that wasn't already there on this item's
      // very first track sync (see _baselineNativeSubtitleIds' own doc
      // comment) — a downloaded sidecar that had already been selected
      // once would otherwise show up a second time here, since a
      // `sub-add` is real and native as far as mpv's own track list is
      // concerned.
      for (var i = 0; i < nativeSubs.length; i++) {
        final native = nativeSubs[i];
        if (!_baselineNativeSubtitleIds!.contains(native.id)) continue;
        final language = native.language ?? '';

        resolvedSubs.add(
          SubtitleTrack(
            index: downloadedSubtitlePaths.length + i,
            language: language,
            displayTitle: native.title ??
                (language.isNotEmpty ? language : 'Track ${i + 1}'),
            isDefault: false,
            isForced: false,
            nativeId: native.id,
          ),
        );
      }
    } else if (jellyfinSubs.isEmpty && item.raw?['IsExternalFile'] == true) {
      // Externally-opened files (Open With / Play With — see
      // ExternalMediaHandler) have no Jellyfin item behind them, so
      // `jellyfinSubs` is always empty for one — there's nothing to pair
      // mpv's demuxed tracks against by the usual positional matching
      // below. Rather than losing subtitles entirely for a movie/show
      // opened this way, list mpv's own native subtitle tracks directly:
      // selection just goes straight through `nativeId`, which is all a
      // real embedded track ever needed anyway (no Jellyfin extraction URL
      // involved). Audio tracks get the same treatment just above, in
      // `resolvedAudio`'s own IsExternalFile branch.
      // Skips any native id that wasn't already there on this item's
      // very first track sync (see _baselineNativeSubtitleIds' own doc
      // comment) — the auto-applied sidecar from
      // _reapplyCachedSubtitleIfAny would otherwise show up a second
      // time here, since a `sub-add` is real and native as far as mpv's
      // own track list is concerned.
      for (var i = 0; i < nativeSubs.length; i++) {
        final native = nativeSubs[i];
        if (!_baselineNativeSubtitleIds!.contains(native.id)) continue;
        final language = native.language ?? '';

        resolvedSubs.add(
          SubtitleTrack(
            index: i,
            language: language,
            displayTitle: native.title ??
                (language.isNotEmpty ? language : 'Track ${i + 1}'),
            isDefault: false,
            isForced: false,
            nativeId: native.id,
          ),
        );
      }
    } else {
      for (final sub in jellyfinSubs) {
        final nativeId = (!sub.isExternal && embeddedIndex < nativeSubs.length)
            ? nativeSubs[embeddedIndex].id
            : sub.nativeId;

        if (!sub.isExternal) embeddedIndex++;

        resolvedSubs.add(
          SubtitleTrack(
            index: sub.index,
            language: sub.language,
            displayTitle: sub.displayTitle,
            isDefault: sub.isDefault,
            isForced: sub.isForced,
            nativeId: nativeId,
            isExternal: sub.isExternal,
            externalUrl: sub.externalUrl,
          ),
        );
      }
    }

    // OpenSubtitles downloads (see loadDownloadedSubtitle) live entirely
    // outside Jellyfin's own MediaStreams — they're appended to
    // `subtitles.value` directly, by the app, after the fact. This
    // listener fires on ANY mpv track-list change though, which
    // includes the one caused by loading that very download (`sub-add`
    // changes mpv's internal track list, which re-triggers this same
    // stream) — so without this, resolvedSubs below (built purely from
    // Jellyfin's list) would silently replace `subtitles.value` and
    // wipe the just-downloaded entry back out the instant it was
    // selected, even though mpv was still actively rendering it. Their
    // always-negative index (never used by a real Jellyfin stream) is
    // what makes them identifiable here.
    final downloadedSubs =
        subtitles.value.where((t) => t.index < 0).toList();

    audioTracks.value = resolvedAudio;
    subtitles.value = [...resolvedSubs, ...downloadedSubs];

    // A quality-change reopen (manual Quality selector pick, or Data
    // Saver/Default/Max Quality switching things automatically — see
    // _reopenStreamPreservingState) left a specific track parked here to
    // be re-applied once the reopened file's real native track list
    // exists, rather than letting the "pick a default" logic below treat
    // this like a brand-new item with nothing selected yet.
    //
    // Deliberately calls `_applyNativeAudioTrack` here, NOT the public
    // `selectAudioTrack` — this is re-confirming a track that's already
    // correctly baked into the file that was just opened (the whole
    // point of the reopen), not a person picking a different one.
    // `selectAudioTrack` itself checks `_activeVideoLevel` to decide
    // whether changing tracks needs a reopen; calling it from here on a
    // constrained stream made it "change" to the same track by reopening
    // AGAIN — which fires this exact tracks-event listener again, which
    // called it again, forever. This was a real infinite reopen loop
    // that shipped and needed a live debug session to catch — see the
    // Quality Switch debugging thread if this comment doesn't make
    // sense in isolation.
    if (_pendingAudioReapply != null) {
      final pending = _pendingAudioReapply!;

      // Only consume this once we can actually find a real match — the
      // native track list can come through empty/incomplete on the
      // very first `_syncTracks` firing right after a reopen (before
      // mpv has actually finished parsing the new file), and clearing
      // `_pendingAudioReapply` unconditionally here meant that
      // premature, empty firing consumed the request and fell back to
      // `pending`'s OLD nativeId — one that doesn't exist in the file
      // that's actually open now, silently selecting no audio at all.
      // There's no second chance once it's already been cleared, which
      // is exactly what made "the audio disappeared" only fixable by
      // manually reselecting a track (a fresh, guaranteed-current
      // AudioTrack from the UI, going through selectAudioTrack instead
      // of this stale one). Leaving it set here lets the next
      // `_syncTracks` firing — the one with the real track list — pick
      // it up correctly instead.
      if (resolvedAudio.isNotEmpty) {
        _pendingAudioReapply = null;

        if (isTranscodedStream) {
          // The reopen itself is what changed the track — the stream
          // that just opened contains exactly the one that was asked
          // for, and nothing else. There is no native switch left to
          // make, so this only records the selection. Calling
          // `setAudioTrack` here is what the fix above exists to stop.
          selectedAudio.value = resolvedAudio.firstWhere(
            (t) => t.index == bakedAudioIndex,
            orElse: () => resolvedAudio.firstWhere(
              (t) => t.index == pending.index,
              orElse: () => resolvedAudio.first,
            ),
          );
        } else {
          final match = resolvedAudio.firstWhere(
            (t) => t.index == pending.index,
            orElse: () => resolvedAudio.first,
          );

          unawaited(_applyNativeAudioTrack(match));
        }
      }
    } else if (selectedAudio.value == null && resolvedAudio.isNotEmpty) {
      // Reflect whichever track mpv actually started on, so the selector
      // shows an accurate checkmark instead of nothing-selected. On a
      // transcode "whichever mpv started on" is by definition the one
      // Jellyfin was told to encode, not the file's own default flag.
      selectedAudio.value = isTranscodedStream
          ? resolvedAudio.firstWhere(
              (t) => t.index == bakedAudioIndex,
              orElse: () => resolvedAudio.first,
            )
          : resolvedAudio.firstWhere(
              (t) => t.isDefault,
              orElse: () => resolvedAudio.first,
            );
    }

    if (_pendingSubtitleReapply != null) {
      final pending = _pendingSubtitleReapply!;
      _pendingSubtitleReapply = null;

      if (pending.index < 0) {
        // A downloaded/OpenSubtitles track (see the downloadedSubs
        // comment above) — not something Jellyfin's own list will ever
        // contain a match for, so there's nothing to look up; it's
        // already carried over into `subtitles.value` verbatim above.
        selectedSubtitle.value = pending;
      } else {
        final match = resolvedSubs.firstWhere(
          (t) => t.index == pending.index,
          orElse: () => pending,
        );
        unawaited(selectSubtitleTrack(match));
      }
    } else {
      _autoSelectDefaultSubtitle(resolvedSubs);
    }
  }

  /// DEFAULT SUBTITLE: every video that has subtitles starts with exactly
  /// one switched on — the file's own default/forced track when it has one,
  /// otherwise the first track in the list (server, downloaded or the
  /// tracks inside an Open With/Play With file). The person can still turn
  /// it off or pick another from the subtitle sheet, whose tick follows
  /// `selectedSubtitle`.
  ///
  /// Runs from `_syncTracks` (every tracks event) and once more when the
  /// cached-subtitle check finishes, so it must be idempotent: it never
  /// acts once something is selected, once the person has turned subtitles
  /// off, or once it has already acted for this item.
  void _autoSelectDefaultSubtitle(List<SubtitleTrack> candidates) {
    if (_subtitleUserOff || _autoSubtitleHandled) return;
    if (selectedSubtitle.value != null) return;
    if (castOnlySubtitles) return;

    final item = currentItem;
    if (item == null || item.audioOnly || item.live) return;

    // Until the cached/sidecar check is done only a file-flagged
    // default/forced track may be picked (the old behavior).
    final pick = pickDefaultSubtitle(
      candidates,
      allowFirstFallback: _cachedSubtitleCheckDone,
    );
    if (pick == null) return;

    _autoSubtitleHandled = true;
    // Actually select it, not just record it — mpv's own implicit
    // default only reliably kicks in for audio (something has to
    // play), not subtitles (off by default), and never for an
    // external one regardless (nothing to auto-pick since it was
    // never loaded in the first place). Setting the notifier alone
    // here left a title's default subtitle marked as "selected" in
    // the UI while nothing actually rendered.
    unawaited(selectSubtitleTrack(pick));
  }

  // ── Closed captions (live TV) ────────────────────────────────────────

  /// mpv only exposes in-stream captions when `sub-create-cc-track` is set
  /// BEFORE the stream is opened, so every open sets it: `yes` for a live
  /// channel, `no` for everything else (a movie must never grow a phantom
  /// caption track in its subtitle list). Never throws.
  Future<void> _prepareClosedCaptionOption(MediaItem item) async {
    _ccAppliedTrackId = null;
    final platform = player.platform;
    if (platform is! NativePlayer) return;
    try {
      await platform.setProperty(
        'sub-create-cc-track',
        item.live && !item.audioOnly ? 'yes' : 'no',
      );
    } catch (e) {
      debugPrint('[ClosedCaptions] could not set sub-create-cc-track: $e');
    }
  }

  /// The caption track mpv created from the stream, or null while mpv has
  /// not listed one yet. Matched by what mpv calls it; when nothing is
  /// recognisable, a channel with exactly one subtitle-type track means
  /// that one.
  mk.SubtitleTrack? _closedCaptionTrack(List<mk.SubtitleTrack> subs) {
    final real = subs.where((t) => t.id != 'auto' && t.id != 'no').toList();
    for (final t in real) {
      final label = '${t.codec} ${t.title}'.toLowerCase();
      if (label.contains('608') ||
          label.contains('708') ||
          label.contains('eia') ||
          label.contains('closed') ||
          label.contains('caption') ||
          label.contains('cc_dec')) {
        return t;
      }
    }
    return real.length == 1 ? real.first : null;
  }

  /// Turns the live channel's closed captions on or off. The captions are
  /// drawn by the same subtitle overlay every other subtitle uses.
  Future<void> setClosedCaptions(bool on) async {
    closedCaptionsOn.value = on;
    _ccAppliedTrackId = null;
    await _applyClosedCaptionChoice();
  }

  /// Makes mpv's selected subtitle match [closedCaptionsOn]. Safe to call
  /// repeatedly (every tracks event does): it only acts when the wanted
  /// track differs from what it last applied.
  Future<void> _applyClosedCaptionChoice() async {
    final item = currentItem;
    if (item == null || !item.live || item.audioOnly || castOnlySubtitles) {
      return;
    }
    try {
      if (!closedCaptionsOn.value) {
        if (_ccAppliedTrackId == 'no') return;
        _ccAppliedTrackId = 'no';
        await player.setSubtitleTrack(mk.SubtitleTrack.no());
        return;
      }
      final cc = _closedCaptionTrack(player.state.tracks.subtitle);
      // Not listed yet: the next tracks event calls this again.
      if (cc == null) return;
      if (_ccAppliedTrackId == cc.id) return;
      _ccAppliedTrackId = cc.id;
      await player.setSubtitleTrack(cc);
    } catch (e) {
      _ccAppliedTrackId = null;
      debugPrint('[ClosedCaptions] could not apply the caption choice: $e');
    }
  }

  /// Runs the remembered/sidecar subtitle check, then — if it didn't
  /// select anything — falls back to the default subtitle of the tracks
  /// that are listed by then.
  Future<void> _applyCachedThenDefaultSubtitle(MediaItem item, int token) async {
    try {
      await _reapplyCachedSubtitleIfAny(item, token);
    } catch (e) {
      debugPrint('[Subtitles] cached subtitle check failed: $e');
    }
    if (token != _playbackToken || currentItem?.id != item.id) return;
    _cachedSubtitleCheckDone = true;

    // Listed tracks excluding OpenSubtitles/sidecar entries (negative
    // index), which the check above already had its chance to select.
    _autoSelectDefaultSubtitle(
      subtitles.value.where((t) => t.index >= 0).toList(),
    );
  }

  /// The Jellyfin stream index of the audio track that will play if
  /// nothing pins one explicitly — the track flagged `IsDefault`, or the
  /// first audio stream when nothing is flagged, matching how the
  /// container itself picks. Used wherever a transcode URL and the app's
  /// own idea of "what's selected" have to agree about which track the
  /// server is encoding; see `_applyVideoLevel` and `_syncTracks`.
  int? _defaultAudioStreamIndex(MediaItem item) {
    final audio = MediaStreamParser.audio(item.mediaStreams);
    if (audio.isEmpty) return null;

    for (final track in audio) {
      if (track.isDefault) return track.index;
    }
    return audio.first.index;
  }

  /// Switches the active audio track. `track` carries Jellyfin's display
  /// metadata plus the native id resolved by [_syncTracks], which is
  /// what actually drives mpv's track switch — at Original quality,
  /// where every one of the item's tracks is embedded in the file mpv
  /// already has open, so this is instant with no re-buffering.
  ///
  /// When a resolution/bitrate-capped quality is active (Quality
  /// selector, Data Saver, or Default mode's network-driven downgrade),
  /// there's no second native track to just flip over to — the
  /// transcode only ever contains the one Jellyfin was told to encode
  /// (see MediaService.getVideoStreamUrl). Switching tracks there
  /// instead reopens the stream at the exact same quality with the new
  /// track's Jellyfin index baked in, preserving position/play state via
  /// [_reopenStreamPreservingState] the same way a quality change does —
  /// audio-track selection keeps working either way, it's just an
  /// instant native switch in the common case and a brief reopen in the
  /// constrained one.
  Future<void> selectAudioTrack(AudioTrack track) async {
    final item = currentItem;

    if (_activeVideoLevel != null &&
        item != null &&
        !item.audioOnly &&
        !_isOfflineFile(item)) {
      // Already the track baked into the current transcode — nothing to
      // do. Without this guard, anything that calls this method again
      // for the *same* track while constrained (there was exactly one
      // such caller, now removed — see _syncTracks' pending-reapply
      // comment) would reopen the stream needlessly, and if that caller
      // itself gets invoked again as a result of the reopen, that's an
      // infinite loop, not just a wasted reopen. Kept as a hard
      // guarantee here too, not just fixed at the one call site.
      if (track.index == _activeAudioStreamIndex) return;

      _activeAudioStreamIndex = track.index;

      // Corrected absolute position, not raw player.state.position —
      // we're already on a transcode segment here (that's the whole
      // reason this branch exists), so the raw mpv position only
      // describes time within THAT segment, not the item's real
      // position. Using it directly here was the actual cause of "the
      // movie restarted from the beginning" when switching audio
      // tracks: it baked a near-zero StartTimeTicks into the new
      // request instead of wherever playback actually was. See
      // _absolutePosition/_streamPositionOffset.
      final resumeAt = _absolutePosition;

      final newUrl = _resolveVideoUrl(
        item,
        _activeVideoLevel,
        audioStreamIndex: track.index,
        startAt: resumeAt,
      );

      await _reopenStreamPreservingState(
        newUrl,
        forceSelectedAudio: track,
        // Already a transcode (that's why we're in this branch at all)
        // — StartTimeTicks above puts it at the right position, so no
        // client-side seek needed. See _applyVideoLevel's comment.
        seekAfterOpen: false,
        // Still a capped-quality stream after this reopen — position 0
        // on the new segment is really `resumeAt`, same reasoning as
        // _applyVideoLevel, and live is zero there for the same reason
        // it is here.
        newStreamOffset: item.live ? Duration.zero : resumeAt,
      );
      return;
    }

    await _applyAudioTrackSmoothly(track);
  }

  // ---------------------------------------------------------------------
  // Audio-track switching on a network stream.
  //
  // mpv only keeps the packets of the audio track that is selected, so
  // switching means the demuxer re-reads the stream from the current
  // position to find the new track's audio. mpv's normal `cache-pause`
  // behaviour is left untouched: while the new audio is fetched, mpv
  // pauses for cache, reports `buffering`, and the app's buffering
  // indicator shows until playback continues.
  //
  // As a safety net, a small watchdog forces `buffering` on if the position
  // stops advancing after a switch, and clears it once playback really
  // continues.
  // ---------------------------------------------------------------------
  static const Duration _audioSwitchGrace = Duration(seconds: 4);
  static const Duration _audioSwitchStallDelay = Duration(milliseconds: 600);
  static const Duration _audioSwitchMaxWait = Duration(seconds: 20);
  DateTime? _audioSwitchGraceUntil;
  Timer? _audioSwitchStallTimer;
  Timer? _audioSwitchMaxTimer;
  Timer? _audioSwitchGraceTimer;
  bool _audioSwitchWatching = false;
  bool _audioSwitchStalled = false;

  /// True for a few seconds after a switch so the pause it causes is not
  /// reported as a bad network (see the `buffering` listener).
  bool get _inAudioSwitchGrace {
    if (_audioSwitchWatching) return true;
    final until = _audioSwitchGraceUntil;
    return until != null && DateTime.now().isBefore(until);
  }

  void _beginAudioSwitchWatch() {
    _endAudioSwitchWatch();
    _audioSwitchWatching = true;
    _audioSwitchGraceUntil = DateTime.now().add(_audioSwitchGrace);
    _armAudioSwitchStallTimer();
    // If playback never stalls, stop watching after the grace window; if it did stall, keep the indicator up
    // until playback resumes, bounded by the max wait.
    _audioSwitchGraceTimer = Timer(_audioSwitchGrace, () {
      if (!_audioSwitchStalled) _endAudioSwitchWatch();
    });
    _audioSwitchMaxTimer = Timer(_audioSwitchMaxWait, _endAudioSwitchWatch);
  }

  void _armAudioSwitchStallTimer() {
    _audioSwitchStallTimer?.cancel();
    _audioSwitchStallTimer = Timer(_audioSwitchStallDelay, () {
      if (!_audioSwitchWatching) return;
      // Paused by the person: nothing is being waited for.
      if (!playing.value) {
        _armAudioSwitchStallTimer();
        return;
      }
      // No position tick for a while although we are meant to be
      // playing: the frame is frozen waiting for the new audio.
      _audioSwitchStalled = true;
      buffering.value = true;
    });
  }

  void _onAudioSwitchPositionTick() {
    if (!_audioSwitchWatching) return;
    if (_audioSwitchStalled) {
      // Playback continued with the new track: drop the indicator and
      // stop watching.
      _endAudioSwitchWatch();
      return;
    }
    _armAudioSwitchStallTimer();
  }

  void _endAudioSwitchWatch() {
    final wasStalled = _audioSwitchStalled;
    _audioSwitchWatching = false;
    _audioSwitchStalled = false;
    _audioSwitchStallTimer?.cancel();
    _audioSwitchMaxTimer?.cancel();
    _audioSwitchGraceTimer?.cancel();
    _audioSwitchStallTimer = null;
    _audioSwitchMaxTimer = null;
    _audioSwitchGraceTimer = null;
    if (wasStalled) buffering.value = player.state.buffering;
  }

  Future<void> _applyAudioTrackSmoothly(AudioTrack track) async {
    final item = currentItem;

    final isNetworkVideo = item != null &&
        !item.audioOnly &&
        !item.live &&
        item.streamUrl.startsWith('http');

    if (!isNetworkVideo) {
      await _applyNativeAudioTrack(track);
      return;
    }

    _beginAudioSwitchWatch();
    try {
      await _applyNativeAudioTrack(track);
    } catch (_) {
      _endAudioSwitchWatch();
      rethrow;
    }
  }

  /// The actual, non-reopening mpv track switch — used both by
  /// [selectAudioTrack] for the common (Original-quality) case, and by
  /// `_syncTracks`' pending-reapply logic to re-confirm a track that's
  /// already correct after a quality-change reopen, without routing
  /// back through [selectAudioTrack]'s "does this need a reopen?" check
  /// (which is exactly the recursion that check exists to avoid — see
  /// its call site's comment).
  Future<void> _applyNativeAudioTrack(AudioTrack track) async {
    await player.setAudioTrack(
      mk.AudioTrack(track.nativeId, track.displayTitle, track.language),
    );

    selectedAudio.value = track;
  }

  /// Converts WebVTT text to SRT. `SubtitleTrack.data()` has no way to
  /// declare the source format explicitly, and the one path proven to
  /// work reliably (OpenSubtitles downloads) is always SRT — so rather
  /// than hope mpv's own format auto-detection correctly identifies raw
  /// WebVTT handed to it as in-memory data, cues are normalized to SRT
  /// here first. Handles the common case Jellyfin's Stream.vtt endpoint
  /// produces: sequential, non-overlapping cues with plain timestamps
  /// and no regions/karaoke/nested-cue VTT features.
  ///
  /// SIDECAR FIX: now delegates to [SubtitleText.toSrt], which understands
  /// WebVTT, SRT and ASS/SSA. The old WebVTT-only version matched nothing in
  /// real SRT text and returned '' — a downloaded `.srt` sidecar was
  /// "selected" with zero cues, so nothing was ever drawn. Still returns ''
  /// when the text holds no cue; callers fall back to the original text.
  static String _webvttToSrt(String vtt) => SubtitleText.toSrt(vtt);

  /// Switches the active subtitle track, or turns subtitles off when
  /// [track] is null.
  Future<void> selectSubtitleTrack(SubtitleTrack? track) async {
    // DEFAULT SUBTITLE: picking Off is final for this item — see
    // `_subtitleUserOff`. Any real pick clears it again.
    _subtitleUserOff = track == null;
    if (track != null) _autoSubtitleHandled = true;

    // CAST-ONLY SUBTITLES (Open With/Play With video sent straight to an
    // already-connected Google Cast TV — see seedCastOnlySubtitles): mpv
    // never opened this file, so there is nothing for it to load a
    // subtitle into. The pick is only recorded here, and
    // PlaybackCoordinator's selectedSubtitle listener mirrors it to the TV.
    if (castOnlySubtitles) {
      selectedSubtitle.value = track;
      return;
    }

    _stopOwnCues();

    if (track == null) {
      await player.setSubtitleTrack(mk.SubtitleTrack.no());
      selectedSubtitle.value = null;
      return;
    }

    // Raw in-memory content (OpenSubtitles downloads, or an Open
    // With/Play With sidecar — see _reapplyCachedSubtitleIfAny) takes
    // priority over everything else — `SubtitleTrack.data()` hands mpv
    // the text directly, no file I/O or URI involved at all.
    if (track.subtitleData != null) {
      debugPrint('[Subtitles] loading from downloaded data: '
          '${track.displayTitle}');

      // An OpenSubtitles download is always SRT already, but a sidecar
      // file found next to an externally-opened file (ExternalMedia-
      // Handler's `SidecarSubtitles`) can be either a real .srt OR a
      // .vtt — the native side just hands back whatever it read off
      // disk, with nothing tagging which format it
      // is. Handing raw WebVTT to `SubtitleTrack.data()` is exactly the
      // silently-selected-but-zero-cues failure the URL branch below
      // already works around by converting first; `_webvttToSrt` only
      // ever matches dot-decimal VTT-style timestamps, so running it
      // against text that's already SRT (comma-decimal) matches nothing
      // and comes back empty — falling back to the original content in
      // that case is what makes this safe for both formats without
      // needing to sniff which one this is first.
      final converted = _webvttToSrt(track.subtitleData!);
      final srtContent =
          converted.trim().isEmpty ? track.subtitleData! : converted;

      await player.setSubtitleTrack(
        mk.SubtitleTrack.data(
          srtContent,
          title: track.displayTitle,
          language: track.language,
        ),
      );

      _startOwnCues(srtContent);
      selectedSubtitle.value = track;
      return;
    }

    // Downloaded movie/episode subtitle sidecar (see _syncTracks) — a
    // plain file already sitting on this device, so this reads it
    // straight off disk with no network involved at all. Checked before
    // `externalUrl` since a downloaded item's tracks never set that
    // field in the first place (see how `resolvedSubs` builds these in
    // _syncTracks), but keeping this its own explicit branch rather than
    // folding it into the URL one below makes it obvious at a glance
    // that this path is offline-only.
    if (track.localPath != null) {
      debugPrint('[Subtitles] loading from local file: ${track.localPath}');

      try {
        final file = File(track.localPath!);
        // SIDECAR FIX: read as bytes and decode (BOM, UTF-16, legacy code
        // pages) — readAsString() threw on any file that is not strict UTF-8.
        final content = SubtitleText.decode(await file.readAsBytes());

        if (content.trim().isEmpty) {
          throw Exception('Subtitle file is empty');
        }

        // A saved sidecar can be SRT, WebVTT or ASS/SSA; mpv's in-memory
        // track and the app's own cue renderer both want SRT. Falls back to
        // the original text when no cue could be parsed (the old code
        // handed mpv an EMPTY string for real SRT files).
        final converted = _webvttToSrt(content);
        final srtContent = converted.trim().isEmpty ? content : converted;

        await player.setSubtitleTrack(
          mk.SubtitleTrack.data(
            srtContent,
            title: track.displayTitle,
            language: track.language,
          ),
        );

        _startOwnCues(srtContent);
        selectedSubtitle.value = track;
      } catch (error) {
        debugPrint('[Subtitles] failed to load local file: $error');
        rethrow;
      }

      return;
    }

    // Prefer loading whenever MediaStreamParser gave us a URL — for
    // genuinely external sidecar files there's no native mpv track to
    // select in the first place (they never show up in
    // `tracks.subtitle`, see _syncTracks), and for embedded text
    // subtitles the URL points at Jellyfin's own server-side vtt
    // extraction rather than depending on positionally matching mpv's
    // demuxed native track id. That positional match is the fragile
    // part: it silently no-ops the moment it drifts even slightly,
    // which is exactly why the selector could show a track as picked
    // while nothing actually rendered. Native id selection below is
    // now only the fallback for tracks with no URL at all (embedded
    // image-based subtitles like PGS/VobSub, which Jellyfin can't
    // convert to text).
    //
    // IMPORTANT: this is fetched by the app and handed to mpv as raw
    // data (`SubtitleTrack.data()`), NOT loaded by giving mpv the URL
    // directly (`SubtitleTrack.uri()`). Confirmed via diagnostic: mpv
    // opens a direct URL fine (socket connects, track gets added and
    // marked selected/visible) but never actually parses any cues out
    // of it — `sub-text` stayed empty through known dialogue even
    // though the exact same URL downloads a fully valid .vtt with real
    // cues in a browser. Jellyfin's on-the-fly Stream.vtt conversion
    // is served chunked (no fixed Content-Length), and mpv's text
    // subtitle demuxers generally need to read the whole file up front
    // — that combination silently yields zero cues. Fetching it
    // ourselves with Dio and handing mpv the text directly sidesteps
    // that path entirely, the same way OpenSubtitles downloads
    // already do above.
    if (track.externalUrl != null) {
      debugPrint('[Subtitles] fetching by URL: ${track.externalUrl}');

      try {
        final response = await Dio(
          BaseOptions(
            connectTimeout: const Duration(seconds: 10),
            sendTimeout: const Duration(seconds: 10),
            receiveTimeout: const Duration(seconds: 15),
          ),
        ).get<List<int>>(
          track.externalUrl!,
          options: Options(responseType: ResponseType.bytes),
        );

        final bytes = response.data;

        debugPrint(
            '[Subtitles] fetched ${bytes?.length} bytes, status ${response.statusCode}');

        if (bytes == null || bytes.isEmpty) {
          throw Exception('Server returned an empty subtitle file');
        }

        final content = utf8.decode(bytes, allowMalformed: true);

        if (content.trim().isEmpty) {
          throw Exception('Server returned an empty subtitle file');
        }

        // Jellyfin's Stream.vtt endpoint returns real WebVTT (dot
        // decimals, "WEBVTT" header) — but `SubtitleTrack.data()` has
        // no way to declare the format explicitly and evidently
        // assumes SRT: handing it raw WebVTT loaded a selected,
        // visible-but-silent track (confirmed via mpv diagnostics —
        // zero cues ever parsed), while converting to SRT first fixed
        // it outright. OpenSubtitles content works through this same
        // call because it's SRT already.
        final converted = _webvttToSrt(content);
        final srtContent = converted.trim().isEmpty ? content : converted;

        await player.setSubtitleTrack(
          mk.SubtitleTrack.data(
            srtContent,
            title: track.displayTitle,
            language: track.language,
          ),
        );

        selectedSubtitle.value = track;
      } catch (error) {
        debugPrint('[Subtitles] failed to fetch by URL: $error');
        rethrow;
      }

      return;
    }

    debugPrint('[Subtitles] loading by native id: ${track.nativeId}');

    await player.setSubtitleTrack(
      mk.SubtitleTrack(track.nativeId, track.displayTitle, track.language),
    );

    selectedSubtitle.value = track;
  }

  bool? _nativeSubsVisible;

  /// Whether mpv itself paints subtitles onto the picture (see the
  /// SUBTITLE STYLE FIX note in `initialize`). Best-effort.
  Future<void> _setNativeSubtitleVisible(bool visible) async {
    if (_nativeSubsVisible == visible) return;
    final platform = player.platform;
    if (platform is! NativePlayer) return;
    _nativeSubsVisible = visible;
    try {
      await platform.setProperty('sub-visibility', visible ? 'yes' : 'no');
    } catch (_) {
      _nativeSubsVisible = null;
    }
  }

  bool? _nativeSubtitleBold;

  /// Forces mpv/libass's own subtitle renderer to the app's bold setting.
  /// `sub-ass-style-overrides` (called `sub-ass-force-style` before mpv
  /// 0.37) overrides the Bold field of every style in the subtitle, so an
  /// .ass/.ssa file can't make itself bold; inline `{\b1}` emphasis in
  /// the text is untouched. `sub-bold` covers SRT/VTT, which mpv converts
  /// to ASS using that option. Each property is set independently and
  /// best-effort: one this libmpv build doesn't know must never block the
  /// other, or affect playback.
  Future<void> _applyNativeSubtitleBold(bool bold) async {
    if (_nativeSubtitleBold == bold) return;
    final platform = player.platform;
    if (platform is! NativePlayer) return;
    _nativeSubtitleBold = bold;

    final flag = bold ? '1' : '0';
    for (final entry in <MapEntry<String, String>>[
      MapEntry('sub-ass-style-overrides', 'Bold=$flag'),
      MapEntry('sub-ass-force-style', 'Bold=$flag'),
      MapEntry('sub-bold', bold ? 'yes' : 'no'),
    ]) {
      try {
        await platform.setProperty(entry.key, entry.value);
      } catch (_) {
        // Unknown on this libmpv build — the others still apply.
      }
    }
  }

  /// Shifts when subtitles appear relative to audio/video. Positive
  /// values delay the subtitle (make it appear later); negative values
  /// bring it forward — the same convention every other player's
  /// subtitle-delay control uses. Backed by mpv's own `sub-delay`
  /// property since media_kit's Player API doesn't expose one directly.
  Future<void> setSubtitleDelay(Duration delay) async {
    subtitleDelay.value = delay;

    final platform = player.platform;
    if (platform is NativePlayer) {
      await platform.setProperty(
        'sub-delay',
        (delay.inMilliseconds / 1000).toStringAsFixed(3),
      );
    }
  }

  /// Nudges the current delay by [step] (positive or negative) — what
  /// the +/- buttons in the subtitle sheet actually call.
  Future<void> adjustSubtitleDelay(Duration step) {
    return setSubtitleDelay(subtitleDelay.value + step);
  }

  // Distinct, always-negative indices for OpenSubtitles downloads —
  // real Jellyfin stream indices are never negative, so these can never
  // collide with an actual embedded/external track. Decrementing per
  // download (rather than reusing one constant) keeps each one distinct
  // too, since SubtitleTrack's equality is index-based.
  int _nextDownloadedSubtitleIndex = -1;

  /// True while the subtitle list/selection below belongs to an Open
  /// With/Play With video that was sent STRAIGHT to an already-connected
  /// Google Cast TV, i.e. local mpv never opened it (see
  /// PlaybackCoordinator.prepareExternalVideoForActiveCast). While set,
  /// [selectSubtitleTrack] only records the pick instead of asking mpv to
  /// load it. Cleared by PlaybackCoordinator when that cast ends and by
  /// [playMedia] the moment anything is actually opened locally.
  bool castOnlySubtitles = false;

  /// Replaces the subtitle list with [entries] (raw subtitle text found
  /// next to an Open With/Play With file, or a remembered OpenSubtitles
  /// pick) WITHOUT touching mpv, and selects the first one — exactly what
  /// [_reapplyCachedSubtitleIfAny] would have done had the file been
  /// opened locally. Audio tracks are cleared too: they describe
  /// whatever mpv last had open, never this file.
  void seedCastOnlySubtitles(
    List<({String content, String displayTitle, String language})> entries,
  ) {
    _nextDownloadedSubtitleIndex = -1;

    final tracks = <SubtitleTrack>[];
    for (final entry in entries) {
      final index = _nextDownloadedSubtitleIndex--;
      tracks.add(
        SubtitleTrack(
          index: index,
          language: entry.language,
          displayTitle: entry.displayTitle,
          isDefault: false,
          isForced: false,
          nativeId: 'downloaded-$index',
          isExternal: true,
          subtitleData: entry.content,
        ),
      );
    }

    audioTracks.value = const [];
    selectedAudio.value = null;
    subtitleDelay.value = Duration.zero;
    subtitles.value = tracks;
    _subtitleUserOff = false;
    _autoSubtitleHandled = true;
    selectedSubtitle.value = tracks.isEmpty ? null : tracks.first;
  }

  /// Selects subtitle [content] fetched from OpenSubtitles directly —
  /// via mpv's `SubtitleTrack.data()`, the same in-memory path
  /// [selectSubtitleTrack] now uses for any downloaded track. No temp
  /// file, no path/URI for mpv to resolve on its own, nothing that can
  /// silently fail before the text ever reaches the renderer.
  Future<void> loadDownloadedSubtitle({
    required String content,
    required String displayTitle,
    required String language,
  }) async {
    final index = _nextDownloadedSubtitleIndex--;

    final track = SubtitleTrack(
      index: index,
      language: language,
      displayTitle: displayTitle,
      isDefault: false,
      isForced: false,
      nativeId: 'downloaded-$index',
      isExternal: true,
      subtitleData: content,
    );

    subtitles.value = [...subtitles.value, track];

    await selectSubtitleTrack(track);
  }

  /// Adds a subtitle to the selectable list without also selecting it —
  /// the non-selecting counterpart to [loadDownloadedSubtitle] just
  /// above, used by [_reapplyCachedSubtitleIfAny] when a folder next to
  /// an externally-opened video has more than one subtitle file: the
  /// first one found is auto-applied via [loadDownloadedSubtitle], and
  /// every one after that lands here instead, so it still shows up in
  /// the subtitle sheet for the person to switch to, without silently
  /// switching mpv away from whatever the first one already picked.
  /// Shares [_nextDownloadedSubtitleIndex] with [loadDownloadedSubtitle]
  /// so every one of these gets its own distinct always-negative index —
  /// the same thing that keeps `_syncTracks`' `downloadedSubs` re-append
  /// logic treating them all as still-live across any later track
  /// re-sync.
  void _appendSidecarSubtitleTrack({
    required String content,
    required String displayTitle,
  }) {
    final index = _nextDownloadedSubtitleIndex--;

    subtitles.value = [
      ...subtitles.value,
      SubtitleTrack(
        index: index,
        language: '',
        displayTitle: displayTitle,
        isDefault: false,
        isForced: false,
        nativeId: 'downloaded-$index',
        isExternal: true,
        subtitleData: content,
      ),
    ];
  }

  /// Open With / Play With: subtitle files found in the video's folder
  /// AFTER playback already started (the scan no longer delays playback).
  /// Skips ones already listed; selects the first only when nothing is
  /// selected yet, otherwise just makes them pickable.
  Future<void> applyLateSidecarSubtitles(
    MediaItem item,
    List<Map<String, String>> subs,
  ) async {
    if (subs.isEmpty || item.audioOnly || item.live) return;
    if (currentItem?.id != item.id) return;

    final known = subtitles.value.map((t) => t.displayTitle).toSet();
    final fresh = [
      for (final s in subs)
        if (!known.contains(s['fileName'] ?? 'Subtitle')) s,
    ];
    if (fresh.isEmpty) return;

    var rest = fresh;
    // Never switch subtitles on behind the back of someone who turned them
    // off: then the files are only made pickable.
    if (selectedSubtitle.value == null && !_subtitleUserOff) {
      final first = fresh.first;
      rest = fresh.sublist(1);
      for (final entry in rest) {
        _appendSidecarSubtitleTrack(
          content: entry['content'] ?? '',
          displayTitle: entry['fileName'] ?? 'Subtitle',
        );
      }
      if (currentItem?.id != item.id) return;
      await loadDownloadedSubtitle(
        content: first['content'] ?? '',
        displayTitle: first['fileName'] ?? 'Subtitle',
        language: '',
      );
      return;
    }

    for (final entry in rest) {
      _appendSidecarSubtitleTrack(
        content: entry['content'] ?? '',
        displayTitle: entry['fileName'] ?? 'Subtitle',
      );
    }
  }

  /// NAMESIS PRIME: resolves once [item] is REALLY playing, i.e. a picture
  /// exists AND the playback position is genuinely moving.
  ///
  /// Why this exists: for a network stream (addon link, torrent) mpv reports
  /// a video size / `playing == true` / even `buffering == false` well before
  /// it is actually rolling. It decodes the first frame, then sits on it at
  /// 00:00 while the demuxer cache fills. Taking the loading screen down on
  /// those earlier signals (or on a fixed timer) is what showed a frozen
  /// 00:00 for a long moment before playback began. The loading screen now
  /// stays up until the position has advanced a little on its own.
  ///
  /// Always bounded, so it can never keep the loading screen up forever:
  ///  - [frameTimeout]: how long to wait for the first picture;
  ///  - [progressTimeout]: how long to wait, once a picture exists, for the
  ///    position to start moving.
  /// Returns early (without the "rolling" proof) when the item changed, the
  /// loading flag was cleared by someone else, or playback was paused (a
  /// paused player has nothing to wait for).
  Future<void> _waitForRealPlayback(
    MediaItem item, {
    required Duration frameTimeout,
    required Duration progressTimeout,
  }) async {
    const poll = Duration(milliseconds: 100);
    // How far the position must advance, beyond where it was when it first
    // looked healthy, to count as "playing".
    const needed = Duration(milliseconds: 250);
    // A single poll that jumps further than this is a seek (resume), not
    // playback.
    const seekJump = Duration(seconds: 2);

    final started = DateTime.now();
    final frameDeadline = started.add(frameTimeout);
    DateTime? progressDeadline;

    // A resumed title is opened at 0:00 and then seeked to the saved point.
    // Progress made before that seek lands says nothing about the real
    // start, so it is ignored until the position gets near the resume point
    // (or a grace period passes, in case the seek never happens).
    final resumeAt = item.playbackPosition ?? Duration.zero;
    final expectSeek =
        resumeAt > const Duration(seconds: 5) && _streamPositionOffset == Duration.zero;
    final seekGraceEnd = started.add(const Duration(seconds: 20));

    Duration? baseline;
    Duration? last;

    while (true) {
      if (currentItemNotifier.value?.id != item.id) return;
      if (!loading.value) return;

      final s = player.state;
      if (!s.playing) return;

      final now = DateTime.now();
      final pos = s.position;
      final hasPicture = (s.width ?? 0) > 0;

      if (hasPicture) {
        progressDeadline ??= now.add(progressTimeout);
      }

      final waitingForSeek = expectSeek &&
          now.isBefore(seekGraceEnd) &&
          pos < resumeAt - const Duration(seconds: 3);

      if (!hasPicture || s.buffering || waitingForSeek) {
        // Not rolling yet: measure again from wherever it is once it is.
        baseline = null;
      } else if (baseline == null) {
        baseline = pos;
      } else {
        final step = pos - (last ?? pos);
        if (step < Duration.zero || step > seekJump) {
          // A seek (or a new file replacing the old one): start measuring
          // again from the new position.
          baseline = pos;
        } else if (pos - baseline >= needed) {
          return; // The picture is genuinely moving.
        }
      }
      last = pos;

      if (now.isAfter(progressDeadline ?? frameDeadline)) return;
      await Future<void>.delayed(poll);
    }
  }

  /// Prefers Jellyfin's own metadata for the item's real duration over
  /// mpv's own `player.state.duration` (see the function body for why —
  /// short version: a capped-quality `.ts` transcode may never report
  /// one at all, and a `.ts` container's own duration isn't trustworthy
  /// even when it does). Still briefly polls mpv's value as a warmup
  /// before a subsequent seek(), up to a few seconds, but the returned
  /// value and [duration] no longer depend on that poll succeeding.
  Future<Duration> _waitForDuration(MediaItem item) async {
    // Jellyfin's own metadata is the authoritative source for a title's
    // real length, and — critically — the ONLY reliable one for a
    // capped-quality `.ts` progressive transcode (any constrained
    // quality — see getVideoStreamUrl's doc comment): MPEG-TS containers
    // don't carry a duration header the way MP4/MKV do, so mpv has to
    // estimate it from PTS timestamps, and for a stream Jellyfin is
    // encoding live as it's requested, that estimate can simply never
    // arrive. This used to always wait on mpv's own duration becoming
    // known before returning anything at all — for a `.ts` stream that
    // meant blocking every constrained-quality playback start (or
    // resume) for the full poll window below, for a value that was
    // going to be wrong even if it did eventually show up (see
    // _streamPositionOffset's doc comment). Known runtime now always
    // takes priority and can return immediately; the poll below still
    // runs afterward, but purely as a best-effort warmup before the
    // subsequent seek() call succeeds reliably — the same reasoning
    // that originally motivated it still applies for Original quality's
    // `static=true` MP4/MKV files, which normally do resolve mpv's own
    // duration quickly.
    final knownRuntime = item.runtime > Duration.zero ? item.runtime : null;

    var ready = player.state.duration;

    if (ready <= Duration.zero) {
      // Shorter than before (this used to be a full, unconditional 10s)
      // — now just a courtesy warmup rather than something the return
      // value depends on, so there's no reason to hold a reopen/resume
      // up any longer than a couple of genuinely slow-to-parse files
      // might need.
      final deadline = DateTime.now().add(const Duration(seconds: 3));

      while (ready <= Duration.zero &&
          DateTime.now().isBefore(deadline)) {
        await Future.delayed(const Duration(milliseconds: 100));

        // The item may have changed (or playback stopped) while we were
        // polling — bail out rather than reporting a stale item's duration.
        if (currentItem?.id != item.id) return knownRuntime ?? Duration.zero;

        ready = player.state.duration;
      }
    }

    if (currentItem?.id != item.id) {
      return knownRuntime ?? Duration.zero;
    }

    final trustPlayer =
        item.raw?['AddonStream'] == true && ready > Duration.zero;
    final real = (trustPlayer && _streamPositionOffset == Duration.zero
            ? ready
            : null) ??
        knownRuntime ??
        (ready > Duration.zero
            ? (_streamPositionOffset == Duration.zero
                ? ready
                : _streamPositionOffset + ready)
            : Duration.zero);

    if (real > Duration.zero) {
      if (_streamPositionOffset == Duration.zero) {
        _originalDuration = real;
      } else {
        _originalDuration ??= real;
      }
      duration.value = _originalDuration!;
    }

    return real;
  }

  //--------------------------------------------------
  // VIDEO / AUDIO QUALITY
  //--------------------------------------------------
  //
  // See MediaService.getVideoStreamUrl and getAudioStreamUrl for the
  // actual Jellyfin capabilities this drives (capped-resolution
  // transcoding for video, MaxStreamingBitrate for audio) and
  // AppSettings.PlaybackQualityMode for the three Data Usage modes.

  /// True for anything that isn't actually a Jellyfin network stream:
  /// local library tracks, files opened via Open With/Play With
  /// (`item.isLocal`), and downloaded items — which keep a real Jellyfin
  /// id but have `streamUrl` pointed at the on-disk file by
  /// DownloadManager.mediaItemFor. None of the quality machinery below
  /// applies to any of these; they always just play the file they
  /// already point at.
  bool _isOfflineFile(MediaItem item) =>
      item.isLocal || !item.streamUrl.startsWith("http");

  /// True only for a file opened via Open With/Play With (see
  /// ExternalMediaHandler's `IsExternalFile` raw marker) — narrower than
  /// [_isOfflineFile], which also matches on-device library songs and
  /// downloads. Those two still exit normally on natural completion
  /// (queue advance / mini player teardown); only an externally-opened
  /// file gets the "stay put, let Play restart it" treatment in
  /// [_finishExternalFilePlayback].
  bool _isExternalFile(MediaItem? item) => item?.raw?['IsExternalFile'] == true;

  /// Strips both the directory and the extension off a file path/URI,
  /// e.g. `/storage/.../Movie (2024).mp4` -> `Movie (2024)`. Used purely
  /// to line a downloaded subtitle sidecar's file name back up against
  /// its video's own file name (see the downloaded-subtitles branch in
  /// `_syncTracks`) — mirrors the same manual string-splitting
  /// `ExternalMediaHandler`/`LocalMusicService` already use for the same
  /// kind of filename parsing, rather than pulling in `package:path` for
  /// one small helper.
  String _fileBaseNameNoExt(String path) {
    final slash = path.lastIndexOf(RegExp(r'[\\/]'));
    final name = slash >= 0 ? path.substring(slash + 1) : path;
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  /// An Open With/Play With item (no queue, nothing to advance to, no
  /// library screen underneath this session to fall back into) reached
  /// its natural end. Unlike the ordinary "queue exhausted" paths this
  /// replaces — which pop the player screen and tear the mini player
  /// down via `stop()`/`playbackFinished` — this deliberately leaves
  /// `currentItemNotifier`, the mini player, and whichever player/lyrics
  /// screen is open exactly as they are: dismissing back to whatever
  /// screen happened to be open before Android handed this file over
  /// would be jarring for something the person explicitly chose to
  /// open. Playback just pauses on a clean 0:00 rather than sitting at
  /// the very end with nothing left to do — that's what makes tapping
  /// Play afterward read as *restarting* this same file rather than
  /// resuming a track that has nowhere further to go.
  Future<void> _finishExternalFilePlayback() async {
    await player.pause();
    await player.seek(Duration.zero);
    position.value = Duration.zero;
  }

  /// The video-stream height reported for this item's first (default)
  /// media source, if Jellyfin's given us that far. Null both while
  /// metadata is still loading (see `_augmentWithPlaybackFields`) and
  /// for Live TV, where a channel isn't really "a file with a fixed
  /// resolution" the same way — either way, null is treated as "don't
  /// clamp the ladder, show/allow everything" everywhere below.
  int? _sourceMaxHeight(MediaItem item) {
    final sources = item.mediaSources;
    if (sources == null || sources.isEmpty) return null;

    final streams = sources.first["MediaStreams"];
    if (streams is! List) return null;

    for (final s in streams) {
      if (s is Map && s["Type"] == "Video") {
        final h = s["Height"];
        if (h is int) return h;
        if (h is num) return h.toInt();
      }
    }

    return null;
  }

  /// Recomputes [videoQualityOptions] for whatever's playing right now.
  /// Runs on every `currentItemNotifier` change — including the
  /// metadata-augmentation update that lands after `playMedia()` already
  /// opened the stream — so the selector starts out showing the full
  /// ladder and narrows to the source's real resolution the moment that
  /// becomes known, rather than waiting on it up front and blocking the
  /// selector from being useful at all in the meantime.
  void _recomputeVideoQualityOptions() {
    final item = currentItem;

    if (item == null || item.audioOnly) {
      videoQualityOptions.value = const [];
      return;
    }

    final maxHeight = _sourceMaxHeight(item);

    videoQualityOptions.value = [
      "Auto",
      for (final level in kVideoQualityLadder)
        if (maxHeight == null || level.height <= maxHeight) level.label,
    ];

    debugPrint(
      "QUALITY OPTIONS recomputed for \"${item.title}\": "
      "sourceMaxHeight=$maxHeight -> ${videoQualityOptions.value}",
    );
  }

  /// What "Auto" currently means for video, given the active
  /// PlaybackQualityMode and (for Default mode) live network conditions.
  /// Null means Original/unconstrained — the plain direct-play stream.
  /// Never returns a rung above the source's own resolution — Jellyfin
  /// would just clamp an upscale request anyway, so there's no reason to
  /// even ask for one.
  VideoQualityLevel? _autoVideoTarget(MediaItem item) {
    final maxHeight = _sourceMaxHeight(item);

    VideoQualityLevel? clampToSource(VideoQualityLevel level) {
      if (maxHeight == null || level.height <= maxHeight) return level;

      final fitting =
          kVideoQualityLadder.where((l) => l.height <= maxHeight).toList();

      return fitting.isEmpty ? null : fitting.last;
    }

    switch (AppSettings.playbackQualityMode.value) {
      case PlaybackQualityMode.dataSaver:
        // The ladder's second-lowest rung, e.g. 480p out of
        // [360, 480, 720, 1080] — per spec, regardless of the network.
        return clampToSource(kVideoQualityLadder[1]);

      case PlaybackQualityMode.maxQuality:
        // No constraint at all — Original, exactly this app's
        // pre-existing default behavior.
        return null;

      case PlaybackQualityMode.standard:
        switch (NetworkQualityService.instance.tier.value) {
          case NetworkTier.excellent:
            return null; // Original — best possible.
          case NetworkTier.good:
            return clampToSource(kVideoQualityLadder[3]); // 1080p
          case NetworkTier.fair:
            return clampToSource(kVideoQualityLadder[2]); // 720p
          case NetworkTier.poor:
            return clampToSource(kVideoQualityLadder[1]); // 480p
        }
    }
  }

  /// The audio equivalent of [_autoVideoTarget]. Unlike video, where
  /// "Original" only ever comes up for network-adaptive Auto,
  /// unconstrained matters here for *any* mode whenever the source is
  /// lossless — `MediaService.getAudioStreamUrl` already lists `flac`
  /// among the direct-playable containers, so an untouched FLAC library
  /// streams at its real (often 1000+ kbps) bitrate today. Returning a
  /// fixed 320kbps ladder rung for Max Quality would force every one of
  /// those files through a lossy transcode — a real downgrade from doing
  /// nothing at all — so null ("no MaxStreamingBitrate param, don't
  /// touch the source") has to be a first-class result here too, exactly
  /// like video's Original.
  int? _modeAudioTarget() {
    switch (AppSettings.playbackQualityMode.value) {
      case PlaybackQualityMode.dataSaver:
        // Fixed second-lowest tier, per spec — regardless of source or
        // network. This one genuinely does mean "transcode it down."
        return kAudioQualityLadder[1].bitrateKbps;

      case PlaybackQualityMode.maxQuality:
        return null; // Original — a lossless source stays lossless.

      case PlaybackQualityMode.standard:
        // Nothing has measured the network yet, so the tier is only its
        // `good` placeholder — don't open the song as a 320kbps
        // transcode on the strength of a guess. Leave it untouched; the
        // first real reading (see NetworkQualityService.measured)
        // re-runs this and adapts if the network actually needs it.
        if (!NetworkQualityService.instance.measured.value) return null;

        switch (NetworkQualityService.instance.tier.value) {
          case NetworkTier.excellent:
            return null; // Strong enough to not need to touch anything.
          case NetworkTier.good:
            return kAudioQualityLadder[3].bitrateKbps; // 320
          case NetworkTier.fair:
            return kAudioQualityLadder[2].bitrateKbps; // 192
          case NetworkTier.poor:
            return kAudioQualityLadder[0].bitrateKbps; // 64
        }
    }
  }

  /// The cap actually worth applying to [item]: whatever the quality
  /// mode asks for ([_modeAudioTarget]), except that a song already at
  /// or below that cap is left alone (null = direct-play the original).
  /// Capping a 128kbps MP3 "to 320" or "to 128" can only ever mean a
  /// pointless re-encode — and a transcode is the one path that has been
  /// dropping songs mid-play, so it shouldn't be taken without a reason.
  /// Unknown source bitrate means no clamp, i.e. the previous behavior.
  int? _autoAudioTarget([MediaItem? item]) {
    final target = _modeAudioTarget();
    if (target == null || item == null) return target;

    final sourceKbps = _audioSourceKbps(item);
    if (sourceKbps != null && sourceKbps <= target) return null;

    return target;
  }

  /// The song's real source bitrate in kbps, from Jellyfin's own
  /// MediaSources/MediaStreams data, or null when it isn't known.
  int? _audioSourceKbps(MediaItem item) {
    int? fromBps(Object? value) =>
        (value is num && value > 0) ? (value / 1000).round() : null;

    final sources = item.mediaSources;
    if (sources != null && sources.isNotEmpty && sources.first is Map) {
      final kbps = fromBps((sources.first as Map)["Bitrate"]);
      if (kbps != null) return kbps;
    }

    final streams = item.mediaStreams;
    if (streams != null) {
      for (final stream in streams) {
        if (stream is Map && stream["Type"] == "Audio") {
          final kbps = fromBps(stream["BitRate"]);
          if (kbps != null) return kbps;
        }
      }
    }

    return null;
  }

  String _resolveVideoUrl(
    MediaItem item,
    VideoQualityLevel? target, {
    int? audioStreamIndex,
    Duration? startAt,
  }) {
    final mediaSourceId =
        (item.mediaSources != null && item.mediaSources!.isNotEmpty)
            ? item.mediaSources!.first["Id"] as String?
            : null;

    // .NET ticks (100ns units, 10,000,000 per second) — see
    // getVideoStreamUrl's doc comment for why this matters specifically
    // for the transcoded branch.
    final startTicks =
        (startAt != null && startAt > Duration.zero && target != null)
            ? startAt.inMicroseconds * 10
            : null;

    if (item.live) {
      return target == null
          ? MediaService.getLiveTvStreamUrl(item.id)
          : MediaService.getVideoStreamUrl(
              item.id,
              maxHeight: target.height,
              videoBitrateKbps: target.videoBitrateKbps,
              audioStreamIndex: audioStreamIndex,
            );
    }

    return target == null
        ? MediaService.getPlaybackUrl(item.id)
        : MediaService.getVideoStreamUrl(
            item.id,
            mediaSourceId: mediaSourceId,
            maxHeight: target.height,
            videoBitrateKbps: target.videoBitrateKbps,
            audioStreamIndex: audioStreamIndex,
            startTimeTicks: startTicks,
          );
  }

  /// The audio counterpart to [_resolveVideoUrl]. [startAt] is only ever
  /// applied to a capped (i.e. actually transcoded) stream, for the same
  /// reason the video branch bakes `StartTimeTicks` in rather than
  /// seeking afterward — see `MediaService.getAudioStreamUrl`'s doc
  /// comment for what the client-side seek was doing to mid-song quality
  /// changes.
  String _resolveAudioUrl(
    MediaItem item,
    int? maxBitrateKbps, {
    Duration? startAt,
  }) {
    final startTicks =
        (startAt != null && startAt > Duration.zero && maxBitrateKbps != null)
            ? startAt.inMicroseconds * 10
            : null;

    // A capped song is a live server transcode. It is requested as a plain
    // progressive MP3 (`stream.mp3`) — the same request song downloads at a
    // chosen bitrate already use, and the simplest thing Jellyfin's
    // transcoder produces — rather than `/Audio/{id}/universal`'s
    // negotiated AAC stream, which is what Data Saver / Default songs used
    // to open and which kept being dropped by the server partway through.
    // The universal URL is still used for the uncapped (direct-play)
    // original, unchanged, and as a recovery fallback.
    if (maxBitrateKbps != null) {
      return MediaService.getAudioMp3TranscodeUrl(
        item.id,
        maxBitrateKbps: maxBitrateKbps,
        startTimeTicks: startTicks,
        playSessionId: _musicPlaySessionId,
      );
    }

    return MediaService.getAudioStreamUrl(item.id);
  }

  /// Reopens the player at [newUrl] while preserving everything about
  /// the session that isn't tied to the specific bytes being streamed:
  /// playback position, play/pause state, and playback speed — so
  /// switching quality (manual or automatic) never means "start the
  /// title over from 0:00" the way a fresh `playMedia()` call would.
  ///
  /// [newStreamOffset] becomes [_streamPositionOffset] once [newUrl] is
  /// actually open — pass `Duration.zero` for Original/an unconstrained
  /// stream (position 0 really is position 0), or the absolute position
  /// [newUrl] was built to start from for a capped-quality transcode
  /// (its position 0 is really that offset — see
  /// `_streamPositionOffset`'s doc comment for why this matters: getting
  /// it wrong is what made switching audio tracks appear to restart the
  /// title from the beginning, and made the seek bar's total duration
  /// jump around like Live TV's).
  ///
  /// [seekAfterOpen] should be false whenever [newUrl] already encodes
  /// the resume position server-side (a transcoded video URL built with
  /// `StartTimeTicks` — see `getVideoStreamUrl`'s doc comment and
  /// `_applyVideoLevel`). Seeking into a live transcode via an HTTP
  /// Range request after opening it isn't reliably supported and is
  /// what caused quality switches to hang indefinitely on "loading"
  /// instead of ever completing — since `loading` is shared, singleton
  /// state, that hang didn't just affect the one video, it looked like
  /// the whole player (including a completely separate later music
  /// session) was stuck, because nothing ever ran the `finally` below
  /// to clear it. `player.open()` is also now wrapped in a hard
  /// [_qualitySwitchTimeout] for exactly that reason: whatever the
  /// cause, this method must never be able to hang forever again.
  ///
  /// [forceSelectedAudio] lets a caller pin exactly which track should
  /// end up selected once the new file's tracks exist (used by
  /// `selectAudioTrack` when the reopen itself IS the track change);
  /// otherwise whatever's currently selected is simply re-applied as-is
  /// so a plain quality change doesn't silently reset the track/subtitle
  /// choice. See `_syncTracks` for where these actually get consumed.
  ///
  /// Deliberately does NOT touch PlaybackProgressService (still the same
  /// item/session — no new "started playing" report needed), skip
  /// segments, trickplay, or the episode/channel queue — none of that
  /// depends on which bitrate/resolution is being demuxed.
  static const _qualitySwitchTimeout = Duration(seconds: 15);

  Future<void> _reopenStreamPreservingState(
    String newUrl, {
    AudioTrack? forceSelectedAudio,
    bool seekAfterOpen = true,
    Duration newStreamOffset = Duration.zero,
    // Where the item should end up. Defaults to wherever playback is now
    // (quality / audio-track changes); a seek passes its target.
    Duration? resumePosition,
    String? failureMessage,
  }) async {
    final item = currentItem;
    if (item == null) {
      debugPrint("REOPEN STREAM: aborted, currentItem is null");
      return;
    }

    debugPrint(
      "REOPEN STREAM: opening $newUrl "
      "(seekAfterOpen=$seekAfterOpen, newStreamOffset=$newStreamOffset)",
    );

    final token = ++_playbackToken;

    // The item's REAL position, correcting for whatever offset the
    // CURRENTLY-open stream already has — not raw player.state.position.
    // If we're already mid-transcode (switching from one capped quality/
    // track to another), the raw mpv position only describes time within
    // that segment; see _absolutePosition.
    final resumeAt = resumePosition ?? _absolutePosition;
    final wasPlaying = playing.value;
    final speed = playbackSpeed.value;

    // Remember what was actually running before this attempt, so a
    // failure/timeout below has something concrete to fall back to
    // rather than leaving the player wedged on a broken URL.
    final previousVideoLevel = _activeVideoLevel;
    final previousAudioBitrateKbps = _activeAudioBitrateKbps;
    final previousAudioStreamIndex = _activeAudioStreamIndex;
    final previousManualOverride = _manualVideoOverride;
    final previousVideoQualityLabel = videoQuality.value;
    final previousStreamOffset = _streamPositionOffset;

    _pendingAudioReapply = forceSelectedAudio ?? selectedAudio.value;
    _pendingSubtitleReapply = selectedSubtitle.value;

    if (!item.audioOnly) PlaybackLoadProgress.instance.opening();
    loading.value = true;

    try {
      await _prepareClosedCaptionOption(item);
      await player
          .open(Media(newUrl), play: false)
          .timeout(_qualitySwitchTimeout);
      debugPrint("REOPEN STREAM: player.open() completed");
      if (token != _playbackToken) {
        debugPrint("REOPEN STREAM: stale token after open, bailing");
        return;
      }

      if (!item.audioOnly) PlaybackLoadProgress.instance.opened();

      // Set as soon as the new stream is actually open, before anything
      // below reads position again — every position/duration listener
      // and any nested reopen this one might trigger (_syncTracks'
      // pending-reapply, in particular) needs this to already be
      // correct.
      _streamPositionOffset = newStreamOffset;

      if (seekAfterOpen && !item.live && resumeAt > Duration.zero) {
        debugPrint("REOPEN STREAM: waiting for duration before seeking...");
        await _waitForDuration(item);
        if (token != _playbackToken) return;

        debugPrint("REOPEN STREAM: seeking to $resumeAt");
        // Bounded for the same reason `player.open()` above is. A seek
        // into a server-side live transcode can never complete, and
        // until this was bounded, that hang held `loading` true forever
        // — which is singleton state, so it wasn't just this title that
        // looked stuck, it was the player itself for the rest of the
        // app's life. Every caller that opens a transcode now passes
        // `seekAfterOpen: false` and lets the server start at the right
        // position instead, so reaching this at all already means we're
        // on a seekable stream; the timeout is the backstop for when
        // that reasoning turns out to be wrong about some file.
        await player.seek(resumeAt).timeout(_qualitySwitchTimeout);
        if (token != _playbackToken) return;
      }

      if (speed != 1.0) {
        await player.setRate(speed);
        if (token != _playbackToken) return;
      }

      if (wasPlaying && !_castBlocksLocalAudio) {
        await player.play();
      }

      // Live has no absolute timeline to restore a position on — the
      // new tuner stream starts at its own live edge, and writing the
      // old channel position here just made the elapsed counter jump
      // backwards for a beat before the position stream corrected it.
      if (!item.live) {
        position.value = resumeAt;
      }
      debugPrint("REOPEN STREAM: success");
    } catch (error) {
      debugPrint("QUALITY SWITCH ERROR: $error");
      if (token != _playbackToken) return;


      lastError.value =
          failureMessage ?? "Couldn't switch quality — reverting.";

      // The attempted URL is the one thing known to be broken/unusable
      // right now — falling back to whatever was actually working
      // before (usually Original, a plain static file that's never
      // gone through this failure mode) recovers real playback instead
      // of leaving the person staring at a dead player. Guarded by
      // `_activeVideoLevel`/`_activeAudioBitrateKbps` already having
      // been reset to the pre-attempt values below, and by not
      // recursing back through this same fallback path a second time.
      _activeVideoLevel = previousVideoLevel;
      _activeAudioBitrateKbps = previousAudioBitrateKbps;
      _activeAudioStreamIndex = previousAudioStreamIndex;
      _streamPositionOffset = previousStreamOffset;

      // Restore the override/label state exactly as it was — NOT
      // derived from previousVideoLevel, since a non-null level can
      // just as easily have come from Default mode's own Auto
      // resolution as from an actual manual pick. Conflating the two
      // here would wrongly turn an Auto-resolved quality into a
      // "manual" one after a failed switch, silently freezing out
      // further automatic adjustment until Auto was explicitly
      // reselected.
      if (!item.audioOnly) {
        _manualVideoOverride = previousManualOverride;
        videoQuality.value = previousVideoQualityLabel;
      }

      final fallbackUrl = item.audioOnly
          ? _resolveAudioUrl(
              item,
              previousAudioBitrateKbps,
              // Same reasoning as the video fallback below: a capped
              // fallback carries its position server-side, or it can
              // hang on the post-open seek exactly like the attempt it
              // is recovering from just did.
              startAt: resumeAt,
            )
          : _resolveVideoUrl(
              item,
              previousVideoLevel,
              audioStreamIndex: previousAudioStreamIndex,
              // Same reasoning as the primary attempt above: if we're
              // falling back to a constrained quality (not necessarily
              // all the way to Original), it needs StartTimeTicks too,
              // not a client-side seek — otherwise the fallback could
              // hang the exact same way the thing it's recovering from
              // just did.
              startAt: resumeAt,
            );

      // Only an unconstrained fallback needs (and safely supports) a
      // post-open seek; a constrained one — capped audio bitrate or
      // capped video resolution alike — already has its position baked
      // in via StartTimeTicks above.
      final fallbackNeedsSeek = item.audioOnly
          ? previousAudioBitrateKbps == null
          : previousVideoLevel == null;

      try {
        await _prepareClosedCaptionOption(item);
        await player
            .open(Media(fallbackUrl), play: false)
            .timeout(_qualitySwitchTimeout);
        if (token != _playbackToken) return;

        // Same as the primary attempt: an unconstrained fallback has no
        // offset (it'll seek directly below); a constrained fallback's
        // position 0 is really `resumeAt`, via the StartTimeTicks baked
        // into fallbackUrl above. Live never carries an offset at all —
        // there is no absolute timeline for one to be an offset into.
        _streamPositionOffset =
            (fallbackNeedsSeek || item.live) ? Duration.zero : resumeAt;

        if (fallbackNeedsSeek && !item.live && resumeAt > Duration.zero) {
          await _waitForDuration(item);
          if (token != _playbackToken) return;
          await player.seek(resumeAt).timeout(_qualitySwitchTimeout);
          if (token != _playbackToken) return;
        }

        if (wasPlaying && !_castBlocksLocalAudio) {
          await player.play();
        }

        if (!item.live) {
          position.value = resumeAt;
        }
      } catch (fallbackError) {
        // Both the requested quality AND the fallback failed (e.g. the
        // connection itself just dropped) — nothing more to recover
        // here client-side; the person sees the error above and can
        // retry once things are back. Offset already restored to
        // whatever was actually running before this whole attempt
        // (set above, right after the primary failure).
        debugPrint("QUALITY SWITCH FALLBACK ALSO FAILED: $fallbackError");
      }
    } finally {
      if (token == _playbackToken) {
        loading.value = false;
      }
    }
  }

  /// Applies a video-quality target, skipping the reopen entirely when
  /// it's the same constraint (or same "Original") already active — a
  /// network tier recomputing to the same rung, or the person tapping
  /// the quality that's already selected, shouldn't interrupt playback
  /// for nothing.
  Future<void> _applyVideoLevel(VideoQualityLevel? target) async {
    final item = currentItem;
    if (item == null) return;

    debugPrint(
      "APPLY VIDEO LEVEL: current=${_activeVideoLevel?.label ?? "Original"} "
      "-> requested=${target?.label ?? "Original"}",
    );

    if (target?.height == _activeVideoLevel?.height) {
      debugPrint("  -> no-op (already at this quality)");
      return;
    }

    _activeVideoLevel = target;

    // LIVE TV / QUALITY FIX: the index baked into a transcode URL and
    // the index the UI thinks is selected have to be the same one, or
    // the reopened stream contains a track nothing in the app expects.
    // `selectedAudio` can legitimately still be null here — a quality
    // change that lands before `_syncTracks` has run at all, which is
    // easy to hit on Live TV where channels are switched quickly — and
    // leaving it null let Jellyfin pick its own default while the app
    // went on believing something else was playing. Falling back to the
    // item's own default audio stream means both sides agree even in
    // that window.
    _activeAudioStreamIndex =
        target == null ? null : (selectedAudio.value?.index ?? _defaultAudioStreamIndex(item));

    // Read now rather than letting _reopenStreamPreservingState capture
    // its own copy a moment later — needed here too so a transcoded
    // target can bake it in as StartTimeTicks (see getVideoStreamUrl's
    // doc comment for why that matters). Uses the *corrected* absolute
    // position, not raw player.state.position — if we're already on a
    // transcode segment (switching from one capped quality to another),
    // the raw mpv position only describes that segment, not the item's
    // real position; see _absolutePosition.
    final resumeAt = _absolutePosition;

    final newUrl = _resolveVideoUrl(
      item,
      target,
      audioStreamIndex: _activeAudioStreamIndex,
      startAt: resumeAt,
    );

    debugPrint("  new URL: $newUrl");
    debugPrint("  resuming at: $resumeAt");

    await _reopenStreamPreservingState(
      newUrl,
      // A transcoded stream already starts at the right position via
      // StartTimeTicks above — seeking into it afterward via an HTTP
      // Range request is what was causing quality switches to hang on
      // "loading" instead of actually completing. Original quality is
      // still a plain static file, where the normal post-open seek
      // works exactly as it always has for resume playback.
      seekAfterOpen: target == null,
      // Original has no offset (it's the real file, position 0 really
      // is position 0); a capped target's position 0 is really
      // `resumeAt` — see _streamPositionOffset. Live is always zero:
      // its "position" is a live-edge high-water mark, not a point on
      // an absolute timeline, so treating one as an offset made the
      // seek bar and the elapsed counter drift further out with every
      // quality change on a channel.
      newStreamOffset:
          (target == null || item.live) ? Duration.zero : resumeAt,
    );

    debugPrint("APPLY VIDEO LEVEL: done, now active = ${_activeVideoLevel?.label ?? "Original"}");
  }

  /// Called by the Quality selector UI. `label` is "Auto" or one of
  /// kVideoQualityLadder's labels. Picking a specific resolution sets a
  /// manual override for the rest of this playback session — Default
  /// mode's network-driven Auto logic won't touch it again until either
  /// "Auto" is picked again or the video player screen is exited (see
  /// [stop], which clears the override), per the in-player selector
  /// being scoped to "this one time I'm watching this video", not a
  /// permanent app-wide change (that's what the Settings screen's Data
  /// Usage mode is for).
  Future<void> setVideoQuality(String label) async {
    final item = currentItem;

    debugPrint("--------------------------------");
    debugPrint("QUALITY SELECTOR TAPPED: \"$label\"");
    debugPrint(
      "  currentItem: ${item?.title ?? "null"}"
      "${item == null ? "" : " (audioOnly: ${item.audioOnly})"}",
    );

    if (item == null || item.audioOnly) {
      debugPrint("  -> ignored (no item, or item is audio-only)");
      debugPrint("--------------------------------");
      return;
    }

    videoQuality.value = label;

    if (label == "Auto") {
      _manualVideoOverride = null;
      final target = _autoVideoTarget(item);
      debugPrint(
        "  Auto resolved to: ${target == null ? "Original" : target.label}",
      );
      debugPrint("--------------------------------");
      await _applyVideoLevel(target);
      return;
    }

    final target = kVideoQualityLadder.firstWhere(
      (l) => l.label == label,
      orElse: () => kVideoQualityLadder.last,
    );

    debugPrint("  Manual target: ${target.label}");
    debugPrint("--------------------------------");

    _manualVideoOverride = target;
    await _applyVideoLevel(target);
  }

  /// Makes mpv wait until it holds a few seconds of audio before it starts
  /// playing a server-transcoded song, and again before it resumes after
  /// running dry. A live transcode hands over its first bytes only once
  /// the server's encoder is up and then keeps feeding in bursts; mpv's
  /// default is to start on ~1 second of data, so any gap in those
  /// bursts surfaced as "plays a moment, goes quiet while it loads,
  /// plays on". Waiting for ~5s (about 80 KB at Data Saver's 128 kbps)
  /// moves that wait in front of the first sound instead of after it.
  ///
  /// Only transcoded music gets this: the untouched original, downloaded
  /// files and video keep mpv's own defaults (`cache-pause-initial=no`,
  /// `cache-pause-wait=1`), restored here the first time something else
  /// plays after a transcoded song. Best-effort — failing to set a
  /// property must never stop playback.
  Future<void> _setAudioPrebuffer(bool enabled) async {
    if (enabled == _audioPrebufferApplied) return;

    final platform = player.platform;
    if (platform is! NativePlayer) return;

    try {
      await platform.setProperty('cache-pause-initial', enabled ? 'yes' : 'no');
      await platform.setProperty('cache-pause-wait', enabled ? '5' : '1');
      _audioPrebufferApplied = enabled;
    } catch (e) {
      debugPrint("AUDIO PREBUFFER: couldn't set ($enabled): $e");
    }
  }

  /// Network-quality readings (`NetworkQualityService.tier`/`measured`)
  /// only ever re-tune VIDEO while it plays. A song's quality is decided
  /// once, when it starts (see `playMedia`), and a network reading that
  /// lands afterwards is left for the NEXT song to pick up.
  ///
  /// STOP-THEN-CONTINUE FIX (Data Saver / Default): re-tuning a song
  /// that is already playing means `_applyAdaptiveQuality` ->
  /// `_reopenStreamPreservingState`, which closes the stream and opens a
  /// new one — the music cuts out, `loading` comes up while the new
  /// (server-transcoded) stream spins up, and only then does it carry on.
  /// The very first bandwidth probe of every session lands a second or
  /// two into the first song (`NetworkQualityService.measured` flips),
  /// and the 3s debounce below puts the reopen a few seconds into the
  /// song — exactly "starts, stops as if loading, continues". In Default
  /// mode that first reading turns "open the original" into "cap it",
  /// and the 25-second re-probes (or a connectivity change) could move
  /// the tier again and repeat it mid-song. In Data Saver the cap itself
  /// doesn't depend on the network, but it does depend on the song's
  /// real source bitrate, which can arrive after the song has already
  /// been opened (`_augmentWithPlaybackFields`) and flip the target the
  /// same way. Max Quality never saw it because its target is always
  /// "original", so there was never anything to change.
  void _onNetworkQualityChanged() {
    if (currentItem?.audioOnly ?? false) return;
    _onQualityInputsChanged();
  }

  /// Fires on every AppSettings.playbackQualityMode change (and, for
  /// video, every NetworkQualityService.tier/measured change via
  /// `_onNetworkQualityChanged`) — registered once in `initialize()`.
  /// Debounced so a flurry of connectivity events settles for a moment
  /// before actually interrupting playback with a reopen.
  void _onQualityInputsChanged() {
    if (currentItem == null) return;
    if (_castSuspended) return;

    _adaptiveQualityDebounce?.cancel();
    _adaptiveQualityDebounce = Timer(
      const Duration(seconds: 3),
      _applyAdaptiveQuality,
    );
  }

  /// MUSIC STREAM RECOVERY. A capped (Data Saver / Default) song is a
  /// live transcode, and a live transcode can be dropped by the server
  /// partway through. Two ways that shows up: mpv reports a clean end of
  /// file well before the song's real length (`completed`), or the
  /// connection dies with an error (`error`, where `completed` never
  /// fires and the song just goes silent). Either way the old code
  /// treated it as "song finished" or did nothing at all.
  ///
  /// Returns true when it took over (the caller must NOT advance the
  /// queue), false when this isn't a cut-short capped stream or recovery
  /// is exhausted (the caller carries on as before).
  ///
  /// Each attempt resumes from where playback got to:
  ///   1. the same capped MP3 stream, restarted server-side at that point;
  ///   2. a capped AAC stream instead, in case it's the MP3 encode itself;
  ///   3. the original file, seeked to that point — last resort, so a
  ///      song never just stops (this one ignores the cap, and says so).
  /// After attempt 3 the stream is the plain original, which falls
  /// outside this method, so it can't loop.
  Future<bool> _recoverCutShortAudioStream({required String reason}) async {
    final item = currentItem;
    if (item == null || !item.audioOnly || item.live) return false;
    if (_isOfflineFile(item)) return false;
    if (_castBlocksLocalAudio || _castSuspended) return false;

    // Only a capped stream is a live transcode. The original is a plain
    // file: if it ends, it ended.
    final cap = _activeAudioBitrateKbps;
    if (cap == null) return false;

    final total = item.runtime > Duration.zero
        ? item.runtime
        : (_originalDuration ?? Duration.zero);
    if (total <= Duration.zero) return false;

    final live = _absolutePosition;
    final reached =
        _lastAbsoluteStreamPosition > live ? _lastAbsoluteStreamPosition : live;

    if (reached >= total - _cutShortTolerance) return false;

    // `completed` and `error` can both fire for one failure.
    if (_audioRecoveryInFlight) return true;
    if (_audioStreamRecoveryAttempts >= 3) return false;

    _audioRecoveryInFlight = true;
    final attempt = ++_audioStreamRecoveryAttempts;
    final startTicks = reached.inMicroseconds * 10;

    debugPrint(
      "MUSIC RECOVERY #$attempt ($reason): '${item.title}' cut short at "
      "$reached of $total (cap ${cap}kbps)",
    );

    try {
      String url;
      int? newCap = cap;
      Duration offset = reached;

      if (attempt == 1) {
        // The same progressive MP3 stream, restarted server-side at the
        // point playback reached.
        url = MediaService.getAudioMp3TranscodeUrl(
          item.id,
          maxBitrateKbps: cap,
          startTimeTicks: startTicks,
          playSessionId: _musicPlaySessionId,
        );
      } else if (attempt == 2) {
        // A different encode path, in case it's the MP3 one that isn't
        // surviving on this server.
        url = MediaService.getAudioStreamUrl(
          item.id,
          maxBitrateKbps: cap,
          startTimeTicks: startTicks,
        );
      } else {
        url = MediaService.getAudioStreamUrl(item.id);
        newCap = null;
        offset = Duration.zero;
      }

      _activeAudioBitrateKbps = newCap;

      await _reopenStreamPreservingState(
        url,
        seekAfterOpen: false,
        newStreamOffset: offset,
      );

      // The person moved on to another song while this was reopening.
      if (currentItem?.id != item.id) return true;

      if (attempt >= 3) {
        // The original file starts at zero (nothing server-side carried
        // the resume point), so seek into it — fine for a plain file.
        try {
          await _waitForDuration(item);
          if (currentItem?.id != item.id) return true;
          await player.seek(reached).timeout(_qualitySwitchTimeout);
        } catch (e) {
          debugPrint("MUSIC RECOVERY: seek into original failed: $e");
        }
        lastError.value =
            "Couldn't stream at reduced quality — playing the original file.";
      }

      position.value = reached;

      // At the end of a stream mpv reports not-playing, so
      // _reopenStreamPreservingState (which restores the previous
      // play/pause state) wouldn't start it again on its own.
      if (!_castBlocksLocalAudio) await player.play();

      return true;
    } catch (e) {
      debugPrint("MUSIC RECOVERY failed: $e");
      return false;
    } finally {
      _audioRecoveryInFlight = false;
    }
  }

  Future<void> _applyAdaptiveQuality() async {
    final item = currentItem;
    if (item == null) return;

    // A local/downloaded file's `streamUrl` isn't a Jellyfin URL at
    // all — nothing here should ever try to rebuild one just because
    // the network tier changed (network monitoring isn't even acquired
    // for these — see playMedia — but the tier ValueNotifier is global,
    // so this listener can still fire while one's playing).
    if (_isOfflineFile(item)) return;

    if (item.audioOnly) {
      // A stream-recovery rebuild owns the stream for the rest of this
      // song; a quality reopen on top of it would just undo it.
      if (_audioStreamRecoveryAttempts > 0) return;

      final target = _autoAudioTarget(item);
      if (target == _activeAudioBitrateKbps) return;

      // Corrected absolute position, not raw player.state.position — if
      // the song is already on a capped (StartTimeTicks-based) stream,
      // the raw position only describes time within that segment. Same
      // reasoning as _applyVideoLevel; see _absolutePosition.
      final resumeAt = _absolutePosition;

      _activeAudioBitrateKbps = target;

      await _reopenStreamPreservingState(
        _resolveAudioUrl(item, target, startAt: resumeAt),
        // A capped stream starts at the right place server-side, so the
        // post-open seek that used to hang here has nothing left to do.
        // Uncapped is the plain direct-play file, where a normal seek
        // works exactly as it always has.
        seekAfterOpen: target == null,
        newStreamOffset: target == null ? Duration.zero : resumeAt,
      );
      return;
    }

    // A manual pick from the in-player Quality selector always wins
    // over the network-driven Auto logic until the video player is
    // exited — see setVideoQuality's doc comment.
    if (_manualVideoOverride != null) return;

    await _applyVideoLevel(_autoVideoTarget(item));
  }

  /// Called by PlaybackCoordinator the moment a local→remote cast
  /// handoff starts. Cancels any already-scheduled reopen and releases
  /// the bandwidth probe for as long as the handoff lasts — Auto has
  /// nothing useful to evaluate for a paused, inaudible local stream,
  /// and leaving the probe running would just burn the phone's own
  /// data/battery for a decision that can't affect what the TV is
  /// actually playing. Idempotent: safe to call even if already
  /// suspended (e.g. a session reconnecting without going through a
  /// resume in between).
  void suspendAdaptiveQualityForCast() {
    if (_castSuspended) return;
    _castSuspended = true;
    _adaptiveQualityDebounce?.cancel();

    if (_networkMonitoringActive) {
      NetworkQualityService.instance.release();
    }
  }

  /// Reverses [suspendAdaptiveQualityForCast] once local playback is
  /// back in the picture — either the cast session ended, or the
  /// handoff attempt itself failed and control was handed straight back
  /// (see PlaybackCoordinator._handleSessionConnected's catch block).
  /// Re-acquires the probe against whatever's currently loaded and
  /// immediately re-evaluates Auto rather than waiting for the next
  /// unrelated connectivity event to happen to fire — the phone's own
  /// network conditions may well have moved on during however long the
  /// cast was active.
  void resumeAdaptiveQualityAfterCast() {
    if (!_castSuspended) return;
    _castSuspended = false;

    final item = currentItem;
    if (item == null) return;

    if (_networkMonitoringActive) {
      NetworkQualityService.instance.acquire();
      _ensureNetworkMonitoring(item);
    }

    _onQualityInputsChanged();
  }

  // ---------------------------------------------------------------------
  // CASTING FIX — cast-mirror mode (audio only).
  //
  // Lets [PlaybackCoordinator] keep every purely-local, PlayerManager-
  // driven "what's playing" surface (mini player, song rows' pulsing
  // equalizer bars, AudioPlayerScreen, the OS media session via
  // NemesisAudioHandler) pointed at whatever's actually playing on a
  // connected cast session — including a *new* song picked from
  // somewhere in the app while already casting, which never gets opened
  // in local mpv at all — without ever calling `player.play()`/
  // `player.open()` for it. `player`/mpv itself is completely untouched
  // by any of this; only the public notifiers screens already watch are
  // updated, exactly the way a normal local `playMedia()` would update
  // them, just without the local audio.
  // ---------------------------------------------------------------------
  bool castMirrorActive = false;

  // ---------------------------------------------------------------------
  // NO LOCAL AUDIO WHILE CAST IS CONNECTED.
  //
  // While a cast session is connected, the TV is the only place playback
  // belongs — local mpv must never produce sound, whatever path tried to
  // start it (a failed cast redirect falling back to local, a stale
  // `open(play: true)` finishing late, a transport button, PiP, a
  // resumed audio-focus interruption...). Three layers enforce that:
  //
  //  1. [playMedia] refuses to open anything in mpv while connected and
  //     hands the item to [redirectPlayToCast] instead.
  //  2. The mpv `playing` listener pauses mpv the instant it reports
  //     playing while connected (catch-all for every other path).
  //  3. The internal `player.play()` call sites check
  //     [_castBlocksLocalAudio] first.
  //
  // Both hooks are installed by PlaybackCoordinator.init() — PlayerManager
  // deliberately never imports the casting layer.
  // ---------------------------------------------------------------------
  bool Function() isCastConnected = () => false;

  /// Sends [item] to the connected cast session. Returns true if it was
  /// handled (sent, or failed-and-reported) — the caller must not start
  /// local playback either way.
  Future<bool> Function(MediaItem item)? redirectPlayToCast;

  bool get _castBlocksLocalAudio => isCastConnected();

  /// Pauses local mpv if it is playing while a cast session is connected.
  /// Safe to call any time; a no-op otherwise.
  Future<void> enforceNoLocalAudioWhileCasting() async {
    if (!_castBlocksLocalAudio) return;
    if (player.state.playing) {
      try {
        await player.pause();
      } catch (_) {}
    }
  }

  Future<void> _divertPlayToCast(MediaItem item) async {
    // Any in-flight local open for an earlier item must not carry on
    // and touch state that now belongs to the cast session.
    ++_playbackToken;
    await enforceNoLocalAudioWhileCasting();

    final redirect = redirectPlayToCast;
    if (redirect != null) {
      try {
        await redirect(item);
      } catch (e) {
        debugPrint('CASTING DEBUG: redirect of "${item.title}" to cast '
            'failed: $e');
      }
    }
    loading.value = false;
    _audioSwitchStalled = false;
    buffering.value = false;
  }

  void beginCastMirror(MediaItem item) {
    castMirrorActive = true;
    currentItemNotifier.value = item;
    loading.value = false;
    lastError.value = null;

    // CASTING FIX (music mini player never appears while casting): this
    // used to leave `isVideo`/`showMiniPlayer` completely untouched, on
    // the assumption whatever local playback had last set them to would
    // still be roughly right. That's only true if something was already
    // playing locally in this exact app session with those two flags
    // already sitting at "audio, mini player visible" — a brand new
    // audio cast session (nothing ever played locally first), or a
    // video item having been the last thing to touch these two
    // notifiers (isVideo left true from an earlier movie/episode,
    // including a video item mirrored via castJumpTo — see below),
    // both left `isVideo` true and/or `showMiniPlayer` false. Since
    // `_buildLocalMiniPlayer` hides itself whenever `isVideo` is true or
    // `showMiniPlayer` is false, that's exactly "the mini player doesn't
    // appear at all" for a fresh/second cast pick.
    //
    // Deriving `isVideo` from the item itself (rather than hard-coding
    // false) matters because this same method is also called for a
    // *video* episode picked from the in-player episode list while
    // already casting (PlaybackCoordinator.castJumpTo, used by
    // EpisodeListPanel) — the video-casting mini player bar/backdrop
    // read the cast session directly and don't care about this flag,
    // but other surfaces (PlayerTopBar's channel-list toggle, anything
    // else keyed off `manager.isVideo`) still should see the correct
    // value for whichever kind of item is actually mirrored.
    isVideo.value = !item.audioOnly;
    showMiniPlayer.value = true;

    _precacheArtwork(item);
  }

  void updateCastMirrorItem(MediaItem item) {
    if (!castMirrorActive) return;
    currentItemNotifier.value = item;
    _precacheArtwork(item);
    _ensureLogo(item);
  }

  void updateCastMirrorPlayback({
    required bool playing_,
    required Duration position_,
    required Duration duration_,
  }) {
    if (!castMirrorActive) return;
    playing.value = playing_;
    position.value = position_;
    duration.value = duration_;
  }

  /// Ends cast-mirror mode. Forces `playing` false regardless of what it
  /// was last mirrored to — whatever was on the TV isn't playing
  /// anywhere anymore the moment the session disconnects, so leaving a
  /// stale "playing" reading would show an actively-pulsing "now
  /// playing" row for audio that has actually stopped. `currentItem`
  /// itself is deliberately left as the last-mirrored track (same
  /// courtesy a real local pause leaves in place) rather than cleared.
  void endCastMirror() {
    if (!castMirrorActive) return;
    castMirrorActive = false;
    playing.value = false;
  }

  /// Starts NetworkQualityService's connectivity/bandwidth monitoring
  /// the first time anything plays, and points its probe at whatever's
  /// actually open right now. Safe to call every `playMedia()` — the
  /// `_networkMonitoringActive` guard means `acquire()` itself only ever
  /// runs once per real playback session (the matching `release()` is
  /// in `stop()`).
  void _ensureNetworkMonitoring(MediaItem item) {
    if (!_networkMonitoringActive) {
      _networkMonitoringActive = true;
      NetworkQualityService.instance.acquire();
    }

    if (item.isLocal) {
      NetworkQualityService.instance.setProbeUrl(null);
      return;
    }

    final probeUrl = item.audioOnly
        ? MediaService.getAudioDownloadUrl(item.id)
        : (item.live
            ? MediaService.getLiveTvStreamUrl(item.id)
            : MediaService.getPlaybackUrl(item.id));

    NetworkQualityService.instance.setProbeUrl(probeUrl);
  }

  /// Immediately populates [currentItemNotifier] and flips [loading] on
  /// for [item], *before* the real playback request has necessarily
  /// produced anything playable yet.
  ///
  /// Callers that need to resolve a season/series queue over the network
  /// (see `PlaybackService.playLibraryItem`) previously awaited that
  /// entire resolution — plus the subsequent `playMedia()` call — before
  /// ever pushing [VideoPlayerScreen], which left the user stranded on
  /// whatever screen they tapped "Play" from with no feedback for however
  /// long that took. Calling this first lets the caller push the player
  /// screen immediately and let its loading overlay (backdrop + logo)
  /// take over right away; `playMedia()`/`playQueue()` shortly after
  /// overwrite this with the real resolved item once ready.
  void showLoadingPreview(MediaItem item) {
    // Invalidate any in-flight stop()/playMedia() call from whatever was
    // playing before — see _playbackToken's doc comment.
    _playbackToken++;

    // The loading logo starts dim and uncoloured while the person still has
    // to choose a source, and starts filling once one is chosen. See
    // PlaybackLoadProgress.
    if (!item.audioOnly) {
      PlaybackLoadProgress.instance
          .begin(awaitingLink: PlaybackLoadProgress.needsLink(item));
    }

    currentItemNotifier.value = item;
    loading.value = true;
    lastError.value = null;
    _precacheArtwork(item);
    _ensureLogo(item);
  }

  /// The movie / series id ("m123" / "s123") whose logo belongs to [item].
  String? _logoIdFor(MediaItem item) {
    if (item.live || item.audioOnly) return null;
    final raw = item.raw;
    final tmdb = raw?['TmdbId'];
    if (raw?['AddonStream'] == true && tmdb != null) {
      return '${raw?['Type'] == 'Episode' ? 's' : 'm'}$tmdb';
    }
    final series = item.seriesId;
    if (series != null && RegExp(r'^s\d+$').hasMatch(series)) return series;
    if (RegExp(r'^[ms]\d+$').hasMatch(item.id)) return item.id;
    return null;
  }

  /// Titles opened from a list or search never had their detail page loaded,
  /// so no logo is known yet. Looks it up in the background and grafts it onto
  /// the loading screen / buffering overlay as soon as it arrives.
  void _ensureLogo(MediaItem item) {
    if (item.logo != null) return;
    final vid = _logoIdFor(item);
    if (vid == null) return;
    unawaited(VirtualCatalog.ensureLogo(vid).then((url) {
      if (url == null) return;
      final cur = currentItem;
      if (cur == null || cur.id != item.id || cur.logo != null) return;
      currentItemNotifier.value = cur.copyWith(logo: url);
      _precacheArtwork(currentItem!);
    }));
  }

  /// Fetches this item's real per-file Intro/Outro timing and grafts it
  /// onto whatever's currently playing once it lands.
  ///
  /// This is deliberately not part of building the MediaItem itself
  /// (MediaService.mediaItemFromJellyfin) — that mapper runs synchronously
  /// in dozens of places (Continue Watching, search, every detail screen,
  /// ...) and making all of them await a second network round trip just
  /// to know where an intro ends would be a much bigger, riskier change
  /// than fetching it once, centrally, the moment something actually
  /// starts playing. It's also what makes this correct regardless of
  /// *how* playback was started — Continue Watching, a season queue, the
  /// mini player's swipe-to-next — since every path funnels through
  /// playMedia() either way.
  ///
  /// Both guards below matter: `token` catches this call having been
  /// superseded by a newer playMedia()/stop() entirely, and the id check
  /// additionally catches the narrower case where playNext()/playPrevious()
  /// already moved on to a different item under the *same* token by the
  /// time this resolves (neither of those bumps _playbackToken, since
  /// they're not superseding a stale request — they're a normal
  /// transport action mid-session).
  Future<void> _loadSkipSegments(MediaItem item, int token) async {
    if (item.audioOnly || item.live) return;

    // Addon titles have no Jellyfin segments: community database first
    // (chapters and the manual button follow in _loadChapterSegments).
    if (item.raw?['AddonStream'] == true) {
      final community = await SegmentService.community(item);
      if (token != _playbackToken || currentItem?.id != item.id) return;
      currentItemNotifier.value = currentItem!.copyWith(
        skipSegments: SegmentService.compose(
          item: item,
          community: community,
          allowManual: false, // wait for the chapter check first
        ),
      );
      return;
    }

    final segments = await MediaService.getSkipSegments(item.id);

    if (token != _playbackToken) return;
    if (currentItem?.id != item.id) return;

    currentItemNotifier.value = currentItem!.copyWith(skipSegments: segments);
  }

  SkipSegment? _estOutro;
  String? _estKey;

  /// Best guess for where the credits start: the last ~3.5% of an episode
  /// (45-120 s), or the last ~6% of a movie (4-9 min). Cached so the
  /// position listener gets the same object on every tick.
  SkipSegment _estimatedOutroFor(MediaItem item, Duration total) {
    final key = '${item.id}:${total.inSeconds}';
    final cached = _estOutro;
    if (cached != null && _estKey == key) return cached;

    final episode = item.raw?['Type'] == 'Episode';
    final minG = episode ? 45 : 240;
    final maxG = episode ? 120 : 540;
    var seconds = (total.inSeconds * (episode ? 0.035 : 0.06)).round();
    if (seconds < minG) seconds = minG;
    if (seconds > maxG) seconds = maxG;

    var start = total - Duration(seconds: seconds);
    if (start < total * 0.6) start = total * 0.6;

    _estKey = key;
    return _estOutro =
        SkipSegment(start: start, end: total, type: SkipSegmentType.outro);
  }

  /// Addon titles, once the file is open: adds Skip Intro / Skip Credits
  /// from the file's own chapter markers where the community database had
  /// nothing, and the manual "Skip 85s" button for episodes still without an
  /// intro. Never throws.
  Future<void> _loadChapterSegments(
      MediaItem item, int token, Duration total) async {
    if (item.audioOnly || item.live || item.raw?['AddonStream'] != true) {
      return;
    }
    try {
      final community = await SegmentService.community(item);
      if (token != _playbackToken || currentItem?.id != item.id) return;

      final marks = await _readChapters();
      if (token != _playbackToken || currentItem?.id != item.id) return;

      final length = total > Duration.zero ? total : item.runtime;
      final fromChapters = SegmentService.fromChapters(marks, length);
      final segments = SegmentService.compose(
        item: item,
        community: community,
        chapters: fromChapters,
        total: length,
      );
      currentItemNotifier.value =
          currentItem!.copyWith(skipSegments: segments);
    } catch (e) {
      debugPrint('[PlayerManager] chapter segments failed: $e');
    }
  }

  /// The chapter list of the open file, through mpv's per-chapter
  /// properties (each returns a plain string; an empty one when absent).
  Future<List<ChapterMark>> _readChapters() async {
    try {
      final native = player.platform;
      if (native is! NativePlayer) return const [];
      final count =
          int.tryParse(await native.getProperty('chapter-list/count')) ?? 0;
      if (count < 2 || count > 200) return const [];
      final out = <ChapterMark>[];
      for (var i = 0; i < count; i++) {
        final title = await native.getProperty('chapter-list/$i/title');
        final time = double.tryParse(
            await native.getProperty('chapter-list/$i/time'));
        if (time == null) continue;
        out.add(ChapterMark(
            title, Duration(milliseconds: (time * 1000).round())));
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  /// Re-applies an OpenSubtitles subtitle previously picked for this
  /// exact item (see OpenSubtitlesSheet._download, which caches every
  /// successful download via MediaExtrasCacheService) without hitting
  /// OpenSubtitles again. That cache otherwise only ever gets written
  /// to, never read — without this, picking a subtitle from there was
  /// good for the current playback session only; closing the video and
  /// reopening the same one lost it entirely and required searching and
  /// downloading it all over again.
  ///
  /// Deliberately does nothing for audio-only or live items (OpenSubtitles
  /// is a video-subtitle feature, reachable only from the video subtitle
  /// sheet), and only applies the cached pick if nothing else has claimed
  /// `selectedSubtitle` by the time this resolves — a real forced/default
  /// track from Jellyfin's own MediaStreams (handled by `_syncTracks`)
  /// takes priority, since that reflects the file itself rather than a
  /// standing choice for this app alone.
  Future<void> _reapplyCachedSubtitleIfAny(MediaItem item, int token) async {
    if (item.audioOnly || item.live) return;

    final cached = await MediaExtrasCacheService.readSubtitle(item.id);

    String? content;
    String? displayTitle;
    String? language;

    // Any beyond the first sidecar file found — still to be added as
    // pickable-but-not-auto-selected entries further down, once the
    // usual token/currentItem guards have passed.
    List<Map>? extraSidecars;

    if (cached != null) {
      content = cached.content;
      displayTitle = cached.displayTitle;
      language = cached.language;
    } else {
      // Externally-opened files (Open With/Play With — see
      // ExternalMediaHandler) may have their own subtitle file(s)
      // sitting right in the same folder as the source file —
      // MainActivity.kt already tried a full directory scan (falling
      // back to a same-named-only guess when that scan couldn't run —
      // see ExternalMediaHandler._scanSidecarSubtitles' own doc
      // comment) and handed whatever text it found straight back on
      // the external-media payload, stashed here in `raw` since
      // there's no Jellyfin item to attach real subtitle metadata to
      // for one of these. Loading the first one exactly like a
      // remembered OpenSubtitles pick means a movie opened this way
      // with its own subtitle already sitting beside it "just works"
      // without the person needing to search for or select it
      // manually; every other file found still needs its own entry so
      // it's pickable from the subtitle sheet, same as a title with
      // more than one real Jellyfin subtitle stream would show.
      final sidecarSubs = (item.raw?['SidecarSubtitles'] as List?)
              ?.whereType<Map>()
              .toList() ??
          const [];

      if (sidecarSubs.isNotEmpty) {
        content = sidecarSubs.first['content'] as String?;
        displayTitle = (sidecarSubs.first['fileName'] as String?) ?? 'Subtitle';
        language = '';
        extraSidecars =
            sidecarSubs.length > 1 ? sidecarSubs.sublist(1) : null;
      }
    }

    if (content == null) return;

    if (token != _playbackToken) return;
    if (currentItem?.id != item.id) return;

    if (extraSidecars != null) {
      for (var i = 0; i < extraSidecars.length; i++) {
        final entry = extraSidecars[i];
        _appendSidecarSubtitleTrack(
          content: entry['content'] as String? ?? '',
          displayTitle: (entry['fileName'] as String?) ?? 'Subtitle ${i + 2}',
        );
      }
    }

    if (selectedSubtitle.value != null) return;

    await loadDownloadedSubtitle(
      content: content,
      displayTitle: displayTitle ?? 'Subtitle',
      language: language ?? '',
    );
  }

  /// Episode/movie list screens now fetch their items *without*
  /// MediaSources/MediaStreams/Trickplay (see MediaService.getEpisodes)
  /// since Jellyfin has to resolve/probe the real media source per item
  /// to fill those in, and doing that for a whole season's worth of
  /// episodes just to show a list was what made season loads/switches
  /// slow. Those three fields are only actually needed once something
  /// is genuinely about to play — for audio/subtitle track selection
  /// (_syncTracks) and trickplay scrub previews — so they're fetched
  /// here, for just the one item that's playing, right as playback
  /// starts.
  ///
  /// Same fire-and-forget/token-guarded shape as [_loadSkipSegments]:
  /// harmless if it loses a race with a newer playMedia()/stop() call,
  /// and skipped entirely for local files (nothing on a Jellyfin server
  /// to fetch), live channels (no season/episode list this ever came
  /// from), or an item that already has the data (e.g. it came from a
  /// screen — like movie details — that still requests the full
  /// fields for its single item).
  Future<void> _augmentWithPlaybackFields(MediaItem item, int token) async {
    // `isLocal` is only ever set for on-device music (LocalMusicService)
    // — a downloaded video/episode's MediaItem has no `IsLocal` raw flag
    // even though its streamUrl is a local file path, so that check
    // alone would miss it. Guard on the streamUrl scheme instead, which
    // covers both cases: nothing to fetch from a server for a file
    // that's already sitting on disk.
    if (item.live) return;
    if (!item.streamUrl.startsWith('http')) return;
    // Previously skipped whenever `mediaStreams` alone was already
    // populated — true for items opened from MediaService.getItems()
    // (search results, tag/genre/collection screens: its default
    // `Fields` list includes MediaSources/MediaStreams but not
    // Trickplay, unlike the movie/series details screen's full
    // getItem() fetch). That meant this early-return fired before
    // Trickplay was ever fetched for such an item, permanently
    // skipping its scrub preview for the rest of that playback since
    // this only runs once per item. Checking trickplay too means an
    // item with tracks-but-no-trickplay still gets the one augment
    // call it actually needs.
    final hasMediaStreams =
        item.mediaStreams != null && item.mediaStreams!.isNotEmpty;

    // STUCK-THUMBNAIL FIX: a non-empty `item.trickplay` used to be
    // trusted outright here, on the assumption that "the field is
    // populated" means "the field is done". That's true for
    // MediaSources/MediaStreams (Jellyfin probes those once, and they
    // don't change afterward) but NOT for Trickplay, which Jellyfin
    // fills in from a background generation job that can still be
    // running — or permanently stalled on one file — at the exact
    // moment some earlier screen (the movie/series details page, or
    // the Continue Watching row via MediaService.getResume, both of
    // which request the Trickplay field up front) happened to fetch
    // this item. That earlier, possibly-incomplete snapshot is what
    // `item.trickplay` already holds by the time this method runs, and
    // the old check let it ride for the entire playback session even
    // though generation may have long since finished server-side —
    // which is exactly what made scrubbing look permanently "stuck on
    // one image" for a title that Jellyfin's own web client (which
    // always fetches its own copy right as playback starts, not
    // whenever a list screen happened to load) shows scrubbing fine:
    // the web client simply never has a chance to observe the stale
    // in-between state this app's cached MediaItem could be carrying.
    //
    // `TrickplayService.looksComplete` below is the fix: only trust the
    // already-loaded Trickplay data if it plausibly covers the item's
    // real runtime. Anything short of that forces the same
    // `MediaService.getItem` call this method already makes to run
    // anyway, picking up whatever Jellyfin has generated as of RIGHT
    // NOW instead of whatever was true whenever the details/resume
    // screen was last loaded.
    //
    // This check used to live here as a PlayerManager-private method
    // (`_trickplayLooksComplete`) reachable only from this file. It's
    // now `TrickplayService.looksComplete` — a shared, public utility —
    // specifically so CastManager's parallel `_ensureFullMediaItem` can
    // call the exact same check instead of the weaker one it had
    // (mediaStreams-only, no regard for whether Trickplay specifically
    // was complete). That gap is what let a *cast* movie stay stuck on
    // a stale trickplay snapshot even after this exact fix already
    // covered local playback — see `_ensureFullMediaItem`'s doc comment
    // in cast_manager.dart for the full story.
    final hasTrickplay = item.trickplay != null &&
        item.trickplay!.isNotEmpty &&
        TrickplayService.looksComplete(item);

    debugPrint(
      'TRICKPLAY AUGMENT (local): item=${item.id} title="${item.title}" '
      'hasMediaStreams=$hasMediaStreams hasTrickplay=$hasTrickplay -> '
      '${(hasMediaStreams && hasTrickplay) ? "skipping refetch (already good)" : "refetching from server"}',
    );

    if (hasMediaStreams && hasTrickplay) return;

    try {
      final fresh = await MediaService.getItem(item.id);

      if (token != _playbackToken) return;
      if (currentItem?.id != item.id) return;

      currentItemNotifier.value = currentItem!.copyWith(
        mediaStreams: fresh["MediaStreams"] != null
            ? List<dynamic>.from(fresh["MediaStreams"])
            : (fresh["MediaSources"] is List &&
                    (fresh["MediaSources"] as List).isNotEmpty
                ? List<dynamic>.from(
                    fresh["MediaSources"][0]["MediaStreams"] ?? [])
                : null),
        mediaSources: fresh["MediaSources"] != null
            ? List<dynamic>.from(fresh["MediaSources"])
            : null,
        trickplay: fresh["Trickplay"] != null
            ? Map<String, dynamic>.from(fresh["Trickplay"])
            : null,
      );

      // The native mpv track list is already open and playing by the
      // time this lands — re-run the same pairing _syncTracks does on
      // every native `tracks` event so the audio/subtitle selector UI
      // picks up the freshly-fetched Jellyfin metadata immediately
      // instead of waiting for mpv to fire another tracks event of its
      // own (which may not happen again for a file whose track set
      // hasn't changed).
      _syncTracks(player.state.tracks);
    } catch (_) {
      // No network, or the item 404s — playback still works off the
      // static stream URL already opened; only the nicer track names/
      // trickplay preview are missed for this item.
    }
  }

  /// Fetches and shows the "Next Movie" recommendation once a movie with
  /// nothing else queued reaches its Outro segment (see the position
  /// listener above) and the person has recommendations turned on. Same
  /// token/id-guard pattern as [_loadSkipSegments], since this is also a
  /// fire-and-forget async call kicked off mid-playback.
  ///
  /// Deliberately appends the recommendation into [PlaybackQueue] as soon
  /// as it's found (via the same `appendRecommendations` the music
  /// continuation feature uses) rather than only when "Play Now" is
  /// tapped — that's what makes this behave exactly like Next Episode if
  /// the person just lets the movie run out on its own instead of
  /// interacting with the card at all: `queue.hasNext` is now true, so
  /// the ordinary "queue.hasNext ? playNext() : ..." handling for
  /// finished video playback picks it up automatically, same as an
  /// episode would.
  Future<void> _maybeShowNextMovie(MediaItem finished, int token) async {
    final alreadyQueued = PlaybackQueue.instance.items
        .map((i) => i.id)
        .toSet();

    // A movie played from the Downloads library should keep
    // recommending from that same downloaded library — a
    // server-Similar pick isn't actually watchable without a
    // connection, which would defeat the entire point of having
    // downloaded this movie in the first place. DownloadManager
    // .isDownloaded is the same signal playMedia() above already
    // checks to pull this movie's own offline resume position, so
    // it's already meaningful by the time this fires.
    MediaItem? recommendation;

    if (DownloadManager.instance.isDownloaded(finished.id)) {
      recommendation = MovieRecommendationService.instance
          .recommendNextDownloaded(finished, exclude: alreadyQueued);
    } else {
      recommendation = await MovieRecommendationService.instance
          .recommendNext(finished, exclude: alreadyQueued)
          .catchError((_) => null);
    }

    if (token != _playbackToken) return;
    if (currentItem?.id != finished.id) return;
    if (recommendation == null) return;

    PlaybackQueue.instance.appendRecommendations([recommendation]);

    nextMovieRecommendation.value = recommendation;
    showNextMovie.value = true;
  }

  /// Declines the "Next Movie" recommendation the person just dismissed.
  ///
  /// [_maybeShowNextMovie] above appends the recommendation into
  /// [PlaybackQueue] the moment it's found — not only once "Play Now" is
  /// tapped — specifically so letting the movie run out untouched
  /// auto-plays it, the same as Next Episode would (see that method's
  /// doc comment). But that means an explicit Dismiss tap on the card
  /// was only ever hiding the overlay: the recommendation stayed queued,
  /// so `queue.hasNext` was still true and the playback-finished handler
  /// auto-played it anyway the moment the current movie ended — the
  /// exact outcome dismissing was supposed to prevent. Pulling the
  /// recommendation back out of the queue here is what makes Dismiss
  /// actually decline it instead of just delaying it by a few seconds.
  void dismissNextMovieRecommendation() {
    final recommendation = nextMovieRecommendation.value;

    if (recommendation != null) {
      final queue = PlaybackQueue.instance;
      final index = queue.items.indexWhere((i) => i.id == recommendation.id);

      if (index != -1) {
        queue.removeAt(index);
      }
    }

    nextMovieRecommendation.value = null;
  }

  /// Fetches and shows the "Next Show" recommendation once the last
  /// episode of a series with nothing else queued reaches its Outro
  /// segment (see the position listener above) and the person has
  /// recommendations turned on. Mirrors [_maybeShowNextMovie] exactly —
  /// same token/id/recommendations-off guards, same "downloaded item
  /// keeps recommending from the downloaded library" branch, same
  /// append-into-queue-immediately behavior so letting the episode run
  /// out untouched auto-plays the recommended show's first episode the
  /// same way an ordinary next episode would.
  Future<void> _maybeShowNextShow(MediaItem finished, int token) async {
    final alreadyQueued = PlaybackQueue.instance.items
        .map((i) => i.id)
        .toSet();

    MediaItem? recommendation;

    if (DownloadManager.instance.isDownloaded(finished.id)) {
      recommendation = ShowRecommendationService.instance
          .recommendNextDownloaded(finished, exclude: alreadyQueued);
    } else {
      recommendation = await ShowRecommendationService.instance
          .recommendNext(finished, exclude: alreadyQueued)
          .catchError((_) => null);
    }

    if (token != _playbackToken) return;
    if (currentItem?.id != finished.id) return;
    if (recommendation == null) return;

    PlaybackQueue.instance.appendRecommendations([recommendation]);

    nextShowRecommendation.value = recommendation;
    showNextShow.value = true;
  }

  /// Declines the "Next Show" recommendation the person just dismissed —
  /// same reasoning as [dismissNextMovieRecommendation]: the
  /// recommendation was appended into the queue the moment it was
  /// found, so pulling it back out here is what makes Dismiss actually
  /// decline it instead of just delaying it.
  void dismissNextShowRecommendation() {
    final recommendation = nextShowRecommendation.value;

    if (recommendation != null) {
      final queue = PlaybackQueue.instance;
      final index = queue.items.indexWhere((i) => i.id == recommendation.id);

      if (index != -1) {
        queue.removeAt(index);
      }
    }

    nextShowRecommendation.value = null;
  }

  /// Re-roots PlaybackQueue onto [firstEpisode]'s series once its Next
  /// Show recommendation actually starts playing. Up to this point the
  /// queue only ever had [firstEpisode] appended onto the *end* of the
  /// series that just finished (see [_maybeShowNextShow]'s
  /// `appendRecommendations` call) — deliberately so, since that's what
  /// makes `queue.hasNext` true and lets the ordinary "let it play out"
  /// completion path in the player's `completed` handler auto-continue
  /// straight into the recommendation, the same way it already does for
  /// Next Movie. But it means the queue itself — and everything that
  /// reads it, like EpisodeListPanel's episode rows, and the mini
  /// player's title/artwork — kept showing the show that just finished
  /// instead of the one now actually playing. This swaps the queue for
  /// a proper season queue of the recommended show's own episodes,
  /// fixing that at the source rather than patching each reader of it
  /// individually.
  ///
  /// Mirrors the downloaded/server split [_maybeShowNextShow] already
  /// uses: a downloaded recommendation builds its season list from
  /// DownloadManager's local records (no network round trip, and
  /// nothing to fail if offline), while a server one fetches it from
  /// Jellyfin. [token] is [_playbackToken] as captured by the
  /// [playMedia] call that started [firstEpisode] — re-checked after
  /// the fetch so a stale call (superseded by another playMedia()/
  /// stop() before this resolves) never clobbers whatever's actually
  /// playing by the time it comes back.
  Future<void> _reRootQueueOnShow(MediaItem firstEpisode, int token) async {
    final seriesId = firstEpisode.seriesId;
    if (seriesId == null) return;

    List<MediaItem> episodes;

    if (DownloadManager.instance.isDownloaded(firstEpisode.id)) {
      episodes = DownloadManager.instance
          .episodesForSeries(seriesId)
          .map(DownloadManager.instance.mediaItemForRecord)
          .toList();
    } else {
      episodes = await ShowRecommendationService.instance
          .firstSeasonEpisodes(seriesId)
          .catchError((_) => <MediaItem>[]);
    }

    if (token != _playbackToken) return;
    if (currentItem?.id != firstEpisode.id) return;
    if (episodes.isEmpty) return;

    final startIndex = episodes.indexWhere((e) => e.id == firstEpisode.id);

    PlaybackQueue.instance.setQueue(
      episodes,
      startIndex: startIndex == -1 ? 0 : startIndex,
      source: PlaybackSource.season,
      title: firstEpisode.subtitle,
      artwork: firstEpisode.backdrop,
    );
  }

  /// Kicks off the backdrop/logo network fetches as early as possible —
  /// called the moment an item is known (preview or resolved), well
  /// before the loading overlay's settle delay expires — so by the
  /// time that delay is up the images are already decoded and sitting
  /// in Flutter's image cache instead of just starting a fresh fetch
  /// the instant `Image.network` first builds.
  void _precacheArtwork(MediaItem item) {
    if (item.backdrop != null) {
      NetworkImage(item.backdrop!)
          .resolve(const ImageConfiguration())
          .addListener(
            ImageStreamListener((_, __) {}, onError: (_, __) {}),
          );
    }

    if (item.logo != null) {
      NetworkImage(item.logo!)
          .resolve(const ImageConfiguration())
          .addListener(
            ImageStreamListener((_, __) {}, onError: (_, __) {}),
          );
    }
  }

  /// [resume] controls whether the item opens at its saved resume
  /// position (`item.playbackPosition`, server- or offline-store-
  /// sourced) or from zero. Defaults to true — Continue Watching,
  /// tapping a partially-watched title, etc. all want the resume.
  /// Track-to-track transitions for music (Next, Previous, auto-advance,
  /// repeat-one) pass false: those must always start the song from the
  /// beginning. `PlaybackQueue.updateItemProgress` grafts the live
  /// position onto queue items as a track plays, so without this a
  /// song left at 0:05 (Next, then Previous back to it) reopened at
  /// 0:05 — "continue where it left off" is only for pausing/playing the
  /// *current* song, never for a skip.
  Future<void> playMedia(MediaItem item, {bool resume = true}) async {
    // NAMESIS PRIME: an item from the virtual TMDB server (a recommended
    // next show, an episode picked in the episode panel) has no stream of its
    // own; the person's addons provide it. Hand it over, and the playable
    // item comes back through this method.
    if (VirtualPlayback.isVirtual(item) && item.raw?['AddonStream'] != true) {
      await VirtualPlayback.play(item, fromPlayer: true);
      return;
    }

    // Parental Controls for video that plays directly (downloads, files
    // opened from other apps, a stream an addon already resolved). TMDB
    // titles were already checked in VirtualPlayback.play; this repeats the
    // (cached) check so no other route to the player can skip it.
    if (!item.audioOnly &&
        !item.live &&
        ParentalControls.instance.isActive) {
      final allowed = await ParentalControls.instance.authorizePlayback(
        itemJson: Map<String, dynamic>.from(item.raw ?? const <String, dynamic>{})
          ..putIfAbsent('Id', () => item.id),
      );
      if (!allowed) {
        loading.value = false;
        unawaited(ParentalPrompts.closePlayer());
        return;
      }
    }

    AnalyticsService.event('play_start', {
      'type': item.audioOnly ? 'audio' : (item.live ? 'live' : 'video'),
    });

    // NO LOCAL AUDIO WHILE CASTING: never open anything in mpv while a
    // cast session is connected — see [_castBlocksLocalAudio].
    if (_castBlocksLocalAudio) {
      // Captured BEFORE the divert: sending the item to the TV changes the
      // cast session's current item, which clears nextShowRecommendation
      // (see CastSkipController) before this call returns.
      final isPromotedShowRecommendation =
          nextShowRecommendation.value?.id == item.id;

      await _divertPlayToCast(item);

      // Same re-rooting the local path below does once a Next Show
      // recommendation actually starts — without it, casting that card's
      // "Play now" left the queue/episode list on the show that just ended.
      if (isPromotedShowRecommendation) {
        unawaited(_reRootQueueOnShow(item, _playbackToken));
      }
      return;
    }

    if (!resume) {
      item = item.copyWith(playbackPosition: Duration.zero);
    }

    // Captured before the state resets below (which unconditionally
    // clear nextShowRecommendation on every playMedia call) — see the
    // hook further down and _reRootQueueOnShow's doc comment for why
    // this matters.
    final isPromotedShowRecommendation =
        nextShowRecommendation.value?.id == item.id;

    // Downloaded movies/episodes keep their own, fully offline resume
    // point (see OfflineProgressStore) — separate from whatever
    // server-reported position the item already carries, since a
    // downloaded title can keep being watched with no network at all.
    // Applied via the same playbackPosition override MediaItem.copyWith
    // already exists for (see its REMOTE -> LOCAL cast-handoff doc
    // comment) — every resume-seek/"where does this open" check below
    // this point already keys off `item.playbackPosition` unmodified,
    // so nothing else needs to know this came from disk rather than the
    // server. Whichever position is further along wins, so this can
    // never regress progress the server happens to know about (e.g.
    // watched further on another device while last online).
    if (resume && DownloadManager.instance.isDownloaded(item.id)) {
      final localPosition = await OfflineProgressStore.getPosition(item.id);
      final existing = item.playbackPosition ?? Duration.zero;
      if (localPosition != null && localPosition > existing) {
        item = item.copyWith(playbackPosition: localPosition);
      }
    }

    // See _playbackToken's doc comment. Captured now and re-checked after
    // every await below, so a stale call that's been superseded by a
    // newer playMedia()/stop() bails out instead of clobbering state that
    // now belongs to whatever's actually current.
    final token = ++_playbackToken;

    nextEpisodeShown = false;
    // See [_nextUpArmed]: the next-up triggers stay off until a position
    // tick from this new item (not the previous file) is seen.
    _nextUpArmed = false;
    _nextUpStartPosition = item.playbackPosition ?? Duration.zero;
    showNextEpisode.value = false;
    nextEpisode.value = null;
    nextShowShown = false;
    showNextShow.value = false;
    nextShowRecommendation.value = null;
    nextMovieShown = false;
    showNextMovie.value = false;
    nextMovieRecommendation.value = null;
    playbackFinished.value = false;

    // The item now actually starting is the Next Show recommendation —
    // whether the person tapped Play Now on its card, or just let the
    // finished episode play out to a natural end and this is the
    // `queue.hasNext` auto-continue picking it up. Either way,
    // PlaybackQueue up to this point still only has this one item
    // tacked onto the *end* of the series that just finished (see
    // _reRootQueueOnShow's own doc comment for why that's deliberate),
    // so it needs re-rooting onto the recommended show's real season
    // now that this is genuinely playing. Unawaited: the season/
    // episode fetch this needs is irrelevant to starting playback
    // itself, so it shouldn't delay it.
    if (isPromotedShowRecommendation) {
      unawaited(_reRootQueueOnShow(item, token));
    }
    showEpisodeList.value = false;
    showChannelList.value = false;
    // Unlike the above, this wasn't reset here at all before — only
    // stop() cleared it. Every ordinary item transition (next,
    // previous, jump, auto-advance) goes through playMedia() instead of
    // stop(), so a Skip Intro/Credits pill still active the instant the
    // old item ended stayed set, and could paint for the new item until
    // the next position tick recomputed it from scratch (empty until
    // its own segments load) — a brief flash of the previous item's
    // skip button on top of whatever's now playing.
    activeSkipSegment.value = null;

    // Per-title quality state — the manual Quality-selector override in
    // particular is deliberately scoped to a single playback session
    // (see setVideoQuality's doc comment), so a fresh item always starts
    // back on "Auto"/whatever the app-wide Data Usage mode resolves to,
    // never carrying over the previous title's override.
    videoQuality.value = "Auto";
    _manualVideoOverride = null;
    _activeVideoLevel = null;
    _activeAudioStreamIndex = null;
    _activeAudioBitrateKbps = null;
    _musicPlaySessionId = null;
    _pendingAudioReapply = null;
    _pendingSubtitleReapply = null;
    _baselineNativeSubtitleIds = null;
    _subtitleUserOff = false;
    _autoSubtitleHandled = false;
    _cachedSubtitleCheckDone = false;
    _adaptiveQualityDebounce?.cancel();

    // A fresh item's first open is always a plain, unconstrained stream
    // (see the Auto-target resolution below) — position 0 really is
    // position 0, and duration hasn't been established yet.
    _streamPositionOffset = Duration.zero;
    _originalDuration = null;
    _audioStreamRecoveryAttempts = 0;
    _lastAbsoluteStreamPosition = Duration.zero;

    // Reset the queue-progress throttle too — otherwise a switch to a
    // new episode shortly after the last throttled push could sit for
    // up to _queueProgressUpdateInterval before EpisodeListPanel's
    // "now playing" row starts reflecting real position again.
    _lastQueueProgressUpdate = null;

    // A new item may have a completely different set of audio/subtitle
    // tracks (or none at all) — clear the previous item's before
    // _syncTracks repopulates them from the new file, so stale entries
    // (and a stale selection) never briefly show for the wrong title.
    castOnlySubtitles = false;
    audioTracks.value = const [];
    subtitles.value = const [];
    selectedAudio.value = null;
    selectedSubtitle.value = null;
    _ccAppliedTrackId = null;
    // mpv resets sub-delay per file on its own, but setting the
    // notifier explicitly keeps the UI in sync without waiting on a
    // round trip through the native property.
    subtitleDelay.value = Duration.zero;
    _stopOwnCues();

    debugPrint("--------------------------------");
    debugPrint("PLAY REQUEST");
    debugPrint("Type: ${item.audioOnly ? "Audio" : "Video"}");
    debugPrint("Title: ${item.title}");
    debugPrint("ID: ${item.id}");
    debugPrint("URL: ${item.streamUrl}");
    debugPrint("--------------------------------");


    // A stream is about to be opened, so a source has been chosen (starts the
    // logo fill by itself when no loading preview announced this load).
    if (!item.audioOnly) PlaybackLoadProgress.instance.opening();

    loading.value = true;
    lastError.value = null;

    currentItemNotifier.value = item;
    _precacheArtwork(item);

    // Real Intro/Outro timestamps for this specific file, fetched from
    // Jellyfin's Media Segments feature — see MediaService.getSkipSegments
    // and _loadSkipSegments's own doc comment for why this happens here
    // rather than synchronously as part of building the MediaItem.
    unawaited(_loadSkipSegments(item, token));

    // MediaSources/MediaStreams/Trickplay for this one item — see
    // _augmentWithPlaybackFields's doc comment for why this is fetched
    // here instead of upfront for the whole episode list.
    unawaited(_augmentWithPlaybackFields(item, token));

    // Feeds the auto-queue recommendation algorithm's session history —
    // harmless to call even when the setting is off, since it's just
    // bookkeeping a capped in-memory list until/unless it's ever read.
    MusicRecommendationService.instance.recordPlayed(item);

    if (item.live) {
      unawaited(_ensureLiveChannelsLoaded());
    }

    // Reset immediately rather than waiting on the next stream event —
    // without this, the seek bar (and mini player) could keep showing
    // the *previous* item's position/duration/buffer for a beat after
    // switching, since `player.stream.duration` in particular only
    // fires on a value change and may not refire right away for the new
    // item. Starting from a clean 0:00/0:00 is also just correct: the
    // new item genuinely hasn't started playing anything yet.
    position.value = Duration.zero;
    duration.value = Duration.zero;
    bufferedPosition.value = Duration.zero;

    isVideo.value = !item.audioOnly;

    // Resolves what "Auto" means right now (Data Saver/Default/Max
    // Quality — see AppSettings.PlaybackQualityMode) and computes the
    // actual URL to open. A brand-new item never starts with a manual
    // override (that's reset above), so this is always the app-wide
    // policy's own pick — the person can still override it for this one
    // title afterward via the Quality selector once playback starts.
    //
    // Local library tracks, files opened via Open With/Play With
    // (`item.isLocal`), AND downloaded items (which keep a real Jellyfin
    // id/`isLocal == false`, but DownloadManager.mediaItemFor already
    // points `streamUrl` at the on-disk file — see its own doc comment)
    // all have no meaningful server URL to build a quality-capped
    // variant of, so quality selection simply doesn't apply to any of
    // them, same as it never did before this feature existed. See
    // _isOfflineFile.
    final isOfflineFile = _isOfflineFile(item);

    String urlToOpen;

    if (isOfflineFile) {
      urlToOpen = item.streamUrl;
    } else if (item.audioOnly) {
      final target = _autoAudioTarget(item);
      _activeAudioBitrateKbps = target;
      _musicPlaySessionId =
          '${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}'
          '${item.id.hashCode.toUnsigned(32).toRadixString(16)}';
      debugPrint(
        "MUSIC STREAM: '${item.title}' "
        "mode=${AppSettings.playbackQualityMode.value.name} "
        "source=${_audioSourceKbps(item) ?? 'unknown'}kbps "
        "cap=${target == null ? 'none (original)' : '${target}kbps'}",
      );
      urlToOpen = _resolveAudioUrl(item, target);
    } else {
      _recomputeVideoQualityOptions();
      final target = _autoVideoTarget(item);
      _activeVideoLevel = target;

      // A constrained target AND a saved resume position means this
      // item's first-ever open is already a live transcode that needs
      // to start somewhere other than 0:00 — same situation as a
      // quality-change reopen, and the same fix applies: bake the
      // resume point in as StartTimeTicks up front rather than
      // seeking into the transcode afterward (see getVideoStreamUrl's
      // doc comment, and the resume-seek block below for why that
      // matters here specifically).
      final resumeAt = item.playbackPosition;
      _streamPositionOffset = (target != null &&
              resumeAt != null &&
              resumeAt > Duration.zero)
          ? resumeAt
          : Duration.zero;

      urlToOpen = _resolveVideoUrl(
        item,
        target,
        startAt: _streamPositionOffset > Duration.zero
            ? _streamPositionOffset
            : null,
      );
    }

    if (!isOfflineFile) {
      _ensureNetworkMonitoring(item);
    }

    try {
      PlaybackProgressService.start(
        item.id,
        isOffline: isOfflineFile,
        // Only server-streamed songs carry a session id (the same one
        // that is on their transcode URL); everything else reports
        // exactly as before.
        playSessionId: (!isOfflineFile && item.audioOnly)
            ? _musicPlaySessionId
            : null,
        playMethod: (!isOfflineFile && item.audioOnly)
            ? (_activeAudioBitrateKbps != null ? 'Transcode' : 'DirectPlay')
            : null,
      );
      await PlaybackProgressService.playbackStart();

      // Independent, fully local progress tracking — only for actual
      // downloads (see OfflineProgressService's own doc comment for
      // why this runs alongside, not instead of, the server report
      // above).
      if (DownloadManager.instance.isDownloaded(item.id)) {
        OfflineProgressService.start(item.id, item.runtime);
      } else {
        OfflineProgressService.stop();
      }

      // Pre-buffer only a server-transcoded song (a capped bitrate);
      // everything else plays on mpv's normal defaults. See
      // _setAudioPrebuffer.
      await _setAudioPrebuffer(
        !isOfflineFile && item.audioOnly && _activeAudioBitrateKbps != null,
      );

      await _prepareClosedCaptionOption(item);
      await _applyNetworkTimeout(item);
      await player.open(
        Media(urlToOpen, httpHeaders: _addonHeaders(item)),
        play: true,
      );
      if (item.raw?['AddonStream'] == true) {
        _armOpenWatchdog(item, token);
        _armBlackVideoCheck(item, token);
      }

      // Bail out without touching any further state if a newer
      // playMedia()/stop() call has started while we were awaiting
      // open() above — that newer call already owns currentItemNotifier/
      // loading/etc. now, and this one finishing late shouldn't stomp on
      // it (e.g. this item's stream took a while to open and the user
      // has since backed out and started something else).
      if (token != _playbackToken) return;

      // The stream answered and is open: a real milestone for the loading
      // logo's fill.
      if (!item.audioOnly) PlaybackLoadProgress.instance.opened();

      // BUGFIX (Open With/Play With sidecar subtitle didn't render until
      // manually re-picked): this used to fire *before* `player.open()`
      // above, racing it — `sub-add`ing a subtitle to a player that
      // hadn't actually opened a file yet was silently dropped by mpv,
      // so the sheet's checkmark showed a track as selected
      // (`selectedSubtitle.value` was still set optimistically) while
      // nothing was really loaded, and only tapping it again — now that
      // the player was genuinely open — actually worked. Awaiting
      // `player.open()` first guarantees mpv has a file open and is
      // ready to accept `sub-add` before this ever runs.
      unawaited(_applyCachedThenDefaultSubtitle(item, token));

      // Live streams don't have a fixed duration to resolve (mpv
      // reports whatever's been buffered so far for a continuously-
      // growing stream, which may never "settle"), and they don't
      // support resuming to a saved position — waiting here would just
      // delay every channel switch for no benefit. `duration.value`
      // still updates naturally via the stream listener as data comes
      // in; the live seek bar tracks its own high-water mark from
      // position/buffer instead of relying on this being accurate.
      if (!item.live) {
        // Always resolve the real duration up front for VOD — win or
        // lose a resume seek, the seek bar's right-hand total needs
        // this to be correct as soon as it's knowable, not whenever
        // `player.stream.duration` next happens to fire.
        final resolvedDuration = await _waitForDuration(item);
        unawaited(_loadChapterSegments(item, token, resolvedDuration));
        // Get the seek-preview reader ready before anyone drags the bar.
        if (FrameGrabber.supports(item)) {
          unawaited(Future<void>.delayed(const Duration(seconds: 6), () {
            if (token == _playbackToken && currentItem?.id == item.id) {
              FrameGrabber.instance
                  .prewarm(item, duration.value > Duration.zero
                      ? duration.value
                      : resolvedDuration);
            }
          }));
        }

        if (item.playbackPosition != null &&
            item.playbackPosition! > Duration.zero &&
            resolvedDuration > Duration.zero) {
          // If this item's very first open already started as a
          // capped-quality transcode (Data Saver mode, or Default mode
          // resolving Auto to something less than Original from the
          // start — see the `_streamPositionOffset` setup above), the
          // resume position is already baked into the URL as
          // StartTimeTicks, and this stream's position 0 genuinely IS
          // the resume point — seeking again here would be the same
          // risky "seek into a live transcode via HTTP Range"
          // operation that quality-change reopens avoid for exactly
          // this reason (see getVideoStreamUrl's doc comment). Only
          // actually seek when this is the plain, unconstrained static
          // file, where a normal Range-backed seek has always worked.
          if (_streamPositionOffset == Duration.zero) {
            // Seeking right after open() doesn't work reliably — at that
            // point the player has only just been told what to open; it
            // hasn't necessarily parsed the stream far enough to know its
            // duration or seek points yet, so an immediate seek() call
            // was being silently dropped and playback always started
            // from 0 despite "Resume" being tapped. _waitForDuration()
            // above guarantees the stream is far enough along before we
            // get here.
            await player.seek(item.playbackPosition!);

            // Same supersession check as above, now that we've awaited
            // seek() too.
            if (token != _playbackToken) return;
          }

          // Set this explicitly instead of waiting for
          // `player.stream.position` to catch up — otherwise the seek
          // bar could briefly show 0:00 (or the pre-seek position) even
          // though playback has already jumped to the resume point.
          position.value = item.playbackPosition!;
        }
      }

      // Deliberately not touching showMiniPlayer here. If it's already
      // true (mini player was already showing, user just tapped another
      // track), it stays true. If it's false (fresh playback, nothing
      // was playing before), it stays false so the mini player doesn't
      // flash in underneath the full player screen the caller is about
      // to push — it only turns on when AudioPlayerScreen is exited
      // (see its dispose()).

      // `loading` is deliberately NOT cleared here on success — this
      // point is only "player.open() resolved and, for VOD, duration/
      // resume-seek settled", which regularly lands well before the
      // native player actually has a first frame ready to show. Clearing
      // it here dropped the loading overlay's backdrop+logo for a beat
      // before real playback appeared (and before BufferingOverlay's
      // own backdrop-less logo picked back up), which is what looked
      // like the backdrop/logo "vanishing and reappearing". The
      // `player.stream.playing` listener above already clears `loading`
      // the moment real playback genuinely starts for this item, which
      // is the right thing to gate it on. The safety-net timer below
      // only exists in case that stream event never arrives.
      unawaited(Future.delayed(const Duration(seconds: 10), () async {
        if (token != _playbackToken) return;
        if (currentItemNotifier.value?.id != item.id) return;
        // Already cleared by the `playing` handler: nothing left to do.
        if (!loading.value) return;
        // NAMESIS PRIME: a slow source (torrent, far server) can need far
        // more than 10 s before it is really playing. Dropping the loading
        // screen at a fixed 10 s showed a frozen picture (or plain black)
        // until playback began, so for video this keeps waiting (bounded)
        // until a picture exists and the position is genuinely moving.
        if (!item.audioOnly && !item.live) {
          final torrent = item.raw?['IsTorrent'] == true;
          await _waitForRealPlayback(
            item,
            frameTimeout: Duration(seconds: torrent ? 240 : 80),
            progressTimeout: Duration(seconds: torrent ? 120 : 45),
          );
        }
        if (token == _playbackToken && currentItemNotifier.value?.id == item.id) {
          loading.value = false;
        }
      }));
    } catch (error) {
      debugPrint("PLAYBACK ERROR: $error");

      // If a newer request has already superseded this one, let it own
      // the error/loading state instead of stomping on it here.
      if (token != _playbackToken) return;

      // Another link may be lined up (auto link selection): switch to it on
      // the same loading screen instead of giving up.
      if (await _tryOpenFailureRecovery(item, '$error')) return;
      if (token != _playbackToken) return;

      lastError.value =
      "Couldn't start playback. Please check your connection and try again.";

      currentItemNotifier.value = null;
      showMiniPlayer.value = false;
      loading.value = false;
    }
  }

  Future<void> playQueue(
      List<MediaItem> items, {
        int startIndex = 0,
        PlaybackSource source = PlaybackSource.unknown,
        String? title,
        String? artwork,
      }) async {
    // A brand-new, person-initiated queue — reset the recommendation
    // history so auto-queued continuations stay tied to *this* listening
    // session instead of blending in whatever played last time.
    MusicRecommendationService.instance.resetHistory();

    PlaybackQueue.instance.setQueue(
      items,
      startIndex: startIndex,
      source: source,
      title: title,
      artwork: artwork,
    );

    await playMedia(items[startIndex]);
  }

  Future<void> playNext() async {

    showNextEpisode.value = false;

    nextEpisode.value = null;

    final item = PlaybackQueue.instance.next();

    if (item == null) {
      // An addon episode with nothing lined up (yet): find the next one.
      if (isAddonEpisode(currentItem)) await _playSiblingEpisode(1);
      return;
    }

    await playMedia(item, resume: !item.audioOnly);
  }

  /// An episode played through the person's addons (as opposed to a
  /// Jellyfin one). These have no real season queue, so Next / Previous work
  /// out the neighbouring episode from the show's season list.
  static bool isAddonEpisode(MediaItem? i) {
    if (i == null) return false;
    final raw = i.raw;
    return raw != null &&
        raw['AddonStream'] == true &&
        raw['Type'] == 'Episode' &&
        i.seasonNumber != null &&
        i.episodeNumber != null;
  }

  bool _siblingBusy = false;

  /// Plays the episode [delta] (+1 / -1) away from the current addon
  /// episode, using the same stream preference as auto-play.
  Future<void> _playSiblingEpisode(int delta) async {
    if (_siblingBusy) return;
    final current = currentItem;
    if (!isAddonEpisode(current)) return;
    final snapshot = TitleSnapshot.fromJson(current!.raw?['NamesisTitle']);
    final episode = episodeFromRaw(current.raw?['NamesisEpisode']);
    if (snapshot == null || episode == null) return;

    _siblingBusy = true;
    final id = current.id;
    try {
      final title = snapshot.toTitle();
      final target = delta > 0
          ? await NextEpisodeService.findNext(title, episode)
          : await NextEpisodeService.findPrevious(title, episode);
      if (target == null) return;

      final stream = await NextEpisodeService.resolveStream(title, target);
      if (stream == null) return;

      final built = await CatalogPlayback.buildItemResolved(
        title: title,
        stream: stream,
        episode: target,
      );

      // The person may have moved on while this was being looked up.
      if (currentItem?.id != id) return;

      await PlaybackService.playQueue([built], source: PlaybackSource.season);
    } catch (e) {
      debugPrint('[PlayerManager] sibling episode failed: $e');
    } finally {
      _siblingBusy = false;
    }
  }


  /// How far into a track "Previous" still counts as "just started" —
  /// past this, pressing Previous restarts the current track instead of
  /// jumping to the prior one in the queue. Matches the convention
  /// virtually every media player (Spotify, Apple Music, YouTube Music,
  /// the stock Android/iOS transport controls) uses for its Previous
  /// button.
  static const Duration _previousRestartThreshold = Duration(seconds: 3);

  /// Previous-track transport control. Every Previous entry point in the
  /// app — the Now Playing screen's transport bar and the OS
  /// notification/lock-screen widget (via
  /// NemesisAudioHandler.skipToPrevious) — funnels through this one
  /// method with [skipRestartThreshold] left at its default, so the
  /// behavior below is shared everywhere rather than needing to be
  /// duplicated (and kept in sync) at each call site.
  ///
  /// If the current track has already played past
  /// [_previousRestartThreshold], Previous restarts it from zero rather
  /// than jumping back a track — otherwise a few seconds into song 2,
  /// tapping Previous once would skip straight past song 2 entirely
  /// instead of just going back to its start.
  ///
  /// Once actually within that opening window (or there's nothing
  /// earlier to go back to — first track in the queue, or a single
  /// standalone item), behaves as normal: loads the earlier item via
  /// playMedia (same as playNext), or restarts the current track if
  /// there isn't an earlier one — the button always does *something*
  /// rather than silently no-op'ing.
  ///
  /// [skipRestartThreshold] bypasses the restart check above entirely
  /// and always jumps to the earlier queue item, regardless of how far
  /// into the current track playback is. The mini player's
  /// swipe-to-previous gesture passes this — a deliberate slide is
  /// already a more committed action than a single tap on a small
  /// transport button, and re-landing on the current track's start
  /// instead of the previous song made the gesture feel like it hadn't
  /// registered.
  Future<void> playPrevious({bool skipRestartThreshold = false}) async {
    if (!skipRestartThreshold &&
        position.value > _previousRestartThreshold) {
      await player.seek(Duration.zero);

      if (!playing.value) {
        await player.play();
      }

      return;
    }

    final item = PlaybackQueue.instance.previous();

    if (item == null && isAddonEpisode(currentItem) && hasPrevious) {
      await _playSiblingEpisode(-1);
      return;
    }

    if (item == null) {
      await player.seek(Duration.zero);

      if (!playing.value) {
        await player.play();
      }

      return;
    }

    await playMedia(item, resume: !item.audioOnly);
  }

  bool get hasNext =>
      PlaybackQueue.instance.hasNext || isAddonEpisode(currentItem);

  bool get hasPrevious {
    if (PlaybackQueue.instance.hasPrevious) return true;
    final i = currentItem;
    // An addon episode has a previous one unless it is the very first.
    return isAddonEpisode(i) &&
        !((i!.seasonNumber ?? 0) <= 1 && (i.episodeNumber ?? 0) <= 1);
  }

  /// Fetches the full channel lineup once per session (skipped if
  /// already loaded or already in flight) so the center controls'
  /// previous/next-channel buttons have something to work from even if
  /// the user never opens the channel list panel.
  Future<void> _ensureLiveChannelsLoaded() async {
    if (liveChannels.value.isNotEmpty || _loadingLiveChannels) return;

    _loadingLiveChannels = true;
    try {
      final channels = await MediaService.getLiveTvChannels();
      liveChannels.value = channels
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    } catch (_) {
      // Leave empty — the skip buttons just stay disabled until a
      // successful load (e.g. the channel list panel gets opened,
      // which populates this cache too).
    } finally {
      _loadingLiveChannels = false;
    }
  }

  int get _currentChannelIndex {
    final id = currentItem?.id;
    if (id == null) return -1;

    return liveChannels.value.indexWhere(
      (channel) => channel["Id"]?.toString() == id,
    );
  }

  bool get hasNextChannel {
    final index = _currentChannelIndex;
    return index != -1 && index < liveChannels.value.length - 1;
  }

  bool get hasPreviousChannel {
    final index = _currentChannelIndex;
    return index > 0;
  }

  Future<void> playNextChannel() async {
    final index = _currentChannelIndex;
    if (index == -1 || index >= liveChannels.value.length - 1) return;

    final media = MediaService.mediaItemFromJellyfin(
      liveChannels.value[index + 1],
    );

    showLoadingPreview(media);
    await playMedia(media);
  }

  Future<void> playPreviousChannel() async {
    final index = _currentChannelIndex;
    if (index <= 0) return;

    final media = MediaService.mediaItemFromJellyfin(
      liveChannels.value[index - 1],
    );

    showLoadingPreview(media);
    await playMedia(media);
  }

  /// NAMESIS PRIME: closes the player screen after a failed open and shows
  /// a short explanation. See the `player.stream.error` listener.
  bool _abortingOpen = false;

  /// Set by LinkFallbackCoordinator while an auto-selected addon stream has
  /// other links to try. Called when an addon stream failed to open; true
  /// means the next link was started and the player screen must stay open.
  Future<bool> Function(MediaItem failed, String reason)? openFailureRecovery;

  Future<bool> _tryOpenFailureRecovery(MediaItem? failed, String reason) async {
    final recover = openFailureRecovery;
    if (recover == null || failed == null) return false;
    if (failed.raw?['AddonStream'] != true || failed.audioOnly == true) {
      return false;
    }
    try {
      return await recover(failed, reason);
    } catch (e) {
      debugPrint('[PlayerManager] link fallback failed: $e');
      return false;
    }
  }

  Future<void> _abortFailedOpen(String message) async {
    if (_abortingOpen) return;
    _abortingOpen = true;
    final failed = currentItem;
    try {
      // Another link may be lined up (auto link selection): switch to it on
      // the same loading screen instead of closing.
      if (await _tryOpenFailureRecovery(failed, message)) return;

      // Close the black loading screen straight away...
      loading.value = false;
      _audioSwitchStalled = false;
      buffering.value = false;
      playbackFinished.value = false;
      playbackFinished.value = true;

      // ...then work out why, so the message says something useful.
      var reason = "Couldn't open this stream.";
      if (failed != null && failed.raw?['IsTorrent'] == true) {
        reason = 'The torrent is not delivering data yet (few or no peers). '
            'Try another source, ideally one with more seeders.';
      } else if (failed != null) {
        try {
          reason = await _diagnoseStream(failed);
        } catch (_) {}
      }
      debugPrint('STREAM OPEN FAILED ($message): $reason');

      final ctx = ExternalMediaHandler
          .instance.navigatorKey.currentState?.overlay?.context;
      if (ctx != null) {
        ScaffoldMessenger.maybeOf(ctx)?.showSnackBar(
          SnackBar(
            content: Text(reason),
            duration: const Duration(seconds: 9),
          ),
        );
      }
    } catch (_) {
    } finally {
      _abortingOpen = false;
    }
  }

  /// Probes the stream URL the way a browser would (DNS, then a 2-byte
  /// ranged GET) and returns a plain-language reason it could not be opened.
  Future<String> _diagnoseStream(MediaItem item) async {
    final uri = Uri.tryParse(item.streamUrl);
    if (uri == null || uri.host.isEmpty) {
      return 'The stream address is not valid.';
    }
    final host = uri.host;

    try {
      final found = await InternetAddress.lookup(host)
          .timeout(const Duration(seconds: 8));
      if (found.isEmpty) {
        return 'Your network could not find $host (DNS).';
      }
    } on SocketException {
      return 'Your network could not look up $host (DNS problem). '
          'Try setting Windows DNS to 1.1.1.1 and 8.8.8.8, then try again.';
    } on TimeoutException {
      return 'Looking up $host timed out (slow DNS). '
          'Try setting Windows DNS to 1.1.1.1 and 8.8.8.8.';
    } catch (_) {}

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await client
          .getUrl(uri)
          .timeout(const Duration(seconds: 12));
      req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-1');
      final extra = _addonHeaders(item);
      if (extra != null) {
        extra.forEach((k, v) => req.headers.set(k, v));
      }
      final resp = await req.close().timeout(const Duration(seconds: 15));
      final code = resp.statusCode;
      if (code == 200 || code == 206) {
        return 'The server answered, but the video could not be opened or '
            'decoded here. The file format or codec may not be supported.';
      }
      if (code == 401 || code == 403) {
        return 'The server refused access (HTTP $code). The link may have '
            'expired, or it needs special headers.';
      }
      if (code == 404 || code == 410) {
        return 'The file was not found (HTTP $code). The link may have '
            'expired. Try another source.';
      }
      if (code >= 500) {
        return 'The source server had an error (HTTP $code). This usually '
            'means the link provider could not prepare the file right '
            'now. Try again in a moment, or pick another source.';
      }
      return 'The server answered with HTTP $code. Try another source.';
    } on HandshakeException {
      return 'A secure connection to $host could not be made (TLS error).';
    } on SocketException {
      return 'Could not connect to $host. The source may be offline or '
          'blocked on your network.';
    } on TimeoutException {
      return '$host took too long to respond. Try another source.';
    } catch (_) {
      return "Couldn't open this stream. Try another source.";
    } finally {
      client.close(force: true);
    }
  }

  /// media_kit starts mpv with `network-timeout=5`: any read that stalls for
  /// 5 seconds is treated as a dead connection. That is fine for a Jellyfin
  /// server on the same network, but a direct link (debrid / hoster / CDN) is
  /// often slow to answer: redirects, a TLS handshake to a far-away host, a
  /// link the provider has to prepare first, or an MKV whose index sits at the
  /// end of the file. Those streams failed with a timeout before the first
  /// byte arrived. Torrents already got a long timeout; direct links now get a
  /// normal one, and everything else keeps whatever mpv started with.
  String? _baseNetworkTimeout;

  Future<void> _applyNetworkTimeout(MediaItem item) async {
    try {
      final p = player.platform;
      if (p is! NativePlayer) return;

      if (_baseNetworkTimeout == null) {
        String? base;
        try {
          base = await p.getProperty('network-timeout');
        } catch (_) {}
        _baseNetworkTimeout = (base == null || base.isEmpty) ? '5' : base;
      }

      final String seconds;
      if (item.raw?['IsTorrent'] == true) {
        // The torrent engine holds the connection while it buffers.
        seconds = '240';
      } else if (item.raw?['AddonStream'] == true) {
        seconds = '60';
      } else {
        seconds = _baseNetworkTimeout!;
      }
      await p.setProperty('network-timeout', seconds);
    } catch (_) {}
  }

  /// media_kit raises `player.stream.error` for ANY error-level mpv log line
  /// (a hardware decoder that could not start and falls back to software, an
  /// audio codec that is skipped, a connection that is re-opened...), not
  /// only for a stream that cannot be opened. Closing the player on the first
  /// one killed streams that were about to play. An error now only closes the
  /// player when, a moment later, mpv has really gone idle (nothing is
  /// loaded any more, i.e. the open failed); a stream that is still loaded
  /// keeps going, and the open watchdog still catches one that never starts.
  Timer? _openFailureTimer;

  void _scheduleOpenFailureCheck(MediaItem item, String message) {
    final token = _playbackToken;
    _openFailureTimer?.cancel();
    _openFailureTimer = Timer(const Duration(seconds: 3), () async {
      if (token != _playbackToken) return;
      if (currentItem?.id != item.id) return;
      if (!loading.value) return;

      var failed = true;
      try {
        final p = player.platform;
        if (p is NativePlayer) {
          failed = (await p.getProperty('idle-active')).trim() == 'yes';
        }
      } catch (_) {}

      if (!failed) {
        debugPrint('PLAYER ERROR ignored, stream is still loaded: $message');
        return;
      }
      if (token != _playbackToken) return;
      if (currentItem?.id != item.id) return;
      if (!loading.value) return;
      unawaited(_abortFailedOpen(message));
    });
  }

  /// The headers the main player sends for [item]; the seek-preview reader
  /// must send the same ones or the provider treats it as a different client.
  Map<String, String>? addonHeaders(MediaItem item) => _addonHeaders(item);

  /// Request headers an addon asked for (`behaviorHints.proxyHeaders`),
  /// stored on the item by CatalogPlayback.
  Map<String, String>? _addonHeaders(MediaItem item) {
    final h = item.raw?['HttpHeaders'];
    final headers = <String, String>{
      if (h is Map)
        for (final e in h.entries) e.key.toString(): e.value.toString(),
    };

    // Direct links (debrid / hoster resolvers, CDNs) are often fronted by
    // firewalls that answer mpv's default "libmpv"/"Lavf" agent, or the
    // Dart agent the failure probe used, with a 4xx/5xx while a normal
    // browser is served fine. Send a browser agent unless the addon
    // asked for a specific one. (ffmpeg skips its own agent when the
    // headers already carry one.) Torrent streams are served by the
    // local engine and need nothing.
    final isDirect = item.raw?['AddonStream'] == true &&
        item.raw?['IsTorrent'] != true;
    final hasAgent =
        headers.keys.any((k) => k.toLowerCase() == 'user-agent');
    if (isDirect && !hasAgent) {
      headers['User-Agent'] = _browserUserAgent;
    }

    return headers.isEmpty ? null : headers;
  }

  static const String _browserUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

  /// If an addon stream is still "loading" a minute after open(), give up
  /// and say why instead of leaving a black screen up forever.
  void _armOpenWatchdog(MediaItem item, int token) {
    // Torrents need longer: the engine must find peers and buffer first.
    final wait = item.raw?['IsTorrent'] == true ? 240 : 60;
    Future<void>.delayed(Duration(seconds: wait), () {
      if (token != _playbackToken) return;
      if (currentItem?.id != item.id) return;
      if (!loading.value) return;
      // A picture exists: the stream did open and is only still filling its
      // buffer. _waitForRealPlayback has its own bound for that phase, so
      // this must not abort a stream that is about to start.
      if ((player.state.width ?? 0) > 0) return;
      unawaited(_abortFailedOpen('open timed out'));
    });
  }

  bool _softwareDecodeFallbackUsed = false;

  /// Audio playing but no picture 20s in usually means the GPU decoder
  /// can't handle this file (e.g. 10-bit HEVC). Switch mpv to software
  /// decoding once and nudge it to re-open the decoder.
  void _armBlackVideoCheck(MediaItem item, int token) {
    Future<void>.delayed(const Duration(seconds: 20), () async {
      if (token != _playbackToken) return;
      if (currentItem?.id != item.id) return;
      if (_softwareDecodeFallbackUsed) return;
      final s = player.state;
      if (!s.playing || s.buffering) return;
      if ((s.width ?? 0) > 0) return;
      try {
        final platform = player.platform;
        if (platform is NativePlayer) {
          _softwareDecodeFallbackUsed = true;
          debugPrint('NO VIDEO after 20s - switching to software decoding');
          await platform.setProperty('hwdec', 'no');
          await player.seek(s.position);
        }
      } catch (e) {
        debugPrint('Software decode fallback failed: $e');
      }
    });
  }

  /// Fully stops playback and resets player state. Used when the user
  /// backs out of the video player — there's no mini-player for video
  /// (MiniPlayer hides itself whenever `isVideo` is true), so unlike
  /// audio, leaving the screen should stop the stream rather than let it
  /// keep running invisibly in the background.
  Future<void> stop() async {
    FrameGrabber.instance.release();
    // See _playbackToken's doc comment. This is the call this token
    // scheme exists for: stop() is fired, unawaited, from
    // VideoPlayerScreen.dispose() whenever the player screen goes away —
    // if the user immediately starts a new title before this finishes
    // awaiting the report + player.stop() below, this check stops it
    // from wiping out the new title's currentItemNotifier/loading once
    // it finally does resolve.
    final token = ++_playbackToken;

    final position = player.state.position;
    final stoppingItem = currentItem;

    // playbackStopped() posts the "Sessions/Playing/Stopped" report to the
    // server and then clears PlaybackProgressService's tracked item id
    // itself — it must run first, or there'd be no item id left to report
    // against.
    if (currentItem != null) {
      await PlaybackProgressService.playbackStopped(position);
    } else {
      PlaybackProgressService.stop();
    }

    // Same "save then stop" shape, purely local — only when the item
    // that's stopping is actually a download (see playMedia()'s own
    // start/stop calls for why this is gated the same way there).
    if (stoppingItem != null &&
        DownloadManager.instance.isDownloaded(stoppingItem.id)) {
      await OfflineProgressService.saveAndStop(position);
    } else {
      OfflineProgressService.stop();
    }

    await player.stop();

    if (token != _playbackToken) return;

    currentItemNotifier.value = null;
    showMiniPlayer.value = false;
    loading.value = false;
    _audioSwitchStalled = false;
    buffering.value = false;
    showNextEpisode.value = false;
    nextEpisode.value = null;
    showNextShow.value = false;
    nextShowRecommendation.value = null;
    showNextMovie.value = false;
    nextMovieRecommendation.value = null;
    playbackFinished.value = false;
    showEpisodeList.value = false;
    showChannelList.value = false;
    activeSkipSegment.value = null;
    nextEpisodeShown = false;
    nextShowShown = false;
    nextMovieShown = false;
    isLocked.value = false;
    videoFit.value = BoxFit.contain;
    audioTracks.value = const [];
    subtitles.value = const [];
    selectedAudio.value = null;
    selectedSubtitle.value = null;
    _subtitleUserOff = false;
    _autoSubtitleHandled = false;
    _cachedSubtitleCheckDone = false;

    // Per the in-player Quality selector's own scope: any manual
    // override made during this session ends here, right along with the
    // rest of the playback state — the next title always starts back on
    // whatever AppSettings.playbackQualityMode resolves "Auto" to.
    videoQuality.value = "Auto";
    videoQualityOptions.value = const [];
    _manualVideoOverride = null;
    _activeVideoLevel = null;
    _activeAudioStreamIndex = null;
    _activeAudioBitrateKbps = null;
    _musicPlaySessionId = null;
    _pendingAudioReapply = null;
    _pendingSubtitleReapply = null;
    _adaptiveQualityDebounce?.cancel();
    _streamPositionOffset = Duration.zero;
    _originalDuration = null;
    _audioStreamRecoveryAttempts = 0;
    _lastAbsoluteStreamPosition = Duration.zero;

    if (_networkMonitoringActive) {
      _networkMonitoringActive = false;
      NetworkQualityService.instance.setProbeUrl(null);
      NetworkQualityService.instance.release();
    }

    PlaybackQueue.instance.clear();
  }
}

/// One subtitle cue (own renderer, see PlayerManager._ownCues).
class _OwnCue {
  final int startMs;
  final int endMs;
  final String text;
  const _OwnCue(this.startMs, this.endMs, this.text);
}
