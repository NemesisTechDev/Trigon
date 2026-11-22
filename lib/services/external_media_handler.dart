import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../player/models/media_item.dart';
import '../player/player_manager.dart';
import '../player/playback_service.dart';
import '../player/screens/audio_player_screen.dart';
import '../player/screens/player_navigation.dart';
import '../player/screens/player_screen_registry.dart';
import '../player/services/playback_queue.dart';
import 'download_manager.dart';
import 'jellyfin_services/storage_service.dart';
import 'sidecar_subtitles.dart';

/// Wires up Android's "Open With" / "Play With" support: when the OS
/// hands Nemesis a local audio or video file directly (see the
/// ACTION_VIEW intent-filter in AndroidManifest.xml and the matching
/// MethodChannel set up in MainActivity.kt), this builds a MediaItem for
/// it and starts playback exactly like tapping any other song/video in
/// the app.
///
/// Deliberately routed through the exact same single-item queue every
/// other "just play this one thing" call site already uses (see
/// PlaybackService.playItem/playQueue) rather than a bespoke path — that
/// queue-of-one is what makes next/previous naturally no-ops, what makes
/// playback stop cleanly the moment the file ends (PlayerManager's
/// `completed` handler has nothing left in the queue to advance to), and
/// what makes the player screen close itself back into the app instead
/// of sitting on a frozen last frame (video) or dangling silently (audio)
/// — see VideoPlayerScreen's playbackFinished listener and
/// AudioPlayerScreen's `_exitIfQueueEnded`, both already built for this.
///
/// The MediaItem's `raw` map deliberately mirrors LocalMusicService's own
/// on-device-song shape (`IsLocal: true`, plus `LocalUri`/`ArtworkPath`/
/// `UserData` etc.) — every piece of shared UI that already knows how to
/// handle a local song (the favorite heart, the three-dot options sheet,
/// "Add to Queue") just works here too, with nothing external-file-
/// specific to maintain there. `IsExternalFile: true` is the one extra
/// marker unique to this feature: PlayerManager's track sync reads it to
/// fall back to mpv's own demuxed audio and subtitle tracks (there's no
/// Jellyfin item to pair Jellyfin stream metadata against — see
/// `_syncTracks`' own IsExternalFile branches for both), and the video
/// player's bottom bar reads it to grey out Quality, which genuinely has
/// no meaning for a file that never came from a Jellyfin server.
///
/// Title/artist/album come from MainActivity.kt's native
/// MediaMetadataRetriever pass when the file actually has ID3-style tags,
/// falling back to parsing "Artist - Title" out of the filename
/// (mirroring LocalMusicService's own untagged-file fallback) when it
/// doesn't — without a real artist here, LyricsScreen's "Search Lyrics"
/// (LrcLibService) has nothing to search on and silently never finds
/// anything, which is what made lyrics look broken for every file opened
/// this way. Every `.srt`/`.vtt`/`.ass`/`.ssa` sitting in the same folder
/// as the source file — found via [_scanSidecarSubtitles]'s full
/// directory listing, or its single same-named-guess fallback when that
/// can't run — rides along in `raw['SidecarSubtitles']` and is picked up
/// by PlayerManager._reapplyCachedSubtitleIfAny the moment playback
/// starts.
class ExternalMediaHandler {
  ExternalMediaHandler._();
  static final ExternalMediaHandler instance = ExternalMediaHandler._();

  static const MethodChannel _channel =
      MethodChannel('com.nemesis.app/external_media');

  /// Owned here (rather than by NemesisApp) so this service can push the
  /// player screen straight onto the root navigator without needing a
  /// BuildContext handed to it from wherever in the widget tree happens
  /// to be on screen when the OS delivers the file.
  final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

  bool _listening = false;

  /// Call once, after the very first frame — `navigatorKey` needs a live
  /// NavigatorState to push onto, which only exists once MaterialApp has
  /// actually built. Checks for a file the app was cold-launched on (a
  /// no-op on iOS/Windows, where the native side of this channel doesn't
  /// exist), then starts listening for any later ones delivered while
  /// already running.
  Future<void> init() async {
    if (!_listening) {
      _listening = true;
      _channel.setMethodCallHandler(_onMethodCall);
    }

    // Nothing meaningful to play into if the person hasn't set up/logged
    // into a server yet — rather than detouring the whole first-launch
    // flow around a file that was opened before the app even had
    // anywhere to play it, just leave it unconsumed on the native side.
    // (It won't be re-delivered on its own; this only ever matters for
    // the rare case of a completely fresh install being used as an
    // "Open With" target before ever being opened normally.)
    if (!await _isLoggedIn()) return;

    try {
      final result = await _channel.invokeMethod('consumeInitialMedia');
      if (result is Map) {
        await _handlePayload(Map<String, dynamic>.from(result));
      }
    } on MissingPluginException {
      // iOS/Windows — no native side wired up for this. Nothing to do.
    } on PlatformException {
      // Same as above, or a transient native-side hiccup — either way,
      // not worth surfacing to the person over a feature they didn't
      // explicitly invoke this session.
    }
  }

  Future<dynamic> _onMethodCall(MethodCall call) async {
    if (call.method != 'onExternalMedia') return null;
    if (!await _isLoggedIn()) return null;

    final args = call.arguments;
    if (args is Map) {
      await _handlePayload(Map<String, dynamic>.from(args));
    }
    return null;
  }

  /// How long playback may wait for tags / duration / cover art before it
  /// starts without them. Everything slower happens after playback begins.
  static const Duration _quickMetadataBudget = Duration(milliseconds: 1000);

  Future<Map<String, dynamic>?> _quickMetadata(
      String uri, String mimeType) async {
    try {
      final r = await _channel
          .invokeMethod('enrichMedia', {'uri': uri, 'mime': mimeType});
      if (r is Map) return Map<String, dynamic>.from(r);
    } on MissingPluginException {
      // Older native build.
    } on PlatformException {
      // Best effort only.
    }
    return null;
  }

  /// Full-folder sidecar subtitle scan, run AFTER playback has started and
  /// never prompting for permission (the old version awaited the "All files
  /// access" screen before playing anything). It simply returns nothing
  /// unless that permission was already granted (Downloads asks for it).
  Future<List<Map<String, String>>> _scanSidecarSubtitles(String uri) async {
    try {
      final result =
          await _channel.invokeMethod('scanSidecarSubtitles', {'uri': uri});
      if (result is List) {
        return result
            .whereType<Map>()
            .map((m) => m.map(
                  (key, value) => MapEntry(key.toString(), value.toString()),
                ))
            .toList();
      }
    } on MissingPluginException {
      // Older native build without this handler yet — nothing to scan.
    } on PlatformException {
      // Best effort only.
    }
    return const [];
  }

  /// The name the opened video has on disk, used to pair subtitles with it:
  /// the provider's display name, else the last part of the URI.
  String _videoFileName(String uri, String? displayName) {
    if (displayName != null && displayName.trim().isNotEmpty) {
      return displayName.trim();
    }
    final parsed = Uri.tryParse(uri);
    var last = (parsed != null && parsed.pathSegments.isNotEmpty)
        ? parsed.pathSegments.last
        : uri;
    final slash = last.lastIndexOf('/');
    if (slash >= 0) last = last.substring(slash + 1);
    return last;
  }

  /// The real file path of a video the app itself downloaded, found by its
  /// file name — for the case where Android hands over a `content://` URI
  /// that gives no path. Null when no download has exactly that file name.
  String? _downloadedPathFor(String fileName) {
    if (fileName.isEmpty) return null;
    final wanted = fileName.toLowerCase();
    try {
      final all = <DownloadRecord>[
        ...DownloadManager.instance.movies,
        ...DownloadManager.instance.episodes,
      ];
      final hits = <String>[];
      for (final r in all) {
        final p = r.mediaPath;
        if (p == null) continue;
        if (SidecarSubtitles.basename(p).toLowerCase() == wanted &&
            File(p).existsSync()) {
          hits.add(p);
        }
      }
      // Two different downloads with the same file name would be ambiguous.
      return hits.length == 1 ? hits.first : null;
    } catch (_) {
      return null;
    }
  }

  /// Subtitle files that sit next to the opened video and carry its name
  /// ("<video name>.<lang>.srt"), read straight from disk by this app — so
  /// this works without the native scan, for any file whose real path can be
  /// worked out (file:// and storage/downloads document URIs, or one of this
  /// app's own downloads matched by name). Empty when the path is unknown or
  /// the folder cannot be read.
  Future<List<Map<String, String>>> _diskSidecars(
    String uri,
    String? displayName,
  ) async {
    try {
      var path = SidecarSubtitles.pathFromUri(uri);
      if (path == null || !File(path).existsSync()) {
        path = _downloadedPathFor(_videoFileName(uri, displayName));
      }
      if (path == null) return const [];
      return await SidecarSubtitles.loadForVideo(path);
    } catch (e) {
      debugPrint('[ExternalMedia] disk subtitle scan failed: $e');
      return const [];
    }
  }

  /// Keeps only the scan results that belong to this video (name starts with
  /// the video's name). When none do, a lone file is kept (the usual
  /// "movie + its one subtitle" folder); several unrelated ones are dropped
  /// rather than guessing — they could belong to other episodes.
  List<Map<String, String>> _onlyThisVideos(
    List<Map<String, String>> found,
    String videoFileName,
  ) {
    final stem = SidecarSubtitles.stemOf(videoFileName);
    if (stem.isEmpty) return found;
    final matched = found
        .where((m) => SidecarSubtitles.matches(m['fileName'] ?? '', stem))
        .toList();
    if (matched.isNotEmpty) return matched;
    return found.length == 1 ? found : const [];
  }

  /// Completes once the player is done loading [item] (or after 60 s).
  Future<void> _waitUntilLoaded() async {
    final loading = PlayerManager.instance.loading;
    if (!loading.value) return;
    final done = Completer<void>();
    void listener() {
      if (!loading.value && !done.isCompleted) done.complete();
    }

    loading.addListener(listener);
    try {
      await done.future.timeout(const Duration(seconds: 60), onTimeout: () {});
    } finally {
      loading.removeListener(listener);
    }
  }

  /// Slow extras for a video, started after playback is already underway:
  /// the poster frame and the other subtitle files in its folder.
  Future<void> _enrichVideoInBackground(
    String uri,
    MediaItem item,
    String? displayName,
  ) async {
    Future<void> frame() async {
      final bytes = await _channel.invokeMethod('videoFrame', {'uri': uri});
      final path = await _cacheImageBytes(uri, bytes, 'frame');
      if (path == null) return;
      final manager = PlayerManager.instance;
      final cur = manager.currentItem;
      if (cur == null || cur.id != item.id) return;
      manager.currentItemNotifier.value =
          cur.copyWith(image: path, backdrop: path);
    }

    Future<void> subtitles() async {
      // Only the files that belong to THIS video (same name), so a folder
      // holding several episodes never lends this one another's subtitles.
      // Files already attached from the disk scan are skipped by name in
      // applyLateSidecarSubtitles.
      final found = _onlyThisVideos(
        await _scanSidecarSubtitles(uri),
        _videoFileName(uri, displayName),
      );
      if (found.isEmpty) return;
      await _waitUntilLoaded();
      await PlayerManager.instance.applyLateSidecarSubtitles(item, found);
    }

    await Future.wait([
      frame().catchError((Object _) {}),
      subtitles().catchError((Object _) {}),
    ]);
  }

  Future<bool> _isLoggedIn() async {
    final server = await StorageService.getServerUrl();
    final token = await StorageService.getToken();
    return server != null &&
        server.isNotEmpty &&
        token != null &&
        token.isNotEmpty;
  }

  Future<void> _handlePayload(Map<String, dynamic> payload) async {
    final uri = payload['uri'] as String?;
    if (uri == null || uri.isEmpty) return;

    final mimeType = (payload['mimeType'] as String?) ?? '';
    final displayName = payload['displayName'] as String?;

    final isAudio = mimeType.startsWith('audio/');
    final isVideo = mimeType.startsWith('video/');

    // Some file managers hand back a generic/missing MIME type for
    // oddly-named files — falling back to the extension means the file
    // the person explicitly chose to open still plays.
    final playAsAudio = isAudio || (!isVideo && _looksLikeAudio(uri, displayName));

    // The native side now answers instantly with just the uri / MIME type /
    // name. Tags, duration and cover art come from one quick follow-up call
    // that playback waits for only briefly; anything slower (the video
    // poster frame, the folder's other subtitle files) is fetched after
    // playback has started. Nothing here ever shows a permission prompt.
    var info = payload;
    if (payload['light'] == true) {
      final quick = await _quickMetadata(uri, mimeType)
          .timeout(_quickMetadataBudget, onTimeout: () => null);
      if (quick != null) info = {...payload, ...quick};
    }

    final artworkPath =
        await _cacheImageBytes(uri, info['artworkBytes'], 'art');
    final videoFramePath =
        await _cacheImageBytes(uri, info['videoFrameBytes'], 'frame');

    final durationMs = (info['durationMs'] as num?)?.toInt();

    // Same-name subtitle the native quick pass found (if any).
    final oldGuessContent = info['subtitleContent'] as String?;
    final oldGuessName = info['subtitleFileName'] as String?;
    final nativeGuess = (oldGuessContent != null && oldGuessContent.isNotEmpty)
        ? [
            {
              'content': oldGuessContent,
              'fileName': oldGuessName ?? 'Subtitle',
            }
          ]
        : const <Map<String, String>>[];

    // SIDECAR FIX: the subtitle files next to the video (same name, any
    // language tag), read from disk right here so the first one is on screen
    // from the first frame and — because they are in `raw` before anything is
    // cast — they also reach a TV the video is sent to. Fast local I/O, but
    // bounded so a slow storage never delays playback. The native
    // same-name guess is only the fallback when the path could not be worked
    // out (and is dropped when a file name does not belong to this video).
    final videoFileName = _videoFileName(uri, displayName);
    final diskSubs = !playAsAudio
        ? await _diskSidecars(uri, displayName)
            .timeout(const Duration(milliseconds: 1500),
                onTimeout: () => const <Map<String, String>>[])
        : const <Map<String, String>>[];
    final sidecarSubtitles = diskSubs.isNotEmpty
        ? diskSubs
        : _onlyThisVideos(nativeGuess, videoFileName);

    final item = _buildMediaItem(
      uri: uri,
      displayName: displayName,
      isAudio: playAsAudio,
      artworkPath: artworkPath,
      videoFramePath: videoFramePath,
      mimeType: mimeType,
      nativeTitle: info['title'] as String?,
      nativeArtist: info['artist'] as String?,
      nativeAlbum: info['album'] as String?,
      durationMs: durationMs,
      sidecarSubtitles: sidecarSubtitles,
      sidecarLyricsContent: info['lyricsContent'] as String?,
      sidecarLyricsName: info['lyricsFileName'] as String?,
    );

    final context = navigatorKey.currentContext;
    if (context == null) return;

    if (playAsAudio) {
      await _playAudio(context, item);
    } else {
      // Started BEFORE _playVideo, which only returns when the player
      // screen closes.
      unawaited(_enrichVideoInBackground(uri, item, displayName));
      await _playVideo(context, item);
    }
  }

  static const _audioExtensions = [
    '.mp3', '.m4a', '.aac', '.flac', '.wav', '.ogg', '.opus', '.wma',
  ];

  bool _looksLikeAudio(String uri, String? displayName) {
    final name = (displayName ?? uri).toLowerCase();
    return _audioExtensions.any(name.endsWith);
  }

  /// Writes MainActivity.kt's embedded-picture bytes (extracted via
  /// MediaMetadataRetriever, since an "Open With" file has no MediaStore
  /// artwork id for on_audio_query to look up) to disk, mirroring
  /// LocalMusicService's own cached-artwork-file approach so every
  /// artwork call site downstream (which all expect a file path, not raw
  /// bytes) works unchanged. Lives under the temp dir rather than
  /// LocalMusicService's app-documents artwork folder — this is a
  /// one-off external file rather than a tracked on-device library
  /// entry, so it's fine (better, even) for the OS to reclaim it under
  /// storage pressure. Returns null on missing/empty bytes or any
  /// write failure — every downstream artwork widget already treats a
  /// null image as "show the placeholder".
  ///
  /// CASTING FIX: generalized from a song-artwork-only `_cacheArtwork` to
  /// also cache a video's decoded first frame (see MainActivity.kt's
  /// `extractVideoFrame` doc comment) — the two are written through this
  /// same helper with a different [kind] tag in the filename purely so
  /// the two can never collide on disk for the same source file, not
  /// because they're handled any differently otherwise.
  Future<String?> _cacheImageBytes(
    String uri,
    Object? bytesPayload,
    String kind,
  ) async {
    if (bytesPayload is! Uint8List && bytesPayload is! List<int>) return null;
    final bytes = bytesPayload is Uint8List
        ? bytesPayload
        : Uint8List.fromList(bytesPayload as List<int>);
    if (bytes.isEmpty) return null;

    try {
      final dir = await getTemporaryDirectory();
      final artDir = Directory('${dir.path}/external_media_artwork');
      if (!await artDir.exists()) {
        await artDir.create(recursive: true);
      }

      final path = '${artDir.path}/${uri.hashCode}_$kind.jpg';
      await File(path).writeAsBytes(bytes, flush: true);
      return path;
    } catch (e) {
      return null;
    }
  }

  MediaItem _buildMediaItem({
    required String uri,
    required String? displayName,
    required bool isAudio,
    required String? artworkPath,
    String? videoFramePath,
    String mimeType = '',
    String? nativeTitle,
    String? nativeArtist,
    String? nativeAlbum,
    int? durationMs,
    List<Map<String, String>> sidecarSubtitles = const [],
    String? sidecarLyricsContent,
    String? sidecarLyricsName,
  }) {
    final fallbackName = (displayName != null && displayName.trim().isNotEmpty)
        ? displayName
        : _titleFromUri(uri);

    var title = (nativeTitle != null && nativeTitle.trim().isNotEmpty)
        ? nativeTitle.trim()
        : fallbackName;
    var artist = (nativeArtist != null && nativeArtist.trim().isNotEmpty)
        ? nativeArtist.trim()
        : '';
    final album = (nativeAlbum != null && nativeAlbum.trim().isNotEmpty)
        ? nativeAlbum.trim()
        : '';

    // No usable embedded ID3 artist tag (either this isn't audio, or
    // the file just didn't have one) — fall back to parsing "Artist -
    // Title" straight out of the filename, exactly like
    // LocalMusicService._resolveTitleAndArtist already does for an
    // on-device library song with the same gap. Without this, `artist`
    // stayed permanently empty for every Open With/Play With track,
    // which is what was silently starving LrcLibService.findBestMatch
    // of anything to search on — the on-device library's "Search
    // Lyrics" button worked because it always had a real artist behind
    // it; this one never did.
    if (isAudio && artist.isEmpty) {
      final parsed = _parseArtistTitleFromFilename(_stripExtension(fallbackName));
      if (parsed.artist.isNotEmpty) {
        artist = parsed.artist;
        // A real embedded title tag always wins — the filename parse
        // only fills in for the title too when there was no tag at all.
        if (nativeTitle == null || nativeTitle.trim().isEmpty) {
          title = parsed.title;
        }
      }
    }

    // CASTING FIX: real runtime, off MainActivity.kt's MediaMetadataRetriever
    // pass (see `durationMs`'s own doc comment on the call site above for
    // exactly what this fixes) — `RunTimeTicks` (Jellyfin's own 100ns-tick
    // unit) is set to match, for any other code path that reads runtime off
    // the raw map rather than `MediaItem.runtime` itself. Falls back to
    // zero, same as before, only when the retriever genuinely couldn't
    // determine a duration (a corrupt file, an exotic container it can't
    // parse) — `durationMs == null` rather than `0` is what distinguishes
    // "unknown" from a real report here, so a genuinely instantaneous/
    // unreadable duration is never confused with a retriever failure.
    final runtime = (durationMs != null && durationMs > 0)
        ? Duration(milliseconds: durationMs)
        : Duration.zero;

    final raw = <String, dynamic>{
      'Id': 'external_${uri.hashCode}',
      'Name': title,
      'AlbumArtist': artist,
      'Artists': artist.isNotEmpty ? [artist] : const [],
      'Album': album,
      'RunTimeTicks': runtime.inMicroseconds * 10,
      'IsLocal': true,
      'IsExternalFile': true,
      'LocalUri': uri,
      // LOCAL CASTING: the provider-reported MIME type is the most
      // reliable thing this app has to work out whether the stock Cast
      // receiver can open this file directly — `uri` here is very often
      // a bare `content://` URI with no file extension of its own
      // (another app's FileProvider handing off a share), unlike
      // LocalMusicService's on-device songs, which always have a real
      // extension to fall back to via MediaStore's `DATA` column (see
      // that service's own `FileExtension` field comment). Passed
      // through as-is; `GoogleCastTransport._localFileExtension` maps it
      // back to a concrete extension/compatibility check.
      'MimeType': mimeType,
      'ArtworkPath': artworkPath,
      'UserData': {'IsFavorite': false, 'PlayCount': 0},
    };

    // CASTING FIX (no poster/backdrop for an Open With/Play With video):
    // `artworkPath` above is always null for video (MainActivity.kt only
    // ever extracts a song's embedded cover, never a video's), so
    // `videoFramePath` — the decoded first frame — is what actually
    // stands in as this item's image for a video. Used for `image` below
    // exactly like a song's own artwork is, and *also* for `backdrop`:
    // `CastingBackdrop` (the on-device casting video player screen) reads
    // `backdrop` specifically, not `image`, for a non-live item — see
    // that widget's own doc comment — and a video opened this way has no
    // Jellyfin-fetched backdrop of any kind to put there otherwise.
    final resolvedImage = isAudio ? artworkPath : videoFramePath;

    // Picked up by PlayerManager._reapplyCachedSubtitleIfAny, which
    // loads the first entry exactly like a remembered OpenSubtitles
    // download the moment playback starts, and adds every other entry
    // (a folder with more than one subtitle file) as a pickable-but-
    // not-yet-selected track — see that function's doc comment.
    if (sidecarSubtitles.isNotEmpty) {
      raw['SidecarSubtitles'] = sidecarSubtitles;
    }

    // LYRICS SIDECAR FIX — the lyrics counterpart to the subtitle sidecar
    // immediately above: a same-named .lrc sitting next to the source
    // file, when MainActivity.kt's resolveSidecarLyrics found one
    // (mirrors resolveSidecarSubtitle exactly, same shared
    // resolveSidecarFile lookup underneath). Picked up by
    // LyricsScreen._loadFromDownloadedLyrics, which shows it immediately
    // with no LRCLIB search needed, exactly like a DownloadManager song's
    // own lyrics sidecar or an on-device library song's (see that
    // function's doc comment for all three paths).
    if (sidecarLyricsContent != null && sidecarLyricsContent.isNotEmpty) {
      raw['SidecarLyricsContent'] = sidecarLyricsContent;
      raw['SidecarLyricsName'] = sidecarLyricsName ?? 'Lyrics';
    }

    return MediaItem(
      id: raw['Id'] as String,
      title: title,
      // Mirrors LocalMusicService.mediaItemFromLocalSong's subtitle
      // exactly (artist, falling back to album) rather than the fixed
      // "On This Device" label — a track opened via Open With/Play With
      // should read the same as one already living in the on-device
      // library: song title up top, artist underneath.
      subtitle: isAudio ? (artist.isNotEmpty ? artist : album) : '',
      streamUrl: uri,
      // Left null when there's no embedded artwork/decoded frame (or
      // extraction failed) — every artwork call site already treats a
      // null image as "show the placeholder", same fallback local
      // library songs get from LocalMusicService.
      image: resolvedImage,
      // CASTING FIX: only set for video (see `resolvedImage`'s own doc
      // comment above) — a song has no "backdrop" concept anywhere else
      // in the app, so this deliberately stays null for audio rather
      // than duplicating `image` onto a field nothing local reads for
      // music.
      backdrop: isAudio ? null : resolvedImage,
      runtime: runtime,
      audioOnly: isAudio,
      artistName: artist,
      raw: raw,
    );
  }

  static final RegExp _leadingTrackNumber = RegExp(r'^\s*\d{1,3}[\s._-]+');

  static final RegExp _bracketedJunk = RegExp(
    r'[\(\[][^)\]]*\b(official|video|audio|lyrics?|hq|hd|remaster\w*|explicit|clean)\b[^)\]]*[\)\]]',
    caseSensitive: false,
  );

  static final RegExp _artistTitleSplit =
      RegExp(r'^(.{1,80}?)\s*[-\u2013\u2014]\s*(.{1,120})$');

  /// Mirrors LocalMusicService._parseArtistTitleFromFilename exactly
  /// (kept as its own small copy here rather than a shared import, to
  /// keep this a self-contained, surgical file per usual) — same
  /// "Artist - Title" convention, same track-number/junk stripping.
  ({String title, String artist}) _parseArtistTitleFromFilename(String name) {
    var cleaned = name.replaceAll('_', ' ').trim();
    cleaned = cleaned.replaceFirst(_leadingTrackNumber, '');
    cleaned = cleaned.replaceAll(_bracketedJunk, '');
    cleaned = cleaned.replaceAll(RegExp(r'\s+'), ' ').trim();

    final match = _artistTitleSplit.firstMatch(cleaned);
    if (match != null) {
      final artist = match.group(1)!.trim();
      final title = match.group(2)!.trim();
      if (artist.isNotEmpty && title.isNotEmpty) {
        return (title: title, artist: artist);
      }
    }

    return (title: cleaned, artist: '');
  }

  String _stripExtension(String name) {
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  /// Falls back to the file's own name (minus extension, percent-decoded)
  /// when the native side couldn't resolve a display name — better than
  /// showing the raw content:// Uri as the title.
  String _titleFromUri(String uri) {
    final parsed = Uri.tryParse(uri);
    var last = (parsed != null && parsed.pathSegments.isNotEmpty)
        ? parsed.pathSegments.last
        : uri;

    try {
      last = Uri.decodeComponent(last);
    } catch (_) {
      // Malformed percent-encoding — just use it as-is.
    }

    final dot = last.lastIndexOf('.');
    if (dot > 0) last = last.substring(0, dot);

    return last.isEmpty ? 'Untitled' : last;
  }

  // Mirrors MusicScreen._playSongs's "not already playing" push pattern:
  // push the full-screen player with a loading preview up front, then
  // let playQueue() resolve the real stream underneath it.
  Future<void> _playAudio(BuildContext context, MediaItem item) async {
    PlayerManager.instance.showLoadingPreview(item);

    // OPEN WITH FIX: replaces an already-open video player screen (or reuses
    // an already-open audio one) instead of stacking a second player route
    // on top — see PlayerScreenRegistry for the root cause.
    unawaited(PlayerScreenRegistry.openExclusive(
      Navigator.of(context, rootNavigator: true),
      PlayerScreenKind.audio,
      MaterialPageRoute<void>(builder: (_) => const AudioPlayerScreen()),
    ));

    await PlaybackService.playQueue([item], source: PlaybackSource.unknown);
  }

  // Mirrors every other video "Play" button's flow (e.g.
  // CollectionDetailsScreen's onPlay): loading preview shown immediately,
  // playQueue kicked off without waiting on it, then PlayerNavigation's
  // guarded push opens the player screen.
  Future<void> _playVideo(BuildContext context, MediaItem item) async {
    PlayerManager.instance.showLoadingPreview(item);

    unawaited(
      PlaybackService.playQueue([item], source: PlaybackSource.unknown),
    );

    await PlayerNavigation.open(context);
  }
}
