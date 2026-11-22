import '../addons/addon_models.dart';
import '../addons/link_ranking.dart';
import '../addons/stream_rules.dart';
import '../services/app_settings.dart';

/// The link [AutoLinkSelector] picked, plus the links to try, in order, if
/// it fails to start (see LinkFallbackCoordinator).
///
/// [overridden] is true when the link is NOT one the current Streaming
/// Quality setting asks for (nothing suitable was available at the wanted
/// quality), so the person should be told.
class AutoLinkChoice {
  const AutoLinkChoice({
    required this.stream,
    required this.overridden,
    this.fallbacks = const [],
  });

  final AddonStream stream;
  final bool overridden;

  /// What to try next if [stream] does not start, best first. Empty when
  /// there is nothing else.
  final List<AddonStream> fallbacks;

  /// [stream] followed by [fallbacks].
  List<AddonStream> get queue => [stream, ...fallbacks];
}

/// Picks one link out of everything the addons returned, using the person's
/// Streaming Quality setting, so the link list never has to be shown.
///
///  - Default      -> 720p
///  - Max Quality  -> 1080p
///  - Data Saver   -> 360p, otherwise 480p
///
/// Links that must never be picked are dropped first (see [StreamRules]):
/// HLS streams, anything from vidlink, CAM recordings, and links whose audio
/// is only a foreign-language dub.
///
/// Within a quality, a direct link always beats a torrent:
///  - direct links are ranked by how well their file type matches the
///    preferred ones ([PreferredTier]), then by the addons' own order;
///  - torrents are only the fallback, and are ranked by seeders, then peers,
///    then file type.
///
/// The fallback order (see [AutoLinkChoice.queue]) is: EVERY suitable direct
/// link of the wanted quality, best first; only when all of those have
/// failed, the torrents of that quality; then the other qualities.
///
/// A torrent that reports 0 seeders is not "suitable" and is not picked.
/// When nothing suitable exists at the wanted quality, the closest other
/// quality that does have a suitable link is used and [AutoLinkChoice.overridden]
/// is set. Null means no link at all is suitable.
///
/// Pure and synchronous on purpose (no UI, no network).
class AutoLinkSelector {
  AutoLinkSelector._();

  /// Shown when a link outside the wanted quality had to be used.
  static const String overrideMessage =
      'Quality setting overridden, no suitable available link for the '
      'current quality setting.';

  /// How many links, at most, are lined up for one playback (the first is
  /// the pick, the rest are the fallbacks).
  static const int maxQueue = 24;

  /// At the wanted quality: at most this many direct links are lined up
  /// (best first), and only after them at most this many torrents.
  static const int maxDirectsPerQuality = 8;
  static const int maxTorrentFallbacks = 3;

  /// At every other quality: at most this many direct links, then the best
  /// torrent.
  static const int maxOtherQualityDirects = 2;

  /// The qualities the setting asks for, best match first. Using one of
  /// these is NOT an override (Data Saver may use 480p when 360p is missing).
  static List<int> wanted(PlaybackQualityMode mode) {
    switch (mode) {
      case PlaybackQualityMode.dataSaver:
        return const [360, 480];
      case PlaybackQualityMode.standard:
        return const [720];
      case PlaybackQualityMode.maxQuality:
        return const [1080];
    }
  }

  /// What is tried, in order, once none of [wanted] has a suitable link.
  /// Data Saver goes to 720p first (then 1080p), as asked.
  static List<int> _fallbacks(PlaybackQualityMode mode) {
    switch (mode) {
      case PlaybackQualityMode.dataSaver:
        return const [720, 1080];
      case PlaybackQualityMode.standard:
        return const [480, 1080, 360];
      case PlaybackQualityMode.maxQuality:
        return const [720, 480, 360];
    }
  }

  /// True when the best possible link is already among [streams]: a direct
  /// link, at the quality the setting asks for first, of the top file type.
  /// Nothing arriving later can beat it, so the caller can stop waiting for
  /// the remaining addons.
  static bool hasIdealLink(
    List<AddonStream> streams,
    PlaybackQualityMode mode, {
    LinkContext ctx = LinkContext.none,
  }) {
    final target = wanted(mode).first;
    for (final s in streams) {
      if (s.isTorrent || s.height != target) continue;
      if (StreamRules.isExcluded(s, ctx)) continue;
      if (StreamRules.tierOf(s) == PreferredTier.a) return true;
    }
    return false;
  }

  /// True when a direct link that may be picked already exists at the quality
  /// the setting asks for first. Playback can start with it: links still
  /// arriving only refine the order, and are handed to the fallback list
  /// (LinkFallbackCoordinator.topUp).
  static bool hasGoodDirectLink(
    List<AddonStream> streams,
    PlaybackQualityMode mode, {
    LinkContext ctx = LinkContext.none,
  }) {
    final target = wanted(mode).first;
    for (final s in streams) {
      if (s.isTorrent || s.height != target) continue;
      if (!StreamRules.isExcluded(s, ctx)) return true;
    }
    return false;
  }

  /// Like [select], but never gives up while there is any link that may be
  /// picked: when nothing is suitable (every torrent shows 0 seeders) the best
  /// of what is there is used anyway, flagged as overridden. Null only when
  /// every link is empty or excluded.
  static AutoLinkChoice? selectAlways(
    List<AddonStream> streams,
    PlaybackQualityMode mode, {
    LinkContext ctx = LinkContext.none,
  }) {
    final strict = select(streams, mode, ctx: ctx);
    if (strict != null) return strict;
    final lenient = _select(streams, mode, ctx, requireSwarm: false);
    if (lenient == null) return null;
    return AutoLinkChoice(
      stream: lenient.stream,
      overridden: true,
      fallbacks: lenient.fallbacks,
    );
  }

  static AutoLinkChoice? select(
    List<AddonStream> streams,
    PlaybackQualityMode mode, {
    LinkContext ctx = LinkContext.none,
  }) =>
      _select(streams, mode, ctx, requireSwarm: true);

  static AutoLinkChoice? _select(
    List<AddonStream> streams,
    PlaybackQualityMode mode,
    LinkContext ctx, {
    required bool requireSwarm,
  }) {
    // Every link that may be picked, grouped by quality
    // (height 0 = quality not stated) and ranked.
    final groups =
        LinkRanking.groupByQuality(streams, ctx, requireSwarm: requireSwarm);
    if (groups.isEmpty) return null;

    final heights = _heightOrder(groups.keys, mode);
    final overridden = !wanted(mode).contains(heights.first);

    final queue = <AddonStream>[];
    final seen = <String>{};
    void add(RankedLink c) {
      if (queue.length >= maxQueue) return;
      if (seen.add(c.stream.infoHash ?? c.stream.url)) queue.add(c.stream);
    }

    for (var i = 0; i < heights.length; i++) {
      final g = groups[heights[i]]!;
      if (i == 0) {
        // The wanted quality: every suitable direct link first, best first,
        // so a direct link that fails is replaced by the next direct link.
        for (final c in g.directs.take(maxDirectsPerQuality)) {
          add(c);
        }
        // Only once all of them have failed: the torrent fallback (most
        // seeders / peers first). With no direct link at all, this is where
        // the pick itself comes from.
        for (final c in g.torrents.take(maxTorrentFallbacks)) {
          add(c);
        }
      } else {
        // Other qualities only matter once everything at the wanted one is
        // used up: their best direct links, then their best torrent.
        for (final c in g.directs.take(maxOtherQualityDirects)) {
          add(c);
        }
        if (g.torrents.isNotEmpty) add(g.torrents.first);
      }
    }

    return AutoLinkChoice(
      stream: queue.first,
      overridden: overridden,
      fallbacks: queue.skip(1).toList(),
    );
  }

  /// The qualities that have a link, in the order they are tried: the ones
  /// the setting asks for, then its fallbacks, then any other stated quality
  /// (576p, 1440p, 4K...) closest to what was wanted (the lower one on a tie),
  /// and last a link whose quality the addon never stated.
  static List<int> _heightOrder(Iterable<int> present, PlaybackQualityMode mode) {
    final have = present.toSet();
    final primary = wanted(mode);
    final fallbacks = _fallbacks(mode);
    final out = <int>[
      for (final h in primary)
        if (have.contains(h)) h,
      for (final h in fallbacks)
        if (have.contains(h)) h,
    ];
    final anchor = primary.first;
    final others = have
        .where((h) => h > 0 && !primary.contains(h) && !fallbacks.contains(h))
        .toList()
      ..sort((a, b) {
        final byDistance = (a - anchor).abs().compareTo((b - anchor).abs());
        return byDistance != 0 ? byDistance : a.compareTo(b);
      });
    out.addAll(others);
    if (have.contains(0)) out.add(0);
    return out;
  }
}
