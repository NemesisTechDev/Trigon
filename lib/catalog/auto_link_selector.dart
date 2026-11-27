import '../addons/addon_models.dart';
import '../addons/link_ranking.dart';
import '../addons/stream_info.dart';
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
///  - Max Quality  -> 1080p, or 1440p when that is what exists
///  - Data Saver   -> 360p, otherwise 480p
///
/// 4K (2160p and above) is NEVER picked here, not even as a last resort or
/// a fallback: a 4K link only plays when the person chooses it themselves
/// (the link list, or the 4K row of the player's Video Quality sheet; see
/// [qualityChoices]). When nothing but 4K exists, null is returned.
///
/// Links that must never be picked are dropped first (see [StreamRules]):
/// HLS streams, anything from vidlink, CAM recordings, and links whose audio
/// is only a foreign-language dub.
///
/// Within a quality, a direct link always beats a torrent:
///  - with Default and Data Saver, when there are several direct links, the
///    one with the SMALLEST file is picked (see [LinkRanking.smallestFirst]);
///    links whose size is not listed come after those whose size is, and
///    equal sizes are ranked by how well their file type matches the
///    preferred ones ([PreferredTier]), then by the addons' own order;
///  - with Max Quality the size is ignored: direct links are ranked by how
///    well their file type matches the preferred ones, then by the addons'
///    own order;
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

  /// From this height up a link counts as 4K (2160p; 4320p too).
  static const int fourKMinHeight = 2000;
  static bool isFourK(int height) => height >= fourKMinHeight;

  /// True when [streams] hold a link that may be played but is 4K (so an
  /// empty automatic pick can say why).
  static bool hasFourKLinks(
    List<AddonStream> streams, {
    LinkContext ctx = LinkContext.none,
  }) {
    for (final s in streams) {
      if (isFourK(s.height) && !StreamRules.isExcluded(s, ctx)) return true;
    }
    return false;
  }

  /// The qualities the setting asks for, best match first. Using one of
  /// these is NOT an override (Data Saver may use 480p when 360p is missing).
  static List<int> wanted(PlaybackQualityMode mode) {
    switch (mode) {
      case PlaybackQualityMode.dataSaver:
        return const [360, 480];
      case PlaybackQualityMode.standard:
        return const [720];
      case PlaybackQualityMode.maxQuality:
        // 1080p first; 1440p counts as wanted too (not an override), 4K never.
        return const [1080, 1440];
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

  /// Whether the smallest file is preferred among direct links of one
  /// quality: Default and Data Saver yes, Max Quality no (it takes the best
  /// file type whatever the size).
  static bool prefersSmallest(PlaybackQualityMode mode) =>
      mode != PlaybackQualityMode.maxQuality;

  static List<RankedLink> _directsInOrder(
    RankedGroup g,
    PlaybackQualityMode mode,
  ) =>
      prefersSmallest(mode) ? LinkRanking.smallestFirst(g.directs) : g.directs;

  /// True when the best possible link is already among [streams]: a direct
  /// link, at the quality the setting asks for first, of the top file type.
  ///
  /// Only meaningful with Max Quality, where nothing arriving later can beat
  /// it, so the caller can stop waiting for the remaining addons. With
  /// Default and Data Saver the pick is the smallest direct link, which a
  /// later addon may still beat, so playback waits the short grace period
  /// after the first good direct link instead (see [hasGoodDirectLink]).
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
    // 4K is manual-only: never part of an automatic pick or its fallbacks.
    groups.removeWhere((height, _) => isFourK(height));
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
        // The wanted quality: every suitable direct link first (smallest
        // file first, except with Max Quality), so a direct link that fails
        // is replaced by the next direct link.
        for (final c
            in _directsInOrder(g, mode).take(maxDirectsPerQuality)) {
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
        for (final c
            in _directsInOrder(g, mode).take(maxOtherQualityDirects)) {
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

  /// One row per quality for the player's Video Quality sheet, highest first
  /// (unknown last), 4K included because the person is choosing by hand.
  ///
  /// Each row's link is the one the automatic selection would use at that
  /// quality: the never-select rules apply ([StreamRules]); a direct link
  /// beats a torrent; direct links are ranked like [select] does (smallest
  /// file first with Default / Data Saver, best file type with Max Quality);
  /// torrents by seeders, then peers. [QualityChoice.fallbacks] holds the
  /// next links of the same quality, in that order.
  static List<QualityChoice> qualityChoices(
    List<AddonStream> streams,
    PlaybackQualityMode mode, {
    LinkContext ctx = LinkContext.none,
  }) {
    final groups =
        LinkRanking.groupByQuality(streams, ctx, requireSwarm: false);
    final heights = groups.keys.toList()
      ..sort((a, b) {
        if (a == 0) return 1;
        if (b == 0) return -1;
        return b.compareTo(a);
      });
    final out = <QualityChoice>[];
    for (final h in heights) {
      final g = groups[h]!;
      final ordered = <RankedLink>[
        ..._directsInOrder(g, mode).take(maxDirectsPerQuality),
        ...g.torrents.take(maxTorrentFallbacks),
      ];
      if (ordered.isEmpty) continue;
      out.add(QualityChoice(
        height: h,
        best: ordered.first.stream,
        info: ordered.first.info,
        sources: g.directs.length + g.torrents.length,
        fallbacks: [for (final c in ordered.skip(1)) c.stream],
      ));
    }
    return out;
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
