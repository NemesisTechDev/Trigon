import 'package:flutter/material.dart';

import '../player_manager.dart';
import '../models/media_item.dart';
import '../services/playback_queue.dart';
import '../../services/jellyfin_services/media_service.dart';
import '../../widgets/common/watched_badge.dart';
import '../../widgets/common/pressable.dart';
import '../../widgets/common/play_icon_overlay.dart';
import '../../widgets/common/artwork_image.dart';
import '../../casting/playback_coordinator.dart';
import '../../virtual/virtual_catalog.dart';
import '../../screens/movie_details/widgets/season_selector.dart';
import '../../virtual/virtual_playback.dart';
import '../../library/watch_history_service.dart';
import '../../services/download_manager.dart';

/// Right-side sliding panel listing the episodes in the current
/// playback queue (only relevant when playing a season/series). Tapping
/// an episode plays it immediately and closes the panel.
class EpisodeListPanel extends StatefulWidget {
  const EpisodeListPanel({super.key});

  @override
  State<EpisodeListPanel> createState() => _EpisodeListPanelState();
}

class _EpisodeListPanelState extends State<EpisodeListPanel> {
  static const _gold = Color(0xFFFFC107);

  List<dynamic> _seasons = [];
  String? _selectedSeasonId;
  String? _loadedForSeriesId;
  bool _loadingSeasons = false;
  bool _loadingEpisodes = false;

  // NAMESIS PRIME: shows that come from the virtual TMDB server (everything
  // played through addons). Their episodes are listed straight from the
  // server, per season, instead of from the playback queue — the queue only
  // ever holds the playing episode and the one lined up after it.
  List<MediaItem> _virtualEpisodes = [];
  String? _virtualEpisodesKey;
  int _virtualToken = 0;
  String? _lastSyncedSeasonId;
  String? _logoRequestedFor;

  // DOWNLOADS: when what is playing comes from the Downloads screen (the
  // playing episode and everything queued with it are on-device files), the
  // panel lists only the downloaded episodes of that show, never the
  // server's full episode list.
  bool _wasDownloadsMode = false;
  int _downloadedEpisodeCount = -1;

  void _onDownloadsChanged() {
    if (!mounted) return;
    final n = DownloadManager.instance.episodes.length;
    if (n == _downloadedEpisodeCount) return;
    _downloadedEpisodeCount = n;
    setState(() {});
  }

  /// True when the playing episode and the whole queue are downloaded
  /// files. A streamed or mixed queue (e.g. started from the detail
  /// screen) keeps the normal full-season behaviour.
  bool _isDownloadsMode(MediaItem? current) {
    if (current == null || current.seriesId == null || current.audioOnly) {
      return false;
    }
    final dm = DownloadManager.instance;
    if (!dm.isDownloaded(current.id)) return false;
    final q = List<MediaItem>.from(PlaybackQueue.instance.queueNotifier.value);
    return q.isNotEmpty && q.every((i) => dm.isDownloaded(i.id));
  }

  /// Seasons that actually have a downloaded episode, built from the local
  /// records (no server call, works offline).
  List<Map<String, dynamic>> _downloadedSeasons(String seriesId) {
    final seasons = <Map<String, dynamic>>[];
    final seen = <String>{};
    for (final e in DownloadManager.instance.episodesForSeries(seriesId)) {
      final id = e.seasonId;
      if (id == null || id.isEmpty || !seen.add(id)) continue;
      final number = e.raw['ParentIndexNumber'] as num?;
      final name = e.seasonName;
      seasons.add(<String, dynamic>{
        'Id': id,
        'Name': (name != null && name.isNotEmpty)
            ? name
            : (number != null ? 'Season ${number.toInt()}' : 'Season'),
        'Number': number,
      });
    }
    seasons.sort((a, b) {
      final an = a['Number'] as num?;
      final bn = b['Number'] as num?;
      if (an != null && bn != null) return an.compareTo(bn);
      return 0;
    });
    return seasons;
  }

  List<MediaItem> _downloadedEpisodes(String seriesId, String? seasonId) {
    final dm = DownloadManager.instance;
    return dm
        .episodesForSeries(seriesId)
        .where((e) => seasonId == null || e.seasonId == seasonId)
        .map(dm.mediaItemForRecord)
        .toList();
  }

  void _onProgressChanged() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    WatchHistoryService.instance.progressRevision
        .addListener(_onProgressChanged);
    _downloadedEpisodeCount = DownloadManager.instance.episodes.length;
    DownloadManager.instance.addListener(_onDownloadsChanged);
  }

  @override
  void dispose() {
    WatchHistoryService.instance.progressRevision
        .removeListener(_onProgressChanged);
    DownloadManager.instance.removeListener(_onDownloadsChanged);
    super.dispose();
  }

  static bool _isVirtualSeries(String? id) =>
      id != null && VId.parse(id).kind == 'series';

  Future<void> _loadVirtualEpisodes(String seriesId, String seasonId) async {
    final key = '$seriesId|$seasonId';
    if (_virtualEpisodesKey == key) return;
    _virtualEpisodesKey = key;
    final token = ++_virtualToken;

    if (mounted) setState(() => _loadingEpisodes = true);
    try {
      final eps = await MediaService.getEpisodes(seriesId, seasonId);
      if (!mounted || token != _virtualToken) return;
      setState(() {
        _virtualEpisodes = MediaService.mediaItemsFromList(eps);
      });
    } catch (_) {
      // Leave the key set (no retry loop); picking a season tries again.
      if (mounted && token == _virtualToken) {
        setState(() => _virtualEpisodes = []);
      }
    } finally {
      if (mounted && token == _virtualToken) {
        setState(() => _loadingEpisodes = false);
      }
    }
  }

  /// Keeps the panel on the playing show: loads its seasons (and the logo),
  /// follows the playing episode into a new season, and lists the selected
  /// season's episodes.
  Future<void> _syncVirtual(String seriesId, MediaItem current) async {
    await _ensureSeasonsLoaded(seriesId, current.seasonId);
    if (!mounted) return;

    final cs = current.seasonId;
    if (cs != null && cs != _lastSyncedSeasonId) {
      _lastSyncedSeasonId = cs;
      if (_selectedSeasonId != cs) setState(() => _selectedSeasonId = cs);
    }

    var sel = _selectedSeasonId ?? cs;
    // A season id left over from a previous show is never valid here.
    if (sel != null &&
        VId.parse(sel).tmdbId != VId.parse(seriesId).tmdbId) {
      sel = cs;
    }
    if (sel != null) await _loadVirtualEpisodes(seriesId, sel);
  }

  /// A series' logo is only known after its details were loaded once; make
  /// sure that has happened, then repaint.
  Future<void> _ensureLogo(String seriesId) async {
    if (_logoRequestedFor == seriesId) return;
    _logoRequestedFor = seriesId;
    if (!MediaService.getLogoUrl(seriesId).contains('/no-image/')) return;
    try {
      await MediaService.getItem(seriesId);
    } catch (_) {}
    if (mounted) setState(() {});
  }

  Future<void> _ensureSeasonsLoaded(String seriesId, String? seasonId) async {
    if (_loadedForSeriesId == seriesId) return;

    _loadedForSeriesId = seriesId;

    setState(() {
      _loadingSeasons = true;
      // A different show: drop the previous show's seasons and episodes.
      _seasons = [];
      _virtualEpisodes = [];
      _virtualEpisodesKey = null;
      _lastSyncedSeasonId = null;
      if (seasonId != null) _selectedSeasonId = seasonId;
    });

    try {
      final seasons = await MediaService.getSeasons(seriesId);

      if (!mounted) return;

      setState(() {
        _seasons = seasons;
        _selectedSeasonId = seasonId ??
            (seasons.isNotEmpty ? seasons.first["Id"] as String? : null);
      });
    } finally {
      if (mounted) {
        setState(() {
          _loadingSeasons = false;
        });
      }
    }
  }

  // ROOT CAUSE (panel showing only 2-3 episodes, some twice, while casting):
  // a Play tap that is redirected to the TV only ever puts the single tapped
  // item into PlaybackQueue (PlaybackService.playItem), and repeated loads /
  // jumps can leave repeats behind. This panel just renders that queue, so
  // it showed whatever little the queue happened to hold. Once per season
  // the panel now compares the queue with the server's real episode list
  // and, if episodes are missing or duplicated, swaps in the full season.
  // Only a queue made purely of this season's episodes is touched — a
  // multi-season / series queue or another season being browsed is left
  // alone.
  String? _repairedKey;

  Future<void> _ensureFullSeasonQueue(MediaItem current) async {
    final seriesId = current.seriesId;
    final seasonId = current.seasonId;
    if (seriesId == null || seasonId == null || current.audioOnly) return;
    // Virtual shows list episodes from the server (see _syncVirtual); the
    // queue is left alone so the next episode stays lined up.
    if (_isVirtualSeries(seriesId)) return;

    final key = '$seriesId:$seasonId';
    if (_repairedKey == key) return;
    _repairedKey = key;

    final queue = PlaybackQueue.instance;
    bool onlyThisSeason(List<MediaItem> items) =>
        items.every((i) => i.seasonId == seasonId);

    if (!onlyThisSeason(List<MediaItem>.from(queue.queueNotifier.value))) {
      return;
    }

    try {
      final episodes = await MediaService.getEpisodes(seriesId, seasonId);
      final full = MediaService.mediaItemsFromList(episodes);
      if (!mounted || full.isEmpty) return;

      // The queue may have changed while the request was in flight.
      final latest = List<MediaItem>.from(queue.queueNotifier.value);
      if (!onlyThisSeason(latest)) return;

      final ids = latest.map((e) => e.id).toList();
      final idSet = ids.toSet();
      final hasDuplicates = ids.length != idSet.length;
      final isMissingEpisodes =
          !idSet.containsAll(full.map((e) => e.id));
      if (!hasDuplicates && !isMissingEpisodes) return;

      final index = full.indexWhere((e) => e.id == current.id);
      queue.setQueue(
        full,
        startIndex: index < 0 ? 0 : index,
        source: queue.source == PlaybackSource.unknown
            ? PlaybackSource.season
            : queue.source,
        title: queue.title,
        artwork: queue.artwork,
      );
    } catch (_) {
      // Best effort — allow another attempt next time the panel opens.
      _repairedKey = null;
    }
  }

  Future<void> _selectSeason(String seriesId, String seasonId) async {
    if (seasonId == _selectedSeasonId) return;

    // Downloads: just switch which season's downloaded episodes are
    // listed; nothing to fetch.
    if (_isDownloadsMode(PlayerManager.instance.currentItemNotifier.value)) {
      setState(() => _selectedSeasonId = seasonId);
      return;
    }

    if (_isVirtualSeries(seriesId)) {
      setState(() => _selectedSeasonId = seasonId);
      await _loadVirtualEpisodes(seriesId, seasonId);
      return;
    }

    setState(() {
      _selectedSeasonId = seasonId;
      _loadingEpisodes = true;
    });

    try {
      final episodes = await MediaService.getEpisodes(seriesId, seasonId);
      final items = MediaService.mediaItemsFromList(episodes);

      // Only browsing — this swaps the queue contents so the list shows
      // the newly selected season, without starting playback. Tapping an
      // episode below still plays it as usual.
      PlaybackQueue.instance.setQueue(
        items,
        startIndex: 0,
        source: PlaybackQueue.instance.source,
        title: PlaybackQueue.instance.title,
        artwork: PlaybackQueue.instance.artwork,
      );
    } finally {
      if (mounted) {
        setState(() {
          _loadingEpisodes = false;
        });
      }
    }
  }

  Widget _buildSeasonSelector(
    String seriesId, {
    List<dynamic>? seasons,
    String? selectedSeasonId,
  }) {
    final downloads = seasons != null;
    if (!downloads && _loadingSeasons) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 10),
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }

    final shown = seasons ?? _seasons;
    if (shown.length < 2) {
      // Nothing to switch between — don't clutter the panel with a
      // selector for a single season.
      return const SizedBox.shrink();
    }

    // The detail screen's own chip row (it also glides the picked season to
    // the middle, like the library chips).
    return SeasonSelector(
      seriesId: seriesId,
      seasons: shown,
      selectedSeasonId: downloads ? selectedSeasonId : _selectedSeasonId,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      onSeasonSelected: (id) => _selectSeason(seriesId, id),
    );
  }

  @override
  Widget build(BuildContext context) {
    final manager = PlayerManager.instance;
    final queue = PlaybackQueue.instance;

    // Aspect-scoped (MediaQuery.sizeOf) instead of the unscoped
    // MediaQuery.of(context) this used to call — that subscribed this
    // whole panel to every MediaQueryData field, including
    // viewInsets.bottom, which flips on every frame while any keyboard
    // animates anywhere on this same player screen (most commonly the
    // subtitle-search sheet). sizeOf only rebuilds when the actual
    // screen size changes, which is the only thing this width
    // calculation cares about.
    final width = MediaQuery.sizeOf(context).width * 0.34;

    return ValueListenableBuilder<bool>(
      valueListenable: manager.showEpisodeList,
      builder: (_, open, __) {
        return IgnorePointer(
          ignoring: !open,
          child: AnimatedSlide(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOut,
            offset: open ? Offset.zero : const Offset(1, 0),
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 200),
              opacity: open ? 1 : 0,
              child: Align(
                alignment: Alignment.centerRight,
                child: Container(
                  width: width.clamp(280.0, 420.0).toDouble(),
                  height: double.infinity,
                  color: const Color(0xf0141414),
                  // Was SafeArea(left: false) here — same fix, and same
                  // reasoning, as LiveChannelListPanel's identical swap:
                  // SafeArea's unscoped MediaQuery.of(context) was
                  // subscribing this whole seasons/episodes tree to
                  // every keyboard animation on this player screen (e.g.
                  // the subtitle-search sheet), not just real padding
                  // changes.
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(
                      0,
                      MediaQuery.paddingOf(context).top,
                      MediaQuery.paddingOf(context).right,
                      MediaQuery.paddingOf(context).bottom,
                    ),
                    child: ValueListenableBuilder<MediaItem?>(
                      valueListenable: manager.currentItemNotifier,
                      builder: (_, currentItem, __) {
                        final seriesId = currentItem?.seriesId;
                        final downloadsMode =
                            seriesId != null && _isDownloadsMode(currentItem);
                        // Addon show (progress comes from watch history).
                        final virtualSeries = _isVirtualSeries(seriesId);
                        // Episodes listed from the server rather than from
                        // the queue — never for a downloads session.
                        final virtualMode = virtualSeries && !downloadsMode;

                        final dlSeasons = downloadsMode
                            ? _downloadedSeasons(seriesId!)
                            : const <Map<String, dynamic>>[];
                        String? dlSelected;
                        if (downloadsMode) {
                          bool has(String? id) =>
                              id != null && dlSeasons.any((x) => x['Id'] == id);
                          dlSelected = has(_selectedSeasonId)
                              ? _selectedSeasonId
                              : has(currentItem?.seasonId)
                                  ? currentItem?.seasonId
                                  : (dlSeasons.isNotEmpty
                                      ? dlSeasons.first['Id'] as String?
                                      : null);
                        }

                        // The series' logo; an addon episode carries its own
                        // as a fallback.
                        String? logoUrl;
                        if (seriesId != null) {
                          final u = MediaService.getLogoUrl(seriesId);
                          if (!u.contains('/no-image/')) {
                            logoUrl = u;
                          } else {
                            final l = currentItem?.logo;
                            if (l != null &&
                                l.isNotEmpty &&
                                !l.contains('/no-image/')) {
                              logoUrl = l;
                            }
                          }
                        }

                        // Kick off the seasons fetch as a side effect of
                        // this build rather than tying it to panel-open
                        // state directly — this keeps it in sync if the
                        // playing item changes (e.g. next episode
                        // auto-plays) while the panel happens to be open.
                        if (open && seriesId != null) {
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            if (!mounted) return;
                            if (downloadsMode) {
                              // Follow the playing episode into its season;
                              // no server calls for a downloaded show.
                              _wasDownloadsMode = true;
                              final cs = currentItem?.seasonId;
                              if (cs != null && cs != _lastSyncedSeasonId) {
                                _lastSyncedSeasonId = cs;
                                setState(() => _selectedSeasonId = cs);
                              }
                              return;
                            }
                            if (_wasDownloadsMode) {
                              // Back to a streamed show: drop what the
                              // downloads view put in place.
                              _wasDownloadsMode = false;
                              _loadedForSeriesId = null;
                              _virtualEpisodesKey = null;
                              _repairedKey = null;
                              _lastSyncedSeasonId = null;
                            }
                            if (_isVirtualSeries(seriesId)) {
                              if (currentItem != null) {
                                _syncVirtual(seriesId, currentItem);
                              }
                              _ensureLogo(seriesId);
                              return;
                            }
                            _ensureSeasonsLoaded(seriesId, currentItem?.seasonId);
                            if (currentItem != null) {
                              _ensureFullSeasonQueue(currentItem);
                            }
                          });
                        }

                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Padding(
                              padding:
                                  const EdgeInsets.fromLTRB(16, 12, 8, 12),
                              child: Row(
                                children: [
                                  const Text(
                                    "Episodes",
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 18,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  if (seriesId != null) ...[
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: _SeriesLogo(
                                        key: ValueKey(logoUrl),
                                        url: logoUrl,
                                      ),
                                    ),
                                  ] else
                                    const Spacer(),
                                  IconButton(
                                    onPressed: () {
                                      manager.showEpisodeList.value = false;
                                    },
                                    icon: const Icon(
                                      Icons.close,
                                      color: Colors.white,
                                    ),
                                  ),
                                ],
                              ),
                            ),

                            if (seriesId != null) ...[
                              downloadsMode
                                  ? _buildSeasonSelector(
                                      seriesId,
                                      seasons: dlSeasons,
                                      selectedSeasonId: dlSelected,
                                    )
                                  : _buildSeasonSelector(seriesId),
                              const SizedBox(height: 10),
                            ],

                            const Divider(color: Colors.white12, height: 1),

                            Expanded(
                              child: (!downloadsMode &&
                                      (_loadingEpisodes ||
                                          (virtualMode &&
                                              _virtualEpisodesKey == null)))
                                  ? const Center(
                                      child: CircularProgressIndicator(),
                                    )
                                  : ValueListenableBuilder<List>(
                                      valueListenable: queue.queueNotifier,
                                      builder: (_, queueItems, __) {
                                        final List<MediaItem> dlItems =
                                            downloadsMode
                                                ? _downloadedEpisodes(
                                                    seriesId!, dlSelected)
                                                : const <MediaItem>[];
                                        final List items = downloadsMode
                                            ? dlItems
                                            : virtualMode
                                                ? _virtualEpisodes
                                                : queueItems;
                                        if (items.isEmpty) {
                                          return const Center(
                                            child: Text(
                                              "No episodes",
                                              style: TextStyle(
                                                  color: Colors.white54),
                                            ),
                                          );
                                        }

                                        return ListView.builder(
                                          padding: const EdgeInsets.symmetric(
                                              vertical: 8),
                                          itemCount: items.length,
                                          itemBuilder: (context, index) {
                                            final item = items[index];
                                            final playing = virtualMode
                                                ? (item.seasonNumber ==
                                                        currentItem
                                                            ?.seasonNumber &&
                                                    item.episodeNumber ==
                                                        currentItem
                                                            ?.episodeNumber)
                                                : item.id == currentItem?.id;

                                            // Same "some progress saved,
                                            // but not yet marked fully
                                            // played" definition
                                            // EpisodeCardCompact uses for
                                            // its progress bar.
                                            // item.resumePosition is only
                                            // ever populated via
                                            // MediaItem.copyWith's local-
                                            // casting-handoff path (see its
                                            // own doc comment) — for every
                                            // ordinary episode built from a
                                            // Jellyfin response it's stuck
                                            // at its Duration.zero default,
                                            // which made this bar never
                                            // show no matter how far into an
                                            // episode the person actually
                                            // was. item.playbackPosition is
                                            // the field mediaItemFromJellyfin
                                            // actually fills from
                                            // UserData.PlaybackPositionTicks.
                                            // NAMESIS PRIME: addon shows
                                            // read live per-episode progress
                                            // from the watch history.
                                            final h = WatchHistoryService
                                                .instance;
                                            final tmdbId = virtualSeries
                                                ? VId.parse(seriesId!).tmdbId
                                                : 0;
                                            final bool played = virtualSeries
                                                ? h.isWatched(
                                                    tmdbId,
                                                    item.seasonNumber ?? 0,
                                                    item.episodeNumber ?? 0)
                                                : item.played;
                                            Duration position =
                                                item.playbackPosition ??
                                                    Duration.zero;
                                            Duration total = item.runtime;
                                            if (virtualSeries) {
                                              final p = h.episodeProgress(
                                                  tmdbId,
                                                  item.seasonNumber ?? 0,
                                                  item.episodeNumber ?? 0);
                                              if (p != null) {
                                                position = Duration(
                                                    milliseconds: p[0]);
                                                total = Duration(
                                                    milliseconds: p[1]);
                                              }
                                            }
                                            final inProgress = !played &&
                                                position > Duration.zero &&
                                                total > Duration.zero;
                                            final progress = inProgress
                                                ? (position.inMilliseconds /
                                                        total.inMilliseconds)
                                                    .clamp(0.0, 1.0)
                                                : 0.0;

                                            return Pressable(
                                              borderRadius: BorderRadius.circular(10),
                                              onTap: () async {
                                                manager.showEpisodeList.value =
                                                    false;

                                                if (playing) return;

                                                // Casting fix: this used to
                                                // unconditionally call
                                                // local playMedia(), even
                                                // while this content is
                                                // actively being cast —
                                                // tapping an episode here
                                                // just kept playing the old
                                                // one on the TV. QueueScreen
                                                // (the audio equivalent of
                                                // this panel) already has
                                                // this exact same "route to
                                                // the TV if casting"
                                                // treatment via
                                                // PlaybackCoordinator
                                                // .castJumpTo — it checks
                                                // CastManager.instance
                                                // .isCasting itself and
                                                // returns false when
                                                // nothing's connected *or*
                                                // when the send to the TV
                                                // itself failed (see its own
                                                // doc comment — this used to
                                                // always report success
                                                // regardless, which is why a
                                                // tap could silently do
                                                // nothing and need a second
                                                // tap to actually land), so
                                                // falling back to the local
                                                // path below is always safe
                                                // and this tap always
                                                // starts something playing
                                                // immediately, on the TV or
                                                // on this device.
                                                if (virtualMode) {
                                                  // Picks a source through the
                                                  // person's addons, then
                                                  // plays it (on the TV when
                                                  // casting).
                                                  await VirtualPlayback.play(
                                                    item as MediaItem,
                                                    fromPlayer: true,
                                                  );
                                                  return;
                                                }

                                                if (downloadsMode) {
                                                  // The queue must be exactly
                                                  // the listed downloaded
                                                  // episodes so `index` means
                                                  // the same thing in both.
                                                  final qIds = queue
                                                      .queueNotifier.value
                                                      .map((e) => e.id)
                                                      .toList();
                                                  final lIds = dlItems
                                                      .map((e) => e.id)
                                                      .toList();
                                                  final same =
                                                      qIds.length ==
                                                              lIds.length &&
                                                          List.generate(
                                                                  qIds.length,
                                                                  (i) =>
                                                                      qIds[i] ==
                                                                      lIds[i])
                                                              .every(
                                                                  (b) => b);
                                                  if (!same) {
                                                    queue.setQueue(
                                                      dlItems,
                                                      startIndex: index,
                                                      source: queue.source ==
                                                              PlaybackSource
                                                                  .unknown
                                                          ? PlaybackSource
                                                              .season
                                                          : queue.source,
                                                      title: queue.title,
                                                      artwork: queue.artwork,
                                                    );
                                                  }
                                                }

                                                final castHandled =
                                                    await PlaybackCoordinator
                                                        .instance
                                                        .castJumpTo(index);
                                                if (castHandled) return;

                                                queue.jumpTo(index);

                                                await manager.playMedia(
                                                  queue.current!,
                                                );
                                              },
                                              child: Container(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                  horizontal: 16,
                                                  vertical: 10,
                                                ),
                                                color: playing
                                                    ? Colors.white10
                                                    : Colors.transparent,
                                                child: Row(
                                                  children: [
                                                    // Fixed-size wrapper the
                                                    // Stack itself now
                                                    // inherits — matching
                                                    // EpisodeCardCompact's
                                                    // own
                                                    // SizedBox(width,height)
                                                    // + Stack construction.
                                                    // Without this, the bare
                                                    // Stack (a non-flex Row
                                                    // child, which gets an
                                                    // unbounded main-axis
                                                    // width constraint) let
                                                    // PlayIconOverlay's inner
                                                    // Center shrink-wrap
                                                    // down to just its own
                                                    // icon size instead of
                                                    // filling the thumbnail,
                                                    // so it rendered pinned
                                                    // to the Stack's default
                                                    // top-start corner
                                                    // instead of centered
                                                    // over it.
                                                    SizedBox(
                                                      width: 96,
                                                      height: 54,
                                                      child: Stack(
                                                      clipBehavior: Clip.none,
                                                      children: [
                                                        ClipRRect(
                                                          borderRadius:
                                                              BorderRadius
                                                                  .circular(6),
                                                          child: SizedBox(
                                                            width: 96,
                                                            height: 54,
                                                            child: item.image !=
                                                                    null
                                                                // Bug fix: this
                                                                // used to be a
                                                                // bare
                                                                // Image.network,
                                                                // which silently
                                                                // fails (and
                                                                // falls through
                                                                // to the plain
                                                                // white12
                                                                // errorBuilder
                                                                // box below,
                                                                // with no play
                                                                // icon or
                                                                // progress bar
                                                                // on top of it
                                                                // either — see
                                                                // the two
                                                                // Positioned
                                                                // widgets
                                                                // further down,
                                                                // which never
                                                                // painted at
                                                                // all before
                                                                // this fix)
                                                                // whenever
                                                                // item.image is
                                                                // a local
                                                                // filesystem
                                                                // path rather
                                                                // than an http
                                                                // URL — exactly
                                                                // what
                                                                // DownloadManager
                                                                // .mediaItemFor
                                                                // hands back
                                                                // for a
                                                                // downloaded
                                                                // episode
                                                                // (record
                                                                // .posterPath).
                                                                // ArtworkImage
                                                                // is the same
                                                                // local-vs-
                                                                // network
                                                                // switch
                                                                // QueueScreen
                                                                // (this panel's
                                                                // audio
                                                                // equivalent)
                                                                // already uses.
                                                                ? ArtworkImage(
                                                                    path: item
                                                                        .image!,
                                                                    fit: BoxFit
                                                                        .cover,
                                                                    errorBuilder: (
                                                                      _,
                                                                      __,
                                                                      ___,
                                                                    ) =>
                                                                        Container(
                                                                      color: Colors
                                                                          .white12,
                                                                    ),
                                                                  )
                                                                : Container(
                                                                    color: Colors
                                                                        .white12,
                                                                  ),
                                                          ),
                                                        ),

                                                        // Same reference
                                                        // look the TV show
                                                        // detail screen's
                                                        // episode cards use
                                                        // (EpisodeCardCompact):
                                                        // a centered "tap to
                                                        // play" glyph over
                                                        // every thumbnail...
                                                        // except the row
                                                        // that's actually
                                                        // playing right now
                                                        // — the gold
                                                        // highlight/text and
                                                        // _EpisodeVisualizer
                                                        // already mark that
                                                        // one, so a "tap to
                                                        // play" glyph on top
                                                        // of its thumbnail
                                                        // read as a second,
                                                        // contradictory
                                                        // affordance. Applies
                                                        // the same way to a
                                                        // downloaded episode's
                                                        // thumbnail as a
                                                        // streamed one — both
                                                        // go through this
                                                        // same ArtworkImage
                                                        // branch above, so
                                                        // there's nothing
                                                        // download-specific
                                                        // to key off here.
                                                        if (!playing)
                                                          const PlayIconOverlay(
                                                              size: 22),

                                                        // ...and a bottom
                                                        // progress bar for
                                                        // an episode with
                                                        // saved position
                                                        // that isn't fully
                                                        // watched yet.
                                                        if (inProgress)
                                                          Positioned(
                                                            left: 3,
                                                            right: 3,
                                                            bottom: 3,
                                                            child: ClipRRect(
                                                              borderRadius:
                                                                  BorderRadius
                                                                      .circular(
                                                                          3),
                                                              child:
                                                                  LinearProgressIndicator(
                                                                value:
                                                                    progress,
                                                                minHeight: 2,
                                                                backgroundColor:
                                                                    Colors
                                                                        .white24,
                                                                valueColor:
                                                                    const AlwaysStoppedAnimation<
                                                                            Color>(
                                                                        _gold),
                                                              ),
                                                            ),
                                                          ),

                                                        if (played)
                                                          const Positioned(
                                                            top: 3,
                                                            right: 3,
                                                            child: WatchedBadge(
                                                              size: 16,
                                                            ),
                                                          ),
                                                      ],
                                                      ),
                                                    ),

                                                    const SizedBox(width: 12),

                                                    Expanded(
                                                      child: Column(
                                                        crossAxisAlignment:
                                                            CrossAxisAlignment
                                                                .start,
                                                        children: [
                                                          Text(
                                                            "Episode ${item.episodeNumber ?? (index + 1)}",
                                                            style: TextStyle(
                                                              color: playing
                                                                  ? _gold
                                                                  : Colors
                                                                      .white54,
                                                              fontSize: 12,
                                                            ),
                                                          ),
                                                          const SizedBox(
                                                              height: 2),
                                                          Text(
                                                            item.title,
                                                            maxLines: 2,
                                                            overflow:
                                                                TextOverflow
                                                                    .ellipsis,
                                                            style: TextStyle(
                                                              color: playing
                                                                  ? _gold
                                                                  : Colors
                                                                      .white,
                                                              fontSize: 14,
                                                              fontWeight: playing
                                                                  ? FontWeight
                                                                      .bold
                                                                  : FontWeight
                                                                      .normal,
                                                            ),
                                                          ),
                                                        ],
                                                      ),
                                                    ),

                                                    if (playing)
                                                      const Padding(
                                                        padding:
                                                            EdgeInsets.only(
                                                                left: 8),
                                                        child:
                                                            _EpisodeVisualizer(),
                                                      ),
                                                  ],
                                                ),
                                              ),
                                            );
                                          },
                                        );
                                      },
                                    ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Series' transparent logo shown next to the "Episodes" header, sized
/// to fit within the header row without pushing the close button out
/// of place. Not every series has a logo asset uploaded in Jellyfin,
/// so this simply disappears (rather than showing a broken-image icon
/// or placeholder box) when the request 404s.
class _SeriesLogo extends StatelessWidget {
  final String? url;

  const _SeriesLogo({super.key, required this.url});

  @override
  Widget build(BuildContext context) {
    final u = url;
    if (u == null) return const SizedBox(height: 26);
    return SizedBox(
      height: 26,
      child: Align(
        alignment: Alignment.center,
        child: Image.network(
          u,
          fit: BoxFit.contain,
          alignment: Alignment.center,
          errorBuilder: (_, __, ___) => const SizedBox.shrink(),
          loadingBuilder: (context, child, progress) {
            if (progress == null) return child;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
  }
}

/// Small pulsing bar-equalizer shown next to the now-playing episode's
/// title, matching the audio player's now-playing visualizer (same
/// bar pulse animation and same collapse-into-dots behavior on
/// pause/resume), just in this panel's gold instead of green.
class _EpisodeVisualizer extends StatefulWidget {
  const _EpisodeVisualizer();

  @override
  State<_EpisodeVisualizer> createState() => _EpisodeVisualizerState();
}

class _EpisodeVisualizerState extends State<_EpisodeVisualizer>
    with TickerProviderStateMixin {
  static const _gold = Color(0xFFFFC107);

  late final AnimationController _pulseController;
  late final AnimationController _collapseController;

  static const double _dotSize = 3;
  static const double _maxBarHeight = 12;

  @override
  void initState() {
    super.initState();

    final isPlaying = PlayerManager.instance.playing.value;

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );

    _collapseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 380),
      // Starts already-collapsed (dots) if the row appears while the
      // episode happens to be paused, otherwise starts as full bars.
      value: isPlaying ? 0.0 : 1.0,
    );

    if (isPlaying) _pulseController.repeat();

    PlayerManager.instance.playing.addListener(_onPlaybackStateChanged);
  }

  // Steps the bars and dots in and out of sync with actual playback:
  // pausing freezes the bar heights right where they are and eases
  // them down into three dots; resuming reverses that and kicks the
  // pulse back off.
  void _onPlaybackStateChanged() {
    if (PlayerManager.instance.playing.value) {
      _collapseController.reverse();
      _pulseController.repeat();
    } else {
      _pulseController.stop();
      _collapseController.forward();
    }
  }

  @override
  void dispose() {
    PlayerManager.instance.playing.removeListener(_onPlaybackStateChanged);
    _pulseController.dispose();
    _collapseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 14,
      height: _maxBarHeight,
      child: AnimatedBuilder(
        animation: Listenable.merge([_pulseController, _collapseController]),
        builder: (context, _) {
          // 0 = playing (full bars), 1 = paused (collapsed into dots).
          final collapse = Curves.easeOutCubic.transform(
            _collapseController.value,
          );

          return Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: List.generate(3, (i) {
              final t = (_pulseController.value + i * 0.33) % 1.0;
              final barHeight = _dotSize + (9 * (0.5 - (t - 0.5).abs()) * 2);

              // Bars shrink down toward a same-size dot as `collapse`
              // goes to 1, so they settle at the bottom of the box
              // rather than disappearing or jumping.
              final height = barHeight + (_dotSize - barHeight) * collapse;

              // Rounds fully into a circle once fully collapsed, and
              // stays a soft pill shape while still a bar.
              final radius = 1 + (0.5 * _dotSize - 1) * collapse;

              return Container(
                width: _dotSize,
                height: height,
                decoration: BoxDecoration(
                  color: _gold,
                  borderRadius: BorderRadius.circular(radius),
                ),
              );
            }),
          );
        },
      ),
    );
  }
}
