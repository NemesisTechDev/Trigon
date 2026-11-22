import 'package:flutter/material.dart';

import '../../../services/parental/parental_controls.dart';
import '../../../services/parental/parental_models.dart';
import '../../../services/parental/viewing_time_service.dart';
import 'parental_widgets.dart';

const _dayNames = [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];
const _dayInitials = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];

/// Daily watch limit (per weekday) and bedtime.
class ScreenTimeScreen extends StatefulWidget {
  const ScreenTimeScreen({super.key});

  @override
  State<ScreenTimeScreen> createState() => _ScreenTimeScreenState();
}

class _ScreenTimeScreenState extends State<ScreenTimeScreen> {
  final ParentalControls _pc = ParentalControls.instance;

  ParentalSettings get _s => _pc.settings.value;

  Future<void> _update(ParentalSettings Function(ParentalSettings) f) async {
    await _pc.save(f(_s));
    if (mounted) setState(() {});
  }

  // ---------------------------------------------------------- daily limit

  String _limitText(int? minutes) =>
      minutes == null ? 'No limit' : ScreenTime.formatMinutes(minutes);

  /// Opens the slider sheet. Returns the chosen limit; `-1` = no limit,
  /// null = cancelled.
  Future<int?> _pickLimit(String title, int? current) {
    // Slider steps of 15 minutes: 0 = no limit, up to 8 hours.
    var steps = ((current ?? 0) / 15).round().clamp(0, 32);
    return showModalBottomSheet<int>(
      context: context,
      useRootNavigator: true,
      backgroundColor: const Color(0xff181818),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          final minutes = steps * 15;
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(title,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w700)),
                  const SizedBox(height: 14),
                  Text(
                    steps == 0 ? 'No limit' : ScreenTime.formatMinutes(minutes),
                    style: const TextStyle(
                        color: pcGold,
                        fontSize: 30,
                        fontWeight: FontWeight.w700),
                  ),
                  Slider(
                    value: steps.toDouble(),
                    min: 0,
                    max: 32,
                    divisions: 32,
                    activeColor: pcGold,
                    inactiveColor: Colors.white12,
                    onChanged: (v) => setSheet(() => steps = v.round()),
                  ),
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final m in const [30, 60, 120, 180])
                        ActionChip(
                          label: Text(ScreenTime.formatMinutes(m)),
                          backgroundColor: pcCardBg,
                          labelStyle: const TextStyle(
                              color: Colors.white70, fontSize: 12),
                          side: const BorderSide(color: Colors.white12),
                          onPressed: () => setSheet(() => steps = m ~/ 15),
                        ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: pcGold,
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14)),
                      ),
                      onPressed: () => Navigator.of(sheetCtx)
                          .pop(steps == 0 ? -1 : steps * 15),
                      child: const Text('Save',
                          style: TextStyle(fontWeight: FontWeight.w700)),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _editDay(int index) async {
    final r = await _pickLimit(_dayNames[index], _s.dailyLimitMinutes[index]);
    if (r == null) return;
    final list = [..._s.dailyLimitMinutes];
    list[index] = r < 0 ? null : r;
    await _update((c) => c.copyWith(dailyLimitMinutes: list));
  }

  Future<void> _setAll() async {
    final first = _s.dailyLimitMinutes.firstWhere((m) => m != null,
        orElse: () => null);
    final r = await _pickLimit('Every day', first);
    if (r == null) return;
    await _update((c) => c.copyWith(
          dailyLimitMinutes: List<int?>.filled(7, r < 0 ? null : r),
        ));
  }

  // -------------------------------------------------------------- bedtime

  Future<void> _pickTime({required bool start}) async {
    final current = start ? _s.bedtimeStartMin : _s.bedtimeEndMin;
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: current ~/ 60, minute: current % 60),
      helpText: start ? 'BEDTIME STARTS' : 'BEDTIME ENDS',
      builder: (ctx, child) => Theme(
        data: Theme.of(ctx).copyWith(
          colorScheme: const ColorScheme.dark(
            primary: pcGold,
            onPrimary: Colors.black,
            surface: Color(0xff1F1F1F),
          ),
        ),
        child: child!,
      ),
    );
    if (t == null) return;
    final minutes = t.hour * 60 + t.minute;
    await _update((c) => start
        ? c.copyWith(bedtimeStartMin: minutes)
        : c.copyWith(bedtimeEndMin: minutes));
  }

  Future<void> _toggleDay(int weekday) async {
    final days = {..._s.bedtimeDays};
    if (days.contains(weekday)) {
      if (days.length == 1) return; // keep at least one night
      days.remove(weekday);
    } else {
      days.add(weekday);
    }
    await _update((c) => c.copyWith(bedtimeDays: days));
  }

  // --------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final s = _s;
    return PcPage(
      title: 'Screen time',
      children: [
        // Today
        ValueListenableBuilder<int>(
          valueListenable: ViewingTimeService.instance.usedSeconds,
          builder: (context, used, _) {
            final limit = ScreenTime.limitFor(s, DateTime.now());
            final usedMin = used ~/ 60;
            return PcBanner(
              icon: Icons.insights_outlined,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Watched today: ${ScreenTime.formatMinutes(usedMin)}',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(
                    limit == null
                        ? 'No daily limit today. Music does not count.'
                        : 'Limit today: ${ScreenTime.formatMinutes(limit)}. Music does not count.',
                    style: const TextStyle(
                        color: Colors.white54, fontSize: 12, height: 1.35),
                  ),
                  if (limit != null) ...[
                    const SizedBox(height: 10),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: (used / (limit * 60)).clamp(0.0, 1.0),
                        minHeight: 6,
                        color: pcGold,
                        backgroundColor: Colors.white12,
                      ),
                    ),
                  ],
                ],
              ),
            );
          },
        ),

        PcSection(
          'Daily watch limit',
          hint: 'How long video can be watched each day. It resets at midnight.',
        ),
        PcTile(
          icon: Icons.edit_calendar_outlined,
          label: 'Set the same limit every day',
          subtitle: 'Quick way to fill in all seven days',
          onTap: _setAll,
        ),
        const SizedBox(height: 8),
        for (var i = 0; i < 7; i++) ...[
          PcTile(
            icon: Icons.timer_outlined,
            label: _dayNames[i],
            subtitle: _limitText(s.dailyLimitMinutes[i]),
            onTap: () => _editDay(i),
          ),
          const SizedBox(height: 8),
        ],

        const PcSection(
          'Bedtime',
          hint: 'Watching is paused during bedtime. A parent can allow more '
              'time with the PIN.',
        ),
        PcToggle(
          icon: Icons.bedtime_outlined,
          label: 'Bedtime',
          subtitle: s.bedtimeEnabled
              ? '${ScreenTime.formatClock(s.bedtimeStartMin)} to '
                  '${ScreenTime.formatClock(s.bedtimeEndMin)}'
              : 'Off',
          value: s.bedtimeEnabled,
          onChanged: (v) => _update((c) => c.copyWith(bedtimeEnabled: v)),
        ),
        if (s.bedtimeEnabled) ...[
          const SizedBox(height: 8),
          PcTile(
            icon: Icons.nights_stay_outlined,
            label: 'Starts',
            subtitle: ScreenTime.formatClock(s.bedtimeStartMin),
            onTap: () => _pickTime(start: true),
          ),
          const SizedBox(height: 8),
          PcTile(
            icon: Icons.wb_sunny_outlined,
            label: 'Ends',
            subtitle: ScreenTime.formatClock(s.bedtimeEndMin),
            onTap: () => _pickTime(start: false),
          ),
          const SizedBox(height: 14),
          const Text('On these nights',
              style: TextStyle(color: Colors.white54, fontSize: 13)),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              for (var i = 0; i < 7; i++)
                GestureDetector(
                  onTap: () => _toggleDay(i + 1),
                  child: Container(
                    width: 40,
                    height: 40,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: s.bedtimeDays.contains(i + 1)
                          ? pcGold
                          : pcCardBg,
                      border: Border.all(
                        color: s.bedtimeDays.contains(i + 1)
                            ? pcGold
                            : Colors.white12,
                      ),
                    ),
                    child: Text(
                      _dayInitials[i],
                      style: TextStyle(
                        color: s.bedtimeDays.contains(i + 1)
                            ? Colors.black
                            : Colors.white60,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'A night belongs to the day it starts on, so a Friday bedtime runs '
            'into Saturday morning.',
            style: TextStyle(color: Colors.white30, fontSize: 12, height: 1.35),
          ),
        ],
      ],
    );
  }
}
