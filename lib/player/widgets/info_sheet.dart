import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../../services/jellyfin_services/media_service.dart';
import '../../utils/epg_utils.dart';
import '../../widgets/shared/nemesis_bottom_sheet.dart';
import '../../widgets/common/rating_badges.dart';
import '../models/media_item.dart';

const _gold = Color(0xffD4AF37);

/// The parent series' IMDb id (needed for [RatingsService.fetchEpisode]
/// — see its doc for why episodes can't just use their own ProviderIds)
/// plus its OfficialRating (the show's PG/content rating, e.g. "TV-14"),
/// since neither is present on an *episode*'s own Jellyfin JSON — only
/// on the series item itself.
class _SeriesInfo {
  final String? imdbId;
  final String officialRating;

  const _SeriesInfo({this.imdbId, this.officialRating = ""});
}

/// Tiny in-memory, session-scoped cache of [_SeriesInfo] keyed by
/// series id, so that watching several episodes of the same show back
/// to back only ever pays for one `getItem` round trip — every info
/// sheet opened afterward for that show paints its episode rating/PG
/// badge on the very first frame via [peek], the same "instant from
/// cache" pattern [RatingsService]/[RatingsRow] already use for the
/// ratings themselves. Deliberately not persisted to disk: this is
/// cheap to refetch per app session and never needs to survive a
/// restart the way the 7-day ratings cache does.
class _SeriesInfoCache {
  _SeriesInfoCache._();

  static final Map<String, _SeriesInfo> _cache = {};
  static final Map<String, Future<_SeriesInfo?>> _inFlight = {};

  static _SeriesInfo? peek(String? seriesId) {
    if (seriesId == null || seriesId.isEmpty) return null;
    return _cache[seriesId];
  }

  static Future<_SeriesInfo?> fetch(String? seriesId) {
    if (seriesId == null || seriesId.isEmpty) return Future.value(null);

    final cached = _cache[seriesId];
    if (cached != null) return Future.value(cached);

    final inFlight = _inFlight[seriesId];
    if (inFlight != null) return inFlight;

    final future = _load(seriesId);
    _inFlight[seriesId] = future;
    return future;
  }

  static Future<_SeriesInfo?> _load(String seriesId) async {
    try {
      final series = await MediaService.getItem(seriesId);
      final providerIds = series["ProviderIds"];
      final imdbRaw = providerIds is Map
          ? (providerIds["Imdb"] ?? providerIds["IMDB"] ?? providerIds["imdb"])
          : null;
      final imdbId = imdbRaw?.toString();

      final info = _SeriesInfo(
        imdbId: (imdbId == null || imdbId.isEmpty) ? null : imdbId,
        officialRating: series["OfficialRating"]?.toString() ?? "",
      );
      _cache[seriesId] = info;
      return info;
    } catch (_) {
      return null;
    } finally {
      _inFlight.remove(seriesId);
    }
  }
}

/// Opens the in-player "Info" sheet for whatever's currently playing.
///
/// Content adapts to the kind of item:
/// - Live TV: whatever program is actually airing right now on this
///   channel — name, description, and a live start/end progress bar —
///   fetched fresh each time the sheet opens (and refreshed every 30s
///   while it stays open), since a channel's "now playing" program can
///   change mid-session the same way LiveTvDetailScreen's own "Now
///   Playing" card does.
/// - Episode: series name, the "SxxExx" code, the show's own PG/
///   content rating, the episode's own IMDb/Rotten Tomatoes ratings
///   (resolved via the parent series' IMDb id + season/episode number
///   — see [_SeriesInfoCache]/RatingsService.fetchEpisode, since
///   individual episodes are essentially never tagged with their own
///   provider ids), and the episode's preview/overview.
/// - Everything else (movies, and any other VOD item): title, year,
///   PG/content rating, IMDb/Rotten Tomatoes ratings, genres, and the
///   overview.
///
/// Reads straight off [MediaItem.raw] (the original Jellyfin JSON this
/// item was built from) rather than issuing its own item fetch — the
/// same "no extra network round trip just to show metadata that's
/// already in memory" approach the rest of the player already follows.
/// Externally-opened files, local library files, and downloaded items
/// have no `raw` behind them at all (see MediaItem.isLocal); the sheet
/// falls back to just the title in that case instead of leaving
/// sections blank/broken.
///
/// CASTING: while a video is being cast, the item that matters is the
/// cast session's own `currentItem` (the TV can move on to another
/// episode on its own — a queue advancing, a remote's next button, the
/// episode panel), not the local player's frozen-at-handoff item. The
/// player's Info button passes that notifier as [liveItem] so the sheet
/// follows it: the sheet re-targets itself (see
/// `_PlayerInfoSheetState.didUpdateWidget`) whenever the cast item's id
/// changes while it's open, and a null/changed-to-nothing value just
/// keeps showing [item]. Omitted for ordinary local playback, where the
/// sheet is the same fixed snapshot it always was.
void showPlayerInfoSheet(
  BuildContext context,
  MediaItem item, {
  ValueListenable<MediaItem?>? liveItem,
}) {
  // Same chrome as before (transparent root-navigator modal wrapping a
  // DraggableScrollableSheet in a 0xff181818 rounded container) — now via
  // the shared helper so it also opens exactly as tall as its content in
  // portrait and never above 2/3 of the screen in landscape.
  showNemesisBottomSheet<void>(
    context,
    initialChildSize: 0.55,
    minChildSize: 0.32,
    maxChildSize: 0.92,
    builder: (_, scrollController) {
      if (liveItem == null) {
        return _PlayerInfoSheet(item: item, scrollController: scrollController);
      }

      return ValueListenableBuilder<MediaItem?>(
        valueListenable: liveItem,
        builder: (_, live, __) => _PlayerInfoSheet(
          item: live ?? item,
          scrollController: scrollController,
        ),
      );
    },
  );
}

class _PlayerInfoSheet extends StatefulWidget {
  final MediaItem item;
  final ScrollController scrollController;

  const _PlayerInfoSheet({
    required this.item,
    required this.scrollController,
  });

  @override
  State<_PlayerInfoSheet> createState() => _PlayerInfoSheetState();
}

class _PlayerInfoSheetState extends State<_PlayerInfoSheet> {
  Map<String, dynamic>? _currentProgram;
  bool _loadingProgram = false;
  Timer? _ticker;

  // Only ever populated for episodes — see _SeriesInfo's doc for why
  // the episode rating and the show's PG rating both need this rather
  // than anything already on the episode's own raw JSON.
  _SeriesInfo? _seriesInfo;

  bool get _isLive => widget.item.live;
  bool get _isEpisode => widget.item.episodeNumber != null;
  Map<String, dynamic>? get _raw => widget.item.raw;

  @override
  void initState() {
    super.initState();
    _loadForItem();
  }

  /// CASTING: the sheet can now be handed a different item while it's
  /// open (the TV moved to another episode/movie — see
  /// showPlayerInfoSheet's `liveItem`). Everything this State caches
  /// per item (the live program, the series' rating info, the 30s
  /// ticker) belongs to the OLD item, so a changed id resets it and
  /// reloads for the new one. A same-id update (CastManager swapping
  /// in the augmented copy of the same item) deliberately does nothing
  /// extra — the build methods read `widget.item` directly.
  @override
  void didUpdateWidget(covariant _PlayerInfoSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.id == widget.item.id) return;

    _ticker?.cancel();
    _ticker = null;
    _currentProgram = null;
    _loadingProgram = false;
    _seriesInfo = null;
    _loadForItem();
  }

  void _loadForItem() {
    if (_isLive) {
      _loadCurrentProgram();

      // Keeps the progress bar (and, on the rare chance a program
      // boundary is crossed while the sheet is left open, the name/
      // description too) live rather than frozen at whatever was true
      // the moment the sheet opened.
      _ticker = Timer.periodic(const Duration(seconds: 30), (_) {
        if (mounted) setState(() {});
      });
    } else if (_isEpisode) {
      // NAMESIS PRIME: addon streams carry the show's IMDb id and age
      // rating themselves (CatalogPlayback.buildItem), there is no
      // Jellyfin series item to fetch.
      final r = _raw;
      if (r != null && r['AddonStream'] == true) {
        final imdb = r['SeriesImdbId']?.toString() ?? '';
        _seriesInfo = _SeriesInfo(
          imdbId: imdb.isEmpty ? null : imdb,
          officialRating: r['SeriesOfficialRating']?.toString() ?? '',
        );
        return;
      }
      // Paint synchronously from cache on the first frame when it's
      // already warm (same reasoning as RatingsRow's own _peek() —
      // see rating_badges.dart) instead of always starting blank.
      final seriesId = widget.item.seriesId;
      final cached = _SeriesInfoCache.peek(seriesId);
      if (cached != null) {
        _seriesInfo = cached;
      } else {
        _loadSeriesInfo(seriesId);
      }
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _loadCurrentProgram() async {
    // CASTING: remembered so a slow response for a channel the sheet has
    // since moved off of (see didUpdateWidget) can't overwrite the new
    // channel's program.
    final requestedFor = widget.item.id;
    setState(() => _loadingProgram = true);

    try {
      final programs =
          await MediaService.getPrograms(channelId: requestedFor);
      final picked = _pickCurrentProgram(programs);

      if (!mounted || widget.item.id != requestedFor) return;
      setState(() {
        _currentProgram = picked;
        _loadingProgram = false;
      });
    } catch (_) {
      if (!mounted || widget.item.id != requestedFor) return;
      setState(() => _loadingProgram = false);
    }
  }

  Future<void> _loadSeriesInfo(String? seriesId) async {
    final info = await _SeriesInfoCache.fetch(seriesId);
    // Same stale-response guard as _loadCurrentProgram.
    if (!mounted || info == null || widget.item.seriesId != seriesId) return;
    setState(() => _seriesInfo = info);
  }

  /// Picking the currently-airing program, its progress/duration, and
  /// formatting its start/end clock times all go through EpgUtils —
  /// the same shared, timezone-correct calculations the TV Guide, Live
  /// TV detail screen's Now Playing card, and the in-player channel
  /// list panel use, so this sheet can never quietly drift out of sync
  /// with what those already show for the same program.
  Map<String, dynamic>? _pickCurrentProgram(List programs) =>
      EpgUtils.pickCurrentProgram(programs);

  double _programProgress() {
    final program = _currentProgram;
    if (program == null) return 0;
    return EpgUtils.progress(program["StartDate"], program["EndDate"]);
  }

  String _programDuration() {
    final program = _currentProgram;
    if (program == null) return "";
    return EpgUtils.formatDuration(program["StartDate"], program["EndDate"]);
  }

  /// Whether [item] is likely to have an IMDb/Rotten Tomatoes rating —
  /// used only to decide whether RatingsRow gets a slot at all, since
  /// RatingsRow itself resolves asynchronously (or synchronously from
  /// cache) and quietly renders nothing when it comes back empty.
  bool _hasRatingSignal(Map<String, dynamic> item) {
    final providerIds = item["ProviderIds"];
    return providerIds is Map &&
        (providerIds["Imdb"] ?? providerIds["IMDB"] ?? providerIds["imdb"]) !=
            null;
  }

  @override
  Widget build(BuildContext context) {
    // The rounded 0xff181818 container + SafeArea + drag/resize behavior
    // now come from showNemesisBottomSheet (see showPlayerInfoSheet).
    return ListView(
      controller: widget.scrollController,
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
      children: [
        Center(
          child: Container(
            width: 40,
            height: 4,
            margin: const EdgeInsets.only(bottom: 18),
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
        if (_isLive)
          _buildLive()
        else if (_isEpisode)
          _buildEpisode()
        else
          _buildMovie(),
      ],
    );
  }

  // ---------------------------------------------------------------
  // Live TV
  // ---------------------------------------------------------------

  Widget _buildLive() {
    final program = _currentProgram;

    if (_loadingProgram && program == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 40),
        child: Center(
          child: CircularProgressIndicator(color: _gold, strokeWidth: 2.4),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.red,
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Text(
                "LIVE",
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 11,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                widget.item.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),

        const SizedBox(height: 12),

        Text(
          program?["Name"]?.toString() ?? "Unknown Program",
          style: const TextStyle(
            color: Colors.white,
            fontSize: 22,
            fontWeight: FontWeight.bold,
          ),
        ),

        if (_programDuration().isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            _programDuration(),
            style: const TextStyle(color: Colors.white54, fontSize: 13),
          ),
        ],

        const SizedBox(height: 16),

        Text(
          (program?["Overview"] ?? "").toString().isEmpty
              ? "No description available."
              : program!["Overview"].toString(),
          style: const TextStyle(color: Colors.white70, height: 1.6),
        ),

        if (program != null) ...[
          const SizedBox(height: 20),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: _programProgress(),
              minHeight: 5,
              backgroundColor: Colors.white12,
              valueColor: const AlwaysStoppedAnimation(_gold),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                EpgUtils.formatTime(program["StartDate"]),
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
              Text(
                EpgUtils.formatTime(program["EndDate"]),
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ],
          ),
        ],
      ],
    );
  }

  // ---------------------------------------------------------------
  // Episode
  // ---------------------------------------------------------------

  Widget _buildEpisode() {
    final raw = _raw;
    final season = widget.item.seasonNumber;
    final episode = widget.item.episodeNumber;
    final code = (season != null && episode != null)
        ? "S${season.toString().padLeft(2, '0')}"
            "E${episode.toString().padLeft(2, '0')}"
        : null;
    final overview = (raw?["Overview"] ?? "").toString();

    // The show's own PG/content rating (e.g. "TV-14") — lives on the
    // series item, not the episode's own raw JSON, so it only ever
    // shows up once _seriesInfo has resolved (instantly from cache
    // when this show's already been seen this session).
    final showRating = _seriesInfo?.officialRating ?? "";

    // Episodes are essentially never tagged with their own IMDb id —
    // RatingsRow needs the series' IMDb id + season/episode instead
    // (see RatingsService.fetchEpisode's doc), so this only renders
    // once _seriesInfo has resolved one.
    final seriesImdbId = _seriesInfo?.imdbId;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.item.subtitle.isNotEmpty)
          Text(
            widget.item.subtitle,
            style: const TextStyle(
              color: _gold,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),

        const SizedBox(height: 4),

        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            if (code != null) ...[
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.white12,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  code,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(width: 6),
            ],
            if (showRating.isNotEmpty) ...[
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.white38, width: 1),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  showRating,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 10),
            ],
            Expanded(
              child: Text(
                widget.item.title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),

        if (raw != null &&
            season != null &&
            episode != null &&
            seriesImdbId != null) ...[
          const SizedBox(height: 10),
          RatingsRow(
            item: raw,
            seriesImdbId: seriesImdbId,
            seasonNumber: season,
            episodeNumber: episode,
            fontSize: 14,
            textColor: Colors.white,
          ),
        ],

        const SizedBox(height: 16),

        Text(
          overview.isEmpty ? "No overview available." : overview,
          style: const TextStyle(color: Colors.white70, height: 1.6),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------
  // Movie (and anything else that isn't live/episode)
  // ---------------------------------------------------------------

  Widget _buildMovie() {
    final raw = _raw;
    final official = raw?["OfficialRating"]?.toString() ?? "";
    final year = raw?["ProductionYear"]?.toString() ?? "";
    final genres = List<String>.from(
      (raw?["Genres"] as List? ?? []).map((g) => g.toString()),
    );
    final overview = (raw?["Overview"] ?? "").toString();

    // Metadata row is deliberately just year + PG rating here — runtime
    // is already visible from the player's own scrubber/duration, so
    // repeating it in this sheet would be redundant.
    final metaParts = <Widget>[];
    void addDot() {
      if (metaParts.isNotEmpty) {
        metaParts.add(
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 8),
            child: Text("•", style: TextStyle(color: Colors.white38)),
          ),
        );
      }
    }

    if (year.isNotEmpty) {
      addDot();
      metaParts.add(Text(
        year,
        style: const TextStyle(color: Colors.white70, fontSize: 13),
      ));
    }

    if (official.isNotEmpty) {
      addDot();
      metaParts.add(Text(
        official,
        style: const TextStyle(color: Colors.white70, fontSize: 13),
      ));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.item.title,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 22,
            fontWeight: FontWeight.bold,
          ),
        ),

        if (metaParts.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: metaParts,
          ),
        ],

        if (raw != null && _hasRatingSignal(raw)) ...[
          const SizedBox(height: 10),
          RatingsRow(item: raw, fontSize: 14, textColor: Colors.white),
        ],

        if (genres.isNotEmpty) ...[
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: genres.map((g) {
              return Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: Colors.white12,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  g,
                  style:
                      const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              );
            }).toList(),
          ),
        ],

        const SizedBox(height: 16),

        Text(
          overview.isEmpty ? "No overview available." : overview,
          style: const TextStyle(color: Colors.white70, height: 1.6),
        ),
      ],
    );
  }
}
