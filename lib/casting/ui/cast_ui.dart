import 'package:flutter/material.dart';

import '../models/cast_device.dart';
import '../models/cast_states.dart';
import '../transports/cast_transport.dart' show UnsupportedCastCommand;

/// Shared visual language for the casting UI (Phase 7). Kept in one file
/// so the Cast button, device picker, and connected-session sheet don't
/// each invent their own copy of "what do we call a Google Cast device"
/// or "what color means connected".
const Color castGold = Color(0xFFD4AF37);
const Color castSheetBg = Color(0xFF1A1A1A);
const Color castRowBg = Color(0xFF232323);

/// Per the master prompt's "user should not need to understand the
/// underlying protocols" rule, these labels describe what the target
/// *is* (a TV, a Chromecast) rather than naming our own transport
/// classes — CastTransportKind itself stays an implementation detail
/// even here, only ever shown as a small caption under a device name
/// when a device offers more than one way to reach it.
String castTransportLabel(CastTransportKind kind) {
  switch (kind) {
    case CastTransportKind.googleCast:
      return 'Chromecast';
    case CastTransportKind.dlna:
      return 'Smart TV (DLNA)';
  }
}

/// Returns [label] unless it names Jellyfin for anything other than the
/// Jellyfin Android TV or Jellyfin Web receivers, in which case it returns
/// null so the caller falls back to a neutral label. Labels that don't
/// mention Jellyfin at all (e.g. "DLNA", "Kodi", a TV's make/model) pass
/// through unchanged.
String? castVisibleLabel(String? label) {
  final text = label?.trim();
  if (text == null || text.isEmpty) return null;

  final lower = text.toLowerCase();
  if (!lower.contains('jellyfin')) return text;

  final isAndroidTv = RegExp(r'android\s*tv').hasMatch(lower);
  final isWeb = RegExp(r'\bweb\b').hasMatch(lower);
  return (isAndroidTv || isWeb) ? text : null;
}

/// What to call the way [device] is being reached, for the small caption
/// next to a connected device: the Jellyfin Android TV / Jellyfin Web
/// client name, or the receiver's own client name (e.g. "DLNA"), never a
/// bare "Jellyfin".
String castDeviceTypeLabel(CastDevice device, CastTransportKind kind) {
  if (device.isNemesisReceiver) return 'Trigon TV';
  return castTransportLabel(kind);
}

IconData castTransportIcon(CastTransportKind kind) {
  switch (kind) {
    case CastTransportKind.googleCast:
      return Icons.cast_rounded;
    case CastTransportKind.dlna:
      return Icons.tv_rounded;
  }
}

/// Short caption for a [CastConnectionState] — used under a device row
/// while connecting, and in the connected-session sheet's header.
String castConnectionLabel(CastConnectionState state) {
  switch (state) {
    case CastConnectionState.disconnected:
      return 'Disconnected';
    case CastConnectionState.discovering:
      return 'Searching…';
    case CastConnectionState.connecting:
      return 'Connecting…';
    case CastConnectionState.connected:
      return 'Connected';
    case CastConnectionState.error:
      return 'Couldn\'t connect';
  }
}

String castPlaybackLabel(CastPlaybackState state) {
  switch (state) {
    case CastPlaybackState.idle:
      return 'Ready';
    case CastPlaybackState.loading:
      return 'Loading…';
    case CastPlaybackState.playing:
      return 'Playing';
    case CastPlaybackState.paused:
      return 'Paused';
    case CastPlaybackState.buffering:
      return 'Buffering…';
    case CastPlaybackState.stopped:
      return 'Stopped';
    case CastPlaybackState.ended:
      return 'Finished';
    case CastPlaybackState.error:
      return 'Error';
  }
}

/// PHASE 10 HARDENING. Runs a CastManager playback command (play, pause,
/// seek, next, previous, ...) fired from a button/slider `onPressed`/
/// `onChanged`, and surfaces a failure via a SnackBar instead of letting
/// it become a silent, unhandled Future rejection.
///
/// Every command button already only appears when `CastCapability` says
/// the connected target supports it, so `UnsupportedCastCommand` should
/// never actually fire in normal use — but that gating can't stop a
/// *supported* command from failing for a real-world reason: the target
/// went unreachable between this frame and the tap, a transient network
/// drop, the receiver rejecting the value. Those are exactly the
/// "Timeout" / "Server unavailable" / "Receiver error" failure cases the
/// master prompt's Phase 10 objective names — until this, they failed
/// with the button visibly doing nothing and the thrown exception going
/// nowhere any person could see it (an `IconButton.onPressed`/
/// `Slider.onChanged` is `void Function()`, so `manager.togglePlayPause`
/// etc. being passed directly meant their returned Future — and any
/// error on it — was simply discarded).
Future<void> runCastCommand(
  BuildContext context,
  Future<void> Function() command,
) async {
  try {
    await command();
  } catch (e) {
    if (!context.mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;

    final message = e is UnsupportedCastCommand
        ? (e.command == 'seek'
            ? 'This TV can\'t jump to a position in this item.'
            : 'That control isn\'t supported on this device.')
        : 'That didn\'t reach the device — it may be unreachable.';

    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(behavior: SnackBarBehavior.floating, content: Text(message)),
    );
  }
}

/// mm:ss / h:mm:ss formatting for the connected-session sheet's position/
/// duration row — deliberately not reusing a player-screen formatter, to
/// keep this UI decoupled from PlayerManager per the master prompt's
/// "UI must not directly depend on..." architecture rule extended to our
/// own local playback code, not just the three transports' native APIs.
String formatCastDuration(Duration d) {
  if (d.isNegative) return '0:00';
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  final s = d.inSeconds.remainder(60);
  final mm = m.toString().padLeft(h > 0 ? 2 : 1, '0');
  final ss = s.toString().padLeft(2, '0');
  return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
}
