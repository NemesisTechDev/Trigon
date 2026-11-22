/// Estimates how big a whole show will be, from the size of ONE episode's
/// link (the first episode still to be downloaded), because looking up a link
/// for every episode just to show a number would be slow and heavy on the
/// addons.
///
/// Episodes are not all the same length (a pilot or a finale can run twice as
/// long), and a file's size follows its running time, so the estimate scales
/// by running time instead of just multiplying by the number of episodes:
///
///   total = sample size / sample minutes * minutes of every episode
///
/// When running times are missing or look wrong it falls back to
/// `sample size * number of episodes`.
///
/// Pure and synchronous (no UI, no network).
class ShowSizeEstimate {
  ShowSizeEstimate._();

  /// A running time shorter than this is treated as "not known" (TMDB uses
  /// tiny placeholder values for some episodes).
  static const double _minUsefulMinutes = 5;

  /// [sampleBytes]: the size of the sample episode's file.
  /// [sampleMinutes]: that episode's running time in minutes, if known.
  /// [episodeMinutes]: the running time in minutes of every episode that
  /// will be downloaded (the sample included), null where not known.
  ///
  /// Returns the estimated total in bytes (0 when there are no episodes).
  static int total({
    required int sampleBytes,
    required double? sampleMinutes,
    required List<double?> episodeMinutes,
  }) {
    final count = episodeMinutes.length;
    if (count == 0 || sampleBytes <= 0) return 0;
    final flat = sampleBytes * count;

    final sample = sampleMinutes;
    if (sample == null || sample < _minUsefulMinutes) return flat;

    final known = <double>[
      for (final m in episodeMinutes)
        if (m != null && m >= _minUsefulMinutes) m,
    ];
    // Too little running-time data to trust: plain count.
    if (known.length * 2 < count) return flat;

    final knownSum = known.fold<double>(0, (a, b) => a + b);
    // An episode with no running time counts as an average one.
    final minutes = knownSum + (knownSum / known.length) * (count - known.length);
    final scaled = sampleBytes / sample * minutes;

    // A wildly different answer means the running times are wrong somewhere
    // (a placeholder, a one-off special as the sample): do not trust them.
    if (scaled < flat * 0.5 || scaled > flat * 2) return flat;
    return scaled.round();
  }
}
