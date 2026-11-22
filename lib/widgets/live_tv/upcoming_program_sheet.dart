import 'package:flutter/material.dart';

import '../../services/live_tv_reminder_service.dart';
import '../../utils/epg_utils.dart';
import '../shared/nemesis_bottom_sheet.dart';

const _gold = Color(0xffD4AF37);
const _goldSoft = Color(0xffE8C75A);

/// Bottom sheet opened by tapping a "Coming Up" card on the Live TV
/// detail screen: the programme's title, when it airs, a short
/// description, and two actions —
///  * "Remind me": the same per-programme reminder the card's bell
///    toggles ([LiveTvReminderService]); the switch listens to
///    [LiveTvReminderService.reminded], so it always agrees with the
///    bell on the card underneath.
///  * "Record to watch later": a placeholder for now — tapping it only
///    shows a "coming soon" note.
///
/// Same chrome as every other pop-up in the app ([showNemesisBottomSheet]).
Future<void> showUpcomingProgramSheet(
  BuildContext context, {
  required Map program,
  required String channelId,
  required String channelName,
}) {
  return showNemesisBottomSheet<void>(
    context,
    builder: (sheetContext, controller) => _UpcomingProgramSheet(
      program: program,
      channelId: channelId,
      channelName: channelName,
      controller: controller,
    ),
  );
}

class _UpcomingProgramSheet extends StatefulWidget {
  const _UpcomingProgramSheet({
    required this.program,
    required this.channelId,
    required this.channelName,
    required this.controller,
  });

  final Map program;
  final String channelId;
  final String channelName;
  final ScrollController controller;

  @override
  State<_UpcomingProgramSheet> createState() => _UpcomingProgramSheetState();
}

class _UpcomingProgramSheetState extends State<_UpcomingProgramSheet> {
  /// Inline feedback line under the actions. A SnackBar would show on
  /// the screen *behind* this sheet (the sheet covers it), so messages
  /// live here instead.
  String? _note;

  Future<void> _toggleReminder() async {
    final result = await LiveTvReminderService.instance.toggle(
      program: widget.program,
      channelId: widget.channelId,
      channelName: widget.channelName,
    );
    if (!mounted) return;
    setState(() {
      _note = switch (result) {
        ReminderResult.set => null,
        ReminderResult.cleared => null,
        ReminderResult.permissionDenied =>
          'Allow notifications for Trigon in system settings to get reminders.',
        ReminderResult.alreadyStarted => 'This programme has already started.',
      };
    });
  }

  void _onRecordTap() {
    setState(() {
      _note = 'Recording is coming soon. For now, set a reminder and watch '
          'it live when it starts.';
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.program;
    final id = p['Id']?.toString();
    final title = (p['Name'] ?? '').toString();
    final start = EpgUtils.formatTime(p['StartDate']);
    final end = EpgUtils.formatTime(p['EndDate']);
    final day = EpgUtils.formatDay(p['StartDate']);
    final date = EpgUtils.formatDate(p['StartDate']);
    final duration = EpgUtils.formatDuration(p['StartDate'], p['EndDate']);
    final overview = (p['Overview'] ?? '').toString();
    final genres = (p['Genres'] is List)
        ? (p['Genres'] as List).map((g) => g.toString()).take(2).toList()
        : <String>[];
    final startsInFuture = (EpgUtils.parseProgramTime(p['StartDate']) ??
            DateTime.fromMillisecondsSinceEpoch(0))
        .isAfter(DateTime.now());

    final whenLabel = [
      if (day.isNotEmpty && date.isNotEmpty)
        '$day, $date'
      else if (day.isNotEmpty)
        day,
      if (start.isNotEmpty && end.isNotEmpty) '$start to $end',
    ].join(' · ');

    return ListView(
      controller: widget.controller,
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      children: [
        const NemesisSheetDragHandle(bottomMargin: 16),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            if (whenLabel.isNotEmpty) _SheetChip(whenLabel, gold: true),
            if (duration.isNotEmpty) _SheetChip(duration),
            for (final g in genres) _SheetChip(g),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          title,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 24,
            fontWeight: FontWeight.bold,
            height: 1.15,
          ),
        ),
        if (widget.channelName.isNotEmpty) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              const Icon(Icons.live_tv_rounded, size: 15, color: Colors.white54),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  widget.channelName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white60, fontSize: 13),
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: 14),
        Text(
          overview.isEmpty ? 'No description available.' : overview,
          style: const TextStyle(
            color: Colors.white70,
            fontSize: 13.5,
            height: 1.55,
          ),
        ),
        const SizedBox(height: 18),
        const Divider(height: 1, color: Colors.white10),
        ValueListenableBuilder<Set<String>>(
          valueListenable: LiveTvReminderService.instance.reminded,
          builder: (context, set, _) {
            final on = id != null && set.contains(id);
            return _ActionRow(
              icon: on
                  ? Icons.notifications_active_rounded
                  : Icons.notifications_none_rounded,
              iconActive: on,
              title: 'Remind me',
              subtitle: on
                  ? 'You\'ll be told ${LiveTvReminderService.leadTime.inMinutes} '
                      'minutes before it starts'
                  : startsInFuture
                      ? 'Get a notification '
                          '${LiveTvReminderService.leadTime.inMinutes} minutes '
                          'before it starts'
                      : 'This programme has already started',
              trailing: Switch(
                value: on,
                onChanged: id == null ? null : (_) => _toggleReminder(),
                activeColor: _gold,
              ),
              onTap: id == null ? null : _toggleReminder,
            );
          },
        ),
        const Divider(height: 1, color: Colors.white10),
        _ActionRow(
          icon: Icons.fiber_manual_record_rounded,
          iconActive: false,
          title: 'Record to watch later',
          subtitle: 'Save it so you can watch after it airs',
          trailing: const _SheetChip('Coming soon'),
          onTap: _onRecordTap,
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 200),
          alignment: Alignment.topLeft,
          child: _note == null
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(
                    _note!,
                    style: const TextStyle(
                      color: _goldSoft,
                      fontSize: 12.5,
                      height: 1.4,
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.icon,
    required this.iconActive,
    required this.title,
    required this.subtitle,
    required this.trailing,
    required this.onTap,
  });

  final IconData icon;
  final bool iconActive;
  final String title;
  final String subtitle;
  final Widget trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: iconActive
                      ? _gold.withValues(alpha: 0.18)
                      : Colors.white.withValues(alpha: 0.07),
                ),
                child: Icon(
                  icon,
                  size: 21,
                  color: iconActive ? _gold : Colors.white70,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 12,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              trailing,
            ],
          ),
        ),
      ),
    );
  }
}

class _SheetChip extends StatelessWidget {
  const _SheetChip(this.label, {this.gold = false});

  final String label;
  final bool gold;

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
