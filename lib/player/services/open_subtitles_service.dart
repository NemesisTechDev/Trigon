import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../services/proxy_config.dart';

/// One search result from OpenSubtitles — a single subtitle file
/// available for download, not yet fetched.
class OpenSubtitleResult {
  final int fileId;
  final String language;
  final String releaseName;
  final int downloadCount;
  final double rating;
  final bool hearingImpaired;
  final bool aiTranslated;
  final bool machineTranslated;

  const OpenSubtitleResult({
    required this.fileId,
    required this.language,
    required this.releaseName,
    required this.downloadCount,
    required this.rating,
    required this.hearingImpaired,
    required this.aiTranslated,
    required this.machineTranslated,
  });
}

/// Thin client for the OpenSubtitles REST API (api.opensubtitles.com).
///
/// Requests go through the Nemesis Worker (see ProxyConfig), which holds
/// the app's OpenSubtitles API key and sets the required Api-Key and
/// User-Agent headers — no key ships in the APK. Anonymous requests (no
/// login) are capped at a small number of downloads/day; logging in via
/// [login] raises that ceiling for a free account. [login] is optional.
///
/// NOTE on reliability: the Worker's key is shared by every install of
/// this app, and OpenSubtitles applies its rate limits (and, under load,
/// its 503s) per key. If failures persist after the retries below,
/// that's a quota problem on the shared key, not something client-side
/// retry logic can paper over.
class OpenSubtitlesService {
  static String get _baseUrl => '${ProxyConfig.baseUrl}/opensubtitles';

  static String? _authToken;

  static final Dio _dio = Dio(
    BaseOptions(
      baseUrl: _baseUrl,
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        ...ProxyConfig.headers,
      },
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 15),
    ),
  );

  /// A separate, headerless client for fetching the actual subtitle
  /// file from the signed link `/download` hands back — that link
  /// already carries its own auth, and does not want (some CDNs will
  /// even reject) the Api-Key header.
  static final Dio _fileDio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 20),
    ),
  );

  /// Optional — raises the daily download quota above the anonymous
  /// tier. Call once (e.g. from a settings screen) before [download].
  static Future<void> login({
    required String username,
    required String password,
  }) async {
    final response = await _dio.post(
      '/login',
      data: {'username': username, 'password': password},
    );

    _authToken = response.data['token'] as String?;

    if (_authToken != null) {
      _dio.options.headers['Authorization'] = 'Bearer $_authToken';
    }
  }

  /// Free-text search — title, optionally with year/season/episode
  /// folded into the query string (e.g. "Breaking Bad S01E01").
  /// [languages] is a comma-separated list of ISO 639-1 codes, e.g.
  /// "en,es"; null searches all languages.
  static Future<List<OpenSubtitleResult>> search({
    required String query,
    String? languages,
  }) async {
    final response = await _request(
      () => _dio.get(
        '/subtitles',
        queryParameters: {
          'query': query,
          if (languages != null && languages.isNotEmpty)
            'languages': languages,
        },
      ),
    );

    final data = response.data['data'] as List<dynamic>? ?? [];

    final results = <OpenSubtitleResult>[];

    for (final entry in data) {
      final attributes = entry['attributes'] as Map<String, dynamic>?;
      if (attributes == null) continue;

      final files = attributes['files'] as List<dynamic>?;
      if (files == null || files.isEmpty) continue;

      // A single OpenSubtitles "subtitle" entry can bundle multiple
      // files (e.g. one per CD split) — the first is the one that
      // matters for the common case of a single video file.
      final fileId = files.first['file_id'];
      if (fileId == null) continue;

      results.add(
        OpenSubtitleResult(
          fileId: fileId as int,
          language: attributes['language'] ?? 'Unknown',
          releaseName: attributes['release'] ??
              files.first['file_name'] ??
              'Subtitle',
          downloadCount: attributes['download_count'] ?? 0,
          rating: (attributes['ratings'] as num?)?.toDouble() ?? 0.0,
          hearingImpaired: attributes['hearing_impaired'] ?? false,
          aiTranslated: attributes['ai_translated'] ?? false,
          machineTranslated: attributes['machine_translated'] ?? false,
        ),
      );
    }

    return _sortResults(results);
  }

  /// Order search results should appear in — language group first
  /// (English, Spanish, French, German, then everything else in
  /// whatever order the API returned it), most-downloaded first within
  /// each group. OpenSubtitles' own ordering isn't sorted by anything
  /// obviously useful, so this replaces it entirely rather than
  /// layering on top of it.
  static const List<String> _priorityLanguages = ['en', 'es', 'fr', 'de'];

  /// Group index for [language] — 0 for English, 1 for Spanish, etc.,
  /// [_priorityLanguages.length] for anything else. Matches both a bare
  /// code ("en") and a regional variant ("en-US", "pt-BR" wouldn't
  /// match "pt" since Portuguese isn't in the priority list — this is
  /// deliberately exact-prefix, not a loose "starts with the same
  /// letter" match, so e.g. "eu" (Basque) never gets mistaken for "en").
  static int _languageRank(String language) {
    final code = language.toLowerCase();
    for (var i = 0; i < _priorityLanguages.length; i++) {
      final target = _priorityLanguages[i];
      if (code == target || code.startsWith('$target-')) {
        return i;
      }
    }
    return _priorityLanguages.length;
  }

  static List<OpenSubtitleResult> _sortResults(
    List<OpenSubtitleResult> results,
  ) {
    results.sort((a, b) {
      final languageComparison =
          _languageRank(a.language).compareTo(_languageRank(b.language));
      if (languageComparison != 0) return languageComparison;

      // Most-downloaded first within the same language group.
      return b.downloadCount.compareTo(a.downloadCount);
    });

    return results;
  }

  /// Requests a one-time download link for [fileId], then fetches the
  /// actual subtitle text from it (SRT in the vast majority of cases).
  /// Both stages are retried independently on transient failures, since
  /// either one — the API handing out the link, or the CDN serving the
  /// file behind it — can 502/503 under load.
  static Future<String> download(int fileId) async {
    final response = await _request(
      () => _dio.post('/download', data: {'file_id': fileId}),
    );

    final link = response.data['link'] as String?;

    if (link == null) {
      throw StateError('OpenSubtitles did not return a download link.');
    }

    final fileResponse = await _request(
      () => _fileDio.get<String>(
        link,
        options: Options(responseType: ResponseType.plain),
      ),
      isFileDownload: true,
    );

    final content = (fileResponse.data as String?) ?? '';

    if (content.trim().isEmpty) {
      throw StateError(
        'OpenSubtitles returned an empty subtitle file. Try a different '
        'result from the list.',
      );
    }

    return content;
  }

  /// Status codes worth retrying — all transient, server-side failures.
  /// A 4xx (bad key, bad request, rate limit) will just fail again
  /// identically, so those are not retried.
  static const _retryableStatuses = {502, 503, 504};

  /// Runs a Dio call and, on failure, rewraps it so the *actual* reason
  /// OpenSubtitles gave (its JSON body's `message`, e.g. "Invalid API
  /// key" or a rate-limit notice) surfaces to the UI instead of Dio's
  /// generic "status code 403" wrapper, which tells you nothing about
  /// which of the several possible causes it actually was.
  ///
  /// Transient errors (502/503/504 — "server had a bad moment", not
  /// "your request is wrong"), plus bare connection/timeout failures,
  /// are retried up to [maxRetries] times with exponential backoff
  /// before giving up, since OpenSubtitles' shared infra returns 503s
  /// fairly often under load and a second or third attempt a beat later
  /// frequently just succeeds.
  static Future<Response> _request(
    Future<Response> Function() call, {
    int maxRetries = 3,
    bool isFileDownload = false,
  }) async {
    DioException? lastError;

    for (var attempt = 0; attempt <= maxRetries; attempt++) {
      try {
        return await call();
      } on DioException catch (error) {
        lastError = error;
        final status = error.response?.statusCode;

        // NAMESIS PRIME: the Worker answers 503 "not_configured" when its
        // OPENSUBTITLES_API_KEY secret is missing. Retrying cannot help and
        // "temporarily unavailable" would be misleading, so say what is wrong.
        final errBody = error.response?.data;
        if (status == 503 && errBody is Map && errBody['error'] == 'not_configured') {
          throw StateError(
            'Subtitle search is not set up on the proxy yet '
            '(${errBody['detail'] ?? 'missing API key'}).',
          );
        }

        // Retry real server errors, and also bare connection/timeout
        // failures (status == null) — those are just as likely to be a
        // transient network blip as a genuine problem.
        final retryable = status == null || _retryableStatuses.contains(status);

        debugPrint(
          '[OpenSubtitles] attempt ${attempt + 1}/${maxRetries + 1} '
          'failed (status: $status, type: ${error.type}): ${error.message}',
        );

        if (!retryable || attempt == maxRetries) break;

        await Future.delayed(Duration(milliseconds: 600 * (1 << attempt)));
      }
    }

    final error = lastError!;
    final status = error.response?.statusCode;

    if (status == null) {
      throw StateError(
        isFileDownload
            ? 'Could not reach the subtitle file after several attempts. '
                'Check your connection and try again.'
            : 'Could not reach OpenSubtitles after several attempts. '
                'Check your connection and try again.',
      );
    }

    if (_retryableStatuses.contains(status)) {
      throw StateError(
        "OpenSubtitles is temporarily unavailable (server error $status) "
        "after several attempts. Their service is likely under heavy load "
        "right now — please try again shortly.",
      );
    }

    if (status == 429) {
      throw StateError(
        "OpenSubtitles rate limit reached for this app's shared API key. "
        "Please wait a while before trying again.",
      );
    }

    final body = error.response?.data;

    String? message;
    if (body is Map) {
      message = body['message']?.toString() ?? body['errors']?.toString();
    }

    throw StateError(
      'OpenSubtitles error${status != null ? ' ($status)' : ''}: '
      '${message ?? error.message ?? 'unknown'}',
    );
  }
}
