import 'package:flutter/foundation.dart';

import '../models/media_item.dart';
import 'dart:math';

enum PlaybackSource {
  movie,
  series,
  season,
  collection,
  album,
  artist,
  playlist,
  liveTv,
  continueWatching,
  unknown,
}

enum QueueRepeatMode {
  off,
  all,
  one,
}

class PlaybackQueue {
  PlaybackQueue._();


  static final PlaybackQueue instance = PlaybackQueue._();

  final List<MediaItem> _items = [];

  // Snapshot of the queue's order the moment it was set, before any
  // shuffling — lets shuffle() be toggled back off and restore the
  // original play order instead of only ever being a one-way shuffle.
  List<MediaItem> _originalOrder = [];

  final ValueNotifier<List<MediaItem>> queueNotifier =
  ValueNotifier([]);

  final ValueNotifier<int> currentIndexNotifier =
  ValueNotifier(-1);

  final ValueNotifier<QueueRepeatMode> repeatModeNotifier =
  ValueNotifier(QueueRepeatMode.off);

  final ValueNotifier<bool> shuffleNotifier =
  ValueNotifier(false);

  int _currentIndex = -1;

  PlaybackSource source =
      PlaybackSource.unknown;

  QueueRepeatMode repeatMode =
      QueueRepeatMode.off;

  String? title;
  String? artwork;

  List<MediaItem> get items =>
      List.unmodifiable(_items);

  int get currentIndex => _currentIndex;

  MediaItem? get current {
    if (_currentIndex < 0 ||
        _currentIndex >= _items.length) {
      return null;
    }

    return _items[_currentIndex];
  }

  bool get hasNext =>
      _currentIndex < _items.length - 1;

  bool get hasPrevious =>
      _currentIndex > 0;

  void setQueue(
      List<MediaItem> items, {
        int startIndex = 0,
        PlaybackSource source =
            PlaybackSource.unknown,
        String? title,
        String? artwork,
      }) {
    _items
      ..clear()
      ..addAll(items);

    _originalOrder = List.from(items);

    _currentIndex = startIndex.clamp(
      0,
      items.isEmpty ? 0 : items.length - 1,
    );

    currentIndexNotifier.value = _currentIndex;

    shuffleNotifier.value = false;

    // A fresh queue always starts fully unshuffled and unrepeated —
    // without this, repeat all/one turned on during an audio session
    // would silently carry over into the next thing played (e.g. a
    // video/series queue, which has no repeat UI of its own to turn it
    // back off), causing episodes to loop or vanish from under the
    // next-episode logic.
    repeatMode = QueueRepeatMode.off;
    repeatModeNotifier.value = QueueRepeatMode.off;

    this.source = source;
    this.title = title;
    this.artwork = artwork;

    queueNotifier.value = List.from(_items);
  }

  void clear() {
    _items.clear();

    _originalOrder = [];

    _currentIndex = -1;

    queueNotifier.value = [];

    source = PlaybackSource.unknown;

    repeatMode = QueueRepeatMode.off;
    repeatModeNotifier.value = QueueRepeatMode.off;

    shuffleNotifier.value = false;

    title = null;

    artwork = null;
  }

  MediaItem? next() {
    if (!hasNext) return null;

    _currentIndex++;
    currentIndexNotifier.value = _currentIndex;

    return current;
  }

  MediaItem? previous() {
    if (!hasPrevious) return null;

    _currentIndex--;
    currentIndexNotifier.value = _currentIndex;

    return current;
  }

  MediaItem? jumpTo(int index) {
    if (index < 0 || index >= _items.length) {
      return null;
    }

    _currentIndex = index;
    currentIndexNotifier.value = index;

    return current;
  }

  double get progress {
    if (_items.isEmpty) return 0;
    return (_currentIndex + 1) / _items.length;
  }

  int get total => _items.length;

  int get index => _currentIndex + 1;

  /// Toggles shuffle on/off. See [_applyModeState] for what actually
  /// happens to the queue as a result.
  void shuffle() {
    if (_items.length < 2) return;

    shuffleNotifier.value = !shuffleNotifier.value;

    _applyModeState();
  }

  /// Reconciles the live queue's order/composition with the current
  /// shuffle + repeat settings. Both shuffle and repeat-all promise to
  /// pull in *every* song from the list playback started from —
  /// including ones that sat before the track the user actually
  /// tapped, which otherwise just sit invisibly ahead of
  /// `_currentIndex` as unreachable "history" (never shown in the
  /// Queue screen's "Next up", never played by forward completion).
  /// Whenever either setting is active, the whole list is rebuilt with
  /// the currently playing track pinned to the front and everything
  /// else — shuffled, or rotated to continue forward then wrap back
  /// around — following it, so nothing is ever left stranded behind
  /// it. Turning both fully off collapses back to the plain "from
  /// here to the end of the list" arrangement, with anything before
  /// the current track once again just invisible history.
  void _applyModeState() {
    final currentItem = current;

    if (currentItem == null) return;

    // The master pool for either arrangement: the original list this
    // queue was set up with, filtered down to whatever's still
    // actually present (this excludes anything a repeat-off
    // completion has already consumed for good, but otherwise
    // includes every song regardless of whether it was ever reached).
    final pool = _originalOrder
        .where((o) => _items.any((i) => i.id == o.id))
        .toList();

    final expanded =
        shuffleNotifier.value || repeatMode == QueueRepeatMode.all;

    if (!expanded) {
      _items
        ..clear()
        ..addAll(pool);

      _currentIndex = _items.indexWhere((e) => e.id == currentItem.id);
    } else {
      final idx = pool.indexWhere((e) => e.id == currentItem.id);

      // Everyone except the current track, continuing forward from
      // its original position through the end of the list and then
      // wrapping back around to the start — i.e. exactly the play
      // order repeat-all should loop through when unshuffled.
      final rest = idx == -1
          ? <MediaItem>[]
          : [...pool.sublist(idx + 1), ...pool.sublist(0, idx)];

      if (shuffleNotifier.value) {
        rest.shuffle(Random());
      }

      _items
        ..clear()
        ..add(currentItem)
        ..addAll(rest);

      _currentIndex = 0;
    }

    currentIndexNotifier.value = _currentIndex;
    queueNotifier.value = List.unmodifiable(_items);
  }

  /// Called when the currently playing *audio* item finishes on its own
  /// (not a manual skip, and not repeat-one — which replays the same
  /// item without touching the queue at all, handled directly in
  /// PlayerManager). Returns the item to play next, or null once the
  /// queue is exhausted and playback should stop.
  ///
  /// - Repeat all: the just-finished item is moved to the *end* of the
  ///   list instead of being removed, so the queue is a genuine loop —
  ///   it keeps playing forever (in shuffled order too, if shuffle is
  ///   also on) and nothing ever disappears from the Queue screen.
  /// - Repeat off: the just-finished item is removed outright, so it
  ///   disappears from the Queue screen. Once the last item finishes
  ///   there's nothing left to point at and this returns null, which
  ///   is what tells PlayerManager to stop playback entirely.
  MediaItem? completeCurrent() {
    if (_items.isEmpty || _currentIndex < 0) {
      return null;
    }

    final played = _items.removeAt(_currentIndex);

    if (repeatMode == QueueRepeatMode.all) {
      _items.add(played);
    }

    // Either way, whatever used to sit right after `played` has
    // already shifted down into `_currentIndex` by virtue of the
    // removeAt above, so the index itself doesn't need to move —
    // except when `played` was the last item in the list, in which
    // case repeat-all wraps back around to the front and repeat-off
    // has nothing left at all.
    if (_currentIndex >= _items.length) {
      _currentIndex = repeatMode == QueueRepeatMode.all ? 0 : -1;
    }

    currentIndexNotifier.value = _currentIndex;
    queueNotifier.value = List.unmodifiable(_items);

    return current;
  }

  /// Appends auto-queued recommendation tracks once the queue has run
  /// out on its own (see PlayerManager's `completed` handling and
  /// MusicRecommendationService). Unlike [setQueue] this doesn't reset
  /// shuffle/repeat or replace anything — the queue is empty by the time
  /// this is called, so it's purely additive and meant to feel like a
  /// continuation of the same session rather than a new one.
  void appendRecommendations(List<MediaItem> items) {
    if (items.isEmpty) return;

    _items.addAll(items);
    _originalOrder.addAll(items);

    if (_currentIndex < 0) {
      _currentIndex = 0;
    }

    currentIndexNotifier.value = _currentIndex;
    queueNotifier.value = List.unmodifiable(_items);
  }

  /// Grafts a live position/played update onto the queue item matching
  /// [itemId], without disturbing anything else about the queue —
  /// same "override just this one field" pattern MediaItem.copyWith
  /// already documents for playbackPosition. Queue items otherwise only
  /// ever carry whatever UserData.PlaybackPositionTicks/Played snapshot
  /// they were built with at fetch time, so anything reading straight
  /// off the queue (EpisodeListPanel's per-row progress bar/watched
  /// badge) stays frozen at that snapshot for the rest of the session —
  /// unlike the TV show detail screen (refetches on player close) and
  /// the Downloads page (reads OfflineProgressStore live), it has no
  /// other way to learn that an episode's progress moved or that it
  /// just got marked watched. Called from PlayerManager's position
  /// listener (throttled) and from its 90%-finished branch.
  /// No-op if [itemId] isn't currently in the queue (e.g. it already
  /// scrolled out via completeCurrent, or this is a non-queue item).
  void updateItemProgress(
    String itemId, {
    Duration? position,
    bool? played,
  }) {
    final index = _items.indexWhere((i) => i.id == itemId);
    if (index == -1) return;

    _items[index] = _items[index].copyWith(
      playbackPosition: position,
      played: played,
    );

    queueNotifier.value = List.unmodifiable(_items);
  }

  void removeAt(int index) {
    if (index < 0 || index >= _items.length) {
      return;
    }

    _items.removeAt(index);

    if (_currentIndex > index) {
      _currentIndex--;
    } else if (_currentIndex >= _items.length) {
      _currentIndex = _items.length - 1;
    }

    queueNotifier.value = List.unmodifiable(_items);

    currentIndexNotifier.value = _currentIndex;
  }

  void addNext(MediaItem item) {
    if (_currentIndex == -1) {
      _items.add(item);
      _currentIndex = 0;
    } else {
      _items.insert(_currentIndex + 1, item);
    }

    _originalOrder.add(item);

    queueNotifier.value = List.unmodifiable(_items);
  }

  void addToQueue(MediaItem item) {
    _items.add(item);

    if (_currentIndex == -1) {
      _currentIndex = 0;
    }

    _originalOrder.add(item);

    queueNotifier.value = List.unmodifiable(_items);
  }

  void move(int oldIndex, int newIndex) {
    if (oldIndex == newIndex) return;

    if (newIndex > oldIndex) {
      newIndex--;
    }

    final item = _items.removeAt(oldIndex);

    _items.insert(newIndex, item);

    if (_currentIndex == oldIndex) {
      _currentIndex = newIndex;
    } else if (
    oldIndex < _currentIndex &&
        newIndex >= _currentIndex) {
      _currentIndex--;
    } else if (
    oldIndex > _currentIndex &&
        newIndex <= _currentIndex) {
      _currentIndex++;
    }

    queueNotifier.value = List.unmodifiable(_items);

    currentIndexNotifier.value = _currentIndex;
  }

  void cycleRepeatMode() {
    switch (repeatMode) {
      case QueueRepeatMode.off:
        repeatMode = QueueRepeatMode.all;
        break;

      case QueueRepeatMode.all:
        repeatMode = QueueRepeatMode.one;
        break;

      case QueueRepeatMode.one:
        repeatMode = QueueRepeatMode.off;
        break;

    }

    repeatModeNotifier.value = repeatMode;

    _applyModeState();
  }
}