import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/download_manager.dart';
import '../../services/jellyfin_services/media_service.dart';
import 'device_check_badge.dart';
import 'download_stop_ring.dart';
import 'movie_download_quality_sheet.dart';
import 'series_addon_download_sheet.dart';

/// The Download control on a TV show's detail screen.
///
/// A show has no file of its own, so this works on all of its episodes at
/// once: tapping it opens the "Download Quality" sheet
/// ([showSeriesDownloadQualitySheet]) with the total size of every
/// episode at each quality, and picking one downloads all of them in that
/// quality.
///
/// It mirrors the aggregate "download all" control on the music detail
/// screens: a plain download icon when nothing is downloaded, a progress
/// ring (tap to stop the episodes that haven't finished) while a batch is
/// in flight, and the shared [DeviceCheckBadge] once every episode is on
/// the device. Sits inside the same bordered circle [DownloadButton] does
/// in the action bar, so the two look identical.
class SeriesDownloadButton extends StatefulWidget {
  final Map<String, dynamic> item;
  final double size;
  final Color color;

  const SeriesDownloadButton({
    super.key,
    required this.item,
    this.size = 22,
    this.color = Colors.white,
  });

  @override
  State<SeriesDownloadButton> createState() => _SeriesDownloadButtonState();
}

class _SeriesDownloadButtonState extends State<SeriesDownloadButton> {
  // Episode ids per series, so re-opening a show (or rebuilding this
  // button) doesn't ask the server again. Ids only — no MediaSources, so
  // the request stays cheap.
  static final Map<String, List<String>> _idCache = {};

  List<String>? _ids;

  String get _seriesId => widget.item['Id']?.toString() ?? '';

  @override
  void initState() {
    super.initState();
    _ids = _idCache[_seriesId];
    if (_ids == null) unawaited(_loadIds());
  }

  @override
  void didUpdateWidget(covariant SeriesDownloadButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item['Id'] != widget.item['Id']) {
      _ids = _idCache[_seriesId];
      if (_ids == null) unawaited(_loadIds());
    }
  }

  Future<void> _loadIds() async {
    final seriesId = _seriesId;
    if (seriesId.isEmpty) return;
    try {
      final episodes = await MediaService.getSeriesEpisodesForDownload(
        seriesId,
        withSources: false,
      );
      final ids = episodes
          .map((e) => e['Id']?.toString())
          .whereType<String>()
          .where((id) => id.isNotEmpty)
          .toList();
      _idCache[seriesId] = ids;
      if (mounted && seriesId == _seriesId) setState(() => _ids = ids);
    } catch (e) {
      // Offline, or the server is unreachable: the control just falls
      // back to whatever is on the device / in progress (see [_knownIds]).
      debugPrint('series download button: episode ids fetch failed: $e');
    }
  }

  /// The episodes this control reports on: the full list once it's known,
  /// otherwise whatever of this show is downloaded or on its way.
  List<String> _knownIds() {
    final ids = _ids;
    if (ids != null) return ids;

    final manager = DownloadManager.instance;
    final seriesId = _seriesId;
    return {
      ...manager.episodesForSeries(seriesId).map((r) => r.id),
      ...manager.activeTasksForSeries(seriesId).map((t) => t.id),
    }.toList();
  }

  void _cancelAll() {
    final manager = DownloadManager.instance;
    for (final id in _knownIds()) {
      if (manager.taskFor(id) != null && !manager.isDownloaded(id)) {
        manager.cancelDownload(id);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final box = widget.size + 20;

    return AnimatedBuilder(
      animation: DownloadManager.instance,
      builder: (context, _) {
        final aggregate = DownloadManager.instance.aggregateFor(_knownIds());

        if (aggregate.isComplete) {
          return SizedBox(
            width: box,
            height: box,
            child: Center(child: DeviceCheckBadge(size: widget.size)),
          );
        }

        if (aggregate.activeOrQueued > 0) {
          final liveFraction = aggregate.activeProgress != null
              ? (aggregate.completed + aggregate.activeProgress!) /
                  aggregate.total
              : aggregate.fraction;

          return SizedBox(
            width: box,
            height: box,
            child: Center(
              child: DownloadStopRing(
                size: widget.size,
                progress: liveFraction.clamp(0.0, 1.0).toDouble(),
                onCancel: _cancelAll,
              ),
            ),
          );
        }

        return SizedBox(
          width: box,
          height: box,
          child: Center(
            child: IconButton(
              onPressed: () {
                if (widget.item['NamesisVirtual'] == true) {
                  showSeriesAddonDownloadSheet(context, widget.item);
                  return;
                }
                showSeriesDownloadQualitySheet(context, widget.item);
              },
              padding: EdgeInsets.zero,
              splashRadius: 20,
              tooltip: 'Download',
              icon: Icon(
                Icons.download_outlined,
                color: widget.color,
                size: widget.size,
              ),
            ),
          ),
        );
      },
    );
  }
}
