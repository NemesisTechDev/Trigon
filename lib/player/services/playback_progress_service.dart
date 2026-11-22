import 'dart:async';

import '../../services/jellyfin_services/jellyfin_client.dart';
import '../player_manager.dart';

class PlaybackProgressService {
  PlaybackProgressService._();

  static Timer? _timer;

  static String? _itemId;

  static bool _reportedFinished = false;

  // ROOT CAUSE FIX (Downloads / On This Device / Open With-Play With
  // failing to play at all with no internet connection): this class
  // reports playback start/progress/stop to Jellyfin's `/Sessions/Playing*`
  // endpoints, which is meaningless for offline content — an Open
  // With/Play With file's `itemId` is a locally made-up string that
  // doesn't exist on any server, and a downloaded item's still-real id
  // has nothing to report to when there's no network. Every one of
  // these three call sites used to hit the network unconditionally and
  // unguarded; `playbackStart()` in particular is `await`ed directly in
  // PlayerManager.playMedia()'s try block, *before* `player.open()` —
  // so the DioException a connectionless device throws there propagated
  // straight out and aborted the whole try block, and `player.open()`
  // was never reached at all. That's what made every one of these
  // offline-capable playback paths fail outright the instant there was
  // no connection, even though the actual media being played needed
  // none. `_isOffline` (set by PlayerManager.playMedia() via the same
  // `_isOfflineFile` check it already uses to skip quality-URL
  // resolution for these exact items) skips the network calls
  // entirely for them, and the try/catch below is a second, independent
  // safety net for the remaining case — a normal server-backed item
  // whose connection genuinely drops mid-playback — so a failure here
  // can never again block or kill playback.
  static bool _isOffline = false;

  // Identifies this playback to Jellyfin. For a server-transcoded song the
  // SAME id is also put on the stream URL (see
  // MediaService.getAudioMp3TranscodeUrl), which is how the server links
  // these start/progress/stop reports to the transcoding job producing
  // the audio — it uses them to decide when to pause the encoder, when
  // to resume it, and whether the job is still wanted. Reports that
  // carry no id can't be linked to the job at all. Null for everything
  // that doesn't transcode (reports then look exactly as they always did).
  static String? _playSessionId;

  // "Transcode" / "DirectPlay" when known, so the server's dashboard and
  // transcoding bookkeeping describe the stream correctly.
  static String? _playMethod;

  static Map<String, dynamic> _sessionFields() => {
        if (_playSessionId != null) "PlaySessionId": _playSessionId,
        if (_playMethod != null) "PlayMethod": _playMethod,
      };

  static void start(
    String itemId, {
    bool isOffline = false,
    String? playSessionId,
    String? playMethod,
  }) {
    stop();

    _reportedFinished = false;

    _itemId = itemId;
    _isOffline = isOffline;
    _playSessionId = playSessionId;
    _playMethod = playMethod;

    // Nothing to poll the server for on an item with no real session —
    // see the doc comment above.
    if (_isOffline) return;

    _timer = Timer.periodic(
      const Duration(seconds: 5),
          (_) {
        final position =
            PlayerManager.instance.player.state.position;

        playbackProgress(position);
      },
    );
  }

  static void stop() {
    _timer?.cancel();
    _timer = null;
    _itemId = null;
    _isOffline = false;
    _playSessionId = null;
    _playMethod = null;
  }

  static bool get reportedFinished => _reportedFinished;

  static void markFinished() {
    _reportedFinished = true;
  }

  static Future<void> playbackStart() async {
    if (_itemId == null || _isOffline) return;

    try {
      await JellyfinClient.dio.post(
        "/Sessions/Playing",
        data: {
          "ItemId": _itemId,
          ..._sessionFields(),
        },
      );
    } catch (_) {
      // Best-effort session report — see the doc comment on _isOffline
      // above. Must never be allowed to block or kill playback.
    }
  }

  static Future<void> playbackProgress(
      Duration position,
      ) async {

    if (_itemId == null || _isOffline) return;

    try {
      await JellyfinClient.dio.post(
        "/Sessions/Playing/Progress",
        data: {
          "ItemId": _itemId,
          "PositionTicks":
          position.inMicroseconds * 10,
          "IsPaused": false,
          ..._sessionFields(),
        },
      );
    } catch (_) {
      // Best-effort — see playbackStart's doc comment. Firing every 5s
      // while playing, so this matters even more here: without the
      // guard, a connection that drops mid-playback would throw an
      // unhandled exception on every single tick for the rest of the
      // session.
    }
  }

  static Future<void> playbackStopped(
      Duration position,
      ) async {

    if (_itemId == null) return;

    if (!_isOffline) {
      try {
        await JellyfinClient.dio.post(
          "/Sessions/Playing/Stopped",
          data: {
            "ItemId": _itemId,
            "PositionTicks":
            position.inMicroseconds * 10,
            ..._sessionFields(),
          },
        );
      } catch (_) {
        // Best-effort — see playbackStart's doc comment. Previously an
        // unguarded throw here would also skip the stop() call below,
        // leaving the (already-cancelled-server-side-anyway) timer
        // state dangling.
      }
    }

    stop();
  }
}
