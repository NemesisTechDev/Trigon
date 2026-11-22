import '../../player/models/media_item.dart';
import '../models/cast_device.dart';
import '../models/cast_session.dart';
import '../models/cast_states.dart';

/// The seam every real casting protocol (Jellyfin Remote Session, Google
/// Cast, Nemesis Native) implements. CastManager is the only thing that
/// ever calls a CastTransport directly — no UI widget or screen imports
/// this file, per the casting master prompt's "UI must not directly
/// depend on Google Cast APIs / Jellyfin remote session APIs / Nemesis
/// socket APIs" architecture rule.
///
/// No implementation exists yet as of Phase 3 — JellyfinRemoteTransport,
/// GoogleCastTransport, and NemesisNativeTransport are Phases 4, 5, and 6
/// respectively. This interface exists now so CastManager's discovery/
/// connection plumbing has a real (if currently unimplemented) contract
/// to hold a `List<CastTransport>` of, rather than being written against
/// an assumed shape that then has to change once a real transport lands.
abstract class CastTransport {
  CastTransportKind get kind;

  /// Starts discovery, emitting the current best-known list of devices
  /// reachable through this transport every time it changes. CastManager
  /// is responsible for the ref-counted acquire()/release() lifecycle
  /// (see CastManager doc comments) — a transport's discover() is only
  /// ever called while at least one thing (typically the device-picker
  /// sheet) actually needs it, matching the master prompt's "avoid
  /// constant network scanning / excessive polling / battery-heavy
  /// discovery" performance rule.
  Stream<List<CastDevice>> discover();

  /// Stops discovery and releases whatever resources it was holding
  /// (platform-channel listeners, mDNS browser, HTTP polling timer, etc).
  /// Must be safe to call even if discover() was never started.
  Future<void> stopDiscovery();

  /// Establishes a session with [device] over this transport. Throws (or
  /// completes the returned session's connectionState with `.error`) on
  /// failure rather than returning null — CastManager surfaces that via
  /// CastSession.lastError.
  Future<CastSession> connect(CastDevice device);

  Future<void> disconnect(CastSession session);

  /// Loads [item] and begins playback at [startAt] (defaults to the
  /// beginning, or the item's own resume position where the transport
  /// supports resuming — see MediaItem.resumePosition). Updates
  /// [session].playbackState/currentItem as loading progresses.
  Future<void> load(
    CastSession session,
    MediaItem item, {
    Duration startAt = Duration.zero,
  });

  Future<void> play(CastSession session);
  Future<void> pause(CastSession session);
  Future<void> stop(CastSession session);
  Future<void> seek(CastSession session, Duration position);
  Future<void> setVolume(CastSession session, double volume);
  Future<void> selectAudioTrack(CastSession session, int trackId);
  Future<void> selectSubtitleTrack(CastSession session, int trackId);
  Future<void> next(CastSession session);
  Future<void> previous(CastSession session);

  /// Casting Phase 12 — queue shuffle/repeat, gated on
  /// `session.capability.shuffle`/`.repeat` exactly like every other
  /// command here. A transport with no real shuffle/repeat concept
  /// (Google Cast, in this app today — see that file's own doc comment)
  /// should leave its capability flag false and throw
  /// [UnsupportedCastCommand] here, the same defensive backstop as
  /// [selectAudioTrack] on that transport.
  Future<void> setShuffle(CastSession session, bool enabled);
  Future<void> setRepeatMode(CastSession session, CastRepeatMode mode);

  /// Casting playback-rate fix, gated on `session.capability
  /// .playbackRate` exactly like every other command here. Per
  /// `CastCapability.playbackRate`'s own doc comment, Jellyfin Remote
  /// genuinely has no protocol support for this and should always throw
  /// [UnsupportedCastCommand] (its capability flag is permanently
  /// false, so this should be unreachable through the UI in normal use,
  /// same defensive backstop as every other capability-gated method).
  Future<void> setPlaybackRate(CastSession session, double rate);

  /// Loads a multi-item queue and begins playback at [startIndex] (an
  /// index into [items], not a track id), resuming at [startAt] within
  /// that starting item. The single-item [load] above stays the only
  /// path `CastManager.loadAndPlay()` uses — this is [CastManager
  /// .playQueue]'s pass-through, gated on `session.capability.queue`
  /// exactly like every other capability-gated command in this
  /// interface. A transport with no real multi-item queue concept
  /// should throw [UnsupportedCastCommand] rather than looping [load]
  /// itself, so CastManager's capability gate stays the single source
  /// of truth for whether this actually does anything.
  Future<void> loadQueue(
    CastSession session,
    List<MediaItem> items, {
    int startIndex = 0,
    Duration startAt = Duration.zero,
  });
}

/// Thrown by a CastTransport method when the session's CastCapability
/// says the requested operation isn't supported by the connected target.
/// CastManager catches this at the call boundary so a UI bug that
/// somehow calls e.g. seek() on a non-seekable session fails loudly in
/// debug rather than silently doing nothing — controls that can't work
/// are expected to already be hidden by the UI layer (per the master
/// prompt's "never present controls that cannot work" rule), so this
/// should never actually fire in normal use.
class UnsupportedCastCommand implements Exception {
  final String command;
  final CastTransportKind transport;

  const UnsupportedCastCommand(this.command, this.transport);

  @override
  String toString() =>
      'UnsupportedCastCommand: "$command" is not supported by $transport';
}
