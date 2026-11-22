import 'package:flutter/material.dart';

import '../../services/live_tv_reminder_service.dart';
import '../../utils/epg_utils.dart';
import '../../utils/responsive.dart';
import '../common/pressable.dart';
import 'upcoming_program_sheet.dart';

const _gold = Color(0xffD4AF37);
const _goldSoft = Color(0xffE8C75A);

/// "Coming Up" for the Live TV detail screen.
///
/// Portrait: a vertical timeline — time on the left, a rail with dots in
/// the middle, a card on the right. The first entry is highlighted as
/// "Up next" with a live "in 28 min" countdown.
///
/// Landscape: a horizontal slider of cards (no time rail — the time sits
/// inside each card), scrolling edge to edge like the other rows on the
/// page, ending in a "Full TV guide" tile.
///
/// Both layouts: tapping a card opens [showUpcomingProgramSheet]
/// (reminder + record-later placeholder), the bell on a card toggles its
/// reminder directly through [LiveTvReminderService], and — when
/// [onOpenGuide] is given — the header ("Full guide") and the bottom
/// button / end tile open the full TV guide.
///
/// Carries its own horizontal padding, like the section it replaces,
/// because it sits outside the screen's padded container.
class UpcomingProgramTimeline extends StatelessWidget {
  final List programs;
  final String channelId;
  final String channelName;

  /// Rows shown (portrait) before collapsing the rest into "+N more".
  final int maxItems;

  /// Cards shown in the landscape slider.
  final int landscapeMaxItems;

  /// Opens the full TV guide scrolled to this channel. Null hides every
  /// guide entry point.
  final VoidCallback? onOpenGuide;

  const UpcomingProgramTimeline({
    super.key,
    required this.programs,
    required this.channelId,
    required this.channelName,
    this.maxItems = 5,
    this.landscapeMaxItems = 12,
    this.onOpenGuide,
  });

  static const double _landscapeCardWidth = 300;
  static const double _landscapeCardHeight = 208;

  @override
  Widget build(BuildContext context) {
    final items = programs.whereType<Map>().toList();
    final pad = Responsive.contentPadding(context, base: 24);

    if (Responsive.isLandscape(context)) {
      final slider = items.take(landscapeMaxItems).toList();
      final hasEndTile = onOpenGuide != null;

      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.symmetric(horizontal: pad),
            child: _SectionHeader(onOpenGuide: onOpenGuide),
          ),
          const SizedBox(height: 16),
          if (slider.isEmpty)
            Padding(
              padding: EdgeInsets.symmetric(horizontal: pad),
              child: const Text(
                'No upcoming programmes.',
                style: TextStyle(color: Colors.white54),
              ),
            )
          else
            SizedBox(
              height: _landscapeCardHeight,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: EdgeInsets.symmetric(horizontal: pad),
                itemCount: slider.length + (hasEndTile ? 1 : 0),
                separatorBuilder: (_, __) => const SizedBox(width: 12),
                itemBuilder: (context, index) {
                  if (hasEndTile && index == slider.length) {
                    return _GuideEndTile(onTap: onOpenGuide!);
                  }
                  return SizedBox(
                    width: _landscapeCardWidth,
                    child: _ProgramCard(
                      program: slider[index],
                      channelId: channelId,
                      channelName: channelName,
                      isFirst: index == 0,
                      horizontal: true,
                    ),
                  );
                },
              ),
            ),
        ],
      );
    }

    final shown = items.take(maxItems).toList();
    final extra = items.length - shown.length;
    // With the guide button below the list, "+N more" moves into it, so
    // the rail no longer needs to run on past the last card.
    final railContinues = extra > 0 && onOpenGuide == null;

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: pad),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionHeader(onOpenGuide: onOpenGuide),
          const SizedBox(height: 16),
          if (shown.isEmpty)
            const Text(
              'No upcoming programmes.',
              style: TextStyle(color: Colors.white54),
            ),
          for (var i = 0; i < shown.length; i++)
            _TimelineRow(
              program: shown[i],
              channelId: channelId,
              channelName: channelName,
              isFirst: i == 0,
              isLast: i == shown.length - 1 && !railContinues,
            ),
          if (railContinues)
            Padding(
              padding: const EdgeInsets.only(left: 66, top: 2),
              child: Text(
                '+$extra more scheduled',
                style: const TextStyle(color: Colors.white54, fontSize: 13),
              ),
            ),
          if (onOpenGuide != null && shown.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: _GuideButton(onTap: onOpenGuide!, extra: extra),
            ),
        ],
      ),
    );
  }
}

/// "in 28 min" / "in 1h 12m" for a programme that hasn't started yet;
/// empty once it has.
String _startsIn(dynamic startValue) {
  final start = EpgUtils.parseProgramTime(startValue);
  if (start == null) return '';
  final now = DateTime.now();
  if (!start.isAfter(now)) return '';
  final mins = start.difference(now).inMinutes;
  if (mins < 1) return 'starting now';
  if (mins < 60) return 'in $mins min';
  final h = mins ~/ 60, m = mins % 60;
  return m == 0 ? 'in ${h}h' : 'in ${h}h ${m}m';
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.onOpenGuide});

  final VoidCallback? onOpenGuide;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Expanded(
          child: Text(
            'Coming Up',
            style: TextStyle(
              color: Colors.white,
              fontSize: 24,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        if (onOpenGuide != null)
          Semantics(
            button: true,
            label: 'Open full TV guide',
            child: Pressable(
              unconstrained: true,
              onTap: onOpenGuide,
              child: Container(
                padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: _gold.withValues(alpha: 0.45)),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Full guide',
                      style: TextStyle(
                        color: _goldSoft,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    SizedBox(width: 2),
                    Icon(
                      Icons.chevron_right_rounded,
                      size: 18,
                      color: _goldSoft,
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

/// Full-width "Open full TV guide" button under the portrait timeline.
class _GuideButton extends StatelessWidget {
  const _GuideButton({required this.onTap, required this.extra});

  final VoidCallback onTap;
  final int extra;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Open full TV guide',
      child: Pressable(
        unconstrained: true,
        onTap: onTap,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 13),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: _gold.withValues(alpha: 0.45)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.calendar_view_week_rounded,
                size: 18,
                color: _goldSoft,
              ),
              const SizedBox(width: 8),
              const Text(
                'Open full TV guide',
                style: TextStyle(
                  color: _goldSoft,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (extra > 0) ...[
                const SizedBox(width: 6),
                Text(
                  '· +$extra more',
                  style: TextStyle(
                    color: _goldSoft.withValues(alpha: 0.65),
                    fontSize: 12,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Last item of the landscape slider: a bare gold chevron with a caption,
/// sitting straight on the page (same treatment as the "View all" tiles).
class _GuideEndTile extends StatelessWidget {
  const _GuideEndTile({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Open full TV guide',
      child: Pressable(
        unconstrained: true,
        onTap: onTap,
        child: const SizedBox(
          width: 96,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.chevron_right_rounded, size: 44, color: _gold),
              SizedBox(height: 6),
              Text(
                'Full TV guide',
                textAlign: TextAlign.center,
                maxLines: 2,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Round bell that sets/clears a programme's reminder. Hidden for a
/// programme with no id or one that has already started.
class _BellButton extends StatelessWidget {
  const _BellButton({
    required this.program,
    required this.channelId,
    required this.channelName,
  });

  final Map program;
  final String channelId;
  final String channelName;

  Future<void> _onTap(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final result = await LiveTvReminderService.instance.toggle(
      program: program,
      channelId: channelId,
      channelName: channelName,
    );
    final msg = switch (result) {
      ReminderResult.set =>
        'Reminder set. You\'ll be told ${LiveTvReminderService.leadTime.inMinutes} minutes before it starts.',
      ReminderResult.cleared => 'Reminder removed.',
      ReminderResult.permissionDenied =>
        'Allow notifications for Trigon in system settings to get reminders.',
      ReminderResult.alreadyStarted => 'This programme has already started.',
    };
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final id = program['Id']?.toString();
    final startsInFuture = (EpgUtils.parseProgramTime(program['StartDate']) ??
            DateTime.fromMillisecondsSinceEpoch(0))
        .isAfter(DateTime.now());
    if (id == null || !startsInFuture) return const SizedBox.shrink();

    return ValueListenableBuilder<Set<String>>(
      valueListenable: LiveTvReminderService.instance.reminded,
      builder: (context, set, _) {
        final on = set.contains(id);
        return Semantics(
          button: true,
          label: on ? 'Remove reminder' : 'Remind me',
          child: Pressable(
            unconstrained: true,
            onTap: () => _onTap(context),
            child: SizedBox(
              width: 40,
              height: 40,
              child: Center(
                child: Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: on
                        ? _gold.withValues(alpha: 0.18)
                        : Colors.white.withValues(alpha: 0.06),
                  ),
                  child: Icon(
                    on
                        ? Icons.notifications_active_rounded
                        : Icons.notifications_none_rounded,
                    color: on ? _gold : Colors.white60,
                    size: 19,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// "Up next" pill + "in 28 min" countdown.
class _UpNextRow extends StatelessWidget {
  const _UpNextRow({required this.startsIn});

  final String startsIn;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: _gold,
            borderRadius: BorderRadius.circular(20),
          ),
          child: const Text(
            'Up next',
            style: TextStyle(
              color: Color(0xff2A2100),
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        if (startsIn.isNotEmpty) ...[
          const SizedBox(width: 8),
          Text(
            startsIn,
            style: const TextStyle(color: _goldSoft, fontSize: 11),
          ),
        ],
      ],
    );
  }
}

/// One programme card, shared by the portrait timeline and the landscape
/// slider. [horizontal] fills the height it is given (the slider's fixed
/// row height) and lets the description take whatever room is left.
class _ProgramCard extends StatelessWidget {
  const _ProgramCard({
    required this.program,
    required this.channelId,
    required this.channelName,
    required this.isFirst,
    required this.horizontal,
  });

  final Map program;
  final String channelId;
  final String channelName;
  final bool isFirst;
  final bool horizontal;

  @override
  Widget build(BuildContext context) {
    final start = EpgUtils.formatTime(program['StartDate']);
    final end = EpgUtils.formatTime(program['EndDate']);
    final day = EpgUtils.formatDay(program['StartDate']);
    final duration =
        EpgUtils.formatDuration(program['StartDate'], program['EndDate']);
    final overview = (program['Overview'] ?? '').toString();
    final startsIn = isFirst ? _startsIn(program['StartDate']) : '';

    final decoration = BoxDecoration(
      color: isFirst ? const Color(0xff1d1d1d) : const Color(0xff1a1a1a),
      borderRadius: BorderRadius.circular(18),
      border: Border.all(
        color: isFirst
            ? _gold.withValues(alpha: 0.45)
            : Colors.white.withValues(alpha: 0.08),
      ),
    );

    final title = Text(
      (program['Name'] ?? '').toString(),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 16,
        fontWeight: FontWeight.w600,
      ),
    );

    final bell = _BellButton(
      program: program,
      channelId: channelId,
      channelName: channelName,
    );

    final Widget card;
    if (horizontal) {
      final range = [
        if (day.isNotEmpty) day,
        '$start to $end',
        if (duration.isNotEmpty) duration,
      ].join(' · ');

      card = Container(
        padding: const EdgeInsets.fromLTRB(14, 8, 6, 14),
        decoration: decoration,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              height: 40,
              child: Row(
                children: [
                  if (isFirst)
                    _UpNextRow(startsIn: startsIn)
                  else
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 3),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.07),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        day.isEmpty ? start : '$start · $day',
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 11,
                        ),
                      ),
                    ),
                  const Spacer(),
                  bell,
                ],
              ),
            ),
            const SizedBox(height: 4),
            title,
            const SizedBox(height: 4),
            Text(
              range,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
            const SizedBox(height: 6),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Text(
                  overview.isEmpty ? 'No description available.' : overview,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white60,
                    fontSize: 13,
                    height: 1.45,
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    } else {
      card = Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
        decoration: decoration,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (isFirst) ...[
                    _UpNextRow(startsIn: startsIn),
                    const SizedBox(height: 8),
                  ],
                  title,
                  const SizedBox(height: 4),
                  Text(
                    duration.isEmpty
                        ? '$start to $end'
                        : '$duration · $start to $end',
                    style:
                        const TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    overview.isEmpty ? 'No description available.' : overview,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white60,
                      fontSize: 13,
                      height: 1.45,
                    ),
                  ),
                ],
              ),
            ),
            bell,
          ],
        ),
      );
    }

    return Pressable(
      // Scale-only press feedback: a ripple would be painted underneath
      // the card's own opaque Container anyway.
      unconstrained: true,
      onTap: () => showUpcomingProgramSheet(
        context,
        program: program,
        channelId: channelId,
        channelName: channelName,
      ),
      child: card,
    );
  }
}

class _TimelineRow extends StatelessWidget {
  final Map program;
  final String channelId;
  final String channelName;
  final bool isFirst;
  final bool isLast;

  const _TimelineRow({
    required this.program,
    required this.channelId,
    required this.channelName,
    required this.isFirst,
    required this.isLast,
  });

  @override
  Widget build(BuildContext context) {
    final start = EpgUtils.formatTime(program['StartDate']);
    final day = EpgUtils.formatDay(program['StartDate']);

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 44,
            child: Padding(
              padding: const EdgeInsets.only(top: 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    start,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    day,
                    style:
                        const TextStyle(color: Colors.white38, fontSize: 11),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 12,
            child: Column(
              children: [
                const SizedBox(height: 18),
                Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: isFirst ? _gold : const Color(0xff141414),
                    border: isFirst
                        ? null
                        : Border.all(color: Colors.white38, width: 2),
                  ),
                ),
                if (!isLast)
                  Expanded(
                    child: Container(
                      width: 2,
                      color: Colors.white.withValues(alpha: 0.12),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _ProgramCard(
                program: program,
                channelId: channelId,
                channelName: channelName,
                isFirst: isFirst,
                horizontal: false,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
