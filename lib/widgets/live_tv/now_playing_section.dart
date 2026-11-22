import 'package:flutter/material.dart';

import '../../utils/app_fonts.dart';
import '../../utils/epg_utils.dart';

const _gold = Color(0xffD4AF37);
const _goldSoft = Color(0xffE8C75A);

/// "Now Playing" header + hero card for the Live TV detail screen:
/// LIVE badge, split title/subtitle, duration + genre chips, a
/// segmented progress bar with a playhead, and a "N min left" readout.
///
/// Replaces the old fixed-height (260) Container: the card now sizes to
/// its content, with a minimum height so the page below doesn't jump
/// when [ready] flips and the program data fades in.
class NowPlayingSection extends StatefulWidget {
  final Map<String, dynamic>? program;

  /// 0..1 — pass the screen's own `_programProgress()` so the existing
  /// once-a-minute ticker keeps driving it.
  final double progress;
  final bool ready;

  const NowPlayingSection({
    super.key,
    required this.program,
    required this.progress,
    required this.ready,
  });

  @override
  State<NowPlayingSection> createState() => _NowPlayingSectionState();
}

class _NowPlayingSectionState extends State<NowPlayingSection> {
  bool _expanded = false;

  /// Descriptions longer than this (characters) get a "Show more" label.
  static const int _moreThreshold = 120;

  /// EPG names often arrive as "Series : Round : Session". The last
  /// segment is the thing actually on air; the rest becomes the
  /// subtitle. Falls back to the whole name when there's no separator.
  (String title, String subtitle) _splitName(String name) {
    final parts = name
        .split(':')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    if (parts.length < 2) return (name, '');
    return (parts.last, parts.sublist(0, parts.length - 1).join(' · '));
  }

  String _timeLeft(dynamic endValue) {
    final end = EpgUtils.parseProgramTime(endValue);
    if (end == null) return '';
    final mins = end.difference(DateTime.now()).inMinutes;
    if (mins <= 0) return 'Ending';
    if (mins < 60) return '$mins min left';
    final h = mins ~/ 60, m = mins % 60;
    return m == 0 ? '${h}h left' : '${h}h ${m}m left';
  }

  /// "Starts in 28 min" for a programme that hasn't started yet (the
  /// card falls back to the soonest upcoming entry when nothing is
  /// airing — e.g. a gap in the channel's EPG data).
  String _startsIn(DateTime start) {
    final mins = start.difference(DateTime.now()).inMinutes;
    if (mins < 1) return 'Starting now';
    if (mins < 60) return 'Starts in $mins min';
    final h = mins ~/ 60, m = mins % 60;
    return m == 0 ? 'Starts in ${h}h' : 'Starts in ${h}h ${m}m';
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.program;
    final name = (p?['Name'] ?? 'Unknown Program').toString();
    final (title, subtitle) = _splitName(name);
    final duration = p == null
        ? ''
        : EpgUtils.formatDuration(p['StartDate'], p['EndDate']);
    final isLive =
        p != null && EpgUtils.isLiveNow(p['StartDate'], p['EndDate']);
    final startTime = EpgUtils.parseProgramTime(p?['StartDate']);
    final isUpcoming =
        !isLive && startTime != null && startTime.isAfter(DateTime.now());
    final overview = (p?['Overview'] ?? '').toString();
    final genres = (p?['Genres'] is List)
        ? (p!['Genres'] as List).map((g) => g.toString()).take(2).toList()
        : <String>[];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                'Now Playing',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            if (isLive)
              const _LiveBadge()
            else if (isUpcoming)
              const _UpNextBadge(),
          ],
        ),
        const SizedBox(height: 14),
        AnimatedOpacity(
          duration: const Duration(milliseconds: 250),
          opacity: widget.ready ? 1 : 0,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 220),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
              decoration: BoxDecoration(
                color: const Color(0xff1d1d1d),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final g in genres) _Chip(g, gold: true),
                      if (duration.isNotEmpty) _Chip(duration),
                    ],
                  ),
                  if (genres.isNotEmpty || duration.isNotEmpty)
                    const SizedBox(height: 12),
                  Text(
                    title,
                    // Root cause of the old overflow risk: unbounded title
                    // in a fixed-height card. Capped + ellipsised now.
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: AppFonts.dosis(
                      fontSize: 26,
                      fontWeight: FontWeight.w700,
                      height: 1.15,
                    ),
                  ),
                  if (subtitle.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 13,
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: overview.isEmpty
                        ? null
                        : () => setState(() => _expanded = !_expanded),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        AnimatedSize(
                          duration: const Duration(milliseconds: 200),
                          alignment: Alignment.topLeft,
                          child: Text(
                            overview.isEmpty
                                ? 'No description available.'
                                : overview,
                            maxLines: _expanded ? 12 : 3,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 13.5,
                              height: 1.55,
                            ),
                          ),
                        ),
                        // Only worth offering when the text is long enough
                        // to actually be cut off at three lines.
                        if (overview.length > _moreThreshold)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              _expanded ? 'Show less' : 'Show more',
                              style: const TextStyle(
                                color: _goldSoft,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 18),
                  _SegmentedProgress(progress: widget.progress),
                  const SizedBox(height: 10),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        EpgUtils.formatTime(p?['StartDate']),
                        style: const TextStyle(
                            color: Colors.white54, fontSize: 12),
                      ),
                      if (isLive || isUpcoming)
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.schedule_rounded,
                                size: 14, color: _goldSoft),
                            const SizedBox(width: 5),
                            Text(
                              isLive
                                  ? _timeLeft(p?['EndDate'])
                                  : _startsIn(startTime!),
                              style: const TextStyle(
                                  color: _goldSoft, fontSize: 12),
                            ),
                          ],
                        ),
                      Text(
                        EpgUtils.formatTime(p?['EndDate']),
                        style: const TextStyle(
                            color: Colors.white54, fontSize: 12),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _LiveBadge extends StatelessWidget {
  const _LiveBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.circle, size: 8, color: Color(0xffff4d4d)),
          SizedBox(width: 6),
          Text(
            'LIVE',
            style: TextStyle(
              color: Colors.white,
              fontSize: 11,
              letterSpacing: 1.0,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// Shown instead of [_LiveBadge] when the card is previewing a
/// programme that hasn't started yet.
class _UpNextBadge extends StatelessWidget {
  const _UpNextBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: _gold.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: _gold.withValues(alpha: 0.45)),
      ),
      child: const Text(
        'UP NEXT',
        style: TextStyle(
          color: _goldSoft,
          fontSize: 11,
          letterSpacing: 1.0,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final bool gold;
  const _Chip(this.label, {this.gold = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: gold
            ? _gold.withValues(alpha: 0.16)
            : Colors.white.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: gold ? _goldSoft : Colors.white70,
          fontSize: 11,
        ),
      ),
    );
  }
}

/// A row of small bars: elapsed ones gold, one taller white playhead at
/// the current position, the rest dim. Animates smoothly between the
/// once-a-minute progress updates.
class _SegmentedProgress extends StatelessWidget {
  final double progress;
  const _SegmentedProgress({required this.progress});

  static const _count = 24;

  @override
  Widget build(BuildContext context) {
    final p = progress.clamp(0.0, 1.0);
    final head = (p * _count).floor().clamp(0, _count - 1);

    return SizedBox(
      height: 22,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (var i = 0; i < _count; i++) ...[
            if (i > 0) const SizedBox(width: 3),
            Expanded(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                height: i == head ? 22 : 10,
                decoration: BoxDecoration(
                  color: i < head
                      ? _gold
                      : (i == head
                          ? Colors.white
                          : Colors.white.withValues(alpha: 0.14)),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
