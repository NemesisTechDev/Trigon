import 'addon_models.dart';
import 'stream_info.dart';
import 'stream_rules.dart';

/// One link that may be offered or picked, with what ranking needs to know.
class RankedLink {
  const RankedLink(this.stream, this.info, this.tier, this.position);

  final AddonStream stream;
  final StreamInfo info;
  final PreferredTier tier;

  /// Where the addons listed it; keeps ties in the addons' own order.
  final int position;
}

/// The links that may be used at one quality, best first within each type.
class RankedGroup {
  RankedGroup(this.height);

  /// 0 when the addons did not state the quality.
  final int height;
  final List<RankedLink> directs = [];
  final List<RankedLink> torrents = [];

  void _sort() {
    directs.sort(LinkRanking._byTier);
    torrents.sort(LinkRanking.torrentTierFirst
        ? LinkRanking._torrentTierFirst
        : LinkRanking._bySwarm);
  }
}

/// The links to offer for one quality (see [LinkRanking.downloadLinks]).
class QualityLinks {
  const QualityLinks(this.height, this.directs, this.torrents);

  final int height;
  final List<AddonStream> directs;
  final List<AddonStream> torrents;

  /// Direct links first, then torrents.
  List<AddonStream> get all => [...directs, ...torrents];
}

/// The one ranking used by auto link selection and by downloads: links that
/// must never be used are dropped ([StreamRules.exclusionReason]), direct
/// links are ranked by how well their file type matches the preferred ones
/// ([PreferredTier]), and torrents by seeders, then peers.
///
/// Pure and synchronous (no UI, no network).
class LinkRanking {
  LinkRanking._();

  /// false: torrents are ranked by seeders, then peers, and the preferred
  /// file type only breaks a tie (a healthy swarm matters most for a
  /// fallback). true: file type first, then seeders and peers.
  static const bool torrentTierFirst = false;

  /// A direct link is always usable. A torrent needs someone to download
  /// from: 0 seeders is out. When the listing gives no seeder count at all,
  /// the peer count decides; with neither, the torrent is kept (it cannot be
  /// shown to be dead) but ranks below any torrent with known seeders.
  static bool isSuitable(AddonStream s, StreamInfo info) {
    if (!s.isTorrent) return true;
    final seeders = info.seeders;
    if (seeders != null) return seeders > 0;
    final peers = info.peers;
    if (peers != null) return peers > 0;
    return true;
  }

  /// Every link that may be used, grouped by quality and ranked.
  /// [requireSwarm] drops torrents that are not [isSuitable].
  static Map<int, RankedGroup> groupByQuality(
    List<AddonStream> streams,
    LinkContext ctx, {
    required bool requireSwarm,
  }) {
    final groups = <int, RankedGroup>{};
    var index = 0;
    for (final s in streams) {
      final position = index++;
      if (StreamRules.isExcluded(s, ctx)) continue;
      final info = StreamInfo.of(s);
      if (requireSwarm && !isSuitable(s, info)) continue;
      final g = groups.putIfAbsent(s.height, () => RankedGroup(s.height));
      (s.isTorrent ? g.torrents : g.directs)
          .add(RankedLink(s, info, StreamRules.tierOf(s), position));
    }
    for (final g in groups.values) {
      g._sort();
    }
    return groups;
  }

  /// What to offer for download, one entry per quality (highest first,
  /// unknown quality last): the best [maxDirect] direct links and the best
  /// [maxTorrent] torrents. Torrents with no seeders are not offered.
  /// The same link listed twice (by two addons) is offered once.
  static List<QualityLinks> downloadLinks(
    List<AddonStream> streams,
    LinkContext ctx, {
    int maxDirect = 3,
    int maxTorrent = 2,
  }) {
    final groups = groupByQuality(streams, ctx, requireSwarm: true);
    final heights = groups.keys.toList()
      ..sort((a, b) {
        // Unknown quality (0) goes last.
        if (a == 0) return 1;
        if (b == 0) return -1;
        return b.compareTo(a);
      });
    final out = <QualityLinks>[];
    for (final h in heights) {
      final g = groups[h]!;
      out.add(QualityLinks(
        h,
        _top(g.directs, maxDirect),
        _top(g.torrents, maxTorrent),
      ));
    }
    return out;
  }

  static List<AddonStream> _top(List<RankedLink> ranked, int max) {
    final seen = <String>{};
    final out = <AddonStream>[];
    for (final r in ranked) {
      if (out.length >= max) break;
      if (seen.add(r.stream.infoHash ?? r.stream.url)) out.add(r.stream);
    }
    return out;
  }

  // ---- comparators ----

  static int _byTier(RankedLink a, RankedLink b) {
    final byTier = a.tier.rank.compareTo(b.tier.rank);
    return byTier != 0 ? byTier : a.position.compareTo(b.position);
  }

  static int _swarm(RankedLink a, RankedLink b) {
    final bySeeders = (b.info.seeders ?? 0).compareTo(a.info.seeders ?? 0);
    if (bySeeders != 0) return bySeeders;
    return (b.info.peers ?? 0).compareTo(a.info.peers ?? 0);
  }

  static int _bySwarm(RankedLink a, RankedLink b) {
    final bySwarm = _swarm(a, b);
    return bySwarm != 0 ? bySwarm : _byTier(a, b);
  }

  static int _torrentTierFirst(RankedLink a, RankedLink b) {
    final byTier = a.tier.rank.compareTo(b.tier.rank);
    if (byTier != 0) return byTier;
    final bySwarm = _swarm(a, b);
    return bySwarm != 0 ? bySwarm : a.position.compareTo(b.position);
  }
}
