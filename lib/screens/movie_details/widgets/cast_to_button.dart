import 'package:flutter/material.dart';

import '../../../casting/cast_manager.dart';
import '../../../casting/models/cast_session.dart';
import '../../../casting/models/cast_states.dart';
import '../../../casting/playback_coordinator.dart';
import '../../../casting/ui/cast_ui.dart';
import '../../../casting/ui/connected_session_sheet.dart';
import '../../../casting/ui/device_picker_sheet.dart';
import '../../../player/playback_service.dart';
import '../../../virtual/virtual_catalog.dart' show VId;
import '../../../virtual/virtual_playback.dart';

/// The Movie/Show Details "Cast" action, per the master prompt's
/// `[ PLAY ]  [ CAST ]` requirement: "lets the user send content directly
/// to a TV without first playing it locally." Mirrors [DownloadButton]'s
/// shape (a self-contained widget that takes the raw Jellyfin item map
/// and drives its own manager directly) rather than routing through a
/// callback — this needs no coordination with the screen's own
/// Play/Favorite state the way `onPlay`/`onFavorite` do.
///
/// Titles here come from the virtual TMDB catalog and have no stream of
/// their own. After a device is connected, the title goes through
/// [PlaybackService.playItem], which asks the person's addons for a source
/// (the same chooser as Play) and, because a session is connected, sends
/// the chosen stream to the TV (Google Cast or DLNA). Any non-virtual item
/// is still resolved and loaded directly.
class CastToButton extends StatefulWidget {
  final Map<String, dynamic> item;

  const CastToButton({super.key, required this.item});

  @override
  State<CastToButton> createState() => _CastToButtonState();
}

class _CastToButtonState extends State<CastToButton> {
  bool _busy = false;

  Future<void> _handleTap() async {
    if (_busy) return;

    final manager = CastManager.instance;
    final wasAlreadyCasting = manager.isCasting;

    // Casting fix (Cast button re-cast itself instead of opening info):
    // this used to unconditionally fall through to loadAndPlay() below
    // whenever a session was already connected — including when that
    // session was already casting *this exact title from this exact
    // screen*. That meant tapping the button a second time on a movie
    // already playing on the TV just silently restarted it from zero,
    // with no way to reach the connected-session sheet (pause/seek/
    // disconnect/device info) from here at all — the same fix
    // CastButton (the player top bar / other surfaces' unified control)
    // already gets from CastManager.isCasting's own branch. Comparing
    // against the raw Jellyfin `Id` here (rather than waiting on the
    // resolved MediaItem below) keeps this a cheap, synchronous check —
    // no network round trip needed just to decide which action to take.
    //
    // A different movie/show's Details screen, while a session is
    // already casting something else, still falls straight through to
    // loadAndPlay() below without reopening the picker — exactly as
    // before, and exactly what "cast from another screen should just
    // start casting that title" needs: the device is already connected,
    // so there's nothing left to pick.
    if (wasAlreadyCasting) {
      final session = manager.activeSession.value;
      // RETRY FIX (a movie that failed to cast could never be retried):
      // a transport sets `session.currentItem` to the title the moment a
      // load starts, so after a FAILED cast the session still "was
      // casting" this exact title — and this check opened the info sheet
      // instead of sending it again, every time. Only a title the TV is
      // really showing (or still opening) counts as "casting this item";
      // one that ended in error / stopped / idle is cast again.
      final liveState = session?.playbackState.value;
      final tvHasItem = liveState == CastPlaybackState.playing ||
          liveState == CastPlaybackState.paused ||
          liveState == CastPlaybackState.buffering ||
          liveState == CastPlaybackState.loading;
      final castingThisItem = tvHasItem &&
          _sameTitle(session?.currentItem.value?.id, widget.item["Id"]?.toString());

      if (castingThisItem) {
        await showConnectedCastSheet(context);
        return;
      }
    }

    // Nothing connected yet — open the unified picker first. If the
    // person cancels out of it (or a pairing attempt fails), there's
    // nothing to send to, so stop here.
    //
    // The intent is declared BEFORE the picker: connecting a session
    // normally hands whatever is playing on this phone (a song, say) over
    // to the TV, which raced with the title being cast here and left the
    // TV / mini player on the song. With the intent declared, the connect
    // doesn't hand anything off — this title is what goes to the TV, and
    // the song is just parked (paused, still in its mini player).
    final coordinator = PlaybackCoordinator.instance;
    if (!wasAlreadyCasting) {
      coordinator.beginExplicitCast();
      final connected = await showCastDevicePicker(context);
      if (!connected || !mounted) {
        coordinator.endExplicitCast();
        return;
      }
    }

    setState(() => _busy = true);
    try {
      final media = await PlaybackService.resolveLibraryItem(widget.item);
      await coordinator.prepareForExplicitCast(media);

      if (VirtualPlayback.isVirtual(media)) {
        // Addon title: choose a source, then cast it (PlaybackService
        // redirects to the connected TV and reports its own failures).
        await PlaybackService.playItem(media);
        return;
      }

      await manager.loadAndPlay(media);

      if (!mounted) return;
      final deviceName = manager.activeSession.value?.device.displayName;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            deviceName != null
                ? 'Casting "${media.title}" to $deviceName'
                : 'Casting "${media.title}"',
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        // A DLNA TV that refused / never started the stream says why; show
        // that instead of a generic sentence so it can be acted on.
        final isDlna =
            manager.activeSession.value?.transportKind == CastTransportKind.dlna;
        final detail = (isDlna && e is StateError && e.message.isNotEmpty)
            ? e.message
            : 'Couldn\'t start casting.';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(detail)),
        );
      }
    } finally {
      coordinator.endExplicitCast();
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Whether the TV's current item [castId] is this screen's title
  /// [itemId]. A virtual movie/episode (`m123`, `e123_s1_e2`...) is cast as
  /// an addon item with a different id (`addon_movie_123`,
  /// `addon_tv_123_s1e2`), so those forms are compared too.
  static bool _sameTitle(String? castId, String? itemId) {
    if (castId == null || itemId == null) return false;
    if (castId == itemId) return true;
    try {
      final v = VId.parse(itemId);
      if (v.kind == 'movie') return castId == 'addon_movie_${v.tmdbId}';
      if (v.kind == 'episode' && v.season != null && v.episode != null) {
        return castId == 'addon_tv_${v.tmdbId}_s${v.season}e${v.episode}';
      }
    } catch (_) {}
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<CastSession?>(
      valueListenable: CastManager.instance.activeSession,
      builder: (context, session, __) {
        final connected = session?.isConnected ?? false;

        if (_busy) {
          return const Center(
            child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2, color: castGold),
            ),
          );
        }

        return Center(
          child: IconButton(
            onPressed: _handleTap,
            padding: EdgeInsets.zero,
            splashRadius: 20,
            tooltip: connected
                ? 'Cast to ${session!.device.displayName}'
                : 'Cast to a device',
            icon: Icon(
              connected ? Icons.cast_connected_rounded : Icons.cast_rounded,
              color: connected ? castGold : Colors.white,
            ),
          ),
        );
      },
    );
  }
}
