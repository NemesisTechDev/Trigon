import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

/// A single parsed line from an LRC-format synced lyric, resolved to a
/// concrete timestamp.
class LrcLine {
  final Duration start;
  final String text;

  const LrcLine({required this.start, required this.text});
}

/// One track entry as returned by LRCLIB, with its lyrics parsed and
/// ready to hand to the lyrics screen.
class LrcLibResult {
  final String trackName;
  final String artistName;
  final int durationSeconds;

  /// Time-stamped lines, present only when LRCLIB has synced lyrics for
  /// this track. Prefer this over [plainText] whenever it's non-empty.
  final List<LrcLine> syncedLines;

  /// Plain, unsynced lyric text — LRCLIB's fallback when no synced
  /// version exists. Null if LRCLIB only had synced (or nothing).
  final String? plainText;

  const LrcLibResult({
    required this.trackName,
    required this.artistName,
    required this.durationSeconds,
    required this.syncedLines,
    this.plainText,
  });

  bool get hasSyncedLyrics => syncedLines.isNotEmpty;
}

/// Thin client for LRCLIB (lrclib.net) — a free, keyless, community
/// lyrics database. Used only as a fallback for tracks where the
/// Jellyfin server itself has no lyrics: results are matched and shown
/// inline on the lyrics screen, never offered as a download/save.
class LrcLibService {
  static const String _baseUrl = 'https://lrclib.net/api';

  static final Dio _dio = Dio(
    BaseOptions(
      baseUrl: _baseUrl,
      // LRCLIB asks integrations to send a descriptive User-Agent, and
      // an explicit Accept header avoids some CDNs/WAFs serving back an
      // HTML challenge page instead of JSON to clients that don't ask.
      headers: {
        'User-Agent':
            'ProjectNemesis/1.0 (Flutter Jellyfin client; lyrics fallback)',
        'Accept': 'application/json',
      },
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 8),
      // Handle status codes ourselves — a 404 from /get just means "no
      // exact match", not a real error, and treating everything from
      // 400-599 as an exception (Dio's default) makes that harder to
      // distinguish from an actual outage below.
      validateStatus: (_) => true,
    ),
  );

  /// Finds and returns the best-matching lyrics for a track, or null if
  /// nothing usable was found (no match, or the match is an
  /// instrumental with no lyrics at all).
  ///
  /// [durationSeconds] — the actual song duration, taken from the
  /// player rather than server metadata — is the single strongest
  /// signal LRCLIB gives us for "same recording, not just same title",
  /// so an exact-match lookup is tried first when it's available, ahead
  /// of the fuzzier free-text search.
  static Future<LrcLibResult?> findBestMatch({
    required String trackName,
    required String artistName,
    String? albumName,
    int? durationSeconds,
  }) async {
    // WEBSITE-BRANDING FIX: tags on downloaded files often carry the site
    // they came from — "Last Last (NaijaVibes.com)", "www.site.com - Title",
    // an artist of "Burna Boy | site.net". LRCLIB matches on clean
    // track/artist names, so every query containing that text came back
    // empty, and the old last-resort cleanup (see [_stripSearchNoise])
    // never removed it, so those songs could never get lyrics. Branding is
    // never part of the real name, so it is removed from everything we
    // search with (and from the artist the wrong-lyrics guard compares
    // against) before the first request — there is no point spending
    // requests on the polluted form. Strings without branding come back
    // untouched.
    trackName = stripWebsiteBranding(trackName);
    artistName = stripWebsiteBranding(artistName);
    if (albumName != null) albumName = stripWebsiteBranding(albumName);

    if (trackName.trim().isEmpty) return null;

    if (durationSeconds != null && durationSeconds > 0) {
      final exact = await _tryExactGet(
        trackName: trackName,
        artistName: artistName,
        albumName: albumName,
        durationSeconds: durationSeconds,
      );
      if (exact != null) return exact;
    }

    // Try with the artist first (more precise), then fall back to a
    // title-only search — the "artist" this app has on hand is often
    // AlbumArtist/Album rather than the true track artist, and an
    // exact-string artist filter on LRCLIB's side can zero out results
    // that a plain title search would still find.
    var candidates = await _search(
      trackName: trackName,
      artistName: artistName,
    );
    // WRONG-LYRICS GUARD: remembers whether the candidates below came from
    // a search that LRCLIB filtered by artist, or from the title-only
    // fallback (which can return any artist's song with that title).
    var searchedByArtist = true;

    if (candidates.isEmpty && artistName.isNotEmpty) {
      candidates = await _search(trackName: trackName, artistName: '');
      searchedByArtist = false;
    }

    // Fallback: on-device/"Open With" titles are often exactly what's
    // in the file's own title tag, not just the filename — things like
    // "Song Title ft. Other Artist (Official Video) 320kbps" — which
    // LocalMusicService's untagged-filename cleanup never touches
    // because the file *is* tagged, just messily. That noise sends
    // LRCLIB's search a query it can't match against its clean
    // trackName/artistName metadata. Strip it and retry once, still
    // searching by "the matching artist and the song title" (same
    // artist/title pairing as above), before giving up.
    if (candidates.isEmpty) {
      final cleanedTitle = _stripSearchNoise(trackName);
      final cleanedArtist = _stripSearchNoise(artistName);
      final changed = cleanedTitle != trackName || cleanedArtist != artistName;

      if (changed && cleanedTitle.isNotEmpty) {
        candidates = await _search(
          trackName: cleanedTitle,
          artistName: cleanedArtist,
        );
        searchedByArtist = true;
        if (candidates.isEmpty && cleanedArtist.isNotEmpty) {
          candidates = await _search(trackName: cleanedTitle, artistName: '');
          searchedByArtist = false;
        }
      }
    }

    if (candidates.isEmpty) {
      debugPrint('[LrcLib] no candidates for "$trackName" / "$artistName"');
      return null;
    }

    // WRONG-LYRICS GUARD: ranking below only looks at synced-ness and
    // duration, so a same-titled song by a different artist (reachable
    // through the title-only fallback) could win. Drop clear mismatches
    // first; see [_guardCandidates] for exactly what is and isn't dropped.
    final guarded = _guardCandidates(
      candidates,
      artistName: artistName,
      durationSeconds: durationSeconds,
      searchedByArtist: searchedByArtist,
    );
    if (guarded.isEmpty) {
      debugPrint('[LrcLib] ${candidates.length} candidate(s) for '
          '"$trackName" / "$artistName" rejected as a different song '
          '(artist/duration mismatch)');
      return null;
    }
    candidates = guarded;

    candidates.sort((a, b) {
      // Synced candidates always outrank plain-text-only ones — being
      // in sync with playback is the entire point of this feature.
      final aSynced = _isNonEmptyString(a['syncedLyrics']) ? 0 : 1;
      final bSynced = _isNonEmptyString(b['syncedLyrics']) ? 0 : 1;
      if (aSynced != bSynced) return aSynced - bSynced;

      // Among equally-synced candidates, the closest reported duration
      // to the song actually playing is the best signal it's the same
      // recording rather than a cover, live version, or remix.
      if (durationSeconds != null) {
        final aDur = ((a['duration'] as num?) ?? 0).round();
        final bDur = ((b['duration'] as num?) ?? 0).round();
        return (aDur - durationSeconds).abs().compareTo(
              (bDur - durationSeconds).abs(),
            );
      }

      return 0;
    });

    return _toResult(candidates.first);
  }

  static bool _isNonEmptyString(dynamic v) => v is String && v.isNotEmpty;

  /// A lyric whose recording length differs from the playing song by more
  /// than this is treated as a different song/edit. Deliberately generous
  /// (LRCLIB's own exact match tolerates ~2s): it only exists to catch
  /// clearly-wrong tracks, never to be picky about slightly different
  /// masters of the same song.
  static const int maxDurationDriftSeconds = 20;

  /// Removes candidates that are clearly a different song, leaving the
  /// existing ranking untouched for everything that remains:
  ///  1. DURATION: when the playing duration is known, drop candidates
  ///     more than [maxDurationDriftSeconds] away (a candidate reporting no
  ///     duration is kept — nothing to compare).
  ///  2. ARTIST: when we have an artist, prefer candidates whose artist
  ///     overlaps ours ([artistsOverlap]). If none overlap, results LRCLIB
  ///     itself filtered by our artist are kept as before (its matching is
  ///     fuzzy/normalised in ways ours isn't), but results from the
  ///     title-only fallback — which never looked at the artist at all —
  ///     are rejected, since "same title, unrelated artist" is exactly how
  ///     the wrong song gets shown.
  static List<Map<String, dynamic>> _guardCandidates(
    List<Map<String, dynamic>> candidates, {
    required String artistName,
    required int? durationSeconds,
    required bool searchedByArtist,
  }) {
    var pool = candidates;

    if (durationSeconds != null && durationSeconds > 0) {
      pool = pool.where((c) {
        final d = ((c['duration'] as num?) ?? 0).round();
        return d <= 0 || (d - durationSeconds).abs() <= maxDurationDriftSeconds;
      }).toList();
    }

    if (artistName.trim().isNotEmpty && pool.isNotEmpty) {
      final matched = pool
          .where((c) => artistsOverlap(artistName, c['artistName']?.toString()))
          .toList();
      if (matched.isNotEmpty) {
        pool = matched;
      } else if (!searchedByArtist) {
        pool = <Map<String, dynamic>>[];
      }
    }

    return pool;
  }

  static const Map<String, String> _foldMap = {
    'à': 'a', 'á': 'a', 'â': 'a', 'ã': 'a', 'ä': 'a', 'å': 'a', 'æ': 'ae',
    'ç': 'c', 'è': 'e', 'é': 'e', 'ê': 'e', 'ë': 'e', 'ì': 'i', 'í': 'i',
    'î': 'i', 'ï': 'i', 'ñ': 'n', 'ò': 'o', 'ó': 'o', 'ô': 'o', 'õ': 'o',
    'ö': 'o', 'ø': 'o', 'ù': 'u', 'ú': 'u', 'û': 'u', 'ü': 'u', 'ý': 'y',
    'ÿ': 'y', 'ß': 'ss',
  };

  static final RegExp _artistSplit = RegExp(
    r'\s*(?:,|&|×|;|\+)\s*|\s+(?:feat\.?|ft\.?|featuring|and|with|vs\.?|x)\s+',
    caseSensitive: false,
  );
  static final RegExp _nonAlnum = RegExp(r'[^\p{L}\p{N}]', unicode: true);

  static const Set<String> _placeholderArtists = {
    'unknown', 'unknownartist', 'various', 'variousartists', 'va',
  };

  /// One lowercase, accent-folded, punctuation-free token per credited
  /// artist ("Tems, Rema feat. X" -> [tems, rema, x]).
  static List<String> _artistTokens(String raw) {
    final lower = raw.toLowerCase();
    final folded = StringBuffer();
    for (final rune in lower.runes) {
      final ch = String.fromCharCode(rune);
      folded.write(_foldMap[ch] ?? ch);
    }
    return folded
        .toString()
        .split(_artistSplit)
        .map((p) => p.replaceAll(_nonAlnum, ''))
        .where((p) => p.isNotEmpty)
        .toList();
  }

  /// Whether two artist credits plausibly name the same artist(s): true when
  /// any credited artist of one equals — or (for names of 4+ letters, so
  /// "the kid laroi" ~ "kid laroi") contains/is contained in — one of the
  /// other. Returns TRUE whenever it can't judge (either side empty, or a
  /// placeholder like "Unknown Artist"/"Various Artists"), so a missing tag
  /// never causes a rejection; this is a guard against clearly-wrong songs,
  /// not a strict matcher.
  static bool artistsOverlap(String? a, String? b) {
    if (a == null || b == null) return true;
    final ta = _artistTokens(a);
    final tb = _artistTokens(b);
    if (ta.isEmpty || tb.isEmpty) return true;
    if (ta.every(_placeholderArtists.contains) ||
        tb.every(_placeholderArtists.contains)) {
      return true;
    }

    for (final x in ta) {
      for (final y in tb) {
        if (x == y) return true;
        final shortest = x.length < y.length ? x.length : y.length;
        if (shortest >= 4 && (x.contains(y) || y.contains(x))) return true;
      }
    }
    return false;
  }

  /// Public wrapper over the LRCLIB-shaped JSON -> [LrcLibResult] parsing,
  /// so [LrcmuxService] (whose compat endpoint speaks the exact same
  /// JSON) can reuse it instead of duplicating it.
  static LrcLibResult? parseEntry(Map<String, dynamic> json) => _toResult(json);

  /// Public wrapper over the noise stripper below, for the same reason.
  static String cleanSearchText(String raw) => _stripSearchNoise(raw);

  // Bracketed/parenthesized release noise — "(Official Video)",
  // "[Lyrics Video]", "(Official Audio)", "(HQ)", etc.
  static final RegExp _bracketedNoise = RegExp(
    r'[\(\[][^)\]]*\b(official|video|audio|lyrics?|visuali[sz]er|mv|m\/v'
    r'|hq|hd|remaster\w*|explicit|clean|extended|slowed|reverb|nightcore)\b'
    r'[^)\]]*[\)\]]',
    caseSensitive: false,
  );

  // "ft. Artist", "feat Artist", "featuring Artist & Other" — eats up to
  // the next bracket (so a trailing "(Official Video)" isn't swallowed
  // into the featured-artist text) or the end of the string.
  static final RegExp _featTag = RegExp(
    r'[\(\[]?\s*(?:ft\.?|feat\.?|featuring)\s+.+?(?=[\(\[]|$)',
    caseSensitive: false,
  );

  // Bitrate/quality markers that show up loose in downloaded-audio
  // titles — "320kbps", "256 kbps", "128k" — with or without brackets.
  static final RegExp _qualityTag = RegExp(
    r'\b\d{2,4}\s?-?\s?(?:kbps|kb\/s|k)\b',
    caseSensitive: false,
  );

  static final RegExp _emptyBrackets = RegExp(r'[\(\[]\s*[\)\]]');
  static final RegExp _trailingSeparator = RegExp(r'[\s\-–—|,]+$');
  static final RegExp _collapseWhitespace = RegExp(r'\s+');

  // ── Website branding ────────────────────────────────────────────────
  // Top-level domains that show up in download-site branding. Second-level
  // forms (co.za, com.ng, ...) come first so they win over a bare "com".
  static const String _tld =
      r'(?:(?:co|com|org|net)\.(?:za|ke|ng|uk|tz|ug|gh|in|pk)'
      r'|com|net|org|info|biz|mobi|xyz|club|site|online|top|ws|cc|tv|fm|pw'
      r'|ng|ke|ug|tz|gh|za|pk|ru|ir|tk|ml|ga|cf|gq|sx)';

  // Explicit URLs: "http://...", "https://...", "www.site.com/...".
  static const String _urlPart =
      r'(?:https?:\/\/|www\d?\.)[^\s\]\)\}\[\(\{<>"]+';

  // Bare domains: "NaijaVibes.com", "tooxclusive.com.ng", "site.co.za".
  // The label right before the TLD must be 3+ letters so dotted names such
  // as "Mr.Top" or "Dr.Tv" are left alone, and the match must start at the
  // beginning of a token. "in"/"io" are real-word-prone, so they only
  // count after a 5+ letter label ("pagalworld.in").
  static const String _domainPart =
      r'(?<![\w.@])(?:[a-z0-9]+(?:-[a-z0-9]+)*\.)*[a-z0-9][a-z0-9-]{2,}\.'
      '$_tld'
      r'(?![\w-])(?:\/[^\s\]\)\}]*)?'
      r'|(?<![\w.@])[a-z0-9][a-z0-9-]{4,}\.(?:in|io)(?![\w-])';

  static final RegExp _urlToken = RegExp(_urlPart, caseSensitive: false);
  static final RegExp _domainToken = RegExp(_domainPart, caseSensitive: false);

  // A whole (...) / [...] / {...} group that contains a URL or domain —
  // "(NaijaVibes.com)", "[www.site.com]", "(Downloaded from site.net)".
  static final RegExp _bracketedWebsite = RegExp(
    r'[\(\[\{][^\)\]\}]*(?:'
    '$_urlPart|$_domainPart'
    r')[^\)\]\}]*[\)\]\}]',
    caseSensitive: false,
  );

  // A bracketed group that is branding even without a domain in it —
  // "(Downloaded from NaijaVibes)", "[Free Download]", "(Presented by X)".
  static final RegExp _bracketedBrandingPhrase = RegExp(
    r'[\(\[\{][^\)\]\}]*\b(?:downloaded?\s+from|free\s+download'
    r'|presented\s+by|powered\s+by|brought\s+to\s+you\s+by'
    r'|more\s+songs\s+at)\b'
    r'[^\)\]\}]*[\)\]\}]',
    caseSensitive: false,
  );

  // The lead-in words left stranded at the end once a domain after them has
  // been removed ("Title - Downloaded from <site>"). Only applied when a
  // domain/URL was actually removed from the same string, so a title that
  // merely ends in one of these words is never touched.
  static final RegExp _trailingBrandingPhrase = RegExp(
    r'[\s\-–—|:]*\b(?:downloaded?\s+from|download\s+(?:at|from)'
    r'|free\s+download(?:\s+(?:at|from))?|visit|presented\s+by'
    r'|powered\s+by|brought\s+to\s+you\s+by|more\s+(?:songs\s+)?at'
    r'|get\s+more(?:\s+at)?|only\s+on|exclusively\s+on)\s*$',
    caseSensitive: false,
  );

  static final RegExp _leadingSeparator = RegExp(r'^[\s\-–—|,:]+');
  static final RegExp _danglingOpenBracket = RegExp(r'[\s\(\[\{]+$');

  /// Removes download-site branding from a title/artist/album string:
  /// URLs, bare domains ("NaijaVibes.com", "site.com.ng") and the
  /// "(Downloaded from ...)"-style wrapper text around them, together with
  /// the separators/brackets they leave behind. A string with no branding
  /// is returned exactly as given.
  static String stripWebsiteBranding(String raw) {
    if (raw.isEmpty) return raw;

    final hasSite = _urlToken.hasMatch(raw) || _domainToken.hasMatch(raw);
    if (!hasSite && !_bracketedBrandingPhrase.hasMatch(raw)) return raw;

    var s = raw;
    s = s.replaceAll(_bracketedWebsite, ' ');
    s = s.replaceAll(_bracketedBrandingPhrase, ' ');
    s = s.replaceAll(_urlToken, ' ');
    s = s.replaceAll(_domainToken, ' ');
    s = s.replaceAll(_collapseWhitespace, ' ').trim();
    if (hasSite) s = s.replaceAll(_trailingBrandingPhrase, '');
    s = s.replaceAll(_danglingOpenBracket, '');
    s = s.replaceAll(_emptyBrackets, ' ');
    s = s.replaceAll(_collapseWhitespace, ' ').trim();
    s = s.replaceAll(_leadingSeparator, '');
    s = s.replaceAll(_trailingSeparator, '').trim();
    return s;
  }

  /// Strips the noise a raw (un-cleaned) title/artist string can carry —
  /// featured-artist tags, "(Official Video)"-style release tags, and
  /// bitrate markers — so a fallback LRCLIB query isn't polluted by text
  /// that was never part of the actual song/artist name. Used only as a
  /// last-resort retry when a search on the name exactly as given comes
  /// back empty; the un-cleaned name is always tried first.
  static String _stripSearchNoise(String raw) {
    var s = stripWebsiteBranding(raw);
    s = s.replaceAll(_bracketedNoise, ' ');
    s = s.replaceAll(_featTag, ' ');
    s = s.replaceAll(_qualityTag, ' ');
    s = s.replaceAll(_emptyBrackets, ' ');
    s = s.replaceAll(_collapseWhitespace, ' ').trim();
    s = s.replaceAll(_trailingSeparator, '').trim();
    return s;
  }

  static Future<LrcLibResult?> _tryExactGet({
    required String trackName,
    required String artistName,
    String? albumName,
    required int durationSeconds,
  }) async {
    try {
      final response = await _dio.get(
        '/get',
        queryParameters: {
          'track_name': trackName,
          'artist_name': artistName,
          if (albumName != null && albumName.isNotEmpty)
            'album_name': albumName,
          'duration': durationSeconds,
        },
      );

      if (response.statusCode != 200) {
        // 404 = no exact match, anything else = treat the same way and
        // fall back to search below.
        if (response.statusCode != 404) {
          debugPrint('[LrcLib] /get ${response.statusCode}: ${response.data}');
        }
        return null;
      }

      final body = _decodeBody(response.data);
      if (body is! Map) return null;

      return _toResult(Map<String, dynamic>.from(body));
    } catch (e) {
      debugPrint('[LrcLib] /get failed: $e');
      return null;
    }
  }

  static Future<List<Map<String, dynamic>>> _search({
    required String trackName,
    required String artistName,
  }) async {
    try {
      final response = await _dio.get(
        '/search',
        queryParameters: {
          'track_name': trackName,
          if (artistName.isNotEmpty) 'artist_name': artistName,
        },
      );

      if (response.statusCode != 200) {
        debugPrint('[LrcLib] /search ${response.statusCode}: ${response.data}');
        return [];
      }

      final body = _decodeBody(response.data);
      if (body is! List) return [];

      return body
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    } catch (e) {
      debugPrint('[LrcLib] /search failed: $e');
      return [];
    }
  }

  /// Dio normally auto-decodes JSON bodies, but if the server responds
  /// with a body that isn't tagged `application/json` (some CDNs/WAFs
  /// do this on edge responses), Dio hands back the raw String instead
  /// — decode it ourselves rather than silently failing a type cast.
  static dynamic _decodeBody(dynamic data) {
    if (data is String) {
      try {
        return jsonDecode(data);
      } catch (_) {
        return null;
      }
    }
    return data;
  }

  static LrcLibResult? _toResult(Map<String, dynamic> json) {
    if (json['instrumental'] == true) return null;

    final synced = json['syncedLyrics'] as String?;
    final plain = json['plainLyrics'] as String?;

    final syncedLines = (synced != null && synced.isNotEmpty)
        ? parseLrc(synced)
        : const <LrcLine>[];

    if (syncedLines.isEmpty && (plain == null || plain.isEmpty)) {
      return null;
    }

    return LrcLibResult(
      trackName: json['trackName']?.toString() ?? '',
      artistName: json['artistName']?.toString() ?? '',
      durationSeconds: ((json['duration'] as num?) ?? 0).round(),
      syncedLines: syncedLines,
      plainText: plain,
    );
  }

  /// Parses an LRC-format blob (lines like "[01:02.34]Some lyric") into
  /// ordered, timestamped lines. Lines without a valid timestamp tag —
  /// e.g. metadata headers like "[ar:Artist]" — are skipped rather than
  /// breaking the whole parse.
  static List<LrcLine> parseLrc(String lrc) {
    final tag = RegExp(r'\[(\d{1,2}):(\d{2})(?:[.:](\d{1,3}))?\]');
    final lines = <LrcLine>[];

    for (final rawLine in lrc.split('\n')) {
      final matches = tag.allMatches(rawLine).toList();
      if (matches.isEmpty) continue;

      final text = rawLine.replaceAll(tag, '').trim();

      for (final match in matches) {
        final minutes = int.parse(match.group(1)!);
        final seconds = int.parse(match.group(2)!);
        final fraction = match.group(3);
        final millis = fraction == null
            ? 0
            : int.parse(fraction.padRight(3, '0').substring(0, 3));

        lines.add(
          LrcLine(
            start:
                Duration(minutes: minutes, seconds: seconds, milliseconds: millis),
            text: text,
          ),
        );
      }
    }

    lines.sort((a, b) => a.start.compareTo(b.start));
    return lines;
  }
}
