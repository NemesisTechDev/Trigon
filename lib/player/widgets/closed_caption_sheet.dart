import 'package:flutter/material.dart';

import '../../casting/cast_manager.dart';
import '../../casting/models/cast_session.dart';
import '../../widgets/shared/nemesis_bottom_sheet.dart';
import '../player_manager.dart';

/// Live TV "Subtitles" sheet: just two choices — Off, or the channel's
/// closed captions (the CEA-608/708 captions broadcast inside the stream,
/// typical for films and shows on TV channels).
///
/// On the phone the captions are decoded by the player and drawn by the
/// normal subtitle overlay. While casting, the choice is sent to the TV
/// through the connected transport — only where that transport can really
/// switch captions; otherwise the row says so instead of pretending.
class ClosedCaptionSheet extends StatelessWidget {
  const ClosedCaptionSheet({super.key, this.scrollController});

  final ScrollController? scrollController;

  @override
  Widget build(BuildContext context) {
    final session = CastManager.instance.activeSession.value;
    final casting = session?.isConnected ?? false;

    if (casting) {
      return ValueListenableBuilder<bool>(
        valueListenable: session!.closedCaptionsOn,
        builder: (_, on, __) => _list(
          context,
          on: on,
          castSession: session,
          castSupported: CastManager.instance.closedCaptionsSupported,
        ),
      );
    }

    return ValueListenableBuilder<bool>(
      valueListenable: PlayerManager.instance.closedCaptionsOn,
      builder: (_, on, __) => _list(context, on: on),
    );
  }

  Future<void> _choose(
    BuildContext context,
    bool wantOn, {
    CastSession? castSession,
  }) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      if (castSession != null) {
        await CastManager.instance.setClosedCaptions(wantOn);
      } else {
        await PlayerManager.instance.setClosedCaptions(wantOn);
      }
    } catch (_) {
      messenger?.hideCurrentSnackBar();
      messenger?.showSnackBar(
        const SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text('Couldn\'t change the closed captions.'),
        ),
      );
      return;
    }
    if (context.mounted) Navigator.pop(context);
  }

  Widget _list(
    BuildContext context, {
    required bool on,
    CastSession? castSession,
    bool castSupported = true,
  }) {
    final canTurnOn = castSession == null || castSupported;

    return ListView(
      controller: scrollController,
      children: [
        const NemesisSheetDragHandle(topMargin: 10, bottomMargin: 4),
        const Padding(
          padding: EdgeInsets.all(16),
          child: Text(
            'Subtitles',
            style: TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        ListTile(
          leading: !on ? const Icon(Icons.check, color: Colors.green) : null,
          title: const Text('Off', style: TextStyle(color: Colors.white)),
          onTap: () async {
            // Off while the TV can't be controlled has nothing to send.
            if (castSession != null && !castSupported && !on) {
              Navigator.pop(context);
              return;
            }
            await _choose(context, false, castSession: castSession);
          },
        ),
        const Divider(),
        ListTile(
          enabled: canTurnOn,
          leading: on ? const Icon(Icons.check, color: Colors.green) : null,
          title: Text(
            'Closed caption',
            style: TextStyle(
              color: canTurnOn ? Colors.white : Colors.white38,
            ),
          ),
          subtitle: Text(
            canTurnOn
                ? 'Shows the captions broadcast with this channel, when it has any.'
                : 'This connection can\'t switch the TV\'s captions from the phone.',
            style: TextStyle(
              color: canTurnOn ? Colors.white54 : Colors.white30,
              fontSize: 12,
            ),
          ),
          onTap: canTurnOn
              ? () => _choose(context, true, castSession: castSession)
              : null,
        ),
        const SizedBox(height: 12),
      ],
    );
  }
}
