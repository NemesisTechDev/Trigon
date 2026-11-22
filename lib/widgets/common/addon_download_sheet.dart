import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';

import '../../addons/addon_manager.dart';
import '../../addons/addon_models.dart';
import '../../addons/link_ranking.dart';
import '../../addons/stream_info.dart';
import '../../addons/stream_rules.dart';
import '../../addons/stream_summary.dart';
import '../../catalog/catalog_models.dart';
import '../../catalog/tmdb_catalog_service.dart';
import '../../services/download_manager.dart';
import '../../virtual/virtual_catalog.dart';
import '../shared/nemesis_bottom_sheet.dart';

const _gold = Color(0xffD4AF37);

/// True for a title from the virtual (TMDB) server, which is downloaded from
/// the person's addon sources instead of from a Jellyfin server.
bool isAddonDownloadable(Map<String, dynamic> item) =>
    item['NamesisVirtual'] == true &&
    (item['Type'] == 'Movie' || item['Type'] == 'Episode');

/// "Download" sheet for a movie or episode from the virtual server.
///
/// Asks every installed addon for sources, then lists, for each quality, up
/// to 5 links: the 3 best direct links and the 2 best torrents (the ones with
/// the most seeders and peers), chosen by the same rules as auto link
/// selection (see [LinkRanking]). Each link is one line: quality, link type,
/// file size, audio language / format and video type (see [StreamSummary]). The addon's
/// own name is never shown.
Future<void> showAddonDownloadSheet(
  BuildContext context,
  Map<String, dynamic> item,
) {
  return showNemesisBottomSheet<void>(
    context,
    initialChildSize: 0.62,
    minChildSize: 0.3,
    maxChildSize: 0.92,
    fitContent: false,
    builder: (sheetContext, controller) =>
        _AddonDownloadSheet(item: item, controller: controller),
  );
}

class _AddonDownloadSheet extends StatefulWidget {
  const _AddonDownloadSheet({required this.item, required this.controller});

  final Map<String, dynamic> item;
  final ScrollController controller;

  @override
  State<_AddonDownloadSheet> createState() => _AddonDownloadSheetState();
}

class _AddonDownloadSheetState extends State<_AddonDownloadSheet> {
  CatalogTitle? _title;
  CatalogEpisode? _episode;
  String? _problem;

  StreamSubscription<List<AddonStream>>? _sub;
  List<AddonStream> _streams = const [];
  bool _searching = true;
  bool _starting = false;

  /// Running time found by opening a direct link (the listing did not say).
  final Map<String, Duration> _probed = {};
  final Set<String> _probing = {};

  DownloadKind get _kind => widget.item['Type'] == 'Episode'
      ? DownloadKind.episode
      : DownloadKind.movie;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    try {
      final v = VId.parse(widget.item['Id']?.toString() ?? '');
      CatalogTitle? title;
      CatalogEpisode? episode;
      if (v.kind == 'movie') {
        title = await TmdbCatalogService.details(CatalogType.movie, v.tmdbId);
      } else if (v.kind == 'episode') {
        title = await TmdbCatalogService.details(CatalogType.series, v.tmdbId);
        final season = v.season;
        final number = v.episode;
        if (season != null && number != null) {
          final eps = await TmdbCatalogService.episodes(v.tmdbId, season);
          for (final e in eps) {
            if (e.number == number) {
              episode = e;
              break;
            }
          }
          episode ??= CatalogEpisode(
            season: season,
            number: number,
            name: (widget.item['Name'] ?? '').toString(),
            overview: '',
          );
        }
      }
      if (!mounted) return;
      if (title == null) {
        setState(() {
          _searching = false;
          _problem = 'Could not load this title. Check your connection.';
        });
        return;
      }
      if (!AddonManager.instance.hasStreamAddons) {
        setState(() {
          _searching = false;
          _problem = 'No addon installed. Open Profile > Addons to add one.';
        });
        return;
      }

      _title = title;
      _episode = episode;
      final id = episode != null
          ? title.addonId(season: episode.season, episode: episode.number)
          : title.addonId();

      _sub = AddonManager.instance.watchStreams(title.type.addon, id).listen(
        (batch) {
          if (!mounted) return;
          setState(() => _streams = _downloadable(batch));
          _probeBest();
        },
        onDone: () {
          if (!mounted) return;
          setState(() => _searching = false);
        },
      );
    } catch (e) {
      debugPrint('[AddonDownloadSheet] failed: $e');
      if (!mounted) return;
      setState(() {
        _searching = false;
        _problem = 'Could not look up sources.';
      });
    }
  }

  /// Streaming-only formats (HLS / DASH playlists) cannot be saved as one
  /// file, so they are not offered.
  static List<AddonStream> _downloadable(List<AddonStream> all) {
    return all.where((s) {
      if (s.isTorrent) return true;
      final path = (Uri.tryParse(s.url)?.path ?? '').toLowerCase();
      return !path.endsWith('.m3u8') && !path.endsWith('.mpd');
    }).toList();
  }

  // ---- grouping ----

  static String _key(AddonStream s) => s.url;

  /// What the never-select rules need to know about the title.
  LinkContext get _ctx => LinkContext(
        originalLanguage: _title?.originalLanguage,
        titleName: _title?.title ?? '',
      );

  /// For each quality (highest first, unknown last): the best 3 direct links
  /// and the best 2 torrents.
  List<QualityLinks> _links() => LinkRanking.downloadLinks(_streams, _ctx);

  // ---- running time ----

  /// For the best direct link of each quality whose listing gives no running
  /// time, opens the link quietly and reads it, so the download knows its
  /// length. Torrents are not probed (that would mean starting the torrent).
  void _probeBest() {
    for (final q in _links()) {
      if (q.directs.isEmpty) continue;
      final s = q.directs.first;
      if (StreamInfo.of(s).duration != null) continue;
      final k = _key(s);
      if (_probed.containsKey(k) || _probing.contains(k)) continue;
      if (_probing.length >= 2) return;
      _probing.add(k);
      unawaited(_probe(s).then((d) {
        _probing.remove(k);
        if (!mounted) return;
        if (d != null) setState(() => _probed[k] = d);
        _probeBest();
      }));
    }
  }

  static Future<Duration?> _probe(AddonStream s) async {
    final player = Player(
      configuration: const PlayerConfiguration(logLevel: MPVLogLevel.error),
    );
    try {
      await player.open(
        Media(
          s.url,
          httpHeaders: s.headers.isEmpty ? null : s.headers,
        ),
        play: false,
      );
      return await player.stream.duration
          .firstWhere((d) => d > Duration.zero)
          .timeout(const Duration(seconds: 12));
    } catch (_) {
      return null;
    } finally {
      try {
        await player.dispose();
      } catch (_) {}
    }
  }

  // ---- starting a download ----

  Future<void> _pick(AddonStream stream) async {
    final title = _title;
    if (title == null || _starting) return;
    _starting = true;
    HapticFeedback.lightImpact();

    final base = StreamInfo.of(stream);
    final info = StreamInfo(
      sizeBytes: base.sizeBytes,
      seeders: base.seeders,
      peers: base.peers,
      duration: base.duration ?? _probed[_key(stream)],
      isTorrent: base.isTorrent,
    );

    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    final label = stream.qualityLabel.isEmpty ? 'Download' : stream.qualityLabel;

    if (!await DownloadManager.instance.ensureStoragePermission()) {
      _starting = false;
      messenger?.showSnackBar(const SnackBar(
        content: Text('Storage access is needed to save downloads.'),
      ));
      return;
    }

    unawaited(DownloadManager.instance.downloadAddon(
      widget.item,
      _kind,
      AddonDownloadJob(
        title: title,
        episode: _episode,
        stream: stream,
        info: info,
      ),
    ));
    navigator.pop();
    messenger?.showSnackBar(SnackBar(
      content: Text(
        'Downloading $label'
        '${info.sizeBytes != null ? ' (${StreamInfo.formatSize(info.sizeBytes!)})' : ''}'
        ' with subtitles',
      ),
    ));
  }

  // ---- UI ----

  @override
  Widget build(BuildContext context) {
    final links = _links();
    final ctx = _ctx;

    final heading = _episode != null
        ? '${_title?.title ?? widget.item['SeriesName'] ?? ''} • '
            'S${_episode!.season}E${_episode!.number}'
        : (_title?.title ?? widget.item['Name'] ?? '').toString();

    return ListView(
      controller: widget.controller,
      padding: const EdgeInsets.only(bottom: 12),
      children: [
        const NemesisSheetDragHandle(topMargin: 10, bottomMargin: 8),
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 8, 20, 2),
          child: Text(
            'Download',
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
            heading,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white54, fontSize: 13.5),
          ),
        ),
        if (_problem != null)
          _status(const Icon(Icons.info_outline, color: Colors.white54, size: 20),
              _problem!)
        else if (links.isEmpty)
          _searching
              ? _status(
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: _gold),
                  ),
                  'Looking for sources…')
              : _status(
                  const Icon(Icons.search_off_rounded,
                      color: Colors.white54, size: 20),
                  'No downloadable source was found for this title.')
        else ...[
          for (var i = 0; i < links.length; i++)
            ..._qualityBlock(links[i], ctx, last: i == links.length - 1),
          if (_searching)
            _status(
              const SizedBox(
                width: 14,
                height: 14,
                child:
                    CircularProgressIndicator(strokeWidth: 2, color: _gold),
              ),
              'Still looking for more sources…',
            ),
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 10, 20, 4),
            child: Text(
              'Subtitles are saved with the video. Up to 3 direct links and '
              '2 torrents (the ones with the most seeders and peers) are '
              'shown for each quality.',
              style: TextStyle(color: Colors.white38, fontSize: 12, height: 1.35),
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

  /// The file size the listing gives for [s], formatted (for example
  /// `2.40 GB`), shown right after the link type. null when the listing does
  /// not say, so no size is shown rather than a made-up one.
  static String? _sizeLabel(AddonStream s) {
    final bytes = StreamInfo.of(s).sizeBytes;
    return bytes != null && bytes > 0 ? StreamInfo.formatSize(bytes) : null;
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
            size: _sizeLabel(s),
          ),
          onTap: () => _pick(s),
        ),
      if (!last)
        const Divider(
            height: 14, indent: 20, endIndent: 20, color: Colors.white10),
    ];
  }
}

/// One download link as a single line (quality, link type, size, audio, video
/// type).
/// Shared with the TV show's "Download all" sheet so both look the same.
class AddonSourceRow extends StatelessWidget {
  const AddonSourceRow({
    super.key,
    required this.summary,
    required this.onTap,
  });

  final String summary;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
        child: Row(
          children: [
            Expanded(
              child: Text(
                summary,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 12),
            const Icon(Icons.download_rounded, color: Colors.white70),
          ],
        ),
      ),
    );
  }
}
