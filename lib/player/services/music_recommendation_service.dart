import '../models/media_item.dart';
import '../../services/jellyfin_services/media_service.dart';

/// A single candidate track accumulated while scoring, along with the raw
/// Jellyfin JSON needed to eventually turn it into a [MediaItem].
class _Candidate {
  final Map<String, dynamic> raw;
  final String artistName;
  double score = 0;

  _Candidate(this.raw, this.artistName);
}

/// Builds the "up next" continuation queue when a music queue the person
/// is actually listening to runs out, if they've opted into auto-queued
/// recommendations (see AppSettings.autoQueueRecommendations — off by
/// default).
///
/// This isn't a single API call — it's a small rank-fusion recommender
/// built on top of what the Jellyfin server already exposes:
///
/// 1. Seeds: the last few *distinct* songs actually played this session
///    (most recent first), each seed weighted higher the more recently
///    it played.
/// 2. Signals: for every seed, two independently-ranked candidate lists
///    are pulled from the server — its Instant Mix (Jellyfin's own
///    playback-continuation engine) as the primary signal, and its
///    Similar-items list as a secondary signal. Being an audio server,
///    both are already informed by genre/artist/play-history metadata
///    server-side; fusing several of them together (instead of trusting
///    a single seed's mix) is what keeps the result from just being "more
///    of the last song" the moment the person happened to end on
///    something atypical for their session.
/// 3. Fusion: every appearance of a candidate contributes
///    `seedWeight * signalWeight * (1 - positionInList / listLength)` to
///    that candidate's running score — a track ranked highly by more than
///    one seed/signal naturally rises to the top.
/// 4. Filtering: anything already played this session, or already sitting
///    in the queue, is excluded outright so nothing repeats.
/// 5. Diversity: the final ranked list is walked with a cap of 2 tracks
///    per artist, so the result doesn't turn into a single artist's
///    greatest hits even if that artist dominates the raw scores.
class MusicRecommendationService {
  MusicRecommendationService._();

  static final MusicRecommendationService instance =
      MusicRecommendationService._();

  static const int _maxSeeds = 5;
  static const int _maxHistory = 30;
  static const int _maxPerArtist = 2;

  final List<MediaItem> _history = [];

  /// Call whenever a brand-new, person-initiated queue starts (not an
  /// auto-queued continuation of an old one) — keeps recommendations tied
  /// to the current listening session instead of bleeding in whatever was
  /// played hours/days ago.
  void resetHistory() {
    _history.clear();
  }

  /// Call every time a track actually starts playing. Only audio items
  /// are tracked — video/live playback never feeds this.
  void recordPlayed(MediaItem item) {
    if (!item.audioOnly) return;
    if (_history.isNotEmpty && _history.last.id == item.id) return;

    _history.add(item);
    if (_history.length > _maxHistory) {
      _history.removeAt(0);
    }
  }

  /// Builds the next batch of tracks to auto-queue. [exclude] can carry
  /// any extra track ids the caller wants kept out (e.g. whatever's
  /// still sitting in the queue) — everything already played this
  /// session is always excluded automatically, no need to pass it in.
  /// Returns an empty list if there's no play history to seed from, or if
  /// the server has nothing left to offer.
  Future<List<MediaItem>> buildContinuation({
    Set<String> exclude = const {},
    int targetCount = 10,
  }) async {
    if (_history.isEmpty) return [];

    final exclude0 = {...exclude, ..._history.map((h) => h.id)};

    // Most-recently-played first, capped at _maxSeeds, weighted so the
    // last song played has by far the biggest say and older ones taper
    // off quickly rather than dragging the whole session's average genre
    // into every continuation.
    final seeds = _history.reversed.take(_maxSeeds).toList();

    final candidates = <String, _Candidate>{};
    final seenSeedIds = seeds.map((s) => s.id).toSet();

    for (var i = 0; i < seeds.length; i++) {
      final seed = seeds[i];
      final seedWeight = 1.0 - (i * 0.18).clamp(0.0, 0.8);

      final results = await Future.wait([
        MediaService.getInstantMix(seed.id, limit: 20)
            .catchError((_) => <dynamic>[]),
        MediaService.getSimilarMusic(seed.id, limit: 15)
            .catchError((_) => <dynamic>[]),
      ]);

      _scoreList(
        results[0],
        candidates: candidates,
        seedWeight: seedWeight,
        signalWeight: 1.0, // Instant Mix: primary signal
        exclude: exclude0,
        excludeIds: seenSeedIds,
      );

      _scoreList(
        results[1],
        candidates: candidates,
        seedWeight: seedWeight,
        signalWeight: 0.55, // Similar: secondary signal
        exclude: exclude0,
        excludeIds: seenSeedIds,
      );
    }

    if (candidates.isEmpty) return [];

    final ranked = candidates.values.toList()
      ..sort((a, b) => b.score.compareTo(a.score));

    final picked = <Map<String, dynamic>>[];
    final perArtistCount = <String, int>{};

    for (final candidate in ranked) {
      if (picked.length >= targetCount) break;

      final artistKey = candidate.artistName.isEmpty
          ? candidate.raw["Id"].toString()
          : candidate.artistName;
      final countSoFar = perArtistCount[artistKey] ?? 0;
      if (countSoFar >= _maxPerArtist) continue;

      perArtistCount[artistKey] = countSoFar + 1;
      picked.add(candidate.raw);
    }

    // Diversity cap left us short (e.g. a small, artist-heavy library) —
    // top up from the ranked leftovers, ignoring the cap rather than
    // returning fewer tracks than asked for.
    if (picked.length < targetCount) {
      for (final candidate in ranked) {
        if (picked.length >= targetCount) break;
        if (picked.any((p) => p["Id"] == candidate.raw["Id"])) continue;
        picked.add(candidate.raw);
      }
    }

    return MediaService.mediaItemsFromList(picked);
  }

  void _scoreList(
    dynamic items, {
    required Map<String, _Candidate> candidates,
    required double seedWeight,
    required double signalWeight,
    required Set<String> exclude,
    required Set<String> excludeIds,
  }) {
    if (items is! List || items.isEmpty) return;

    final len = items.length;

    for (var pos = 0; pos < len; pos++) {
      final raw = items[pos];
      if (raw is! Map) continue;

      final id = raw["Id"]?.toString();
      if (id == null || exclude.contains(id) || excludeIds.contains(id)) {
        continue;
      }

      final artistsList = raw["Artists"];
      final artistName = (artistsList is List && artistsList.isNotEmpty)
          ? artistsList.first.toString()
          : (raw["AlbumArtist"]?.toString() ?? "");

      final positionWeight = 1.0 - (pos / len);
      final delta = seedWeight * signalWeight * positionWeight;

      final existing = candidates[id];
      if (existing == null) {
        candidates[id] = _Candidate(Map<String, dynamic>.from(raw), artistName)
          ..score = delta;
      } else {
        existing.score += delta;
      }
    }
  }
}
