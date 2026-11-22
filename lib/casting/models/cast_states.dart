/// Which underlying protocol a [CastSession]/[CastDevice] entry uses.
/// Deliberately never surfaced to the person casting — CastManager and its
/// UI consumers (PlayerTopBar's Cast button, the device picker, etc.) are
/// the only things that ever branch on this; the person just sees device
/// names, per the Nemesis Casting master prompt's "the user should not
/// need to understand the underlying protocols" goal.
enum CastTransportKind {
  /// Chromecast / Google TV / other Google Cast receivers.
  googleCast,

  /// Any UPnP/DLNA "MediaRenderer" — LG webOS, Samsung Tizen, Sony,
  /// Philips, Hisense, Roku, set-top boxes, network speakers, and the
  /// Trigon TV receiver app (which is a UPnP/DLNA renderer too; see
  /// `CastDevice.isNemesisReceiver`). These have no Cast receiver app:
  /// the phone hands them a plain HTTP URL (via SOAP `SetAVTransportURI`)
  /// and polls their state. See `DlnaTransport`.
  dlna,
}

/// Capabilities shared by the two transports that hand the TV a bare
/// media URL and therefore have to *reload* the item to change anything
/// about it (audio track, subtitle track), rather than sending a live
/// "switch track" command.
extension CastTransportKindMediaHandoff on CastTransportKind {
  /// True when audio/subtitle changes are done by re-loading the item at
  /// the current position (with the `CastAudioStreamOverride` /
  /// `CastActiveSubtitleId` / `CastLocalSubtitles` / `CastSidecarSubtitleUrl`
  /// hints on `MediaItem.raw`), and when this phone can serve local files
  /// to the TV itself through `LocalCastServer`.
  bool get switchesTracksByReload =>
      this == CastTransportKind.googleCast || this == CastTransportKind.dlna;
}

/// Whether we're connected to a cast target at all. Deliberately separate
/// from [CastPlaybackState] below — "is a device connected" and "what's
/// currently playing on it" are different questions, and conflating them
/// (as a single combined enum would) makes it hard to tell "connected but
/// nothing loaded yet" apart from "in the middle of loading something".
enum CastConnectionState {
  disconnected,
  discovering,
  connecting,
  connected,
  error,
}

/// What the active [CastSession] is doing, once connected. Mirrors mpv's
/// own local playback states closely on purpose, so a future PlayerManager
/// integration (Phase 8) has an easy mental mapping between LOCAL and
/// REMOTE playback state.
enum CastPlaybackState {
  idle,
  loading,
  playing,
  paused,
  buffering,
  stopped,
  ended,
  error,
}

/// Receiver-side lifecycle for a future Nemesis Native TV app (Phase 6).
/// Not used by CastManager directly today — CastManager only ever sees a
/// NemesisNativeTransport's session through the shared
/// CastConnectionState/CastPlaybackState pair above, same as the other two
/// transports. This exists so the TV-side protocol design has a named,
/// stable state machine to implement against once that project starts,
/// without CastManager itself needing to know about it.
enum NemesisReceiverState {
  idle,
  ready,
  connecting,
  connected,
  loading,
  playing,
  paused,
  buffering,
  stopped,
  ended,
  error,
}

/// SEEK-RESTART FIX (root cause, replacing the old timing-heuristic-only
/// approach): why a [CastSession] landed on an "idle"-ish [CastPlaybackState]
/// (`idle`/`stopped`/`ended`), when the transport actually knows. Mirrors
/// the Google Cast SDK's own `GoogleCastMediaIdleReason` one-for-one
/// (`none`/`finished`/`cancelled`/`interrupted`/`error`) rather than
/// reusing that package's enum directly, matching this layer's "nothing
/// here imports a concrete transport's types" rule — the Cast SDK already
/// hands this exact distinction back on every status push specifically so
/// callers don't have to *guess* "did it end, or did we just interrupt it
/// ourselves with a seek/stop/new load?" from state-name transitions and
/// timing alone, which is what [PlaybackCoordinator]'s auto-advance logic
/// used to do (see its own doc comments) and which was the actual source
/// of "seeking a casted song restarts it" — a seek's own transient
/// buffering dip could still race past the old `isSeekPending` timing
/// guard, read as a spontaneous "track ended", and trigger a reload from
/// position 0. `interrupted`/`cancelled` are exactly the reasons a seek,
/// a stop, or a fresh load produces on their own, on purpose — those
/// should never be treated as "the song ended" no matter how the timing
/// lines up. Only [finished] means "the receiver genuinely ran out of
/// content to play". JellyfinRemoteTransport/NemesisNativeTransport have
/// no equivalent authoritative signal, so their sessions simply never set
/// this (stays `null`), and [PlaybackCoordinator] falls back to the old
/// `isSeekPending`-timing heuristic only when it's `null` — Google Cast is
/// the only transport that gets the strictly more reliable path.
enum CastIdleReason {
  /// No reason reported, or a transport that doesn't know how to report
  /// one — treated as "unknown", not as "finished".
  none,

  /// The media actually played to the end on its own.
  finished,

  /// A sender (this app) issued an explicit STOP.
  cancelled,

  /// A sender (this app) issued a LOAD/seek-driven reload while something
  /// else was already playing — Google Cast's own term for exactly the
  /// "we did this to ourselves" case a seek's transient re-buffer produces.
  interrupted,

  /// Playback stopped because of a genuine error (network drop, unplayable
  /// format, etc.) rather than reaching the end normally.
  error,
}

/// Mirrors PlaybackQueue's local `QueueRepeatMode` (see
/// `player/services/playback_queue.dart`) for a [CastSession] — kept as a
/// distinct enum rather than reusing that one directly, matching the rest
/// of the casting layer's rule that nothing here imports local-playback
/// types. `all`/`one` map straight onto Jellyfin's own `RepeatAll`/
/// `RepeatOne` remote-control values (see
/// `CastCapability.fromJellyfinSession` and
/// `JellyfinRemoteTransport.setRepeatMode`).
enum CastRepeatMode {
  off,
  all,
  one,
}
