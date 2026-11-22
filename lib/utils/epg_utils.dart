import 'package:intl/intl.dart';

class EpgUtils {
  static const double pixelsPerMinute = 2.5;
  static const int hoursInGuide = 24;

  static double get hourWidth => 60 * pixelsPerMinute;
  static double get timelineWidth => hoursInGuide * hourWidth;

  /// Parses a Program's StartDate/EndDate into a correct local
  /// DateTime.
  ///
  /// Handles a real Jellyfin quirk: most of the API reliably marks
  /// dates as UTC (trailing "Z"), but LiveTV EPG timestamps are
  /// sometimes serialized WITHOUT it — even though the value is
  /// genuinely a UTC instant, just missing the marker. Dart's
  /// DateTime.parse treats an offset-less ISO8601 string as if it were
  /// already the device's own local time, which makes a later
  /// `.toLocal()` call a no-op — so on a naive string, the server's raw
  /// UTC clock digits would get displayed (and compared against
  /// DateTime.now()) as if they were already local, which is wrong for
  /// anyone not in UTC+0. This checks whether the string actually
  /// carries a "Z" or an explicit +/-HH:MM offset; if it doesn't, the
  /// parsed digits are re-anchored as UTC before converting to local,
  /// instead of being silently misinterpreted as local to begin with.
  static DateTime? parseProgramTime(dynamic value) {
    if (value == null) return null;
    final raw = value.toString();
    if (raw.isEmpty) return null;

    final parsed = DateTime.tryParse(raw);
    if (parsed == null) return null;

    final hasOffset =
        raw.endsWith('Z') || RegExp(r'[+-]\d{2}:?\d{2}$').hasMatch(raw);

    if (hasOffset) {
      return parsed.toLocal();
    }

    // No timezone marker — treat the parsed wall-clock digits as UTC
    // (what they actually represent) rather than trusting Dart's
    // default local-time interpretation of an offset-less string.
    final asUtc = DateTime.utc(
      parsed.year,
      parsed.month,
      parsed.day,
      parsed.hour,
      parsed.minute,
      parsed.second,
      parsed.millisecond,
      parsed.microsecond,
    );

    return asUtc.toLocal();
  }

  static String formatTime(dynamic value) {
    final date = parseProgramTime(value);
    return date == null ? '' : DateFormat('HH:mm').format(date);
  }

  static String formatDay(dynamic value) {
    final date = parseProgramTime(value);
    return date == null ? '' : DateFormat('EEE').format(date);
  }

  static String formatDate(dynamic value) {
    final date = parseProgramTime(value);
    return date == null ? '' : DateFormat('MMM d').format(date);
  }

  /// Position/width relative to [dayStart] (the guide's midnight
  /// reference), NOT the naive hour-of-day. A program that began before
  /// midnight (still airing when the previous day rolled over) would
  /// otherwise wrap back to a small "hour of day" offset and render in
  /// completely the wrong place — this anchors everything to the actual
  /// elapsed minutes since the visible grid's start instead, and clamps
  /// both ends to the 24h window so nothing draws off-grid.
  ///
  /// [start] is expected to already be a correct local DateTime (see
  /// parseProgramTime) — this only handles the day-boundary math, not
  /// timezone correction.
  static double leftOffset(DateTime start, DateTime dayStart) {
    final minutesFromDayStart = start.difference(dayStart).inMinutes;
    return minutesFromDayStart.clamp(0, hoursInGuide * 60) * pixelsPerMinute;
  }

  static double width(DateTime start, DateTime end, DateTime dayStart) {
    final clippedStart = start.isBefore(dayStart) ? dayStart : start;
    final dayEnd = dayStart.add(const Duration(days: 1));
    final clippedEnd = end.isAfter(dayEnd) ? dayEnd : end;
    return clippedEnd.difference(clippedStart).inMinutes * pixelsPerMinute;
  }

  /// Whether a program spanning [startValue]–[endValue] is airing right
  /// now. Both are raw Jellyfin date strings (StartDate/EndDate) —
  /// parsed with [parseProgramTime] so the same timezone correction
  /// applies here as everywhere else a program's schedule is read.
  static bool isLiveNow(dynamic startValue, dynamic endValue) {
    final start = parseProgramTime(startValue);
    final end = parseProgramTime(endValue);
    if (start == null || end == null) return false;

    final now = DateTime.now();
    return !now.isBefore(start) && now.isBefore(end);
  }

  /// Fraction (0.0–1.0) of [startValue]–[endValue] that has elapsed
  /// right now — 0 before it starts, 1 once it's over. This is the one
  /// "how far through this program are we" calculation every screen
  /// that shows a program progress bar (TV Guide's tile painter, the
  /// Live TV detail screen's Now Playing card, the in-player channel
  /// list, and the in-player Info sheet) should share, rather than each
  /// keeping its own near-identical copy that can quietly drift out of
  /// sync with the others.
  static double progress(dynamic startValue, dynamic endValue) {
    final start = parseProgramTime(startValue);
    final end = parseProgramTime(endValue);
    if (start == null || end == null || !end.isAfter(start)) return 0;

    final now = DateTime.now();
    if (now.isBefore(start)) return 0;
    if (!now.isBefore(end)) return 1;

    return now.difference(start).inSeconds /
        end.difference(start).inSeconds;
  }

  /// "1h 30m" / "45m" — a program's total scheduled length from its own
  /// StartDate/EndDate. Distinct from MediaService.formatRuntime, which
  /// formats an on-demand item's RunTimeTicks rather than a schedule
  /// window.
  static String formatDuration(dynamic startValue, dynamic endValue) {
    final start = parseProgramTime(startValue);
    final end = parseProgramTime(endValue);
    if (start == null || end == null) return '';

    final mins = end.difference(start).inMinutes;
    if (mins <= 0) return '';

    final h = mins ~/ 60;
    final m = mins % 60;
    if (h == 0) return '${m}m';
    if (m == 0) return '${h}h';
    return '${h}h ${m}m';
  }

  /// Picks whichever program in [programs] is genuinely airing right
  /// now — a defensive client-side re-check on top of the server-side
  /// StartDate/EndDate window filter (see MediaService.getPrograms/
  /// getGuide) — falling back to the soonest upcoming entry (assumes
  /// [programs] is already sorted by StartDate, as every caller's own
  /// fetch already requests) if nothing is currently airing, e.g. a gap
  /// in the channel's EPG data. Returns null for an empty list.
  static Map<String, dynamic>? pickCurrentProgram(List programs) {
    if (programs.isEmpty) return null;

    for (final p in programs) {
      if (p is! Map) continue;
      if (isLiveNow(p['StartDate'], p['EndDate'])) {
        return Map<String, dynamic>.from(p);
      }
    }

    final first = programs.first;
    return first is Map ? Map<String, dynamic>.from(first) : null;
  }
}
