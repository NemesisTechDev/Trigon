import 'dart:async';

import 'package:flutter/material.dart';

import '../models/audio_track.dart';
import '../player_manager.dart';
import '../../casting/cast_manager.dart';
import '../../casting/local_cast_format.dart'
    show LocalCastUnsupportedException;
import '../../casting/playback_coordinator.dart';
import '../../casting/ui/cast_ui.dart';
import '../../widgets/shared/nemesis_bottom_sheet.dart';

class AudioSelector extends StatelessWidget {
  final List<AudioTrack> audioTracks;
  final ScrollController? scrollController;

  const AudioSelector({
    super.key,
    required this.audioTracks,
    this.scrollController,
  });

  @override
  Widget build(BuildContext context) {
    final manager = PlayerManager.instance;

    // Casting fix (Phase 14): while this item is handed off to a TV,
    // switching tracks has to reach the session, not the paused local
    // player — CastManager.selectAudioTrack is the same capability-
    // gated pass-through every other cast command already goes through.
    //
    // Checkmark fix: this used to always read `manager.selectedAudio`
    // (local player state) for the checkmark, even while casting — the
    // same bug SubtitleSheet had and fixed for the identical reason.
    // Every transport actually does keep the real selection current on
    // `session.activeAudioTrackId` (see CastSession.activeAudioTrackId's
    // own doc comment and each transport's selectAudioTrack/_applyState),
    // so the checkmark now reads that instead while casting — and stays
    // live if a *different* device changes the audio track on a shared
    // TV session.
    final castSession = CastManager.instance.activeSession.value;
    final casting = castSession?.isConnected ?? false;

    // LOCAL VIDEO CAST (Open With/Play With over Google Cast): the TV's
    // audio is switched by remuxing the chosen track and reloading the TV
    // at the current position (PlaybackCoordinator.switchLocalCastAudio),
    // which can take a while for a big file — so the sheet closes right
    // away instead of hanging open, and the switch finishes in the
    // background. No progress notice is shown; only a failure is
    // reported. Selection is mirrored into the phone's own player, so
    // the checkmark reads manager.selectedAudio like local playback does.
    final localCast =
        casting && PlaybackCoordinator.instance.isLocalVideoCast;

    // CHECKMARK FALLBACK (cast branch only): the session's
    // `activeAudioTrackId` is null until a transport has reported or been
    // told which audio stream the TV is on — which used to mean no row was
    // ticked at all until one was tapped. Until it says otherwise the TV is
    // on the file's default stream (the one flagged default, else the
    // first), so that's what is ticked.
    final int? fallbackAudioIndex = audioTracks.isEmpty
        ? null
        : audioTracks
            .firstWhere((t) => t.isDefault, orElse: () => audioTracks.first)
            .index;

    return ListView(
        controller: scrollController,
        children: [

          const NemesisSheetDragHandle(topMargin: 10, bottomMargin: 12),

          const Text(
            "Audio",
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 20,
            ),
            textAlign: TextAlign.center,
          ),

          const Divider(),

          ...audioTracks.map(
                (track) => localCast
                ? ValueListenableBuilder<AudioTrack?>(
              valueListenable: manager.selectedAudio,
              builder: (_, current, __) {

                final selected = current?.index == track.index;

                return ListTile(
                  leading: Icon(
                    selected
                        ? Icons.check_circle
                        : Icons.music_note,
                  ),

                  title: Text(track.displayTitle),

                  subtitle: Text(track.language),

                  onTap: () {
                    final messenger = ScaffoldMessenger.maybeOf(context);
                    Navigator.pop(context);

                    unawaited(
                      PlaybackCoordinator.instance
                          .switchLocalCastAudio(track)
                          .catchError((Object e) {
                        debugPrint('LOCAL CAST AUDIO: switch failed: $e');
                        messenger?.hideCurrentSnackBar();
                        messenger?.showSnackBar(
                          SnackBar(
                            behavior: SnackBarBehavior.floating,
                            content: Text(
                              e is LocalCastUnsupportedException
                                  ? e.message
                                  : 'Couldn\'t switch the audio track on the TV.',
                            ),
                          ),
                        );
                      }),
                    );
                  },
                );
              },
            )
                : casting
                ? ValueListenableBuilder<int?>(
              valueListenable: castSession!.activeAudioTrackId,
              builder: (_, activeIndex, __) {

                final selected =
                    (activeIndex ?? fallbackAudioIndex) == track.index;

                return ListTile(
                  leading: Icon(
                    selected
                        ? Icons.check_circle
                        : Icons.music_note,
                  ),

                  title: Text(track.displayTitle),

                  subtitle: Text(track.language),

                  onTap: () {
                    // Close at once and let the TV reload finish in the
                    // background (same as the Open With branch above):
                    // the sheet used to stay open until the receiver
                    // acknowledged the reload, and the movie kept playing
                    // the old track meanwhile.
                    final messenger = ScaffoldMessenger.maybeOf(context);
                    Navigator.pop(context);

                    unawaited(
                      CastManager.instance
                          .selectAudioTrack(track.index)
                          .catchError((Object e) {
                        messenger?.hideCurrentSnackBar();
                        messenger?.showSnackBar(
                          SnackBar(
                            behavior: SnackBarBehavior.floating,
                            content: Text(
                              'Couldn\'t switch the audio track on the TV.',
                            ),
                          ),
                        );
                      }),
                    );
                  },
                );
              },
            )
                : ValueListenableBuilder<AudioTrack?>(
              valueListenable: manager.selectedAudio,
              builder: (_, current, __) {

                final selected = current?.index == track.index;

                return ListTile(
                  leading: Icon(
                    selected
                        ? Icons.check_circle
                        : Icons.music_note,
                  ),

                  title: Text(track.displayTitle),

                  subtitle: Text(track.language),

                  onTap: () async {
                    await manager.selectAudioTrack(track);

                    if (context.mounted) Navigator.pop(context);
                  },
                );
              },
            ),
          ),
          const SizedBox(height: 20),
        ],
      );
  }
}
