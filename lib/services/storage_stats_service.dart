import 'dart:io';

import 'package:disk_space_plus/disk_space_plus.dart';
import 'package:path_provider/path_provider.dart';

/// A snapshot of how much space the app is using, broken down into the
/// three buckets that map onto real user actions (Clear Cache empties
/// one of them; deleting a download empties another), plus the
/// device's total capacity for context.
///
/// Moved here from the Downloads screen, which used to show only the
/// downloads slice pinned to the top of the page. This service covers
/// the full picture instead: cache, app data, and downloads, each
/// queryable and summable into one "space used by this app" total.
class StorageBreakdown {
  final int cacheBytes;
  final int appDataBytes;
  final int downloadsBytes;

  /// Null if the platform query failed or isn't supported — same
  /// "nice to have, not worth crashing over" handling the old
  /// Downloads-screen header used for this same lookup.
  final double? totalDeviceBytes;

  /// Free space currently available on the device. Unlike
  /// [totalDeviceBytes] (a fixed device capacity, cached for the life
  /// of the process) this is queried fresh on every [compute] call
  /// since it changes as apps write/delete files.
  final double? freeDeviceBytes;

  const StorageBreakdown({
    required this.cacheBytes,
    required this.appDataBytes,
    required this.downloadsBytes,
    required this.totalDeviceBytes,
    required this.freeDeviceBytes,
  });

  int get appTotalBytes => cacheBytes + appDataBytes + downloadsBytes;

  /// Everything on the device that isn't Nemesis and isn't free space —
  /// i.e. the OS plus every other app's data. There's no platform API
  /// for "space used by other apps" directly, so this is derived as
  /// total minus free minus Nemesis' own total. Null whenever either
  /// device-wide figure is unavailable; clamped to 0 to guard against
  /// the free/total readings landing a hair apart in rounding.
  int? otherAppsBytes(int downloadsBytesLive) {
    if (totalDeviceBytes == null || freeDeviceBytes == null) return null;
    final ourTotal = cacheBytes + appDataBytes + downloadsBytesLive;
    final other = totalDeviceBytes! - freeDeviceBytes! - ourTotal;
    return other < 0 ? 0 : other.round();
  }
}

class StorageStatsService {
  StorageStatsService._();

  /// A device's total capacity is fixed for the life of the app
  /// process (barring an SD card swap, which isn't worth a re-query
  /// here) — same reasoning/caching the old Downloads-screen header
  /// applied to this same platform call.
  static double? _cachedTotalDeviceBytes;

  /// Top-level folder name under the app documents directory that
  /// [DownloadManager] falls back to for the public downloads root
  /// when no external storage volume exists (rare — effectively only
  /// a bare Android device/emulator with no shared storage, or a
  /// desktop dev run). Skipped when scanning app data so that edge
  /// case doesn't double-count real downloaded media as app data; on
  /// the common path downloads already live entirely outside the app
  /// documents directory, so this skip is a no-op there.
  static const String _downloadsFallbackFolderName = 'Nemesis';

  /// Computes cache, app data, and downloads size plus device total,
  /// in parallel. Each piece degrades to 0 (or null for device total)
  /// on failure rather than throwing, so one unreadable directory or
  /// an unsupported platform call doesn't blank the whole card.
  static Future<StorageBreakdown> compute() async {
    final results = await Future.wait([
      _cacheBytes(),
      _appDataBytes(),
      _totalDeviceBytes(),
      _freeDeviceBytes(),
    ]);

    return StorageBreakdown(
      cacheBytes: results[0] as int,
      appDataBytes: results[1] as int,
      // Downloads size isn't scanned from disk here — DownloadManager
      // already tracks each record's file size in memory (it's what
      // drove the old header), and that number updates live the
      // instant a download completes or is deleted, which a disk scan
      // wouldn't without an extra round trip.
      downloadsBytes: 0,
      totalDeviceBytes: results[2] as double?,
      freeDeviceBytes: results[3] as double?,
    );
  }

  /// Cached network images (DefaultCacheManager + NemesisImageCache)
  /// and mpv's stream cache all live under the OS temp directory —
  /// see AppSettingsScreen._clearCache, which empties all three as one
  /// unit. Summing the whole temp directory therefore covers exactly
  /// what "Clear Cache" clears.
  static Future<int> _cacheBytes() async {
    try {
      final dir = await getTemporaryDirectory();
      return await _directorySize(dir);
    } catch (_) {
      return 0;
    }
  }

  /// Everything else the app has written to its own documents
  /// directory: settings/login (via SharedPreferences' backing file),
  /// and the downloads index/poster-art metadata DownloadManager keeps
  /// privately (small — not the downloaded media itself, which lives
  /// under the public downloads root and is counted separately).
  static Future<int> _appDataBytes() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      return await _directorySize(
        dir,
        skipTopLevelNames: {_downloadsFallbackFolderName},
      );
    } catch (_) {
      return 0;
    }
  }

  static Future<double?> _totalDeviceBytes() async {
    if (_cachedTotalDeviceBytes != null) return _cachedTotalDeviceBytes;
    try {
      final totalMb = await DiskSpacePlus().getTotalDiskSpace;
      if (totalMb == null) return null;
      final totalBytes = totalMb * 1024 * 1024;
      _cachedTotalDeviceBytes = totalBytes;
      return totalBytes;
    } catch (_) {
      return null;
    }
  }

  /// Free space right now, in bytes. Deliberately not cached like
  /// [_totalDeviceBytes] — this number moves as apps download,
  /// install, or clear data, so a stale reading would make the
  /// "Other apps" derivation drift the longer the process stays alive.
  static Future<double?> _freeDeviceBytes() async {
    try {
      final freeMb = await DiskSpacePlus().getFreeDiskSpace;
      if (freeMb == null) return null;
      return freeMb * 1024 * 1024;
    } catch (_) {
      return null;
    }
  }

  /// Recursively sums file sizes under [dir]. [skipTopLevelNames]
  /// excludes immediate child entries by name (not nested ones with
  /// the same name deeper in the tree) — used to carve the rare
  /// downloads-fallback folder out of the app-data scan above.
  /// Failures on individual entries (permissions, a file deleted
  /// mid-scan) are swallowed and just don't add to the total, rather
  /// than aborting the whole scan.
  static Future<int> _directorySize(
    Directory dir, {
    Set<String> skipTopLevelNames = const {},
    bool isTopLevel = true,
  }) async {
    if (!await dir.exists()) return 0;

    var total = 0;
    try {
      await for (final entity in dir.list(followLinks: false)) {
        if (isTopLevel) {
          final name = entity.path.split(Platform.pathSeparator).last;
          if (skipTopLevelNames.contains(name)) continue;
        }

        if (entity is File) {
          try {
            total += await entity.length();
          } catch (_) {
            // Skip files that vanish or are locked mid-scan.
          }
        } else if (entity is Directory) {
          total += await _directorySize(entity, isTopLevel: false);
        }
      }
    } catch (_) {
      // Non-fatal — return whatever was summed before the failure.
    }
    return total;
  }
}
