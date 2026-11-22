import 'dart:convert';
import 'dart:io';

/// Reading and normalising subtitle TEXT, whatever file it came from.
///
/// Why this exists: a subtitle saved next to a video can be UTF-8, UTF-8 with
/// a byte-order mark, UTF-16 or a legacy Windows code page, and its cues can be
/// SRT, WebVTT or ASS/SSA. The player hands text to mpv as SRT and also draws
/// its own cues from that SRT, and Cast/DLNA need WebVTT made from the same
/// SRT. Everything therefore goes through [toSrt] first.
///
/// (The old `PlayerManager._webvttToSrt` only understood WebVTT and returned an
/// EMPTY string for real SRT text, which is what a downloaded `.srt` sidecar
/// is. The track was "selected" with zero cues, so nothing was drawn.)
class SubtitleText {
  SubtitleText._();

  // Windows-1252 bytes 0x80-0x9F (the only part that differs from Latin-1).
  static const List<int> _cp1252High = [
    0x20AC, 0x0081, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, //
    0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008D, 0x017D, 0x008F, //
    0x0090, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, //
    0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x009D, 0x017E, 0x0178, //
  ];

  /// Bytes -> text. Understands UTF-8 (with or without BOM), UTF-16 LE/BE
  /// (BOM) and falls back to Windows-1252 when the bytes are not valid UTF-8.
  static String decode(List<int> bytes) {
    if (bytes.isEmpty) return '';
    if (bytes.length >= 3 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF) {
      return utf8.decode(bytes.sublist(3), allowMalformed: true);
    }
    if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
      return _utf16(bytes, 2, littleEndian: true);
    }
    if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
      return _utf16(bytes, 2, littleEndian: false);
    }
    try {
      return utf8.decode(bytes);
    } on FormatException {
      final b = StringBuffer();
      for (final v in bytes) {
        if (v >= 0x80 && v <= 0x9F) {
          b.writeCharCode(_cp1252High[v - 0x80]);
        } else {
          b.writeCharCode(v);
        }
      }
      return b.toString();
    }
  }

  static String _utf16(List<int> bytes, int from, {required bool littleEndian}) {
    final units = <int>[];
    for (var i = from; i + 1 < bytes.length; i += 2) {
      units.add(littleEndian
          ? (bytes[i] | (bytes[i + 1] << 8))
          : ((bytes[i] << 8) | bytes[i + 1]));
    }
    return String.fromCharCodes(units);
  }

  static final RegExp _timing = RegExp(
    r'(?:(\d+):)?(\d{1,2}):(\d{2})[,.](\d{1,3})\s*-->\s*(?:(\d+):)?(\d{1,2}):(\d{2})[,.](\d{1,3})',
  );

  static int _ms(String? h, String m, String s, String f) =>
      (int.tryParse(h ?? '0') ?? 0) * 3600000 +
      int.parse(m) * 60000 +
      int.parse(s) * 1000 +
      int.parse(f.padRight(3, '0').substring(0, 3));

  static String _two(int v) => v.toString().padLeft(2, '0');

  static String _stamp(int ms) {
    final h = ms ~/ 3600000;
    final m = (ms ~/ 60000) % 60;
    final s = (ms ~/ 1000) % 60;
    final f = ms % 1000;
    return '${_two(h)}:${_two(m)}:${_two(s)},${f.toString().padLeft(3, '0')}';
  }

  // WebVTT-only markup that mpv's SRT reader would print literally.
  static final RegExp _vttTags = RegExp(
    r'</?c(?:\.[^>]*)?>|</?v(?:[ .][^>]*)?>|<\d{1,2}:\d{2}(?::\d{2})?[.,]\d{2,3}>|</?ruby>|</?rt>|</?lang(?: [^>]*)?>',
  );

  /// Any supported subtitle text (SRT, WebVTT, ASS/SSA) -> clean SRT with
  /// renumbered cues and `HH:MM:SS,mmm` times. Returns '' when the text holds
  /// no cue at all.
  static String toSrt(String input) {
    final text = input
        .replaceAll('﻿', '')
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n');
    if (text.trim().isEmpty) return '';

    if (!text.contains('-->') &&
        RegExp(r'^\s*Dialogue\s*:', multiLine: true, caseSensitive: false)
            .hasMatch(text)) {
      return _assToSrt(text);
    }
    return _cuesToSrt(text);
  }

  static String _cuesToSrt(String text) {
    final out = StringBuffer();
    var n = 0;
    for (final block in text.split(RegExp(r'\n[ \t]*\n'))) {
      final lines = block.split('\n');
      final ti = lines.indexWhere((l) => l.contains('-->'));
      if (ti < 0) continue;
      final m = _timing.firstMatch(lines[ti]);
      if (m == null) continue;
      final start = _ms(m.group(1), m.group(2)!, m.group(3)!, m.group(4)!);
      final end = _ms(m.group(5), m.group(6)!, m.group(7)!, m.group(8)!);

      final body = lines
          .sublist(ti + 1)
          .map((l) => l.replaceAll(_vttTags, '').trimRight())
          .where((l) => l.isNotEmpty)
          .toList();
      if (body.isEmpty) continue;

      n++;
      out
        ..writeln(n)
        ..writeln('${_stamp(start)} --> ${_stamp(end < start ? start : end)}')
        ..writeln(body.join('\n'))
        ..writeln();
    }
    return out.toString();
  }

  static List<String> _splitMax(String s, int n) {
    final out = <String>[];
    var from = 0;
    for (var k = 0; k < n - 1; k++) {
      final i = s.indexOf(',', from);
      if (i < 0) break;
      out.add(s.substring(from, i));
      from = i + 1;
    }
    out.add(s.substring(from));
    return out;
  }

  static int? _assTime(String s) {
    final m = RegExp(r'^\s*(\d+):(\d{1,2}):(\d{1,2})[.:](\d{1,3})\s*$')
        .firstMatch(s);
    if (m == null) return null;
    final frac = m.group(4)!;
    // ASS uses centiseconds ("0:00:01.50"); tolerate 1 or 3 digits too.
    final ms = frac.length == 2
        ? int.parse(frac) * 10
        : int.parse(frac.padRight(3, '0').substring(0, 3));
    return int.parse(m.group(1)!) * 3600000 +
        int.parse(m.group(2)!) * 60000 +
        int.parse(m.group(3)!) * 1000 +
        ms;
  }

  static String _assToSrt(String text) {
    var startI = 1, endI = 2, textI = 9, fields = 10;
    var inEvents = false;
    final cues = <({int start, int end, String text})>[];

    for (final raw in text.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      if (line.startsWith('[')) {
        inEvents = line.toLowerCase() == '[events]';
        continue;
      }
      if (!inEvents) continue;

      final lower = line.toLowerCase();
      if (lower.startsWith('format:')) {
        final cols = line
            .substring(7)
            .split(',')
            .map((c) => c.trim().toLowerCase())
            .toList();
        final s = cols.indexOf('start');
        final e = cols.indexOf('end');
        final t = cols.indexOf('text');
        if (s >= 0 && e >= 0 && t >= 0) {
          startI = s;
          endI = e;
          textI = t;
          fields = cols.length;
        }
        continue;
      }
      if (!lower.startsWith('dialogue:')) continue;

      final parts = _splitMax(line.substring(9).trimLeft(), fields);
      final need = [startI, endI, textI].reduce((a, b) => a > b ? a : b);
      if (parts.length <= need) continue;

      final start = _assTime(parts[startI]);
      final end = _assTime(parts[endI]);
      if (start == null || end == null) continue;

      final body = parts[textI]
          .replaceAll(RegExp(r'\{[^}]*\}'), '')
          .replaceAll(r'\N', '\n')
          .replaceAll(r'\n', '\n')
          .replaceAll(r'\h', ' ')
          .split('\n')
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty)
          .join('\n');
      if (body.isEmpty) continue;
      cues.add((start: start, end: end < start ? start : end, text: body));
    }

    cues.sort((a, b) => a.start.compareTo(b.start));
    final out = StringBuffer();
    for (var i = 0; i < cues.length; i++) {
      out
        ..writeln(i + 1)
        ..writeln('${_stamp(cues[i].start)} --> ${_stamp(cues[i].end)}')
        ..writeln(cues[i].text)
        ..writeln();
    }
    return out.toString();
  }
}

/// Finding the subtitle files that sit next to a video (same folder, file name
/// starting with the video's own name: `Movie (2020).mkv` ->
/// `Movie (2020).en.srt`, `Movie (2020).srt`) and reading them.
class SidecarSubtitles {
  SidecarSubtitles._();

  static const List<String> extensions = ['srt', 'vtt', 'ass', 'ssa', 'sub'];

  static String basename(String path) {
    final slash = path.lastIndexOf(RegExp(r'[\\/]'));
    return slash >= 0 ? path.substring(slash + 1) : path;
  }

  /// File name without its last extension.
  static String stemOf(String fileName) {
    final name = basename(fileName);
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  static bool isSubtitleName(String fileName) {
    final dot = fileName.lastIndexOf('.');
    if (dot <= 0) return false;
    return extensions.contains(fileName.substring(dot + 1).toLowerCase());
  }

  /// True when [fileName] is a subtitle that belongs to the video called
  /// [videoStem]: the same name, optionally followed by `.something`
  /// (language, `forced`, ...).
  static bool matches(String fileName, String videoStem) {
    if (videoStem.isEmpty || !isSubtitleName(fileName)) return false;
    final n = basename(fileName).toLowerCase();
    final s = videoStem.toLowerCase();
    final base = n.substring(0, n.lastIndexOf('.'));
    return base == s || base.startsWith('$s.');
  }

  /// "Movie (2020).en.srt" for video stem "Movie (2020)" -> "en".
  /// Empty when the subtitle carries no extra tag.
  static String tagOf(String subtitleFileName, String videoStem) {
    final base = stemOf(subtitleFileName);
    if (videoStem.isNotEmpty &&
        base.length > videoStem.length &&
        base.toLowerCase().startsWith('${videoStem.toLowerCase()}.')) {
      return base.substring(videoStem.length + 1);
    }
    return '';
  }

  static bool _isEnglishName(String fileName, String stem) {
    final t = tagOf(fileName, stem).toLowerCase();
    return t == 'en' ||
        t == 'eng' ||
        t.startsWith('en.') ||
        t.startsWith('en-') ||
        t.startsWith('en_') ||
        t.startsWith('eng.') ||
        t.startsWith('english');
  }

  static int _order(String a, String b, String stem) {
    final ea = _isEnglishName(a, stem) ? 0 : 1;
    final eb = _isEnglishName(b, stem) ? 0 : 1;
    if (ea != eb) return ea - eb;
    return a.toLowerCase().compareTo(b.toLowerCase());
  }

  /// Synchronous folder listing — only used for small, local folders.
  static List<File> findSync(String videoPath) {
    try {
      final file = File(videoPath);
      final dir = file.parent;
      if (!dir.existsSync()) return const [];
      final stem = stemOf(videoPath);
      final found = dir
          .listSync(followLinks: false)
          .whereType<File>()
          .where((f) => matches(basename(f.path), stem))
          .toList()
        ..sort((a, b) => _order(basename(a.path), basename(b.path), stem));
      return found;
    } catch (_) {
      return const [];
    }
  }

  static Future<List<File>> find(String videoPath) async {
    try {
      final dir = File(videoPath).parent;
      if (!await dir.exists()) return const [];
      final stem = stemOf(videoPath);
      final found = <File>[];
      await for (final e in dir.list(followLinks: false)) {
        if (e is File && matches(basename(e.path), stem)) found.add(e);
      }
      found.sort((a, b) => _order(basename(a.path), basename(b.path), stem));
      return found;
    } catch (_) {
      return const [];
    }
  }

  /// Reads [paths] into the `{content, fileName}` maps PlayerManager's sidecar
  /// loader (`raw['SidecarSubtitles']`) and the cast code use. `content` is
  /// normalised SRT; files with no readable cue are dropped.
  ///
  /// [shortNames] makes `fileName` just the language tag ("EN") instead of the
  /// whole file name.
  static Future<List<Map<String, String>>> readFiles(
    List<String> paths, {
    String? videoStem,
    bool shortNames = false,
  }) async {
    final out = <Map<String, String>>[];
    for (final path in paths) {
      try {
        final file = File(path);
        if (!await file.exists()) continue;
        if (await file.length() > 6 * 1024 * 1024) continue;
        final srt = SubtitleText.toSrt(SubtitleText.decode(await file.readAsBytes()));
        if (srt.trim().isEmpty) continue;

        final name = basename(path);
        var label = name;
        if (shortNames) {
          final tag = tagOf(name, videoStem ?? '');
          label = tag.isNotEmpty ? tag.toUpperCase() : 'Subtitle';
        }
        out.add({'content': srt, 'fileName': label});
      } catch (_) {
        // Unreadable file: skip it, the others still count.
      }
    }
    return out;
  }

  /// Every subtitle belonging to the video at [videoPath], ready to use.
  static Future<List<Map<String, String>>> loadForVideo(
    String videoPath, {
    bool shortNames = false,
  }) async {
    final files = await find(videoPath);
    return readFiles(
      files.map((f) => f.path).toList(),
      videoStem: stemOf(videoPath),
      shortNames: shortNames,
    );
  }

  /// Best-effort conversion of a `content://` / `file://` URI (what Android's
  /// "Open with" hands over) to a real file path. Null when the URI gives no
  /// way to know the path (a MediaStore id, another app's private provider).
  static String? pathFromUri(String uri) {
    if (uri.startsWith('/')) return uri;
    final u = Uri.tryParse(uri);
    if (u == null) return null;
    if (u.scheme == 'file') {
      try {
        return u.toFilePath();
      } catch (_) {
        return null;
      }
    }
    if (u.scheme != 'content') return null;

    final segs = u.pathSegments;
    final di = segs.lastIndexOf('document');
    if (di < 0 || di + 1 >= segs.length) return null;
    final docId = segs.sublist(di + 1).join('/');

    switch (u.authority) {
      case 'com.android.externalstorage.documents':
        final colon = docId.indexOf(':');
        if (colon < 0) return null;
        final volume = docId.substring(0, colon);
        final rel = docId.substring(colon + 1);
        final base =
            volume == 'primary' ? '/storage/emulated/0' : '/storage/$volume';
        return rel.isEmpty ? base : '$base/$rel';
      case 'com.android.providers.downloads.documents':
        return docId.startsWith('raw:') ? docId.substring(4) : null;
    }
    return null;
  }
}
