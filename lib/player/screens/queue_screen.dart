import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';

import '../models/media_item.dart';
import '../player_manager.dart';
import '../playback_service.dart';
import '../services/playback_queue.dart';
import '../../casting/cast_manager.dart';
import '../../casting/playback_coordinator.dart';
import '../../casting/models/cast_session.dart';
import '../../casting/ui/cast_ui.dart';
import '../../services/jellyfin_services/media_service.dart';
import '../../services/local_playlist_service.dart';
import '../../widgets/music/song_selection_actions.dart';
import '../../utils/artwork_accent_extractor.dart';
import '../../utils/artwork_source.dart';
import '../../widgets/common/pressable.dart';
import '../../widgets/shared/nemesis_bottom_sheet.dart'
    show nemesisSheetSizes;
import '../../services/cache/nemesis_image_cache.dart';
import '../../utils/responsive.dart';
import '../../widgets/common/dustbin_icon.dart';

const _gold = Color(0xffD4AF37);
const _queueBg = Color(0xff121212);

/// ReorderableListView's default drag feedback wraps the row in an
/// opaque Material surface (the theme's canvas color) — against this
/// screen's transparent blurred-artwork rows, that showed up as the
/// dragged row snapping back to a flat solid box until it was dropped.
/// This swaps that for a frosted "liquid glass" surface instead: a
/// backdrop blur of whatever's behind it (the rest of the list/artwork
/// backdrop) plus a faint white tint and border, so the row reads as
/// lifted glass rather than a plain rectangle while it's being dragged.
Widget _queueRowProxyDecorator(
  Widget child,
  int index,
  Animation<double> animation,
) {
  return AnimatedBuilder(
    animation: animation,
    builder: (context, _) {
      final t = Curves.easeOut.transform(animation.value);
      final elevation = lerpDouble(0, 10, t)!;

      return Material(
        color: Colors.transparent,
        elevation: elevation,
        shadowColor: Colors.black87,
        borderRadius: BorderRadius.circular(12),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.10),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: Colors.white.withOpacity(0.22),
                ),
              ),
              child: child,
            ),
          ),
        ),
      );
    },
    child: child,
  );
}

class QueueScreen extends StatefulWidget {
  const QueueScreen({super.key});

  @override
  State<QueueScreen> createState() => _QueueScreenState();
}

class _QueueScreenState extends State<QueueScreen> {
  @override
  void initState() {
    super.initState();
    PlayerManager.instance.currentItemNotifier.addListener(_onItemChanged);
  }

  @override
  void dispose() {
    PlayerManager.instance.currentItemNotifier
        .removeListener(_onItemChanged);
    super.dispose();
  }

  void _onItemChanged() {
    _exitIfQueueEnded(PlayerManager.instance.currentItem);
  }

  // Re-checked any time this screen's "am I the visible route" status
  // changes, not just when the queue actually ends — see the same
  // comment on AudioPlayerScreen/LyricsScreen for why that matters.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _exitIfQueueEnded(PlayerManager.instance.currentItem);
  }

  // The queue ran out on its own (repeat off, last song finished) —
  // this screen has nothing left to show at that point, so close it
  // rather than leaving the user sitting on an empty "Queue is empty"
  // list. Only pops if this screen is still the one actually visible.
  void _exitIfQueueEnded(MediaItem? item) {
    if (item != null || !mounted) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;

      final route = ModalRoute.of(context);

      if (route != null && route.isCurrent && Navigator.canPop(context)) {
        Navigator.pop(context);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final queue = PlaybackQueue.instance;

    return Scaffold(
      appBar: AppBar(
        title: const Text("Queue"),
        backgroundColor: Colors.transparent,
        elevation: 0,
        // Always tinted with the currently-playing track's own artwork
        // color — the same "collapsed bar takes the artwork's color"
        // treatment as the album detail screen's top bar, except here
        // it's on permanently rather than only appearing once scrolled,
        // since this screen has no separate expanded/collapsed states.
        flexibleSpace: const _QueueAppBarBackground(),
      ),
      body: Stack(
        children: [
          const Positioned.fill(child: _QueueBackground()),

          Column(
            children: [
              const _QueueControlsRow(),

              Expanded(
                child: ValueListenableBuilder<List<MediaItem>>(
                  valueListenable: queue.queueNotifier,
                  builder: (context, items, _) {
                    return ValueListenableBuilder<int>(
                      valueListenable: queue.currentIndexNotifier,
                      builder: (context, currentIndex, _) {
                        if (items.isEmpty) {
                          return const Center(
                            child: Text(
                              "Queue is empty",
                              style: TextStyle(color: Colors.white54),
                            ),
                          );
                        }

                        final hasCurrent =
                            currentIndex >= 0 && currentIndex < items.length;

                        final currentItem =
                            hasCurrent ? items[currentIndex] : null;

                        // Only the currently-playing track and everything
                        // still ahead of it are shown — matching Spotify's
                        // queue screen rather than a full scroll-back
                        // history. `baseIndex` is where "upcoming" starts
                        // in the *actual* queue list, so taps/drags/swipes
                        // on the upcoming list can be translated back to
                        // real queue indices.
                        final baseIndex = hasCurrent ? currentIndex + 1 : 0;
                        final upcoming =
                            hasCurrent ? items.sublist(baseIndex) : items;

                        return Column(
                          children: [
                            if (currentItem != null) ...[
                              const _SectionLabel("Now playing"),

                              _QueueRow(
                                item: currentItem,
                                playing: true,
                              ),
                            ],

                            if (upcoming.isNotEmpty)
                              const _SectionLabel("Next up"),

                            Expanded(
                              child: upcoming.isEmpty
                                  ? const SizedBox.shrink()
                                  : ReorderableListView.builder(
                                      buildDefaultDragHandles: false,
                                      padding:
                                          const EdgeInsets.only(bottom: 24),
                                      proxyDecorator:
                                          _queueRowProxyDecorator,
                                      itemCount: upcoming.length,
                                      onReorder: (oldIndex, newIndex) {
                                        queue.move(
                                          baseIndex + oldIndex,
                                          baseIndex + newIndex,
                                        );
                                      },
                                      itemBuilder: (context, i) {
                                        final item = upcoming[i];
                                        final actualIndex = baseIndex + i;

                                        return _QueueRow(
                                          key: ValueKey(item.id),
                                          item: item,
                                          playing: false,
                                          dragIndex: i,
                                          onTap: () async {
                                            // CASTING FIX (queue did
                                            // nothing while casting):
                                            // this used to always call
                                            // PlayerManager.playMedia()
                                            // directly — purely local,
                                            // so tapping a queued song
                                            // while a cast session was
                                            // active jumped the on-screen
                                            // index but never told the
                                            // TV to actually play
                                            // anything. While casting,
                                            // route through
                                            // PlaybackCoordinator so the
                                            // tapped song loads on the
                                            // connected device instead —
                                            // same "keep it on the TV"
                                            // rule playAudioQueueOnActiveCast
                                            // already applies everywhere
                                            // else a song gets tapped.
                                            if (CastManager
                                                .instance.isCasting) {
                                              final sent =
                                                  await PlaybackCoordinator
                                                      .instance
                                                      .castJumpTo(
                                                actualIndex,
                                              );
                                              if (sent) return;
                                            }

                                            queue.jumpTo(actualIndex);

                                            await PlayerManager.instance
                                                .playMedia(queue.current!);
                                          },
                                          onDismissed: () {
                                            queue.removeAt(actualIndex);
                                          },
                                        );
                                      },
                                    ),
                            ),
                          ],
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Always-on gradient tint for the Queue screen's AppBar, colored from
/// the currently-playing track's artwork — same idea as the album
/// detail screen's collapsed top bar, just permanently active instead
/// of fading in on scroll (there's no expanded/collapsed state here).
/// Re-extracts the accent color only when the track's artwork actually
/// changes, via a keyed swap (AnimatedSwitcher + ValueKey) exactly like
/// [AccentTintedBar] does for the movie/collection headers.
class _QueueAppBarBackground extends StatelessWidget {
  const _QueueAppBarBackground();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<MediaItem?>(
      valueListenable: PlayerManager.instance.currentItemNotifier,
      builder: (context, item, _) {
        final imageUrl = item?.image;

        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 400),
          child: _QueueAccentTint(
            key: ValueKey(imageUrl),
            imageUrl: imageUrl,
          ),
        );
      },
    );
  }
}

class _QueueAccentTint extends StatefulWidget {
  final String? imageUrl;

  const _QueueAccentTint({super.key, required this.imageUrl});

  @override
  State<_QueueAccentTint> createState() => _QueueAccentTintState();
}

class _QueueAccentTintState extends State<_QueueAccentTint> {
  Color? _accent;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final url = widget.imageUrl;
    if (url == null) return;

    final color = await ArtworkAccentExtractor.extractFromUrl(url);
    if (!mounted) return;
    setState(() => _accent = color);
  }

  @override
  Widget build(BuildContext context) {
    final accent = _accent;

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: [
            _queueBg,
            accent == null ? _queueBg : Color.lerp(_queueBg, accent, 0.85)!,
          ],
        ),
      ),
    );
  }
}

/// Full-bleed, heavily blurred, darkened backdrop behind the queue list —
/// the currently playing track's own artwork stretched to cover the
/// whole screen, matching the washed-out full-art-background treatment
/// other queue screens (Spotify, YouTube Music) use instead of a flat
/// color. Rebuilds only when the *track* changes, not on every queue
/// reorder/consume, since it listens to currentItemNotifier directly
/// rather than the queue list itself.
class _QueueBackground extends StatelessWidget {
  const _QueueBackground();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<MediaItem?>(
      valueListenable: PlayerManager.instance.currentItemNotifier,
      builder: (context, item, _) {
        final imageUrl = item?.image;

        return Container(
          color: const Color(0xff121212),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (imageUrl != null)
                ClipRect(
                  child: ImageFiltered(
                    imageFilter: ImageFilter.blur(
                      sigmaX: 7,
                      sigmaY: 7,
                      tileMode: TileMode.decal,
                    ),
                    child: Transform.scale(
                      // Scaled up before blurring so the heavy blur's
                      // soft, faded edges land outside the visible
                      // screen bounds (ClipRect above trims them)
                      // instead of leaving a washed-out border where
                      // the image runs out.
                      scale: 1.08,
                      child: isRemoteArtwork(imageUrl)
                          ? CachedNetworkImage(
                              cacheManager: NemesisImageCache.instance,
                              imageUrl: imageUrl,
                              fit: BoxFit.cover,
                              width: double.infinity,
                              height: double.infinity,
                            )
                          : Image.file(
                              File(imageUrl),
                              fit: BoxFit.cover,
                              width: double.infinity,
                              height: double.infinity,
                              errorBuilder: (_, __, ___) =>
                                  const SizedBox.shrink(),
                            ),
                    ),
                  ),
                ),

              // Darkening scrim — strongest at the very top, behind the
              // "Now playing" header and app bar, easing up through the
              // middle of the list so the blurred art still reads as a
              // photo rather than a flat tint, then deepening again
              // toward the bottom.
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    stops: const [0.0, 0.32, 0.68, 1.0],
                    colors: [
                      Colors.black.withOpacity(0.85),
                      Colors.black.withOpacity(0.55),
                      Colors.black.withOpacity(0.6),
                      Colors.black.withOpacity(0.82),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;

  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          text,
          style: const TextStyle(
            color: Colors.white54,
            fontSize: 12,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.6,
          ),
        ),
      ),
    );
  }
}

/// Shuffle / repeat / playlist controls above the queue list. Mirrors the
/// gold "active" styling used throughout the player, and updates the
/// queue immediately since it's all driven off [PlaybackQueue]'s
/// ValueNotifiers.
class _QueueControlsRow extends StatelessWidget {
  const _QueueControlsRow();

  @override
  Widget build(BuildContext context) {
    final queue = PlaybackQueue.instance;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          ValueListenableBuilder<bool>(
            valueListenable: queue.shuffleNotifier,
            builder: (context, shuffled, _) {
              return IconButton(
                icon: Icon(
                  Icons.shuffle,
                  color: shuffled ? _gold : Colors.white70,
                ),
                onPressed: queue.shuffle,
              );
            },
          ),

          ValueListenableBuilder<QueueRepeatMode>(
            valueListenable: queue.repeatModeNotifier,
            builder: (context, mode, _) {
              return IconButton(
                icon: Icon(
                  mode == QueueRepeatMode.one
                      ? Icons.repeat_one
                      : Icons.repeat,
                  color: mode == QueueRepeatMode.off
                      ? Colors.white70
                      : _gold,
                ),
                onPressed: queue.cycleRepeatMode,
              );
            },
          ),

          IconButton(
            icon: const Icon(Icons.playlist_play, color: Colors.white70),
            onPressed: () => _showPlaylistPicker(context),
          ),
        ],
      ),
    );
  }

  void _showPlaylistPicker(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xff181818),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => const _PlaylistPickerSheet(),
    );
  }
}

class _PlaylistPickerSheet extends StatefulWidget {
  const _PlaylistPickerSheet();

  @override
  State<_PlaylistPickerSheet> createState() => _PlaylistPickerSheetState();
}

class _PlaylistPickerSheetState extends State<_PlaylistPickerSheet> {
  // Server playlists plus device-only ones (see LocalPlaylistService).
  // A failing server call no longer empties the sheet — device-only
  // playlists don't need the server.
  late final Future<List<dynamic>> _future = _loadPlaylists();

  Future<List<dynamic>> _loadPlaylists() async {
    await LocalPlaylistService.instance.ensureLoaded();

    List<dynamic> server = const [];
    try {
      server = await MediaService.getPlaylists();
    } catch (_) {}

    return LocalPlaylistService.instance.mergePlaylists(
      server,
      newestFirst: false,
    );
  }

  bool _loadingId = false;

  @override
  Widget build(BuildContext context) {
    // Landscape: opens at most 2/3 of the screen, draggable to full.
    final sizes = nemesisSheetSizes(
      context,
      initial: 0.6,
      min: 0.3,
      max: 0.9,
    );

    return DraggableScrollableSheet(
      initialChildSize: sizes.initial,
      minChildSize: sizes.min,
      maxChildSize: sizes.max,
      expand: false,
      builder: (context, scrollController) {
        return Column(
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(top: 10, bottom: 4),
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 8, 20, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  "Playlists",
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),

            Expanded(
              child: FutureBuilder<List<dynamic>>(
                future: _future,
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const Center(
                      child: CircularProgressIndicator(color: _gold),
                    );
                  }

                  final playlists = snapshot.data ?? [];

                  if (playlists.isEmpty) {
                    return const Center(
                      child: Text(
                        "No playlists found",
                        style: TextStyle(color: Colors.white54),
                      ),
                    );
                  }

                  return ListView.builder(
                    controller: scrollController,
                    itemCount: playlists.length,
                    itemBuilder: (context, index) {
                      final playlist = playlists[index];
                      final id = playlist["Id"].toString();
                      final name = playlist["Name"] ?? "";
                      final isDeviceOnly = playlist["IsLocalPlaylist"] == true;
                      // A device-only playlist has no server image to
                      // request — it falls straight to the placeholder.
                      final image = isDeviceOnly
                          ? ''
                          : MediaService.getPrimaryImage(id, size: 130);
                      // 10-foot viewing distance makes a flat 46px
                      // thumbnail hard to make out on TV; the network
                      // fetch above (130) already has headroom for this,
                      // so only the rendered size needs to grow.
                      final thumbSize = Responsive.isTV ? 64.0 : 46.0;

                      return ListTile(
                        leading: ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: isDeviceOnly
                              ? Container(
                                  width: thumbSize,
                                  height: thumbSize,
                                  color: const Color(0xff252525),
                                  child: const Icon(
                                    Icons.queue_music,
                                    color: Colors.white24,
                                  ),
                                )
                              : CachedNetworkImage(
                                  cacheManager: NemesisImageCache.instance,
                                  imageUrl: image,
                                  width: thumbSize,
                                  height: thumbSize,
                                  fit: BoxFit.cover,
                                  errorWidget: (_, __, ___) => Container(
                                    width: thumbSize,
                                    height: thumbSize,
                                    color: const Color(0xff252525),
                                    child: const Icon(
                                      Icons.queue_music,
                                      color: Colors.white24,
                                    ),
                                  ),
                                ),
                        ),
                        title: Text(
                          name,
                          style: const TextStyle(color: Colors.white),
                        ),
                        subtitle: isDeviceOnly
                            ? const Text(
                                "On this device only",
                                style: TextStyle(
                                  color: Colors.white38,
                                  fontSize: 12,
                                ),
                              )
                            : null,
                        trailing: _loadingId
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: _gold,
                                ),
                              )
                            : null,
                        onTap: () => _playPlaylist(id, name),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _playPlaylist(String id, String name) async {
    if (_loadingId) return;

    setState(() => _loadingId = true);

    try {
      // Device-only playlists have no server tracklist; a server
      // playlist's tracks get its on-device songs appended (same order
      // MusicDetailScreen shows them in). Built per song so on-device
      // ones get a file-backed item instead of a Jellyfin stream URL.
      final tracks = LocalPlaylistService.isLocalPlaylistId(id)
          ? await LocalPlaylistService.instance.songsFor(id)
          : [
              ...await MediaService.getPlaylistTracks(id),
              ...await LocalPlaylistService.instance.songsFor(id),
            ];
      final queueItems = mediaItemsFromMixedSongs(tracks);

      if (queueItems.isEmpty) return;

      await PlaybackService.playQueue(
        queueItems,
        source: PlaybackSource.playlist,
        title: name,
      );

      if (mounted) Navigator.of(context).pop();
    } finally {
      if (mounted) setState(() => _loadingId = false);
    }
  }
}

class _QueueRow extends StatelessWidget {
  final MediaItem item;
  final bool playing;

  /// Index within the reorderable "upcoming" list — null for the pinned
  /// now-playing row, which can't be dragged or swiped away.
  final int? dragIndex;

  final VoidCallback? onTap;
  final VoidCallback? onDismissed;

  const _QueueRow({
    super.key,
    required this.item,
    required this.playing,
    this.dragIndex,
    this.onTap,
    this.onDismissed,
  });

  @override
  Widget build(BuildContext context) {
    // Only the tappable info area (artwork + text) is wrapped in
    // InkWell. Its tap recognizer sits in the same gesture arena as
    // whatever's inside it, and was quietly beating the drag handle's
    // long-press-to-drag recognizer — the row wasn't actually picking
    // up when dragged, it was just showing InkWell's ordinary
    // press-highlight for as long as the finger stayed down. Keeping
    // the handle as a sibling, outside InkWell, gives its recognizer
    // an uncontested region to win from.
    final infoContent = InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Row(
          children: [
            _QueueArtwork(item: item, playing: playing),

            const SizedBox(width: 12),

            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      if (playing) ...[
                        const _QueueVisualizer(),
                        const SizedBox(width: 6),
                      ],

                      Expanded(
                        child: Text(
                          item.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: playing ? _gold : Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 4),

                  Text(
                    item.subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white54,
                      fontSize: 12,
                    ),
                  ),

                  if (playing) ...[
                    const SizedBox(height: 8),
                    const _QueueProgressBar(),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );

    // The handle is a sibling of infoContent rather than nested inside
    // it, but both still sit inside the same Row that Dismissible
    // wraps below — so it slides along with the rest of the row when
    // swiped to delete, without sharing InkWell's gesture region.
    final rowContent = Row(
      children: [
        Expanded(child: infoContent),

        if (dragIndex != null)
          // A plain ReorderableDelayedDragStartListener waits for
          // Flutter's default long-press delay (~500ms), which reads
          // as a deliberate "hold" rather than a quick touch-and-lift.
          // _QueueDragStartListener below uses the same underlying
          // mechanism with a much shorter delay, so a touch just
          // slightly longer than a normal tap is enough to pick the
          // row up.
          _QueueDragStartListener(
            index: dragIndex!,
            child: const _DragHandle(),
          ),
      ],
    );

    final swipeableContent = onDismissed == null
        ? rowContent
        : Dismissible(
            key: ValueKey("dismiss_${item.id}_${dragIndex ?? 0}"),
            onDismissed: (_) => onDismissed!(),
            background: _dismissBackground(Alignment.centerLeft),
            secondaryBackground: _dismissBackground(Alignment.centerRight),
            child: rowContent,
          );

    final card = ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: swipeableContent,
    );

    if (!playing) {
      return Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: card,
      );
    }

    // The pinned "Now playing" row gets a frosted-glass treatment — a
    // backdrop blur of the artwork scrolling underneath it, a very
    // faint tint (light enough that the artwork's actual color still
    // shows through instead of just reading as a flat grey box), and a
    // soft highlight along the top edge like light catching the edge
    // of real glass.
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: Colors.white.withOpacity(0.16),
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.white.withOpacity(0.14),
                  Colors.white.withOpacity(0.04),
                ],
              ),
            ),
            child: swipeableContent,
          ),
        ),
      ),
    );
  }

  Widget _dismissBackground(Alignment alignment) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      alignment: alignment,
      color: Colors.red.withValues(alpha: 0.25),
      child: const DustbinIcon(color: Colors.white70),
    );
  }
}

/// Album/track artwork for a queue row. The currently-playing row gets a
/// tappable play/pause overlay on top of the artwork.
class _QueueArtwork extends StatelessWidget {
  final MediaItem item;
  final bool playing;

  const _QueueArtwork({required this.item, required this.playing});

  @override
  Widget build(BuildContext context) {
    final image = item.image;

    // At 10-foot TV viewing distance a flat 52px row thumbnail (tuned
    // for phone) reads as barely more than a color swatch — same class
    // of issue the AlbumCard fix already addressed for grid artwork.
    // The network fetch/cache dimensions below are derived from this
    // size (times devicePixelRatio) so the TV request actually asks for
    // a larger image instead of just upscaling the same 52px decode.
    final artSize = Responsive.isTV ? 72.0 : 52.0;
    final cachePixels = (artSize * MediaQuery.devicePixelRatioOf(context))
        .round();

    final art = ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: image != null
          ? (isRemoteArtwork(image)
              ? CachedNetworkImage(
                cacheManager: NemesisImageCache.instance,
                  imageUrl: image,
                  width: artSize,
                  height: artSize,
                  fit: BoxFit.cover,
                  memCacheWidth: cachePixels,
                  memCacheHeight: cachePixels,
                  fadeInDuration: const Duration(milliseconds: 150),
                  placeholder: (_, __) => Container(
                    width: artSize,
                    height: artSize,
                    color: const Color(0xff252525),
                  ),
                  errorWidget: (_, __, ___) => Container(
                    width: artSize,
                    height: artSize,
                    color: const Color(0xff252525),
                    child: const Icon(
                      Icons.music_note,
                      color: Colors.white24,
                      size: 24,
                    ),
                  ),
                )
              : Image.file(
                  File(image),
                  width: artSize,
                  height: artSize,
                  fit: BoxFit.cover,
                  cacheWidth: cachePixels,
                  errorBuilder: (_, __, ___) => Container(
                    width: artSize,
                    height: artSize,
                    color: const Color(0xff252525),
                    child: const Icon(
                      Icons.music_note,
                      color: Colors.white24,
                      size: 24,
                    ),
                  ),
                ))
          : Container(
              width: artSize,
              height: artSize,
              color: const Color(0xff252525),
              child: const Icon(
                Icons.music_note,
                color: Colors.white24,
                size: 24,
              ),
            ),
    );

    if (!playing) return art;

    return SizedBox(
      width: artSize,
      height: artSize,
      child: Stack(
        alignment: Alignment.center,
        children: [
          art,

          Container(
            width: artSize,
            height: artSize,
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(8),
            ),
          ),

          // CASTING FIX (overlay did nothing while casting): this used to
          // always drive the phone's local player, which is paused/idle
          // during a cast, so tapping it never reached the TV. While a
          // session is connected it now reads the session's own playback
          // state and sends play/pause through CastManager — the exact
          // path the mini player and cast controls use.
          ValueListenableBuilder<CastSession?>(
            valueListenable: CastManager.instance.activeSession,
            builder: (context, session, _) {
              if (session == null) {
                return ValueListenableBuilder<bool>(
                  valueListenable: PlayerManager.instance.playing,
                  builder: (context, isPlaying, _) {
                    return Pressable(
                      borderRadius: BorderRadius.circular(8),
                      onTap: () {
                        PlayerManager.instance.player.playOrPause();
                      },
                      child: Icon(
                        isPlaying ? Icons.pause : Icons.play_arrow,
                        color: Colors.white,
                        size: 26,
                      ),
                    );
                  },
                );
              }

              return ValueListenableBuilder<bool>(
                valueListenable: session.showsPlaying,
                builder: (context, isPlaying, _) {
                  return Pressable(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () {
                      runCastCommand(
                        context,
                        CastManager.instance.togglePlayPause,
                      );
                    },
                    child: Icon(
                      isPlaying ? Icons.pause : Icons.play_arrow,
                      color: Colors.white,
                      size: 26,
                    ),
                  );
                },
              );
            },
          ),
        ],
      ),
    );
  }
}

/// Thin progress bar tracking playback position for the currently
/// Thin progress bar tracking playback position for the currently
/// playing row, always shown in the same gold used throughout the
/// player rather than a per-track extracted accent color.
class _QueueProgressBar extends StatelessWidget {
  const _QueueProgressBar();

  @override
  Widget build(BuildContext context) {
    final manager = PlayerManager.instance;

    return ValueListenableBuilder<Duration>(
      valueListenable: manager.position,
      builder: (context, position, _) {
        return ValueListenableBuilder<Duration>(
          valueListenable: manager.duration,
          builder: (context, duration, _) {
            final total = duration.inMilliseconds;
            final value = total == 0
                ? 0.0
                : (position.inMilliseconds / total).clamp(0.0, 1.0);

            return ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: value,
                minHeight: 3,
                backgroundColor: Colors.white24,
                valueColor: const AlwaysStoppedAnimation(_gold),
              ),
            );
          },
        );
      },
    );
  }
}

/// Small pulsing bar-equalizer next to the now-playing row's title.
/// Mirrors [SongRow]'s visualizer: when playback pauses, the bars ease
/// down into three small dots resting at the bottom of the same
/// footprint (and back up into bars on resume) instead of either
/// freezing mid-bar or pulsing forever regardless of playback state.
class _QueueVisualizer extends StatefulWidget {
  const _QueueVisualizer();

  @override
  State<_QueueVisualizer> createState() => _QueueVisualizerState();
}

class _QueueVisualizerState extends State<_QueueVisualizer>
    with TickerProviderStateMixin {
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
      // song happens to be paused, otherwise starts as full bars.
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

/// Like [ReorderableDelayedDragStartListener], but with a much shorter
/// hold delay. Flutter's built-in delayed listener waits for the
/// standard long-press duration (~500ms) before starting the drag,
/// which reads as a deliberate hold rather than a quick touch — this
/// starts the drag after a brief, tap-like delay instead, so lifting
/// the row feels immediate without being so short that it fights the
/// list's own scroll gesture (which an undelayed listener would).
class _QueueDragStartListener extends StatelessWidget {
  final Widget child;
  final int index;

  const _QueueDragStartListener({
    required this.child,
    required this.index,
  });

  @override
  Widget build(BuildContext context) {
    return Listener(
      // Opaque so pointer events are captured across the handle's full
      // hit-test area, not just where the two thin bars actually paint.
      // With the default deferToChild behavior, touches landing in the
      // empty space around the lines (most of the 44x44 target) never
      // reached this Listener at all, which is why the handle felt
      // unresponsive outside a couple of very precise pixels.
      behavior: HitTestBehavior.opaque,
      onPointerDown: (event) => _startDragging(context, event),
      child: child,
    );
  }

  void _startDragging(BuildContext context, PointerDownEvent event) {
    final gestureSettings = MediaQuery.maybeGestureSettingsOf(context);
    final list = SliverReorderableList.maybeOf(context);

    // ImmediateMultiDragGestureRecognizer wins the gesture arena and
    // starts the drag on the very first pointer-down on the handle —
    // no hold delay at all, unlike DelayedMultiDragGestureRecognizer
    // (which still waited ~120ms before arming). Since the handle is
    // its own hit-test region (a sibling of the tappable info area,
    // not nested inside it — see the comment on `rowContent` above),
    // there's no competing tap recognizer for it to race against, so
    // going fully immediate here is safe and doesn't cost accidental
    // drags from ordinary row taps.
    list?.startItemDragReorder(
      index: index,
      event: event,
      recognizer: ImmediateMultiDragGestureRecognizer(
        debugOwner: this,
      )..gestureSettings = gestureSettings,
    );
  }
}

/// Two-line drag handle for reordering queue rows, matching Spotify's
/// trailing drag affordance rather than a full hamburger icon.
class _DragHandle extends StatelessWidget {
  const _DragHandle();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 44,
      height: 44,
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 16,
              height: 2,
              decoration: BoxDecoration(
                color: Colors.white38,
                borderRadius: BorderRadius.circular(1),
              ),
            ),
            const SizedBox(height: 4),
            Container(
              width: 16,
              height: 2,
              decoration: BoxDecoration(
                color: Colors.white38,
                borderRadius: BorderRadius.circular(1),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
