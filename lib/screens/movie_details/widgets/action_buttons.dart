import 'package:flutter/material.dart';

import '../../../services/download_manager.dart';
import '../../../widgets/common/download_button.dart';
import '../../../widgets/common/series_download_button.dart';
import '../../../widgets/common/filmstrip_icon.dart';
import '../../../widgets/common/stacked_action_bar.dart';
import 'cast_to_button.dart';

class ActionButtons extends StatelessWidget {
  final bool favorite;
  final VoidCallback onFavorite;
  final VoidCallback onPlay;
  final bool resume;

  /// The movie/series item this action bar belongs to — needed so the
  /// download button can drive DownloadManager directly. Optional so
  /// existing call sites keep compiling; when omitted the download
  /// button is simply not shown.
  final Map<String, dynamic>? item;

  /// Centers the Play/Favorite/Download group as one block instead of
  /// the default left alignment — used by the landscape detail layout,
  /// which centers everything above this row too.
  final bool centered;

  /// Opens the Trailers popup (TrailerSheet) for [item]. Optional so
  /// existing call sites keep compiling; the button itself is only
  /// shown when this is supplied.
  final VoidCallback? onTrailers;

  /// Stacked layout (Movie / Show details): a wide gold play button with
  /// the labelled, un-circled action icons in a row underneath it. Left
  /// false for other callers (Collection details), which keep the original
  /// single-row bar.
  final bool stacked;

  /// Text of the play button in [stacked] mode — e.g. "Start Watching
  /// Episode 1" / "Continue Watching Episode 4". When null it falls back to
  /// "Continue Watching" if [resume] else "Start Watching".
  final String? playLabel;

  /// Original single-row bar only: shows "Start Watching" on the play
  /// button and a text label to the right of each enclosed (circled)
  /// icon button. Used by Collection details.
  final bool enclosedLabels;

  const ActionButtons({
    super.key,
    required this.favorite,
    required this.onFavorite,
    required this.onPlay,
    required this.resume,
    this.item,
    this.centered = false,
    this.onTrailers,
    this.stacked = false,
    this.playLabel,
    this.enclosedLabels = false,
  });

  /// Download label follows the real state for a movie/episode; a series
  /// (many episodes) just says "Download".
  Widget _downloadLabel() {
    final it = item!;
    if (it['Type'] == 'Series') return StackedActionBar.labelText('Download');
    final id = it['Id']?.toString() ?? '';
    return AnimatedBuilder(
      animation: DownloadManager.instance,
      builder: (context, _) {
        final manager = DownloadManager.instance;
        if (manager.isDownloaded(id)) {
          return StackedActionBar.labelText('Downloaded');
        }
        switch (manager.stateOf(id)) {
          case DownloadState.downloading:
          case DownloadState.paused:
          case DownloadState.queued:
            return StackedActionBar.labelText('Downloading');
          default:
            return StackedActionBar.labelText('Download');
        }
      },
    );
  }

  List<Widget> _stackedActions() {
    return [
      if (item != null)
        StackedActionBar.item(
          icon: CastToButton(item: item!),
          label: StackedActionBar.labelText('Cast'),
        ),
      if (onTrailers != null)
        StackedActionBar.item(
          icon: Center(
            child: IconButton(
              onPressed: onTrailers,
              icon: const FilmstripIcon(color: Colors.white),
            ),
          ),
          label: StackedActionBar.labelText('Trailers'),
        ),
      StackedActionBar.item(
        icon: Center(
          child: IconButton(
            onPressed: onFavorite,
            icon: Icon(
              favorite ? Icons.favorite : Icons.favorite_border,
              color: favorite ? Colors.red : Colors.white,
            ),
          ),
        ),
        label: StackedActionBar.labelText('Favorite'),
      ),
      if (item != null)
        StackedActionBar.item(
          icon: Center(
            // A TV show has no file of its own: its button downloads all
            // of its episodes (quality sheet with per-quality totals).
            child: item!['Type'] == 'Series'
                ? SeriesDownloadButton(item: item!)
                : DownloadButton(
                    item: item!,
                    kind: item!['Type'] == 'Episode'
                        ? DownloadKind.episode
                        : DownloadKind.movie,
                  ),
          ),
          label: _downloadLabel(),
        ),
    ];
  }

  /// Enclosed-labels mode: the heart and its "Favorite" label inside one
  /// bordered pill.
  Widget _favoritePill() {
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        borderRadius: BorderRadius.circular(28),
        onTap: onFavorite,
        child: Container(
          height: 56,
          padding: const EdgeInsets.symmetric(horizontal: 20),
          decoration: BoxDecoration(
            border: Border.all(color: Colors.white.withOpacity(.12)),
            borderRadius: BorderRadius.circular(28),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                favorite ? Icons.favorite : Icons.favorite_border,
                color: favorite ? Colors.red : Colors.white,
              ),
              const SizedBox(width: 10),
              Text(
                'Favorite',
                maxLines: 1,
                style: TextStyle(
                  color: Colors.white.withOpacity(.72),
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Non-stacked mode only: puts [text] to the right of an enclosed
  /// (circled) button when [enclosedLabels] is on.
  Widget _sideLabeled(Widget circle, String text) {
    if (!enclosedLabels) return circle;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        circle,
        const SizedBox(width: 8),
        Text(
          text,
          maxLines: 1,
          style: TextStyle(
            color: Colors.white.withOpacity(.72),
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (stacked) {
      return StackedActionBar(
        playLabel:
            playLabel ?? (resume ? 'Continue Watching' : 'Start Watching'),
        onPlay: onPlay,
        actions: _stackedActions(),
      );
    }

    // mainAxisSize.min so the Row only ever claims the width its
    // buttons actually need — the FittedBox below is what shrinks
    // that content to fit the real available width when it doesn't.
    final content = Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment:
          centered ? MainAxisAlignment.center : MainAxisAlignment.start,
      children: [
        /// PLAY
        SizedBox(
          height: 56,
          child: ElevatedButton.icon(
            onPressed: onPlay,
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xffD4AF37),
              foregroundColor: Colors.black,
              elevation: 0,
              padding: const EdgeInsets.symmetric(
                horizontal: 26,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(30),
              ),
            ),
            icon: const Icon(Icons.play_arrow),
            label: Text(
              enclosedLabels
                  ? (playLabel ?? "Start Watching")
                  : (resume ? "Resume" : "Play"),
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 16,
              ),
            ),
          ),
        ),

        const SizedBox(width: 14),

        /// CAST — per the casting master prompt's "[ PLAY ] [ CAST ]"
        /// requirement. Only shown when an [item] map was supplied (same
        /// gating the Download button below already uses) since casting
        /// needs the raw Jellyfin item to resolve a playable MediaItem.
        if (item != null)
          _sideLabeled(
            Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              border: Border.all(
                color: Colors.white.withOpacity(.12),
              ),
              borderRadius: BorderRadius.circular(28),
            ),
            child: CastToButton(item: item!),
          ),
          'Cast',
          ),

        const SizedBox(width: 14),

        /// TRAILERS
        if (onTrailers != null)
          _sideLabeled(
            Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              border: Border.all(
                color: Colors.white.withOpacity(.12),
              ),
              borderRadius: BorderRadius.circular(28),
            ),
            child: IconButton(
              onPressed: onTrailers,
              icon: const FilmstripIcon(color: Colors.white),
            ),
          ),
          'Trailers',
          ),

        if (onTrailers != null) const SizedBox(width: 14),

        /// FAVORITE — icon-only, same bordered-circle treatment as
        /// the Cast/Trailers/Download buttons in this row rather than
        /// a labelled pill, so every icon-only action here shares one
        /// consistent visual language.
        enclosedLabels
            ? _favoritePill()
            : _sideLabeled(
          Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            border: Border.all(
              color: Colors.white.withOpacity(.12),
            ),
            borderRadius: BorderRadius.circular(28),
          ),
          child: IconButton(
            onPressed: onFavorite,
            icon: Icon(
              favorite
                  ? Icons.favorite
                  : Icons.favorite_border,
              color: favorite
                  ? Colors.red
                  : Colors.white,
            ),
          ),
        ),
          'Favorite',
        ),

        const SizedBox(width: 14),

        /// DOWNLOAD
        if (item != null)
          _sideLabeled(
            Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              border: Border.all(
                color: Colors.white.withOpacity(.12),
              ),
              borderRadius: BorderRadius.circular(28),
            ),
            // A TV show has no file of its own: its button downloads all
            // of its episodes (quality sheet with per-quality totals).
            child: item!['Type'] == 'Series'
                ? SeriesDownloadButton(item: item!)
                : DownloadButton(
                    item: item!,
                    kind: item!['Type'] == 'Episode'
                        ? DownloadKind.episode
                        : DownloadKind.movie,
                  ),
          ),
          'Download',
          ),
      ],
    );

    // SizedBox(width: centered ? double.infinity : null) around the
    // Padding+FittedBox below — this is the actual centering fix, not
    // the `alignment: Alignment.center` passed to FittedBox further
    // down (that part already existed and was never the problem).
    // FittedBox lays its child out unconstrained, then reports its OWN
    // size as that child's natural size clamped into the incoming
    // constraints — it never grows to fill extra space just because
    // there's room. Every call site here (Movie/Series details and
    // Collection details, both landscape) sits inside a
    // Column(crossAxisAlignment: CrossAxisAlignment.start), which gives
    // this widget loose (not tight) width constraints, so FittedBox's
    // reported width was always just the button group's own content
    // width — leaving nothing wider for `Alignment.center` to center
    // within, and the "centered" group only ever rendered flush against
    // the left edge (Column.start) in both screens despite `centered:
    // true` being passed. SizedBox(width: double.infinity), enforced
    // against those loose incoming constraints, becomes a *tight* box
    // at the full available row width — exactly the same trick
    // _LandscapeMetaRow's own metadata line already relies on (there
    // via a ConstrainedBox(minWidth: ...) + SingleChildScrollView) to
    // actually claim the full row before centering inside it. Left
    // alone (width: null) for non-centered callers, this SizedBox is a
    // no-op — portrait's left-aligned rendering is unchanged.
    return SizedBox(
      width: centered ? double.infinity : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        // On most phones/tablets Play + Favorite (+ Cast/Trailers/
        // Download, when supplied) comfortably fit the available width
        // and this renders at its natural size, unscaled. On the
        // narrowest phones in the size matrix (360dp) all of them
        // together can exceed the space left after this Padding's own
        // 40dp — rather than overflowing (RenderFlex error) or letting
        // the row scroll horizontally (which risks buttons landing
        // partly or fully off-screen), FittedBox with BoxFit.scaleDown
        // shrinks the whole row uniformly just enough to fit, so every
        // button stays visible and reachable at every display width.
        // scaleDown never enlarges, so normal-width screens are
        // unaffected. Alignment stays left (or centered, per [centered])
        // to match the row's own alignment.
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: centered ? Alignment.center : Alignment.centerLeft,
          child: content,
        ),
      ),
    );
  }
}
