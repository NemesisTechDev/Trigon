import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/download_manager.dart';
import '../../services/jellyfin_services/media_service.dart';
import '../shared/nemesis_bottom_sheet.dart';

const _gold = Color(0xffD4AF37);

/// Opens the "Download Quality" sheet for a movie, in place of starting
/// the download straight away.
///
/// Only "Original" is wired up for now: it starts the download exactly
/// as the Download button always did. The converted qualities (1080p /
/// 720p / 480p / 360p) are placeholders — tapping one shows a "coming
/// soon" notice inside the sheet and leaves the sheet open so the person
/// can pick Original instead.
///
/// The converted rows are listed only when the movie's own picture is at
/// least that big (a 720p movie never offers 1080p) — see
/// [_buildOptions]. [item] is the Jellyfin movie map; it needs its
/// `MediaSources` (which the movie detail screen's item already has) for
/// the sizes, formats and resolution check.
Future<void> showMovieDownloadQualitySheet(
  BuildContext context,
  Map<String, dynamic> item,
) {
  return _openSheet(context, item: item, kind: DownloadKind.movie);
}

/// Same sheet, same rows, same behaviour as the movie one — for a single
/// episode. Episode lists deliberately don't carry `MediaSources` (see
/// MediaService.getEpisodes), so the file details are fetched once when
/// the sheet opens; if that fails the sheet still offers Original, just
/// without sizes.
Future<void> showEpisodeDownloadQualitySheet(
  BuildContext context,
  Map<String, dynamic> item,
) {
  return _openSheet(context, item: item, kind: DownloadKind.episode);
}

/// The TV show Download button's sheet: the same quality rows as the
/// movie/episode sheets, but each row shows the TOTAL size of every
/// episode of [series] at that quality, and picking one downloads all of
/// those episodes in exactly that quality (today: Original is real, the
/// converted qualities are the same "coming soon" placeholders).
///
/// Episodes that are already downloaded, or already queued/downloading,
/// are left out of both the totals and the download.
Future<void> showSeriesDownloadQualitySheet(
  BuildContext context,
  Map<String, dynamic> series,
) {
  return _openSheet(
    context,
    item: series,
    kind: DownloadKind.episode,
    batch: true,
  );
}

Future<void> _openSheet(
  BuildContext context, {
  required Map<String, dynamic> item,
  required DownloadKind kind,
  bool batch = false,
}) {
  return showNemesisBottomSheet<void>(
    context,
    initialChildSize: 0.62,
    minChildSize: 0.3,
    maxChildSize: 0.92,
    builder: (sheetContext, controller) => _VideoQualitySheet(
      item: item,
      kind: kind,
      batch: batch,
      controller: controller,
    ),
  );
}

class _VideoQualitySheet extends StatefulWidget {
  const _VideoQualitySheet({
    required this.item,
    required this.kind,
    required this.batch,
    required this.controller,
  });

  final Map<String, dynamic> item;
  final DownloadKind kind;

  /// True for the TV show button: [item] is the series and the sheet
  /// covers all of its episodes.
  final bool batch;
  final ScrollController controller;

  @override
  State<_VideoQualitySheet> createState() => _VideoQualitySheetState();
}

class _VideoQualitySheetState extends State<_VideoQualitySheet> {
  bool _showNotice = false;

  // True while the file details (single) or the episode list (batch) are
  // being fetched.
  bool _loading = false;

  // Batch only: the episode list couldn't be loaded.
  bool _failed = false;

  // Guards against a second tap starting the same batch twice.
  bool _starting = false;

  // Single item: the item as handed to DownloadManager — the original map
  // plus the file details it was missing, if they had to be fetched.
  late Map<String, dynamic> _item;

  // Batch: every downloadable episode of the series, with MediaSources.
  List<Map<String, dynamic>> _episodes = const [];

  @override
  void initState() {
    super.initState();
    _item = Map<String, dynamic>.from(widget.item);

    if (widget.batch) {
      _loading = true;
      unawaited(_loadEpisodes());
    } else if (!_hasSources(_item)) {
      _loading = true;
      unawaited(_loadDetails());
    }
  }

  static bool _hasSources(Map item) {
    final sources = item['MediaSources'];
    return sources is List && sources.isNotEmpty && sources.first is Map;
  }

  Future<void> _loadDetails() async {
    try {
      final full = await MediaService.getItem(_item['Id'].toString());
      if (!mounted) return;
      final merged = Map<String, dynamic>.from(_item);
      for (final key in const ['MediaSources', 'MediaStreams', 'RunTimeTicks']) {
        if (merged[key] == null && full[key] != null) {
          merged[key] = full[key];
        }
      }
      _item = merged;
    } catch (e) {
      // Sizes simply stay unknown; Original still works.
      debugPrint('quality sheet: file details fetch failed: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadEpisodes() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _failed = false;
      });
    }
    try {
      final episodes = await MediaService.getSeriesEpisodesForDownload(
        widget.item['Id'].toString(),
      );
      if (!mounted) return;
      setState(() {
        _episodes = episodes;
        _loading = false;
      });
    } catch (e) {
      debugPrint('quality sheet: episode list fetch failed: $e');
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
    }
  }

  /// Episodes that would actually be downloaded: not already on the
  /// device and not already queued/downloading/paused.
  List<Map<String, dynamic>> get _pending {
    final manager = DownloadManager.instance;
    return _episodes.where((e) {
      final id = e['Id']?.toString();
      if (id == null || id.isEmpty) return false;
      return !manager.isDownloaded(id) && manager.taskFor(id) == null;
    }).toList();
  }

  Future<void> _pick(_QualityOption option) async {
    if (!option.isOriginal) {
      // Placeholder qualities: nothing is downloaded. The notice stays
      // inside the sheet because a SnackBar would render underneath it.
      HapticFeedback.lightImpact();
      if (!_showNotice) setState(() => _showNotice = true);
      return;
    }

    if (widget.batch) {
      await _downloadAllOriginal();
      return;
    }

    if (widget.kind == DownloadKind.episode) {
      unawaited(DownloadManager.instance.downloadEpisode(_item));
    } else {
      unawaited(DownloadManager.instance.downloadMovie(_item));
    }
    Navigator.pop(context);
  }

  Future<void> _downloadAllOriginal() async {
    if (_starting) return;
    _starting = true;

    final pending = _pending;
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    final manager = DownloadManager.instance;

    if (pending.isEmpty) {
      navigator.pop();
      return;
    }

    // Ask for storage access once up front, instead of once per episode.
    if (!await manager.ensureStoragePermission()) {
      _starting = false;
      return;
    }

    navigator.pop();

    final count = pending.length;
    messenger?.showSnackBar(
      SnackBar(
        content: Text(
          'Downloading $count ${count == 1 ? 'episode' : 'episodes'} '
          '(Original)',
        ),
      ),
    );

    // Each call only registers the episode (the manager's own queue runs
    // them a couple at a time), so this returns quickly.
    for (final episode in pending) {
      await manager.downloadEpisode(episode);
    }
  }

  Widget _statusRow(Widget leading, String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      child: Row(
        children: [
          leading,
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(color: Colors.white54, fontSize: 13.5),
            ),
          ),
        ],
      ),
    );
  }

  Widget _optionTile(_QualityOption option) {
    return InkWell(
      onTap: () => _pick(option),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    option.title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (option.subtitle.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      option.subtitle,
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 14,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _body() {
    const spinner = SizedBox(
      width: 16,
      height: 16,
      child: CircularProgressIndicator(strokeWidth: 2, color: _gold),
    );

    if (_loading) {
      return [
        _statusRow(
          spinner,
          widget.batch ? 'Loading episodes\u2026' : 'Checking file details\u2026',
        ),
      ];
    }

    if (!widget.batch) {
      return [for (final option in _buildOptions(_item)) _optionTile(option)];
    }

    if (_failed) {
      return [
        _statusRow(
          const Icon(Icons.error_outline, color: Colors.white54, size: 20),
          'Couldn\u2019t load the episodes. Check your connection and try again.',
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: _loadEpisodes,
              child: const Text('Retry', style: TextStyle(color: _gold)),
            ),
          ),
        ),
      ];
    }

    final pending = _pending;
    final skipped = _episodes.length - pending.length;

    if (_episodes.isEmpty) {
      return [
        _statusRow(
          const Icon(Icons.info_outline, color: Colors.white54, size: 20),
          'There are no episodes to download yet.',
        ),
      ];
    }

    if (pending.isEmpty) {
      return [
        _statusRow(
          const Icon(Icons.check_circle_outline, color: _gold, size: 20),
          'Every episode is already downloaded or downloading.',
        ),
      ];
    }

    final seriesName = (widget.item['Name'] ?? '').toString();
    final count = pending.length;
    final summary = [
      if (seriesName.isNotEmpty) seriesName,
      '$count ${count == 1 ? 'episode' : 'episodes'}',
      if (skipped > 0) '$skipped already downloaded or downloading',
    ].join(_dot);

    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
        child: Text(
          summary,
          style: const TextStyle(color: Colors.white54, fontSize: 13.5),
        ),
      ),
      for (final option in _buildBatchOptions(pending)) _optionTile(option),
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
          padding: EdgeInsets.fromLTRB(20, 8, 20, 10),
          child: Text(
            'Download Quality',
            style: TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          alignment: Alignment.topCenter,
          child: _showNotice
              ? Container(
                  width: double.infinity,
                  margin: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0x1AD4AF37),
                    border: Border.all(color: const Color(0x99D4AF37)),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.info_outline, color: _gold, size: 20),
                      SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Choosing a quality is coming soon. For now, you '
                          'can download the original quality.',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 13.5,
                            height: 1.35,
                          ),
                        ),
                      ),
                    ],
                  ),
                )
              : const SizedBox(width: double.infinity, height: 0),
        ),
        ..._body(),
      ],
    );
  }
}

class _QualityOption {
  const _QualityOption({
    required this.title,
    required this.subtitle,
    required this.isOriginal,
  });

  final String title;
  final String subtitle;
  final bool isOriginal;
}

class _Tier {
  const _Tier(this.label, this.height, this.videoKbps);

  final String label;

  /// Picture height this tier stands for, in pixels.
  final int height;

  /// Video bitrate (kbps) the size estimate assumes for this tier.
  final int videoKbps;
}

const _tiers = [
  _Tier('High (1080p)', 1080, 4200),
  _Tier('Medium (720p)', 720, 2000),
  _Tier('Low (480p)', 480, 1000),
  _Tier('Mobile (360p)', 360, 450),
];

/// Audio bitrate assumed for every converted tier's size estimate.
const _assumedAudioKbps = 128;

/// What the converted rows say they'll be. Placeholder text only (nothing
/// is converted yet) — change it here once the real encode is chosen.
const _convertedFormat = 'MP4';

const _dot = ' \u2022 ';

/// What the sheet needs to know about one video file.
class _VideoInfo {
  const _VideoInfo({
    required this.seconds,
    required this.sizeBytes,
    required this.pictureHeight,
    required this.container,
  });

  final double seconds;
  final int sizeBytes;

  /// Null when the resolution isn't known at all.
  final int? pictureHeight;
  final String container;
}

_VideoInfo _probe(Map item) {
  final sources = item['MediaSources'];
  final Map? source =
      (sources is List && sources.isNotEmpty && sources.first is Map)
          ? sources.first as Map
          : null;

  final streamsRaw = source?['MediaStreams'] ?? item['MediaStreams'];
  final streams =
      streamsRaw is List ? streamsRaw.whereType<Map>().toList() : <Map>[];

  Map? video;
  for (final s in streams) {
    if (s['Type'] == 'Video') {
      video = s;
      break;
    }
  }

  final ticks =
      (item['RunTimeTicks'] as num?) ?? (source?['RunTimeTicks'] as num?);
  final seconds = ticks != null ? ticks.toDouble() / 10000000 : 0.0;

  final sizeBytes = (source?['Size'] as num?)?.toInt() ?? 0;

  // A tier is offered only if the picture is at least that big.
  // Widescreen films are letterboxed, so a 1080p film is often 1920x804:
  // its height alone would hide 1080p, so the picture size is the larger
  // of the real height and the height a 16:9 frame of the same width
  // would have (1920 wide -> 1080). A small tolerance (applied by the
  // callers) absorbs rips that are cropped a few pixels short of the
  // nominal size. If the resolution isn't known at all, nothing can be
  // confirmed as available.
  final width = (video?['Width'] as num?)?.toInt();
  final height = (video?['Height'] as num?)?.toInt();

  int? pictureHeight;
  if (width != null || height != null) {
    final fromWidth = width != null ? (width * 9 / 16).round() : 0;
    final real = height ?? 0;
    pictureHeight = real > fromWidth ? real : fromWidth;
  }

  return _VideoInfo(
    seconds: seconds,
    sizeBytes: sizeBytes,
    pictureHeight: pictureHeight,
    container: _containerLabel(source?['Container']?.toString()),
  );
}

/// Estimated size of [seconds] of video at [tier]'s assumed bitrates.
int _tierBytes(_Tier tier, double seconds) =>
    ((tier.videoKbps + _assumedAudioKbps) * 1000 / 8 * seconds).round();

/// Rows for a single movie / episode.
List<_QualityOption> _buildOptions(Map<String, dynamic> item) {
  final info = _probe(item);

  // ── Original ──────────────────────────────────────────────────────────
  final originalParts = [
    if (info.sizeBytes > 0) _formatSize(info.sizeBytes),
    info.container,
  ].where((p) => p.isNotEmpty);

  final options = <_QualityOption>[
    _QualityOption(
      title: 'Original',
      subtitle: originalParts.join(_dot),
      isOriginal: true,
    ),
  ];

  // ── Converted (placeholder) rows ──────────────────────────────────────
  final pictureHeight = info.pictureHeight;
  if (pictureHeight != null) {
    for (final tier in _tiers) {
      if (pictureHeight < tier.height * 0.95) continue;

      final parts = [
        if (info.seconds > 0)
          '~${_formatSize(_tierBytes(tier, info.seconds))}',
        _convertedFormat,
      ];

      options.add(
        _QualityOption(
          title: tier.label,
          subtitle: parts.join(_dot),
          isOriginal: false,
        ),
      );
    }
  }

  return options;
}

/// Rows for a whole show: the same qualities, each with the TOTAL size of
/// [episodes] at that quality.
///
/// Every episode is downloaded in the one quality picked, so a converted
/// tier is only offered when the smallest episode picture in the set is
/// at least that big (a show with one 720p episode never offers 1080p).
/// Original's total is the sum of the real file sizes; if some episodes
/// don't report one it's topped up at the average bytes-per-second of the
/// ones that do and shown as an estimate (~). Converted totals are always
/// estimates, like the single-episode rows.
List<_QualityOption> _buildBatchOptions(List<Map<String, dynamic>> episodes) {
  final infos = episodes.map(_probe).toList();
  final count = infos.length;

  // ── Original ──────────────────────────────────────────────────────────
  var knownBytes = 0;
  var knownSeconds = 0.0;
  var knownCount = 0;
  for (final info in infos) {
    if (info.sizeBytes > 0) {
      knownBytes += info.sizeBytes;
      knownSeconds += info.seconds;
      knownCount++;
    }
  }

  var originalBytes = knownBytes;
  var originalEstimated = false;
  if (knownCount < count) {
    originalEstimated = true;
    if (knownCount > 0 && knownSeconds > 0) {
      final bytesPerSecond = knownBytes / knownSeconds;
      for (final info in infos) {
        if (info.sizeBytes <= 0 && info.seconds > 0) {
          originalBytes += (bytesPerSecond * info.seconds).round();
        }
      }
    }
  }

  String uniform(Iterable<String> values) {
    final distinct = values.where((v) => v.isNotEmpty).toSet();
    return distinct.length == 1 ? distinct.first : '';
  }

  final originalParts = [
    if (originalBytes > 0)
      '${originalEstimated ? '~' : ''}${_formatSize(originalBytes)}',
    uniform(infos.map((i) => i.container)),
  ].where((p) => p.isNotEmpty);

  final options = <_QualityOption>[
    _QualityOption(
      title: 'Original',
      subtitle: originalParts.join(_dot),
      isOriginal: true,
    ),
  ];

  // ── Converted (placeholder) rows ──────────────────────────────────────
  int? smallestPicture;
  var totalSeconds = 0.0;
  for (final info in infos) {
    totalSeconds += info.seconds;
    final h = info.pictureHeight;
    if (h != null && (smallestPicture == null || h < smallestPicture)) {
      smallestPicture = h;
    }
  }

  if (smallestPicture != null) {
    for (final tier in _tiers) {
      if (smallestPicture < tier.height * 0.95) continue;

      final parts = [
        if (totalSeconds > 0) '~${_formatSize(_tierBytes(tier, totalSeconds))}',
        _convertedFormat,
      ];

      options.add(
        _QualityOption(
          title: tier.label,
          subtitle: parts.join(_dot),
          isOriginal: false,
        ),
      );
    }
  }

  return options;
}

/// "2.3 GB" / "1010.5 MB" — binary units, one decimal, matching how the
/// rest of the app sizes files.
String _formatSize(int bytes) {
  const mb = 1024 * 1024;
  const gb = mb * 1024;
  if (bytes >= gb) return '${(bytes / gb).toStringAsFixed(1)} GB';
  return '${(bytes / mb).toStringAsFixed(1)} MB';
}

const _knownContainers = {
  'mp4': 'MP4',
  'm4v': 'M4V',
  'mkv': 'MKV',
  'matroska': 'MKV',
  'webm': 'WEBM',
  'avi': 'AVI',
  'mov': 'MOV',
  'ts': 'TS',
  'mpegts': 'TS',
  'wmv': 'WMV',
  'asf': 'WMV',
  'flv': 'FLV',
};

/// Jellyfin's `Container` is sometimes a comma-separated list (an MP4
/// can come back as "mov,mp4,m4a,3gp,3g2,mj2"), so take the first entry
/// that's a recognisable video container instead of printing the list.
String _containerLabel(String? container) {
  if (container == null || container.trim().isEmpty) return '';
  final tokens = container
      .toLowerCase()
      .split(',')
      .map((t) => t.trim())
      .where((t) => t.isNotEmpty)
      .toList();

  // "mov,mp4,..." is MP4 in practice; prefer it over the leading "mov".
  if (tokens.contains('mp4')) return 'MP4';

  for (final token in tokens) {
    final label = _knownContainers[token];
    if (label != null) return label;
  }
  return tokens.isNotEmpty ? tokens.first.toUpperCase() : '';
}
