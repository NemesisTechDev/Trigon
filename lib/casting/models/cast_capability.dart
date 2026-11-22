/// What a specific transport on a specific device can actually do.
///
/// Every flag defaults to false ([CastCapability.none]) — a transport must
/// explicitly report support after inspecting the real target (Jellyfin's
/// `SupportedCommands`, the Cast SDK's loaded-media track list, Nemesis
/// Native's own fixed feature set) rather than the UI assuming a command
/// will work. Per the casting master prompt: "Only expose controls that
/// the target actually supports" / "Never present controls that cannot
/// work."
class CastCapability {
  final bool play;
  final bool pause;
  final bool stop;
  final bool seek;
  final bool next;
  final bool previous;
  final bool volume;
  final bool audioTrackSelection;
  final bool subtitleTrackSelection;
  final bool queue;

  /// Casting Phase 12 — shuffle/repeat-mode control over the connected
  /// session's queue, surfaced by the audio transport row's shuffle/
  /// repeat buttons (see `CastTransportControls`). Separate flags (not
  /// folded into [queue]) because a transport can support `next`/
  /// `previous` over a loaded queue without necessarily exposing
  /// shuffle/repeat toggles for it, or vice versa.
  final bool shuffle;
  final bool repeat;

  /// Playback-speed control over the connected session, surfaced by the
  /// video player's Speed button/`PlaybackSpeedSheet` while casting.
  ///
  /// `GoogleCastTransport` sets this `true`: `flutter_chrome_cast`'s
  /// `GoogleCastRemoteMediaClient.setPlaybackRate()` is a real API. DLNA
  /// renderers have no rate control, so `DlnaTransport` reports `false`.
  final bool playbackRate;

  const CastCapability({
    this.play = false,
    this.pause = false,
    this.stop = false,
    this.seek = false,
    this.next = false,
    this.previous = false,
    this.volume = false,
    this.audioTrackSelection = false,
    this.subtitleTrackSelection = false,
    this.queue = false,
    this.shuffle = false,
    this.repeat = false,
    this.playbackRate = false,
  });

  /// Safe default for a device/transport whose capabilities haven't been
  /// determined yet (e.g. mid-discovery, before a session is connected).
  static const CastCapability none = CastCapability();

  /// Used by GoogleCastTransport.load() to flip [subtitleTrackSelection]
  /// (and, once a queue is loaded, [queue]/[next]/[previous]) on or off
  /// per loaded item without hand-rebuilding every other flag — see
  /// CastSession.capabilityNotifier's doc comment for why Google Cast is
  /// the one transport whose real capability changes after `load()`.
  CastCapability copyWith({
    bool? play,
    bool? pause,
    bool? stop,
    bool? seek,
    bool? next,
    bool? previous,
    bool? volume,
    bool? audioTrackSelection,
    bool? subtitleTrackSelection,
    bool? queue,
    bool? shuffle,
    bool? repeat,
    bool? playbackRate,
  }) {
    return CastCapability(
      play: play ?? this.play,
      pause: pause ?? this.pause,
      stop: stop ?? this.stop,
      seek: seek ?? this.seek,
      next: next ?? this.next,
      previous: previous ?? this.previous,
      volume: volume ?? this.volume,
      audioTrackSelection: audioTrackSelection ?? this.audioTrackSelection,
      subtitleTrackSelection:
          subtitleTrackSelection ?? this.subtitleTrackSelection,
      queue: queue ?? this.queue,
      shuffle: shuffle ?? this.shuffle,
      repeat: repeat ?? this.repeat,
      playbackRate: playbackRate ?? this.playbackRate,
    );
  }

  /// Nemesis Native's TV app is built by us on both ends, so — once that
  /// project exists — it's expected to support everything. Kept separate
  /// from [none] so NemesisNativeTransport has an explicit, named starting
  /// point rather than every flag being turned on ad hoc at each call
  /// site.
  static const CastCapability full = CastCapability(
    play: true,
    pause: true,
    stop: true,
    seek: true,
    next: true,
    previous: true,
    volume: true,
    audioTrackSelection: true,
    subtitleTrackSelection: true,
    queue: true,
    shuffle: true,
    repeat: true,
    playbackRate: true,
  );

  @override
  String toString() {
    final supported = <String>[
      if (play) 'play',
      if (pause) 'pause',
      if (stop) 'stop',
      if (seek) 'seek',
      if (next) 'next',
      if (previous) 'previous',
      if (volume) 'volume',
      if (audioTrackSelection) 'audioTrackSelection',
      if (subtitleTrackSelection) 'subtitleTrackSelection',
      if (queue) 'queue',
      if (shuffle) 'shuffle',
      if (repeat) 'repeat',
      if (playbackRate) 'playbackRate',
    ];
    return 'CastCapability(${supported.join(', ')})';
  }
}
