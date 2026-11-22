import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/material.dart';

import '../cast_manager.dart';
import '../models/cast_session.dart';
import 'cast_ui.dart';

/// Sends TV-volume changes to the active cast session without flooding
/// the network: a drag produces dozens of values per second, so only the
/// latest one is sent, at most once per [interval], and the final value
/// of a gesture is always delivered (trailing send).
///
/// Works the same for every transport (Google Cast, Jellyfin Remote /
/// DLNA-UPnP, Nemesis Native) because it only goes through
/// `CastManager.setVolume`, which routes to the active session's own
/// transport. Errors (unsupported command, dropped session) are swallowed
/// on purpose — a volume tweak must never throw into the UI.
class CastVolumeSender {
  CastVolumeSender({this.interval = const Duration(milliseconds: 120)});

  final Duration interval;

  Timer? _timer;
  double? _pending;
  DateTime _lastSent = DateTime.fromMillisecondsSinceEpoch(0);

  /// Queues [volume] (0.0–1.0) to be sent.
  void send(double volume) {
    _pending = volume.clamp(0.0, 1.0).toDouble();

    if (_timer != null) return;

    final sinceLast = DateTime.now().difference(_lastSent);
    final wait = sinceLast >= interval ? Duration.zero : interval - sinceLast;

    _timer = Timer(wait, _flush);
  }

  /// Sends whatever is pending right now (e.g. when a drag ends).
  void flushNow() {
    _timer?.cancel();
    _timer = null;
    _flush();
  }

  void _flush() {
    _timer = null;

    final value = _pending;
    _pending = null;
    if (value == null) return;

    _lastSent = DateTime.now();

    CastManager.instance.setVolume(value).catchError((Object e) {
      debugPrint('[CastVolume] setVolume failed: $e');
    });
  }

  /// Delivers any last pending value, then stops.
  void dispose() {
    flushNow();
  }
}

/// Rebuilds with whether the TV's volume can currently be controlled:
/// a connected cast session whose capability includes volume.
///
/// Takes a builder (rather than being a widget that hides itself) so a
/// parent layout can add or leave out the volume button entirely —
/// otherwise a zero-width placeholder would still shift `spaceEvenly`
/// rows around while nothing is casting.
class CastVolumeAvailability extends StatefulWidget {
  const CastVolumeAvailability({super.key, required this.builder});

  final Widget Function(BuildContext context, bool available) builder;

  @override
  State<CastVolumeAvailability> createState() => _CastVolumeAvailabilityState();
}

class _CastVolumeAvailabilityState extends State<CastVolumeAvailability> {
  CastSession? _session;

  @override
  void initState() {
    super.initState();
    CastManager.instance.activeSession.addListener(_onSessionChanged);
    _attach(CastManager.instance.activeSession.value);
  }

  void _attach(CastSession? session) {
    _session?.connectionState.removeListener(_onChanged);
    _session?.capabilityNotifier.removeListener(_onChanged);
    _session = session;
    _session?.connectionState.addListener(_onChanged);
    _session?.capabilityNotifier.addListener(_onChanged);
  }

  void _onSessionChanged() {
    _attach(CastManager.instance.activeSession.value);
    _onChanged();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    CastManager.instance.activeSession.removeListener(_onSessionChanged);
    _session?.connectionState.removeListener(_onChanged);
    _session?.capabilityNotifier.removeListener(_onChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;
    final available = session != null &&
        session.isConnected &&
        session.capability.volume;

    return widget.builder(context, available);
  }
}

/// The speaker button for the casting audio player screen. Opens the TV
/// volume dialog.
class CastVolumeButton extends StatelessWidget {
  const CastVolumeButton({super.key});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: 'TV volume',
      icon: const Icon(
        Icons.volume_up,
        color: Colors.white,
      ),
      onPressed: () => showCastVolumeDialog(context),
    );
  }
}

Future<void> showCastVolumeDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (_) => const _CastVolumeDialog(),
  );
}

class _CastVolumeDialog extends StatefulWidget {
  const _CastVolumeDialog();

  @override
  State<_CastVolumeDialog> createState() => _CastVolumeDialogState();
}

class _CastVolumeDialogState extends State<_CastVolumeDialog> {
  final CastVolumeSender _sender = CastVolumeSender();

  CastSession? _session;

  // While the thumb is being dragged — and for a moment after, until the
  // TV has had time to apply the change and report it back — the slider
  // follows the finger, not the session's (possibly stale) reported
  // volume, so a late poll can't yank the thumb backwards.
  bool _useLocal = false;
  double _local = 0.5;
  Timer? _releaseTimer;

  @override
  void initState() {
    super.initState();

    final manager = CastManager.instance;
    manager.activeSession.addListener(_onSessionChanged);

    _session = manager.activeSession.value;
    _local = _session?.volume.value ?? 0.5;

    // Google Cast doesn't push the TV's current volume to us, so read it
    // when the dialog opens — otherwise the slider would start at the
    // default instead of where the TV actually is.
    unawaited(manager.syncVolume());
  }

  void _onSessionChanged() {
    if (!mounted) return;

    final session = CastManager.instance.activeSession.value;
    if (session == null || !session.isConnected) {
      // Casting ended while the dialog was open.
      Navigator.of(context).maybePop();
      return;
    }

    setState(() => _session = session);
  }

  @override
  void dispose() {
    CastManager.instance.activeSession.removeListener(_onSessionChanged);
    _releaseTimer?.cancel();
    _sender.dispose();
    super.dispose();
  }

  /// Jumps straight to [v] (0.0 or 1.0 from the end icons): moves the
  /// slider, sends it to the TV right away, and holds the local value for a
  /// moment so a stale reported volume can't snap the thumb back.
  void _jumpTo(double v) {
    _releaseTimer?.cancel();
    setState(() {
      _useLocal = true;
      _local = v;
    });
    _sender.send(v);
    _sender.flushNow();
    _releaseTimer = Timer(const Duration(milliseconds: 1500), () {
      if (!mounted) return;
      setState(() => _useLocal = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;

    return Dialog(
      backgroundColor: const Color(0xFF242424),
      insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
      // ROOT CAUSE (sharp corners): the radius was a hard-coded 4, which
      // reads as nearly square. 20 matches the "Cast to" device picker
      // sheet (device_picker_sheet.dart: Radius.circular(20)) so both
      // cast surfaces share one corner language.
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 18, 24, 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Volume',
              style: TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            if (session == null)
              const SizedBox(height: 40)
            else
              ValueListenableBuilder<double>(
                valueListenable: session.volume,
                builder: (_, reported, __) {
                  final value = (_useLocal ? _local : reported)
                      .clamp(0.0, 1.0)
                      .toDouble();

                  return Row(
                    children: [
                      IconButton(
                        tooltip: 'Mute (0%)',
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                            minWidth: 40, minHeight: 40),
                        icon: const Icon(
                          Icons.volume_mute,
                          color: Colors.white70,
                          size: 22,
                        ),
                        onPressed: () => _jumpTo(0.0),
                      ),
                      Expanded(
                        child: SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            activeTrackColor: castGold,
                            inactiveTrackColor: Colors.white24,
                            thumbColor: castGold,
                            overlayColor: castGold.withValues(alpha: 0.18),
                            trackHeight: 3,
                            // Smaller touch overlay -> shorter slider row
                            // (the default 24dp overlay radius forces a
                            // 48dp-tall row); thumb size is unchanged.
                            overlayShape: const RoundSliderOverlayShape(
                                overlayRadius: 18),
                          ),
                          child: Slider(
                            value: value,
                            min: 0,
                            max: 1,
                            onChangeStart: (_) {
                              _releaseTimer?.cancel();
                              setState(() {
                                _useLocal = true;
                                _local = value;
                              });
                            },
                            onChanged: (v) {
                              setState(() {
                                _useLocal = true;
                                _local = v;
                              });
                              _sender.send(v);
                            },
                            onChangeEnd: (v) {
                              _sender.send(v);
                              _sender.flushNow();

                              _releaseTimer?.cancel();
                              _releaseTimer = Timer(
                                const Duration(milliseconds: 1500),
                                () {
                                  if (!mounted) return;
                                  setState(() => _useLocal = false);
                                },
                              );
                            },
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Full volume (100%)',
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                            minWidth: 40, minHeight: 40),
                        icon: const Icon(
                          Icons.volume_up,
                          color: Colors.white70,
                          size: 22,
                        ),
                        onPressed: () => _jumpTo(1.0),
                      ),
                    ],
                  );
                },
              ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => Navigator.of(context).maybePop(),
                style: TextButton.styleFrom(
                  foregroundColor: castGold,
                  visualDensity: VisualDensity.compact,
                ),
                child: const Text(
                  'Dismiss',
                  style: TextStyle(
                    color: castGold,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
