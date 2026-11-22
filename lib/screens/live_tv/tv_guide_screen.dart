import 'dart:async';

import 'package:flutter/material.dart';

import '../../player/playback_service.dart';
import '../../player/player_manager.dart';
import '../../player/screens/player_navigation.dart';
import '../../services/jellyfin_services/media_service.dart';
import '../../utils/channel_categories.dart';
import '../../utils/epg_utils.dart';
import '../../utils/responsive.dart';
import '../../widgets/live_tv/category_chips_row.dart';
import '../../widgets/live_tv/guide_channel_tile.dart';
import '../../widgets/live_tv/guide_program_tile.dart';
import '../../widgets/live_tv/guide_time_header.dart';
import '../../widgets/common/pressable.dart';
import '../../widgets/shared/selector_dropdown.dart';
import '../../widgets/common/resistive_refresh.dart';
import '../../widgets/common/fade_scrollbar.dart';
import '../../widgets/common/collapsing_screen_label.dart';
import '../../utils/bottom_clearance.dart';

class TvGuideScreen extends StatefulWidget {
  /// Channels the caller already has in memory (Live TV's screen fetches
  /// this same list to render its own rows). When provided, the guide
  /// skips its own `/LiveTv/Channels` call entirely on open instead of
  /// re-fetching an identical list from scratch — that duplicate fetch
  /// was the actual cause of the guide appearing to hang: it's the same
  /// slow call Live TV's screen makes, just not noticed there because it
  /// happens once at that screen's own load instead of a second time
  /// right as the guide opens.
  final List<Map<String, dynamic>>? initialChannels;

  /// When set (the Live TV detail screen's "Full guide" buttons), the
  /// guide scrolls that channel's row into view as soon as the grid is
  /// on screen and briefly highlights it, instead of opening at the top
  /// of the channel list.
  final String? focusChannelId;

  const TvGuideScreen({super.key, this.initialChannels, this.focusChannelId});

  @override
  State<TvGuideScreen> createState() => _TvGuideScreenState();
}

class _TvGuideScreenState extends State<TvGuideScreen> {
  static const _channelColumnWidth = 130.0;
  static const _rowHeight = 108.0;

  final _headerController = ScrollController();
  final _timelineController = ScrollController();

  // Vertical scroll is now driven by two lazy ListViews (channel names +
  // program rows) that must stay in sync, the same way the horizontal
  // header/timeline controllers already do.
  final _channelListController = ScrollController();
  final _rowsListController = ScrollController();
  bool _syncingVertical = false;

  Timer? _timer;

  /// True until [TvGuideScreen.focusChannelId]'s row has been scrolled
  /// into view (see [_scheduleFocusScroll]).
  late bool _focusPending =
      (widget.focusChannelId ?? '').isNotEmpty;

  /// The row currently wearing the gold "this is your channel" highlight,
  /// and whether it is in its fade-out.
  String? _highlightChannelId;
  bool _highlightFading = false;
  Timer? _highlightTimer;

  List<Map<String, dynamic>> _channels = const [];
  List<Map<String, dynamic>> _programs = const [];

  /// Precomputed once per load (and once per minute tick) instead of being
  /// recomputed via a linear filter+sort on every single build.
  Map<String, List<Map<String, dynamic>>> _programsByChannel = const {};
  Map<String, bool> _isPlayingByChannel = const {};

  String? _error;
  bool _loading = true;

  /// True only until the very first [_loadGuide] call has consumed (or
  /// declined) the chance to reuse [TvGuideScreen.initialChannels] — see
  /// [_loadGuide]. Tracked separately from `_channels.isEmpty` because
  /// [initState] now fills `_channels` in synchronously, before that
  /// first call even runs (see below), so emptiness alone can no longer
  /// tell "haven't loaded yet" apart from "loaded, but happened to come
  /// back with zero channels".
  bool _usingPrefilledChannels = false;

  // Bumped on every _loadGuide() call (initial load, refresh button, or
  // pull-to-refresh) and captured locally by that call. Each pass below
  // checks its own snapshot against the live value before applying its
  // result — without this, a slower *older* request finishing after a
  // newer one (very possible: the quick pass is fast but the background
  // full-day pass isn't, so tapping refresh while it's still in flight
  // used to let its stale result land after the new request's, silently
  // undoing the refresh) would win and overwrite fresher data.
  int _loadGeneration = 0;

  String _selectedCategory = 'All';

  // Same category list/icons the portrait chip row builds one at a time
  // via _buildCategoryChip — the landscape dropdown needs both together.
  static const List<String> _categories = [
    'All',
    'Sports',
    'Movies',
    'News',
    'Kids',
    'Music',
    'Documentaries',
    'Entertainment',
  ];

  static const Map<String, IconData> _categoryIcons = {
    'All': Icons.apps_rounded,
    'Sports': Icons.sports_soccer,
    'Movies': Icons.movie,
    'News': Icons.newspaper,
    'Kids': Icons.child_care,
    'Music': Icons.music_note,
    'Documentaries': Icons.menu_book,
    'Entertainment': Icons.theaters,
  };

  /// Landscape-only search box (mirrors Movies/Music/All Channels),
  /// matching channel name or its currently-airing program's title.
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  Timer? _searchDebounce;
  String _search = '';

  /// The date this guide is currently showing (day-only, no time-of-day).
  /// Defaults to today.
  DateTime _selectedDate = _dateOnly(DateTime.now());

  static DateTime _dateOnly(DateTime date) =>
      DateTime(date.year, date.month, date.day);

  bool get _isViewingToday =>
      _selectedDate == _dateOnly(DateTime.now());

  /// Sunday-to-Saturday strip for the current calendar week.
  List<DateTime> get _guideDays {
    final today = _dateOnly(DateTime.now());
    // DateTime.weekday: Monday=1 ... Sunday=7. Step back to that week's
    // Sunday (0 days back if today already is Sunday).
    final startOfWeek = today.subtract(Duration(days: today.weekday % 7));
    return List.generate(7, (i) => startOfWeek.add(Duration(days: i)));
  }

  /// [_filteredChannels] is read many times per build — twice for the
  /// channel column and timeline lists' `itemCount`, plus once per
  /// visible row in each of their `itemBuilder`s — so it's memoized here
  /// rather than re-filtering (and re-classifying every channel) on each
  /// access. The cache key is just reference equality on `_channels`
  /// (only ever reassigned wholesale on load) plus the selected category,
  /// both cheap checks.
  List<Map<String, dynamic>>? _filteredChannelsCache;
  List<Map<String, dynamic>>? _filteredChannelsCacheSource;
  String? _filteredChannelsCacheCategory;
  String? _filteredChannelsCacheSearch;

  List<Map<String, dynamic>> get _filteredChannels {
    if (identical(_filteredChannelsCacheSource, _channels) &&
        _filteredChannelsCacheCategory == _selectedCategory &&
        _filteredChannelsCacheSearch == _search) {
      return _filteredChannelsCache!;
    }

    final query = _search.trim().toLowerCase();

    final result = _channels.where((channel) {
      final name = (channel['Name'] ?? '').toString();

      if (_selectedCategory != 'All' &&
          ChannelCategories.classify(name) != _selectedCategory) {
        return false;
      }

      if (query.isEmpty) return true;

      if (name.toLowerCase().contains(query)) return true;

      final channelId = channel['Id']?.toString() ?? '';
      final programmes = _programsByChannel[channelId] ?? const [];
      final currentProgram = programmes.isNotEmpty ? programmes.first : null;
      final programName =
          (currentProgram?['Name'] ?? '').toString().toLowerCase();
      return programName.contains(query);
    }).toList();

    _filteredChannelsCache = result;
    _filteredChannelsCacheSource = _channels;
    _filteredChannelsCacheCategory = _selectedCategory;
    _filteredChannelsCacheSearch = _search;
    return result;
  }

  double get _currentTimeOffset {
    final now = DateTime.now();
    return (now.hour * 60 + now.minute) * EpgUtils.pixelsPerMinute;
  }

  @override
  void initState() {
    super.initState();
    _timelineController.addListener(_syncHeader);
    _channelListController.addListener(_syncFromChannelList);
    _rowsListController.addListener(_syncFromRowsList);

    // The caller (Live TV's own screen) already has the channel list in
    // memory — painting the channel column, time header, and empty grid
    // with it immediately, before the guide's own network calls even
    // start, is what lets the rest of the screen appear just as fast as
    // everything else instead of sitting behind a spinner until the
    // first programs response comes back too. Programs then simply pop
    // into their rows once _loadGuide's passes resolve, same as before.
    if (widget.initialChannels?.isNotEmpty ?? false) {
      _channels = _asMapList(widget.initialChannels!);
      _loading = false;
      _usingPrefilledChannels = true;
    }

    _loadGuide();
    // With a prefilled channel list the grid is already on screen after
    // this first frame; otherwise _loadGuide() schedules it again once
    // the channels arrive.
    _scheduleFocusScroll();
    _timer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (!mounted) return;
      setState(_rebuildProgramIndex);
    });
  }

  void _syncHeader() {
    if (!_headerController.hasClients || !_timelineController.hasClients) {
      return;
    }

    final offset = _timelineController.offset;
    if ((_headerController.offset - offset).abs() > 0.5) {
      _headerController.jumpTo(offset);
    }
  }

  void _syncFromChannelList() => _syncVertical(from: _channelListController, to: _rowsListController);
  void _syncFromRowsList() => _syncVertical(from: _rowsListController, to: _channelListController);

  void _syncVertical({required ScrollController from, required ScrollController to}) {
    if (_syncingVertical) return;
    if (!from.hasClients || !to.hasClients) return;

    final offset = from.offset;
    if ((to.offset - offset).abs() > 0.5) {
      _syncingVertical = true;
      to.jumpTo(offset.clamp(0.0, to.position.maxScrollExtent));
      _syncingVertical = false;
    }
  }

  /// How far back before midnight we look for programs. A show that
  /// started the previous evening and is still airing when the day rolls
  /// over would otherwise fall outside a strict midnight-to-midnight
  /// fetch window entirely — it just wouldn't be in `_programs` at all,
  /// which is exactly why "on air" highlighting looked inconsistent from
  /// channel to channel (it depended on whether that channel's schedule
  /// happened to line up with midnight).
  static const _guideLookback = Duration(hours: 6);

  /// A load happens in two passes so the guide paints almost instantly:
  /// the first pass fetches only a narrow window around "now" (enough to
  /// fill the visible viewport plus a little scroll headroom either
  /// side), so the grid appears and is scrollable right away instead of
  /// waiting on the full day's data. The second pass then fetches the
  /// complete day in the background and merges it in silently — no
  /// loading spinner, no scroll position reset.
  /// [silent] skips the full-screen loading spinner — used by
  /// pull-to-refresh, which already shows its own gold spinner and
  /// needs the grid (and the pull gesture's scroll position) to stay on
  /// screen underneath it instead of being replaced, the same "silent"
  /// convention Home and Live TV's channel list use for their own
  /// pull-to-refresh.
  Future<void> _loadGuide({bool silent = false}) async {
    final generation = ++_loadGeneration;

    // Don't drop back into the full-screen spinner when the channel
    // column/grid is already on screen from a prefilled list (see
    // initState) — that would throw away the head start this whole
    // mechanism exists to give, replacing visible content with a blank
    // spinner while programs are still the only thing actually pending.
    final showSpinner = !silent && !_usingPrefilledChannels;

    setState(() {
      if (showSpinner) _loading = true;
      _error = null;
    });

    final dayStart = _selectedDate;
    final fetchStart = dayStart.subtract(_guideLookback);
    final dayEnd = dayStart.add(const Duration(days: 1));

    try {
      // Channels are needed before the schedule call now (see below), so
      // this can no longer run in parallel with it — but when the caller
      // already handed us a channel list (see [TvGuideScreen.initialChannels]),
      // that's already in hand with no wait at all, so the common path
      // (opened from Live TV's screen) isn't actually slowed down by
      // this change.
      final bool reuseInitialChannels = !silent &&
          _usingPrefilledChannels &&
          (widget.initialChannels?.isNotEmpty ?? false);
      // Consumed either way — only the very first call gets to reuse
      // the prefilled list; a day change, refresh, or pull-to-refresh
      // after that always re-fetches for real, same as before.
      _usingPrefilledChannels = false;

      final List channelsResult = reuseInitialChannels
          ? widget.initialChannels!
          : await MediaService.getLiveTvChannels().timeout(
              const Duration(seconds: 20),
              onTimeout: () =>
                  throw Exception('Timed out loading the channel list.'),
            );

      final channels = _asMapList(channelsResult);
      final channelIds = channels
          .map((channel) => channel['Id']?.toString())
          .whereType<String>()
          .toList();

      // Narrowed from the previous 1hr-before/6hr-after window. That
      // wider window is what could push a channel-heavy server's
      // program count for this call past a single page (1000 items),
      // triggering several *concurrent* page requests on top of an
      // already-slow call — this only needs enough to fill the visible
      // grid plus a little scroll headroom; the full day still arrives
      // moments later via the silent background pass below.
      final quickStart = _isViewingToday
          ? DateTime.now().subtract(const Duration(minutes: 30))
          : dayStart;
      final quickEnd = _isViewingToday
          ? DateTime.now().add(const Duration(hours: 2))
          : dayStart.add(const Duration(hours: 3));

      final programsResult = await MediaService.getGuide(
        start: quickStart,
        end: quickEnd,
        // Scoping to just the channels we're about to display — some
        // Jellyfin Live TV backends (IPTV/Xtream-style tuners in
        // particular) compute EPG data by walking every configured
        // channel for any unscoped request, so an unfiltered call's
        // cost scales with total channel count rather than the date
        // window. This was the actual source of "timed out loading the
        // program schedule": a narrower date window didn't help because
        // the slow part was never the window size.
        channelIds: channelIds,
      ).timeout(
        const Duration(seconds: 45),
        onTimeout: () =>
            throw Exception('Timed out loading the program schedule.'),
      );

      if (!mounted) return;

      // A newer call (another refresh tap, a day change, pull-to-refresh)
      // already started and should be the one that gets to paint —
      // applying this older response now would stomp on its result.
      if (generation != _loadGeneration) return;

      setState(() {
        _channels = channels;
        _programs = _asMapList(programsResult);
        _rebuildProgramIndex();
        _loading = false;
      });
      if (_isViewingToday) {
        _scrollToNow();
      }
      _scheduleFocusScroll();
    } catch (error) {
      if (!mounted) return;
      if (generation != _loadGeneration) return;
      setState(() {
        // Surfaces the real exception text (timeout, HTTP status,
        // parsing error, etc.) instead of a generic message — so a
        // failure is actually diagnosable from the on-screen card
        // without needing console/logcat access.
        _error = 'Could not load the TV guide.\n$error';
        _loading = false;
      });
      debugPrint('TV guide error: $error');
      return;
    }

    // Background pass: fill in the rest of the day silently.
    try {
      final channelIds = _channels
          .map((channel) => channel['Id']?.toString())
          .whereType<String>()
          .toList();

      final fullGuide = await MediaService.getGuide(
        start: fetchStart,
        end: dayEnd,
        channelIds: channelIds,
      );

      if (!mounted || dayStart != _selectedDate) return;
      if (generation != _loadGeneration) return;

      setState(() {
        _programs = _asMapList(fullGuide);
        _rebuildProgramIndex();
      });
    } catch (error) {
      // The quick pass already succeeded and is on screen — a failure
      // here just means the rest of the day doesn't fill in, not worth
      // surfacing as a hard error.
      debugPrint('TV guide background fetch error: $error');
    }
  }

  /// Starts live playback for [channel] immediately — same behavior as the
  /// "Watch Live" button on the channel detail screen.
  Future<void> _playChannel(Map<String, dynamic> channel) async {
    final media = MediaService.mediaItemFromJellyfin(channel);

    // Show the player immediately with a loading overlay instead of
    // waiting on the stream to open before navigating there.
    PlayerManager.instance.showLoadingPreview(media);
    unawaited(PlaybackService.playItem(media));

    if (!mounted) return;

    await PlayerNavigation.open(context);
  }

  void _onSearchChanged(String value) {
    // Debounced the same way All Channels/Movies/Music debounce theirs —
    // this filters via a cheap memoized getter rather than an async
    // call, but keeping the same rhythm avoids a rebuild on every single
    // keystroke while the guide's minute timer is also ticking.
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      setState(() => _search = value);
    });
  }

  void _selectDay(DateTime day) {
    if (day == _selectedDate) return;
    setState(() {
      _selectedDate = day;
    });
    _loadGuide();
  }

  /// Groups + sorts programs by channel ONCE (on load and on each minute
  /// tick) instead of filtering/sorting the full program list on every
  /// build for every channel row.
  void _rebuildProgramIndex() {
    final byChannel = <String, List<Map<String, dynamic>>>{};

    for (final program in _programs) {
      final channelId = program['ChannelId']?.toString() ?? '';
      (byChannel[channelId] ??= []).add(program);
    }

    for (final list in byChannel.values) {
      list.sort((a, b) {
        final aStart = EpgUtils.parseProgramTime(a['StartDate']);
        final bStart = EpgUtils.parseProgramTime(b['StartDate']);
        return (aStart ?? DateTime(0)).compareTo(bStart ?? DateTime(0));
      });
    }

    final now = DateTime.now();
    final playing = <String, bool>{};
    byChannel.forEach((channelId, programmes) {
      playing[channelId] = programmes.any((program) {
        final start = EpgUtils.parseProgramTime(program['StartDate']);
        final end = EpgUtils.parseProgramTime(program['EndDate']);
        return start != null &&
            end != null &&
            now.isAfter(start) &&
            now.isBefore(end);
      });
    });

    _programsByChannel = byChannel;
    _isPlayingByChannel = playing;
  }

  List<Map<String, dynamic>> _asMapList(dynamic values) {
    if (values is! List) return const [];
    return values
        .whereType<Map>()
        .map((value) => Map<String, dynamic>.from(value))
        .toList(growable: false);
  }

  /// Scrolls [TvGuideScreen.focusChannelId]'s row to the top of the grid
  /// (clamped at the end of the list) and highlights it for a moment.
  ///
  /// Rows have a fixed height ([_rowHeight]), so the target offset is
  /// simply `index * _rowHeight` — it doesn't depend on programs having
  /// loaded. If the grid isn't built yet (still loading, or no channels
  /// yet) this does nothing and stays pending; [_loadGuide] calls it
  /// again once the channels are in.
  void _scheduleFocusScroll() {
    if (!_focusPending) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_focusPending) return;

      final targetId = widget.focusChannelId;
      if (targetId == null || targetId.isEmpty) {
        _focusPending = false;
        return;
      }

      if (!_rowsListController.hasClients) return;
      final position = _rowsListController.position;
      if (!position.hasContentDimensions) return;

      final index = _filteredChannels
          .indexWhere((c) => c['Id']?.toString() == targetId);
      if (index < 0) {
        // Only give up once there really is a channel list to search.
        if (_channels.isNotEmpty) _focusPending = false;
        return;
      }

      _focusPending = false;

      final target =
          (index * _rowHeight).clamp(0.0, position.maxScrollExtent).toDouble();
      // The channel-name column follows via the vertical sync listeners.
      _rowsListController.animateTo(
        target,
        duration: const Duration(milliseconds: 450),
        curve: Curves.easeOutCubic,
      );

      setState(() {
        _highlightChannelId = targetId;
        _highlightFading = false;
      });
      _highlightTimer?.cancel();
      _highlightTimer = Timer(const Duration(milliseconds: 2400), () {
        if (!mounted) return;
        setState(() => _highlightFading = true);
        _highlightTimer = Timer(const Duration(milliseconds: 700), () {
          if (!mounted) return;
          setState(() {
            _highlightChannelId = null;
            _highlightFading = false;
          });
        });
      });
    });
  }

  void _scrollToNow({bool animated = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_timelineController.hasClients) return;

      final target = (_currentTimeOffset - 120)
          .clamp(0.0, _timelineController.position.maxScrollExtent)
          .toDouble();
      _moveTo(_timelineController, target, animated: animated);
      _moveTo(_headerController, target, animated: animated);
    });
  }

  void _moveTo(
    ScrollController controller,
    double offset, {
    required bool animated,
  }) {
    if (!controller.hasClients) return;
    if (animated) {
      controller.animateTo(
        offset,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOut,
      );
    } else {
      controller.jumpTo(offset);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _highlightTimer?.cancel();
    _searchDebounce?.cancel();
    _searchController.dispose();
    _searchFocusNode.dispose();
    _timelineController
      ..removeListener(_syncHeader)
      ..dispose();
    _headerController.dispose();
    _channelListController
      ..removeListener(_syncFromChannelList)
      ..dispose();
    _rowsListController
      ..removeListener(_syncFromRowsList)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // LabelCollapseScope: the app bar (title + Jump to now / Refresh)
    // slides away on scroll down and returns on scroll up (see
    // collapsing_screen_label.dart); the category/day chips and the time
    // header stay pinned. resetKey brings the bar back when the category
    // or day changes.
    return LabelCollapseScope(
      resetKey: Object.hash(_selectedCategory, _selectedDate),
      child: Scaffold(
      backgroundColor: const Color(0xff161616),
      // primary: false — CollapsibleAppBar supplies the status-bar inset
      // itself so the bar can collapse down to just that inset.
      appBar: CollapsibleAppBar(
        child: AppBar(
          primary: false,
          title: Text(
            'TV Guide • ${_selectedDate.day}/${_selectedDate.month}',
          ),
          backgroundColor: const Color(0xff161616),
          actions: [
            IconButton(
              tooltip: 'Jump to now',
              icon: const Icon(Icons.schedule),
              onPressed: () {
                if (_isViewingToday) {
                  _scrollToNow(animated: true);
                } else {
                  _selectDay(_dateOnly(DateTime.now()));
                }
              },
            ),
            IconButton(
              tooltip: 'Refresh guide',
              icon: const Icon(Icons.refresh),
              onPressed: _loading ? null : () => _loadGuide(),
            ),
          ],
        ),
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: Color(0xffD4AF37)),
            )
          : _error != null
              ? _ErrorState(message: _error!, onRetry: _loadGuide)
              : _buildGuide(),
      ),
    );
  }

  Widget _buildGuide() {
    return Column(
      children: [
        // App bar to first row: 10, matching the other Live TV screens.
        const SizedBox(height: 10),

        if (Responsive.isLandscape(context)) ...[
          // Landscape: the category-chip row and day-chip row collapse
          // into a single row — a category dropdown, a day dropdown,
          // and a compact search field — instead of stacking two
          // scrollable chip rows, freeing up vertical space for the
          // grid. Matches the Movies/Music/All Channels landscape
          // headers; selection behavior is identical to the portrait
          // chips below, just presented as pills.
          _buildLandscapeFiltersRow(),
          const SizedBox(height: 8),
        ] else ...[
          SizedBox(
            height: 45,
            // Auto-scrolls the tapped/selected chip into view, matching
            // the Movies screen's library chips (see
            // lib/widgets/live_tv/category_chips_row.dart). The day-chip
            // row below is left as a plain ListView.
            child: CategoryChipsRow(
              categories: _categories,
              selected: _selectedCategory,
              padding: EdgeInsets.symmetric(
                horizontal: Responsive.contentPadding(context),
              ),
              chipBuilder: (category, _) => _buildCategoryChip(category),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 64,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.symmetric(
                horizontal: Responsive.contentPadding(context),
              ),
              itemCount: _guideDays.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (context, index) =>
                  _buildDayChip(_guideDays[index]),
            ),
          ),
          const SizedBox(height: 5),
        ],
        Expanded(
          child: ResistiveRefresh(
            onRefresh: () => _loadGuide(silent: true),
            color: const Color(0xffD4AF37),
            backgroundColor: const Color(0xff232323),
            child: _channels.isEmpty
              ? ListView(
                  // A plain Center isn't a Scrollable, so RefreshIndicator
                  // has nothing to listen to — wrapping the empty-state
                  // text in a ListView keeps the pull gesture working
                  // even when there are no channels to show yet.
                  children: const [
                    SizedBox(height: 120),
                    Center(
                      child: Text(
                        'No TV channels are available.',
                        style: TextStyle(color: Colors.white70),
                      ),
                    ),
                  ],
                )
              : _filteredChannels.isEmpty
                  ? ListView(
                      children: const [
                        SizedBox(height: 120),
                        Center(
                          child: Text(
                            'No channels match this category.',
                            style: TextStyle(color: Colors.white70),
                          ),
                        ),
                      ],
                    )
                  : _buildGrid(),
          ),
        ),
      ],
    );
  }

  Widget _buildCategoryChip(String title) {
    final selected = _selectedCategory == title;

    return Padding(
      padding: const EdgeInsets.only(right: 10),
      child: ChoiceChip(
        showCheckmark: false,
        backgroundColor: const Color(0xff2A2A2A),
        selectedColor: const Color(0xffD4AF37),
        labelStyle: TextStyle(
          color: selected ? Colors.black : Colors.white,
          fontWeight: FontWeight.bold,
        ),
        label: Text(title),
        selected: selected,
        onSelected: (_) {
          setState(() {
            _selectedCategory = title;
          });
        },
      ),
    );
  }

  /// Landscape header: category chips + day chips collapse into two
  /// dropdown pills sharing a row with the search field — same
  /// selection state/handlers as the portrait chips, just presented
  /// as pills like Movies/Music/All Channels' landscape headers.
  Widget _buildLandscapeFiltersRow() {
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: Responsive.contentPadding(context),
      ),
      child: Row(
        children: [
          Flexible(
            child: SelectorDropdown<String>(
              label: _selectedCategory,
              leadingIcon:
                  _categoryIcons[_selectedCategory] ?? Icons.apps_rounded,
              selectedValue: _selectedCategory,
              maxWidth: 170,
              options: _categories
                  .map(
                    (c) => DropdownOption(
                      value: c,
                      label: c,
                      icon: _categoryIcons[c],
                    ),
                  )
                  .toList(),
              onSelected: (category) {
                setState(() => _selectedCategory = category);
              },
            ),
          ),

          const SizedBox(width: 10),

          SelectorDropdown<DateTime>(
            label: _dayLabel(_selectedDate),
            leadingIcon: Icons.calendar_today_rounded,
            selectedValue: _selectedDate,
            options: _guideDays
                .map(
                  (day) => DropdownOption(
                    value: day,
                    label: _dayLabel(day),
                  ),
                )
                .toList(),
            onSelected: _selectDay,
          ),

          const Spacer(),

          // Fixed, compact width instead of Expanded — two dropdown
          // pills already read as filters, so a full-width search
          // field would look oversized beside them. Matches the
          // Movies/Music/All Channels landscape search width.
          SizedBox(
            width: 200,
            height: 34,
            child: _buildSearchField(),
          ),
        ],
      ),
    );
  }

  String _dayLabel(DateTime day) {
    if (day == _dateOnly(DateTime.now())) return 'Today';
    return '${_weekdayLabels[day.weekday] ?? ''} ${day.day}';
  }

  Widget _buildSearchField() {
    return TextField(
      controller: _searchController,
      focusNode: _searchFocusNode,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 13,
      ),
      decoration: InputDecoration(
        isDense: true,
        hintText: 'Search guide...',
        hintStyle: const TextStyle(
          color: Colors.white54,
          fontSize: 13,
        ),
        prefixIcon: const Icon(
          Icons.search,
          color: Colors.white70,
          size: 18,
        ),
        prefixIconConstraints: const BoxConstraints(
          minWidth: 32,
          minHeight: 32,
        ),
        filled: true,
        fillColor: const Color(0xff252525),
        contentPadding: const EdgeInsets.symmetric(vertical: 8),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(30),
          borderSide: BorderSide.none,
        ),
      ),
      onChanged: _onSearchChanged,
    );
  }

  static const _weekdayLabels = {
    1: 'MON',
    2: 'TUE',
    3: 'WED',
    4: 'THU',
    5: 'FRI',
    6: 'SAT',
    7: 'SUN',
  };

  Widget _buildDayChip(DateTime day) {
    final isSelected = day == _selectedDate;
    final isToday = day == _dateOnly(DateTime.now());

    return Pressable(
      onTap: () => _selectDay(day),
      borderRadius: BorderRadius.circular(14),
      child: Container(
        width: 52,
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xffD4AF37) : const Color(0xff2A2A2A),
          borderRadius: BorderRadius.circular(14),
        ),
        alignment: Alignment.center,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              isToday ? 'TODAY' : (_weekdayLabels[day.weekday] ?? ''),
              style: TextStyle(
                color: isSelected ? Colors.black : Colors.white54,
                fontSize: isToday ? 9 : 11,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              '${day.day}',
              style: TextStyle(
                color: isSelected ? Colors.black : Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGrid() {
    return Column(
      children: [
        GuideTimeHeader(
          controller: _headerController,
          leadingWidth: _channelColumnWidth,
        ),
        const Divider(height: 1, color: Colors.white10),
        Expanded(
          // Single BottomClearanceBuilder around both lists so they
          // always read the exact same bottomClearance value on every
          // rebuild — matches the existing "kept identical" intent for
          // their bottom padding instead of letting two separate
          // reactive builders drift out of sync with each other.
          child: BottomClearanceBuilder(
            builder: (context, bottomClearance) => FadeScrollbar(
            controller: _rowsListController,
            child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Channel name column — lazily built, only visible rows exist.
              SizedBox(
                width: _channelColumnWidth,
                child: ListView.builder(
                  controller: _channelListController,
                  itemExtent: _rowHeight,
                  itemCount: _filteredChannels.length,
                  // Rows are cheap to build but include a network image —
                  // pre-building a screen's worth ahead of the viewport
                  // (instead of the ~250px default) means that decode
                  // work has already happened by the time a row actually
                  // scrolls into view, instead of happening right on the
                  // edge of the viewport where it reads as stutter.
                  cacheExtent: 900,
                  // These rows carry no per-item state worth retaining
                  // and don't need a11y indexing — skipping both trims
                  // the per-item bookkeeping on every scroll rebuild.
                  addAutomaticKeepAlives: false,
                  addSemanticIndexes: false,
                  // Kept identical to the timeline list's bottom padding
                  // below so the two lazily-built, scroll-synced lists
                  // stay aligned row-for-row — only the trailing empty
                  // space grows, clearing the floating bottom nav bar
                  // (a plain Stack, not a real Scaffold.extendBody —
                  // see MainNavScreen's own doc comment) instead of
                  // scrolling behind it. BottomClearance.of adds the
                  // bar's actual height on top of the safe-area inset
                  // MediaQuery alone reports.
                  // Aspect-scoped (MediaQuery.paddingOf) instead of the
                  // unscoped MediaQuery.of(context) this used to call —
                  // that subscribed this whole guide (channel column +
                  // synced program grid) to every MediaQueryData field,
                  // including viewInsets.bottom, which the framework
                  // updates every single frame while any keyboard
                  // animates anywhere in the app (this screen's own
                  // search field, or — since every bottom-nav tab is
                  // kept alive together in an IndexedStack — one open on
                  // a completely different tab). paddingOf only rebuilds
                  // when the actual safe-area padding changes.
                  padding: EdgeInsets.only(
                    bottom:
                        MediaQuery.paddingOf(context).bottom + bottomClearance,
                  ),
                  itemBuilder: (context, index) {
                    final channel = _filteredChannels[index];
                    final channelId = channel['Id']?.toString() ?? '';
                    return _FocusHighlight(
                      active: channelId == _highlightChannelId,
                      fading: _highlightFading,
                      child: GuideChannelTile(
                        channel: channel,
                        isPlaying: _isPlayingByChannel[channelId] ?? false,
                        onTap: () => _playChannel(channel),
                      ),
                    );
                  },
                ),
              ),
              // Program grid — horizontal scroll is shared across all rows
              // (synced with the time header); vertical scroll is a lazy
              // ListView.builder so off-screen channels are never built.
              Expanded(
                child: SingleChildScrollView(
                  controller: _timelineController,
                  scrollDirection: Axis.horizontal,
                  child: SizedBox(
                    width: EpgUtils.timelineWidth,
                    child: ListView.builder(
                      controller: _rowsListController,
                      itemExtent: _rowHeight,
                      itemCount: _filteredChannels.length,
                      // See matching comment on the channel column list.
                      cacheExtent: 900,
                      addAutomaticKeepAlives: false,
                      addSemanticIndexes: false,
                      // Same bottom padding keeps both lists' scroll
                      // ranges identical. Aspect-scoped for the same
                      // reason as the channel column's padding above —
                      // this timeline row list would otherwise also
                      // rebuild in lockstep with any keyboard animating
                      // anywhere in the app.
                      padding: EdgeInsets.only(
                        bottom: MediaQuery.paddingOf(context).bottom +
                            bottomClearance,
                      ),
                      itemBuilder: (context, index) {
                        final channel = _filteredChannels[index];
                        final channelId = channel['Id']?.toString() ?? '';
                        return _FocusHighlight(
                          active: channelId == _highlightChannelId,
                          fading: _highlightFading,
                          child: _GuideTimelineRow(
                            programmes:
                                _programsByChannel[channelId] ?? const [],
                            showNowLabel: index == 0 && _isViewingToday,
                            nowOffset: _currentTimeOffset,
                            rowHeight: _rowHeight,
                            showNowLine: _isViewingToday,
                            dayStart: _selectedDate,
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ],
          ),
          ),
          ),
        ),
      ],
    );
  }
}

/// Gold wash + top/bottom rules drawn OVER a guide row (channel tile and
/// its timeline row both use it, so the band reads as one continuous
/// strip across the two lists). Rows that aren't highlighted are returned
/// untouched — no extra widgets in the common case.
class _FocusHighlight extends StatelessWidget {
  const _FocusHighlight({
    required this.active,
    required this.fading,
    required this.child,
  });

  final bool active;
  final bool fading;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!active) return child;

    const gold = Color(0xffD4AF37);

    return Stack(
      // Keep the list's tight itemExtent constraints on the real child.
      fit: StackFit.passthrough,
      children: [
        child,
        Positioned.fill(
          child: IgnorePointer(
            child: TweenAnimationBuilder<double>(
              tween: Tween<double>(begin: 0, end: 1),
              duration: const Duration(milliseconds: 350),
              builder: (context, value, overlay) =>
                  Opacity(opacity: value, child: overlay),
              child: AnimatedOpacity(
                opacity: fading ? 0 : 1,
                duration: const Duration(milliseconds: 600),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: gold.withValues(alpha: 0.10),
                    border: Border.symmetric(
                      horizontal: BorderSide(
                        color: gold.withValues(alpha: 0.7),
                        width: 1.5,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _GuideTimelineRow extends StatelessWidget {
  const _GuideTimelineRow({
    required this.programmes,
    required this.showNowLabel,
    required this.nowOffset,
    required this.rowHeight,
    required this.showNowLine,
    required this.dayStart,
  });

  final List<Map<String, dynamic>> programmes;
  final bool showNowLabel;
  final double nowOffset;
  final double rowHeight;
  final bool showNowLine;
  final DateTime dayStart;

  @override
  Widget build(BuildContext context) {
    // Program tiles used to be one Container+Text+GestureDetector widget
    // each — for a channel with a full day of half-hour slots that's
    // regularly 40-60 real widgets built and laid out every time a row
    // scrolls into view, almost all of them off-screen at any given
    // horizontal scroll position, and it was the single biggest
    // remaining cost behind the guide feeling heavy. They're now laid
    // out once into plain geometry and drawn in one CustomPaint pass —
    // taps are resolved against that same geometry instead of needing a
    // GestureDetector per tile.
    final tiles = _layoutProgramTiles(programmes, dayStart);

    // RepaintBoundary isolates each row's paint from the others — the
    // minute timer and horizontal scroll no longer force every visible
    // row to repaint together, which is most of what was making
    // scrolling feel sticky.
    return RepaintBoundary(
      child: SizedBox(
        height: rowHeight,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            // A single CustomPaint for all 24 gridlines instead of 24
            // separate Container widgets — far cheaper to build and
            // layout per row, and there are many rows on screen at once.
            const Positioned.fill(child: _HourGridlines()),
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTapUp: (details) =>
                    _handleTap(context, details.localPosition, tiles),
                child: CustomPaint(
                  painter: _ProgramTilesPainter(tiles),
                  size: Size.infinite,
                ),
              ),
            ),
            if (showNowLine)
            Positioned(
              left: nowOffset,
              top: 0,
              bottom: 0,
              child: IgnorePointer(
                child: Column(
                  children: [
                    if (showNowLabel)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.red,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Text(
                          'NOW',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    Expanded(child: Container(width: 2, color: Colors.red)),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _handleTap(
    BuildContext context,
    Offset localPosition,
    List<_ProgramTileGeom> tiles,
  ) {
    for (final tile in tiles) {
      if (localPosition.dx >= tile.left && localPosition.dx <= tile.right) {
        showProgramDetailsSheet(context, tile.program, tile.isLive);
        return;
      }
    }
  }
}

/// Precomputed layout + live state for one program tile. Building this
/// list once per row (instead of once per program *widget*, as before)
/// is what lets [_ProgramTilesPainter] draw an entire row in a single
/// canvas pass.
class _ProgramTileGeom {
  _ProgramTileGeom({
    required this.program,
    required this.left,
    required this.width,
    required this.isLive,
    required this.progress,
  });

  final Map<String, dynamic> program;
  final double left;
  final double width;
  final bool isLive;
  final double progress;

  double get right => left + width;
}

List<_ProgramTileGeom> _layoutProgramTiles(
  List<Map<String, dynamic>> programmes,
  DateTime dayStart,
) {
  final now = DateTime.now();
  final tiles = <_ProgramTileGeom>[];

  for (final program in programmes) {
    final start = EpgUtils.parseProgramTime(program['StartDate']);
    final end = EpgUtils.parseProgramTime(program['EndDate']);
    if (start == null || end == null || !end.isAfter(start)) continue;

    final isLive = now.isAfter(start) && now.isBefore(end);
    final progress = EpgUtils.progress(
      program['StartDate'],
      program['EndDate'],
    ).clamp(0.0, 1.0).toDouble();

    tiles.add(_ProgramTileGeom(
      program: program,
      left: EpgUtils.leftOffset(start, dayStart),
      width: EpgUtils.width(start, end, dayStart)
          .clamp(48.0, double.infinity)
          .toDouble(),
      isLive: isLive,
      progress: progress,
    ));
  }

  return tiles;
}

/// Draws every program tile in a row with plain [Canvas] calls instead of
/// a widget per tile — the same rounded block, "LIVE" badge, progress bar
/// and title/time text as before, just painted rather than built/laid out
/// through the widget tree.
class _ProgramTilesPainter extends CustomPainter {
  _ProgramTilesPainter(this.tiles);

  final List<_ProgramTileGeom> tiles;

  static const _tileHeight = 100.0;
  static const _margin = 3.0;
  static const _gold = Color(0xffD4AF37);
  static const _tileDark = Color(0xff2B2B2B);

  @override
  void paint(Canvas canvas, Size size) {
    for (final tile in tiles) {
      final rect = Rect.fromLTWH(
        tile.left + _margin,
        _margin,
        (tile.width - _margin * 2).clamp(0.0, double.infinity),
        _tileHeight,
      );
      if (rect.width <= 0) continue;

      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(10)),
        Paint()..color = tile.isLive ? _gold : _tileDark,
      );

      final padded = rect.deflate(10);
      if (padded.width <= 0) continue;
      var cursorY = padded.top;

      if (tile.isLive && rect.width >= 90) {
        const badgeSize = Size(34, 16);
        final badgeRect = Rect.fromLTWH(
          padded.left,
          cursorY,
          badgeSize.width,
          badgeSize.height,
        );
        canvas.drawRRect(
          RRect.fromRectAndRadius(badgeRect, const Radius.circular(20)),
          Paint()..color = Colors.red,
        );
        _drawText(
          canvas,
          'LIVE',
          Offset(badgeRect.left + 6, badgeRect.top + 3),
          const TextStyle(
            color: Colors.white,
            fontSize: 9,
            fontWeight: FontWeight.bold,
          ),
          maxWidth: badgeSize.width - 6,
        );
        cursorY += badgeSize.height + 4;
      }

      // A live tile already spends its height on the badge and progress
      // bar, so it only has room for one line without overflowing;
      // non-live tiles can afford two.
      final titleHeight = _drawText(
        canvas,
        tile.program['Name']?.toString() ?? '',
        Offset(padded.left, cursorY),
        TextStyle(
          color: tile.isLive ? Colors.black : Colors.white,
          fontWeight: FontWeight.bold,
        ),
        maxWidth: padded.width,
        maxLines: tile.isLive ? 1 : 2,
      );
      cursorY += titleHeight;

      final timeText =
          '${EpgUtils.formatTime(tile.program['StartDate'])} - '
          '${EpgUtils.formatTime(tile.program['EndDate'])}';
      final timeY = padded.bottom - 14;

      if (tile.isLive) {
        final barRect =
            Rect.fromLTWH(padded.left, timeY - 8, padded.width, 4);
        canvas.drawRRect(
          RRect.fromRectAndRadius(barRect, const Radius.circular(2)),
          Paint()..color = Colors.black26,
        );
        if (tile.progress > 0) {
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromLTWH(
                barRect.left,
                barRect.top,
                barRect.width * tile.progress,
                barRect.height,
              ),
              const Radius.circular(2),
            ),
            Paint()..color = Colors.red,
          );
        }
      }

      if (timeY >= padded.top) {
        _drawText(
          canvas,
          timeText,
          Offset(padded.left, timeY),
          TextStyle(
            color: tile.isLive ? Colors.black87 : Colors.white54,
            fontSize: 11,
          ),
          maxWidth: padded.width,
        );
      }
    }
  }

  double _drawText(
    Canvas canvas,
    String text,
    Offset offset,
    TextStyle style, {
    required double maxWidth,
    int maxLines = 1,
  }) {
    if (maxWidth <= 0) return 0;
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      maxLines: maxLines,
      ellipsis: '…',
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: maxWidth);
    painter.paint(canvas, offset);
    return painter.height;
  }

  // Every row already sits inside its own RepaintBoundary and only
  // rebuilds (and thus repaints) when it scrolls into view or the
  // once-a-minute timer ticks — so there's no cheaper "did anything
  // actually change" check worth doing here beyond a reference compare.
  @override
  bool shouldRepaint(covariant _ProgramTilesPainter oldDelegate) {
    return !identical(oldDelegate.tiles, tiles);
  }
}

/// Static 24-hour gridline backdrop for a guide row, painted once via
/// [CustomPaint] instead of built as 24 separate [Container] widgets.
/// Widgets carry per-instance layout/build/element overhead that adds up
/// fast across many visible rows; a single paint call per row is far
/// cheaper and is what actually smooths out scrolling.
class _HourGridlines extends StatelessWidget {
  const _HourGridlines();

  @override
  Widget build(BuildContext context) {
    return CustomPaint(painter: _HourGridlinesPainter());
  }
}

class _HourGridlinesPainter extends CustomPainter {
  static final Paint _paint = Paint()
    ..color = Colors.white10
    ..strokeWidth = 1;

  @override
  void paint(Canvas canvas, Size size) {
    for (var hour = 0; hour < EpgUtils.hoursInGuide; hour++) {
      final x = hour * EpgUtils.hourWidth;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), _paint);
    }
  }

  // The grid never changes shape/position, so it never needs to repaint.
  @override
  bool shouldRepaint(covariant _HourGridlinesPainter oldDelegate) => false;
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: Colors.redAccent, size: 48),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 16),
            FilledButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}
