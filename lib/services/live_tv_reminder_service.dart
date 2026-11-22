import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
// NOTE: `timezone` is already in the dependency tree (flutter_local_notifications
// requires it). Add `timezone:` to pubspec.yaml too so this import doesn't trip
// the depend_on_referenced_packages lint.
import 'package:timezone/timezone.dart' as tz;

import '../screens/live_tv/live_tv_detail_screen.dart';
import '../screens/main_nav/navigation_controller.dart';
import '../services/external_media_handler.dart';
import '../utils/epg_utils.dart';

/// What happened when a reminder was toggled — lets the UI pick the
/// right SnackBar without knowing anything about notifications.
enum ReminderResult { set, cleared, permissionDenied, alreadyStarted }

/// Per-programme "remind me" for Live TV's Coming Up timeline.
///
/// ROOT-CAUSE NOTES (why it's built this way):
///  - [FlutterLocalNotificationsPlugin] is a process-wide singleton and
///    DownloadNotificationService.init() already calls `initialize()` on
///    it with its own tap callback. A second `initialize()` would
///    silently REPLACE that callback and break download-notification
///    taps, so this service never initializes the plugin itself — it
///    only creates its own Android channel and schedules through the
///    already-initialized plugin. Taps arrive in
///    DownloadNotificationService._onResponse, which hands any payload
///    starting with [payloadPrefix] to [handleTap] below.
///  - Reminders are scheduled against `tz.UTC` using the programme's
///    absolute instant, so no device-timezone lookup package is needed
///    and a timezone change can't shift when one fires.
///  - Records are mirrored in SharedPreferences and re-scheduled on
///    [init] (same notification id => replaces, never duplicates), so a
///    reminder survives cleared notification state; the plugin's own
///    boot receiver covers reboots.
class LiveTvReminderService {
  LiveTvReminderService._();
  static final LiveTvReminderService instance = LiveTvReminderService._();

  static const payloadPrefix = 'ltv_reminder:';
  static const _channelId = 'nemesis_live_tv_reminders';
  static const _prefsKey = 'live_tv_reminders_v1';

  /// How long before a programme starts the reminder fires.
  static const leadTime = Duration(minutes: 5);

  final _plugin = FlutterLocalNotificationsPlugin();

  /// Programme ids that currently have a reminder. Tiles listen to this
  /// so the bell updates everywhere without a rebuild of the screen.
  final ValueNotifier<Set<String>> reminded = ValueNotifier(<String>{});

  final Map<String, _Reminder> _records = {};
  bool _initialized = false;

  static bool isReminderPayload(String? p) =>
      p != null && p.startsWith(payloadPrefix);

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    try {
      await _plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(
            const AndroidNotificationChannel(
              _channelId,
              'Live TV reminders',
              description: 'Reminders for programmes you chose to be told about.',
              importance: Importance.high,
            ),
          );

      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw != null) {
        for (final e in (jsonDecode(raw) as List)) {
          final r = _Reminder.fromJson(Map<String, dynamic>.from(e));
          // Drop anything whose programme has already started.
          if (r.start.isAfter(DateTime.now())) _records[r.programId] = r;
        }
      }
      await _persist(prefs);
      reminded.value = _records.keys.toSet();

      // Re-assert every surviving schedule (same id => replace).
      for (final r in _records.values) {
        await _schedule(r);
      }
    } catch (e) {
      debugPrint('LiveTvReminderService.init failed: $e');
    }
  }

  bool isSet(String programId) => _records.containsKey(programId);

  Future<ReminderResult> toggle({
    required Map program,
    required String channelId,
    required String channelName,
  }) async {
    final programId = program['Id']?.toString();
    final start = EpgUtils.parseProgramTime(program['StartDate']);
    if (programId == null || start == null) return ReminderResult.alreadyStarted;

    if (_records.containsKey(programId)) {
      await _cancel(programId);
      return ReminderResult.cleared;
    }

    if (!start.isAfter(DateTime.now())) return ReminderResult.alreadyStarted;

    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    // Android 13+: runtime permission. Returns null on older versions
    // where it isn't needed.
    final granted = await android?.requestNotificationsPermission();
    if (granted == false) return ReminderResult.permissionDenied;

    final r = _Reminder(
      programId: programId,
      channelId: channelId,
      channelName: channelName,
      title: (program['Name'] ?? 'Live programme').toString(),
      start: start,
    );
    _records[programId] = r;
    await _schedule(r);
    await _persistAndPublish();
    return ReminderResult.set;
  }

  Future<void> _cancel(String programId) async {
    _records.remove(programId);
    try {
      await _plugin.cancel(id: _idFor(programId));
    } catch (_) {}
    await _persistAndPublish();
  }

  Future<void> _schedule(_Reminder r) async {
    final now = DateTime.now();
    var fireAt = r.start.subtract(leadTime);
    // Inside the lead window already: fire a few seconds from now
    // rather than skipping the reminder the person just asked for.
    if (!fireAt.isAfter(now)) fireAt = now.add(const Duration(seconds: 3));
    if (!r.start.isAfter(now)) return;

    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    // Exact when the OS allows it (SCHEDULE_EXACT_ALARM granted),
    // otherwise inexact — a reminder a few minutes late beats none.
    final exactOk = (await android?.canScheduleExactNotifications()) ?? false;

    await _plugin.zonedSchedule(
      id: _idFor(r.programId),
      title: 'Starting soon: ${r.title}',
      body: '${EpgUtils.formatTime(r.start.toUtc().toIso8601String())} · '
          '${r.channelName} — tap to open the channel',
      scheduledDate: tz.TZDateTime.from(fireAt, tz.UTC),
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          'Live TV reminders',
          channelDescription:
              'Reminders for programmes you chose to be told about.',
          importance: Importance.high,
          priority: Priority.high,
          autoCancel: true,
        ),
      ),
      androidScheduleMode: exactOk
          ? AndroidScheduleMode.exactAllowWhileIdle
          : AndroidScheduleMode.inexactAllowWhileIdle,
      payload: '$payloadPrefix${r.channelId}',
    );
  }

  Future<void> _persistAndPublish() async {
    reminded.value = _records.keys.toSet();
    try {
      await _persist(await SharedPreferences.getInstance());
    } catch (_) {}
  }

  Future<void> _persist(SharedPreferences prefs) => prefs.setString(
        _prefsKey,
        jsonEncode(_records.values.map((r) => r.toJson()).toList()),
      );

  /// Deterministic (FNV-1a) so the same programme maps to the same
  /// notification id across launches and Dart versions — String.hashCode
  /// makes no such promise, and a drifting id would leave a stale
  /// duplicate scheduled on every relaunch.
  int _idFor(String programId) {
    var h = 0x811c9dc5;
    for (final c in 'ltv:$programId'.codeUnits) {
      h ^= c;
      h = (h * 0x01000193) & 0xffffffff;
    }
    return h & 0x7ffffffd;
  }

  // ───────────────────────────── Tap handling ─────────────────────────────

  /// Opens the reminded channel's detail screen inside the main nav
  /// shell. On a cold start the content Navigator doesn't exist yet, so
  /// this polls briefly (post-frame cadence) until MainNavScreen mounts.
  void handleTap(String payload) {
    final channelId = payload.substring(payloadPrefix.length);
    if (channelId.isEmpty) return;

    var attempts = 0;
    Timer.periodic(const Duration(milliseconds: 300), (t) {
      attempts++;
      final nav = NavigationController.instance;
      final content = nav.contentNavigatorKey?.currentState;
      if (content != null) {
        t.cancel();
        // Clear anything above the shell (player, sheets), then land on
        // the Live TV tab with the channel's detail pushed on top.
        ExternalMediaHandler.instance.navigatorKey.currentState
            ?.popUntil((route) => route.isFirst);
        content.popUntil((route) => route.isFirst);
        nav.goToTab(NavTabs.liveTv);
        content.push(MaterialPageRoute(
          builder: (_) => LiveTvDetailScreen(channelId: channelId),
        ));
      } else if (attempts >= 25) {
        t.cancel(); // ~7.5s: give up rather than poll forever.
      }
    });
  }
}

class _Reminder {
  final String programId;
  final String channelId;
  final String channelName;
  final String title;
  final DateTime start;

  _Reminder({
    required this.programId,
    required this.channelId,
    required this.channelName,
    required this.title,
    required this.start,
  });

  Map<String, dynamic> toJson() => {
        'p': programId,
        'c': channelId,
        'n': channelName,
        't': title,
        's': start.millisecondsSinceEpoch,
      };

  factory _Reminder.fromJson(Map<String, dynamic> j) => _Reminder(
        programId: j['p'] as String,
        channelId: j['c'] as String,
        channelName: (j['n'] ?? '') as String,
        title: (j['t'] ?? '') as String,
        start: DateTime.fromMillisecondsSinceEpoch(j['s'] as int),
      );
}
