import 'dart:async';

import 'package:flutter/foundation.dart';

import '../player/models/media_item.dart';
import '../player/models/subtitle_appearance.dart';
import '../player/services/trickplay_service.dart';
import '../services/jellyfin_services/media_service.dart';
import '../utils/artwork_source.dart';
import 'addon_cast_relay.dart';
import 'default_subtitle.dart';
import 'local_cast_format.dart';
import 'local_cast_server.dart';
import 'models/cast_device.dart';
import 'models/cast_session.dart';
import 'models/cast_states.dart';
import 'transports/cast_transport.dart';
import 'transports/closed_caption_capable.dart';
import 'transports/dlna_transport.dart';
import 'transports/google_cast_transport.dart';
import 'transports/subtitle_style_capable.dart';

/// The single class every screen/widget talks to for casting. Mirrors the
/// singleton + ValueNotifier + ref-counted-discovery pattern
/// NetworkQualityService already established in this codebase (see
/// NetworkQualityService.acquire()/release()) — nothing new is being
/// introduced architecturally, just applied to a new domain.
///
/// As of Phase 3, no CastTransport implementations exist yet
/// (JellyfinRemoteTransport/GoogleCastTransport/NemesisNativeTransport are
/// Phases 4-6). [_transports] is therefore always empty, [devices] always
/// resolves to an empty list, and [isCasting] is always false — this file
/// exists to give Phases 4-6 (real transports) and Phase 7 (UI) a stable
/// surface to build against, not to cast anything yet.
///
/// No screen, PlayerTopBar, or MiniPlayer should import anything from
/// casting/transports/ directly — always come through here.
class CastManager {
  CastManager._();

  static final CastManager instance = CastManager._();

  /// LOCAL CASTING PERFORMANCE FIX — see `playQueue()`'s own doc comment
  /// on the delay this exists to close. A deliberately generous superset
  /// of the forward-only window `GoogleCastTransport.loadQueue` actually
  /// ever sends to a receiver (its own private `_maxQueueItems`,
  /// currently 50 tracks starting at `startIndex`) — the only transport
  /// a queue containing a local item can ever reach in the first place,
  /// since both `JellyfinRemoteTransport.loadQueue` and
  /// `NemesisNativeTransport.loadQueue` reject any local item outright
  /// before that window would even matter. Kept as this class's own
  /// constant rather than importing GoogleCastTransport's, so this stays
  /// correct (a safe superset, not an exact mirror that could quietly
  /// fall out of sync) even if that transport's own cap ever changes.
  static const _localQueueResolveWindow = 80;

  /// CAST START DELAY FIX — see `playQueue()`'s own doc comment. How many
  /// items, forward from the tapped one, actually get the network
  /// `_ensureFullMediaItem` backfill before a queue-load is sent. Mirrors
  /// `GoogleCastTransport._maxQueueItems` (50), the only transport that
  /// reads anything beyond id/title from each queued item (container/codec
  /// for its per-item stream URL and subtitle declarations). Jellyfin
  /// Remote and Nemesis Native only ever send ids + basic metadata, so
  /// they only need the tapped item itself.
  static const _googleCastEnrichWindow = 50;

  /// Registered transport implementations, one per CastTransportKind at
  /// most. Real transports register themselves here during their own
  /// initialization (Phases 4-6 add a `CastManager.instance
  /// .registerTransport(...)` call somewhere in main.dart's startup
  /// sequence, the same place PlayerManager/DownloadManager/etc. are
  /// already initialized) — CastManager itself never constructs a
  /// transport.
  final Map<CastTransportKind, CastTransport> _transports = {};

  /// Every device currently known across all registered transports,
  /// already merged (see [_recomputeDevices]) so one physical TV
  /// reachable multiple ways appears as a single entry. Empty whenever
  /// discovery isn't active or no transports are registered.
  final ValueNotifier<List<CastDevice>> devices = ValueNotifier([]);

  /// The current session, or null when nothing is connected. Consumed
  /// directly by PlayerTopBar/MiniPlayer/etc. via ValueListenableBuilder
  /// once Phase 7 wires up the UI.
  final ValueNotifier<CastSession?> activeSession = ValueNotifier(null);

  final Map<CastTransportKind, List<CastDevice>> _devicesByTransport = {};

  /// Set by PlaybackCoordinator: true while the phone is playing/holding a
  /// file that lives only on this device (on-device song, Open With video).
  bool Function()? hasLocalMediaProvider;

  /// PHASE 2 (F2.2 / F1.5): the app's own copy of every local item that was
  /// resolved for casting, by id. Resolving hands the TV a COPY that carries
  /// phone-server URLs (media + cover); those URLs die with the server at
  /// disconnect and must never end up in app state (mini player, the
  /// "resume on this phone" offer, the connect-time handoff).
  /// [appItemFor] maps a resolved copy back to this.
  final Map<String, MediaItem> _localOriginals = {};
  static const int _maxLocalOriginals = 200;

  bool _carriesPhoneUrl(MediaItem item) {
    bool phone(String? u) =>
        u != null && u.isNotEmpty && LocalCastServer.isPhoneServerUrl(u);
    return phone(item.remoteStreamUrl) ||
        phone(item.image) ||
        phone(item.backdrop);
  }

  /// The item the REST OF THE APP should hold for [castItem] (what a cast
  /// session reports as its current item). For a local item that was
  /// resolved for the TV this is the original, with its on-device source
  /// and cover; anything else is returned unchanged.
  MediaItem appItemFor(MediaItem castItem) {
    if (!castItem.isLocal || !_carriesPhoneUrl(castItem)) return castItem;
    return _localOriginals[castItem.id] ?? castItem;
  }
  final Map<CastTransportKind, StreamSubscription<List<CastDevice>>>
      _discoverySubscriptions = {};

  int _discoveryRefCount = 0;

  /// PHASE 10 HARDENING. The listener CastManager itself attaches to the
  /// *current* session's [CastSession.connectionState] so a transport
  /// noticing its target went away (TV powered off, network drop, app
  /// closed on the receiver, pairing revoked) actually finalizes
  /// [activeSession] instead of just mutating a field inside a session
  /// object every UI widget was still holding a stale reference to.
  ///
  /// Every transport (Jellyfin Remote's session-sync timer, Google Cast's
  /// currentSessionStream, Nemesis Native's socket-close handler) already
  /// detected this correctly and flipped `session.connectionState` to
  /// `.disconnected`/`.error` — see each transport's own doc comments.
  /// What none of them did, and what nothing else in this file did
  /// either, was tell *CastManager* the session was over. Every screen
  /// (CastButton, MiniPlayer, CastingActivePanel, the connected-session
  /// sheet) only ever listens to `activeSession` itself, not the nested
  /// notifier inside whatever session it currently holds — the
  /// connected-session sheet's and CastingActivePanel's own doc comments
  /// even already describe the "session disappears out from under this
  /// widget -> it closes/reverts itself" behavior as if it were
  /// implemented, when in fact `activeSession` never actually went null
  /// on its own. In practice: the Cast button stayed gold and "Connected"
  /// forever, the connected-session sheet stayed open showing
  /// "Disconnected" as inert text, and PlaybackCoordinator's REMOTE ->
  /// LOCAL resume offer never fired, because none of that machinery ever
  /// saw `activeSession` change. This map/listener pair is what actually
  /// closes that loop, at the one place (CastManager) every transport and
  /// every screen already agrees is authoritative.
  final Map<CastSession, VoidCallback> _sessionTeardownListeners = {};

  /// SEEK-THUMBNAIL FIX (episodes losing trickplay after the first one):
  /// `_augmentCastItem` was previously only ever called from
  /// `loadAndPlay`/`playQueue`, i.e. only for whichever item a cast
  /// session *starts* on. The moment a session advances past that first
  /// item — a TV show's queue naturally auto-advancing episode to
  /// episode, or an explicit next()/previous() — every transport just
  /// writes the new item straight onto `session.currentItem` itself
  /// (Jellyfin Remote's queue top-up matching the receiver's reported
  /// now-playing id against its own already-built queue array, Nemesis
  /// Native's equivalent, Google Cast's `currentItem` derived from its
  /// session's media-status listener), and none of those items were ever
  /// individually augmented. A movie is a single-item "queue" so this
  /// never showed up there, but a TV show's queue made every episode
  /// after the first silently lose its seek-thumbnail preview.
  ///
  /// Watching `currentItem` itself, here, at the one place every
  /// transport's advance path already funnels through regardless of
  /// *how* it decided to advance, closes that gap for movies and
  /// episodes alike without needing every transport's own advance logic
  /// to remember to call this — `_augmentCastItem` is already a cheap
  /// no-op for items that already carry `mediaStreams` (a movie/episode
  /// cast from a details screen that already fetched the full item), so
  /// this only ever does real work for the cases that need it.
  ///
  /// Largely a defensive backstop now that `loadAndPlay`/`playQueue`
  /// pre-fetch every item's `mediaStreams` before ever handing it to a
  /// transport (see `_ensureFullMediaItem`'s own doc comment) — this
  /// still matters for Google Cast, whose `currentItem` can also be
  /// re-derived straight from the receiver's own media-status reports,
  /// not only from what this app itself sent.
  final Map<CastSession, VoidCallback> _sessionTrickplayListeners = {};

  bool get isCasting =>
      activeSession.value != null &&
      activeSession.value!.connectionState.value ==
          CastConnectionState.connected;

  /// Lets a real transport (Phases 4-6) make itself available. Safe to
  /// call multiple times for the same kind — the latest registration
  /// wins, which matters if a transport ever needs to be rebuilt (e.g.
  /// Jellyfin server URL changes, so JellyfinRemoteTransport is
  /// recreated).
  void registerTransport(CastTransport transport) {
    _transports[transport.kind] = transport;
  }

  void unregisterTransport(CastTransportKind kind) {
    _transports.remove(kind);
    _devicesByTransport.remove(kind);
    _discoverySubscriptions.remove(kind)?.cancel();
    _recomputeDevices();
  }

  // ---------------------------------------------------------------------
  // Discovery
  // ---------------------------------------------------------------------

  /// Starts discovery across every registered transport, if it isn't
  /// already running. Ref-counted: call once per "thing that needs a live
  /// device list" (typically: the device-picker sheet becoming visible),
  /// and call [releaseDiscovery] when that thing goes away. Matches
  /// NetworkQualityService's acquire()/release() exactly, for the same
  /// reason — discovery must not run for the app's whole lifetime, only
  /// while something is actually showing device results (master prompt's
  /// "avoid constant network scanning / battery-heavy discovery" rule).
  void acquireDiscovery() {
    _discoveryRefCount++;
    // Re-opened within the linger window: the scan is still running and the
    // device list is still filled, so there is nothing to start over.
    _discoveryStopTimer?.cancel();
    _discoveryStopTimer = null;
    if (_discoveryRefCount == 1 && !_discoveryRunning) {
      _discoveryRunning = true;
      _startDiscovery();
    }
  }

  void releaseDiscovery() {
    if (_discoveryRefCount == 0) return;
    _discoveryRefCount--;
    if (_discoveryRefCount == 0) {
      // Not stopped at once: the device list used to be wiped and the scan
      // restarted from nothing on every open, which is why devices took so
      // long to appear. Keep it alive briefly instead.
      _discoveryStopTimer?.cancel();
      _discoveryStopTimer = Timer(_discoveryLinger, () {
        _discoveryStopTimer = null;
        if (_discoveryRefCount == 0 && _discoveryRunning) {
          _discoveryRunning = false;
          _stopDiscovery();
        }
      });
    }
  }

  Timer? _discoveryStopTimer;
  bool _discoveryRunning = false;
  static const Duration _discoveryLinger = Duration(seconds: 45);

  /// Starts looking for TVs a few seconds before anyone taps the cast
  /// button (called when a cast button appears), so the list is already
  /// filled when the picker opens. Stops by itself again.
  void prewarmDiscovery({Duration hold = const Duration(seconds: 12)}) {
    if (isCasting) return;
    acquireDiscovery();
    Timer(hold, releaseDiscovery);
  }

  void _startDiscovery() {
    for (final transport in _transports.values) {
      _discoverySubscriptions[transport.kind]?.cancel();
      // One transport failing to start (e.g. the Google Cast SDK not
      // being set up) must not stop the transports after it from
      // scanning — the loop used to abort on the first synchronous throw.
      try {
        _discoverySubscriptions[transport.kind] =
            transport.discover().listen((found) {
          _devicesByTransport[transport.kind] = found;
          _recomputeDevices();
        }, onError: (Object e) {
          debugPrint('CastManager: ${transport.kind} discovery error: $e');
        });
      } catch (e) {
        debugPrint('CastManager: ${transport.kind} discovery failed: $e');
      }
    }
  }

  void _stopDiscovery() {
    for (final subscription in _discoverySubscriptions.values) {
      subscription.cancel();
    }
    _discoverySubscriptions.clear();

    // Fire-and-forget: releaseDiscovery() (this method's only caller) is a
    // synchronous void method, matching NetworkQualityService.release()'s
    // calling convention, which call sites rely on not having to await.
    // Each transport's stopDiscovery() is still expected to actually run
    // to completion; nothing here depends on its result.
    for (final transport in _transports.values) {
      unawaited(transport.stopDiscovery());
    }

    _devicesByTransport.clear();
    devices.value = [];
  }

  /// Merges each transport's independently-discovered device list into
  /// the unified list the UI actually sees. Per the Phase 2 architecture
  /// decision: merging is identity-based and conservative — two entries
  /// only ever collapse into one CastDevice with multiple transports when
  /// they share a real, explicit identity signal (e.g. a Nemesis Native
  /// TV's advertised Jellyfin DeviceId matching a live Jellyfin session).
  /// No such signal exists yet as of Phase 3 (no real transports are
  /// registered), so today this is effectively a flatten-and-dedupe-by-id
  /// no-op — the actual matching heuristic gets real inputs to work with
  /// starting in Phase 4/6, and should be implemented here (not
  /// duplicated per-transport) when that lands.
  void _recomputeDevices() {
    final merged = <String, CastDevice>{};

    for (final entry in _devicesByTransport.entries) {
      for (final device in entry.value) {
        final existing = merged[device.id];
        if (existing == null) {
          merged[device.id] = device;
          continue;
        }

        // Same id reported by more than one transport lookup (e.g. a
        // transport re-emitting on every discovery tick) — combine their
        // capability maps rather than letting the later one clobber the
        // earlier one.
        merged[device.id] = existing.copyWith(
          transports: {...existing.transports, ...device.transports},
        );
      }
    }

    // A TV that speaks both Google Cast and DLNA (Sony/Philips/TCL Google
    // TVs, Chromecast built-in sets) is discovered by both transports under
    // different ids. Hide the DLNA twin when a non-DLNA entry with the same
    // display name exists, so the person sees one row for that TV and it
    // keeps using the richer transport.
    //
    // The Trigon TV receiver is never hidden (it is the richest DLNA target).
    final castNames = <String>{
      for (final d in merged.values)
        if (d.transports.containsKey(CastTransportKind.googleCast))
          d.displayName.trim().toLowerCase(),
    };
    merged.removeWhere((id, d) =>
        !d.isNemesisReceiver &&
        d.transports.keys.every((k) => k == CastTransportKind.dlna) &&
        castNames.contains(d.displayName.trim().toLowerCase()));

    // Trigon TV receivers first (stable partition), everything else in
    // discovery order.
    final all = merged.values.toList(growable: false);
    devices.value = [
      ...all.where((d) => d.isNemesisReceiver),
      ...all.where((d) => !d.isNemesisReceiver),
    ];
  }

  // ---------------------------------------------------------------------
  // Connection
  // ---------------------------------------------------------------------

  /// Connects to [device]. Omitting [transport] uses the device's
  /// resolved preference (its stored override, or the default Google Cast >
  /// DLNA priority) — see
  /// CastDevice.preferredTransport. Passing [transport] explicitly is how
  /// the device-picker's per-transport sub-rows force a specific choice.
  Future<void> connect(CastDevice device, {CastTransportKind? transport}) async {
    final kind = transport ?? device.preferredTransport;
    // PHASE 0 (diagnostics): which transport this connection uses and why —
    // the transport is fixed for the whole session (finding F2.4).
    debugPrint(
      'CASTING DEBUG: connect "${device.displayName}" -> $kind '
      '(requested=${transport ?? 'auto'}, preferred='
      '${device.preferredTransport}, offers='
      '${device.transports.keys.join('/')}, localMediaPlaying='
      '${hasLocalMediaProvider?.call() ?? false})',
    );
    final impl = _transports[kind];

    if (impl == null) {
      throw StateError(
        'No CastTransport registered for $kind — cannot connect to '
        '${device.displayName}.',
      );
    }

    // Disconnect any existing session first — casting to a second device
    // while already connected to one isn't a supported flow (avoids the
    // "double playback" the master prompt explicitly warns against).
    if (activeSession.value != null) {
      await disconnect();
    }

    try {
      // The first attempt right after discovery often fails while the TV is
      // still waking its receiver / the session service is warming up; the
      // same tap succeeds a moment later. One automatic retry makes that
      // invisible instead of making the person tap twice.
      CastSession session;
      try {
        session = await impl.connect(device);
      } catch (first) {
        debugPrint(
          'CASTING DEBUG: first connect attempt to "${device.displayName}" '
          'failed ($first) — retrying once',
        );
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        session = await impl.connect(device);
      }
      activeSession.value = session;
      _attachAutoTeardown(session);
    } catch (e) {
      // Surface the failure via a short-lived session in the error state
      // rather than leaving activeSession null with no explanation — the
      // device-picker sheet (Phase 7) can show device.lastError this way
      // without CastManager needing a separate "last connection error"
      // field.
      final failed = CastSession(
        device: device,
        transportKind: kind,
        initialConnectionState: CastConnectionState.error,
      );
      failed.lastError.value = e.toString();
      activeSession.value = failed;
      rethrow;
    }
  }

  Future<void> disconnect() async {
    final session = activeSession.value;
    if (session == null) return;

    // Detach before doing anything else: once impl.disconnect() runs
    // (below), CastManager itself is finalizing this session, so the
    // auto-teardown listener has nothing left to do — and must not still
    // be attached when session.dispose() runs a few lines down, or it
    // would try to double-finalize an already-nulled activeSession.
    _detachAutoTeardown(session);

    final impl = _transports[session.transportKind];
    if (impl != null) {
      await impl.disconnect(session);
    }

    // LOCAL CASTING: tears down whatever LocalCastServer routes this
    // session opened for on-device songs/Open With files — a cheap no-op
    // when nothing local was ever cast this session (see
    // LocalCastServer.stopAll's own doc comment for why this is always
    // safe to call unconditionally here rather than only when the
    // session's transport/items are known to have been local).
    unawaited(LocalCastServer.instance.stopAll());
    _localOriginals.clear();
    _replacedBy.clear();

    session.dispose();
    activeSession.value = null;
  }

  /// PHASE 10 HARDENING. Wires up [session.connectionState] so a
  /// transport-detected disconnect/error actually finalizes
  /// [activeSession] — see the field doc on [_sessionTeardownListeners]
  /// for the bug this closes. Attached once, right after a session
  /// becomes the active one, from every path that can make that happen
  /// ([connect]).
  void _attachAutoTeardown(CastSession session) {
    void listener() => _handleSessionConnectionStateChange(session);
    _sessionTeardownListeners[session] = listener;
    session.connectionState.addListener(listener);

    // See [_sessionTrickplayListeners]'s field doc comment.
    void trickplayListener() {
      final item = session.currentItem.value;
      if (item != null) unawaited(_augmentCastItem(session, item));
    }

    _sessionTrickplayListeners[session] = trickplayListener;
    session.currentItem.addListener(trickplayListener);
  }

  void _detachAutoTeardown(CastSession session) {
    final listener = _sessionTeardownListeners.remove(session);
    if (listener != null) {
      session.connectionState.removeListener(listener);
    }

    final trickplayListener = _sessionTrickplayListeners.remove(session);
    if (trickplayListener != null) {
      session.currentItem.removeListener(trickplayListener);
    }
  }

  void _handleSessionConnectionStateChange(CastSession session) {
    final state = session.connectionState.value;
    if (state != CastConnectionState.disconnected &&
        state != CastConnectionState.error) {
      // Still connecting/connected/discovering — nothing to finalize.
      return;
    }

    // Guard against a stale callback: only ever finalize the session
    // that is still actually the active one. (CastManager.connect()
    // always disconnects any existing session before creating a new one,
    // so in practice this session and activeSession.value are the same
    // object whenever this fires — this is a defensive check, not a
    // path this codebase is expected to exercise today.)
    if (!identical(activeSession.value, session)) {
      _detachAutoTeardown(session);
      return;
    }

    // The transport that owns this session already tore down its own
    // side (closed the socket, cancelled its sync timer/stream
    // subscription) by the time it set connectionState to this terminal
    // value — see each transport's own doc comments on this exact
    // sequencing. So this only finalizes CastManager's side of the
    // bookkeeping: detach, dispose, and null out activeSession so every
    // screen watching it (and PlaybackCoordinator's REMOTE -> LOCAL
    // resume offer) actually reacts.
    _detachAutoTeardown(session);
    session.dispose();
    activeSession.value = null;
  }

  // ---------------------------------------------------------------------
  // Playback commands — all pass-throughs to the active session's
  // transport, capability-gated. Per the master prompt, the UI is
  // expected to already hide controls a session doesn't support; these
  // guards are a defensive backstop, not the primary mechanism.
  // ---------------------------------------------------------------------

  CastTransport? get _activeTransport {
    final session = activeSession.value;
    if (session == null) return null;
    return _transports[session.transportKind];
  }

  /// CASTING FIX (subtitle button doesn't always work + no seek
  /// thumbnails for cast episodes): episode lists are deliberately
  /// fetched without MediaSources/MediaStreams/Trickplay for performance
  /// (see MediaService.getEpisodes's own doc comment) — those three
  /// fields are only actually needed once something is genuinely about
  /// to play. Local playback already fixes this for itself via
  /// PlayerManager._augmentWithPlaybackFields(), which fetches the full
  /// item right as playback starts.
  ///
  /// A movie, or anything cast from a screen that already fetched the
  /// full item for its own display (movie/show details), already carries
  /// `mediaStreams` — but that alone doesn't mean the *Trickplay* portion
  /// of that same earlier fetch was actually complete.
  ///
  /// SEEK-THUMBNAIL FIX (movies stuck on a stale trickplay snapshot while
  /// casting): this used to short-circuit on `mediaStreams` alone, with
  /// no regard for whether `item.trickplay` itself was any good. A movie
  /// opened from its details screen always has `mediaStreams` (that
  /// screen fetches full fields up front) — so this returned `item`
  /// unchanged even when its Trickplay snapshot was taken while
  /// server-side generation was still running, and nothing ever
  /// refetched it for the rest of that cast session. PlayerManager's
  /// equivalent local-playback path never had this gap because it checks
  /// `TrickplayService.looksComplete()` too, not just whether
  /// `mediaStreams` is populated — using the same shared check here is
  /// what closes it for casting as well, instead of letting the two
  /// playback paths drift apart again.
  Future<MediaItem> _ensureFullMediaItem(MediaItem item) async {
    if (item.live) return item;
    if (item.isLocal) return item;

    final hasMediaStreams =
        item.mediaStreams != null && item.mediaStreams!.isNotEmpty;
    // CAST START DELAY FIX: trickplay (seek-thumbnail sprites) only ever
    // exists for video. A song's `trickplay` is always null, so this used
    // to read as "incomplete" for EVERY song and force a full
    // `MediaService.getItem()` round trip per track, even when the song
    // already carried its `mediaStreams`. Audio is therefore judged on
    // `mediaStreams` alone.
    final hasTrickplay = item.audioOnly ||
        (item.trickplay != null &&
            item.trickplay!.isNotEmpty &&
            TrickplayService.looksComplete(item));

    debugPrint(
      'TRICKPLAY AUGMENT (cast): item=${item.id} title="${item.title}" '
      'hasMediaStreams=$hasMediaStreams hasTrickplay=$hasTrickplay -> '
      '${(hasMediaStreams && hasTrickplay) ? "skipping refetch (already good)" : "refetching from server"}',
    );

    if (hasMediaStreams && hasTrickplay) {
      return item;
    }

    try {
      // CAST START DELAY FIX: a song only needs MediaSources/MediaStreams
      // (container + codec -> direct vs HLS URL). The full-field getItem()
      // below drags people/studios/trickplay with no-cache headers; use the
      // slim batched endpoint for audio and keep getItem for video, which
      // genuinely needs Trickplay.
      if (item.audioOnly) {
        final light = await MediaService.getItemsPlaybackFields([item.id]);
        final entry = light[item.id];
        if (entry != null) return _applyFreshPlaybackFields(item, entry);
        // Slim fetch failed: fall through to the original full fetch.
      }

      final fresh = await MediaService.getItem(item.id);
      return _applyFreshPlaybackFields(item, fresh);
    } catch (_) {
      return item;
    }
  }

  /// Copies the playback-relevant fields of a fresh Jellyfin item JSON onto
  /// [item]. Shared by the per-item fetch above and playQueue()'s batched
  /// prefetch so both produce exactly the same result.
  MediaItem _applyFreshPlaybackFields(
    MediaItem item,
    Map<String, dynamic> fresh,
  ) {
    return item.copyWith(
      mediaStreams: fresh["MediaStreams"] != null
          ? List<dynamic>.from(fresh["MediaStreams"])
          : (fresh["MediaSources"] is List &&
                  (fresh["MediaSources"] as List).isNotEmpty
              ? List<dynamic>.from(
                  fresh["MediaSources"][0]["MediaStreams"] ?? [])
              : null),
      mediaSources: fresh["MediaSources"] != null
          ? List<dynamic>.from(fresh["MediaSources"])
          : null,
      trickplay: fresh["Trickplay"] != null
          ? Map<String, dynamic>.from(fresh["Trickplay"])
          : null,
    );
  }

  /// Defensive backstop for whatever [_ensureFullMediaItem] can't cover
  /// up front — a transport advancing `session.currentItem` on its own
  /// (a queue naturally moving episode to episode, an explicit
  /// next()/previous()) to an item this app never itself pre-augmented.
  /// In the common case (every item [loadAndPlay]/[playQueue] pre-
  /// augments before ever handing it to a transport — see their own doc
  /// comments) this is a no-op, since `item.mediaStreams` is already
  /// populated by the time `session.currentItem` changes to it.
  ///
  /// Called from the `session.currentItem` listener `_attachAutoTeardown`
  /// wires up (see `_sessionTrickplayListeners`'s field doc comment).
  ///
  /// Fire-and-forget: harmless if the session has moved on to a
  /// different item (a fast double-tap through several episodes, the
  /// session disconnecting) by the time this network call resolves —
  /// guarded by re-checking `session.currentItem` still matches [item]
  /// before writing anything back.
  Future<void> _augmentCastItem(CastSession session, MediaItem item) async {
    final full = await _ensureFullMediaItem(item);
    if (identical(full, item)) return; // Already had it, or the fetch failed.

    final current = session.currentItem.value;
    if (current == null || current.id != item.id) return;
    session.currentItem.value = full;
  }

  /// LOCAL CASTING: gives a local item (see [MediaItem.isLocal] — an
  /// on-device song via LocalMusicService, or a file opened through
  /// Android's Open With/Play With via ExternalMediaHandler) a real,
  /// network-fetchable [MediaItem.remoteStreamUrl] by registering it
  /// with [LocalCastServer], so [MediaItem.castStreamUrl] resolves to
  /// something a receiver can actually reach instead of null. A no-op
  /// for anything else — [_ensureFullMediaItem] already no-ops for
  /// [MediaItem.isLocal] for the same "nothing to do here" reason, so
  /// the two calls stay cleanly separated by exactly which kind of item
  /// each one is actually for. Deliberately not folded into
  /// [_ensureFullMediaItem] itself: that function's whole contract is
  /// "fetch missing Jellyfin fields", and mixing in a completely
  /// different resolution path (a local HTTP server, not a network
  /// request) for a completely different reason would make its own
  /// short-circuit logic harder to follow for no real benefit.
  ///
  /// Lets [LocalCastUnsupportedException]/any other failure propagate —
  /// [loadAndPlay]/[playQueue]'s callers (PlaybackCoordinator) already
  /// catch and surface load failures; this needs to be one of the things
  /// that can fail loudly, not a silent pass-through, since a null
  /// [MediaItem.castStreamUrl] reaching the transport is exactly the
  /// "TV never responds, no idea why" bug this whole feature exists to
  /// close.
  Future<MediaItem> _ensureCastableLocalItem(MediaItem input) async {
    if (!input.isLocal) return input;

    // PHASE 2 (F2.2): always start from the app's own item. An item that
    // already carries phone-server URLs is a resolved copy from an earlier
    // load — its URLs may belong to a server that disconnect shut down, so
    // they are never trusted: the original is resolved afresh (the server
    // reuses the live route for the same file, so this costs nothing when
    // the URLs were in fact still good).
    final carried = _carriesPhoneUrl(input);
    final item = carried ? (_localOriginals[input.id] ?? input) : input;
    if (!carried) {
      _localOriginals.remove(input.id); // keep insertion order = recency
      _localOriginals[input.id] = input;
      while (_localOriginals.length > _maxLocalOriginals) {
        _localOriginals.remove(_localOriginals.keys.first);
      }
    }

    // CASTING FIX (no artwork/poster on the TV for a local song/video):
    // runs even when `castStreamUrl` is already set below (a local item
    // re-entering this — e.g. a queue containing the same song twice, or
    // this being called again after an earlier successful cast) — this
    // block has its own independent short-circuit (`isRemoteArtwork`) so
    // it's a no-op the moment `image`/`backdrop` are already http(s),
    // exactly mirroring the `castStreamUrl != null` short-circuit the
    // media-URL registration below already has. Kept as a genuinely
    // separate step from that registration (rather than folded into one
    // combined "make this castable" block) since the two can independently
    // succeed or fail — a song with an unreadable/missing artwork file
    // should still cast with sound and no art, not be blocked entirely by
    // an image-only failure (see LocalCastServer.registerLocalImage's own
    // "never throws" doc comment for why that's true by construction).
    //
    // GoogleCastTransport._imagesFor already knows to use `item.image`
    // once it's a real http(s) URL — no changes needed there; this is the
    // one thing standing between a local item and that already-written
    // code path actually firing.
    var withArt = item;
    final image = item.image;
    if (image != null && image.isNotEmpty && !isRemoteArtwork(image)) {
      final artUrl = await LocalCastServer.instance.registerLocalImage(
        title: item.title,
        localPath: image,
      );
      if (artUrl != null) {
        withArt = withArt.copyWith(image: artUrl.toString());
      }
    }

    // CASTING FIX: `backdrop` is a separate field from `image` (see
    // MediaItem's own doc comment on the two), so an Open With/Play With
    // video — which now sets both to the same cached first-frame path,
    // see ExternalMediaHandler._buildMediaItem's own doc comment — needs
    // its own independent registration here too. Almost always the exact
    // same on-disk file `image` just resolved above, so this is a second,
    // separate LocalCastServer route rather than reusing the first one —
    // a little wasteful (one extra tiny HTTP route for what's usually a
    // duplicate file), but far simpler than threading "these two fields
    // might be the same file" special-casing through here for a route
    // that costs nothing once registered.
    final backdrop = withArt.backdrop;
    if (backdrop != null && backdrop.isNotEmpty && !isRemoteArtwork(backdrop)) {
      final backdropUrl = await LocalCastServer.instance.registerLocalImage(
        title: item.title,
        localPath: backdrop,
      );
      if (backdropUrl != null) {
        withArt = withArt.copyWith(backdrop: backdropUrl.toString());
      }
    }

    // DOWNLOADED ADDON MEDIA: a finished download keeps the AddonStream flag
    // but its streamUrl is now a file on this phone, and its remoteStreamUrl
    // is only a placeholder Jellyfin-style address that no TV can open. It
    // must be served like any other on-device file, so the placeholder is
    // dropped here (otherwise it would be trusted as "already castable" and
    // the file would never be served), and the addon relay below is only
    // used for sources that really are http(s) links.
    final isAddon = item.raw?['AddonStream'] == true;
    final addonSourceIsRemote = isAddon && _isHttpUrl(item.streamUrl);
    if (isAddon && !addonSourceIsRemote) {
      withArt = withArt.copyWith(clearRemoteStreamUrl: true);
    }

    // PHASE 2 (F2.2): a phone-server URL is only kept when the running
    // server still owns it. A URL left over from a server that disconnect
    // shut down is dead, and this used to be skipped as "already set",
    // handing the TV a dead address (and no cover).
    final existingUrl = withArt.castStreamUrl;
    final existingIsPhoneUrl =
        existingUrl != null && LocalCastServer.isPhoneServerUrl(existingUrl);
    debugPrint(
      'CASTING DEBUG: local item "${item.title}" — castStreamUrl '
      '${existingUrl == null ? 'absent (will register a route)' : (existingIsPhoneUrl ? 'phone-server URL, owned by the running server: ${LocalCastServer.instance.ownsUrl(existingUrl)} (re-registered either way)' : 'present (not a phone-server URL)')}; '
      'cover ${withArt.image == null ? 'none' : (isRemoteArtwork(withArt.image!) ? 'http(s) URL' : 'on-disk path')}',
    );

    // NAMESIS PRIME: addon streams (direct links and torrents) get their own
    // handling - relayed through this phone where a TV could not fetch them.
    if (addonSourceIsRemote) {
      return _castableAddonItem(withArt);
    }

    if (existingUrl != null && !existingIsPhoneUrl) return withArt;

    // DLNA TVs decode in their own firmware: they accept far more containers
    // than Google's receiver (AVI/MOV/WMV/FLAC/WMA…) and play MKV natively,
    // so for them the file is served exactly as it is — no MKV->TS remux.
    final isDlna = activeSession.value?.transportKind == CastTransportKind.dlna;
    final format = isDlna
        ? resolveLocalDlnaFormat(withArt)
        : resolveLocalCastFormat(withArt);
    final url = await LocalCastServer.instance.registerMedia(
      item: withArt,
      sourceUri: withArt.streamUrl,
      contentType: format.contentType,
      extensionForUrl: format.extension,
      remuxMkvToTs: !isDlna,
    );
    return withArt.copyWith(remoteStreamUrl: url.toString());
  }

  static bool _isHttpUrl(String value) {
    final uri = Uri.tryParse(value);
    return uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.isNotEmpty;
  }

  /// NAMESIS PRIME: makes an addon stream castable. Every non-HLS link is
  /// relayed through this phone on both transports, exactly like a torrent
  /// (the TV never contacts the source itself, so redirects, header-locked or
  /// IP-locked links, https and servers without Range all work).
  ///  - DLNA: relayed as it is, declared with the format found in the link.
  ///  - Google Cast: MP4/WebM/TS are relayed as they are; everything else
  ///    (MKV, AVI, unknown) is repackaged to HLS on the phone, because the
  ///    receiver cannot open it.
  Future<MediaItem> _castableAddonItem(MediaItem item) async {
    final isDlna = activeSession.value?.transportKind == CastTransportKind.dlna;
    final source = item.streamUrl;
    final uri = Uri.tryParse(source);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw LocalCastUnsupportedException(
        '"${item.title}" has no playable address yet. Start it on the phone '
        'first, then cast.',
      );
    }

    final headers = <String, String>{};
    final rawHeaders = item.raw?['HttpHeaders'];
    if (rawHeaders is Map) {
      rawHeaders.forEach((k, v) {
        if (k != null && v != null) headers['$k'] = '$v';
      });
    }
    final host = uri.host.toLowerCase();
    final loopback = host == '127.0.0.1' ||
        host == 'localhost' ||
        host == '::1' ||
        host == '[::1]';
    var ext = item.raw?['FileExtension']?.toString().toLowerCase() ?? '';
    if (ext.isEmpty) {
      final m = RegExp(r'\.([A-Za-z0-9]{1,5})$').firstMatch(uri.path);
      ext = m?.group(1)?.toLowerCase() ?? '';
    }

    // What is this link really? Read from its first bytes. The torrent
    // engine's own loopback address is skipped (its file name already says).
    CastSourceProbe? probe;
    if (!loopback) {
      probe = await probeCastSource(uri, headers);
      if (probe?.looksLikeHtml ?? false) {
        throw LocalCastUnsupportedException(
          'The link for "${item.title}" returned a web page instead of a '
          'video - it has probably expired. Pick another link.',
        );
      }
    }
    final probedType = probe?.contentType ?? '';
    final isHls = ext == 'm3u8' ||
        uri.path.toLowerCase().contains('.m3u8') ||
        (probe?.isHls ?? false) ||
        probedType.contains('mpegurl');
    if (isHls) {
      throw LocalCastUnsupportedException(
        '"${item.title}" is an HLS stream, which can\'t be cast. Pick '
        'another link.',
      );
    }
    if (probe?.extension != null) ext = probe!.extension!;

    // The transports work the format out from the item again: keep them in
    // step with what is actually relayed.
    final raw = item.raw;
    if (raw != null) {
      if (ext.isNotEmpty) raw['CastResolvedExtension'] = ext;
      if (probedType.startsWith('video/')) {
        raw['CastResolvedMimeType'] = probedType;
      }
    }

    final server = LocalCastServer.instance;

    if (isDlna) {
      final format = resolveLocalDlnaFormat(item);
      final url = await server.registerAddonStream(
        item: item,
        sourceUrl: source,
        headers: headers,
        contentType: format.contentType,
        extension: format.extension,
        hls: false,
      );
      return item.copyWith(remoteStreamUrl: url.toString());
    }

    const googleDirect = {'mp4', 'm4v', 'webm', 'ts'};
    if (googleDirect.contains(ext)) {
      final url = await server.registerAddonStream(
        item: item,
        sourceUrl: source,
        headers: headers,
        contentType: ext == 'webm'
            ? 'video/webm'
            : (ext == 'ts' ? 'video/mp2t' : 'video/mp4'),
        extension: ext,
        hls: false,
      );
      return item.copyWith(remoteStreamUrl: url.toString());
    }

    final url = await server.registerAddonStream(
      item: item,
      sourceUrl: source,
      headers: headers,
      contentType: 'application/x-mpegurl',
      extension: ext,
      hls: true,
    );
    return item.copyWith(remoteStreamUrl: url.toString());
  }

  /// DEFAULT SUBTITLE (all transports): a fresh cast of a video starts with
  /// one subtitle switched on — the file's default/forced track, else the
  /// first one — which the person can turn off or change afterwards (the
  /// subtitle sheet's tick follows the session's active subtitle id).
  ///
  /// Done by stamping the item's `CastActiveSubtitleId` hint, which every
  /// transport already honors at load time (Google Cast activates the
  /// declared track in the same load call, DLNA declares it in the DIDL,
  /// Jellyfin Remote / Nemesis Native send it as the start subtitle index).
  /// A fresh cast also forgets a previous "subtitles off" on this item.
  ///
  /// Skipped for an item whose subtitle choice the caller already carries
  /// over (a local -> TV handoff passes `auto: false`), and never overrides
  /// a hint that is already there (a remembered pick / local sidecar).
  void _applyInitialSubtitleHint(
    MediaItem item,
    CastSession session, {
    required bool auto,
  }) {
    if (!auto) return;
    final raw = item.raw;
    if (raw == null || item.audioOnly || item.live) return;

    raw.remove(kCastSubtitlesOffHint);
    if (raw[kCastActiveSubtitleHint] is int) return;

    final textOnly = switch (session.transportKind) {
      CastTransportKind.googleCast || CastTransportKind.dlna => true,
      _ => false,
    };
    final index = defaultCastSubtitleIndex(item, textOnly: textOnly);
    if (index != null) raw[kCastActiveSubtitleHint] = index;
  }

  /// Sessions replaced by a newer one on the same device (always empty now
  /// that no transport swaps sessions mid-playback; kept because the
  /// connect-time handoff still asks [liveSessionFor]).
  final Map<CastSession, CastSession> _replacedBy = {};

  /// The live session that continues [original]: [original] itself while it
  /// is still the active one, the DLNA twin that replaced it, or null when
  /// that connection is gone.
  CastSession? liveSessionFor(CastSession original) {
    var current = original;
    for (var hops = 0; hops < 4; hops++) {
      final next = _replacedBy[current];
      if (next == null) break;
      current = next;
    }
    return identical(current, activeSession.value) ? current : null;
  }

  /// Whether the active session can carry media that only exists on this
  /// phone. Both remaining transports (Google Cast, DLNA) are served by
  /// [LocalCastServer], so this is true whenever a session exists.
  Future<bool> ensureLocalCapableSession() =>
      Future.value(activeSession.value != null);

  /// PHASE 1: counts every load REQUEST made on the active session
  /// ([loadAndPlay], [playQueue]), in the order they were made. A transport
  /// serialises loads and a newer one silently supersedes an older one, so a
  /// caller that must not act on a load that was overtaken (the connect-time
  /// handoff, a video redirect mirroring its item) compares this counter
  /// before and after its own request: unchanged means its load is still the
  /// newest.
  int _loadSeq = 0;
  int get loadSeq => _loadSeq;

  Future<void> loadAndPlay(
    MediaItem item, {
    Duration startAt = Duration.zero,
    bool autoSubtitle = true,
  }) async {
    var session = activeSession.value;
    var impl = _activeTransport;
    if (session == null || impl == null) {
      throw StateError('loadAndPlay() called with no active cast session.');
    }
    _loadSeq++;

    // PHASE 2 (F2.4): a local file on a Jellyfin / Native session switches
    // the session to its DLNA twin first.
    if (item.isLocal && !session.transportKind.switchesTracksByReload) {
      await ensureLocalCapableSession();
      session = activeSession.value;
      impl = _activeTransport;
      if (session == null || impl == null) {
        throw StateError('loadAndPlay() called with no active cast session.');
      }
    }

    // LOCAL CASTING: runs before _ensureFullMediaItem below (which
    // no-ops for a local item anyway) so a local song/Open With file has
    // a real remoteStreamUrl by the time anything else here looks at it.
    final castableItem = await _ensureCastableLocalItem(item);

    // SUBTITLE-BUTTON FIX (episode subtitles/seek-thumbnails missing
    // while movies worked fine): this used to hand `item` straight to
    // `impl.load()` and only backfill `mediaStreams`/`trickplay`
    // *afterward*, fire-and-forget, via the `session.currentItem`
    // listener (`_augmentCastItem`). That's fine for the trickplay
    // preview (CastSeekBar just rebuilds once the richer item lands),
    // but GoogleCastTransport.load() bakes its subtitle-track
    // declaration into the one `loadMedia()` call it ever makes for this
    // item — computed from `item.mediaStreams` at the moment `load()`
    // runs, never revisited afterward. An episode cast straight from an
    // episode list (fetched without MediaStreams — see
    // MediaService.getEpisodes's own doc comment) therefore always
    // declared zero subtitle tracks to the receiver and permanently
    // disabled the Subtitles button for that session (`load()`'s own
    // `subtitleTrackSelection: subtitleTracks.isNotEmpty`) — no later
    // backfill could fix it, since the receiver was never told those
    // tracks existed in the first place. A movie cast from a details
    // screen never showed this, because that screen already fetched the
    // full item. Awaiting the real item *before* calling `impl.load()`
    // closes that gap for every transport uniformly: a no-op resolve for
    // anything that already carries `mediaStreams` (see
    // `_ensureFullMediaItem`'s own short-circuit), a real fetch only for
    // the sparse-episode-list case.
    final fullItem = await _ensureFullMediaItem(castableItem);

    // RESUME-POINT FIX: this used to also call `await impl.play(session);`
    // right after `load()`. That's redundant — every transport's `load()`
    // already starts playback itself at exactly `startAt` (Jellyfin's
    // `PlayCommand: PlayNow` + `StartPositionTicks`, Google Cast's
    // `autoPlay: true` + `playPosition`, Nemesis Native's
    // `startPositionTicks` in the load message) — and worse than
    // redundant: a bare, position-less `play()` landing a beat later,
    // while the receiver is still settling into that requested start
    // position, is a real race that some receivers resolve by just
    // (re)starting the current item from the top. That's exactly what
    // "casting a movie/song always restarts from 0 instead of resuming
    // where local playback left off" looks like, and it's identical
    // across all three transports because this call — not anything
    // transport-specific — was the shared cause. `load()` alone is
    // sufficient; nothing here needs a follow-up play command.
    _applyInitialSubtitleHint(fullItem, session, auto: autoSubtitle);
    // A fresh channel stream starts without captions on the TV.
    if (session.currentItem.value?.id != fullItem.id) {
      session.closedCaptionsOn.value = false;
    }
    await impl.load(session, fullItem, startAt: startAt);
  }

  /// LOCAL CASTING (audio-track switch / late-added subtitle): re-sends an
  /// item that has ALREADY been through [loadAndPlay]'s local-item
  /// resolution (its `remoteStreamUrl` is a live [LocalCastServer] URL) to
  /// the receiver at [startAt] (default: where the TV currently is),
  /// without going through [_ensureCastableLocalItem] again. Going back
  /// through [loadAndPlay] would re-register — and for an MKV, re-REMUX —
  /// the whole file just to change one track. The Cast SDK has no way to
  /// add a text track or swap the audio stream of media that's already
  /// loaded, so a fresh `load()` at the current position is the only way
  /// to change either; it's the same thing VLC's Cast does.
  Future<void> reloadResolvedItem(
    MediaItem resolvedItem, {
    Duration? startAt,
  }) async {
    final session = activeSession.value;
    final impl = _activeTransport;
    if (session == null || impl == null) {
      throw StateError('reloadResolvedItem() called with no active cast session.');
    }
    // PHASE 2 (F2.2/F2.7): a resolved copy whose phone-server URL the
    // running server no longer owns (the session was re-created, the route
    // was released) is resolved again instead of being handed to the TV dead.
    var toLoad = resolvedItem;
    if (toLoad.isLocal) {
      final url = toLoad.castStreamUrl;
      if (url != null &&
          LocalCastServer.isPhoneServerUrl(url) &&
          !LocalCastServer.instance.ownsUrl(url)) {
        toLoad = await _ensureCastableLocalItem(toLoad);
      }
    }
    await impl.load(
      session,
      toLoad,
      startAt: startAt ?? session.position.value,
    );
  }

  /// FOLLOW-UP FIX (flagged as "No Cast queue support" in Phase 11,
  /// addressed here): the `playQueue()` the Phase 2 doc already stubbed
  /// `capability.queue` for, but that nothing ever called — `loadAndPlay`
  /// above stayed the only load path, so `queue`/`next`/`previous` never
  /// had anything to be true about. Capability-gated exactly like every
  /// other command here: a transport whose session doesn't report
  /// `queue` support throws before ever reaching the transport, the same
  /// defensive backstop the UI's own capability checks are expected to
  /// make unreachable in practice. Each transport's own `loadQueue()`
  /// doc comment covers what it actually does with this (Google Cast's
  /// `queueLoadItems`, Jellyfin Remote's multi-`ItemIds` `/Playing` call,
  /// Nemesis Native's speculative `loadQueue` wire message).
  Future<void> playQueue(
    List<MediaItem> items, {
    int startIndex = 0,
    Duration startAt = Duration.zero,
    String? manualSubtitleItemId,
  }) async {
    var session = activeSession.value;
    var impl = _activeTransport;
    if (session == null || impl == null) {
      throw StateError('playQueue() called with no active cast session.');
    }
    _loadSeq++;

    // PHASE 2 (F2.4): see [ensureLocalCapableSession]. Decided by the item
    // the queue starts on — the one that has to play first.
    if (items.isNotEmpty &&
        items[startIndex.clamp(0, items.length - 1)].isLocal &&
        !session.transportKind.switchesTracksByReload) {
      await ensureLocalCapableSession();
      session = activeSession.value;
      impl = _activeTransport;
      if (session == null || impl == null) {
        throw StateError('playQueue() called with no active cast session.');
      }
    }
    if (!session.capability.queue) {
      throw UnsupportedCastCommand('loadQueue', session.transportKind);
    }

    // SUBTITLE-BUTTON FIX: same reasoning as loadAndPlay() above, applied
    // to every item in the queue rather than just the one it starts on —
    // GoogleCastTransport.loadQueue() declares *every* item's subtitle
    // tracks to the receiver in the single `queueLoadItems()` call this
    // makes, up front, so an episode 12 slots into that call with real
    // tracks only if its `mediaStreams` are already known by the time
    // this runs — the same `session.currentItem` backfill that self-heals
    // the in-app subtitle sheet later (once the queue actually reaches
    // that episode) can't retroactively fix what the receiver was
    // already told at queue-load time. Fetched in parallel: a no-op for
    // any item that already carries `mediaStreams` (typical for a queue
    // built from a screen that already loaded full items), a real fetch
    // only for genuinely sparse ones (an episode-list-sourced queue).
    //
    // LOCAL CASTING: each item is first given a real remoteStreamUrl if
    // it needs one (an on-device song queue, most commonly — see
    // _ensureCastableLocalItem) before _ensureFullMediaItem's Jellyfin
    // backfill runs over the result, same ordering as loadAndPlay above.
    //
    // LOCAL CASTING PERFORMANCE FIX (huge delay before a local "On This
    // Device" song starts casting): this used to call
    // `_ensureCastableLocalItem` over every single item in `items`
    // before ever calling `impl.loadQueue()` below. For a Jellyfin-backed
    // queue that's cheap — `_ensureCastableLocalItem` no-ops immediately
    // for anything that isn't `MediaItem.isLocal` — but `items` here is
    // `PlaybackQueue.instance.items` (see
    // `PlaybackCoordinator.playAudioQueueOnActiveCast`'s `useFullQueue`
    // branch), and for the "On This Device" section that's the entire
    // local song library: potentially hundreds of tracks. Every one of
    // them used to get a real native file descriptor opened
    // (`LocalMediaBridge.openContentFd`) and a fresh `LocalCastServer`
    // HTTP route registered — all *before* the very first queue-load
    // command ever reached the TV — which is exactly the multi-second
    // delay tapping any local song produced, scaling with library size,
    // while casting a same-sized Jellyfin-backed queue stayed instant.
    //
    // Only `GoogleCastTransport.loadQueue` can ever actually play a queue
    // containing a local item to begin with (see
    // `_localQueueResolveWindow`'s own doc comment), and even that
    // transport only ever sends a forward-only window of at most a few
    // dozen tracks starting at `startIndex` — never the rest of a long
    // queue, and never anything before `startIndex` (no wraparound for a
    // local queue, unlike the other two transports' rotation). Nothing
    // outside that same forward window is ever actually used, so
    // resolving it up front was pure wasted latency for every item
    // outside it. Only the items inside that window get the real,
    // possibly-slow local resolution now; everything outside it is
    // passed through untouched — a typical Jellyfin album/playlist queue
    // is already far smaller than this window, so this changes nothing
    // for the non-local case.
    final windowStart =
        items.isEmpty ? 0 : startIndex.clamp(0, items.length - 1);
    // DLNA loads exactly one item at a time (the phone drives the queue), so
    // only the tapped item is worth resolving now — resolving 80 would open
    // 80 file descriptors the TV will never ask for.
    final resolveCount =
        activeSession.value?.transportKind == CastTransportKind.dlna
            ? 1
            : _localQueueResolveWindow;
    final windowEnd = (windowStart + resolveCount) > items.length
        ? items.length
        : windowStart + resolveCount;

    // CAST START DELAY FIX (tapping a song from Songs / Most Played / On
    // This Device / Favorites took 3-5s to reach the TV, while songs tapped
    // inside an album/artist/playlist screen started instantly): those
    // four entry points queue the WHOLE tab (hundreds or thousands of
    // songs) versus a few dozen for a detail screen. The old code ran
    // `_ensureFullMediaItem` — a `MediaService.getItem()` network request
    // per item that lacked `mediaStreams`/complete trickplay (every song,
    // because songs never have trickplay) — over EVERY item in the queue
    // and awaited all of them before `impl.loadQueue()`, even though no
    // transport ever uses more than a short forward window: Google Cast
    // sends 50 tracks from the tap point, Jellyfin Remote and Nemesis
    // Native only send ids/titles. Latency therefore scaled with library
    // size instead of staying constant.
    //
    // Now only the window a transport can actually use is backfilled
    // (1 item — the tapped one, which becomes `session.currentItem` — for
    // id-only transports; 50 for Google Cast). Everything else passes
    // through untouched; `_augmentCastItem` still backfills any later item
    // the moment the session advances onto it.
    final enrichCount = activeSession.value?.transportKind ==
            CastTransportKind.googleCast
        ? _googleCastEnrichWindow
        : 1;
    final enrichEnd = (windowStart + enrichCount) > items.length
        ? items.length
        : windowStart + enrichCount;

    // COMPILE FIX: the closure's ternary used to mix a `Future<MediaItem>`
    // (`_ensureFullMediaItem(...)`) with a bare `MediaItem` (`resolved`), so
    // Dart inferred the closure's return as `Future<Object>` and
    // `Future.wait` handed back a `List<Object>` — which `loadQueue()`
    // below rejects as not a `List<MediaItem>`. Awaiting inside the
    // ternary makes both branches a plain `MediaItem`, and the explicit
    // type arguments pin the inference so it can't widen again.
    //
    // CAST START DELAY FIX (batched prefetch): even windowed, Google Cast
    // still enriched up to 50 songs with one full getItem() each, all
    // awaited before the TV got anything. Songs in the window that lack
    // mediaStreams are now fetched in ONE slim batched request, started
    // before the per-item work so it runs alongside local resolution.
    // Anything the batch misses falls back to _ensureFullMediaItem exactly
    // as before.
    final needLight = <String>[
      for (var i = windowStart; i < enrichEnd; i++)
        if (items[i].audioOnly &&
            !items[i].isLocal &&
            !items[i].live &&
            (items[i].mediaStreams == null || items[i].mediaStreams!.isEmpty))
          items[i].id,
    ];
    final prefetched = needLight.isEmpty
        ? const <String, Map<String, dynamic>>{}
        : await MediaService.getItemsPlaybackFields(needLight);

    final fullItems = await Future.wait<MediaItem>(
      List<Future<MediaItem>>.generate(items.length, (i) async {
        final withinResolveWindow = i >= windowStart && i < windowEnd;
        final MediaItem resolved = withinResolveWindow
            ? await _ensureCastableLocalItem(items[i])
            : items[i];
        final withinEnrichWindow = i >= windowStart && i < enrichEnd;
        if (!withinEnrichWindow) return resolved;
        final batched = prefetched[resolved.id];
        if (batched != null && resolved.audioOnly && !resolved.isLocal) {
          return _applyFreshPlaybackFields(resolved, batched);
        }
        return await _ensureFullMediaItem(resolved);
      }),
    );

    // RESUME-POINT FIX: same reasoning as loadAndPlay() above — each
    // transport's loadQueue() already starts the queue playing at
    // startAt on its own, so the extra play() this used to send right
    // after was a redundant, position-less command that could race with
    // the receiver still settling into that start position and reset it
    // to the top of the item instead.
    // DEFAULT SUBTITLE: every video in the queue starts on its default
    // subtitle — except the item whose subtitle choice the caller already
    // carries over (see PlaybackCoordinator's handoff).
    for (final queued in fullItems) {
      _applyInitialSubtitleHint(
        queued,
        session,
        auto: queued.id != manualSubtitleItemId,
      );
    }

    await impl.loadQueue(session, fullItems, startIndex: startIndex, startAt: startAt);
  }

  /// CASTING FIX (audio double-playback): explicit play/pause, as opposed
  /// to [togglePlayPause]'s "flip whatever it currently is" semantics.
  /// Added so [NemesisAudioHandler] — which the OS calls with a definite
  /// "play" or "pause" intent (lock-screen tap, Bluetooth headset button,
  /// Android Auto, a `MediaSession` command from anywhere else) — has a
  /// way to route that intent at the *cast session* instead of always
  /// falling through to local `PlayerManager.player.play()/.pause()`
  /// regardless of whether a session is connected. That fallthrough was
  /// the actual mechanism behind "cast a song, it connects, but tapping
  /// play on the lock-screen/headset makes it play locally again while
  /// the TV is still going" — those OS-level controls never went through
  /// `CastManager` at all before this. [togglePlayPause] intentionally
  /// stays as the toggle every existing in-app cast-aware play/pause
  /// button already uses (MiniPlayer, PlayerControlsBar, CastTransportControls,
  /// VideoPlayerScreen) — this doesn't replace that, it's additive for a
  /// caller that actually knows which direction it means.
  Future<void> play() async {
    final session = activeSession.value;
    final impl = _activeTransport;
    if (session == null || impl == null) return;
    if (!session.capability.play) {
      throw UnsupportedCastCommand('play', session.transportKind);
    }
    // PLAY/PAUSE DELAY FIX: reflect the new state immediately, the same
    // "don't wait for the round trip" reasoning seek() already applies
    // via reportOptimisticSeek above. Without this, every play/pause
    // button bound to session.playbackState (CastTransportControls,
    // MiniPlayer, CastingActivePanel) sat unchanged until Jellyfin
    // Remote's next ~3s /Sessions poll tick or a Nemesis Native state
    // push confirmed it, reading as a laggy/unresponsive button even
    // though the command itself went out right away.
    //
    // PLAY/PAUSE LAG FIX (root cause): routed through
    // `reportOptimisticPlaybackState` rather than a bare `.value =`
    // write — see that method's doc comment on CastSession for the race
    // this closes against `reportPosition`'s stuck-icon promotion, which
    // is what made this optimistic set look like it "didn't take"/was
    // buggy for pause specifically.
    await _sendOptimisticPlayPause(session, impl, wantPlaying: true);
  }

  Future<void> pause() async {
    final session = activeSession.value;
    final impl = _activeTransport;
    if (session == null || impl == null) return;
    if (!session.capability.pause) {
      throw UnsupportedCastCommand('pause', session.transportKind);
    }
    // PLAY/PAUSE DELAY FIX / PLAY/PAUSE LAG FIX: see play() above.
    await _sendOptimisticPlayPause(session, impl, wantPlaying: false);
  }

  /// PLAY/PAUSE FLICKER FIX: shows the tapped state immediately, sends the
  /// command, and — if the command itself fails — puts the button back to
  /// what it showed before instead of leaving a state nothing will confirm.
  Future<void> _sendOptimisticPlayPause(
    CastSession session,
    CastTransport impl, {
    required bool wantPlaying,
  }) async {
    final previous = session.playbackState.value;
    session.reportOptimisticPlaybackState(
      wantPlaying ? CastPlaybackState.playing : CastPlaybackState.paused,
    );
    try {
      if (wantPlaying) {
        await impl.play(session);
      } else {
        await impl.pause(session);
      }
    } catch (_) {
      session.settlePlaybackCommand();
      session.playbackState.value = previous;
      rethrow;
    }
  }

  Future<void> togglePlayPause() async {
    final session = activeSession.value;
    final impl = _activeTransport;
    if (session == null || impl == null) return;

    // PLAY/PAUSE FLICKER FIX: flip what the button is actually SHOWING
    // (`showsPlaying`), not the raw transport state — a `buffering`/
    // `loading` blip is drawn as whatever was showing before, so a tap
    // during one must do the opposite of what the person sees.
    if (session.showsPlaying.value) {
      if (!session.capability.pause) {
        throw UnsupportedCastCommand('pause', session.transportKind);
      }
      // PLAY/PAUSE DELAY FIX / PLAY/PAUSE LAG FIX: see play() above —
      // this is the toggle every in-app play/pause button actually
      // calls, so it's the one that matters most for the perceived lag.
      await _sendOptimisticPlayPause(session, impl, wantPlaying: false);
    } else {
      if (!session.capability.play) {
        throw UnsupportedCastCommand('play', session.transportKind);
      }
      await _sendOptimisticPlayPause(session, impl, wantPlaying: true);
    }
  }

  Future<void> seek(Duration position) async {
    final session = activeSession.value;
    final impl = _activeTransport;
    if (session == null || impl == null) return;
    if (!session.capability.seek) {
      throw UnsupportedCastCommand('seek', session.transportKind);
    }
    // SMOOTH-SEEK-BAR FIX: every seek (the seek bar's commit, ±10s
    // buttons) funnels through here regardless of caller or transport,
    // so this is the one place to update the displayed position
    // immediately rather than waiting for the transport's round-trip
    // and the next authoritative sample — otherwise a seek reads as
    // laggy even though the command itself went out right away.
    session.reportOptimisticSeek(position);
    await impl.seek(session, position);
  }

  Future<void> stop() async {
    final session = activeSession.value;
    final impl = _activeTransport;
    if (session == null || impl == null) return;
    await impl.stop(session);
  }

  Future<void> setVolume(double volume) async {
    final session = activeSession.value;
    final impl = _activeTransport;
    if (session == null || impl == null) return;
    if (!session.capability.volume) {
      throw UnsupportedCastCommand('setVolume', session.transportKind);
    }
    await impl.setVolume(session, volume);
  }

  /// Refreshes `session.volume` from the TV where the transport doesn't
  /// push it on its own (Google Cast only reports the receiver's volume
  /// when asked). Jellyfin Remote and Nemesis Native already keep it
  /// current from their own state updates, so this is a no-op for them.
  Future<void> syncVolume() async {
    final session = activeSession.value;
    final impl = _activeTransport;
    if (session == null || impl == null) return;
    if (impl is GoogleCastTransport) {
      await impl.syncVolume(session);
    } else if (impl is DlnaTransport) {
      await impl.syncVolume(session);
    }
  }

  Future<void> selectAudioTrack(int trackId) async {
    final session = activeSession.value;
    final impl = _activeTransport;
    if (session == null || impl == null) return;
    if (!session.capability.audioTrackSelection) {
      throw UnsupportedCastCommand('selectAudioTrack', session.transportKind);
    }
    await impl.selectAudioTrack(session, trackId);
  }

  Future<void> selectSubtitleTrack(int trackId) async {
    final session = activeSession.value;
    final impl = _activeTransport;
    if (session == null || impl == null) return;
    if (!session.capability.subtitleTrackSelection) {
      throw UnsupportedCastCommand(
          'selectSubtitleTrack', session.transportKind);
    }
    await impl.selectSubtitleTrack(session, trackId);
  }

  /// Whether the connected TV can be told to show/hide a live channel's
  /// closed captions (see [ClosedCaptionCapableTransport]).
  bool get closedCaptionsSupported {
    final session = activeSession.value;
    final impl = _activeTransport;
    if (session == null || impl == null || !session.isConnected) return false;
    if (impl is! ClosedCaptionCapableTransport) return false;
    return (impl as ClosedCaptionCapableTransport)
        .supportsClosedCaptions(session);
  }

  /// Turns the connected TV's closed captions on or off. The session flag
  /// only moves once the command went through.
  Future<void> setClosedCaptions(bool on) async {
    final session = activeSession.value;
    final impl = _activeTransport;
    if (session == null || impl == null) return;
    if (impl is! ClosedCaptionCapableTransport ||
        !closedCaptionsSupported) {
      throw UnsupportedCastCommand('setClosedCaptions', session.transportKind);
    }
    await (impl as ClosedCaptionCapableTransport)
        .setClosedCaptions(session, on);
    session.closedCaptionsOn.value = on;
  }

  /// Casting playback-rate fix. `PlaybackSpeedSheet` calls this while
  /// casting instead of the local `player.setRate()` it always used to,
  /// same branch-on-`isConnected` pattern `SubtitleSheet`/`AudioSelector`
  /// already use. Gated on `session.capability.playbackRate` — false for
  /// every Jellyfin Remote session (see that flag's own doc comment), so
  /// the Speed button is expected to already grey itself out for those
  /// rather than reaching this throw in normal use.
  Future<void> setPlaybackRate(double rate) async {
    final session = activeSession.value;
    final impl = _activeTransport;
    if (session == null || impl == null) return;
    if (!session.capability.playbackRate) {
      throw UnsupportedCastCommand('setPlaybackRate', session.transportKind);
    }
    await impl.setPlaybackRate(session, rate);
  }

  /// Pushes the user's subtitle style to the connected receiver, if its
  /// transport supports restyling (Google Cast, Nemesis Native); a no-op
  /// for Jellyfin Remote and when nothing is connected. Called by
  /// `CastSubtitleStyleSync` — not meant to be called from UI.
  Future<void> applySubtitleStyle(SubtitleAppearance appearance) async {
    final session = activeSession.value;
    final impl = _activeTransport;
    if (session == null || impl == null) return;
    if (session.connectionState.value != CastConnectionState.connected) return;
    // Dart only promotes `impl` to a subtype of its declared type, and
    // SubtitleStyleCapableTransport is unrelated to CastTransport, so
    // `is!` alone doesn't make applySubtitleStyle callable — bind it.
    final capable = impl;
    if (capable is! SubtitleStyleCapableTransport) return;
    await (capable as SubtitleStyleCapableTransport)
        .applySubtitleStyle(session, appearance);
  }

  /// PHASE 4: lets a DLNA session get the following item's cover ready while
  /// the current one plays, so the switch to it does not wait for a picture.
  /// A no-op for every other transport.
  void prefetchNextItem(MediaItem item) {
    final impl = _activeTransport;
    if (impl is DlnaTransport) unawaited(impl.prefetchCover(item));
  }

  Future<void> next() async {
    final session = activeSession.value;
    final impl = _activeTransport;
    if (session == null || impl == null) return;
    if (!session.capability.next) {
      throw UnsupportedCastCommand('next', session.transportKind);
    }
    await impl.next(session);
  }

  Future<void> previous() async {
    final session = activeSession.value;
    final impl = _activeTransport;
    if (session == null || impl == null) return;
    if (!session.capability.previous) {
      throw UnsupportedCastCommand('previous', session.transportKind);
    }
    await impl.previous(session);
  }

  /// Casting Phase 12. Flips the connected session's shuffle state and
  /// sends it to the transport. Set on [CastSession.shuffleNotifier]
  /// optimistically (before/regardless of the transport call's own
  /// result reaching back) since none of the three transports can
  /// reliably push a confirmed shuffle state on their own — same
  /// reasoning `CastSession.shuffleNotifier`'s doc comment gives. A
  /// failed command still leaves the toggle flipped in the UI until the
  /// person notices nothing changed on the TV and tries again; that's
  /// the same tradeoff `runCastCommand`'s SnackBar-on-failure already
  /// exists to soften for every optimistic control on this screen.
  Future<void> toggleShuffle() async {
    final session = activeSession.value;
    final impl = _activeTransport;
    if (session == null || impl == null) return;
    if (!session.capability.shuffle) {
      throw UnsupportedCastCommand('shuffle', session.transportKind);
    }
    final next = !session.shuffleNotifier.value;
    await impl.setShuffle(session, next);
    session.shuffleNotifier.value = next;
  }

  /// Casting Phase 12. Cycles off -> all -> one -> off, mirroring
  /// `PlaybackQueue.cycleRepeatMode()`'s local order exactly so the cast
  /// repeat button behaves the way anyone already used to this app's
  /// local repeat button would expect. Same optimistic-set reasoning as
  /// [toggleShuffle] — JellyfinRemoteTransport's session-sync poll will
  /// still correct this from the server's real `PlayState.RepeatMode`
  /// a few seconds later if the optimistic guess was wrong.
  Future<void> cycleRepeatMode() async {
    final session = activeSession.value;
    final impl = _activeTransport;
    if (session == null || impl == null) return;
    if (!session.capability.repeat) {
      throw UnsupportedCastCommand('repeat', session.transportKind);
    }
    final next = switch (session.repeatModeNotifier.value) {
      CastRepeatMode.off => CastRepeatMode.all,
      CastRepeatMode.all => CastRepeatMode.one,
      CastRepeatMode.one => CastRepeatMode.off,
    };
    await impl.setRepeatMode(session, next);
    session.repeatModeNotifier.value = next;
  }
}
