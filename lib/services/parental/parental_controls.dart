import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../catalog/catalog_models.dart';
import '../../catalog/tmdb_catalog_service.dart';
import '../../screens/main_nav/navigation_controller.dart';
import '../../screens/profile/parental/parental_prompts.dart';
import '../jellyfin_services/media_service.dart';
import '../jellyfin_services/storage_service.dart';
import 'parental_models.dart';
import 'pin_vault.dart';
import 'ratings_resolver.dart';
import 'viewing_time_service.dart';

/// Thrown by the virtual catalog when something the person asked for is
/// blocked, so the screens see an ordinary failed request.
class ParentalBlockedException implements Exception {
  final Decision decision;
  ParentalBlockedException(this.decision);
  @override
  String toString() => 'Blocked by Parental Controls: ${decision.message}';
}

/// Device-level parental controls.
///
/// Everything here applies to the device, not to one sign-in: signing out
/// into Guest mode or signing into another account does not lift it. Only
/// the parental PIN (or the account owner via "Forgot PIN") can change it.
///
/// Where it bites:
///  * lists / search / home / favorites / continue watching are filtered in
///    VirtualCatalog (the layer every screen already reads from);
///  * a blocked title cannot be opened (VirtualCatalog.item -> 403);
///  * playback is checked right before streaming starts
///    (VirtualPlayback.play, PlayerManager.playMedia);
///  * [ViewingTimeService] enforces daily limits and bedtime while watching.
class ParentalControls {
  ParentalControls._();
  static final ParentalControls instance = ParentalControls._();

  static const String _kSettings = 'parental_settings_v1';
  static const String _kPausedUntil = 'parental_paused_until_ms_v1';

  final ValueNotifier<ParentalSettings> settings =
      ValueNotifier(ParentalSettings.defaults);

  /// Whether a PIN is stored. Controls can be ON without one only in the
  /// recovery case (reinstall / restored backup): they stay enforced and
  /// the owner re-creates the PIN through "Forgot PIN".
  final ValueNotifier<bool> hasPin = ValueNotifier(false);

  /// When a parent switched restrictions off temporarily.
  final ValueNotifier<DateTime?> pausedUntil = ValueNotifier(null);

  /// Bumped whenever what is shown or allowed may have changed.
  final ValueNotifier<int> revision = ValueNotifier(0);

  final Set<String> _allowedOnce = {};
  Timer? _resumeTimer;
  bool _loaded = false;

  // ---------------------------------------------------------------- state

  bool get isPaused {
    final p = pausedUntil.value;
    return p != null && DateTime.now().isBefore(p);
  }

  /// Restrictions are being enforced right now.
  bool get isActive => settings.value.enabled && !isPaused;

  /// Content rules (maturity / genres / words / titles) are being enforced.
  bool get contentFilterActive => isActive && settings.value.hasContentRules;

  bool get timeRulesActive => isActive && settings.value.hasTimeRules;

  /// True when controls are on but the PIN is gone (needs recovery).
  bool get needsPinReset => settings.value.enabled && !hasPin.value;

  /// One-line status for the Settings tile.
  String get summary {
    final s = settings.value;
    if (!s.enabled) return 'Off - set a PIN, age limit and screen time';
    if (isPaused) return 'Paused';
    final parts = <String>[];
    if (s.hasMaturityLimit) parts.add(tierForLevel(s.maxLevel).name);
    if (s.blockedTitles.isNotEmpty ||
        s.blockedGenres.isNotEmpty ||
        s.blockedWords.isNotEmpty) {
      parts.add('custom blocks');
    }
    if (s.hasDailyLimit) parts.add('daily limit');
    if (s.bedtimeEnabled) parts.add('bedtime');
    return parts.isEmpty ? 'On' : 'On - ${parts.join(', ')}';
  }

  // ----------------------------------------------------------------- load

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      settings.value = ParentalSettings.decode(prefs.getString(_kSettings));
      final paused = prefs.getInt(_kPausedUntil);
      if (paused != null) {
        pausedUntil.value = DateTime.fromMillisecondsSinceEpoch(paused);
      }
    } catch (_) {}
    hasPin.value = await PinVault.hasPin();
    await RatingResolver.instance.load();
    _armResumeTimer();
  }

  Future<void> save(ParentalSettings next) async {
    final before = settings.value;
    settings.value = next;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kSettings, next.encode());
    } catch (_) {}
    if (_affectsContent(before, next)) revision.value++;
  }

  static bool _affectsContent(ParentalSettings a, ParentalSettings b) =>
      a.enabled != b.enabled ||
      a.maxLevel != b.maxLevel ||
      a.blockUnrated != b.blockUnrated ||
      a.blockedGenres.length != b.blockedGenres.length ||
      !a.blockedGenres.containsAll(b.blockedGenres) ||
      a.blockedWords.join('\u0000') != b.blockedWords.join('\u0000') ||
      a.blockedTitles.map((t) => t.id).join(',') !=
          b.blockedTitles.map((t) => t.id).join(',');

  // ------------------------------------------------------------------ PIN

  Future<void> setPin(String pin) async {
    await PinVault.setPin(pin);
    hasPin.value = true;
  }

  /// Turns controls off and forgets the PIN and every rule.
  Future<void> removeAll() async {
    await PinVault.clearPin();
    hasPin.value = false;
    _allowedOnce.clear();
    await setPaused(null);
    await save(ParentalSettings.defaults);
    await ViewingTimeService.instance.resetToday();
    revision.value++;
  }

  // ---------------------------------------------------------------- pause

  Future<void> setPaused(Duration? length) async {
    final until = length == null ? null : DateTime.now().add(length);
    pausedUntil.value = until;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (until == null) {
        await prefs.remove(_kPausedUntil);
      } else {
        await prefs.setInt(_kPausedUntil, until.millisecondsSinceEpoch);
      }
    } catch (_) {}
    _armResumeTimer();
    revision.value++;
  }

  void _armResumeTimer() {
    _resumeTimer?.cancel();
    final p = pausedUntil.value;
    if (p == null) return;
    final left = p.difference(DateTime.now());
    if (left <= Duration.zero) {
      unawaited(setPaused(null));
      return;
    }
    _resumeTimer = Timer(left + const Duration(seconds: 1), () {
      unawaited(setPaused(null));
      refreshApp();
    });
  }

  // ----------------------------------------------------------- allow once

  void allowOnce(String baseId) => _allowedOnce.add(baseId);
  bool isAllowedOnce(String baseId) => _allowedOnce.contains(baseId);

  // ----------------------------------------------------------- app refresh

  /// Rebuilds the app from Home with fresh data, the same way a profile
  /// switch does, so no screen keeps showing lists from before the change.
  Future<void> refreshApp() async {
    try {
      await StorageService.clearAppDataCache();
      MediaService.resetUserCaches();
      // The library cards' picture of the week was chosen under the old
      // rules (it could be a now-blocked movie): pick again.
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('vc_art_week2');
      await prefs.remove('vc_art_map2');
      await prefs.remove('vc_coll_art_v1');
    } catch (_) {}
    final nav = ParentalPrompts.navigator;
    if (nav == null) return;
    NavigationController.instance.goToTab(NavTabs.home);
    nav.pushNamedAndRemoveUntil('/home', (route) => false);
  }

  // ------------------------------------------------------------ id helpers

  /// `s12x1x2` / `s12x1` / `m5` / `s12` -> `s12` / `m5`; null for others.
  static String? baseIdOf(String id) {
    final m = RegExp(r'^([ms]\d+)(?:x\d+(?:x\d+)?)?$').firstMatch(id);
    return m?.group(1);
  }

  static String idOfTitle(CatalogTitle t) =>
      t.type == CatalogType.movie ? 'm${t.tmdbId}' : 's${t.tmdbId}';

  // --------------------------------------------------------------- facts

  TitleFacts _facts(CatalogTitle t, {RatingInfo? rating}) => TitleFacts(
        id: idOfTitle(t),
        name: t.title,
        overview: t.overview,
        genreIds: t.genreIds.toSet(),
        genreNames: {for (final g in t.genres) g.toLowerCase()},
        level: rating?.level,
        ratingLabel: rating?.label,
        ratingKnown: rating?.known ?? true,
      );

  // ----------------------------------------------------- list filtering

  /// Removes everything the rules block from [titles], keeping order.
  ///
  /// [ratingChecked]: the caller already asked TMDB for ratings up to the
  /// limit (movie discover with `certification.lte`), so no per-title
  /// rating lookup is needed for movies.
  Future<List<CatalogTitle>> filterTitles(
    List<CatalogTitle> titles, {
    bool ratingChecked = false,
  }) async {
    if (!contentFilterActive || titles.isEmpty) return titles;
    final s = settings.value;

    // Titles that only carry a snapshot (favorites, continue watching) have
    // no genres; fetch them (cached) only when genres are being blocked.
    var list = titles;
    if (s.blockedGenres.isNotEmpty) {
      list = await Future.wait(list.map((t) async {
        if (t.genreIds.isNotEmpty || t.genres.isNotEmpty) return t;
        try {
          return await TmdbCatalogService.details(t.type, t.tmdbId) ?? t;
        } catch (_) {
          return t;
        }
      }));
    }

    // Free, instant rules first.
    final survivors = <CatalogTitle>[];
    for (final t in list) {
      if (isAllowedOnce(idOfTitle(t))) {
        survivors.add(t);
        continue;
      }
      if (ParentalPolicy.evaluateStatic(s, _facts(t)).allowed) {
        survivors.add(t);
      }
    }
    if (!s.hasMaturityLimit || survivors.isEmpty) return survivors;

    final needRating = <String>[
      for (final t in survivors)
        if (!isAllowedOnce(idOfTitle(t)) &&
            !(ratingChecked && t.type == CatalogType.movie))
          idOfTitle(t),
    ];
    final ratings = await RatingResolver.instance.resolveMany(needRating);

    final out = <CatalogTitle>[];
    for (final t in survivors) {
      final id = idOfTitle(t);
      if (isAllowedOnce(id) ||
          (ratingChecked && t.type == CatalogType.movie)) {
        out.add(t);
        continue;
      }
      final f = _facts(t, rating: ratings[id]);
      if (ParentalPolicy.evaluateRating(s, f).allowed) out.add(t);
    }
    return out;
  }

  /// The ids (`m5` / `s12`) of the titles in [titles] that the rules block.
  /// Search uses this to still LIST blocked titles - blurred and locked -
  /// instead of dropping them (see VirtualCatalog.items and MovieCard).
  Future<Set<String>> blockedIdsAmong(List<CatalogTitle> titles) async {
    if (!contentFilterActive || titles.isEmpty) return <String>{};
    final allowed = {
      for (final t in await filterTitles(titles)) idOfTitle(t),
    };
    return {
      for (final t in titles)
        if (!allowed.contains(idOfTitle(t))) idOfTitle(t),
    };
  }

  // --------------------------------------------------------- collections

  final Map<int, bool> _collVerdict = {};
  int _collRevision = -1;

  static int? _collId(Map<String, dynamic> e) {
    final raw = e['id'] ?? e['Id'];
    if (raw is num) return raw.toInt();
    final m = RegExp(r'^c(\d+)$').firstMatch('${raw ?? ''}');
    return m == null ? null : int.parse(m.group(1)!);
  }

  /// Filters movie collections (franchises). Works on TMDB maps
  /// (`id`/`name`/`overview`) and on BoxSet items (`Id`/`Name`/`Overview`).
  ///
  /// A collection is hidden when its own name or overview hits a blocked
  /// word, or - when a maturity limit, genre or title rule is set - when
  /// none of its movies would be allowed. [partsOf] returns a collection's
  /// released movies; results are remembered until the rules change.
  Future<List<Map<String, dynamic>>> filterCollections(
    List<Map<String, dynamic>> entries,
    Future<List<CatalogTitle>> Function(int id) partsOf,
  ) async {
    if (!contentFilterActive || entries.isEmpty) return entries;
    if (_collRevision != revision.value) {
      _collVerdict.clear();
      _collRevision = revision.value;
    }
    final s = settings.value;
    final needParts = s.hasMaturityLimit ||
        s.blockedGenres.isNotEmpty ||
        s.blockedTitles.isNotEmpty;

    final verdict = <int, bool>{};
    final pending = <int>[];
    for (final e in entries) {
      final id = _collId(e);
      if (id == null) continue;
      if (isAllowedOnce('c$id')) {
        verdict[id] = true;
        continue;
      }
      final stat = ParentalPolicy.evaluateStatic(
        s,
        TitleFacts(
          id: 'c$id',
          name: '${e['name'] ?? e['Name'] ?? ''}',
          overview: '${e['overview'] ?? e['Overview'] ?? ''}',
        ),
      );
      if (!stat.allowed) {
        verdict[id] = false;
      } else if (!needParts) {
        verdict[id] = true;
      } else if (_collVerdict.containsKey(id)) {
        verdict[id] = _collVerdict[id]!;
      } else if (!pending.contains(id)) {
        pending.add(id);
      }
    }

    // Look the rest up a few at a time.
    final queue = List<int>.from(pending);
    Future<void> worker() async {
      while (queue.isNotEmpty) {
        final id = queue.removeLast();
        try {
          final parts = await partsOf(id);
          final ok = await filterTitles(parts);
          verdict[id] = ok.isNotEmpty;
          _collVerdict[id] = ok.isNotEmpty;
        } catch (_) {
          verdict[id] = false; // could not check: fail closed, retry later
        }
      }
    }

    await Future.wait([for (var i = 0; i < 6 && i < pending.length; i++) worker()]);

    return [
      for (final e in entries)
        if (_collId(e) == null || verdict[_collId(e)!] == true) e,
    ];
  }

  // ------------------------------------------------------- single checks

  /// Judges one title / season / episode id (`m5`, `s12`, `s12x1x2`).
  Future<Decision> checkId(String id) async {
    if (!contentFilterActive) return const Decision.allow();
    final base = baseIdOf(id);
    if (base == null) return const Decision.allow();
    if (isAllowedOnce(base)) return const Decision.allow();

    final s = settings.value;
    final isMovie = base.startsWith('m');
    final tmdbId = int.parse(base.substring(1));

    // Blocked-title / word / genre rules need the title's own data.
    CatalogTitle? t;
    if (s.blockedTitles.isNotEmpty ||
        s.blockedWords.isNotEmpty ||
        s.blockedGenres.isNotEmpty) {
      try {
        t = await TmdbCatalogService.details(
          isMovie ? CatalogType.movie : CatalogType.series,
          tmdbId,
        );
      } catch (_) {}
    }
    final stat = ParentalPolicy.evaluateStatic(
      s,
      t != null ? _facts(t) : TitleFacts(id: base),
    );
    if (!stat.allowed) return stat;
    if (!s.hasMaturityLimit) return const Decision.allow();

    final r = await RatingResolver.instance.resolve(base);
    return ParentalPolicy.evaluateRating(
      s,
      TitleFacts(
        id: base,
        level: r.level,
        ratingLabel: r.label,
        ratingKnown: r.known,
      ),
    );
  }

  /// Judges a Jellyfin-shaped item (details screen, player item, download).
  Future<Decision> checkItemJson(Map<String, dynamic> j) async {
    if (!contentFilterActive) return const Decision.allow();

    final type = (j['Type'] ?? '').toString();
    String? base;
    final rawId = (type == 'Episode' ? j['SeriesId'] : j['Id'])?.toString();
    if (rawId != null) base = baseIdOf(rawId);

    // Addon / downloaded items carry the TMDB id instead.
    if (base == null) {
      final tmdb = j['TmdbId'] ?? (j['ProviderIds'] is Map
          ? (j['ProviderIds'] as Map)['Tmdb']
          : null);
      final n = tmdb is num ? tmdb.toInt() : int.tryParse('${tmdb ?? ''}');
      if (n != null) base = (type == 'Movie' ? 'm' : 's') + n.toString();
    }

    if (base == null) {
      // A file we know nothing about (e.g. opened from another app).
      final s = settings.value;
      if (s.hasMaturityLimit && s.blockUnrated) {
        return const Decision.block(
          BlockReason.unrated,
          'This video has no age rating.',
        );
      }
      return const Decision.allow();
    }
    return checkId(base);
  }

  // --------------------------------------------------------- PIN gating

  /// Asks for the PIN before an account-level action (sign out, delete
  /// account) when the parent turned that lock on. True = go ahead.
  Future<bool> guardAccountAction(BuildContext context, String what) async {
    final s = settings.value;
    if (!s.enabled || isPaused || !s.lockAccountActions) return true;
    if (!hasPin.value) return true;
    return ParentalPrompts.verifyPin(context, reason: what);
  }

  Future<bool> guardAddons(BuildContext context) async {
    final s = settings.value;
    if (!s.enabled || isPaused || !s.lockAddons) return true;
    if (!hasPin.value) return true;
    return ParentalPrompts.verifyPin(context, reason: 'Manage add-ons');
  }

  /// Whether [area] (Downloads / Favorites) must be opened with the PIN
  /// right now: the parent switched that lock on, controls are enabled and
  /// not paused, and a PIN exists (same rule as [guardAddons]).
  bool isAreaLocked(LockedArea area) {
    final s = settings.value;
    if (!s.enabled || isPaused || !hasPin.value) return false;
    switch (area) {
      case LockedArea.downloads:
        return s.lockDownloads;
      case LockedArea.favorites:
        return s.lockFavorites;
    }
  }

  // ----------------------------------------------------------- playback

  /// The single question every playback path asks before streaming:
  /// "may this start right now?". Shows the block / lock screen itself when
  /// the answer is no, and returns true only if playback may proceed
  /// (including after a parent entered the PIN).
  Future<bool> authorizePlayback({
    String? titleId,
    Map<String, dynamic>? itemJson,
  }) async {
    if (!isActive) return true;

    // Bedtime / daily limit.
    final time = ViewingTimeService.instance.blockNow();
    if (time != null) {
      final unlocked = await ViewingTimeService.instance.showLock(time);
      if (!unlocked) return false;
    }

    if (!contentFilterActive) return true;
    Decision d;
    if (itemJson != null) {
      d = await checkItemJson(itemJson);
    } else if (titleId != null) {
      d = await checkId(titleId);
    } else {
      return true;
    }
    if (d.allowed) return true;

    final base = titleId != null
        ? baseIdOf(titleId)
        : (itemJson?['SeriesId'] ?? itemJson?['Id'])?.toString();
    final ok = await ParentalPrompts.showBlocked(d, titleId: base);
    if (ok && base != null && baseIdOf(base) != null) {
      allowOnce(baseIdOf(base)!);
    }
    return ok;
  }
}
