import 'dart:io';

import 'package:flutter/material.dart';

import '../../player/models/media_item.dart';
import '../../utils/artwork_source.dart';
import '../cast_manager.dart';
import '../models/cast_capability.dart';
import '../models/cast_session.dart';
import '../models/cast_states.dart';
import '../../widgets/shared/nemesis_bottom_sheet.dart';
import 'cast_seek_bar.dart';
import 'cast_transport_controls.dart';
import 'cast_ui.dart';
import 'device_picker_sheet.dart';

/// Opens the connected-session sheet for whatever [CastManager] currently
/// has active. Callers should already know a session exists (the Cast
/// button only routes here when `CastManager.instance.isCasting`); if the
/// session disappears out from under this sheet (TV lost, disconnected
/// elsewhere) it just closes itself rather than showing a stale/empty
/// state.
Future<void> showConnectedCastSheet(BuildContext context) {
  // Same chrome as the video player's Info sheet (see
  // showNemesisBottomSheet's doc comment) — rounded top corners, drag
  // handle, drag up/down to resize, tap-outside/back-gesture/drag-down
  // to close. This sheet's content is compact (header, now-casting
  // row, transport controls, two buttons), so a smaller initial/max
  // fraction than the player's Info sheet keeps it from opening with a
  // lot of empty space underneath.
  return showNemesisBottomSheet<void>(
    context,
    initialChildSize: 0.45,
    minChildSize: 0.25,
    maxChildSize: 0.8,
    builder: (_, scrollController) =>
        _ConnectedSessionSheet(scrollController: scrollController),
  );
}

class _ConnectedSessionSheet extends StatelessWidget {
  const _ConnectedSessionSheet({required this.scrollController});

  final ScrollController scrollController;

  @override
  Widget build(BuildContext context) {
    final manager = CastManager.instance;

    return ValueListenableBuilder<CastSession?>(
      valueListenable: manager.activeSession,
      builder: (context, session, __) {
        if (session == null) {
          // The session ended (disconnected/TV disappeared) while this
          // sheet was open — close rather than render nothing useful.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (Navigator.of(context, rootNavigator: true).canPop()) {
              Navigator.of(context, rootNavigator: true).pop();
            }
          });
          return const SizedBox.shrink();
        }

        return SingleChildScrollView(
          controller: scrollController,
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const NemesisSheetDragHandle(),
                _buildHeader(context, session),
                const SizedBox(height: 20),
                _buildNowCasting(session),
                const SizedBox(height: 20),
                ValueListenableBuilder<CastCapability>(
                  valueListenable: session.capabilityNotifier,
                  builder: (context, capability, __) =>
                      _buildControls(context, manager, session, capability),
                ),
                const SizedBox(height: 20),
                // RESPONSIVE ACTIONS: both buttons scale with the sheet's
                // width (padding, icon and text size), and the label is
                // always a single row — a larger system font or a narrow
                // display shrinks it to fit instead of wrapping.
                LayoutBuilder(
                  builder: (context, constraints) {
                    final scale =
                        (constraints.maxWidth / 360).clamp(0.8, 1.4);
                    return Row(
                      children: [
                        Expanded(
                          child: _SessionActionButton(
                            scale: scale,
                            label: 'Switch device',
                            icon: Icons.swap_horiz,
                            color: Colors.white,
                            borderColor: Colors.white.withOpacity(.2),
                            onPressed: () async {
                              Navigator.of(context, rootNavigator: true).pop();
                              await showCastDevicePicker(context);
                            },
                          ),
                        ),
                        SizedBox(width: 12 * scale),
                        Expanded(
                          child: _SessionActionButton(
                            scale: scale,
                            label: 'Disconnect',
                            icon: Icons.cast_connected,
                            color: Colors.redAccent,
                            borderColor: Colors.redAccent,
                            onPressed: () async {
                              await manager.disconnect();
                              if (context.mounted) {
                                Navigator.of(context, rootNavigator: true)
                                    .pop();
                              }
                            },
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ],
            ),
          );
      },
    );
  }

  Widget _buildHeader(BuildContext context, CastSession session) {
    return Row(
      children: [
        Icon(castTransportIcon(session.transportKind), color: castGold, size: 22),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                session.device.displayName,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 17,
                  fontWeight: FontWeight.bold,
                ),
              ),
              ValueListenableBuilder<CastConnectionState>(
                valueListenable: session.connectionState,
                builder: (context, state, __) {
                  // Casting Phase 12: append the signed-in Jellyfin
                  // account for the two transports that actually have
                  // one of their own (Jellyfin Remote/Nemesis Native —
                  // see CastDevice.userName's doc comment). Google Cast
                  // devices, and any session whose transport didn't
                  // report a username, just keep the original two-part
                  // caption.
                  final userName = session.device.userName;
                  final caption = [
                    castDeviceTypeLabel(session.device, session.transportKind),
                    castConnectionLabel(state),
                    if (userName != null) 'as $userName',
                  ].join(' · ');
                  return Text(
                    caption,
                    style:
                        const TextStyle(color: Colors.white54, fontSize: 12),
                  );
                },
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildNowCasting(CastSession session) {
    return ValueListenableBuilder<MediaItem?>(
      valueListenable: session.currentItem,
      builder: (context, item, __) {
        if (item == null) {
          return const Text(
            'Nothing playing yet.',
            style: TextStyle(color: Colors.white38),
          );
        }

        return Row(
          children: [
            _NowCastingThumbnail(item: item),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (item.subtitle.isNotEmpty)
                    Text(
                      item.subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white54, fontSize: 12),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildControls(
    BuildContext context,
    CastManager manager,
    CastSession session,
    CastCapability capability,
  ) {
    return Column(
      children: [
        // SEEK-THUMBNAIL SCOPE FIX: trickplay scrub preview is scoped to
        // CastingActivePanel's fullscreen casting video player screen —
        // see CastSeekBar's own class doc comment. This sheet only shows
        // the slider and position/duration labels.
        CastSeekBar(
          session: session,
          capability: capability,
          enableTrickplayPreview: false,
        ),
        const SizedBox(height: 6),
        CastTransportControls(
          session: session,
          capability: capability,
          fullscreen: false,
        ),
      ],
    );
  }
}

/// Outlined pill button used by the connected-session sheet's Switch device /
/// Disconnect row. Everything scales with [scale] (derived from the sheet's
/// width) and the label is forced onto one line: [FittedBox] shrinks icon +
/// text together when the text is larger than the space, so it never wraps.
class _SessionActionButton extends StatelessWidget {
  const _SessionActionButton({
    required this.scale,
    required this.label,
    required this.icon,
    required this.color,
    required this.borderColor,
    required this.onPressed,
  });

  final double scale;
  final String label;
  final IconData icon;
  final Color color;
  final Color borderColor;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        foregroundColor: color,
        side: BorderSide(color: borderColor),
        minimumSize: Size(0, 44 * scale),
        padding: EdgeInsets.symmetric(
          horizontal: 12 * scale,
          vertical: 10 * scale,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24 * scale),
        ),
      ),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18 * scale),
            SizedBox(width: 8 * scale),
            Text(
              label,
              maxLines: 1,
              softWrap: false,
              style: TextStyle(fontSize: 14 * scale),
            ),
          ],
        ),
      ),
    );
  }
}

/// Same poster-shaped/bare-logo treatment as MiniPlayer's `_Artwork` and
/// CastingMediaCard's `_Thumbnail` — a movie/show poster (not a squared
/// crop) for movies/episodes, the channel's own logo sitting directly on
/// this sheet's background (no card behind it) for live channels.
///
/// CASTING FIX (songs showed a squashed/cropped movie poster in this
/// sheet): unlike MiniPlayer's `_Artwork` and CastingMediaCard's
/// `_Thumbnail`, this widget never actually had an `audioOnly` branch —
/// every non-live item, songs included, fell straight into the 2:3
/// poster frame below, forcing square album art into that portrait
/// rectangle. This sheet is reachable from a song cast via any
/// transport (Google Cast, Jellyfin Remote, Nemesis Native — all three
/// funnel into the Cast button's `showConnectedCastSheet`, see
/// cast_button.dart), so the distortion showed regardless of which one
/// was casting. Square, rounded-corner treatment now matches the other
/// two surfaces' own `audioOnly` branch: same footprint as this sheet's
/// existing thumbnail size, no forced 2:3 aspect.
class _NowCastingThumbnail extends StatelessWidget {
  const _NowCastingThumbnail({required this.item});

  final MediaItem item;

  static const double _posterHeight = 52;
  static const double _posterWidth = _posterHeight * 2 / 3;

  @override
  Widget build(BuildContext context) {
    if (item.audioOnly) {
      final artwork = item.image;
      Widget placeholder() => Container(
            width: _posterHeight,
            height: _posterHeight,
            color: Colors.grey.shade800,
            child: const Icon(Icons.music_note, color: Colors.white38),
          );

      return ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: artwork == null
            ? placeholder()
            : (isRemoteArtwork(artwork)
                ? Image.network(
                    artwork,
                    width: _posterHeight,
                    height: _posterHeight,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => placeholder(),
                  )
                : Image.file(
                    File(artwork),
                    width: _posterHeight,
                    height: _posterHeight,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => placeholder(),
                  )),
      );
    }

    if (item.live) {
      final logo = item.logo;
      if (logo == null || logo.isEmpty) {
        return const SizedBox(
          width: 52,
          height: 52,
          child: Icon(Icons.live_tv_rounded, color: Colors.white70),
        );
      }
      return SizedBox(
        width: 52,
        height: 52,
        child: isRemoteArtwork(logo)
            ? Image.network(
                logo,
                fit: BoxFit.contain,
                errorBuilder: (_, __, ___) => const Icon(
                  Icons.live_tv_rounded,
                  color: Colors.white70,
                ),
              )
            : Image.file(
                File(logo),
                fit: BoxFit.contain,
                errorBuilder: (_, __, ___) => const Icon(
                  Icons.live_tv_rounded,
                  color: Colors.white70,
                ),
              ),
      );
    }

    final isEpisode = item.seasonNumber != null || item.episodeNumber != null;
    final fallbackIcon = isEpisode ? Icons.tv_rounded : Icons.movie_rounded;
    final artwork = isEpisode ? (item.seriesImage ?? item.image) : item.image;

    Widget placeholder() => Container(
          width: _posterWidth,
          height: _posterHeight,
          color: Colors.grey.shade800,
          child: Icon(fallbackIcon, color: Colors.white38),
        );

    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: artwork == null
          ? placeholder()
          : (isRemoteArtwork(artwork)
              ? Image.network(
                  artwork,
                  width: _posterWidth,
                  height: _posterHeight,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => placeholder(),
                )
              : Image.file(
                  File(artwork),
                  width: _posterWidth,
                  height: _posterHeight,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => placeholder(),
                )),
    );
  }
}
