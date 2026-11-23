import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../addons/addon_manager.dart';
import '../../addons/addon_models.dart';
import '../../addons/link_ranking.dart';
import '../../addons/show_size_estimate.dart';
import '../../addons/stream_info.dart';
import '../../addons/stream_rules.dart';
import '../../addons/stream_summary.dart';
import '../../catalog/catalog_models.dart';
import '../../catalog/tmdb_catalog_service.dart';
import '../../services/download_manager.dart';
import '../../virtual/virtual_catalog.dart';
import '../shared/nemesis_bottom_sheet.dart';
import 'addon_download_sheet.dart' show AddonSourceRow;

const _gold = Color(0xffD4AF37);

/// "Download all" for a TV show from the virtual server: asks which link to
/// use, then queues every aired episode of every season.
///
/// The links are listed exactly like the single movie / episode download
/// sheet (showAddonDownloadSheet): for each quality up to 3 direct links
/// and the 2 torrents with the most seeders and peers, chosen by the same
/// rules ([LinkRanking]), one line each ([StreamSummary]). They are the
/// links of the first episode still to be downloaded; the size on each line
/// is an estimate for ALL the episodes (see [ShowSizeEstimate]).
///
/// Picking a link queues every episode at that quality, and of that type
/// (direct or torrent). Each episode looks up its own source when its turn
/// comes.
Future<void> showSeriesAddonDownloadSheet(
  BuildContext context,
  Map<String, dynamic> series,
) {
  return showNemesisBottomSheet<void>(
    context,
    initialChildSize: 0.62,
    minChildSize: 0.3,
    maxChildSize: 0.92,
    fitContent: false,
    builder: (sheetContext, controller) =>
        _SeriesSheet(series: series, controller: controller),
  );
}

class _SeriesSheet extends StatefulWidget {
  const _SeriesSheet({required this.series, required this.controller});

  final Map<String, dynamic> series;
  final ScrollController controller;

  @override
  State<_SeriesSheet> createState() => _SeriesSheetState();
}

class _SeriesSheetState extends State<_SeriesSheet> {
  CatalogTitle? _title;
  List<Map<String, dynamic>> _todo = const [];
  int _already = 0;
  String? _problem;

  /// Running time (minutes) of the episode the links belong to, and of every
  /// episode still to be downloaded; null where TMDB gives none. Used to
  /// scale the size of one episode up to the whole show.
  double? _sampleMinutes;
  List<double?> _episodeMinutes = const [];

  StreamSubscription<List<AddonStream>>? _sub;
  List<AddonStream> _streams = const [];
  bool _searching = true;
  bool _starting = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  /// 1 minute = 600,000,000 ticks (the Jellyfin-style unit the episode list
  /// uses).
  static double? _minutesOf(Map<String, dynamic> episode) {
    final ticks = (episode['RunTimeTicks'] as num?)?.toDouble() ?? 0;
    return ticks > 0 ? ticks / 600000000.0 : null;
  }

  Future<void> _load() async {
    try {
      final seriesId = widget.series['Id']?.toString() ?? '';
      final v = VId.parse(seriesId);
      if (v.kind != 'series') {
        _fail('This show cannot be downloaded.');
        return;
      }
      if (!AddonManager.instance.hasStreamAddons) {
        _fail(AddonManager.instance.noAddonsMessage);
        return;
      }

      final results = await Future.wait<Object?>([
        TmdbCatalogService.details(CatalogType.series, v.tmdbId),
        VirtualCatalog.episodesOf(seriesId, null),
      ]);
      final title = results[0] as CatalogTitle?;
      final all = (results[1] as List<Map<String, dynamic>>?) ?? const [];
      if (!mounted) return;
      if (title == null) {
        _fail('Could not load this show. Check your connection.');
        return;
      }
      if (all.isEmpty) {
        _fail('This show has no aired episodes to download yet.');
        return;
      }

      final manager = DownloadManager.instance;
      final todo = all.where((e) {
        final id = e['Id']?.toString() ?? '';
        return id.isNotEmpty &&
            !manager.isDownloaded(id) &&
            manager.taskFor(id) == null;
      }).toList();
      if (todo.isEmpty) {
        _fail('Every episode is already downloaded or waiting in Downloads.');
        return;
      }

      // Links are read from the first episode that is still to be
      // downloaded; every other episode looks up its own source later.
      final sample = todo.first;
      final season = (sample['ParentIndexNumber'] as num?)?.toInt();
      final number = (sample['IndexNumber'] as num?)?.toInt();
      if (season == null || number == null) {
        _fail('Could not read the episode list.');
        return;
      }

      _title = title;
      _todo = todo;
      _already = all.length - todo.length;
      _sampleMinutes = _minutesOf(sample);
      _episodeMinutes = [for (final e in todo) _minutesOf(e)];

      final addonId = title.addonId(season: season, episode: number);
      _sub = AddonManager.instance.watchStreams(title.type.addon, addonId).listen(
        (batch) {
          if (!mounted) return;
          setState(() => _streams = batch.where(isDownloadableStream).toList());
        },
        onDone: () {
          if (!mounted) return;
          setState(() => _searching = false);
        },
      );
      setState(() {});
    } catch (e) {
      debugPrint('[SeriesAddonDownloadSheet] failed: $e');
      _fail('Could not look up sources.');
    }
  }

  void _fail(String text) {
    if (!mounted) return;
    setState(() {
      _searching = false;
      _problem = text;
    });
  }

  /// What the never-select rules need to know about the show.
  LinkContext get _ctx => LinkContext(
        originalLanguage: _title?.originalLanguage,
        titleName: _title?.title ?? '',
      );

  /// For each quality (highest first, unknown last): the best 3 direct links
  /// and the best 2 torrents (the same list the single episode sheet shows).
  List<QualityLinks> _links() => LinkRanking.downloadLinks(_streams, _ctx);

  String _label(int height) {
    if (height >= 2160) return '4K';
    if (height >= 1440) return '1440p';
    if (height > 0) return '${height}p';
    return 'HD';
  }

  /// The estimated size of every episode still to be downloaded, from the
  /// size of one episode's file, or null when the listing gives no size.
  int? _estimatedTotal(AddonStream s) {
    final each = StreamInfo.of(s).sizeBytes;
    if (each == null || each <= 0) return null;
    return ShowSizeEstimate.total(
      sampleBytes: each,
      sampleMinutes: _sampleMinutes,
      episodeMinutes: _episodeMinutes,
    );
  }

  Future<void> _pick(AddonStream stream) async {
    final title = _title;
    if (title == null || _starting) return;

    final count = _todo.length;
    final height = stream.height;
    final torrent = stream.isTorrent;
    final total = _estimatedTotal(stream);
    final sizeText = total != null
        ? '\nAbout ${StreamInfo.formatSize(total)} in total '
            '(estimated from the first episode).'
        : '';
    final how = torrent
        ? 'Each one uses the torrent with the most seeders, and a direct '
            'link only if it has no torrent that can be used.'
        : 'Each one uses a direct link when there is one, otherwise the '
            'torrent with the most seeders.';

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: Text(
          'Download $count ${count == 1 ? 'episode' : 'episodes'}?',
          style: const TextStyle(color: Colors.white, fontSize: 18),
        ),
        content: Text(
          'Every episode is queued in ${_label(height)}. $how '
          'If an episode has no ${_label(height)} source, the closest '
          'quality is used.$sizeText',
          style: const TextStyle(color: Colors.white70, height: 1.35),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel', style: TextStyle(color: Colors.white70)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Download', style: TextStyle(color: _gold)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    _starting = true;
    HapticFeedback.lightImpact();
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);

    if (!await DownloadManager.instance.ensureStoragePermission()) {
      _starting = false;
      messenger?.showSnackBar(const SnackBar(
        content: Text('Storage access is needed to save downloads.'),
      ));
      return;
    }

    final episodes = List<Map<String, dynamic>>.of(_todo);
    navigator.pop();
    messenger?.showSnackBar(SnackBar(
      content: Text(
        'Queued $count ${count == 1 ? 'episode' : 'episodes'} '
        'in ${_label(height)}',
      ),
    ));
    unawaited(_queueEpisodes(title, episodes, height, wantTorrent: torrent));
  }

  @override
  Widget build(BuildContext context) {
    final title = _title;
    final links = _links();
    final ctx = _ctx;
    return ListView(
      controller: widget.controller,
      padding: const EdgeInsets.only(bottom: 12),
      children: [
        const NemesisSheetDragHandle(topMargin: 10, bottomMargin: 8),
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 8, 20, 2),
          child: Text(
            'Download all episodes',
            style: TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
          child: Text(
            title == null
                ? (widget.series['Name'] ?? '').toString()
                : '${title.title} • ${_todo.length} '
                    '${_todo.length == 1 ? 'episode' : 'episodes'}'
                    '${_already > 0 ? ' ($_already already saved or queued)' : ''}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white54, fontSize: 13.5),
          ),
        ),
        if (_problem != null)
          _status(
              const Icon(Icons.info_outline, color: Colors.white54, size: 20),
              _problem!)
        else if (links.isEmpty)
          _searching
              ? _status(
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child:
                        CircularProgressIndicator(strokeWidth: 2, color: _gold),
                  ),
                  'Looking for sources…')
              : _status(
                  const Icon(Icons.search_off_rounded,
                      color: Colors.white54, size: 20),
                  'No downloadable source was found for this show.')
        else ...[
          for (var i = 0; i < links.length; i++)
            ..._qualityBlock(links[i], ctx, last: i == links.length - 1),
          if (_searching)
            _status(
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2, color: _gold),
              ),
              'Still looking for more sources…',
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 4),
            child: Text(
              'Sizes are estimates for all ${_todo.length} '
              '${_todo.length == 1 ? 'episode' : 'episodes'}, worked out '
              'from the first episode. Every episode picks its own best link '
              'of the quality and type you tap, one after another. Subtitles '
              'are saved with each video. A download that is interrupted can '
              'be continued from the Downloads page.',
              style: const TextStyle(
                  color: Colors.white38, fontSize: 12, height: 1.35),
            ),
          ),
        ],
      ],
    );
  }

  Widget _status(Widget leading, String text) {
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

  /// The links of one quality: direct links first, then torrents, each one
  /// line. A thin divider separates one quality from the next.
  List<Widget> _qualityBlock(QualityLinks q, LinkContext ctx,
      {required bool last}) {
    return [
      for (final s in q.all)
        AddonSourceRow(
          summary: StreamSummary.line(
            s,
            ctx: ctx,
            size: () {
              final total = _estimatedTotal(s);
              return total == null ? null : '≈ ${StreamInfo.formatSize(total)}';
            }(),
          ),
          onTap: () => _pick(s),
        ),
      if (!last)
        const Divider(
            height: 14, indent: 20, endIndent: 20, color: Colors.white10),
    ];
  }
}

/// Queues the episodes one after another (in order), each with no source yet:
/// the download manager picks the best one at [height] when the episode's
/// turn comes (a torrent first when [wantTorrent], otherwise a direct link
/// first).
Future<void> _queueEpisodes(
  CatalogTitle title,
  List<Map<String, dynamic>> episodes,
  int height, {
  required bool wantTorrent,
}) async {
  for (final ep in episodes) {
    try {
      final season = (ep['ParentIndexNumber'] as num?)?.toInt();
      final number = (ep['IndexNumber'] as num?)?.toInt();
      if (season == null || number == null) continue;
      final ticks = (ep['RunTimeTicks'] as num?)?.toInt() ?? 0;
      final episode = CatalogEpisode(
        season: season,
        number: number,
        name: (ep['Name'] ?? 'Episode $number').toString(),
        overview: (ep['Overview'] ?? '').toString(),
        runtime: ticks > 0 ? ticks ~/ 600000000 : null,
      );
      await DownloadManager.instance.downloadAddon(
        Map<String, dynamic>.from(ep),
        DownloadKind.episode,
        AddonDownloadJob(
          title: title,
          episode: episode,
          wantHeight: height,
          wantTorrent: wantTorrent,
        ),
      );
    } catch (e) {
      debugPrint('queueing ${ep['Id']} failed: $e');
    }
  }
}
