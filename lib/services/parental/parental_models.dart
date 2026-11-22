// Pure Dart on purpose (no Flutter imports): everything in this file is a
// rule or a piece of arithmetic, so it can be unit-tested with plain `dart`.
//
// Parental Controls data model + the rules engine:
//   * [RatingScale]      - turns "PG-13" / "TV-MA" / "15" ... into a level
//   * [ParentalSettings] - everything a parent can configure (JSON-able)
//   * [TitleFacts]       - what we know about one movie / show
//   * [ParentalPolicy]   - settings + facts -> allowed / blocked (+ why)
//   * [ScreenTime]       - daily limits and bedtime arithmetic

import 'dart:convert';

// ---------------------------------------------------------------------------
// Maturity levels
// ---------------------------------------------------------------------------

/// One selectable maturity limit ("who is watching").
class MaturityTier {
  /// 0..4. A title whose level is <= the chosen tier's level is allowed.
  final int level;
  final String name;
  final String movies;
  final String shows;
  final String blurb;
  const MaturityTier(
    this.level,
    this.name,
    this.movies,
    this.shows,
    this.blurb,
  );
}

const List<MaturityTier> kMaturityTiers = [
  MaturityTier(
    0,
    'Little Kids',
    'G',
    'TV-Y, TV-Y7, TV-G',
    'Cartoons and gentle stories made for the youngest viewers.',
  ),
  MaturityTier(
    1,
    'Kids',
    'Up to PG',
    'Up to TV-PG',
    'Family films and shows. Some mild action or scary moments.',
  ),
  MaturityTier(
    2,
    'Teens',
    'Up to PG-13',
    'Up to TV-14',
    'Not suitable for under 13s. Stronger themes, language and violence.',
  ),
  MaturityTier(
    3,
    'Mature',
    'Up to R',
    'Up to TV-MA',
    'Everything except adults-only titles.',
  ),
  MaturityTier(
    4,
    'Everything',
    'All ratings',
    'All ratings',
    'No maturity limit.',
  ),
];

/// The highest level (= "no maturity limit").
const int kNoLimitLevel = 4;

MaturityTier tierForLevel(int level) {
  for (final t in kMaturityTiers) {
    if (t.level == level) return t;
  }
  return kMaturityTiers.last;
}

/// Turns a certification string from a rating system into a maturity level.
class RatingScale {
  RatingScale._();

  /// Countries we know how to read, in the order we try them. TMDB gives
  /// every title's rating per country; the US one is the app's reference.
  static const List<String> countries = ['US', 'GB', 'DE'];

  static const Map<String, int> _us = {
    'G': 0,
    'TV-Y': 0,
    'TV-Y7': 0,
    'TV-Y7-FV': 0,
    'TV-G': 0,
    'PG': 1,
    'TV-PG': 1,
    'PG-13': 2,
    'TV-14': 2,
    'R': 3,
    'TV-MA': 3,
    'NC-17': 4,
    'X': 4,
    'XXX': 4,
  };

  // BBFC. 15 is treated like R / TV-MA on purpose: when in doubt, protect.
  static const Map<String, int> _gb = {
    'U': 0,
    'UC': 0,
    'PG': 1,
    '12': 2,
    '12A': 2,
    '15': 3,
    '18': 3,
    'R18': 4,
  };

  // FSK (Germany).
  static const Map<String, int> _de = {
    '0': 0,
    '6': 1,
    '12': 2,
    '16': 3,
    '18': 3,
  };

  /// The level for [cert] as written by [country], or null when it is
  /// missing / "Not Rated" / something we do not recognise.
  static int? levelOf(String country, String? cert) {
    if (cert == null) return null;
    final key = cert.trim().toUpperCase().replaceAll(' ', '');
    if (key.isEmpty) return null;
    switch (country.toUpperCase()) {
      case 'US':
        return _us[key];
      case 'GB':
        return _gb[key];
      case 'DE':
        return _de[key];
    }
    return null;
  }

  /// The `certification.lte` value TMDB's /discover/movie understands for
  /// US ratings, or null when no limit applies.
  static String? tmdbMovieCeiling(int maxLevel) {
    switch (maxLevel) {
      case 0:
        return 'G';
      case 1:
        return 'PG';
      case 2:
        return 'PG-13';
      case 3:
        return 'R';
    }
    return null;
  }
}

// ---------------------------------------------------------------------------
// Genres a parent can block
// ---------------------------------------------------------------------------

class BlockableGenre {
  final String key;
  final String label;

  /// TMDB genre ids (movie + TV flavours) this group covers.
  final Set<int> ids;
  const BlockableGenre(this.key, this.label, this.ids);
}

const List<BlockableGenre> kBlockableGenres = [
  BlockableGenre('horror', 'Horror', {27}),
  BlockableGenre('thriller', 'Thriller', {53}),
  BlockableGenre('crime', 'Crime', {80}),
  BlockableGenre('war', 'War', {10752, 10768}),
  BlockableGenre('romance', 'Romance', {10749}),
  BlockableGenre('mystery', 'Mystery', {9648}),
  BlockableGenre('action', 'Action & Adventure', {28, 12, 10759}),
  BlockableGenre('scifi', 'Sci-Fi & Fantasy', {878, 14, 10765}),
  BlockableGenre('comedy', 'Comedy', {35}),
  BlockableGenre('drama', 'Drama', {18}),
  BlockableGenre('animation', 'Animation', {16}),
  BlockableGenre('family', 'Family', {10751}),
  BlockableGenre('documentary', 'Documentary', {99}),
  BlockableGenre('history', 'History', {36}),
  BlockableGenre('music', 'Music', {10402}),
  BlockableGenre('western', 'Western', {37}),
  BlockableGenre('reality', 'Reality', {10764}),
  BlockableGenre('talk', 'Talk & News', {10763, 10767}),
  BlockableGenre('soap', 'Soap', {10766}),
];

BlockableGenre? genreByKey(String key) {
  for (final g in kBlockableGenres) {
    if (g.key == key) return g;
  }
  return null;
}

// ---------------------------------------------------------------------------
// Settings
// ---------------------------------------------------------------------------

/// A blocked title as remembered in settings (name kept so the list can be
/// shown without asking TMDB again).
class BlockedTitle {
  /// `m603` / `s1399` - the same ids the rest of the app uses.
  final String id;
  final String name;
  final int? year;
  final String? posterPath;
  const BlockedTitle(this.id, this.name, {this.year, this.posterPath});

  Map<String, dynamic> toJson() => {
        'id': id,
        'n': name,
        if (year != null) 'y': year,
        if (posterPath != null) 'p': posterPath,
      };

  static BlockedTitle? fromJson(dynamic j) {
    if (j is! Map) return null;
    final id = j['id']?.toString();
    if (id == null || id.isEmpty) return null;
    return BlockedTitle(
      id,
      (j['n'] ?? '').toString(),
      year: (j['y'] as num?)?.toInt(),
      posterPath: j['p'] as String?,
    );
  }
}

/// Pages a parent can lock behind the PIN (see [ParentalSettings.lockDownloads]
/// / [ParentalSettings.lockFavorites] and ParentalLockGate).
enum LockedArea { downloads, favorites }

/// Everything a parent can configure. Immutable; use [copyWith].
class ParentalSettings {
  /// Master switch. Settings are kept when it is off, so turning controls
  /// back on does not mean re-entering everything.
  final bool enabled;

  /// Highest allowed maturity level (see [kMaturityTiers]); 4 = no limit.
  final int maxLevel;

  /// Hide titles that have no rating we can read. Only applies while a
  /// maturity limit (< 4) is set.
  final bool blockUnrated;

  /// [BlockableGenre.key]s.
  final Set<String> blockedGenres;

  /// Words / phrases checked against a title's name, overview and tags.
  final List<String> blockedWords;

  final List<BlockedTitle> blockedTitles;

  /// Minutes of watching allowed per weekday, Monday (index 0) to Sunday
  /// (index 6). null = no limit that day.
  final List<int?> dailyLimitMinutes;

  final bool bedtimeEnabled;

  /// Minutes after midnight.
  final int bedtimeStartMin;
  final int bedtimeEndMin;

  /// Weekdays (1 = Monday .. 7 = Sunday) on which the bedtime window STARTS.
  final Set<int> bedtimeDays;

  /// Ask for the PIN before signing out / deleting the account, so a child
  /// cannot sign out into an unrestricted guest session or wipe things.
  final bool lockAccountActions;

  /// Ask for the PIN before changing add-ons.
  final bool lockAddons;

  /// Ask for the PIN every time the Downloads page is opened.
  final bool lockDownloads;

  /// Ask for the PIN every time the Favorites page is opened.
  final bool lockFavorites;

  const ParentalSettings({
    this.enabled = false,
    this.maxLevel = kNoLimitLevel,
    this.blockUnrated = true,
    this.blockedGenres = const {},
    this.blockedWords = const [],
    this.blockedTitles = const [],
    this.dailyLimitMinutes = const [
      null,
      null,
      null,
      null,
      null,
      null,
      null,
    ],
    this.bedtimeEnabled = false,
    this.bedtimeStartMin = 21 * 60,
    this.bedtimeEndMin = 7 * 60,
    this.bedtimeDays = const {1, 2, 3, 4, 5, 6, 7},
    this.lockAccountActions = true,
    this.lockAddons = false,
    this.lockDownloads = false,
    this.lockFavorites = false,
  });

  static const ParentalSettings defaults = ParentalSettings();

  bool get hasMaturityLimit => maxLevel < kNoLimitLevel;

  bool get hasContentRules =>
      hasMaturityLimit ||
      blockedGenres.isNotEmpty ||
      blockedWords.isNotEmpty ||
      blockedTitles.isNotEmpty;

  bool get hasDailyLimit => dailyLimitMinutes.any((m) => m != null);

  bool get hasTimeRules => hasDailyLimit || bedtimeEnabled;

  ParentalSettings copyWith({
    bool? enabled,
    int? maxLevel,
    bool? blockUnrated,
    Set<String>? blockedGenres,
    List<String>? blockedWords,
    List<BlockedTitle>? blockedTitles,
    List<int?>? dailyLimitMinutes,
    bool? bedtimeEnabled,
    int? bedtimeStartMin,
    int? bedtimeEndMin,
    Set<int>? bedtimeDays,
    bool? lockAccountActions,
    bool? lockAddons,
    bool? lockDownloads,
    bool? lockFavorites,
  }) {
    return ParentalSettings(
      enabled: enabled ?? this.enabled,
      maxLevel: maxLevel ?? this.maxLevel,
      blockUnrated: blockUnrated ?? this.blockUnrated,
      blockedGenres: blockedGenres ?? this.blockedGenres,
      blockedWords: blockedWords ?? this.blockedWords,
      blockedTitles: blockedTitles ?? this.blockedTitles,
      dailyLimitMinutes: dailyLimitMinutes ?? this.dailyLimitMinutes,
      bedtimeEnabled: bedtimeEnabled ?? this.bedtimeEnabled,
      bedtimeStartMin: bedtimeStartMin ?? this.bedtimeStartMin,
      bedtimeEndMin: bedtimeEndMin ?? this.bedtimeEndMin,
      bedtimeDays: bedtimeDays ?? this.bedtimeDays,
      lockAccountActions: lockAccountActions ?? this.lockAccountActions,
      lockAddons: lockAddons ?? this.lockAddons,
      lockDownloads: lockDownloads ?? this.lockDownloads,
      lockFavorites: lockFavorites ?? this.lockFavorites,
    );
  }

  Map<String, dynamic> toJson() => {
        'v': 1,
        'on': enabled,
        'lvl': maxLevel,
        'unr': blockUnrated,
        'gen': blockedGenres.toList()..sort(),
        'words': blockedWords,
        'titles': [for (final t in blockedTitles) t.toJson()],
        'lim': dailyLimitMinutes,
        'bed': bedtimeEnabled,
        'bs': bedtimeStartMin,
        'be': bedtimeEndMin,
        'bd': bedtimeDays.toList()..sort(),
        'lockAcc': lockAccountActions,
        'lockAdd': lockAddons,
        'lockDl': lockDownloads,
        'lockFav': lockFavorites,
      };

  String encode() => jsonEncode(toJson());

  /// Reads settings back. Anything missing / damaged falls back to the
  /// default for that field; this never throws.
  static ParentalSettings decode(String? raw) {
    if (raw == null || raw.isEmpty) return defaults;
    try {
      final j = jsonDecode(raw);
      if (j is! Map) return defaults;
      return fromJson(Map<String, dynamic>.from(j));
    } catch (_) {
      return defaults;
    }
  }

  static ParentalSettings fromJson(Map<String, dynamic> j) {
    int clampInt(dynamic v, int lo, int hi, int fallback) {
      final n = (v is num) ? v.toInt() : null;
      if (n == null) return fallback;
      return n < lo ? lo : (n > hi ? hi : n);
    }

    final limits = <int?>[for (var i = 0; i < 7; i++) null];
    final rawLim = j['lim'];
    if (rawLim is List) {
      for (var i = 0; i < 7 && i < rawLim.length; i++) {
        final v = rawLim[i];
        if (v is num && v > 0) limits[i] = v.toInt().clamp(5, 24 * 60);
      }
    }

    final days = <int>{};
    final rawDays = j['bd'];
    if (rawDays is List) {
      for (final d in rawDays) {
        if (d is num && d >= 1 && d <= 7) days.add(d.toInt());
      }
    }

    return ParentalSettings(
      enabled: j['on'] == true,
      maxLevel: clampInt(j['lvl'], 0, kNoLimitLevel, kNoLimitLevel),
      blockUnrated: j['unr'] != false,
      blockedGenres: {
        if (j['gen'] is List)
          for (final g in j['gen'] as List)
            if (g is String && genreByKey(g) != null) g,
      },
      blockedWords: [
        if (j['words'] is List)
          for (final w in j['words'] as List)
            if (w is String && w.trim().isNotEmpty) w.trim(),
      ],
      blockedTitles: [
        if (j['titles'] is List)
          for (final t in j['titles'] as List) ?BlockedTitle.fromJson(t),
      ],
      dailyLimitMinutes: limits,
      bedtimeEnabled: j['bed'] == true,
      bedtimeStartMin: clampInt(j['bs'], 0, 1439, 21 * 60),
      bedtimeEndMin: clampInt(j['be'], 0, 1439, 7 * 60),
      bedtimeDays: days.isEmpty ? const {1, 2, 3, 4, 5, 6, 7} : days,
      lockAccountActions: j['lockAcc'] != false,
      lockAddons: j['lockAdd'] == true,
      lockDownloads: j['lockDl'] == true,
      lockFavorites: j['lockFav'] == true,
    );
  }
}

// ---------------------------------------------------------------------------
// Title facts + decisions
// ---------------------------------------------------------------------------

enum BlockReason {
  title,
  word,
  genre,
  maturity,
  unrated,
  dailyLimit,
  bedtime,
}

class Decision {
  final bool allowed;
  final BlockReason? reason;

  /// Short sentence for the person who hit the block.
  final String message;
  const Decision.allow()
      : allowed = true,
        reason = null,
        message = '';
  const Decision.block(BlockReason this.reason, this.message) : allowed = false;

  bool get isContentBlock =>
      !allowed &&
      reason != BlockReason.dailyLimit &&
      reason != BlockReason.bedtime;
}

/// What we know about one movie / show when judging it.
class TitleFacts {
  /// `m603` / `s1399`.
  final String id;
  final String name;
  final String overview;
  final Set<int> genreIds;

  /// Lower-cased genre names ("horror"); used when only names are known.
  final Set<String> genreNames;
  final List<String> tags;

  /// Maturity level, null = no readable rating.
  final int? level;

  /// Rating as shown to people ("PG-13"), if any.
  final String? ratingLabel;

  /// False when the rating could not be looked up (offline, TMDB error).
  /// Different from "this title has no rating": unknown fails closed.
  final bool ratingKnown;

  const TitleFacts({
    required this.id,
    this.name = '',
    this.overview = '',
    this.genreIds = const {},
    this.genreNames = const {},
    this.tags = const [],
    this.level,
    this.ratingLabel,
    this.ratingKnown = true,
  });
}

// ---------------------------------------------------------------------------
// The rules
// ---------------------------------------------------------------------------

class ParentalPolicy {
  ParentalPolicy._();

  static final Map<String, RegExp> _wordCache = {};

  /// Whole-word, case-insensitive match of [word] inside [text].
  static bool containsWord(String text, String word) {
    final w = word.trim();
    if (w.isEmpty || text.isEmpty) return false;
    final re = _wordCache.putIfAbsent(w.toLowerCase(), () {
      final escaped = RegExp.escape(w.toLowerCase());
      return RegExp(
        '(?<![\\p{L}\\p{N}])$escaped(?![\\p{L}\\p{N}])',
        unicode: true,
        caseSensitive: false,
      );
    });
    return re.hasMatch(text);
  }

  /// Everything that does not need the rating: blocked title, words, genres.
  /// Cheap and synchronous, so lists run it first and only look up ratings
  /// for what survives.
  static Decision evaluateStatic(ParentalSettings s, TitleFacts f) {
    for (final t in s.blockedTitles) {
      if (t.id == f.id) {
        return const Decision.block(
          BlockReason.title,
          'This title is blocked.',
        );
      }
    }

    if (s.blockedWords.isNotEmpty) {
      final haystack = [f.name, f.overview, ...f.tags].join('\n');
      for (final w in s.blockedWords) {
        if (containsWord(haystack, w)) {
          return const Decision.block(
            BlockReason.word,
            'This title mentions a blocked word.',
          );
        }
      }
    }

    if (s.blockedGenres.isNotEmpty) {
      for (final key in s.blockedGenres) {
        final g = genreByKey(key);
        if (g == null) continue;
        final byId = f.genreIds.any(g.ids.contains);
        final byName = f.genreNames.contains(g.label.toLowerCase()) ||
            f.genreNames.contains(g.key);
        if (byId || byName) {
          return Decision.block(
            BlockReason.genre,
            '${g.label} titles are blocked.',
          );
        }
      }
    }
    return const Decision.allow();
  }

  /// Only the maturity part.
  static Decision evaluateRating(ParentalSettings s, TitleFacts f) {
    if (!s.hasMaturityLimit) return const Decision.allow();
    final limit = tierForLevel(s.maxLevel);

    if (!f.ratingKnown) {
      return const Decision.block(
        BlockReason.unrated,
        "Couldn't check this title's rating.",
      );
    }
    final level = f.level;
    if (level == null) {
      if (s.blockUnrated) {
        return const Decision.block(
          BlockReason.unrated,
          'This title has no age rating.',
        );
      }
      return const Decision.allow();
    }
    if (level > s.maxLevel) {
      final r = f.ratingLabel;
      return Decision.block(
        BlockReason.maturity,
        r == null
            ? 'Too mature for the ${limit.name} setting.'
            : 'Rated $r - above the ${limit.name} setting.',
      );
    }
    return const Decision.allow();
  }

  static Decision evaluate(ParentalSettings s, TitleFacts f) {
    final stat = evaluateStatic(s, f);
    if (!stat.allowed) return stat;
    return evaluateRating(s, f);
  }
}

// ---------------------------------------------------------------------------
// Screen time
// ---------------------------------------------------------------------------

class ScreenTime {
  ScreenTime._();

  /// The day's limit in minutes, or null for "no limit".
  static int? limitFor(ParentalSettings s, DateTime day) =>
      s.dailyLimitMinutes[day.weekday - 1];

  /// Whether [now] falls inside a bedtime window.
  ///
  /// A window that starts on a selected weekday continues past midnight
  /// into the next morning, even when the next day is not selected.
  static bool isBedtime(ParentalSettings s, DateTime now) {
    if (!s.bedtimeEnabled) return false;
    final start = s.bedtimeStartMin;
    final end = s.bedtimeEndMin;
    if (start == end) return false;
    final t = now.hour * 60 + now.minute;

    if (start < end) {
      // Same-day window (e.g. 13:00-15:00 quiet time).
      return s.bedtimeDays.contains(now.weekday) && t >= start && t < end;
    }

    // Overnight window.
    if (t >= start) return s.bedtimeDays.contains(now.weekday);
    if (t < end) {
      final prev = now.weekday == 1 ? 7 : now.weekday - 1;
      return s.bedtimeDays.contains(prev);
    }
    return false;
  }

  /// When the bedtime window that is active at [now] ends.
  static DateTime? bedtimeEnds(ParentalSettings s, DateTime now) {
    if (!isBedtime(s, now)) return null;
    final end = s.bedtimeEndMin;
    var d = DateTime(now.year, now.month, now.day, end ~/ 60, end % 60);
    if (!d.isAfter(now)) d = d.add(const Duration(days: 1));
    return d;
  }

  /// Minutes of bedtime-free viewing left before the next bedtime starts
  /// today, or null when none starts within the next [within] (used to warn
  /// "bedtime in 5 minutes").
  static Duration? untilBedtime(ParentalSettings s, DateTime now,
      {Duration within = const Duration(minutes: 10)}) {
    if (!s.bedtimeEnabled || isBedtime(s, now)) return null;
    if (s.bedtimeStartMin == s.bedtimeEndMin) return null;
    var start = DateTime(
      now.year,
      now.month,
      now.day,
      s.bedtimeStartMin ~/ 60,
      s.bedtimeStartMin % 60,
    );
    if (!start.isAfter(now)) start = start.add(const Duration(days: 1));
    if (!s.bedtimeDays.contains(start.weekday)) return null;
    final left = start.difference(now);
    return left <= within ? left : null;
  }

  /// Seconds of watching left today, or null when there is no limit.
  /// [usedSeconds] is what was watched so far today, [bonusMinutes] extra
  /// time a parent granted.
  static int? secondsLeft(
    ParentalSettings s,
    DateTime now, {
    required int usedSeconds,
    int bonusMinutes = 0,
  }) {
    final limit = limitFor(s, now);
    if (limit == null) return null;
    final left = (limit + bonusMinutes) * 60 - usedSeconds;
    return left < 0 ? 0 : left;
  }

  static String formatClock(int minutesAfterMidnight) {
    final h = minutesAfterMidnight ~/ 60;
    final m = minutesAfterMidnight % 60;
    final period = h >= 12 ? 'PM' : 'AM';
    var dh = h % 12;
    if (dh == 0) dh = 12;
    return '$dh:${m.toString().padLeft(2, '0')} $period';
  }

  static String formatMinutes(int minutes) {
    if (minutes < 60) return '$minutes min';
    final h = minutes ~/ 60;
    final m = minutes % 60;
    return m == 0 ? '${h}h' : '${h}h ${m}m';
  }

  static String formatDuration(Duration d) {
    final s = d.inSeconds < 0 ? 0 : d.inSeconds;
    final m = (s / 60).ceil();
    return formatMinutes(m == 0 ? 1 : m);
  }
}
