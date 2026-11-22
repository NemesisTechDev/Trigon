import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../player/models/media_item.dart';
import 'favorite_service.dart';
import 'local_playlist_service.dart';

/// Everything about the opt-in "Local Files" feature on the Music
/// screen: requesting the runtime permission, scanning device storage
/// for audio via Android's MediaStore (through `on_audio_query`),
/// caching embedded artwork to disk, and tracking the local-only
/// favorite/"removed from app" state that has no server-side Jellyfin
/// equivalent to live on.
///
/// Deliberately mirrors [DownloadManager]'s shape (singleton,
/// ChangeNotifier-adjacent via a couple of ValueNotifiers, lazy disk
/// persistence) so the rest of the app can reason about it the same way.
class LocalMusicService {
  LocalMusicService._();
  static final LocalMusicService instance = LocalMusicService._();

  static const _kEnabledKey = 'local_music_enabled_v1';
  static const _kFavoritesKey = 'local_music_favorites_v1';
  static const _kExcludedKey = 'local_music_excluded_v1';

  // Favorited-at timestamps for local songs only, id -> milliseconds
  // since epoch — the on-device counterpart to FavoriteService's
  // account-synced timestamp map, kept entirely separate on purpose.
  // A local file has no Jellyfin item id and nothing to sync it to, so
  // this never goes near DisplayPreferences or any network call; it's
  // read purely so the Favorites page can slot local favorites into
  // the same newest-favorited-first ordering as everything else.
  static const _kFavoritedAtKey = 'local_music_favorited_at_v1';

  final OnAudioQuery _query = OnAudioQuery();

  /// Whether the person has the Local Files toggle on. Read
  /// synchronously by the Music screen to decide whether the chip
  /// should even be built, and listened to so flipping it in Settings
  /// updates the Music screen live if it's already open.
  final ValueNotifier<bool> enabledNotifier = ValueNotifier(false);
  bool get enabled => enabledNotifier.value;

  final Set<String> _favorites = {};
  final Set<String> _excluded = {};
  final Map<String, int> _favoritedAt = {};

  /// Most recent scan result, kept around so a song just removed via
  /// "Remove from App" (or favorited/unfavorited) can be reflected
  /// immediately without waiting on a fresh MediaStore query.
  List<Map<String, dynamic>> _cachedSongs = [];
  List<Map<String, dynamic>> get cachedSongs =>
      List.unmodifiable(_cachedSongs);

  bool _initialized = false;

  /// Loads the persisted enabled flag plus favorite/exclusion sets. Call
  /// once at app startup — cheap and safe to call more than once.
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    try {
      final prefs = await SharedPreferences.getInstance();
      enabledNotifier.value = prefs.getBool(_kEnabledKey) ?? false;
      _favorites.addAll(prefs.getStringList(_kFavoritesKey) ?? const []);
      _excluded.addAll(prefs.getStringList(_kExcludedKey) ?? const []);

      final rawTimestamps = prefs.getString(_kFavoritedAtKey);
      if (rawTimestamps != null) {
        try {
          final decoded = json.decode(rawTimestamps) as Map<String, dynamic>;
          _favoritedAt.addAll(
            decoded.map((key, value) => MapEntry(key, value as int)),
          );
        } catch (e) {
          debugPrint('LocalMusicService.init failed to parse timestamps: $e');
        }
      }
    } catch (e) {
      debugPrint('LocalMusicService.init failed: $e');
    }
  }

  /// Favorited-at timestamps for local songs, id -> milliseconds since
  /// epoch. Merged into [FavoriteService]'s map by the Favorites page
  /// so local favorites sort newest-first alongside everything else —
  /// see the field doc comment above for why this stays local-only.
  Map<String, int> get favoritedAtTimestamps => Map.unmodifiable(_favoritedAt);

  Future<Directory> get _artworkDir async {
    final dir = await getApplicationDocumentsDirectory();
    final artDir = Directory('${dir.path}/local_music_artwork');
    if (!await artDir.exists()) {
      await artDir.create(recursive: true);
    }
    return artDir;
  }

  // ───────────────────────────── Permission / enable ─────────────────────────────

  /// Requests whatever permission the OS needs, flips [enabledNotifier]
  /// on success, and persists the choice. Returns the resulting
  /// [PermissionStatus] so the caller (Settings screen) can tell a plain
  /// denial apart from "permanently denied" (needs Settings-app
  /// intervention) and show the right message.
  Future<PermissionStatus> requestPermissionAndEnable() async {
    if (!Platform.isAndroid) {
      // No runtime prompt on other platforms — best effort, just turn
      // the feature on.
      await _setEnabled(true);
      return PermissionStatus.granted;
    }

    // Request both — only the one that actually applies to this OS
    // version does anything; the other resolves immediately as
    // permanently denied/restricted and is ignored.
    final results = await [
      Permission.audio,
      Permission.storage,
    ].request();

    final granted = results.values.any((s) => s.isGranted);

    if (granted) {
      await _setEnabled(true);
      return PermissionStatus.granted;
    }

    final permanentlyDenied =
        results.values.any((s) => s.isPermanentlyDenied);

    return permanentlyDenied
        ? PermissionStatus.permanentlyDenied
        : PermissionStatus.denied;
  }

  Future<void> _setEnabled(bool value) async {
    enabledNotifier.value = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kEnabledKey, value);
    } catch (e) {
      debugPrint('LocalMusicService._setEnabled failed: $e');
    }
  }

  /// Turns the feature off: clears the in-memory scan, every persisted
  /// local favorite/exclusion, and any cached artwork on disk. Doesn't
  /// touch the actual audio files on the device — only what this app
  /// tracks about them. Callers are responsible for warning the person
  /// first (this performs the removal unconditionally).
  Future<void> disable() async {
    await _setEnabled(false);
    _cachedSongs = [];
    _favorites.clear();
    _excluded.clear();
    _favoritedAt.clear();

    // Playlist membership for on-device songs is tracked by this app
    // alone (see LocalPlaylistService), so switching the feature off
    // has to drop it too — otherwise on-device-only playlists would be
    // left behind as permanently empty entries.
    await LocalPlaylistService.instance.clearAll();

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kFavoritesKey);
      await prefs.remove(_kExcludedKey);
      await prefs.remove(_kFavoritedAtKey);
    } catch (e) {
      debugPrint('LocalMusicService.disable failed to clear prefs: $e');
    }

    try {
      final dir = await _artworkDir;
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    } catch (e) {
      debugPrint('LocalMusicService.disable failed to clear artwork: $e');
    }
  }

  // ─────────────────────────────── Scanning ───────────────────────────────

  static String _idFor(int mediaStoreId) => 'local_$mediaStoreId';

  /// Queries device storage fresh (cheap — it's a local MediaStore
  /// lookup, not a network call) and returns every song not currently
  /// excluded, sorted A–Z by title. Extracts and disk-caches embedded
  /// artwork for any song that doesn't already have a cached copy.
  Future<List<Map<String, dynamic>>> scanAndGetSongs() async {
    if (!enabled) return [];

    List<SongModel> songs;
    try {
      songs = await _query.querySongs(
        sortType: SongSortType.TITLE,
        orderType: OrderType.ASC_OR_SMALLER,
        uriType: UriType.EXTERNAL,
        ignoreCase: true,
      );
    } catch (e) {
      debugPrint('LocalMusicService.scanAndGetSongs failed: $e');
      return _cachedSongs;
    }

    final artDir = await _artworkDir;
    final result = <Map<String, dynamic>>[];

    for (final song in songs) {
      // MediaStore tags every audio file with IS_MUSIC based on its type
      // (podcast/ringtone/alarm/notification/audiobook/voice recording
      // all get is_music = 0) — exactly the same signal VLC and other
      // "Music" scanners key off of to keep voice memos and ringtones out
      // of a music library. Defaults to included when the plugin can't
      // read the column at all, rather than risk hiding real music on a
      // device/OEM that doesn't populate it reliably.
      if (song.isMusic == false) continue;

      final id = _idFor(song.id);
      if (_excluded.contains(id)) continue;

      final artworkPath = await _resolveArtwork(song.id, artDir);
      final resolved = _resolveTitleAndArtist(song);
      final lyricsPath = await _resolveSidecarLyrics(song.data);

      result.add({
        'Id': id,
        'Name': resolved.title,
        'AlbumArtist': resolved.artist,
        'Artists': resolved.artist.isNotEmpty ? [resolved.artist] : [],
        'Album': song.album,
        'RunTimeTicks': (song.duration ?? 0) * 10000,
        'IsLocal': true,
        'LocalUri': song.uri ?? song.data,
        // LOCAL CASTING: `song.uri` (what `LocalUri` above prefers, per
        // scoped storage) is a bare `content://media/.../<id>` URI with
        // no file extension of its own to read — `GoogleCastTransport`
        // needs the *real* container (mp3/m4a/flac/etc.) to know
        // whether the stock Cast receiver can even open this file, and
        // has no way to derive that from the content URI alone.
        // `song.data` is still always populated by MediaStore with the
        // real absolute path (even where it isn't itself a readable
        // path under scoped storage) purely as a string to read the
        // true extension off of.
        'FileExtension': _extensionOf(song.data),
        'ArtworkPath': artworkPath,
        // LYRICS SIDECAR FIX: a same-named ".lrc" sitting next to this
        // song on disk (see _resolveSidecarLyrics) — LyricsScreen reads
        // this straight off disk exactly like a DownloadManager song's
        // own lyrics sidecar, just discovered by matching a file name on
        // this on-device scan rather than a Jellyfin download record.
        // Key simply omitted (LyricsScreen sees it as absent, same as a
        // download with no lyrics) when there's no matching file.
        if (lyricsPath != null) 'LyricsPath': lyricsPath,
        // MediaStore's DATE_ADDED, in epoch seconds — the only thing
        // backing the "New" sort on the Music screen's On This Device
        // tab, since there's no server-side sort query for a local scan.
        'DateAdded': song.dateAdded ?? 0,
        'UserData': {
          'IsFavorite': _favorites.contains(id),
          'PlayCount': 0,
        },
      });
    }

    _cachedSongs = result;
    return result;
  }

  /// MediaStore's `title`/`artist` columns are only as good as the
  /// file's own tags — for a file with missing/blank tags, MediaStore
  /// silently falls back to the bare filename as the "title" and leaves
  /// artist unset, which is indistinguishable from an actual song
  /// legitimately titled that. That untagged case is exactly what was
  /// slipping through: the Music screen showed a garbled/filename-y
  /// title, and worse, [LyricsScreen]'s LRCLIB lookup (which sends this
  /// same title + artist as its search query) had a near-empty or
  /// literally-the-filename query to work with and came back empty.
  ///
  /// When that fallback is detected, this re-parses the filename itself
  /// for the extremely common "Artist - Title" naming convention (how
  /// most manually-renamed/downloaded audio ends up named in practice),
  /// stripping leading track-number prefixes and bracketed junk like
  /// "(Official Audio)" first. A real tagged title/artist from MediaStore
  /// always wins when present — this is only ever a fallback for files
  /// that had nothing usable to begin with.
  ({String title, String artist}) _resolveTitleAndArtist(SongModel song) {
    final rawTitle = song.title.trim();
    final rawArtist =
        (song.artist == null || song.artist == '<unknown>')
            ? ''
            : song.artist!.trim();

    // MediaStore stamps the bare filename in as `title` when the file
    // has no usable tag of its own — that's the specific case worth
    // second-guessing, not just "artist happens to be blank" (plenty of
    // real singles/loosies are tagged with a title but no artist).
    final looksUntagged =
        rawTitle.isEmpty || rawTitle == song.displayNameWOExt.trim();

    if (!looksUntagged) {
      return (title: rawTitle, artist: rawArtist);
    }

    final parsed = _parseArtistTitleFromFilename(song.displayNameWOExt);
    final title = parsed.title.isNotEmpty
        ? parsed.title
        : (rawTitle.isNotEmpty ? rawTitle : song.displayNameWOExt);

    return (
      title: title,
      artist: rawArtist.isNotEmpty ? rawArtist : parsed.artist,
    );
  }

  static final RegExp _leadingTrackNumber = RegExp(r'^\s*\d{1,3}[\s._-]+');

  // Strips common "extra info" noise (release tags, quality markers)
  // that shows up in downloaded-audio filenames but was never part of
  // the actual song title, so it doesn't end up polluting either the
  // displayed title or the LRCLIB search query built from it.
  static final RegExp _bracketedJunk = RegExp(
    r'[\(\[][^)\]]*\b(official|video|audio|lyrics?|hq|hd|remaster\w*|explicit|clean)\b[^)\]]*[\)\]]',
    caseSensitive: false,
  );

  static final RegExp _artistTitleSplit =
      RegExp(r'^(.{1,80}?)\s*[-\u2013\u2014]\s*(.{1,120})$');

  ({String artist, String title}) _parseArtistTitleFromFilename(String name) {
    var cleaned = name.replaceAll('_', ' ').trim();
    cleaned = cleaned.replaceFirst(_leadingTrackNumber, '');
    cleaned = cleaned.replaceAll(_bracketedJunk, '');
    cleaned = cleaned.replaceAll(RegExp(r'\s+'), ' ').trim();

    final match = _artistTitleSplit.firstMatch(cleaned);
    if (match != null) {
      final artist = match.group(1)!.trim();
      final title = match.group(2)!.trim();
      if (artist.isNotEmpty && title.isNotEmpty) {
        return (artist: artist, title: title);
      }
    }

    return (artist: '', title: cleaned);
  }

  /// See the `'FileExtension'` field doc comment in [scanAndGetSongs].
  String _extensionOf(String? path) {
    if (path == null || path.isEmpty) return '';
    final dot = path.lastIndexOf('.');
    if (dot < 0 || dot == path.length - 1) return '';
    return path.substring(dot + 1).toLowerCase();
  }

  /// A same-named `.lrc` file sitting right next to an on-device song's
  /// real file path (e.g. "Artist - Title.mp3" / "Artist - Title.lrc")
  /// — the same sidecar convention DownloadManager already uses for its
  /// own downloaded songs, just discovered here by checking disk
  /// directly instead of trusting a download record keyed by Jellyfin
  /// item id (an on-device file was never downloaded through this app
  /// at all). `song.data` (not `song.uri`) is used because it's the one
  /// MediaStore column guaranteed to be a real filesystem path — see
  /// `FileExtension`'s own doc comment above for why `.uri` can't be
  /// used the same way. Returns null on anything but a genuine match
  /// (no sidecar, or a permission/IO error reading for it) — the caller
  /// already treats a missing lyrics path as "nothing to show" exactly
  /// like a download with no lyrics sidecar of its own.
  Future<String?> _resolveSidecarLyrics(String? dataPath) async {
    if (dataPath == null || dataPath.isEmpty) return null;

    final dot = dataPath.lastIndexOf('.');
    if (dot <= 0) return null;

    try {
      final candidate = File('${dataPath.substring(0, dot)}.lrc');
      return await candidate.exists() ? candidate.path : null;
    } catch (e) {
      debugPrint('LocalMusicService lyrics sidecar check failed: $e');
      return null;
    }
  }

  Future<String?> _resolveArtwork(int mediaStoreId, Directory artDir) async {
    final path = '${artDir.path}/$mediaStoreId.jpg';
    final file = File(path);

    if (await file.exists()) {
      // Empty marker file means a previous attempt found no artwork —
      // skip re-querying it every single scan.
      final size = await file.length();
      return size > 0 ? path : null;
    }

    try {
      final bytes = await _query.queryArtwork(
        mediaStoreId,
        ArtworkType.AUDIO,
        format: ArtworkFormat.JPEG,
        size: 400,
      );

      if (bytes == null || bytes.isEmpty) {
        // Write a zero-byte marker so the next scan doesn't re-attempt
        // (and re-fail) the same lookup for a track with no embedded
        // art at all.
        await file.create();
        return null;
      }

      await file.writeAsBytes(bytes, flush: true);
      return path;
    } catch (e) {
      debugPrint('LocalMusicService artwork extract failed for $mediaStoreId: $e');
      return null;
    }
  }

  // ─────────────────────────────── Favorites ───────────────────────────────

  bool isFavorite(String id) => _favorites.contains(id);

  /// Favorited local songs, for the Favorites page's Songs section.
  /// Re-scans (see [scanAndGetSongs] — a local MediaStore query, not a
  /// network call, so this stays as fast as the rest of the Local
  /// Files feature) rather than trusting [_cachedSongs], which is only
  /// ever populated once the Music tab's On This Device view has
  /// actually been opened this session; without a fresh scan here, a
  /// song favorited on-device would be invisible on the Favorites page
  /// until that tab happened to be opened first.
  Future<List<Map<String, dynamic>>> getFavoritedSongs() async {
    if (!enabled) return [];
    final all = await scanAndGetSongs();
    return all
        .where((song) => (song['UserData'] as Map?)?['IsFavorite'] == true)
        .toList();
  }

  /// Flips local-favorite state for [id] and mirrors it onto whichever
  /// song map(s) hold this id in the in-memory scan cache, the same
  /// "keep every reference in sync" reasoning SongOptionsSheet already
  /// applies for server-side favorites.
  Future<void> toggleFavorite(String id) async {
    final nowFavorite = !_favorites.contains(id);

    if (nowFavorite) {
      _favorites.add(id);
      // Recorded the same moment the favorite itself is set, exactly
      // like FavoriteService.recordFavoritedTimestamp does for
      // server-backed items — this is what lets the Favorites page
      // place this song correctly among newest-favorited-first.
      _favoritedAt[id] = DateTime.now().millisecondsSinceEpoch;
    } else {
      _favorites.remove(id);
      _favoritedAt.remove(id);
    }

    for (final song in _cachedSongs) {
      if (song['Id'] == id) {
        song['UserData'] = {
          ...(song['UserData'] as Map? ?? {}),
          'IsFavorite': nowFavorite,
        };
      }
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_kFavoritesKey, _favorites.toList());
      await prefs.setString(_kFavoritedAtKey, json.encode(_favoritedAt));
    } catch (e) {
      debugPrint('LocalMusicService.toggleFavorite failed to persist: $e');
    }

    // In-memory state is already updated above, so live favorites lists
    // can reload now (see FavoriteService.changes).
    FavoriteService.notifyChanged();
  }

  // ────────────────────────── Remove from app ──────────────────────────

  /// Hides [id] from the app's Local Files list without touching the
  /// actual file on the device. Persisted, so it stays hidden across
  /// app restarts (and future scans) until the feature is toggled off
  /// and back on again.
  Future<void> removeFromApp(String id) async {
    _excluded.add(id);
    _favorites.remove(id);
    _favoritedAt.remove(id);
    _cachedSongs.removeWhere((song) => song['Id'] == id);

    // Also out of every playlist it was in — see LocalPlaylistService.
    await LocalPlaylistService.instance.removeSongEverywhere([id]);

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_kExcludedKey, _excluded.toList());
      await prefs.setStringList(_kFavoritesKey, _favorites.toList());
      await prefs.setString(_kFavoritedAtKey, json.encode(_favoritedAt));
    } catch (e) {
      debugPrint('LocalMusicService.removeFromApp failed to persist: $e');
    }
  }

  // ───────────────────────────── MediaItem building ─────────────────────────────

  /// Builds a playable [MediaItem] straight from a local file path/URI —
  /// no server round trip, no Jellyfin id. `raw` carries `IsLocal: true`
  /// so every other layer (PlayerManager favorites, the options sheet,
  /// the queue/mini player artwork) can tell it apart from a normal
  /// Jellyfin item without a second parameter threaded everywhere.
  static MediaItem mediaItemFromLocalSong(Map<String, dynamic> song) {
    final artistName = (song['AlbumArtist'] ?? '').toString();
    final artworkPath = song['ArtworkPath'] as String?;
    final durationTicks = (song['RunTimeTicks'] as num?)?.toInt() ?? 0;

    return MediaItem(
      id: song['Id'].toString(),
      title: song['Name']?.toString() ?? '',
      subtitle: artistName.isNotEmpty
          ? artistName
          : (song['Album']?.toString() ?? ''),
      streamUrl: (song['LocalUri'] ?? '').toString(),
      // Left null when there's no embedded artwork — every artwork
      // call site in the player already treats a null image as "show
      // the music-note placeholder" / "no backdrop", which is exactly
      // the fallback local songs need.
      image: artworkPath,
      audioOnly: true,
      artistName: artistName,
      runtime: Duration(microseconds: durationTicks ~/ 10),
      raw: song,
    );
  }

  static List<MediaItem> mediaItemsFromList(List songs) {
    return songs
        .map((e) => mediaItemFromLocalSong(Map<String, dynamic>.from(e)))
        .toList();
  }
}
