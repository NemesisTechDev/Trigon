import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/download_manager.dart';
import '../../services/jellyfin_services/media_service.dart';
import '../shared/nemesis_bottom_sheet.dart';

const _gold = Color(0xffD4AF37);

/// Opens the "Download Quality" sheet for a whole list of songs — the
/// artist / album / playlist Download button.
///
/// Rows are exactly the ones in a single song's Download dropdown
/// (song_options_sheet.dart): Original (real bitrate, FLAC/MP3/... format,
/// "BEST QUALITY" when lossless), then 320 / 256 / 192 / 128 kbps MP3 —
/// except each row's size is the TOTAL for every song in [songs] at that
/// quality. Picking a row downloads all of those songs in that quality.
///
/// Same rule as the single-song dropdown: a lossy song is never
/// "converted" to a bitrate at or above its own (that can only make it
/// bigger or worse), so such a song keeps its original file for that row
/// and the row says how many did. Songs already downloaded or already
/// queued/downloading are left out of the totals and the download.
Future<void> showSongsDownloadQualitySheet(
  BuildContext context,
  List songs,
) {
  return showNemesisBottomSheet<void>(
    context,
    initialChildSize: 0.55,
    minChildSize: 0.3,
    maxChildSize: 0.9,
    builder: (sheetContext, controller) => _SongsQualitySheet(
      songs: songs
          .whereType<Map>()
          .map((s) => Map<String, dynamic>.from(s))
          .toList(),
      controller: controller,
    ),
  );
}

class _SongsQualitySheet extends StatefulWidget {
  const _SongsQualitySheet({required this.songs, required this.controller});

  final List<Map<String, dynamic>> songs;
  final ScrollController controller;

  @override
  State<_SongsQualitySheet> createState() => _SongsQualitySheetState();
}

class _SongsQualitySheetState extends State<_SongsQualitySheet> {
  // Song lists don't always carry file size/bitrate (MediaSources); the
  // ones that don't are looked up in one go when the sheet opens.
  bool _loading = false;
  bool _starting = false;
  final Map<String, Map<String, dynamic>> _fetched = {};

  // Fixed when the sheet opens: songs that aren't already downloaded or
  // on their way, and how many were left out.
  late final List<Map<String, dynamic>> _pending;
  late final int _skipped;

  @override
  void initState() {
    super.initState();

    final manager = DownloadManager.instance;
    final pending = <Map<String, dynamic>>[];
    var skipped = 0;
    final seen = <String>{};
    for (final song in widget.songs) {
      final id = song['Id']?.toString();
      if (id == null || id.isEmpty) continue;
      if (!seen.add(id)) continue;
      if (manager.isDownloaded(id) || manager.taskFor(id) != null) {
        skipped++;
        continue;
      }
      pending.add(song);
    }
    _pending = pending;
    _skipped = skipped;

    if (_pending.any((s) => !_hasFileInfo(s))) {
      _loading = true;
      unawaited(_loadDetails());
    }
  }

  static bool _hasFileInfo(Map song) {
    final sources = song['MediaSources'];
    return sources is List &&
        sources.isNotEmpty &&
        sources.first is Map &&
        sources.first['Size'] is num;
  }

  Future<void> _loadDetails() async {
    final missing = _pending
        .where((s) => !_hasFileInfo(s))
        .map((s) => s['Id'].toString())
        .toList();

    // Chunked so the ids never push the URL past a server/proxy limit.
    const chunkSize = 50;
    final requests = <Future<void>>[];
    for (var i = 0; i < missing.length; i += chunkSize) {
      final chunk = missing.sublist(
        i,
        i + chunkSize > missing.length ? missing.length : i + chunkSize,
      );
      requests.add(() async {
        try {
          final items = await MediaService.getItems(
            ids: chunk.join(','),
            limit: chunk.length,
            fields: 'MediaSources,RunTimeTicks',
          );
          for (final item in items) {
            if (item is Map && item['Id'] != null) {
              _fetched[item['Id'].toString()] =
                  Map<String, dynamic>.from(item);
            }
          }
        } catch (e) {
          // Sizes for these songs simply stay unknown; every row still
          // works.
          debugPrint('song quality sheet: file details fetch failed: $e');
        }
      }());
    }

    await Future.wait(requests);
    if (mounted) setState(() => _loading = false);
  }

  /// The song as handed to DownloadManager: the original map plus the
  /// file details it was missing, if they had to be fetched. MediaSources
  /// is also what DownloadManager reads to give an original-quality file
  /// its real extension (.flac, not a default .mp3).
  Map<String, dynamic> _withFileInfo(Map<String, dynamic> song) {
    final fetched = _fetched[song['Id'].toString()];
    if (fetched == null) return song;

    final merged = Map<String, dynamic>.from(song);
    for (final key in const ['MediaSources', 'MediaStreams', 'RunTimeTicks']) {
      if (merged[key] == null && fetched[key] != null) {
        merged[key] = fetched[key];
      }
    }
    return merged;
  }

  Future<void> _start(_Option option) async {
    if (_starting) return;
    _starting = true;

    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    final manager = DownloadManager.instance;

    // Ask for storage access once up front, instead of once per song.
    if (!await manager.ensureStoragePermission()) {
      _starting = false;
      return;
    }

    final songs = [for (final s in _pending) _withFileInfo(s)];
    final count = songs.length;
    final detail =
        option.kbps == null ? 'Original' : '${option.kbps} kbps MP3';

    navigator.pop();
    messenger?.showSnackBar(
      SnackBar(
        content: Text(
          'Downloading $count ${count == 1 ? 'song' : 'songs'} ($detail)',
        ),
      ),
    );

    // Each call only registers the song (the manager's own queue runs
    // them a couple at a time), so this returns quickly.
    for (final song in songs) {
      final kbps = option.kbps;
      final convert = kbps != null && _SongInfo.of(song).convertsTo(kbps);
      await manager.downloadSong(song, targetKbps: convert ? kbps : null);
    }
  }

  Widget _optionRow(_Option option) {
    final details = <String>[
      if (option.bytes != null)
        '${option.estimated ? '~' : ''}${_formatSize(option.bytes!)} total',
      option.format,
      if (option.note.isNotEmpty) option.note,
    ];

    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 20),
      title: Row(
        children: [
          Flexible(
            child: Text(
              option.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white),
            ),
          ),
          if (option.bestQuality) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: const Color(0x26D4AF37),
                border: Border.all(color: _gold, width: 0.8),
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Text(
                'BEST QUALITY',
                style: TextStyle(
                  color: _gold,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.4,
                ),
              ),
            ),
          ],
        ],
      ),
      subtitle: Text(
        details.join(' \u00b7 '),
        style: const TextStyle(color: Colors.white54, fontSize: 12),
      ),
      onTap: () => _start(option),
    );
  }

  List<Widget> _body() {
    if (_loading) {
      return const [
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.symmetric(horizontal: 20),
          title: Row(
            children: [
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2, color: _gold),
              ),
              SizedBox(width: 12),
              Text(
                'Checking file details\u2026',
                style: TextStyle(color: Colors.white54, fontSize: 13),
              ),
            ],
          ),
        ),
      ];
    }

    if (_pending.isEmpty) {
      return const [
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.symmetric(horizontal: 20),
          title: Text(
            'Every song is already downloaded or downloading.',
            style: TextStyle(color: Colors.white54, fontSize: 13),
          ),
        ),
      ];
    }

    final count = _pending.length;
    final summary = [
      '$count ${count == 1 ? 'song' : 'songs'}',
      if (_skipped > 0) '$_skipped already downloaded or downloading',
    ].join(' \u00b7 ');

    final infos = [for (final s in _pending) _SongInfo.of(_withFileInfo(s))];

    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
        child: Text(
          summary,
          style: const TextStyle(color: Colors.white54, fontSize: 13),
        ),
      ),
      for (final option in _buildOptions(infos)) _optionRow(option),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      controller: widget.controller,
      padding: const EdgeInsets.only(bottom: 12),
      children: [
        const NemesisSheetDragHandle(topMargin: 10, bottomMargin: 8),
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 8, 20, 6),
          child: Text(
            'Download Quality',
            style: TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        ..._body(),
      ],
    );
  }
}

/// One row of the sheet.
class _Option {
  const _Option({
    required this.kbps,
    required this.title,
    required this.format,
    required this.bytes,
    required this.estimated,
    required this.bestQuality,
    this.note = '',
  });

  /// Target MP3 bitrate, or null for the original files untouched.
  final int? kbps;
  final String title;
  final String format;

  /// Total for all songs, null when no song's size could be worked out.
  final int? bytes;

  /// True when [bytes] includes guesses (bitrate x duration, or songs
  /// whose size is unknown) rather than only real file sizes.
  final bool estimated;
  final bool bestQuality;

  /// Extra detail, e.g. how many songs keep their original file.
  final String note;
}

const _lowerQualities = [320, 256, 192, 128];

const _knownAudioFormats = {
  'flac', 'mp3', 'm4a', 'aac', 'ogg', 'opus', 'wav', 'wma', 'alac', //
  'aiff', 'ape', 'wv', 'mka', 'webma',
};

const _losslessCodecs = {'flac', 'alac', 'ape', 'wavpack', 'tta'};

/// What the sheet needs to know about one song's file — the same facts
/// song_options_sheet.dart reads for a single song.
class _SongInfo {
  const _SongInfo({
    required this.seconds,
    required this.sizeBytes,
    required this.originalKbps,
    required this.lossless,
    required this.format,
  });

  final double seconds;

  /// 0 when unknown.
  final int sizeBytes;
  final int? originalKbps;
  final bool lossless;
  final String format;

  factory _SongInfo.of(Map song) {
    final sources = song['MediaSources'];
    final Map? source =
        (sources is List && sources.isNotEmpty && sources.first is Map)
            ? sources.first as Map
            : null;

    Map? audioStream;
    final streams = source?['MediaStreams'] ?? song['MediaStreams'];
    if (streams is List) {
      for (final stream in streams) {
        if (stream is Map && stream['Type'] == 'Audio') {
          audioStream = stream;
          break;
        }
      }
    }

    final ticks =
        (song['RunTimeTicks'] as num?) ?? (source?['RunTimeTicks'] as num?);
    final seconds = ticks != null ? ticks.toDouble() / 10000000 : 0.0;

    final sizeBytes = (source?['Size'] as num?)?.toInt() ?? 0;

    int? originalKbps;
    final bps =
        (audioStream?['BitRate'] as num?) ?? (source?['Bitrate'] as num?);
    if (bps != null && bps > 0) {
      originalKbps = (bps / 1000).round();
    } else if (sizeBytes > 0 && seconds > 0) {
      originalKbps = (sizeBytes * 8 / seconds / 1000).round();
    }

    final codec = (audioStream?['Codec'] ?? '').toString().toLowerCase();
    final container = (source?['Container'] ?? '').toString().toLowerCase();

    final lossless = _losslessCodecs.contains(codec) ||
        codec.startsWith('pcm') ||
        const {'flac', 'wav', 'aiff'}.contains(container);

    return _SongInfo(
      seconds: seconds,
      sizeBytes: sizeBytes,
      originalKbps: originalKbps,
      lossless: lossless,
      format: _originalFormat(container, codec),
    );
  }

  /// Whether converting to [kbps] MP3 makes sense for this song: always for
  /// a lossless one, otherwise only to a bitrate below its own.
  bool convertsTo(int kbps) =>
      lossless || originalKbps == null || kbps < originalKbps!;

  /// The original file's size, and whether it's a guess.
  ({int? bytes, bool estimated}) get originalBytes {
    if (sizeBytes > 0) return (bytes: sizeBytes, estimated: false);
    final kbps = originalKbps;
    if (kbps != null && seconds > 0) {
      return (bytes: (kbps * 1000 / 8 * seconds).round(), estimated: true);
    }
    return (bytes: null, estimated: true);
  }
}

List<_Option> _buildOptions(List<_SongInfo> songs) {
  final count = songs.length;

  // ── Original ──────────────────────────────────────────────────────────
  var originalTotal = 0;
  var originalHasGuess = false;
  var originalAnyKnown = false;
  for (final song in songs) {
    final original = song.originalBytes;
    if (original.bytes != null) {
      originalTotal += original.bytes!;
      originalAnyKnown = true;
    }
    if (original.estimated) originalHasGuess = true;
  }

  final kbpsValues = songs.map((s) => s.originalKbps).toSet();
  final sameKbps = kbpsValues.length == 1 && kbpsValues.first != null;

  final formats = songs.map((s) => s.format).toSet().toList()..sort();
  final String originalFormat;
  if (formats.length == 1) {
    originalFormat = formats.first;
  } else if (formats.length <= 3) {
    originalFormat = formats.join('/');
  } else {
    originalFormat = 'Mixed formats';
  }

  final options = <_Option>[
    _Option(
      kbps: null,
      title: sameKbps ? 'Original \u00b7 ${kbpsValues.first} kbps' : 'Original',
      format: originalFormat,
      bytes: originalAnyKnown ? originalTotal : null,
      estimated: originalHasGuess,
      bestQuality: songs.every((s) => s.lossless),
    ),
  ];

  // ── Converted MP3s ────────────────────────────────────────────────────
  for (final kbps in _lowerQualities) {
    var converted = 0;
    var total = 0;
    var anyKnown = false;
    var hasGuess = false;

    for (final song in songs) {
      if (song.convertsTo(kbps)) {
        converted++;
        if (song.seconds > 0) {
          total += (kbps * 1000 / 8 * song.seconds).round();
          anyKnown = true;
        }
        hasGuess = true; // a converted file's real size is only known later
      } else {
        final original = song.originalBytes;
        if (original.bytes != null) {
          total += original.bytes!;
          anyKnown = true;
        }
        if (original.estimated) hasGuess = true;
      }
    }

    // Nothing would be converted to this bitrate (every song is already at
    // or below it) — same as the single-song dropdown hiding the row.
    if (converted == 0) continue;

    final kept = count - converted;
    options.add(
      _Option(
        kbps: kbps,
        title: '$kbps kbps',
        format: 'MP3',
        bytes: anyKnown ? total : null,
        estimated: hasGuess,
        bestQuality: false,
        note: kept > 0
            ? '$kept ${kept == 1 ? 'song keeps' : 'songs keep'} '
                'its original file'
            : '',
      ),
    );
  }

  return options;
}

/// Display name for the original file's format. Jellyfin's `Container`
/// can be a comma-separated list for some files (e.g. an .m4a reports
/// "mov,mp4,m4a,..."), so pick the first entry that's an actual audio
/// format rather than showing the whole list.
String _originalFormat(String container, String codec) {
  final tokens = container
      .split(',')
      .map((t) => t.trim())
      .where((t) => t.isNotEmpty)
      .toList();

  for (final token in tokens) {
    if (_knownAudioFormats.contains(token)) return token.toUpperCase();
  }
  if (_knownAudioFormats.contains(codec)) return codec.toUpperCase();
  if (tokens.isNotEmpty) return tokens.first.toUpperCase();
  if (codec.isNotEmpty) return codec.toUpperCase();
  return 'Original file';
}

/// "412 MB" / "1.4 GB" — binary units, like the rest of the app.
String _formatSize(int bytes) {
  final mb = bytes / (1024 * 1024);
  if (mb >= 1024) return '${(mb / 1024).toStringAsFixed(1)} GB';
  return '${mb >= 100 ? mb.toStringAsFixed(0) : mb.toStringAsFixed(1)} MB';
}
