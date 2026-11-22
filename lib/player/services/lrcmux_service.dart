import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'lrclib_service.dart';

/// Thin client for lrcmux (lrcmux.dev) — a free, keyless lyrics aggregator
/// that fans out across several providers. Used ONLY as the second step
/// after [LrcLibService] finds nothing for a track.
///
/// It's queried through lrcmux's LRCLIB-compatible `/get` route, which
/// returns the exact JSON shape LRCLIB does, so the result is parsed by the
/// same code and handed back as the same [LrcLibResult] — the lyrics screen
/// needs no new model.
///
/// ROOT CAUSE of "the fallback never finds anything" (verified against
/// lrcmux's own source, github.com/f1nniboy/lrcmux):
///
///  1. WRONG HOST. `lrcmux.dev` is only the website (a SvelteKit app on
///     Cloudflare Workers — see frontend/wrangler.toml). The API is served
///     from `api.lrcmux.dev`, and the compat route is
///     `/compat/lrclib/api/get`. Every request used to go to
///     `lrcmux.dev/...`, which answers 404 (or an HTML page) for every
///     track — indistinguishable from "no lyrics", and silently swallowed.
///     (A later attempt probed `lrcmux.dev/api` and `lrcmux.dev/compat/...`
///     — both still the website, so neither could ever succeed.)
///  2. `/get` REQUIRES BOTH artist and title; with an empty artist the
///     server answers 400 "provide either ISRC or both artist and title"
///     (on-device songs often have no artist tag). Such a request can't
///     succeed, so it is skipped instead of sent.
///  3. The compat `/search` route is not a real search: it runs the very
///     same single lookup as `/get` and wraps it in a list. It adds no
///     coverage, only extra requests against a rate-limited instance, so
///     it is no longer used.
///  4. A cold lookup makes lrcmux resolve the track (Deezer) and then query
///     several lyric providers, which can outlast a 15s timeout while the
///     server keeps working and caches the answer. The timeout is longer
///     and a timed-out request is retried once (usually then cached).
///
/// The public instance rate-limits per IP (and asks callers to honor
/// `Retry-After` on a 429), so after a 429 this service stays quiet until
/// that window passes instead of hammering it with every lookup.
class LrcmuxService {
  /// The API host — NOT lrcmux.dev (that's the website). Change this one
  /// constant if the public instance ever moves, or to point at a
  /// self-hosted lrcmux (whose compat route is the same path).
  static const String _baseUrl = 'https://api.lrcmux.dev/compat/lrclib/api';

  static DateTime? _blockedUntil;

  static final Dio _dio = Dio(
    BaseOptions(
      baseUrl: _baseUrl,
      headers: {
        'User-Agent':
            'ProjectNemesis/1.0 (Flutter Jellyfin client; lyrics fallback)',
        'Accept': 'application/json',
      },
      // A cold lookup resolves the track, then fans out to several
      // providers — much slower than LRCLIB's single database lookup.
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 30),
      validateStatus: (_) => true,
    ),
  );

  static bool get _isBlocked {
    final blocked = _blockedUntil;
    return blocked != null && DateTime.now().isBefore(blocked);
  }

  /// Returns the best lyrics lrcmux has for the track, or null when it has
  /// nothing usable (no match, instrumental, rate-limited, offline, error).
  /// Never throws.
  static Future<LrcLibResult?> findBestMatch({
    required String trackName,
    required String artistName,
    String? albumName,
    int? durationSeconds,
  }) async {
    // WEBSITE-BRANDING FIX: same as LrcLibService.findBestMatch — a
    // "(NaijaVibes.com)" in the title or artist tag can never match
    // Deezer's catalogue (and would also trip the artist guard below), so
    // it is removed before anything is sent. Clean strings are unchanged.
    trackName = LrcLibService.stripWebsiteBranding(trackName);
    artistName = LrcLibService.stripWebsiteBranding(artistName);
    if (albumName != null) {
      albumName = LrcLibService.stripWebsiteBranding(albumName);
    }

    if (trackName.trim().isEmpty) return null;

    if (artistName.trim().isEmpty) {
      debugPrint('[Lrcmux] skipped "$trackName": lrcmux needs an artist '
          'AND a title (empty artist is a guaranteed 400)');
      return null;
    }

    if (_isBlocked) {
      debugPrint('[Lrcmux] skipped, rate-limited until $_blockedUntil');
      return null;
    }

    // Distinct (title, artist) attempts, strictest first. lrcmux matches
    // the track against Deezer's catalogue, which has clean titles and one
    // credited artist, so progressively cleaner variants rescue messy
    // file tags. Each one is only tried when it differs from the last.
    final cleanedTitle = LrcLibService.cleanSearchText(trackName);
    final cleanedArtist = LrcLibService.cleanSearchText(artistName);
    final primaryArtist = _primaryArtist(cleanedArtist);

    final attempts = <({String title, String artist})>[];
    void add(String title, String artist) {
      if (title.trim().isEmpty || artist.trim().isEmpty) return;
      if (attempts.any((a) => a.title == title && a.artist == artist)) return;
      attempts.add((title: title, artist: artist));
    }

    add(trackName, artistName);
    add(cleanedTitle, cleanedArtist);
    add(cleanedTitle, primaryArtist);

    for (final attempt in attempts) {
      if (_isBlocked) return null;
      try {
        final match = await _get(
          title: attempt.title,
          artist: attempt.artist,
          album: albumName,
          durationSeconds: durationSeconds,
        );
        if (match != null) return match;
      } catch (e) {
        debugPrint('[Lrcmux] lookup failed: $e');
        return null;
      }
    }

    debugPrint('[Lrcmux] nothing found for "$trackName" / "$artistName"');
    return null;
  }

  /// "A, B & C" / "A feat. B" / "A x B" -> "A". Deezer credits a single
  /// main artist, so a credit list in the tag can stop the match.
  static String _primaryArtist(String artist) {
    final split = artist.split(
      RegExp(r'\s*(?:,|&|×|;)\s*|\s+(?:feat\.?|ft\.?|featuring|and|with|vs\.?|x)\s+',
          caseSensitive: false),
    );
    return split.first.trim();
  }

  static bool _isTimeout(DioException e) =>
      e.type == DioExceptionType.connectionTimeout ||
      e.type == DioExceptionType.receiveTimeout ||
      e.type == DioExceptionType.sendTimeout;

  static Future<LrcLibResult?> _get({
    required String title,
    required String artist,
    String? album,
    int? durationSeconds,
  }) async {
    final params = <String, dynamic>{
      'track_name': title,
      'artist_name': artist,
      if (album != null && album.isNotEmpty) 'album_name': album,
      // Duration only influences lrcmux's track-matching score (it is not a
      // hard filter), so it is safe to send whenever it is known.
      if (durationSeconds != null && durationSeconds > 0)
        'duration': durationSeconds,
    };

    Response<dynamic>? response;
    for (var attempt = 1; attempt <= 2; attempt++) {
      try {
        response = await _dio.get('/get', queryParameters: params);
        break;
      } on DioException catch (e) {
        if (_isTimeout(e) && attempt == 1) {
          debugPrint('[Lrcmux] /get timed out, retrying once');
          continue;
        }
        debugPrint('[Lrcmux] /get failed: ${e.type} ${e.message}');
        return null;
      } catch (e) {
        debugPrint('[Lrcmux] /get failed: $e');
        return null;
      }
    }
    if (response == null) return null;

    final status = response.statusCode ?? 0;

    if (status == 429) {
      final retryAfter =
          int.tryParse(response.headers.value('retry-after') ?? '');
      final wait = Duration(
        seconds: (retryAfter != null && retryAfter > 0) ? retryAfter : 600,
      );
      _blockedUntil = DateTime.now().add(wait);
      debugPrint('[Lrcmux] rate-limited, backing off for $wait');
      return null;
    }

    dynamic body = response.data;
    if (body is String) {
      try {
        body = jsonDecode(body);
      } catch (_) {
        // Not JSON (e.g. an HTML page from a wrong host) — left as text.
      }
    }

    if (status != 200) {
      // 404 = lrcmux genuinely has nothing; logged anyway, because a wrong
      // route and "no lyrics" look identical and hiding it is what made
      // this fallback undebuggable.
      final text = body.toString();
      debugPrint('[Lrcmux] /get $status for "$title" / "$artist": '
          '${text.length > 160 ? text.substring(0, 160) : text}');
      return null;
    }

    if (body is! Map) {
      debugPrint('[Lrcmux] /get 200 but body is not JSON object: '
          '${body.toString().length > 160 ? body.toString().substring(0, 160) : body}');
      return null;
    }

    final parsed = LrcLibService.parseEntry(Map<String, dynamic>.from(body));
    if (parsed == null) {
      debugPrint('[Lrcmux] /get 200 but no usable lyrics '
          '(instrumental or empty) for "$title"');
      return null;
    }

    // WRONG-LYRICS GUARD: lrcmux first matches the request to a track in
    // Deezer's catalogue with a lenient score (title similarity plus a
    // partial artist/duration signal), so a close-but-different song can
    // come back. The result says which track it actually resolved to —
    // reject it when its artist or length clearly isn't ours. Fails open
    // (keeps the result) whenever either side has no artist/duration.
    if (!LrcLibService.artistsOverlap(artist, parsed.artistName)) {
      debugPrint('[Lrcmux] rejected "${parsed.trackName}" by '
          '"${parsed.artistName}" — not "$artist"');
      return null;
    }
    if (durationSeconds != null &&
        durationSeconds > 0 &&
        parsed.durationSeconds > 0 &&
        (parsed.durationSeconds - durationSeconds).abs() >
            LrcLibService.maxDurationDriftSeconds) {
      debugPrint('[Lrcmux] rejected "${parsed.trackName}" — '
          '${parsed.durationSeconds}s vs playing ${durationSeconds}s');
      return null;
    }
    return parsed;
  }
}
