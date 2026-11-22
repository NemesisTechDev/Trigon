import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../casting/cast_manager.dart';
import '../../services/download_manager.dart';
import '../../services/jellyfin_services/media_service.dart';
import '../../services/media_extras_cache_service.dart';
import '../models/media_item.dart';
import '../player_manager.dart';
import '../services/lrclib_service.dart';
import '../services/lrcmux_service.dart';
import '../widgets/player_accent_background.dart';
import '../widgets/player_controls_bar.dart';
import '../../utils/responsive.dart';

class _LyricLine {
  final String text;
  final Duration? start;

  const _LyricLine({required this.text, this.start});
}

/// Full-screen synced (or plain) lyrics view for the currently playing
/// track. Pulls lyrics straight from Jellyfin's `/Audio/{id}/Lyrics`
/// endpoint. When the server returns per-line timestamps the active
/// line is highlighted and auto-scrolled in time with playback; when it
/// only has plain text (no timestamps), the lyrics are shown statically.
///
/// The active line + auto-scroll are driven by a [ValueNotifier] that
/// only the individual line widgets listen to (see [_LyricLineTile])
/// rather than a `setState` on the whole screen. Position updates fire
/// many times a second while a song plays, so keeping that off the
/// screen's own rebuild path is what keeps the highlight glide and
/// auto-scroll smooth instead of stuttering — the background, header,
/// and controls bar never re-render just because playback moved on.
class LyricsScreen extends StatefulWidget {
  const LyricsScreen({super.key});

  @override
  State<LyricsScreen> createState() => _LyricsScreenState();
}

class _LyricsScreenState extends State<LyricsScreen> {
  final ScrollController _scrollController = ScrollController();
  final Map<int, GlobalKey> _lineKeys = {};
  final ValueNotifier<int> _activeIndexNotifier = ValueNotifier(-1);

  List<_LyricLine>? _lines;
  bool _loading = true;
  bool _hasTimestamps = false;
  String? _loadedForItemId;

  // Drives the "Search Lyrics" button state: LRCLIB is now only ever
  // queried when the user explicitly asks for it (see _searchLrcLib),
  // not automatically the moment Jellyfin comes back empty — silent
  // auto-fetch was indistinguishable from "LRCLIB found nothing" and
  // "the request itself failed", which made a real bug (see
  // mediaItemFromJellyfin's artist fallback fix) look identical to
  // LRCLIB just not having the track.
  bool _searchingLrcLib = false;
  bool _lrcLibSearchedAndEmpty = false;

  // The very first time an active line resolves for a freshly-opened
  // screen (e.g. lyrics opened mid-song), snap straight there instead
  // of gliding up from the top — that glide only reads as "smooth" when
  // it's following real playback, not on first paint.
  bool _didInitialScroll = false;

  @override
  void initState() {
    super.initState();
    PlayerManager.instance.currentItemNotifier.addListener(_onItemChanged);
    PlayerManager.instance.position.addListener(_onPositionChanged);
    _load(PlayerManager.instance.currentItem);
  }

  @override
  void dispose() {
    PlayerManager.instance.currentItemNotifier
        .removeListener(_onItemChanged);
    PlayerManager.instance.position.removeListener(_onPositionChanged);
    _scrollController.dispose();
    _activeIndexNotifier.dispose();
    super.dispose();
  }

  void _onPositionChanged() {
    _updateActiveIndex(PlayerManager.instance.position.value);
  }

  void _onItemChanged() {
    final item = PlayerManager.instance.currentItem;

    // Guards against reloading lyrics for every position/queue tweak —
    // only a genuinely different track (e.g. skip to next song while
    // this screen is open) should trigger a refetch.
    if (item?.id != _loadedForItemId) {
      _load(item);
    }

    _exitIfQueueEnded(item);
  }

  // Re-checked any time this screen's "am I the visible route" status
  // changes — not just when the queue actually ends. Without this, a
  // screen that was covered by the Queue screen at the exact moment
  // the queue ended would correctly skip popping itself (per the
  // isCurrent guard below), but then never got asked again once it
  // *became* current after the screen on top of it closed — leaving
  // it stuck showing its empty state instead of also closing in turn.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _exitIfQueueEnded(PlayerManager.instance.currentItem);
  }

  // The queue ran out on its own (repeat off, last song finished) —
  // PlayerManager.stop() has already deactivated the mini player, so
  // exit this screen too instead of leaving it on an empty black
  // scaffold with nothing playing. Only pops if this screen is still
  // the one actually visible.
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

  /// Shared by every "found lyrics without hitting the network" path
  /// below — parses and shows [content] exactly like a server-provided
  /// lyric, bailing out without touching state if the track has already
  /// moved on while this was resolving. Returns whether [content]
  /// actually contained anything usable, so each caller can tell "found
  /// but empty" apart from "genuinely nothing here" and fall through
  /// accordingly.
  bool _applyLrcContent(String content, MediaItem item) {
    final lines = _parseLrc(content);
    if (lines.isEmpty) return false;

    if (!mounted || PlayerManager.instance.currentItem?.id != item.id) {
      return true;
    }

    _lineKeys
      ..clear()
      ..addEntries(
        List.generate(lines.length, (i) => MapEntry(i, GlobalKey())),
      );

    setState(() {
      _lines = lines;
      _hasTimestamps = lines.any((l) => l.start != null);
      _loading = false;
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _updateActiveIndex(PlayerManager.instance.position.value);
    });

    return true;
  }

  /// Reads this track's `.lrc` sidecar (if any) straight off disk/memory
  /// and shows it exactly like a server-provided lyric, without ever
  /// hitting the network. Returns true when it found and applied usable
  /// lyrics this way — the caller falls through to the normal network
  /// fetch when it returns false (nothing sidecar-shaped for this
  /// track at all, or the file/content turned out empty). Tries, in
  /// order:
  ///  1. A DownloadManager-downloaded song's own `.lrc` sidecar (see
  ///     DownloadManager.downloadSong) — read by Jellyfin item id.
  ///  2. An on-device library song's same-named `.lrc` sitting next to
  ///     it on disk (see LocalMusicService's `LyricsPath` field) — same
  ///     sidecar convention, just matched by file name on a local scan
  ///     rather than a download record, since this file was never
  ///     downloaded through this app at all.
  ///  3. An Open With/Play With song's sidecar, when the native side
  ///     found one next to the source file and handed the text straight
  ///     back (see ExternalMediaHandler's `SidecarLyricsContent` — the
  ///     lyrics counterpart to that same feature's existing
  ///     `SidecarSubtitleContent`). Already raw text, not a path — a
  ///     content:// URI has nothing on disk for this app to read beside
  ///     directly, which is exactly why the native side resolves it
  ///     instead and rides the text along on the payload.
  Future<bool> _loadFromDownloadedLyrics(MediaItem item) async {
    final downloadedPath =
        DownloadManager.instance.recordFor(item.id)?.lyricsPath;
    final onDevicePath = item.raw?['LyricsPath'] as String?;
    final lyricsPath = downloadedPath ?? onDevicePath;

    if (lyricsPath != null) {
      try {
        final file = File(lyricsPath);
        if (await file.exists()) {
          final content = await file.readAsString();
          if (_applyLrcContent(content, item)) return true;
        }
      } catch (e) {
        debugPrint('local lyrics read failed for ${item.id}: $e');
      }
    }

    final sidecarContent = item.raw?['SidecarLyricsContent'] as String?;
    if (sidecarContent != null && sidecarContent.isNotEmpty) {
      if (_applyLrcContent(sidecarContent, item)) return true;
    }

    return false;
  }

  /// Mirrors [_loadFromDownloadedLyrics], but reads from the app's own
  /// LRCLIB cache (see [MediaExtrasCacheService]) instead of a
  /// downloaded song's sidecar file. Returns true when a cached match
  /// was found and applied.
  Future<bool> _loadFromCachedLyrics(MediaItem item) async {
    final content = await MediaExtrasCacheService.readLyrics(item.id);
    if (content == null) return false;

    if (!mounted || PlayerManager.instance.currentItem?.id != item.id) {
      return true;
    }

    final lines = _parseLrc(content);
    if (lines.isEmpty) return false;

    _lineKeys
      ..clear()
      ..addEntries(
        List.generate(lines.length, (i) => MapEntry(i, GlobalKey())),
      );

    setState(() {
      _lines = lines;
      _hasTimestamps = lines.any((l) => l.start != null);
      _loading = false;
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _updateActiveIndex(PlayerManager.instance.position.value);
    });

    return true;
  }

  /// Serializes parsed lyric lines back to standard LRC text — the
  /// inverse of [_parseLrc] — so an LRCLIB match found via
  /// [_searchLrcLib] can be written to [MediaExtrasCacheService] in the
  /// same format a downloaded song's sidecar already uses.
  String _linesToLrc(List<_LyricLine> lines) {
    final buffer = StringBuffer();

    for (final line in lines) {
      final start = line.start;
      if (start != null) {
        final minutes = start.inMinutes;
        final seconds = start.inSeconds % 60;
        final centis = (start.inMilliseconds % 1000) ~/ 10;
        buffer.writeln(
          '[${minutes.toString().padLeft(2, '0')}:'
          '${seconds.toString().padLeft(2, '0')}.'
          '${centis.toString().padLeft(2, '0')}]${line.text}',
        );
      } else {
        buffer.writeln(line.text);
      }
    }

    return buffer.toString();
  }

  /// Parses standard LRC text (`[mm:ss.xx]line`, one line per tag) back
  /// into the same `_LyricLine` shape the Jellyfin JSON path produces.
  /// Lines with no timestamp tag (LRCLIB-style plain lyrics) come
  /// through as untimed lines, same as Jellyfin's own plain-text case.
  ///
  /// Real-world `.lrc` files (native sidecars especially — LRCLIB's own
  /// export and most taggers/generators) commonly lead with ID3-style
  /// metadata tags — `[ti:Title]`, `[ar:Artist]`, `[al:Album]`,
  /// `[by:...]`, `[offset:...]`, `[re:...]`/`[tool:...]` naming the
  /// encoder, etc. — before the first timed line. None of those match
  /// the timestamp pattern, so they used to fall into the plain-text
  /// branch below and render as literal lyric lines: exactly the
  /// bracketed "branding" showing up above the real lyrics. These are
  /// header metadata, not a lyric, so they're dropped instead.
  List<_LyricLine> _parseLrc(String content) {
    final tagPattern = RegExp(r'^\[(\d{2}):(\d{2})\.(\d{2})\](.*)$');
    // Standard LRC metadata tag: a short known key, not a timestamp —
    // ti/ar/al/au/lr/by/offset/re/ve/tool/length/creator etc.
    final metadataPattern =
        RegExp(r'^\[[a-zA-Z]{2,10}:[^\]]*\]$');
    final lines = <_LyricLine>[];

    for (final raw in content.split('\n')) {
      final line = raw.trimRight();
      if (line.isEmpty) continue;

      final match = tagPattern.firstMatch(line);
      if (match != null) {
        lines.add(
          _LyricLine(
            text: (match.group(4) ?? '').trim(),
            start: Duration(
              minutes: int.parse(match.group(1)!),
              seconds: int.parse(match.group(2)!),
              milliseconds: int.parse(match.group(3)!) * 10,
            ),
          ),
        );
      } else if (metadataPattern.hasMatch(line)) {
        continue;
      } else {
        lines.add(_LyricLine(text: line.trim()));
      }
    }

    return lines;
  }

  Future<void> _load(MediaItem? item) async {
    if (item == null) return;

    setState(() {
      _loading = true;
      _lines = null;
      _loadedForItemId = item.id;
    });
    _activeIndexNotifier.value = -1;
    _didInitialScroll = false;
    _searchingLrcLib = false;
    _lrcLibSearchedAndEmpty = false;

    // A downloaded song carries its own lyrics sidecar (see
    // DownloadManager.downloadSong) — read that straight off disk
    // instead of hitting /Audio/{id}/Lyrics, which only ever works
    // with a reachable server. This also just means one less network
    // round-trip for a song that's already fully local.
    if (await _loadFromDownloadedLyrics(item)) return;

    // ON-DEVICE / OPEN WITH SONGS: these never have a Jellyfin item id
    // (see LocalMusicService / ExternalMediaHandler — `IsLocal: true`
    // with a synthetic local id), so `/Audio/{id}/Lyrics` can never
    // return anything for them — the request was pure wasted time.
    // Worse, with the server unreachable it sat waiting on the
    // connection until Dio's timeout expired, keeping the spinner up
    // for ages before either a cached LRCLIB match or the "Search
    // Lyrics" button could show. Skip the server entirely: check the
    // local LRCLIB cache (a quick disk read) and then settle straight
    // onto the lyrics / "Search Lyrics" state, with no network wait
    // whether the server is online or not.
    if (item.isLocal) {
      if (await _loadFromCachedLyrics(item)) return;

      // The track may have changed while the cache read was resolving.
      if (!mounted || PlayerManager.instance.currentItem?.id != item.id) {
        return;
      }

      setState(() {
        _loading = false;
        _lines = null;
      });
      return;
    }

    final raw = await MediaService.getLyrics(item.id);

    // The track may have changed again while the request was in
    // flight — bail out rather than applying now-stale lyrics.
    if (!mounted || PlayerManager.instance.currentItem?.id != item.id) {
      return;
    }

    if (raw == null || raw.isEmpty) {
      // Jellyfin has nothing, but this exact track may already have an
      // LRCLIB match cached from a previous "Search Lyrics" tap (see
      // _searchLrcLib) — applying that here means the same song playing
      // again never needs the button pressed twice, and never re-hits
      // LRCLIB for something already found.
      if (await _loadFromCachedLyrics(item)) return;

      setState(() {
        _loading = false;
        _lines = null;
      });
      return;
    }

    final lines = raw.map((entry) {
      final map = Map<String, dynamic>.from(entry as Map);
      final startTicks = map["Start"];

      return _LyricLine(
        text: (map["Text"] ?? "").toString(),
        // Jellyfin timestamps are in 100-nanosecond ticks, same unit
        // used for playback position ticks elsewhere in this app.
        start: startTicks != null
            ? Duration(microseconds: (startTicks as num).toInt() ~/ 10)
            : null,
      );
    }).toList();

    _lineKeys
      ..clear()
      ..addEntries(
        List.generate(lines.length, (i) => MapEntry(i, GlobalKey())),
      );

    setState(() {
      _lines = lines;
      _hasTimestamps = lines.any((l) => l.start != null);
      _loading = false;
    });

    // Resolve + jump to wherever playback already is (e.g. lyrics
    // opened mid-song) once the list has actually laid out.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _updateActiveIndex(PlayerManager.instance.position.value);
    });
  }

  /// Triggered by the "Search Lyrics" button, shown once Jellyfin has
  /// come back with no lyrics for the current track. Looks up LRCLIB
  /// and, if it has a usable match, shows it exactly like a
  /// server-provided lyric — synced lines highlight/auto-scroll the
  /// same way; plain-text-only matches just render statically. There's
  /// no picker: [LrcLibService.findBestMatch] already applies the
  /// preference order this needs (synced over plain-text, then closest
  /// duration match among same-title/artist candidates) and the best
  /// result is shown directly.
  Future<void> _searchLrcLib() async {
    final item = PlayerManager.instance.currentItem;
    if (item == null || item.id != _loadedForItemId) return;

    setState(() {
      _searchingLrcLib = true;
      _lrcLibSearchedAndEmpty = false;
    });

    // The actual playback duration is a far stronger "same recording"
    // signal than server metadata, and is usually already known by the
    // time lyrics are opened for a track that's playing.
    final playerDuration = PlayerManager.instance.duration.value;
    final durationSeconds =
        playerDuration > Duration.zero ? playerDuration.inSeconds : null;

    LrcLibResult? match;
    try {
      match = await LrcLibService.findBestMatch(
        trackName: item.title,
        // `artistName`, not `subtitle` — `subtitle` prioritizes
        // AlbumArtist/Album for display and can resolve to an album
        // title on tracks without an AlbumArtist set, which sends
        // LRCLIB a query that can never match anything. See
        // mediaItemFromJellyfin.
        artistName: item.artistName,
        durationSeconds: durationSeconds,
      );
    } catch (_) {
      match = null;
    }

    // FALLBACK: LRCLIB had nothing usable, so ask lrcmux (a multi-provider
    // aggregator) before giving up. Never runs when LRCLIB found a match,
    // and never throws — a failure here just means "still no lyrics".
    if (match == null) {
      try {
        match = await LrcmuxService.findBestMatch(
          trackName: item.title,
          artistName: item.artistName,
          durationSeconds: durationSeconds,
        );
      } catch (_) {
        match = null;
      }
    }

    // The track may have changed again while the request was in
    // flight — bail out rather than applying now-stale lyrics.
    if (!mounted || PlayerManager.instance.currentItem?.id != item.id) {
      return;
    }

    if (match == null) {
      setState(() {
        _searchingLrcLib = false;
        _lrcLibSearchedAndEmpty = true;
      });
      return;
    }

    final lines = match.hasSyncedLyrics
        ? match.syncedLines
            .map((l) => _LyricLine(text: l.text, start: l.start))
            .toList()
        : (match.plainText ?? '')
            .split('\n')
            .where((l) => l.trim().isNotEmpty)
            .map((l) => _LyricLine(text: l.trim()))
            .toList();

    if (lines.isEmpty) {
      setState(() {
        _searchingLrcLib = false;
        _lrcLibSearchedAndEmpty = true;
      });
      return;
    }

    _lineKeys
      ..clear()
      ..addEntries(
        List.generate(lines.length, (i) => MapEntry(i, GlobalKey())),
      );

    setState(() {
      _lines = lines;
      _hasTimestamps = match!.hasSyncedLyrics;
      _searchingLrcLib = false;
    });

    // Cache this match so the next time this track plays, it's applied
    // straight away (see _loadFromCachedLyrics) instead of showing the
    // "Search Lyrics" button and re-querying LRCLIB again.
    unawaited(
      MediaExtrasCacheService.saveLyrics(item.id, _linesToLrc(lines)),
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _updateActiveIndex(PlayerManager.instance.position.value);
    });
  }

  void _updateActiveIndex(Duration position) {
    final lines = _lines;

    if (lines == null || !_hasTimestamps || !mounted) return;

    var index = -1;

    for (var i = 0; i < lines.length; i++) {
      final start = lines[i].start;

      if (start == null) continue;

      if (position >= start) {
        index = i;
      } else {
        break;
      }
    }

    if (index == _activeIndexNotifier.value) return;

    // Updating the notifier (rather than calling setState here) only
    // wakes the individual _LyricLineTile widgets that are listening
    // to it — the rest of the screen never rebuilds just because the
    // song moved forward.
    _activeIndexNotifier.value = index;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToActive(animate: _didInitialScroll);
      _didInitialScroll = true;
    });
  }

  void _scrollToActive({required bool animate}) {
    final context = _lineKeys[_activeIndexNotifier.value]?.currentContext;

    if (context == null || !mounted) return;

    var duration =
        animate ? const Duration(milliseconds: 650) : Duration.zero;

    // Some lyric lines are timestamped only a few hundred ms apart
    // (fast passages). If the previous line's scroll animation is
    // still in flight when this one fires, Scrollable.ensureVisible
    // interrupts it mid-motion and restarts a new animation from
    // wherever the scroll position currently sits — an abrupt velocity
    // change that reads as a stutter, but *only* on lines close enough
    // together for this collision to happen. Lines with generous gaps
    // never hit it, since the previous scroll already finished and came
    // to rest — which is why the stutter looked inconsistent rather
    // than constant, rather than a general auto-scroll problem. Capping
    // this animation to comfortably less than the gap to the *next*
    // line change means it's always finished and at rest well before
    // the next one could possibly interrupt it.
    final lines = _lines;
    final index = _activeIndexNotifier.value;
    if (animate && lines != null && index >= 0 && index + 1 < lines.length) {
      final thisStart = lines[index].start;
      final nextStart = lines[index + 1].start;
      if (thisStart != null && nextStart != null && nextStart > thisStart) {
        final gap = nextStart - thisStart;
        final capped = Duration(
          milliseconds: (gap.inMilliseconds * 0.6).round(),
        );
        if (capped < duration) duration = capped;
      }
    }

    Scrollable.ensureVisible(
      context,
      duration: duration,
      curve: Curves.easeInOutCubic,
      alignment: 0.4,
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<MediaItem?>(
      valueListenable: PlayerManager.instance.currentItemNotifier,
      builder: (context, item, _) {
        if (item == null) {
          return const Scaffold(
            backgroundColor: Colors.black,
            body: SizedBox.shrink(),
          );
        }

        final isLandscape = Responsive.isLandscape(context);

        return Scaffold(
          backgroundColor: Colors.black,
          body: PlayerAccentBackground(
            imageUrl: item.image,
            useGradient: false,
            child: SafeArea(
              child: isLandscape
                  ? _buildLandscapeBody(context, item)
                  : _buildPortraitBody(context, item),
            ),
          ),
        );
      },
    );
  }

  // Original portrait layout — untouched. Back button + title/artist
  // header, the lyrics list filling the rest of the screen, and the
  // compact transport controls pinned to the bottom.
  Widget _buildPortraitBody(BuildContext context, MediaItem item) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(
                  Icons.keyboard_arrow_down,
                  color: Colors.white,
                  size: 30,
                ),
                onPressed: () => Navigator.pop(context),
              ),

              Expanded(
                child: Column(
                  children: [
                    Text(
                      item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      item.subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),

              // Balances the leading back button so the title
              // block above stays visually centered.
              const SizedBox(width: 48),
            ],
          ),
        ),

        Expanded(child: _buildBody()),

        const Padding(
          padding: EdgeInsets.only(bottom: 32),
          child: PlayerControlsBar(compact: true),
        ),
      ],
    );
  }

  // Landscape layout: the lyrics list takes the artwork's place on the
  // left, while the title/artist and transport controls stay on the
  // right — the same right-hand arrangement the audio player screen
  // uses in landscape, so stepping into lyrics reads as the artwork
  // panel swapping out rather than a different screen. No control here
  // that isn't already in the portrait layout above.
  Widget _buildLandscapeBody(BuildContext context, MediaItem item) {
    return Column(
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: IconButton(
            icon: const Icon(
              Icons.keyboard_arrow_down,
              color: Colors.white,
              size: 28,
            ),
            onPressed: () => Navigator.pop(context),
          ),
        ),

        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // Lyrics, left half — replaces where the artwork sits
              // on the audio player screen.
              Expanded(
                flex: 5,
                child: _buildBody(),
              ),

              // Title/artist + transport controls, right half —
              // untouched from the audio player screen's arrangement.
              Expanded(
                flex: 6,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        item.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.left,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        item.subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.left,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 14,
                        ),
                      ),

                      const SizedBox(height: 16),

                      const PlayerControlsBar(compact: true),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // TAP-TO-SEEK: mirrors the cast-aware pattern every other seek
  // control in the app already follows (rewind/forward-10, the seek
  // bar's commit) — a plain `PlayerManager.instance.player.seek()`
  // only moves the local mpv player, which is silently a no-op while
  // a Google Cast / Jellyfin Remote / Nemesis Native session is the
  // one actually playing the track (the phone's own audio is muted
  // during a cast session, so nothing about the miss is audible
  // locally either). Route through `CastManager.instance.seek()`
  // whenever a session is connected and the transport actually
  // supports seeking; otherwise fall back to the local player exactly
  // as before.
  void _seekTo(Duration target) {
    final session = CastManager.instance.activeSession.value;

    if (session != null && session.isConnected) {
      if (session.capability.seek) {
        CastManager.instance.seek(target);
      }
      return;
    }

    PlayerManager.instance.player.seek(target);
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white),
      );
    }

    final lines = _lines;

    if (lines == null || lines.isEmpty) {
      if (_searchingLrcLib) {
        return const Center(
          child: CircularProgressIndicator(color: Colors.white),
        );
      }

      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _lrcLibSearchedAndEmpty
                  ? "No lyrics found"
                  : "No lyrics available for this song",
              style: const TextStyle(color: Colors.white70, fontSize: 16),
            ),
            const SizedBox(height: 20),
            OutlinedButton.icon(
              onPressed: _searchLrcLib,
              icon: const Icon(Icons.search, color: Colors.white),
              label: Text(
                _lrcLibSearchedAndEmpty ? "Search again" : "Search Lyrics",
                style: const TextStyle(color: Colors.white),
              ),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Colors.white38),
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 12,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(24),
                ),
              ),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      controller: _scrollController,
      // A generous cache extent keeps lines well outside the
      // viewport already built, so ensureVisible can still find and
      // scroll to them after a big jump (e.g. the user scrubbing
      // the seek bar far ahead).
      cacheExtent: 2000,
      padding: const EdgeInsets.symmetric(
        vertical: 48,
        horizontal: 28,
      ),
      itemCount: lines.length,
      itemBuilder: (context, index) {
        final line = lines[index];

        return _LyricLineTile(
          key: _lineKeys[index],
          index: index,
          line: line,
          activeIndex: _activeIndexNotifier,
          hasTimestamps: _hasTimestamps,
          onTap: line.start != null ? () => _seekTo(line.start!) : null,
        );
      },
    );
  }
}

/// A single lyric line. Listens to the shared active-index notifier
/// directly, so a line only repaints itself (a cheap text-style tween)
/// when the active line changes — nothing above it in the tree, and no
/// other line, is touched.
class _LyricLineTile extends StatelessWidget {
  final int index;
  final _LyricLine line;
  final ValueNotifier<int> activeIndex;
  final bool hasTimestamps;
  final VoidCallback? onTap;

  const _LyricLineTile({
    required super.key,
    required this.index,
    required this.line,
    required this.activeIndex,
    required this.hasTimestamps,
    this.onTap,
  });

  // Rendering every line at one constant font size/weight — and only
  // ever changing *color* (no layout impact) plus a paint-time
  // AnimatedScale (also no layout impact) — is what keeps the list
  // stable. Animating fontSize/fontWeight directly, like the previous
  // version did, changes that line's actual measured height every
  // frame, which forces the ListView to reflow every sibling line at
  // the same time the scroll animation is independently trying to
  // settle on a target — two layout-shifting animations fighting each
  // other is what read as lines "suddenly shrinking".
  static const double _baseFontSize = 28;
  static const double _inactiveScale = 22 / _baseFontSize;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: activeIndex,
      builder: (context, active, _) {
        final isActive = hasTimestamps && index == active;

        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onTap,
            child: AnimatedScale(
              duration: const Duration(milliseconds: 600),
              curve: Curves.easeInOutCubic,
              scale: isActive ? 1.0 : _inactiveScale,
              alignment: Alignment.centerLeft,
              child: AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 600),
                curve: Curves.easeInOutCubic,
                style: TextStyle(
                  color: isActive ? Colors.white : Colors.white54,
                  fontSize: _baseFontSize,
                  fontWeight: FontWeight.bold,
                  height: 1.4,
                ),
                child: Text(
                  line.text.isEmpty ? "♪" : line.text,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
