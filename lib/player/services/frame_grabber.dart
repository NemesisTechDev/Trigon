import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../models/media_item.dart';
import '../player_manager.dart';

/// Seek-bar preview pictures for titles played through addons, which (unlike
/// Jellyfin) come with no ready-made thumbnail sheets.
///
/// A second, silent player opens the same link and, while the person drags
/// the seek bar, jumps to the spot and grabs one small frame. Frames are kept
/// per 10-second slot, so dragging over the same part again is instant. It is
/// "on demand": nothing is fetched until the bar is dragged, and the second
/// player is dropped after a short idle time.
///
/// SPEED-UP: a grab that has already started is finished (and cached) even
/// if the bar has moved on, the slots just ahead of the drag are fetched
/// speculatively, the background sweep is denser (120 s apart, then 60 s),
/// the frame is polled for every 40 ms, and software decoding skips the
/// loop filter / uses mpv's fast flag.
///
/// It lands on the nearest keyframe (fast, and reads only a little of the
/// file), so a preview can be up to a few seconds off the exact spot. For
/// torrents the second reader asks the engine for pieces away from where
/// playback is, which can slow the main stream briefly while dragging.
class FrameGrabber {
  FrameGrabber._();
  static final FrameGrabber instance = FrameGrabber._();

  static const int _slotMs = 10000;
  static const int _maxFrames = 480;
  static const Duration _idleAfter = Duration(minutes: 20);

  /// Background pictures are taken in passes: this many slots apart first
  /// (120 s), so the bar already has something close to show anywhere on
  /// first touch, then each following step (60 s) fills the gaps. The last
  /// step is the density cap; lower it (e.g. add 3 for 30 s) for finer
  /// previews at the cost of more background data on direct links.
  static const List<int> _sweepSteps = [12, 6];

  /// How far (in slots) [frameFor] looks for a stand-in picture.
  static const int _nearRange = 14;

  /// Slots fetched speculatively just ahead of the drag direction.
  static const int _aheadDirect = 2;
  static const int _aheadTorrent = 1;

  /// A grab already in flight is only abandoned for a newer request after
  /// this long (it is usually about to finish, and its frame is kept).
  static const Duration _abandonAfter = Duration(milliseconds: 2500);

  /// How often a grab checks whether the picture is ready.
  static const Duration _pollEvery = Duration(milliseconds: 40);

  /// If the position has not moved from where it was before the seek, the
  /// seek has probably not landed yet; wait this long before accepting it
  /// (the keyframe really can be the same one).
  static const Duration _landWait = Duration(milliseconds: 700);

  /// Bumped whenever a new frame arrives, so a preview can repaint.
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  final LinkedHashMap<int, Uint8List> _frames = LinkedHashMap();

  Player? _player;
  VideoController? _controller;
  String? _itemId;
  Future<void>? _opening;
  bool _busy = false;
  int? _wanted;
  Timer? _idle;
  final List<int> _sweep = [];
  final List<int> _ahead = [];
  int? _lastSlot;
  int _dir = 1;

  static bool supports(MediaItem? item) =>
      item != null &&
      !item.live &&
      !item.audioOnly &&
      item.raw?['AddonStream'] == true &&
      item.runtime > Duration.zero;

  /// The best picture we have for [position]: this slot's, else a close one.
  Uint8List? frameFor(Duration position) {
    final slot = position.inMilliseconds ~/ _slotMs;
    final exact = _frames[slot];
    if (exact != null) return exact;
    for (var d = 1; d <= _nearRange; d++) {
      final a = _frames[slot - d] ?? _frames[slot + d];
      if (a != null) return a;
    }
    return null;
  }

  bool hasExact(Duration position) =>
      _frames.containsKey(position.inMilliseconds ~/ _slotMs);

  /// Asks for the picture at [position]. Only the latest request matters
  /// while the bar is being dragged.
  void request(MediaItem item, Duration position) {
    if (!supports(item)) return;
    if (_itemId != null && _itemId != item.id) _dropAll();
    final slot = position.inMilliseconds ~/ _slotMs;

    // Which way the bar is moving, to fetch the slots it is heading for.
    final last = _lastSlot;
    if (last != null && slot != last) _dir = slot > last ? 1 : -1;
    _lastSlot = slot;

    _ahead.clear();
    final lastSlot = item.runtime.inMilliseconds ~/ _slotMs;
    final count =
        item.raw?['IsTorrent'] == true ? _aheadTorrent : _aheadDirect;
    for (var i = 1; i <= count; i++) {
      final s = slot + _dir * i;
      if (s >= 0 && s <= lastSlot && !_frames.containsKey(s)) _ahead.add(s);
    }

    final cached = _frames.containsKey(slot);
    if (!cached) _wanted = slot;
    if (cached && _ahead.isEmpty) return;
    _idle?.cancel();
    if (!_busy) unawaited(_work(item));
  }

  /// Opens the reader early (so the first drag does not wait for it) and,
  /// for direct links, quietly collects a coarse set of pictures. Torrents
  /// only get the early open: scanning them would compete with playback.
  void prewarm(MediaItem item, Duration total) {
    if (!supports(item)) return;
    if (_itemId != null && _itemId != item.id) _dropAll();
    _sweep.clear();
    if (item.raw?['IsTorrent'] != true && total > Duration.zero) {
      final slots = total.inMilliseconds ~/ _slotMs;
      final seen = <int>{};
      for (final step in _sweepSteps) {
        for (var s = step ~/ 2; s < slots; s += step) {
          if (seen.add(s)) _sweep.add(s);
        }
      }
    }
    _idle?.cancel();
    if (!_busy) unawaited(_work(item, openOnly: true));
  }

  Future<void> _work(MediaItem item, {bool openOnly = false}) async {
    _busy = true;
    try {
      if (openOnly) {
        try {
          await _ensure(item);
        } catch (e) {
          debugPrint('[FrameGrabber] warm-up failed: $e');
          await _closePlayer();
          return;
        }
      }
      while (_wanted != null || _ahead.isNotEmpty || _sweep.isNotEmpty) {
        final int slot;
        var background = true;
        var fromAhead = false;
        if (_wanted != null) {
          slot = _wanted!;
          _wanted = null;
          background = false;
        } else if (_ahead.isNotEmpty) {
          slot = _ahead.removeAt(0);
          fromAhead = true;
        } else {
          slot = _sweep.removeAt(0);
        }
        if (_frames.containsKey(slot)) continue;
        if (background) {
          // Speculative work starts almost at once; the slow sweep stays
          // out of the way of playback.
          await Future<void>.delayed(
            Duration(milliseconds: fromAhead ? 100 : 600),
          );
          if (_wanted != null) {
            // The person asked for something: that comes first. Ahead
            // slots are recomputed by request(); sweep slots wait.
            if (!fromAhead) _sweep.insert(0, slot);
            continue;
          }
          if (_frames.containsKey(slot)) continue;
        }
        try {
          await _ensure(item);
          await _grab(slot, background: background);
        } catch (e) {
          debugPrint('[FrameGrabber] grab failed: $e');
          // Start clean next time (a stuck second player is not worth
          // keeping).
          await _closePlayer();
          break;
        }
      }
    } finally {
      _busy = false;
      _idle?.cancel();
      _idle = Timer(_idleAfter, _closePlayer);
    }
  }

  Future<void> _ensure(MediaItem item) async {
    if (_player != null && _itemId == item.id) {
      await _opening;
      return;
    }
    await _closePlayer();
    _frames.clear();
    _itemId = item.id;

    final player = Player(
      configuration: const PlayerConfiguration(
        bufferSize: 8 * 1024 * 1024,
        logLevel: MPVLogLevel.error,
      ),
    );
    _player = player;
    _controller = VideoController(
      player,
      configuration: const VideoControllerConfiguration(
        width: 320,
        height: 180,
        enableHardwareAcceleration: false,
      ),
    );

    final native = player.platform;
    if (native is NativePlayer) {
      for (final p in {
        // Same reason as PlayerManager._applyNetworkTimeout: mpv's default
        // of 5 s is too short for a direct link.
        'network-timeout': item.raw?['IsTorrent'] == true ? '240' : '60',
        'ao': 'null',
        'aid': 'no',
        'sid': 'no',
        'volume': '0',
        // Land on the nearest keyframe: fast, and little data is read.
        'hr-seek': 'no',
        'hwdec': 'no',
        // Cheaper software decoding of the one keyframe we need.
        'vd-lavc-fast': 'yes',
        'vd-lavc-skiploopfilter': 'all',
        'screenshot-jpeg-quality': '70',
        'vf': 'scale=320:-2',
        'cache': 'yes',
        'demuxer-max-bytes': '8MiB',
        'demuxer-max-back-bytes': '1MiB',
        'demuxer-readahead-secs': '2',
      }.entries) {
        try {
          await native.setProperty(p.key, p.value);
        } catch (_) {}
      }
    }

    final open = player.open(
      Media(
        item.streamUrl,
        // The same headers (including the browser User-Agent) the main
        // player sends, so the provider sees one consistent client.
        httpHeaders: PlayerManager.instance.addonHeaders(item),
      ),
      play: false,
    );
    _opening = open;
    await open;
    // A torrent may need a while to find peers; give it room.
    final long = item.raw?['IsTorrent'] == true;
    await player.stream.duration
        .firstWhere((d) => d > Duration.zero)
        .timeout(Duration(seconds: long ? 90 : 25));
  }

  Future<void> _grab(int slot, {required bool background}) async {
    final player = _player;
    if (player == null) return;

    final target = Duration(milliseconds: slot * _slotMs + _slotMs ~/ 2);
    final before = player.state.position;
    final started = DateTime.now();
    await player.seek(target);

    // The picture is ready a moment after the seek lands; poll for it.
    final deadline = started.add(const Duration(seconds: 12));
    while (DateTime.now().isBefore(deadline)) {
      if (_player != player) return; // dropped meanwhile
      if (_wanted != null && _wanted != slot) {
        // The bar moved on. Speculative work gives way at once; a grab the
        // person asked for is kept (and cached) unless it is dragging on.
        if (background ||
            DateTime.now().difference(started) > _abandonAfter) {
          return;
        }
      }
      await Future<void>.delayed(_pollEvery);
      final pos = player.state.position;
      if ((pos - target).abs() > const Duration(seconds: 15)) continue;
      // Position still where it was before the seek: the seek has most
      // likely not landed, so a picture now would be the previous one.
      if ((pos - before).abs() < const Duration(milliseconds: 30) &&
          DateTime.now().difference(started) < _landWait) {
        continue;
      }
      // The first picture only exists once the video size is known.
      if ((player.state.width ?? 0) <= 0) continue;
      final bytes = await player.screenshot(format: 'image/jpeg');
      if (_player != player) return;
      if (bytes != null && bytes.isNotEmpty) {
        _frames.remove(slot);
        _frames[slot] = bytes;
        while (_frames.length > _maxFrames) {
          _frames.remove(_frames.keys.first);
        }
        revision.value++;
        return;
      }
    }
  }

  Future<void> _closePlayer() async {
    _idle?.cancel();
    final p = _player;
    _player = null;
    _controller = null;
    _opening = null;
    if (p != null) {
      try {
        await p.dispose();
      } catch (_) {}
    }
  }

  void _dropAll() {
    _frames.clear();
    _sweep.clear();
    _ahead.clear();
    _lastSlot = null;
    _itemId = null;
    _wanted = null;
    unawaited(_closePlayer());
  }

  /// Frees the second player and the pictures (playback ended / changed).
  void release() {
    _dropAll();
    revision.value++;
  }
}
