import 'package:flutter/material.dart';

import '../player_manager.dart';
import '../../widgets/shared/nemesis_bottom_sheet.dart';

/// The in-player Quality selector for Movies, TV Shows, and Live TV.
///
/// Options come from `PlayerManager.videoQualityOptions` — always
/// headed by "Auto", followed by whichever of the 1080p/720p/480p/360p
/// ladder actually fits the source's own resolution (see
/// `PlayerManager._recomputeVideoQualityOptions`; Jellyfin isn't asked
/// to upscale a lower-resolution source). Picking a specific resolution
/// asks Jellyfin to transcode down to it (`MediaService.
/// getVideoStreamUrl`) and reopens the stream at the current position —
/// not from 0:00 — so it never feels like restarting the title.
/// Picking "Auto" hands control back to whatever the Settings screen's
/// Data Usage mode (Data Saver / Default / Max Quality) resolves to,
/// including Default mode's own live network-based switching.
///
/// This selector only ever appears for video — per spec, Music
/// deliberately has no manual quality control at all, only automatic
/// adaptive switching (see PlayerManager._autoAudioTarget).
class VideoQualitySheet extends StatelessWidget {
  const VideoQualitySheet({super.key, this.scrollController});

  final ScrollController? scrollController;

  @override
  Widget build(BuildContext context) {
    final manager = PlayerManager.instance;

    return Material(
      type: MaterialType.transparency,
      child: ValueListenableBuilder<List<String>>(
          valueListenable: manager.videoQualityOptions,
          builder: (_, options, __) {
            final effectiveOptions =
                options.isEmpty ? const ["Auto"] : options;

            return ValueListenableBuilder<String>(
              valueListenable: manager.videoQuality,
              builder: (_, selected, __) {
                return ListView(
                  controller: scrollController,
                  children: [
                    const NemesisSheetDragHandle(topMargin: 10, bottomMargin: 4),
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text(
                        "Video Quality",
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),

                    const Divider(),

                    ...effectiveOptions.map(
                      (label) {
                        final active = selected == label;

                        return ListTile(
                          leading: active
                              ? const Icon(
                                  Icons.check,
                                  color: Colors.green,
                                )
                              : const SizedBox(width: 24),
                          title: Text(
                            label,
                            style: const TextStyle(
                              color: Colors.white,
                            ),
                          ),
                          subtitle: label == "Auto"
                              ? const Text(
                                  "Matches your Data Usage setting",
                                  style: TextStyle(
                                    color: Colors.white54,
                                    fontSize: 12,
                                  ),
                                )
                              : null,
                          onTap: () {
                            manager.setVideoQuality(label);
                            Navigator.pop(context);
                          },
                        );
                      },
                    ),
                  ],
                );
              },
            );
          },
        ),
      );
  }
}
