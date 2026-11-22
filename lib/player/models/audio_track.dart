class AudioTrack {
  /// The absolute stream index as reported by Jellyfin's `MediaStreams`
  /// (i.e. this track's identity on the server).
  final int index;
  final String language;
  final String displayTitle;
  final bool isDefault;

  /// The id media_kit/mpv uses for this same track on the currently
  /// playing file, so selecting this track can actually call
  /// `Player.setAudioTrack`. This is resolved positionally against the
  /// player's own reported tracks (see `PlayerManager._syncTracks`) and
  /// falls back to `index.toString()` when no matching native track was
  /// found yet.
  final String nativeId;

  const AudioTrack({
    required this.index,
    required this.language,
    required this.displayTitle,
    required this.isDefault,
    required this.nativeId,
  });

  @override
  bool operator ==(Object other) =>
      other is AudioTrack && other.index == index;

  @override
  int get hashCode => index.hashCode;
}