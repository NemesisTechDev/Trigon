import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'addon_models.dart';

/// Talks to one addon over HTTP. Stateless; [AddonManager] owns the list.
class AddonClient {
  AddonClient._();

  static final Dio _dio = Dio(
    BaseOptions(
      // NAMESIS PRIME: addons that scrape or sign links can take a while.
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 40),
      // Every non-2xx is handled explicitly below; never throw on status.
      validateStatus: (_) => true,
      responseType: ResponseType.json,
    ),
  );

  /// Accepts what people actually paste: `http://host:7000`,
  /// `http://host:7000/manifest.json`, or Stremio's `stremio://host/...`.
  /// Returns the addon's base URL (no trailing slash, no manifest.json), or
  /// null if it isn't a usable http(s) URL.
  static String? normalizeBaseUrl(String input) {
    var s = input.trim();
    if (s.isEmpty) return null;
    if (s.startsWith('stremio://')) {
      s = 'https://${s.substring('stremio://'.length)}';
    }
    if (!s.contains('://')) s = 'http://$s';
    final uri = Uri.tryParse(s);
    if (uri == null || uri.host.isEmpty) return null;
    if (uri.scheme != 'http' && uri.scheme != 'https') return null;

    var path = uri.path;
    if (path.endsWith('/manifest.json')) {
      path = path.substring(0, path.length - '/manifest.json'.length);
    }
    while (path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    return Uri(
      scheme: uri.scheme,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
      path: path,
    ).toString();
  }

  /// Fetches and parses `manifest.json`. Throws [AddonException] with a
  /// message that is safe to show the person.
  static Future<AddonManifest> fetchManifest(String input) async {
    final base = normalizeBaseUrl(input);
    if (base == null) {
      throw const AddonException('That does not look like a valid addon URL.');
    }
    try {
      final res = await _dio.get('$base/manifest.json');
      if (res.statusCode != 200 || res.data is! Map) {
        throw AddonException(
            'No addon manifest found at that address (HTTP ${res.statusCode}).');
      }
      final manifest =
          AddonManifest.fromJson(Map<String, dynamic>.from(res.data as Map), base);
      if (manifest.resources.isEmpty) {
        throw const AddonException('This addon does not declare any resources.');
      }
      return manifest;
    } on AddonException {
      rethrow;
    } on DioException catch (e) {
      throw AddonException(_describe(e));
    } catch (e) {
      throw AddonException('Could not read the addon manifest: $e');
    }
  }

  static String _describe(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.sendTimeout:
        return 'The addon took too long to respond.';
      case DioExceptionType.connectionError:
        return 'Could not reach the addon. Check the address and that your '
            'phone and the addon are on the same network.';
      default:
        return 'Network error talking to the addon.';
    }
  }

  /// Counters read by the source picker to explain an empty list. Reset by
  /// the picker each time it opens.
  static int torrentOnlyCount = 0;
  static int failedStreamRequests = 0;

  /// Streams for one title. Never throws: any failure is an empty list so one
  /// broken addon can't hide the others' results.
  static Future<List<AddonStream>> fetchStreams(
    AddonManifest addon,
    String type,
    String id,
  ) async =>
      (await fetchStreamsChecked(addon, type, id)).streams;

  /// Like [fetchStreams], but also says whether the request itself failed
  /// (timeout, network error, bad status) as opposed to the addon honestly
  /// having nothing for this title. [AddonManager] uses that to decide
  /// whether an answer is worth remembering. Never throws.
  static Future<AddonStreamsResult> fetchStreamsChecked(
    AddonManifest addon,
    String type,
    String id,
  ) async {
    final data = await _getResource(addon, 'stream', type, id);
    if (data == null) failedStreamRequests++;
    final list = data?['streams'];
    if (list is! List) return AddonStreamsResult(const [], failed: data == null);
    final out = <AddonStream>[];
    for (final s in list) {
      final parsed = AddonStream.tryParse(
        s,
        addonId: addon.id,
        addonName: addon.name,
      );
      if (parsed != null) {
        out.add(parsed);
      } else if (s is Map && s['infoHash'] != null) {
        // Torrent-only result: this app plays direct links, not torrents.
        torrentOnlyCount++;
      }
    }
    return AddonStreamsResult(out, failed: false);
  }

  static Future<List<AddonSubtitle>> fetchSubtitles(
    AddonManifest addon,
    String type,
    String id,
  ) async {
    final data = await _getResource(addon, 'subtitles', type, id);
    final list = data?['subtitles'];
    if (list is! List) return const [];
    return list
        .map((s) => AddonSubtitle.tryParse(s, addon.name))
        .whereType<AddonSubtitle>()
        .toList();
  }

  /// When the first try ended because the addon was too slow to answer, the
  /// second try only waits this long: it can help when the addon finished the
  /// work in the background and now has the answer ready, but it must not
  /// double the wait for an addon that is simply slow.
  static const Duration _retryReceiveTimeout = Duration(seconds: 15);

  static Future<Map<String, dynamic>?> _getResource(
    AddonManifest addon,
    String resource,
    String type,
    String id,
  ) async {
    final url =
        '${addon.baseUrl}/$resource/$type/${Uri.encodeComponent(id)}.json';
    // One retry for network hiccups (dropped connections, a server that was
    // briefly down) and for a slow addon (with a shorter wait, see above).
    Options? retryOptions;
    for (var attempt = 1; attempt <= 2; attempt++) {
      final last = attempt == 2;
      try {
        final res = await _dio.get(
          url,
          options: attempt == 1 ? null : retryOptions,
        );
        var body = res.data;
        // Some addons answer with a JSON body but not a JSON content type,
        // which Dio hands back as a plain String.
        if (body is String) {
          try {
            body = jsonDecode(body);
          } catch (_) {}
        }
        final code = res.statusCode ?? 0;
        if (code == 200 && body is Map) {
          return Map<String, dynamic>.from(body);
        }
        debugPrint('[AddonClient] $url -> $code');
        // A server error is often gone a moment later. A 4xx answer (not
        // found, rate limited) is not retried: asking again right away
        // would not change it.
        if (!last && code >= 500) {
          await Future<void>.delayed(const Duration(milliseconds: 400));
          continue;
        }
        return null;
      } catch (e) {
        if (last) {
          debugPrint('[AddonClient] $url failed: $e');
          return null;
        }
        if (e is DioException && e.type == DioExceptionType.receiveTimeout) {
          retryOptions = Options(receiveTimeout: _retryReceiveTimeout);
        }
      }
    }
    return null;
  }
}

/// What one addon answered for a stream request.
class AddonStreamsResult {
  const AddonStreamsResult(this.streams, {required this.failed});

  final List<AddonStream> streams;

  /// True when the request did not get a usable answer (timeout, network
  /// error, bad status). False for a real answer, even an empty one.
  final bool failed;
}

class AddonException implements Exception {
  final String message;
  const AddonException(this.message);
  @override
  String toString() => message;
}
