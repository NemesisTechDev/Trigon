import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

/// NAMESIS PRIME: what [LocalCastServer] needs to hand an addon stream (a
/// direct link or a torrent served by the built-in engine) to a TV.
///
/// A TV fetches URLs itself. That fails for
///  - a torrent: the engine only listens on this phone (127.0.0.1),
///  - a link that needs special request headers (a TV cannot send them),
///  - an https link on a DLNA TV (most cannot do TLS),
/// so the phone fetches the bytes and the TV fetches them from the phone.
///
/// Two kinds of relay:
///  - [CastRelay.remote]    proxies one URL, honouring Range (seeking).
///  - [CastRelay.directory] serves an HLS playlist + segments that ffmpeg is
///    writing into a folder (used for Google Cast, which cannot open MKV).
class CastRelay {
  CastRelay.remote({
    required String this.url,
    required this.headers,
    required this.contentType,
  })  : dir = null,
        onDispose = null;

  CastRelay.directory({required Directory this.dir, this.onDispose})
      : url = null,
        headers = const {},
        contentType = '';

  final String? url;
  final Map<String, String> headers;
  final String contentType;
  final Directory? dir;
  final Future<void> Function()? onDispose;

  /// Other relay tokens this one depends on (the source feeding ffmpeg).
  final List<String> dependsOn = [];

  int requests = 0;
  int bytesSent = 0;

  Future<void> dispose() async {
    try {
      await onDispose?.call();
    } catch (e) {
      debugPrint('CastRelay: dispose failed: $e');
    }
  }
}

const _dlnaFeatures = 'DLNA.ORG_OP=01;DLNA.ORG_CI=0;'
    'DLNA.ORG_FLAGS=01700000000000000000000000000000';

// Same string as PlayerManager._browserUserAgent: the hosts behind addon
// links often reject a non-browser agent such as "Dart/x (dart:io)".
const _relayUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

/// Answers one request for [relay]. Always completes the response and
/// returns a short outcome string for the log. Never throws.
Future<String> serveCastRelay(HttpRequest request, CastRelay relay) async {
  relay.requests++;
  try {
    if (relay.dir != null) {
      return await _serveDirectory(request, relay);
    }
    return await _serveRemote(request, relay);
  } catch (e) {
    debugPrint('CastRelay: request failed: $e');
    try {
      await request.response.close();
    } catch (_) {}
    return 'relay-aborted: $e';
  }
}

Future<String> _fail(HttpRequest request, int status, String why) async {
  request.response.statusCode = status;
  await request.response.close();
  return why;
}

Future<String> _serveRemote(HttpRequest request, CastRelay relay) async {
  final isHead = request.method == 'HEAD';
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 20)
    ..idleTimeout = const Duration(seconds: 15)
    ..userAgent = _relayUserAgent
    ..autoUncompress = false;
  try {
    final clientRange =
        isHead ? 'bytes=0-0' : request.headers.value(HttpHeaders.rangeHeader);
    final ifRange =
        isHead ? null : request.headers.value(HttpHeaders.ifRangeHeader);

    Future<HttpClientResponse> open() async {
      final upstream = await client.getUrl(Uri.parse(relay.url!));
      upstream.followRedirects = true;
      upstream.maxRedirects = 6;
      relay.headers.forEach((k, v) {
        try {
          upstream.headers.set(k, v);
        } catch (_) {}
      });
      upstream.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      if (clientRange != null) {
        upstream.headers.set(HttpHeaders.rangeHeader, clientRange);
      }
      if (ifRange != null) {
        upstream.headers.set(HttpHeaders.ifRangeHeader, ifRange);
      }
      return upstream.close();
    }

    // One retry on a server error, throttling or a dropped connection, so a
    // hiccup at the source does not fail the whole cast.
    HttpClientResponse resp;
    try {
      resp = await open();
      if (resp.statusCode >= 500 || resp.statusCode == 429) {
        await resp.drain<void>();
        await Future<void>.delayed(const Duration(milliseconds: 500));
        resp = await open();
      }
    } catch (e) {
      if (e is! IOException && e is! TimeoutException) rethrow;
      await Future<void>.delayed(const Duration(milliseconds: 500));
      resp = await open();
    }

    final code = resp.statusCode;
    if (code >= 400) {
      await resp.drain<void>();
      return _fail(request, code, 'upstream-$code');
    }

    int? total;
    final contentRange = resp.headers.value(HttpHeaders.contentRangeHeader);
    if (code == HttpStatus.partialContent && contentRange != null) {
      total = int.tryParse(
          RegExp(r'/(\d+)\s*$').firstMatch(contentRange)?.group(1) ?? '');
    } else if (resp.contentLength >= 0) {
      total = resp.contentLength;
    }

    // The source ignored the Range and answered 200 with the whole file.
    // Passing that on would hand a TV that asked for the tail (an MP4's
    // moov box, a seek) the wrong bytes, so the range is cut here.
    int? sliceFrom;
    int? sliceLen;
    if (!isHead &&
        clientRange != null &&
        code == HttpStatus.ok &&
        total != null) {
      final m = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(clientRange.trim());
      final a = m?.group(1) ?? '';
      final b = m?.group(2) ?? '';
      if (m != null && (a.isNotEmpty || b.isNotEmpty)) {
        int start;
        int end;
        if (a.isEmpty) {
          start = (total - int.parse(b)).clamp(0, total - 1).toInt();
          end = total - 1;
        } else {
          start = int.parse(a);
          end = b.isEmpty ? total - 1 : int.parse(b);
          if (end > total - 1) end = total - 1;
        }
        if (start >= total) {
          await resp.drain<void>();
          request.response.headers.set('Content-Range', 'bytes */$total');
          return _fail(request, HttpStatus.requestedRangeNotSatisfiable,
              'range-416');
        }
        sliceFrom = start;
        sliceLen = end - start + 1;
      }
    }
    final emulated = sliceFrom != null && sliceLen != null;

    final rangesOk = emulated ||
        code == HttpStatus.partialContent ||
        (resp.headers.value(HttpHeaders.acceptRangesHeader) ?? '')
            .toLowerCase()
            .contains('bytes');

    final out = request.response;
    out.headers
      ..set('Content-Type', relay.contentType, preserveHeaderCase: true)
      ..set('Accept-Ranges', rangesOk ? 'bytes' : 'none',
          preserveHeaderCase: true)
      ..set('transferMode.dlna.org', 'Streaming', preserveHeaderCase: true)
      ..set('contentFeatures.dlna.org', _dlnaFeatures,
          preserveHeaderCase: true);

    if (isHead) {
      await resp.drain<void>();
      out.statusCode = HttpStatus.ok;
      if (total != null) {
        out.contentLength = total;
        try {
          out.headers.set('Content-Length', '$total', preserveHeaderCase: true);
        } catch (_) {}
      }
      await out.close();
      return 'relay-head';
    }

    Stream<List<int>> counted(Stream<List<int>> s) => s.map((chunk) {
          relay.bytesSent += chunk.length;
          return chunk;
        });

    final from = sliceFrom;
    final len = sliceLen;
    if (from != null && len != null) {
      out.statusCode = HttpStatus.partialContent;
      out.headers.set('Content-Range', 'bytes $from-${from + len - 1}/$total',
          preserveHeaderCase: true);
      out.contentLength = len;
      await out.addStream(counted(_slice(resp, from, len)));
      await out.close();
      return 'relay-ok-range-emulated';
    }

    if (code == HttpStatus.partialContent && clientRange != null) {
      out.statusCode = HttpStatus.partialContent;
      if (contentRange != null) {
        out.headers
            .set('Content-Range', contentRange, preserveHeaderCase: true);
      }
    } else {
      out.statusCode = HttpStatus.ok;
    }
    if (resp.contentLength >= 0) {
      out.contentLength = resp.contentLength;
      try {
        out.headers.set('Content-Length', '${resp.contentLength}',
            preserveHeaderCase: true);
      } catch (_) {}
    }

    await out.addStream(counted(resp));
    await out.close();
    return 'relay-ok';
  } finally {
    client.close(force: true);
  }
}

/// [source] without its first [skip] bytes, cut to [take] bytes.
Stream<List<int>> _slice(Stream<List<int>> source, int skip, int take) async* {
  var toSkip = skip;
  var left = take;
  await for (final chunk in source) {
    var c = chunk;
    if (toSkip > 0) {
      if (c.length <= toSkip) {
        toSkip -= c.length;
        continue;
      }
      c = c.sublist(toSkip);
      toSkip = 0;
    }
    if (c.length > left) c = c.sublist(0, left);
    left -= c.length;
    yield c;
    if (left <= 0) return;
  }
}

/// What a link really is, read from its first bytes (after redirects).
class CastSourceProbe {
  const CastSourceProbe({
    this.contentType,
    this.extension,
    this.isHls = false,
    this.looksLikeHtml = false,
  });
  final String? contentType;

  /// The container found in the bytes (mp4, mkv, webm, ts, avi, m3u8), or
  /// null when it could not be recognised.
  final String? extension;
  final bool isHls;

  /// The link answered with a web page (an expired or blocked link).
  final bool looksLikeHtml;
}

/// Reads the first bytes of [url] with the addon's [headers]. Null when the
/// source could not be reached in time; callers then fall back to guessing
/// from the URL.
Future<CastSourceProbe?> probeCastSource(
    Uri url, Map<String, String> headers) async {
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 8)
    ..userAgent = _relayUserAgent
    ..autoUncompress = false;
  try {
    final req = await client.getUrl(url);
    req.followRedirects = true;
    req.maxRedirects = 6;
    headers.forEach((k, v) {
      try {
        req.headers.set(k, v);
      } catch (_) {}
    });
    req.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
    req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-1023');
    final resp = await req.close().timeout(const Duration(seconds: 10));
    if (resp.statusCode >= 400) {
      await resp.drain<void>();
      return null;
    }
    final buf = BytesBuilder(copy: false);
    await for (final chunk in resp.timeout(const Duration(seconds: 6))) {
      buf.add(chunk);
      if (buf.length >= 512) break;
    }
    final Uint8List b = buf.takeBytes();
    final type = resp.headers.contentType?.mimeType.toLowerCase();
    final head =
        String.fromCharCodes(b.take(64)).trimLeft().toLowerCase();
    final html = type == 'text/html' ||
        head.startsWith('<!doctype html') ||
        head.startsWith('<html');

    String? ext;
    if (b.length >= 7 && String.fromCharCodes(b.sublist(0, 7)) == '#EXTM3U') {
      ext = 'm3u8';
    } else if (b.length >= 12 &&
        b[4] == 0x66 &&
        b[5] == 0x74 &&
        b[6] == 0x79 &&
        b[7] == 0x70) {
      ext = 'mp4';
    } else if (b.length >= 4 &&
        b[0] == 0x1A &&
        b[1] == 0x45 &&
        b[2] == 0xDF &&
        b[3] == 0xA3) {
      ext = (type ?? '').contains('webm') ? 'webm' : 'mkv';
    } else if (b.length >= 189 && b[0] == 0x47 && b[188] == 0x47) {
      ext = 'ts';
    } else if (b.length >= 12 &&
        String.fromCharCodes(b.sublist(0, 4)) == 'RIFF' &&
        String.fromCharCodes(b.sublist(8, 12)) == 'AVI ') {
      ext = 'avi';
    }
    return CastSourceProbe(
      contentType: type,
      extension: ext,
      isHls: ext == 'm3u8' || (type ?? '').contains('mpegurl'),
      looksLikeHtml: html,
    );
  } catch (e) {
    debugPrint('CastRelay: probe failed: $e');
    return null;
  } finally {
    client.close(force: true);
  }
}

Future<String> _serveDirectory(HttpRequest request, CastRelay relay) async {
  final segs = request.uri.pathSegments;
  final name = segs.length > 1 ? segs[1] : '';
  // Only the files ffmpeg writes here; no path tricks.
  if (!RegExp(r'^stream[A-Za-z0-9_\-]*\.(m3u8|ts)$').hasMatch(name)) {
    return _fail(request, HttpStatus.notFound, 'relay-bad-name');
  }
  final file = File('${relay.dir!.path}/$name');
  if (!await file.exists()) {
    return _fail(request, HttpStatus.notFound, 'relay-missing');
  }

  final playlist = name.endsWith('.m3u8');
  final out = request.response;
  out.headers
    ..set('Content-Type',
        playlist ? 'application/vnd.apple.mpegurl' : 'video/mp2t',
        preserveHeaderCase: true)
    ..set('Cache-Control', playlist ? 'no-cache' : 'max-age=3600');

  final bytes = await file.readAsBytes();
  out.statusCode = HttpStatus.ok;
  out.contentLength = bytes.length;
  if (request.method != 'HEAD') {
    out.add(bytes);
    relay.bytesSent += bytes.length;
  }
  await out.close();
  return playlist ? 'relay-playlist' : 'relay-segment';
}
