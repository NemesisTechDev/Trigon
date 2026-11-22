import 'package:flutter/material.dart';

import '../cast_manager.dart';
import '../models/cast_session.dart';
import '../models/cast_states.dart';
import 'cast_ui.dart';
import 'connected_session_sheet.dart';
import 'device_picker_sheet.dart';

/// The one Cast control every surface (player top bar, home app bar,
/// landscape sidebar, movie/show details) shows — per the master
/// prompt's "use ONE unified Cast control" rule. Tapping it opens the
/// device picker when nothing is connected, or the connected-session
/// sheet when something already is; it never casts anything itself.
///
/// Deliberately icon-only with no built-in container/background — call
/// sites wrap this in whatever chrome matches their surface (a plain
/// IconButton in the player top bar, `_circleIcon`'s dark circle on
/// Home, a `_RailActionButton`-style column in the landscape sidebar),
/// matching how every other icon in those surfaces is already styled
/// rather than this widget imposing its own look everywhere it appears.
class CastButton extends StatefulWidget {
  final double iconSize;
  final Color color;
  final Color activeColor;

  const CastButton({
    super.key,
    this.iconSize = 24,
    this.color = Colors.white,
    this.activeColor = castGold,
  });

  @override
  State<CastButton> createState() => _CastButtonState();
}

class _CastButtonState extends State<CastButton> {
  double get iconSize => widget.iconSize;
  Color get color => widget.color;
  Color get activeColor => widget.activeColor;

  @override
  void initState() {
    super.initState();
    // Start the device scan now, so the list is ready when this is tapped.
    CastManager.instance.prewarmDiscovery();
  }

  Future<void> _handleTap(BuildContext context) async {
    if (CastManager.instance.isCasting) {
      await showConnectedCastSheet(context);
    } else {
      await showCastDevicePicker(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<CastSession?>(
      valueListenable: CastManager.instance.activeSession,
      builder: (context, session, _) {
        final connecting = session != null &&
            session.connectionState.value == CastConnectionState.connecting;
        final connected = session?.isConnected ?? false;

        return IconButton(
          iconSize: iconSize,
          // `connected` being true implies `session` is non-null (it's
          // derived from `session?.isConnected`), but the analyzer can't
          // follow that through a separate bool variable — `session?.`
          // here is just a null-safe read, not a real behavior change,
          // since `connected` is already false whenever `session` is null.
          tooltip: connected ? 'Casting to ${session?.device.displayName}' : 'Cast',
          onPressed: () => _handleTap(context),
          icon: Stack(
            clipBehavior: Clip.none,
            children: [
              Icon(
                connected ? Icons.cast_connected_rounded : Icons.cast_rounded,
                size: iconSize,
                color: connected ? activeColor : color,
              ),
              if (connecting)
                Positioned(
                  right: -2,
                  top: -2,
                  child: SizedBox(
                    width: iconSize * 0.4,
                    height: iconSize * 0.4,
                    child: const CircularProgressIndicator(
                      strokeWidth: 1.6,
                      color: castGold,
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
