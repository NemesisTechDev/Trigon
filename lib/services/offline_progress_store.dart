import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Per-download watch progress, saved entirely on-device — the local,
/// offline counterpart to the server-reported resume position Jellyfin
/// tracks for everything else (see PlaybackProgressService).
///
/// Deliberately separate from that server state, and from the Home
/// screen's "Continue Watching" row (built from Jellyfin's own
/// UserData): this store is only ever written to while playing a
/// *downloaded* movie or episode (see OfflineProgressService/
/// PlayerManager), and only ever read by the Downloads page and by
/// PlayerManager's own resume-seek logic when re-opening a download.
/// The two "continue watching" surfaces stay fully independent of one
/// another, which is the whole point — a downloaded title keeps
/// tracking progress with no network at all, and nothing here ever
/// touches (or is touched by) the server-driven state used elsewhere.
///
/// Keyed by Jellyfin item id — a movie's own id, or an individual
/// episode's id, exactly like the server keys its own UserData — and
/// stored as one JSON blob in SharedPreferences:
///   { itemId: { "position": <ms>, "runtime": <ms>, "updatedAt": <ms>, "played": bool } }
class OfflineProgressStore {
  OfflineProgressStore._();

  static const _key = "offline_playback_progress_v1";

  /// An item counts as "finished" past this fraction of its runtime —
  /// the same 90% heuristic PlayerManager already uses for the
  /// server-reported "Sessions/Playing/Stopped" finished report (see
  /// its position-stream listener), kept in sync so a downloaded title
  /// reads as watched at the same point playback actually stops
  /// mattering either way.
  static const double _finishedThreshold = 0.9;

  /// A position under this floor is treated as "hasn't really
  /// started" rather than persisted as a resume point — mirrors why
  /// the server doesn't bother keeping a PlaybackPositionTicks of a
  /// couple of seconds either.
  static const _minResumePosition = Duration(seconds: 5);

  static Future<Map<String, dynamic>> _readAll() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {
      // Corrupt/unreadable blob — treat as "nothing saved yet" rather
      // than crashing playback or the Downloads page.
    }
    return {};
  }

  static Future<void> _writeAll(Map<String, dynamic> all) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(all));
  }

  /// Persists [position]/[runtime] for [itemId] — called periodically
  /// (and on stop) while a download is actually playing. Idempotent
  /// and safe to call often; entries below [_minResumePosition] are
  /// dropped rather than stored as a near-zero "resume" point, and
  /// entries past [_finishedThreshold] collapse to a `played` marker
  /// with the position reset, matching Jellyfin's own UserData
  /// behavior once something is marked watched.
  static Future<void> save(
    String itemId,
    Duration position,
    Duration runtime,
  ) async {
    if (itemId.isEmpty) return;

    final all = await _readAll();

    final finished =
        runtime > Duration.zero && position >= runtime * _finishedThreshold;

    if (finished) {
      all[itemId] = _entry(Duration.zero, runtime, played: true);
    } else if (position < _minResumePosition) {
      all.remove(itemId);
    } else {
      all[itemId] = _entry(position, runtime, played: false);
    }

    await _writeAll(all);
  }

  /// Marks [itemId] as fully watched outright, without waiting for the
  /// next periodic [save] to catch up — used for the same "reached
  /// 90%" early-finish moment PlaybackProgressService.markFinished()
  /// covers server-side.
  static Future<void> markFinished(String itemId, Duration runtime) async {
    if (itemId.isEmpty) return;
    final all = await _readAll();
    all[itemId] = _entry(Duration.zero, runtime, played: true);
    await _writeAll(all);
  }

  static Map<String, dynamic> _entry(
    Duration position,
    Duration runtime, {
    required bool played,
  }) {
    return {
      "position": position.inMilliseconds,
      "runtime": runtime.inMilliseconds,
      "updatedAt": DateTime.now().millisecondsSinceEpoch,
      "played": played,
    };
  }

  /// The saved resume position for [itemId], or null if there isn't
  /// one (never played, already finished, or below the resume floor).
  static Future<Duration?> getPosition(String itemId) async {
    final all = await _readAll();
    return _positionFrom(all[itemId]);
  }

  static Duration? _positionFrom(dynamic entry) {
    if (entry == null) return null;
    final map = Map<String, dynamic>.from(entry as Map);
    if (map['played'] == true) return null;
    final ms = (map['position'] as num?)?.toInt() ?? 0;
    return ms > 0 ? Duration(milliseconds: ms) : null;
  }

  /// 0.0–1.0 watched fraction for [itemId], or null if nothing's been
  /// saved yet — what the Downloads page's progress bars read from.
  static Future<double?> getFraction(String itemId) async {
    final all = await _readAll();
    return _fractionFrom(all[itemId]);
  }

  static double? _fractionFrom(dynamic entry) {
    if (entry == null) return null;
    final map = Map<String, dynamic>.from(entry as Map);
    if (map['played'] == true) return 1.0;
    final positionMs = (map['position'] as num?)?.toInt() ?? 0;
    final runtimeMs = (map['runtime'] as num?)?.toInt() ?? 0;
    if (runtimeMs <= 0) return null;
    return (positionMs / runtimeMs).clamp(0.0, 1.0);
  }

  /// Bulk variant of [getFraction] — one SharedPreferences read for a
  /// whole grid/list of downloads instead of one per tile.
  static Future<Map<String, double>> getFractions(
    Iterable<String> itemIds,
  ) async {
    final all = await _readAll();
    final result = <String, double>{};
    for (final id in itemIds) {
      final fraction = _fractionFrom(all[id]);
      if (fraction != null) result[id] = fraction;
    }
    return result;
  }

  /// Returns a shallow copy of [raw] (a Jellyfin item map, as stored on
  /// a [DownloadRecord]) with its `UserData.PlaybackPositionTicks`/
  /// `Played` overridden by whatever's saved locally for this item,
  /// whenever that's more advanced than what [raw] already carries.
  /// [raw] itself is returned unchanged when there's no local entry,
  /// or the local one isn't ahead — so this is always safe to call,
  /// including for items that were never downloaded at all.
  ///
  /// Used to make the Downloads page's movie/episode cards — which
  /// otherwise only have whatever UserData snapshot was captured at
  /// download time — reflect progress made while watching fully
  /// offline, without touching the server-driven UserData anywhere
  /// else in the app.
  static Future<Map<String, dynamic>> applyToRaw(
    Map<String, dynamic> raw,
  ) async {
    final id = raw['Id']?.toString();
    if (id == null || id.isEmpty) return raw;

    final all = await _readAll();
    return _mergeUserData(raw, all[id]);
  }

  /// Batch variant of [applyToRaw] for an episode list — a single
  /// SharedPreferences read for the whole season instead of one per
  /// episode.
  static Future<List<Map<String, dynamic>>> applyToRawList(
    List<Map<String, dynamic>> items,
  ) async {
    if (items.isEmpty) return items;
    final all = await _readAll();
    return items
        .map((item) => _mergeUserData(item, all[item['Id']?.toString()]))
        .toList();
  }

  static Map<String, dynamic> _mergeUserData(
    Map<String, dynamic> raw,
    dynamic entry,
  ) {
    if (entry == null) return raw;
    final map = Map<String, dynamic>.from(entry as Map);

    final played = map['played'] == true;
    final localTicks = ((map['position'] as num?)?.toInt() ?? 0) * 10000;

    final userData = Map<String, dynamic>.from(raw['UserData'] ?? {});
    final existingTicks =
        (userData['PlaybackPositionTicks'] as num?)?.toInt() ?? 0;
    final existingPlayed = userData['Played'] == true;

    if (played && !existingPlayed) {
      userData['Played'] = true;
      userData['PlaybackPositionTicks'] = 0;
    } else if (!played && localTicks > existingTicks) {
      userData['PlaybackPositionTicks'] = localTicks;
      userData['Played'] = false;
    } else {
      return raw;
    }

    final copy = Map<String, dynamic>.from(raw);
    copy['UserData'] = userData;
    return copy;
  }

  /// Called when a download is deleted — no point keeping progress for
  /// media that no longer exists on disk.
  static Future<void> clear(String itemId) async {
    final all = await _readAll();
    if (all.remove(itemId) != null) {
      await _writeAll(all);
    }
  }
}
