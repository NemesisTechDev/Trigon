import 'package:flutter_cache_manager/flutter_cache_manager.dart';

/// Shared disk cache for every `CachedNetworkImage` in the app.
///
/// `CachedNetworkImage` falls back to `DefaultCacheManager()` when no
/// `cacheManager` is supplied, which caps out at 200 cached files / 30
/// days. For a media library, 200 objects is small enough that normal
/// browsing (posters, backdrops, album art, channel logos, cast photos
/// across Movies/TV/Music/Live TV) evicts images you've already looked
/// at within a single session, so revisiting a screen re-downloads
/// artwork you already paid the bandwidth for once.
///
/// This raises the ceiling to 2000 objects / 60 days — same underlying
/// package, decode path, and lookup, just a bigger table — so nothing
/// about how fast an image appears changes; the only difference is that
/// more of them are already on disk instead of back on the network.
///
/// Uses a distinct cache key from the default manager so switching to
/// this doesn't inherit or fight over the old cache's on-disk state.
class NemesisImageCache {
  NemesisImageCache._();

  static final CacheManager instance = CacheManager(
    Config(
      'nemesisImageCache',
      stalePeriod: const Duration(days: 60),
      maxNrOfCacheObjects: 6000,
    ),
  );
}
