import 'catalog_models.dart';

/// Decides whether a title (or one episode of a series) is out yet, so the
/// app never asks the addons for links to something that has not been
/// released.
///
/// Why it is needed: addons answer for ANY valid IMDb id, and for an
/// unreleased title they often return fake files, camera recordings or
/// torrents that are not the real thing. The app had no check of its own,
/// so such links reached the list and could be played or downloaded.
///
/// The rule, using TMDB's dates (date only, no time) against the device's
/// local date:
///  - a movie / first-air date AFTER today -> not released;
///  - an episode's air date AFTER today -> not aired;
///  - no date at all -> not released only when TMDB's status says it is
///    still planned or in production; a title with no date and no status is
///    allowed (missing data must not block old titles);
///  - the release day itself is allowed.
///
/// Pure and synchronous: no network, no UI.
class ReleaseGate {
  ReleaseGate._();

  /// TMDB `status` values that mean "not out yet".
  static const Set<String> _unreleasedStatuses = {
    'rumored',
    'planned',
    'in production',
    'post production',
  };

  static const List<String> _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  /// `yyyy-mm-dd` (what TMDB sends) as a local date, or null.
  static DateTime? _parse(String? raw) {
    if (raw == null || raw.length < 10) return null;
    final y = int.tryParse(raw.substring(0, 4));
    final m = int.tryParse(raw.substring(5, 7));
    final d = int.tryParse(raw.substring(8, 10));
    if (y == null || m == null || d == null) return null;
    return DateTime(y, m, d);
  }

  static DateTime _today(DateTime? now) {
    final n = now ?? DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  static String _format(DateTime d) => '${_months[d.month - 1]} ${d.day}, ${d.year}';

  /// True when [title] itself is not out yet.
  static bool isTitleUnreleased(CatalogTitle title, {DateTime? now}) {
    final date = _parse(title.releaseDate);
    if (date != null) return date.isAfter(_today(now));
    final status = title.status?.trim().toLowerCase();
    return status != null && _unreleasedStatuses.contains(status);
  }

  /// True when [episode] has an air date that is still in the future.
  static bool isEpisodeUnaired(CatalogEpisode episode, {DateTime? now}) {
    final date = _parse(episode.airDate);
    return date != null && date.isAfter(_today(now));
  }

  /// A short message for the person when [title] / [episode] must not be
  /// looked up yet, or null when it may be.
  static String? blockedMessage(
    CatalogTitle title, {
    CatalogEpisode? episode,
    DateTime? now,
  }) {
    if (episode != null && isEpisodeUnaired(episode, now: now)) {
      final date = _parse(episode.airDate)!;
      return 'This episode has not aired yet. It airs on ${_format(date)}.';
    }
    if (isTitleUnreleased(title, now: now)) {
      final date = _parse(title.releaseDate);
      return date != null
          ? 'Not released yet. Releases on ${_format(date)}.'
          : 'Not released yet.';
    }
    return null;
  }
}
