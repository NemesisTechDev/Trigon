import 'dart:async';

import 'package:flutter/material.dart';

import '../../player/models/media_item.dart';
import '../../player/player_manager.dart';
import '../../player/playback_service.dart';
import '../../player/screens/audio_player_screen.dart';
import '../../player/screens/player_navigation.dart';
import '../../player/services/playback_queue.dart';
import '../../services/download_manager.dart';
import '../movie_details/movie_details_screen.dart';
import '../../widgets/music/song_selection_bar.dart';
import '../../widgets/music/song_multi_select.dart';
import '../../widgets/music/playlist_picker_sheet.dart';
import '../main_nav/navigation_controller.dart';

import 'show_downloads_screen.dart';
import 'widgets/active_downloads_section.dart';
import 'widgets/downloaded_movie_tile.dart';
import 'widgets/downloaded_show_tile.dart';
import 'widgets/downloaded_song_row.dart';
import 'widgets/downloads_empty_state.dart'; // exports DownloadsBrowseMoreButton too
import 'widgets/downloads_sort_chips.dart';
import 'widgets/downloads_tab_bar.dart';
import '../../widgets/common/resistive_refresh.dart';
import '../../widgets/common/fade_scrollbar.dart';
import '../../widgets/common/category_swipe_switcher.dart';
import '../../widgets/common/collapsing_screen_label.dart';
import '../../utils/bottom_clearance.dart';

class DownloadsScreen extends StatefulWidget {
  const DownloadsScreen({super.key});

  @override
  State<DownloadsScreen> createState() => _DownloadsScreenState();
}

class _DownloadsScreenState extends State<DownloadsScreen>
    with WidgetsBindingObserver {
  DownloadsTab tab = DownloadsTab.movies;

  // Phase 5: one sort control shared across all three tabs, same as
  // Movies/Music's own single sort row applies across their tabs —
  // rather than a separately-remembered sort per Downloads tab.
  DownloadsSortOption _sort = DownloadsSortOption.recent;

  // One ScrollController per tab rather than a single shared one — per
  // CategorySwipeSwitcher's own doc comment, it keeps the outgoing tab's
  // CustomScrollView mounted alongside the incoming one for the length of
  // the swipe transition, so two lanes sharing one controller would mean
  // two live Scrollables attached to the same controller at once. Same
  // fix already applied to Movies' grid and Music's tabs for the
  // identical crash.
  final Map<DownloadsTab, ScrollController> _scrollControllers = {
    for (final t in DownloadsTab.values) t: ScrollController(),
  };
  ScrollController get _scrollController => _scrollControllers[tab]!;

  static const List<DownloadsTab> _tabOrder = [
    DownloadsTab.movies,
    DownloadsTab.shows,
  ];

  // Keeps this page honest about what's actually still sitting in the
  // device's Downloads > Nemesis folder: a file (or a whole album/
  // movie/show folder) removed from outside the app — a file manager,
  // another app, whatever — should stop showing up here without
  // requiring an explicit pull-to-refresh. DownloadManager.refresh()
  // re-validates every record's file against disk and drops anything
  // that's gone, so a light poll while this screen is actually visible
  // is enough to make that feel live without any platform-specific
  // filesystem-watcher plumbing.
  Timer? _liveSyncTimer;

  // Hold-to-multi-select for the Songs tab of Downloads. Bulk actions
  // here skip "Download" (everything shown is already downloaded) and
  // use Delete instead of Remove-from-Playlist for the destructive one.
  final SongMultiSelect _songSelect = SongMultiSelect();

  void _enterSongSelection(String id) {
    setState(() => _songSelect.enter(id));
  }

  void _toggleSongSelection(String id) {
    setState(() => _songSelect.toggle(id));
  }

  void _exitSongSelection() {
    setState(() => _songSelect.clear());
  }

  List<DownloadRecord> _selectedRecords(List<DownloadRecord> songs) => songs
      .where((r) => _songSelect.selectedIds.contains(r.id))
      .toList();

  Future<void> _bulkAddSelectedSongsToQueue(List<DownloadRecord> songs) async {
    final selected = _selectedRecords(songs);
    if (selected.isEmpty) return;

    final messenger = ScaffoldMessenger.maybeOf(context);

    // Same reasoning as the single-song "Add to Queue" action — nothing
    // playing means there's no "current song" for these to queue up
    // after, so tell the user to start playback first instead of
    // silently starting it on their behalf.
    if (PlayerManager.instance.currentItem == null) {
      _exitSongSelection();
      messenger?.showSnackBar(
        const SnackBar(
          content: Text("Play something first to add songs to the queue"),
        ),
      );
      return;
    }

    final items =
        selected.map((r) => DownloadManager.instance.mediaItemForRecord(r)).toList();
    for (final mediaItem in items) {
      PlaybackQueue.instance.addToQueue(mediaItem);
    }

    _exitSongSelection();
    messenger?.showSnackBar(
      SnackBar(
        content: Text(
          '${items.length} song${items.length == 1 ? '' : 's'} added to queue',
        ),
      ),
    );
  }

  /// "Play selected": a brand-new queue of exactly the selected
  /// downloaded songs, in list order.
  Future<void> _bulkPlaySelectedSongs(List<DownloadRecord> songs) async {
    final selected = _selectedRecords(songs);
    if (selected.isEmpty) return;

    _exitSongSelection();
    await _playSongs(selected);
  }

  void _bulkAddSelectedSongsToPlaylist(List<DownloadRecord> songs) {
    final selected = _selectedRecords(songs);
    if (selected.isEmpty) return;

    showPlaylistPickerSheetMulti(
      context,
      selected.map((r) => r.raw).toList(),
    );
    _exitSongSelection();
  }

  Future<void> _bulkDeleteSelectedSongs(List<DownloadRecord> songs) async {
    final selected = _selectedRecords(songs);
    if (selected.isEmpty) return;

    final confirmed = await _confirm(
      selected.length == 1
          ? selected.first.title
          : '${selected.length} songs',
    );
    if (!confirmed) return;

    setState(() => _songSelect.busy = true);

    for (final record in selected) {
      try {
        await DownloadManager.instance.deleteDownload(record.id);
      } catch (e) {
        debugPrint(e.toString());
      }
    }

    _exitSongSelection();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Safe to call even if main.dart's startup call already ran — init()
    // is a no-op after the first successful load.
    DownloadManager.instance.init();
    // Catches anything deleted externally while this page was closed —
    // e.g. the person cleared out old episodes in a file manager, then
    // reopened the app straight to Downloads.
    DownloadManager.instance.refresh();
    _startLiveSync();

    // A tap on a download notification (see DownloadNotificationService)
    // asks for a specific sub-tab via NavigationController. Applied
    // straight onto `tab` here for the case where this screen is first
    // built after the request was made (cold start from a
    // notification), and via the listener below for when it's already
    // mounted in MainNavScreen's IndexedStack.
    final pending = _takePendingTab();
    if (pending != null) tab = pending;
    NavigationController.instance.addListener(_onNavigationChanged);
  }

  DownloadsTab? _takePendingTab() {
    final pending = NavigationController.instance.pendingDownloadsTab;
    if (pending == null) return null;
    NavigationController.instance.pendingDownloadsTab = null;
    // NAMESIS PRIME: no Music tab on this screen any more.
    for (final t in _tabOrder) {
      if (t.name == pending) return t;
    }
    return null;
  }

  void _onNavigationChanged() {
    final pending = _takePendingTab();
    if (pending == null || !mounted || pending == tab) return;
    _changeTab(pending);
  }

  void _startLiveSync() {
    _liveSyncTimer?.cancel();
    _liveSyncTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted) return;
      // Only worth doing while this page is actually on screen. Each
      // refresh re-reads and re-parses the whole download index from
      // disk on the UI isolate; running it every 5 seconds behind other
      // tabs and behind pushed detail screens put a periodic hitch into
      // every scroll and page transition elsewhere in the app. Coming
      // back to this tab/page catches up on the next tick (or via
      // pull-to-refresh / app resume, which refresh immediately).
      final onScreen =
          NavigationController.instance.tabIndex == NavTabs.downloads &&
              (ModalRoute.of(context)?.isCurrent ?? true);
      if (onScreen) DownloadManager.instance.refresh();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Covers switching to a file manager (or another app) to delete a
    // download, then switching straight back — the change should
    // already be reflected the moment this page is visible again
    // rather than waiting up to 5 seconds for the next poll.
    if (state == AppLifecycleState.resumed) {
      DownloadManager.instance.refresh();
    }
  }

  @override
  void dispose() {
    _liveSyncTimer?.cancel();
    NavigationController.instance.removeListener(_onNavigationChanged);
    WidgetsBinding.instance.removeObserver(this);
    for (final controller in _scrollControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  /// Shared by the tab bar's tap handler and the swipe gesture below, so
  /// both ways of switching tabs clear any in-progress song selection
  /// the same way.
  void _changeTab(DownloadsTab t) {
    _songSelect.clear();
    setState(() => tab = t);
  }

  /// Swipe axis: left-right moves between Movies/TV Shows/Music, same
  /// order as the tab bar. Clamped at either end rather than wrapping
  /// around — matches Movies/Music's swipe behavior.
  void _swipeTab(int delta) {
    final index = _tabOrder.indexOf(tab);
    final nextIndex = index + delta;
    if (nextIndex < 0 || nextIndex >= _tabOrder.length) return;
    _changeTab(_tabOrder[nextIndex]);
  }

  Future<bool> _confirm(String name) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xff1E1E1E),
        title: const Text(
          "Remove download?",
          style: TextStyle(color: Colors.white),
        ),
        content: Text(
          '"$name" will be deleted from your device.',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text("Cancel"),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              "Remove",
              style: TextStyle(color: Colors.redAccent),
            ),
          ),
        ],
      ),
    );
    return result == true;
  }

  Future<void> _deleteMovie(DownloadRecord record) async {
    if (await _confirm(record.title)) {
      await DownloadManager.instance.deleteDownload(record.id);
    }
  }

  Future<void> _deleteShow(String seriesId, String seriesName) async {
    if (await _confirm(seriesName)) {
      await DownloadManager.instance.deleteSeries(seriesId);
    }
  }

  Future<void> _deleteSong(DownloadRecord record) async {
    if (await _confirm(record.title)) {
      await DownloadManager.instance.deleteDownload(record.id);
    }
  }

  void _openMovie(DownloadRecord record) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MovieDetailsScreen(
          itemId: record.id,
          initialItem: Map<String, dynamic>.from(record.raw),
        ),
      ),
    );
  }

  // Backs the movie row's "Play Download" sheet action — same
  // local-file-first pattern MovieDetailsScreen's own Play button uses
  // for a downloaded movie (DownloadManager.mediaItemFor already
  // prefers the on-disk file over a network stream), just entered
  // directly instead of routing through the details screen first.
  Future<void> _playMovie(DownloadRecord record) async {
    final media = DownloadManager.instance.mediaItemForRecord(record);

    PlayerManager.instance.showLoadingPreview(media);
    unawaited(PlaybackService.playItem(media));

    if (!mounted) return;
    await PlayerNavigation.open(context);
  }

  void _openShow(String seriesId, String seriesName) {
    // A dedicated, downloads-only screen instead of the full
    // MovieDetailsScreen(downloadedOnly: true) this used to push — see
    // ShowDownloadsScreen's own doc comment for why: a hero backdrop,
    // overview, cast/crew, etc. don't mean anything for a device's own
    // downloaded episodes.
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ShowDownloadsScreen(
          seriesId: seriesId,
          seriesName: seriesName,
        ),
      ),
    );
  }

  Future<void> _playSongs(
    List<DownloadRecord> records, {
    int startIndex = 0,
  }) async {
    if (records.isEmpty) return;

    // Same "was something already playing" pattern the Music tab uses —
    // only jump into the full player automatically on a fresh session,
    // otherwise let the mini player just switch tracks in place.
    final wasAlreadyPlaying = PlayerManager.instance.currentItem != null;

    final queue = records
        .map((r) => DownloadManager.instance.mediaItemForRecord(r))
        .toList();

    if (!wasAlreadyPlaying) {
      // Pushes the player immediately with a loading preview instead of
      // waiting on playQueue() to actually open the stream first — same
      // pattern the video player already uses for "Play". playQueue()
      // below overwrites the preview with the real resolved item, and
      // any failure surfaces via the error overlay on AudioPlayerScreen
      // itself rather than a SnackBar back here.
      PlayerManager.instance.showLoadingPreview(queue[startIndex]);

      Navigator.of(context, rootNavigator: true).push(
        MaterialPageRoute(builder: (_) => const AudioPlayerScreen()),
      );

      await PlaybackService.playQueue(
        queue,
        startIndex: startIndex,
        source: PlaybackSource.playlist,
        title: "Downloads",
      );
      return;
    }

    // Already playing something, so there's no screen being pushed here
    // to show an error overlay on — surface a failure with a SnackBar
    // instead.
    await PlaybackService.playQueue(
      queue,
      startIndex: startIndex,
      source: PlaybackSource.playlist,
      title: "Downloads",
    );

    if (!mounted) return;

    final error = PlayerManager.instance.lastError.value;
    if (error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: DownloadManager.instance,
      builder: (context, _) {
        // Phase 5: sorted once here per build so every reader below
        // (grid, counts, empty-state check) sees the same order —
        // counts/emptiness are unaffected by sort choice, only order is.
        final movies = _applySort(DownloadManager.instance.movies);
        final showsMap = DownloadManager.instance.episodesBySeries;
        final songs = _applySort(DownloadManager.instance.songs);

        // Items still transferring (or waiting in the queue) no longer
        // get their own block above the list — each tab draws its own
        // kind's tasks inline, in the spot they'll settle into once
        // finished. TV episodes are grouped under their series (an
        // episode task's imageId is the series id).
        final activeTasks = <DownloadTask>[
          ...DownloadManager.instance.downloadingTasks,
          // Paused tasks stay listed (shown as "Paused"), like paused
          // episodes do, instead of vanishing until resumed.
          ...DownloadManager.instance.pausedTasks,
          ...DownloadManager.instance.queuedTasks,
        ];
        final movieTasks = activeTasks
            .where((t) => t.kind == DownloadKind.movie)
            .toList();
        final songTasks = activeTasks
            .where((t) => t.kind == DownloadKind.song)
            .toList();
        final showTasks = <String, List<DownloadTask>>{};
        for (final t in activeTasks) {
          if (t.kind != DownloadKind.episode) continue;
          showTasks.putIfAbsent(t.imageId, () => []).add(t);
        }

        // Aspect-scoped — only rebuilds this screen when device padding
        // itself changes (rotation, notch/gesture-area changes), never
        // on keyboard insets (this screen's own, or — since every
        // bottom-nav tab is kept alive together in an IndexedStack —
        // one open on a completely different tab).
        final viewPadding = MediaQuery.paddingOf(context);

        return Scaffold(
          // Matches the app-wide page background every other bottom-nav
          // tab uses (Home, Live TV, Music, Movies) — was still on the
          // older 0xff111111 shade, so switching into Downloads visibly
          // shifted the background color.
          backgroundColor: const Color(0xff161616),
          // No bottom padding is added below (see the Padding replacing
          // SafeArea further down) — matches every other tab's scaffold
          // so the glass bottom nav bar keeps blurring real scrolled
          // content instead of a hard SafeArea edge.
          //
          // Was SafeArea(bottom: false) here. SafeArea's own build()
          // calls the *unscoped* MediaQuery.of(context) internally,
          // which subscribes it to every MediaQueryData field —
          // including viewInsets.bottom, which the framework updates
          // every single frame while any keyboard is sliding open or
          // closed anywhere in the app. That forced this whole
          // title/stats/tab-bar/list tree to rebuild from scratch in
          // lockstep with the keyboard's own animation — the same
          // app-wide stutter fixed the same way on Music/Movies/Live TV.
          // A plain Padding using the aspect-scoped `viewPadding` above
          // gets the identical top/left/right safe-area values (bottom
          // was already excluded) but only rebuilds when device padding
          // itself actually changes.
          body: Padding(
            padding: EdgeInsets.only(
              top: viewPadding.top,
              left: viewPadding.left,
              right: viewPadding.right,
            ),
            // Title, stats header, and the tab bar stay fixed in place
            // (a plain Column) — only the grid/list below scrolls, in
            // its own nested CustomScrollView. Matches the Music
            // screen's fixed header.
            // LabelCollapseScope: the "Downloads" label slides away on
            // scroll down and returns on scroll up (see
            // collapsing_screen_label.dart); the stats header and tab bar
            // stay pinned. resetKey brings the label back on a tab switch.
            child: LabelCollapseScope(
              resetKey: tab,
              child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 8 stays above the pinned rows even while the label is
                // collapsed; the other 7 of the old 15 top margin
                // collapses with the label (or is added back for the
                // selection bar, which never collapses).
                const SizedBox(height: kCollapsedLabelTopGap),

                if (_songSelect.active && tab == DownloadsTab.music) ...[
                  const SizedBox(height: 7),
                  SongSelectionBar(
                    count: _songSelect.count,
                    busy: _songSelect.busy,
                    onClose: _exitSongSelection,
                    onPlaySelected: () => _bulkPlaySelectedSongs(songs),
                    onAddToQueue: () => _bulkAddSelectedSongsToQueue(songs),
                    onAddToPlaylist: () =>
                        _bulkAddSelectedSongsToPlaylist(songs),
                    onDelete: () => _bulkDeleteSelectedSongs(songs),
                    deleteLabel: "Delete",
                  ),
                  const SizedBox(height: 15),
                ]
                else ...[
                  // Label-to-first-row gap is 15, matching the other
                  // screens. It's part of the collapsing block. The tab
                  // bar below is the first row now — the space-used
                  // indicator that used to sit here was moved to the
                  // Storage section of Settings (StorageUsageCard),
                  // where it can show the full app/cache/downloads
                  // breakdown instead of just the downloads slice.
                  const CollapsibleLabel(
                    topPadding: 7,
                    bottomPadding: 15,
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: 20),
                      child: Text(
                        "Downloads",
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 30,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),

                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: DownloadsTabBar(
                      selected: tab,
                      onChanged: _changeTab,
                      movieCount: movies.length,
                      showCount: showsMap.length,
                      songCount: songs.length,
                    ),
                  ),
                ],

                const SizedBox(height: 22),

                Expanded(
                  child: CategorySwipeSwitcher(
                    categoryKey: tab,
                    onSwipeNext: () => _swipeTab(1),
                    onSwipePrevious: () => _swipeTab(-1),
                    child: ResistiveRefresh(
                    onRefresh: DownloadManager.instance.refresh,
                    color: const Color(0xffD4AF37),
                    backgroundColor: const Color(0xff232323),
                    child: FadeScrollbar(
                    controller: _scrollController,
                    child: CustomScrollView(
                      controller: _scrollController,

                      // A short downloads list (a handful of items, or
                      // none) doesn't overflow the viewport, which
                      // otherwise leaves the pull gesture with nothing
                      // to grab onto.
                      physics: const AlwaysScrollableScrollPhysics(),
                      // Without a key, switching tabs reuses the same
                      // underlying Scrollable/ScrollPosition (same
                      // widget type, same spot in the tree) even though
                      // the slivers inside it changed — so a scroll
                      // offset left over from a longer tab could carry
                      // into an empty tab and shove its centered empty
                      // state out of view. Keying on the tab forces a
                      // fresh ScrollPosition (starting at 0) every time.
                      key: ValueKey(tab),
                      slivers: [
                        ...buildActiveDownloadsSection(
                          context,
                          kinds: switch (tab) {
                            DownloadsTab.movies => {DownloadKind.movie},
                            DownloadsTab.shows => {DownloadKind.episode},
                            DownloadsTab.music => {DownloadKind.song},
                          },
                        ),
                        ..._buildBody(
                          movies,
                          showsMap,
                          songs,
                          movieTasks,
                          showTasks,
                          songTasks,
                        ),

                        // Dynamic clearance for the glass mini-player/tab
                        // bar, same as every other tab. Only added when
                        // there's real content below it — appending this
                        // after an empty tab's SliverFillRemaining (which
                        // already fills the full viewport) would push
                        // the total sliver height past the viewport,
                        // making an otherwise-empty screen scrollable
                        // and letting its centered empty state drift out
                        // of the middle once dragged.
                        if (!_currentTabIsEmpty(
                          movies,
                          showsMap,
                          songs,
                          movieTasks,
                          showTasks,
                          songTasks,
                        ))
                          SliverToBoxAdapter(
                            child: BottomClearanceBuilder(
                              builder: (context, bottomClearance) => SizedBox(
                                height: 20 +
                                    MediaQuery.paddingOf(context).bottom +
                                    bottomClearance,
                              ),
                            ),
                          ),
                      ],
                    
                    ),
                  ),
                  ),
                  ),
                ),
              ],
            ),
            ),
          ),
        );
      },
    );
  }

  /// Orders a flat record list (Movies or Songs) by the current sort
  /// choice. [DownloadManager.movies]/[.songs] already come back sorted
  /// newest-first, so `recent` re-sorting here is a harmless no-op —
  /// keeping it in the switch means there's one place that knows what
  /// each option means instead of the "recent" case living implicitly
  /// in DownloadManager while the other two live here.
  List<DownloadRecord> _applySort(List<DownloadRecord> records) {
    final list = List<DownloadRecord>.from(records);
    switch (_sort) {
      case DownloadsSortOption.recent:
        list.sort((a, b) => b.addedAt.compareTo(a.addedAt));
        break;
      case DownloadsSortOption.az:
        list.sort(
          (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
        );
        break;
      case DownloadsSortOption.largest:
        list.sort((a, b) => b.fileSizeBytes.compareTo(a.fileSizeBytes));
        break;
    }
    return list;
  }

  /// Same three orderings as [_applySort], but for the TV Shows tab's
  /// series groups: "recent" uses each series' most recently downloaded
  /// episode, "largest" sums every episode's file size, and "A-Z" reads
  /// the series name straight off the first episode (all episodes in a
  /// group share one seriesName). Episode order *within* a series stays
  /// untouched — only which series comes first changes.
  ///
  /// A series with nothing finished yet (only an episode in flight) has
  /// no records to sort by, so it's ordered from its tasks instead: at
  /// the top under "recent" (it will be the newest download the moment
  /// it lands), by name under "A-Z", and by bytes so far under
  /// "largest".
  List<String> _sortedSeriesIds(
    Map<String, List<DownloadRecord>> showsMap,
    Map<String, List<DownloadTask>> showTasks,
  ) {
    final ids = <String>{...showsMap.keys, ...showTasks.keys}.toList();

    int taskBytes(DownloadTask t) =>
        t.totalBytes > 0 ? t.totalBytes : t.downloadedBytes;
    int latestAddedAt(String id) {
      final records = showsMap[id];
      if (records != null) {
        return records.fold<int>(
            0, (latest, r) => r.addedAt > latest ? r.addedAt : latest);
      }
      return (showTasks[id] ?? const <DownloadTask>[]).fold<int>(
          0, (latest, t) => t.addedAt > latest ? t.addedAt : latest);
    }

    int totalSize(String id) {
      final records = showsMap[id];
      if (records != null) {
        return records.fold<int>(0, (sum, r) => sum + r.fileSizeBytes);
      }
      return (showTasks[id] ?? const <DownloadTask>[])
          .fold<int>(0, (sum, t) => sum + taskBytes(t));
    }

    String name(String id) =>
        _seriesName(showsMap[id] ?? const <DownloadRecord>[], showTasks[id])
            .toLowerCase();

    switch (_sort) {
      case DownloadsSortOption.recent:
        ids.sort((a, b) {
          final aActiveOnly = !showsMap.containsKey(a);
          final bActiveOnly = !showsMap.containsKey(b);
          if (aActiveOnly != bActiveOnly) return aActiveOnly ? -1 : 1;
          return latestAddedAt(b).compareTo(latestAddedAt(a));
        });
        break;
      case DownloadsSortOption.az:
        ids.sort((a, b) => name(a).compareTo(name(b)));
        break;
      case DownloadsSortOption.largest:
        ids.sort((a, b) => totalSize(b).compareTo(totalSize(a)));
        break;
    }
    return ids;
  }

  /// A series' display name: read off its first finished episode when
  /// there is one (all episodes in a group share one seriesName),
  /// otherwise off its in-flight task's Jellyfin item.
  String _seriesName(List<DownloadRecord> episodes, List<DownloadTask>? tasks) {
    if (episodes.isNotEmpty) {
      return episodes.first.seriesName ?? episodes.first.title;
    }
    final task = (tasks != null && tasks.isNotEmpty) ? tasks.first : null;
    return task?.item['SeriesName']?.toString() ?? task?.title ?? '';
  }

  /// Puts in-progress [tasks] into the same list as the finished
  /// [records] (already sorted by [_applySort]), each landing where it
  /// will sit once it completes: at the top under "recent" — a
  /// finishing download is stamped with the completion time, so it's
  /// always the newest — by title under "A-Z", and by bytes so far
  /// under "largest". Returns [DownloadRecord]s and [DownloadTask]s.
  List<Object> _mergeWithTasks(
    List<DownloadRecord> records,
    List<DownloadTask> tasks,
  ) {
    if (tasks.isEmpty) return List<Object>.from(records);

    int taskBytes(DownloadTask t) =>
        t.totalBytes > 0 ? t.totalBytes : t.downloadedBytes;

    switch (_sort) {
      case DownloadsSortOption.recent:
        final ordered = List<DownloadTask>.from(tasks)
          ..sort((a, b) => b.addedAt.compareTo(a.addedAt));
        return <Object>[...ordered, ...records];
      case DownloadsSortOption.az:
        String title(Object o) =>
            (o is DownloadRecord ? o.title : (o as DownloadTask).title)
                .toLowerCase();
        return <Object>[...records, ...tasks]
          ..sort((a, b) => title(a).compareTo(title(b)));
      case DownloadsSortOption.largest:
        int size(Object o) => o is DownloadRecord
            ? o.fileSizeBytes
            : taskBytes(o as DownloadTask);
        return <Object>[...records, ...tasks]
          ..sort((a, b) => size(b).compareTo(size(a)));
    }
  }

  /// Phase 5: sort/filter chip row shown above each non-empty tab's
  /// content (Recently downloaded / A-Z / Largest first), matching the
  /// sort-chip pattern already used on the Movies and Music screens.
  /// Left out of the empty-state branches — a sort control has nothing
  /// to act on there.
  Widget _buildSortRow() {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
        child: DownloadsSortChips(
          selected: _sort,
          onSelected: (value) => setState(() => _sort = value),
        ),
      ),
    );
  }

  List<Widget> _buildBody(
    List<DownloadRecord> movies,
    Map<String, List<DownloadRecord>> showsMap,
    List<DownloadRecord> songs,
    List<DownloadTask> movieTasks,
    Map<String, List<DownloadTask>> showTasks,
    List<DownloadTask> songTasks,
  ) {
    switch (tab) {
      case DownloadsTab.movies:
        return _movieSection(movies, movieTasks);
      case DownloadsTab.shows:
        return _showSection(showsMap, showTasks);
      case DownloadsTab.music:
        return _songSection(songs, songTasks);
    }
  }

  /// Whether the currently selected tab has nothing to show. Used to
  /// decide whether the trailing bottom-clearance sliver should be
  /// appended — see the note where it's used in build().
  bool _currentTabIsEmpty(
    List<DownloadRecord> movies,
    Map<String, List<DownloadRecord>> showsMap,
    List<DownloadRecord> songs,
    List<DownloadTask> movieTasks,
    Map<String, List<DownloadTask>> showTasks,
    List<DownloadTask> songTasks,
  ) {
    switch (tab) {
      case DownloadsTab.movies:
        return movies.isEmpty && movieTasks.isEmpty;
      case DownloadsTab.shows:
        return showsMap.isEmpty && showTasks.isEmpty;
      case DownloadsTab.music:
        return songs.isEmpty && songTasks.isEmpty;
    }
  }

  List<Widget> _movieSection(
    List<DownloadRecord> movies,
    List<DownloadTask> movieTasks,
  ) {
    if (movies.isEmpty && movieTasks.isEmpty) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          // Phase 3 fix: was Center(...), which put this dead center —
          // the handout called for "roughly a third of the way down,
          // not dead center" specifically so it reads as a designed
          // state rather than a placeholder. Align's y maps -1..1 to
          // 0..1 of the available height; -0.35 puts the empty state's
          // vertical center at ~32% down, which is what "a third" reads
          // as once the block's own height (icon + copy + button) is
          // accounted for.
          child: Align(
            alignment: const Alignment(0, -0.35),
            child: DownloadsEmptyState(
              icon: Icons.movie_creation_outlined,
              title: "No downloaded movies",
              subtitle:
                  "Movies you download for offline playback will show up here.",
              ctaLabel: "Browse Movies",
              ctaTargetTab: NavTabs.movies,
              ctaPendingMode: "movies",
            ),
          ),
        ),
      ];
    }

    final entries = _mergeWithTasks(movies, movieTasks);

    return [
      _buildSortRow(),
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        sliver: SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, index) {
              final entry = entries[index];
              if (entry is DownloadTask) {
                return InProgressDownloadRow(
                  key: ValueKey('progress-${entry.id}'),
                  task: entry,
                );
              }
              final record = entry as DownloadRecord;
              return DownloadedMovieTile(
                record: record,
                onTap: () => _openMovie(record),
                onPlay: () => _playMovie(record),
                onDelete: () => _deleteMovie(record),
              );
            },
            childCount: entries.length,
          ),
        ),
      ),
      _browseMoreSliver(
        label: "Browse Movies",
        targetTab: NavTabs.movies,
        pendingMode: "movies",
      ),
    ];
  }

  /// The "Browse ___" CTA, kept visible below an already-populated
  /// list — not just in the empty state — so there's always a way to
  /// find more to download.
  Widget _browseMoreSliver({
    required String label,
    required int targetTab,
    String? pendingMode,
  }) {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        child: Center(
          child: DownloadsBrowseMoreButton(
            label: label,
            targetTab: targetTab,
            pendingMode: pendingMode,
          ),
        ),
      ),
    );
  }

  List<Widget> _showSection(
    Map<String, List<DownloadRecord>> showsMap,
    Map<String, List<DownloadTask>> showTasks,
  ) {
    if (showsMap.isEmpty && showTasks.isEmpty) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          // See _movieSection's identical fix above for why Align
          // replaced Center here.
          child: Align(
            alignment: const Alignment(0, -0.35),
            child: DownloadsEmptyState(
              icon: Icons.live_tv_outlined,
              title: "No downloaded TV Shows",
              subtitle:
                  "TV Shows you download for offline playback will show up here.",
              ctaLabel: "Browse TV Shows",
              ctaTargetTab: NavTabs.tvShows,
              ctaPendingMode: "tvshows",
            ),
          ),
        ),
      ];
    }

    // Phase 5: which series comes first, per the shared sort control —
    // see _sortedSeriesIds for what each option means for a group.
    final seriesIds = _sortedSeriesIds(showsMap, showTasks);

    return [
      _buildSortRow(),
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        sliver: SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, index) {
              final seriesId = seriesIds[index];
              // Empty for a series whose first episode is still
              // transferring — its row still shows, marked "Download
              // in progress", in the spot it'll settle into.
              final episodes =
                  showsMap[seriesId] ?? const <DownloadRecord>[];
              final seriesName =
                  _seriesName(episodes, showTasks[seriesId]);

              return DownloadedShowTile(
                seriesId: seriesId,
                seriesName: seriesName,
                episodes: episodes,
                onTap: () => _openShow(seriesId, seriesName),
                onDelete: () => _deleteShow(seriesId, seriesName),
              );
            },
            childCount: seriesIds.length,
          ),
        ),
      ),
      _browseMoreSliver(
        label: "Browse TV Shows",
        targetTab: NavTabs.tvShows,
        pendingMode: "tvshows",
      ),
    ];
  }

  List<Widget> _songSection(
    List<DownloadRecord> songs,
    List<DownloadTask> songTasks,
  ) {
    if (songs.isEmpty && songTasks.isEmpty) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          // See _movieSection's identical fix above for why Align
          // replaced Center here.
          child: Align(
            alignment: const Alignment(0, -0.35),
            child: DownloadsEmptyState(
              icon: Icons.music_note_outlined,
              title: "No downloaded songs",
              subtitle:
                  "Songs you download for offline playback will show up here.",
              ctaLabel: "Browse Music",
              ctaTargetTab: NavTabs.music,
            ),
          ),
        ),
      ];
    }

    final entries = _mergeWithTasks(songs, songTasks);

    return [
      _buildSortRow(),
      SliverList(
        delegate: SliverChildBuilderDelegate(
          (context, index) {
            final entry = entries[index];
            if (entry is DownloadTask) {
              return InProgressDownloadRow(
                key: ValueKey('progress-${entry.id}'),
                task: entry,
              );
            }
            final record = entry as DownloadRecord;
            // Position among the finished songs only — the play queue
            // is built from [songs], which has no in-progress rows.
            final songIndex = songs.indexOf(record);
            final selected = _songSelect.isSelected(record.id);

            return ValueListenableBuilder<MediaItem?>(
              valueListenable: PlayerManager.instance.currentItemNotifier,
              builder: (context, current, _) {
                return DownloadedSongRow(
                  record: record,
                  playing: current != null && current.id == record.id,
                  selectionMode: _songSelect.active,
                  selected: selected,
                  onLongPress: _songSelect.active
                      ? null
                      : () => _enterSongSelection(record.id),
                  onTap: _songSelect.active
                      ? () => _toggleSongSelection(record.id)
                      : () => _playSongs(songs, startIndex: songIndex),
                  onPlay: () => _playSongs(songs, startIndex: songIndex),
                  onDelete: () => _deleteSong(record),
                );
              },
            );
          },
          childCount: entries.length,
        ),
      ),
      _browseMoreSliver(
        label: "Browse Music",
        targetTab: NavTabs.music,
      ),
    ];
  }
}
