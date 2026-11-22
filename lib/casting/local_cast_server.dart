import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:ffmpeg_kit_flutter_new_min/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min/return_code.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../player/models/media_item.dart';
import '../services/sidecar_subtitles.dart';
import 'addon_cast_relay.dart';
import 'local_cast_format.dart';
import 'local_media_bridge.dart';
import 'local_video_transcode_service.dart';

/// CASTING FIX (OpenSubtitles/Open-With sidecar subtitles invisible on
/// the TV): the fixed Google Cast trackId used for the one, on-the-fly
/// subtitle track [LocalCastServer.registerSubtitleText] serves — see
/// that method's own doc comment, and `PlaybackCoordinator`'s
/// LOCAL -> REMOTE handoff and `GoogleCastTransport._subtitleTracksFor`
/// for where this actually gets declared/selected. Deliberately a value
/// no real Jellyfin `MediaStreams` index would ever collide with (those
/// are always small, 0-based container stream indices) rather than 0/1,
/// since a local/external item can also have genuine Jellyfin-style
/// subtitle entries of its own in principle (a downloaded item's own
/// sidecar tracks, handled separately in `_syncTracks`).
const int kLocalCastSubtitleTrackId = 9001;

/// A single file being made available to whatever's currently cast —
/// either the real on-device path (an absolute filesystem path, or the
/// `/proc/self/fd/<fd>` alias [LocalMediaBridge] resolved for a
/// `content://` source) plus the fd to close when this route is torn
/// down, or null when nothing needed opening (a plain file path).
class _ServedFile {
  _ServedFile({
    required this.contentType,
    this.path,
    this.bytes,
    this.fd,
    this.isTempFile = false,
  }) : assert(
          path != null || bytes != null,
          'A served route needs either an on-disk path or in-memory bytes',
        );

  /// Null for an in-memory route (see [bytes]) — a subtitle registered
  /// via [LocalCastServer.registerSubtitleText] never touches disk at
  /// all, unlike every other route this server hands out.
  final String? path;

  /// Raw bytes served directly from memory rather than read off disk.
  /// Only ever set for [LocalCastServer.registerSubtitleText]'s routes —
  /// a subtitle is small enough (a few hundred KB at most) that writing
  /// it to a temp file first, the way [LocalVideoTranscodeService]'s
  /// remux output does, would just be extra I/O for no benefit, and it
  /// sidesteps needing a cleanup entry in [LocalCastServer.stopAll] for
  /// yet another kind of temp file.
  final Uint8List? bytes;

  final String contentType;
  final int? fd;

  /// DLNA only: URL of an SRT sidecar to advertise through Samsung's
  /// `getCaptionInfo.sec` / `CaptionInfo.sec` HTTP header handshake (see
  /// [LocalCastServer.attachCaption]). Mutable because the subtitle is
  /// chosen *after* the media route was registered.
  String? captionUrl;

  /// How many HTTP requests (GET / HEAD) a client has made for this route.
  /// Lets `DlnaTransport` tell "the TV never even connected to this phone"
  /// (a network problem) from "the TV fetched the file and then wouldn't
  /// play it" (a format problem) when a cast fails — see
  /// [LocalCastServer.requestCountForUrl].
  int requests = 0;

  // PHASE 0 (DIAGNOSTICS ONLY): what each route has actually done, so a
  // failed cast can say "the TV never asked", "asked and was dropped" or
  // "was answered with 404" instead of leaving it to guesswork. Nothing
  // in here changes what the server serves.
  /// media / art / subtitle / remux — set by [LocalCastServer._addRoute].
  String label = 'media';

  /// Total body bytes actually written to clients for this route.
  int bytesSent = 0;

  /// HTTP status of the most recent request, null until one arrives.
  int? lastStatus;

  /// Requests that carried a `Range` header (seeks / tail reads).
  int rangeRequests = 0;

  /// Requests whose connection ended before the body was fully written.
  int aborted = 0;

  // PHASE 2: bookkeeping so a route can be reused for the same item (F2.5)
  // and the oldest ones released once too many pile up.
  /// This route's token (the first URL path segment). Set by `_addRoute`.
  String? token;

  /// Last URL path segment (`stream.mp3`, `art.jpg`…), so the URL can be
  /// rebuilt on the phone's CURRENT address when a route is reused.
  String urlName = '';

  /// What identifies the item this route serves (source + type); a second
  /// request for the same thing gets this route back instead of a new one.
  String? reuseKey;

  /// True for a file this server created itself (currently: an
  /// on-device MKV remux from [LocalVideoTranscodeService]) rather than
  /// one already sitting on the device — see [LocalCastServer.stopAll],
  /// which deletes these but leaves a real source file (a MediaStore
  /// song, an Open With file) alone.
  final bool isTempFile;
}

/// Casts local, on-device media (an "On This Device" song, or a file
/// opened via Android's Open With/Play With — see [MediaItem.isLocal])
/// to Google Cast by making it briefly reachable over plain HTTP on the
/// LAN, the same thing VLC's own "Cast" feature does for the same
/// underlying reason: a Chromecast/Google TV receiver only ever fetches
/// URLs itself, over the network — it has no access to this phone's
/// filesystem or content providers, so a local item needs *something*
/// on this phone acting as a tiny web server for the TV to pull from.
///
/// Deliberately hand-rolled on top of `dart:io`'s `HttpServer` rather
/// than pulling in a package like `shelf` — the only real requirement
/// (serving a file with `Range` support, so the TV can seek) is a small
/// enough amount of code that a new dependency isn't worth the
/// resolution risk `GoogleCastTransport`'s own doc comment already
/// flags for `flutter_chrome_cast`'s `permission_handler` pin.
///
/// One server for the whole app, started lazily on the first local item
/// that needs casting and torn down by [CastManager.disconnect] calling
/// [stopAll] — never running for the app's whole lifetime, matching the
/// "don't do unnecessary background work" rule the discovery
/// ref-counting elsewhere in casting already follows.
///
/// Every route this hands out is gated behind a random per-item token
/// baked into its URL path (`/<token>/stream.<ext>`) — anyone else on
/// the same LAN would have to guess a real token to fetch anything, the
/// same lightweight protection VLC's own local streaming server relies
/// on rather than real auth, which the Cast SDK has no way to attach to
/// a receiver's plain HTTP fetch anyway.
class LocalCastServer {
  LocalCastServer._();
  static final LocalCastServer instance = LocalCastServer._();

  HttpServer? _server;
  String? _lanIp;
  final Map<String, _ServedFile> _routes = {};
  final _random = Random.secure();

  bool get _isRunning => _server != null;

  // ── PHASE 2 ───────────────────────────────────────────────────────────
  /// Host (IPv4) of the TV currently being cast to. Lets [_resolveLanIp]
  /// pick the phone address that sits on the TV's own subnet (F2.3) instead
  /// of "the first Wi-Fi looking interface".
  String? _peerHost;

  /// reuseKey -> token of the live route serving it (F2.5).
  final Map<String, String> _tokenByReuseKey = {};

  /// Most routes of each kind kept alive at once. A long session used to
  /// register a new route (and, for content:// files, open a new file
  /// descriptor) for every single cast and release them only at disconnect.
  static const int _maxMediaRoutes = 8;
  static const int _maxArtRoutes = 24;
  static const int _maxSubtitleRoutes = 48;

  /// Tells the server which TV it is serving. The next address lookup then
  /// prefers the phone address on that TV's subnet (F2.3).
  void setPeerHint(String? host) {
    if (_peerHost == host) return;
    _peerHost = host;
    debugPrint('LocalCastServer: serving TV at ${host ?? '(none)'}');
    if (_isRunning) unawaited(_refreshLanIp());
  }

  static final RegExp _phoneUrlPath =
      RegExp(r'^/[0-9a-f]{32}/(stream|art|sub)[^/]*$');

  /// True when [url] has the shape of a URL this server hands out
  /// (`http://<ip>:<port>/<32 hex token>/stream.ext` …), whether or not the
  /// server that issued it is still running. Together with [ownsUrl] this
  /// tells a live phone-server URL from a dead one left over from an
  /// earlier session (F2.2).
  static bool isPhoneServerUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'http') return false;
    return _phoneUrlPath.hasMatch(uri.path);
  }

  Uri _urlFor(String token, String urlName) =>
      Uri.parse('http://$_lanIp:${_server!.port}/$token/$urlName');

  /// Returns the URL of the live route registered under [key] (rebuilt on
  /// the phone's current address), or null when there is none or its
  /// source has vanished.
  Future<Uri?> _reuseRoute(String key) async {
    final token = _tokenByReuseKey[key];
    if (token == null) return null;
    final served = _routes[token];
    if (served == null || _server == null) {
      _tokenByReuseKey.remove(key);
      return null;
    }
    final path = served.path;
    if (path != null && !await File(path).exists()) {
      _dropRoute(token, 'source no longer readable');
      return null;
    }
    await _ensureRunning();
    if (_server == null || _lanIp == null) return null;
    // Re-insert so it counts as the most recently used route.
    _routes.remove(token);
    _routes[token] = served;
    debugPrint('LocalCastServer: reusing ${served.label} route '
        '${_shortToken(token)}/${served.urlName} (${_routes.length} route(s))');
    return _urlFor(token, served.urlName);
  }

  /// Releases one route: its file descriptor, its temp remux file, its
  /// reuse entry.
  void _dropRoute(String token, String why) {
    final served = _routes.remove(token);
    if (served == null) return;
    final key = served.reuseKey;
    if (key != null && _tokenByReuseKey[key] == token) {
      _tokenByReuseKey.remove(key);
    }
    final fd = served.fd;
    if (fd != null) {
      unawaited(LocalMediaBridge.instance.closeContentFd(fd));
    }
    if (served.isTempFile && served.path != null) {
      final tempPath = served.path!;
      unawaited(
        File(tempPath).delete().catchError((e) {
          debugPrint('LocalCastServer: failed to delete temp file '
              '$tempPath: $e');
          return File(tempPath);
        }),
      );
    }
    debugPrint('LocalCastServer: route -${served.label} '
        '${_shortToken(token)}/${served.urlName} ($why; '
        '${_routes.length} route(s) left)');
  }

  /// Keeps each kind of route under its cap by releasing the oldest ones.
  /// Never touches [keepToken], the route that was just registered.
  void _enforceRouteCaps(String keepToken) {
    int capFor(String label) => switch (label) {
          'art' => _maxArtRoutes,
          'subtitle' => _maxSubtitleRoutes,
          _ => _maxMediaRoutes, // media + remux
        };
    String groupOf(String label) =>
        (label == 'art' || label == 'subtitle') ? label : 'media';

    final byGroup = <String, List<String>>{};
    for (final e in _routes.entries) {
      byGroup.putIfAbsent(groupOf(e.value.label), () => []).add(e.key);
    }
    for (final e in byGroup.entries) {
      final cap = capFor(e.key);
      var excess = e.value.length - cap;
      for (final token in e.value) {
        if (excess <= 0) break;
        if (token == keepToken) continue;
        _dropRoute(token, 'over the ${e.key} route limit');
        excess--;
      }
    }
  }

  /// Registers [item] (already confirmed [MediaItem.isLocal]) with the
  /// server and returns the URL a Cast receiver should fetch, or throws
  /// [LocalCastUnsupportedException] when it genuinely can't be —
  /// resolving [source] to real bytes failed, or there's no local
  /// address to serve from at all. Never returns null; every failure is
  /// a specific, user-facing message rather than a silent miss, since a
  /// null here used to be exactly what read as "the TV never responds"
  /// before this feature existed.
  Future<Uri> registerMedia({
    required MediaItem item,
    required String sourceUri,
    required String contentType,
    required String extensionForUrl,
    // Google Cast's receiver has no Matroska demuxer, so MKV is remuxed to
    // MPEG-TS on-device first. DLNA TVs (LG/Samsung/Sony…) play MKV
    // natively, so for them the original file is served untouched —
    // no ffmpeg pass, instant start, exact seeking.
    bool remuxMkvToTs = true,
  }) async {
    // PHASE 2 (F2.5): casting the same file again (a repeat, a queue that
    // contains it twice, a retry, a reload for another audio/subtitle
    // track) reuses its route instead of opening another file descriptor
    // (and, for an MKV, remuxing the whole file again).
    final reuseKey = 'media|$sourceUri|$contentType|$remuxMkvToTs';
    final reused = await _reuseRoute(reuseKey);
    if (reused != null) return reused;

    var resolved = await _resolveReadableSource(
      sourceUri,
      item.title,
      contentType,
    );
    var effectiveExtensionForUrl = extensionForUrl;

    // CASTING FIX (local MKV files never start playing on the TV): see
    // local_cast_format.dart's `mkv` map entry and
    // LocalVideoTranscodeService's own doc comment for the full story —
    // short version, Cast's Default Media Receiver has no Matroska
    // demuxer, so an MKV has to be remuxed to MPEG-TS before it's handed
    // to the receiver, and there's no Jellyfin server here to do that
    // remux the way GoogleCastTransport's HLS path does for a
    // server-hosted MKV. Runs after `_resolveReadableSource` on purpose:
    // that call already turned a `content://` source into a real,
    // directly-openable path (or opened the fd bridge for one), which is
    // what ffmpeg needs as its input regardless of where the original
    // bytes came from.
    if (remuxMkvToTs && contentType == 'video/x-matroska') {
      final originalFd = resolved.fd;
      try {
        // `resolved` always comes from `_resolveReadableSource` here (never
        // the in-memory `bytes`-only shape `registerSubtitleText` builds),
        // which always sets `path` — but the field itself is nullable on
        // `_ServedFile` in general, so this satisfies the type checker
        // with a clear failure message instead of an unchecked `!`.
        final inputPath = resolved.path;
        if (inputPath == null) {
          throw LocalCastUnsupportedException(
            '"${item.title}" couldn\'t be read to remux it for casting.',
          );
        }

        final remuxedPath =
            await LocalVideoTranscodeService.instance.remuxToMpegTs(
          inputPath: inputPath,
          title: item.title,
        );
        resolved = _ServedFile(
          path: remuxedPath,
          contentType: 'video/mp2t',
          isTempFile: true,
        );
        effectiveExtensionForUrl = 'ts';
      } finally {
        // The remux already fully read the original file (or fd-backed
        // path) by the time it returns (success or failure) — nothing
        // downstream needs it open any longer, so close it right away
        // rather than waiting for `stopAll()` at the end of the whole
        // cast session.
        if (originalFd != null) {
          unawaited(LocalMediaBridge.instance.closeContentFd(originalFd));
        }
      }
    }

    await _ensureRunning();
    if (_lanIp == null || _server == null) {
      // The source was opened above but nothing will ever serve it.
      final fd = resolved.fd;
      if (fd != null) unawaited(LocalMediaBridge.instance.closeContentFd(fd));
      throw LocalCastUnsupportedException(
        'Couldn\'t find this device\'s network address to cast '
        '"${item.title}" — check that Wi-Fi is turned on.',
      );
    }

    final token = _newToken();
    final ext =
        effectiveExtensionForUrl.isNotEmpty ? '.$effectiveExtensionForUrl' : '';
    _addRoute(token, resolved, 'stream$ext', reuseKey: reuseKey);
    return _urlFor(token, 'stream$ext');
  }

  /// Lists the audio streams inside a local video (see
  /// [LocalVideoTranscodeService.probeAudioStreams]). Resolves a
  /// `content://` source the same way [registerMediaWithAudioTrack] does
  /// and closes its fd again before returning. Never throws — an
  /// unreadable file just yields an empty list.
  Future<List<LocalAudioStreamInfo>> probeAudioStreams({
    required MediaItem item,
    required String sourceUri,
  }) async {
    _ServedFile? resolved;
    try {
      resolved = await _resolveReadableSource(
        sourceUri,
        item.title,
        'video/mp2t',
      );
      final inputPath = resolved.path;
      if (inputPath == null) return const [];

      return await LocalVideoTranscodeService.instance
          .probeAudioStreams(inputPath: inputPath);
    } catch (e) {
      debugPrint(
        'LocalCastServer.probeAudioStreams failed for "${item.title}": $e',
      );
      return const [];
    } finally {
      final fd = resolved?.fd;
      if (fd != null) {
        unawaited(LocalMediaBridge.instance.closeContentFd(fd));
      }
    }
  }

  /// DLNA FALLBACK FOR LOCAL VIDEO: serves an MPEG-TS stream-copy remux of
  /// the whole file (any source container). A TV's own built-in receiver
  /// plays far fewer containers than Kodi / AirScreen do — many LG /
  /// Samsung / Android-TV firmwares refuse MKV, AVI, MOV, WMV … outright —
  /// while MPEG-TS is the one container every one of them accepts. Used by
  /// `DlnaTransport` only AFTER the TV has refused the original file, so a
  /// receiver that plays the file as it is never pays for the remux.
  ///
  /// Same plumbing as [registerMediaWithAudioTrack] (without the audio-track
  /// selection): the remux output is a temp file this server owns and
  /// deletes in [stopAll]. Throws [LocalCastUnsupportedException] when the
  /// file can't be read or remuxed (non-Android, ffmpeg refused the codecs).
  Future<Uri> registerMediaAsMpegTs({
    required MediaItem item,
    required String sourceUri,
  }) async {
    final resolved = await _resolveReadableSource(
      sourceUri,
      item.title,
      'video/mp2t',
    );
    final originalFd = resolved.fd;

    late final String remuxedPath;
    try {
      final inputPath = resolved.path;
      if (inputPath == null) {
        throw LocalCastUnsupportedException(
          '\"${item.title}\" couldn\'t be read to convert it for the TV.',
        );
      }
      remuxedPath = await LocalVideoTranscodeService.instance.remuxToMpegTs(
        inputPath: inputPath,
        title: item.title,
      );
    } finally {
      // The remux has fully read the source by now (success or failure).
      if (originalFd != null) {
        unawaited(LocalMediaBridge.instance.closeContentFd(originalFd));
      }
    }

    await _ensureRunning();
    if (_lanIp == null || _server == null) {
      throw LocalCastUnsupportedException(
        'Couldn\'t find this device\'s network address to cast '
        '\"${item.title}\" — check that Wi-Fi is turned on.',
      );
    }

    final token = _newToken();
    _addRoute(
      token,
      _ServedFile(
        path: remuxedPath,
        contentType: 'video/mp2t',
        isTempFile: true,
      ),
      'stream.ts',
    );
    return _urlFor(token, 'stream.ts');
  }

  /// PHASE 0 (DIAGNOSTICS ONLY): the single place a route is stored, so
  /// every registration is logged the same way. [urlName] is the last URL
  /// segment (`stream.mp3`, `art.jpg`, `sub.vtt`…), which also decides the
  /// route's log label.
  void _addRoute(
    String token,
    _ServedFile served,
    String urlName, {
    String? reuseKey,
  }) {
    served
      ..token = token
      ..urlName = urlName
      ..reuseKey = reuseKey;
    if (reuseKey != null) _tokenByReuseKey[reuseKey] = token;
    final lower = urlName.toLowerCase();
    if (lower.startsWith('art.')) {
      served.label = 'art';
    } else if (lower.startsWith('sub.')) {
      served.label = 'subtitle';
    } else if (served.isTempFile) {
      served.label = 'remux';
    } else {
      served.label = 'media';
    }
    _routes[token] = served;

    final path = served.path;
    final String source;
    if (served.bytes != null) {
      source = 'memory ${served.bytes!.length} B';
    } else if (path != null && path.startsWith('/proc/self/fd/')) {
      source = 'content:// via fd ${served.fd}';
    } else if (path != null) {
      source = 'file ${path.split('/').last}';
    } else {
      source = '?';
    }
    debugPrint('LocalCastServer: route +${served.label} '
        '${_shortToken(token)}/$urlName type=${served.contentType} '
        'source=[$source] temp=${served.isTempFile} '
        '(${_routes.length} route(s) now)');
    _enforceRouteCaps(token);
  }

  static String _shortToken(String token) =>
      token.length > 6 ? '${token.substring(0, 6)}…' : token;

  /// PHASE 0: reads the first bytes of a cover file and logs its real
  /// format next to the `image/jpeg` the route claims.
  Future<void> _logImageFormat(String title, _ServedFile served) async {
    final path = served.path;
    if (path == null) return;
    try {
      final head = <int>[];
      await for (final chunk in File(path).openRead(0, 12)) {
        head.addAll(chunk);
      }
      String kind = 'unknown';
      if (head.length >= 3 && head[0] == 0xFF && head[1] == 0xD8) {
        kind = 'JPEG';
      } else if (head.length >= 4 &&
          head[0] == 0x89 &&
          head[1] == 0x50 &&
          head[2] == 0x4E &&
          head[3] == 0x47) {
        kind = 'PNG';
      } else if (head.length >= 12 &&
          String.fromCharCodes(head.sublist(0, 4)) == 'RIFF' &&
          String.fromCharCodes(head.sublist(8, 12)) == 'WEBP') {
        kind = 'WebP';
      } else if (head.length >= 3 &&
          String.fromCharCodes(head.sublist(0, 3)) == 'GIF') {
        kind = 'GIF';
      }
      final length = await File(path).length();
      debugPrint('LocalCastServer: cover for "$title" is really $kind, '
          '$length B, served as ${served.contentType}');
    } catch (e) {
      debugPrint('LocalCastServer: could not inspect cover for "$title": $e');
    }
  }

  /// PHASE 0: a one-line account of what a client has done with the route
  /// behind [url] — used by `DlnaTransport`'s per-load summary. Null when
  /// [url] isn't one of this server's routes (e.g. a Jellyfin URL, which
  /// the TV fetches from the server directly and this phone can't see).
  String? routeSummaryForUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.pathSegments.isEmpty) return null;
    final r = _routes[uri.pathSegments.first];
    final relay = _relays[uri.pathSegments.first];
    if (r == null && relay != null) {
      return 'relay: ${relay.requests} request(s), ${relay.bytesSent} B sent';
    }
    if (r == null) return null;
    return '${r.label}: ${r.requests} request(s), ${r.rangeRequests} ranged, '
        '${r.bytesSent} B sent, ${r.aborted} aborted, '
        'last status ${r.lastStatus ?? '-'}';
  }

  /// How many requests a client has made for the route behind [url]; null
  /// when [url] isn't one of this server's routes.
  int? requestCountForUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.pathSegments.isEmpty) return null;
    final first = uri.pathSegments.first;
    return _routes[first]?.requests ?? _relays[first]?.requests;
  }

  /// Size in bytes of what the route behind [url] serves, or null when
  /// [url] isn't one of this server's routes or can't be read. Lets
  /// `DlnaTransport` declare the exact `size` of a local file in the
  /// DIDL-Lite metadata, as media servers do and strict TV firmwares expect.
  Future<int?> sizeForUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.pathSegments.isEmpty) return null;
    final served = _routes[uri.pathSegments.first];
    if (served == null) return null;
    final bytes = served.bytes;
    if (bytes != null) return bytes.length;
    final path = served.path;
    if (path == null) return null;
    try {
      return await File(path).length();
    } catch (_) {
      return null;
    }
  }

  /// AUDIO-TRACK SWITCH FOR LOCAL CASTING: like [registerMedia], but the
  /// served stream is an MPEG-TS remux containing only the file's
  /// [audioIndex]-th audio track (see
  /// [LocalVideoTranscodeService.remuxToMpegTsWithAudio] for why a whole
  /// new stream is needed). Always MPEG-TS regardless of the source
  /// container, so callers must declare `video/mp2t` for it (see
  /// GoogleCastTransport._resolveCastMedia's `CastLocalRemuxedTs` check).
  /// The remux output is a temp file this server owns and deletes in
  /// [stopAll], same as [registerMedia]'s MKV remux.
  Future<Uri> registerMediaWithAudioTrack({
    required MediaItem item,
    required String sourceUri,
    required int audioIndex,
  }) async {
    final resolved = await _resolveReadableSource(
      sourceUri,
      item.title,
      'video/mp2t',
    );
    final originalFd = resolved.fd;

    late final String remuxedPath;
    try {
      final inputPath = resolved.path;
      if (inputPath == null) {
        throw LocalCastUnsupportedException(
          '"${item.title}" couldn\'t be read to switch its audio track.',
        );
      }

      remuxedPath = await LocalVideoTranscodeService.instance
          .remuxToMpegTsWithAudio(
        inputPath: inputPath,
        title: item.title,
        audioIndex: audioIndex,
      );
    } finally {
      // The remux has fully read the source by now (success or failure).
      if (originalFd != null) {
        unawaited(LocalMediaBridge.instance.closeContentFd(originalFd));
      }
    }

    await _ensureRunning();
    if (_lanIp == null || _server == null) {
      throw LocalCastUnsupportedException(
        'Couldn\'t find this device\'s network address to cast '
        '"${item.title}" — check that Wi-Fi is turned on.',
      );
    }

    final token = _newToken();
    _addRoute(
      token,
      _ServedFile(
        path: remuxedPath,
        contentType: 'video/mp2t',
        isTempFile: true,
      ),
      'stream.ts',
    );
    return _urlFor(token, 'stream.ts');
  }

  /// CASTING FIX (no artwork/poster on the TV for a local song/video):
  /// the same "make a local, on-device file reachable over plain HTTP"
  /// job [registerMedia] already does for the media file itself, applied
  /// to a cached artwork/video-frame file instead — [CastManager
  /// ._ensureCastableLocalItem] calls this right alongside [registerMedia]
  /// so an Open With/Play With item's `image`/`backdrop` (an on-disk path
  /// nothing but this app's own UI could ever load — see
  /// GoogleCastTransport._imagesFor's own doc comment on exactly why that
  /// silently produced no artwork on the receiver) becomes a real URL a
  /// Cast receiver can fetch, the same way its media URL already is.
  ///
  /// Deliberately more forgiving than [registerMedia]: returns null on
  /// any failure (couldn't read the file, no LAN address, server failed
  /// to bind) instead of throwing — missing cover art shouldn't ever be
  /// the reason a whole cast attempt fails. [localPath] is always a
  /// plain on-disk path here (ExternalMediaHandler's own cache file),
  /// never a `content://` Uri, so this skips straight to
  /// [_resolveReadableSource]'s plain-path branch rather than needing the
  /// fd-bridging [registerMedia] handles for a MediaStore/Open-With
  /// source file.
  Future<Uri?> registerLocalImage({
    required String title,
    required String localPath,
  }) async {
    try {
      // PHASE 2 (F2.5): one route per cover file, however often it is cast.
      final reuseKey = 'art|$localPath';
      final reused = await _reuseRoute(reuseKey);
      if (reused != null) return reused;

      final resolved =
          await _resolveReadableSource(localPath, title, 'image/jpeg');

      await _ensureRunning();
      if (_lanIp == null || _server == null) {
        final fd = resolved.fd;
        if (fd != null) unawaited(LocalMediaBridge.instance.closeContentFd(fd));
        return null;
      }

      final token = _newToken();
      _addRoute(token, resolved, 'art.jpg', reuseKey: reuseKey);
      // PHASE 0: the route is declared image/jpeg whatever the file really
      // is (finding F1.4) — log what the bytes actually are.
      unawaited(_logImageFormat(title, resolved));
      return _urlFor(token, 'art.jpg');
    } catch (e) {
      debugPrint('LocalCastServer.registerLocalImage failed for '
          '"$title": $e');
      return null;
    }
  }

  // ── PHASE 3: covers prepared for DLNA TVs (see `CastArtwork`) ──────────

  /// The URL of the live cover route registered under [key] (rebuilt on the
  /// phone's current address), or null when there is none.
  Future<Uri?> reuseCoverRoute(String key) async {
    try {
      return await _reuseRoute('cover|$key');
    } catch (_) {
      return null;
    }
  }

  /// Serves an already-prepared JPEG [bytes] as `.../art.jpg` with the
  /// correct type and length, and returns its URL (the live route's URL
  /// when [key] was registered before). Null when there is no local address
  /// to serve from — a missing cover must never fail a cast.
  Future<Uri?> registerCoverJpeg({
    required String key,
    required Uint8List bytes,
  }) async {
    try {
      final reuseKey = 'cover|$key';
      final reused = await _reuseRoute(reuseKey);
      if (reused != null) return reused;

      await _ensureRunning();
      if (_lanIp == null || _server == null) return null;

      final token = _newToken();
      _addRoute(
        token,
        _ServedFile(bytes: bytes, contentType: 'image/jpeg'),
        'art.jpg',
        reuseKey: reuseKey,
      );
      return _urlFor(token, 'art.jpg');
    } catch (e) {
      debugPrint('LocalCastServer.registerCoverJpeg failed: $e');
      return null;
    }
  }

  /// The bytes behind a route of this server (a local item's cover that
  /// [registerLocalImage] registered), or null when [url] isn't one of its
  /// routes, is gone, or is larger than [maxBytes].
  Future<Uint8List?> readRouteBytes(String url,
      {int maxBytes = 25 * 1024 * 1024}) async {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.pathSegments.isEmpty) return null;
    final served = _routes[uri.pathSegments.first];
    if (served == null) return null;
    final mem = served.bytes;
    if (mem != null) return mem.length <= maxBytes ? mem : null;
    final path = served.path;
    if (path == null) return null;
    try {
      final file = File(path);
      if (await file.length() > maxBytes) return null;
      return await file.readAsBytes();
    } catch (e) {
      debugPrint('LocalCastServer.readRouteBytes failed: $e');
      return null;
    }
  }

  /// CASTING FIX (OpenSubtitles/Open-With sidecar subtitles invisible on
  /// the TV): a subtitle for one of these items — an OpenSubtitles
  /// search result, a downloaded movie/episode's own saved sidecar, or a
  /// same-named .srt/.vtt MainActivity.kt found next to an Open
  /// With/Play With source file — only ever exists as raw text sitting
  /// in this app's own memory (`SubtitleTrack.subtitleData`/
  /// `SidecarSubtitleContent`). None of that has a server-side stream
  /// index or hosted URL a Cast receiver could ever load, which is
  /// exactly why `PlaybackCoordinator`'s LOCAL -> REMOTE handoff used to
  /// have "genuinely nothing to carry over" for it. This closes that
  /// gap the same way [registerMedia] already does for the file itself:
  /// hand the text a real http(s) URL a receiver on the LAN can fetch,
  /// so it becomes an ordinary Cast sidecar text track like any other
  /// (see `GoogleCastTransport._subtitleTracksFor` and
  /// [kLocalCastSubtitleTrackId]).
  ///
  /// [content] can be either SRT or WebVTT — whatever PlayerManager
  /// already has in memory for the currently-selected subtitle, with no
  /// format check needed at the call site. Cast's Default Media Receiver
  /// only understands WebVTT/TTML sidecar tracks (unlike mpv locally,
  /// which is handed SRT directly via `SubtitleTrack.data()` — see
  /// PlayerManager.selectSubtitleTrack), so this converts SRT to VTT
  /// first when needed; content that's already WebVTT is served as-is.
  ///
  /// Deliberately as forgiving as [registerLocalImage]: returns null on
  /// any failure instead of throwing — a subtitle that can't be
  /// registered shouldn't ever be the reason a whole cast handoff fails,
  /// only the reason that one track doesn't show up on the TV.
  Future<Uri?> registerSubtitleText({
    required String title,
    required String content,
  }) async {
    try {
      final vtt = _ensureWebVtt(content);
      // No cue timing line at all (an .ass/.ssa sidecar, or garbage):
      // _srtToWebVtt would return just the "WEBVTT" header, which used
      // to register as a perfectly valid-looking but permanently silent
      // track. Better to not declare it than to offer a selectable
      // subtitle that can never show anything on the TV.
      if (vtt.trim().isEmpty || !vtt.contains('-->')) return null;
      final bytes = Uint8List.fromList(utf8.encode(vtt));

      await _ensureRunning();
      if (_lanIp == null || _server == null) return null;

      final token = _newToken();
      _addRoute(
        token,
        _ServedFile(bytes: bytes, contentType: 'text/vtt; charset=utf-8'),
        'sub.vtt',
      );
      return _urlFor(token, 'sub.vtt');
    } catch (e) {
      debugPrint(
          'LocalCastServer.registerSubtitleText failed for "$title": $e');
      return null;
    }
  }

  /// Passes WebVTT content through untouched; converts SRT (the format
  /// every OpenSubtitles download and most sidecar files already use —
  /// see PlayerManager._webvttToSrt's own doc comment on why *local*
  /// playback normalizes the other direction) to WebVTT for Cast. Only
  /// checks for the "WEBVTT" header rather than fully validating the
  /// format — a sidecar that's neither well-formed SRT nor WebVTT was
  /// never going to render correctly either way, and this at least never
  /// throws on it.
  static String _ensureWebVtt(String content) {
    // SIDECAR FIX: SRT, WebVTT and ASS/SSA all go through the shared
    // normaliser first (the TV only understands WebVTT, and an ASS sidecar
    // used to be dropped as "no cues"). A WebVTT file that normalises to
    // nothing is still passed through untouched, as before.
    final srt = SubtitleText.toSrt(content);
    if (srt.trim().isNotEmpty) return _srtToWebVtt(srt);
    if (content.trimLeft().toUpperCase().startsWith('WEBVTT')) {
      return content;
    }
    return _srtToWebVtt(content);
  }

  static final RegExp _srtTimeLine = RegExp(
    r'(\d{2}:\d{2}:\d{2}),(\d{3})\s*-->\s*(\d{2}:\d{2}:\d{2}),(\d{3})',
  );

  /// SRT's comma-decimal timestamps -> WebVTT's dot-decimal ones, plus
  /// the mandatory "WEBVTT" header SRT doesn't have. Mirrors
  /// PlayerManager._webvttToSrt's cue-by-cue approach exactly, just
  /// converting the opposite direction.
  static String _srtToWebVtt(String srt) {
    final lines =
        srt.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');

    final buffer = StringBuffer('WEBVTT\n\n');
    var i = 0;

    while (i < lines.length) {
      final match = _srtTimeLine.firstMatch(lines[i]);
      if (match != null) {
        final start = '${match.group(1)}.${match.group(2)}';
        final end = '${match.group(3)}.${match.group(4)}';

        buffer.writeln('$start --> $end');
        i++;

        while (i < lines.length && lines[i].trim().isNotEmpty) {
          buffer.writeln(lines[i]);
          i++;
        }
        buffer.writeln();
      } else {
        i++;
      }
    }

    return buffer.toString();
  }

  /// Ends the whole local-cast serving session: closes every open
  /// bridged fd, drops every route, and shuts the server down. Called
  /// unconditionally from `CastManager.disconnect()` — a no-op (cheap
  /// map/null checks only) whenever no local item was ever cast this
  /// session, since only one cast session is ever active at a time (see
  /// `CastManager.connect`'s own "disconnect any existing session
  /// first" rule) so there's never a second session still relying on
  /// these routes when this runs.
  Future<void> stopAll() async {
    if (_routes.isNotEmpty || _server != null) {
      // PHASE 0: what this session's routes did over their lifetime.
      debugPrint('LocalCastServer: stopping — ${_routes.length} route(s)');
      for (final e in _routes.entries) {
        final r = e.value;
        debugPrint('LocalCastServer:   ${_shortToken(e.key)} ${r.label} '
            '${r.requests} request(s), ${r.bytesSent} B sent, '
            '${r.aborted} aborted, last status ${r.lastStatus ?? '-'}');
      }
    }
    for (final served in _routes.values) {
      final fd = served.fd;
      if (fd != null) {
        unawaited(LocalMediaBridge.instance.closeContentFd(fd));
      }
      // Deletes an on-device MKV remux LocalVideoTranscodeService
      // created for this session (see registerMedia) — a real source
      // file (isTempFile == false) is left untouched, since this server
      // never owns those.
      // `isTempFile` is only ever set alongside a real on-disk `path`
      // (registerMedia's MKV remux output) — never for an in-memory
      // subtitle route (see `_ServedFile.bytes`), so the `!` here is
      // safe.
      if (served.isTempFile) {
        final tempPath = served.path!;
        unawaited(
          File(tempPath).delete().catchError((e) {
            debugPrint(
              'LocalCastServer.stopAll failed to delete temp file '
              '$tempPath: $e',
            );
            return File(tempPath);
          }),
        );
      }
    }
    _routes.clear();
    _tokenByReuseKey.clear();
    _peerHost = null;

    // NAMESIS PRIME: stop ffmpeg and delete the HLS folders of this session.
    final relays = _relays.values.toList();
    _relays.clear();
    _relayTokenByKey.clear();
    for (final relay in relays) {
      await relay.dispose();
    }

    final server = _server;
    _server = null;
    _lanIp = null;
    if (server != null) {
      try {
        await server.close(force: true);
      } catch (e) {
        debugPrint('LocalCastServer.stopAll failed to close server: $e');
      }
    }
  }

  // ── NAMESIS PRIME: addon streams (direct links and torrents) ──────────
  final Map<String, CastRelay> _relays = {};
  final Map<String, String> _relayTokenByKey = {};
  static const int _maxRelays = 6;

  /// Makes an addon stream reachable by a TV through this phone.
  ///
  /// [hls] false: the phone proxies [sourceUrl] as it is (seeking works) at
  /// `http://<phone>:<port>/<token>/stream.<ext>`.
  /// [hls] true: ffmpeg repackages it into HLS (video copied, audio to AAC
  /// stereo) in a temp folder; served at `.../stream.m3u8`. Needed for Google
  /// Cast, whose receiver cannot open MKV and friends. Returns once the first
  /// segments exist. Throws [LocalCastUnsupportedException] with a message
  /// safe to show when that does not work out.
  Future<Uri> registerAddonStream({
    required MediaItem item,
    required String sourceUrl,
    required Map<String, String> headers,
    required String contentType,
    required String extension,
    required bool hls,
  }) async {
    await _ensureRunning();
    final server = _server;
    if (server == null || _lanIp == null) {
      throw LocalCastUnsupportedException(
        'Couldn\'t find this device\'s network address to cast '
        '"${item.title}" - check that Wi-Fi is turned on.',
      );
    }

    final ext = extension.isEmpty ? 'mkv' : extension;
    final name = hls ? 'stream.m3u8' : 'stream.$ext';
    final key = '$sourceUrl|$contentType|$hls';
    final known = _relayTokenByKey[key];
    if (known != null && _relays.containsKey(known)) {
      return _urlFor(known, name);
    }

    final token = _newToken();

    if (!hls) {
      _relays[token] = CastRelay.remote(
        url: sourceUrl,
        headers: headers,
        contentType: contentType,
      );
      _relayTokenByKey[key] = token;
      _trimRelays(token);
      debugPrint('LocalCastServer: relay +direct ${_shortToken(token)}/$name '
          'type=$contentType');
      return _urlFor(token, name);
    }

    // Only one title plays on the TV at a time. Stop and delete the HLS
    // output of any earlier one BEFORE starting this ffmpeg: disposing a
    // directory relay calls FFmpegKit.cancel(), which stops EVERY running
    // ffmpeg session, so doing it afterwards killed the new stream.
    final staleTokens = [
      for (final e in _relays.entries)
        if (e.value.dir != null) e.key,
    ];
    for (final stale in staleTokens) {
      final relay = _relays.remove(stale);
      _relayTokenByKey.removeWhere((_, v) => v == stale);
      if (relay == null) continue;
      for (final dep in relay.dependsOn) {
        _relays.remove(dep);
        _relayTokenByKey.removeWhere((_, v) => v == dep);
      }
      await relay.dispose();
    }

    // The source relay is what ffmpeg reads (over loopback), so ffmpeg never
    // needs TLS, redirects or the addon's headers itself.
    final sourceToken = _newToken();
    _relays[sourceToken] = CastRelay.remote(
      url: sourceUrl,
      headers: headers,
      contentType: 'application/octet-stream',
    );
    final input = 'http://127.0.0.1:${server.port}/$sourceToken/stream.$ext';

    final tempDir = await getTemporaryDirectory();
    final dir = Directory(
        '${tempDir.path}/nemesis_cast_hls_${DateTime.now().millisecondsSinceEpoch}');
    await dir.create(recursive: true);

    final command = '-y -fflags +genpts -i "$input" '
        '-map 0:v:0 -map 0:a:0? -sn -dn '
        '-c:v copy -c:a aac -b:a 192k -ac 2 '
        '-f hls -hls_time 6 -hls_list_size 0 -hls_playlist_type event '
        '-hls_segment_filename "${dir.path}/stream_%05d.ts" '
        '"${dir.path}/stream.m3u8"';

    var finished = false;
    var succeeded = false;
    String? logTail;
    unawaited(() async {
      try {
        final session = await FFmpegKit.execute(command);
        final code = await session.getReturnCode();
        succeeded = ReturnCode.isSuccess(code);
        if (!succeeded && !ReturnCode.isCancel(code)) {
          final logs = await session.getAllLogsAsString() ?? '';
          logTail = logs.length > 600 ? logs.substring(logs.length - 600) : logs;
          debugPrint('LocalCastServer: HLS remux failed: $logTail');
        }
      } catch (e) {
        logTail = '$e';
      } finally {
        finished = true;
      }
    }());

    Future<void> cleanup() async {
      _relays.remove(sourceToken);
      try {
        await FFmpegKit.cancel();
      } catch (_) {}
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    }

    final playlist = File('${dir.path}/stream.m3u8');
    final deadline = DateTime.now().add(const Duration(seconds: 90));
    var ready = false;
    while (DateTime.now().isBefore(deadline)) {
      if (await playlist.exists()) {
        final text = await playlist.readAsString();
        if ('#EXTINF'.allMatches(text).length >= 2 ||
            text.contains('#EXT-X-ENDLIST')) {
          ready = true;
          break;
        }
      }
      if (finished && !succeeded) break;
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }

    if (!ready) {
      await cleanup();
      throw LocalCastUnsupportedException(
        finished && !succeeded
            ? '"${item.title}" can\'t be converted for Google Cast. Its '
                'video format (for example HEVC/10-bit) may not be supported '
                'by the TV, or the source stopped sending data.'
            : '"${item.title}" took too long to prepare for the TV. The '
                'source may be slow (a torrent needs peers) - try again '
                'in a minute.',
      );
    }

    _relays[token] = CastRelay.directory(
      dir: dir,
      onDispose: () async {
        try {
          await FFmpegKit.cancel();
        } catch (_) {}
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      },
    )..dependsOn.add(sourceToken);
    _relayTokenByKey[key] = token;
    _trimRelays(token);
    debugPrint('LocalCastServer: relay +hls ${_shortToken(token)}/$name');
    return _urlFor(token, name);
  }

  /// Keeps at most [_maxRelays] relays, releasing the oldest first.
  void _trimRelays(String keep) {
    while (_relays.length > _maxRelays) {
      final oldest = _relays.keys.firstWhere(
        (t) =>
            t != keep &&
            !(_relays[keep]?.dependsOn.contains(t) ?? false),
        orElse: () => '',
      );
      if (oldest.isEmpty) return;
      final relay = _relays.remove(oldest);
      _relayTokenByKey.removeWhere((_, v) => v == oldest);
      if (relay != null) {
        for (final dep in relay.dependsOn) {
          _relays.remove(dep);
        }
        unawaited(relay.dispose());
      }
    }
  }

  /// WebVTT -> SubRip (public wrapper, used by `DlnaTransport` to build the
  /// styled/shifted SRT it hands a TV).
  static String vttToSrt(String vtt) => _vttToSrt(vtt);

  /// True when [url] points at a route this server is serving.
  bool ownsUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.pathSegments.isEmpty) return false;
    return _routes.containsKey(uri.pathSegments.first) ||
        _relays.containsKey(uri.pathSegments.first);
  }

  /// The text of an in-memory route (a subtitle registered through
  /// [registerSubtitleText]) addressed by [url], or null for anything else.
  /// Lets `DlnaTransport` start from the exact text the coordinator
  /// registered — including its time-shifted "subtitle delay" variants.
  String? textForUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.pathSegments.isEmpty) return null;
    final bytes = _routes[uri.pathSegments.first]?.bytes;
    if (bytes == null) return null;
    return utf8.decode(bytes, allowMalformed: true);
  }

  /// Serves ready-made SubRip [content] to a DLNA renderer at
  /// `http://<lan-ip>:<port>/<token>/sub.srt`. Like [registerSubtitleText],
  /// returns null instead of throwing — a subtitle that can't be hosted
  /// must never be the reason a whole cast fails.
  Future<Uri?> registerSrtText({required String content}) async {
    try {
      if (content.trim().isEmpty || !content.contains('-->')) return null;
      await _ensureRunning();
      if (_lanIp == null || _server == null) return null;
      final token = _newToken();
      _addRoute(
        token,
        _ServedFile(
          bytes: Uint8List.fromList(utf8.encode(content)),
          contentType: 'application/x-subrip; charset=utf-8',
        ),
        'sub.srt',
      );
      return _urlFor(token, 'sub.srt');
    } catch (e) {
      debugPrint('LocalCastServer.registerSrtText failed: $e');
      return null;
    }
  }

  /// DLNA / Samsung: remembers [subtitleUrl] (an `.srt` URL) for the media
  /// route that [mediaUrl] points at, so the route can answer Samsung's
  /// `getCaptionInfo.sec: 1` request header with `CaptionInfo.sec: <url>`.
  /// A no-op for any URL this server doesn't own (e.g. a Jellyfin stream).
  void attachCaption(String mediaUrl, String? subtitleUrl) {
    final uri = Uri.tryParse(mediaUrl);
    if (uri == null || uri.pathSegments.isEmpty) return;
    final served = _routes[uri.pathSegments.first];
    if (served == null) return;
    served.captionUrl = subtitleUrl;
  }

  /// WebVTT -> SubRip, for DLNA renderers. Cue settings and `<c>`/`<v>`
  /// tags are dropped; `<i>`/`<b>`/`<u>` are kept (SRT supports them).
  static String _vttToSrt(String vtt) {
    final lines =
        vtt.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');
    final timing = RegExp(
      r'^\s*(?:(\d{1,2}):)?(\d{2}):(\d{2})[.,](\d{3})\s*-->\s*'
      r'(?:(\d{1,2}):)?(\d{2}):(\d{2})[.,](\d{3})',
    );
    final out = StringBuffer();
    var cue = 0;
    var i = 0;
    String hh(String? h) => (h ?? '0').padLeft(2, '0');
    while (i < lines.length) {
      final m = timing.firstMatch(lines[i]);
      if (m == null) {
        i++;
        continue;
      }
      cue++;
      out.writeln(cue);
      out.writeln(
        '${hh(m.group(1))}:${m.group(2)}:${m.group(3)},${m.group(4)} --> '
        '${hh(m.group(5))}:${m.group(6)}:${m.group(7)},${m.group(8)}',
      );
      i++;
      while (i < lines.length && lines[i].trim().isNotEmpty) {
        out.writeln(
          lines[i]
              .replaceAll(RegExp(r'</?c(\.[^>]*)?>'), '')
              .replaceAll(RegExp(r'<v[^>]*>'), '')
              .replaceAll('</v>', ''),
        );
        i++;
      }
      out.writeln();
    }
    return out.toString();
  }

  /// Re-reads the phone's network addresses and re-picks the one the TV can
  /// reach. Called on every registration, so a Wi-Fi reconnect, a hotspot
  /// being switched on or a VPN appearing never leaves routes advertised on
  /// an address the TV cannot use (F2.3). The server itself listens on every
  /// interface, so only the address put into the URLs changes.
  Future<void> _refreshLanIp() async {
    _lanIp = await _resolveLanIp();
  }

  Future<void> _ensureRunning() async {
    if (_isRunning) {
      await _refreshLanIp();
      return;
    }

    await _refreshLanIp();

    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    } catch (e) {
      debugPrint('LocalCastServer failed to bind: $e');
      _server = null;
      return;
    }

    debugPrint('LocalCastServer: listening on '
        '${_lanIp ?? '(no LAN address)'}:${_server!.port}');
    _server!.listen(
      (request) {
        unawaited(_handleRequest(request));
      },
      onError: (e) {
        debugPrint('LocalCastServer server error: $e');
      },
    );
  }

  /// PHASE 0 (DIAGNOSTICS ONLY): logs one line per request — method, route
  /// kind, Range, who asked, what was answered and how it ended. Nothing
  /// here changes a response.
  void _logRequest(
    HttpRequest request,
    _ServedFile? served,
    DateTime startedAt,
    int sentBytes,
    String outcome,
  ) {
    try {
      final segs = request.uri.pathSegments;
      final token = segs.isNotEmpty ? segs.first : '';
      final name = segs.length > 1 ? segs.last : '';
      final range = request.headers.value(HttpHeaders.rangeHeader);
      final ua = request.headers.value(HttpHeaders.userAgentHeader);
      final peer = request.connectionInfo?.remoteAddress.address;
      final ms = DateTime.now().difference(startedAt).inMilliseconds;
      debugPrint('LocalCastServer: ${request.method} '
          '${served?.label ?? 'UNKNOWN-ROUTE'} '
          '${_shortToken(token)}/$name '
          'from=${peer ?? '?'} ua="${ua ?? '-'}" '
          'range=${range ?? '-'} '
          '-> ${request.response.statusCode} sent=$sentBytes B in ${ms} ms '
          '[$outcome]');
    } catch (_) {
      // Logging must never be what breaks a response.
    }
  }

  Future<void> _handleRequest(HttpRequest request) async {
    final startedAt = DateTime.now();
    var sentBytes = 0;
    var outcome = 'completed';
    _ServedFile? servedForLog;
    try {
      // CASTING FIX (Open With/Play With subtitles never show on the TV):
      // ROOT CAUSE — the Cast receiver (Default Media Receiver) does NOT
      // load a text track through the <video> element the way it plays
      // the video file itself; it fetches the WebVTT with a cross-origin
      // XHR/fetch from its own origin, and the browser silently drops
      // that response unless the server answers with CORS headers.
      // Jellyfin's own `Stream.vtt` endpoint always sends
      // `Access-Control-Allow-Origin`, which is exactly why subtitles
      // worked for the app's server movies/episodes — while this
      // server (the one that hosts the phone's sidecar / OpenSubtitles
      // text as `.../sub.vtt`) sent none, so every declared local
      // track "existed" on the TV but never rendered a single cue.
      // Applied to EVERY response (media, artwork, subtitles, 404s) so
      // no route can ever be the odd one out again.
      request.response.headers
        ..set('Access-Control-Allow-Origin', '*')
        ..set('Access-Control-Allow-Methods', 'GET, HEAD, OPTIONS')
        ..set('Access-Control-Allow-Headers', 'Range, Content-Type, Origin')
        ..set('Access-Control-Expose-Headers',
            'Content-Length, Content-Range, Accept-Ranges, Content-Type');

      // CORS preflight — some receiver versions send one before fetching
      // a text track (it carries no route data worth resolving).
      if (request.method == 'OPTIONS') {
        outcome = 'cors-preflight';
        request.response.statusCode = HttpStatus.noContent;
        await request.response.close();
        return;
      }

      final segments = request.uri.pathSegments;
      final token = segments.isNotEmpty ? segments.first : null;

      // NAMESIS PRIME: addon-stream relays (see addon_cast_relay.dart).
      final relay = token != null ? _relays[token] : null;
      if (relay != null) {
        outcome = await serveCastRelay(request, relay);
        sentBytes = relay.bytesSent;
        return;
      }

      final served = token != null ? _routes[token] : null;

      if (served == null) {
        // A token this server doesn't know: a stale URL from an earlier
        // server lifetime, or a guess.
        outcome = 'unknown-route';
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      servedForLog = served;
      served.requests++;
      if (request.headers.value(HttpHeaders.rangeHeader) != null) {
        served.rangeRequests++;
      }

      // CASTING FIX (OpenSubtitles/Open-With sidecar subtitles invisible
      // on the TV): a route registered via [registerSubtitleText] has no
      // backing file at all — `served.path` is null, `served.bytes` is
      // the whole response body already sitting in memory. Every other
      // route (media, artwork, an MKV remux) is still file-backed, so
      // this only branches at the point the two genuinely diverge
      // (getting a length, and later opening a byte range to stream) —
      // everything else below (Range parsing, headers, HEAD handling)
      // is identical either way.
      final file = served.path != null ? File(served.path!) : null;
      final int length;

      // DLNA TVs only understand SRT, not WebVTT: the in-memory subtitle
      // route is registered once as `.../sub.vtt`, and the very same token
      // is also answered as `.../sub.srt` (converted on the fly).
      var memBytes = served.bytes;
      var responseContentType = served.contentType;
      if (memBytes != null &&
          request.uri.path.toLowerCase().endsWith('.srt')) {
        memBytes = Uint8List.fromList(
          utf8.encode(
            _vttToSrt(utf8.decode(memBytes, allowMalformed: true)),
          ),
        );
        responseContentType = 'application/x-subrip; charset=utf-8';
      }

      if (file != null) {
        try {
          length = await file.length();
        } catch (e) {
          // The fd-backed /proc/self/fd path stops resolving if the fd
          // was already closed (stopAll ran mid-request) or the source
          // file was deleted/revoked out from under us — either way,
          // nothing left to serve.
          outcome = 'file-unreadable: $e';
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
          return;
        }
      } else {
        length = memBytes!.length;
      }

      var start = 0;
      var end = length - 1;
      var isPartial = false;

      final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
      // A single `bytes=` range is honoured; anything else (several ranges,
      // garbage) is ignored and the whole body is served, which HTTP allows.
      if (length > 0 &&
          rangeHeader != null &&
          rangeHeader.startsWith('bytes=') &&
          !rangeHeader.contains(',')) {
        final range = rangeHeader.substring(6).trim().split('-');
        final rangeStart = range.isNotEmpty ? range[0].trim() : '';
        final rangeEnd = range.length > 1 ? range[1].trim() : '';

        if (rangeStart.isEmpty && rangeEnd.isNotEmpty) {
          // Suffix range ("last N bytes") — TVs read the tail of an MP4 /
          // MP3 this way to find the index / ID3v1 tag.
          final suffixLength = int.tryParse(rangeEnd) ?? 0;
          if (suffixLength > 0) {
            start = length - suffixLength;
            if (start < 0) start = 0;
            end = length - 1;
            isPartial = true;
          }
        } else if (rangeStart.isNotEmpty) {
          final parsedStart = int.tryParse(rangeStart);
          if (parsedStart != null && parsedStart >= 0) {
            if (parsedStart >= length) {
              // Starts beyond the end: say so, as a strict client expects,
              // instead of quietly answering with the last byte.
              outcome = 'range-not-satisfiable';
              request.response.statusCode =
                  HttpStatus.requestedRangeNotSatisfiable;
              request.response.headers.set(
                  'Content-Range', 'bytes */$length',
                  preserveHeaderCase: true);
              request.response.contentLength = 0;
              await request.response.close();
              return;
            }
            var parsedEnd = rangeEnd.isEmpty
                ? length - 1
                : (int.tryParse(rangeEnd) ?? (length - 1));
            if (parsedEnd >= length) parsedEnd = length - 1;
            if (parsedEnd >= parsedStart) {
              start = parsedStart;
              end = parsedEnd;
              isPartial = true;
            }
          }
        }
      }

      // ROOT CAUSE (a TV's own DLNA receiver won't play anything this phone
      // serves, while Kodi / AirScreen do): dart:io writes every response
      // header name in LOWER case (`content-length`, `content-type`,
      // `accept-ranges`, `content-range`) unless asked not to. HTTP header
      // names are case-insensitive, and Kodi / AirScreen / ExoPlayer honour
      // that — but several TV firmware HTTP stacks look the names up with
      // their canonical spelling and then see a response with no length, no
      // type and no range support, so they never start the stream. The
      // canonical spelling is now written, exactly like the SOAP requests
      // to the TV already do.
      final bodyLength = end - start + 1;
      final responseHeaders = request.response.headers;
      responseHeaders
        ..set('Accept-Ranges', 'bytes', preserveHeaderCase: true)
        ..set('Content-Type', responseContentType, preserveHeaderCase: true);
      // The plain setter first: it is what stops dart:io from falling back
      // to chunked encoding. The canonical-case re-set can only refine the
      // header's spelling; if it were ever refused, the plain value stands.
      request.response.contentLength = bodyLength;
      try {
        responseHeaders.set('Content-Length', '$bodyLength',
            preserveHeaderCase: true);
      } catch (_) {
        request.response.contentLength = bodyLength;
      }

      // DLNA handshake headers (ignored by Google Cast). Only answered when
      // the renderer asked for them, as the DLNA spec requires.
      if (responseContentType.startsWith('video/') ||
          responseContentType.startsWith('audio/')) {
        final h = request.response.headers;
        // PHASE 2 (F2.6): these used to be sent only to a client that asked
        // for them (`getcontentFeatures.dlna.org: 1`). Some renderers never
        // send that request header yet still judge the stream by the
        // answer, so every media response now carries them. Clients that
        // do not know DLNA ignore them.
        h.set('transferMode.dlna.org', 'Streaming', preserveHeaderCase: true);
        h.set(
          'contentFeatures.dlna.org',
          'DLNA.ORG_OP=01;DLNA.ORG_CI=0;'
              'DLNA.ORG_FLAGS=01700000000000000000000000000000',
          preserveHeaderCase: true,
        );
        final caption = served.captionUrl;
        if (caption != null &&
            request.headers.value('getCaptionInfo.sec') == '1') {
          h.set('CaptionInfo.sec', caption, preserveHeaderCase: true);
        }
      }

      if (isPartial) {
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set(
            'Content-Range', 'bytes $start-$end/$length',
            preserveHeaderCase: true);
      } else {
        request.response.statusCode = HttpStatus.ok;
      }

      if (request.method == 'HEAD') {
        outcome = 'head';
        await request.response.close();
        return;
      }

      if (file != null) {
        // Counting wrapper: when the client hangs up mid-body the byte count
        // says how far it got (PHASE 0 diagnostics).
        await request.response.addStream(
          file.openRead(start, end + 1).map((chunk) {
            sentBytes += chunk.length;
            served.bytesSent += chunk.length;
            return chunk;
          }),
        );
      } else {
        request.response.add(memBytes!.sublist(start, end + 1));
        sentBytes += bodyLength;
        served.bytesSent += bodyLength;
      }
      await request.response.close();
    } catch (e) {
      // A receiver aborting/re-requesting mid-seek (closing the
      // connection before this finishes writing) throws here on the
      // response stream — expected, frequent during scrubbing, and not
      // an error worth doing anything more than logging.
      debugPrint('LocalCastServer request failed: $e');
      outcome = 'aborted: $e';
      servedForLog?.aborted++;
      try {
        await request.response.close();
      } catch (_) {}
    } finally {
      servedForLog?.lastStatus = request.response.statusCode;
      _logRequest(request, servedForLog, startedAt, sentBytes, outcome);
    }
  }

  /// Resolves [sourceUri] — [MediaItem.streamUrl] for a local item,
  /// either a `content://` URI (the common case: an on_audio_query
  /// MediaStore song, or an Open With file handed over by another app's
  /// FileProvider) or a plain filesystem path/`file://` URI — to
  /// something `dart:io` can actually open and seek within.
  Future<_ServedFile> _resolveReadableSource(
    String sourceUri,
    String title,
    String contentType,
  ) async {
    final parsed = Uri.tryParse(sourceUri);

    if (parsed != null && parsed.scheme == 'content') {
      final fd = await LocalMediaBridge.instance.openContentFd(sourceUri);
      if (fd == null) {
        throw LocalCastUnsupportedException(
          '"$title" couldn\'t be opened to cast it — the app doesn\'t '
          'currently have a way to read this file\'s bytes for the TV. '
          '(Requires the openContentFd native bridge — see the casting '
          'handoff notes.)',
        );
      }
      final procPath = '/proc/self/fd/$fd';
      if (!await File(procPath).exists()) {
        await LocalMediaBridge.instance.closeContentFd(fd);
        throw LocalCastUnsupportedException(
          '"$title" couldn\'t be read to cast it.',
        );
      }
      // PHASE 2 (F2.6): reading through /proc/self/fd/N opens the file a
      // second time, and Android re-checks permissions on that open. It works
      // for a MediaStore file, but can be refused for a file another app
      // handed over (Open With) that only the original descriptor may read.
      // Finding that out now gives a precise reason; otherwise the TV would
      // just be answered 404 later and the person would see "couldn't be
      // cast" with no explanation.
      try {
        final probe = await File(procPath).open();
        await probe.close();
      } on FileSystemException catch (e) {
        await LocalMediaBridge.instance.closeContentFd(fd);
        throw LocalCastUnsupportedException(
          '"$title" belongs to another app, which only lets this app read '
          'it directly, so it can\'t be handed to the TV '
          '(${e.osError?.message ?? e.message}). Copy it to your '
          'phone\'s storage and open it from there.',
        );
      }
      return _ServedFile(path: procPath, contentType: contentType, fd: fd);
    }

    // A plain absolute path, or a file:// URI — either way, something
    // dart:io's File can already open directly.
    final path = (parsed != null && parsed.scheme == 'file')
        ? parsed.toFilePath()
        : sourceUri;

    if (!await File(path).exists()) {
      throw LocalCastUnsupportedException(
        '"$title" couldn\'t be found on this device to cast it.',
      );
    }
    return _ServedFile(path: path, contentType: contentType);
  }

  String _newToken() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// The last address chosen, so the log only speaks when it changes.
  String? _lastLoggedChoice;

  /// Picks the address a TV could actually reach this phone on.
  ///
  /// PHASE 2 (F2.3): when the TV's own address is known ([setPeerHint]) the
  /// phone address on the TV's subnet wins — same /24 first, then same /16 —
  /// so a hotspot, a second Wi-Fi interface, a VPN or a Wi-Fi reconnect can
  /// no longer leave the URLs on a network the TV is not on. Without a hint,
  /// or when nothing matches, it falls back to the old preference: an
  /// interface that looks like Wi-Fi (`wlan`/`swlan`/`ap`/`eth` — Android's
  /// usual names) over whatever else `NetworkInterface.list` reports first
  /// (e.g. a mobile-data `rmnet` interface a TV could never route to), and
  /// finally the first non-loopback IPv4 address, since some OEMs name their
  /// Wi-Fi interface differently.
  Future<String?> _resolveLanIp() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLinkLocal: false,
        includeLoopback: false,
      );

      final all = <({String iface, String ip})>[
        for (final iface in interfaces)
          for (final addr in iface.addresses)
            if (!addr.isLoopback) (iface: iface.name, ip: addr.address),
      ];
      final candidates = [for (final c in all) '${c.iface}=${c.ip}'];

      String? chosen;
      String why = 'fallback';

      final peer = _peerHost;
      final peerParts = peer?.split('.');
      if (peerParts != null && peerParts.length == 4) {
        bool sharePrefix(String ip, int octets) {
          final p = ip.split('.');
          if (p.length != 4) return false;
          for (var i = 0; i < octets; i++) {
            if (p[i] != peerParts[i]) return false;
          }
          return true;
        }

        for (final c in all) {
          if (sharePrefix(c.ip, 3)) {
            chosen = c.ip;
            why = 'same /24 as the TV (${c.iface})';
            break;
          }
        }
        if (chosen == null) {
          for (final c in all) {
            if (sharePrefix(c.ip, 2)) {
              chosen = c.ip;
              why = 'same /16 as the TV (${c.iface})';
              break;
            }
          }
        }
      }

      if (chosen == null) {
        final wifiLike =
            RegExp(r'^(wlan|swlan|ap|eth)', caseSensitive: false);
        for (final c in all) {
          if (wifiLike.hasMatch(c.iface)) {
            chosen = c.ip;
            why = 'Wi-Fi-looking interface (${c.iface})';
            break;
          }
        }
        if (chosen == null && all.isNotEmpty) {
          chosen = all.first.ip;
          why = 'first interface (${all.first.iface})';
        }
      }

      final summary = '${chosen ?? 'none'} [$why]';
      if (summary != _lastLoggedChoice) {
        _lastLoggedChoice = summary;
        debugPrint('LocalCastServer: LAN address candidates '
            '[${candidates.join(', ')}] — TV=${peer ?? '?'} — '
            'chose $summary');
      }
      return chosen;
    } catch (e) {
      debugPrint('LocalCastServer failed to resolve LAN IP: $e');
      return null;
    }
  }
}
