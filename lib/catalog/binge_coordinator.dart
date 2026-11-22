import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../library/watch_entry.dart';
import '../player/models/media_item.dart';
import '../player/player_manager.dart';
import '../player/services/playback_queue.dart';
import 'catalog_playback.dart';
import 'next_episode_service.dart';

/// Keeps the next episode lined up behind the one that is playing.
///
/// The existing player already knows how to show a "Next episode" card and
/// auto-advance (it does this for Jellyfin season queues). It does that
/// whenever the queue's source is `season` and a next item is queued. So all
/// this has to do is, once an addon episode is playing, work out the next
/// episode, resolve a stream for it, and append it to the queue.
class BingeCoordinator {
  BingeCoordinator._();
  static final BingeCoordinator instance = BingeCoordinator._();

  bool _inited = false;
  String? _handledId;

  void init() {
    if (_inited) return;
    _inited = true;
    PlayerManager.instance.currentItemNotifier.addListener(_onItemChanged);
  }

  void _onItemChanged() {
    final item = PlayerManager.instance.currentItem;
    if (item == null ||
        item.raw?['AddonStream'] != true ||
        item.raw?['Type'] != 'Episode') {
      _handledId = null;
      return;
    }
    if (item.id == _handledId) return;
    _handledId = item.id;
    unawaited(_queueNext(item));
  }

  Future<void> _queueNext(MediaItem item) async {
    try {
      final snapshot = TitleSnapshot.fromJson(item.raw?['NamesisTitle']);
      final episode = episodeFromRaw(item.raw?['NamesisEpisode']);
      if (snapshot == null || episode == null) return;

      // Don't touch the queue until this item is really playing: opening an
      // item (re)sets the queue, which would wipe anything added earlier.
      if (!await _waitUntilPlaying(item.id)) return;

      final title = snapshot.toTitle();
      final next = await NextEpisodeService.findNext(title, episode);
      if (next == null) return;

      final stream = await NextEpisodeService.resolveStream(title, next);
      if (stream == null) return;

      final nextItem = await CatalogPlayback.buildItemResolved(
        title: title,
        stream: stream,
        episode: next,
      );

      // Re-check: the person may have moved on, or something else queued.
      final queue = PlaybackQueue.instance;
      if (PlayerManager.instance.currentItem?.id != item.id) return;
      if (queue.current?.id != item.id || queue.hasNext) return;

      queue.addToQueue(nextItem);
      // This is what makes the player treat the queue as a season and show
      // its own Next Episode card.
      queue.source = PlaybackSource.season;

      // The next episode used to start from a cold connection (new link,
      // or a torrent that had not started), which showed as a long wait at
      // 0:00. Touch it shortly before the current one ends.
      unawaited(_warmNearEnd(item.id, nextItem));
    } catch (e) {
      debugPrint('[BingeCoordinator] queue next failed: $e');
    }
  }

  /// Waits until the playing item [id] is within a few minutes of its end,
  /// then opens the next episode's stream briefly so its server (or the
  /// torrent engine) is ready when playback moves on.
  Future<void> _warmNearEnd(String id, MediaItem next) async {
    final pm = PlayerManager.instance;
    for (var i = 0; i < 1200; i++) {
      await Future<void>.delayed(const Duration(seconds: 10));
      if (pm.currentItem?.id != id) return;
      final dur = pm.duration.value;
      if (dur <= Duration.zero) continue;
      if (dur - pm.position.value <= const Duration(minutes: 4)) {
        await _warm(next);
        return;
      }
    }
  }

  static Future<void> _warm(MediaItem item) async {
    HttpClient? client;
    try {
      final uri = Uri.tryParse(item.streamUrl);
      if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
        return;
      }
      client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
      final req = await client.getUrl(uri);
      req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-65535');
      final extra = item.raw?['HttpHeaders'];
      if (extra is Map) {
        extra.forEach((k, v) => req.headers.set(k.toString(), v.toString()));
      }
      final resp = await req.close().timeout(const Duration(seconds: 20));
      // Take the first chunk only, then drop the connection.
      await resp.first.timeout(const Duration(seconds: 20));
    } catch (_) {
      // Best effort: playback works the same without it.
    } finally {
      client?.close(force: true);
    }
  }

  /// True once [id] is the current item, finished loading and is the queue's
  /// current entry. Gives up after ~5 minutes or if something else starts.
  /// (It used to give up after 60 s, but resuming into a slow source or a
  /// torrent can keep the first picture waiting longer than that, and the
  /// next episode was then never lined up.)
  Future<bool> _waitUntilPlaying(String id) async {
    final pm = PlayerManager.instance;
    for (var i = 0; i < 600; i++) {
      if (pm.currentItem?.id != id) return false;
      if (!pm.loading.value && PlaybackQueue.instance.current?.id == id) {
        return true;
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    return false;
  }
}
