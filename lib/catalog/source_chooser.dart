import 'dart:async';

import 'package:flutter/material.dart';

import '../addons/addon_manager.dart';
import '../addons/addon_models.dart';
import '../addons/stream_rules.dart';
import '../library/source_preferences.dart';
import '../screens/discover/stream_picker_sheet.dart';
import '../services/app_settings.dart';
import '../services/external_media_handler.dart';
import 'auto_link_selector.dart';
import 'catalog_models.dart';
import 'link_fallback.dart';
import 'release_gate.dart';
import 'tmdb_catalog_service.dart';

/// The one place the UI asks "which stream should this play?".
///
/// With Auto-Select Link on (Settings), the link is chosen from the person's
/// Streaming Quality setting and returned without showing the list (see
/// [AutoLinkSelector]). If no link is suitable the normal list is shown.
///
/// Otherwise, if the person already picked a source for this title and
/// Auto-pick is on, that source is found and returned without showing the
/// list (so resuming a show or watching the next episode is one tap). If the
/// remembered source is no longer offered, the normal source list is shown.
class SourceChooser {
  SourceChooser._();

  /// Once a direct link of the wanted quality has arrived, how long to wait
  /// for a better one before starting. Addons still answering after that keep
  /// feeding the fallback list (LinkFallbackCoordinator.topUp), so starting
  /// early costs no fallback.
  static const Duration _graceAfterGoodDirect = Duration(milliseconds: 1200);

  /// Longest wait before using whatever has arrived, and the extra wait (up
  /// to 45 s in all) when nothing usable has arrived by then.
  static const Duration _firstWait = Duration(seconds: 12);
  static const Duration _extraWait = Duration(seconds: 33);

  /// How long addons may keep feeding the fallback list after playback of
  /// the pick has been started.
  static const Duration _topUpWindow = Duration(seconds: 45);

  static Future<AddonStream?> choose(
    BuildContext context, {
    required CatalogTitle title,
    CatalogEpisode? episode,
  }) async {
    // A new choice replaces whatever link fallback was watching an earlier
    // one (auto selection starts a new one below).
    LinkFallbackCoordinator.instance.end();

    // Safety net: callers check this first, but nothing may look for links
    // to a title (or episode) that is not out yet.
    final notOut = ReleaseGate.blockedMessage(title, episode: episode);
    if (notOut != null) {
      _announce(context, notOut);
      return null;
    }

    final prefs = SourcePreferences.instance;
    await prefs.load();
    // Saved addons loaded and the default addon installed (first launch).
    // Without this, a Play tapped right after launch saw "no addon".
    await AddonManager.instance.whenReady();
    if (!context.mounted) return null;

    // Auto-Select Link never shows the link list. Null here means there was
    // no link at all (the person has been told why), so playback stops.
    if (AppSettings.autoLinkSelection.value &&
        AddonManager.instance.hasStreamAddons) {
      return _autoByQuality(context, title, episode);
    }

    final pref = prefs.forTitle('${title.type.tmdb}:${title.tmdbId}');
    if (prefs.autoPick.value &&
        pref != null &&
        AddonManager.instance.hasStreamAddons) {
      final auto = await _tryAuto(context, title, episode, pref);
      if (auto != null) return auto;
      if (!context.mounted) return null;
    }
    return StreamPickerSheet.show(context, title: title, episode: episode);
  }

  /// Blocking spinner shown while the addons answer.
  ///
  /// Deliberately NOT showDialog: that insets its content for notches, system
  /// bars and folds, which moved the spinner off the middle of the loading
  /// logo (the player's loading screen centres the logo on the whole screen).
  /// showGeneralDialog fills the whole screen, so both share one centre.
  static void _showSpinner(BuildContext context) {
    unawaited(showGeneralDialog<void>(
      context: context,
      barrierDismissible: false,
      barrierLabel: 'Loading',
      barrierColor: Colors.black54,
      transitionDuration: Duration.zero,
      pageBuilder: (_, __, ___) => const PopScope(
        canPop: false,
        child: SizedBox.expand(
          child: Center(
            child: CircularProgressIndicator(
                color: Color(0xFFD4AF37), strokeWidth: 2.5),
          ),
        ),
      ),
    ));
  }

  /// Auto-Select Link: picks the link for the current Streaming Quality (see
  /// [AutoLinkSelector.selectAlways]), following the never-select and
  /// preference rules in [StreamRules], as fast as it safely can:
  ///
  ///  - the title's name / language is looked up IN PARALLEL with the addons;
  ///  - it starts a short moment ([_graceAfterGoodDirect]) after the first
  ///    direct link of the wanted quality, without waiting for the slow
  ///    addons (with Default and Data Saver the smallest of the direct links
  ///    that have arrived by then is picked); with Max Quality it starts as
  ///    soon as the best possible link has arrived
  ///    ([AutoLinkSelector.hasIdealLink]);
  ///  - the addons that answer later keep feeding the fallback list.
  ///
  /// Otherwise: up to 12 s, then whatever has arrived is used. If nothing
  /// usable has arrived by then it keeps waiting (up to 45 s in all), and if
  /// the addons answered with nothing at all it asks them once more, because
  /// an addon can fail once and work the next second.
  ///
  /// Null only when there is no link that may be played; a message says so.
  ///
  /// The links to try if the picked one does not start (every other suitable
  /// direct link of that quality first, then the torrents) are handed to
  /// [LinkFallbackCoordinator].
  static Future<AddonStream?> _autoByQuality(
    BuildContext context,
    CatalogTitle title,
    CatalogEpisode? episode,
  ) async {
    final id = episode != null
        ? title.addonId(season: episode.season, episode: episode.number)
        : title.addonId();

    // Small blocking spinner while the addons answer.
    _showSpinner(context);

    final mode = AppSettings.playbackQualityMode.value;
    // Started now, runs alongside the addons (it used to run first).
    final ctxFuture = contextFor(title);
    var ctx = LinkContext(titleName: title.title);
    AutoLinkChoice? choice;
    _LinkCollector? collector;
    var sawLinks = false;
    var sawFourK = false;
    try {
      for (var attempt = 0; attempt < 2 && choice == null; attempt++) {
        collector?.dispose();
        collector = _LinkCollector(
          type: title.type.addon,
          id: id,
          mode: mode,
          ctxFuture: ctxFuture,
        )..start();
        final latest = await collector.settle();
        ctx = await ctxFuture;
        if (latest.isNotEmpty) sawLinks = true;
        if (AutoLinkSelector.hasFourKLinks(latest, ctx: ctx)) sawFourK = true;
        choice = AutoLinkSelector.selectAlways(latest, mode, ctx: ctx);
        // Links came back but none may be played: asking again returns the
        // same links, so only an empty answer is worth a second try.
        if (choice == null && latest.isNotEmpty) break;
      }
    } finally {
      if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
    }

    if (choice == null) {
      collector?.dispose();
      _announce(
        context,
        sawFourK
            ? 'Only 4K links were found. 4K never plays automatically: '
                'turn off Auto-Select Link in Settings to choose one.'
            : sawLinks
            ? 'No suitable links found for this title.'
            : 'No links found for this title. Check your connection and try again.',
      );
      return null;
    }
    if (choice.overridden) _announce(context, AutoLinkSelector.overrideMessage);
    LinkFallbackCoordinator.instance
        .begin(title: title, episode: episode, choice: choice);

    // Addons that are still answering keep adding to the links to try.
    final topUpCtx = ctx;
    collector?.followUp((streams) {
      LinkFallbackCoordinator.instance.topUp(
        title: title,
        episode: episode,
        streams: streams,
        mode: mode,
        ctx: topUpCtx,
      );
    });
    return choice.stream;
  }

  /// What the never-select rules need to know about [title]: its name and
  /// original language. Saved snapshots (history, watchlist) do not keep the
  /// language, so it is looked up (cached, bounded) when missing.
  static Future<LinkContext> contextFor(CatalogTitle title) async {
    var language = title.originalLanguage;
    if (language == null) {
      try {
        final full = await TmdbCatalogService.details(title.type, title.tmdbId)
            .timeout(const Duration(seconds: 4), onTimeout: () => null);
        language = full?.originalLanguage;
      } catch (_) {}
    }
    return LinkContext(originalLanguage: language, titleName: title.title);
  }

  /// Snackbar shown through the app's navigator so it stays visible while
  /// the player opens.
  static void _announce(BuildContext fallback, String message) {
    final ctx = ExternalMediaHandler
            .instance.navigatorKey.currentState?.overlay?.context ??
        (fallback.mounted ? fallback : null);
    if (ctx == null) return;
    final messenger = ScaffoldMessenger.maybeOf(ctx);
    messenger?.hideCurrentSnackBar();
    messenger?.showSnackBar(SnackBar(
      content: Text(message),
      duration: const Duration(seconds: 6),
      behavior: SnackBarBehavior.floating,
      backgroundColor: const Color(0xff1A1A1A),
    ));
  }

  static Future<AddonStream?> _tryAuto(
    BuildContext context,
    CatalogTitle title,
    CatalogEpisode? episode,
    SourcePreference pref,
  ) async {
    final id = episode != null
        ? title.addonId(season: episode.season, episode: episode.number)
        : title.addonId();

    // Small blocking spinner while the addons answer.
    _showSpinner(context);

    final completer = Completer<AddonStream?>();
    var latest = <AddonStream>[];
    final sub = AddonManager.instance.watchStreams(title.type.addon, id).listen(
      (batch) {
        latest = batch;
        // Act early only on an exact match; anything looser waits until every
        // addon has answered so a better match isn't missed.
        final exact = pref.exactFrom(batch);
        if (exact != null && !completer.isCompleted) completer.complete(exact);
      },
      onDone: () {
        if (!completer.isCompleted) completer.complete(pref.pickFrom(latest));
      },
    );

    AddonStream? result;
    try {
      result = await completer.future
          .timeout(const Duration(seconds: 10), onTimeout: () => null);
    } finally {
      await sub.cancel();
      if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
    }
    return result;
  }
}

/// One "ask every addon" run for Auto-Select Link.
///
/// [settle] returns the links known when it is time to pick (see
/// SourceChooser._autoByQuality). Afterwards [followUp] hands every later
/// answer to the fallback list until all addons have answered or the
/// follow-up window ends.
class _LinkCollector {
  _LinkCollector({
    required this.type,
    required this.id,
    required this.mode,
    required this.ctxFuture,
  });

  final String type;
  final String id;
  final PlaybackQualityMode mode;
  final Future<LinkContext> ctxFuture;

  List<AddonStream> latest = const [];
  LinkContext? _ctx;
  void Function(List<AddonStream>)? _follower;
  StreamSubscription<List<AddonStream>>? _sub;
  Timer? _grace;
  Timer? _lifetime;
  final Completer<void> _enough = Completer<void>();

  void start() {
    unawaited(ctxFuture.then((c) {
      _ctx = c;
      _check();
    }));
    _sub = AddonManager.instance.watchStreams(type, id).listen(
      (batch) {
        latest = batch;
        _check();
        _follower?.call(batch);
      },
      onError: (Object _) => dispose(),
      onDone: dispose,
    );
    _lifetime = Timer(SourceChooser._topUpWindow, dispose);
  }

  /// Starts playback as soon as the best possible link is here, or a short
  /// moment after the first direct link of the wanted quality.
  void _check() {
    final ctx = _ctx;
    if (ctx == null || _enough.isCompleted || latest.isEmpty) return;
    // Max Quality takes the best file type whatever the size, so it can
    // start the moment the best possible link is here. Default and Data
    // Saver pick the smallest direct link: a short wait after the first
    // good one lets the other addons' links be compared too.
    if (mode == PlaybackQualityMode.maxQuality &&
        AutoLinkSelector.hasIdealLink(latest, mode, ctx: ctx)) {
      _release();
      return;
    }
    if (_grace == null &&
        AutoLinkSelector.hasGoodDirectLink(latest, mode, ctx: ctx)) {
      _grace = Timer(SourceChooser._graceAfterGoodDirect, _release);
    }
  }

  void _release() {
    if (!_enough.isCompleted) _enough.complete();
  }

  /// The links to pick from: see SourceChooser._autoByQuality for the limits.
  Future<List<AddonStream>> settle() async {
    await _enough.future.timeout(SourceChooser._firstWait, onTimeout: () {});
    final ctx = await ctxFuture;
    if (!_enough.isCompleted &&
        AutoLinkSelector.selectAlways(latest, mode, ctx: ctx) == null) {
      await _enough.future.timeout(SourceChooser._extraWait, onTimeout: () {});
    }
    return latest;
  }

  /// Hands everything that arrived since the pick, and then every later
  /// answer, to [onLinks]. Stops by itself when all addons have answered or
  /// the follow-up window ends.
  void followUp(void Function(List<AddonStream>) onLinks) {
    onLinks(latest);
    if (_sub == null) return; // everything has already arrived
    _follower = onLinks;
  }

  void dispose() {
    _grace?.cancel();
    _lifetime?.cancel();
    _follower = null;
    final sub = _sub;
    _sub = null;
    if (sub != null) unawaited(sub.cancel());
    _release();
  }
}
