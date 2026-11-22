import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../player/models/media_item.dart';
import '../../services/jellyfin_services/media_service.dart';
import '../../utils/artwork_source.dart';
import '../../utils/epg_utils.dart';
import '../models/cast_session.dart';
import 'cast_ui.dart';

/// Casting Phase 13 — the "what's casting" header `VideoPlayerScreen`'s
/// fullscreen casting panel shows above its seek bar/transport controls.
///
/// Previously this was a plain centered column (a generic Cast icon, then
/// "Casting to X" as the only line identifying *what* was playing) — the
/// same treatment regardless of whether a movie, a TV episode, or a live
/// channel was actually on the TV. This instead reuses the mini player's
/// own established layout language (poster/logo thumbnail on the left,
/// a text column on the right, mirroring MiniPlayer's own casting
/// artwork treatment — a scaled-down 2:3 poster card for movies/
/// episodes, the bare logo for live channels) so the casting panel
/// reads the same
/// way the rest of the app already presents "what's playing", just
/// pointed at the cast session instead of local playback — and, unlike
/// the old generic panel, actually shows the right fields for what's
/// casting:
/// - **Movie**: poster + title only.
/// - **Episode**: poster + a small "Season X · Episode Y" line, then the
///   show name and episode name combined on one line ("Show · Episode")
///   to keep this readable at mini-player width rather than wrapping.
/// - **Live TV channel**: the channel's own logo/icon (not a poster —
///   channels don't have one), the channel name, and the currently-
///   airing program's name + duration, fetched the same way the
///   in-player Info sheet already does (`MediaService.getPrograms` +
///   `EpgUtils.pickCurrentProgram`/`formatDuration`) so this can never
///   show a different "what's on now" than that sheet does for the same
///   channel.
///
/// The casting indicator itself — a small cast icon plus the connected
/// device's name — is kept exactly as before, just folded into this
/// card's text column (in `castGold`, mirroring how `MiniPlayer` swaps
/// its own subtitle line for "Playing on X" while a session is
/// connected) rather than living in a separate block above it.
class CastingMediaCard extends StatelessWidget {
  const CastingMediaCard({super.key, required this.session});

  final CastSession session;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<MediaItem?>(
      valueListenable: session.currentItem,
      builder: (context, item, __) {
        if (item == null) return const SizedBox.shrink();

        return Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            _Thumbnail(item: item),
            const SizedBox(width: 14),
            Expanded(child: _InfoColumn(item: item, session: session)),
          ],
        );
      },
    );
  }
}

class _Thumbnail extends StatelessWidget {
  const _Thumbnail({required this.item});

  final MediaItem item;

  // Scaled-down movie/show card — same 2:3 poster proportions as the
  // mini player's own casting artwork (MiniPlayer's `_Artwork`) and the
  // card grids elsewhere in the app, rather than a squared-off crop of
  // whatever image happened to be on the item.
  static const double _posterHeight = 56;
  static const double _posterWidth = _posterHeight * 2 / 3;

  @override
  Widget build(BuildContext context) {
    // Live channels never have a poster-shaped Primary image the way a
    // movie/episode does — their own logo (see MediaService
    // .mediaItemFromJellyfin's `logo` field, which reads the channel's
    // Primary image specifically for this) is the closest thing to
    // "artwork" a channel has. Per the mini player's own established
    // treatment, that logo sits directly on this panel's background —
    // no rounded card, no grey fallback fill behind it — rendered with
    // BoxFit.contain instead of the cropped/carded treatment below.
    if (item.live) {
      final logo = item.logo;
      if (logo == null || logo.isEmpty) {
        return const SizedBox(
          width: 56,
          height: 56,
          child: Icon(Icons.live_tv_rounded, color: Colors.white70),
        );
      }
      return SizedBox(
        width: 56,
        height: 56,
        child: isRemoteArtwork(logo)
            ? Image.network(
                logo,
                fit: BoxFit.contain,
                errorBuilder: (_, __, ___) => const Icon(
                  Icons.live_tv_rounded,
                  color: Colors.white70,
                ),
              )
            : Image.file(
                File(logo),
                fit: BoxFit.contain,
                errorBuilder: (_, __, ___) => const Icon(
                  Icons.live_tv_rounded,
                  color: Colors.white70,
                ),
              ),
      );
    }

    // CASTING FIX (music showed a stretched/cropped movie poster): a
    // song has no 2:3 poster art the way a movie/episode does — its
    // artwork is square. This used to fall straight through to the
    // poster branch below, which forced `item.image` (the square album
    // cover) into the same `_posterWidth x _posterHeight` (2:3) frame,
    // visibly distorting it. Square, rounded-corner treatment instead —
    // same radius and footprint as MiniPlayer's own local-audio artwork
    // (`_buildBar`'s Hero-tagged image), so this panel's music thumbnail
    // matches what the rest of the app already shows for a song.
    if (item.audioOnly) {
      final artwork = item.image;
      Widget placeholder() => Container(
            width: _posterHeight,
            height: _posterHeight,
            color: Colors.grey.shade800,
            child: const Icon(Icons.music_note, color: Colors.white),
          );

      return ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: artwork == null
            ? placeholder()
            : (isRemoteArtwork(artwork)
                ? Image.network(
                    artwork,
                    width: _posterHeight,
                    height: _posterHeight,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => placeholder(),
                  )
                : Image.file(
                    File(artwork),
                    width: _posterHeight,
                    height: _posterHeight,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => placeholder(),
                  )),
      );
    }

    final isEpisode = item.seasonNumber != null || item.episodeNumber != null;
    final fallbackIcon = isEpisode ? Icons.tv_rounded : Icons.movie_rounded;

    // Episodes: the show's own poster (MediaItem.seriesImage — the
    // parent series' Primary image), not the episode's own wide
    // thumbnail frame — same reasoning as MiniPlayer's `_Artwork`.
    // Falls back to the episode thumbnail if the series poster wasn't
    // resolved, and movies just use their own poster as always.
    final artwork = isEpisode ? (item.seriesImage ?? item.image) : item.image;

    Widget placeholder() => Container(
          width: _posterWidth,
          height: _posterHeight,
          color: Colors.grey.shade800,
          child: Icon(fallbackIcon, color: Colors.white),
        );

    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: artwork == null
          ? placeholder()
          : (isRemoteArtwork(artwork)
              ? Image.network(
                  artwork,
                  width: _posterWidth,
                  height: _posterHeight,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => placeholder(),
                )
              : Image.file(
                  File(artwork),
                  width: _posterWidth,
                  height: _posterHeight,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => placeholder(),
                )),
    );
  }
}

class _InfoColumn extends StatelessWidget {
  const _InfoColumn({required this.item, required this.session});

  final MediaItem item;
  final CastSession session;

  @override
  Widget build(BuildContext context) {
    final isEpisode = item.seasonNumber != null || item.episodeNumber != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (item.live)
          _LiveChannelLines(item: item)
        else if (isEpisode)
          _EpisodeLines(item: item)
        else
          Text(
            item.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: 15,
            ),
          ),

        const SizedBox(height: 4),

        // The casting indicator kept from the old panel: a small cast
        // icon plus the connected device's name, in castGold — the same
        // "Playing on X" treatment MiniPlayer already uses for local
        // playback that's been handed off.
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              castTransportIcon(session.transportKind),
              size: 13,
              color: castGold,
            ),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                'Casting to ${session.device.displayName}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: castGold, fontSize: 12),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _EpisodeLines extends StatelessWidget {
  const _EpisodeLines({required this.item});

  final MediaItem item;

  @override
  Widget build(BuildContext context) {
    final season = item.seasonNumber;
    final episode = item.episodeNumber;

    // Show name and episode name share one line (separated by " · ")
    // rather than each getting their own — at this card's width, two
    // full-size text lines for a long show title AND a long episode
    // title would routinely truncate one or both to near-uselessness.
    // `item.subtitle` is the show name here (MediaService
    // .mediaItemFromJellyfin sets it from SeriesName for episodes);
    // `item.title` is the episode's own name.
    final combined = item.subtitle.isNotEmpty
        ? '${item.subtitle} · ${item.title}'
        : item.title;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (season != null || episode != null)
          Text(
            [
              if (season != null) 'Season $season',
              if (episode != null) 'Episode $episode',
            ].join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white54, fontSize: 11),
          ),
        Text(
          combined,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 15,
          ),
        ),
      ],
    );
  }
}

/// Channel name + the currently-airing program's name/duration, fetched
/// fresh whenever the casted channel changes. Mirrors the in-player Info
/// sheet's own `_loadCurrentProgram` pattern (same endpoint, same
/// `EpgUtils` picks/formatting) rather than inventing a second way to
/// compute "what's on now" for a channel that could drift out of sync
/// with what that sheet shows for the same channel.
class _LiveChannelLines extends StatefulWidget {
  const _LiveChannelLines({required this.item});

  final MediaItem item;

  @override
  State<_LiveChannelLines> createState() => _LiveChannelLinesState();
}

class _LiveChannelLinesState extends State<_LiveChannelLines> {
  Map<String, dynamic>? _currentProgram;

  @override
  void initState() {
    super.initState();
    _loadCurrentProgram();
  }

  @override
  void didUpdateWidget(covariant _LiveChannelLines oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.id != widget.item.id) {
      _currentProgram = null;
      _loadCurrentProgram();
    }
  }

  Future<void> _loadCurrentProgram() async {
    try {
      final programs = await MediaService.getPrograms(
        channelId: widget.item.id,
      );
      final picked = EpgUtils.pickCurrentProgram(programs);
      if (!mounted) return;
      setState(() => _currentProgram = picked);
    } catch (_) {
      // Best-effort, same as the Info sheet's own fetch — a failed guide
      // lookup just means no program subtitle, not a broken card.
    }
  }

  String? get _programLine {
    final program = _currentProgram;
    if (program == null) return null;

    final name = program['Name']?.toString();
    final duration = EpgUtils.formatDuration(
      program['StartDate'],
      program['EndDate'],
    );

    if (name == null || name.isEmpty) return null;
    return duration.isNotEmpty ? '$name · $duration' : name;
  }

  @override
  Widget build(BuildContext context) {
    final programLine = _programLine;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          widget.item.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 15,
          ),
        ),
        if (programLine != null)
          Text(
            programLine,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white54, fontSize: 11),
          ),
      ],
    );
  }
}
