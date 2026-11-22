import 'dart:async';

import 'package:flutter/foundation.dart';

import '../torrent/torrent_engine.dart';
import 'models/media_item.dart';
import 'player_manager.dart';

/// How far the loading screen's logo is filled, built only from things the
/// player and the torrent engine really report.
///
/// One "load" runs from the moment Play / Continue Watching is tapped until
/// the first picture is on screen (PlayerManager.loading goes false):
///
///   1. Source not chosen yet (the stream list is open)   -> [linkChosen]
///      is false and the fill stays at 0: the logo is dim and uncoloured.
///   2. Source chosen                                     -> fill starts.
///   3. Torrent only: the engine's own numbers (peers found, file list
///      received, bytes preloaded) move the fill forward.
///   4. The player starts opening the stream.
///   5. The player has opened it (the server / engine answered).
///   6. The player knows the video's real length.
///   7. mpv is filling its start-up buffer: its real buffering percentage
///      moves the fill between 55% and 85%.
///   8. The first video frame has been decoded.
///
/// Every step only ever raises [value]; nothing creeps on a timer, so a long
/// wait (a torrent looking for peers) shows as a fill that waits, while the
/// logo keeps pulsing to show the app is alive.
class PlaybackLoadProgress {
  PlaybackLoadProgress._();
  static final PlaybackLoadProgress instance = PlaybackLoadProgress._();

  // Where each real milestone puts the fill (0..1).
  static const double _kChosen = 0.08; // a source was picked
  static const double _kEngine = 0.10; // torrent engine knows the torrent
  static const double _kPeers = 0.14; // connected to at least one peer
  static const double _kMetadata = 0.22; // torrent file list received
  static const double _kOpening = 0.30; // player is opening the stream
  static const double _kOpened = 0.45; // stream answered / container opened
  static const double _kDuration = 0.55; // real video length known
  static const double _kBufferingEnd = 0.85; // start-up buffer is full
  static const double _kFrame = 0.92; // first picture decoded
  static const double _kCeiling = 0.97; // never "done" before it really is

  /// False while the person still has to pick a source: the logo is then
  /// shown dim and uncoloured. True from the moment a source is chosen (and
  /// from the start for anything that has no choice to make).
  final ValueNotifier<bool> linkChosen = ValueNotifier<bool>(false);

  /// 0..1 fill of the logo. Only goes up during one load.
  final ValueNotifier<double> value = ValueNotifier<double>(0);

  bool _attached = false;
  bool _active = false;
  bool _opening = false;
  bool _opened = false;
  bool _sawBuffering = false;
  bool _polling = false;
  int _gen = 0;
  int _tick = 0;
  String? _torrentHash;
  Timer? _timer;

  /// True when [item] is a title from the virtual catalogue that has no
  /// stream yet, i.e. the person is about to be asked to choose a source.
  static bool needsLink(MediaItem item) {
    final raw = item.raw;
    return raw?['NamesisVirtual'] == true && raw?['AddonStream'] != true;
  }

  /// Starts a new load, resetting the fill to 0.
  void begin({required bool awaitingLink}) {
    _attach();
    _gen++;
    _active = true;
    _opening = false;
    _opened = false;
    _sawBuffering = false;
    _tick = 0;
    _torrentHash = null;
    value.value = 0;
    linkChosen.value = !awaitingLink;
    if (!awaitingLink) _raise(_kChosen);
    _startTimer();
  }

  /// A source was chosen from the stream list (or picked automatically).
  /// [torrentHash] is the stream's info hash when it is a torrent, so the
  /// engine's real numbers can be read while it prepares the file.
  void linkSelected({String? torrentHash}) {
    if (!_active) return;
    final hash = torrentHash?.trim().toLowerCase();
    _torrentHash = (hash == null || hash.isEmpty) ? null : hash;
    linkChosen.value = true;
    _raise(_kChosen);
  }

  /// PlayerManager is about to open the stream. Also starts a load by
  /// itself when nothing announced one first (next episode, quality change).
  void opening() {
    if (!_active) begin(awaitingLink: false);
    _opening = true;
    _opened = false;
    _sawBuffering = false;
    linkChosen.value = true;
    _raise(_kOpening);
  }

  /// `player.open()` returned: the stream answered and was opened.
  void opened() {
    if (!_active) return;
    _opening = true;
    _opened = true;
    _raise(_kOpened);
  }

  /// mpv reported a real, positive duration for the opened stream.
  void durationKnown() {
    if (!_active || !_opening) return;
    _raise(_kDuration);
  }

  /// mpv reported a real video size, i.e. the first picture is decoded.
  void firstFrame() {
    if (!_active || !_opening) return;
    _raise(_kFrame);
  }

  // ---------- internals ----------

  void _attach() {
    if (_attached) return;
    _attached = true;
    PlayerManager.instance.loading.addListener(_onLoadingChanged);
  }

  void _onLoadingChanged() {
    if (!PlayerManager.instance.loading.value) _finish();
  }

  void _finish() {
    _active = false;
    _opening = false;
    _opened = false;
    _gen++;
    _timer?.cancel();
    _timer = null;
  }

  void _raise(double v) {
    final c = v < 0.0 ? 0.0 : (v > _kCeiling ? _kCeiling : v);
    if (c > value.value) value.value = c;
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(milliseconds: 250), (_) => _onTick());
  }

  void _onTick() {
    final manager = PlayerManager.instance;
    if (!_active || !manager.loading.value) {
      _finish();
      return;
    }
    _tick++;

    // mpv's own start-up buffering, once the stream is open.
    if (_opened) {
      final s = manager.player.state;
      if (s.buffering) {
        _sawBuffering = true;
        final pct = s.bufferingPercentage.clamp(0.0, 100.0).toDouble();
        _raise(_kDuration + (_kBufferingEnd - _kDuration) * (pct / 100.0));
      } else if (_sawBuffering) {
        _raise(_kBufferingEnd);
      }
    }

    // The torrent engine's own numbers, about once a second.
    if (_torrentHash != null && _tick % 4 == 0) {
      unawaited(_pollTorrent());
    }
  }

  Future<void> _pollTorrent() async {
    final hash = _torrentHash;
    if (hash == null || _polling) return;
    _polling = true;
    final gen = _gen;
    try {
      final stats = await TorrentEngine.instance.loadStats(hash);
      if (stats == null || gen != _gen || !_active) return;

      _raise(_kEngine);
      if (stats.activePeers > 0) _raise(_kPeers);
      if (stats.fileCount > 0) _raise(_kMetadata);
      if (stats.preloadSize > 0) {
        final f = (stats.preloadedBytes / stats.preloadSize)
            .clamp(0.0, 1.0)
            .toDouble();
        _raise(_kMetadata + (_kOpened - _kMetadata) * f);
      }
    } catch (_) {
      // Only a progress hint: never let it affect playback.
    } finally {
      _polling = false;
    }
  }
}
