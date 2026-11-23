import 'dart:async';

import 'package:flutter/material.dart';

import '../../addons/addon_manager.dart';
import '../../addons/addon_models.dart';
import '../../addons/stream_info.dart';
import '../../catalog/catalog_models.dart';
import '../../catalog/catalog_playback.dart';
import '../../catalog/tmdb_catalog_service.dart';
import '../../library/watch_entry.dart';
import '../../widgets/shared/nemesis_bottom_sheet.dart';
import '../models/media_item.dart';

const _gold = Color(0xffD4AF37);

/// True for a movie or episode that is streaming from an addon right now
/// (not a downloaded copy, which plays from a file).
bool isStreamingFromAddon(MediaItem? item) =>
    item != null &&
    item.raw?['AddonStream'] == true &&
    item.streamUrl.startsWith('http');

/// In-player Quality selector for titles fed by addons.
///
/// Lists every quality the addons have for this title, one row each, using
/// the best source for it: a direct link if there is one, otherwise the
/// torrent with the most seeders and peers. Picking a row switches playback
/// to that source from the current position.
class AddonQualitySheet extends StatefulWidget {
  const AddonQualitySheet({
    super.key,
    required this.item,
    this.scrollController,
  });

  final MediaItem item;
  final ScrollController? scrollController;

  @override
  State<AddonQualitySheet> createState() => _AddonQualitySheetState();
}

class _AddonQualitySheetState extends State<AddonQualitySheet> {
  CatalogTitle? _title;
  CatalogEpisode? _episode;
  String? _problem;
  bool _searching = true;
  List<QualityChoice> _choices = const [];
  StreamSubscription<List<AddonStream>>? _sub;

  int get _currentHeight =>
      (widget.item.raw?['StreamHeight'] as num?)?.toInt() ?? -1;

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

  Future<void> _load() async {
    try {
      final raw = widget.item.raw ?? const <String, dynamic>{};
      final tmdbId = (raw['TmdbId'] as num?)?.toInt();
      final isEpisode = raw['Type'] == 'Episode';
      if (tmdbId == null) {
        _fail('Could not tell which title this is.');
        return;
      }
      final title = await TmdbCatalogService.details(
        isEpisode ? CatalogType.series : CatalogType.movie,
        tmdbId,
      );
      if (!mounted) return;
      if (title == null) {
        _fail('Could not load this title. Check your connection.');
        return;
      }
      final episode = isEpisode ? episodeFromRaw(raw['NamesisEpisode']) : null;
      if (isEpisode && episode == null) {
        _fail('Could not tell which episode this is.');
        return;
      }
      if (!AddonManager.instance.hasStreamAddons) {
        _fail(AddonManager.instance.noAddonsMessage);
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
          setState(() => _choices = bestPerQuality(batch));
        },
        onDone: () {
          if (!mounted) return;
          setState(() => _searching = false);
        },
      );
    } catch (_) {
      if (mounted) _fail('Could not look up sources.');
    }
  }

  void _fail(String message) {
    setState(() {
      _searching = false;
      _problem = message;
    });
  }

  void _pick(QualityChoice choice) {
    final title = _title;
    if (title == null) return;
    final navigator = Navigator.of(context);
    final current = widget.item;
    navigator.pop();
    // Same quality as now: nothing to change.
    if (choice.height == _currentHeight) return;
    unawaited(CatalogPlayback.switchSource(
      current: current,
      title: title,
      stream: choice.best,
      episode: _episode,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: ListView(
        controller: widget.scrollController,
        children: [
          const NemesisSheetDragHandle(topMargin: 10, bottomMargin: 4),
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Video Quality',
              style: TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const Divider(),
          if (_problem != null)
            _note(const Icon(Icons.info_outline, color: Colors.white54),
                _problem!)
          else if (_choices.isEmpty)
            _searching
                ? _note(
                    const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: _gold),
                    ),
                    'Looking for sources…')
                : _note(
                    const Icon(Icons.search_off_rounded,
                        color: Colors.white54),
                    'No other source was found for this title.')
          else ...[
            for (final c in _choices) _row(c),
            if (_searching)
              _note(
                const SizedBox(
                  width: 16,
                  height: 16,
                  child:
                      CircularProgressIndicator(strokeWidth: 2, color: _gold),
                ),
                'Still looking for more sources…',
              ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 10, 20, 16),
              child: Text(
                'Each quality uses its best source: a direct link when there '
                'is one, otherwise the torrent with the most seeders and '
                'peers. Playback continues from where you are.',
                style: TextStyle(
                    color: Colors.white38, fontSize: 12, height: 1.35),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _note(Widget leading, String text) => Padding(
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

  Widget _row(QualityChoice c) {
    final active = c.height == _currentHeight;
    final info = c.info;

    final label = c.best.qualityLabel.isEmpty
        ? 'Unknown quality'
        : c.best.qualityLabel;

    final parts = <String>[];
    if (info.sizeBytes != null) parts.add(StreamInfo.formatSize(info.sizeBytes!));
    var warn = Colors.white54;
    if (info.isTorrent) {
      final s = info.seeders;
      final p = info.peers;
      final t = StringBuffer('Torrent');
      if (s != null) t.write(' • $s ${s == 1 ? 'seeder' : 'seeders'}');
      if (p != null) t.write(' • $p peers');
      if (s == null && p == null) t.write(' • seeders unknown');
      parts.add(t.toString());
      if (s != null && s < 5) warn = Colors.orangeAccent;
      if (s == 0) warn = Colors.redAccent;
    } else {
      parts.add(c.best.typeLabel);
    }

    return ListTile(
      leading: active
          ? const Icon(Icons.check, color: Colors.green)
          : const SizedBox(width: 24),
      title: Text(
        label,
        style: const TextStyle(color: Colors.white),
      ),
      subtitle: Text(
        parts.join('  •  '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: warn, fontSize: 12.5),
      ),
      trailing: active
          ? const Text('Playing',
              style: TextStyle(color: Colors.white38, fontSize: 12))
          : null,
      onTap: () => _pick(c),
    );
  }
}
