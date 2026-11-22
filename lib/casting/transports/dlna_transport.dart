import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show MethodChannel, MissingPluginException;

import '../../player/models/media_item.dart';
import '../../player/models/subtitle_appearance.dart';
import '../../player/services/media_stream_parser.dart';
import '../../services/jellyfin_services/media_service.dart';
import '../../services/subtitle_appearance_settings.dart';
import '../cast_artwork.dart';
import '../local_cast_format.dart';
import '../local_cast_server.dart' show LocalCastServer, kLocalCastSubtitleTrackId;
import '../models/cast_capability.dart';
import '../models/cast_device.dart';
import '../models/cast_session.dart';
import '../models/cast_states.dart';
import 'cast_transport.dart';
import 'subtitle_style_capable.dart';

// ─────────────────────────────────────────────────────────────────────────
// DLNA / UPnP "MediaRenderer" transport.
//
// Reaches LG webOS, Samsung Tizen, Sony, Philips, Hisense, Roku, AV
// receivers, network speakers, Windows "Play to", etc. — anything that
// advertises a UPnP MediaRenderer on the LAN. There is no receiver app and
// no session API: the phone
//
//   1. finds renderers with SSDP (UDP multicast M-SEARCH),
//   2. reads each renderer's device description (XML) for its
//      AVTransport / RenderingControl SOAP endpoints,
//   3. hands it a plain HTTP URL with SetAVTransportURI + Play, and
//   4. polls GetTransportInfo / GetPositionInfo once a second.
//
// DLNA has no "switch audio track" or "switch subtitle track" command, so —
// exactly like GoogleCastTransport does for local files — track changes are
// done by RELOADING the item at the current position with different hints
// on `MediaItem.raw` (CastAudioStreamOverride, CastActiveSubtitleId,
// CastLocalSubtitles, CastSidecarSubtitleUrl, CastLocalRemuxedTs). The
// PlaybackCoordinator already writes exactly those hints for Google Cast,
// so the same Subtitles / Audio sheets drive this transport unchanged.
//
//   * Jellyfin audio track  -> /Videos/{id}/stream.ts?AudioStreamIndex=n
//     (server remuxes/transcodes a progressive TS carrying that track)
//   * Local audio track     -> LocalCastServer remuxes the chosen track to TS
//   * Subtitles             -> SRT sidecar declared in the DIDL-Lite
//     metadata (standard <res>, Samsung sec:CaptionInfoEx, LG/PacketVideo
//     pv:subtitleFileUri) plus the CaptionInfo.sec HTTP header for local
//     files. Whether a TV honours a sidecar is up to the TV's firmware.
// ─────────────────────────────────────────────────────────────────────────

class DlnaTransport implements CastTransport, SubtitleStyleCapableTransport {
  @override
  CastTransportKind get kind => CastTransportKind.dlna;

  // ── constants ──────────────────────────────────────────────────────────
  static const String _idPrefix = 'dlna:';
  static const String _ssdpAddress = '239.255.255.250';
  static const int _ssdpPort = 1900;
  static const List<String> _searchTargets = [
    'urn:schemas-upnp-org:device:MediaRenderer:1',
    'urn:schemas-upnp-org:service:AVTransport:1',
  ];
  static const String _dlnaFlags = 'DLNA.ORG_FLAGS=01700000000000000000000000000000';

  // Codecs that can be copied into an MPEG-TS for a TV without re-encoding.
  static const Set<String> _tsCopyableAudio = {'aac', 'mp3', 'ac3'};

  // ── shared HTTP client (SOAP + description fetch) ─────────────────────
  final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 5)
    ..idleTimeout = const Duration(seconds: 2)
    ..userAgent = 'Android UPnP/1.0 Nemesis/1.0'
    ..findProxy = ((_) => 'DIRECT');

  // ── discovery state ────────────────────────────────────────────────────
  final Map<String, _DlnaRenderer> _renderers = {};

  /// PHASE 5 (test seam): when set, every item is sent to the TV as this one
  /// URL (no Jellyfin / phone-server URL building, no cover preparation).
  /// Null in the app, so nothing changes there.
  @visibleForTesting
  String? debugStreamUrlOverride;

  /// Merged-device id -> renderer id (see CastManager._dlnaTwinOf). Lets a
  /// device row that also exists as a Jellyfin session connect here.
  final Map<String, String> _aliases = {};
  void linkAlias(String deviceId, String rendererId) =>
      _aliases[deviceId] = rendererId;
  final Map<String, String> _locationToId = {};
  final Set<String> _describing = {};
  final Map<String, DateTime> _ignoredLocations = {};
  final List<RawDatagramSocket> _sockets = [];
  final List<Timer> _discoveryTimers = [];
  StreamController<List<CastDevice>>? _controller;
  int _discoveryGen = 0;

  // ── session state (only one DLNA session at a time) ───────────────────
  CastSession? _session;
  _DlnaRenderer? _renderer;
  Timer? _pollTimer;
  bool _polling = false;
  int _pollTick = 0;
  int _pollFailures = 0;
  // STALL DETECTION (TV shows one frame and stops): a renderer can keep
  // reporting PLAYING while its picture and RelTime no longer move (it ran
  // out of data, or cannot decode what it was handed). The poller used to
  // show that as plain "playing", so it looked identical to normal use.
  // These track how long the reported position has been unchanged.
  Duration? _stallRel;
  DateTime? _stallSince;
  bool _relEverAdvanced = false;
  static const Duration _stallAfter = Duration(seconds: 6);
  // ROOT CAUSE (session + mini player vanishing on Kodi/AirScreen): the poller
  // used to give up after 8 consecutive exceptions of ANY kind. A renderer
  // that is busy opening a big file, or that answers a SOAP fault while
  // it switches items, produced those within seconds; the transport then
  // reported `disconnected`, CastManager disposed the session and nulled
  // `activeSession` (mini player gone, open sheets listening to disposed
  // notifiers). The give-up is now time based and only for real network
  // failures — see [_poll].
  DateTime _lastPollOkAt = DateTime.now();
  static const Duration _lostAfter = Duration(seconds: 60);
  // The subtitle id the TV was actually told about in the last load
  // (-1 = none). `session.activeSubtitleTrackId` can't be used for the
  // "already loaded?" check because the Subtitles sheet writes the new id
  // into it BEFORE calling selectSubtitleTrack, which made every subtitle
  // pick look like a no-op.
  int _declaredSubtitleId = -1;
  int _activeLoads = 0;
  int _loadGeneration = 0;
  bool _commandedStop = false;
  DateTime _holdPollStateUntil = DateTime.fromMillisecondsSinceEpoch(0);

  // ── PHASE 4: controls ─────────────────────────────────────────────────
  //
  // ROOT CAUSE (play/pause button flipped back on AirScreen-style TVs): the
  // poller trusted the renderer's reported state again 1.5 s after every
  // command, but such a receiver confirms a Pause/Play several seconds
  // late — the old state was written over the tap, then the new one landed.
  // The state the person asked for is now remembered until the TV reports
  // it (or [_commandConfirmWindow] passes); a TV that has not obeyed after
  // [_commandRetryAfter] is asked once more, and one that never does is
  // shown as what it really is.
  CastPlaybackState? _wantedPlayback;
  DateTime _wantedPlaybackSince = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _wantedPlaybackUntil = DateTime.fromMillisecondsSinceEpoch(0);
  bool _wantedRetried = false;
  static const Duration _commandConfirmWindow = Duration(seconds: 6);
  static const Duration _commandRetryAfter = Duration(milliseconds: 2500);

  /// Newest seek wins: a background verification of an older seek stops as
  /// soon as a newer one starts.
  int _seekSerial = 0;

  /// True once the renderer has reported a usable RelTime for the item that
  /// is loaded (see [_handleRendererStopped]).
  bool _relSeen = false;

  /// When the poller last saw the TV PLAYING (kept across non-playing polls,
  /// unlike [_lastPlayingPollAt]).
  DateTime? _lastPlayingSeenAt;

  Duration _lastPolledPosition = Duration.zero;
  Duration _streamOffset = Duration.zero;
  _DlnaStream? _current;

  // ── load serialisation + end-of-media bookkeeping ─────────────────────
  //
  // ROOT CAUSE of "next/auto-next/re-cast plays a few seconds then skips
  // on, over and over" (Kodi, AirScreen): none of this was reset per load.
  //  * `_lastPolledPosition` kept the PREVIOUS song's position (often right
  //    at its end). The first time the renderer reported STOPPED while
  //    switching tracks, `_handleRendererStopped` compared that stale
  //    position with the new song's duration, decided the new song had
  //    "finished", and PlaybackCoordinator auto-advanced — which loaded the
  //    next song, which repeated the cycle.
  //  * `_waitForPlaying` accepted the old song's still-PLAYING state as the
  //    new song starting.
  //  * Two loads (a skip during an auto-advance, a fast double tap) ran
  //    their Stop/SetURI/Play sequences interleaved on the same renderer.
  // Everything below exists to make those three impossible.
  Future<void>? _loadTail;
  // The Stop sent after a load FAILED (see [_loadItemBody]). The next load
  // waits for it so that Stop can never land on top of the retry.
  Future<void>? _failureStop;
  DateTime? _loadedAt;
  Duration _loadStartAt = Duration.zero;
  Duration _wallBase = Duration.zero;
  Duration _playedFor = Duration.zero;
  DateTime? _lastPlayingPollAt;
  int _playingPolls = 0;
  Duration _lastTrackDuration = Duration.zero;
  Duration _directStartAt = Duration.zero;
  bool _trustRel = false;
  bool _confirmedPlaying = false;
  bool _startNudged = false;
  // Local videos the connected TV refused as they are but accepted once
  // remuxed to MPEG-TS on the phone (see [_wantsLocalTsFallback]):
  // item id -> the TS route's URL. Later loads of the same item (a subtitle
  // or style reload, a re-cast) go straight to the form the TV accepts
  // instead of failing the original container again. Per session: cleared
  // on connect and disconnect (the routes die with the server).
  final Map<String, String> _localTsFallbackUrls = {};

  // Renderers whose GetPositionInfo TrackURI never matched the URL we sent
  // (they rewrite it) — the stale-track check is skipped for them.
  final Set<String> _trackUriUnreliable = {};

  // ROOT CAUSE (movies / episodes / videos never cast to MagiConnect, songs
  // do): everything a video carries that a song doesn't is metadata the TV
  // has to parse and accept in SetAVTransportURI (the subtitle declaration
  // every fresh video cast now has, the container MIME), and the same
  // metadata was re-sent unchanged on every attempt, so a renderer that
  // rejected it rejected every attempt. See [_sendStream]. What a renderer
  // is known to need is remembered here so the next load goes straight to
  // the form it accepts.
  //  * renderers that refuse the subtitle-decorated DIDL but accept it plain
  final Set<String> _plainMetadataRenderers = {};
  //  * '<renderer id>|<mime>' keys for which the alternative MIME spelling
  //    is the one the renderer accepts
  final Set<String> _altMimeKeys = {};

  // PHASE 3: the cover prepared for the load in progress (a small JPEG served
  // by this phone, see [CastArtwork]). Transport-only: the app's own item is
  // never rewritten with it. Prepared while the TV is being stopped / made
  // idle, awaited just before the metadata is built.
  Future<CastCover?>? _loadCoverFuture;
  CastCover? _loadCover;
  String? _loadCoverItemId;

  // PHASE 3: renderers that refused the metadata WITH the cover declaration
  // but accepted the same form without it. They are sent no cover
  // declaration for the rest of this connection rather than failing the
  // first form on every load.
  final Set<String> _coverRejectedRenderers = {};

  // ROOT CAUSE (a title that failed to cast kept failing, and a renderer
  // that rejected one load stayed "learned" wrongly for the whole app run):
  // the two sets above used to be updated the moment SetAVTransportURI was
  // ACCEPTED — before anything proved the TV could play the item. A
  // transient refusal (TV busy after a failed load, still tearing a player
  // down) made the first metadata form fail and a simpler one pass, and that
  // accident was then remembered as "this renderer needs plain metadata /
  // the other MIME" for good. What a send learned now waits here and is only
  // committed once the TV has really PLAYED the item (see
  // [_commitLearnedForm]); connect() forgets everything, so a fresh
  // connection always starts clean.
  _LearnedForm? _pendingLearn;

  // ── PHASE 0 (DIAGNOSTICS ONLY) ──────────────────────────────────────
  // Everything below exists so each load can end in ONE log line that says
  // what was tried, what the TV did and whether it fetched anything from
  // this phone. None of it feeds back into a decision.
  final List<String> _tlEvents = [];
  final List<String> _tlSends = [];
  final Set<String> _tlMediaUrls = {};
  final Set<String> _tlSubUrls = {};
  DateTime _tlStart = DateTime.now();

  /// Records [event] on the current load's timeline (and nowhere else).
  void _tlAdd(String event) {
    if (_tlEvents.length >= 60) return; // bounded: never grows without limit
    _tlEvents.add('+${DateTime.now().difference(_tlStart).inMilliseconds}ms '
        '$event');
  }

  // Last SOAP-fault log per action+text, so a TV that faults on every
  // one-second poll can't flood the log.
  final Map<String, DateTime> _faultLoggedAt = {};

  // Titles whose declared subtitle made the TV fail to start (or that could
  // not be fetched at all): '<item id>|<subtitle id>'. Such a title is cast
  // without the subtitle declaration from then on instead of failing the
  // same way every time. Cleared on connect and when the person explicitly
  // picks a subtitle for the item.
  final Set<String> _subtitleBlocked = {};

  /// Set by [_waitForPlaying] when it gave up because the renderer positively
  /// reported an EMPTY CurrentURI while STOPPED: the URI we sent was accepted
  /// and then wiped (typically by the previous item's teardown after the
  /// Stop of a track switch). Re-sending the same item once works — exactly
  /// what a second tap on Next used to do by accident.
  bool _waitLostUri = false;

  /// Set by [_waitForPlaying] (direct-switch mode only) when it gave up
  /// because the renderer kept reporting the PREVIOUS item as playing: the
  /// SetAVTransportURI that was sent without a Stop was ignored. The caller
  /// then repeats the switch with the Stop-first sequence.
  bool _waitStaleTrack = false;

  /// Set by [_waitForPlaying] (mid-playback direct switch only) when it gave
  /// up because the renderer DROPPED the switch.
  ///
  /// ROOT CAUSE (a TV's own DLNA receiver: Next / tapping another song while
  /// one is playing just closes the TV's casting player, and only the NEXT
  /// tap plays): such a receiver treats the old item being replaced as "the
  /// cast ended", closes its player and goes STOPPED / NO_MEDIA_PRESENT (or
  /// stops answering for a moment while it restarts). The new URI it was
  /// just sent is lost with the player. The old code then idled for the whole
  /// patience window (12 s+) — or, when the TV had gone quiet, even assumed
  /// the item had started — and nothing reached the screen until the person
  /// tapped again, which worked only because the TV was idle by then. Now a
  /// mid-playback switch that leaves the TV STOPPED without ever being seen
  /// TRANSITIONING is re-sent straight away, to the TV that has settled
  /// idle — exactly what the second tap used to do by hand.
  bool _waitDropped = false;

  /// PHASE 1: set by [_waitForPlaying] when it ran out of time while the TV
  /// was visibly still opening the item (TRANSITIONING) — a slow start, not
  /// a failure. The attempt loop then waits longer instead of aborting the
  /// start with a Stop and a fallback form.
  bool _waitStillOpening = false;

  /// PHASE 1: the AirScreen profile already re-sent Play once during this
  /// load; [_handleRendererStopped] must not nudge it a second time.
  bool _replayedDuringLoad = false;

  /// PHASE 1: the streams the last failed load tried, so a start that the
  /// TV completes late can be recognised and adopted (see
  /// [_reconcileAfterFailure]). Cleared when the next load begins.
  List<_DlnaStream> _failedAttempts = const [];

  /// Item id that [_handleRendererStopped] has already re-sent once after
  /// the TV went STOPPED without ever having played it (the switch was
  /// accepted while the TV still reported the OLD item as playing). Cleared
  /// on every fresh [load] and as soon as an item is confirmed playing, so
  /// the recovery runs at most once per attempt and can never loop.
  String? _dropReloadedFor;

  // Volume: SetVolume calls are coalesced (latest wins) so a dragged slider
  // or a held volume key can't pile up reordered SOAP requests.
  double? _pendingVolume;
  bool _volumeSending = false;
  DateTime _holdVolumeUntil = DateTime.fromMillisecondsSinceEpoch(0);

  // Subtitle styling (see applySubtitleStyle).
  SubtitleAppearance _appearance = SubtitleAppearanceSettings.notifier.value;
  String _loadedStyleKey = '';
  Timer? _styleReloadTimer;
  final Map<String, String> _subtitleTextCache = {};

  // Android Wi-Fi multicast lock (see MainActivity.kt).
  static const MethodChannel _multicastChannel =
      MethodChannel('com.nemesis.app/multicast_lock');

  bool get _loading => _activeLoads > 0;

  // ═══════════════════════════════════════════════════════════════════════
  // Discovery
  // ═══════════════════════════════════════════════════════════════════════

  @override
  Stream<List<CastDevice>> discover() {
    _teardownDiscovery();
    final controller = StreamController<List<CastDevice>>.broadcast();
    _controller = controller;
    final gen = ++_discoveryGen;
    unawaited(_startSsdp(gen));
    // Anything already known from an earlier scan shows up immediately.
    Future<void>(_emit);
    return controller.stream;
  }

  @override
  Future<void> stopDiscovery() async {
    _teardownDiscovery();
  }

  Future<void> _setMulticastLock(bool acquire) async {
    if (!Platform.isAndroid) return;
    try {
      await _multicastChannel.invokeMethod<bool>(acquire ? 'acquire' : 'release');
    } on MissingPluginException {
      // Older native shell without the channel — discovery still works on
      // most devices, just without the lock.
    } catch (e) {
      debugPrint('DlnaTransport: multicast lock ${acquire ? 'acquire' : 'release'} failed: $e');
    }
  }

  void _teardownDiscovery() {
    unawaited(_setMulticastLock(false));
    _discoveryGen++;
    for (final t in _discoveryTimers) {
      t.cancel();
    }
    _discoveryTimers.clear();
    for (final s in _sockets) {
      try {
        s.close();
      } catch (_) {}
    }
    _sockets.clear();
    final c = _controller;
    _controller = null;
    if (c != null && !c.isClosed) {
      unawaited(c.close());
    }
  }

  Future<void> _startSsdp(int gen) async {
    // The multicast lock is taken while the interfaces are listed and the
    // sockets bound (it used to finish first, one platform round trip
    // before anything else could start); it is still awaited before the
    // first M-SEARCH goes out.
    final lockReady = _setMulticastLock(true);
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
        includeLinkLocal: false,
      );
      final binds = <Future<void>>[];
      for (final iface in interfaces) {
        // Mobile-data / VPN / tunnel interfaces can't see a TV on the LAN.
        if (RegExp(r'^(rmnet|ccmni|pdp|tun|ppp|dummy|v4-|clat)',
                caseSensitive: false)
            .hasMatch(iface.name)) {
          continue;
        }
        for (final addr in iface.addresses) {
          binds.add(_bindSocket(addr, gen));
        }
      }
      await Future.wait(binds);
    } catch (e) {
      debugPrint('DlnaTransport: listing interfaces failed: $e');
    }
    await lockReady;
    if (gen != _discoveryGen) {
      unawaited(_setMulticastLock(false));
      return;
    }
    if (_sockets.isEmpty) {
      await _bindSocket(InternetAddress.anyIPv4, gen);
    }
    if (gen != _discoveryGen) return;

    // M-SEARCH is lossy UDP — send a few bursts early, then keep refreshing
    // so renderers that were asleep on the first scan still show up.
    //
    // ROOT CAUSE (DLNA devices missing on the FIRST open of the device
    // picker, all there on the second): the burst schedule used to be
    // 0/0.7/2/4.5s and then nothing until a refresh every 12s. A cold
    // first scan is the lossy one — the Wi-Fi radio was just woken, the
    // multicast lock has barely taken effect, and a TV that is asleep or
    // slow to answer misses all four early packets — so such a renderer
    // only appeared 12s+ in. The second open looked complete only because
    // `_renderers` (kept across opens) already held everything the first
    // open eventually found. Bursts are now denser across the first
    // seconds (still stopping as soon as the picker closes — discovery is
    // only ever running while the sheet is open) with a faster steady
    // refresh afterwards, so devices keep emerging live instead of
    // needing a re-open.
    _sendSearch();
    for (final ms in const [350, 900, 1700, 2800, 4200, 6000]) {
      _discoveryTimers.add(Timer(Duration(milliseconds: ms), () {
        if (gen == _discoveryGen) _sendSearch();
      }));
    }
    _discoveryTimers.add(Timer.periodic(const Duration(seconds: 7), (_) {
      if (gen == _discoveryGen) _sendSearch();
    }));
    _discoveryTimers.add(Timer.periodic(const Duration(seconds: 10), (_) {
      if (gen == _discoveryGen) _emit();
    }));
  }

  Future<void> _bindSocket(InternetAddress address, int gen) async {
    try {
      final socket = await RawDatagramSocket.bind(address, 0);
      if (gen != _discoveryGen) {
        socket.close();
        return;
      }
      socket.multicastHops = 4;
      socket.listen(
        (event) {
          if (event != RawSocketEvent.read) return;
          for (;;) {
            final datagram = socket.receive();
            if (datagram == null) break;
            _handleDatagram(datagram);
          }
        },
        onError: (Object e) => debugPrint('DlnaTransport SSDP socket error: $e'),
        cancelOnError: false,
      );
      _sockets.add(socket);
    } catch (e) {
      debugPrint('DlnaTransport: could not bind SSDP socket on $address: $e');
    }
  }

  void _sendSearch() {
    for (final target in _searchTargets) {
      final message = 'M-SEARCH * HTTP/1.1\r\n'
          'HOST: $_ssdpAddress:$_ssdpPort\r\n'
          'MAN: "ssdp:discover"\r\n'
          'MX: 2\r\n'
          'ST: $target\r\n'
          'USER-AGENT: Android UPnP/1.1 Nemesis/1.0\r\n'
          '\r\n';
      final data = utf8.encode(message);
      for (final socket in List<RawDatagramSocket>.of(_sockets)) {
        try {
          socket.send(data, InternetAddress(_ssdpAddress), _ssdpPort);
        } catch (_) {}
      }
    }
  }

  void _handleDatagram(Datagram datagram) {
    final text = utf8.decode(datagram.data, allowMalformed: true);
    final lines = text.split(RegExp(r'\r?\n'));
    if (lines.isEmpty) return;
    final first = lines.first.toUpperCase();
    if (!first.startsWith('HTTP/1.1 200') && !first.startsWith('NOTIFY')) {
      return;
    }

    String? location;
    String? target;
    String? nts;
    for (final line in lines.skip(1)) {
      final idx = line.indexOf(':');
      if (idx <= 0) continue;
      final name = line.substring(0, idx).trim().toLowerCase();
      final value = line.substring(idx + 1).trim();
      switch (name) {
        case 'location':
          location = value;
          break;
        case 'st':
        case 'nt':
          target = value;
          break;
        case 'nts':
          nts = value;
          break;
      }
    }
    if (nts != null && nts.toLowerCase().contains('byebye')) return;
    if (location == null || location.isEmpty) return;
    if (target != null &&
        !target.contains('MediaRenderer') &&
        !target.contains('AVTransport')) {
      return;
    }
    _onLocation(location);
  }

  void _onLocation(String location) {
    final knownId = _locationToId[location];
    if (knownId != null) {
      _renderers[knownId]?.lastSeen = DateTime.now();
      return;
    }
    final ignoredAt = _ignoredLocations[location];
    if (ignoredAt != null && DateTime.now().isBefore(ignoredAt)) return;
    if (!_describing.add(location)) return;
    unawaited(_describe(location).whenComplete(() {
      _describing.remove(location);
    }));
  }

  /// PHASE 5 (test seam): reads a renderer's description document the way
  /// discovery does and registers it, so a test can [connect] to a fake
  /// renderer without SSDP multicast. Throws if it is not a renderer.
  @visibleForTesting
  Future<CastDevice> debugAddRenderer(Uri description) async {
    final xml = await _httpGet(description, const Duration(seconds: 4));
    final renderer = _parseDescription(xml, description);
    if (renderer == null) {
      throw StateError('$description is not a UPnP media renderer');
    }
    renderer.lastSeen = DateTime.now();
    _renderers[renderer.id] = renderer;
    _locationToId[description.toString()] = renderer.id;
    return _toDevice(renderer);
  }

  Future<void> _describe(String location) async {
    try {
      final uri = Uri.parse(location);

      // ROOT CAUSE (renderer missing until the picker was reopened): one
      // failed/slow description fetch — typical for the FIRST request to a
      // TV that is waking up or whose ARP entry is cold — put the location
      // on the ignore list for 20s, so a perfectly good renderer stayed
      // invisible for that long even though it kept answering M-SEARCH.
      // Retry a couple of times right away before giving up, and the
      // give-up itself is short (see below).
      String? xml;
      Object? lastError;
      for (var attempt = 0; attempt < 3; attempt++) {
        try {
          xml = await _httpGet(uri, const Duration(seconds: 4));
          break;
        } catch (e) {
          lastError = e;
          if (attempt < 2) {
            await Future<void>.delayed(
              Duration(milliseconds: 500 * (attempt + 1)),
            );
          }
        }
      }
      if (xml == null) throw lastError ?? StateError('empty description');

      final renderer = _parseDescription(xml, uri);
      if (renderer == null) {
        // Responded, but isn't a renderer (no AVTransport) — don't refetch.
        _ignoredLocations[location] =
            DateTime.now().add(const Duration(minutes: 5));
        return;
      }
      renderer.lastSeen = DateTime.now();
      _renderers[renderer.id] = renderer;
      _locationToId[location] = renderer.id;
      _emit();
    } catch (e) {
      debugPrint('DlnaTransport: describing $location failed: $e');
      // Short on purpose (was 20s): the next M-SEARCH response from this
      // location simply tries again, which is what lets a slow TV appear
      // live while the picker is open.
      _ignoredLocations[location] =
          DateTime.now().add(const Duration(seconds: 3));
    }
  }

  _DlnaRenderer? _parseDescription(String xml, Uri location) {
    final urlBase = _tag(xml, 'URLBase')?.trim();
    final base = (urlBase != null && urlBase.isNotEmpty)
        ? (Uri.tryParse(urlBase) ?? location)
        : location;

    _DlnaService? av;
    _DlnaService? rc;
    final services =
        RegExp(r'<service>([\s\S]*?)</service>', caseSensitive: false);
    for (final match in services.allMatches(xml)) {
      final block = match.group(1) ?? '';
      final type = _tag(block, 'serviceType')?.trim();
      final control = _tag(block, 'controlURL')?.trim();
      if (type == null || control == null || control.isEmpty) continue;
      final controlUri = base.resolve(control);
      final scpd = _tag(block, 'SCPDURL')?.trim();
      final scpdUri =
          (scpd != null && scpd.isNotEmpty) ? base.resolve(scpd) : null;
      if (type.contains(':service:AVTransport:')) {
        av ??= _DlnaService(type, controlUri, scpdUri);
      } else if (type.contains(':service:RenderingControl:')) {
        rc ??= _DlnaService(type, controlUri, scpdUri);
      }
    }
    if (av == null) return null;

    final friendly = _tag(xml, 'friendlyName')?.trim();
    final manufacturer = _tag(xml, 'manufacturer')?.trim() ?? '';
    final model = _tag(xml, 'modelName')?.trim() ?? '';
    final extra = [
      _tag(xml, 'modelDescription'),
      _tag(xml, 'manufacturerURL'),
      _tag(xml, 'modelURL'),
      _tag(xml, 'modelNumber'),
    ].whereType<String>().map((e) => e.trim()).where((e) => e.isNotEmpty).join(' ');
    final udn = _tag(xml, 'UDN')?.trim();
    final key = (udn != null && udn.isNotEmpty)
        ? udn.replaceFirst(RegExp(r'^uuid:', caseSensitive: false), '')
        : '${location.host}:${location.port}';

    return _DlnaRenderer(
      id: '$_idPrefix$key',
      friendlyName:
          (friendly != null && friendly.isNotEmpty) ? friendly : location.host,
      manufacturer: manufacturer,
      modelName: model,
      host: location.host,
      avTransport: av,
      renderingControl: rc,
      extraFingerprint: extra,
    );
  }

  void _emit() {
    final controller = _controller;
    if (controller == null || controller.isClosed) return;
    final cutoff = DateTime.now().subtract(const Duration(seconds: 75));
    controller.add([
      for (final r in _renderers.values)
        if (r.lastSeen.isAfter(cutoff)) _toDevice(r),
    ]);
  }

  CastDevice _toDevice(_DlnaRenderer r) {
    final label = [r.manufacturer, r.modelName]
        .where((s) => s.isNotEmpty)
        .join(' ')
        .trim();
    // The Trigon TV receiver app is a standard UPnP MediaRenderer that
    // identifies itself through its manufacturer / model strings.
    final maker = '${r.manufacturer} ${r.modelName}'.toLowerCase();
    final isNemesisReceiver =
        maker.contains('trigon') || maker.contains('nemesis');
    return CastDevice(
      id: r.id,
      displayName: r.friendlyName,
      roomOrGroup: label.isEmpty ? null : label,
      isNemesisReceiver: isNemesisReceiver,
      transports: {
        CastTransportKind.dlna: CastCapability(
          play: true,
          pause: true,
          stop: true,
          seek: true,
          volume: r.renderingControl != null,
          queue: true,
        ),
      },
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  // Connect / disconnect
  // ═══════════════════════════════════════════════════════════════════════

  @override
  Future<CastSession> connect(CastDevice device) async {
    final renderer = _renderers[device.id] ??
        (_aliases[device.id] == null ? null : _renderers[_aliases[device.id]]);
    if (renderer == null) {
      throw Exception(
        '${device.displayName} is no longer visible on the network. '
        'Make sure the TV is on and on the same Wi-Fi, then try again.',
      );
    }

    final session = CastSession(
      device: device,
      transportKind: kind,
      initialConnectionState: CastConnectionState.connecting,
    );

    // Reachability probe — a TV that's off (or on another VLAN) fails here
    // with a clear message instead of failing later on the first load().
    //
    // ROOT CAUSE (AirScreen / some Kodi builds "couldn't be reached" although
    // they were on and visible): the probe treated ANY exception as "TV
    // unreachable", including a SOAP fault. A fault is an ANSWER — the TV is
    // there, it just refuses GetTransportInfo in its current idle state — and
    // the first request to a TV that was asleep also routinely times out
    // once. Only a TV that stays silent on two tries is unreachable.
    var reachable = false;
    for (var probe = 0; probe < 2 && !reachable; probe++) {
      try {
        await _soapCall(
          renderer.avTransport,
          'GetTransportInfo',
          const {'InstanceID': '0'},
          timeout: const Duration(seconds: 5),
        );
        reachable = true;
      } on _DlnaSoapException {
        reachable = true;
      } catch (_) {
        if (probe == 0) {
          await Future<void>.delayed(const Duration(milliseconds: 400));
        }
      }
    }
    if (!reachable) {
      session.lastError.value = 'Couldn\'t reach ${device.displayName}.';
      session.connectionState.value = CastConnectionState.error;
      throw Exception(
        'Couldn\'t reach ${device.displayName}. Check that the TV is on and '
        'on the same Wi-Fi network.',
      );
    }

    // One line that says which behaviour profile this renderer was given —
    // the first thing to read in the log when a TV misbehaves.
    final profile = identical(renderer.quirks, _RendererQuirks._airScreen)
        ? 'AirScreen'
        : identical(renderer.quirks, _RendererQuirks._kodi)
            ? 'Kodi'
            : 'generic';
    debugPrint('DlnaTransport: connected to "${renderer.friendlyName}" '
        '(manufacturer="${renderer.manufacturer}", '
        'model="${renderer.modelName}", ${renderer.extraFingerprint}) '
        '-> $profile profile');

    _stopPolling();
    _renderer = renderer;
    _session = session;
    // PHASE 2 (F2.3): the phone address put into every URL it serves to this
    // TV is the one on the TV's own subnet.
    LocalCastServer.instance.setPeerHint(renderer.host);
    _loadGeneration++;
    _activeLoads = 0;
    _commandedStop = false;
    _pollFailures = 0;
    _lastPollOkAt = DateTime.now();
    _declaredSubtitleId = -1;
    _pollTick = 0;
    _current = null;
    _streamOffset = Duration.zero;
    _lastPolledPosition = Duration.zero;
    _loadTail = null;
    _failureStop = null;
    _dropReloadedFor = null;
    _localTsFallbackUrls.clear();
    // A fresh connection forgets what earlier loads "learned" about this
    // renderer (see [_pendingLearn]) so one bad moment can never stick.
    _plainMetadataRenderers.clear();
    _altMimeKeys.clear();
    CastArtwork.instance.reset();
    _coverRejectedRenderers.clear();
    _loadCoverFuture = null;
    _loadCover = null;
    _loadCoverItemId = null;
    _subtitleBlocked.clear();
    _pendingLearn = null;
    _resetPlaybackTracking(Duration.zero);

    _appearance = SubtitleAppearanceSettings.notifier.value;
    _loadedStyleKey = _tagStyle(_appearance).key;
    _styleReloadTimer?.cancel();
    _subtitleTextCache.clear();
    _pendingVolume = null;

    // What the TV itself says it can do (playback speeds, volume range).
    await _loadRendererCaps(renderer);
    session.capabilityNotifier.value = session.capability.copyWith(
      volume: renderer.renderingControl != null,
    );

    // Seed the volume slider with the TV's real volume (best effort).
    await _refreshVolume(session, force: true);

    session.connectionState.value = CastConnectionState.connected;
    _startPolling(session);
    return session;
  }

  @override
  Future<void> disconnect(CastSession session) async {
    final renderer = _renderer;
    final wasActive = identical(session, _session);
    // ROOT CAUSE (phone disconnects, TV keeps playing — Disconnect button AND
    // Switch device, which goes through the same CastManager.disconnect()):
    //  * the single Stop had a 2 s timeout, no retry and swallowed every
    //    error, so a Kodi/AirScreen/TV that was slow, busy opening a big
    //    stream or in TRANSITIONING (it refuses Stop there) just kept playing;
    //  * a load still in flight could land its SetAVTransportURI/Play AFTER
    //    that Stop and start the TV again.
    // Stop is now retried until the renderer itself reports
    // STOPPED/NO_MEDIA_PRESENT, and a load that was mid-flight gets one more
    // Stop once it has unwound.
    final pendingLoad = wasActive ? _loadTail : null;
    final loadWasRunning = wasActive && _loading;
    if (wasActive) _localTsFallbackUrls.clear();
    _stopPolling();
    _styleReloadTimer?.cancel();
    _subtitleTextCache.clear();
    _pendingVolume = null;
    final gen = ++_loadGeneration;
    if (wasActive) {
      _session = null;
      _renderer = null;
      _current = null;
    }
    if (renderer != null && wasActive) {
      final stopped = await _stopRendererReliably(
        renderer,
        budget: const Duration(seconds: 5),
        maxSilent: 1,
        superseded: () => gen != _loadGeneration,
        settle: renderer.quirks.verifyStopSettled,
      );
      if (!stopped || loadWasRunning) {
        unawaited(_finishStopAfterDisconnect(renderer, gen, pendingLoad));
      }
    }
    session.connectionState.value = CastConnectionState.disconnected;
  }

  /// Sends Stop until the renderer itself confirms it is STOPPED /
  /// NO_MEDIA_PRESENT. Returns true once confirmed (or when there is nothing
  /// left to do), false when it could not be confirmed — TV unreachable or
  /// [budget] used up. Never throws.
  Future<bool> _stopRendererReliably(
    _DlnaRenderer renderer, {
    required Duration budget,
    required int maxSilent,
    required bool Function() superseded,
    bool settle = false,
  }) async {
    final deadline = DateTime.now().add(budget);
    var silent = 0;
    var round = 0;
    var settleChecks = 0;
    while (true) {
      if (superseded()) return true;
      round++;

      // A renderer that has ignored two Stops in a row is still playing: a
      // Pause first silences it at once, and the Stop that follows then
      // ends the session (never sent on the first rounds, so a renderer
      // that stops normally sees exactly the plain Stop it always did).
      if (round >= 3) {
        try {
          await _soapCall(renderer.avTransport, 'Pause', const {'InstanceID': '0'},
              timeout: const Duration(seconds: 2));
        } catch (_) {}
        if (superseded()) return true;
      }

      var stopAccepted = false;
      var answered = false;
      try {
        await _soapCall(renderer.avTransport, 'Stop', const {'InstanceID': '0'},
            timeout: const Duration(seconds: 3));
        stopAccepted = true;
        answered = true;
      } on _DlnaSoapException {
        // The TV answered with a fault (already stopped, or 701/705 while
        // it is switching) — the state check below decides what that meant.
        answered = true;
      } catch (_) {
        // No answer at all (timeout / socket error).
      }

      if (answered) {
        try {
          final state =
              await _transportState(renderer, timeout: const Duration(seconds: 2));
          if (state == null ||
              state == 'STOPPED' ||
              state == 'NO_MEDIA_PRESENT') {
            if (!settle || settleChecks >= 3) return true;
            // STOPPED can just mean "has not started yet" (see
            // [_RendererQuirks.verifyStopSettled]): look again shortly and
            // Stop once more if it has begun playing in the meantime.
            settleChecks++;
            await Future<void>.delayed(const Duration(milliseconds: 1200));
            if (superseded()) return true;
            String? again;
            try {
              again = await _transportState(renderer,
                  timeout: const Duration(seconds: 2));
            } catch (_) {
              return true;
            }
            if (again == null ||
                again == 'STOPPED' ||
                again == 'NO_MEDIA_PRESENT') {
              return true;
            }
            debugPrint('DlnaTransport[${renderer.friendlyName}]: reported '
                'STOPPED but is $again again — stopping it once more');
            continue;
          }
        } on _DlnaSoapException {
          // Renderer doesn't implement GetTransportInfo properly: an
          // accepted Stop is the best proof available.
          if (stopAccepted) return true;
        } catch (_) {
          answered = false;
        }
      }

      silent = answered ? 0 : silent + 1;
      if (silent >= maxSilent) return false;
      if (DateTime.now().add(const Duration(milliseconds: 400)).isAfter(deadline)) {
        return false;
      }
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
  }

  /// Runs after [disconnect] has already returned: waits for any load that
  /// was mid-flight to unwind (its last SetURI/Play may have reached the TV
  /// after our first Stop) and then stops the renderer again, retrying while
  /// it still reports anything but STOPPED. Gives up silently if a new
  /// session started in the meantime so it can never kill a fresh cast.
  Future<void> _finishStopAfterDisconnect(
    _DlnaRenderer renderer,
    int gen,
    Future<void>? pendingLoad,
  ) async {
    bool superseded() => gen != _loadGeneration || _session != null;
    try {
      if (pendingLoad != null) {
        try {
          await pendingLoad.timeout(const Duration(seconds: 20));
        } catch (_) {}
      }
      if (superseded()) return;
      final stopped = await _stopRendererReliably(
        renderer,
        budget: const Duration(seconds: 12),
        maxSilent: 3,
        superseded: superseded,
        settle: renderer.quirks.verifyStopSettled,
      );
      // Last resort for a renderer that still would not stop: take the item
      // away from it (an empty URI is the UPnP way to clear it), then Stop.
      if (!stopped && !superseded()) {
        try {
          await _soapCall(renderer.avTransport, 'SetAVTransportURI', const {
            'InstanceID': '0',
            'CurrentURI': '',
            'CurrentURIMetaData': '',
          }, timeout: const Duration(seconds: 3));
        } catch (_) {}
        try {
          await _soapCall(renderer.avTransport, 'Stop', const {'InstanceID': '0'},
              timeout: const Duration(seconds: 3));
        } catch (_) {}
      }
    } catch (_) {}
  }

  // ═══════════════════════════════════════════════════════════════════════
  // Loading
  // ═══════════════════════════════════════════════════════════════════════

  @override
  Future<void> load(
    CastSession session,
    MediaItem item, {
    Duration startAt = Duration.zero,
  }) {
    final resumeAt = startAt > Duration.zero ? startAt : item.resumePosition;
    // The coordinator reloads the item "at the current position" to change
    // an audio/subtitle track or add a subtitle. If the person had paused,
    // keep the TV paused afterwards instead of silently resuming.
    final isInPlaceReload = startAt > Duration.zero &&
        identical(session, _session) &&
        session.currentItem.value?.id == item.id &&
        session.playbackState.value == CastPlaybackState.paused;
    // A fresh load from the app gets its own one-time drop recovery.
    _dropReloadedFor = null;
    return _loadItem(session, item,
        startAt: resumeAt, startPaused: isInPlaceReload);
  }

  /// A DLNA renderer plays ONE uri at a time. The queue is therefore kept
  /// phone-side: the requested item is loaded, and PlaybackCoordinator's
  /// mirrored-queue auto-advance (it watches [CastPlaybackState.ended] +
  /// [CastIdleReason.finished]) sends the next track when this one ends.
  @override
  Future<void> loadQueue(
    CastSession session,
    List<MediaItem> items, {
    int startIndex = 0,
    Duration startAt = Duration.zero,
  }) {
    if (items.isEmpty) {
      throw StateError('Nothing to cast: the queue is empty.');
    }
    final index = startIndex.clamp(0, items.length - 1);
    return load(session, items[index], startAt: startAt);
  }

  /// Loads are strictly serialised. Bumping [_loadGeneration] first makes
  /// any load already in flight bail out at its next checkpoint (every SOAP
  /// step checks it); this one then waits for that load to finish unwinding
  /// before touching the renderer, so two Stop/SetURI/Play sequences can
  /// never interleave. [_activeLoads] is held for the whole wait so the
  /// poller can't misread the in-between renderer state as an end of track.
  Future<void> _loadItem(
    CastSession session,
    MediaItem item, {
    required Duration startAt,
    bool preferTranscode = false,
    bool isSeekReload = false,
    bool startPaused = false,
  }) async {
    _requireRenderer(session);
    // PHASE 2 (F2.2/F2.7): a local item whose phone-server URL the running
    // server no longer owns would hand the TV a dead address (it ends as
    // "the TV never fetched the file"). Say so plainly instead. The app-side
    // paths re-resolve such an item before it gets here; this catches an
    // internal reload (style change, dropped-item reload) of an old copy.
    if (item.isLocal) {
      final url = item.castStreamUrl;
      if (url != null &&
          LocalCastServer.isPhoneServerUrl(url) &&
          !LocalCastServer.instance.ownsUrl(url)) {
        throw StateError(
          '"${item.title}" is no longer being shared from this phone — '
          'pick it again to cast it.',
        );
      }
    }
    final gen = ++_loadGeneration;
    _activeLoads++;
    final previous = _loadTail;
    final done = Completer<void>();
    _loadTail = done.future;
    try {
      if (previous != null) {
        try {
          await previous;
        } catch (_) {}
      }
      // RETRY FIX: the clean-up Stop of a failed load runs unawaited; a
      // retry tapped right away used to race it, and the late Stop killed
      // the very item the retry had just started. Wait for it (bounded).
      final pendingStop = _failureStop;
      if (pendingStop != null) {
        _failureStop = null;
        try {
          await pendingStop.timeout(const Duration(seconds: 4));
        } catch (_) {}
      }
      // A newer load arrived while this one was queued: it supersedes us.
      if (gen != _loadGeneration) return;
      await _loadItemBody(
        session,
        item,
        gen: gen,
        startAt: startAt,
        preferTranscode: preferTranscode,
        isSeekReload: isSeekReload,
        startPaused: startPaused,
      );
    } finally {
      // PHASE 0: a load that a newer one replaced returns to its caller
      // without saying so — leave a trace of it.
      if (gen != _loadGeneration) {
        debugPrint('DlnaTransport: load #$gen "${item.title}" ended '
            'superseded by load #$_loadGeneration');
      }
      _activeLoads = _activeLoads > 0 ? _activeLoads - 1 : 0;
      // Time spent inside a (possibly 45 s) load is not "the TV was
      // silent": restart the lost-connection clock when the load ends.
      _lastPollOkAt = DateTime.now();
      _pollFailures = 0;
      done.complete();
    }
  }

  /// Forgets everything learned about the previous track. Called for every
  /// load and every connect — nothing about "where the last song was" may
  /// leak into the decision of whether this one has ended.
  void _resetPlaybackTracking(Duration startAt) {
    _loadedAt = null;
    _loadStartAt = startAt;
    _wallBase = startAt;
    _playedFor = Duration.zero;
    _lastPlayingPollAt = null;
    _playingPolls = 0;
    _lastTrackDuration = Duration.zero;
    _directStartAt = Duration.zero;
    _trustRel = false;
    _confirmedPlaying = false;
    _startNudged = false;
    _replayedDuringLoad = false;
    _lastPolledPosition = startAt;
    _wantedPlayback = null;
    _wantedRetried = false;
    _relSeen = false;
    _lastPlayingSeenAt = null;
    _seekSerial++;
  }

  Future<void> _loadItemBody(
    CastSession session,
    MediaItem item, {
    required int gen,
    required Duration startAt,
    bool preferTranscode = false,
    bool isSeekReload = false,
    bool startPaused = false,
  }) async {
    final renderer = _requireRenderer(session);

    // A direct switch (no Stop first, see [_RendererQuirks.stopBeforeSwitch])
    // is only for a real change of item. Reloading the item that is playing
    // right now (a seek on a transcode, an audio/subtitle/style change)
    // keeps the classic sequence it has always used.
    final previousState = session.playbackState.value;
    final inPlaceReload = session.currentItem.value?.id == item.id &&
        (previousState == CastPlaybackState.playing ||
            previousState == CastPlaybackState.paused ||
            previousState == CastPlaybackState.buffering);
    // RETRY FIX (once a movie failed to cast, every retry failed too): after
    // a failed VIDEO load the TV is left in an unknown state — a half-open
    // player, a sticky ERROR_OCCURRED, a "can't play" dialog — and a bare
    // SetAVTransportURI on top of that is ignored or refused again and
    // again. The TV is idle at that point (nothing is playing, so there is
    // no player to tear down), which makes the classic Stop-first reset
    // harmless and is what clears it. Songs keep their direct switch.
    //
    // ROOT CAUSE (once ANY title failed to cast, later casts of it kept
    // failing): this reset was limited to videos, so after a failed song a
    // direct switch was sent on top of the same unknown state. The TV is idle
    // after a failure whatever the item was, so the Stop-first reset is safe
    // (and needed) for every kind of item.
    final afterFailedVideo = previousState == CastPlaybackState.error;
    final switchDirectly = !renderer.quirks.stopBeforeSwitch &&
        !isSeekReload &&
        !inPlaceReload &&
        !afterFailedVideo;
    // A real switch away from an item that is playing right now — the only
    // case in which a TV's own receiver tears its player down under us (see
    // [_waitDropped]).
    // Also while the previous tap was still loading when this one arrived
    // (it was superseded and left the state at `loading`): the TV may well
    // be playing an even older item, and the "TV dropped the switch"
    // recovery must apply to this rapid second tap too. A fresh session
    // (no current item yet) is not a switch away from anything.
    final switchedFromActive = switchDirectly &&
        (previousState == CastPlaybackState.playing ||
            previousState == CastPlaybackState.paused ||
            previousState == CastPlaybackState.buffering ||
            (previousState == CastPlaybackState.loading &&
                session.currentItem.value != null));

    _commandedStop = false;
    _resetPlaybackTracking(startAt);

    // PHASE 0: a fresh timeline per load, and one line saying what this
    // load intends to do.
    _failedAttempts = const [];
    _tlEvents.clear();
    _tlSends.clear();
    _tlMediaUrls.clear();
    _tlSubUrls.clear();
    _tlStart = DateTime.now();
    debugPrint('DlnaTransport[${renderer.friendlyName}]: load #$gen '
        '"${item.title}" (${item.isLocal ? 'local' : 'server'} '
        '${item.audioOnly ? 'audio' : (item.live ? 'live' : 'video')}) '
        'startAt=${startAt.inSeconds}s '
        'mode=${switchDirectly ? 'direct-switch' : 'stop-first'} '
        'previousState=$previousState inPlaceReload=$inPlaceReload '
        'seekReload=$isSeekReload '
        'art=${_redact(item.image ?? '-')}');

    // PHASE 3: start preparing the cover now; it is ready long before the
    // TV has been stopped and made idle, and is awaited in [_sendStream].
    _startCoverPrep(item);

    session.idleReason.value = null;
    session.lastError.value = null;
    session.currentItem.value = item;
    // Always overwritten (zero when the item's runtime is unknown), so the
    // previous song's length can never be mistaken for this one's.
    session.duration.value = item.runtime;
    session.playbackState.value =
        isSeekReload ? CastPlaybackState.buffering : CastPlaybackState.loading;
    session.playbackRateNotifier.value = 1.0;
    // The style this load's subtitle is rendered with; applySubtitleStyle
    // compares against it so a later push only reloads on a real change.
    final style = _tagStyle(_appearance);
    _loadedStyleKey = style.key;
    _seedCapabilityAndTracks(session, item);

    // PHASE 0: true once this load has written its summary line, so the
    // outer catch doesn't write a second one for the same failure.
    var summarized = false;

    try {
      // Growable on purpose: a local video the TV refuses as it is gets an
      // on-device MPEG-TS remux appended below.
      final attempts = List<_DlnaStream>.of(_buildAttempts(
        item,
        startAt: startAt,
        preferTranscode: preferTranscode,
      ));
      // A remux the TV already accepted for this item is tried first by
      // [_buildAttempts]; don't register a second one if it fails.
      var tsFallbackTried = _localTsFallbackUrls.containsKey(item.id);
      var subtitleRetryQueued = false;
      if (attempts.isEmpty) {
        throw StateError(
          '"${item.title}" has no network address a TV could play from.',
        );
      }

      var subtitle = _activeSubtitle(item);
      // A subtitle that already made the TV fail on this title is not
      // declared again (see [_subtitleBlocked]).
      if (subtitle != null &&
          _subtitleBlocked.contains('${item.id}|${subtitle.id}')) {
        subtitle = null;
      }
      final subtitleUrl =
          subtitle == null ? null : await _resolveSubtitleUrl(subtitle.url, style);
      if (gen != _loadGeneration) return;
      // A subtitle that couldn't be fetched (null) is left out of the
      // metadata entirely, so it can never be what stalls the TV.
      if (subtitle != null && subtitleUrl == null) {
        debugPrint('DlnaTransport[${renderer.friendlyName}]: subtitle '
            '#${subtitle.id} could not be fetched — casting without it');
      }
      _declaredSubtitleId = subtitleUrl == null ? -1 : subtitle!.id;
      _DlnaStream? started;
      Object? lastError;
      // The subtitle the TV's accepted metadata actually declares (null when
      // none, or when the TV only accepted the item without it).
      String? sentSubtitle = subtitleUrl;

      // Where the TV was in whatever it is playing right now. Only used to
      // recognise a direct switch that the TV ignored (it keeps playing the
      // old item, whose position is beyond anything the new item can have
      // reached yet).
      Duration? preRel;
      if (switchDirectly) {
        preRel = await _readRelTime(renderer);
        if (gen != _loadGeneration) return;
      }

      for (var attemptIndex = 0;
          attemptIndex < attempts.length;
          attemptIndex++) {
        // PHASE 1 (a start is never aborted by a fallback): before the next
        // form is sent, check whether the TV has meanwhile started playing
        // the one that "failed". A slow receiver that did is adopted as the
        // result instead of being stopped and sent something else.
        if (attemptIndex > 0 && started == null) {
          final previous = attempts[attemptIndex - 1];
          final lateStart = await _urlsPlayingNow(renderer, [previous.url]);
          if (gen != _loadGeneration) return;
          if (lateStart != null) {
            debugPrint('DlnaTransport[${renderer.friendlyName}]: the TV '
                'started "${item.title}" late (${previous.label}) — '
                'adopting it instead of trying another form');
            _tlAdd('late start adopted (${previous.label})');
            started = previous;
            _commitLearnedForm();
            break;
          }
        }
        final attempt = attempts[attemptIndex];
        if (gen != _loadGeneration) return;
        try {
          var ok = false;
          // Kodi / AirScreen (and every reload of the item already playing)
          // keep the Stop-first sequence exactly as before. Everything else
          // starts with a direct switch and drops back to Stop-first inside
          // this same attempt if the TV refuses or ignores it.
          var viaStop = !switchDirectly;
          var lostResends = 0;
          var dropResends = 0;
          var patienceExtended = false;
          for (var send = 0; send < 6; send++) {
            _waitLostUri = false;
            _waitStaleTrack = false;
            _waitDropped = false;
            debugPrint('DlnaTransport[${renderer.friendlyName}]: sending '
                '"${item.title}" (${attempt.label}) '
                '${viaStop ? 'Stop-first' : 'direct switch'}');
            _tlSends.add('${attempt.label}/'
                '${viaStop ? 'stop-first' : 'direct'}');
            _tlAdd('send ${attempt.label} '
                '${viaStop ? 'stop-first' : 'direct'}');
            // Only a send the TV ACCEPTED says what it was told.
            sentSubtitle = null;
            try {
              sentSubtitle = await _sendStream(
                renderer,
                item,
                attempt,
                attempt.noSubtitle ? null : subtitleUrl,
                gen,
                viaStop: viaStop,
              );
            } on _DlnaSoapException catch (e) {
              if (gen != _loadGeneration) return;
              if (!viaStop) {
                debugPrint('DlnaTransport[${renderer.friendlyName}]: direct '
                    'switch refused (${e.describe()}) — retrying Stop-first');
                viaStop = true;
                continue;
              }
              rethrow;
            }
            if (gen != _loadGeneration) return;
            ok = await _waitForPlaying(
              renderer,
              gen,
              attempt.transcoded
                  ? const Duration(seconds: 60)
                  : renderer.quirks.directStartTimeout,
              expectedUrl: attempt.url,
              transcoded: attempt.transcoded,
              directSwitch: !viaStop,
              preRel: preRel,
              switchedFromActive: switchedFromActive,
              isVideo: !item.audioOnly,
            );
            if (gen != _loadGeneration) return;
            if (ok) break;
            // PHASE 1: the TV was still TRANSITIONING when the patience ran
            // out — it is opening the item, not refusing it. Waiting longer
            // costs nothing; a Stop + new SetAVTransportURI would restart
            // the open (and is exactly what made slow starts "fail" while
            // the song then played on the TV).
            if (!ok && _waitStillOpening && !patienceExtended) {
              patienceExtended = true;
              debugPrint('DlnaTransport[${renderer.friendlyName}]: the TV is '
                  'still opening "${item.title}" — waiting longer instead of '
                  'trying another form');
              _tlAdd('patience extended 25s (TV still TRANSITIONING)');
              ok = await _waitForPlaying(
                renderer,
                gen,
                const Duration(seconds: 25),
                expectedUrl: attempt.url,
                transcoded: attempt.transcoded,
                directSwitch: !viaStop,
                preRel: preRel,
                switchedFromActive: switchedFromActive,
                isVideo: !item.audioOnly,
              );
              if (gen != _loadGeneration) return;
              if (ok) break;
            }
            // The TV closed its player when the old item was replaced and
            // lost the new one (see [_waitDropped]): re-send to the now idle
            // TV, at most twice per attempt.
            if (_waitDropped && dropResends < 2) {
              dropResends++;
              debugPrint('DlnaTransport[${renderer.friendlyName}]: the TV '
                  'dropped the switch — re-sending ($dropResends)');
              continue;
            }
            // At most one automatic re-send per attempt when the TV
            // positively lost the URI (see [_waitLostUri]).
            if (_waitLostUri && lostResends < 1) {
              lostResends++;
              continue;
            }
            // The TV ignored a switch sent without Stop: do it the
            // Stop-first way instead.
            if (_waitStaleTrack && !viaStop) {
              debugPrint('DlnaTransport[${renderer.friendlyName}]: direct '
                  'switch ignored — retrying Stop-first');
              viaStop = true;
              continue;
            }
            break;
          }
          if (ok) {
            started = attempt;
            _commitLearnedForm();
            // The same stream only played once the subtitle declaration was
            // taken out: that subtitle is what the TV choked on.
            if (attempt.noSubtitle && subtitleRetryQueued && subtitle != null) {
              _subtitleBlocked.add('${item.id}|${subtitle.id}');
              debugPrint('DlnaTransport[${renderer.friendlyName}]: the TV '
                  'only played \"${item.title}\" without its subtitle '
                  'declaration — not declaring it again');
            }
            // RETRY FIX: the TS form is only remembered once the TV has
            // PLAYED it. It used to be pinned the moment it was merely
            // registered, so one failed remux attempt made every later
            // load of that item use only that failing form.
            if (item.isLocal && attempt.label == 'local (on-device TS remux)') {
              _localTsFallbackUrls[item.id] = attempt.url;
            }
            break;
          }
          lastError = 'The TV didn\'t start playing "${item.title}".';
          debugPrint('DlnaTransport: ${attempt.label} attempt failed to start');
        } catch (e) {
          if (gen != _loadGeneration) return;
          lastError = e;
          debugPrint('DlnaTransport: ${attempt.label} attempt error: $e');
        }

        // A remembered TS form that did not play this time is forgotten, so
        // the next load tries the original file again.
        if (started == null && _localTsFallbackUrls[item.id] == attempt.url) {
          _localTsFallbackUrls.remove(item.id);
        }

        // ROOT CAUSE (local videos never play on a TV's own receiver, while
        // Kodi / AirScreen play them): the file was handed over exactly as
        // it is on the phone (MKV, AVI, MOV, WMV …). Kodi and AirScreen
        // decode all of those, but a TV's built-in receiver commonly can't
        // open them and just goes STOPPED — and unlike a Jellyfin title
        // there was no second form to fall back on (the server transcode
        // has no local equivalent), so the cast simply failed. MPEG-TS is
        // the container every TV firmware accepts, and the phone can
        // stream-copy into it without re-encoding. So when the TV fetched
        // the file and still wouldn't play it, a TS remux of the same file
        // is tried next (before the alternative MIME spelling), once per
        // load; a TV that plays the original never reaches this.
        if (started == null &&
            !tsFallbackTried &&
            _wantsLocalTsFallback(item, attempt)) {
          tsFallbackTried = true;
          try {
            final tsUrl = await LocalCastServer.instance.registerMediaAsMpegTs(
              item: item,
              sourceUri: item.streamUrl,
            );
            if (gen != _loadGeneration) return;
            attempts.insert(
              attemptIndex + 1,
              _DlnaStream(
                url: tsUrl.toString(),
                mime: 'video/mp2t',
                label: 'local (on-device TS remux)',
                durationHint: item.runtime,
              ),
            );
            debugPrint('DlnaTransport[${renderer.friendlyName}]: the TV '
                'fetched but did not play "${item.title}" as it is — '
                'trying an MPEG-TS remux');
          } catch (e) {
            if (gen != _loadGeneration) return;
            debugPrint('DlnaTransport: TS remux fallback unavailable: $e');
          }
        }

        // ROOT CAUSE (AirScreen / Kodi stopped casting videos altogether, and
        // a title that failed never worked again): every fresh video cast
        // now declares a default subtitle in the metadata. The TV accepted
        // that metadata, then stalled or stopped because it had to fetch /
        // open the subtitle first (a Jellyfin text subtitle is extracted on
        // the fly and can take a long time or fail) — and since the same
        // subtitle was sent again on every attempt and every retry, the
        // title failed identically forever. A start that failed with a
        // subtitle declared is now repeated ONCE with the very same stream
        // and no subtitle declaration, before any transcode is tried.
        if (started == null &&
            !attempt.noSubtitle &&
            sentSubtitle != null &&
            subtitleUrl != null) {
          subtitleRetryQueued = true;
          attempts.insert(attemptIndex + 1, attempt.withoutSubtitle());
          debugPrint('DlnaTransport[${renderer.friendlyName}]: no start '
              'with the subtitle declared — retrying the same stream '
              'without it');
        }
      }

      // PHASE 1 (late-start adoption): every form is exhausted, but the TV
      // may still be completing the start of one of them. Look once more
      // (the TV's own report of what it is playing is the authority); only
      // a positive match is adopted.
      if (started == null && attempts.isNotEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        if (gen != _loadGeneration) return;
        final matched = await _urlsPlayingNow(
            renderer, attempts.map((a) => a.url).toSet().toList());
        if (gen != _loadGeneration) return;
        if (matched != null) {
          started = attempts.firstWhere((a) => a.url == matched);
          debugPrint('DlnaTransport[${renderer.friendlyName}]: the TV is '
              'playing "${item.title}" after all (${started.label}) — '
              'adopting it');
          _tlAdd('late start adopted at the end (${started.label})');
          _commitLearnedForm();
        }
      }

      if (started == null) {
        // Leave the TV in a state that matches what the phone now reports:
        // a renderer that was merely slow must not start playing a title
        // the person has already been told failed.
        if (gen == _loadGeneration) {
          _failureStop = _bestEffortStop(renderer);
        }
        final message = (item.isLocal &&
                lastError is String &&
                _tvNeverFetched(attempts))
            // The TV accepted the item (nothing refused it) yet never asked
            // this phone for the file even once: the problem is the network
            // path, not the file.
            ? 'The TV couldn\'t reach this phone to fetch \"${item.title}\". '
                'Make sure both are on the same Wi-Fi network (not a guest '
                'network) and try again.'
            : lastError is _DlnaSoapException
                ? 'The TV refused to play this (${lastError.describe()}).'
                : (lastError is String
                    ? lastError
                    : 'Couldn\'t start playback on the TV.');
        _failedAttempts = List<_DlnaStream>.of(attempts);
        _tlAdd('FAILED: $message');
        _logLoadSummary('FAILED: $message', item, gen);
        summarized = true;
        session.lastError.value = message;
        session.playbackState.value = CastPlaybackState.error;
        throw StateError(message);
      }

      // The TV only took the item once the subtitle declaration was left
      // out: report what it was really told, so the Subtitles sheet shows
      // "Off" instead of ticking a track the TV isn't showing.
      if (!item.audioOnly && sentSubtitle == null) {
        _declaredSubtitleId = -1;
        if (session.activeSubtitleTrackId.value != -1) {
          session.activeSubtitleTrackId.value = -1;
        }
      }

      _current = started;
      _streamOffset = started.offset;
      _directStartAt = started.transcoded ? Duration.zero : startAt;
      _wallBase = startAt;
      _playedFor = Duration.zero;
      _lastPlayingPollAt = DateTime.now();
      _playingPolls = 1; // _waitForPlaying just saw it PLAYING
      _loadedAt = DateTime.now();
      // A seek-driven reload only ever happens mid-playback, so the item has
      // already proven it plays; a stop right after it is a real end.
      if (isSeekReload) _confirmedPlaying = true;

      // A direct (byte-seekable) stream always starts at 0 — jump to the
      // resume point now that the TV is actually playing. Transcoded
      // streams were already started at `startAt` server-side.
      if (!started.transcoded && startAt > const Duration(seconds: 2)) {
        await _seekWhenProgressing(renderer, gen, startAt);
        if (gen != _loadGeneration) return;
      } else if (started.transcoded) {
        session.reportPosition(startAt);
      }

      // Speed needs a stream the TV itself can time-scale: not a server
      // transcode (fixed-rate TS) and not live.
      session.capabilityNotifier.value = session.capability.copyWith(
        playbackRate: renderer.playSpeeds.isNotEmpty &&
            !started.transcoded &&
            !item.live,
      );

      session.playbackState.value = CastPlaybackState.playing;
      // The renderer's state right after a switch is the least trustworthy
      // moment: don't let an immediate poll overwrite it.
      _holdPollState();

      // PHASE 0: one summary line, plus a read-only look at what the TV
      // itself reports a couple of seconds into playback.
      _tlAdd('PLAYING via ${started.label}');
      _logLoadSummary('PLAYING via ${started.label}', item, gen);
      summarized = true;
      unawaited(_logRendererSnapshot(renderer, gen));

      // A reload done while the person had paused (subtitle/audio switch,
      // restyle, seek on a transcode) shouldn't unpause the TV.
      if (startPaused) {
        try {
          await _soapCall(
              renderer.avTransport, 'Pause', const {'InstanceID': '0'});
          _holdPollState();
          session.playbackState.value = CastPlaybackState.paused;
        } catch (e) {
          debugPrint('DlnaTransport: re-pausing after reload failed: $e');
        }
      }
    } catch (e) {
      if (!summarized && gen == _loadGeneration) {
        _tlAdd('EXCEPTION: $e');
        _logLoadSummary('EXCEPTION: $e', item, gen);
      }
      if (gen == _loadGeneration &&
          session.playbackState.value != CastPlaybackState.error) {
        session.lastError.value = e is LocalCastUnsupportedException
            ? e.message
            : (session.lastError.value ?? 'Couldn\'t start playback.');
        session.playbackState.value = CastPlaybackState.error;
      }
      rethrow;
    }
  }

  /// Whether a failed attempt on a LOCAL video justifies the on-device
  /// MPEG-TS remux: only when the TV did fetch the file from this phone
  /// (so the network path is fine and the container/codec is what it
  /// refused), the item isn't already TS, and the phone can remux.
  bool _wantsLocalTsFallback(MediaItem item, _DlnaStream attempt) {
    if (!Platform.isAndroid) return false;
    if (!item.isLocal || item.audioOnly || item.live) return false;
    if (item.raw?['CastLocalRemuxedTs'] == true) return false;
    // An addon link is relayed from an http source; there is no local file
    // to remux.
    if (item.streamUrl.startsWith('http')) return false;
    if (attempt.mime == 'video/mp2t') return false;
    final fetched = LocalCastServer.instance.requestCountForUrl(attempt.url);
    return fetched != null && fetched > 0;
  }

  /// True when every URL tried for a local item is one of this phone's own
  /// routes that the TV never requested even once.
  bool _tvNeverFetched(List<_DlnaStream> attempts) {
    if (attempts.isEmpty) return false;
    for (final a in attempts) {
      final n = LocalCastServer.instance.requestCountForUrl(a.url);
      if (n == null || n > 0) return false;
    }
    return true;
  }

  /// Stop → SetAVTransportURI → Play, with the retries real TVs need
  /// (Samsung rejects SetURI right after Stop with 701/705 for a moment;
  /// several LG models reject Play until the new URI is accepted).
  ///
  /// Returns the subtitle URL that ended up declared in the metadata the TV
  /// accepted (null when none was, or when the TV only accepted the item
  /// without it).
  ///
  /// ROOT CAUSE (MagiConnect never casts a movie / episode / video): the
  /// metadata a video carries is richer than a song's — the subtitle
  /// declaration (`<res text/srt>`, `sec:CaptionInfoEx`, `pv:subtitleFileUri`;
  /// every fresh video cast has one since the default-subtitle change) and a
  /// container MIME such as `video/x-matroska` or `video/mp2t` — and it was
  /// sent identically on every attempt. A renderer whose DIDL parser or
  /// protocolInfo sink list refuses any of it answered SetAVTransportURI
  /// with a fault each time, so every attempt (direct, then transcode) died
  /// the same way and the cast was reported as failed. A rejected
  /// SetAVTransportURI now walks down the metadata forms (with / without
  /// the subtitle declaration, the MIME and its alternative spelling) before
  /// giving up, and remembers what the renderer accepted.
  Future<String?> _sendStream(
    _DlnaRenderer renderer,
    MediaItem item,
    _DlnaStream stream,
    String? subtitleUrl,
    int gen, {
    bool viaStop = true,
  }) async {
    bool cancelled() => gen != _loadGeneration;

    // A file this phone serves itself: declare its exact byte size, as every
    // media server does and strict TV firmwares expect to find in `<res>`.
    if (item.isLocal) {
      final bytes = await LocalCastServer.instance.sizeForUrl(stream.url);
      if (bytes != null && bytes > 0) stream = stream.withSize(bytes);
      if (cancelled()) return null;
    }

    // Samsung reads CaptionInfo.sec from the media response headers — wire
    // the SRT to the local route (no-op for a Jellyfin URL).
    LocalCastServer.instance.attachCaption(stream.url, subtitleUrl);

    // [viaStop] false = direct switch: no Stop, no waiting for idle (see
    // [_RendererQuirks.stopBeforeSwitch] for why a TV's own receiver must
    // not be stopped between two items).
    if (viaStop) {
      try {
        await _soapCall(renderer.avTransport, 'Stop', const {'InstanceID': '0'},
            timeout: const Duration(seconds: 4));
      } catch (_) {
        // "Already stopped" faults are normal.
      }
      if (cancelled()) return null;
      // Stop is asynchronous on Kodi/AirScreen: SetAVTransportURI sent
      // before the old item has really stopped is rejected, or worse
      // accepted and then wiped by the old item's teardown.
      await _waitUntilIdle(renderer, gen);
    }
    if (cancelled()) return null;

    // PHASE 3: the cover for this item (null = fall back to the old form).
    final cover = await _coverFor(item);
    if (cancelled()) return null;

    // Metadata forms to offer, most complete first. Local files and music
    // keep the exact single form they always had (their MIME fallbacks are
    // separate attempts in [_buildAttempts]).
    final altMime =
        (item.isLocal || item.audioOnly || item.live) ? null : _altMime(stream.mime);
    final mimeKey = '${renderer.id}|${stream.mime}';
    final preferAlt = altMime != null && _altMimeKeys.contains(mimeKey);
    final primary = (preferAlt && altMime != null) ? stream.withMime(altMime) : stream;
    final secondary = altMime == null
        ? null
        : (preferAlt ? stream : stream.withMime(altMime));
    final withSubtitle = subtitleUrl != null &&
        subtitleUrl.isNotEmpty &&
        !_plainMetadataRenderers.contains(renderer.id);

    final variants = <({_DlnaStream stream, String? subtitle})>[];
    for (final s in <_DlnaStream>[primary, if (secondary != null) secondary]) {
      if (withSubtitle) variants.add((stream: s, subtitle: subtitleUrl));
      variants.add((stream: s, subtitle: null));
    }

    _DlnaSoapException? rejection;
    String? declared;
    var accepted = false;
    _pendingLearn = null;
    // PHASE 3: the cover declaration is the newest part of the metadata. If
    // a form is refused, the SAME form is retried once without it before any
    // simpler form is tried (so a cover can never cost a cast).
    var useCover = cover != null && !_coverRejectedRenderers.contains(renderer.id);
    var coverDropped = false;
    for (var i = 0; i < variants.length; i++) {
      if (cancelled()) return null;
      final v = variants[i];
      LocalCastServer.instance.attachCaption(v.stream.url, v.subtitle);
      final didl = _buildDidl(item, v.stream, v.subtitle,
          cover: useCover ? cover : null);
      // PHASE 0: exactly what the TV is told (token blanked, trimmed).
      _tlMediaUrls.add(v.stream.url);
      if (v.subtitle != null) _tlSubUrls.add(v.subtitle!);
      _tlAdd('SetAVTransportURI form ${i + 1}/${variants.length} '
          'mime=${v.stream.mime} subtitle=${v.subtitle != null}');
      debugPrint('DlnaTransport[${renderer.friendlyName}]: '
          'SetAVTransportURI form ${i + 1}/${variants.length} '
          '(${item.isLocal ? 'local' : 'server'} '
          '${item.audioOnly ? 'audio' : 'video'}) '
          'url=${_redact(v.stream.url)}');
      debugPrint('DlnaTransport[${renderer.friendlyName}]: '
          'metadata sent: ${_clip(_redact(didl), 1800)}');
      try {
        await _retrySoap(
          () => _soapCall(renderer.avTransport, 'SetAVTransportURI', {
            'InstanceID': '0',
            'CurrentURI': v.stream.url,
            'CurrentURIMetaData': didl,
          }),
          attempts: i == 0 ? 3 : 2,
          cancelled: cancelled,
        );
        if (cancelled()) return null;
        accepted = true;
        declared = v.subtitle;
        _tlAdd('SetAVTransportURI accepted (form ${i + 1})');
        if (coverDropped) {
          _coverRejectedRenderers.add(renderer.id);
          debugPrint('DlnaTransport[${renderer.friendlyName}]: accepted the '
              'item only without the cover declaration — no cover will be '
              'declared to this TV for the rest of this connection');
        }
        if (i > 0) {
          debugPrint('DlnaTransport[${renderer.friendlyName}]: accepted the '
              'item only with mime=${v.stream.mime} '
              'subtitle=${v.subtitle != null} — will remember once it plays');
          // Held back until the TV has really played the item (see
          // [_pendingLearn]).
          _pendingLearn = _LearnedForm(
            rendererId: renderer.id,
            altKey: v.stream.mime != primary.mime ? mimeKey : null,
            altWasPreferred: preferAlt,
            plain: withSubtitle && v.subtitle == null,
          );
        }
        break;
      } on _DlnaSoapException catch (e) {
        rejection = e;
        debugPrint('DlnaTransport[${renderer.friendlyName}]: '
            'SetAVTransportURI rejected (${e.describe()}) for '
            'mime=${v.stream.mime} subtitle=${v.subtitle != null}'
            '${i + 1 < variants.length ? ' — trying simpler metadata' : ''}');
        if (useCover) {
          useCover = false;
          coverDropped = true;
          _loadCover = null;
          debugPrint('DlnaTransport[${renderer.friendlyName}]: retrying the '
              'same form without the cover declaration');
          i--; // same form again, minus the cover
        }
      }
    }
    if (cancelled()) return null;
    if (!accepted) {
      throw rejection ?? StateError('The TV did not accept the item.');
    }

    await _sendPlay(renderer, gen);
    return declared;
  }

  /// PHASE 0: the per-load summary line — what was tried, what the TV did
  /// (the state timeline), and what it fetched from this phone.
  void _logLoadSummary(String result, MediaItem item, int gen) {
    final name = _renderer?.friendlyName ?? '?';
    debugPrint('DlnaTransport[$name]: LOAD SUMMARY #$gen "${item.title}" '
        '-> $result | sends=[${_tlSends.join(', ')}] | '
        'timeline: ${_tlEvents.join(' ; ')}');
    final media = _tlMediaUrls.toList();
    final subs = _tlSubUrls.toList();
    _logFetches('at load end', item, gen, media, subs);
    // Covers are often fetched a little after playback starts, and a TV
    // that was slow can still fetch after a reported failure: look again.
    unawaited(Future<void>.delayed(const Duration(seconds: 6), () {
      _logFetches('6 s later', item, gen, media, subs);
    }));
  }

  /// PHASE 0: what this phone's own server saw for the media, cover and
  /// subtitle of [item]. A URL that isn't one of this phone's routes (a
  /// Jellyfin URL) is fetched by the TV straight from the server, so the
  /// phone cannot tell whether the TV asked for it.
  void _logFetches(String when, MediaItem item, int gen, List<String> media,
      List<String> subs) {
    final name = _renderer?.friendlyName ?? '?';
    String seen(String? url) {
      if (url == null || url.isEmpty) return 'none declared';
      return LocalCastServer.instance.routeSummaryForUrl(url) ??
          'not served by this phone (TV fetches it from the server itself)';
    }

    final prepared = _loadCoverItemId == item.id ? _loadCover : null;
    final art = prepared?.url ?? _artworkUrl(item.image);
    // PHASE 3: the cover is served by this phone, so the log can say
    // outright whether the TV asked for it. If not, the metadata form for
    // this renderer is what to change (see [_CoverForm]).
    final artRequests =
        art == null ? null : LocalCastServer.instance.requestCountForUrl(art);
    final artVerdict = (prepared != null && artRequests == 0)
        ? ' — the TV has NOT fetched the cover'
        : '';
    debugPrint('DlnaTransport[$name]: FETCHES #$gen $when — '
        'media: ${media.isEmpty ? 'none sent' : media.map(seen).join(' | ')}; '
        'cover: ${seen(art)}$artVerdict; '
        'subtitle: ${subs.isEmpty ? 'none declared' : subs.map(seen).join(' | ')}');
  }

  /// PHASE 0: read-only questions put to the TV two seconds after a load
  /// started playing — which actions it currently allows, and whether it
  /// reports the track, duration and position this app relies on.
  Future<void> _logRendererSnapshot(_DlnaRenderer renderer, int gen) async {
    await Future<void>.delayed(const Duration(seconds: 2));
    if (gen != _loadGeneration || !identical(renderer, _renderer)) return;
    final name = renderer.friendlyName;
    try {
      final body = await _soapCall(renderer.avTransport,
          'GetCurrentTransportActions', const {'InstanceID': '0'},
          timeout: const Duration(seconds: 3));
      debugPrint('DlnaTransport[$name]: GetCurrentTransportActions -> '
          '${_clip(_tag(body, 'Actions') ?? body, 200)}');
    } catch (e) {
      debugPrint('DlnaTransport[$name]: GetCurrentTransportActions '
          'unavailable: $e');
    }
    if (gen != _loadGeneration) return;
    try {
      final body = await _soapCall(renderer.avTransport, 'GetPositionInfo',
          const {'InstanceID': '0'},
          timeout: const Duration(seconds: 3));
      debugPrint('DlnaTransport[$name]: GetPositionInfo -> '
          'TrackURI=${_redact(_clip(_tag(body, 'TrackURI') ?? '-', 160))} '
          'TrackDuration=${_tag(body, 'TrackDuration') ?? '-'} '
          'RelTime=${_tag(body, 'RelTime') ?? '-'} '
          'AbsTime=${_tag(body, 'AbsTime') ?? '-'}');
    } catch (e) {
      debugPrint('DlnaTransport[$name]: GetPositionInfo unavailable: $e');
    }
  }

  /// Applies what the last accepted send learned about the renderer, now
  /// that the TV has actually played the item (see [_pendingLearn]).
  void _commitLearnedForm() {
    final l = _pendingLearn;
    _pendingLearn = null;
    if (l == null) return;
    final key = l.altKey;
    if (key != null) {
      if (l.altWasPreferred) {
        _altMimeKeys.remove(key);
      } else {
        _altMimeKeys.add(key);
      }
    }
    if (l.plain) _plainMetadataRenderers.add(l.rendererId);
  }

  /// Play right after SetAVTransportURI.
  ///
  /// ROOT CAUSE (second half of the MagiConnect failure): a song is ready
  /// within a fraction of a second, a movie / episode is not — the TV spends
  /// seconds opening a large file. While it does, many renderers (Android TV
  /// ones especially) answer Play with a fault (701 "Transition not
  /// available") or have already started playing on their own when the URI
  /// was set. The old code gave up after four tries (~2 s) and failed the
  /// whole cast on that fault even though the TV was just opening the video.
  ///
  /// Now: a fault while the TV is TRANSITIONING (or says 701) is retried for
  /// up to 25 s; a fault while it is already PLAYING is a redundant Play and
  /// is ignored. Any other fault keeps the old four-try behaviour, and a TV
  /// that is still opening after the window is handed to [_waitForPlaying],
  /// which has the per-renderer patience to judge it.
  Future<void> _sendPlay(_DlnaRenderer renderer, int gen) async {
    final started = DateTime.now();
    const window = Duration(seconds: 25);
    var attempt = 0;
    for (;;) {
      if (gen != _loadGeneration) return;
      attempt++;
      try {
        await _soapCall(renderer.avTransport, 'Play',
            const {'InstanceID': '0', 'Speed': '1'});
        return;
      } on _DlnaSoapException catch (e) {
        String? state;
        try {
          state = await _transportState(renderer,
              timeout: const Duration(seconds: 3));
        } catch (_) {}
        if (gen != _loadGeneration) return;
        debugPrint('DlnaTransport[${renderer.friendlyName}]: Play rejected '
            '(${e.describe()}), transport state=$state');
        if (state == 'PLAYING') return;
        final elapsed = DateTime.now().difference(started);
        if (state == 'TRANSITIONING') {
          if (elapsed > window) return;
        } else if (e.code == 701) {
          if (elapsed > window) rethrow;
        } else if (attempt >= 4) {
          rethrow;
        }
        await Future<void>.delayed(const Duration(milliseconds: 700));
      }
    }
  }

  /// Waits (briefly) for the renderer to report that the previous item is
  /// really gone before a new URI is set.
  Future<void> _waitUntilIdle(_DlnaRenderer renderer, int gen) async {
    final deadline = DateTime.now().add(const Duration(milliseconds: 2500));
    while (DateTime.now().isBefore(deadline)) {
      if (gen != _loadGeneration) return;
      String? state;
      try {
        state = await _transportState(renderer,
            timeout: const Duration(seconds: 2));
      } catch (_) {
        break;
      }
      if (state == null || state == 'STOPPED' || state == 'NO_MEDIA_PRESENT') {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }

  Future<void> _retrySoap(
    Future<void> Function() call, {
    required int attempts,
    bool Function()? cancelled,
  }) async {
    for (var i = 0; i < attempts; i++) {
      if (cancelled != null && cancelled()) return;
      try {
        await call();
        return;
      } on _DlnaSoapException {
        if (i == attempts - 1) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 700));
      }
    }
  }

  /// Waits for the TV to actually start the item we just sent.
  ///
  /// ROOT CAUSE of the "works sometimes, fails on a fresh connection" /
  /// "Playback failed" behaviour on Kodi (and of AirScreen being given up
  /// on): this used to declare failure after only 7 s of STOPPED. Kodi (and
  /// most Android-TV receivers) keep reporting STOPPED / NO_MEDIA_PRESENT
  /// for the whole time they are opening a network stream — on a cold start
  /// that is routinely 8-20 s — and never pass through TRANSITIONING. The
  /// old code then fell through to the next attempt, whose Stop +
  /// SetAVTransportURI aborted the open that was still in progress, which
  /// is exactly what Kodi reports as "Playback failed". Warm second
  /// attempts opened fast enough to squeeze under the limit, hence the
  /// inconsistency.
  ///
  /// Now: PLAYING proves a start; TRANSITIONING proves the TV is working;
  /// STOPPED is tolerated for a per-renderer patience window (see
  /// [_RendererQuirks]); only a TV that stays STOPPED past that window, or
  /// reports ERROR_OCCURRED, is treated as having rejected the stream.
  Future<bool> _waitForPlaying(
    _DlnaRenderer renderer,
    int gen,
    Duration timeout, {
    String? expectedUrl,
    bool transcoded = false,
    bool directSwitch = false,
    Duration? preRel,
    bool switchedFromActive = false,
    bool isVideo = false,
  }) async {
    final quirks = renderer.quirks;
    final started = DateTime.now();
    final deadline = started.add(timeout);
    _waitStillOpening = false;
    // How long a PLAYING report that is still about the previous item is
    // tolerated before the check is given up on (renderers that rewrite
    // the URL they report). A direct switch (no Stop first) gets a little
    // longer — a TV opening a big file keeps the old item up until the new
    // one is ready — and then reports the switch as ignored instead of
    // quietly accepting the old item as the new one.
    // A movie is slower to open than a song and the TV keeps the old
    // picture up meanwhile, so a direct switch to a VIDEO gets longer.
    final staleDeadline = started.add(
        Duration(seconds: directSwitch ? (isVideo ? 10 : 7) : 4));
    // A server transcode needs several seconds before it sends a byte.
    final stoppedBeforeTransition = quirks.stoppedBeforeTransition +
        (transcoded ? const Duration(seconds: 10) : Duration.zero);

    DateTime? stoppedSince;
    DateTime? pausedSince;
    DateTime? errorSince;
    DateTime? unreadableSince;
    var lastReplayAt = started;
    var lastLostCheck = started;
    var lastDropCheck = started;
    var lostChecks = 0;
    var replays = 0;
    var sawTransition = false;
    var nudgedPaused = false;
    var everReadable = false;
    String? lastLogged;
    String? lastStateSeen;

    while (DateTime.now().isBefore(deadline)) {
      if (gen != _loadGeneration) return true; // superseded; caller re-checks
      String? state;
      String? status;
      try {
        final info = await _transportInfo(renderer);
        state = info.state;
        status = info.status;
      } catch (_) {
        state = null;
      }
      final now = DateTime.now();
      lastStateSeen = state;
      if (state != lastLogged) {
        lastLogged = state;
        debugPrint('DlnaTransport[${renderer.friendlyName}]: start-wait '
            'state=$state status=$status '
            '(+${now.difference(started).inMilliseconds} ms)');
        _tlAdd('state=$state status=$status');
      }

      if (state != null && state.isNotEmpty) everReadable = true;

      // A renderer whose GetTransportInfo never gives a readable state can't
      // be verified at all. Its SetAVTransportURI and Play were accepted (a
      // refusal would have thrown before this wait), so after a few seconds
      // of silence assume it started rather than failing a cast that is
      // probably playing.
      if (state == null || state.isEmpty) {
        unreadableSince ??= now;
        // A TV that answered a moment ago and has gone quiet right after a
        // mid-playback direct switch is restarting its receiver (see
        // [_waitDropped]) — not a TV that can never be verified. Keep
        // waiting for it to answer again instead of assuming success.
        final wentQuiet = directSwitch && switchedFromActive && everReadable;
        if (!wentQuiet &&
            now.difference(unreadableSince) > const Duration(seconds: 8)) {
          debugPrint('DlnaTransport[${renderer.friendlyName}]: transport '
              'state unreadable for 8 s after an accepted Play — assuming '
              'it started');
          return true;
        }
      } else {
        unreadableSince = null;
      }

      switch (state) {
        case 'PLAYING':
          if (expectedUrl != null) {
            var stillOld = !_trackUriUnreliable.contains(renderer.id) &&
                await _reportsOtherTrack(renderer, expectedUrl);
            // A TV that doesn't report which item it is playing: a direct
            // switch is still the old item if the position hasn't gone back
            // below where the old item was.
            if (!stillOld && directSwitch) {
              stillOld = await _stillAtPreviousPosition(renderer, preRel);
            }
            if (stillOld) {
              if (now.isBefore(staleDeadline)) break; // still the old item
              if (directSwitch) {
                debugPrint('DlnaTransport[${renderer.friendlyName}]: still '
                    'playing the previous item ${now.difference(started).inSeconds} s '
                    'after a direct switch');
                _waitStaleTrack = true;
                return false;
              }
              _trackUriUnreliable.add(renderer.id);
            }
          }
          return true;
        case 'TRANSITIONING':
          sawTransition = true;
          stoppedSince = null;
          pausedSince = null;
          errorSince = null;
          break;
        case 'PAUSED_PLAYBACK':
        case 'PAUSED_RECORDING':
          stoppedSince = null;
          pausedSince ??= now;
          // Some TVs park in PAUSED after SetURI — nudge them once, and if
          // they still sit there the item is loaded (the poller will show
          // it paused and the person can press play).
          if (!nudgedPaused) {
            nudgedPaused = true;
            try {
              await _soapCall(renderer.avTransport, 'Play',
                  const {'InstanceID': '0', 'Speed': '1'});
            } catch (_) {}
          } else if (now.difference(pausedSince) > const Duration(seconds: 6)) {
            return true;
          }
          break;
        case 'STOPPED':
        case 'NO_MEDIA_PRESENT':
          stoppedSince ??= now;
          pausedSince = null;
          if (status == 'ERROR_OCCURRED') {
            errorSince ??= now;
            if (now.difference(errorSince) > const Duration(seconds: 3)) {
              debugPrint('DlnaTransport[${renderer.friendlyName}]: '
                  'renderer reports ERROR_OCCURRED — giving up on this URL');
              _tlAdd('gave up: ERROR_OCCURRED');
              return false;
            }
          } else {
            errorSince = null;
          }
          // A mid-playback switch that leaves the TV STOPPED and never
          // TRANSITIONING: its receiver closed the player when the old item
          // was replaced and lost the new URI with it. Report it at once so
          // the caller re-sends to the idle TV (see [_waitDropped]).
          //
          // ROOT CAUSE (switching to another MOVIE while one is casting
          // never worked, songs did): a song is open within a second, so
          // 2.5 s of STOPPED after the switch really meant "dropped". A
          // movie keeps a receiver in STOPPED for far longer while it
          // opens the file, so the same rule fired mid-open, re-sent the
          // item (restarting the open) and gave up after two re-sends.
          // For a video, STOPPED alone is no longer proof: the TV must say
          // NO_MEDIA_PRESENT or an empty CurrentURI, or stay STOPPED for
          // 10 s. Songs keep the 2.5 s rule exactly as before.
          if (directSwitch &&
              switchedFromActive &&
              !sawTransition &&
              status != 'ERROR_OCCURRED') {
            final stoppedFor = now.difference(stoppedSince);
            var dropped = false;
            if (!isVideo) {
              dropped = stoppedFor >= const Duration(milliseconds: 2500);
            } else if (stoppedFor >= const Duration(seconds: 10)) {
              dropped = true;
            } else if (stoppedFor >= const Duration(milliseconds: 2500)) {
              if (state == 'NO_MEDIA_PRESENT') {
                dropped = true;
              } else if (now.difference(lastDropCheck) >=
                  const Duration(milliseconds: 1500)) {
                lastDropCheck = now;
                dropped = await _rendererLostUri(renderer);
              }
            }
            if (dropped) {
              debugPrint('DlnaTransport[${renderer.friendlyName}]: STOPPED '
                  '${stoppedFor.inMilliseconds} ms after a '
                  'mid-playback switch — the TV dropped it');
              _tlAdd('TV dropped the switch');
              _waitDropped = true;
              return false;
            }
          }
          // Receivers that accepted the URI but are waiting for a Play they
          // already ignored once (AirScreen-style): ask again, gently. Never
          // for Kodi — a second Play while it is still opening makes it
          // restart the open.
          // PHASE 1: ONE re-send, after 5 s (was two, after 3.5 s and 4.5 s).
          // A receiver that is still opening can restart the open on every
          // extra Play.
          if (quirks.replayWhileStopped &&
              !sawTransition &&
              replays < 1 &&
              now.difference(lastReplayAt) >= const Duration(seconds: 5)) {
            replays++;
            _replayedDuringLoad = true;
            lastReplayAt = now;
            debugPrint('DlnaTransport[${renderer.friendlyName}]: still '
                'STOPPED — re-sending Play ($replays)');
            _tlAdd('Play re-sent while STOPPED ($replays)');
            try {
              await _soapCall(renderer.avTransport, 'Play',
                  const {'InstanceID': '0', 'Speed': '1'});
            } catch (_) {}
          }
          // URI wiped by the previous item's teardown (never TRANSITIONING,
          // CurrentURI now empty): waiting longer can't help — report it so
          // the caller re-sends the item once instead of idling for the whole
          // patience window with the TV sitting on its home screen.
          if (!sawTransition &&
              now.difference(stoppedSince) > const Duration(seconds: 3) &&
              now.difference(lastLostCheck) >= const Duration(seconds: 2)) {
            lastLostCheck = now;
            if (await _rendererLostUri(renderer)) {
              lostChecks++;
              if (lostChecks >= 2) {
                debugPrint('DlnaTransport[${renderer.friendlyName}]: '
                    'renderer lost the URI it was sent — re-sending');
                _waitLostUri = true;
                return false;
              }
            } else {
              lostChecks = 0;
            }
          }
          final limit = sawTransition
              ? quirks.stoppedAfterTransition
              : stoppedBeforeTransition;
          if (now.difference(stoppedSince) > limit) {
            debugPrint('DlnaTransport[${renderer.friendlyName}]: STOPPED for '
                '${now.difference(stoppedSince).inSeconds} s without ever '
                'playing — giving up on this URL');
            _tlAdd('gave up: STOPPED ${now.difference(stoppedSince).inSeconds}s '
                'without playing');
            return false;
          }
          break;
        default:
          // Unreadable answer: the TV is busy, not necessarily failing.
          break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    // Out of time. If the TV's last word was TRANSITIONING it is still
    // opening the item (see [_waitStillOpening]).
    _waitStillOpening = lastStateSeen == 'TRANSITIONING';
    return false;
  }

  /// True only when the renderer positively reports an empty CurrentURI
  /// (GetMediaInfo). Unreadable / unimplemented answers are "can't tell".
  Future<bool> _rendererLostUri(_DlnaRenderer renderer) async {
    try {
      final body = await _soapCall(
        renderer.avTransport,
        'GetMediaInfo',
        const {'InstanceID': '0'},
        timeout: const Duration(seconds: 3),
      );
      if (RegExp(r'<(?:[\w.-]+:)?CurrentURI\s*/>', caseSensitive: false)
          .hasMatch(body)) {
        return true;
      }
      final uri = _tag(body, 'CurrentURI');
      return uri != null && uri.trim().isEmpty;
    } catch (_) {
      return false;
    }
  }

  /// Stops the renderer without letting any error escape. Used after a load
  /// has been reported as failed.
  Future<void> _bestEffortStop(_DlnaRenderer renderer) async {
    try {
      await _soapCall(renderer.avTransport, 'Stop', const {'InstanceID': '0'},
          timeout: const Duration(seconds: 3));
    } catch (_) {}
  }

  /// True only when the renderer positively reports a TrackURI that is a
  /// different resource from [expectedUrl] — i.e. its PLAYING state still
  /// belongs to the previous item. Unknown / empty / unimplemented answers
  /// are "can't tell", never "stale".
  Future<bool> _reportsOtherTrack(
      _DlnaRenderer renderer, String expectedUrl) async {
    try {
      final body = await _soapCall(
        renderer.avTransport,
        'GetPositionInfo',
        const {'InstanceID': '0'},
        timeout: const Duration(seconds: 3),
      );
      final reported = _tag(body, 'TrackURI')?.trim();
      if (reported == null ||
          reported.isEmpty ||
          reported.toUpperCase() == 'NOT_IMPLEMENTED') {
        return false;
      }
      return _uriKey(reported) != _uriKey(expectedUrl);
    } catch (_) {
      return false;
    }
  }

  /// RelTime as the TV reports it right now; null when it can't say.
  Future<Duration?> _readRelTime(_DlnaRenderer renderer) async {
    try {
      final body = await _soapCall(
        renderer.avTransport,
        'GetPositionInfo',
        const {'InstanceID': '0'},
        timeout: const Duration(seconds: 2),
      );
      return _parseHms(_tag(body, 'RelTime'));
    } catch (_) {
      return null;
    }
  }

  /// True only when the TV positively reports a position at or beyond
  /// [preRel] (where the previous item was when the switch was sent, and at
  /// least 8 s in). A freshly started item can't be there yet — its
  /// position restarts near zero — so the old item is still what plays.
  Future<bool> _stillAtPreviousPosition(
      _DlnaRenderer renderer, Duration? preRel) async {
    if (preRel == null || preRel < const Duration(seconds: 8)) return false;
    final rel = await _readRelTime(renderer);
    return rel != null && rel >= preRel;
  }

  String _uriKey(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null) return url.trim().toLowerCase();
    try {
      return Uri.decodeComponent(uri.path).toLowerCase();
    } catch (_) {
      return uri.path.toLowerCase();
    }
  }

  /// PHASE 1: the resume seek used to go out the moment PLAYING was first
  /// seen, and a receiver that mishandles an early Seek stops or restarts
  /// (which reads as a failed start). It now waits (at most 5 s) for the TV
  /// to show real progress — RelTime past 1 s, or 2 s of wall clock when it
  /// reports no RelTime — and is best-effort: nothing it hits fails the load.
  Future<void> _seekWhenProgressing(
    _DlnaRenderer renderer,
    int gen,
    Duration position,
  ) async {
    final began = DateTime.now();
    final deadline = began.add(const Duration(seconds: 5));
    while (DateTime.now().isBefore(deadline)) {
      if (gen != _loadGeneration) return;
      final rel = await _readRelTime(renderer);
      if (rel != null && rel >= const Duration(seconds: 1)) break;
      if (rel == null &&
          DateTime.now().difference(began) >= const Duration(seconds: 2)) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 700));
    }
    if (gen != _loadGeneration) return;
    try {
      await _seekWithRetry(renderer, gen, position);
    } catch (e) {
      debugPrint('DlnaTransport[${renderer.friendlyName}]: resume seek to '
          '${position.inSeconds}s failed (ignored): $e');
    }
  }

  /// PHASE 1: the url (one of [urls]) the TV positively reports it is
  /// PLAYING right now, else null. "Can't tell" (unreadable state, empty or
  /// unimplemented TrackURI) is null too — nothing is adopted on a guess.
  Future<String?> _urlsPlayingNow(
      _DlnaRenderer renderer, List<String> urls) async {
    try {
      final info =
          await _transportInfo(renderer, timeout: const Duration(seconds: 3));
      if (info.state != 'PLAYING') return null;
      final body = await _soapCall(
        renderer.avTransport,
        'GetPositionInfo',
        const {'InstanceID': '0'},
        timeout: const Duration(seconds: 3),
      );
      final reported = _tag(body, 'TrackURI')?.trim();
      if (reported == null ||
          reported.isEmpty ||
          reported.toUpperCase() == 'NOT_IMPLEMENTED') {
        return null;
      }
      final key = _uriKey(reported);
      for (final u in urls) {
        if (_uriKey(u) == key) return u;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// PHASE 1: the poller saw PLAYING while the session says the load failed
  /// (a slow TV that started after the phone gave up). Used to flip
  /// error -> playing on any PLAYING report, so the buttons came alive for
  /// whatever the TV happened to be playing. Now it is only adopted when the
  /// TV reports one of the URLs this very load tried; anything else leaves
  /// the failure standing (and is never stopped — it may be the TV's own use).
  Future<void> _reconcileAfterFailure(
      CastSession session, _DlnaRenderer renderer) async {
    final tried = _failedAttempts;
    if (tried.isEmpty) return;
    final matched =
        await _urlsPlayingNow(renderer, tried.map((a) => a.url).toList());
    if (matched == null || _loading || !identical(session, _session)) return;
    if (session.playbackState.value != CastPlaybackState.error) return;
    final stream = tried.firstWhere((a) => a.url == matched);
    debugPrint('DlnaTransport[${renderer.friendlyName}]: the TV started '
        '"${session.currentItem.value?.title}" after the phone had reported '
        'a failure — adopting it (${stream.label})');
    _current = stream;
    _streamOffset = stream.offset;
    _confirmedPlaying = true;
    _lastPlayingPollAt = DateTime.now();
    _failedAttempts = const [];
    session.lastError.value = null;
    session.idleReason.value = null;
    session.playbackState.value = CastPlaybackState.playing;
  }

  Future<void> _seekWithRetry(
    _DlnaRenderer renderer,
    int gen,
    Duration position,
  ) async {
    for (var i = 0; i < 4; i++) {
      if (gen != _loadGeneration) return;
      try {
        await _seekRenderer(renderer, position);
        return;
      } catch (e) {
        debugPrint('DlnaTransport: seek to $position failed ($e), retrying');
        await Future<void>.delayed(const Duration(milliseconds: 800));
      }
    }
  }

  // ── what to send ──────────────────────────────────────────────────────

  List<_DlnaStream> _buildAttempts(
    MediaItem item, {
    required Duration startAt,
    required bool preferTranscode,
  }) {
    final raw = item.raw;

    // PHASE 5 (test seam): one fixed URL for every item.
    final override = debugStreamUrlOverride;
    if (override != null) {
      return [
        _DlnaStream(
          url: override,
          mime: 'audio/mpeg',
          label: 'test override',
          durationHint: item.runtime,
        ),
      ];
    }

    // Local file served by this phone's LocalCastServer.
    if (item.isLocal) {
      // This TV already proved it needs the MPEG-TS remux for this file
      // (see [_wantsLocalTsFallback]): go straight to it.
      final knownTs = _localTsFallbackUrls[item.id];
      final knownTsStream = (knownTs != null &&
              raw?['CastLocalRemuxedTs'] != true &&
              LocalCastServer.instance.ownsUrl(knownTs))
          ? _DlnaStream(
              url: knownTs,
              mime: 'video/mp2t',
              label: 'local (on-device TS remux)',
              durationHint: item.runtime,
            )
          : null;
      final url = item.castStreamUrl;
      if (url == null) return [if (knownTsStream != null) knownTsStream];
      final remuxed = raw?['CastLocalRemuxedTs'] == true;
      final mime =
          remuxed ? 'video/mp2t' : resolveLocalDlnaFormat(item).contentType;
      // Some TV firmwares only accept their own spelling of the MIME type
      // (error 714 "Illegal MIME-type", or an instant STOPPED). The same URL
      // is retried once with the common alternative before giving up.
      final alt = _altMime(mime);
      return [
        // Known-good form first, the original file behind it as a net.
        if (knownTsStream != null) knownTsStream,
        _DlnaStream(
          url: url,
          mime: mime,
          label: 'local',
          durationHint: item.runtime,
        ),
        if (alt != null)
          _DlnaStream(
            url: url,
            mime: alt,
            label: 'local ($alt)',
            durationHint: item.runtime,
          ),
      ];
    }

    // Live TV: whatever Jellyfin gave us, not seekable.
    if (item.live) {
      final url = item.castStreamUrl;
      if (url == null) return const [];
      final isHls = url.toLowerCase().contains('.m3u8');
      return [
        _DlnaStream(
          url: url,
          mime: isHls ? 'application/vnd.apple.mpegurl' : 'video/mp2t',
          label: 'live',
          seekable: false,
        ),
      ];
    }

    // Jellyfin music.
    if (item.audioOnly) {
      final direct = _DlnaStream(
        url: _withContainerExtension(
          MediaService.getAudioDownloadUrl(item.id),
          _extensionFor(item, audio: true),
        ),
        mime: _audioMime(item),
        label: 'direct audio',
        durationHint: item.runtime,
      );
      final transcode = _DlnaStream(
        url: MediaService.getAudioMp3TranscodeUrl(
          item.id,
          maxBitrateKbps: 320,
          startTimeTicks: startAt > Duration.zero ? _ticks(startAt) : null,
        ),
        mime: 'audio/mpeg',
        label: 'mp3 transcode',
        seekable: false,
        transcoded: true,
        offset: startAt,
      );
      return preferTranscode ? [transcode] : [direct, transcode];
    }

    // Jellyfin movie / episode.
    final directUrl = item.castStreamUrl;
    if (directUrl == null) return const [];
    final mediaSourceId = _mediaSourceId(item);
    final forcedAudio = raw?['CastAudioStreamOverride'];
    final audioIndex = forcedAudio is int
        ? forcedAudio
        : _defaultStream(item, 'Audio')?['Index'] as int?;

    _DlnaStream transcode() {
      final videoCodec = _codecOf(_defaultStream(item, 'Video'));
      final audioCodec = _codecOf(_streamByIndex(item, 'Audio', audioIndex) ??
          _defaultStream(item, 'Audio'));
      final copyVideo = videoCodec == 'h264';
      final copyAudio = audioCodec != null && _tsCopyableAudio.contains(audioCodec);
      return _DlnaStream(
        url: MediaService.getVideoDlnaStreamUrl(
          item.id,
          mediaSourceId: mediaSourceId,
          audioStreamIndex: audioIndex,
          allowVideoStreamCopy: copyVideo,
          allowAudioStreamCopy: copyAudio,
          startTimeTicks: _ticks(startAt),
        ),
        mime: 'video/mp2t',
        label: 'server transcode',
        seekable: false,
        transcoded: true,
        offset: startAt,
      );
    }

    // A chosen audio track can only be honoured by a stream that carries
    // just that track, so there's no point trying the direct file first.
    if (forcedAudio is int || preferTranscode) {
      return [transcode()];
    }
    return [
      _DlnaStream(
        url: _withContainerExtension(
          directUrl,
          _extensionFor(item, audio: false),
        ),
        mime: _videoMime(item),
        label: 'direct',
        durationHint: item.runtime,
      ),
      transcode(),
    ];
  }

  // ── subtitles ─────────────────────────────────────────────────────────

  /// The subtitle to declare to the TV, following the same hint protocol
  /// GoogleCastTransport uses (`CastActiveSubtitleId` wins; otherwise the
  /// file's own default-flagged external subtitle, unless the user switched
  /// subtitles off).
  ({int id, String url, String name})? _activeSubtitle(MediaItem item) {
    final raw = item.raw;
    final candidates = _subtitleCandidates(item);
    if (candidates.isEmpty) return null;

    final override = raw?['CastActiveSubtitleId'];
    if (override is int) {
      for (final c in candidates) {
        if (c.id == override) return c;
      }
    }
    if (raw?['CastSubtitlesOff'] == true) return null;

    final mediaSourceId = _mediaSourceId(item);
    final jellyfin = MediaStreamParser.subtitles(
      item.mediaStreams,
      itemId: item.id,
      mediaSourceId: mediaSourceId,
    );
    for (final sub in jellyfin) {
      if (!sub.isDefault) continue;
      for (final c in candidates) {
        if (c.id == sub.index) return c;
      }
    }
    return null;
  }

  List<({int id, String url, String name})> _subtitleCandidates(
    MediaItem item,
  ) {
    final out = <({int id, String url, String name})>[];

    final mediaSourceId = _mediaSourceId(item);
    for (final sub in MediaStreamParser.subtitles(
      item.mediaStreams,
      itemId: item.id,
      mediaSourceId: mediaSourceId,
    )) {
      final url = sub.externalUrl;
      if (url == null || url.isEmpty) continue;
      out.add((id: sub.index, url: url, name: sub.displayTitle));
    }

    final sidecar = item.raw?['CastSidecarSubtitleUrl'];
    if (sidecar is String && sidecar.isNotEmpty) {
      out.add((
        id: kLocalCastSubtitleTrackId,
        url: sidecar,
        name: (item.raw?['CastSidecarSubtitleName'] as String?) ?? 'Subtitle',
      ));
    }

    final extra = item.raw?['CastLocalSubtitles'];
    if (extra is List) {
      for (final entry in extra) {
        if (entry is! Map) continue;
        final id = entry['id'];
        final url = entry['url'];
        if (id is! int || url is! String || url.isEmpty) continue;
        out.add((
          id: id,
          url: url,
          name: (entry['name'] as String?) ?? 'Subtitle',
        ));
      }
    }
    return out;
  }

  /// DLNA TVs want SubRip. Jellyfin serves `.../Stream.srt` for any text
  /// subtitle, and LocalCastServer answers `.../sub.srt` for the same
  /// token it registered as `.../sub.vtt`.
  /// Turns the subtitle the coordinator/Jellyfin gave us into the exact SRT
  /// URL the TV will fetch.
  ///
  /// * Untouched style (white, regular): hand the TV the plain `.srt` URL
  ///   (Jellyfin's own, or this phone's token) — nothing to rewrite.
  /// * Custom text colour / bold: the phone fetches the text (its own route,
  ///   including any time-shifted "subtitle delay" variant, or Jellyfin's
  ///   `Stream.srt`), wraps every cue line in `<font color>` / `<b>` tags —
  ///   the only styling the SRT format can carry to a TV — and serves that.
  /// * Any failure falls back to the plain URL: a subtitle must never be
  ///   the reason a cast fails.
  Future<String?> _resolveSubtitleUrl(String rawUrl, _SubtitleTagStyle style) async {
    final plain = _toSrtUrl(rawUrl);
    final server = LocalCastServer.instance;
    // A subtitle that lives on the media server is fetched by the phone
    // FIRST (bounded). Jellyfin builds a text subtitle on demand — for an
    // embedded track it may have to read through the whole video file — and
    // a TV that is handed such a URL stalls its playback start until it
    // arrives (or fails). Fetching it here both proves it is usable and
    // warms the server's cache, so the TV's own fetch is instant. A
    // subtitle that can't be fetched is left out (null) rather than being
    // declared to a TV that would then fail to start.
    if (!server.ownsUrl(rawUrl)) {
      String? fetched;
      try {
        fetched = await _fetchSubtitleText(plain)
            .timeout(const Duration(seconds: 12));
      } catch (_) {
        fetched = null;
      }
      if (fetched == null || !fetched.contains('-->')) return null;
    }
    if (style.isPlain) return plain;
    try {
      String? text;
      if (server.ownsUrl(rawUrl)) {
        final stored = server.textForUrl(rawUrl);
        if (stored != null) {
          text = stored.trimLeft().toUpperCase().startsWith('WEBVTT')
              ? LocalCastServer.vttToSrt(stored)
              : stored;
        }
      } else {
        text = await _fetchSubtitleText(plain);
      }
      if (text == null || !text.contains('-->')) return plain;
      final uri = await server.registerSrtText(content: _applySrtStyle(text, style));
      return uri?.toString() ?? plain;
    } catch (e) {
      debugPrint('DlnaTransport: styling subtitle failed, using plain: $e');
      return plain;
    }
  }

  Future<String?> _fetchSubtitleText(String url) async {
    final cached = _subtitleTextCache[url];
    if (cached != null) return cached;
    try {
      var text = await _httpGet(Uri.parse(url), const Duration(seconds: 8));
      if (text.trimLeft().toUpperCase().startsWith('WEBVTT')) {
        text = LocalCastServer.vttToSrt(text);
      }
      if (_subtitleTextCache.length >= 8) {
        _subtitleTextCache.remove(_subtitleTextCache.keys.first);
      }
      _subtitleTextCache[url] = text;
      return text;
    } catch (e) {
      debugPrint('DlnaTransport: fetching subtitle failed: $e');
      return null;
    }
  }

  _SubtitleTagStyle _tagStyle(SubtitleAppearance a) {
    final rgb = a.textColor.toARGB32() & 0xFFFFFF;
    return _SubtitleTagStyle(rgb == 0xFFFFFF ? null : rgb, a.bold);
  }

  String _applySrtStyle(String srt, _SubtitleTagStyle style) {
    if (style.isPlain) return srt;
    final lines =
        srt.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');
    final out = <String>[];
    var inCue = false;
    for (final line in lines) {
      if (line.trim().isEmpty) {
        inCue = false;
        out.add(line);
        continue;
      }
      if (!inCue) {
        if (line.contains('-->')) inCue = true; // timing line
        out.add(line); // cue index / timing line pass through untouched
        continue;
      }
      var t = line;
      if (style.bold) t = '<b>$t</b>';
      final rgb = style.colorRgb;
      if (rgb != null) {
        t = '<font color="#${rgb.toRadixString(16).padLeft(6, '0').toUpperCase()}">$t</font>';
      }
      out.add(t);
    }
    return out.join('\n');
  }

  /// LIVE SUBTITLE STYLE (Settings > Subtitle Style) for a DLNA TV.
  ///
  /// DLNA has no styling command: the TV draws subtitles itself with its own
  /// settings. What *can* travel to it is inline SubRip markup, so text
  /// colour and bold are applied by re-serving the subtitle with `<font>` /
  /// `<b>` tags and reloading the item at the current position (debounced,
  /// and only when colour/bold actually changed — size, background, edge,
  /// font and height are TV-side settings DLNA cannot reach).
  /// CastSubtitleStyleSync pushes the style repeatedly (after every load,
  /// track change, …); the style key makes those pushes no-ops.
  @override
  Future<void> applySubtitleStyle(
    CastSession session,
    SubtitleAppearance appearance,
  ) async {
    _appearance = appearance;
    if (!identical(session, _session)) return;
    final key = _tagStyle(appearance).key;
    if (key == _loadedStyleKey) {
      _styleReloadTimer?.cancel();
      return;
    }
    final item = session.currentItem.value;
    if (item == null || item.audioOnly || item.live) {
      _loadedStyleKey = key;
      return;
    }
    if (_activeSubtitle(item) == null) {
      // No subtitle on screen — the next one selected is built with the
      // new style, nothing to reload now.
      _loadedStyleKey = key;
      return;
    }
    _styleReloadTimer?.cancel();
    _styleReloadTimer = Timer(const Duration(milliseconds: 1500), () {
      unawaited(_reloadForStyle(session));
    });
  }

  Future<void> _reloadForStyle(CastSession session) async {
    if (!identical(session, _session)) return;
    if (_loading) {
      _styleReloadTimer = Timer(const Duration(seconds: 1), () {
        unawaited(_reloadForStyle(session));
      });
      return;
    }
    final item = session.currentItem.value;
    if (item == null) return;
    final state = session.playbackState.value;
    final wasPaused = state == CastPlaybackState.paused;
    if (state != CastPlaybackState.playing &&
        state != CastPlaybackState.buffering &&
        !wasPaused) {
      return; // ended/stopped/idle — the next load picks the style up
    }
    if (_tagStyle(_appearance).key == _loadedStyleKey) return;
    try {
      await _loadItem(
        session,
        item,
        startAt: session.position.value,
        preferTranscode: _current?.transcoded == true,
        startPaused: wasPaused,
      );
    } catch (e) {
      debugPrint('DlnaTransport: restyle reload failed: $e');
    }
  }

  String _toSrtUrl(String url) =>
      url.replaceFirst(RegExp(r'\.vtt(?=\?|$)', caseSensitive: false), '.srt');

  // ── PHASE 3: the cover for the TV ─────────────────────────────────────

  /// PHASE 4: gets [item]'s cover ready (the result is cached by
  /// [CastArtwork]) while the current item plays, so the switch to it does
  /// not wait for the picture. Never throws, never touches the session.
  Future<void> prefetchCover(MediaItem item) async {
    if (_renderer == null || _loading || debugStreamUrlOverride != null) return;
    try {
      await CastArtwork.instance.prepare(item);
    } catch (_) {}
  }

  /// Starts preparing this item's cover (a small JPEG served by this phone).
  /// Runs alongside the Stop / wait-for-idle part of the load; bounded so a
  /// slow image server can never hold a load back for long.
  void _startCoverPrep(MediaItem item) {
    _loadCover = null;
    _loadCoverItemId = item.id;
    if (debugStreamUrlOverride != null) {
      _loadCoverFuture = null; // tests: no cover, no network, no FFmpeg
      return;
    }
    _loadCoverFuture = CastArtwork.instance
        .prepare(item)
        .timeout(const Duration(seconds: 8), onTimeout: () {
      debugPrint('DlnaTransport: cover for "${item.title}" was not ready '
          'in time — the old cover form is used');
      return null;
    });
  }

  /// The cover prepared for [item]'s load, or null (no picture, not ready,
  /// or a different item's load) — the caller then uses the old form.
  Future<CastCover?> _coverFor(MediaItem item) async {
    if (_loadCoverItemId != item.id) return null;
    final pending = _loadCoverFuture;
    if (pending == null) return null;
    try {
      _loadCover = await pending;
    } catch (_) {
      _loadCover = null;
    }
    return _loadCover;
  }

  // ── DIDL-Lite metadata ────────────────────────────────────────────────

  String _buildDidl(MediaItem item, _DlnaStream stream, String? subtitleUrl,
      {CastCover? cover}) {
    final isAudio = item.audioOnly;
    final upnpClass =
        isAudio ? 'object.item.audioItem.musicTrack' : 'object.item.videoItem';
    final features = stream.seekable
        ? 'DLNA.ORG_OP=01;DLNA.ORG_CI=0;$_dlnaFlags'
        : 'DLNA.ORG_OP=00;DLNA.ORG_CI=${stream.transcoded ? 1 : 0};$_dlnaFlags';

    final b = StringBuffer()
      ..write('<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" '
          'xmlns:dc="http://purl.org/dc/elements/1.1/" '
          'xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" '
          'xmlns:dlna="urn:schemas-dlna-org:metadata-1-0/" '
          'xmlns:sec="http://www.sec.co.kr/" '
          'xmlns:pv="http://www.pv.com/pvns/">')
      ..write('<item id="0" parentID="-1" restricted="1">')
      ..write('<dc:title>${_xmlEscape(item.title)}</dc:title>')
      ..write('<upnp:class>$upnpClass</upnp:class>');

    if (isAudio && item.artistName.isNotEmpty) {
      // dc:creator as well as upnp:artist: simple renderers (AirScreen's
      // audio screen among them) read the artist from dc:creator.
      b
        ..write('<dc:creator>${_xmlEscape(item.artistName)}</dc:creator>')
        ..write('<upnp:artist>${_xmlEscape(item.artistName)}</upnp:artist>');
    }
    if (isAudio) {
      final album = item.raw?['Album']?.toString().trim() ?? '';
      if (album.isNotEmpty) {
        b.write('<upnp:album>${_xmlEscape(album)}</upnp:album>');
      }
    }
    // PHASE 3 (F1.1): the cover declared the way UPnP controllers do — a
    // typed albumArtURI (dlna:profileID) AND an image <res> — and pointing
    // at a small JPEG this phone serves itself. Which parts a renderer gets
    // is one setting per renderer profile ([_RendererQuirks.coverForm]).
    // Without a prepared cover the previous form is kept as it was.
    final coverForm = _renderer?.quirks.coverForm ?? _CoverForm.full;
    if (cover != null) {
      final url = _xmlEscape(cover.url);
      if (coverForm == _CoverForm.plain) {
        b.write('<upnp:albumArtURI>$url</upnp:albumArtURI>');
      } else {
        b.write('<upnp:albumArtURI dlna:profileID="JPEG_TN">$url'
            '</upnp:albumArtURI>');
      }
    } else {
      final art = _artworkUrl(item.image);
      if (art != null) {
        b.write('<upnp:albumArtURI>${_xmlEscape(art)}</upnp:albumArtURI>');
      }
    }

    final duration = stream.durationHint;
    final durationAttr = (duration != null && duration > Duration.zero)
        ? ' duration="${_formatHms(duration)}.000"'
        : '';
    final sizeBytes = stream.sizeBytes;
    final sizeAttr =
        (sizeBytes != null && sizeBytes > 0) ? ' size="$sizeBytes"' : '';
    b.write('<res protocolInfo="http-get:*:${stream.mime}:$features"'
        '$sizeAttr$durationAttr>${_xmlEscape(stream.url)}</res>');

    // The picture as an image resource, AFTER the media <res> (a renderer
    // that takes the first <res> as the media must still find the media).
    if (cover != null && coverForm == _CoverForm.full) {
      final resolution =
          cover.resolution == null ? '' : ' resolution="${cover.resolution}"';
      b.write('<res protocolInfo="http-get:*:image/jpeg:'
          'DLNA.ORG_PN=${cover.dlnaProfile};DLNA.ORG_OP=01;DLNA.ORG_CI=1;'
          'DLNA.ORG_FLAGS=00f00000000000000000000000000000" '
          'size="${cover.bytes}"$resolution>${_xmlEscape(cover.url)}</res>');
    }

    if (!isAudio && subtitleUrl != null && subtitleUrl.isNotEmpty) {
      final u = _xmlEscape(subtitleUrl);
      // Standard additional <res>, Samsung (Tizen) and LG/PacketVideo forms.
      b
        ..write('<res protocolInfo="http-get:*:text/srt:*">$u</res>')
        ..write('<sec:CaptionInfoEx sec:type="srt">$u</sec:CaptionInfoEx>')
        ..write('<sec:CaptionInfo sec:type="srt">$u</sec:CaptionInfo>')
        ..write('<pv:subtitleFileUri>$u</pv:subtitleFileUri>')
        ..write('<pv:subtitleFileType>srt</pv:subtitleFileType>');
    }

    b
      ..write('</item>')
      ..write('</DIDL-Lite>');
    return b.toString();
  }

  /// PHASE 3: now only the FALLBACK cover URL, used when the phone could not
  /// prepare its own JPEG (see [CastArtwork]).
  ///
  /// The cover URL to declare. ROOT CAUSE (no artwork on AirScreen): the
  /// Jellyfin image URL named no format, and Jellyfin then answers with the
  /// file's own format or WebP depending on the request's Accept header — a
  /// simple renderer's image loader often can't decode that and silently
  /// shows nothing (Kodi and the TV receivers happen to cope). Asking for a
  /// JPEG explicitly gives every renderer something it can show. Anything
  /// that isn't a Jellyfin image URL (a cover served by this phone) is left
  /// exactly as it was.
  String? _artworkUrl(String? art) {
    if (art == null || !art.startsWith('http')) return null;
    final uri = Uri.tryParse(art);
    if (uri == null || !uri.path.contains('/Images/')) return art;
    final params = Map<String, String>.of(uri.queryParameters);
    final hasFormat = params.keys.any((k) => k.toLowerCase() == 'format');
    if (hasFormat) return art;
    params['format'] = 'Jpg';
    return uri.replace(queryParameters: params).toString();
  }

  // ── session bookkeeping when an item loads ────────────────────────────

  void _seedCapabilityAndTracks(CastSession session, MediaItem item) {
    final audioCount = _streams(item).where((s) => s['Type'] == 'Audio').length;
    session.capabilityNotifier.value = session.capability.copyWith(
      seek: !item.live && !(item.isLocal && (_renderer?.cannotSeek ?? false)),
      subtitleTrackSelection: !item.audioOnly && !item.live,
      audioTrackSelection:
          !item.isLocal && !item.live && !item.audioOnly && audioCount > 1,
    );

    // Same checkmark seeding GoogleCastTransport does, so the Audio /
    // Subtitles sheets tick the right row straight after the load.
    if (item.isLocal || item.live || item.audioOnly) {
      session.activeAudioTrackId.value = null;
    } else {
      final forced = item.raw?['CastAudioStreamOverride'];
      session.activeAudioTrackId.value = forced is int
          ? forced
          : _defaultStream(item, 'Audio')?['Index'] as int?;
    }
    session.activeSubtitleTrackId.value =
        item.audioOnly ? null : (_activeSubtitle(item)?.id ?? -1);
  }

  // ═══════════════════════════════════════════════════════════════════════
  // Transport commands
  // ═══════════════════════════════════════════════════════════════════════

  @override
  Future<void> play(CastSession session) =>
      _commandPlayback(session, wantPlaying: true);

  @override
  Future<void> pause(CastSession session) =>
      _commandPlayback(session, wantPlaying: false);

  /// PHASE 4: Play / Pause, remembered until the TV confirms it (see
  /// [_wantedPlayback]).
  Future<void> _commandPlayback(
    CastSession session, {
    required bool wantPlaying,
  }) async {
    final renderer = _requireRenderer(session);
    final now = DateTime.now();
    _wantedPlayback =
        wantPlaying ? CastPlaybackState.playing : CastPlaybackState.paused;
    _wantedPlaybackSince = now;
    _wantedPlaybackUntil = now.add(_commandConfirmWindow);
    _wantedRetried = false;
    _holdPollState();
    session.holdPlaybackCommand(_commandConfirmWindow);
    try {
      await _sendPlaybackCommand(renderer, wantPlaying);
    } catch (_) {
      // The TV refused (or never heard it): the button must go back to what
      // the TV really reports, not stay on a state nothing will confirm.
      _wantedPlayback = null;
      _holdPollStateUntil = DateTime.fromMillisecondsSinceEpoch(0);
      session.settlePlaybackCommand();
      unawaited(_poll(session));
      rethrow;
    }
  }

  Future<void> _sendPlaybackCommand(
      _DlnaRenderer renderer, bool wantPlaying) async {
    if (wantPlaying) {
      await _soapCall(renderer.avTransport, 'Play',
          const {'InstanceID': '0', 'Speed': '1'});
    } else {
      await _soapCall(
          renderer.avTransport, 'Pause', const {'InstanceID': '0'});
    }
  }

  /// The state the person asked for, while it is still waiting for the TV
  /// to report it; null once confirmed, given up on, or never asked.
  CastPlaybackState? _pendingWanted(DateTime now, CastSession session) {
    final wanted = _wantedPlayback;
    if (wanted == null) return null;
    if (now.isAfter(_wantedPlaybackUntil)) {
      debugPrint('DlnaTransport: the TV did not ${wanted.name == 'paused' ? 'pause' : 'resume'} '
          'within ${_commandConfirmWindow.inSeconds} s — showing what it reports');
      _wantedPlayback = null;
      session.settlePlaybackCommand();
      return null;
    }
    return wanted;
  }

  void _confirmWanted(CastSession session) {
    if (_wantedPlayback == null) return;
    _wantedPlayback = null;
    session.settlePlaybackCommand();
  }

  /// The TV still reports the opposite of what was asked. Asks once more
  /// after [_commandRetryAfter]; the button keeps showing the tapped state
  /// meanwhile.
  void _retryWantedOnce(CastSession session, _DlnaRenderer renderer, DateTime now) {
    final wanted = _wantedPlayback;
    if (wanted == null ||
        _wantedRetried ||
        now.difference(_wantedPlaybackSince) < _commandRetryAfter) {
      return;
    }
    _wantedRetried = true;
    final wantPlaying = wanted == CastPlaybackState.playing;
    debugPrint('DlnaTransport[${renderer.friendlyName}]: the TV has not '
        '${wantPlaying ? 'resumed' : 'paused'} yet — asking once more');
    unawaited(_sendPlaybackCommand(renderer, wantPlaying)
        .then((_) {}, onError: (_) {}));
  }

  @override
  Future<void> stop(CastSession session) async {
    final renderer = _requireRenderer(session);
    _commandedStop = true;
    _wantedPlayback = null;
    session.settlePlaybackCommand();
    _holdPollState();
    session.idleReason.value = CastIdleReason.cancelled;
    try {
      await _soapCall(renderer.avTransport, 'Stop', const {'InstanceID': '0'});
    } finally {
      session.playbackState.value = CastPlaybackState.stopped;
    }
  }

  @override
  Future<void> seek(CastSession session, Duration position) async {
    final renderer = _requireRenderer(session);
    final item = session.currentItem.value;
    final stream = _current;

    // A progressive transcode has no byte index — the only way to "seek"
    // is to restart the stream at the new position.
    if (item != null && stream != null && stream.transcoded) {
      await _reloadAt(session, item, position);
      return;
    }

    // PHASE 4: a TV already shown (or declared) unable to seek. A server
    // item is restarted at the position; a file from the phone can't be, so
    // the control is switched off and the person is told plainly.
    if (renderer.cannotSeek) {
      if (item != null && stream != null && _canRestartAt(item)) {
        debugPrint('DlnaTransport[${renderer.friendlyName}]: this TV does '
            'not seek — restarting the stream at ${_formatHms(position)}');
        await _reloadAt(session, item, position);
        return;
      }
      _disableSeek(session, item);
      throw UnsupportedCastCommand('seek', kind);
    }

    _holdPollState();
    // A seek is deliberate progress: from here on the renderer's RelTime is
    // trusted and a stop at the new position is a real end, not a glitch.
    _trustRel = true;
    _confirmedPlaying = true;
    final before = _effectivePosition;
    _wallBase = position;
    _playedFor = Duration.zero;
    _lastPolledPosition = _streamOffset + position;
    final serial = ++_seekSerial;
    try {
      await _seekRenderer(renderer, position);
    } on _DlnaSoapException catch (e) {
      // ROOT CAUSE (the seek bar does nothing on AirScreen-style
      // receivers): a minimal renderer may not implement the AVTransport
      // `Seek` action at all (UPnP 401 "Invalid Action", 602 "Optional
      // action not implemented", 710 "Seek mode not supported"), and the
      // fault used to be the end of it. The same item can still be started
      // at the chosen position — the server transcode takes a start offset
      // — which is exactly what a seek on a transcoded stream already does.
      // Only when the renderer says the action is unsupported, so a
      // transient 701 on a TV that does seek is never turned into a restart.
      final unsupported = e.code == 401 ||
          e.code == 602 ||
          e.code == 710 ||
          (e.code == null &&
              (e.httpStatus == 404 ||
                  e.httpStatus == 405 ||
                  e.httpStatus == 501));
      if (!unsupported) rethrow;
      renderer.seekBroken = true;
      if (item != null && stream != null && _canRestartAt(item)) {
        debugPrint('DlnaTransport[${renderer.friendlyName}]: Seek not '
            'supported (${e.describe()}) — restarting the stream at '
            '${_formatHms(position)}');
        await _reloadAt(session, item, position);
        return;
      }
      session.cancelPendingSeek();
      _disableSeek(session, item);
      throw UnsupportedCastCommand('seek', kind);
    }

    // The TV accepted the command. Whether it MOVED is checked in the
    // background so the control stays instant; see [_verifySeek].
    unawaited(_verifySeek(session, renderer, position, before, serial));
  }

  /// A server item (not a file from the phone, not live) can be restarted at
  /// a position by asking the server for a stream that begins there.
  bool _canRestartAt(MediaItem item) => !item.isLocal && !item.live;

  Future<void> _reloadAt(
      CastSession session, MediaItem item, Duration position) {
    return _loadItem(
      session,
      item,
      startAt: position,
      preferTranscode: true,
      isSeekReload: true,
      startPaused: session.playbackState.value == CastPlaybackState.paused,
    );
  }

  /// PHASE 4: no seeking on this TV for a file the phone serves.
  void _disableSeek(CastSession session, MediaItem? item) {
    if (!identical(session, _session)) return;
    if (session.capability.seek) {
      session.capabilityNotifier.value =
          session.capability.copyWith(seek: false);
    }
    debugPrint('DlnaTransport: this TV cannot seek'
        '${item == null ? '' : ' in "${item.title}"'} — the seek '
        'controls are switched off');
  }

  /// PHASE 4: after the TV ACCEPTED a Seek, read its position a few times.
  /// Only a TV that keeps reporting the OLD position (never the target) is
  /// treated as not having seeked — anything unclear (no RelTime, a
  /// position somewhere else entirely, a newer seek) counts as success, so a
  /// slow receiver is never restarted for nothing. On a verified miss the
  /// other seek unit is tried once, then a server item is restarted at the
  /// position and the TV is remembered as unable to seek.
  Future<void> _verifySeek(
    CastSession session,
    _DlnaRenderer renderer,
    Duration target,
    Duration before,
    int serial,
  ) async {
    bool stale() =>
        serial != _seekSerial ||
        _loading ||
        !identical(session, _session) ||
        !identical(renderer, _renderer);

    Future<bool?> check(Duration from) async {
      final began = DateTime.now();
      final verdict = <bool>[];
      for (final wait in const [700, 900, 1200]) {
        await Future<void>.delayed(Duration(milliseconds: wait));
        if (stale()) return null;
        final rel = await _readRelTime(renderer);
        if (stale()) return null;
        if (rel == null) return null; // can't tell: assume it worked
        final elapsed = DateTime.now().difference(began);
        final onTarget = (rel - target).abs() <= const Duration(seconds: 6) ||
            (rel > target &&
                rel <= target + elapsed + const Duration(seconds: 6));
        if (onTarget) return true;
        final nearOld = rel >= from - const Duration(seconds: 3) &&
            rel <= from + elapsed + const Duration(seconds: 6);
        verdict.add(nearOld);
      }
      // Missed three times, every time on the old trajectory.
      return verdict.every((v) => v) ? false : null;
    }

    try {
      final first = await check(before);
      if (first != false || stale()) return;
      final item = session.currentItem.value;
      debugPrint('DlnaTransport[${renderer.friendlyName}]: the TV accepted '
          'Seek to ${_formatHms(target)} but is still at the old position '
          '— trying the other seek unit');
      final tried = renderer.lastSeekUnit;
      final other = renderer.seekUnits().where((u) => u != tried).toList();
      if (other.isNotEmpty) {
        try {
          await _soapCall(renderer.avTransport, 'Seek', {
            'InstanceID': '0',
            'Unit': other.first,
            'Target': _formatHms(target),
          });
          renderer.lastSeekUnit = other.first;
          final second = await check(before);
          if (second != false || stale()) return;
        } on _DlnaSoapException {
          // fall through to the restart below
        }
      }
      if (stale()) return;
      renderer.seekBroken = true;
      session.cancelPendingSeek();
      if (item != null && _canRestartAt(item)) {
        debugPrint('DlnaTransport[${renderer.friendlyName}]: Seek has no '
            'effect on this TV — restarting "${item.title}" at '
            '${_formatHms(target)}');
        await _reloadAt(session, item, target);
      } else {
        _disableSeek(session, item);
      }
    } catch (e) {
      debugPrint('DlnaTransport[${renderer.friendlyName}]: seek check '
          'failed (ignored): $e');
    }
  }

  /// Seeks with the unit the TV declares (REL_TIME first), remembering the
  /// one that worked. Throws the last fault if none is accepted.
  Future<void> _seekRenderer(_DlnaRenderer renderer, Duration position) async {
    final target = _formatHms(position);
    _DlnaSoapException? last;
    for (final unit in renderer.seekUnits()) {
      try {
        await _soapCall(renderer.avTransport, 'Seek',
            {'InstanceID': '0', 'Unit': unit, 'Target': target});
        renderer.lastSeekUnit = unit;
        return;
      } on _DlnaSoapException catch (e) {
        last = e;
      }
    }
    throw last ??
        _DlnaSoapException(action: 'Seek', httpStatus: 0, code: 710);
  }

  @override
  Future<void> setVolume(CastSession session, double volume) async {
    final renderer = _requireRenderer(session);
    final rc = renderer.renderingControl;
    if (rc == null) throw UnsupportedCastCommand('setVolume', kind);
    final clamped = volume.clamp(0.0, 1.0);

    // Show the new level at once and keep a stale poll from snapping the
    // slider back while the TV catches up.
    session.volume.value = clamped;
    _holdVolumeUntil = DateTime.now().add(const Duration(milliseconds: 2000));

    // Latest value wins: while one SOAP call is in flight, newer requests
    // only update the pending target instead of queueing behind it.
    _pendingVolume = clamped;
    if (_volumeSending) return;
    _volumeSending = true;
    try {
      while (_pendingVolume != null) {
        final next = _pendingVolume!;
        _pendingVolume = null;
        await _soapCall(rc, 'SetVolume', {
          'InstanceID': '0',
          'Channel': 'Master',
          'DesiredVolume': '${(next * renderer.volumeMax).round()}',
        });
      }
    } finally {
      _volumeSending = false;
    }
  }

  /// Refreshes `session.volume` from the TV (the volume dialog and the
  /// player's volume gesture call this through CastManager.syncVolume, as
  /// they do for Google Cast — the TV's remote can change it behind our back).
  Future<void> syncVolume(CastSession session) async {
    if (!identical(session, _session)) return;
    await _refreshVolume(session, force: true);
  }

  /// DLNA has no audio-track command. Same approach as Google Cast for a
  /// Jellyfin movie: remember the choice on the item and reload at the
  /// current position — the stream URL then asks the server for a
  /// progressive TS carrying exactly that track.
  @override
  Future<void> selectAudioTrack(CastSession session, int trackId) async {
    if (!session.capability.audioTrackSelection) {
      throw UnsupportedCastCommand('selectAudioTrack', kind);
    }
    final item = session.currentItem.value;
    if (item == null || item.raw == null) {
      throw UnsupportedCastCommand('selectAudioTrack', kind);
    }

    final prevAudioHint = item.raw!['CastAudioStreamOverride'];
    item.raw!['CastAudioStreamOverride'] = trackId;

    // A reload would otherwise drop the subtitle that's currently showing.
    final activeSub = session.activeSubtitleTrackId.value;
    if (activeSub != null && activeSub >= 0) {
      item.raw!['CastActiveSubtitleId'] = activeSub;
    }

    final previousAudio = session.activeAudioTrackId.value;
    final wasPaused = session.playbackState.value == CastPlaybackState.paused;
    session.activeAudioTrackId.value = trackId;
    try {
      await _loadItem(
        session,
        item,
        startAt: session.position.value,
        preferTranscode: true,
        startPaused: wasPaused,
      );
    } catch (_) {
      if (prevAudioHint == null) {
        item.raw!.remove('CastAudioStreamOverride');
      } else {
        item.raw!['CastAudioStreamOverride'] = prevAudioHint;
      }
      if (identical(session, _session)) {
        session.activeAudioTrackId.value = previousAudio;
      }
      rethrow;
    }
  }

  /// Subtitle changes are a reload with a different sidecar declared in the
  /// DIDL. If the requested track is already the declared one (the
  /// coordinator reloads with the hint set and *then* calls this as a
  /// backstop) it's a no-op instead of a second reload.
  @override
  Future<void> selectSubtitleTrack(CastSession session, int trackId) async {
    if (!session.capability.subtitleTrackSelection) {
      throw UnsupportedCastCommand('selectSubtitleTrack', kind);
    }
    final item = session.currentItem.value;
    if (item == null || item.raw == null) {
      throw UnsupportedCastCommand('selectSubtitleTrack', kind);
    }

    final wanted = trackId < 0 ? -1 : trackId;
    final active = session.activeSubtitleTrackId.value ?? -1;
    // An explicit pick deserves a real attempt even if an automatic one was
    // given up on earlier (see [_subtitleBlocked]).
    if (wanted >= 0) _subtitleBlocked.remove('${item.id}|$wanted');
    // Compare with what the TV was really told (see [_declaredSubtitleId]),
    // not with the UI-mutated notifier.
    if (wanted == _declaredSubtitleId) {
      session.activeSubtitleTrackId.value = wanted;
      return;
    }

    // Remember the hints as they were so a failed reload can put them back
    // (otherwise the next load would silently use the failed choice).
    final prevActiveHint = item.raw!['CastActiveSubtitleId'];
    final prevOffHint = item.raw!['CastSubtitlesOff'];
    final prevDeclared = _declaredSubtitleId;

    if (wanted < 0) {
      item.raw!.remove('CastActiveSubtitleId');
      item.raw!['CastSubtitlesOff'] = true;
    } else {
      item.raw!['CastActiveSubtitleId'] = wanted;
      item.raw!.remove('CastSubtitlesOff');
    }

    final wasPaused = session.playbackState.value == CastPlaybackState.paused;
    try {
      await _loadItem(
        session,
        item,
        startAt: session.position.value,
        preferTranscode: _current?.transcoded == true,
        startPaused: wasPaused,
      );
    } catch (_) {
      if (prevActiveHint == null) {
        item.raw!.remove('CastActiveSubtitleId');
      } else {
        item.raw!['CastActiveSubtitleId'] = prevActiveHint;
      }
      if (prevOffHint == null) {
        item.raw!.remove('CastSubtitlesOff');
      } else {
        item.raw!['CastSubtitlesOff'] = prevOffHint;
      }
      _declaredSubtitleId = prevDeclared;
      if (identical(session, _session)) {
        session.activeSubtitleTrackId.value = prevDeclared;
      }
      rethrow;
    }
  }

  @override
  Future<void> next(CastSession session) =>
      throw UnsupportedCastCommand('next', kind);

  @override
  Future<void> previous(CastSession session) =>
      throw UnsupportedCastCommand('previous', kind);

  @override
  Future<void> setShuffle(CastSession session, bool enabled) =>
      throw UnsupportedCastCommand('setShuffle', kind);

  @override
  Future<void> setRepeatMode(CastSession session, CastRepeatMode mode) =>
      throw UnsupportedCastCommand('setRepeatMode', kind);

  @override
  Future<void> setPlaybackRate(CastSession session, double rate) async {
    final renderer = _requireRenderer(session);
    final speed = renderer.nearestSpeed(rate);
    if (speed == null ||
        !session.capability.playbackRate ||
        _current?.transcoded == true) {
      throw UnsupportedCastCommand('setPlaybackRate', kind);
    }
    _holdPollState();
    // Play(Speed) is the only speed control UPnP AVTransport has; the TV
    // advertises which tokens it accepts and the closest one is used.
    await _soapCall(renderer.avTransport, 'Play',
        {'InstanceID': '0', 'Speed': speed.token});
    session.playbackRateNotifier.value = speed.value;
  }

  /// Reads the TV's own capability documents: which `Play` speeds it accepts
  /// (most LG/Samsung sets only list "1", in which case the Speed button
  /// stays disabled) and the real range of its volume control.
  Future<void> _loadRendererCaps(_DlnaRenderer renderer) async {
    if (renderer.capsLoaded) return;
    renderer.capsLoaded = true;

    Future<void> speeds() async {
      final url = renderer.avTransport.scpdUrl;
      if (url == null) return;
      try {
        final xml = await _httpGet(url, const Duration(seconds: 3));
        renderer.playSpeeds = _parsePlaySpeeds(xml);
        _readSeekSupport(renderer, xml);
        // PHASE 0: what the TV's own description says it can do.
        debugPrint('DlnaTransport[${renderer.friendlyName}]: AVTransport '
            'description — ${_describeAvTransportScpd(xml)} '
            'playSpeeds=[${renderer.playSpeeds.map((e) => e.token).join(', ')}]');
      } catch (e) {
        debugPrint('DlnaTransport: AVTransport SCPD unavailable: $e');
      }
    }

    Future<void> volume() async {
      final url = renderer.renderingControl?.scpdUrl;
      if (url == null) return;
      try {
        final xml = await _httpGet(url, const Duration(seconds: 3));
        renderer.volumeMax = _parseVolumeMax(xml) ?? 100;
      } catch (e) {
        debugPrint('DlnaTransport: RenderingControl SCPD unavailable: $e');
      }
    }

    await Future.wait([speeds(), volume()]);
  }

  /// PHASE 4: the TV's declared Seek action and units, from its AVTransport
  /// description.
  void _readSeekSupport(_DlnaRenderer renderer, String scpd) {
    final actions = RegExp(r'<action>\s*<name>([^<]+)</name>',
            caseSensitive: false)
        .allMatches(scpd)
        .map((m) => m.group(1)!.trim())
        .toList();
    if (actions.isNotEmpty) renderer.seekActionDeclared = actions.contains('Seek');
    final modes = <String>[];
    for (final m in RegExp(r'<stateVariable[^>]*>([\s\S]*?)</stateVariable>',
            caseSensitive: false)
        .allMatches(scpd)) {
      final block = m.group(1) ?? '';
      if (_tag(block, 'name')?.trim() != 'A_ARG_TYPE_SeekMode') continue;
      for (final v in RegExp(r'<allowedValue>([\s\S]*?)</allowedValue>',
              caseSensitive: false)
          .allMatches(block)) {
        modes.add(_xmlUnescape(v.group(1) ?? '').trim().toUpperCase());
      }
    }
    renderer.seekModes = modes;
    // A TV whose description says it cannot seek: a file from the phone gets
    // no seek control from the start.
    final item = _session?.currentItem.value;
    final session = _session;
    if (session != null &&
        item != null &&
        item.isLocal &&
        renderer.cannotSeek &&
        session.capability.seek) {
      session.capabilityNotifier.value =
          session.capability.copyWith(seek: false);
    }
  }

  List<_PlaySpeed> _parsePlaySpeeds(String scpd) {
    final blocks = RegExp(r'<stateVariable[^>]*>([\s\S]*?)</stateVariable>',
            caseSensitive: false)
        .allMatches(scpd);
    for (final m in blocks) {
      final block = m.group(1) ?? '';
      if (_tag(block, 'name')?.trim() != 'TransportPlaySpeed') continue;
      final out = <_PlaySpeed>[];
      for (final v in RegExp(r'<allowedValue>([\s\S]*?)</allowedValue>',
              caseSensitive: false)
          .allMatches(block)) {
        final token = _xmlUnescape(v.group(1) ?? '').trim();
        final value = _parseSpeedToken(token);
        if (value != null && value > 0) out.add(_PlaySpeed(token, value));
      }
      // Only worth enabling if there is something besides normal speed.
      final hasOther = out.any((p) => (p.value - 1.0).abs() > 0.01);
      return hasOther ? out : const [];
    }
    return const [];
  }

  double? _parseSpeedToken(String token) {
    final frac = RegExp(r'^(-?\d+(?:\.\d+)?)\s*/\s*(\d+(?:\.\d+)?)$').firstMatch(token);
    if (frac != null) {
      final a = double.tryParse(frac.group(1)!);
      final b = double.tryParse(frac.group(2)!);
      if (a == null || b == null || b == 0) return null;
      return a / b;
    }
    return double.tryParse(token);
  }

  int? _parseVolumeMax(String scpd) {
    final blocks = RegExp(r'<stateVariable[^>]*>([\s\S]*?)</stateVariable>',
            caseSensitive: false)
        .allMatches(scpd);
    for (final m in blocks) {
      final block = m.group(1) ?? '';
      if (_tag(block, 'name')?.trim() != 'Volume') continue;
      final max = int.tryParse(_tag(block, 'maximum')?.trim() ?? '');
      if (max != null && max > 0) return max;
    }
    return null;
  }

  // ═══════════════════════════════════════════════════════════════════════
  // Polling (DLNA eventing needs an inbound callback server and is
  // unreliable across TVs — one-second polling is what every DLNA
  // controller app actually does)
  // ═══════════════════════════════════════════════════════════════════════

  void _startPolling(CastSession session) {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      unawaited(_poll(session));
    });
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _polling = false;
  }

  void _holdPollState() {
    _holdPollStateUntil = DateTime.now().add(const Duration(milliseconds: 1500));
  }

  Future<void> _poll(CastSession session) async {
    final renderer = _renderer;
    if (_polling ||
        _loading ||
        renderer == null ||
        !identical(session, _session)) {
      return;
    }
    _polling = true;
    try {
      final state = await _transportState(renderer,
          timeout: const Duration(seconds: 4));

      Duration? rel;
      Duration? trackDuration;
      if (state == 'PLAYING' || state == 'PAUSED_PLAYBACK') {
        final body = await _soapCall(
          renderer.avTransport,
          'GetPositionInfo',
          const {'InstanceID': '0'},
          timeout: const Duration(seconds: 4),
        );
        rel = _parseHms(_tag(body, 'RelTime'));
        trackDuration = _parseHms(_tag(body, 'TrackDuration'));
      }

      _pollFailures = 0;
      _lastPollOkAt = DateTime.now();
      // A load/stop started while this poll was in flight owns the state.
      if (_loading || !identical(session, _session)) return;

      final now = DateTime.now();
      final sinceLoad =
          _loadedAt == null ? Duration.zero : now.difference(_loadedAt!);

      // Wall-clock proof that this item is genuinely playing: seconds spent
      // in PLAYING since the load. Independent of whether the renderer
      // reports a usable RelTime (several don't).
      if (state == 'PLAYING') {
        final last = _lastPlayingPollAt;
        if (last != null) {
          final delta = now.difference(last);
          if (delta < const Duration(seconds: 5)) _playedFor += delta;
        }
        _lastPlayingPollAt = now;
        _lastPlayingSeenAt = now;
        _playingPolls++;
      } else {
        _lastPlayingPollAt = null;
      }

      // STALL DETECTION: PLAYING, but the reported position has not moved
      // for [_stallAfter]. Only trusted for a renderer that reports time at
      // all (its position has moved before, or it gave a TrackDuration);
      // one that always answers 0:00:00 must not look stalled for a whole
      // movie. Never for live TV, whose position is not meaningful.
      var stalled = false;
      if (state == 'PLAYING' &&
          rel != null &&
          sinceLoad >= const Duration(seconds: 2) &&
          session.currentItem.value?.live != true) {
        final prevRel = _stallRel;
        if (prevRel == null || rel != prevRel) {
          if (prevRel != null) _relEverAdvanced = true;
          _stallRel = rel;
          _stallSince = now;
        } else {
          final since = _stallSince ?? now;
          final reportsTime = _relEverAdvanced ||
              (trackDuration != null && trackDuration > Duration.zero);
          if (reportsTime && now.difference(since) >= _stallAfter) {
            stalled = true;
          }
        }
      } else {
        _stallRel = null;
        _stallSince = null;
        if (sinceLoad < const Duration(seconds: 2)) _relEverAdvanced = false;
      }

      if (stalled && session.playbackState.value != CastPlaybackState.buffering) {
        debugPrint('DlnaTransport[${renderer.friendlyName}]: PLAYING but the '
            'position has been stuck at ${_stallRel?.inSeconds}s for '
            '${_stallAfter.inSeconds}s+ — showing as buffering');
      }

      final hold = now.isBefore(_holdPollStateUntil);
      // PHASE 4: a Play/Pause the TV has not confirmed yet.
      final wanted = _pendingWanted(now, session);
      switch (state) {
        case 'PLAYING':
          if (session.playbackState.value == CastPlaybackState.error) {
            // PHASE 1: never resurrect a failed load on a bare PLAYING.
            if (!hold) await _reconcileAfterFailure(session, renderer);
            break;
          }
          if (wanted == CastPlaybackState.paused) {
            // Asked to pause, TV still plays: keep the tapped state.
            _retryWantedOnce(session, renderer, now);
            break;
          }
          if (wanted == CastPlaybackState.playing) {
            _confirmWanted(session);
            session.playbackState.value = stalled
                ? CastPlaybackState.buffering
                : CastPlaybackState.playing;
            break;
          }
          if (!hold) {
            session.playbackState.value = stalled
                ? CastPlaybackState.buffering
                : CastPlaybackState.playing;
          }
          break;
        case 'PAUSED_PLAYBACK':
        case 'PAUSED_RECORDING':
          if (wanted == CastPlaybackState.playing) {
            // Asked to resume, TV still paused: keep the tapped state.
            _retryWantedOnce(session, renderer, now);
            break;
          }
          if (wanted == CastPlaybackState.paused) {
            _confirmWanted(session);
            session.playbackState.value = CastPlaybackState.paused;
            break;
          }
          if (!hold) session.playbackState.value = CastPlaybackState.paused;
          break;
        case 'TRANSITIONING':
          final s = session.playbackState.value;
          // A TV that is switching state after a command is not buffering.
          if (!hold &&
              wanted == null &&
              (s == CastPlaybackState.playing ||
                  s == CastPlaybackState.paused)) {
            session.playbackState.value = CastPlaybackState.buffering;
          }
          break;
        case 'STOPPED':
        case 'NO_MEDIA_PRESENT':
          if (!hold) {
            _confirmWanted(session);
            _handleRendererStopped(session);
          }
          break;
      }

      if (rel != null && _relPlausible(rel, sinceLoad)) {
        _relSeen = true;
        _lastPolledPosition = _streamOffset + rel;
        session.reportPosition(_lastPolledPosition);
      } else if (rel == null && state == 'PLAYING') {
        // Renderer doesn't report RelTime: keep the seek bar and the
        // end-of-track check moving from the wall clock instead.
        _lastPolledPosition = _wallBase + _playedFor;
        session.reportPosition(_lastPolledPosition);
      }
      // TrackDuration right after a switch can still be the previous
      // item's — only trust it once the new item has been playing a moment.
      final trustDuration = sinceLoad >= const Duration(seconds: 2);
      if (trackDuration != null &&
          trackDuration > Duration.zero &&
          trustDuration &&
          _current?.transcoded != true) {
        _lastTrackDuration = trackDuration;
        if (session.duration.value <= Duration.zero) {
          session.duration.value = trackDuration;
        }
      }

      if (!_confirmedPlaying && state == 'PLAYING') {
        final known = session.duration.value;
        if (_playedFor >= const Duration(seconds: 3) ||
            _lastPolledPosition - _loadStartAt >= const Duration(seconds: 3) ||
            (known > Duration.zero &&
                known <= const Duration(seconds: 8) &&
                _playingPolls >= 1)) {
          _confirmedPlaying = true;
        }
      }
      if (_confirmedPlaying) _dropReloadedFor = null;

      _pollTick++;
      if (_pollTick % 3 == 0) {
        await _refreshVolume(session);
      }
    } catch (e) {
      if (e is _DlnaSoapException) {
        // The TV ANSWERED (with a fault — typical while Kodi/AirScreen are
        // switching or opening an item). That proves it is reachable, so it
        // must never count towards "lost connection".
        _pollFailures = 0;
        _lastPollOkAt = DateTime.now();
      } else if (!_loading) {
        _pollFailures++;
      }
      final silentFor = DateTime.now().difference(_lastPollOkAt);
      // Only a TV that has been silent for a full minute AND failed many
      // polls in a row is treated as gone (powered off / left the Wi-Fi).
      if (_pollFailures >= 8 &&
          silentFor >= _lostAfter &&
          !_loading &&
          identical(session, _session)) {
        debugPrint('DlnaTransport: TV stopped answering ($e) — disconnecting');
        _stopPolling();
        // Cancels any load still in flight so it can't keep writing into a
        // session CastManager is about to dispose.
        _loadGeneration++;
        _renderer = null;
        _session = null;
        session.lastError.value = 'Lost connection to the TV.';
        session.connectionState.value = CastConnectionState.disconnected;
      }
    } finally {
      _polling = false;
    }
  }

  /// A RelTime reported in the first seconds after a switch can still belong
  /// to the previous item (e.g. 3:58 for a song that just started). While
  /// that is physically impossible for the new item, ignore it.
  bool _relPlausible(Duration rel, Duration sinceLoad) {
    if (_trustRel || _loadedAt == null) return true;
    if (sinceLoad > const Duration(seconds: 20)) return true;
    return rel <= sinceLoad + _directStartAt + const Duration(seconds: 6);
  }

  Duration get _effectivePosition {
    final wall = _wallBase + _playedFor;
    return _lastPolledPosition > wall ? _lastPolledPosition : wall;
  }

  /// The renderer went STOPPED/NO_MEDIA_PRESENT while we thought it was
  /// playing. Decide *why*, so PlaybackCoordinator's auto-advance only
  /// fires for a genuine end of media:
  ///  * a stop pressed on the TV's own remote must not skip to the next song;
  ///  * a STOPPED reported while the renderer is still switching to the item
  ///    we just sent (Kodi/AirScreen do this) must NEVER count as the item
  ///    having finished — that was the "plays 5 seconds, then skips, over
  ///    and over" loop.
  void _handleRendererStopped(CastSession session) {
    final prev = session.playbackState.value;
    final wasActive = prev == CastPlaybackState.playing ||
        prev == CastPlaybackState.paused ||
        prev == CastPlaybackState.buffering;
    if (!wasActive || _commandedStop) return;

    final item = session.currentItem.value;

    // ── the item never really started ────────────────────────────────
    if (!_confirmedPlaying && item?.live != true) {
      final sinceLoad = _loadedAt == null
          ? Duration.zero
          : DateTime.now().difference(_loadedAt!);
      if (sinceLoad < const Duration(seconds: 10)) {
        final renderer = _renderer;
        // A TV's own receiver (not Kodi / AirScreen) that accepted the
        // switch while still reporting the OLD item as playing, and then
        // closed its player and went STOPPED without ever playing this one:
        // the URI died with the player, and a bare Play can't bring it back.
        // Re-send the item once, to the now idle TV (see [_waitDropped]).
        if (renderer != null &&
            item != null &&
            !renderer.quirks.stopBeforeSwitch &&
            sinceLoad >= const Duration(milliseconds: 2500) &&
            _dropReloadedFor != item.id) {
          _dropReloadedFor = item.id;
          unawaited(_reloadDroppedItem(session, item));
          return;
        }
        // Give the renderer a chance to finish switching; poke it once.
        if (!_startNudged &&
            !_replayedDuringLoad &&
            renderer != null &&
            renderer.quirks.replayWhileStopped) {
          _startNudged = true;
          _holdPollState();
          unawaited(_soapCall(renderer.avTransport, 'Play',
                  const {'InstanceID': '0', 'Speed': '1'})
              .then((_) {}, onError: (_) {}));
        }
        return;
      }
      // Still stopped 10 s after "playing" was reported and it never
      // progressed: that's a failed start, not a finished song. Report an
      // error (the coordinator never auto-advances on one).
      final title = item?.title ?? 'this item';
      session.lastError.value =
          'The TV stopped right after starting "$title".';
      session.idleReason.value = CastIdleReason.error;
      session.playbackState.value = CastPlaybackState.error;
      return;
    }

    // ── it did play: did it play to the end? ─────────────────────────
    //
    // PHASE 4 (loop and auto-next silently did nothing on some TVs): the
    // end of a track is judged from three things, each of which a TV may
    // get wrong — the position, the length, and how recently the position
    // was read. The window below is therefore wider where the evidence is
    // weaker (position from the wall clock only; metadata length that the
    // TV never confirmed) and counts the time since the last poll that saw
    // the TV playing. A stop the phone sent itself is excluded above, and a
    // stop from the TV's own remote far from the end still reads as
    // cancelled.
    final duration = session.duration.value > Duration.zero
        ? session.duration.value
        : _lastTrackDuration;
    final position = _effectivePosition;
    final seenAt = _lastPlayingSeenAt;
    var sincePlaying = seenAt == null
        ? Duration.zero
        : DateTime.now().difference(seenAt);
    if (sincePlaying > const Duration(seconds: 5)) {
      sincePlaying = const Duration(seconds: 5);
    }
    var slack = const Duration(seconds: 8);
    if (!_relSeen) slack += const Duration(seconds: 4);
    final bool finished;
    if (item?.live == true) {
      finished = false;
    } else if (duration > Duration.zero) {
      final reach = position + sincePlaying + slack;
      finished = reach >= duration ||
          (_lastTrackDuration > Duration.zero &&
              _current?.transcoded != true &&
              reach >= _lastTrackDuration);
    } else {
      finished = true; // genuinely played, nothing says how long it was
    }
    debugPrint('DlnaTransport: end-of-track check — position='
        '${position.inSeconds}s duration=${duration.inSeconds}s '
        'tvDuration=${_lastTrackDuration.inSeconds}s '
        'relReported=$_relSeen slack=${slack.inSeconds}s '
        'sincePlaying=${sincePlaying.inSeconds}s -> '
        '${finished ? 'finished' : 'cancelled (stopped before the end)'}');

    // Order matters: the coordinator reads idleReason from inside the
    // playbackState listener.
    session.idleReason.value =
        finished ? CastIdleReason.finished : CastIdleReason.cancelled;
    session.playbackState.value =
        finished ? CastPlaybackState.ended : CastPlaybackState.stopped;
  }

  /// One-shot recovery for [_dropReloadedFor]: sends the item again with the
  /// classic Stop-first sequence, which is harmless now — the TV has already
  /// closed its player and sits idle.
  Future<void> _reloadDroppedItem(CastSession session, MediaItem item) async {
    debugPrint('DlnaTransport: the TV went STOPPED without ever playing '
        '"${item.title}" — re-sending it once');
    try {
      await _loadItem(
        session,
        item,
        startAt: _loadStartAt,
        preferTranscode: _current?.transcoded == true,
      );
    } catch (e) {
      debugPrint('DlnaTransport: re-sending the dropped item failed: $e');
    }
  }

  Future<void> _refreshVolume(CastSession session, {bool force = false}) async {
    final renderer = _renderer;
    final rc = renderer?.renderingControl;
    if (renderer == null || rc == null) return;
    if (_volumeSending || _pendingVolume != null) return;
    if (!force && DateTime.now().isBefore(_holdVolumeUntil)) return;
    try {
      final body = await _soapCall(
        rc,
        'GetVolume',
        const {'InstanceID': '0', 'Channel': 'Master'},
        timeout: const Duration(seconds: 3),
      );
      final v = int.tryParse(_tag(body, 'CurrentVolume')?.trim() ?? '');
      if (v != null &&
          !_loading &&
          !_volumeSending &&
          _pendingVolume == null &&
          (force || DateTime.now().isAfter(_holdVolumeUntil))) {
        session.volume.value = (v / renderer.volumeMax).clamp(0.0, 1.0);
      }
    } catch (_) {}
  }

  Future<String?> _transportState(
    _DlnaRenderer renderer, {
    Duration timeout = const Duration(seconds: 6),
  }) async =>
      (await _transportInfo(renderer, timeout: timeout)).state;

  /// GetTransportInfo: the transport state plus the transport status
  /// (`OK` / `ERROR_OCCURRED`), both upper-cased; either can be null when
  /// the renderer leaves it out.
  Future<({String? state, String? status})> _transportInfo(
    _DlnaRenderer renderer, {
    Duration timeout = const Duration(seconds: 6),
  }) async {
    final body = await _soapCall(
      renderer.avTransport,
      'GetTransportInfo',
      const {'InstanceID': '0'},
      timeout: timeout,
    );
    return (
      state: _tag(body, 'CurrentTransportState')?.trim().toUpperCase(),
      status: _tag(body, 'CurrentTransportStatus')?.trim().toUpperCase(),
    );
  }

  _DlnaRenderer _requireRenderer(CastSession session) {
    final renderer = _renderer;
    if (renderer == null || !identical(session, _session)) {
      throw StateError('Not connected to a DLNA TV.');
    }
    return renderer;
  }

  // ═══════════════════════════════════════════════════════════════════════
  // SOAP / HTTP plumbing
  // ═══════════════════════════════════════════════════════════════════════

  Future<String> _soapCall(
    _DlnaService service,
    String action,
    Map<String, String> args, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final body = StringBuffer()
      ..write('<?xml version="1.0" encoding="utf-8"?>')
      ..write('<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
          's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">')
      ..write('<s:Body><u:$action xmlns:u="${service.type}">');
    args.forEach((key, value) {
      body.write('<$key>${_xmlEscape(value)}</$key>');
    });
    body.write('</u:$action></s:Body></s:Envelope>');
    final payload = utf8.encode(body.toString());

    Object? lastError;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final request =
            await _http.postUrl(service.controlUrl).timeout(timeout);
        // TVs routinely drop keep-alive connections without telling us.
        request.persistentConnection = false;
        request.headers
          ..set('Content-Type', 'text/xml; charset="utf-8"',
              preserveHeaderCase: true)
          ..set('SOAPAction', '"${service.type}#$action"',
              preserveHeaderCase: true);
        // Fixed length (never chunked) — several renderers reject chunked.
        request.contentLength = payload.length;
        request.add(payload);

        final response = await request.close().timeout(timeout);
        final bytes = await response.fold<List<int>>(<int>[], (acc, chunk) {
          acc.addAll(chunk);
          return acc;
        }).timeout(timeout);
        final text = utf8.decode(bytes, allowMalformed: true);

        if (response.statusCode >= 200 && response.statusCode < 300) {
          return text;
        }
        final fault = _DlnaSoapException(
          action: action,
          httpStatus: response.statusCode,
          code: int.tryParse(_tag(text, 'errorCode')?.trim() ?? ''),
          description: _tag(text, 'errorDescription')?.trim(),
        );
        _logSoapProblem(action, 'fault ${fault.describe()}'
            '${fault.code == null ? ' body="${_clip(text, 160)}"' : ''}');
        throw fault;
      } catch (e) {
        if (e is _DlnaSoapException) rethrow;
        _logSoapProblem(action, 'failed (try ${attempt + 1}): $e');
        lastError = e;
        if (attempt == 0 && (e is SocketException || e is HttpException)) {
          await Future<void>.delayed(const Duration(milliseconds: 250));
          continue;
        }
        rethrow;
      }
    }
    throw lastError ?? StateError('SOAP $action failed');
  }

  /// PHASE 0: one line per distinct SOAP problem (same action + same text
  /// at most every 10 s).
  void _logSoapProblem(String action, String what) {
    final key = '$action|$what';
    final now = DateTime.now();
    final last = _faultLoggedAt[key];
    if (last != null && now.difference(last) < const Duration(seconds: 10)) {
      return;
    }
    _faultLoggedAt[key] = now;
    if (_faultLoggedAt.length > 40) _faultLoggedAt.clear();
    final name = _renderer?.friendlyName ?? '?';
    debugPrint('DlnaTransport[$name]: SOAP $action $what');
    _tlAdd('SOAP $action $what');
  }

  static String _clip(String s, int max) {
    final flat = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return flat.length <= max ? flat : '${flat.substring(0, max)}…';
  }

  Future<String> _httpGet(Uri uri, Duration timeout) async {
    final request = await _http.getUrl(uri).timeout(timeout);
    request.persistentConnection = false;
    final response = await request.close().timeout(timeout);
    if (response.statusCode != 200) {
      await response.drain<void>();
      throw HttpException('HTTP ${response.statusCode}', uri: uri);
    }
    final bytes = await response.fold<List<int>>(<int>[], (acc, chunk) {
      acc.addAll(chunk);
      return acc;
    }).timeout(timeout);
    return utf8.decode(bytes, allowMalformed: true);
  }

  // ═══════════════════════════════════════════════════════════════════════
  // Jellyfin metadata helpers
  // ═══════════════════════════════════════════════════════════════════════

  List<Map> _streams(MediaItem item) {
    dynamic src = item.mediaStreams;
    if (src is! List || src.isEmpty) {
      final sources = item.mediaSources;
      if (sources != null && sources.isNotEmpty && sources.first is Map) {
        src = (sources.first as Map)['MediaStreams'];
      }
    }
    if (src is! List || src.isEmpty) {
      src = item.raw?['MediaStreams'];
    }
    if (src is List) return src.whereType<Map>().toList();
    return const [];
  }

  Map? _defaultStream(MediaItem item, String type) {
    final all = _streams(item).where((s) => s['Type'] == type).toList();
    if (all.isEmpty) return null;
    for (final s in all) {
      if (s['IsDefault'] == true) return s;
    }
    return all.first;
  }

  Map? _streamByIndex(MediaItem item, String type, int? index) {
    if (index == null) return null;
    for (final s in _streams(item)) {
      if (s['Type'] == type && s['Index'] == index) return s;
    }
    return null;
  }

  String? _codecOf(Map? stream) =>
      stream?['Codec']?.toString().toLowerCase();

  String _mediaSourceId(MediaItem item) {
    final sources = item.mediaSources;
    if (sources != null && sources.isNotEmpty && sources.first is Map) {
      final id = (sources.first as Map)['Id'];
      if (id is String && id.isNotEmpty) return id;
    }
    return item.id;
  }

  Set<String> _containerTokens(MediaItem item) {
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
        if (dot >= 0 && dot < path.length - 1) raw = path.substring(dot + 1);
      }
    }
    if (raw == null || raw.trim().isEmpty) return const <String>{};
    return raw
        .toLowerCase()
        .split(RegExp(r'[,;\s]+'))
        .where((t) => t.isNotEmpty)
        .toSet();
  }

  String? _altMime(String mime) {
    switch (mime) {
      case 'video/x-matroska':
        return 'video/x-mkv';
      case 'video/mp2t':
        return 'video/mpeg';
      case 'video/x-msvideo':
        return 'video/avi';
      case 'video/quicktime':
        return 'video/mp4';
      case 'audio/flac':
        return 'audio/x-flac';
      case 'audio/wav':
        return 'audio/x-wav';
      case 'audio/aac':
        return 'audio/mp4';
      default:
        return null;
    }
  }

  /// Jellyfin's direct-play URLs are `/Videos/{id}/stream?static=true` and
  /// `/Audio/{id}/stream?static=true` — no file extension. Plenty of
  /// renderers (AirScreen, several LG/Samsung firmwares) pick their demuxer
  /// from the URL's extension and refuse an extension-less one even though
  /// the bytes are fine. Jellyfin serves the very same file from
  /// `stream.{container}` (this is the form its own web client uses), so the
  /// real container is added when it is known. Anything that doesn't look
  /// like those URLs (a local server route, a transcode URL) is untouched.
  String _withContainerExtension(String url, String? ext) {
    if (ext == null) return url;
    return url.replaceFirstMapped(
      RegExp(r'(/(?:Audio|Videos)/[^/?]+/stream)\?'),
      (m) => '${m.group(1)}.$ext?',
    );
  }

  /// File extension for the item's container, or null when it isn't known
  /// well enough to name (the URL is then left exactly as it was).
  String? _extensionFor(MediaItem item, {required bool audio}) {
    final t = _containerTokens(item);
    if (t.isEmpty) return null;
    if (audio) {
      if (t.contains('flac')) return 'flac';
      if (t.contains('mp3')) return 'mp3';
      if (t.contains('aac')) return 'aac';
      if (t.contains('m4a') || t.contains('mp4') || t.contains('alac')) {
        return 'm4a';
      }
      if (t.contains('wav') || t.contains('wave')) return 'wav';
      if (t.contains('ogg') || t.contains('opus') || t.contains('oga')) {
        return 'ogg';
      }
      if (t.contains('wma') || t.contains('asf')) return 'wma';
      return null;
    }
    if (t.contains('matroska') || t.contains('mkv')) return 'mkv';
    if (t.contains('webm')) return 'webm';
    if (t.contains('mp4') || t.contains('mov') || t.contains('m4v')) {
      return 'mp4';
    }
    if (t.contains('avi')) return 'avi';
    if (t.contains('mpegts') || t.contains('m2ts') || t.contains('ts')) {
      return 'ts';
    }
    return null;
  }

  String _videoMime(MediaItem item) {
    final t = _containerTokens(item);
    if (t.contains('matroska') || t.contains('mkv')) return 'video/x-matroska';
    if (t.contains('webm')) return 'video/webm';
    if (t.contains('mp4') || t.contains('mov') || t.contains('m4v')) {
      return 'video/mp4';
    }
    if (t.contains('avi')) return 'video/x-msvideo';
    if (t.contains('mpegts') || t.contains('ts') || t.contains('m2ts')) {
      return 'video/mp2t';
    }
    if (t.contains('wmv') || t.contains('asf')) return 'video/x-ms-wmv';
    if (t.contains('mpeg') || t.contains('mpg')) return 'video/mpeg';
    if (t.contains('flv')) return 'video/x-flv';
    if (t.contains('3gp')) return 'video/3gpp';
    return 'video/mp4';
  }

  String _audioMime(MediaItem item) {
    final t = _containerTokens(item);
    if (t.contains('flac')) return 'audio/flac';
    if (t.contains('mp3')) return 'audio/mpeg';
    if (t.contains('aac')) return 'audio/aac';
    if (t.contains('m4a') || t.contains('mp4') || t.contains('alac')) {
      return 'audio/mp4';
    }
    if (t.contains('wav') || t.contains('wave')) return 'audio/wav';
    if (t.contains('ogg') || t.contains('opus') || t.contains('oga')) {
      return 'audio/ogg';
    }
    if (t.contains('wma') || t.contains('asf')) return 'audio/x-ms-wma';
    if (t.contains('aiff') || t.contains('aif')) return 'audio/aiff';
    return 'audio/mpeg';
  }

  int _ticks(Duration d) => d.inMicroseconds * 10;
}

// ═════════════════════════════════════════════════════════════════════════
// Small value types + XML helpers
// ═════════════════════════════════════════════════════════════════════════

class _DlnaService {
  const _DlnaService(this.type, this.controlUrl, [this.scpdUrl]);
  final String type;
  final Uri controlUrl;

  /// Where the service's own capability description (allowed values etc.)
  /// lives. Read once at connect time.
  final Uri? scpdUrl;
}

/// One value the TV accepts for AVTransport `Play`'s `Speed` argument.
class _PlaySpeed {
  const _PlaySpeed(this.token, this.value);
  final String token; // exactly as the TV lists it ("1", "2", "1/2" …)
  final double value;
}

class _DlnaRenderer {
  _DlnaRenderer({
    required this.id,
    required this.friendlyName,
    required this.manufacturer,
    required this.modelName,
    required this.host,
    required this.avTransport,
    required this.renderingControl,
    this.extraFingerprint = '',
  });

  final String id;
  final String friendlyName;
  final String manufacturer;
  final String modelName;
  final String host;
  final _DlnaService avTransport;
  final _DlnaService? renderingControl;
  DateTime lastSeen = DateTime.now();

  /// Timing behaviour tuned to what this renderer is (see [_RendererQuirks]).
  late final _RendererQuirks quirks = _RendererQuirks.detect(
      '$friendlyName $manufacturer $modelName $extraFingerprint');

  /// Other identifying text from the device description (model description,
  /// manufacturer / model URLs). ROOT CAUSE (AirScreen treated as a generic
  /// TV): detection used to look only at friendlyName + manufacturer +
  /// modelName, and AirScreen's friendly name is whatever the owner typed
  /// into its settings, so a renamed AirScreen got the generic profile (no
  /// Stop before a switch, no patience for its slow start) and behaved
  /// differently from the one that was named "AirScreen".
  final String extraFingerprint;

  // Filled in from the TV's SCPD documents when a session connects.
  bool capsLoaded = false;
  List<_PlaySpeed> playSpeeds = const [];
  int volumeMax = 100;

  // PHASE 4: what the TV's AVTransport description says about seeking.
  /// Units from A_ARG_TYPE_SeekMode (empty = not declared).
  List<String> seekModes = const [];

  /// False when the description was read, lists its actions, and `Seek` is
  /// not one of them. Null when the description could not be read.
  bool? seekActionDeclared;

  /// The unit the last accepted Seek used (tried first next time).
  String? lastSeekUnit;

  /// Learned: Seek is refused, or accepted without effect.
  bool seekBroken = false;

  bool get cannotSeek =>
      seekBroken ||
      seekActionDeclared == false ||
      (seekModes.isNotEmpty &&
          !seekModes.any((m) => m == 'REL_TIME' || m == 'ABS_TIME'));

  /// Seek units to try, best first: the one that worked, then REL_TIME, then
  /// ABS_TIME — limited to what the TV declares when it declares anything.
  List<String> seekUnits() {
    final declared = seekModes.isEmpty
        ? const ['REL_TIME', 'ABS_TIME']
        : ['REL_TIME', 'ABS_TIME'].where(seekModes.contains).toList();
    final first = lastSeekUnit;
    if (first == null || !declared.contains(first)) return declared;
    return [first, ...declared.where((u) => u != first)];
  }

  _PlaySpeed? nearestSpeed(double rate) {
    _PlaySpeed? best;
    for (final s in playSpeeds) {
      if (best == null || (s.value - rate).abs() < (best.value - rate).abs()) {
        best = s;
      }
    }
    return best;
  }
}

/// PHASE 3: how a cover prepared by the phone is declared in the DIDL-Lite
/// metadata. One value per renderer profile (see [_RendererQuirks.coverForm]);
/// if a renderer never fetches the cover (the load log says "the TV has NOT
/// fetched the cover"), change that renderer's value to the next form.
enum _CoverForm {
  /// albumArtURI with dlna:profileID AND an image <res> (what most UPnP
  /// controllers send).
  full,

  /// albumArtURI with dlna:profileID only.
  albumArtOnly,

  /// A bare albumArtURI, as before — only the URL changed.
  plain,
}

/// How patient to be with a renderer, and which recovery tricks are safe for
/// it. Chosen from the name the renderer advertises; anything unrecognised
/// gets the generic profile, which is deliberately tolerant (a TV that is
/// merely slow must never be mistaken for one that refused the stream).
class _RendererQuirks {
  const _RendererQuirks({
    this.coverForm = _CoverForm.full,
    required this.stoppedBeforeTransition,
    required this.stoppedAfterTransition,
    required this.directStartTimeout,
    required this.replayWhileStopped,
    required this.stopBeforeSwitch,
    this.verifyStopSettled = false,
  });

  /// How the cover is declared to this kind of renderer (PHASE 3).
  final _CoverForm coverForm;

  /// Whether a confirmed Stop is re-checked a moment later and repeated if
  /// the renderer is playing again.
  ///
  /// ROOT CAUSE (AirScreen keeps playing after the phone disconnects): the
  /// first Stop was trusted as soon as GetTransportInfo said STOPPED. An
  /// AirScreen that was still opening / buffering the stream reports STOPPED
  /// (it has not started yet) and then starts playing the item it had already
  /// been given, so the song carried on after the phone had let go. Only
  /// renderers that need it pay the extra second.
  final bool verifyStopSettled;

  /// How long STOPPED / NO_MEDIA_PRESENT is tolerated right after the item
  /// was sent, while the renderer has not yet been seen TRANSITIONING or
  /// PLAYING (it is still opening the stream).
  final Duration stoppedBeforeTransition;

  /// Same, once the renderer HAS been seen TRANSITIONING — dropping back to
  /// STOPPED after that is a genuine rejection of the stream.
  final Duration stoppedAfterTransition;

  /// Overall limit for a direct (non-transcoded) stream to start.
  final Duration directStartTimeout;

  /// Whether re-sending `Play` while the renderer sits STOPPED is safe.
  final bool replayWhileStopped;

  /// Whether a new item is loaded with the classic Stop -> wait until idle ->
  /// SetAVTransportURI -> Play sequence.
  ///
  /// ROOT CAUSE (a TV's own DLNA receiver: tapped song sometimes never
  /// plays, Next / another song "exits the casting player" and only the
  /// SECOND tap plays, another movie can't be switched to): the Stop that
  /// precedes every SetAVTransportURI is what Kodi and AirScreen (apps that
  /// keep running in the background) want, but a TV's built-in receiver
  /// treats Stop as "end of the cast" and tears its whole player down (the
  /// casting screen closes). The URI sent a moment later lands on a
  /// receiver that is busy closing and is dropped or wiped, so the item
  /// never starts; the next tap works only because the TV is idle by then.
  /// UPnP allows SetAVTransportURI in every transport state, so for
  /// renderers that are not Kodi/AirScreen a switch is now sent WITHOUT the
  /// Stop (what BubbleUPnP and VLC do), and falls back to the Stop-first
  /// sequence inside the same load only when the TV proves it needs it.
  final bool stopBeforeSwitch;

  static const _generic = _RendererQuirks(
    stoppedBeforeTransition: Duration(seconds: 12),
    stoppedAfterTransition: Duration(seconds: 4),
    directStartTimeout: Duration(seconds: 45),
    replayWhileStopped: true,
    stopBeforeSwitch: false,
  );

  // Kodi reports STOPPED for the whole time it opens a network stream
  // (cold start: many seconds) and restarts the open if Play is repeated.
  static const _kodi = _RendererQuirks(
    stoppedBeforeTransition: Duration(seconds: 30),
    stoppedAfterTransition: Duration(seconds: 8),
    directStartTimeout: Duration(seconds: 60),
    replayWhileStopped: false,
    stopBeforeSwitch: true,
  );

  // AirScreen accepts and displays the item but may need Play repeated
  // before its player starts.
  static const _airScreen = _RendererQuirks(
    stoppedBeforeTransition: Duration(seconds: 16),
    stoppedAfterTransition: Duration(seconds: 6),
    directStartTimeout: Duration(seconds: 50),
    replayWhileStopped: true,
    stopBeforeSwitch: true,
    verifyStopSettled: true,
  );

  factory _RendererQuirks.detect(String fingerprint) {
    final f = fingerprint.toLowerCase();
    if (f.contains('kodi') || f.contains('xbmc')) return _kodi;
    if (f.contains('airscreen') ||
        f.contains('air screen') ||
        f.contains('ionitech')) {
      return _airScreen;
    }
    return _generic;
  }
}

/// One concrete URL to hand to the TV.
class _DlnaStream {
  const _DlnaStream({
    required this.url,
    required this.mime,
    required this.label,
    this.seekable = true,
    this.transcoded = false,
    this.offset = Duration.zero,
    this.durationHint,
    this.sizeBytes,
    this.noSubtitle = false,
  });

  final String url;
  final String mime;
  final String label;

  /// True for the repeat of a stream that failed to start with a subtitle
  /// declared: sent with no subtitle in the metadata.
  final bool noSubtitle;

  /// True when the TV can byte-range / time-seek this URL itself.
  final bool seekable;

  /// True for a server-side progressive transcode (seek = restart stream).
  final bool transcoded;

  /// Where this stream's own t=0 sits on the media timeline (a restarted
  /// transcode begins at its StartTimeTicks, but the TV reports 0:00).
  final Duration offset;

  final Duration? durationHint;

  /// Exact size in bytes, when known (a file this phone serves itself).
  /// Declared as `size` in the DIDL-Lite `<res>`.
  final int? sizeBytes;

  /// The same URL declared under another MIME spelling.
  _DlnaStream withMime(String newMime) => _DlnaStream(
        url: url,
        mime: newMime,
        label: '$label ($newMime)',
        seekable: seekable,
        transcoded: transcoded,
        offset: offset,
        durationHint: durationHint,
        sizeBytes: sizeBytes,
        noSubtitle: noSubtitle,
      );

  /// The same stream, sent without any subtitle declaration.
  _DlnaStream withoutSubtitle() => _DlnaStream(
        url: url,
        mime: mime,
        label: '$label (no subtitle)',
        seekable: seekable,
        transcoded: transcoded,
        offset: offset,
        durationHint: durationHint,
        sizeBytes: sizeBytes,
        noSubtitle: true,
      );

  /// The same stream with its byte size filled in.
  _DlnaStream withSize(int bytes) => _DlnaStream(
        url: url,
        mime: mime,
        label: label,
        seekable: seekable,
        transcoded: transcoded,
        offset: offset,
        durationHint: durationHint,
        sizeBytes: bytes,
        noSubtitle: noSubtitle,
      );
}

/// What a SetAVTransportURI that needed a simpler metadata form taught us
/// about the renderer — applied only once the item really plays.
class _LearnedForm {
  const _LearnedForm({
    required this.rendererId,
    required this.altKey,
    required this.altWasPreferred,
    required this.plain,
  });
  final String rendererId;
  final String? altKey;
  final bool altWasPreferred;
  final bool plain;
}

/// The slice of the user's subtitle style an SRT file can carry to a TV.
class _SubtitleTagStyle {
  const _SubtitleTagStyle(this.colorRgb, this.bold);

  /// 0xRRGGBB, or null for the default white.
  final int? colorRgb;
  final bool bold;

  bool get isPlain => colorRgb == null && !bold;
  String get key => '${colorRgb ?? 'x'}:$bold';
}

class _DlnaSoapException implements Exception {
  _DlnaSoapException({
    required this.action,
    required this.httpStatus,
    this.code,
    this.description,
  });

  final String action;
  final int httpStatus;
  final int? code;
  final String? description;

  String describe() {
    final parts = <String>[
      action,
      if (code != null) 'UPnP error $code',
      if (description != null && description!.isNotEmpty) description!,
      if (code == null) 'HTTP $httpStatus',
    ];
    return parts.join(': ');
  }

  @override
  String toString() => '_DlnaSoapException(${describe()})';
}

/// PHASE 0: log lines get sent around when something is debugged, and a
/// Jellyfin URL carries the access token in its query string — blank it.
String _redact(String s) => s.replaceAllMapped(
      RegExp(r'(api_key|apikey|x-emby-token|x-mediabrowser-token)=[^&"<\s]+',
          caseSensitive: false),
      (m) => '${m.group(1)}=***',
    );

/// PHASE 0: what an AVTransport description document (SCPD) declares —
/// the actions the TV implements and the seek units it accepts.
String _describeAvTransportScpd(String scpd) {
  final actions = RegExp(r'<action>\s*<name>([^<]+)</name>',
          caseSensitive: false)
      .allMatches(scpd)
      .map((m) => m.group(1)!.trim())
      .toList();
  final modes = <String>[];
  for (final m in RegExp(r'<stateVariable[^>]*>([\s\S]*?)</stateVariable>',
          caseSensitive: false)
      .allMatches(scpd)) {
    final block = m.group(1) ?? '';
    if (_tag(block, 'name')?.trim() != 'A_ARG_TYPE_SeekMode') continue;
    for (final v in RegExp(r'<allowedValue>([\s\S]*?)</allowedValue>',
            caseSensitive: false)
        .allMatches(block)) {
      modes.add(_xmlUnescape(v.group(1) ?? '').trim());
    }
  }
  bool has(String a) => actions.contains(a);
  return 'actions=${actions.length} '
      '(Pause=${has('Pause')}, Seek=${has('Seek')}, Next=${has('Next')}, '
      'Previous=${has('Previous')}, '
      'SetNextAVTransportURI=${has('SetNextAVTransportURI')}, '
      'GetCurrentTransportActions=${has('GetCurrentTransportActions')}) '
      'seekModes=${modes.isEmpty ? 'not declared' : modes.join('/')}';
}

String _xmlEscape(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');

String _xmlUnescape(String s) => s
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'")
    .replaceAll('&#39;', "'")
    .replaceAll('&amp;', '&');

/// First `<tag>…</tag>` (namespace prefix tolerated) as unescaped text.
String? _tag(String xml, String tag) {
  final match = RegExp(
    r'<(?:[\w.-]+:)?' +
        tag +
        r'(?:\s[^>]*)?>([\s\S]*?)</(?:[\w.-]+:)?' +
        tag +
        r'>',
    caseSensitive: false,
  ).firstMatch(xml);
  final value = match?.group(1);
  return value == null ? null : _xmlUnescape(value);
}

String _formatHms(Duration d) {
  final total = d.inSeconds < 0 ? 0 : d.inSeconds;
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  return '${h.toString().padLeft(2, '0')}:'
      '${m.toString().padLeft(2, '0')}:'
      '${s.toString().padLeft(2, '0')}';
}

Duration? _parseHms(String? value) {
  if (value == null) return null;
  final m = RegExp(r'^\s*(\d+):(\d{1,2}):(\d{1,2})(?:[.,](\d+))?\s*$')
      .firstMatch(value);
  if (m == null) return null; // "NOT_IMPLEMENTED", empty, etc.
  final h = int.parse(m.group(1)!);
  final mi = int.parse(m.group(2)!);
  final s = int.parse(m.group(3)!);
  final frac = m.group(4);
  final ms = frac == null
      ? 0
      : int.parse(frac.padRight(3, '0').substring(0, 3));
  return Duration(hours: h, minutes: mi, seconds: s, milliseconds: ms);
}
