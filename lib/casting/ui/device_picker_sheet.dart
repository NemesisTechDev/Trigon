import 'package:flutter/material.dart';

import '../cast_manager.dart';
import '../models/cast_device.dart';
import '../models/cast_session.dart';
import '../models/cast_states.dart';
import '../../widgets/shared/nemesis_bottom_sheet.dart' show nemesisSheetSizes;
import 'cast_ui.dart';

/// Opens the unified "Cast to" device picker (Google Cast and DLNA/UPnP
/// devices, including the Trigon TV receiver).
///
/// Returns `true` if the sheet closes with an active cast session
/// (whether one was already connected, or the person just connected one),
/// `false` otherwise. Callers that want to immediately send content to
/// whatever got connected (e.g. the Movie/Show Details Cast action) should
/// check [CastManager.instance.activeSession] after this resolves.
Future<bool> showCastDevicePicker(BuildContext context) async {
  await showModalBottomSheet<void>(
    context: context,
    // Matches the rest of the app's bottom sheets (see e.g.
    // PlaylistPickerSheet/SongOptionsSheet) — required for this to render
    // above MainNavScreen's floating mini-player/tab bar rather than
    // underneath it.
    useRootNavigator: true,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => const _DevicePickerSheet(),
  );

  return CastManager.instance.isCasting;
}

class _DevicePickerSheet extends StatefulWidget {
  const _DevicePickerSheet();

  @override
  State<_DevicePickerSheet> createState() => _DevicePickerSheetState();
}

class _DevicePickerSheetState extends State<_DevicePickerSheet> {
  final _manager = CastManager.instance;

  /// The device currently mid-connect, so only its row shows a spinner
  /// rather than the whole sheet locking up while one connect attempt is
  /// in flight.
  String? _connectingId;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _manager.acquireDiscovery();
  }

  @override
  void dispose() {
    _manager.releaseDiscovery();
    super.dispose();
  }

  Future<void> _connect(CastDevice device) async {
    setState(() {
      _connectingId = device.id;
      _errorText = null;
    });

    try {
      await _manager.connect(device);
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _connectingId = null;
        _errorText = 'Couldn\'t connect to ${device.displayName}.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    // Landscape: opens at most 2/3 of the screen, draggable to full.
    final sizes = nemesisSheetSizes(
      context,
      initial: 0.55,
      min: 0.3,
      max: 0.85,
    );

    return DraggableScrollableSheet(
      initialChildSize: sizes.initial,
      minChildSize: sizes.min,
      maxChildSize: sizes.max,
      expand: false,
      builder: (context, scrollController) {
        return Container(
          decoration: const BoxDecoration(
            color: castSheetBg,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(
            children: [
              const SizedBox(height: 10),
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 16, 20, 4),
                child: Row(
                  children: [
                    Icon(Icons.cast_rounded, color: castGold, size: 20),
                    SizedBox(width: 10),
                    Text(
                      'Cast to',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
              if (_errorText != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
                  child: Text(
                    _errorText!,
                    style: const TextStyle(color: Colors.redAccent, fontSize: 13),
                  ),
                ),
              Expanded(
                child: ValueListenableBuilder<List<CastDevice>>(
                  valueListenable: _manager.devices,
                  builder: (context, devices, __) {
                    if (devices.isEmpty) {
                      return _buildSearching(scrollController);
                    }

                    return ValueListenableBuilder<CastSession?>(
                      valueListenable: _manager.activeSession,
                      builder: (context, session, __) {
                        return ListView.builder(
                          controller: scrollController,
                          padding: EdgeInsets.fromLTRB(12, 8, 12, 16 + bottomInset),
                          // +1: a live "still looking" footer. Discovery
                          // keeps running (and the list keeps updating in
                          // real time through `_manager.devices`) for as
                          // long as this sheet is open, but once the
                          // first device showed up the full-sheet
                          // "Searching…" state vanished, so a list that
                          // was still growing (slower DLNA/UPnP renderers
                          // answer after the quicker Google Cast ones)
                          // looked finished and complete.
                          itemCount: devices.length + 1,
                          itemBuilder: (context, index) {
                            if (index == devices.length) {
                              return _buildSearchingFooter();
                            }

                            final device = devices[index];
                            final isConnectedHere = session != null &&
                                session.device.id == device.id &&
                                session.isConnected;

                            return _DeviceRow(
                              // Stable identity as devices emerge/leave
                              // while the sheet is open, so rows keep
                              // their own state instead of shifting onto
                              // whichever device now sits at that index.
                              key: ValueKey(device.id),
                              device: device,
                              connecting: _connectingId == device.id,
                              connected: isConnectedHere,
                              // Casting Phase 9: lands D-pad focus on
                              // the first row the instant this sheet
                              // opens, instead of leaving an Android TV
                              // remote's first press to Flutter's
                              // nearest-neighbor guess (which, for a
                              // sheet with nothing focused yet, isn't
                              // guaranteed to be inside the sheet at
                              // all). Only the very first item in the
                              // list gets it — `devices` is rebuilt in
                              // place as discovery finds/loses devices,
                              // not reordered out from under an
                              // already-focused row, so this doesn't
                              // fight a person who's already navigated
                              // further down the list.
                              autofocus: index == 0,
                              onTap: () => _connect(device),
                            );
                          },
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSearchingFooter() {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 14),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2, color: castGold),
          ),
          SizedBox(width: 10),
          Text(
            'Looking for more devices…',
            style: TextStyle(color: Colors.white38, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _buildSearching(ScrollController controller) {
    // Still needs to be scrollable (even with nothing worth scrolling)
    // so DraggableScrollableSheet's own drag handling keeps working while
    // no devices have been found yet.
    return ListView(
      controller: controller,
      padding: const EdgeInsets.symmetric(vertical: 48),
      children: const [
        Center(
          child: SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(strokeWidth: 2.4, color: castGold),
          ),
        ),
        SizedBox(height: 16),
        Center(
          child: Text(
            'Searching for devices…',
            style: TextStyle(color: Colors.white60),
          ),
        ),
        SizedBox(height: 6),
        Center(
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 40),
            child: Text(
              'Make sure your TV or Chromecast is on the same Wi-Fi network.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white38, fontSize: 12),
            ),
          ),
        ),
      ],
    );
  }
}

class _DeviceRow extends StatelessWidget {
  final CastDevice device;
  final bool connecting;
  final bool connected;
  final VoidCallback onTap;
  final VoidCallback? onForget;
  final bool autofocus;

  const _DeviceRow({
    super.key,
    required this.device,
    required this.connecting,
    required this.connected,
    required this.onTap,
    this.onForget,
    this.autofocus = false,
  });

  /// Casting Phase 12: appends the signed-in Jellyfin account to the
  /// existing room/client-name subtitle, when the device actually has
  /// one to report — see `CastDevice.userName`'s doc comment for which
  /// transports that is. A not-yet-paired Nemesis Native TV (nothing to
  /// report until pairing resolves an account) and every Google Cast
  /// device fall straight through to the original two options unchanged.
  String _subtitleFor(CastDevice device, {required bool connected}) {
    if (connected) return 'Connected';

    final base = device.isNemesisReceiver
        ? 'Trigon TV'
        : castVisibleLabel(device.roomOrGroup) ??
            castTransportLabel(device.preferredTransport);
    final userName = device.userName;
    return userName != null ? '$base · $userName' : base;
  }

  @override
  Widget build(BuildContext context) {
    final primaryIcon = device.isNemesisReceiver
        ? Icons.live_tv_rounded
        : castTransportIcon(device.preferredTransport);

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: castRowBg,
        borderRadius: BorderRadius.circular(14),
        border: connected
            ? Border.all(color: castGold.withOpacity(.6), width: 1)
            : null,
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          autofocus: autofocus,
          onTap: connecting ? null : onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: Colors.black38,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(primaryIcon, color: Colors.white70, size: 20),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            device.displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Text(
                            _subtitleFor(device, connected: connected),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: connected ? castGold : Colors.white54,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (connecting)
                      const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: castGold,
                        ),
                      )
                    else if (connected)
                      const Icon(Icons.check_circle, color: castGold, size: 20)
                    else if (onForget != null)
                      IconButton(
                        icon: const Icon(Icons.link_off, size: 18, color: Colors.white38),
                        tooltip: 'Forget this TV',
                        onPressed: onForget,
                      )
                    else
                      const Icon(Icons.chevron_right, color: Colors.white24),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
