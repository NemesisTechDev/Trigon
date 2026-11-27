import 'addon_models.dart';
import 'link_ranking.dart';
import 'stream_rules.dart';

/// What a stream's listing says about the file behind it: size, how many
/// people are sharing it (torrents) and how long the video is.
///
/// Stremio addons put this in free text (Torrentio, for instance, writes
/// "👤 124 💾 2.4 GB ⚙️ source"), and a few also send it as proper fields.
/// Everything here is best effort: any value can be null when the listing
/// does not say.
class StreamInfo {
  final int? sizeBytes;
  final int? seeders;
  final int? peers;
  final Duration? duration;
  final bool isTorrent;

  const StreamInfo({
    this.sizeBytes,
    this.seeders,
    this.peers,
    this.duration,
    this.isTorrent = false,
  });

  Map<String, dynamic> toJson() => {
        'sizeBytes': sizeBytes,
        'seeders': seeders,
        'peers': peers,
        'durationMs': duration?.inMilliseconds,
        'isTorrent': isTorrent,
      };

  static StreamInfo fromJson(dynamic j) {
    if (j is! Map) return const StreamInfo();
    final ms = (j['durationMs'] as num?)?.toInt();
    return StreamInfo(
      sizeBytes: (j['sizeBytes'] as num?)?.toInt(),
      seeders: (j['seeders'] as num?)?.toInt(),
      peers: (j['peers'] as num?)?.toInt(),
      duration: ms == null ? null : Duration(milliseconds: ms),
      isTorrent: j['isTorrent'] == true,
    );
  }

  static StreamInfo of(AddonStream s) {
    final text = '${s.name}\n${s.description}\n${s.fileName ?? ''}';
    return StreamInfo(
      sizeBytes: s.videoSize ?? _size(text),
      seeders: s.jsonSeeders ?? _seeders(text),
      peers: s.jsonPeers ?? _peers(text),
      duration: _duration(text),
      isTorrent: s.isTorrent,
    );
  }

  // ---- size ----

  static final RegExp _sizeRe = RegExp(
    r'(\d+(?:[.,]\d+)?)\s*(TiB|TB|GiB|GB|MiB|MB)(?![A-Za-z/])(?!\s*/)',
    caseSensitive: false,
  );

  static int? _size(String text) {
    // A size next to the disk icon / the word "size" is the file's own.
    final tagged = RegExp(
      r'(?:💾|size\s*[:=]?)\s*(\d+(?:[.,]\d+)?)\s*(TiB|TB|GiB|GB|MiB|MB)'
      r'(?![A-Za-z/])',
      caseSensitive: false,
    ).firstMatch(text);
    final m = tagged ?? _sizeRe.firstMatch(text);
    if (m == null) return null;
    final value = double.tryParse(m.group(1)!.replaceAll(',', '.'));
    if (value == null) return null;
    final unit = m.group(2)!.toLowerCase();
    final mult = unit.startsWith('t')
        ? 1024.0 * 1024 * 1024 * 1024
        : unit.startsWith('g')
            ? 1024.0 * 1024 * 1024
            : 1024.0 * 1024;
    return (value * mult).round();
  }

  // ---- seeders / peers ----

  static int? _seeders(String text) {
    final m = RegExp(
      r'(?:👤|🌱|⬆️?|seeders?|seeds?)\s*[:=]?\s*(\d{1,6})',
      caseSensitive: false,
    ).firstMatch(text);
    if (m != null) return int.tryParse(m.group(1)!);
    final short =
        RegExp(r'\bS\s*[:=]\s*(\d{1,6})\b').firstMatch(text);
    return short == null ? null : int.tryParse(short.group(1)!);
  }

  static int? _peers(String text) {
    final m = RegExp(
      r'(?:👥|⬇️?|peers?|leech(?:ers?)?)\s*[:=]?\s*(\d{1,6})',
      caseSensitive: false,
    ).firstMatch(text);
    if (m != null) return int.tryParse(m.group(1)!);
    final short =
        RegExp(r'\b[PL]\s*[:=]\s*(\d{1,6})\b').firstMatch(text);
    return short == null ? null : int.tryParse(short.group(1)!);
  }

  // ---- duration ----

  static Duration? _duration(String text) {
    final clock = RegExp(
      r'(?:⏱️?|⏲️?|duration|runtime|length)\s*[:=]?\s*'
      r'(\d{1,2}):(\d{2})(?::(\d{2}))?',
      caseSensitive: false,
    ).firstMatch(text);
    if (clock != null) {
      final a = int.parse(clock.group(1)!);
      final b = int.parse(clock.group(2)!);
      final c = clock.group(3);
      return c == null
          ? Duration(minutes: a, seconds: b)
          : Duration(hours: a, minutes: b, seconds: int.parse(c));
    }
    final words = RegExp(
      r'(?:(\d{1,2})\s*h(?:ours?|rs?)?)\s*(\d{1,2})\s*m(?:in(?:ute)?s?)?',
      caseSensitive: false,
    ).firstMatch(text);
    if (words != null) {
      return Duration(
        hours: int.parse(words.group(1)!),
        minutes: int.parse(words.group(2)!),
      );
    }
    final mins = RegExp(
      r'(?:duration|runtime|length)\s*[:=]?\s*(\d{2,3})\s*m(?:in)?',
      caseSensitive: false,
    ).firstMatch(text);
    if (mins != null) return Duration(minutes: int.parse(mins.group(1)!));
    return null;
  }

  // ---- display ----

  static String formatSize(int bytes) {
    const gb = 1024 * 1024 * 1024;
    const mb = 1024 * 1024;
    if (bytes >= gb) return '${(bytes / gb).toStringAsFixed(bytes >= 10 * gb ? 1 : 2)} GB';
    if (bytes >= mb) return '${(bytes / mb).round()} MB';
    return '${(bytes / 1024).round()} KB';
  }

  static String formatDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes % 60;
    if (h > 0) return '${h}h ${m.toString().padLeft(2, '0')}m';
    return '${d.inMinutes}m';
  }

  /// Higher is better. A direct link is always available, so it outranks any
  /// torrent; torrents rank by seeders, then peers. A torrent with no
  /// seeders at all ranks last.
  int get score {
    if (!isTorrent) return 1 << 40;
    return (seeders ?? 0) * 100000 + (peers ?? 0);
  }
}

/// The best source for one quality, out of everything the addons returned.
class QualityChoice {
  const QualityChoice({
    required this.height,
    required this.best,
    required this.info,
    required this.sources,
    this.fallbacks = const [],
  });

  /// Other links of the same quality to try, best first, if [best] cannot
  /// be opened. Only filled by the Streaming-Quality-aware selection
  /// (AutoLinkSelector.qualityChoices).
  final List<AddonStream> fallbacks;

  /// 0 when the addons did not say.
  final int height;
  final AddonStream best;
  final StreamInfo info;

  /// How many sources exist for this quality (best one included).
  final int sources;
}

/// One entry per quality, highest first (unknown quality last). For each the
/// source with the best [StreamInfo.score] is chosen: a direct link if there
/// is one, otherwise the torrent with the most seeders, then peers. Ties keep
/// the addons' own order.
///
/// With a [ctx], the auto-selection rules apply as well: links that must
/// never be used (see [StreamRules]) are left out, direct links are ranked by
/// preferred file type, and torrents by seeders, then peers.
List<QualityChoice> bestPerQuality(
  List<AddonStream> streams, {
  LinkContext? ctx,
}) {
  if (ctx != null) {
    final groups = LinkRanking.groupByQuality(streams, ctx, requireSwarm: false);
    final heights = groups.keys.toList()
      ..sort((a, b) {
        if (a == 0) return 1;
        if (b == 0) return -1;
        return b.compareTo(a);
      });
    return [
      for (final h in heights)
        () {
          final g = groups[h]!;
          final best = g.directs.isNotEmpty ? g.directs.first : g.torrents.first;
          return QualityChoice(
            height: h,
            best: best.stream,
            info: best.info,
            sources: g.directs.length + g.torrents.length,
          );
        }(),
    ];
  }
  final byHeight = <int, List<AddonStream>>{};
  for (final s in streams) {
    byHeight.putIfAbsent(s.height, () => []).add(s);
  }
  final heights = byHeight.keys.toList()
    ..sort((a, b) {
      if (a == 0) return 1;
      if (b == 0) return -1;
      return b.compareTo(a);
    });
  final out = <QualityChoice>[];
  for (final h in heights) {
    final list = byHeight[h]!;
    var best = list.first;
    var bestInfo = StreamInfo.of(best);
    for (final s in list.skip(1)) {
      final info = StreamInfo.of(s);
      if (info.score > bestInfo.score) {
        best = s;
        bestInfo = info;
      }
    }
    out.add(QualityChoice(
      height: h,
      best: best,
      info: bestInfo,
      sources: list.length,
    ));
  }
  return out;
}

/// Streaming-only formats (HLS / DASH playlists) cannot be saved as one file.
bool isDownloadableStream(AddonStream s) {
  if (s.isTorrent) return true;
  final path = (Uri.tryParse(s.url)?.path ?? '').toLowerCase();
  return !path.endsWith('.m3u8') && !path.endsWith('.mpd');
}

/// The source to download for one episode at the wanted [height]: a direct
/// link when there is one, otherwise the torrent with the most seeders and
/// peers. When this episode has nothing at exactly that quality, the closest
/// lower quality is used (then the closest higher one), so one missing
/// quality does not leave a gap in the season.
///
/// With a [ctx], links that must never be used (see [StreamRules]) are left
/// out and the best one is chosen by the auto-selection ranking (direct links
/// by preferred file type, torrents by seeders, then peers).
///
/// With [preferTorrent] (the person picked a torrent), the best torrent that
/// someone is sharing is chosen at that quality; only when there is none does
/// a direct link get used.
AddonStream? pickStreamForHeight(
  List<AddonStream> all,
  int height, {
  LinkContext? ctx,
  bool preferTorrent = false,
}) {
  var usable = all.where(isDownloadableStream).toList();
  if (ctx != null) {
    usable = usable.where((s) => !StreamRules.isExcluded(s, ctx)).toList();
  }
  if (usable.isEmpty) return null;
  final heights = usable.map((s) => s.height).toSet();
  int target;
  if (heights.contains(height)) {
    target = height;
  } else {
    final lower = heights.where((h) => h > 0 && h < height).toList()..sort();
    final higher = heights.where((h) => h > height).toList()..sort();
    if (height > 0 && lower.isNotEmpty) {
      target = lower.last;
    } else if (higher.isNotEmpty) {
      target = higher.first;
    } else {
      target = heights.first;
    }
  }
  if (ctx != null) {
    final g =
        LinkRanking.groupByQuality(usable, ctx, requireSwarm: false)[target];
    if (g == null) return null;
    if (preferTorrent) {
      for (final t in g.torrents) {
        if (LinkRanking.isSuitable(t.stream, t.info)) return t.stream;
      }
    }
    if (g.directs.isNotEmpty) return g.directs.first.stream;
    return g.torrents.isEmpty ? null : g.torrents.first.stream;
  }
  var candidates = usable.where((s) => s.height == target).toList();
  if (preferTorrent) {
    final alive = candidates
        .where((s) => s.isTorrent && LinkRanking.isSuitable(s, StreamInfo.of(s)))
        .toList();
    if (alive.isNotEmpty) candidates = alive;
  }
  AddonStream? best;
  StreamInfo? bestInfo;
  for (final s in candidates) {
    final info = StreamInfo.of(s);
    if (best == null || info.score > bestInfo!.score) {
      best = s;
      bestInfo = info;
    }
  }
  return best;
}
