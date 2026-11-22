import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:ffmpeg_kit_flutter_new_min/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min/return_code.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../player/models/media_item.dart';
import '../services/jellyfin_services/jellyfin_client.dart';
import '../services/jellyfin_services/media_service.dart';
import '../utils/artwork_source.dart';
import 'local_cast_server.dart';

/// PHASE 3 (artwork on DLNA renderers, AirScreen in particular).
///
/// A cover that is ready for a TV: a small baseline JPEG served by THIS
/// phone's [LocalCastServer] at `http://<phone>:<port>/<token>/art.jpg`.
class CastCover {
  const CastCover({
    required this.url,
    required this.bytes,
    required this.source,
    this.width,
    this.height,
  });

  /// Where the TV fetches the cover from (the phone's own server).
  final String url;

  /// Size of the JPEG that is served.
  final int bytes;
  final int? width;
  final int? height;

  /// Human-readable origin, for the log ("song art", "album art"…).
  final String source;

  /// `resolution="WxH"` for the image `<res>`, or null when unknown.
  String? get resolution =>
      (width != null && height != null) ? '${width}x$height' : null;

  /// DLNA image profile that matches the picture's pixel size.
  String get dlnaProfile {
    final w = width, h = height;
    if (w == null || h == null) return 'JPEG_MED';
    if (w <= 160 && h <= 160) return 'JPEG_TN';
    if (w <= 640 && h <= 480) return 'JPEG_SM';
    if (w <= 1024 && h <= 768) return 'JPEG_MED';
    return 'JPEG_LRG';
  }
}

/// PHASE 3 (F1.2, F1.3, F1.4): prepares the cover for a DLNA TV.
///
/// WHY: the TV used to be handed Jellyfin's own image URL (server-side
/// resizing, an api_key in the URL, possibly https, WebP/PNG depending on the
/// request), or — for a local song — the raw embedded picture declared as
/// `image/jpeg` whatever it really was. A simple renderer's image loader
/// (AirScreen) fails silently on any of those. Now the PHONE does the work:
///
///   1. finds the best picture (the song's own, else its album's; a poster
///      for a video; the cached cover of a local file),
///   2. fetches or reads it,
///   3. converts it to a small baseline JPEG (long side at most 600 px) with
///      the FFmpeg that is already in the app (no new package),
///   4. serves it from the phone's server with the right type and length.
///
/// The TV then fetches a tiny, plain, same-network JPEG: no token, no https,
/// no server-side resize, no 404 for a song that only has album art.
///
/// This never throws and never rewrites the app's [MediaItem]: the result is
/// used only to build the metadata sent to the TV. When nothing can be
/// prepared the caller falls back to the old behaviour.
class CastArtwork {
  CastArtwork._();
  static final CastArtwork instance = CastArtwork._();

  /// Long side, in pixels, of the cover handed to a TV.
  static const int _maxSide = 600;

  /// A baseline JPEG at most this large (long side, bytes) is already fine
  /// for a TV and is passed through without another encode.
  static const int _passThroughSide = 900;
  static const int _passThroughBytes = 400 * 1024;

  static const int _maxSourceBytes = 25 * 1024 * 1024;
  static const Duration _fetchTimeout = Duration(seconds: 9);
  static const Duration _convertTimeout = Duration(seconds: 12);

  /// Source keys known to have no usable picture (a 404, not an image, an
  /// unreadable file), so a song without art isn't asked about again on
  /// every load. Cleared by [reset].
  final Set<String> _missing = <String>{};
  static const int _maxMissing = 200;

  /// Size of what a cached route serves, by key. The route itself lives in
  /// [LocalCastServer] (and is dropped with it).
  final Map<String, ({int? w, int? h, int bytes, String source})> _meta = {};
  static const int _maxMeta = 64;

  static final Dio _plainDio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 6),
      receiveTimeout: const Duration(seconds: 8),
      responseType: ResponseType.bytes,
      validateStatus: (_) => true,
    ),
  );

  /// Forgets what was learned about missing pictures. Called when a new TV
  /// connection starts.
  void reset() {
    _missing.clear();
    _meta.clear();
  }

  /// The cover for [item], ready to be declared to a TV, or null when there
  /// is none (or it could not be prepared). Never throws.
  Future<CastCover?> prepare(MediaItem item) async {
    final started = DateTime.now();
    try {
      final sources = _sourcesFor(item);
      if (sources.isEmpty) {
        debugPrint('CastArtwork: "${item.title}" has no cover to send');
        return null;
      }
      for (final src in sources) {
        final cover = await _fromSource(item, src);
        if (cover != null) {
          debugPrint('CastArtwork: "${item.title}" cover ready from '
              '${cover.source} — ${cover.width ?? '?'}x${cover.height ?? '?'}, '
              '${cover.bytes} B JPEG in '
              '${DateTime.now().difference(started).inMilliseconds} ms');
          return cover;
        }
      }
      debugPrint('CastArtwork: "${item.title}" — none of ${sources.length} '
          'cover source(s) could be prepared '
          '(${sources.map((s) => s.label).join(', ')})');
    } catch (e) {
      debugPrint('CastArtwork: "${item.title}" cover preparation failed: $e');
    }
    return null;
  }

  // ── where a cover can come from ───────────────────────────────────────

  List<_Src> _sourcesFor(MediaItem item) {
    final out = <_Src>[];
    void add(String? ref, String label) {
      if (ref == null || ref.isEmpty) return;
      if (out.any((s) => s.ref == ref)) return;
      out.add(_Src(ref, label));
    }

    // A local song / Open With video: the cover (or the video's cached first
    // frame). By the time the transport sees the item this is usually a URL
    // of this phone's own server, which is read back from the server.
    if (item.isLocal) {
      add(item.image, 'local cover');
      add(item.backdrop, 'local backdrop');
      return out;
    }

    if (item.audioOnly) {
      final raw = item.raw;
      final tags = raw?['ImageTags'];
      // A song with no Primary image of its own would answer 404 (F1.3) —
      // skip straight to its album instead of asking first.
      final ownImage = !(tags is Map && !tags.containsKey('Primary'));
      final albumId = (raw?['AlbumId'] ?? raw?['ParentId'])?.toString();
      if (ownImage) add(item.image, 'song art');
      if (albumId != null && albumId.isNotEmpty) {
        add(MediaService.getPrimaryImage(albumId), 'album art');
      }
      // Last resort: whatever the item itself carried.
      add(item.image, 'song art');
      return out;
    }

    add(item.image, 'poster');
    add(item.seriesImage, 'series poster');
    add(item.backdrop, 'backdrop');
    return out;
  }

  Future<CastCover?> _fromSource(MediaItem item, _Src src) async {
    final key = await _keyFor(src);
    if (key == null) {
      return null; // unreadable reference (content:// or a missing file)
    }
    if (_missing.contains(key)) return null;

    // Same picture already prepared and still served: hand back its URL
    // (rebuilt on the phone's current address by the server).
    final meta = _meta[key];
    if (meta != null) {
      final reused = await LocalCastServer.instance.reuseCoverRoute(key);
      if (reused != null) {
        return CastCover(
          url: reused.toString(),
          bytes: meta.bytes,
          width: meta.w,
          height: meta.h,
          source: '${meta.source} (cached)',
        );
      }
    }

    final read = await _read(src);
    final raw = read.bytes;
    if (raw == null) {
      if (read.permanent) _markMissing(key);
      return null;
    }

    final jpeg = await _toBaselineJpeg(raw, item.title, src.label);
    if (jpeg == null) {
      _markMissing(key);
      return null;
    }

    final uri = await LocalCastServer.instance
        .registerCoverJpeg(key: key, bytes: jpeg.bytes);
    if (uri == null) return null; // no LAN address: not the picture's fault

    if (_meta.length >= _maxMeta) _meta.remove(_meta.keys.first);
    _meta[key] = (
      w: jpeg.width,
      h: jpeg.height,
      bytes: jpeg.bytes.length,
      source: src.label,
    );
    return CastCover(
      url: uri.toString(),
      bytes: jpeg.bytes.length,
      width: jpeg.width,
      height: jpeg.height,
      source: src.label,
    );
  }

  void _markMissing(String key) {
    if (_missing.length >= _maxMissing) _missing.clear();
    _missing.add(key);
  }

  // ── reading the source picture ────────────────────────────────────────

  /// A stable identity for the source, without anything secret in it.
  Future<String?> _keyFor(_Src src) async {
    final ref = src.ref;
    if (isRemoteArtwork(ref)) {
      final uri = Uri.tryParse(ref);
      if (uri == null) return null;
      if (LocalCastServer.isPhoneServerUrl(ref)) {
        if (uri.pathSegments.isEmpty) return null;
        return 'p|${uri.pathSegments.first}';
      }
      final params = uri.queryParameters.entries
          .where((e) => !_isSecretParam(e.key))
          .map((e) => '${e.key}=${e.value}')
          .toList()
        ..sort();
      return 'u|${uri.host}:${uri.port}${uri.path}?${params.join('&')}';
    }
    final path = _filePath(ref);
    if (path == null) return null;
    try {
      final stat = await File(path).stat();
      if (stat.type == FileSystemEntityType.notFound) return null;
      return 'f|$path|${stat.modified.millisecondsSinceEpoch}|${stat.size}';
    } catch (_) {
      return null;
    }
  }

  static bool _isSecretParam(String name) {
    final n = name.toLowerCase();
    return n == 'api_key' || n == 'apikey' || n == 'token';
  }

  /// A plain path from a path / `file://` reference; null for `content://`
  /// (not readable from here) and anything else.
  static String? _filePath(String ref) {
    final uri = Uri.tryParse(ref);
    if (uri != null && uri.scheme == 'file') return uri.toFilePath();
    if (uri != null && uri.scheme.isNotEmpty && uri.scheme.length > 1) {
      return null; // content://, asset:… — not a path
    }
    return ref;
  }

  Future<({Uint8List? bytes, bool permanent})> _read(_Src src) async {
    final ref = src.ref;
    try {
      if (isRemoteArtwork(ref)) {
        if (LocalCastServer.isPhoneServerUrl(ref)) {
          final bytes = await LocalCastServer.instance
              .readRouteBytes(ref, maxBytes: _maxSourceBytes);
          return (bytes: bytes, permanent: false);
        }
        return await _fetch(ref).timeout(_fetchTimeout);
      }
      final path = _filePath(ref);
      if (path == null) return (bytes: null, permanent: true);
      final file = File(path);
      final length = await file.length();
      if (length <= 0 || length > _maxSourceBytes) {
        return (bytes: null, permanent: true);
      }
      return (bytes: await file.readAsBytes(), permanent: false);
    } on TimeoutException {
      debugPrint('CastArtwork: timed out reading ${src.label}');
      return (bytes: null, permanent: false);
    } catch (e) {
      debugPrint('CastArtwork: could not read ${src.label}: $e');
      return (bytes: null, permanent: false);
    }
  }

  /// Asks the server for a small JPEG of a Jellyfin image; any other URL is
  /// fetched as it is.
  Future<({Uint8List? bytes, bool permanent})> _fetch(String url) async {
    final tvUrl = _jpegUrl(url);
    final server = JellyfinClient.serverUrl;
    final isServer = server.isNotEmpty && tvUrl.startsWith(server);
    // Only the Jellyfin server gets the app's own client (its certificate
    // handling and auth); any other host is fetched without the token.
    final dio = isServer ? JellyfinClient.dio : _plainDio;
    final res = await dio.get<List<int>>(
      tvUrl,
      options: Options(
        responseType: ResponseType.bytes,
        receiveTimeout: const Duration(seconds: 8),
      ),
    );
    final status = res.statusCode ?? 0;
    final data = res.data;
    if (status == 200 && data != null && data.isNotEmpty) {
      return (
        bytes: data is Uint8List ? data : Uint8List.fromList(data),
        permanent: false,
      );
    }
    debugPrint('CastArtwork: image request answered $status '
        '(${data?.length ?? 0} B) for ${_redactUrl(tvUrl)}');
    // 404 / 204: the item simply has no such picture.
    return (bytes: null, permanent: status == 404 || status == 204);
  }

  /// A Jellyfin image URL asked for as a JPEG no wider than the cover size.
  static String _jpegUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.path.contains('/Images/')) return url;
    final params = Map<String, String>.of(uri.queryParameters)
      ..removeWhere((k, _) => k.toLowerCase() == 'format');
    params['format'] = 'Jpg';
    final width = int.tryParse(params['maxWidth'] ?? '');
    if (width == null || width > _maxSide) params['maxWidth'] = '$_maxSide';
    return uri.replace(queryParameters: params).toString();
  }

  static String _redactUrl(String s) => s.replaceAllMapped(
        RegExp(r'(api_key|apikey|token)=[^&\s]+', caseSensitive: false),
        (m) => '${m.group(1)}=***',
      );

  // ── conversion ────────────────────────────────────────────────────────

  Future<({Uint8List bytes, int? width, int? height})?> _toBaselineJpeg(
    Uint8List src,
    String title,
    String label,
  ) async {
    final info = _inspect(src);
    if (info.kind == _ImgKind.unknown) {
      debugPrint('CastArtwork: $label for "$title" is not a picture the '
          'phone recognises (${src.length} B) — ignored');
      return null;
    }

    // Already a small baseline JPEG: nothing to improve.
    if (info.kind == _ImgKind.jpeg &&
        !info.progressive &&
        info.width != null &&
        info.height != null &&
        math.max(info.width!, info.height!) <= _passThroughSide &&
        src.length <= _passThroughBytes) {
      return (bytes: src, width: info.width, height: info.height);
    }

    final converted = await _convertWithFfmpeg(src, title);
    if (converted != null) {
      final out = _inspect(converted);
      debugPrint('CastArtwork: $label for "$title": ${info.kind.name} '
          '${info.width ?? '?'}x${info.height ?? '?'} ${src.length} B -> '
          'baseline JPEG ${out.width ?? '?'}x${out.height ?? '?'} '
          '${converted.length} B');
      return (bytes: converted, width: out.width, height: out.height);
    }

    // Could not convert: a JPEG is still better for a TV than nothing.
    if (info.kind == _ImgKind.jpeg) {
      debugPrint('CastArtwork: conversion unavailable for "$title" — '
          'sending the original JPEG as it is');
      return (bytes: src, width: info.width, height: info.height);
    }
    debugPrint('CastArtwork: $label for "$title" is ${info.kind.name} and '
        'could not be converted — no cover sent from it');
    return null;
  }

  Future<Uint8List?> _convertWithFfmpeg(Uint8List src, String title) async {
    final dir = await getTemporaryDirectory();
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final inFile = File('${dir.path}/nemesis_cover_${stamp}_in');
    final outFile = File('${dir.path}/nemesis_cover_${stamp}_out.jpg');
    try {
      await inFile.writeAsBytes(src, flush: true);
      // Fits inside 600x600 without ever enlarging, keeps the aspect ratio,
      // even dimensions, full-range YUV 4:2:0 (what a baseline JPEG is).
      final command = '-y -i "${inFile.path}" '
          '-vf "scale=\'min($_maxSide,iw)\':\'min($_maxSide,ih)\':'
          'force_original_aspect_ratio=decrease:force_divisible_by=2" '
          '-frames:v 1 -update 1 -q:v 3 -pix_fmt yuvj420p '
          '"${outFile.path}"';
      final session =
          await FFmpegKit.execute(command).timeout(_convertTimeout);
      final code = await session.getReturnCode();
      if (!ReturnCode.isSuccess(code) || !await outFile.exists()) {
        final logs = await session.getAllLogsAsString();
        final tail = (logs ?? '(no log)')
            .trim()
            .split('\n')
            .reversed
            .take(6)
            .toList()
            .reversed
            .join(' | ');
        debugPrint('CastArtwork: FFmpeg could not convert the cover of '
            '"$title": $tail');
        return null;
      }
      final out = await outFile.readAsBytes();
      return out.isEmpty ? null : out;
    } catch (e) {
      debugPrint('CastArtwork: FFmpeg conversion failed for "$title": $e');
      return null;
    } finally {
      for (final f in [inFile, outFile]) {
        unawaited(f.delete().then<void>((_) {}).catchError((_) {}));
      }
    }
  }

  // ── reading an image's kind and size from its first bytes ─────────────

  static _ImgInfo _inspect(Uint8List b) {
    if (b.length >= 4 && b[0] == 0xFF && b[1] == 0xD8) return _jpegInfo(b);
    if (b.length >= 24 &&
        b[0] == 0x89 &&
        b[1] == 0x50 &&
        b[2] == 0x4E &&
        b[3] == 0x47) {
      final w = (b[16] << 24) | (b[17] << 16) | (b[18] << 8) | b[19];
      final h = (b[20] << 24) | (b[21] << 16) | (b[22] << 8) | b[23];
      return _ImgInfo(_ImgKind.png, width: w, height: h);
    }
    if (b.length >= 12 &&
        String.fromCharCodes(b.sublist(0, 4)) == 'RIFF' &&
        String.fromCharCodes(b.sublist(8, 12)) == 'WEBP') {
      return const _ImgInfo(_ImgKind.webp);
    }
    if (b.length >= 10 && String.fromCharCodes(b.sublist(0, 3)) == 'GIF') {
      return _ImgInfo(_ImgKind.gif,
          width: b[6] | (b[7] << 8), height: b[8] | (b[9] << 8));
    }
    return const _ImgInfo(_ImgKind.unknown);
  }

  static _ImgInfo _jpegInfo(Uint8List b) {
    var i = 2;
    while (i + 3 < b.length) {
      if (b[i] != 0xFF) {
        i++;
        continue;
      }
      final marker = b[i + 1];
      if (marker == 0xFF) {
        i++; // fill byte
        continue;
      }
      // Markers that carry no length.
      if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD8)) {
        i += 2;
        continue;
      }
      final isSof = marker >= 0xC0 &&
          marker <= 0xCF &&
          marker != 0xC4 &&
          marker != 0xC8 &&
          marker != 0xCC;
      if (isSof) {
        if (i + 8 >= b.length) break;
        final h = (b[i + 5] << 8) | b[i + 6];
        final w = (b[i + 7] << 8) | b[i + 8];
        final progressive =
            marker == 0xC2 || marker == 0xC6 || marker == 0xCA || marker == 0xCE;
        return _ImgInfo(_ImgKind.jpeg,
            width: w, height: h, progressive: progressive);
      }
      final len = (b[i + 2] << 8) | b[i + 3];
      if (len < 2) break;
      i += 2 + len;
    }
    return const _ImgInfo(_ImgKind.jpeg); // a JPEG whose size wasn't found
  }
}

class _Src {
  const _Src(this.ref, this.label);
  final String ref;
  final String label;
}

enum _ImgKind { jpeg, png, webp, gif, unknown }

class _ImgInfo {
  const _ImgInfo(this.kind, {this.width, this.height, this.progressive = false});
  final _ImgKind kind;
  final int? width;
  final int? height;
  final bool progressive;
}
