import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../models/media_item.dart';
import '../models/subtitle_track.dart';
import '../../player/player_manager.dart';
import 'open_subtitles_sheet.dart';
import '../../casting/cast_manager.dart';
import '../../casting/local_cast_format.dart'
    show LocalCastUnsupportedException;
import '../../casting/playback_coordinator.dart';
import '../../casting/ui/cast_ui.dart';
import '../../widgets/shared/nemesis_bottom_sheet.dart';

class SubtitleSheet extends StatelessWidget {
  const SubtitleSheet({
    super.key,
    required this.subtitles,
    this.scrollController,
  });

  final List<SubtitleTrack> subtitles;
  final ScrollController? scrollController;

  /// INSTANT TICK (every row, "Off" included — normal playback, server
  /// video cast and the Jellyfin Remote / Nemesis Native cast paths):
  /// the checkmark follows a notifier that used to move only AFTER the
  /// pick had fully finished — mpv loading/fetching the subtitle locally,
  /// or the TV round-trip (and for Jellyfin Remote / Nemesis Native not
  /// even then: those transports never write the notifier on select and
  /// only catch up on the next status poll). The tap now records the pick
  /// first, exactly like PlaybackCoordinator.selectLocalCastSubtitle does
  /// for Open With/Play With, and puts the previous value back if the
  /// pick fails.
  Future<void> _pickLocal(PlayerManager manager, SubtitleTrack? track) async {
    final before = manager.selectedSubtitle.value;
    final willChange = before?.index != track?.index;
    if (willChange) manager.selectedSubtitle.value = track;

    try {
      await manager.selectSubtitleTrack(track);
    } catch (_) {
      if (willChange && manager.selectedSubtitle.value?.index == track?.index) {
        manager.selectedSubtitle.value = before;
      }
      rethrow;
    }
  }

  /// Cast counterpart of [_pickLocal]: [trackId] is the Cast/Jellyfin
  /// subtitle stream index, -1 meaning "Off". Failures are still reported
  /// by [runCastCommand]'s usual snackbar.
  Future<void> _pickCast(
    BuildContext context,
    int trackId,
    Future<void> Function() command,
  ) async {
    final notifier = CastManager.instance.activeSession.value
        ?.activeSubtitleTrackId;
    final previous = notifier?.value;
    if (notifier != null) notifier.value = trackId;

    await runCastCommand(context, () async {
      try {
        await command();
      } catch (_) {
        if (notifier != null && notifier.value == trackId) {
          notifier.value = previous;
        }
        rethrow;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final manager = PlayerManager.instance;

    // Casting fix (Phase 14): same reasoning as AudioSelector — while
    // casting, a subtitle change needs to reach the session via
    // CastManager.selectSubtitleTrack, not the paused local player.
    // -1 is Jellyfin's own convention for "no subtitle stream", used
    // here for "Off" for the same reason the rest of this app's
    // Jellyfin calls already follow server conventions rather than
    // inventing a local one.
    final castSession = CastManager.instance.activeSession.value;
    final casting = castSession?.isConnected ?? false;

    // Casting fix: the "active" checkmark used to read
    // `manager.selectedSubtitle` (local player state) unconditionally —
    // while casting, the real selection lives on
    // `session.activeSubtitleTrackId`, which every transport keeps
    // current (see CastSession.activeSubtitleTrackId's own doc comment
    // and each transport's selectSubtitleTrack/_applyState). Branching
    // the whole list on which notifier to listen to, rather than reading
    // `castSession!.activeSubtitleTrackId.value` once, so the checkmark
    // still updates live if a *different* device changes the subtitle
    // track on a shared TV session.
    // LOCAL VIDEO CAST (Open With/Play With over Google Cast): the tracks
    // here are the phone's own text subtitles. Picks go through the normal
    // local PlayerManager selection and PlaybackCoordinator mirrors them
    // to the TV (declared track -> instant switch; fresh OpenSubtitles
    // download -> reload with it declared) — so "Search online" works
    // while casting too. The checkmark maps the TV's active Cast track id
    // back to the local track it came from.
    final localCast =
        casting && PlaybackCoordinator.instance.isLocalVideoCast;

    // SERVER VIDEO CAST (Jellyfin movie/episode over Google Cast): the
    // server's own subtitle tracks are already selectable on the TV, but
    // "Search online (OpenSubtitles)" and "Delay" used to be hidden for
    // the whole cast session because they only acted on the phone's
    // paused mpv. They now act on the TV — see PlaybackCoordinator's
    // SERVER VIDEO CAST section. Online downloads are listed next to the
    // server tracks; a delayed copy of a track is an internal variant, so
    // the checkmark maps it back to the track it came from.
    final serverCast = casting &&
        !localCast &&
        PlaybackCoordinator.instance.isServerVideoCast;

    if (serverCast) {
      final coordinator = PlaybackCoordinator.instance;
      final session = castSession!;
      return ValueListenableBuilder<int>(
        valueListenable: coordinator.serverCastSubtitlesRevision,
        builder: (_, __, ___) => ValueListenableBuilder<int?>(
          valueListenable: session.activeSubtitleTrackId,
          builder: (_, activeId, __) => _buildList(
            context,
            manager: manager,
            casting: true,
            serverCast: true,
            castItem: session.currentItem.value,
            activeSubtitleId: session.activeSubtitleTrackId,
            activeIndex: coordinator.serverCastBaseSubtitleId(activeId),
          ),
        ),
      );
    }

    if (localCast) {
      // ROOT CAUSE (checkmark never moved, "Off" included): this used to
      // derive the checkmark from the TV session's
      // `activeSubtitleTrackId` mapped back through a cast-id table. That
      // value only changes after the TV round-trip succeeds (and is
      // skipped entirely when the pick doesn't reach the TV), so any
      // hiccup on the receiver side made the sheet look completely dead.
      // The phone's own selection is set synchronously by the tap and is
      // exactly what PlaybackCoordinator mirrors to the TV, so it is the
      // right source of truth for the checkmark — the TV catching up (or
      // failing, which now shows a snackbar) no longer affects it.
      //
      // The track list is read from the phone's own list here rather than
      // from the `subtitles` the caller passed: the Subtitles button may
      // have been built a moment before this cast became a local video
      // cast (e.g. the file was opened while the TV was already
      // connected), in which case the caller handed over the Jellyfin
      // layout's empty list.
      return ValueListenableBuilder<List<SubtitleTrack>>(
        valueListenable: manager.subtitles,
        builder: (_, phoneTracks, __) =>
            ValueListenableBuilder<SubtitleTrack?>(
          valueListenable: manager.selectedSubtitle,
          builder: (_, selected, __) => _buildList(
            context,
            manager: manager,
            casting: true,
            localCast: true,
            localTracks: phoneTracks,
            activeIndex: selected?.index,
          ),
        ),
      );
    }

    return casting
        ? ValueListenableBuilder<int?>(
      valueListenable: castSession!.activeSubtitleTrackId,
      builder: (_, activeIndex, __) => _buildList(
        context,
        manager: manager,
        casting: true,
        activeIndex: activeIndex,
      ),
    )
        : ValueListenableBuilder<SubtitleTrack?>(
      valueListenable: manager.selectedSubtitle,
      builder: (_, selected, __) => _buildList(
        context,
        manager: manager,
        casting: false,
        activeIndex: selected?.index,
      ),
    );
  }

  Widget _buildList(
      BuildContext context, {
        required PlayerManager manager,
        required bool casting,
        bool localCast = false,
        bool serverCast = false,
        List<SubtitleTrack>? localTracks,
        MediaItem? castItem,
        ValueListenable<int?>? activeSubtitleId,
        required int? activeIndex,
      }) {
    // Server tracks handed in by the caller plus, for a server cast, the
    // OpenSubtitles downloads declared on the TV for this item.
    final List<SubtitleTrack> listedTracks = localCast
        ? (localTracks ?? subtitles)
            .where(PlaybackCoordinator.isCastableLocalSubtitle)
            .toList()
        : serverCast
        ? [
      ...subtitles,
      ...PlaybackCoordinator.instance.serverCastOnlineTracks(castItem),
    ]
        : subtitles;

    // "Off" is null (local player, server cast, local cast) OR a negative
    // stream index (-1, Jellyfin's own "no subtitle stream" — what the
    // Jellyfin Remote / Nemesis Native / Google Cast sessions hold after
    // Off). The tick used to test `== null` only, so it never showed for
    // the -1 form.
    //
    // BUT a downloaded (OpenSubtitles) / sidecar track also has a negative
    // index of its own, so a negative value only means "Off" when none of
    // the listed rows owns it — otherwise "Off" and that track were both
    // ticked at once.
    final bool subtitlesOff = activeIndex == null ||
        (activeIndex < 0 &&
            !listedTracks.any((track) => track.index == activeIndex));

    return ListView(

      controller: scrollController,

      children: [

        const NemesisSheetDragHandle(topMargin: 10, bottomMargin: 4),

        const Padding(
          padding: EdgeInsets.all(16),
          child: Text(
            "Subtitles",
            style: TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),

        ListTile(

          leading: subtitlesOff
              ? const Icon(
            Icons.check,
            color: Colors.green,
          )
              : null,

          title: const Text(
            "Off",
            style: TextStyle(
              color: Colors.white,
            ),
          ),

          onTap: () async {

            final messenger = ScaffoldMessenger.maybeOf(context);

            if (localCast) {
              await PlaybackCoordinator.instance.selectLocalCastSubtitle(null);
            } else if (serverCast) {
              await _pickCast(
                context,
                -1,
                    () => PlaybackCoordinator.instance.selectServerCastSubtitle(-1),
              );
            } else if (casting) {
              await _pickCast(
                context,
                -1,
                    () => CastManager.instance.selectSubtitleTrack(-1),
              );
            } else {
              try {
                await _pickLocal(manager, null);
              } catch (error) {
                messenger?.showSnackBar(
                  SnackBar(
                    content: Text(
                      'Could not turn subtitles off: $error',
                    ),
                  ),
                );
                return;
              }
            }

            if (context.mounted) Navigator.pop(context);

          },
        ),

        // Only between "Off" and the track rows. With no tracks the divider
        // above "Search online" is the only one, so there is never a
        // double line.
        if (listedTracks.isNotEmpty) const Divider(),

        // While casting a local video only subtitles the phone can
        // actually serve to the TV (raw text / a file on disk) are
        // pickable — mpv-embedded tracks have nothing to send, and the
        // bottom bar's stale-branch fallback used to hand this sheet the
        // unfiltered list, showing rows that could never do anything.
        ...listedTracks.map(
              (track) {

            final active = activeIndex == track.index;

            return ListTile(

              leading: active
                  ? const Icon(
                Icons.check,
                color: Colors.green,
              )
                  : null,

              title: Text(
                track.displayTitle,
                style: const TextStyle(
                  color: Colors.white,
                ),
              ),

              subtitle: Text(
                track.language,
                style: const TextStyle(
                  color: Colors.white54,
                ),
              ),

              onTap: () async {

                final messenger = ScaffoldMessenger.maybeOf(context);

                if (casting && !localCast) {
                  await _pickCast(
                    context,
                    track.index,
                        () => serverCast
                        ? PlaybackCoordinator.instance
                        .selectServerCastSubtitle(track.index)
                        : CastManager.instance
                        .selectSubtitleTrack(track.index),
                  );
                  if (context.mounted) Navigator.pop(context);
                  return;
                }

                try {
                  if (localCast) {
                    await PlaybackCoordinator.instance
                        .selectLocalCastSubtitle(track);
                  } else {
                    await _pickLocal(manager, track);
                  }
                } catch (error) {
                  messenger?.showSnackBar(
                    SnackBar(
                      content: Text(
                        'Could not load subtitle: $error',
                      ),
                    ),
                  );
                  return;
                }

                if (context.mounted) Navigator.pop(context);

              },
            );


          },
        ),

        // "Search online" (OpenSubtitles) and the delay control both
        // only ever act on the local mpv player — hidden while casting
        // rather than shown non-functional, same "controls that can't
        // work stay hidden/greyed rather than dangling" principle the
        // casting layer already follows elsewhere (e.g. the Quality
        // button while casting).
        //
        // Server video over Google Cast is the exception: both act on the
        // TV there (online subtitle -> declared + reload, delay -> shifted
        // copy + reload), so they stay visible for it.
        if (!casting || localCast || serverCast) ...[
          const Divider(),

          // Stacked on top of this sheet rather than replacing it —
          // popping first and reopening on the parent context isn't
          // safe once this sheet's route is gone, and a stacked
          // sheet is a perfectly normal pattern (back/swipe just
          // dismisses the top one first).
          ListTile(
            leading: const Icon(Icons.search, color: Colors.white70),
            title: const Text(
              "Search online (OpenSubtitles)",
              style: TextStyle(color: Colors.white),
            ),
            onTap: () {
              showNemesisBottomSheet(
                context,
                initialChildSize: 0.6,
                minChildSize: 0.3,
                maxChildSize: 0.95,
                // A search box (keyboard) plus a results list that fills in
                // later: its height is not "its content", so it keeps a
                // fixed opening size (still capped to 2/3 in landscape).
                fitContent: false,
                builder: (_, sheetScrollController) => OpenSubtitlesSheet(
                  scrollController: sheetScrollController,
                  castItem: serverCast ? castItem : null,
                ),
              );
            },
          ),

          // Only meaningful once a subtitle is actually on screen
          // to be out of sync with — hidden otherwise rather than
          // shown disabled. Also hidden while casting: the delay only
          // ever shifts the phone's own mpv subtitle, never the TV's.
          if (!subtitlesOff && !casting) ...[
            const Divider(),
            const _SubtitleDelayControl(),
          ],
          if (!subtitlesOff && serverCast && activeSubtitleId != null) ...[
            const Divider(),
            _ServerCastDelayControl(activeSubtitleId: activeSubtitleId),
          ],
          // LOCAL VIDEO CAST (Open With/Play With): the delay acts on the
          // TV too — a shifted copy of the active track, see
          // PlaybackCoordinator.setLocalCastSubtitleDelay. Only offered for
          // a track the TV actually has.
          if (!subtitlesOff &&
              localCast &&
              PlaybackCoordinator.instance
                  .canDelayLocalCastSubtitle(activeIndex)) ...[
            const Divider(),
            _LocalCastDelayControl(
              key: ValueKey('local-cast-delay-$activeIndex'),
              subtitleIndex: activeIndex,
            ),
          ],
        ],
      ],
    );
  }
}

class _SubtitleDelayControl extends StatelessWidget {
  const _SubtitleDelayControl();

  static const _step = Duration(milliseconds: 250);

  @override
  Widget build(BuildContext context) {
    final manager = PlayerManager.instance;

    return ValueListenableBuilder<Duration>(
      valueListenable: manager.subtitleDelay,
      builder: (_, delay, __) {
        final seconds = delay.inMilliseconds / 1000;

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Row(
            children: [
              const Text(
                "Delay",
                style: TextStyle(color: Colors.white70, fontSize: 14),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.remove, color: Colors.white),
                tooltip: "Subtitle earlier",
                onPressed: () => manager.adjustSubtitleDelay(-_step),
              ),
              SizedBox(
                width: 64,
                child: Text(
                  "${seconds >= 0 ? '+' : ''}${seconds.toStringAsFixed(2)}s",
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.add, color: Colors.white),
                tooltip: "Subtitle later",
                onPressed: () => manager.adjustSubtitleDelay(_step),
              ),
              if (delay != Duration.zero)
                IconButton(
                  icon: const Icon(Icons.restart_alt, color: Colors.white54),
                  tooltip: "Reset delay",
                  onPressed: () => manager.setSubtitleDelay(Duration.zero),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// Subtitle delay while a Jellyfin-server movie/episode is on the TV.
///
/// The TV can't shift a subtitle live, so applying a delay means sending a
/// time-shifted copy and reloading the stream at the current position
/// (PlaybackCoordinator.setServerCastSubtitleDelay). Doing that per 0.25s
/// tap would restart playback on the TV over and over, so taps only move
/// the shown value and the change is sent once the taps stop — or right
/// away if the sheet is closed first.
class _ServerCastDelayControl extends StatefulWidget {
  const _ServerCastDelayControl({required this.activeSubtitleId});

  final ValueListenable<int?> activeSubtitleId;

  @override
  State<_ServerCastDelayControl> createState() =>
      _ServerCastDelayControlState();
}

class _ServerCastDelayControlState extends State<_ServerCastDelayControl> {
  static const _step = Duration(milliseconds: 250);
  static const _applyAfter = Duration(milliseconds: 1200);

  final _coordinator = PlaybackCoordinator.instance;

  late Duration _delay;
  Timer? _timer;
  bool _applying = false;
  bool _disposing = false;
  ScaffoldMessengerState? _messenger;

  @override
  void initState() {
    super.initState();
    _delay = _coordinator
        .serverCastSubtitleDelayFor(widget.activeSubtitleId.value);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _messenger = ScaffoldMessenger.maybeOf(context);
  }

  void _change(Duration next) {
    setState(() => _delay = next);
    _timer?.cancel();
    _timer = Timer(_applyAfter, _apply);
  }

  Future<void> _apply() async {
    _timer?.cancel();
    _timer = null;
    if (mounted && !_disposing) setState(() => _applying = true);

    try {
      await _coordinator.setServerCastSubtitleDelay(_delay);
    } catch (error) {
      _messenger
        ?..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            content: Text(
              error is Exception && error.toString().isNotEmpty
                  ? error.toString()
                  : 'Couldn\'t change the subtitle delay on the TV.',
            ),
          ),
        );
      if (mounted && !_disposing) {
        setState(() => _delay = _coordinator.serverCastSubtitleDelayFor(
          widget.activeSubtitleId.value,
        ));
      }
    } finally {
      if (mounted && !_disposing) setState(() => _applying = false);
    }
  }

  @override
  void dispose() {
    _disposing = true;
    if (_timer?.isActive ?? false) {
      _timer!.cancel();
      // Sheet closed mid-adjustment: still send what was chosen.
      unawaited(_apply());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final seconds = _delay.inMilliseconds / 1000;
    final pending = _timer != null || _applying;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                "Delay",
                style: TextStyle(color: Colors.white70, fontSize: 14),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.remove, color: Colors.white),
                tooltip: "Subtitle earlier",
                onPressed: () => _change(_delay - _step),
              ),
              SizedBox(
                width: 64,
                child: Text(
                  "${seconds >= 0 ? '+' : ''}${seconds.toStringAsFixed(2)}s",
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.add, color: Colors.white),
                tooltip: "Subtitle later",
                onPressed: () => _change(_delay + _step),
              ),
              if (_delay != Duration.zero)
                IconButton(
                  icon: const Icon(Icons.restart_alt, color: Colors.white54),
                  tooltip: "Reset delay",
                  onPressed: () => _change(Duration.zero),
                ),
            ],
          ),
          if (pending)
            const Padding(
              padding: EdgeInsets.only(bottom: 4),
              child: Text(
                "Updating on the TV…",
                style: TextStyle(color: Colors.white38, fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }
}

/// Subtitle delay while an Open With/Play With video is on the TV.
///
/// Same shape as [_ServerCastDelayControl]: the TV can't shift a subtitle
/// live, so applying a delay means sending a time-shifted copy and
/// reloading the stream at the current position
/// (PlaybackCoordinator.setLocalCastSubtitleDelay). Taps only move the
/// shown value and the change is sent once the taps stop — or right away
/// if the sheet is closed first.
class _LocalCastDelayControl extends StatefulWidget {
  const _LocalCastDelayControl({super.key, required this.subtitleIndex});

  /// The phone-side [SubtitleTrack.index] of the track being delayed.
  final int subtitleIndex;

  @override
  State<_LocalCastDelayControl> createState() => _LocalCastDelayControlState();
}

class _LocalCastDelayControlState extends State<_LocalCastDelayControl> {
  static const _step = Duration(milliseconds: 250);
  static const _applyAfter = Duration(milliseconds: 1200);

  final _coordinator = PlaybackCoordinator.instance;

  late Duration _delay;
  Timer? _timer;
  bool _applying = false;
  bool _disposing = false;
  ScaffoldMessengerState? _messenger;

  @override
  void initState() {
    super.initState();
    _delay = _coordinator.localCastSubtitleDelayFor(widget.subtitleIndex);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _messenger = ScaffoldMessenger.maybeOf(context);
  }

  void _change(Duration next) {
    setState(() => _delay = next);
    _timer?.cancel();
    _timer = Timer(_applyAfter, _apply);
  }

  Future<void> _apply() async {
    _timer?.cancel();
    _timer = null;
    if (mounted && !_disposing) setState(() => _applying = true);

    try {
      await _coordinator.setLocalCastSubtitleDelay(_delay);
    } catch (error) {
      _messenger
        ?..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            content: Text(
              error is LocalCastUnsupportedException
                  ? error.message
                  : 'Couldn\'t change the subtitle delay on the TV.',
            ),
          ),
        );
      if (mounted && !_disposing) {
        setState(() => _delay =
            _coordinator.localCastSubtitleDelayFor(widget.subtitleIndex));
      }
    } finally {
      if (mounted && !_disposing) setState(() => _applying = false);
    }
  }

  @override
  void dispose() {
    _disposing = true;
    if (_timer?.isActive ?? false) {
      _timer!.cancel();
      // Sheet closed mid-adjustment: still send what was chosen.
      unawaited(_apply());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final seconds = _delay.inMilliseconds / 1000;
    final pending = _timer != null || _applying;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                "Delay",
                style: TextStyle(color: Colors.white70, fontSize: 14),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.remove, color: Colors.white),
                tooltip: "Subtitle earlier",
                onPressed: () => _change(_delay - _step),
              ),
              SizedBox(
                width: 64,
                child: Text(
                  "${seconds >= 0 ? '+' : ''}${seconds.toStringAsFixed(2)}s",
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.add, color: Colors.white),
                tooltip: "Subtitle later",
                onPressed: () => _change(_delay + _step),
              ),
              if (_delay != Duration.zero)
                IconButton(
                  icon: const Icon(Icons.restart_alt, color: Colors.white54),
                  tooltip: "Reset delay",
                  onPressed: () => _change(Duration.zero),
                ),
            ],
          ),
          if (pending)
            const Padding(
              padding: EdgeInsets.only(bottom: 4),
              child: Text(
                "Updating on the TV…",
                style: TextStyle(color: Colors.white38, fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }
}
