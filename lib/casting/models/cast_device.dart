import 'cast_capability.dart';
import 'cast_states.dart';

/// The priority order CastDevice.preferredTransport falls back to when the
/// person hasn't picked a specific transport for this device before:
/// Google Cast first, then DLNA/UPnP.
const List<CastTransportKind> kDefaultTransportPriority = [
  CastTransportKind.googleCast,
  CastTransportKind.dlna,
];

/// One target the person can cast to, as shown in the device picker.
///
/// A single physical TV reachable multiple ways (e.g. a Nemesis Native TV
/// that's also a Chromecast built-in device) is represented as ONE
/// CastDevice with multiple entries in [transports] — never as separate
/// picker rows — per the master prompt's "intelligently represent
/// multiple transports on one device rather than creating confusing
/// duplicate devices" rule. CastManager's discovery-merge step (Phase 3
/// implements the data structure; the actual merge heuristic runs once
/// real transports exist in Phases 4-6) is what produces that.
class CastDevice {
  /// Stable composite identity, e.g. "jellyfinRemote:{sessionId}" or
  /// "googleCast:{cast device id}" — namespaced per transport until/unless
  /// a merge (see class doc above) combines two entries under one
  /// synthetic id. Used as the key for persisted per-device transport
  /// preference (see [preferredTransportOverride] usage in CastManager).
  final String id;

  final String displayName;

  /// Optional grouping/room hint, when a transport's discovery metadata
  /// provides one (Jellyfin session `DeviceName`/room info, mDNS TXT
  /// records, etc.). Purely cosmetic — never used for identity matching.
  final String? roomOrGroup;

  /// Every transport this device is currently reachable through, and what
  /// each one supports. A device usually has exactly one entry; more than
  /// one only after a successful merge.
  final Map<CastTransportKind, CastCapability> transports;

  /// The person's remembered choice for this device (persisted in
  /// AppSettings, keyed by [id]), if they've ever explicitly picked a
  /// non-default transport for it. Null means "use the default priority
  /// order".
  final CastTransportKind? preferredTransportOverride;

  /// Account name shown on the other end, when a transport can report one.
  /// No transport does any more (the Jellyfin-session transports were
  /// removed), so this is always null; kept so existing UI keeps compiling.
  final String? userName;

  /// True when this is the Trigon TV receiver app, which advertises itself
  /// as a standard UPnP/DLNA MediaRenderer (manufacturer or model contains
  /// "trigon" or "nemesis"). Cosmetic only: it is still driven entirely by
  /// the DLNA transport, but gets a "Trigon TV" label and is listed first.
  final bool isNemesisReceiver;

  const CastDevice({
    required this.id,
    required this.displayName,
    required this.transports,
    this.roomOrGroup,
    this.preferredTransportOverride,
    this.userName,
    this.isNemesisReceiver = false,
  });

  /// The transport CastManager.connect() should use when the person taps
  /// this device's row directly (rather than a specific transport
  /// sub-row) — their explicit override if they have one and it's still
  /// available, otherwise the highest-priority transport this device
  /// actually offers right now.
  CastTransportKind get preferredTransport {
    final override = preferredTransportOverride;
    if (override != null && transports.containsKey(override)) {
      return override;
    }

    for (final kind in kDefaultTransportPriority) {
      if (transports.containsKey(kind)) return kind;
    }

    // Should be unreachable in practice — a CastDevice is never
    // constructed with an empty transports map — but fall back to
    // whatever's there rather than throwing.
    return transports.keys.first;
  }

  CastCapability capabilityFor(CastTransportKind kind) =>
      transports[kind] ?? CastCapability.none;

  CastDevice copyWith({
    String? displayName,
    String? roomOrGroup,
    Map<CastTransportKind, CastCapability>? transports,
    CastTransportKind? preferredTransportOverride,
    String? userName,
    bool? isNemesisReceiver,
  }) {
    return CastDevice(
      id: id,
      displayName: displayName ?? this.displayName,
      roomOrGroup: roomOrGroup ?? this.roomOrGroup,
      transports: transports ?? this.transports,
      preferredTransportOverride:
          preferredTransportOverride ?? this.preferredTransportOverride,
      userName: userName ?? this.userName,
      isNemesisReceiver: isNemesisReceiver ?? this.isNemesisReceiver,
    );
  }

  @override
  bool operator ==(Object other) => other is CastDevice && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() =>
      'CastDevice($displayName, transports: ${transports.keys})';
}
