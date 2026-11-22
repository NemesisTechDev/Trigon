import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../addons/addon_models.dart';
import '../catalog/catalog_models.dart';

/// Thrown with a message that is safe to show to the person.
class TorrentException implements Exception {
  final String message;
  const TorrentException(this.message);
  @override
  String toString() => message;
}

/// Plays torrent sources the way Stremio does: a small local torrent engine
/// downloads the pieces and serves the video file over plain HTTP on
/// 127.0.0.1, so the normal player just opens a URL.
///
/// The engine is TorrServer (open source, one executable, runs on Windows,
/// Linux, macOS and Android). This class only talks to its HTTP API:
///   GET  /echo                      -> engine is alive
///   POST /torrents {action:add|get} -> adds a magnet / reads its file list
///   GET  /stream/<name>?link=..&index=..&play -> the video bytes (Range ok)
class TorrentEngine {
  TorrentEngine._();
  static final TorrentEngine instance = TorrentEngine._();

  static const String defaultUrl = 'http://127.0.0.1:8090';
  static const String _prefsKey = 'namesis_torrent_engine_v1';

  /// Address of the engine, without a trailing slash.
  String baseUrl = defaultUrl;

  /// Optional path to the TorrServer executable. When set (desktop only),
  /// the app starts it by itself if it is not already running.
  String exePath = '';

  bool _loaded = false;
  Future<void>? _starting;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw == null) return;
      final j = jsonDecode(raw);
      if (j is Map) {
        final u = j['url']?.toString().trim() ?? '';
        if (u.isNotEmpty) baseUrl = _clean(u);
        exePath = j['exe']?.toString().trim() ?? '';
      }
    } catch (e) {
      debugPrint('[TorrentEngine] load failed: $e');
    }
  }

  Future<void> save({String? url, String? exe}) async {
    await load();
    if (url != null) {
      final u = url.trim();
      baseUrl = u.isEmpty ? defaultUrl : _clean(u);
    }
    if (exe != null) exePath = exe.trim();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          _prefsKey, jsonEncode({'url': baseUrl, 'exe': exePath}));
    } catch (e) {
      debugPrint('[TorrentEngine] save failed: $e');
    }
  }

  static String _clean(String u) {
    var s = u.trim();
    if (!s.contains('://')) s = 'http://$s';
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  Dio _dio({Duration receive = const Duration(seconds: 30)}) => Dio(
        BaseOptions(
          baseUrl: baseUrl,
          connectTimeout: const Duration(seconds: 8),
          receiveTimeout: receive,
          validateStatus: (_) => true,
        ),
      );

  /// True if the engine answers at [baseUrl].
  Future<bool> isRunning() async {
    await load();
    try {
      final res = await _dio(receive: const Duration(seconds: 3))
          .get<dynamic>('/echo');
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// What the engine reports for [infoHash] right now, or null when it cannot
  /// be read (engine not started yet, torrent not added yet). Never throws
  /// and never starts or changes anything; it only feeds the loading
  /// screen's progress.
  Future<TorrentLoadStats?> loadStats(String infoHash) async {
    try {
      await load();
      final info = await _post(
        _dio(receive: const Duration(seconds: 3)),
        {'action': 'get', 'hash': infoHash.toLowerCase()},
      );
      if (info == null) return null;
      return TorrentLoadStats.fromJson(info);
    } catch (_) {
      return null;
    }
  }

  /// Why the last automatic start failed (for the settings screen).
  String? lastStartError;

  /// True when [baseUrl] points at this device, so the app may start its own
  /// engine for it. A remote TorrServer is never started from here.
  bool get _isLocalAddress {
    final h = Uri.tryParse(baseUrl)?.host.toLowerCase() ?? '';
    return h == '127.0.0.1' || h == 'localhost' || h == '::1' || h == '[::1]';
  }

  /// The engine that ships inside the app, or null when this build has none.
  ///  - Android: libtorrserver.so inside the app's native library folder
  ///    (that folder is found through the already loaded libflutter.so).
  ///  - Windows / Linux: torrserver(.exe) next to the app executable.
  Future<String?> embeddedExe() async {
    try {
      if (Platform.isAndroid) {
        final bytes = await File('/proc/self/maps')
            .openRead()
            .expand((c) => c)
            .toList();
        final maps = utf8.decode(bytes, allowMalformed: true);
        for (final line in maps.split('\n')) {
          if (!line.contains('libflutter.so')) continue;
          final at = line.indexOf('/');
          if (at < 0) continue;
          final lib = line.substring(at).trim();
          if (lib.contains('!')) continue; // still packed inside the apk
          final dir = lib.substring(0, lib.lastIndexOf('/'));
          final f = File('$dir/libtorrserver.so');
          if (await f.exists()) return f.path;
        }
        return null;
      }
      if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
        final sep = Platform.isWindows ? '\\' : '/';
        final self = Platform.resolvedExecutable;
        final dir = self.substring(0, self.lastIndexOf(sep));
        final name = Platform.isWindows ? 'torrserver.exe' : 'torrserver';
        final f = File('$dir$sep$name');
        if (await f.exists()) return f.path;
      }
    } catch (e) {
      debugPrint('[TorrentEngine] embedded lookup failed: $e');
    }
    return null;
  }

  /// True when the app can start an engine by itself (own or chosen file).
  Future<bool> canAutoStart() async {
    await load();
    if (!_isLocalAddress) return false;
    if (exePath.isNotEmpty) return true;
    return (await embeddedExe()) != null;
  }

  /// Returns true when the engine is reachable, starting it first when the
  /// address is local and an engine file is available.
  Future<bool> ensureRunning() async {
    await load();
    if (await isRunning()) return true;
    if (!_isLocalAddress) return false;
    _starting ??= _start().whenComplete(() => _starting = null);
    await _starting;
    return isRunning();
  }

  Future<void> _start() async {
    lastStartError = null;
    try {
      final path = exePath.isNotEmpty ? exePath : await embeddedExe();
      if (path == null) {
        lastStartError = 'No torrent engine file is bundled with this build.';
        return;
      }
      final exe = File(path);
      if (!await exe.exists()) {
        lastStartError = 'Engine file not found: $path';
        debugPrint('[TorrentEngine] $lastStartError');
        return;
      }
      final port = Uri.tryParse(baseUrl)?.port ?? 8090;
      final data = Directory('${Directory.systemTemp.path}/torrserver');
      await data.create(recursive: true);
      await Process.start(
        path,
        ['--port', '$port', '--ip', '127.0.0.1', '--path', data.path],
        workingDirectory: data.path,
        mode: ProcessStartMode.detached,
      );
      // Give it a few seconds to open its port. Polled every 250 ms so the
      // first play starts the moment the engine is up (it used to wait out
      // whole 750 ms steps).
      for (var i = 0; i < 72; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        if (await isRunning()) return;
      }
      lastStartError = 'The engine was started but did not answer.';
    } catch (e) {
      lastStartError = 'Could not start the engine: $e';
      debugPrint('[TorrentEngine] $lastStartError');
    }
  }

  /// Turns a torrent [stream] into a normal one whose [AddonStream.url] is a
  /// local http address the player can open. Non-torrent streams are
  /// returned unchanged. Throws [TorrentException] with a readable message.
  Future<AddonStream> resolve(
    AddonStream stream, {
    CatalogEpisode? episode,
  }) async {
    if (!stream.isTorrent) return stream;
    await load();

    if (!await ensureRunning()) {
      final why = lastStartError == null ? '' : ' ($lastStartError)';
      throw TorrentException(
        _isLocalAddress
            ? 'The built-in torrent engine could not start$why. '
                'See Profile > Addons > Torrent engine.'
            : 'The torrent engine at $baseUrl is not reachable. '
                'Check its address in Profile > Addons > Torrent engine.',
      );
    }

    // Streaming connection settings must be in place BEFORE the torrent is
    // added (changing them restarts the engine's torrent client). Normally
    // warmUp() already did this while the source list was open, so this is
    // instant. Bounded and best effort: never holds playback up.
    await tuneForStreaming()
        .timeout(const Duration(seconds: 10), onTimeout: () {});

    final hash = stream.infoHash!.toLowerCase();
    final dio = _dio(receive: const Duration(seconds: 60));
    final clock = Stopwatch()..start();

    Map<String, dynamic>? info;
    try {
      info = await _post(dio, {
        'action': 'add',
        'link': stream.url, // magnet, includes the addon's trackers
        'title': stream.fileName ?? '',
        'save_to_db': false,
      });
    } on DioException catch (e) {
      // The engine may hold the request open while it looks for peers; that
      // is fine, the loop below keeps asking for the file list.
      if (e.type != DioExceptionType.receiveTimeout) {
        throw TorrentException(
            'Could not talk to the torrent engine (${e.type.name}).');
      }
    } on TorrentException catch (e) {
      // The engine answers an error status when the torrent's metadata did
      // not arrive within ITS own wait. That is not final: peers may still
      // show up, so keep polling until our own deadline (before this, the
      // first such answer ended the attempt at once).
      debugPrint('[TorrentEngine] add answered an error, will keep '
          'polling: ${e.message}');
    }

    // Metadata (the file list) can take a while when peers are few.
    var files = _files(info);
    final deadline = DateTime.now().add(const Duration(seconds: 90));
    while (files.isEmpty && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(seconds: 1));
      try {
        info = await _post(dio, {'action': 'get', 'hash': hash});
      } on DioException {
        // Keep trying until the deadline.
      } on TorrentException {
        // Same: the engine may not have registered it yet.
      }
      files = _files(info);
      if (files.isEmpty) {
        // Second opinion: the stream endpoint can also report torrent stats.
        files = _files(await _statViaStream(dio, stream.url));
      }
    }
    if (files.isEmpty) {
      throw const TorrentException(
        'No peers answered for this torrent, so it cannot start. '
        'Try another source, ideally one with more seeders.',
      );
    }

    debugPrint('[TorrentEngine] file list ready after '
        '${clock.elapsedMilliseconds} ms');
    final file = _pickFile(files, stream, episode);
    final base = file.path.split('/').last.split('\\').last;
    final name = base.isEmpty ? 'video.mp4' : base;

    final url = '$baseUrl/stream/${Uri.encodeComponent(name)}'
        '?link=${Uri.encodeQueryComponent(stream.url)}'
        '&index=${file.id}&play';

    return AddonStream(
      addonId: stream.addonId,
      addonName: stream.addonName,
      name: stream.name,
      description: stream.description,
      url: url,
      subtitles: stream.subtitles,
      height: stream.height,
      viaTorrent: true,
    );
  }

  bool _tuned = false; // full (download) tuning applied
  bool _streamTuned = false; // streaming tuning applied
  Future<void>? _tuningRun;
  bool _warmRequested = false;

  /// Starts the engine and applies the streaming settings in the
  /// background, so the first play does not pay for a cold start. Called as
  /// soon as a source list contains a torrent (the person is still reading
  /// the list). Safe to call any number of times; never throws.
  Future<void> warmUp() async {
    if (_warmRequested) return;
    _warmRequested = true;
    try {
      await load();
      if (!await ensureRunning()) {
        // Allow another attempt later (e.g. the engine was not ready).
        _warmRequested = false;
        return;
      }
      await tuneForStreaming();
    } catch (e) {
      _warmRequested = false;
      debugPrint('[TorrentEngine] warm-up failed: $e');
    }
  }

  /// Raises the engine's connection limits and cache so a download can use
  /// the whole swarm instead of the cautious streaming defaults. Best effort,
  /// done once per app run, and BEFORE a torrent is added (changing settings
  /// makes the engine restart its torrent client). Only values that are lower
  /// than wanted are changed.
  Future<void> tuneForDownload() => _runTuning(full: true);

  /// The part of the tuning that makes a torrent START faster: more peer
  /// connections, no download cap, extra trackers. Unlike
  /// [tuneForDownload] it leaves the cache alone. Only ever applied to the
  /// engine this app runs itself, never to a remote one the person set up.
  Future<void> tuneForStreaming() async {
    await load();
    if (!_isLocalAddress) return;
    await _runTuning(full: false);
  }

  Future<void> _runTuning({required bool full}) async {
    bool done() => _tuned || (!full && _streamTuned);
    if (done()) return;
    var pending = _tuningRun;
    while (pending != null) {
      await pending;
      if (done()) return;
      pending = _tuningRun;
    }
    final run = _tune(full: full);
    _tuningRun = run.whenComplete(() => _tuningRun = null);
    await _tuningRun;
  }

  Future<void> _tune({required bool full}) async {
    try {
      if (!await ensureRunning()) return;
      final dio = _dio();
      final res =
          await dio.post<dynamic>('/settings', data: {'action': 'get'});
      var data = res.data;
      if (data is String) data = jsonDecode(data);
      if (data is! Map) return;
      final current = Map<String, dynamic>.from(data);

      final changes = <String, dynamic>{};
      void atLeast(String key, int wanted) {
        final v = current[key];
        if (v is num && v >= wanted) return;
        changes[key] = wanted;
      }

      if (full) {
        atLeast('CacheSize', 256 * 1024 * 1024);
        atLeast('ReaderReadAHead', 95);
      }
      atLeast('ConnectionsLimit', 200);
      if (current['DownloadRateLimit'] is num &&
          (current['DownloadRateLimit'] as num) != 0) {
        changes['DownloadRateLimit'] = 0;
      }
      // Ask trackers for extra peers (0 = off, 1 = add).
      if (current['RetrackersMode'] is num &&
          (current['RetrackersMode'] as num) == 0) {
        changes['RetrackersMode'] = 1;
      }

      if (changes.isNotEmpty) {
        current.addAll(changes);
        await dio.post<dynamic>(
          '/settings',
          data: {'action': 'set', 'sets': current},
        );
        debugPrint('[TorrentEngine] tuned settings: ${changes.keys.join(', ')}');
        // The engine restarts its client; give it a moment.
        await Future<void>.delayed(const Duration(seconds: 2));
      }
      _streamTuned = true;
      if (full) _tuned = true;
    } catch (e) {
      debugPrint('[TorrentEngine] could not tune settings: $e');
    }
  }

  /// Drops a torrent (and its cached data) from the engine. Best effort:
  /// used after a download finished, so the copy kept for streaming does not
  /// take up space for nothing.
  Future<void> remove(String infoHash) async {
    try {
      await load();
      await _post(_dio(), {'action': 'rem', 'hash': infoHash.toLowerCase()});
    } catch (e) {
      debugPrint('[TorrentEngine] could not remove torrent: $e');
    }
  }

  Future<Map<String, dynamic>?> _statViaStream(Dio dio, String link) async {
    try {
      final res = await dio.get<dynamic>(
        '/stream?link=${Uri.encodeQueryComponent(link)}&stat',
        options: Options(receiveTimeout: const Duration(seconds: 15)),
      );
      var data = res.data;
      if (data is String) {
        try {
          data = jsonDecode(data);
        } catch (_) {}
      }
      return data is Map ? Map<String, dynamic>.from(data) : null;
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>?> _post(
    Dio dio,
    Map<String, dynamic> body,
  ) async {
    final res = await dio.post<dynamic>('/torrents', data: body);
    final code = res.statusCode ?? 0;
    if (code != 200) {
      throw TorrentException('The torrent engine answered HTTP $code.');
    }
    var data = res.data;
    if (data is String) {
      try {
        data = jsonDecode(data);
      } catch (_) {}
    }
    return data is Map ? Map<String, dynamic>.from(data) : null;
  }

  static List<_TFile> _files(Map<String, dynamic>? info) {
    final raw = info?['file_stats'];
    if (raw is! List) return const [];
    final out = <_TFile>[];
    for (var i = 0; i < raw.length; i++) {
      final f = raw[i];
      if (f is! Map) continue;
      final id = f['id'];
      final len = f['length'];
      out.add(_TFile(
        pos: i,
        id: id is num ? id.toInt() : i + 1,
        path: f['path']?.toString() ?? '',
        length: len is num ? len.toInt() : 0,
      ));
    }
    return out;
  }

  static const Set<String> _videoExt = {
    'mkv', 'mp4', 'avi', 'mov', 'm4v', 'webm', 'ts', 'm2ts', 'mpg', 'mpeg',
    'wmv', 'flv',
  };

  static bool _isVideo(String path) {
    final dot = path.lastIndexOf('.');
    if (dot < 0) return false;
    return _videoExt.contains(path.substring(dot + 1).toLowerCase());
  }

  static _TFile _largest(Iterable<_TFile> files) {
    var best = files.first;
    for (final f in files) {
      if (f.length > best.length) best = f;
    }
    return best;
  }

  /// Chooses which file of the torrent to play.
  ///
  /// Note: TorrServer lists files sorted by path, while an addon's fileIdx
  /// counts files in the torrent's own order, so fileIdx is only a last
  /// resort and is never trusted for movies.
  static _TFile _pickFile(
    List<_TFile> files,
    AddonStream stream,
    CatalogEpisode? episode,
  ) {
    // 1. The addon named the file.
    final wanted = stream.fileName?.trim().toLowerCase() ?? '';
    if (wanted.isNotEmpty) {
      final byName = files.where((f) {
        final p = f.path.toLowerCase();
        return p == wanted || p.endsWith('/$wanted') || p.endsWith('\\$wanted');
      }).toList();
      if (byName.isNotEmpty) return byName.first;
    }

    final videos = files.where((f) => _isVideo(f.path)).toList();
    if (videos.length == 1) return videos.first;

    // 2. A season pack: find the episode by its S01E02 / 1x02 marker.
    final ep = episode;
    if (ep != null && videos.isNotEmpty) {
      final a = RegExp('s0*${ep.season}[ ._-]*e0*${ep.number}(?!\\d)',
          caseSensitive: false);
      final b = RegExp('(?<!\\d)${ep.season}x0*${ep.number}(?!\\d)',
          caseSensitive: false);
      final matches =
          videos.where((f) => a.hasMatch(f.path) || b.hasMatch(f.path));
      if (matches.isNotEmpty) return _largest(matches);

      // No marker found: the addon's position hint, if it lands on a video.
      final idx = stream.fileIdx;
      if (idx != null && idx >= 0 && idx < files.length) {
        final hinted = files[idx];
        if (_isVideo(hinted.path)) return hinted;
      }
    }

    // 3. Otherwise the biggest video (the movie itself, not samples).
    if (videos.isNotEmpty) return _largest(videos);
    return _largest(files);
  }
}

/// A snapshot of how far the engine has got with one torrent (see
/// [TorrentEngine.loadStats]). Fields the engine does not send read as 0.
class TorrentLoadStats {
  /// Files listed so far: more than 0 once the torrent's metadata arrived.
  final int fileCount;

  /// Peers the engine is currently exchanging data with.
  final int activePeers;

  /// Bytes already preloaded, and how many it wants before it starts
  /// serving (preloadSize is 0 when no preload is running).
  final int preloadedBytes;
  final int preloadSize;

  const TorrentLoadStats({
    required this.fileCount,
    required this.activePeers,
    required this.preloadedBytes,
    required this.preloadSize,
  });

  static int _int(dynamic v) => v is num ? v.toInt() : 0;

  factory TorrentLoadStats.fromJson(Map<String, dynamic> j) {
    final files = j['file_stats'];
    return TorrentLoadStats(
      fileCount: files is List ? files.length : 0,
      activePeers: _int(j['active_peers']),
      preloadedBytes: _int(j['preloaded_bytes']),
      preloadSize: _int(j['preload_size']),
    );
  }
}

class _TFile {
  final int pos;
  final int id;
  final String path;
  final int length;
  const _TFile({
    required this.pos,
    required this.id,
    required this.path,
    required this.length,
  });
}
