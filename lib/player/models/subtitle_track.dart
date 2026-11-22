class SubtitleTrack {
  /// The absolute stream index as reported by Jellyfin's `MediaStreams`.
  final int index;
  final String language;
  final String displayTitle;
  final bool isDefault;
  final bool isForced;

  /// The id media_kit/mpv uses for this same track — see
  /// `AudioTrack.nativeId` for why this exists. Only meaningful when
  /// [isExternal] is false: mpv only demuxes tracks that are actually
  /// muxed into the file it opened, so an external subtitle never gets
  /// a real native id and this stays as the placeholder Jellyfin index.
  final String nativeId;

  /// True when Jellyfin serves this subtitle as a separate sidecar file
  /// (its own `IsExternal` flag) rather than a track embedded in the
  /// video container. Common for subtitles added after the fact, or in
  /// formats Jellyfin won't remux — these never show up in mpv's own
  /// demuxed track list, so they can't be selected by [nativeId] at
  /// all; they have to be loaded directly by URL instead.
  final bool isExternal;

  /// A directly-fetchable URL for this subtitle, when one is available —
  /// server host + api key in front of either:
  ///  - Jellyfin's own `DeliveryUrl` for genuinely external sidecar files, or
  ///  - a manually-built `/Subtitles/{index}/Stream.vtt` extraction URL for
  ///    an *embedded* text-based track (see `MediaStreamParser.subtitles`).
  /// Jellyfin can convert any embedded text subtitle (srt/ass/ssa/mov_text/
  /// etc.) to vtt on the fly through that same endpoint it uses for
  /// external ones — so whenever this is non-null, [PlayerManager]
  /// prefers loading it by URL over matching a native mpv track id, since
  /// that positional match is the fragile part that was leaving tracks
  /// showing "selected" with nothing actually rendering. Null for
  /// image-based embedded tracks (PGS/VobSub) Jellyfin can't convert to
  /// text, which still fall back to native id selection.
  final String? externalUrl;

  /// Raw subtitle text (SRT/VTT/etc.) for tracks that were never a URL
  /// to begin with — currently only OpenSubtitles downloads, which
  /// arrive as an in-memory string from the API. When set,
  /// [PlayerManager.selectSubtitleTrack] hands this straight to mpv via
  /// `SubtitleTrack.data()` instead of writing it to a temp file and
  /// loading it back by path/URI — skipping local file I/O (and the
  /// sandboxed-storage/URI-parsing quirks that come with it) entirely.
  final String? subtitleData;

  /// Absolute path to a subtitle sidecar file already sitting on this
  /// device — a downloaded movie/episode's own subtitle sidecar (see
  /// DownloadManager's own doc comments on `subtitlePaths`), read
  /// straight off disk at selection time with no network involved at
  /// all. Distinct from [subtitleData] (already-in-memory text, e.g. an
  /// OpenSubtitles download) purely so [PlayerManager.selectSubtitleTrack]
  /// knows whether the content still needs a file read first.
  final String? localPath;

  const SubtitleTrack({
    required this.index,
    required this.language,
    required this.displayTitle,
    required this.isDefault,
    required this.isForced,
    required this.nativeId,
    this.isExternal = false,
    this.externalUrl,
    this.subtitleData,
    this.localPath,
  });

  @override
  bool operator ==(Object other) =>
      other is SubtitleTrack && other.index == index;

  @override
  int get hashCode => index.hashCode;
}