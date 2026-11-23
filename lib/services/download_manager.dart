import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:disk_space_plus/disk_space_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import '../addons/addon_manager.dart';
import '../addons/addon_models.dart';
import '../addons/stream_info.dart';
import '../addons/stream_rules.dart';
import '../catalog/catalog_models.dart';
import '../library/watch_entry.dart';
import '../player/models/media_item.dart';
import '../player/services/media_stream_parser.dart';
import '../torrent/torrent_engine.dart';
import 'analytics_service.dart';
import 'app_settings.dart';
import 'download_keepalive.dart';
import 'download_notification_service.dart';
import 'id3_artwork_embedder.dart';
import 'jellyfin_services/media_service.dart';
import 'offline_progress_store.dart';
import 'sidecar_subtitles.dart';

/// The three kinds of content the Downloads page groups content into.
enum DownloadKind { movie, episode, song }

/// Every state a download can be in on its way to (or instead of)
/// becoming a completed [DownloadRecord]. "Not downloaded" isn't a
/// member here on purpose — it's simply the absence of both a
/// [DownloadTask] and a [DownloadRecord] for that id.
enum DownloadState { queued, downloading, paused, failed }

/// Everything an addon download needs beyond the Jellyfin-shaped item: which
/// title / episode it is and which source (direct link or torrent) to fetch.
class AddonDownloadJob {
  final CatalogTitle title;
  final CatalogEpisode? episode;

  /// The chosen source. Null for an episode queued by "Download all": its
  /// source (the best one at [wantHeight]) is looked up when its turn comes.
  AddonStream? stream;
  StreamInfo info;

  /// The quality asked for when [stream] is not chosen yet.
  final int? wantHeight;

  /// True when the person picked a torrent for "Download all": each episode
  /// then looks for a torrent first (a direct link only when it has none
  /// that can be used). False: a direct link first, then a torrent.
  final bool wantTorrent;

  /// True once an expired direct link was replaced by a fresh one.
  bool refreshed = false;

  AddonDownloadJob({
    required this.title,
    this.stream,
    this.info = const StreamInfo(),
    this.episode,
    this.wantHeight,
    this.wantTorrent = false,
  });

  Map<String, dynamic> toJson() => {
        'title': TitleSnapshot.of(title).toJson(),
        if (episode != null) 'episode': episodeToRaw(episode!),
        if (stream != null) 'stream': stream!.toJson(),
        'info': info.toJson(),
        'wantHeight': wantHeight,
        'wantTorrent': wantTorrent,
        'refreshed': refreshed,
      };

  static AddonDownloadJob? fromJson(dynamic j) {
    if (j is! Map) return null;
    final snap = TitleSnapshot.fromJson(j['title']);
    if (snap == null) return null;
    final stream = j['stream'] == null ? null : AddonStream.fromJson(j['stream']);
    final wanted = (j['wantHeight'] as num?)?.toInt();
    // Neither a source nor a quality to look one up with: unusable.
    if (stream == null && wanted == null) return null;
    final job = AddonDownloadJob(
      title: snap.toTitle(),
      episode: episodeFromRaw(j['episode']),
      stream: stream,
      info: StreamInfo.fromJson(j['info']),
      wantHeight: wanted,
      wantTorrent: j['wantTorrent'] == true,
    );
    job.refreshed = j['refreshed'] == true;
    return job;
  }
}

/// A snapshot of an in-flight (or not-yet-started, or errored) download
/// — everything the Downloads screen, the floating summary pill, and
/// every download indicator dotted around the app need to render one
/// consistent state without any of them owning their own copy of it.
/// Lives only for as long as the transfer isn't finished: a completed
/// download becomes a [DownloadRecord] instead and this is discarded.
class DownloadTask {
  final String id;
  final DownloadKind kind;
  final String title;
  final String subtitle;

  /// The id used to build a live network thumbnail (`MediaService.
  /// getImageUrl`/`getMusicImage`) while the transfer is in flight —
  /// for an episode this is the *series'* id, same fallback
  /// [DownloadRecord]/`mediaItemFor` already use for art.
  final String imageId;

  /// The original Jellyfin item this task was started from — kept so
  /// a paused/failed task can be resumed without needing the caller to
  /// hand it back over.
  final Map<String, dynamic> item;

  DownloadState state;
  int downloadedBytes;
  int totalBytes;

  /// Bytes/second, only meaningful while [state] is
  /// [DownloadState.downloading] — zeroed out otherwise.
  double speedBps;

  String? error;
  final int addedAt;

  // Resolved once (on the first attempt) and reused across pause/
  // resume/retry so a resumed transfer appends to the exact same file
  // instead of colliding with it and getting renamed "(2)".
  String? mediaPath;
  String? mediaDir;
  String? baseName;

  /// For a song: the MP3 bitrate (kbps) the person chose to download it
  /// at, or null for the original file untouched. Kept on the task so a
  /// paused/failed download resumes at the same quality it started at.
  final int? targetKbps;

  /// Size guess (bytes) for a download whose real size the server can't
  /// tell us up front — a transcode is generated on the fly, so it has no
  /// Content-Length. Only used to give the progress bar something to
  /// measure against; 0 means "no estimate".
  int estimatedBytes = 0;

  /// Set for a download that comes from an addon source (a direct link or a
  /// torrent) rather than from a Jellyfin server.
  final AddonDownloadJob? job;

  /// True when the transfer was cut off because no data arrived for too long
  /// (so it is reported as a failure, not a cancel).
  bool stalledOut = false;

  /// Set when the transfer failed because the connection dropped: it is
  /// retried by itself once a network comes back.
  bool retryOnNetwork = false;
  int autoRetries = 0;

  /// Held back by "Download on Wi-Fi Only": paused because the device is on
  /// mobile data, and continued by itself once Wi-Fi is back.
  bool waitingForWifi = false;

  DownloadTask({
    required this.id,
    required this.kind,
    required this.title,
    required this.subtitle,
    required this.imageId,
    required this.item,
    required this.state,
    this.downloadedBytes = 0,
    this.totalBytes = 0,
    this.speedBps = 0,
    this.error,
    required this.addedAt,
    this.mediaPath,
    this.mediaDir,
    this.baseName,
    this.targetKbps,
    this.job,
  });

  double get progress => totalBytes > 0
      ? (downloadedBytes / totalBytes).clamp(0.0, 1.0).toDouble()
      : 0;
}

/// The aggregate download state of a group of ids — what a season's or
/// album's "6 / 10 downloaded" header is built from, without every
/// caller having to loop over [DownloadManager] queries by hand.
class DownloadAggregate {
  final int completed;
  final int total;
  final int activeOrQueued;
  final bool hasFailed;

  /// The progress of whichever item in the group happens to be
  /// actively downloading right now, if any — enough to give the
  /// aggregate bar a bit of live motion without tracking per-item
  /// progress at this level.
  final double? activeProgress;

  const DownloadAggregate({
    required this.completed,
    required this.total,
    required this.activeOrQueued,
    required this.hasFailed,
    this.activeProgress,
  });

  bool get isEmpty => total == 0;
  bool get isComplete => total > 0 && completed == total;
  double get fraction => total > 0 ? completed / total : 0;
}

/// Everything needed to show a downloaded item in the UI and play it back
/// without touching the network — a snapshot of the original Jellyfin
/// item plus where its bytes actually live on disk.
class DownloadRecord {
  final String id;
  final DownloadKind kind;
  final String title;
  final String subtitle;

  final String? seriesId;
  final String? seriesName;
  final String? seasonId;
  final String? seasonName;
  final int? episodeIndex;

  final String? albumId;
  final String? albumName;
  final String artistName;

  final String? mediaPath;
  final String? posterPath;

  /// Path to a locally-cached landscape (`Thumb`-type) image, when the
  /// server had one — used by the Downloads screen's row layout, which
  /// mirrors the Continue Watching card's 16:9 art instead of the
  /// portrait poster used everywhere else. Null falls back to
  /// [posterPath] at render time; not every item has a Thumb image on
  /// the server, so this is best-effort.
  final String? thumbPath;

  /// Path to this specific episode's own locally-cached Primary image
  /// (an actual frame grab from the episode, same image
  /// MediaService.getEpisodeThumbUrl shows on the TV show detail
  /// screen's episode cards) — as opposed to [posterPath]/[thumbPath]
  /// above, which for an episode-kind record deliberately hold the
  /// *series'* shared art instead (used by DownloadedShowTile's series
  /// row, and as this field's own fallback when the server has no
  /// per-episode image). Null for movie/song records, and for an
  /// episode whose own image download failed or hasn't happened yet.
  final String? episodeThumbPath;

  /// Path to the downloaded `.lrc` lyrics sidecar for a song, when
  /// Jellyfin had lyrics for it at download time. Lives next to
  /// [mediaPath] on disk, inside the same album folder.
  final String? lyricsPath;

  /// Paths to any downloaded subtitle sidecar files for a movie/episode
  /// (one per text-based subtitle track Jellyfin could serve), named to
  /// match [mediaPath]'s file name so mpv's own same-folder subtitle
  /// auto-detection picks them up without any extra wiring.
  final List<String> subtitlePaths;

  final int runtimeTicks;
  final int fileSizeBytes;
  final int addedAt;

  /// For a song downloaded as an MP3 at a chosen quality: that bitrate in
  /// kbps. Null for everything else, including every song downloaded
  /// before quality choice existed — i.e. "the original file".
  final int? downloadKbps;

  /// The original Jellyfin JSON this record was built from — kept so
  /// detail screens can be handed a proper `initialItem` (aspect ratio,
  /// overview, genres, etc.) and so MediaService.mediaItemFromJellyfin
  /// can still be used as a base when building a playable MediaItem.
  final Map<String, dynamic> raw;

  const DownloadRecord({
    required this.id,
    required this.kind,
    required this.title,
    required this.subtitle,
    this.seriesId,
    this.seriesName,
    this.seasonId,
    this.seasonName,
    this.episodeIndex,
    this.albumId,
    this.albumName,
    this.artistName = '',
    this.mediaPath,
    this.posterPath,
    this.thumbPath,
    this.episodeThumbPath,
    this.lyricsPath,
    this.subtitlePaths = const [],
    this.runtimeTicks = 0,
    this.fileSizeBytes = 0,
    required this.addedAt,
    this.downloadKbps,
    required this.raw,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind.name,
        'title': title,
        'subtitle': subtitle,
        'seriesId': seriesId,
        'seriesName': seriesName,
        'seasonId': seasonId,
        'seasonName': seasonName,
        'episodeIndex': episodeIndex,
        'albumId': albumId,
        'albumName': albumName,
        'artistName': artistName,
        'mediaPath': mediaPath,
        'posterPath': posterPath,
        'thumbPath': thumbPath,
        'episodeThumbPath': episodeThumbPath,
        'lyricsPath': lyricsPath,
        'subtitlePaths': subtitlePaths,
        'runtimeTicks': runtimeTicks,
        'fileSizeBytes': fileSizeBytes,
        'addedAt': addedAt,
        'downloadKbps': downloadKbps,
        'raw': raw,
      };

  factory DownloadRecord.fromJson(Map<String, dynamic> json) {
    return DownloadRecord(
      id: json['id'],
      kind: DownloadKind.values.firstWhere(
        (k) => k.name == json['kind'],
        orElse: () => DownloadKind.movie,
      ),
      title: json['title'] ?? '',
      subtitle: json['subtitle'] ?? '',
      seriesId: json['seriesId'],
      seriesName: json['seriesName'],
      seasonId: json['seasonId'],
      seasonName: json['seasonName'],
      episodeIndex: json['episodeIndex'],
      albumId: json['albumId'],
      albumName: json['albumName'],
      artistName: json['artistName'] ?? '',
      mediaPath: json['mediaPath'],
      posterPath: json['posterPath'],
      thumbPath: json['thumbPath'],
      episodeThumbPath: json['episodeThumbPath'],
      lyricsPath: json['lyricsPath'],
      subtitlePaths: json['subtitlePaths'] != null
          ? List<String>.from(json['subtitlePaths'])
          : const [],
      runtimeTicks: json['runtimeTicks'] ?? 0,
      fileSizeBytes: json['fileSizeBytes'] ?? 0,
      addedAt: json['addedAt'] ?? 0,
      downloadKbps: (json['downloadKbps'] as num?)?.toInt(),
      raw: Map<String, dynamic>.from(json['raw'] ?? {}),
    );
  }
}

/// Singleton that owns everything about downloads: queueing and running
/// transfers with real progress/speed, pausing and resuming them,
/// retrying failures, persisting completed records to disk (via a
/// JSON file in the app's private documents directory — avoids stuffing
/// potentially large raw item payloads into SharedPreferences), and
/// building locally-playable MediaItems for the player.
///
/// The media files themselves (and their subtitle/lyrics sidecars) are
/// deliberately NOT kept in that private directory — they're written to
/// the device's public `Download/Nemesis` folder (see [_publicRoot]) so
/// they're visible to any file manager, survive an app uninstall, and
/// can be organized/removed outside the app. [_records] always mirrors
/// what's actually still on disk under that folder: [refresh] (and
/// every load path) drops any record whose backing file has vanished,
/// which is what makes the Downloads page follow along when someone
/// deletes a file directly out of Nemesis's Downloads folder.
///
/// A ChangeNotifier so the Downloads page, the floating download
/// summary pill, and any download indicator dotted around detail
/// screens/cards can all react live to the same state without polling.
class DownloadManager extends ChangeNotifier {
  DownloadManager._();
  static final DownloadManager instance = DownloadManager._();

  final Map<String, DownloadRecord> _records = {};

  // Every download that isn't finished yet — queued, actively
  // transferring, paused, or failed. Removed the moment it either
  // completes (folds into [_records]) or is explicitly cancelled.
  final Map<String, DownloadTask> _tasks = {};
  final Map<String, CancelToken> _tokens = {};

  // Ids that finished transferring in the last couple of seconds —
  // purely cosmetic, so the Downloads screen's active-downloads
  // section can show a brief "finished" state (device icon + gold
  // check) instead of an item just vanishing from DOWNLOADING the
  // instant its bytes land, before it settles into the ordinary
  // completed row below. Never persisted; cleared on a short timer.
  final Set<String> _recentlyCompleted = {};

  // FIFO of task ids waiting for a concurrency slot to free up.
  final List<String> _queue = [];

  // Ids currently being paused — checked (and cleared) the moment the
  // resulting cancellation lands, so that path can tell a deliberate
  // pause apart from an outright cancel or a real network failure
  // without depending on the exact shape of Dio's cancel exception.
  final Set<String> _pauseRequested = {};

  /// Resume was tapped while a pause was still winding down: start again as
  /// soon as the pause has completed.
  final Set<String> _resumeWhenPaused = {};

  // How many transfers run at once — enough for the floating pill and
  // Downloads screen to show genuinely simultaneous progress without
  // hammering the server with everything a person queues up at once.
  static const int _maxConcurrent = 2;

  bool _initialized = false;
  bool get initialized => _initialized;

  // ────────────────────────── Storage locations ──────────────────────────

  /// App-private directory — only the index.json (the list of
  /// DownloadRecords) and cached poster art live here. Neither is media
  /// the person actually asked to keep, so there's no reason to put
  /// them in the public folder alongside the real downloads.
  Future<Directory> get _privateRoot async {
    final dir = await getApplicationDocumentsDirectory();
    final downloadsDir = Directory('${dir.path}/downloads');
    if (!await downloadsDir.exists()) {
      await downloadsDir.create(recursive: true);
    }
    return downloadsDir;
  }

  Future<File> get _indexFile async {
    final dir = await _privateRoot;
    return File('${dir.path}/index.json');
  }

  Directory? _publicRootCache;

  /// The public, user-visible root every downloaded media file lives
  /// under: `<device Downloads folder>/Nemesis`. Derived from
  /// path_provider's app-specific external directory
  /// (`.../Android/data/<package>/files`) by walking back up to the
  /// primary shared-storage root — that's more portable across devices
  /// than hardcoding `/storage/emulated/0`, while still landing on the
  /// same public `Download` folder the OS Downloads app and any file
  /// manager browse.
  Future<Directory> get _publicRoot async {
    if (_publicRootCache != null) return _publicRootCache!;

    Directory root;
    if (Platform.isAndroid) {
      final extDir = await getExternalStorageDirectory();
      if (extDir != null && extDir.path.contains('/Android/')) {
        final sharedRoot = extDir.path.split('/Android/').first;
        root = Directory('$sharedRoot/Download/Nemesis');
      } else {
        // Extremely unlikely fallback — no external storage volume at
        // all. Falls back to app-private storage so downloads still
        // work, just without the public-folder visibility this is
        // otherwise built for.
        final appDir = await getApplicationDocumentsDirectory();
        root = Directory('${appDir.path}/Nemesis');
      }
    } else {
      // Non-Android platforms (e.g. a desktop dev run) — a "Downloads"
      // folder isn't a scoped-storage concept there, so app documents
      // is a perfectly normal place for it.
      final appDir = await getApplicationDocumentsDirectory();
      root = Directory('${appDir.path}/Nemesis');
    }

    if (!await root.exists()) {
      await root.create(recursive: true);
    }
    _publicRootCache = root;
    return root;
  }

  Future<Directory> _subDir(String name) async {
    final root = await _publicRoot;
    final dir = Directory('${root.path}/$name');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<Directory> _albumDir(String albumName) async {
    final music = await _subDir('Music');
    final dir = Directory('${music.path}/${_sanitize(albumName)}');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<Directory> _movieDir(String title) async {
    final movies = await _subDir('Movies');
    final dir = Directory('${movies.path}/${_sanitize(title)}');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<Directory> _showDir(String seriesName) async {
    final shows = await _subDir('TV Shows');
    final dir = Directory('${shows.path}/${_sanitize(seriesName)}');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// Strips characters that are illegal (or awkward) in a folder/file
  /// name on Android's filesystem, so a title like "Foo: Bar?" doesn't
  /// blow up directory creation.
  String _sanitize(String name) {
    final cleaned = name
        .trim()
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ');
    return cleaned.isEmpty ? 'Unknown' : cleaned;
  }

  /// Builds a file in [dir] named [baseName].[ext], appending " (2)",
  /// " (3)", etc. if that name is already taken — e.g. two different
  /// songs on an album that happen to share a title.
  Future<File> _uniqueFile(Directory dir, String baseName, String ext) async {
    var candidate = File('${dir.path}/$baseName.$ext');
    var n = 2;
    while (await candidate.exists()) {
      candidate = File('${dir.path}/$baseName ($n).$ext');
      n++;
    }
    return candidate;
  }

  // ───────────────────────────── Permissions ─────────────────────────────

  /// Makes sure this app can actually write into the public Downloads
  /// folder before a transfer starts. Android 11+ (this app's whole
  /// target range) needs the "All files access" special permission for
  /// plain File I/O against a public path outside the app's own
  /// sandbox — scoped storage otherwise blocks it outright. Older
  /// versions fall back to the legacy storage permission.
  Future<bool> ensureStoragePermission() async {
    if (!Platform.isAndroid) return true;

    if (await Permission.manageExternalStorage.isGranted) return true;

    final status = await Permission.manageExternalStorage.request();
    if (status.isGranted) return true;

    // Pre-Android-11 devices don't have manageExternalStorage at all —
    // request() above resolves that as permanently denied/restricted
    // instantly on them, so fall back to the permission that actually
    // applies there.
    final legacy = await Permission.storage.request();
    return legacy.isGranted;
  }

  /// Loads persisted records from disk. Call once at app startup — safe
  /// to call more than once, subsequent calls are no-ops.
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    try {
      final file = await _indexFile;
      if (await file.exists()) {
        final raw = await file.readAsString();
        final list = jsonDecode(raw) as List;

        for (final entry in list) {
          final record = DownloadRecord.fromJson(
            Map<String, dynamic>.from(entry),
          );
          // Drop the record if its file vanished underneath us (folder
          // deleted from a file manager, storage cleared, etc.) instead
          // of showing a broken tile forever.
          if (record.mediaPath != null &&
              await File(record.mediaPath!).exists()) {
            _records[record.id] = record;
          }
        }
      }
    } catch (e) {
      debugPrint('DownloadManager.init failed: $e');
    }

    await _restoreTasks();
    _tasksRestored = true;
    _watchNetwork();

    notifyListeners();
    if (_tasks.isNotEmpty) {
      unawaited(DownloadNotificationService.instance
          .updateSummary(this)
          .catchError((Object e) => debugPrint('summary after restore: $e')));
    }
  }

  // ───────────────── Surviving an app restart / power-off ─────────────────

  bool _tasksRestored = false;
  String? _lastTasksSig;
  Timer? _tasksPersistTimer;

  Future<File> get _tasksFile async {
    final dir = await _privateRoot;
    return File('${dir.path}/tasks.json');
  }

  /// Called on every state change: when the set of tasks or any task's state
  /// changed, the list is saved (a moment later, so bursts are one write).
  /// Progress is not saved: the bytes on disk are the progress.
  void _syncTasksPersist() {
    if (!_tasksRestored) return;
    final sig = StringBuffer();
    for (final t in _tasks.values) {
      sig
        ..write(t.id)
        ..write(':')
        ..write(t.state.index)
        ..write(':')
        ..write(t.mediaPath ?? '')
        ..write(':')
        ..write(t.job?.stream?.url.hashCode ?? 0)
        ..write(';');
    }
    final now = sig.toString();
    if (now == _lastTasksSig) return;
    _lastTasksSig = now;
    _tasksPersistTimer?.cancel();
    _tasksPersistTimer =
        Timer(const Duration(milliseconds: 600), () => unawaited(_persistTasks()));
  }

  Map<String, dynamic> _taskToJson(DownloadTask t) => {
        'id': t.id,
        'kind': t.kind.name,
        'title': t.title,
        'subtitle': t.subtitle,
        'imageId': t.imageId,
        'item': t.item,
        'state': t.state.name,
        'addedAt': t.addedAt,
        'targetKbps': t.targetKbps,
        'mediaPath': t.mediaPath,
        'mediaDir': t.mediaDir,
        'baseName': t.baseName,
        'totalBytes': t.totalBytes,
        'error': t.error,
        if (t.job != null) 'job': t.job!.toJson(),
      };

  Future<void> _persistTasks() async {
    try {
      final list = <Map<String, dynamic>>[];
      for (final t in _tasks.values) {
        try {
          final m = _taskToJson(t);
          jsonEncode(m); // a task that cannot be saved is skipped, not fatal
          list.add(m);
        } catch (e) {
          debugPrint('download ${t.id} could not be saved: $e');
        }
      }
      final file = await _tasksFile;
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(jsonEncode(list), flush: true);
      await tmp.rename(file.path);
    } catch (e) {
      debugPrint('saving downloads failed: $e');
    }
  }

  /// Brings back downloads that were not finished when the app stopped
  /// (closed, killed, phone switched off). They come back paused, with the
  /// progress that is on disk, ready to continue.
  Future<void> _restoreTasks() async {
    try {
      final file = await _tasksFile;
      if (!await file.exists()) return;
      final list = jsonDecode(await file.readAsString());
      if (list is! List) return;
      for (final e in list) {
        try {
          if (e is! Map) continue;
          final m = Map<String, dynamic>.from(e);
          final id = m['id']?.toString();
          if (id == null || id.isEmpty) continue;
          if (_records.containsKey(id) || _tasks.containsKey(id)) continue;

          DownloadKind? kind;
          for (final k in DownloadKind.values) {
            if (k.name == m['kind']) kind = k;
          }
          if (kind == null) continue;
          final itemRaw = m['item'];
          if (itemRaw is! Map) continue;

          AddonDownloadJob? job;
          if (m['job'] != null) {
            job = AddonDownloadJob.fromJson(m['job']);
            if (job == null) continue;
          }

          final mediaPath = m['mediaPath']?.toString();
          final (have, total) = await _diskProgress(mediaPath);
          final wasFailed = m['state'] == DownloadState.failed.name;

          final task = DownloadTask(
            id: id,
            kind: kind,
            title: (m['title'] ?? '').toString(),
            subtitle: (m['subtitle'] ?? '').toString(),
            imageId: (m['imageId'] ?? id).toString(),
            item: Map<String, dynamic>.from(itemRaw),
            state: wasFailed ? DownloadState.failed : DownloadState.paused,
            downloadedBytes: have,
            totalBytes: total > 0 ? total : ((m['totalBytes'] as num?)?.toInt() ?? 0),
            error: wasFailed ? (m['error']?.toString() ?? 'Download failed') : null,
            addedAt: (m['addedAt'] as num?)?.toInt() ??
                DateTime.now().millisecondsSinceEpoch,
            mediaPath: mediaPath,
            mediaDir: m['mediaDir']?.toString(),
            baseName: m['baseName']?.toString(),
            targetKbps: (m['targetKbps'] as num?)?.toInt(),
            job: job,
          );
          _tasks[id] = task;
        } catch (err) {
          debugPrint('restoring a download failed: $err');
        }
      }
    } catch (e) {
      debugPrint('restoring downloads failed: $e');
    }
  }

  StreamSubscription<List<ConnectivityResult>>? _netSub;

  /// Whether the device is on Wi-Fi / ethernet right now. Null until the
  /// first reading arrives; "Download on Wi-Fi Only" treats null as "not
  /// yet", so nothing sneaks onto mobile data during startup.
  bool? _onUnmetered;

  bool get _mayUseNetwork =>
      !AppSettings.downloadWifiOnly.value || _onUnmetered == true;

  void _applyConnectivity(List<ConnectivityResult> results) {
    _onUnmetered = results.contains(ConnectivityResult.wifi) ||
        results.contains(ConnectivityResult.ethernet);
    _syncWifiOnly();
  }

  /// Brings downloads in line with "Download on Wi-Fi Only" and the current
  /// connection: off Wi-Fi, running and queued downloads stop (keeping the
  /// bytes already on disk); back on Wi-Fi, the ones that were held back
  /// continue.
  void _syncWifiOnly() {
    if (_mayUseNetwork) {
      for (final t in _tasks.values.toList()) {
        if (!t.waitingForWifi) continue;
        final stopping = t.state == DownloadState.downloading &&
            _pauseRequested.contains(t.id);
        if (t.state == DownloadState.paused || stopping) {
          resumeDownload(t.id);
        } else {
          t.waitingForWifi = false;
        }
      }
    } else {
      for (final t in _tasks.values.toList()) {
        if (t.state == DownloadState.downloading ||
            t.state == DownloadState.queued) {
          t.waitingForWifi = true;
          pauseDownload(t.id);
        }
      }
    }
  }

  /// Parks a download that may not start because Wi-Fi-only is on and the
  /// device is on mobile data. It shows as paused and resumes by itself.
  void _parkForWifi(DownloadTask task) {
    _queue.remove(task.id);
    task.state = DownloadState.paused;
    task.waitingForWifi = true;
    task.error = null;
    task.speedBps = 0;
    notifyListeners();
    DownloadNotificationService.instance.onPaused(task);
    unawaited(DownloadNotificationService.instance.updateSummary(this));
  }

  /// A download that failed because the connection dropped continues by
  /// itself when a network is back.
  void _watchNetwork() {
    if (_netSub != null) return;
    try {
      AppSettings.downloadWifiOnly.addListener(_syncWifiOnly);
      Connectivity().checkConnectivity().then(_applyConnectivity).catchError(
            (Object e) => debugPrint('connectivity check failed: $e'),
          );
      _netSub = Connectivity().onConnectivityChanged.listen((results) {
        _applyConnectivity(results);
        if (results.every((r) => r == ConnectivityResult.none)) return;
        Future<void>.delayed(const Duration(seconds: 3), () {
          if (!_mayUseNetwork) return;
          for (final t in _tasks.values.toList()) {
            if (t.state == DownloadState.failed &&
                t.retryOnNetwork &&
                t.autoRetries < 20) {
              t.autoRetries++;
              resumeDownload(t.id);
            }
          }
        });
      });
    } catch (e) {
      debugPrint('network watch unavailable: $e');
    }
  }

  Future<void> _persist() async {
    final file = await _indexFile;
    final list = _records.values.map((r) => r.toJson()).toList();
    await file.writeAsString(jsonEncode(list));
  }

  /// Re-scans disk and reloads records, even though [init] already ran.
  /// Used by the Downloads page's pull-to-refresh and its periodic
  /// live-sync check — unlike init(), this always re-reads the index
  /// file (dropping any record whose backing file has since vanished)
  /// instead of no-oping, so it picks up changes made outside the app —
  /// e.g. a file (or a whole album/movie/show folder) deleted straight
  /// out of the device's Downloads > Nemesis folder in a file manager.
  Future<void> refresh() async {
    // Set below once the on-disk index has been compared with memory. If
    // reading it fails, listeners are still notified, as before.
    var refreshChanged = true;
    try {
      final file = await _indexFile;
      final fresh = <String, DownloadRecord>{};

      if (await file.exists()) {
        final raw = await file.readAsString();
        final list = jsonDecode(raw) as List;

        for (final entry in list) {
          final record = DownloadRecord.fromJson(
            Map<String, dynamic>.from(entry),
          );
          if (record.mediaPath != null &&
              await File(record.mediaPath!).exists()) {
            fresh[record.id] = record;
          }
        }
      }

      final changed = fresh.length != _records.length ||
          !fresh.keys.every(_records.containsKey);

      // Whether anything a listener could be showing differs. Compared
      // before _records is overwritten below.
      var visiblyChanged = changed;
      if (!visiblyChanged) {
        for (final entry in fresh.entries) {
          final old = _records[entry.key];
          if (old == null ||
              old.mediaPath != entry.value.mediaPath ||
              old.fileSizeBytes != entry.value.fileSizeBytes ||
              old.posterPath != entry.value.posterPath ||
              old.thumbPath != entry.value.thumbPath ||
              old.episodeThumbPath != entry.value.episodeThumbPath ||
              old.title != entry.value.title) {
            visiblyChanged = true;
            break;
          }
        }
      }
      refreshChanged = visiblyChanged;

      _records
        ..clear()
        ..addAll(fresh);

      // Prunes anything dropped above out of the persisted index too,
      // so a restart doesn't have to silently re-discover the same
      // deletions every time.
      if (changed) {
        await _persist();
      }
    } catch (e) {
      debugPrint('DownloadManager.refresh failed: $e');
      // Leaves whatever was already loaded in place on failure, same as
      // every other load path in this class.
    }

    // Nothing differs from what's already in memory (the usual result of
    // the Downloads page's periodic sync): skip the notification.
    // Notifying unconditionally rebuilt every DownloadButton, song row
    // and the Downloads page itself on each poll for no visible change.
    if (refreshChanged) notifyListeners();
  }

  // ─────────────────────────────── Queries ───────────────────────────────

  bool isDownloaded(String id) => _records.containsKey(id);
  DownloadRecord? recordFor(String id) => _records[id];

  /// Subtitle files that belong to the downloaded video [id], as absolute
  /// paths: the ones saved with it (still existing) plus any other subtitle
  /// file in the same folder whose name starts with the video's file name
  /// ("<video name>.<lang>.srt"). Empty for anything that is not a download.
  /// Synchronous on purpose (one small folder) — PlayerManager calls it from
  /// its track sync.
  List<String> subtitlePathsFor(String id) {
    final record = _records[id];
    if (record == null) return const [];

    final out = <String>[];
    final seen = <String>{};
    void add(String p) {
      if (seen.add(p)) out.add(p);
    }

    for (final p in record.subtitlePaths) {
      try {
        if (File(p).existsSync()) add(p);
      } catch (_) {}
    }
    final media = record.mediaPath;
    if (media != null && media.isNotEmpty) {
      for (final f in SidecarSubtitles.findSync(media)) {
        add(f.path);
      }
    }
    return out;
  }

  /// File name without directory and extension ("…/Movie (2).mkv" ->
  /// "Movie (2)"). Subtitle sidecars are named from THIS, not from the
  /// planned base name: when the video had to be renamed because the name was
  /// taken ("Movie (2).mkv"), the subtitle must still start with the video's
  /// real name or no player will pair them.
  String _stemOfPath(String path) => SidecarSubtitles.stemOf(path);

  /// Language tag for a sidecar file name: letters, digits and '-' only.
  String _langTag(String raw) {
    final cleaned = raw.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9-]'), '');
    return (cleaned.isEmpty || cleaned == 'unknown') ? 'und' : cleaned;
  }

  /// True only while [id] is actively transferring — queued/paused/
  /// failed all read as false, same as before this class grew those
  /// states, so any older call site that only ever checked "is this
  /// spinning right now" keeps working unchanged.
  bool isDownloading(String id) => _tasks[id]?.state == DownloadState.downloading;

  /// 0–1 progress for [id] in any non-terminal state, or null if it
  /// isn't tracked at all (not downloaded, and no task). Kept for
  /// existing call sites that only care about a raw fraction; anything
  /// wanting queued/paused/failed detail should use [taskFor] instead.
  double? progressOf(String id) {
    final task = _tasks[id];
    if (task == null) return null;
    return task.progress;
  }

  DownloadState? stateOf(String id) => _tasks[id]?.state;
  DownloadTask? taskFor(String id) => _tasks[id];

  /// 1-based position in the wait line, or null if [id] isn't actually
  /// queued (already running, not tracked, etc).
  int? queuePositionOf(String id) {
    final index = _queue.indexOf(id);
    return index == -1 ? null : index + 1;
  }

  /// Every state change flows through here, so this is also where the
  /// background keep-alive follows the downloads: running while anything is
  /// transferring or waiting, stopped when nothing is.
  @override
  void notifyListeners() {
    super.notifyListeners();
    try {
      _syncTasksPersist();
    } catch (_) {}
    try {
      var active = 0;
      var running = 0;
      var paused = 0;
      var speed = 0.0;
      for (final t in _tasks.values) {
        if (t.state == DownloadState.downloading) {
          active++;
          running++;
          speed += t.speedBps;
        } else if (t.state == DownloadState.queued) {
          active++;
        } else if (t.state == DownloadState.paused) {
          paused++;
        }
      }
      final mb = speed / (1024 * 1024);
      final speedText = speed <= 0
          ? ''
          : (mb >= 1
              ? ' \u2022 ${mb.toStringAsFixed(1)} MB/s'
              : ' \u2022 ${(speed / 1024).toStringAsFixed(0)} KB/s');
      final waiting = active - running;
      final shown = running == 0 ? active : running;
      final text = active == 0
          ? '$paused paused'
          : '$shown ${shown == 1 ? 'download' : 'downloads'}'
              '${waiting > 0 && running > 0 ? ' \u2022 $waiting waiting' : ''}'
              '${paused > 0 ? ' \u2022 $paused paused' : ''}'
              '$speedText';
      DownloadKeepAlive.sync(active: active, paused: paused, text: text);
    } catch (_) {}
  }

  int get _runningCount =>
      _tasks.values.where((t) => t.state == DownloadState.downloading).length;

  List<DownloadTask> get downloadingTasks => _tasks.values
      .where((t) => t.state == DownloadState.downloading)
      .toList()
    ..sort((a, b) => a.addedAt.compareTo(b.addedAt));

  List<DownloadTask> get queuedTasks =>
      _queue.map((id) => _tasks[id]).whereType<DownloadTask>().toList();

  List<DownloadTask> get pausedTasks => _tasks.values
      .where((t) => t.state == DownloadState.paused)
      .toList()
    ..sort((a, b) => a.addedAt.compareTo(b.addedAt));

  List<DownloadTask> get failedTasks => _tasks.values
      .where((t) => t.state == DownloadState.failed)
      .toList()
    ..sort((a, b) => a.addedAt.compareTo(b.addedAt));

  /// Completed [DownloadRecord]s that finished transferring within the
  /// last couple of seconds — see [_recentlyCompleted].
  List<DownloadRecord> get recentlyCompletedRecords => _recentlyCompleted
      .map((id) => _records[id])
      .whereType<DownloadRecord>()
      .toList();

  /// Marks [id] as just-finished for a brief window, then clears it and
  /// notifies again so the "finished" card reverts to being a plain
  /// completed row.
  void _flashCompleted(String id) {
    _recentlyCompleted.add(id);
    notifyListeners();
    Timer(const Duration(seconds: 2), () {
      _recentlyCompleted.remove(id);
      notifyListeners();
    });
  }

  /// Active + queued item count — what the floating summary pill's
  /// "Downloading N items" label reads from.
  int get activeOrQueuedCount => _tasks.values
      .where((t) =>
          t.state == DownloadState.downloading ||
          t.state == DownloadState.queued)
      .length;

  int get activeDownloadedBytes =>
      downloadingTasks.fold(0, (sum, t) => sum + t.downloadedBytes);

  int get activeTotalBytes => downloadingTasks.fold(
        0,
        (sum, t) => sum + (t.totalBytes > 0 ? t.totalBytes : t.downloadedBytes),
      );

  /// Rolls a group of ids (a season's episodes, an album's tracks) up
  /// into one aggregate — what feeds a "6 / 10 downloaded" header,
  /// while every individual row still reads its own state via
  /// [stateOf]/[isDownloaded] as usual.
  DownloadAggregate aggregateFor(Iterable<String> ids) {
    var completed = 0;
    var total = 0;
    var activeOrQueued = 0;
    var hasFailed = false;
    double? activeProgress;

    for (final id in ids) {
      total++;
      if (isDownloaded(id)) {
        completed++;
        continue;
      }
      final task = _tasks[id];
      if (task == null) continue;
      switch (task.state) {
        case DownloadState.downloading:
          activeOrQueued++;
          activeProgress = task.progress;
          break;
        case DownloadState.queued:
        case DownloadState.paused:
          activeOrQueued++;
          break;
        case DownloadState.failed:
          hasFailed = true;
          break;
      }
    }

    return DownloadAggregate(
      completed: completed,
      total: total,
      activeOrQueued: activeOrQueued,
      hasFailed: hasFailed,
      activeProgress: activeProgress,
    );
  }

  List<DownloadRecord> get movies => _records.values
      .where((r) => r.kind == DownloadKind.movie)
      .toList()
    ..sort((a, b) => b.addedAt.compareTo(a.addedAt));

  List<DownloadRecord> get songs => _records.values
      .where((r) => r.kind == DownloadKind.song)
      .toList()
    ..sort((a, b) => b.addedAt.compareTo(a.addedAt));

  List<DownloadRecord> get episodes => _records.values
      .where((r) => r.kind == DownloadKind.episode)
      .toList();

  /// Downloaded episodes grouped by series, each series' episodes sorted
  /// by season/episode number — what the Downloads page's TV Shows tab
  /// and the offline episode list/season selector both read from.
  Map<String, List<DownloadRecord>> get episodesBySeries {
    final map = <String, List<DownloadRecord>>{};
    for (final e in episodes) {
      final key = e.seriesId ?? e.id;
      map.putIfAbsent(key, () => []).add(e);
    }
    for (final list in map.values) {
      list.sort((a, b) => (a.episodeIndex ?? 0).compareTo(b.episodeIndex ?? 0));
    }
    return map;
  }

  List<DownloadRecord> episodesForSeries(String seriesId) {
    final list = episodesBySeries[seriesId] ?? [];
    return list;
  }

  /// True while an episode of [seriesId] is queued or actively
  /// transferring — what the Downloads page's TV Shows row reads to
  /// show its "Downloading in progress" line, ahead of that episode
  /// landing as a completed [DownloadRecord] in [episodesBySeries].
  /// [DownloadTask.imageId] is always the series id for episode-kind
  /// tasks (see `_enqueue`), so this needs no lookup into `item`.
  bool seriesHasActiveDownload(String seriesId) => _tasks.values.any((t) =>
      t.kind == DownloadKind.episode &&
      t.imageId == seriesId &&
      (t.state == DownloadState.downloading ||
          t.state == DownloadState.queued));

  /// Episodes of [seriesId] that are queued, downloading, or paused —
  /// not yet a completed [DownloadRecord], but still worth surfacing
  /// (with a live progress indicator) in that series' offline episode
  /// list. Deliberately excludes failed tasks: those already have
  /// their own visibility and retry action in the Downloads page's
  /// FAILED section, and don't belong in what's meant to be a purely
  /// "what's here or on its way" offline view.
  List<DownloadTask> activeTasksForSeries(String seriesId) {
    return _tasks.values
        .where((t) =>
            t.kind == DownloadKind.episode &&
            t.imageId == seriesId &&
            (t.state == DownloadState.downloading ||
                t.state == DownloadState.queued ||
                t.state == DownloadState.paused))
        .toList()
      ..sort((a, b) => a.addedAt.compareTo(b.addedAt));
  }

  int get totalItemCount => _records.length;

  int get totalBytes =>
      _records.values.fold(0, (sum, r) => sum + r.fileSizeBytes);

  // ────────────────────────────── Downloads ──────────────────────────────

  Future<void> downloadMovie(Map<String, dynamic> item) =>
      _enqueue(item, DownloadKind.movie);

  /// Downloads a movie or episode from an addon [job] (direct link or
  /// torrent), plus its subtitle files. [item] is the Jellyfin-shaped item
  /// the detail screen already shows, so the Downloads screen and the rest of
  /// the app treat it like any other download.
  Future<void> downloadAddon(
    Map<String, dynamic> item,
    DownloadKind kind,
    AddonDownloadJob job,
  ) =>
      _enqueue(item, kind, job: job);

  Future<void> downloadEpisode(Map<String, dynamic> item) =>
      _enqueue(item, DownloadKind.episode);

  /// [targetKbps] null (the default, and what every existing caller
  /// gets) downloads the original file untouched. A value converts the
  /// song to an MP3 at that bitrate on the server first.
  Future<void> downloadSong(Map<String, dynamic> item, {int? targetKbps}) =>
      _enqueue(item, DownloadKind.song, targetKbps: targetKbps);

  /// Registers a new download and either starts it immediately (a
  /// concurrency slot is free) or drops it in the queue behind whatever
  /// else is already running — the single entry point every
  /// downloadMovie/Episode/Song call funnels through.
  Future<void> _enqueue(
    Map<String, dynamic> item,
    DownloadKind kind, {
    int? targetKbps,
    AddonDownloadJob? job,
  }) async {
    final id = item['Id']?.toString();
    if (id == null || id.isEmpty) return;
    if (isDownloaded(id) || _tasks.containsKey(id)) return;

    if (!await ensureStoragePermission()) {
      debugPrint('download($id) aborted: storage permission denied');
      return;
    }

    AnalyticsService.event('download_started', {'kind': kind.name});

    final title = (item['Name'] ?? 'Unknown').toString();
    String subtitle;
    String imageId;

    switch (kind) {
      case DownloadKind.episode:
        subtitle = item['SeriesName']?.toString() ?? '';
        imageId = item['SeriesId']?.toString() ?? id;
        break;
      case DownloadKind.song:
        if (item['AlbumArtist'] != null &&
            item['AlbumArtist'].toString().isNotEmpty) {
          subtitle = item['AlbumArtist'].toString();
        } else if (item['Artists'] is List &&
            (item['Artists'] as List).isNotEmpty) {
          subtitle = (item['Artists'] as List).join(', ');
        } else {
          subtitle = '';
        }
        imageId = id;
        break;
      case DownloadKind.movie:
        subtitle = item['ProductionYear']?.toString() ?? '';
        imageId = id;
        break;
    }

    final task = DownloadTask(
      id: id,
      kind: kind,
      title: title,
      subtitle: subtitle,
      imageId: imageId,
      item: item,
      state: DownloadState.queued,
      addedAt: DateTime.now().millisecondsSinceEpoch,
      targetKbps: kind == DownloadKind.song ? targetKbps : null,
      job: job,
    );
    _tasks[id] = task;

    if (_runningCount < _maxConcurrent) {
      _startTask(id);
    } else {
      _queue.add(id);
      notifyListeners();
      // A whole season queued at once would post one notification per
      // episode; past the first few, the group summary tells the story.
      if (_queue.length <= 4) {
        DownloadNotificationService.instance
            .onQueued(task, queuePositionOf(id));
      }
    }
    unawaited(DownloadNotificationService.instance.updateSummary(this));
  }

  void _startTask(String id) {
    final task = _tasks[id];
    if (task == null) return;

    if (!_mayUseNetwork) {
      _parkForWifi(task);
      return;
    }
    task.waitingForWifi = false;

    task.state = DownloadState.downloading;
    task.error = null;
    task.speedBps = 0;

    final token = CancelToken();
    _tokens[id] = token;
    notifyListeners();
    DownloadNotificationService.instance.onStarted(task);

    // Deliberately not awaited — this is the point a queued task
    // actually starts transferring, and callers (downloadMovie et al.)
    // only care that the task now exists, not that it's finished.
    unawaited(_runTask(task, token));
  }

  Future<void> _runTask(DownloadTask task, CancelToken token) async {
    try {
      switch (task.kind) {
        case DownloadKind.movie:
          task.job != null
              ? await _runAddonTask(task, token, DownloadKind.movie)
              : await _runVideoTask(task, token, DownloadKind.movie);
          break;
        case DownloadKind.episode:
          task.job != null
              ? await _runAddonTask(task, token, DownloadKind.episode)
              : await _runVideoTask(task, token, DownloadKind.episode);
          break;
        case DownloadKind.song:
          await _runSongTask(task, token);
          break;
      }
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) {
        if (task.stalledOut) {
          task.stalledOut = false;
          task.state = DownloadState.failed;
          task.error = task.job?.stream?.isTorrent == true
              ? 'No data arrived. This torrent probably has too few '
                  'seeders. Try another source.'
              : 'No data arrived. The link may have expired. '
                  'Try another source.';
          task.speedBps = 0;
          await DownloadNotificationService.instance.onFailed(task);
        } else if (_pauseRequested.remove(task.id)) {
          task.state = DownloadState.paused;
          task.speedBps = 0;
          DownloadNotificationService.instance.onPaused(task);
          if (_resumeWhenPaused.remove(task.id)) {
            // Scheduled after the cleanup below, once the token is gone.
            scheduleMicrotask(() => resumeDownload(task.id));
          }
        } else {
          _resumeWhenPaused.remove(task.id);
          // A genuine user cancel, not a pause — nothing left to keep.
          _tasks.remove(task.id);
          await _cleanupTaskFiles(task);
          DownloadNotificationService.instance.onCancelled(task.id);
        }
      } else {
        task.state = DownloadState.failed;
        task.error = _friendlyError(e);
        task.speedBps = 0;
        task.retryOnNetwork = e.type == DioExceptionType.connectionError ||
            e.type == DioExceptionType.connectionTimeout ||
            e.type == DioExceptionType.sendTimeout ||
            e.type == DioExceptionType.receiveTimeout;
        await DownloadNotificationService.instance.onFailed(task);
      }
    } catch (e) {
      task.state = DownloadState.failed;
      task.error = e.toString();
      task.speedBps = 0;
      debugPrint('download failed for ${task.id}: $e');
      await DownloadNotificationService.instance.onFailed(task);
    } finally {
      _tokens.remove(task.id);
      if (!_tasks.containsKey(task.id)) {
        // Finished or cancelled: no pause request can still be pending.
        _pauseRequested.remove(task.id);
        _resumeWhenPaused.remove(task.id);
      }
      notifyListeners();
      _advanceQueue();
      unawaited(DownloadNotificationService.instance.updateSummary(this));
    }
  }

  String _friendlyError(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return 'Connection timed out';
      case DioExceptionType.connectionError:
        return 'Connection lost';
      default:
        return 'Download failed';
    }
  }

  void _advanceQueue() {
    while (_runningCount < _maxConcurrent && _queue.isNotEmpty) {
      final id = _queue.removeAt(0);
      final task = _tasks[id];
      if (task == null || task.state != DownloadState.queued) continue;
      _startTask(id);
    }
  }

  /// Pauses an in-progress (or dequeues a not-yet-started) download,
  /// keeping whatever bytes already landed on disk so [resumeDownload]
  /// can pick up where it left off instead of starting over.
  void pauseDownload(String id) {
    final task = _tasks[id];
    if (task == null) return;

    if (task.state == DownloadState.downloading) {
      _resumeWhenPaused.remove(id);
      _pauseRequested.add(id);
      _tokens[id]?.cancel('pause');
    } else if (task.state == DownloadState.queued) {
      _queue.remove(id);
      task.state = DownloadState.paused;
      notifyListeners();
      DownloadNotificationService.instance.onPaused(task);
      unawaited(DownloadNotificationService.instance.updateSummary(this));
    }
  }

  /// Resumes a paused or failed download — starts right away if a
  /// concurrency slot is free, otherwise rejoins the queue.
  void resumeDownload(String id) {
    final task = _tasks[id];
    if (task == null) return;
    if (task.state == DownloadState.downloading &&
        _pauseRequested.contains(id)) {
      // Still stopping: resume as soon as it has stopped.
      _resumeWhenPaused.add(id);
      return;
    }
    if (task.state != DownloadState.paused &&
        task.state != DownloadState.failed) {
      return;
    }

    task.error = null;

    if (_runningCount < _maxConcurrent) {
      _startTask(id);
    } else {
      task.state = DownloadState.queued;
      _queue.add(id);
      notifyListeners();
      DownloadNotificationService.instance.onQueued(task, queuePositionOf(id));
    }
    unawaited(DownloadNotificationService.instance.updateSummary(this));
  }

  /// Same as [resumeDownload] — a distinct name so call sites reading
  /// "Retry" on a failed download don't look like they're resuming a
  /// pause.
  void retryDownload(String id) => resumeDownload(id);

  /// Cancels a download outright: an in-flight transfer is aborted and
  /// its partial file removed; a queued/paused/failed one is just
  /// dropped along with whatever it had already written.
  void cancelDownload(String id) {
    final task = _tasks[id];
    if (task == null) return;

    if (task.state == DownloadState.downloading) {
      // Cancel wins over a pause that is still winding down (otherwise the
      // download would end up paused instead of removed).
      _pauseRequested.remove(id);
      _resumeWhenPaused.remove(id);
      _tokens[id]?.cancel('cancel');
    } else {
      _queue.remove(id);
      _tasks.remove(id);
      unawaited(_cleanupTaskFiles(task));
      notifyListeners();
      _advanceQueue();
      DownloadNotificationService.instance.onCancelled(id);
      unawaited(DownloadNotificationService.instance.updateSummary(this));
    }
  }

  Future<void> _cleanupTaskFiles(DownloadTask task) async {
    try {
      if (task.mediaPath != null) {
        await _deletePartsDir(task.mediaPath!);
        final f = File(task.mediaPath!);
        if (await f.exists()) await f.delete();
      }
    } catch (_) {}
  }

  /// Streams [url] into [filePath], resuming from whatever's already on
  /// disk (via an HTTP `Range` request) when [filePath] already has
  /// bytes in it — a fresh download and a resumed paused/failed one
  /// both funnel through here, the only difference being whether the
  /// file already has a partial body to append to. Updates
  /// [task.downloadedBytes]/[task.totalBytes]/[task.speedBps] live so
  /// every listener sees real progress, not simulated.
  /// Downloads [url] into [filePath]. Uses several connections at once when
  /// the server allows ranged requests (this is what makes it fast: one
  /// connection is usually limited by the server, many are not), and falls
  /// back to a single streamed connection otherwise.
  Future<void> _rangedDownload({
    required String url,
    required String filePath,
    required DownloadTask task,
    required CancelToken token,
    int estimatedTotalBytes = 0,
    Map<String, String>? headers,
    Duration? stallAfter,
  }) async {
    final file = File(filePath);
    final existing = await file.exists() ? await file.length() : 0;
    // A file left by the single-connection path is continued by that same
    // path; a download with saved blocks, or a fresh one, goes by segments.
    final hasParts = await Directory(_partsDirOf(filePath)).exists();
    if (hasParts || existing == 0) {
      final torrent = task.job?.stream?.isTorrent == true;
      final handled = await _segmentedDownload(
        url: url,
        filePath: filePath,
        task: task,
        token: token,
        headers: headers,
        stallAfter: stallAfter,
        connections: torrent ? 4 : 6,
        blockSize: torrent ? 8 * 1024 * 1024 : 4 * 1024 * 1024,
      );
      if (handled) return;
    }
    await _singleDownload(
      url: url,
      filePath: filePath,
      task: task,
      token: token,
      estimatedTotalBytes: estimatedTotalBytes,
      headers: headers,
      stallAfter: stallAfter,
    );
  }

  /// Where the blocks of a segmented download are kept until all of them
  /// have arrived. Each block is its own small file that only ever grows at
  /// its end, so what is on disk is exactly what has been downloaded: after
  /// an app restart or a power-off the download continues from it.
  static String _partsDirOf(String filePath) => '$filePath.parts';

  Future<void> _deletePartsDir(String filePath) async {
    try {
      final d = Directory(_partsDirOf(filePath));
      if (await d.exists()) await d.delete(recursive: true);
    } catch (_) {}
  }

  /// Bytes of an unfinished download that are on disk, and its total size
  /// when known (0 when not).
  Future<(int, int)> _diskProgress(String? mediaPath) async {
    if (mediaPath == null) return (0, 0);
    try {
      final dir = Directory(_partsDirOf(mediaPath));
      if (await dir.exists()) {
        var total = 0;
        final meta = File('${dir.path}/meta');
        if (await meta.exists()) {
          final p = (await meta.readAsString()).trim().split(',');
          if (p.length == 2) total = int.tryParse(p[0]) ?? 0;
        }
        var have = 0;
        await for (final e in dir.list()) {
          if (e is! File) continue;
          final name = e.uri.pathSegments.last;
          if (int.tryParse(name) == null) continue;
          have += await e.length();
        }
        return (have, total);
      }
      final f = File(mediaPath);
      if (await f.exists()) return (await f.length(), 0);
    } catch (_) {}
    return (0, 0);
  }

  /// Returns false (without touching the disk) when the server cannot do
  /// ranged requests, so the caller uses the single-connection path.
  Future<bool> _segmentedDownload({
    required String url,
    required String filePath,
    required DownloadTask task,
    required CancelToken token,
    required int connections,
    required int blockSize,
    Map<String, String>? headers,
    Duration? stallAfter,
  }) async {
    final partsDir = Directory(_partsDirOf(filePath));
    final metaFile = File('${partsDir.path}/meta');

    // A download that was interrupted left its size and block size behind.
    int? savedTotal;
    int? savedBlock;
    try {
      if (await metaFile.exists()) {
        final p = (await metaFile.readAsString()).trim().split(',');
        if (p.length == 2) {
          savedTotal = int.tryParse(p[0]);
          savedBlock = int.tryParse(p[1]);
        }
      }
    } catch (_) {}
    final resuming = savedTotal != null && savedBlock != null && savedBlock > 0;

    // Gives up (as a failure the person can retry) when nothing arrives for
    // [stallAfter]. Started before the probe: a torrent with no seeders never
    // answers it.
    var lastData = DateTime.now();
    Timer? watchdog;
    if (stallAfter != null) {
      watchdog = Timer.periodic(const Duration(seconds: 5), (_) {
        if (DateTime.now().difference(lastData) > stallAfter) {
          task.stalledOut = true;
          token.cancel('stalled');
        }
      });
    }

    DioException cancelled() => DioException(
          requestOptions: RequestOptions(path: url),
          type: DioExceptionType.cancel,
          error: token.cancelError,
        );

    try {
      // Probe: ask for the first byte only. A 206 with a total means ranges
      // work.
      int? probedTotal;
      try {
        final probe = await Dio().get<ResponseBody>(
          url,
          options: Options(
            responseType: ResponseType.stream,
            headers: {if (headers != null) ...headers, 'range': 'bytes=0-0'},
          ),
          cancelToken: token,
        );
        final cr = probe.headers.value('content-range');
        if (probe.statusCode == 206 && cr != null && cr.contains('/')) {
          probedTotal = int.tryParse(cr.split('/').last.trim());
        }
        // Close the connection without reading the body (a server that
        // ignored the range would otherwise send the whole file).
        final sub = probe.data?.stream.listen((_) {});
        await sub?.cancel();
      } on DioException catch (e) {
        if (e.type == DioExceptionType.cancel) rethrow;
        if (resuming) rethrow;
        return false;
      }
      if (probedTotal == null || probedTotal < 8 * 1024 * 1024) {
        if (resuming) throw StateError('The server stopped supporting resume.');
        return false;
      }
      final int total = probedTotal;
      lastData = DateTime.now();

      var block = blockSize;
      if (resuming && savedTotal == total) {
        block = savedBlock!;
      } else if (resuming) {
        // The file behind the link is not the one that was being saved.
        await _deletePartsDir(filePath);
      }
      await partsDir.create(recursive: true);
      await metaFile.writeAsString('$total,$block', flush: true);

      final blocks = (total + block - 1) ~/ block;
      int expected(int b) {
        final start = b * block;
        final end = start + block > total ? total : start + block;
        return end - start;
      }

      // What is on disk is what has been downloaded. The tail of a block
      // that was still growing is dropped on the way in: after a power cut
      // the last bytes written may not have reached the storage.
      const tornTail = 512 * 1024;
      final have = List<int>.filled(blocks, 0);
      var written = 0;
      for (var b = 0; b < blocks; b++) {
        final f = File('${partsDir.path}/$b');
        if (!await f.exists()) continue;
        var len = await f.length();
        final want = expected(b);
        if (len > want) {
          await f.delete();
          len = 0;
        } else if (len < want && len > 0) {
          final keep = len > tornTail ? len - tornTail : 0;
          if (keep == 0) {
            await f.delete();
          } else {
            final raf = await f.open(mode: FileMode.append);
            try {
              await raf.truncate(keep);
            } finally {
              await raf.close();
            }
          }
          len = keep;
        }
        have[b] = len;
        written += len;
      }

      task.totalBytes = total;
      task.downloadedBytes = written;
      notifyListeners();

      final pending = <int>[
        for (var b = 0; b < blocks; b++)
          if (have[b] < expected(b)) b,
      ];

      var lastTick = DateTime.now();
      var lastBytes = written;
      void tick() {
        final now = DateTime.now();
        final ms = now.difference(lastTick).inMilliseconds;
        if (ms < 400) return;
        task.speedBps = (written - lastBytes) * 1000 / ms;
        lastTick = now;
        lastBytes = written;
        notifyListeners();
        DownloadNotificationService.instance.onProgress(task);
      }

      Future<void> fetchBlock(int b) async {
        final blockStart = b * block;
        final blockEnd = blockStart + expected(b) - 1;
        final from = blockStart + have[b];
        if (from > blockEnd) return;

        final res = await Dio().get<ResponseBody>(
          url,
          options: Options(
            responseType: ResponseType.stream,
            headers: {
              if (headers != null) ...headers,
              'range': 'bytes=$from-$blockEnd',
            },
          ),
          cancelToken: token,
        );
        if (res.statusCode != 206) {
          throw StateError('The server did not honour a range request.');
        }
        final body = res.data;
        if (body == null) throw StateError('Empty response body.');
        lastData = DateTime.now();

        final raf = await File('${partsDir.path}/$b').open(mode: FileMode.append);
        try {
          final pieces = <List<int>>[];
          var buffered = 0;

          Future<void> flush() async {
            if (buffered == 0) return;
            final out = Uint8List(buffered);
            var o = 0;
            for (final p in pieces) {
              out.setRange(o, o + p.length, p);
              o += p.length;
            }
            pieces.clear();
            buffered = 0;
            await raf.writeFrom(out);
            have[b] += out.length;
            written += out.length;
            task.downloadedBytes = written;
            lastData = DateTime.now();
            tick();
          }

          await for (final chunk in body.stream) {
            pieces.add(chunk);
            buffered += chunk.length;
            lastData = DateTime.now();
            if (buffered >= 256 * 1024) await flush();
          }
          await flush();
          await raf.flush();
        } finally {
          try {
            await raf.close();
          } catch (_) {}
        }
        if (have[b] < expected(b)) {
          throw StateError('The connection ended early.');
        }
      }

      Object? firstError;
      StackTrace? firstStack;

      Future<void> worker(int index) async {
        while (firstError == null) {
          if (pending.isEmpty) return;
          final b = pending.removeAt(0);
          var attempt = 0;
          while (true) {
            try {
              await fetchBlock(b);
              break;
            } on DioException catch (e) {
              if (e.type == DioExceptionType.cancel) rethrow;
              final code = e.response?.statusCode;
              // The host limits parallel connections: give this one up and
              // let the others carry on instead of failing the download.
              if (index > 0 && (code == 429 || code == 503 || code == 403)) {
                pending.insert(0, b);
                return;
              }
              if (++attempt >= 5) rethrow;
              await Future<void>.delayed(Duration(milliseconds: 400 * attempt));
            } catch (e) {
              if (token.isCancelled) throw cancelled();
              if (++attempt >= 5) rethrow;
              await Future<void>.delayed(Duration(milliseconds: 400 * attempt));
            }
          }
        }
      }

      final n = connections < pending.length ? connections : pending.length;
      await Future.wait([
        for (var i = 0; i < n; i++)
          worker(i).catchError((Object e, StackTrace s) {
            firstError ??= e;
            firstStack ??= s;
          }),
      ]);

      if (firstError != null) {
        final e = firstError;
        if (token.isCancelled &&
            !(e is DioException && e.type == DioExceptionType.cancel)) {
          throw cancelled();
        }
        // The blocks stay on disk, so Resume / Retry continues from here.
        Error.throwWithStackTrace(
            firstError!, firstStack ?? StackTrace.current);
      }
      if (token.isCancelled) throw cancelled();

      for (var b = 0; b < blocks; b++) {
        if (have[b] < expected(b)) {
          throw StateError('The download ended before every part arrived.');
        }
      }

      // Everything is here. Nothing is downloading any more, so the stall
      // watchdog stops, and the join below is not interrupted by a pause (a
      // half-joined file could not be continued).
      watchdog?.cancel();
      task.speedBps = 0;
      task.downloadedBytes = total;
      notifyListeners();

      var spare = false;
      try {
        final freeMb = await DiskSpacePlus().getFreeDiskSpace;
        spare = freeMb != null && freeMb * 1024 * 1024 > total * 1.05 + 300 * 1024 * 1024;
      } catch (_) {}

      final out = await File(filePath).open(mode: FileMode.write);
      try {
        for (var b = 0; b < blocks; b++) {
          final part = File('${partsDir.path}/$b');
          await for (final chunk in part.openRead()) {
            await out.writeFrom(chunk);
          }
          // With little free space each block is removed as soon as it has
          // been joined; otherwise they are kept until the file is whole.
          if (!spare) await part.delete();
        }
        await out.flush();
      } finally {
        try {
          await out.close();
        } catch (_) {}
      }
      if (await File(filePath).length() != total) {
        throw StateError('The saved file has the wrong size.');
      }
      await _deletePartsDir(filePath);

      if (token.isCancelled) {
        if (_pauseRequested.contains(task.id)) {
          // Too late to pause: the file is complete.
          _pauseRequested.remove(task.id);
          _resumeWhenPaused.remove(task.id);
        } else {
          throw cancelled();
        }
      }
      return true;
    } finally {
      watchdog?.cancel();
    }
  }

  /// The original single-connection path: streams one response into the file
  /// and appends to a partial file when resuming.
  Future<void> _singleDownload({
    required String url,
    required String filePath,
    required DownloadTask task,
    required CancelToken token,
    int estimatedTotalBytes = 0,
    Map<String, String>? headers,
    Duration? stallAfter,
  }) async {
    final file = File(filePath);
    var startAt = await file.exists() ? await file.length() : 0;
    task.downloadedBytes = startAt;
    if (startAt == 0) task.totalBytes = 0;

    // Gives up (as a failure the person can retry) when nothing arrives for
    // [stallAfter] — a torrent with no seeders would otherwise sit at 0%
    // forever.
    var lastData = DateTime.now();
    Timer? watchdog;
    if (stallAfter != null) {
      watchdog = Timer.periodic(const Duration(seconds: 5), (_) {
        if (DateTime.now().difference(lastData) > stallAfter) {
          task.stalledOut = true;
          token.cancel('stalled');
        }
      });
    }

    final Response<ResponseBody> response;
    try {
      response = await Dio().get<ResponseBody>(
        url,
        options: Options(
          responseType: ResponseType.stream,
          headers: {
            if (headers != null) ...headers,
            if (startAt > 0) 'range': 'bytes=$startAt-',
          },
        ),
        cancelToken: token,
      );
    } catch (_) {
      watchdog?.cancel();
      rethrow;
    }

    final body = response.data;
    if (body == null) {
      watchdog?.cancel();
      throw StateError('empty response body for $url');
    }
    lastData = DateTime.now();

    final contentRange = response.headers.value('content-range');
    if (startAt > 0 && contentRange != null && contentRange.contains('/')) {
      // "bytes 1234-5678/9999" — the part after "/" is the true total.
      task.totalBytes =
          int.tryParse(contentRange.split('/').last) ?? task.totalBytes;
    } else {
      // Either a fresh download, or the server ignored our Range
      // request and is sending the whole file again from byte 0 (some
      // servers don't support partial content) — in the latter case,
      // restart the local file from scratch rather than corrupt it by
      // appending a second full copy onto the partial one.
      if (startAt > 0) {
        startAt = 0;
        task.downloadedBytes = 0;
      }
      final len = body.contentLength;
      task.totalBytes = len >= 0 ? len : estimatedTotalBytes;
    }

    // True only when the server gave no length and the total shown is
    // our own estimate (a transcode) — see below.
    final totalIsEstimate = task.totalBytes > 0 &&
        task.totalBytes == estimatedTotalBytes &&
        body.contentLength < 0;

    final raf = await file.open(
      mode: startAt > 0 ? FileMode.append : FileMode.write,
    );

    var received = startAt;
    var lastTick = DateTime.now();
    var lastBytes = received;
    final completer = Completer<void>();
    late StreamSubscription<List<int>> sub;

    sub = body.stream.listen(
      (chunk) {
        sub.pause();
        raf.writeFrom(chunk).then((_) {
          lastData = DateTime.now();
          received += chunk.length;
          task.downloadedBytes = received;

          // An estimate can come in low; never show more downloaded
          // than "total" (the bar just waits at full for the last bit).
          if (totalIsEstimate && received > task.totalBytes) {
            task.totalBytes = received;
          }

          final now = DateTime.now();
          final elapsedMs = now.difference(lastTick).inMilliseconds;
          if (elapsedMs >= 400) {
            task.speedBps = (received - lastBytes) * 1000 / elapsedMs;
            lastTick = now;
            lastBytes = received;
            notifyListeners();
            DownloadNotificationService.instance.onProgress(task);
          }
          sub.resume();
        }).catchError((Object e) {
          sub.cancel();
          if (!completer.isCompleted) completer.completeError(e);
        });
      },
      onDone: () {
        if (!completer.isCompleted) completer.complete();
      },
      onError: (Object e, StackTrace st) {
        if (!completer.isCompleted) completer.completeError(e);
      },
      cancelOnError: true,
    );

    try {
      await completer.future;
    } finally {
      watchdog?.cancel();
      try {
        await raf.close();
      } catch (_) {}
    }

    task.speedBps = 0;
  }

  Future<void> _runVideoTask(
    DownloadTask task,
    CancelToken token,
    DownloadKind kind,
  ) async {
    var item = task.item;
    final id = task.id;

    if (task.mediaPath == null) {
      final container = (item['MediaSources'] is List &&
              (item['MediaSources'] as List).isNotEmpty)
          ? (item['MediaSources'][0]['Container'] ?? 'mp4').toString()
          : 'mp4';

      final title = task.title;
      Directory dir;
      String baseName;

      if (kind == DownloadKind.episode) {
        final seriesName = (item['SeriesName']?.toString().trim().isNotEmpty ??
                false)
            ? item['SeriesName'].toString()
            : title;

        final season = item['ParentIndexNumber'];
        final episodeNum = item['IndexNumber'];
        final code = (season is int && episodeNum is int)
            ? 'S${season.toString().padLeft(2, '0')}'
                'E${episodeNum.toString().padLeft(2, '0')} - '
            : '';
        baseName = _sanitize('$code$title');

        // Each episode gets its own folder, nested inside the series
        // folder, holding just that episode's video file plus its
        // subtitle sidecars — rather than every episode of a series
        // landing flat in one shared folder — so the episode (and its
        // subs) can be moved, shared, or dropped into another player
        // as a single self-contained unit.
        final showDir = await _showDir(seriesName);
        dir = Directory('${showDir.path}/$baseName');
        if (!await dir.exists()) {
          await dir.create(recursive: true);
        }
      } else {
        final year = item['ProductionYear'];
        final folderName = year != null ? '$title ($year)' : title;
        dir = await _movieDir(folderName);
        baseName = _sanitize(folderName);
      }

      final mediaFile = await _uniqueFile(dir, baseName, container);
      task.mediaPath = mediaFile.path;
      task.mediaDir = dir.path;
      task.baseName = baseName;
    }

    await _rangedDownload(
      url: MediaService.getPlaybackUrl(id),
      filePath: task.mediaPath!,
      task: task,
      token: token,
    );

    final size = await File(task.mediaPath!).length();
    final dir = Directory(task.mediaDir!);
    final baseName = task.baseName!;

    // For episodes, art almost never lives on the episode itself —
    // same reasoning as mediaItemFromJellyfin's backdrop/logo
    // fallback — so download the series' poster instead when we
    // have a SeriesId, falling back to the episode's own image.
    final imageSourceId = (kind == DownloadKind.episode &&
            item['SeriesId'] != null)
        ? item['SeriesId'].toString()
        : id;
    final posterPath = await _downloadImage(id, imageId: imageSourceId);
    // Landscape art for the Downloads screen's row layout (mirrors the
    // Continue Watching card). Best-effort — falls back to
    // [posterPath] at render time when the server has no Thumb image
    // for this item.
    // Same Thumb -> Backdrop fallback Jellyfin's own clients use, so a
    // downloaded row for an item with no dedicated Thumb still gets
    // landscape art instead of a tightly-cropped portrait poster.
    final thumbPath = await _downloadImage(
          id,
          imageId: imageSourceId,
          type: "Thumb",
        ) ??
        await _downloadImage(
          id,
          imageId: imageSourceId,
          type: "Backdrop",
        );

    // The episode's own Primary image — the actual frame grab shown
    // on the TV show detail screen's episode cards (see
    // MediaService.getEpisodeThumbUrl, which is the same Primary
    // type/itemId combination). Jellyfin does populate this per
    // episode in practice, despite the reasoning above for why
    // posterPath/thumbPath fall back to the series' art instead —
    // so a downloaded episode row can still show its real frame
    // rather than always reusing the shared series art. Best-effort:
    // null (falling back to the series art at render time) whenever
    // the server has no Primary image for this specific episode.
    final episodeThumbPath = kind == DownloadKind.episode
        ? await _downloadImage(id, imageId: id)
        : null;

    // BUG FIX (episodes downloaded with no subtitle sidecars):
    // MediaStreamParser.subtitles below reads item['MediaStreams'],
    // but the episode-row item this task was started from comes
    // straight from MediaService.getEpisodes, which deliberately
    // omits MediaStreams/MediaSources to keep season lists fast (see
    // that method's own comment) — so every episode download saw an
    // empty stream list and silently produced zero subtitle files,
    // while movies (started from the full MediaService.getItem
    // fetch) happened to hit the same gap until getItem's Fields list
    // was fixed alongside this. Re-fetching full details once, right
    // before subtitle extraction, keeps the season-list endpoint
    // untouched (still fast) and is harmless for movies (a no-op
    // fetch that's simply skipped since they already carry MediaStreams).
    if (item['MediaStreams'] is! List ||
        (item['MediaStreams'] as List).isEmpty) {
      try {
        final full = await MediaService.getItem(id);
        item = {
          ...item,
          if (full['MediaStreams'] != null)
            'MediaStreams': full['MediaStreams'],
          if (full['MediaSources'] != null)
            'MediaSources': full['MediaSources'],
        };
      } catch (e) {
        debugPrint('subtitle metadata refetch failed for $id: $e');
      }
    }

    // Subtitle sidecars — best-effort, saved with the same base name
    // as the video file (Jellyfin/Kodi/Plex convention: "<video
    // name>.<lang>.vtt") so mpv's own same-folder subtitle
    // auto-detection can find and offer them without this app having
    // to do anything else at playback time.
    final subtitlePaths = <String>[];
    try {
      final mediaSourceId = (item['MediaSources'] is List &&
              (item['MediaSources'] as List).isNotEmpty)
          ? (item['MediaSources'][0]['Id']?.toString() ?? id)
          : id;

      final tracks = MediaStreamParser.subtitles(
        item['MediaStreams'] is List
            ? List<dynamic>.from(item['MediaStreams'])
            : null,
        itemId: id,
        mediaSourceId: mediaSourceId,
      );

      final usedLangs = <String>{};
      for (final track in tracks) {
        final url = track.externalUrl;
        if (url == null) continue;

        final lang = _langTag(track.language);
        var langKey = lang;
        var suffix = 2;
        while (usedLangs.contains(langKey)) {
          langKey = '$lang-$suffix';
          suffix++;
        }
        usedLangs.add(langKey);

        try {
          final response = await Dio().get<String>(
            url,
            options: Options(responseType: ResponseType.plain),
          );
          final text = response.data ?? '';
          if (text.trim().isEmpty) continue;
          // Named after the video file's real name (see _stemOfPath), kept
          // as a separate file next to it — never muxed into the video.
          final subFile = await _uniqueFile(
              dir, '${_stemOfPath(task.mediaPath!)}.$langKey', 'vtt');
          await subFile.writeAsString(text);
          subtitlePaths.add(subFile.path);
        } catch (e) {
          debugPrint('subtitle download failed for $id ($lang): $e');
        }
      }
    } catch (e) {
      debugPrint('subtitle track parsing failed for $id: $e');
    }

    _records[id] = DownloadRecord(
      id: id,
      kind: kind,
      title: task.title,
      subtitle: kind == DownloadKind.episode
          ? (item['SeriesName']?.toString() ?? '')
          : (item['ProductionYear']?.toString() ?? ''),
      seriesId: item['SeriesId']?.toString(),
      seriesName: item['SeriesName']?.toString(),
      seasonId: item['SeasonId']?.toString(),
      seasonName: item['SeasonName']?.toString(),
      episodeIndex: item['IndexNumber'],
      mediaPath: task.mediaPath,
      posterPath: posterPath,
      thumbPath: thumbPath,
      episodeThumbPath: episodeThumbPath,
      subtitlePaths: subtitlePaths,
      runtimeTicks: (item['RunTimeTicks'] as num?)?.toInt() ?? 0,
      fileSizeBytes: size,
      addedAt: DateTime.now().millisecondsSinceEpoch,
      raw: item,
    );

    await _persist();
    _tasks.remove(id);
    _flashCompleted(id);
    await DownloadNotificationService.instance.onCompleted(
      id: id,
      kind: kind,
      title: task.title,
      subtitle: _records[id]!.subtitle,
      posterPath: posterPath,
    );
  }

  // ───────────────────────── Addon (direct / torrent) ─────────────────────────

  /// Container extension for the file about to be written.
  String _containerFor(AddonStream original, AddonStream resolved) {
    final re = RegExp(r'\.(mkv|mp4|m4v|avi|mov|webm|ts|wmv|flv)$',
        caseSensitive: false);
    for (final candidate in [
      original.fileName,
      Uri.tryParse(resolved.url)?.path,
      Uri.tryParse(original.url)?.path,
    ]) {
      final m = re.firstMatch((candidate ?? '').trim());
      if (m != null) return m.group(1)!.toLowerCase();
    }
    return original.isTorrent ? 'mkv' : 'mp4';
  }

  Future<void> _runAddonTask(
    DownloadTask task,
    CancelToken token,
    DownloadKind kind,
  ) async {
    final job = task.job!;
    final item = task.item;
    final id = task.id;

    // An episode queued by "Download all" has no source yet: the best one
    // at the chosen quality is looked up now that its turn has come.
    if (job.stream == null) {
      await _resolveJobSource(job, token, job.wantHeight ?? 0);
    }
    var stream = job.stream!;

    // A torrent first becomes a local http address: the engine finds peers
    // and reads the file list. Done on every (re)start, so a paused torrent
    // picks up where it stopped.
    var source = stream;
    if (source.isTorrent) {
      await TorrentEngine.instance.tuneForDownload();
      source = await TorrentEngine.instance
          .resolve(source, episode: job.episode);
      if (token.isCancelled) {
        throw DioException(
          requestOptions: RequestOptions(path: ''),
          type: DioExceptionType.cancel,
        );
      }
    }

    if (task.mediaPath == null) {
      final ext = _containerFor(stream, source);
      final title = task.title;
      Directory dir;
      String baseName;

      if (kind == DownloadKind.episode) {
        final seriesName = (item['SeriesName']?.toString().trim().isNotEmpty ??
                false)
            ? item['SeriesName'].toString()
            : title;
        final season = item['ParentIndexNumber'];
        final episodeNum = item['IndexNumber'];
        final code = (season is int && episodeNum is int)
            ? 'S${season.toString().padLeft(2, '0')}'
                'E${episodeNum.toString().padLeft(2, '0')} - '
            : '';
        baseName = _sanitize('$code$title');
        final showDir = await _showDir(seriesName);
        dir = Directory('${showDir.path}/$baseName');
        if (!await dir.exists()) await dir.create(recursive: true);
      } else {
        final year = item['ProductionYear'];
        final folderName = year != null ? '$title ($year)' : title;
        dir = await _movieDir(folderName);
        baseName = _sanitize(folderName);
      }

      final mediaFile = await _uniqueFile(dir, baseName, ext);
      task.mediaPath = mediaFile.path;
      task.mediaDir = dir.path;
      task.baseName = baseName;
    }

    Future<void> transfer() => _rangedDownload(
          url: source.url,
          filePath: task.mediaPath!,
          task: task,
          token: token,
          estimatedTotalBytes: job.info.sizeBytes ?? 0,
          headers: stream.headers.isEmpty ? null : stream.headers,
          stallAfter: Duration(seconds: stream.isTorrent ? 150 : 60),
        );

    try {
      await transfer();
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      final expired = e.type == DioExceptionType.badResponse &&
          (code == 401 || code == 403 || code == 404 || code == 410);
      if (!expired || stream.isTorrent || job.refreshed) rethrow;
      // A direct link that has expired (a paused download resumed hours or
      // days later): ask the addons for a fresh one of the same quality and
      // continue. Blocks already saved are kept when it is the same file.
      job.refreshed = true;
      final heightBefore = stream.height;
      job.stream = null;
      await _resolveJobSource(job, token, heightBefore, fresh: true);
      stream = job.stream!;
      source = stream;
      if (source.isTorrent) {
        await TorrentEngine.instance.tuneForDownload();
        source = await TorrentEngine.instance
            .resolve(source, episode: job.episode);
      }
      await transfer();
    }

    final size = await File(task.mediaPath!).length();
    // A link that answers with a page or an error instead of the video ends
    // up as a few kilobytes.
    if (size < 2 * 1024 * 1024) {
      try {
        await File(task.mediaPath!).delete();
      } catch (_) {}
      task.mediaPath = null;
      throw const _DownloadException(
          'The source did not return a video file. Try another source.');
    }

    final dir = Directory(task.mediaDir!);
    final baseName = task.baseName!;

    // The cached copy inside the torrent engine is no longer needed.
    if (stream.isTorrent && stream.infoHash != null) {
      unawaited(TorrentEngine.instance.remove(stream.infoHash!));
    }

    final imageSourceId =
        (kind == DownloadKind.episode && item['SeriesId'] != null)
            ? item['SeriesId'].toString()
            : id;
    final posterPath = await _downloadImage(id, imageId: imageSourceId);
    final thumbPath = await _downloadImage(
          id,
          imageId: imageSourceId,
          type: 'Thumb',
        ) ??
        await _downloadImage(
          id,
          imageId: imageSourceId,
          type: 'Backdrop',
        );
    final episodeThumbPath =
        kind == DownloadKind.episode ? await _downloadImage(id, imageId: id) : null;

    final subtitlePaths =
        await _downloadAddonSubtitles(job, dir, _stemOfPath(task.mediaPath!));

    // Same shape as an addon item built for streaming, so everything that
    // knows how to play those (skip segments, next episode, trickplay)
    // works on the downloaded copy too.
    final raw = <String, dynamic>{...item}
      ..remove('NamesisVirtual')
      ..addAll({
        'AddonStream': true,
        'IsLocal': true,
        'IsExternalFile': true,
        'TmdbId': job.title.tmdbId,
        'NamesisTitle': TitleSnapshot.of(job.title).toJson(),
        if (job.episode != null) 'NamesisEpisode': episodeToRaw(job.episode!),
        'Type': job.episode != null ? 'Episode' : 'Movie',
      });

    final ticks = (item['RunTimeTicks'] as num?)?.toInt() ??
        ((job.info.duration?.inMicroseconds ?? 0) * 10);

    _records[id] = DownloadRecord(
      id: id,
      kind: kind,
      title: task.title,
      subtitle: kind == DownloadKind.episode
          ? (item['SeriesName']?.toString() ?? '')
          : (item['ProductionYear']?.toString() ?? ''),
      seriesId: item['SeriesId']?.toString(),
      seriesName: item['SeriesName']?.toString(),
      seasonId: item['SeasonId']?.toString(),
      seasonName: item['SeasonName']?.toString(),
      episodeIndex: item['IndexNumber'],
      mediaPath: task.mediaPath,
      posterPath: posterPath,
      thumbPath: thumbPath,
      episodeThumbPath: episodeThumbPath,
      subtitlePaths: subtitlePaths,
      runtimeTicks: ticks,
      fileSizeBytes: size,
      addedAt: DateTime.now().millisecondsSinceEpoch,
      raw: raw,
    );

    await _persist();
    _tasks.remove(id);
    _flashCompleted(id);
    await DownloadNotificationService.instance.onCompleted(
      id: id,
      kind: kind,
      title: task.title,
      subtitle: _records[id]!.subtitle,
      posterPath: posterPath,
    );
  }

  /// Looks up the sources for [job]'s title or episode and chooses the best
  /// one at [height] (see [pickStreamForHeight]).
  ///
  /// [fresh] asks the addons again instead of reusing an answer from the last
  /// few minutes (used when a link has expired).
  Future<void> _resolveJobSource(
    AddonDownloadJob job,
    CancelToken token,
    int height, {
    bool fresh = false,
  }) async {
    DioException cancelled() => DioException(
          requestOptions: RequestOptions(path: ''),
          type: DioExceptionType.cancel,
        );

    if (!AddonManager.instance.hasStreamAddons) {
      throw _DownloadException(AddonManager.instance.noAddonsMessage);
    }
    final ep = job.episode;
    final id = ep != null
        ? job.title.addonId(season: ep.season, episode: ep.number)
        : job.title.addonId();

    var streams = const <AddonStream>[];
    for (var attempt = 0; attempt < 2 && streams.isEmpty; attempt++) {
      if (token.isCancelled) throw cancelled();
      try {
        // After the time limit, whatever has arrived is used: links from the
        // quick addons are not thrown away because a slow one is still busy.
        streams = await AddonManager.instance.streamsFor(
          job.title.type.addon,
          id,
          timeout: const Duration(seconds: 60),
          fresh: fresh,
        );
      } catch (e) {
        debugPrint('source lookup failed for $id: $e');
      }
    }
    if (token.isCancelled) throw cancelled();

    // Same never-select rules and ranking as auto link selection.
    final picked = pickStreamForHeight(
      streams,
      height,
      ctx: LinkContext(
        originalLanguage: job.title.originalLanguage,
        titleName: job.title.title,
      ),
      preferTorrent: job.wantTorrent,
    );
    if (picked == null) {
      throw const _DownloadException(
          'No downloadable source was found for this episode.');
    }
    job.stream = picked;
    job.info = StreamInfo.of(picked);
  }

  /// Saves the subtitle files the addons offer for this title next to the
  /// video, named "<video name>.<language>.<ext>" so the player finds them by
  /// itself. English first, at most two per language and eight in all.
  Future<List<String>> _downloadAddonSubtitles(
    AddonDownloadJob job,
    Directory dir,
    String baseName,
  ) async {
    final saved = <String>[];
    try {
      final id = job.episode != null
          ? job.title.addonId(
              season: job.episode!.season, episode: job.episode!.number)
          : job.title.addonId();

      // Two attempts: a single slow/failed lookup used to mean a download
      // with no subtitle files at all.
      var fromAddons = <AddonSubtitle>[];
      for (var attempt = 0; attempt < 2 && fromAddons.isEmpty; attempt++) {
        try {
          fromAddons = await AddonManager.instance
              .subtitlesFor(job.title.type.addon, id)
              .timeout(const Duration(seconds: 20));
        } catch (e) {
          debugPrint('subtitle lookup failed (attempt ${attempt + 1}): $e');
        }
        if (fromAddons.isEmpty && (job.stream?.subtitles.isNotEmpty ?? false)) {
          break;
        }
      }

      final all = <AddonSubtitle>[...?job.stream?.subtitles, ...fromAddons];
      bool english(AddonSubtitle s) =>
          s.lang.toLowerCase().startsWith('en');
      all.sort((a, b) => (english(b) ? 1 : 0).compareTo(english(a) ? 1 : 0));

      final seenUrls = <String>{};
      final perLang = <String, int>{};
      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 15),
        responseType: ResponseType.bytes,
        validateStatus: (s) => s != null && s >= 200 && s < 300,
      ));

      for (final s in all) {
        if (saved.length >= 8) break;
        if (!seenUrls.add(s.url)) continue;

        final lang = _langTag(s.lang);
        final count = perLang[lang] ?? 0;
        if (count >= 2) continue;

        try {
          final res = await dio.get<List<int>>(s.url);
          final bytes = res.data;
          if (bytes == null || bytes.isEmpty || bytes.length > 5 * 1024 * 1024) {
            continue;
          }
          // An error page instead of a subtitle file.
          final head = String.fromCharCodes(
              bytes.take(64).where((b) => b < 128)).toLowerCase();
          if (head.contains('<!doctype') || head.contains('<html')) continue;
          // Something that is not subtitle text at all (an archive, say):
          // not worth a file the player could never show.
          if (SubtitleText.toSrt(SubtitleText.decode(bytes)).trim().isEmpty) {
            continue;
          }

          final path = (Uri.tryParse(s.url)?.path ?? '').toLowerCase();
          var ext = 'srt';
          for (final e in const ['vtt', 'ass', 'ssa', 'sub', 'srt']) {
            if (path.endsWith('.$e')) {
              ext = e;
              break;
            }
          }

          final langKey = count == 0 ? lang : '$lang-${count + 1}';
          final file = await _uniqueFile(dir, '$baseName.$langKey', ext);
          await file.writeAsBytes(bytes);
          saved.add(file.path);
          perLang[lang] = count + 1;
        } catch (e) {
          debugPrint('subtitle download failed (${s.lang}): $e');
        }
      }
    } catch (e) {
      debugPrint('addon subtitles failed: $e');
    }
    return saved;
  }

  // Single source of truth for a song's display artist — AlbumArtist
  // first (matches what the Music screen shows under the title), falling
  // back to the Artists list. Shared between the pre-download filename
  // (baseName above) and the post-download DownloadRecord so a file's
  // name on disk and its metadata inside the app never disagree.
  String _songArtist(Map<String, dynamic> item) {
    if (item['AlbumArtist'] != null &&
        item['AlbumArtist'].toString().isNotEmpty) {
      return item['AlbumArtist'].toString();
    }
    if (item['Artists'] is List && (item['Artists'] as List).isNotEmpty) {
      return (item['Artists'] as List).join(', ');
    }
    return '';
  }

  Future<void> _runSongTask(DownloadTask task, CancelToken token) async {
    final item = task.item;
    final id = task.id;

    if (task.mediaPath == null) {
      final title = task.title;
      final albumName = (item['Album']?.toString().trim().isNotEmpty ?? false)
          ? item['Album'].toString()
          : 'Unknown Album';
      final dir = await _albumDir(albumName);

      // Mirrors _runVideoTask's container lookup below: `static=true`
      // on the download URL already means the server hands back the
      // original file byte-for-byte, untranscoded — but nothing here
      // was reading what that original container actually was, so
      // every song got hardcoded to a `.mp3` name regardless. A FLAC
      // source downloaded that way is genuinely still FLAC bytes on
      // disk, just mislabeled — which is what made downloads look like
      // they'd been transcoded when they hadn't been.
      // A song converted to a chosen bitrate is always an MP3, whatever
      // the source was.
      //
      // The Music tab's Songs / Most Played lists no longer carry
      // MediaSources (that made their 5000-row request very slow), so a
      // song started straight from one of them — e.g. a bulk download from
      // multi-select — has none. Without it every file would be mislabeled
      // `.mp3`, so look the container up once here when it's missing.
      Object? sources = item['MediaSources'];
      if (task.targetKbps == null &&
          (sources is! List || sources.isEmpty)) {
        try {
          final fetched = await MediaService.getItems(
            ids: id,
            limit: 1,
            fields: 'MediaSources',
          );
          if (fetched.isNotEmpty && fetched.first is Map) {
            sources = (fetched.first as Map)['MediaSources'];
          }
        } catch (e) {
          debugPrint('song container lookup failed for $id: $e');
        }
      }
      final container = task.targetKbps != null
          ? 'mp3'
          : (sources is List &&
                  sources.isNotEmpty &&
                  sources.first is Map)
              ? ((sources.first as Map)['Container'] ?? 'mp3').toString()
              : 'mp3';

      // "{Title} - {Artist}" — what shows up in a plain file manager
      // matches what the app itself shows, rather than a bare track
      // number the person has no way to map back to a song without
      // opening the app. Computed the same way the post-download
      // metadata block below derives `artist`, just earlier, since the
      // filename needs it too now.
      final artist = _songArtist(item);
      final baseName = artist.isNotEmpty
          ? _sanitize('$title - $artist')
          : _sanitize(title);

      final mediaFile = await _uniqueFile(dir, baseName, container);
      task.mediaPath = mediaFile.path;
      task.mediaDir = dir.path;
      task.baseName = baseName;
    }

    final targetKbps = task.targetKbps;

    // A converted song has no Content-Length (the server encodes it as it
    // sends), so estimate its size from bitrate x duration purely so the
    // progress bar has something to measure against.
    final runtimeSeconds =
        ((item['RunTimeTicks'] as num?)?.toDouble() ?? 0) / 10000000;
    task.estimatedBytes = (targetKbps != null && runtimeSeconds > 0)
        ? (targetKbps * 1000 / 8 * runtimeSeconds).round()
        : 0;

    await _rangedDownload(
      url: targetKbps != null
          ? MediaService.getAudioDownloadTranscodeUrl(id, targetKbps)
          : MediaService.getAudioDownloadUrl(id),
      filePath: task.mediaPath!,
      task: task,
      token: token,
      estimatedTotalBytes: task.estimatedBytes,
    );

    var size = await File(task.mediaPath!).length();

    // A transcode has no length to check the finished file against, so a
    // server that stops converting partway would otherwise leave a
    // truncated MP3 that looks like a normal download. An MP3 at a fixed
    // bitrate lands close to bitrate x duration (encoders drift a little
    // either way), so anything well under that was cut short. (The original-file path doesn't need
    // this: a plain download has a real Content-Length.)
    if (targetKbps != null &&
        task.estimatedBytes > 0 &&
        size < task.estimatedBytes * 0.7) {
      try {
        await File(task.mediaPath!).delete();
      } catch (_) {}
      throw _DownloadException(
        'The server stopped converting this song early. Please try again.',
      );
    }

    final artist = _songArtist(item);

    // Songs without their own Primary image (common — the cover usually
    // lives on the album) fall back to the album's cover, same as the
    // rest of the app shows them.
    var posterPath = await _downloadImage(id);
    final albumId = item['AlbumId']?.toString();
    if (posterPath == null && albumId != null && albumId.isNotEmpty) {
      posterPath = await _downloadImage(id, imageId: albumId);
    }

    // ARTWORK FIX: a song converted to a chosen bitrate is encoded by
    // the server on the fly and arrives with no embedded picture, so it
    // showed no cover anywhere outside this app (file manager, media
    // library, other players). Write the cover we just cached into the
    // MP3's ID3 tag — for every bitrate. A file that already carries
    // its own artwork (the untouched original MP3) is left as-is, and
    // non-MP3 originals (FLAC/M4A/...) are never modified.
    // Best-effort: a failure here must never fail the download.
    if (posterPath != null && task.mediaPath!.toLowerCase().endsWith('.mp3')) {
      try {
        final ok = await Id3ArtworkEmbedder.embed(
          mp3Path: task.mediaPath!,
          imagePath: posterPath,
        );
        if (ok) size = await File(task.mediaPath!).length();
      } catch (e) {
        debugPrint('artwork embed failed for $id: $e');
      }
    }

    // Lyrics sidecar — best-effort. Jellyfin having none for this
    // track is the common case, not a failure.
    String? lyricsPath;
    try {
      final lyrics = await MediaService.getLyrics(id);
      if (lyrics != null && lyrics.isNotEmpty) {
        final lrc = _buildLrc(lyrics);
        if (lrc.isNotEmpty) {
          final dir = Directory(task.mediaDir!);
          final lyricsFile = await _uniqueFile(dir, task.baseName!, 'lrc');
          await lyricsFile.writeAsString(lrc);
          lyricsPath = lyricsFile.path;
        }
      }
    } catch (e) {
      debugPrint('lyrics download failed for $id: $e');
    }

    _records[id] = DownloadRecord(
      id: id,
      kind: DownloadKind.song,
      title: task.title,
      subtitle: artist,
      albumId: item['AlbumId']?.toString(),
      albumName: item['Album']?.toString(),
      artistName: artist,
      mediaPath: task.mediaPath,
      posterPath: posterPath,
      lyricsPath: lyricsPath,
      runtimeTicks: (item['RunTimeTicks'] as num?)?.toInt() ?? 0,
      fileSizeBytes: size,
      addedAt: DateTime.now().millisecondsSinceEpoch,
      downloadKbps: targetKbps,
      raw: item,
    );

    await _persist();
    _tasks.remove(id);
    _flashCompleted(id);
    await DownloadNotificationService.instance.onCompleted(
      id: id,
      kind: DownloadKind.song,
      title: task.title,
      subtitle: artist,
      posterPath: posterPath,
    );
  }

  /// Converts Jellyfin's `/Audio/{id}/Lyrics` line list (`Text` +
  /// optional `Start` in 100-nanosecond ticks) into standard LRC text —
  /// a plain, widely-supported sidecar format any media app (including
  /// this one, offline) can read back without needing Jellyfin's own
  /// JSON shape.
  String _buildLrc(List<dynamic> lines) {
    final buffer = StringBuffer();
    for (final entry in lines) {
      final map = Map<String, dynamic>.from(entry as Map);
      final text = (map['Text'] ?? '').toString();
      final startTicks = map['Start'];

      if (startTicks != null) {
        final totalMs = (startTicks as num).toInt() ~/ 10000;
        final minutes = totalMs ~/ 60000;
        final seconds = (totalMs % 60000) ~/ 1000;
        final centis = (totalMs % 1000) ~/ 10;
        buffer.writeln(
          '[${minutes.toString().padLeft(2, '0')}:'
          '${seconds.toString().padLeft(2, '0')}.'
          '${centis.toString().padLeft(2, '0')}]$text',
        );
      } else {
        buffer.writeln(text);
      }
    }
    return buffer.toString().trim();
  }

  /// Poster art cache — deliberately kept in app-private storage (not
  /// the public Nemesis folder) since it's a UI convenience, not
  /// something the person asked to download; multiple episodes of the
  /// same series, or re-downloading after a delete, reuse whatever's
  /// already cached here instead of re-fetching.
  Future<String?> _downloadImage(
    String id, {
    String? imageId,
    String type = "Primary",
  }) async {
    try {
      final dir = await _privateRoot;
      // "Primary" keeps the existing `art_<id>.jpg` naming so already-
      // downloaded posters aren't orphaned by this; any other type
      // ("Thumb"/"Backdrop") gets its own prefix so the two never
      // collide on disk.
      final prefix = type == "Primary" ? "art" : type.toLowerCase();
      final path = '${dir.path}/${prefix}_${imageId ?? id}.jpg';
      final file = File(path);
      if (await file.exists()) return path;

      final url = type == "Primary"
          ? MediaService.getPrimaryImage(imageId ?? id, size: 600)
          : MediaService.getImageUrl(imageId ?? id, type: type, maxWidth: 600);

      await Dio().download(url, path);
      return path;
    } catch (e) {
      // Expected/non-fatal for "Thumb" — plenty of library items never
      // had a landscape image set on the server, so a 404 here just
      // means the row layout falls back to the poster at render time.
      debugPrint('$type image download failed for $id: $e');
      return null;
    }
  }

  Future<void> deleteDownload(String id) async {
    final record = _records[id];
    if (record == null) return;

    Directory? parentDir;

    try {
      if (record.mediaPath != null) {
        final f = File(record.mediaPath!);
        parentDir = f.parent;
        if (await f.exists()) await f.delete();
      }

      for (final path in record.subtitlePaths) {
        final f = File(path);
        if (await f.exists()) await f.delete();
      }

      // Subtitle files found next to the video by name (added later, or never
      // listed in the record) go with it, so no orphan is left in the folder.
      if (record.mediaPath != null) {
        for (final f in await SidecarSubtitles.find(record.mediaPath!)) {
          if (await f.exists()) await f.delete();
        }
      }

      if (record.lyricsPath != null) {
        final f = File(record.lyricsPath!);
        if (await f.exists()) await f.delete();
      }

      // Note: poster files are intentionally left alone if shared by a
      // series' other downloaded episodes (checked via still-referenced
      // path below).
      final posterStillUsed = _records.values.any(
        (r) => r.id != id && r.posterPath == record.posterPath,
      );
      if (!posterStillUsed && record.posterPath != null) {
        final p = File(record.posterPath!);
        if (await p.exists()) await p.delete();
      }

      final thumbStillUsed = _records.values.any(
        (r) => r.id != id && r.thumbPath == record.thumbPath,
      );
      if (!thumbStillUsed && record.thumbPath != null) {
        final t = File(record.thumbPath!);
        if (await t.exists()) await t.delete();
      }

      // episodeThumbPath is keyed by this episode's own id (never
      // shared with another record the way posterPath/thumbPath can
      // be), so it's always safe to delete outright here.
      if (record.episodeThumbPath != null) {
        final e = File(record.episodeThumbPath!);
        if (await e.exists()) await e.delete();
      }
    } catch (_) {}

    _records.remove(id);
    await _persist();

    // No point keeping a locally-saved resume point for media that no
    // longer exists on disk — see OfflineProgressStore.
    await OfflineProgressStore.clear(id);

    // Tidy up: a movie/album/show folder that's now completely empty
    // (this was its last file) is just clutter left behind in the
    // person's public Downloads folder — remove it. Left alone (and
    // silently ignored on failure) if anything else still lives there,
    // e.g. a series folder with other downloaded episodes.
    if (parentDir != null) {
      await _pruneIfEmpty(parentDir);
    }

    // Safety net: clears a lingering "Download complete" notification
    // for this item if the person deletes it from the Downloads page
    // before ever opening/swiping that notification away.
    DownloadNotificationService.instance.onDeleted(id);

    notifyListeners();
  }

  /// Deletes [dir] if it's now empty, then repeats for its parent, and
  /// so on — e.g. deleting an episode's own folder can leave the
  /// series folder empty too if it was the last episode downloaded.
  /// Stops before ever touching the public root or the fixed category
  /// folders directly under it ("Movies" / "TV Shows" / "Music"),
  /// which must always exist regardless of what's downloaded.
  Future<void> _pruneIfEmpty(Directory dir) async {
    try {
      final root = await _publicRoot;
      var current = dir;
      while (current.path != root.path && current.parent.path != root.path) {
        if (!await current.exists()) {
          current = current.parent;
          continue;
        }
        if (await current.list().isEmpty) {
          await current.delete();
          current = current.parent;
        } else {
          break;
        }
      }
    } catch (_) {}
  }

  /// Deletes every downloaded episode belonging to [seriesId].
  Future<void> deleteSeries(String seriesId) async {
    final ids = episodesForSeries(seriesId).map((e) => e.id).toList();
    for (final id in ids) {
      await deleteDownload(id);
    }
  }

  /// Wipes every download: cancels anything in-flight/queued/paused
  /// (each cancel cleans up its own partial file) and deletes every
  /// completed record's media/subtitle/poster/thumb files, exactly the
  /// way [deleteDownload] does per-item. Backs the Storage screen's
  /// "Remove all downloads" action.
  Future<void> deleteAllDownloads() async {
    for (final id in _tasks.keys.toList()) {
      cancelDownload(id);
    }
    for (final id in _records.keys.toList()) {
      await deleteDownload(id);
    }
  }

  // ───────────────────────────── Playback ─────────────────────────────

  /// Builds a MediaItem that plays from the local file when [item] (or
  /// its id) is downloaded, otherwise falls back to the normal network
  /// MediaItem — same shape either way, so nothing downstream (player,
  /// queue, mini player) needs to know or care which one it got.
  MediaItem mediaItemFor(Map<String, dynamic> item) {
    final id = item['Id']?.toString() ?? '';
    final record = _records[id];
    final base = MediaService.mediaItemFromJellyfin(item);

    if (record == null || record.mediaPath == null) return base;

    // NAMESIS PRIME: a title from the virtual server is normally "played" by
    // asking the addons for a stream. Once it is downloaded, the file on this
    // phone is what plays, so it must stop looking like a virtual item.
    final playableRaw = (base.raw != null &&
            base.raw!['NamesisVirtual'] == true &&
            record.raw['AddonStream'] == true)
        ? (<String, dynamic>{
            ...base.raw!,
            for (final k in const [
              'AddonStream',
              'IsLocal',
              'IsExternalFile',
              'TmdbId',
              'NamesisTitle',
              'NamesisEpisode',
            ])
              if (record.raw[k] != null) k: record.raw[k],
          }..remove('NamesisVirtual'))
        : base.raw;

    return MediaItem(
      id: base.id,
      title: base.title,
      subtitle: base.subtitle,
      streamUrl: record.mediaPath!,
      // Casting fix: `base.streamUrl` is the real, network-fetchable
      // Jellyfin stream URL `MediaService.mediaItemFromJellyfin` already
      // built (getAudioStreamUrl/getPlaybackUrl) — it was previously
      // discarded entirely once a download existed, so a Google Cast/
      // Nemesis Native receiver got handed this phone's on-disk file
      // path instead, which no other device can ever fetch (see
      // MediaItem.castStreamUrl). Keeping it here as `remoteStreamUrl`
      // lets local playback keep using the fast on-disk copy while
      // casting still has a real URL to send, whenever this device has
      // a network path to the server at all.
      remoteStreamUrl: base.streamUrl,
      // BUG FIX (episode list panel showing the stretched series poster
      // instead of the episode's own thumbnail for a downloaded
      // episode): `record.posterPath`/`thumbPath` deliberately hold the
      // *series'* shared art for an episode-kind record (see
      // DownloadRecord.episodeThumbPath's own doc comment for why) —
      // this line was reading straight past that field and always
      // preferring posterPath, so every downloaded episode's MediaItem
      // carried the series' portrait poster as `image`. Every consumer
      // of `image` for an episode (this panel's 96x54 landscape
      // thumbnail, EpisodeCardCompact, etc.) expects a 16:9 episode
      // frame, so BoxFit.cover rendered a heavily cropped, "stretched"-
      // looking sliver of the poster instead. episodeThumbPath is only
      // ever set for episode-kind records (null for movie/song), so
      // this doesn't change movie/song behavior at all.
      image: record.episodeThumbPath ?? record.posterPath ?? base.image,
      backdrop: base.backdrop,
      logo: base.logo,
      seriesId: base.seriesId,
      seasonId: base.seasonId,
      seasonNumber: base.seasonNumber,
      episodeNumber: base.episodeNumber,
      live: base.live,
      audioOnly: base.audioOnly,
      playbackPosition: base.playbackPosition,
      resumePosition: base.resumePosition,
      runtime: base.runtime,
      played: base.played,
      mediaStreams: base.mediaStreams,
      mediaSources: base.mediaSources,
      trickplay: base.trickplay,
      artistName: base.artistName,
      skipSegments: base.skipSegments,
      raw: playableRaw,
    );
  }

  /// Same as [mediaItemFor] but starting from an already-stored
  /// DownloadRecord rather than a live Jellyfin item — what the
  /// Downloads page itself uses, since it has no live item map handy.
  MediaItem mediaItemForRecord(DownloadRecord record) {
    return mediaItemFor(record.raw);
  }
}

/// A download failure with a message that's already fit to show the
/// person as-is — plain `Exception`/`StateError` stringify with a
/// "Exception: "/"Bad state: " prefix, which is what DownloadManager's
/// generic catch would otherwise surface on the failed-download row.
class _DownloadException implements Exception {
  final String message;
  const _DownloadException(this.message);

  @override
  String toString() => message;
}
