import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
// NOTE: not previously a dependency of this project — add
// `connectivity_plus: ^7.3.1` (or whatever's current on pub.dev) to
// pubspec.yaml. Used for the coarse "wifi vs cellular vs offline"
// signal below; combined with the real bandwidth probe further down
// since connection *type* alone doesn't tell you much about a
// congested/far-from-the-router Wi-Fi network vs. a strong 5G one.
import 'package:connectivity_plus/connectivity_plus.dart';

import 'jellyfin_services/jellyfin_client.dart';

/// Coarse network-quality bucket driving Default mode's automatic
/// video/audio quality (see PlayerManager._autoVideoTarget/
/// _autoAudioTarget). Deliberately just four broad tiers rather than a
/// raw kbps number — quality decisions only ever need "which ladder
/// rung", and a handful of stable buckets is far less prone to
/// flapping between adjacent bitrates than reacting to every small
/// fluctuation in a continuous measurement would be.
enum NetworkTier { excellent, good, fair, poor }

/// Singleton that keeps a live best-guess of how good the network
/// currently is, from two signals:
///
///  1. `connectivity_plus`'s connection *type* (Wi-Fi/ethernet vs.
///     cellular vs. none) — cheap, instant, and a reasonable starting
///     point/floor the moment the network changes, before a real
///     measurement exists yet.
///  2. A periodic lightweight bandwidth probe against whatever
///     [setProbeUrl] was last pointed at — normally the *unconstrained*
///     static stream URL of whatever's actually playing right now
///     (see PlayerManager.playMedia), fetched with an HTTP Range
///     request for a small byte window so this never downloads a
///     meaningful amount of data on someone's metered connection just
///     to measure it.
///
/// PlayerManager also feeds this a third signal directly —
/// [reportRebuffer] — for the case a probe says "this looks fine" but
/// playback is visibly stalling anyway; real stalls are stronger
/// evidence than a point-in-time sample.
///
/// Reference-counted via [acquire]/[release] so the connectivity
/// listener + probe timer only run while something is actually
/// playing, not for the lifetime of the app.
class NetworkQualityService {
  NetworkQualityService._();

  static final NetworkQualityService instance = NetworkQualityService._();

  final ValueNotifier<NetworkTier> tier = ValueNotifier(NetworkTier.good);

  /// False until something has actually told us how the network is doing
  /// — a completed bandwidth probe, a real playback stall
  /// ([reportRebuffer]), or the OS reporting no connection. [tier]
  /// starts out as `good` purely as a placeholder, and Default mode
  /// used to act on that placeholder, opening every song as a 320kbps
  /// transcode before anything had been measured. Consumers should
  /// treat [tier] as meaningless while this is false. Reset on
  /// [release] so a new playback session never trusts a stale reading
  /// from a different network. A separate notifier (rather than just
  /// the tier) because the first real reading often equals the
  /// placeholder, and a ValueNotifier doesn't notify on an equal value.
  final ValueNotifier<bool> measured = ValueNotifier(false);

  int _refCount = 0;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  Timer? _probeTimer;
  bool _probing = false;
  String? _probeUrl;

  final List<DateTime> _recentRebuffers = [];

  /// Points the periodic bandwidth probe at a real, currently-relevant
  /// URL. Called by PlayerManager every time playback starts on a new
  /// item — passing null (or never calling this) just leaves probing
  /// paused, since there's nothing meaningful to measure against yet.
  void setProbeUrl(String? url) {
    final changed = url != _probeUrl;
    _probeUrl = url;

    // acquire() fires its "immediate" probe before PlayerManager has had
    // a chance to call this, so that probe always found no URL and
    // returned — leaving the first real measurement waiting on the
    // 25-second timer. Probe as soon as there's actually something to
    // probe, until the first reading exists.
    if (changed && url != null && _refCount > 0 && !measured.value) {
      unawaited(_probeBandwidth());
    }
  }

  void acquire() {
    _refCount++;
    if (_refCount > 1) return;

    _connectivitySub =
        Connectivity().onConnectivityChanged.listen(_onConnectivityChanged);

    Connectivity().checkConnectivity().then(_onConnectivityChanged);

    _probeTimer = Timer.periodic(
      const Duration(seconds: 25),
      (_) => _probeBandwidth(),
    );

    // Fire one probe immediately rather than waiting the full interval
    // for the first real measurement.
    unawaited(_probeBandwidth());
  }

  void release() {
    if (_refCount == 0) return;
    _refCount--;
    if (_refCount > 0) return;

    _connectivitySub?.cancel();
    _connectivitySub = null;
    _probeTimer?.cancel();
    _probeTimer = null;
    _recentRebuffers.clear();
    _probeUrl = null;
    measured.value = false;
  }

  /// Called by PlayerManager every time mpv reports a buffering
  /// (stalled/re-buffering) event during active playback. Two stalls
  /// within a short window is treated as "the current quality is too
  /// high for this connection right now" and steps the tier down a
  /// notch immediately, rather than waiting on the next scheduled
  /// probe to (maybe) notice the same thing.
  void reportRebuffer() {
    final now = DateTime.now();
    _recentRebuffers.add(now);
    _recentRebuffers.removeWhere(
      (t) => now.difference(t) > const Duration(seconds: 45),
    );

    if (_recentRebuffers.length >= 2) {
      _stepDown();
      _recentRebuffers.clear();
    }
  }

  void _stepDown() {
    measured.value = true;
    switch (tier.value) {
      case NetworkTier.excellent:
        tier.value = NetworkTier.good;
        break;
      case NetworkTier.good:
        tier.value = NetworkTier.fair;
        break;
      case NetworkTier.fair:
      case NetworkTier.poor:
        tier.value = NetworkTier.poor;
        break;
    }
  }

  void _onConnectivityChanged(List<ConnectivityResult> results) {
    if (results.isEmpty || results.contains(ConnectivityResult.none)) {
      measured.value = true;
      tier.value = NetworkTier.poor;
      return;
    }

    // Only used as an optimistic *floor* right after a network change —
    // e.g. coming back onto Wi-Fi from being offline shouldn't stay
    // stuck at "poor" until the next 25s probe happens to land. Doesn't
    // downgrade an already-good measurement just because this fired
    // again for an unrelated reason.
    final isFastType = results.contains(ConnectivityResult.wifi) ||
        results.contains(ConnectivityResult.ethernet);

    if (isFastType && tier.value == NetworkTier.poor) {
      tier.value = NetworkTier.good;
    } else if (!isFastType &&
        results.contains(ConnectivityResult.mobile) &&
        tier.value == NetworkTier.excellent) {
      // Cellular starts a notch more conservative than "excellent"
      // until a real measurement confirms it can sustain that.
      tier.value = NetworkTier.good;
    }

    // Trigger a fresh probe on every network change instead of waiting
    // out the rest of the current 25s interval — switching from Wi-Fi
    // to cellular (or between two very different Wi-Fi networks) is
    // exactly the moment a stale measurement is most likely to be
    // wrong.
    unawaited(_probeBandwidth());
  }

  Future<void> _probeBandwidth() async {
    if (_probing) return;
    final url = _probeUrl;
    if (url == null || url.isEmpty) return;
    if (JellyfinClient.serverUrl.isEmpty) return;

    _probing = true;

    try {
      final stopwatch = Stopwatch()..start();

      // A 512KB Range request is enough to get a meaningful throughput
      // sample in well under a second on anything from poor cellular to
      // gigabit Wi-Fi, without pulling down anything close to a
      // noticeable chunk of a movie file just to measure the network.
      final response = await Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 4),
          receiveTimeout: const Duration(seconds: 6),
          validateStatus: (_) => true,
        ),
      ).get<List<int>>(
        url,
        options: Options(
          responseType: ResponseType.bytes,
          headers: {"Range": "bytes=0-524287"},
        ),
      );

      stopwatch.stop();

      final bytes = response.data?.length ?? 0;
      final seconds = stopwatch.elapsedMilliseconds / 1000.0;

      if (bytes <= 0 || seconds <= 0) return;

      final kbps = (bytes * 8 / 1000) / seconds;
      measured.value = true;
      tier.value = _tierFromKbps(kbps);
    } catch (_) {
      // A single failed probe (timeout, server briefly unreachable)
      // shouldn't yank quality down on its own — leave the last known
      // tier in place. Genuine, sustained problems still get caught by
      // reportRebuffer() and by the next successful probe.
    } finally {
      _probing = false;
    }
  }

  NetworkTier _tierFromKbps(double kbps) {
    if (kbps >= 8000) return NetworkTier.excellent;
    if (kbps >= 3000) return NetworkTier.good;
    if (kbps >= 1000) return NetworkTier.fair;
    return NetworkTier.poor;
  }
}
