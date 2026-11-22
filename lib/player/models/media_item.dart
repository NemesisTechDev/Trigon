import 'skip_segment.dart';

class MediaItem {
  final String id;
  final String title;
  final String subtitle;
  final String streamUrl;

  /// The network-fetchable Jellyfin stream URL for this item, when one
  /// exists — kept separate from [streamUrl] because [streamUrl] is
  /// sometimes overridden to a local, on-device path for local playback
  /// speed/offline support (see DownloadManager.mediaItemFor, which
  /// points [streamUrl] at the downloaded file on disk while this field
  /// still carries the original `getAudioStreamUrl`/`getPlaybackUrl`
  /// the item would have used if it weren't downloaded). Cast transports
  /// (Google Cast, Nemesis Native — anything that hands a URL to a
  /// *different* device to fetch) need a URL that device can actually
  /// reach over the network; a local file path/content URI only ever
  /// resolves on this phone. Null when [streamUrl] is already
  /// network-fetchable on its own (the normal, non-downloaded case) or
  /// when this item has no server-side presence at all (see [isLocal]).
  final String? remoteStreamUrl;

  /// The URL a cast transport should actually load, or null if this item
  /// has no network-reachable source at all (a purely local, non-Jellyfin
  /// file — see [isLocal] — that was never downloaded from a server).
  /// Prefers [remoteStreamUrl] when set (the downloaded-item case);
  /// otherwise falls back to [streamUrl] itself, but only if it actually
  /// looks like an http(s) URL a receiver on the local network could
  /// fetch — a bare local file path/content:// URI never qualifies.
  String? get castStreamUrl {
    final remote = remoteStreamUrl;
    if (remote != null && remote.isNotEmpty) return remote;
    final uri = Uri.tryParse(streamUrl);
    if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
      return streamUrl;
    }
    return null;
  }

  final String? image;
  final String? backdrop;
  final String? logo;

  /// The parent series' own Primary (poster-shaped) image — only
  /// populated for episodes. Episodes' own `image` above is the
  /// *episode* thumbnail (a wide, backdrop-shaped Jellyfin "Primary"
  /// image for most shows), which reads as a squashed/oddly-cropped
  /// square when forced into a poster-shaped card. Cards that want the
  /// show's own poster — e.g. the video-casting mini player, which
  /// shows a movie/show poster rather than an episode-frame thumbnail
  /// for everything else it displays — should prefer this over [image]
  /// whenever it's set.
  final String? seriesImage;

  /// Only populated for episodes — the parent series/season ids, used to
  /// look up the show's other seasons (e.g. for the in-player episode
  /// list's season selector).
  final String? seriesId;
  final String? seasonId;

  /// Only populated for episodes (Jellyfin's ParentIndexNumber /
  /// IndexNumber) — used to render "S02E06"-style codes, e.g. on the
  /// in-player Next Episode card.
  final int? seasonNumber;
  final int? episodeNumber;

  final Duration? playbackPosition;
  final Duration resumePosition;
  final Duration runtime;

  /// Whether Jellyfin considers this item fully watched
  /// (UserData.Played). Used to show the "watched" checkmark badge
  /// on episode thumbnails.
  final bool played;

  final List<dynamic>? mediaStreams;
  final List<dynamic>? mediaSources;

  /// Raw Jellyfin `Trickplay` dictionary from the item response, keyed
  /// by MediaSourceId -> width -> { Width, Height, TileWidth, TileHeight,
  /// ThumbnailCount, Interval, Bandwidth }. Null/empty when the server
  /// hasn't generated trickplay tiles for this item (or the item was
  /// fetched from an endpoint that doesn't request the `Trickplay`
  /// field). See TrickplayService for how this gets turned into actual
  /// scrub-preview image URLs.
  final Map<String, dynamic>? trickplay;

  final List<SkipSegment> skipSegments;

  final bool live;
  final bool audioOnly;

  /// The actual performing artist — deliberately separate from
  /// [subtitle], which prioritizes AlbumArtist/Album/SeriesName for
  /// display and can legitimately resolve to an album title rather
  /// than an artist. Anything that needs a real artist name for
  /// matching (LRCLIB lookups) should use this instead of [subtitle].
  final String artistName;

  /// The original, unmodified Jellyfin JSON this item was built from
  /// (when available). Kept around so screens that only hold a
  /// [MediaItem] — the audio player's Now Playing screen, in
  /// particular — can still open the same three-dot options sheet
  /// (add to playlist, add to queue, download, go to album/artist)
  /// that song rows use, since that sheet operates on the raw
  /// Jellyfin map rather than this typed model. Null for items that
  /// weren't built from a Jellyfin response.
  final Map<String, dynamic>? raw;

  /// True for songs built from on-device files via LocalMusicService
  /// rather than a Jellyfin item — lets shared code (PlayerManager
  /// favorites, the song options sheet, artwork rendering) branch
  /// without a second parameter threaded everywhere `MediaItem` is
  /// already passed around.
  bool get isLocal => raw?['IsLocal'] == true;

  const MediaItem({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.streamUrl,
    this.remoteStreamUrl,
    this.image,
    this.backdrop,
    this.logo,
    this.seriesImage,
    this.seriesId,
    this.seasonId,
    this.seasonNumber,
    this.episodeNumber,
    this.live = false,
    this.audioOnly = false,
    this.playbackPosition,
    this.resumePosition = Duration.zero,
    this.runtime = Duration.zero,
    this.played = false,
    this.mediaStreams,
    this.mediaSources,
    this.trickplay,
    this.artistName = '',
    this.raw,

    this.skipSegments = const [],
  });

  /// Used to graft freshly-fetched real skip segments — or, now, a
  /// freshly-fetched MediaStreams/MediaSources/Trickplay trio (see
  /// PlayerManager._augmentWithPlaybackFields) — onto the already-
  /// playing item without disturbing anything else about it —
  /// MediaItem's fields are all `final`, so this is the only way to
  /// update just these pieces of state after playback has already
  /// started.
  /// Added for Casting Phase 8's REMOTE → LOCAL handoff: when a cast
  /// session disconnects and the person chooses to resume on this device
  /// (see PlaybackCoordinator), the TV's last-reported position has to
  /// travel with the item into a fresh `PlayerManager.playMedia()` call —
  /// but MediaItem's fields are all `final`, so, like every other field
  /// this class needs to override post-construction, that means adding it
  /// here rather than mutating the original. `playbackPosition` (not
  /// `resumePosition`) is deliberately what's overridable: it's the field
  /// `playMedia()` actually seeks to on open (see its resume-seek block),
  /// while `resumePosition` is only ever used for display (e.g. a "12m
  /// left" badge) — see the doc comments on both fields above.
  /// LOCAL CASTING: lets [CastManager] graft a freshly-started
  /// [LocalCastServer] URL onto a local item (see [MediaItem.isLocal])
  /// right before handing it to a transport, the exact same "override
  /// just this one field without disturbing anything else" pattern
  /// [playbackPosition] already uses here — [remoteStreamUrl] is `final`
  /// like every other field, so this is the only way to set it after
  /// construction. Left out of every other call site's `copyWith` calls
  /// (mediaStreams/trickplay backfills, resume-position handoffs), which
  /// have no reason to touch it.
  ///
  /// CASTING FIX (no artwork/poster on the TV for a local song/video):
  /// [image]/[backdrop] join [remoteStreamUrl] here for the exact same
  /// reason — [CastManager._ensureCastableLocalItem] now also registers a
  /// local item's cached artwork/video-frame file with [LocalCastServer]
  /// (the same server that already makes the media itself network-
  /// fetchable) and needs to graft the resulting http(s) URL onto the item
  /// afterward, in place of the on-disk path nothing but this app's own
  /// UI could ever load. Every other call site's `copyWith` call leaves
  /// these two null, which — same as `remoteStreamUrl` above — falls
  /// through to `this.image`/`this.backdrop` and changes nothing.
  MediaItem copyWith({
    List<SkipSegment>? skipSegments,
    List<dynamic>? mediaStreams,
    List<dynamic>? mediaSources,
    Map<String, dynamic>? trickplay,
    Duration? playbackPosition,
    String? remoteStreamUrl,
    String? image,
    String? backdrop,
    String? logo,
    bool? played,
    bool clearRemoteStreamUrl = false,
  }) {
    return MediaItem(
      id: id,
      title: title,
      subtitle: subtitle,
      streamUrl: streamUrl,
      remoteStreamUrl: clearRemoteStreamUrl
          ? remoteStreamUrl
          : (remoteStreamUrl ?? this.remoteStreamUrl),
      image: image ?? this.image,
      backdrop: backdrop ?? this.backdrop,
      logo: logo ?? this.logo,
      seriesImage: seriesImage,
      seriesId: seriesId,
      seasonId: seasonId,
      seasonNumber: seasonNumber,
      episodeNumber: episodeNumber,
      live: live,
      audioOnly: audioOnly,
      playbackPosition: playbackPosition ?? this.playbackPosition,
      resumePosition: resumePosition,
      runtime: runtime,
      played: played ?? this.played,
      mediaStreams: mediaStreams ?? this.mediaStreams,
      mediaSources: mediaSources ?? this.mediaSources,
      trickplay: trickplay ?? this.trickplay,
      artistName: artistName,
      raw: raw,
      skipSegments: skipSegments ?? this.skipSegments,
    );
  }
}