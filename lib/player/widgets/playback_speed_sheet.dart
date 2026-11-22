import 'package:flutter/material.dart';
import '../../player/player_manager.dart';
import '../../casting/cast_manager.dart';
import '../../casting/ui/cast_ui.dart';
import '../../widgets/shared/nemesis_bottom_sheet.dart';

class PlaybackSpeedSheet extends StatelessWidget {
  const PlaybackSpeedSheet({super.key, this.scrollController});

  final ScrollController? scrollController;

  static const List<double> speeds = [
    0.25,
    0.5,
    0.75,
    1.0,
    1.25,
    1.5,
    1.75,
    2.0,
  ];

  @override
  Widget build(BuildContext context) {
    final player = PlayerManager.instance.player;

    // Casting fix: while casting, changing speed needs to reach the TV
    // via CastManager.setPlaybackRate, not the paused local player —
    // same reasoning AudioSelector/SubtitleSheet already follow for
    // their own controls. Only Google Cast and Nemesis Native actually
    // support this (see CastCapability.playbackRate's own doc comment);
    // this button is expected to already be greyed out by
    // PlayerBottomBar for a Jellyfin Remote session, so reaching this
    // sheet at all while casting implies the connected session supports
    // it.
    final castSession = CastManager.instance.activeSession.value;
    final casting = castSession?.isConnected ?? false;

    return ListView(
          controller: scrollController,
          children: [
            const NemesisSheetDragHandle(topMargin: 10, bottomMargin: 4),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                "Playback Speed",
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            casting
                ? ValueListenableBuilder<double>(
                    valueListenable: castSession!.playbackRateNotifier,
                    builder: (_, currentSpeed, __) {
                      return _buildList(
                        context,
                        currentSpeed: currentSpeed,
                        onSelect: (speed) => runCastCommand(
                          context,
                          () => CastManager.instance.setPlaybackRate(speed),
                        ),
                      );
                    },
                  )
                : ValueListenableBuilder<double>(
                    valueListenable: PlayerManager.instance.playbackSpeed,
                    builder: (_, currentSpeed, __) {
                      return _buildList(
                        context,
                        currentSpeed: currentSpeed,
                        onSelect: (speed) async {
                          await player.setRate(speed);
                          PlayerManager.instance.playbackSpeed.value = speed;
                        },
                      );
                    },
                  ),
          ],
    );
  }

  Widget _buildList(
    BuildContext context, {
    required double currentSpeed,
    required Future<void> Function(double speed) onSelect,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: speeds.map((speed) {
        return ListTile(
          leading: currentSpeed == speed
              ? const Icon(
                  Icons.check,
                  color: Colors.green,
                )
              : null,
          title: Text(
            "${speed}x",
            style: const TextStyle(
              color: Colors.white,
            ),
          ),
          onTap: () async {
            await onSelect(speed);
            if (context.mounted) Navigator.pop(context);
          },
        );
      }).toList(),
    );
  }
}