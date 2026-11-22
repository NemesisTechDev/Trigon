import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:youtube_player_iframe/youtube_player_iframe.dart';

import '../../../services/external_metadata/trailer_service.dart';
import '../../../widgets/shared/nemesis_bottom_sheet.dart';
import 'trailer_row.dart';

const _gold = Color(0xffD4AF37);

/// Movies/TV Shows detail screens' "Trailers" popup.
///
/// Deliberately isolated from media_kit/PlayerManager/CastManager —
/// see TrailerService's doc comment for why. This is its own small,
/// self-contained mini player: it owns its own YoutubePlayerController
/// and never touches the app's real playback state.
///
/// One sheet, same horizontal-card layout, used identically in
/// portrait and landscape. It has two internal states:
///  - Browsing: the trailer row (TrailerRow/TrailerCard, matching
///    EpisodeRow's styling).
///  - Playing: the sheet morphs (AnimatedSize) into a compact YouTube
///    player with native YouTube chrome hidden (`showControls: false`)
///    and a slim gold custom bar underneath instead — play/pause,
///    ±10s, fullscreen, dismiss — so it reads as this app's player,
///    not YouTube's. Fullscreen is handled by YoutubePlayerScaffold
///    itself (the package expands the player in place, no separate
///    route, so playback never restarts).
///
/// Windows has no WebView target for youtube_player_iframe, so there
/// tapping a trailer card opens the YouTube URL in the system browser
/// instead of trying to embed a player — see [_onSelect].
///
/// Call via [TrailerSheet.show].
class TrailerSheet extends StatefulWidget {
  final Map<String, dynamic> item;
  final ScrollController? scrollController;

  const TrailerSheet({super.key, required this.item, this.scrollController});

  // Same chrome as the video player's Info sheet — rounded top
  // corners, drag handle, drag up/down to resize, tap-outside/back-
  // gesture/drag-down to close (see showNemesisBottomSheet's doc
  // comment). initialChildSize is generous since a playing trailer
  // (16:9 player + controls bar) needs real height to not feel cramped.
  static Future<void> show(BuildContext context, Map<String, dynamic> item) {
    return showNemesisBottomSheet<void>(
      context,
      initialChildSize: 0.6,
      minChildSize: 0.3,
      maxChildSize: 0.95,
      // A playing video, not a list of options — fixed opening size
      // (capped to 2/3 of the screen in landscape).
      fitContent: false,
      builder: (_, scrollController) => TrailerSheet(
        item: item,
        scrollController: scrollController,
      ),
    );
  }

  @override
  State<TrailerSheet> createState() => _TrailerSheetState();
}

class _TrailerSheetState extends State<TrailerSheet> {
  bool _loading = true;
  List<TrailerInfo> _trailers = const [];

  TrailerInfo? _playing;
  YoutubePlayerController? _controller;

  // Fullscreen back button. The package's own fullscreen (in-place swap on
  // older versions, an OverlayPortal on newer ones) has no way to leave
  // except the hardware back key / a vertical swipe, so while fullscreen is
  // on we float a small back button in the root Overlay — above the sheet
  // AND above the package's own fullscreen layer, whichever it uses.
  StreamSubscription<YoutubePlayerValue>? _valueSub;
  OverlayEntry? _fsBackEntry;
  bool _fullscreen = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _onPlayerValue(YoutubePlayerValue value) {
    final fs = value.fullScreenOption.enabled;
    if (fs == _fullscreen) return;
    _fullscreen = fs;
    if (fs) {
      _showFullscreenBack();
    } else {
      _hideFullscreenBack();
    }
  }

  void _showFullscreenBack() {
    if (!mounted || _fsBackEntry != null) return;
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    final entry = OverlayEntry(
      builder: (_) => _FullscreenBackButton(onBack: _exitFullscreen),
    );
    _fsBackEntry = entry;
    overlay.insert(entry);
  }

  void _hideFullscreenBack() {
    final entry = _fsBackEntry;
    if (entry == null) return;
    _fsBackEntry = null;
    entry.remove();
    entry.dispose();
  }

  void _exitFullscreen() {
    final c = _controller;
    if (c != null && c.value.fullScreenOption.enabled) c.exitFullScreen();
    // Don't wait for the value stream to hide the button.
    _fullscreen = false;
    _hideFullscreenBack();
  }

  Future<void> _load() async {
    final trailers = await TrailerService.resolve(widget.item);
    if (!mounted) return;
    setState(() {
      _trailers = trailers;
      _loading = false;
    });
  }

  Future<void> _onSelect(TrailerInfo trailer) async {
    // No WebView target on Windows — fall back to the system browser
    // rather than trying (and failing) to embed a player.
    if (Platform.isWindows) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Opening trailer in your browser…"),
            duration: Duration(seconds: 2),
          ),
        );
      }
      try {
        await launchUrl(
          Uri.parse(trailer.youtubeUrl),
          mode: LaunchMode.externalApplication,
        );
      } catch (_) {
        // Nothing more useful to do here — the sheet just stays in
        // its browsing state if the launch itself fails.
      }
      return;
    }

    final controller = YoutubePlayerController.fromVideoId(
      videoId: trailer.youtubeKey,
      autoPlay: true,
      params: const YoutubePlayerParams(
        // Native YouTube chrome is hidden on purpose — the gold
        // _PlayerControlsBar below is this app's own control surface
        // instead, so the popup reads as Nemesis, not a YouTube embed.
        showControls: false,
        showFullscreenButton: false,
        strictRelatedVideos: true,
      ),
    );

    _valueSub?.cancel();
    _valueSub = controller.stream.listen(_onPlayerValue);

    setState(() {
      _playing = trailer;
      _controller = controller;
    });
  }

  void _dismissPlayer() {
    if (_fullscreen) _exitFullscreen();
    _valueSub?.cancel();
    _valueSub = null;
    _controller?.close();
    setState(() {
      _controller = null;
      _playing = null;
    });
  }

  @override
  void dispose() {
    _valueSub?.cancel();
    _hideFullscreenBack();
    _controller?.close();
    super.dispose();
  }

  Widget _buildBrowsing() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 4, 20, 12),
          child: Text(
            "Trailers",
            style: TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        TrailerRow(
          trailers: _trailers,
          loading: _loading,
          onSelect: _onSelect,
        ),
        const SizedBox(height: 12),
      ],
    );
  }

  Widget _buildPlayer(YoutubePlayerController controller) {
    return YoutubePlayerScaffold(
      controller: controller,
      aspectRatio: 16 / 9,
      // Off on purpose: with this left at its default (true), simply
      // rotating the phone while a trailer is open was enough to
      // trigger the package's own fullscreen takeover — which moves
      // the player to a full-screen overlay outside this sheet, while
      // our custom _PlayerControlsBar below stays behind in the
      // sheet's normal (now off-screen/clipped) layout. That's what
      // made landscape look like playback stopped and controls
      // disappeared. Fullscreen should only ever be a deliberate
      // choice via the button in _PlayerControlsBar, never automatic.
      autoFullScreen: false,
      builder: (context, player) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 12, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _playing?.title ?? "Trailer",
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: _dismissPlayer,
                    icon: const Icon(Icons.close, color: Colors.white70),
                  ),
                ],
              ),
            ),
            player,
            _PlayerControlsBar(controller: controller),
            const SizedBox(height: 8),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;

    // The outer showNemesisBottomSheet call already supplies the
    // rounded-top-corner container, background, and SafeArea — this
    // just needs to render into it via the shared scrollController so
    // drag up/down and drag-to-dismiss behave the same as every other
    // sheet in the app.
    return SingleChildScrollView(
      controller: widget.scrollController,
      child: AnimatedSize(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
        alignment: Alignment.topCenter,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const NemesisSheetDragHandle(topMargin: 12, bottomMargin: 6),
            controller == null
                ? _buildBrowsing()
                : _buildPlayer(controller),
          ],
        ),
      ),
    );
  }
}

/// Custom gold control bar shown under the player instead of
/// YouTube's own chrome (which is hidden via `showControls: false`
/// above) — a drag-to-seek bar with elapsed/total labels, play/pause,
/// ±10s, fullscreen. Dismiss lives in the header row above the player
/// instead of here.
///
/// Position comes from [YoutubePlayerController.videoStateStream];
/// total duration comes from `value.metaData.duration` inside the
/// same [YoutubeValueBuilder] already needed for the play/pause icon
/// — both are documented, stable fields on this package's current
/// API, unlike the async `currentTime()`/`duration()` methods this
/// bar deliberately avoids (see phase 2's handoff notes).
class _PlayerControlsBar extends StatefulWidget {
  final YoutubePlayerController controller;

  const _PlayerControlsBar({required this.controller});

  @override
  State<_PlayerControlsBar> createState() => _PlayerControlsBarState();
}

class _PlayerControlsBarState extends State<_PlayerControlsBar> {
  Duration _position = Duration.zero;

  // Non-null only while the user has a finger on the seek bar — the
  // slider shows this instead of the live [_position] so it doesn't
  // fight the drag, and [_position] itself is only reconciled once
  // the drag ends (see onChangeEnd below).
  double? _dragFraction;

  StreamSubscription<YoutubeVideoState>? _sub;

  // Whether the video was playing when the current seek (drag or ±10s)
  // began — so it can be resumed once the seek lands.
  bool _resumeAfterSeek = false;
  Timer? _resumeCheck;

  // SEEK-STICK FIX: the position a seek (drag release or ±10s) just asked
  // for, held on screen until the player's own position feed confirms it
  // has actually moved there.
  //
  // The bug this fixes: releasing the thumb used to set [_position] to the
  // target and immediately resume trusting [YoutubeVideoState] ticks — but
  // the tick already in flight (or the next one, before the iframe has
  // processed the seek) still carried the PRE-seek position, so the thumb
  // snapped back to where it came from, then jumped forward again once a
  // post-seek tick finally arrived.
  Duration? _pendingSeek;
  DateTime? _pendingSeekAt;

  /// A tick this close to (or just past — playback continues after the
  /// seek lands) the pending target means the player has caught up.
  static const Duration _seekLandTolerance = Duration(milliseconds: 1500);

  /// Upper bound on how long stale ticks are ignored, so a seek the player
  /// never honoured can't pin the thumb forever.
  static const Duration _seekHoldMax = Duration(seconds: 4);

  @override
  void initState() {
    super.initState();
    _sub = widget.controller.videoStateStream.listen((state) {
      if (!mounted) return;
      // Ignore the live feed while the thumb is held — the slider shows the
      // drag position, and a stale tick must not yank it back.
      if (_dragFraction != null) return;
      // ...and likewise right after a release, until a tick confirms the
      // seek (see [_pendingSeek]).
      if (!_acceptLivePosition(state.position)) return;
      setState(() => _position = state.position);
    });
    // This bar is rebuilt from scratch after fullscreen (the package swaps
    // the whole builder out), so pick the position up from the player
    // instead of showing 0:00 until the next tick.
    widget.controller.currentTime.then((seconds) {
      if (!mounted || _dragFraction != null || _pendingSeek != null) return;
      if (_position != Duration.zero) return;
      setState(
        () => _position = Duration(milliseconds: (seconds * 1000).round()),
      );
    }).catchError((_) {});
  }

  @override
  void dispose() {
    _resumeCheck?.cancel();
    _sub?.cancel();
    super.dispose();
  }

  /// The player is "going" — playing, or buffering on its way to playing.
  /// Buffering counts so the button reads Pause (not Play) while a seek
  /// loads, and a tap then does what the icon says.
  static bool _isActive(PlayerState s) =>
      s == PlayerState.playing || s == PlayerState.buffering;

  /// Seeks and, if the video was playing, makes sure it keeps playing.
  ///
  /// `allowSeekAhead: true` is the important part: with the package's
  /// default (false) the IFrame player only seeks inside data it has
  /// already buffered, so releasing the thumb anywhere further ahead left
  /// the video stalled until pause + play. The IFrame docs say to pass
  /// false while dragging and true on release — this is the release.
  void _seekTo(Duration target, {required bool resume}) {
    final c = widget.controller;
    c.seekTo(seconds: target.inMilliseconds / 1000, allowSeekAhead: true);
    if (!resume) return;
    c.playVideo();
    // One safety re-check: if the player still reports paused/cued/unstarted
    // shortly after the seek, kick it again.
    _resumeCheck?.cancel();
    _resumeCheck = Timer(const Duration(milliseconds: 900), () {
      if (!mounted) return;
      final s = widget.controller.value.playerState;
      if (!_isActive(s) && s != PlayerState.ended) {
        widget.controller.playVideo();
      }
    });
  }

  /// Records [target] as the position the thumb must keep showing until the
  /// player reports having reached it.
  void _holdSeekTarget(Duration target) {
    _pendingSeek = target;
    _pendingSeekAt = DateTime.now();
  }

  /// Whether a live [live] position tick may replace what's on screen. While
  /// a seek is pending, only a tick that has caught up with it (or the hold
  /// window running out) lifts the hold.
  bool _acceptLivePosition(Duration live) {
    final pending = _pendingSeek;
    final at = _pendingSeekAt;
    if (pending == null || at == null) return true;

    final age = DateTime.now().difference(at);
    final landed = live >= pending - _seekLandTolerance &&
        live <= pending + age + _seekLandTolerance;
    if (landed || age > _seekHoldMax) {
      _pendingSeek = null;
      _pendingSeekAt = null;
      return true;
    }
    return false;
  }

  void _seekBy(int deltaSeconds, Duration duration) {
    final wasActive = _isActive(widget.controller.value.playerState);
    var target = _position + Duration(seconds: deltaSeconds);
    if (target < Duration.zero) target = Duration.zero;
    if (duration > Duration.zero && target > duration) target = duration;
    _holdSeekTarget(target);
    setState(() => _position = target);
    _seekTo(target, resume: wasActive);
  }

  void _onDragStart() {
    _resumeAfterSeek = _isActive(widget.controller.value.playerState);
  }

  void _seekToFraction(double fraction, Duration duration) {
    final target = duration * fraction;
    _holdSeekTarget(target);
    setState(() {
      _position = target;
      _dragFraction = null;
    });
    _seekTo(target, resume: _resumeAfterSeek);
    _resumeAfterSeek = false;
  }

  static String _format(Duration d) {
    final hours = d.inHours;
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    return YoutubeValueBuilder(
      controller: widget.controller,
      builder: (context, value) {
        final duration = value.metaData.duration;
        final hasDuration = duration.inMilliseconds > 0;
        final fraction = hasDuration
            ? (_dragFraction ??
                    (_position.inMilliseconds / duration.inMilliseconds))
                .clamp(0.0, 1.0)
            : 0.0;
        final playing = _isActive(value.playerState);

        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Text(
                    _format(_position),
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 11,
                    ),
                  ),
                  Expanded(
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 3,
                        activeTrackColor: _gold,
                        inactiveTrackColor: Colors.white24,
                        thumbColor: _gold,
                        overlayColor: _gold.withValues(alpha: 0.2),
                        thumbShape: const RoundSliderThumbShape(
                          enabledThumbRadius: 6,
                        ),
                        overlayShape: const RoundSliderOverlayShape(
                          overlayRadius: 12,
                        ),
                      ),
                      child: Slider(
                        value: fraction,
                        onChangeStart: hasDuration ? (_) => _onDragStart() : null,
                        onChanged: hasDuration
                            ? (v) => setState(() => _dragFraction = v)
                            : null,
                        onChangeEnd: hasDuration
                            ? (v) => _seekToFraction(v, duration)
                            : null,
                      ),
                    ),
                  ),
                  Text(
                    _format(duration),
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  onPressed: () => _seekBy(-10, duration),
                  icon: const Icon(
                    Icons.replay_10,
                    color: Colors.white,
                    size: 26,
                  ),
                ),
                const SizedBox(width: 12),
                IconButton(
                  onPressed: value.playerState != PlayerState.unknown
                      ? () {
                          // A manual tap overrides any pending post-seek
                          // auto-resume, or it would undo a Pause.
                          _resumeCheck?.cancel();
                          if (playing) {
                            widget.controller.pauseVideo();
                          } else {
                            widget.controller.playVideo();
                          }
                        }
                      : null,
                  icon: Icon(
                    playing
                        ? Icons.pause_circle_filled
                        : Icons.play_circle_fill,
                    color: _gold,
                    size: 44,
                  ),
                ),
                const SizedBox(width: 12),
                IconButton(
                  onPressed: () => _seekBy(10, duration),
                  icon: const Icon(
                    Icons.forward_10,
                    color: Colors.white,
                    size: 26,
                  ),
                ),
                const SizedBox(width: 20),
                IconButton(
                  onPressed: () => widget.controller.toggleFullScreen(),
                  icon: const Icon(
                    Icons.fullscreen,
                    color: Colors.white,
                    size: 26,
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

/// Floating back button shown over the trailer while it is fullscreen.
/// Lives in an [OverlayEntry] (see _TrailerSheetState._showFullscreenBack),
/// so it must be a [Positioned] that only claims its own small area — the
/// rest of the screen stays touchable by the player underneath.
class _FullscreenBackButton extends StatelessWidget {
  final VoidCallback onBack;

  const _FullscreenBackButton({required this.onBack});

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: 0,
      left: 0,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Material(
            color: Colors.black54,
            shape: const CircleBorder(),
            clipBehavior: Clip.antiAlias,
            child: IconButton(
              tooltip: 'Back',
              onPressed: onBack,
              icon: const Icon(Icons.arrow_back, color: Colors.white),
            ),
          ),
        ),
      ),
    );
  }
}
