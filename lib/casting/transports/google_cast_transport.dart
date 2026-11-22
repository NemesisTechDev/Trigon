import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart'
    show MethodChannel, MissingPluginException, PlatformException;
import 'package:flutter_chrome_cast/cast_context.dart';
import 'package:flutter_chrome_cast/common.dart';
import 'package:flutter_chrome_cast/discovery.dart';
import 'package:flutter_chrome_cast/entities.dart';
import 'package:flutter_chrome_cast/enums.dart';
import 'package:flutter_chrome_cast/media.dart';
import 'package:flutter_chrome_cast/models.dart';
import 'package:flutter_chrome_cast/session.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../player/models/media_item.dart';
import '../../player/models/subtitle_appearance.dart';
import '../../player/models/subtitle_track.dart';
import '../../player/services/media_stream_parser.dart';
import '../../services/jellyfin_services/media_service.dart';
import '../../utils/epg_utils.dart';
import '../local_cast_format.dart';
import '../local_cast_server.dart' show kLocalCastSubtitleTrackId;
import '../models/cast_capability.dart';
import '../models/cast_device.dart';
import '../models/cast_session.dart';
import '../models/cast_states.dart';
import 'cast_transport.dart';
import 'subtitle_style_capable.dart';

/// Casts to a Chromecast / Google TV / other Google Cast receiver via
/// `package:flutter_chrome_cast`, talking to Google's stock **Default
/// Media Receiver** — no custom Nemesis receiver app exists or is needed
/// for this transport (that's what Phase 6's Nemesis Native receiver is
/// for; Google Cast's default receiver already knows how to play a plain
/// HTTP video/audio URL with no app-specific receiver code required).
///
/// **Dependency compatibility (per the master prompt's "verify before
/// committing" rule for Phase 5):** `flutter_chrome_cast` (every published
/// version through the current 1.4.8) constrains `permission_handler` to
/// `^12.0.0+1`. This app already depends on `permission_handler: ^13.0.1`
/// (used for the notification/battery-optimization prompts in
/// `main.dart`) — those two constraints don't overlap at all, so
/// `flutter pub get` fails outright without help. I checked *why* that
/// constraint hasn't moved: permission_handler 13.0.0's only breaking
/// change was bumping the Android `compileSdk`/AGP/Java version target
/// for the plugin's own native build — not the Dart-facing API. The two
/// calls this app actually makes (`Permission.notification`,
/// `Permission.ignoreBatteryOptimizations`, both `.status`/`.request()`)
/// are unchanged between 12.x and 13.x. So `pubspec.yaml` adds a
/// `dependency_overrides: permission_handler: ^13.0.1` pin — this
/// overrides `flutter_chrome_cast`'s stale declared constraint for
/// resolution purposes only; the actual permission_handler code that
/// ships and runs is still 13.0.1+, so nothing about the app's existing
/// permission-request behavior changes. **This reasoning is my best
/// verification from published changelogs/dependency metadata — I don't
/// have a Flutter toolchain in this environment to actually run `flutter
/// pub get`/`flutter analyze`/a debug build. Please run those before
/// relying on this** — same caveat every previous casting phase has
/// flagged, just applied to a third-party native plugin instead of a
/// documented HTTP API this time, which is a bigger unknown than Phases
/// 3/4 carried. If `flutter analyze` turns up a class/method name below
/// that doesn't match the installed package version, it's almost
/// certainly a small rename in a `flutter_chrome_cast` point release, not
/// a structural problem with this transport.
///
/// **Android setup added alongside this file** (see PHASE5 handoff for
/// the exact diff): a `OPTIONS_PROVIDER_CLASS_NAME` meta-data entry
/// pointing at the plugin's own bundled provider class (not a
/// hand-written one — `flutter_chrome_cast` ships
/// `com.felnanuke.google_cast.GoogleCastOptionsProvider` and reads the
/// Cast app ID from the Dart-side `GoogleCastOptionsAndroid(appId: ...)`
/// call below at runtime) and the `MediaNotificationService` entry Cast's
/// own now-playing notification needs. `FOREGROUND_SERVICE_MEDIA_PLAYBACK`
/// was already declared for audio_service, so nothing new there.
/// **`MainActivity.kt` is untouched** — this plugin's Cast context init
/// happens from Dart (`_ensureContextInitialized` below), not from native
/// code, so there was no concrete reason to modify it.
///
/// **iOS is out of scope for this phase** (the master prompt's Phase 5
/// objective is "configure Android correctly" specifically) — the
/// `Info.plist` `NSBonjourServices`/`NSLocalNetworkUsageDescription`
/// entries `flutter_chrome_cast`'s docs call for are not added here.
/// `Platform.isAndroid`/`Platform.isIOS` branches below exist only
/// because the plugin's init call itself is written that way in its own
/// docs; casting from an iOS build isn't expected to work yet.
class GoogleCastTransport
    implements CastTransport, SubtitleStyleCapableTransport {
  @override
  CastTransportKind get kind => CastTransportKind.googleCast;

  static const _idPrefix = 'googleCast:';

  /// FOLLOW-UP FIX (flagged, not fixed, in Phase 10; addressed here):
  /// every Cast SDK call below used to have no timeout at all, unlike
  /// NemesisNativeTransport's three named ones (`_connectTimeout`/
  /// `_handshakeTimeout`/`_quickConnectTimeout`) — a receiver that never
  /// responds (network drop mid-command, receiver app crashed, etc.)
  /// would hang the calling command forever instead of surfacing an
  /// error. 10s split the difference between Nemesis Native's two 8s
  /// handshake timeouts and its 45s Quick-Connect one: every command
  /// here is a single local-network round trip with no user-facing
  /// "type a code" step, so it doesn't need Quick Connect's slack, but a
  /// plain 8s felt tight for a first cut with no real Chromecast in this
  /// sandbox to time an actual round trip against. Applied uniformly
  /// (connect/load and every playback command) rather than tuned
  /// per-call, for the same "don't guess at a third-party native SDK's
  /// hang behavior without a device to check it against" reason Phase
  /// 10 gave for not fixing this originally — a single named constant
  /// is one thing to retune once real timing data exists, instead of
  /// several ad hoc numbers.
  static const _callTimeout = Duration(seconds: 10);

  // GoogleCastContext is a process-wide singleton the underlying Cast SDK
  // only expects to be configured once per app launch — guarded here
  // rather than in main.dart's startup sequence so the native SDK (and
  // whatever background discovery machinery it spins up) only ever
  // initializes the first time a device-picker actually asks to discover,
  // matching the master prompt's "avoid battery-heavy discovery/don't do
  // unnecessary work at startup" performance rule the other two
  // transports already follow.
  //
  // ROOT CAUSE (Google Cast devices never appearing): the SDK setup call
  // below is asynchronous, but it used to be fired without waiting and the
  // "done" flag was set immediately — so discovery started before the SDK
  // was ready and, if setup failed, was never retried. Setup is now
  // awaited (once, shared by every caller) before discovery starts, and a
  // failed setup is retried on the next attempt.
  static Future<void>? _contextInit;

  static Future<void> _ensureContextInitialized() {
    return _contextInit ??= _initContext().catchError((Object e) {
      _contextInit = null;
      debugPrint('GoogleCastTransport: Cast SDK setup failed: $e');
      throw e;
    });
  }

  static Future<void> _initContext() async {

    // Google's stock Default Media Receiver — plays a plain HTTP media
    // URL directly, no custom receiver app registration needed. Nemesis
    // doesn't (yet) have a registered Cast Application ID of its own;
    // if a custom Nemesis web receiver is ever built (e.g. to unlock
    // real multi-audio/embedded-subtitle-track switching — see the
    // capability note on _deviceFromGoogleCastDevice below), swap this
    // constant for that receiver's registered app ID and nothing else
    // in this file needs to change.
    //
    // BRANDING FIX (blue default-receiver cast icon → Nemesis splash):
    // a custom receiver (cast_receiver/index.html, delivered alongside
    // this app rather than inside lib/ — it's a hosted web page, not
    // Dart/Flutter code) now exists for exactly this. Once it's hosted
    // and registered in the Google Cast SDK Developer Console (see that
    // file's own top-of-file instructions), replace the line below with
    // the literal App ID Google's console gives back, e.g.:
    //     const appId = 'A1B2C3D4';
    // Left on the stock ID for now so casting keeps working today —
    // flipping this one constant is the only phone-side change needed
    // once the receiver is actually live.
    const appId = GoogleCastDiscoveryCriteria.kDefaultApplicationId;

    final options = Platform.isIOS
        ? IOSGoogleCastOptions(
            GoogleCastDiscoveryCriteriaInitialize.initWithApplicationID(appId),
          )
        : GoogleCastOptionsAndroid(appId: appId);

    // An async closure always gives a real Future<void>. (Wrapping the
    // plugin's Future<bool> in Future<void>.sync keeps the bool type at
    // runtime, and .timeout(onTimeout: () {...}) then throws a TypeError,
    // so the Cast SDK setup failed every single time.)
    Future<void> setup() async {
      await GoogleCastContext.instance.setSharedInstanceWithOptions(options);
    }

    await setup().timeout(const Duration(seconds: 5), onTimeout: () {
      // Not fatal (the native side may just be slow), but never silent.
      debugPrint(
        'GoogleCastTransport: Cast SDK setup did not answer within 5s; '
        'continuing anyway.',
      );
    });
  }

  // CAST DISCOVERY FIX (Android): the plugin's startDiscovery() is a
  // PASSIVE scan by default (MediaRouter CALLBACK_FLAG_REQUEST_DISCOVERY),
  // which only lists receivers Google Play services already knows about
  // and can stay empty for a long time on a quiet network. Passing
  // `activeScan: true` adds CALLBACK_FLAG_PERFORM_ACTIVE_SCAN, the same
  // thing the Cast SDK's own chooser does. Battery cost is bounded because
  // CastManager only keeps discovery alive while the picker is open (plus
  // its short prewarm/linger windows) and then calls stopDiscovery().
  //
  // Android 13+ also needs the runtime NEARBY_WIFI_DEVICES permission for
  // the SDK to find anything on the local network. main.dart asks once at
  // startup, but that single prompt can be dismissed or denied, so it is
  // re-checked here every time discovery starts. A permanently denied
  // permission is not re-requested (the OS would not show a prompt).
  // MULTICAST LOCK (Android): Google Cast receivers answer discovery over
  // multicast mDNS, which Android's Wi-Fi stack drops unless an app holds a
  // WifiManager.MulticastLock. Project Nemesis held one while its picker
  // scanned (taken by its DLNA scan, shared by the Cast scan); Trigon's
  // native side had no handler for it, so the lock was never taken. The Cast
  // scan now asks for it itself, under its own owner name, so it does not
  // depend on the DLNA scan. See MainActivity.kt (setMulticastLock).
  static const MethodChannel _multicastChannel =
      MethodChannel('com.nemesis.app/multicast_lock');

  static Future<void> _setMulticastLock(bool acquire) async {
    if (!Platform.isAndroid) return;
    try {
      await _multicastChannel.invokeMethod<bool>(
        acquire ? 'acquire' : 'release',
        <String, Object?>{'owner': 'cast'},
      );
    } on MissingPluginException {
      debugPrint('GoogleCastTransport: native multicast lock handler is '
          'missing (MainActivity.kt); Google Cast devices may not be found.');
    } catch (e) {
      debugPrint('GoogleCastTransport: multicast lock '
          '${acquire ? 'acquire' : 'release'} failed: $e');
    }
  }

  static Future<void> _ensureNearbyPermission() async {
    if (!Platform.isAndroid) return;
    try {
      final status = await Permission.nearbyWifiDevices.status;
      if (status.isGranted || status.isPermanentlyDenied) {
        if (!status.isGranted) {
          debugPrint(
            'GoogleCastTransport: Nearby devices permission is permanently '
            'denied; Google Cast devices may not be found. Enable it in '
            'Settings > Apps > Trigon > Permissions.',
          );
        }
        return;
      }
      final result = await Permission.nearbyWifiDevices.request();
      debugPrint('GoogleCastTransport: Nearby devices permission: $result');
    } catch (e) {
      debugPrint('GoogleCastTransport: Nearby devices permission check '
          'failed: $e');
    }
  }

  StreamSubscription<List<GoogleCastDevice>>? _discoverySubscription;
  StreamController<List<CastDevice>>? _discoveryController;

  /// The most recent discovery tick's raw Google Cast device objects,
  /// keyed by [GoogleCastDevice.uniqueID] — connect() needs the real SDK
  /// object to hand back to GoogleCastSessionManager, not just the
  /// [CastDevice] the picker UI holds.
  final Map<String, GoogleCastDevice> _knownDevices = {};

  StreamSubscription<GoggleCastMediaStatus?>? _mediaStatusSubscription;
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<GoogleCastSession?>? _sessionSubscription;

  // RECEIVER-ADVANCE FIX (song changes on the TV, phone keeps showing
  // the old one): `session.currentItem` used to only ever get written
  // by this class's own load()/loadQueue() calls — fine for an
  // app-initiated switch (castNext()/castPrevious()/a fresh tap
  // elsewhere in the app all call load() again themselves), but the
  // receiver's own native queue (built by queueLoadItems() below) also
  // advances entirely on its own — natural end-of-track, or someone
  // using the Google Home app/the TV's own remote to skip — and none
  // of that ever went through this transport's load() again, so
  // `session.currentItem` (and everything downstream of it —
  // PlaybackCoordinator's `_itemListener`, the mini player, Audio
  // Player screen) just sat frozen on whichever item was first loaded.
  // `GoggleCastMediaStatus.mediaInformation.contentId` is the Cast
  // SDK's own report of *what's actually loaded right now* — since
  // every queue item was sent with `contentId: item.id` in load()/
  // loadQueue() below, matching that back against whichever MediaItems
  // this transport most recently sent (`_loadedItems`) recovers the
  // real MediaItem for whatever the receiver just switched to, with no
  // guessing needed. JellyfinRemoteTransport already does the
  // equivalent match against `NowPlayingItem.Id` for the same reason —
  // this is that same fix, just keyed off Cast's own status field
  // instead of Jellyfin's polled session report.
  List<MediaItem> _loadedItems = const [];

  /// LOAD-TIMEOUT WATCHDOG: `load()`/`loadQueue()`'s own `.timeout()`
  /// only covers the initial `loadMedia()`/`queueLoadItems()` method-
  /// channel round trip — the Future those calls return completes the
  /// moment the receiver *acknowledges the request*, not once it's
  /// actually opened the content and started reporting real playback
  /// status. A receiver that accepts the request but then can't
  /// actually play what it was handed guards against *any* future
  /// reason a load silently never produces a non-idle status — this
  /// used to leave `session.playbackState` parked on
  /// `loading` forever with no error surfaced anywhere: the cast info
  /// tab just showed nothing playing, and every play/pause tap after
  /// that was silently aimed at a receiver with nothing loaded. This
  /// timer is armed right after a load call succeeds and cancelled the
  /// moment `_applyMediaStatus` sees the receiver actually report
  /// anything other than `idle` — if it fires first, that silent hang
  /// becomes a real, visible `session.lastError` instead.
  Timer? _loadWatchdog;

  static const _loadWatchdogDuration = Duration(seconds: 15);

  /// See the CONNECT-THEN-LOAD RACE FIX in [connect].
  static const _sessionReadyTimeout = Duration(seconds: 8);
  // CAST START DELAY FIX: was 1200ms of unconditional waiting on every
  // connect. It only ever guarded a race that the first-send retry
  // ([_sendInitialLoad]) and the load-ack re-send ([_verifyLoadAcked])
  // already close with real confirmation, so a long blind sleep here just
  // adds latency to the common case. Kept short as a cheap first line of
  // defence; the confirmed-retry path covers a receiver that is slower.
  static const _sessionSettleDelay = Duration(milliseconds: 400);

  /// LOAD-ACK RETRY (root-cause fix for "casting from a player screen's
  /// Cast button connects but the TV sits on its splash screen until the
  /// item is re-sent by hand"). The CONNECT-THEN-LOAD RACE FIX in
  /// [connect] only *reduces* the window in which the handoff's first
  /// `loadMedia()`/`queueLoadItems()` can land before the receiver's
  /// media channel is attached — it can't close it, because the Cast SDK
  /// gives no signal for "media channel attached", and a load sent too
  /// early still completes its method-channel Future successfully (it is
  /// dropped on the receiver side, no error, no status). Timing guesses
  /// alone therefore can't make this reliable across TVs/networks.
  ///
  /// So a load is now *confirmed*, not assumed: every load bumps
  /// [_loadGeneration] and clears [_loadAcked]; `_applyMediaStatus` sets
  /// [_loadAcked] the moment the receiver reports anything about the
  /// media (any non-idle state, or an idle status that still carries
  /// mediaInformation). [_verifyLoadAcked] waits for that and, if the
  /// receiver stays silent, re-sends the same load — exactly what the
  /// manual "select the app again from Play With" workaround did — up to
  /// [_loadAckMaxRetries] times. It only ever re-sends while *no* status
  /// at all has been seen for this generation, so a load that worked can
  /// never be restarted by it, and a newer load/disconnect bumps the
  /// generation and silently ends any older verifier (no double start).
  int _loadGeneration = 0;
  bool _loadAcked = false;
  static const _loadAckTimeout = Duration(seconds: 3);
  static const _loadAckMaxRetries = 3;

  /// FRESH-SESSION LOAD RESILIENCE (root cause of the REMAINING
  /// "casting from a player screen's Cast button sometimes connects but
  /// the TV just sits on the cast screen" inconsistency, after the
  /// CONNECT-THEN-LOAD RACE FIX and LOAD-ACK RETRY above). Two gaps were
  /// left, both only reachable in the first seconds after a connect —
  /// exactly when the PlaybackCoordinator's LOCAL -> REMOTE handoff fires
  /// its one and only load:
  ///
  ///  1. The very FIRST send was never retried. [_verifyLoadAcked] is
  ///     only armed after `loadMedia()`/`queueLoadItems()` returns
  ///     successfully, so if that first call THREW or TIMED OUT (the
  ///     receiver's media channel still attaching), load()/loadQueue()
  ///     rethrew straight into the handoff's catch block, which aborts
  ///     the handoff for good — no retry ever happened, the TV stayed on
  ///     its splash screen. See [_sendInitialLoad].
  ///  2. The ack-retry budget (3 re-sends, ~9s) is shorter than how long
  ///     a TV can take to launch the receiver app (a TV waking from
  ///     standby/ambient mode routinely needs 10s+), so a slow-but-
  ///     healthy receiver ran out of retries while still not ready.
  ///
  /// Both are widened ONLY for a session that connected within
  /// [_freshSessionWindow]; a load on an established session behaves
  /// exactly as before (same single send, same 3 ack retries), so the
  /// connect-first/Home-screen flow and every mid-session action are
  /// untouched. Retries never fire once the receiver has reported
  /// anything for the load ([_loadAcked]) and a newer load/disconnect
  /// ([_loadGeneration]) silently ends any older retry loop.
  DateTime? _sessionConnectedAt;
  static const _freshSessionWindow = Duration(seconds: 30);
  static const _freshLoadAckMaxRetries = 16;
  // CAST START DELAY FIX: on a fresh session the receiver is most likely to
  // have silently dropped the first load, so check for its ack sooner.
  // Retries are raised to match (16 x 1.5s) so the total re-send patience
  // stays at the previous ~24s (8 x 3s) for a TV that is slow to launch.
  static const _freshLoadAckTimeout = Duration(milliseconds: 1500);
  static const _initialSendMaxAttempts = 4;
  static const _initialSendRetryDelay = Duration(milliseconds: 1500);
  static const _initialSendRetryBudget = Duration(seconds: 20);

  bool get _isFreshSession {
    final since = _sessionConnectedAt;
    return since != null &&
        DateTime.now().difference(since) < _freshSessionWindow;
  }

  /// Sends the FIRST load for [generation], re-trying a failed/timed-out
  /// send while the session is still fresh (see [_sessionConnectedAt]).
  /// Returns true once the send went through (or the receiver already
  /// reported the media despite the call erroring — a slow response, not
  /// a failure), false if a newer load/disconnect superseded this one
  /// while waiting (the caller must then stop without seeding any state),
  /// and rethrows the last error once retries are exhausted or the
  /// session isn't fresh — i.e. exactly the old behavior in that case.
  Future<bool> _sendInitialLoad(
    CastSession session,
    int generation,
    Future<void> Function() send, {
    required String label,
  }) async {
    final started = DateTime.now();
    var attempt = 0;
    while (true) {
      attempt++;
      try {
        await send();
        return generation == _loadGeneration;
      } catch (e) {
        // The call errored/timed out but the receiver did report the
        // media: the load arrived, only the method-channel reply was
        // late. Re-sending would restart playback — treat as sent.
        if (generation == _loadGeneration && _loadAcked) return true;
        if (generation != _loadGeneration) return false;

        final withinBudget =
            DateTime.now().difference(started) < _initialSendRetryBudget;
        final canRetry = _isFreshSession &&
            withinBudget &&
            attempt < _initialSendMaxAttempts &&
            session.connectionState.value == CastConnectionState.connected;
        if (!canRetry) rethrow;

        debugPrint(
          'CASTING DEBUG: first load of \"$label\" failed on a fresh '
          'session ($e) — retrying (attempt ${attempt + 1}/'
          '$_initialSendMaxAttempts).',
        );
        await Future<void>.delayed(_initialSendRetryDelay);
        if (generation != _loadGeneration) return false;
        if (_loadAcked) return true;
      }
    }
  }

  /// FIRST-CONNECT MINI-PLAYER FIX (root cause). When a load is sent
  /// right after a *fresh* connect (the receiver app was only just
  /// launched), the Cast SDK's `mediaStatusStream` can emit a `null`
  /// status while the receiver is still attaching its media channel —
  /// even though the load itself succeeds and the TV goes on to play
  /// the item. `_applyMediaStatus(null)` used to treat that as "nothing
  /// is loaded" and wiped `session.currentItem` *and* [_loadedItems]
  /// (the only thing the receiver-advance recovery below can restore
  /// from). Every later, real status then found nothing to resolve its
  /// `contentId` against, so `currentItem` stayed null for the rest of
  /// the session: the cast mini player (which needs a non-null video
  /// `currentItem`) flashed up from the optimistic `load()` seed and
  /// vanished, and CastToButton's "already casting this title?" check
  /// failed too. Tapping Cast again re-ran `load()` after the SDK's
  /// initial nulls had passed, which is why only the repeat tap "worked".
  ///
  /// Same time-based settle window JellyfinRemoteTransport already uses
  /// for its own "nothing playing" snapshot right after a load
  /// (`_lastLoadIssuedAt`/`_loadSettleGrace`): a null status this soon
  /// after a load is the receiver catching up, not a real stop. Stamped
  /// by [_beginLoadAttempt] and refreshed by [_armLoadWatchdog] (which
  /// runs after every successful send, including ack-retry re-sends);
  /// cleared by stop().
  DateTime? _lastLoadIssuedAt;
  static const _loadSettleGrace = Duration(seconds: 10);

  bool get _withinLoadSettleGrace {
    final since = _lastLoadIssuedAt;
    return since != null &&
        DateTime.now().difference(since) < _loadSettleGrace;
  }

  int _beginLoadAttempt() {
    _loadAcked = false;
    _lastLoadIssuedAt = DateTime.now();
    return ++_loadGeneration;
  }

  void _verifyLoadAcked(
    CastSession session,
    int generation,
    Future<void> Function() resend, {
    required String label,
  }) {
    // FRESH-SESSION LOAD RESILIENCE: a freshly connected receiver gets a
    // longer re-send budget — see [_sessionConnectedAt].
    final maxRetries =
        _isFreshSession ? _freshLoadAckMaxRetries : _loadAckMaxRetries;
    unawaited(() async {
      for (var attempt = 1; attempt <= maxRetries; attempt++) {
        final deadline = DateTime.now().add(
          _isFreshSession ? _freshLoadAckTimeout : _loadAckTimeout,
        );
        while (DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 200));
          if (generation != _loadGeneration) return; // superseded/disconnected
          if (_loadAcked) return; // receiver reported the media — done
        }
        if (generation != _loadGeneration || _loadAcked) return;
        try {
          if (session.connectionState.value != CastConnectionState.connected) {
            return;
          }
          debugPrint(
            'CASTING DEBUG: receiver never reported \"$label\" after load — '
            're-sending (attempt $attempt/$maxRetries).',
          );
          await resend();
          if (generation != _loadGeneration) return;
          _armLoadWatchdog(session);
        } catch (e) {
          debugPrint('CASTING DEBUG: load re-send for \"$label\" failed: $e');
        }
      }
    }());
  }

  void _armLoadWatchdog(CastSession session) {
    _lastLoadIssuedAt = DateTime.now(); // see [_lastLoadIssuedAt]
    _loadWatchdog?.cancel();
    _loadWatchdog = Timer(_loadWatchdogDuration, () {
      if (session.playbackState.value == CastPlaybackState.loading ||
          session.playbackState.value == CastPlaybackState.idle) {
        session.playbackState.value = CastPlaybackState.error;
        session.lastError.value =
            '${session.device.displayName} accepted the load request but '
            'never started playing. This usually means the file\'s '
            'format isn\'t one the device can play directly.';
      }
    });
  }

  void _disarmLoadWatchdog() {
    _loadWatchdog?.cancel();
    _loadWatchdog = null;
  }

  @override
  Stream<List<CastDevice>> discover() {
    _discoverySubscription?.cancel();
    unawaited(_discoveryController?.close());

    final controller = StreamController<List<CastDevice>>.broadcast();
    _discoveryController = controller;

    unawaited(_startSdkDiscovery(controller));

    return controller.stream;
  }

  Future<void> _startSdkDiscovery(
    StreamController<List<CastDevice>> controller,
  ) async {
    // Held until stopDiscovery(); taken first so it is already on while the
    // SDK is being set up.
    await _setMulticastLock(true);

    try {
      await _ensureContextInitialized();
    } catch (_) {
      return; // Already logged; the next discover() tries setup again.
    }

    await _ensureNearbyPermission();

    // stopDiscovery() or a newer discover() took over while the SDK was
    // being set up (or the permission prompt was open) — that one owns
    // the scan now.
    if (_discoveryController != controller || controller.isClosed) return;

    void publish(List<GoogleCastDevice> found) {
      // Merged, never cleared: the SDK briefly reports a partial/empty list
      // while it refreshes, and wiping the handles then made a tap in that
      // window fail with "no longer available" (the "first attempt fails,
      // second works" symptom). A stale handle just fails the connect and
      // is retried by CastManager; a missing one could never succeed.
      _knownDevices.addEntries(found.map((d) => MapEntry(d.uniqueID, d)));

      if (!controller.isClosed) {
        controller.add(found.map(_deviceFromGoogleCastDevice).toList());
      }
    }

    _discoverySubscription =
        GoogleCastDiscoveryManager.instance.devicesStream.listen(
      publish,
      onError: (Object e) {
        debugPrint('GoogleCastTransport: discovery stream error: $e');
      },
    );

    try {
      await GoogleCastDiscoveryManager.instance
          .startDiscovery(activeScan: true);
    } catch (e) {
      debugPrint('GoogleCastTransport: startDiscovery failed: $e');
      return;
    }

    // Safety net: if the plugin's stream does not replay receivers that
    // were already known before this listener attached, pick them up here.
    if (_discoveryController != controller || controller.isClosed) return;
    try {
      final already = GoogleCastDiscoveryManager.instance.devices;
      if (already.isNotEmpty) publish(already);
    } catch (e) {
      debugPrint('GoogleCastTransport: reading known devices failed: $e');
    }
  }

  @override
  Future<void> stopDiscovery() async {
    // ROOT CAUSE (Google Cast devices stopping to appear after closing and
    // quickly reopening the device picker): this used to `await` the
    // subscription cancel/controller close and only THEN null the fields
    // and stop the SDK scan. CastManager fires stopDiscovery()
    // unawaited and a re-open calls discover() right away, so by the time
    // this continuation resumed it was nulling out — and closing — the
    // NEW subscription/controller and stopping the SDK scan the new
    // discover() had just started. Detaching the current ones first and
    // only stopping the SDK scan if no newer discover() has begun keeps a
    // quick reopen's discovery alive.
    final subscription = _discoverySubscription;
    final controller = _discoveryController;
    _discoverySubscription = null;
    _discoveryController = null;
    await subscription?.cancel();
    await controller?.close();
    if (_discoveryController != null) return; // A newer discover() owns the scan now.

    // Safe to call even though CastManager may still hold an active
    // session using a device from this discovery pass — stopping
    // *discovery* doesn't touch an already-connected session/media
    // client, same contract JellyfinRemoteTransport.stopDiscovery()
    // already follows (that one tears down its polling timer, not the
    // connection).
    GoogleCastDiscoveryManager.instance.stopDiscovery();
    unawaited(_setMulticastLock(false));
  }

  CastDevice _deviceFromGoogleCastDevice(GoogleCastDevice device) {
    return CastDevice(
      id: '$_idPrefix${device.uniqueID}',
      displayName: device.friendlyName,
      roomOrGroup: device.modelName,
      transports: const {
        // Google Cast's Default Media Receiver always supports the core
        // transport controls regardless of what's loaded. Per the Phase
        // 2 architecture doc, audio/subtitle track selection is the one
        // asymmetric case: whether that's actually possible depends on
        // the *loaded item* (does it declare separate sidecar tracks the
        // Cast SDK knows about?), not on the device — and the Default
        // Media Receiver in practice only ever exposes explicitly
        // declared sidecar tracks (e.g. a WebVTT subtitle URL passed at
        // load time), not arbitrary tracks already muxed inside an MKV/
        // MP4 container the way Jellyfin's static-stream files usually
        // have them. Jellyfin's `MediaSources`/`MediaStreams` describe
        // exactly that kind of embedded, in-container track.
        //
        // FOLLOW-UP FIX (flagged in Phase 5/11, addressed here):
        // `load()` below now fetches Jellyfin's text-subtitle tracks via
        // `MediaStreamParser.subtitles()` (the same call PlayerManager
        // already makes for local mpv playback) and declares any
        // text-based ones as sidecar WebVTT tracks at load time, which
        // the Default Media Receiver *can* select — so
        // `subtitleTrackSelection` is no longer a fixed `false` here;
        // `load()` flips it on `session.capabilityNotifier` per loaded
        // item once it knows whether that item actually has a usable
        // text subtitle. It stays `false` below as the pre-load default
        // so a session between connect() and the first load() doesn't
        // show a subtitle control with nothing loaded to select from
        // yet. `audioTrackSelection` stays permanently unreachable
        // through this map for a different reason: it needs *embedded*
        // multi-audio switching, which the stock receiver genuinely
        // cannot do without a custom Nemesis Cast receiver — no
        // per-item fix changes that, so it's not handled in `load()`
        // the way subtitles are.
        CastTransportKind.googleCast: CastCapability(
          play: true,
          pause: true,
          stop: true,
          seek: true,
          volume: true,
          // CASTING FIX (music never played via Google Cast — or
          // Jellyfin Remote, see CastCapability.fromJellyfinSession's
          // own fix): `CastManager.playQueue()` — the ONLY path any
          // song/album/playlist actually casts through, since even a
          // single tapped song goes through
          // `PlaybackCoordinator.playAudioQueueOnActiveCast` ->
          // `CastManager.playQueue()` rather than the single-item
          // `loadAndPlay()` movies use — refuses to even call
          // `loadQueue()` unless `session.capability.queue` is already
          // true. That flag used to only ever get set true as a *side
          // effect of* `loadQueue()` succeeding (see the `copyWith`
          // near the end of `loadQueue()` below) — a genuine catch-22
          // that made the very first queue load impossible on every
          // Google Cast session, every time, regardless of file format.
          // The Default Media Receiver has always supported
          // `queueLoadItems()` from the start of a session with nothing
          // preloaded, so there's no real reason this needs to start
          // false and wait for a successful load to flip it — video
          // casting (CastToButton on Movie/Show Details) never hit
          // this because it calls `loadAndPlay()`/`load()` directly,
          // which was never gated this way.
          queue: true,
          // Casting playback-rate fix: `GoogleCastRemoteMediaClient
          // .setPlaybackRate()` is a real, shipped API on this package
          // (its own changelog documents fixing a case where it had no
          // effect on iOS, which only makes sense if the method itself
          // is genuine and cross-platform) — unlike audio/subtitle
          // track selection, this isn't conditional on what's loaded,
          // so it's set true here at the device level rather than
          // needing `load()`'s per-item flip the way
          // `subtitleTrackSelection` does above.
          playbackRate: true,
        ),
      },
    );
  }

  String _uniqueIdOf(CastDevice device) {
    if (!device.id.startsWith(_idPrefix)) {
      throw StateError(
        'GoogleCastTransport was handed a non-Google-Cast device: '
        '${device.id}',
      );
    }
    return device.id.substring(_idPrefix.length);
  }

  @override
  Future<CastSession> connect(CastDevice device) async {
    await _ensureContextInitialized();

    final uniqueId = _uniqueIdOf(device);
    final googleDevice = _knownDevices[uniqueId];
    if (googleDevice == null) {
      throw Exception('${device.displayName} is no longer available.');
    }

    final session = CastSession(
      device: device,
      transportKind: CastTransportKind.googleCast,
      initialConnectionState: CastConnectionState.connecting,
    );

    // CONNECT-THEN-LOAD RACE FIX (casting started from a player screen's
    // Cast button stuck on the TV's splash screen until the item was
    // re-sent by hand): `startSessionWithDevice()`'s Future completes
    // when the Cast SDK has accepted the *request* to start a session,
    // not once the session is actually live on the receiver
    // (receiver app launched, media channel attached). CastManager
    // publishes the returned session the instant this method returns,
    // and PlaybackCoordinator's LOCAL -> REMOTE handoff reacts to that
    // synchronously by calling loadMedia() — into a session that
    // doesn't have a remote media client yet, where it is silently
    // dropped (no error, no status, receiver left idle). Re-sending the
    // same item later (Play With, Cast button again) worked only
    // because by then the session had finished starting. Subscribing to
    // `currentSessionStream` *before* the start request (so an emission
    // during the request can't be missed) and waiting for the first
    // non-null session closes the gap; bounded by [_sessionReadyTimeout]
    // and best-effort past it, so a stream that never emits can only
    // ever cost that delay, never hang the connect.
    final sessionReady = Completer<void>();
    final readySub =
        GoogleCastSessionManager.instance.currentSessionStream.listen(
      (googleSession) {
        if (googleSession != null && !sessionReady.isCompleted) {
          sessionReady.complete();
        }
      },
    );

    try {
      await GoogleCastSessionManager.instance
          .startSessionWithDevice(googleDevice)
          .timeout(_callTimeout);
      await sessionReady.future.timeout(
        _sessionReadyTimeout,
        onTimeout: () {},
      );
      // Small settle for the receiver's media channel to attach after
      // the session reports started — loadMedia() sent in the same
      // instant can still race it on some receivers.
      await Future<void>.delayed(_sessionSettleDelay);
    } catch (e) {
      session.connectionState.value = CastConnectionState.error;
      session.lastError.value = e is TimeoutException
          ? '${device.displayName} did not respond in time.'
          : 'Failed to connect to ${device.displayName}: $e';
      rethrow;
    } finally {
      await readySub.cancel();
    }

    session.connectionState.value = CastConnectionState.connected;
    _sessionConnectedAt = DateTime.now(); // see [_sessionConnectedAt]
    _startStateSync(session);
    return session;
  }

  @override
  Future<void> disconnect(CastSession session) async {
    _loadGeneration++; // ends any in-flight load verifier
    _lastLoadIssuedAt = null;
    _sessionConnectedAt = null;
    _disarmLoadWatchdog();
    await _mediaStatusSubscription?.cancel();
    await _positionSubscription?.cancel();
    await _sessionSubscription?.cancel();
    _mediaStatusSubscription = null;
    _positionSubscription = null;
    _sessionSubscription = null;

    try {
      await GoogleCastSessionManager.instance.endSessionAndStopCasting();
    } catch (_) {
      // Already gone (TV powered off, session dropped on its own,
      // etc.) — nothing left to tear down.
    }
  }

  void _startStateSync(CastSession session) {
    _mediaStatusSubscription?.cancel();
    _positionSubscription?.cancel();
    _sessionSubscription?.cancel();

    // Real-time, push-based state sync — the Cast SDK's own
    // mediaStatusStream/playerPositionStream, no polling at all. This is
    // the "no manual polling needed here" case the Phase 2 doc called
    // out for Google Cast specifically, unlike JellyfinRemoteTransport's
    // deliberate polling fallback.
    _mediaStatusSubscription =
        GoogleCastRemoteMediaClient.instance.mediaStatusStream.listen(
      (status) => _applyMediaStatus(session, status),
    );

    _positionSubscription =
        GoogleCastRemoteMediaClient.instance.playerPositionStream.listen(
      // SMOOTH-SEEK-BAR FIX: even though this is the Cast SDK's own
      // push-based stream (no polling), it still only emits roughly
      // once a second — reportPosition() feeds it to the session's
      // local interpolator so the seek bar advances smoothly between
      // those emissions instead of visibly stepping each time.
      (position) => session.reportPosition(position),
    );

    _sessionSubscription =
        GoogleCastSessionManager.instance.currentSessionStream.listen(
      (googleSession) {
        if (googleSession == null) {
          // The Cast SDK itself decided the session ended (receiver
          // powered off, network drop, user disconnected from the
          // system Cast dialog outside our own UI, etc.) — surface it
          // exactly like JellyfinRemoteTransport does when its polled
          // session disappears, rather than leaving the UI showing a
          // stale "connected" state.
          _disarmLoadWatchdog();
          _sessionConnectedAt = null;
          session.connectionState.value = CastConnectionState.disconnected;
          session.playbackState.value = CastPlaybackState.stopped;
          session.lastError.value =
              '${session.device.displayName} disconnected.';
        }
      },
    );
  }

  void _applyMediaStatus(CastSession session, GoggleCastMediaStatus? status) {
    if (status == null) {
      // FIRST-CONNECT MINI-PLAYER FIX: see [_lastLoadIssuedAt]. A null
      // status right after a load is the receiver still attaching, not
      // "nothing loaded" — leave currentItem/_loadedItems/playbackState
      // exactly as load()/loadQueue() seeded them.
      if (_withinLoadSettleGrace) {
        debugPrint(
          'CASTING DEBUG: ignoring null media status inside post-load '
          'settle window (currentItem preserved).',
        );
        return;
      }
      session.playbackState.value = CastPlaybackState.idle;
      // No status at all is a different situation than a reported idle
      // status with a reason — genuinely unknown, so this is left for
      // PlaybackCoordinator's isSeekPending-timing fallback to interpret
      // rather than asserting a specific CastIdleReason we don't have.
      session.idleReason.value = null;
      session.currentItem.value = null;
      _loadedItems = const [];
      return;
    }

    // Compared by .name rather than the enum constant directly: I could
    // only confirm `CastMediaPlayerState.playing` against the package's
    // published usage examples, not the full member list, without a
    // toolchain to check the installed version's enums.dart myself. This
    // degrades safely (falls through to leaving playbackState as-is) if
    // a name below doesn't match, rather than failing to compile at all
    // over the states I couldn't verify — please confirm against
    // `flutter_chrome_cast`'s `enums.dart` and tighten this to direct
    // enum comparisons once you can run `flutter analyze`.
    // LOAD-ACK RETRY: any sign the receiver has the media (see the field
    // doc on [_loadAcked]) confirms the most recent load arrived.
    if (status.playerState.name != 'idle' || status.mediaInformation != null) {
      _loadAcked = true;
    }

    switch (status.playerState.name) {
      case 'playing':
        session.playbackState.value = CastPlaybackState.playing;
        // SEEK-RESTART FIX: any non-idle status supersedes whatever idle
        // reason a *previous* idle dip left behind — see CastIdleReason's
        // doc comment. Without this, a stale `interrupted`/`finished`
        // from an earlier idle blip could linger and be misread by a
        // later, genuinely-unrelated idle transition.
        session.idleReason.value = null;
        _disarmLoadWatchdog();
      case 'paused':
        session.playbackState.value = CastPlaybackState.paused;
        session.idleReason.value = null;
        _disarmLoadWatchdog();
      case 'buffering':
        session.playbackState.value = CastPlaybackState.buffering;
        session.idleReason.value = null;
        // Not disarmed here on purpose — genuinely buffering (as
        // opposed to never having started) is exactly the state this
        // watchdog should keep watching through, in case it's actually
        // stuck buffering forever rather than making progress.
      case 'loading':
        // STUCK PLAY/PAUSE-ICON FIX: `CastMediaPlayerState` actually has
        // a `loading` member (confirmed against the package's published
        // enum docs) distinct from `idle` — this case was missing
        // entirely before, so a receiver reporting "loading" fell
        // through to `default` and left `playbackState` completely
        // unchanged. That's harmless right after `load()`/`loadQueue()`
        // (which already seed `.loading` themselves), but meant this
        // transport was silently dropping a real status update instead
        // of just confirming what was already assumed. Mapped onto our
        // own `.loading` for the same reason `idle`/`buffering` map
        // onto their own direct equivalents just below/above.
        session.playbackState.value = CastPlaybackState.loading;
        session.idleReason.value = null;
      case 'idle':
        session.playbackState.value = CastPlaybackState.idle;
        // SEEK-RESTART FIX (root cause): the Cast SDK's own `idleReason`
        // is the authoritative answer to "did this song actually end, or
        // did *we* just cause this idle dip ourselves (a seek's transient
        // re-buffer, a stop, a fresh load)?" — see CastIdleReason's doc
        // comment for the full reasoning on why this replaces guessing
        // from state-name transitions plus a timing heuristic. Mapped
        // defensively (an unrecognized name degrades to `.none`, which
        // PlaybackCoordinator treats as "not a confirmed natural end" —
        // the same safe direction the enum-name mismatch fallback above
        // already takes elsewhere in this switch) rather than crashing
        // over an idleReason name a future package bump might rename.
        session.idleReason.value = switch (status.idleReason?.name) {
          'finished' => CastIdleReason.finished,
          'cancelled' => CastIdleReason.cancelled,
          'interrupted' => CastIdleReason.interrupted,
          'error' => CastIdleReason.error,
          _ => CastIdleReason.none,
        };
      default:
        // An unrecognized name — see the doc comment above on why this
        // is possible. Left as a debug breadcrumb rather than silently
        // doing nothing, so if a future `flutter_chrome_cast` bump
        // renames states again, that shows up as visible log noise
        // instead of another silent "stuck" report.
        debugPrint(
          'GoogleCastTransport: unrecognized CastMediaPlayerState '
          '"${status.playerState.name}" — playbackState left unchanged.',
        );
    }

    final mediaDuration = status.mediaInformation?.duration;
    if (mediaDuration != null) {
      session.duration.value = mediaDuration;
    }

    // RECEIVER-ADVANCE FIX: see this class's own field doc comment on
    // `_loadedItems`. `contentId` is exactly the Jellyfin item id this
    // transport put on every item it ever sent (`contentId: item.id` in
    // both load() and loadQueue() above), so a mismatch here means the
    // receiver moved on to a different item in its own queue than
    // whatever `session.currentItem` currently says — resolve it back
    // to the real MediaItem instead of leaving the stale one in place.
    // No-ops for a single-item load (nothing else in `_loadedItems` to
    // ever mismatch against) and for any status whose contentId isn't
    // one this transport recognizes (an unrelated/stale status tick).
    final reportedContentId = status.mediaInformation?.contentId;
    if (reportedContentId != null &&
        reportedContentId != session.currentItem.value?.id) {
      for (final candidate in _loadedItems) {
        if (candidate.id == reportedContentId) {
          session.currentItem.value = candidate;
          // AUDIO CHECKMARK FIX: the previous episode's audio index
          // must not carry over to the one the receiver just advanced to.
          _seedActiveAudioTrack(session, candidate);
          break;
        }
      }
    }
  }

  /// The single cast-facing image for [item], per content type — the
  /// Default Media Receiver's card is portrait-shaped, so this always
  /// resolves a poster/logo-style image rather than the landscape
  /// backdrops the in-app screens use as full-bleed backgrounds (a
  /// backdrop stretched into that portrait frame is what this replaces).
  /// Returns at most one image; the receiver only ever renders one
  /// regardless of how many are declared.
  List<GoogleCastImage> _imagesFor(MediaItem item) {
    if (item.live) {
      // `item.logo` is exactly what Nemesis's own live TV player screen
      // shows (the PulsingLogo loading/buffering overlay) — not
      // `item.image`, which is what the Live TV browse screens'
      // channel_logo_card/channel_card use instead. Both happen to
      // resolve to the same Jellyfin Primary-image URL today (see
      // MediaService.mediaItemFromJellyfin's TvChannel branch), but
      // this points at the semantically "player screen" field on
      // purpose so the two can't silently diverge later without this
      // needing a second look.
      return [
        if (item.logo != null) GoogleCastImage(url: Uri.parse(item.logo!)),
      ];
    }

    // Episodes: MediaItem has no "series poster" field of its own —
    // `item.image` is the EPISODE's own Primary image (a landscape
    // still, not a poster) and `item.backdrop` is the SERIES' backdrop
    // (also landscape — see mediaItemFromJellyfin's backdropLogoId
    // comment). Building the series' own Primary-image URL directly
    // here, the same way mediaItemFromJellyfin builds every other image
    // URL, is what actually gets a portrait show poster onto the cast
    // card instead.
    if (item.seriesId != null) {
      return [
        GoogleCastImage(
          url: Uri.parse(MediaService.getPrimaryImage(item.seriesId!)),
        ),
      ];
    }

    // Movies (and anything else without a seriesId): the poster/card
    // image, never the backdrop.
    //
    // CASTING FIX (no artwork/poster on the TV for a local song/video):
    // `item.image` for a local item (LocalMusicService's on-device songs,
    // ExternalMediaHandler's Open With files — see MediaItem.isLocal)
    // used to always be an on-disk artwork path, never an http(s) URL —
    // nothing downstream served that file to the receiver the way
    // LocalCastServer already did for the media itself, so handing it
    // straight to GoogleCastImage would have declared a URL the receiver
    // could never actually fetch. `CastManager._ensureCastableLocalItem`
    // now registers a local item's cached artwork/video-frame file with
    // LocalCastServer the same way it already does for the media itself,
    // and rewrites `item.image`/`item.backdrop` to the resulting http(s)
    // URL before this ever runs — so by the time `_imagesFor` sees a
    // local item, `item.image` is either a real, receiver-fetchable URL
    // or still null/local (source file missing, artwork extraction
    // failed, no LAN address available), in which case the
    // `_looksLikeHttpUrl` check below correctly still omits it rather
    // than sending a broken one. The in-app cast screens' own no-art
    // treatment (see CastingBackdrop) still covers that remaining case.
    return [
      if (item.image != null && _looksLikeHttpUrl(item.image!))
        GoogleCastImage(url: Uri.parse(item.image!)),
    ];
  }

  bool _looksLikeHttpUrl(String value) {
    final uri = Uri.tryParse(value);
    return uri != null && (uri.scheme == 'http' || uri.scheme == 'https');
  }

  /// Cast-facing metadata for [item], matching whatever `_imagesFor`
  /// picked above. Async only because the live-TV branch needs a
  /// network round trip for the current program — MediaItem doesn't
  /// carry EPG data on itself; the movie/TV-show branches resolve
  /// synchronously and just await trivially.
  Future<GoogleCastMediaMetadata> _metadataFor(MediaItem item) async {
    final images = _imagesFor(item);

    if (item.live) {
      return GoogleCastGenericMediaMetadata(
        title: item.title,
        subtitle: await _currentProgramTitle(item.id),
        images: images,
      );
    }

    // Songs: GoogleCastMusicMediaMetadata is what actually gets the
    // Default Media Receiver's built-in Now Playing treatment — art on
    // one side, title/artist stacked as text, darkened/blurred
    // background — the same layout the stock receiver already renders
    // for any other Cast sender's music. Previously audio fell through
    // to the Movie branch below, which has no `artist` field at all, so
    // casting a song never actually showed who it was by.
    if (item.audioOnly) {
      return GoogleCastMusicMediaMetadata(
        title: item.title,
        artist: item.artistName.isNotEmpty ? item.artistName : null,
        // `item.subtitle` isn't used here — it's a display fallback
        // chain that can resolve to AlbumArtist *or* Album depending on
        // what Jellyfin sent, so it can't be trusted to always be the
        // album name specifically. Reading `Album` directly off the
        // raw Jellyfin item is the only reliable way to get the real
        // album name, when there is one.
        albumName: item.raw?['Album']?.toString(),
        images: images,
      );
    }

    if (item.episodeNumber != null && item.seasonNumber != null) {
      // Unlike the underlying native Cast SDK (and unlike this package's
      // own Movie/Music/Generic metadata classes), flutter_chrome_cast's
      // GoogleCastTvShowMediaMetadata constructor has no `title` param at
      // all — only seriesTitle/season/episode/images/originalAirDate. So
      // there's no field to carry the episode's own name here; the
      // receiver's "Season X, Episode Y" line under seriesTitle is as
      // specific as this class allows.
      return GoogleCastTvShowMediaMetadata(
        episode: item.episodeNumber,
        season: item.seasonNumber,
        seriesTitle: item.subtitle,
        images: images,
      );
    }

    return GoogleCastMovieMediaMetadata(
      title: item.title,
      images: images,
    );
  }

  /// The currently-airing program's name for channel [channelId], or
  /// null if the guide fetch fails or nothing is airing right now —
  /// reuses EpgUtils.pickCurrentProgram, the exact same pick the
  /// in-player info sheet and Live TV detail screen's Now Playing card
  /// already use, so the cast card can never show a different "what's
  /// on now" than the rest of the app does for the same channel. Best-
  /// effort: a failed guide fetch shouldn't block starting the cast
  /// itself, just falls back to no subtitle.
  Future<String?> _currentProgramTitle(String channelId) async {
    try {
      final programs = await MediaService.getPrograms(channelId: channelId);
      final current = EpgUtils.pickCurrentProgram(programs);
      return current?['Name']?.toString();
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> load(
    CastSession session,
    MediaItem item, {
    Duration startAt = Duration.zero,
  }) async {
    session.playbackState.value = CastPlaybackState.loading;
    session.currentItem.value = item;
    // RECEIVER-ADVANCE FIX: see this class's own field doc comment.
    // A single-item load() replaces whatever the receiver had, so this
    // is the only item a later status update could ever legitimately
    // resolve to until the next load()/loadQueue() call replaces it.
    _loadedItems = [item];

    // CASTING FIX: item.streamUrl is sometimes a *local* path/content URI
    // (a downloaded file, or a purely on-device LocalMusicService song —
    // see MediaItem.isLocal/castStreamUrl's doc comments) rather than the
    // absolute, directly-fetchable Jellyfin URL PlayerManager/mpv use for
    // *local* playback. A Chromecast receiver fetches whatever URL it's
    // given itself, over the network, with no access to this phone's
    // filesystem — handing it a local path just silently never loads
    // (this used to be the "cast a downloaded/local song and the TV
    // never responds" bug). `item.castStreamUrl` resolves to the real
    // network URL when one exists (remoteStreamUrl for downloaded items,
    // or streamUrl itself when it's already http(s)) and null only for
    // genuinely local-only content with no server-side presence at all.
    final castUrl = item.castStreamUrl;
    if (castUrl == null) {
      // LOCAL CASTING: reachable in the ordinary case only if `load()`
      // is ever called without going through
      // CastManager.loadAndPlay/playQueue's own
      // `_ensureCastableLocalItem` resolution step first — that step
      // already turns a castable local item's `remoteStreamUrl` into a
      // real LocalCastServer URL (making `castStreamUrl` non-null)
      // before anything reaches here, or throws its own specific
      // LocalCastUnsupportedException before `load()` is even called at
      // all for one that genuinely can't be cast. This message is
      // deliberately non-committal about *why* rather than the old flat
      // "is a local file and can't be cast" — since local items can
      // often be cast now, this path being hit at all means something
      // upstream skipped that resolution step, not that this item is
      // inherently uncastable.
      final err = item.isLocal
          ? '"${item.title}" couldn\'t be cast to '
              '${session.device.displayName}.'
          : '"${item.title}" has no network-reachable source to cast to '
              '${session.device.displayName}.';
      session.playbackState.value = CastPlaybackState.error;
      session.lastError.value = err;
      throw StateError(err);
    }

    // Resolves the real URL + content type to hand the receiver — see
    // `_resolveCastMedia`'s doc comment for the two bugs this fixes
    // (music always using the wrong, HLS-manifest URL with a
    // mismatched content type, and video/episodes whose default audio
    // track uses a codec the receiver can't decode at all).
    final resolved = _resolveCastMedia(item);

    final metadata = await _metadataFor(item);

    // FOLLOW-UP FIX (flagged in Phase 5/11, addressed here): declare any
    // Jellyfin text-subtitle tracks as sidecar WebVTT tracks so the
    // stock Default Media Receiver can actually select them — see the
    // capability doc comment on `_deviceFromGoogleCastDevice` above for
    // why this is the one case Google Cast's capability is computed per
    // loaded item rather than fixed at discovery time.
    final subtitleTracks = _subtitleTracksFor(item);
    final defaultSubtitleId = _defaultSubtitleTrackId(item, subtitleTracks);

    final mediaInfo = GoogleCastMediaInformation(
      contentId: item.id,
      streamType: item.live
          ? CastMediaStreamType.live
          : CastMediaStreamType.buffered,
      contentUrl: resolved.url,
      contentType: resolved.contentType,
      // DURATION FIX: never set before, so `status.mediaInformation
      // .duration` — the *only* thing `_applyMediaStatus` ever wrote
      // `session.duration` from — stayed null for the whole session,
      // which is why the cast info tab's right-hand time always read
      // 0:00:00 and, worse, silently disabled the seek bar entirely
      // (`CastSeekBar` only enables `onChanged` once `duration >
      // Duration.zero`). Jellyfin already told this app the real
      // runtime when the item was fetched — no reason to depend on the
      // receiver re-deriving it from the stream. `item.live` channels
      // have no fixed runtime, so this is left null for those and the
      // seek bar/duration label naturally stay hidden/disabled for
      // live, same as before.
      duration: item.live || item.runtime <= Duration.zero
          ? null
          : item.runtime,
      metadata: metadata,
      tracks: subtitleTracks.isEmpty ? null : subtitleTracks,
    );

    final resumeAt = startAt > Duration.zero ? startAt : item.resumePosition;

    Future<void> sendLoad() => GoogleCastRemoteMediaClient.instance
        .loadMedia(
          mediaInfo,
          autoPlay: true,
          playPosition: resumeAt,
          activeTrackIds:
              defaultSubtitleId != null ? [defaultSubtitleId] : null,
        )
        .timeout(_callTimeout);

    final loadGeneration = _beginLoadAttempt();

    try {
      final sent = await _sendInitialLoad(
        session,
        loadGeneration,
        sendLoad,
        label: item.title,
      );
      // Superseded by a newer load/disconnect while retrying — that load
      // owns the session state now, so seed nothing from this one.
      if (!sent) return;
    } catch (e) {
      session.playbackState.value = CastPlaybackState.error;
      session.lastError.value = e is TimeoutException
          ? '${session.device.displayName} did not respond to load in time.'
          : 'Failed to start playback on ${session.device.displayName}: $e';
      rethrow;
    }

    // Seed immediately rather than waiting on the first status
    // round-trip — same reasoning as the `duration:` hint above, just
    // applied on this side too so the seek bar/duration label are
    // correct and interactive from the very first frame instead of
    // popping to life a second or two later once a status update
    // happens to arrive. `_applyMediaStatus` still overwrites this the
    // moment the receiver reports its own value, so this is only ever
    // the fallback for the gap before that first report.
    if (!item.live && item.runtime > Duration.zero) {
      session.duration.value = item.runtime;
    }

    if (defaultSubtitleId != null) {
      session.activeSubtitleTrackId.value = defaultSubtitleId;
    }

    // AUDIO CHECKMARK FIX (Audio sheet showed nothing selected until a
    // track was tapped): `session.activeAudioTrackId` used to be written
    // in exactly one place — `selectAudioTrack` below, after a manual
    // pick — so for a freshly loaded movie/episode it stayed null (or
    // kept the PREVIOUS item's value across an episode switch) while the
    // TV was in fact playing the file's default audio stream.
    // AudioSelector's cast branch reads this notifier for its checkmark,
    // hence the blank list. Seeded here, on every load, with the stream
    // that is really playing: a forced track from an earlier pick
    // (`CastAudioStreamOverride`, which survives a reload) or else the
    // default one.
    _seedActiveAudioTrack(session, item);

    _armLoadWatchdog(session);
    _verifyLoadAcked(session, loadGeneration, sendLoad, label: item.title);

    // AUDIO-TRACK SWITCH FOR JELLYFIN-BACKED CASTING (movies/episodes,
    // downloaded or not — "app content" as opposed to Open With/Play
    // With): this used to stay permanently false, with `selectAudioTrack`
    // below unconditionally throwing, on the theory that the Default
    // Media Receiver can't switch an embedded audio track inside an
    // already-loaded file — true, but beside the point, since VLC's own
    // Cast support doesn't switch the loaded file's track either: it
    // re-requests the stream with the wanted track baked in and reloads
    // at the current position. Jellyfin's own HLS transcoder
    // (`MediaService.getVideoCastTranscodeUrl`'s `AudioStreamIndex`) can
    // already do exactly that server-side remux/re-encode — this is the
    // same mechanism the container/codec-transcode branch in
    // `_resolveCastMedia` already uses, just aimed at a *chosen* track
    // instead of the default one. See `selectAudioTrack` below for the
    // reload itself. Gated on more than one audio stream existing at
    // all — a single-track file has nothing to switch to — and never for
    // local/external items (no server to remux for) or live channels
    // (can't renegotiate a live broadcast mid-stream).
    final audioStreamCount = item.mediaStreams
            ?.whereType<Map>()
            .where((s) => s['Type'] == 'Audio')
            .length ??
        0;
    final audioSelectable =
        !item.isLocal && !item.live && !item.audioOnly && audioStreamCount > 1;

    // Real capability for *this* loaded item, not the device-level
    // default from `_deviceFromGoogleCastDevice` — flips
    // `subtitleTrackSelection`/`audioTrackSelection` on only when this
    // item actually has something to switch. Every other flag carries
    // over unchanged from whatever `connect()` seeded the session with.
    session.capabilityNotifier.value = session.capability.copyWith(
      subtitleTrackSelection: subtitleTracks.isNotEmpty,
      audioTrackSelection: audioSelectable,
    );
  }

  /// Chromecast's Default Media Receiver only natively decodes these
  /// audio codecs. Anything else on the *selected* audio track — most
  /// commonly DTS/DTS-HD, TrueHD, or a multichannel PCM track pulled
  /// straight off a Blu-ray remux — plays video with no sound at all,
  /// since (unlike mpv locally) the receiver can't decode it and Cast's
  /// direct-stream URL isn't transcoded. This is the file-dependent "no
  /// audio when casting some episodes" bug: it only ever hits titles
  /// whose default audio track happens to use one of these codecs.
  static const Set<String> _castCompatibleAudioCodecs = {
    'aac',
    'mp3',
    'flac',
    'vorbis',
    'opus',
    'pcm_s16le',
    'pcm_s24le',
  };

  /// CONTAINER HISTORY (superseded twice — read this before touching MKV
  /// handling again): an early version of this check forced *any*
  /// non-MP4/WebM/MPEG-TS container through the `.ts` transcode branch
  /// below, on the theory that the stock Default Media Receiver can't
  /// open MKV at all. That was reverted because it broke previously-
  /// working MKV casting — but the revert's own theory (MKV direct-
  /// streams fine, the container was never the problem) turned out to be
  /// wrong too, just in the opposite direction: it happened to look true
  /// only because `_resolveCastMedia`'s default branch was, at the time,
  /// hardcoding `contentType: 'video/mp4'` for every direct-streamed
  /// file regardless of its real container — so an MKV file's actual
  /// bytes were being labeled as MP4 to the receiver. Once that hardcode
  /// was fixed to declare the real `video/x-matroska` type (see the
  /// default branch below), MKV casting broke again — because Google's
  /// Default Media Receiver genuinely has no Matroska demuxer
  /// (https://developers.google.com/cast/docs/media lists MP2T/MP3/MP4/
  /// OGG/WAV/WebM only). The earlier "MKV direct-streams fine" belief was
  /// really "MKV bytes served under a false MP4 label sometimes decode
  /// anyway" — accurate labeling just let the receiver correctly refuse
  /// what it was accurately told it was being given.
  ///
  /// The third attempt introduced `_needsContainerTranscodeForCast` and
  /// routed a Cast-unsupported container with already-compatible codecs
  /// through a cheap HLS *remux* (`MediaService.getVideoCastTranscodeUrl`)
  /// rather than the full re-encode `.ts` path a bad codec needs. The
  /// idea was right; the implementation shipped two defects that between
  /// them left MKV exactly as broken as before and took MP4 down with
  /// it, and both are worth knowing about before touching this again:
  ///
  ///  * The remux URL omitted `MediaSourceId`, which Jellyfin marks
  ///    `[Required]` on `/Videos/{id}/master.m3u8` — so every request
  ///    through the new branch was a 400. Fixed in
  ///    `MediaService.getVideoCastTranscodeUrl`; see its doc comment.
  ///  * The container was read as one exact string off a field that is
  ///    often a comma-separated ffprobe format list and often absent
  ///    entirely, so an ordinary MP4 reading `mov,mp4,m4a,3gp,3g2,mj2`
  ///    was classified as exotic and sent down that same 400ing branch.
  ///    That is why MP4 — which had never needed any of this — stopped
  ///    working at the same moment. Fixed in `_containerTokensFor`; see
  ///    its CONTAINER DETECTION note.
  ///
  /// The current shape also no longer keeps the container and codec
  /// checks in mutually exclusive branches — see `_resolveCastMedia`'s
  /// own comment above the merged branch for why that combination was
  /// unfixable as two separate paths.

  /// The audio MediaStream that will actually play for [item] if it's
  /// direct-streamed as-is — the one flagged `IsDefault`, or Jellyfin's
  /// own first audio stream when nothing is flagged (matches how the
  /// container itself picks a default track when a player doesn't
  /// choose one explicitly).
  Map<String, dynamic>? _defaultAudioStream(MediaItem item) {
    final streams = item.mediaStreams;
    if (streams == null) return null;
    final audio = streams
        .whereType<Map>()
        .where((s) => s['Type'] == 'Audio')
        .map((s) => Map<String, dynamic>.from(s))
        .toList();
    if (audio.isEmpty) return null;
    return audio.firstWhere(
      (s) => s['IsDefault'] == true,
      orElse: () => audio.first,
    );
  }

  /// The audio MediaStream at Jellyfin stream index [index] — used by
  /// the audio-track-switch reload to check whether the *chosen* track
  /// (not necessarily the default one `_defaultAudioStream` looks up)
  /// needs re-encoding for Cast.
  Map<String, dynamic>? _audioStreamByIndex(MediaItem item, int index) {
    final streams = item.mediaStreams;
    if (streams == null) return null;
    for (final s in streams.whereType<Map>()) {
      if (s['Type'] == 'Audio' && s['Index'] == index) {
        return Map<String, dynamic>.from(s);
      }
    }
    return null;
  }

  /// Writes the audio stream that is (or is about to be) playing on the TV
  /// for [item] into `session.activeAudioTrackId`, so the Audio sheet's
  /// checkmark is right from the first frame — see the call site in
  /// `load()` for the bug this closes. A forced track
  /// (`CastAudioStreamOverride`) wins over the file's default stream.
  ///
  /// Only for Jellyfin-backed VOD (movies/episodes): local/external files
  /// take their checkmark from the phone's own player, songs have no
  /// audio-track list, and a live channel can't switch tracks at all — for
  /// those the notifier is cleared rather than left holding a stale index
  /// from whatever was cast before.
  void _seedActiveAudioTrack(CastSession session, MediaItem item) {
    if (item.isLocal || item.live || item.audioOnly) {
      session.activeAudioTrackId.value = null;
      return;
    }
    final forced = item.raw?['CastAudioStreamOverride'];
    session.activeAudioTrackId.value =
        forced is int ? forced : _defaultAudioStream(item)?['Index'] as int?;
  }

  /// Whether [item]'s default audio track needs transcoding for Cast to
  /// have any sound at all — see `_castCompatibleAudioCodecs` above.
  /// Live channels are deliberately excluded: a live stream can't be
  /// re-negotiated mid-broadcast the way a VOD file can, and this app's
  /// transcoded URL branch (`maxHeight`-driven) isn't exercised for live
  /// today, so forcing it here would be new, untested territory rather
  /// than a targeted fix for the reported bug.
  bool _needsAudioTranscodeForCast(MediaItem item) {
    if (item.live || item.audioOnly) return false;
    final codec = _defaultAudioStream(item)?['Codec']?.toString().toLowerCase();
    if (codec == null || codec.isEmpty) return false;
    return !_castCompatibleAudioCodecs.contains(codec);
  }

  /// The video MediaStream that will actually play for [item] if it's
  /// direct-streamed as-is. Same "flagged default, else first" fallback
  /// as [_defaultAudioStream] — a video-only stream list never has
  /// `IsDefault` disagreements in practice (a file has exactly one video
  /// track in the overwhelming majority of cases), but this keeps the
  /// two lookups symmetric rather than assuming `.first` is always safe.
  Map<String, dynamic>? _defaultVideoStream(MediaItem item) {
    final streams = item.mediaStreams;
    if (streams == null) return null;
    final video = streams
        .whereType<Map>()
        .where((s) => s['Type'] == 'Video')
        .map((s) => Map<String, dynamic>.from(s))
        .toList();
    if (video.isEmpty) return null;
    return video.firstWhere(
      (s) => s['IsDefault'] == true,
      orElse: () => video.first,
    );
  }

  /// CASTING FIX ("not all episodes cast — some just fail"): the
  /// counterpart to `_castCompatibleAudioCodecs` that never existed for
  /// video at all. `_needsTranscodeForCast` only ever checked the audio
  /// track — a file whose *video* codec the connected receiver can't
  /// decode (most commonly HEVC/H.265, VP9, AV1, or a legacy MPEG-2/
  /// VC-1/Xvid transfer) was always sent through the plain direct-stream
  /// branch regardless, which is exactly the "accepted the load request
  /// but never started playing" pattern the load watchdog's error
  /// message describes — the receiver has no way to decode what it was
  /// handed, so it never gets anywhere near a real `playing` status, and
  /// the episode just silently fails while a same-show episode encoded
  /// in H.264 casts fine. That per-episode inconsistency (rather than
  /// every episode of a season failing alike) is the signature of a
  /// codec-dependent bug, not a systemic one — Jellyfin libraries
  /// routinely mix encodes across a season (a remux here, a re-encode
  /// there), so this was always going to look file-dependent rather than
  /// all-or-nothing.
  ///
  /// H.264 is Google Cast's one universally-supported video codec across
  /// every generation of receiver — Chromecast Ultra/Google TV also
  /// decode HEVC/VP9, but first/second/third-gen Chromecast and other
  /// Default-Media-Receiver targets don't, and this transport has no
  /// reliable way to tell which generation it's actually talking to (the
  /// Cast SDK doesn't expose decoder capability, only a device/model
  /// name). Restricting the compatible set to H.264 — the same
  /// conservative "known-good allowlist, transcode everything else"
  /// approach `_castCompatibleAudioCodecs` already uses — means some
  /// HEVC titles get transcoded on a receiver that could actually have
  /// handled them directly, but that's a quality tradeoff, not a
  /// broken-cast bug; the alternative (guessing a codec is safe and being
  /// wrong) is the exact silent failure being fixed here. High-10 (10-bit
  /// H.264) is excluded too — real 10-bit source but still nominally
  /// "h264" in `MediaStreams`, and just as undecodable on hardware that
  /// only supports 8-bit H.264 profiles.
  static const Set<String> _castCompatibleVideoCodecs = {'h264'};

  bool _needsVideoTranscodeForCast(MediaItem item) {
    if (item.live || item.audioOnly) return false;
    final video = _defaultVideoStream(item);
    final codec = video?['Codec']?.toString().toLowerCase();
    if (codec == null || codec.isEmpty) return false;
    if (!_castCompatibleVideoCodecs.contains(codec)) return true;
    final profile = video?['Profile']?.toString().toLowerCase() ?? '';
    final bitDepth = video?['BitDepth'] as int?;
    return profile.contains('high 10') || (bitDepth != null && bitDepth > 8);
  }

  /// Whether `_resolveCastMedia` needs to send the receiver a
  /// server-side transcode instead of the raw source file — either the
  /// audio track (`_needsAudioTranscodeForCast`) or the video track
  /// (`_needsVideoTranscodeForCast`) is something the receiver can't
  /// decode as-is. There is deliberately no *container* check here:
  /// that's `_needsContainerTranscodeForCast`'s job, and
  /// `_resolveCastMedia` now consults both and sends a single HLS
  /// request that fixes whichever of them actually fired. The two used
  /// to be exclusive alternatives, which is why a file with both
  /// problems could never be fixed — see that branch's own comment.
  bool _needsTranscodeForCast(MediaItem item) {
    return _needsAudioTranscodeForCast(item) || _needsVideoTranscodeForCast(item);
  }

  /// Containers Google's Default Media Receiver actually demuxes on its
  /// own (https://developers.google.com/cast/docs/media): MP4-family and
  /// WebM, plus the MPEG-TS/M2TS this app's own transcode branches
  /// already output. `mov` is included too — never observed to fail and
  /// effectively MP4-compatible at the container level (both are ISO
  /// base media format variants) — kept rather than newly reclassified
  /// as unsupported without an actual failing case behind it.
  static const Set<String> _castNativeContainers = {
    'mp4',
    'm4v',
    'mov',
    'webm',
    'ts',
    'mpegts',
    'm2ts',
  };

  /// Containers that must never be direct-streamed, checked *before*
  /// [_castNativeContainers] rather than simply being "not in" it.
  ///
  /// The reason this exists as its own set is Matroska specifically:
  /// ffprobe demuxes MKV and WebM with the same demuxer and reports the
  /// format as `matroska,webm`, so an MKV whose `Container` came through
  /// un-normalized contains the token `webm` — which is genuinely
  /// Cast-native. A plain "does any token look native?" test would
  /// therefore wave an MKV straight through onto the direct-stream path,
  /// which is the exact failure this whole container check was added to
  /// stop. Listing the hostile names explicitly and giving them
  /// precedence resolves that ambiguity in the only direction that's
  /// safe: a file claiming to be both Matroska and WebM gets remuxed,
  /// which a real WebM tolerates fine (Jellyfin stream-copies it) but an
  /// MKV genuinely needs.
  static const Set<String> _castHostileContainers = {
    'mkv',
    'matroska',
    'avi',
    'wmv',
    'asf',
    'flv',
    'ogv',
    'ogg',
    'vob',
    'mpg',
    'mpeg',
    'rm',
    'rmvb',
    'divx',
  };

  /// Jellyfin's media-source id for [item] — the same
  /// `MediaSources[0].Id` lookup `_subtitleTracksFor`/
  /// `_defaultSubtitleTrackId` already do, pulled out so the cast
  /// transcode URL can use it too. `/Videos/{id}/master.m3u8` requires
  /// it (see `MediaService.getVideoCastTranscodeUrl`'s doc comment for
  /// what leaving it out actually did).
  String _mediaSourceIdFor(MediaItem item) {
    final sources = item.mediaSources;
    if (sources != null && sources.isNotEmpty) {
      final first = sources.first;
      if (first is Map) {
        final id = first['Id']?.toString();
        if (id != null && id.isNotEmpty) return id;
      }
    }
    return item.id;
  }

  /// CONTAINER DETECTION (this is what actually decided MKV vs MP4 —
  /// read before changing any of the three lookups below): the first
  /// version of this read `item.raw['Container']`, falling back to
  /// `item.raw['MediaSources'][0]['Container']`, and treated any value
  /// that wasn't an exact match in `_castNativeContainers` as "not a
  /// Cast-native container, send it through the transcoder". Two
  /// separate things went wrong with that, and between them they explain
  /// both halves of "MKV still won't cast and now MP4 doesn't either":
  ///
  ///  1. `item.raw` is whatever list/detail endpoint originally built
  ///     the item and is *never* refreshed —
  ///     `CastManager._ensureFullMediaItem` backfills `item.mediaStreams`
  ///     and `item.mediaSources` from a fresh fetch but leaves `raw`
  ///     exactly as it was. So the freshest container information the
  ///     app has (`item.mediaSources`) was the one place this never
  ///     looked, while `raw['MediaSources']` — which a sparse
  ///     episode-list item simply doesn't have — was.
  ///
  ///  2. `Container` is not reliably a single token. Depending on how
  ///     the library was scanned, an ordinary MP4 can come back as
  ///     ffprobe's raw format list (`mov,mp4,m4a,3gp,3g2,mj2`) rather
  ///     than the normalized `mp4`. An exact set lookup misses that,
  ///     classifies a perfectly Cast-native MP4 as an exotic container,
  ///     and routes it into the transcode branch — which is how a file
  ///     that had always direct-streamed fine suddenly stopped playing
  ///     the moment a container check was introduced at all.
  ///
  /// So: check every source in freshness order, split on commas, and
  /// fall back to the file extension of `Path` when no `Container` field
  /// survives anywhere (a sparse episode item usually still carries a
  /// path, and `.mkv` is as definitive as the field would have been).
  Set<String> _containerTokensFor(MediaItem item) {
    String? raw;

    final sources = item.mediaSources;
    if (sources != null && sources.isNotEmpty && sources.first is Map) {
      raw = (sources.first as Map)['Container']?.toString();
    }
    if (raw == null || raw.trim().isEmpty) {
      raw = item.raw?['Container']?.toString();
    }
    if (raw == null || raw.trim().isEmpty) {
      final rawSources = item.raw?['MediaSources'];
      if (rawSources is List && rawSources.isNotEmpty && rawSources.first is Map) {
        raw = (rawSources.first as Map)['Container']?.toString();
      }
    }
    if (raw == null || raw.trim().isEmpty) {
      final path = item.raw?['Path']?.toString();
      if (path != null) {
        final dot = path.lastIndexOf('.');
        if (dot >= 0 && dot < path.length - 1) {
          raw = path.substring(dot + 1);
        }
      }
    }

    if (raw == null || raw.trim().isEmpty) return const <String>{};
    return raw
        .toLowerCase()
        .split(RegExp(r'[,;\s]+'))
        .where((t) => t.isNotEmpty)
        .toSet();
  }

  /// CASTING FIX (MKV — and any other container outside
  /// `_castNativeContainers` — fails to cast even when its codecs are
  /// already Cast-compatible h264/aac): see the CONTAINER HISTORY note
  /// above `_castCompatibleAudioCodecs`'s section for why a container
  /// check exists separately from `_needsTranscodeForCast` at all, and
  /// the CONTAINER DETECTION note directly above for why the actual
  /// lookup looks the way it does now.
  ///
  /// Two behavioural rules here, both deliberately biased toward leaving
  /// a working direct stream alone:
  ///
  ///  * **Any** recognized native token is enough (`mov,mp4,m4a,...`
  ///    counts as MP4), rather than requiring the whole string to match
  ///    — unless a [_castHostileContainers] token is also present, which
  ///    wins (see that set's own comment for the `matroska,webm` case
  ///    that makes this ordering necessary rather than pedantic).
  ///  * An unknown or entirely missing container is treated as native,
  ///    i.e. left on the direct-stream path. Transcoding on the strength
  ///    of "this app couldn't tell what this file is" is what turns a
  ///    metadata gap into a broken cast; the file itself is unchanged by
  ///    whatever the server did or didn't report about it.
  ///
  /// Unlike the previous version this no longer short-circuits when the
  /// codecs need transcoding too — `_resolveCastMedia` now has a single
  /// transcode branch that handles any combination of container and
  /// codec problems, so there's nothing to hand off to.
  bool _needsContainerTranscodeForCast(MediaItem item) {
    if (item.live || item.audioOnly) return false;
    final tokens = _containerTokensFor(item);
    if (tokens.isEmpty) return false;
    if (tokens.any(_castHostileContainers.contains)) return true;
    if (tokens.any(_castNativeContainers.contains)) return false;
    return true;
  }

  /// Resolves the actual URL + MIME type Cast should be told to fetch

  /// for [item] — the single source of truth `load()` and `loadQueue()`
  /// both call into, so the two can't drift out of sync the way they
  /// had (both hand-rolled `item.audioOnly ? 'audio/mp4' : 'video/mp4'`
  /// inline, which is what let the two bugs below go unnoticed in one
  /// of the two call sites for a while).
  ///
  /// Three real bugs fixed here:
  ///
  /// 1. **Music never had working sound at all.** `item.castStreamUrl`
  ///    for an audio item resolves to `MediaService.getAudioStreamUrl`'s
  ///    `/Audio/{id}/universal?...TranscodingProtocol=hls...` endpoint —
  ///    the same HLS-negotiated URL mpv (which speaks HLS natively) uses
  ///    for local playback. The Default Media Receiver was then told
  ///    `contentType: 'audio/mp4'` for that same URL, which is really an
  ///    `.m3u8` playlist, not a raw audio/mp4 file — the receiver had no
  ///    working way to open it, which reads exactly like "tries to open
  ///    a video cast instead of an audio cast" (it never gets far enough
  ///    to show *any* Now Playing UI, video or audio, for a playlist it
  ///    can't parse as a raw stream). Audio now casts through
  ///    `MediaService.getAudioDownloadUrl` instead — the same plain
  ///    `?static=true` direct-file endpoint the video branch already
  ///    used successfully — with a content type read off the source's
  ///    real container instead of a hardcoded, usually-wrong 'audio/mp4'.
  ///
  /// 2. **Some episodes/movies cast with picture but no sound.** See
  ///    `_needsAudioTranscodeForCast` — when the file's default audio
  ///    track is a codec the receiver can't decode (DTS/TrueHD/etc.),
  ///    this switches from the plain direct-stream URL to Jellyfin's
  ///    transcoded endpoint with that track pinned via
  ///    `AudioStreamIndex`, which forces the server to re-encode just
  ///    that track to AAC. `maxHeight` is set generously high (not left
  ///    at the source resolution) purely because `getVideoStreamUrl`
  ///    only exposes the transcode branch when a cap is supplied —
  ///    4K is high enough that virtually nothing actually gets
  ///    downscaled by it, so this is an audio-codec fix, not a quality
  ///    tradeoff.
  ({Uri url, String contentType}) _resolveCastMedia(MediaItem item) {
    // LOCAL CASTING: an on-device song (LocalMusicService) or an Open
    // With/Play With file (ExternalMediaHandler) — see MediaItem.isLocal
    // — never has a Jellyfin `Id` any of the branches below could do
    // anything with (`getAudioDownloadUrl`/`getVideoStreamUrl` would be
    // building a URL against this app's own Jellyfin server using a
    // local-only id like `local_123`/`external_456`, which doesn't
    // identify anything on that server). By the time this runs,
    // CastManager._ensureCastableLocalItem has already registered the
    // file with LocalCastServer and given it a real
    // `item.remoteStreamUrl` — this only has to declare the matching
    // contentType, via the same resolveLocalCastFormat CastManager
    // already used to decide what to tell the local server to serve it
    // as, so the two can't disagree about what format is being sent.
    // Only reachable when castStreamUrl really is set (CastManager's
    // resolution step throws before ever reaching here otherwise), but
    // resolveLocalCastFormat can still throw here too — e.g. queueing
    // straight into `load()` without going through CastManager at all
    // isn't a real call path today, but failing loudly here rather than
    // falling through into the Jellyfin-only logic below (which would
    // silently misbehave for a local item) is the safer default.
    if (item.isLocal) {
      // NAMESIS PRIME: an addon stream repackaged to HLS by LocalCastServer.
      final castUrl = item.castStreamUrl;
      if (castUrl != null &&
          (Uri.tryParse(castUrl)?.path.toLowerCase().endsWith('.m3u8') ??
              false)) {
        return (url: Uri.parse(castUrl), contentType: 'application/x-mpegurl');
      }
      final format = resolveLocalCastFormat(item);
      return (
        url: Uri.parse(item.castStreamUrl!),
        // AUDIO-TRACK SWITCH: a stream PlaybackCoordinator swapped in to
        // change the TV's audio track is always an MPEG-TS remux,
        // whatever container the original file was (see
        // LocalCastServer.registerMediaWithAudioTrack).
        contentType: item.raw?['CastLocalRemuxedTs'] == true
            ? 'video/mp2t'
            : format.contentType,
      );
    }

    // AUDIO-TRACK SWITCH FOR JELLYFIN-BACKED CASTING: `selectAudioTrack`
    // below stashes the chosen track's Jellyfin stream index here before
    // calling `load()` again — see this file's own `selectAudioTrack`
    // doc comment for why a reload (not a live switch) is how this has
    // to work. Checked before every other branch so a movie/episode that
    // would otherwise direct-stream still gets the forced-track HLS URL
    // once a non-default track has been picked.
    final audioOverride = item.raw?['CastAudioStreamOverride'] as int?;
    if (audioOverride != null && !item.live && !item.audioOnly) {
      final chosen = _audioStreamByIndex(item, audioOverride);
      final chosenCodec = chosen?['Codec']?.toString().toLowerCase();
      final needsAudio =
          chosenCodec == null || !_castCompatibleAudioCodecs.contains(chosenCodec);
      final needsVideo = _needsVideoTranscodeForCast(item);
      return (
        url: Uri.parse(
          MediaService.getVideoCastTranscodeUrl(
            item.id,
            mediaSourceId: _mediaSourceIdFor(item),
            audioStreamIndex: audioOverride,
            allowVideoStreamCopy: !needsVideo,
            allowAudioStreamCopy: !needsAudio,
          ),
        ),
        contentType: 'application/x-mpegurl',
      );
    }

    if (item.audioOnly) {
      // SONG-FAILS-TO-CAST FIX: the container/codec used to be read from
      // `item.raw` only, and only `flac` was ever sent down the
      // transcode path. Two ways a song still failed on the receiver:
      // (1) a song from a list endpoint (Songs/Favorites/Search/
      // Playlists) whose `raw` carries no Container -- CastManager's
      // backfill puts the fresh MediaSources on `item.mediaSources`,
      // never on `raw`, so FLAC went out as a raw direct stream;
      // (2) any other format the Default Media Receiver can't decode
      // (ALAC in .m4a, WMA, APE, WavPack, AIFF, DSD, ...). Now the
      // container is read from raw, mediaSources, then the first audio
      // stream's codec too, and anything not known to be receiver-safe
      // goes through the same mp3 transcode FLAC already used. Unknown
      // (nothing readable) still direct-streams, as before.
      final firstSource = () {
        final src = item.mediaSources ?? item.raw?['MediaSources'];
        return (src is List && src.isNotEmpty && src.first is Map)
            ? src.first as Map
            : null;
      }();
      final containerRaw =
          (item.raw?['Container'] ?? firstSource?['Container'])
              ?.toString()
              .toLowerCase();
      // ffprobe-style lists ("mov,mp4,m4a,3gp,3g2,mj2") are split.
      final containerTokens = containerRaw == null
          ? const <String>[]
          : containerRaw
              .split(',')
              .map((t) => t.trim())
              .where((t) => t.isNotEmpty)
              .toList();
      final audioStreams = item.mediaStreams ?? firstSource?['MediaStreams'];
      String? audioCodec;
      if (audioStreams is List) {
        for (final st in audioStreams) {
          if (st is Map && st['Type']?.toString() == 'Audio') {
            audioCodec = st['Codec']?.toString().toLowerCase();
            break;
          }
        }
      }
      const directContainers = {
        'mp3', 'aac', 'm4a', 'mp4', 'mov', 'wav', 'ogg', 'oga', 'opus',
        'webm', 'm4b',
      };
      const directCodecs = {'mp3', 'aac', 'vorbis', 'opus'};
      final containerUnsafe = containerTokens.isNotEmpty &&
          !containerTokens.any(directContainers.contains);
      final codecUnsafe = audioCodec != null &&
          audioCodec.isNotEmpty &&
          !directCodecs.contains(audioCodec) &&
          !audioCodec.startsWith('pcm');
      if (containerUnsafe || codecUnsafe) {
        // SEEK-RESTART FIX (root cause): this used to be the progressive
        // `stream.mp3` transcode (`getAudioCastTranscodeUrl`), a chunked,
        // range-less stream the receiver cannot seek within -- a seek
        // just re-opened it from 0:00, so every song that took this
        // branch (FLAC, ALAC, WMA, ...) "restarted" when the seek bar
        // was dragged/tapped. HLS gives the receiver a real, seekable
        // timeline; see `MediaService.getAudioCastHlsUrl`.
        return (
          url: Uri.parse(
            MediaService.getAudioCastHlsUrl(
              item.id,
              mediaSourceId: _mediaSourceIdFor(item),
            ),
          ),
          contentType: 'application/x-mpegurl',
        );
      }
      final container = containerTokens.firstWhere(
        (t) => directContainers.contains(t),
        orElse: () => '',
      );

      const mimeByContainer = {
        'mp3': 'audio/mpeg',
        'aac': 'audio/aac',
        'm4a': 'audio/mp4',
        'mp4': 'audio/mp4',
        'mov': 'audio/mp4',
        'm4b': 'audio/mp4',
        'wav': 'audio/wav',
        'ogg': 'audio/ogg',
        'oga': 'audio/ogg',
        'opus': 'audio/ogg',
        'webm': 'audio/webm',
      };
      return (
        url: Uri.parse(MediaService.getAudioDownloadUrl(item.id)),
        // 'audio/mpeg' (mp3) is the fallback rather than 'audio/mp4' —
        // most home Jellyfin libraries skew mp3/m4a, and the receiver
        // still negotiates off the real Content-Type header the server
        // sends back regardless, same as the video branch below.
        contentType: mimeByContainer[container] ?? 'audio/mpeg',
      );
    }

    // CASTING FIX (MKV never started playing; MP4 stopped too): this
    // used to be two separate branches — a container branch that hit
    // Jellyfin's HLS endpoint, and, below it, a codec branch that hit
    // `getVideoStreamUrl`'s progressive `.ts` transcode. Both are folded
    // into the one HLS request here, for two reasons:
    //
    //  * The two branches were mutually exclusive by construction
    //    (`_needsContainerTranscodeForCast` used to bail out whenever
    //    the codecs needed work), which meant the very worst case — a
    //    Cast-hostile container *and* a Cast-hostile codec, i.e. exactly
    //    the DTS-in-MKV files people actually have — got the branch that
    //    fixes the container only, or the one that fixes the codecs only,
    //    never both. It could never have worked.
    //
    //  * The progressive `.ts` branch re-encodes everything from scratch
    //    regardless of what's actually wrong with the file, and its
    //    startup latency routinely outran the receiver's own load timeout
    //    — an H.264 file with one bad audio track sat there re-encoding
    //    video it never needed to touch. The HLS endpoint decides per
    //    track, so the flags below re-encode only what genuinely can't be
    //    copied.
    //
    // See `MediaService.getVideoCastTranscodeUrl`'s doc comment for the
    // missing `MediaSourceId` that made every request through the old
    // container branch fail with a 400 before any of this mattered, and
    // the CONTAINER HISTORY note further up this file for why a
    // container check is needed at all.
    if (!item.live) {
      final needsAudio = _needsAudioTranscodeForCast(item);
      final needsVideo = _needsVideoTranscodeForCast(item);
      final needsContainer = _needsContainerTranscodeForCast(item);

      if (_needsTranscodeForCast(item) || needsContainer) {
        final audioIndex = _defaultAudioStream(item)?['Index'] as int?;
        return (
          url: Uri.parse(
            MediaService.getVideoCastTranscodeUrl(
              item.id,
              mediaSourceId: _mediaSourceIdFor(item),
              audioStreamIndex: audioIndex,
              // Veto a stream copy only for the specific track this app
              // already knows the receiver can't decode; the other track
              // stays eligible to be copied. A container-only problem
              // vetoes neither, so it stays the pure remux it should be.
              allowVideoStreamCopy: !needsVideo,
              allowAudioStreamCopy: !needsAudio,
            ),
          ),
          // HLS manifest — the receiver fetches and follows this, not a
          // single media file, so the MIME type is the playlist type, not
          // a video container type.
          contentType: 'application/x-mpegurl',
        );
      }
    }

    // 3. **Default case — direct-stream the source file as-is.** This
    //    is the normal, working path for the overwhelming majority of
    //    movies/episodes (MKV included — see the note above
    //    `_needsAudioTranscodeForCast`'s section: the *container* was
    //    never the reason MKV titles failed to cast, only specific
    //    codecs inside it were, and that's still handled purely by
    //    `_needsTranscodeForCast` above, not by anything below).
    //
    //    CASTING FIX (MKV movies/episodes fail to cast, MP4 casts fine):
    //    `contentType` used to be hardcoded to `'video/mp4'` here
    //    regardless of the real on-disk container, on the assumption
    //    that the receiver ignores the sender's declared type and
    //    negotiates purely off the real `Content-Type` header Jellyfin's
    //    `static=true` response sends back — mirroring the same
    //    assumption the audio branch above states for itself. That
    //    assumption doesn't hold here: the Default Media Receiver uses
    //    the `contentType` declared in the `MediaInfo` the sender loads
    //    it with to pick a demuxer, so telling it "video/mp4" for a file
    //    that's actually Matroska bytes is a real mismatch, not a no-op
    //    — the receiver accepts the load request but never gets anywhere
    //    near a real `playing` status, same failure signature as an
    //    actually-undecodable codec. An MP4 file never showed this bug
    //    only because its real container happened to match the
    //    hardcoded label by coincidence. Reading the real `Container`
    //    field (same field/lookup the audio branch above already uses)
    //    fixes the mismatch for MKV without touching audio at all.
    // Same tokenized read the container check above uses — see
    // `_containerTokensFor`'s CONTAINER DETECTION note. Using the raw
    // `Container` string directly here was the other half of the MP4
    // regression: a value like `mov,mp4,m4a,3gp,3g2,mj2` missed every
    // key in this map and fell through to the fallback. That happened to
    // be harmless (the fallback is `video/mp4`, which is what such a
    // file actually is), but it meant the map was silently doing nothing
    // for exactly the items whose container was hardest to read.
    //
    // 'mkv' is deliberately *not* in this map any more. Declaring
    // `video/x-matroska` to the receiver was never a working fallback —
    // the Default Media Receiver has no Matroska demuxer, so an accurate
    // label just gets the file accurately refused (see the CONTAINER
    // HISTORY note further up this file). Anything Matroska-shaped is
    // now routed to the HLS remux branch above before reaching here, and
    // if something ever did reach here anyway, `video/mp4` — the
    // fallback — at least reproduces the old "sometimes decodes anyway"
    // behaviour rather than a guaranteed refusal.
    const videoMimeByContainer = {
      'mp4': 'video/mp4',
      'm4v': 'video/mp4',
      'mov': 'video/mp4',
      'webm': 'video/webm',
      'ts': 'video/mp2t',
      'mpegts': 'video/mp2t',
      'm2ts': 'video/mp2t',
    };

    String? contentType;
    for (final token in _containerTokensFor(item)) {
      final mapped = videoMimeByContainer[token];
      if (mapped != null) {
        contentType = mapped;
        break;
      }
    }

    return (
      url: Uri.parse(item.castStreamUrl!),
      // 'video/mp4' remains the fallback for an unrecognized/missing
      // Container value — the previous, always-correct default for the
      // overwhelming majority of libraries — so nothing changes for any
      // format this map doesn't explicitly know about.
      contentType: contentType ?? 'video/mp4',
    );
  }

  /// Text-based Jellyfin subtitle tracks for [item], declared as Google
  /// Cast sidecar WebVTT tracks. Reuses `MediaStreamParser.subtitles()`
  /// — the same parsing PlayerManager already does for local mpv
  /// playback — so this reads the exact same `MediaStreams`/
  /// `MediaSources` data local playback does, rather than re-deriving
  /// subtitle info from scratch for casting. Only tracks with a real
  /// [SubtitleTrack.externalUrl] are usable here: that's Jellyfin's own
  /// `/Subtitles/{index}/Stream.vtt` extraction (or, rarely, a genuine
  /// `DeliveryUrl`) — anything without one is an image-based embedded
  /// track (PGS/VobSub) Jellyfin can't convert to text/vtt, which the
  /// Default Media Receiver has no way to render regardless.
  List<GoogleCastMediaTrack> _subtitleTracksFor(MediaItem item) {
    final mediaSourceId = (item.mediaSources != null &&
            item.mediaSources!.isNotEmpty)
        ? item.mediaSources!.first['Id'] as String? ?? item.id
        : item.id;

    final subtitles = MediaStreamParser.subtitles(
      item.mediaStreams,
      itemId: item.id,
      mediaSourceId: mediaSourceId,
    );

    // NOTE: flutter_chrome_cast's "Enum Naming Convention Update"
    // (shipped ahead of the 1.4.8 this project pins) renamed every Cast
    // SDK enum from UPPER_SNAKE_CASE to lowerCamelCase — confirmed
    // against the published changelog (`TrackType.TEXT` -> `.text`,
    // `TextTrackType.SUBTITLES` -> `.subtitles`, and the
    // `CastMediaStreamType` members used just above), so the lowercase
    // members are used throughout this file now rather than the
    // upper-case ones the very first draft of this transport guessed at.
    final tracks = [
      for (final sub in subtitles)
        if (sub.externalUrl != null)
          GoogleCastMediaTrack(
            trackId: sub.index,
            type: TrackType.text,
            trackContentId: sub.externalUrl!,
            trackContentType: 'text/vtt',
            name: sub.displayTitle,
            subtype: TextTrackType.subtitles,
          ),
    ];

    // CASTING FIX (OpenSubtitles/Open-With sidecar subtitles invisible on
    // the TV): `subtitles` above is always empty for one of these items —
    // there's no Jellyfin item/MediaStreams behind an Open With/Play With
    // file or an on-device song/video (see ExternalMediaHandler) — so the
    // loop above never has anything to find for one, regardless of what
    // subtitle text is actually available on the phone right now.
    // `PlaybackCoordinator`'s LOCAL -> REMOTE handoff registers whatever
    // raw-text subtitle is currently selected locally (an OpenSubtitles
    // download, a downloaded item's own sidecar, or an Open With/Play
    // With sidecar auto-selected by
    // PlayerManager._reapplyCachedSubtitleIfAny) with LocalCastServer
    // ahead of `load()`/`queueLoadItems()` and stashes the resulting URL
    // here — this is just where that URL finally gets declared to the
    // receiver, under the same fixed [kLocalCastSubtitleTrackId] both
    // sides agree on, the same way a Jellyfin sidecar URL is declared
    // under its own real stream index just above.
    final localSubtitleUrl = item.raw?['CastSidecarSubtitleUrl'] as String?;
    if (localSubtitleUrl != null && localSubtitleUrl.isNotEmpty) {
      tracks.add(
        GoogleCastMediaTrack(
          trackId: kLocalCastSubtitleTrackId,
          type: TrackType.text,
          trackContentId: localSubtitleUrl,
          trackContentType: 'text/vtt',
          name:
              (item.raw?['CastSidecarSubtitleName'] as String?) ?? 'Subtitle',
          subtype: TextTrackType.subtitles,
        ),
      );
    }

    // LOCAL VIDEO CAST (Open With/Play With): every OTHER text subtitle
    // available on the phone — sidecar files from the same folder, and
    // OpenSubtitles downloads — is declared up front too, each under its
    // own id (kLocalCastSubtitleTrackId + 1, +2, ...), so picking one in
    // the Subtitles sheet later is just a fast setActiveTrackIDs, exactly
    // like a movie/episode's server subtitles. PlaybackCoordinator
    // (_prepareLocalCastTracks / _syncLocalSubtitleToCast) builds this
    // list: [{id, url, name}, ...].
    final localExtra = item.raw?['CastLocalSubtitles'];
    if (localExtra is List) {
      for (final entry in localExtra) {
        if (entry is! Map) continue;
        final id = entry['id'];
        final url = entry['url'];
        if (id is! int || url is! String || url.isEmpty) continue;
        tracks.add(
          GoogleCastMediaTrack(
            trackId: id,
            type: TrackType.text,
            trackContentId: url,
            trackContentType: 'text/vtt',
            name: (entry['name'] as String?) ?? 'Subtitle',
            subtype: TextTrackType.subtitles,
          ),
        );
      }
    }

    return tracks;
  }

  /// The subtitle track id to activate on load — Jellyfin's own default
  /// subtitle flag when one of the declared tracks has it, otherwise
  /// null (no subtitle active), matching local mpv playback's own
  /// default-track behavior rather than always forcing the first track
  /// on.
  int? _defaultSubtitleTrackId(
    MediaItem item,
    List<GoogleCastMediaTrack> declaredTracks,
  ) {
    if (declaredTracks.isEmpty) return null;

    // LOCAL/EXTERNAL SUBTITLE ACTIVATION FIX (Open With/downloaded
    // subtitles reload but never actually show): a subtitle carried
    // over from local playback (a sidecar file, an OpenSubtitles
    // download, or one picked while already local-casting — see
    // PlaybackCoordinator's LOCAL -> REMOTE handoff and
    // _syncLocalSubtitleToCast/switchLocalCastAudio) has no Jellyfin
    // `IsDefault` flag the lookup below could ever find, since it isn't
    // a real Jellyfin MediaStream at all. That used to mean every
    // load()/reload() carrying one of these declared it to the receiver
    // (tracks.isNotEmpty) but never activated it (`activeTrackIds:
    // null`) — activation only ever happened via a *separate*
    // `setActiveTrackIDs` call sent right after `loadMedia()`'s Future
    // resolves, which (per load()'s own "acknowledges the request, not
    // once it's actually opened the content" doc comment) can race the
    // receiver still settling into the just-(re)loaded stream and get
    // silently dropped — the exact "movie reloads, but no subtitles
    // ever show" symptom. `CastActiveSubtitleId` is the coordinator's
    // way of saying "activate this declared track the moment it's
    // loaded" so it rides in the same `loadMedia()`/`queueLoadItems()`
    // call as everything else, with no separate racy follow-up needed.
    final override = item.raw?['CastActiveSubtitleId'] as int?;
    if (override != null &&
        declaredTracks.any((t) => t.trackId == override)) {
      return override;
    }

    final mediaSourceId = (item.mediaSources != null &&
            item.mediaSources!.isNotEmpty)
        ? item.mediaSources!.first['Id'] as String? ?? item.id
        : item.id;

    final subtitles = MediaStreamParser.subtitles(
      item.mediaStreams,
      itemId: item.id,
      mediaSourceId: mediaSourceId,
    );

    final declaredIds = declaredTracks.map((t) => t.trackId).toSet();
    for (final sub in subtitles) {
      if (sub.isDefault && declaredIds.contains(sub.index)) return sub.index;
    }
    return null;
  }

  /// Shared timeout + error-surfacing wrapper for every simple command
  /// below (play/pause/stop/seek/setVolume/next/previous) — same
  /// `_callTimeout` used for connect/load, and the same "set lastError,
  /// rethrow so CastManager's caller sees it" contract those two already
  /// follow, rather than a command silently hanging with no feedback
  /// (Phase 10's other fix, "command failures now tell you instead of
  /// doing nothing", only covered failures the SDK actually reported —
  /// a hang was never a reported failure).
  Future<T> _runTimedCommand<T>(
    CastSession session,
    String commandLabel,
    Future<T> Function() command,
  ) async {
    try {
      return await command().timeout(_callTimeout);
    } catch (e) {
      session.lastError.value = e is TimeoutException
          ? '${session.device.displayName} did not respond to '
              '$commandLabel in time.'
          : '$commandLabel failed on ${session.device.displayName}: $e';
      rethrow;
    }
  }

  @override
  Future<void> play(CastSession session) async {
    if (!session.capability.play) {
      throw UnsupportedCastCommand('play', kind);
    }
    await _runTimedCommand(
        session, 'play', () => GoogleCastRemoteMediaClient.instance.play());
  }

  @override
  Future<void> pause(CastSession session) async {
    if (!session.capability.pause) {
      throw UnsupportedCastCommand('pause', kind);
    }
    await _runTimedCommand(
        session, 'pause', () => GoogleCastRemoteMediaClient.instance.pause());
  }

  @override
  Future<void> stop(CastSession session) async {
    if (!session.capability.stop) {
      throw UnsupportedCastCommand('stop', kind);
    }
    _lastLoadIssuedAt = null; // a real stop's null status must not be ignored
    await _runTimedCommand(
        session, 'stop', () => GoogleCastRemoteMediaClient.instance.stop());
  }

  @override
  Future<void> seek(CastSession session, Duration position) async {
    if (!session.capability.seek) {
      throw UnsupportedCastCommand('seek', kind);
    }
    await _runTimedCommand(
      session,
      'seek',
      () => GoogleCastRemoteMediaClient.instance.seek(
        GoogleCastMediaSeekOption(position: position),
      ),
    );
  }

  @override
  Future<void> setVolume(CastSession session, double volume) async {
    if (!session.capability.volume) {
      throw UnsupportedCastCommand('setVolume', kind);
    }
    final clamped = volume.clamp(0.0, 1.0);
    await _runTimedCommand(
      session,
      'setVolume',
      // `setDeviceVolume` is a fire-and-forget `void` call on this
      // package's session manager (it invokes the native method channel
      // without awaiting a reply), not a `Future<void>` — an `async`
      // closure is needed here (rather than a plain `() =>`) so this
      // still satisfies `_runTimedCommand`'s `Future<T> Function()`
      // signature instead of failing to compile with "void isn't
      // returnable from a Future<_> function".
      () async => GoogleCastSessionManager.instance.setDeviceVolume(clamped),
    );
    session.volume.value = clamped;
  }

  /// Reads the receiver's current volume from the Cast SDK session and
  /// mirrors it into `session.volume`, so the volume UI starts at where
  /// the TV actually is instead of the notifier's 1.0 default.
  ///
  /// Accessed dynamically on purpose: this app has already hit
  /// `flutter_chrome_cast` API-shape differences between the installed
  /// version and pub.dev's docs, and a missing member here must degrade
  /// to "keep the last known volume", never a compile error or a throw.
  Future<void> syncVolume(CastSession session) async {
    try {
      final dynamic manager = GoogleCastSessionManager.instance;
      final dynamic googleSession = manager.currentSession;
      final dynamic level = googleSession?.currentDeviceVolume;
      if (level is num) {
        session.volume.value = level.clamp(0.0, 1.0).toDouble();
      }
    } catch (e) {
      debugPrint('[GoogleCast] syncVolume failed: $e');
    }
  }

  // AUDIO-TRACK SWITCH FOR JELLYFIN-BACKED CASTING (see the capability
  // doc comment on `load()` above): the Default Media Receiver has no
  // way to switch an already-loaded stream's audio track, embedded or
  // otherwise — there's no SDK call for it, which is why this used to
  // just throw unconditionally. VLC's own Chromecast support solves the
  // identical problem by re-requesting the stream with the wanted track
  // selected and reloading at the current position; Jellyfin's HLS
  // transcoder can do that server-side remux/re-encode on demand (see
  // `_resolveCastMedia`'s new `CastAudioStreamOverride` branch), so this
  // does the same thing here: stash the chosen track on the item, carry
  // over whatever subtitle is currently active (a reload would otherwise
  // silently drop it — see `_defaultSubtitleTrackId`'s `CastActiveSubtitleId`
  // doc comment), and reload at the session's current position.
  @override
  Future<void> selectAudioTrack(CastSession session, int trackId) async {
    if (!session.capability.audioTrackSelection) {
      throw UnsupportedCastCommand('selectAudioTrack', kind);
    }
    final item = session.currentItem.value;
    if (item == null || item.raw == null) {
      throw UnsupportedCastCommand('selectAudioTrack', kind);
    }

    item.raw!['CastAudioStreamOverride'] = trackId;

    final activeSub = session.activeSubtitleTrackId.value;
    if (activeSub != null && activeSub >= 0) {
      item.raw!['CastActiveSubtitleId'] = activeSub;
    } else {
      item.raw!.remove('CastActiveSubtitleId');
    }

    // INSTANT TICK: the Audio sheet's checkmark follows this notifier, so
    // it moves on the tap instead of after the receiver acknowledges the
    // reload; put back if the reload fails.
    final previousAudio = session.activeAudioTrackId.value;
    session.activeAudioTrackId.value = trackId;

    try {
      await load(session, item, startAt: session.position.value);
    } catch (_) {
      session.activeAudioTrackId.value = previousAudio;
      rethrow;
    }
    session.activeAudioTrackId.value = trackId;
  }

  // FOLLOW-UP FIX (flagged in Phase 5/11, addressed here): `trackId`
  // here is the same Jellyfin MediaStreams index `load()` declared as
  // this track's Cast `trackId` above (see `_subtitleTracksFor`), so it
  // can be handed straight to `setActiveTrackIDs` with no id
  // translation needed. Only reachable once `session.capability
  // .subtitleTrackSelection` is true, which `load()` only ever sets
  // when it actually declared a matching track — so a `trackId` this
  // receives should always be one it already knows about, but the
  // Cast SDK call itself is still the source of truth for whether the
  // receiver accepts it.
  @override
  Future<void> selectSubtitleTrack(CastSession session, int trackId) async {
    if (!session.capability.subtitleTrackSelection) {
      throw UnsupportedCastCommand('selectSubtitleTrack', kind);
    }
    await _runTimedCommand(
      session,
      'selectSubtitleTrack',
      () => GoogleCastRemoteMediaClient.instance.setActiveTrackIDs(
        [trackId],
      ),
    );
    session.activeSubtitleTrackId.value = trackId;

    // DEFAULT SUBTITLE: a fresh cast stamps the item's default subtitle
    // into `CastActiveSubtitleId` (see CastManager.loadAndPlay). Once the
    // person turns subtitles off that stamp is stale — an audio-track
    // reload or a re-send of this item must not bring the subtitle back.
    if (trackId < 0) {
      session.currentItem.value?.raw?.remove('CastActiveSubtitleId');
    }
  }

  /// Native bridge to the Cast SDK's `RemoteMediaClient.setTextTrackStyle`
  /// (see `MainActivity.kt`). The Dart plugin's own method for this could
  /// never be verified, and the old dynamic call failed silently, so on
  /// Android the style is pushed through the SDK directly.
  static const MethodChannel _subtitleStyleChannel =
      MethodChannel('com.nemesis.app/cast_subtitle_style');

  /// LIVE SUBTITLE STYLE (Settings > Subtitle Style): applies the user's
  /// style to the receiver's text tracks via the Cast SDK's
  /// `RemoteMediaClient.setTextTrackStyle`. The Default Media Receiver
  /// honors color, background, edge, font family/style and scale; it has
  /// no concept of subtitle *height*, so that one setting is ignored here.
  ///
  /// Android: goes through the native channel above. Anything else (or if
  /// the native call fails) falls back to the old dynamic plugin call,
  /// which is caught and logged — subtitles on the TV then simply keep
  /// the receiver's own style; the phone-side style is unaffected.
  @override
  Future<void> applySubtitleStyle(
    CastSession session,
    SubtitleAppearance appearance,
  ) async {
    if (Platform.isAndroid) {
      try {
        await _subtitleStyleChannel.invokeMethod<void>(
          'setTextTrackStyle',
          appearance.toAndroidCastStyle(),
        );
        return;
      } on PlatformException catch (e) {
        // Typically "no media session yet" / the receiver not accepting
        // the style yet (right after a load). This used to be swallowed
        // and then "retried" through a plugin call that has never worked,
        // so a push that lost the race with the load was simply lost and
        // the TV stayed on its own style. Rethrown instead:
        // CastSubtitleStyleSync catches it and retries a few times.
        debugPrint(
            'GoogleCastTransport.applySubtitleStyle native failed: ${e.code} ${e.message}');
        rethrow;
      } on MissingPluginException catch (e) {
        debugPrint(
            'GoogleCastTransport.applySubtitleStyle channel missing: $e');
      }
    }
    final style = Map<String, dynamic>.from(appearance.toCastStyleJson())
      ..remove('bottomOffset');
    try {
      final dynamic client = GoogleCastRemoteMediaClient.instance;
      await client.setTextTrackStyle(style);
    } catch (e) {
      debugPrint('GoogleCastTransport.applySubtitleStyle failed: $e');
    }
  }

  @override
  Future<void> next(CastSession session) async {
    if (!session.capability.next) {
      throw UnsupportedCastCommand('next', kind);
    }
    await _runTimedCommand(session, 'next',
        () => GoogleCastRemoteMediaClient.instance.queueNextItem());
  }

  @override
  Future<void> previous(CastSession session) async {
    if (!session.capability.previous) {
      throw UnsupportedCastCommand('previous', kind);
    }
    await _runTimedCommand(session, 'previous',
        () => GoogleCastRemoteMediaClient.instance.queuePrevItem());
  }

  // Casting Phase 12: `capability.shuffle`/`.repeat` are never set true
  // for this transport (see `_deviceFromGoogleCastDevice` — nothing
  // there flips either flag), so these two should be unreachable in
  // normal use. The Cast SDK does have a real queue repeat mode
  // (`REPEAT_OFF`/`REPEAT_ALL`/`REPEAT_SINGLE`/`REPEAT_ALL_AND_SHUFFLE`),
  // but wiring it up needs a confirmed `flutter_chrome_cast` API surface
  // this sandbox has no pub.dev access to verify against — same
  // "implemented-but-gated rather than guessed" call this file already
  // makes for `selectAudioTrack` above. Left as an explicit throw so a
  // future phase that does confirm the API only has to flip the
  // capability flags and fill these in, not discover they were silently
  // no-ops.
  // Casting playback-rate fix: `setPlaybackRate` is a genuine
  // `GoogleCastRemoteMediaClient` API (see the capability doc comment
  // above for the changelog evidence) — unlike `selectAudioTrack`/
  // `setShuffle`/`setRepeatMode` just below, which stay gated behind an
  // unconfirmed-API throw, this one has real evidence it exists and
  // works, so it's wired for real rather than left as a stub. No
  // confirmed event stream reports rate changes back from the receiver,
  // so `session.playbackRateNotifier` is set optimistically on success —
  // same tradeoff `setVolume` above already accepts for this transport.
  @override
  Future<void> setPlaybackRate(CastSession session, double rate) async {
    if (!session.capability.playbackRate) {
      throw UnsupportedCastCommand('setPlaybackRate', kind);
    }
    await _runTimedCommand(
      session,
      'setPlaybackRate',
      // Wrapped in an `async` closure rather than a plain `() =>`, same
      // reasoning as `setVolume`'s `setDeviceVolume` call above: this
      // keeps working regardless of whether the installed package
      // version's `setPlaybackRate` returns `void`/fire-and-forget or a
      // real `Future<GoogleCastRequest>` — either satisfies
      // `_runTimedCommand`'s `Future<T> Function()` signature this way.
      () async => GoogleCastRemoteMediaClient.instance.setPlaybackRate(rate),
    );
    session.playbackRateNotifier.value = rate;
  }

  @override
  Future<void> setShuffle(CastSession session, bool enabled) async {
    throw UnsupportedCastCommand('shuffle', kind);
  }

  @override
  Future<void> setRepeatMode(CastSession session, CastRepeatMode mode) async {
    throw UnsupportedCastCommand('repeat', kind);
  }

  /// CASTING FIX (Songs/Most Played/large Playlists silently fall back
  /// to LOCAL playback instead of casting): the Cast v2 wire protocol
  /// caps every message on the channel at 64KB
  /// (Chromium's own `cast_channel::kMaxCastMessagePayload`) — and
  /// `queueLoadItems()` below packs the *entire* queue's worth of
  /// `GoogleCastQueueItem`s (each with a full contentUrl, title,
  /// artist, album, and an artwork URL) into that one message. An
  /// album/artist tracklist or a typical favorites list is a few dozen
  /// items and stays comfortably under that ceiling — Songs and Most
  /// Played hand this the *entire library* (up to 5000 tracks, see
  /// `MediaService.getSongs`/`getMostPlayedSongs`), and a large
  /// playlist can run into the hundreds (see `getPlaylistTracks`'s own
  /// doc comment on how big those get). Past a few dozen tracks the
  /// serialized payload blows past 64KB, the SDK call fails, and
  /// `PlaybackCoordinator.playAudioQueueOnActiveCast`'s catch block
  /// (see its own "CASTING DEBUG" logging) falls back to starting the
  /// song locally instead — which is exactly "it plays on the device
  /// instead of the TV" for every screen that hands this a long queue.
  ///
  /// `JellyfinRemoteTransport.loadQueue` hit the same class of bug for
  /// the same screens already (see its own "Broken pipe / HTTP 414"
  /// doc comment) and fixed it by capping what's actually sent — this
  /// mirrors that, sized for Cast's protocol ceiling rather than
  /// Jellyfin's URL-length one. Unlike that transport, there's no need
  /// to *rotate* the list so the tapped item lands at index 0: Google's
  /// own `GoogleCastQueueLoadOptions.startIndex` is a genuine, honored
  /// part of the SDK (the workaround in JellyfinRemoteTransport exists
  /// specifically because some *Jellyfin* receivers ignore that
  /// endpoint's `StartIndex`, not because Cast does) — so this just
  /// windows the queue forward from the tapped song instead.
  ///
  /// `_maxQueueItems` is sized from the known 64KB ceiling divided by a
  /// conservative per-item estimate (contentId + a Jellyfin
  /// stream/download URL + title/artist/album strings + one artwork
  /// URL, plus JSON struct overhead — roughly 600-700 bytes per audio
  /// item in practice), leaving a wide safety margin for method-channel
  /// framing and any receiver metadata this app doesn't control. Not
  /// verified against a real over-64KB queue on a physical device —
  /// please confirm on-device and tighten/loosen this constant if it
  /// turns out to be too conservative (queue cuts off early) or still
  /// not conservative enough (queue still fails to load).
  ///
  /// KNOWN LIMITATION: unlike JellyfinRemoteTransport's queue top-up
  /// (`_appendMoreToQueue`, triggered as the receiver nears the end of
  /// what's already been sent), this doesn't yet refill the receiver's
  /// queue as it plays past `_maxQueueItems` tracks — the Cast SDK does
  /// expose `queueInsertItems()` for exactly that, but wiring up "how
  /// far into the sent window is the receiver right now" needs
  /// `GoggleCastMediaStatus.currentItemId` mapped back against the
  /// receiver-assigned item ids `queueLoadItems()` returns, which
  /// wasn't verified against this project's installed package version
  /// here. A long Songs/Most Played session will stop advancing after
  /// the first `_maxQueueItems` tracks from the tap point instead of
  /// silently reverting to local playback the way it does today — a
  /// real improvement, but top-up is real follow-up work, not done in
  /// this fix.
  static const _maxQueueItems = 50;
  @override
  Future<void> loadQueue(
    CastSession session,
    List<MediaItem> items, {
    int startIndex = 0,
    Duration startAt = Duration.zero,
  }) async {
    if (items.isEmpty) {
      throw ArgumentError('loadQueue() called with an empty item list.');
    }

    // See `_maxQueueItems`'s doc comment above — windows the queue
    // forward from the tapped song rather than sending everything.
    // `windowStart` is where the person actually tapped; `windowed[0]`
    // is that same song, so passing `startIndex: 0` for the *windowed*
    // list below still starts on the right track.
    final windowStart = startIndex.clamp(0, items.length - 1);
    final windowed = (items.length - windowStart) > _maxQueueItems
        ? items.sublist(windowStart, windowStart + _maxQueueItems)
        : items.sublist(windowStart);

    // CASTING FIX: same guard as load() above — a queue containing a
    // local-only/undownloaded-local item would otherwise send the
    // receiver an unfetchable local path for that one entry and just
    // silently stall on it. Fail before calling the SDK at all rather
    // than partway through building queueItems, so the error is clear
    // about which item is the problem. Checked against the windowed
    // list only — an unreachable item outside the window that's never
    // actually sent shouldn't block casting the part that is.
    //
    // LOCAL CASTING: same non-committal wording as load()'s equivalent
    // guard above — reachable in the ordinary case only if this queue
    // skipped CastManager.playQueue's own per-item
    // `_ensureCastableLocalItem` resolution, not because every local
    // item is inherently uncastable.
    final unreachable = windowed.where((i) => i.castStreamUrl == null).toList();
    if (unreachable.isNotEmpty) {
      final err = '"${unreachable.first.title}" couldn\'t be cast to '
          '${session.device.displayName}.';
      session.playbackState.value = CastPlaybackState.error;
      session.lastError.value = err;
      throw StateError(err);
    }

    session.playbackState.value = CastPlaybackState.loading;
    session.currentItem.value = windowed.first;
    // RECEIVER-ADVANCE FIX: see this class's own field doc comment —
    // `windowed` is exactly the set of items the receiver was just told
    // about, so it's also exactly the set a later status update's
    // `contentId` can legitimately resolve to as the receiver's own
    // queue advances through it.
    _loadedItems = windowed;

    var anySubtitles = false;

    final queueItems = <GoogleCastQueueItem>[
      for (final item in windowed)
        () {
          final images = _imagesFor(item);

          // No async EPG lookup here the way `load()`/`_metadataFor` do
          // for a single live item — a live channel actually ending up
          // inside a *queue* is the same untested territory the queue-
          // vs-live doc comments elsewhere in this file already call
          // out (queues are built from VOD playlists in practice), so
          // this only reaches for the channel name/logo, not "what's on
          // now", rather than adding an await into what's otherwise a
          // synchronous per-item builder for no exercised benefit.
          final metadata = item.live
              ? GoogleCastGenericMediaMetadata(
                  title: item.title,
                  images: images,
                )
              : item.audioOnly
                  ? GoogleCastMusicMediaMetadata(
                      title: item.title,
                      artist:
                          item.artistName.isNotEmpty ? item.artistName : null,
                      albumName: item.raw?['Album']?.toString(),
                      images: images,
                    )
                  : (item.episodeNumber != null && item.seasonNumber != null)
                      // No `title` param exists on this class (see
                      // _metadataFor's doc comment above) — omitted here
                      // too, for the same reason.
                      ? GoogleCastTvShowMediaMetadata(
                          episode: item.episodeNumber,
                          season: item.seasonNumber,
                          seriesTitle: item.subtitle,
                          images: images,
                        )
                      : GoogleCastMovieMediaMetadata(
                          title: item.title,
                          images: images,
                        );

          final subtitleTracks = _subtitleTracksFor(item);
          if (subtitleTracks.isNotEmpty) anySubtitles = true;
          final defaultSubtitleId = _defaultSubtitleTrackId(
            item,
            subtitleTracks,
          );

          // Same resolution `load()` uses for a single item — see
          // `_resolveCastMedia`'s doc comment. The unreachable-item
          // guard above (`windowed.where((i) => i.castStreamUrl ==
          // null)`) already ran before this loop, so every item here is
          // known to have real network presence.
          final resolved = _resolveCastMedia(item);

          return GoogleCastQueueItem(
            mediaInformation: GoogleCastMediaInformation(
              contentId: item.id,
              streamType: item.live
                  ? CastMediaStreamType.live
                  : CastMediaStreamType.buffered,
              contentUrl: resolved.url,
              contentType: resolved.contentType,
              // Same duration fix as `load()` — see its doc comment.
              // Needed here too since loadQueue() (Continue Watching's
              // "play full queue", music album/playlist casting) is a
              // completely separate call into the SDK that skipped the
              // same hint.
              duration: item.live || item.runtime <= Duration.zero
                  ? null
                  : item.runtime,
              metadata: metadata,
              tracks: subtitleTracks.isEmpty ? null : subtitleTracks,
            ),
            activeTrackIds:
                defaultSubtitleId != null ? [defaultSubtitleId] : null,
          );
        }(),
    ];

    Future<void> sendQueueLoad() => GoogleCastRemoteMediaClient.instance
        .queueLoadItems(
          queueItems,
          // `startIndex: 0` — `windowed[0]` is already the tapped
          // song (see `_maxQueueItems`'s doc comment above), so the
          // windowed list never needs a nonzero start index the way
          // the original, unwindowed `items`/`startIndex` pair did.
          options: GoogleCastQueueLoadOptions(
            startIndex: 0,
            playPosition: startAt > Duration.zero
                ? startAt
                : windowed.first.resumePosition,
          ),
        )
        .timeout(_callTimeout);

    final queueLoadGeneration = _beginLoadAttempt();

    try {
      final sent = await _sendInitialLoad(
        session,
        queueLoadGeneration,
        sendQueueLoad,
        label: windowed.first.title,
      );
      // Superseded by a newer load/disconnect while retrying — see load().
      if (!sent) return;
    } catch (e) {
      session.playbackState.value = CastPlaybackState.error;
      session.lastError.value = e is TimeoutException
          ? '${session.device.displayName} did not respond to '
              'the queue load in time.'
          : 'Failed to start queue playback on '
              '${session.device.displayName}: $e';
      rethrow;
    }

    // Same immediate-seed fix as `load()` — see its doc comment.
    final startItem = windowed.first;
    if (!startItem.live && startItem.runtime > Duration.zero) {
      session.duration.value = startItem.runtime;
    }

    // AUDIO CHECKMARK FIX: same as `load()` — see `_seedActiveAudioTrack`.
    _seedActiveAudioTrack(session, startItem);

    _armLoadWatchdog(session);
    _verifyLoadAcked(
      session,
      queueLoadGeneration,
      sendQueueLoad,
      label: startItem.title,
    );

    // Queue navigation and (per-item) subtitle selection are both real
    // now that a real multi-item queue was actually loaded — see the
    // capability doc comment on `_deviceFromGoogleCastDevice` for why
    // Google Cast's capability is computed rather than fixed.
    session.capabilityNotifier.value = session.capability.copyWith(
      queue: true,
      next: true,
      previous: true,
      subtitleTrackSelection: anySubtitles,
    );
  }
}
