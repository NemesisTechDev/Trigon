import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import '../../player/player_manager.dart';
import '../models/audio_track.dart';
import '../models/subtitle_track.dart';
import '../models/media_item.dart';
import 'player_seek_bar.dart';
import 'fit_row.dart';
import 'audio_selector.dart';
import 'closed_caption_sheet.dart';
import 'subtitle_sheet.dart';
import 'playback_speed_sheet.dart';
import 'addon_quality_sheet.dart';
import 'video_quality_sheet.dart';
import 'info_sheet.dart';
import '../../widgets/common/pressable.dart';
import '../../widgets/common/measure_size.dart';
import '../../utils/responsive.dart';
import '../../casting/cast_manager.dart';
import '../../casting/playback_coordinator.dart';
import '../../casting/models/cast_capability.dart';
import '../../casting/models/cast_session.dart';
import '../../casting/models/cast_states.dart'
    show CastTransportKind, CastTransportKindMediaHandoff;
import '../../casting/ui/cast_seek_bar.dart';
import '../services/media_stream_parser.dart';
import '../../widgets/shared/nemesis_bottom_sheet.dart';

class PlayerBottomBar extends StatelessWidget {
  const PlayerBottomBar({
    super.key,
  });

  @override
  Widget build(BuildContext context) {

    final manager = PlayerManager.instance;
    final player = manager.player;

    // No SafeArea here for the same reason as the top bar — immersive
    // fullscreen is already forced, and SafeArea's own inset just
    // doubled up with the video's letterbox bar instead of letting
    // the controls reach the true screen edge.
    //
    // GESTURE-NAV CROP FIX (portrait): that fixed 14px bottom padding
    // only ever covered *actual* fullscreen (landscape). In windowed
    // portrait — manager.isFullscreen == false, system bars restored,
    // same distinction PlayerTopBar's own doc comment already draws
    // for the top inset — this bar sits right above the real bottom
    // safe-area inset, and on a gesture-nav device that inset is tall
    // enough to crop the seek bar's duration labels and the
    // Fit/Quality/Info row under the gesture pill. Adding the real
    // inset on top of the existing 14 in that case (0 extra in true
    // fullscreen, where PlayerTopBar's doc comment notes the reported
    // inset can be a stale non-zero "swipe to reveal" reservation even
    // while genuinely hidden) means this always clears the gesture bar
    // regardless of how tall a given device's is, rather than a fixed
    // nudge that only happens to clear today's test devices.
    //
    // Aspect-scoped (MediaQuery.paddingOf) rather than the unscoped
    // MediaQuery.of(context), for the same reason as PlayerTopBar —
    // this only rebuilds when the real bottom inset itself changes,
    // not on every keyboard animation.
    return ValueListenableBuilder<bool>(
      valueListenable: manager.isFullscreen,
      builder: (context, fullscreenForPadding, __) {
        final bottomPadding = 14.0 +
            (fullscreenForPadding
                ? 0.0
                : MediaQuery.paddingOf(context).bottom);

        return ValueListenableBuilder<MediaItem?>(
      valueListenable: manager.currentItemNotifier,
      builder: (context, item, __) {
        final isLive = item?.live ?? false;

        return MeasureSize(
        onChange: (size) {
          manager.bottomBarHeight.value = size.height;
        },
        child: Container(
        padding: EdgeInsets.only(top: 14, bottom: bottomPadding),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [
              Colors.black.withValues(alpha: 0.9),
              Colors.transparent,
            ],
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [

            // Casting fix (Phase 14): the seek bar has to reflect and
            // control the TV's own reported position/duration while
            // casting, not the local (paused) player's — same
            // CastManager.activeSession branch CenterControls just
            // above already uses. Everything below this (Fit, Quality,
            // Audio, Subtitles, Speed, Info) stays the same local-player
            // row regardless — those buttons are handled individually,
            // Quality fading itself out below rather than this whole
            // bar switching wholesale.
            ValueListenableBuilder<CastSession?>(
              valueListenable: CastManager.instance.activeSession,
              builder: (context, session, __) {
                final casting = session?.isConnected ?? false;

                if (casting) {
                  return ValueListenableBuilder<CastCapability>(
                    valueListenable: session!.capabilityNotifier,
                    builder: (context, capability, __) {
                      return Padding(
                        padding:
                            const EdgeInsets.symmetric(horizontal: 4),
                        child: CastSeekBar(
                          session: session,
                          capability: capability,
                        ),
                      );
                    },
                  );
                }

                return PlayerSeekBar(
                  player: player,
                );
              },
            ),

            const SizedBox(height: 4),

            // SPLIT-GROUP LAYOUT: instead of one evenly-spread strip, the
            // row is divided into two clusters pinned to opposite edges —
            // what you're listening to / reading on the left (Audio,
            // Subtitles) and how it's played and shown on the right
            // (Speed, Quality, Fit, Info). Buttons are icon-only; each one
            // keeps its name as a tooltip + accessibility label (see
            // _BottomBarAction). The 16px side padding matches the seek
            // bar's time labels so both edges line up.
            //
            // Play/pause and next/previous-episode live in the center
            // controls now, so this row is only for the secondary
            // playback settings. Live channels have no audio tracks or
            // meaningful playback speed, so they only get Subtitles (CC)
            // on the left and Quality, Fit and Info on the right.
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: FitRow(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: isLive
                    ? [
                        _ButtonGroup(
                          children: [
                            _closedCaptionButton(context),
                          ],
                        ),
                        _ButtonGroup(
                          children: [
                            _qualityControl(context, item),
                            _scaleControl(manager),
                            _infoButton(context, item),
                          ],
                        ),
                      ]
                    : [
                        _ButtonGroup(
                          children: [
                            _audioButton(context, manager),
                            _subtitlesButton(context, manager),
                          ],
                        ),
                        _ButtonGroup(
                          children: [
                            _speedButton(context),
                            _qualityControl(context, item),
                            _scaleControl(manager),
                            _infoButton(context, item),
                          ],
                        ),
                      ],
              ),
            ),
          ],
        ),
        ),
        );
      },
    );
      },
    );
  }
}

/// Casting fix (Audio button stuck disabled while
/// casting): this used to always read
/// `manager.audioTracks` — the *local* mpv
/// player's track list — exactly the same mistake
/// the Subtitles button below already had fixed
/// for the identical reason. `CastManager.
/// loadAndPlay()` never touches local mpv, so
/// while casting a video that list is empty (or a
/// stale leftover), which made `tracks.isEmpty`
/// permanently disable this button for the whole
/// cast session regardless of transport — even
/// Nemesis Native and Jellyfin Remote sessions
/// that fully support switching the TV's audio
/// track. Now this branches on
/// `CastManager.instance.activeSession` the same
/// way Subtitles does: while casting, the real
/// per-item audio track list comes from
/// `session.currentItem.value.mediaStreams`
/// (parsed with the same MediaStreamParser used
/// for local playback), and the button is only
/// greyed out when the connected transport
/// genuinely can't select an audio track
/// (`session.capability.audioTrackSelection`),
/// not based on local player state that was
/// never populated in the first place.
Widget _audioButton(BuildContext context, PlayerManager manager) {
  return ValueListenableBuilder<CastSession?>(
    valueListenable: CastManager.instance.activeSession,
    builder: (_, session, __) {
      // ROOT CAUSE (Audio button greyed out while
      // casting an Open With/Play With video that
      // was opened locally first, then cast): this
      // builder only listened to `activeSession`,
      // which is published BEFORE the coordinator
      // has declared the video a local cast and
      // before the session has a current item. The
      // local-vs-Jellyfin decision below was made
      // once, too early, and never re-made — and the
      // Jellyfin branch keeps Audio disabled for a
      // local item (the transport reports
      // audioTrackSelection: false for it). It now
      // re-evaluates whenever the coordinator starts/
      // stops owning a local cast, or the session's
      // current item / connection state changes.
      return ListenableBuilder(
        listenable: Listenable.merge([
          PlaybackCoordinator.instance.localCastRevision,
          if (session != null) session.currentItem,
          if (session != null) session.connectionState,
        ]),
        builder: (_, __) {
      final castItem = session?.currentItem.value;
      final castingVideo = session != null &&
          session.isConnected &&
          castItem != null &&
          !castItem.audioOnly;

      // LOCAL VIDEO CAST (Open With/Play With over
      // Google Cast): the item has no Jellyfin
      // MediaStreams, so the track list comes from
      // the phone's own player (mpv still has the
      // file open, paused) and picking one remuxes
      // and reloads the TV — see PlaybackCoordinator
      // .switchLocalCastAudio.
      //
      // `castItem == null` is tolerated here:
      // isLocalVideoCast itself treats a null current
      // item as "still this coordinator's local
      // video" (the receiver briefly reports no
      // media during a reload), and dropping to the
      // Jellyfin branch for that moment is what
      // greyed the button out.
      if (session != null &&
          session.isConnected &&
          (castItem == null || !castItem.audioOnly) &&
          PlaybackCoordinator.instance
              .isLocalVideoCast) {
        return ValueListenableBuilder<List<AudioTrack>>(
          valueListenable: manager.audioTracks,
          builder: (_, tracks, __) {
            return _BottomBarAction(
              icon: Icons.audiotrack,
              label: "Audio",
              onPressed: tracks.isEmpty
                  ? null
                  : () {
                      showNemesisBottomSheet(
                        context,
                        initialChildSize: 0.5,
                        minChildSize: 0.25,
                        maxChildSize: 0.85,
                        builder: (_, scrollController) =>
                            AudioSelector(
                          audioTracks: tracks,
                          scrollController:
                              scrollController,
                        ),
                      );
                    },
            );
          },
        );
      }

      if (castingVideo) {
        return ValueListenableBuilder<MediaItem?>(
          valueListenable: session.currentItem,
          builder: (_, liveCastItem, __) {
            final tracks =
                _castAudioTracks(liveCastItem);
            final disabled = !session
                .capability.audioTrackSelection;

            return _BottomBarAction(
              icon: Icons.audiotrack,
              label: "Audio",
              onPressed: disabled
                  ? null
                  : () {
                      showNemesisBottomSheet(
                        context,
                        initialChildSize: 0.5,
                        minChildSize: 0.25,
                        maxChildSize: 0.85,
                        builder: (_, scrollController) =>
                            AudioSelector(
                          audioTracks: tracks,
                          scrollController:
                              scrollController,
                        ),
                      );
                    },
            );
          },
        );
      }

      // Always shown regardless of whether the
      // current title actually has multiple local
      // tracks to offer — only greyed out (via the
      // null onPressed below) when there's
      // genuinely nothing to switch to, rather than
      // disappearing outright.
      return ValueListenableBuilder<List<AudioTrack>>(
        valueListenable: manager.audioTracks,
        builder: (_, tracks, __) {
          return _BottomBarAction(
            icon: Icons.audiotrack,
            label: "Audio",
            onPressed: tracks.isEmpty
                ? null
                : () {
                    showNemesisBottomSheet(
                      context,
                      initialChildSize: 0.5,
                      minChildSize: 0.25,
                      maxChildSize: 0.85,
                      builder: (_, scrollController) =>
                          AudioSelector(
                        audioTracks: tracks,
                        scrollController:
                            scrollController,
                      ),
                    );
                  },
          );
        },
      );
        },
      );
    },
  );
}

/// Casting fix (server subtitles not showing
/// while casting): this used to always read
/// `manager.subtitles` — the *local* mpv player's
/// track list. `CastManager.loadAndPlay()` never
/// touches local mpv at all, so while casting a
/// video that list is either empty or a stale
/// leftover from whatever last played locally,
/// and the sheet it opened had nothing real to
/// select from even though the backend
/// (CastManager.selectSubtitleTrack) already
/// fully supports it. The real per-item track
/// list while casting lives on
/// `session.currentItem.value.mediaStreams` (kept
/// fresh by CastManager._augmentCastItem, the
/// same fetch that fixed cast trickplay previews)
/// — parsed with the same MediaStreamParser
/// PlayerManager already uses for local playback,
/// so it's built identically either way.
Widget _subtitlesButton(BuildContext context, PlayerManager manager) {
  return ValueListenableBuilder<CastSession?>(
    valueListenable: CastManager.instance.activeSession,
    builder: (_, session, __) {
      final castItem = session?.currentItem.value;
      final castingVideo = session != null &&
          session.isConnected &&
          castItem != null &&
          !castItem.audioOnly;

      // LOCAL VIDEO CAST: list the phone's own text
      // subtitles (sidecar files + OpenSubtitles
      // downloads) — see the Audio button above.
      // Always enabled so "Search online" stays
      // reachable even with no subtitle on hand yet.
      if (castingVideo &&
          PlaybackCoordinator.instance
              .isLocalVideoCast) {
        return ValueListenableBuilder<
            List<SubtitleTrack>>(
          valueListenable: manager.subtitles,
          builder: (_, allTracks, __) {
            final tracks = allTracks
                .where(PlaybackCoordinator
                    .isCastableLocalSubtitle)
                .toList();

            return _BottomBarAction(
              icon: Icons.closed_caption,
              label: "Subtitles",
              onPressed: () {
                showNemesisBottomSheet(
                  context,
                  initialChildSize: 0.55,
                  minChildSize: 0.3,
                  maxChildSize: 0.9,
                  builder: (_, scrollController) =>
                      SubtitleSheet(
                    subtitles: tracks,
                    scrollController: scrollController,
                  ),
                );
              },
            );
          },
        );
      }

      if (castingVideo) {
        return ValueListenableBuilder<MediaItem?>(
          valueListenable: session.currentItem,
          builder: (_, liveCastItem, __) {
            final tracks =
                _castSubtitleTracks(liveCastItem);
            // Google Cast: never greyed out. A
            // movie/episode with no server subtitle
            // tracks has
            // `subtitleTrackSelection == false`
            // (nothing declared to the TV), which
            // used to disable this button and with
            // it the sheet's "Search online" and
            // Delay entries — the very case where
            // an online subtitle is most needed.
            // Other transports keep the old gate.
            final disabled = !session
                    .transportKind.switchesTracksByReload &&
                !session.capability
                    .subtitleTrackSelection;

            return _BottomBarAction(
              icon: Icons.closed_caption,
              label: "Subtitles",
              onPressed: disabled
                  ? null
                  : () {
                      showNemesisBottomSheet(
                        context,
                        initialChildSize: 0.55,
                        minChildSize: 0.3,
                        maxChildSize: 0.9,
                        builder: (_, scrollController) =>
                            SubtitleSheet(
                          subtitles: tracks,
                          scrollController:
                              scrollController,
                        ),
                      );
                    },
            );
          },
        );
      }

      return ValueListenableBuilder<List<SubtitleTrack>>(
        valueListenable: manager.subtitles,
        builder: (_, tracks, __) {
          // Always enabled, even with zero local
          // tracks — SubtitleSheet's "Search online"
          // entry (OpenSubtitles) needs to be reachable
          // regardless of whether this title shipped
          // with any subtitles of its own.
          return _BottomBarAction(
            icon: Icons.closed_caption,
            label: "Subtitles",
            onPressed: () {
              showNemesisBottomSheet(
                context,
                initialChildSize: 0.55,
                minChildSize: 0.3,
                maxChildSize: 0.9,
                builder: (_, scrollController) =>
                    SubtitleSheet(
                  subtitles: tracks,
                  scrollController: scrollController,
                ),
              );
            },
          );
        },
      );
    },
  );
}

/// Casting fix: playback rate is a genuine
/// per-transport capability, not a blanket
/// local-only feature like Quality above —
/// Google Cast and Nemesis Native can both
/// actually change the TV's speed (see
/// CastCapability.playbackRate's own doc
/// comment), only Jellyfin Remote can't. So this
/// greys out only for that one case rather than
/// for casting in general, unlike _qualityButton.
Widget _speedButton(BuildContext context) {
  return ValueListenableBuilder<CastSession?>(
    valueListenable: CastManager.instance.activeSession,
    builder: (_, session, __) {
      final casting = session?.isConnected ?? false;
      final disabled =
          casting && !session!.capability.playbackRate;

      return _BottomBarAction(
        icon: Icons.speed,
        label: "Speed",
        onPressed: disabled
            ? null
            : () {
                showNemesisBottomSheet(
                  context,
                  initialChildSize: 0.45,
                  minChildSize: 0.25,
                  maxChildSize: 0.75,
                  builder: (_, scrollController) =>
                      PlaybackSpeedSheet(
                    scrollController: scrollController,
                  ),
                );
              },
      );
    },
  );
}

/// Scale (Fit/Fill/Stretch) button, rebuilt whenever a cast session
/// connects/disconnects so it can grey itself out while casting.
Widget _scaleControl(PlayerManager manager) {
  return ValueListenableBuilder<CastSession?>(
    valueListenable: CastManager.instance.activeSession,
    builder: (_, session, __) => _scaleButton(
      manager,
      casting: session?.isConnected ?? false,
    ),
  );
}

/// Quality button, rebuilt whenever a cast session connects/disconnects
/// so it can grey itself out while casting.
Widget _qualityControl(BuildContext context, MediaItem? item) {
  return ValueListenableBuilder<CastSession?>(
    valueListenable: CastManager.instance.activeSession,
    builder: (_, session, __) => _qualityButton(
      context,
      item,
      casting: session?.isConnected ?? false,
    ),
  );
}

/// Casting fix (server subtitles not showing while casting): builds the
/// same [SubtitleTrack] list PlayerManager builds for local playback,
/// but from a cast session's item instead — see the call site's own doc
/// comment for why `manager.subtitles` can't be reused directly here.
/// Mirrors PlayerManager's own `mediaSourceId` fallback exactly so the
/// `/Subtitles/{index}/Stream.vtt` extraction URL MediaStreamParser
/// builds for non-external tracks resolves against the right media
/// source.
List<SubtitleTrack> _castSubtitleTracks(MediaItem? item) {
  if (item == null) return const [];

  final mediaSourceId =
      (item.mediaSources != null && item.mediaSources!.isNotEmpty)
          ? item.mediaSources!.first["Id"] as String? ?? item.id
          : item.id;

  return MediaStreamParser.subtitles(
    item.mediaStreams,
    itemId: item.id,
    mediaSourceId: mediaSourceId,
  );
}

/// Casting fix (Audio button stuck disabled while casting): mirrors
/// [_castSubtitleTracks] above, but for audio streams — builds the same
/// [AudioTrack] list PlayerManager builds for local playback, from a
/// cast session's item instead. No `mediaSourceId`/extraction-URL
/// handling is needed here the way subtitles required: audio tracks are
/// selected purely by stream index (`SetAudioStreamIndex`/
/// `selectAudioTrack`), never fetched via a standalone URL.
List<AudioTrack> _castAudioTracks(MediaItem? item) {
  if (item == null) return const [];
  return MediaStreamParser.audio(item.mediaStreams);
}

Widget _qualityButton(
  BuildContext context,
  MediaItem? item, {
  bool casting = false,
}) {
  // Externally-opened files (Open With / Play With — see
  // ExternalMediaHandler), local library files, and downloaded items all
  // play straight from a local path/content URI with no Jellyfin server
  // behind them to transcode a different resolution from — the button
  // greys itself out for all three, same as Audio already does naturally
  // for external files (no MediaStreams to populate it from).
  //
  // Titles streaming from an addon are the exception: they are flagged
  // local only so the Jellyfin-only steps are skipped, but they do have
  // other qualities to switch to (see AddonQualitySheet).
  final addon = isStreamingFromAddon(item);
  final isOfflineFile = !addon &&
      item != null &&
      (item.isLocal || !item.streamUrl.startsWith("http"));

  // Casting fix (Phase 14): the quality/bitrate this button negotiates
  // is for the *local* player's own transcode of the stream — while a
  // cast session has this item, the TV is pulling (or transcoding) its
  // own copy directly from the server, entirely independent of
  // whatever the local player would request. Opening this sheet and
  // changing anything here wouldn't reach the TV at all, so it fades
  // and disables itself for as long as casting is active, same "greyed
  // out rather than hidden" treatment already used for offline files —
  // the button's still there to explain why it isn't doing anything
  // right now, rather than disappearing and leaving a gap in the row.
  final disabled = isOfflineFile || casting;

  return _BottomBarAction(
    icon: Icons.high_quality_outlined,
    label: "Quality",
    onPressed: disabled
        ? null
        : () {
            showNemesisBottomSheet(
              context,
              initialChildSize: 0.4,
              minChildSize: 0.22,
              maxChildSize: 0.7,
              builder: (_, scrollController) => addon
                  ? AddonQualitySheet(
                      item: item!,
                      scrollController: scrollController,
                    )
                  : VideoQualitySheet(
                      scrollController: scrollController,
                    ),
            );
          },
  );
}

/// Opens the Info sheet (see info_sheet.dart) for whatever's currently
/// playing — ratings/PG rating/overview for a movie, episode number +
/// ratings + preview for an episode, or the current program (with its
/// own progress bar) for a live channel. Greys itself out only in the
/// brief window before the current item is actually known (matches how
/// Audio/Quality already handle their own "nothing to act on yet" case).
///
/// CASTING FIX (Info button dead/stale while casting, every transport):
/// this used to be handed `manager.currentItemNotifier`'s item no matter
/// what — local playback's own paused, frozen-at-handoff item.
/// PlaybackCoordinator deliberately doesn't mirror that notifier for a
/// video cast, and a connect-first cast / a TV-side episode change never
/// touches it at all, so the button either stayed greyed out (nothing
/// local ever loaded) or opened the sheet for whatever played locally
/// BEFORE the cast instead of what's actually on the TV. It now follows
/// the cast session's own `currentItem` — the same source of truth
/// PlayerTopBar's title and the casting backdrop already use — for every
/// transport (Google Cast, DLNA/UPnP, Jellyfin Remote, Nemesis Native),
/// and the open sheet keeps following it (`liveItem`) if the TV moves on
/// to another episode.
///
/// Open With/Play With files (MediaItem.isLocal) have no server
/// metadata to show, so while one is being cast the button is greyed
/// out. Ordinary (non-casting) playback is unchanged.
/// Live TV only: opens the Off / Closed caption sheet. Same button on the
/// phone's own player and while casting — the sheet routes the choice to
/// the phone's player or to the TV.
Widget _closedCaptionButton(BuildContext context) {
  return _BottomBarAction(
    icon: Icons.closed_caption,
    label: "Subtitles",
    onPressed: () {
      showNemesisBottomSheet(
        context,
        initialChildSize: 0.4,
        minChildSize: 0.25,
        maxChildSize: 0.7,
        builder: (_, scrollController) =>
            ClosedCaptionSheet(scrollController: scrollController),
      );
    },
  );
}

Widget _infoButton(BuildContext context, MediaItem? item) {
  return _CastAwareInfoButton(localItem: item);
}

class _CastAwareInfoButton extends StatelessWidget {
  final MediaItem? localItem;

  const _CastAwareInfoButton({required this.localItem});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<CastSession?>(
      valueListenable: CastManager.instance.activeSession,
      builder: (context, session, __) {
        // No session at all: exactly the pre-existing local behavior.
        if (session == null) {
          return _buildAction(context, localItem, casting: false);
        }

        // Re-evaluates on the same triggers the Audio button does: the
        // session's current item (set/changed/cleared by every
        // transport, incl. CastManager's augmented copy), its
        // connection state, and the coordinator starting/stopping a
        // local-file cast.
        return ListenableBuilder(
          listenable: Listenable.merge([
            session.currentItem,
            session.connectionState,
            PlaybackCoordinator.instance.localCastRevision,
          ]),
          builder: (context, __) {
            final castItem = session.currentItem.value;
            final castingVideo = session.isConnected &&
                castItem != null &&
                !castItem.audioOnly;

            // Whatever is really on the TV wins; otherwise (not
            // connected yet, receiver briefly reporting no media, an
            // audio cast) fall back to the local item as before.
            final effective = castingVideo ? castItem : localItem;

            return _buildAction(
              context,
              effective,
              casting: session.isConnected,
              liveItem: castingVideo ? session.currentItem : null,
              // A local-file cast whose session item is momentarily
              // null (Google Cast reload window) is still a local file.
              forceLocal: session.isConnected &&
                  PlaybackCoordinator.instance.isLocalVideoCast,
            );
          },
        );
      },
    );
  }

  Widget _buildAction(
    BuildContext context,
    MediaItem? item, {
    required bool casting,
    ValueListenable<MediaItem?>? liveItem,
    bool forceLocal = false,
  }) {
    final disabled =
        item == null || (casting && (forceLocal || item.isLocal));

    return _BottomBarAction(
      icon: Icons.info_outline,
      label: "Info",
      onPressed: disabled
          ? null
          : () => showPlayerInfoSheet(context, item, liveItem: liveItem),
    );
  }
}

/// Casting fix (Fit button does nothing useful while casting): unlike
/// Audio/Subtitles/Speed, which are genuine per-transport capabilities
/// that can (for at least some transports) actually reach the TV, video
/// fit/scale has no equivalent anywhere in any of the three casting
/// protocols — checked across Google Cast, Jellyfin Remote, and Nemesis
/// Native, none expose a remote "set aspect/scale mode" command, because
/// it's inherently a receiver-side rendering decision, not something a
/// controller can dictate. This button used to always read/write
/// `manager.videoFit` — the *local* player's scale, which nothing on
/// screen is even using once a video's handed off to a cast session
/// (there's no local video surface actively playing it) — so tapping it
/// while casting silently changed a value with no visible effect on
/// either the phone or the TV. Now it greys itself out for as long as
/// casting is active, the exact same "greyed out rather than dangling"
/// treatment `_qualityButton` already uses for its own local-only
/// concept.
Widget _scaleButton(PlayerManager manager, {bool casting = false}) {
  return ValueListenableBuilder<BoxFit>(
    valueListenable: manager.videoFit,
    builder: (_, fit, __) {
      return _BottomBarAction(
        icon: _scaleIconFor(fit),
        label: _scaleLabelFor(fit),
        onPressed: casting
            ? null
            : () {
                manager.videoFit.value = _nextScale(fit);
              },
      );
    },
  );
}

/// Cycles Fit (standard, letterboxed) -> Fill (crops to cover the
/// screen) -> Stretch (fills without preserving aspect ratio) -> back
/// to Fit.
BoxFit _nextScale(BoxFit current) {
  switch (current) {
    case BoxFit.contain:
      return BoxFit.cover;
    case BoxFit.cover:
      return BoxFit.fill;
    default:
      return BoxFit.contain;
  }
}

IconData _scaleIconFor(BoxFit fit) {
  switch (fit) {
    case BoxFit.contain:
      return Icons.fit_screen_outlined;
    case BoxFit.cover:
      return Icons.crop_free;
    default:
      return Icons.aspect_ratio;
  }
}

String _scaleLabelFor(BoxFit fit) {
  switch (fit) {
    case BoxFit.contain:
      return "Fit";
    case BoxFit.cover:
      return "Fill";
    default:
      return "Stretch";
  }
}

/// One cluster of the split-group bottom row: its buttons packed together
/// at their natural width, so [FitRow]'s spaceBetween pushes the two
/// groups to opposite edges.
class _ButtonGroup extends StatelessWidget {
  final List<Widget> children;

  const _ButtonGroup({required this.children});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }
}

/// Icon-only action for the bottom row. [label] is no longer drawn but is
/// kept as the tooltip (long-press / hover) and the screen-reader label,
/// so "Audio", "Subtitles", "Speed", "Quality", "Fit"/"Fill"/"Stretch"
/// and "Info" stay identifiable.
class _BottomBarAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  const _BottomBarAction({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;

    // TV is remote-navigated, not touched, so this action gets a
    // deliberate bump (icon, padding) rather than the phone-tuned
    // default — same Responsive.isTV pattern used across the rest of the
    // player control surface. Phone target is 48x48, the Material
    // minimum, now that the label is gone.
    final iconSize = Responsive.isTV ? 34.0 : 24.0;
    final horizontalPadding = Responsive.isTV ? 16.0 : 12.0;
    const verticalPadding = 12.0;

    return Semantics(
      button: true,
      enabled: enabled,
      child: Tooltip(
        message: label,
        child: Pressable(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(24),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: horizontalPadding,
              vertical: verticalPadding,
            ),
            child: Icon(
              icon,
              size: iconSize,
              color: enabled ? Colors.white : Colors.white30,
            ),
          ),
        ),
      ),
    );
  }
}
