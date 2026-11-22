import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// A subtitle previously fetched from OpenSubtitles for some item, read
/// back off disk. Shape matches exactly what
/// `PlayerManager.loadDownloadedSubtitle` needs, so a cache hit can be
/// applied the same way a fresh download would be.
class CachedSubtitle {
  final String content;
  final String displayTitle;
  final String language;

  const CachedSubtitle({
    required this.content,
    required this.displayTitle,
    required this.language,
  });
}

/// App-private, on-disk cache for the two "found it once, shouldn't have
/// to ask again" cases in the player: an LRCLIB lyrics match for a
/// streamed song Jellyfin itself has no lyrics for, and an OpenSubtitles
/// download picked for a streamed video. Neither is a user-initiated
/// "download" (see [DownloadManager] for that), so both live under the
/// app's private documents dir rather than the public Nemesis folder —
/// nothing here is meant to be visible to the user in a file manager,
/// it's purely so the same item played again doesn't re-hit LRCLIB or
/// OpenSubtitles for something already resolved.
///
/// Keyed by Jellyfin item id, one entry per item for each cache. Every
/// method is best-effort: a failed read or write here should never break
/// the lyrics screen or subtitle playback, it just means that case falls
/// back to a fresh network fetch, same as before this cache existed.
class MediaExtrasCacheService {
  MediaExtrasCacheService._();

  static Future<Directory> get _lyricsDir async {
    final dir = await getApplicationDocumentsDirectory();
    final target = Directory('${dir.path}/media_extras_cache/lyrics');
    if (!await target.exists()) {
      await target.create(recursive: true);
    }
    return target;
  }

  static Future<Directory> get _subtitlesDir async {
    final dir = await getApplicationDocumentsDirectory();
    final target = Directory('${dir.path}/media_extras_cache/subtitles');
    if (!await target.exists()) {
      await target.create(recursive: true);
    }
    return target;
  }

  /// Item ids are already server-generated hex/guid-like strings in
  /// practice, but sanitizing before using one as a filename costs
  /// nothing and rules out any surprise from a future id format.
  static String _sanitize(String id) => id.replaceAll(RegExp(r'[^\w\-]'), '_');

  // ─────────────────────────── Lyrics (LRCLIB) ───────────────────────────

  /// Saves LRCLIB's match for [itemId] as raw LRC text — the exact same
  /// format `LyricsScreen._parseLrc` already reads for a downloaded
  /// song's `.lrc` sidecar, so one parser serves both paths.
  static Future<void> saveLyrics(String itemId, String lrcContent) async {
    if (lrcContent.trim().isEmpty) return;

    try {
      final dir = await _lyricsDir;
      final file = File('${dir.path}/${_sanitize(itemId)}.lrc');
      await file.writeAsString(lrcContent);
    } catch (e) {
      // Best-effort — see class doc comment.
    }
  }

  /// Returns the previously-cached LRCLIB match for [itemId], or null if
  /// nothing was ever cached (or the file turned out empty/unreadable).
  static Future<String?> readLyrics(String itemId) async {
    try {
      final dir = await _lyricsDir;
      final file = File('${dir.path}/${_sanitize(itemId)}.lrc');
      if (!await file.exists()) return null;

      final content = await file.readAsString();
      return content.trim().isEmpty ? null : content;
    } catch (e) {
      return null;
    }
  }

  // ────────────────────────── Subtitles (OpenSubtitles) ──────────────────

  /// Saves an OpenSubtitles download for [itemId]. One cached subtitle
  /// per item — a second save for the same item replaces the first,
  /// mirroring the fact that picking a subtitle for a video is a single
  /// choice, not a set.
  static Future<void> saveSubtitle({
    required String itemId,
    required String content,
    required String displayTitle,
    required String language,
  }) async {
    if (content.trim().isEmpty) return;

    try {
      final dir = await _subtitlesDir;
      final file = File('${dir.path}/${_sanitize(itemId)}.json');
      await file.writeAsString(jsonEncode({
        'displayTitle': displayTitle,
        'language': language,
        'content': content,
      }));
    } catch (e) {
      // Best-effort — see class doc comment.
    }
  }

  /// Returns the previously-cached OpenSubtitles pick for [itemId], or
  /// null if nothing was ever cached (or it turned out unreadable).
  static Future<CachedSubtitle?> readSubtitle(String itemId) async {
    try {
      final dir = await _subtitlesDir;
      final file = File('${dir.path}/${_sanitize(itemId)}.json');
      if (!await file.exists()) return null;

      final map = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final content = (map['content'] as String?) ?? '';
      if (content.trim().isEmpty) return null;

      return CachedSubtitle(
        content: content,
        displayTitle: (map['displayTitle'] as String?) ?? 'Subtitle',
        language: (map['language'] as String?) ?? 'und',
      );
    } catch (e) {
      return null;
    }
  }
}
