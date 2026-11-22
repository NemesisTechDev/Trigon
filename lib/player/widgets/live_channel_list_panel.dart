import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../player_manager.dart';
import '../playback_service.dart';
import '../models/media_item.dart';
import '../../services/jellyfin_services/media_service.dart';
import '../../utils/channel_categories.dart';
import '../../utils/epg_utils.dart';
import '../../widgets/common/pressable.dart';
import '../../services/cache/nemesis_image_cache.dart';

const _gold = Color(0xffD4AF37);

/// Right-side sliding panel listing every Live TV channel (grouped by
/// category, with left/right arrows to page between categories),
/// opened from the top bar while watching a live channel. Mirrors the
/// row layout of the "All Channels" browsing screen, and the
/// slide-in-from-the-right, full-height presentation of
/// [EpisodeListPanel], so switching channels never leaves the player.
class LiveChannelListPanel extends StatefulWidget {
  const LiveChannelListPanel({super.key});

  @override
  State<LiveChannelListPanel> createState() => _LiveChannelListPanelState();
}

class _LiveChannelListPanelState extends State<LiveChannelListPanel> {
  /// "All" first, then every classify() bucket in the app's usual order.
  static const List<String> _categories = ["All", ...ChannelCategories.labels];

  bool _loaded = false;
  bool _loading = false;
  String? _error;

  /// Tracks the panel's own open/closed state (separate from the
  /// ValueListenableBuilder's `open` param below) purely to detect the
  /// closed→open transition — that's what triggers a fresh reload each
  /// time, so the current-show names and progress bars are never
  /// showing stale data left over from whenever the panel was last
  /// opened.
  bool _wasOpen = false;

  List<Map<String, dynamic>> _channels = const [];

  /// Channel id -> the single program currently airing on it (if any).
  Map<String, Map<String, dynamic>> _currentProgramByChannel = const {};

  int _categoryIndex = 0;

  bool _searching = false;
  String _query = "";
  final _searchController = TextEditingController();
  Timer? _searchDebounce;
  final _searchFocus = FocusNode();

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  /// Loads the channel list on its own first — far lighter than the
  /// program guide (no per-program StartDate/EndDate rows to fetch or
  /// page through) — so the panel has something to show right away
  /// instead of the spinner sitting there until both requests finish.
  /// "Now airing" names and progress bars fill themselves in a beat
  /// later once the guide (below) resolves. Called every time the panel
  /// opens (not just the first time) so that info stays current even if
  /// the panel was left closed for a while. Deliberately doesn't clear
  /// `_channels`/`_currentProgramByChannel` first — the existing list
  /// stays on screen (and tappable) until the fresh data lands, rather
  /// than flashing empty/spinner on every reopen.
  Future<void> _loadChannels() async {
    if (_loading) return;

    _loading = true;
    if (mounted) setState(() {});

    try {
      final channels = (await MediaService.getLiveTvChannels())
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();

      // Also feeds PlayerManager's cache, which the center controls'
      // previous/next-channel buttons read from — so opening this panel
      // (which happens naturally via the top-bar toggle) keeps that
      // cache fresh too, without a second, separate fetch.
      PlayerManager.instance.liveChannels.value = channels;

      if (!mounted) return;
      setState(() {
        _channels = channels;
        _loaded = true;
        _loading = false;
      });

      // Runs in the background — the channel list above is already
      // live and tappable, this only fills in the "now airing" subtitle
      // and progress bar per row as it resolves.
      unawaited(_loadCurrentPrograms());
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = "Could not load channels.";
        _loading = false;
      });
    }
  }

  /// Fetches the current 3-hour guide window and maps each channel to
  /// whatever's airing on it right now. Split out from [_loadChannels]
  /// so a slow/failed guide fetch never blocks (or breaks) the channel
  /// list itself — rows just show "No program info" until this resolves.
  Future<void> _loadCurrentPrograms() async {
    try {
      // Same trimmed 3-hour window the Live TV home screen uses — this
      // panel only ever needs to know what's airing *right now* per
      // channel, not a full guide.
      final programs = (await MediaService.getGuide(
        end: DateTime.now().add(const Duration(hours: 3)),
      ))
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();

      final currentByChannel = <String, Map<String, dynamic>>{};

      for (final program in programs) {
        final channelId = program["ChannelId"]?.toString();
        if (channelId == null || currentByChannel.containsKey(channelId)) {
          continue;
        }

        // Same "genuinely airing right now" check the TV Guide, Live TV
        // detail screen, and in-player Info sheet all share.
        if (EpgUtils.isLiveNow(program["StartDate"], program["EndDate"])) {
          currentByChannel[channelId] = program;
        }
      }

      if (!mounted) return;
      setState(() {
        _currentProgramByChannel = currentByChannel;
      });
    } catch (_) {
      // Non-fatal — the channel list itself already loaded fine, rows
      // just keep showing "No program info" instead of failing the
      // whole panel over guide data specifically.
    }
  }

  void _changeCategory(int delta) {
    setState(() {
      _categoryIndex = (_categoryIndex + delta) % _categories.length;
      if (_categoryIndex < 0) _categoryIndex += _categories.length;
    });
  }

  void _toggleSearch() {
    setState(() {
      _searching = !_searching;
      if (!_searching) {
        _query = "";
        _searchController.clear();
      }
    });

    if (_searching) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _searchFocus.requestFocus();
      });
    }
  }

  void _onSearchChanged(String value) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      setState(() => _query = value);
    });
  }

  List<Map<String, dynamic>> get _filteredChannels {
    final category = _categories[_categoryIndex];

    return _channels.where((channel) {
      final name = (channel["Name"] ?? "").toString();

      if (category != "All" && ChannelCategories.classify(name) != category) {
        return false;
      }

      if (_query.isEmpty) return true;

      final query = _query.toLowerCase();
      final program = _currentProgramByChannel[channel["Id"]?.toString()];
      final programName = (program?["Name"] ?? "").toString().toLowerCase();

      return name.toLowerCase().contains(query) || programName.contains(query);
    }).toList();
  }

  Future<void> _playChannel(Map<String, dynamic> channel) async {
    final media = MediaService.mediaItemFromJellyfin(channel);

    PlayerManager.instance.showChannelList.value = false;

    // Same "show a preview immediately, resolve the real stream in the
    // background" flow used everywhere else a channel gets tapped
    // (Live TV home, TV Guide) — except there's no navigation here,
    // since we're already sitting on the player screen.
    PlayerManager.instance.showLoadingPreview(media);
    unawaited(PlaybackService.playItem(media));
  }

  @override
  Widget build(BuildContext context) {
    final manager = PlayerManager.instance;

    // Aspect-scoped (MediaQuery.sizeOf) instead of the unscoped
    // MediaQuery.of(context) this used to call — that subscribed this
    // whole panel (including its own search field's results list, and
    // — since this panel stays mounted for the life of the player
    // screen — the movie/show subtitle-search sheet's keyboard too) to
    // every MediaQueryData field, including viewInsets.bottom, which
    // flips on every frame while any keyboard animates. sizeOf only
    // rebuilds when the actual screen size changes, which is the only
    // thing this width calculation cares about.
    final width = MediaQuery.sizeOf(context).width * 0.34;

    return ValueListenableBuilder<bool>(
      valueListenable: manager.showChannelList,
      builder: (_, open, __) {
        // Reload on every closed→open transition (real-time "now
        // airing" + progress bars), not just the very first time the
        // panel is opened.
        if (open && !_wasOpen) {
          WidgetsBinding.instance.addPostFrameCallback((_) => _loadChannels());
        }
        _wasOpen = open;

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
                  // Was SafeArea(left: false) here. SafeArea's own
                  // build() calls the *unscoped* MediaQuery.of(context)
                  // internally, which subscribes it to every
                  // MediaQueryData field — including viewInsets.bottom,
                  // which the framework updates every single frame
                  // while this panel's own search field (or the
                  // movie/show subtitle-search sheet elsewhere on this
                  // same player screen) is animating open or closed.
                  // That forced this entire channel list/search/chips
                  // tree to rebuild in lockstep with the keyboard's own
                  // animation. A plain Padding using the aspect-scoped
                  // `MediaQuery.paddingOf` below gets the identical
                  // top/right/bottom safe-area values (left was already
                  // excluded) but only rebuilds when device padding
                  // itself actually changes.
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(
                      0,
                      MediaQuery.paddingOf(context).top,
                      MediaQuery.paddingOf(context).right,
                      MediaQuery.paddingOf(context).bottom,
                    ),
                    child: _buildContent(context),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildContent(BuildContext context) {
    final manager = PlayerManager.instance;
    final category = _categories[_categoryIndex];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Top row: dismiss (left) — search (right).
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
          child: Row(
            children: [
              IconButton(
                onPressed: () => manager.showChannelList.value = false,
                icon: const Icon(Icons.close, color: Colors.white),
              ),

              // Small, unobtrusive spinner for reloads after the first —
              // the list itself stays exactly as-is underneath while
              // this shows, so a re-open doesn't flash empty/spinner
              // over channels that were already there.
              if (_loading && _loaded)
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    color: Colors.white54,
                    strokeWidth: 2,
                  ),
                ),

              const Spacer(),
              IconButton(
                onPressed: _toggleSearch,
                icon: Icon(
                  _searching ? Icons.close : Icons.search,
                  color: Colors.white,
                ),
              ),
            ],
          ),
        ),

        // Either the category switcher (arrows + label) or the search
        // field, never both — the search field takes over that row.
        if (_searching)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: _SearchField(
              controller: _searchController,
              focusNode: _searchFocus,
              onChanged: _onSearchChanged,
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
            child: Row(
              children: [
                IconButton(
                  onPressed: () => _changeCategory(-1),
                  icon: const Icon(Icons.chevron_left, color: _gold),
                ),
                Expanded(
                  child: Text(
                    category,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: () => _changeCategory(1),
                  icon: const Icon(Icons.chevron_right, color: _gold),
                ),
              ],
            ),
          ),

        const Divider(height: 1, color: Colors.white12),

        Expanded(child: _buildList()),
      ],
    );
  }

  Widget _buildList() {
    if (_loading && !_loaded) {
      return const Center(
        child: CircularProgressIndicator(color: _gold, strokeWidth: 2.4),
      );
    }

    if (_error != null) {
      return Center(
        child: Text(_error!, style: const TextStyle(color: Colors.white54)),
      );
    }

    final channels = _filteredChannels;

    if (channels.isEmpty) {
      return const Center(
        child: Text(
          "No channels found",
          style: TextStyle(color: Colors.white54),
        ),
      );
    }

    return ValueListenableBuilder<MediaItem?>(
      valueListenable: PlayerManager.instance.currentItemNotifier,
      builder: (_, currentItem, __) {
        return ListView.separated(
          padding: const EdgeInsets.symmetric(vertical: 6),
          itemCount: channels.length,
          separatorBuilder: (_, __) => const Divider(
            height: 1,
            indent: 16,
            endIndent: 16,
            color: Colors.white10,
          ),
          itemBuilder: (context, index) {
            final channel = channels[index];
            final program = _currentProgramByChannel[channel["Id"]?.toString()];
            final playing = currentItem != null &&
                currentItem.live &&
                currentItem.id == channel["Id"]?.toString();

            return _ChannelRow(
              channel: channel,
              program: program,
              playing: playing,
              onTap: () => _playChannel(channel),
            );
          },
        );
      },
    );
  }
}

class _SearchField extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onChanged;

  const _SearchField({
    required this.controller,
    required this.focusNode,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      focusNode: focusNode,
      style: const TextStyle(color: Colors.white),
      decoration: InputDecoration(
        isDense: true,
        hintText: "Search channels...",
        hintStyle: const TextStyle(color: Colors.white54),
        prefixIcon: const Icon(Icons.search, color: Colors.white70, size: 20),
        filled: true,
        fillColor: Colors.white.withValues(alpha: 0.08),
        contentPadding: const EdgeInsets.symmetric(vertical: 10),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(24),
          borderSide: BorderSide.none,
        ),
      ),
      onChanged: onChanged,
    );
  }
}

class _ChannelRow extends StatelessWidget {
  final Map<String, dynamic> channel;
  final Map<String, dynamic>? program;
  final bool playing;
  final VoidCallback onTap;

  const _ChannelRow({
    required this.channel,
    required this.program,
    required this.playing,
    required this.onTap,
  });

  double get _progress {
    if (program == null) return 0;
    return EpgUtils.progress(program!["StartDate"], program!["EndDate"]);
  }

  String get _duration {
    if (program == null) return "";
    return EpgUtils.formatDuration(
      program!["StartDate"],
      program!["EndDate"],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: onTap,
      child: Container(
        color: playing ? const Color(0x22D4AF37) : Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              width: 46,
              height: 46,
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: const Color(0xff2a2a2a),
                borderRadius: BorderRadius.circular(10),
              ),
              child: CachedNetworkImage(
                cacheManager: NemesisImageCache.instance,
                imageUrl: MediaService.getPrimaryImage(channel["Id"], size: 150),
                fit: BoxFit.contain,
                memCacheWidth: 120,
                fadeInDuration: const Duration(milliseconds: 200),
                placeholder: (_, __) => const SizedBox.shrink(),
                errorWidget: (_, __, ___) => const Icon(
                  Icons.live_tv,
                  color: Colors.white38,
                  size: 22,
                ),
              ),
            ),

            const SizedBox(width: 12),

            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    channel["Name"]?.toString() ?? "",
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: playing ? _gold : Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),

                  const SizedBox(height: 3),

                  Text(
                    program?["Name"]?.toString() ?? "No program info",
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: _gold,
                      fontSize: 12,
                    ),
                  ),

                  if (program != null) ...[
                    const SizedBox(height: 6),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: LinearProgressIndicator(
                        value: _progress,
                        minHeight: 3,
                        backgroundColor: Colors.white12,
                        valueColor: const AlwaysStoppedAnimation(_gold),
                      ),
                    ),
                    if (_duration.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        _duration,
                        style: const TextStyle(
                          color: Colors.white38,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
