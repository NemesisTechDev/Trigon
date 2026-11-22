import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../casting/cast_manager.dart';
import '../../casting/models/cast_states.dart';
import '../../player/player_manager.dart';
import '../../screens/profile/parental/parental_prompts.dart';
import 'parental_controls.dart';
import 'parental_models.dart';

/// Why watching is not allowed right now.
class TimeBlock {
  final BlockReason reason; // dailyLimit | bedtime
  final String title;
  final String message;

  /// When it ends by itself (bedtime ends / tomorrow), if known.
  final DateTime? endsAt;
  const TimeBlock(this.reason, this.title, this.message, {this.endsAt});
}

/// Counts how long video has been watched today and enforces the daily
/// limit and bedtime while something is playing (on this phone or cast to a
/// TV).
///
/// Time is counted from the wall clock between ticks, with each tick capped,
/// so a suspended app is not billed for time it was not playing. Music does
/// not count: these controls are about watching.
class ViewingTimeService {
  ViewingTimeService._();
  static final ViewingTimeService instance = ViewingTimeService._();

  static const String _kUsage = 'parental_usage_v1';
  static const Duration _warnAt = Duration(minutes: 5);

  /// Seconds watched today; the Parental Controls screen shows it.
  final ValueNotifier<int> usedSeconds = ValueNotifier(0);

  /// True while the embed web player (EmbedPlayerScreen) is open. It does
  /// not use PlayerManager, so without this its watch time would never be
  /// counted and the daily limit / bedtime could be sidestepped.
  final ValueNotifier<bool> externalWatching = ValueNotifier(false);

  /// Set by EmbedPlayerScreen: stop / restart its picture when a time block
  /// locks the screen (the native player is paused directly below).
  Future<void> Function()? onExternalPause;
  Future<void> Function()? onExternalResume;

  String _day = '';
  int _bonusMin = 0;
  int _overrideUntilMs = 0; // bedtime lifted by a parent until this time
  bool _warnedLimit = false;
  bool _warnedBedtime = false;

  Timer? _timer;
  DateTime? _lastTick;
  int _unsaved = 0;
  bool _locking = false;
  bool _started = false;

  static String _dayKey(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  // ----------------------------------------------------------------- init

  Future<void> init() async {
    if (_started) return;
    _started = true;
    await _load();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kUsage);
      if (raw != null) {
        final j = jsonDecode(raw);
        if (j is Map && j['d'] == _dayKey(DateTime.now())) {
          _day = j['d'] as String;
          usedSeconds.value = (j['s'] as num?)?.toInt() ?? 0;
          _bonusMin = (j['b'] as num?)?.toInt() ?? 0;
          _overrideUntilMs = (j['o'] as num?)?.toInt() ?? 0;
          _warnedLimit = j['w'] == true;
          return;
        }
      }
    } catch (_) {}
    _rollDay();
  }

  void _rollDay() {
    _day = _dayKey(DateTime.now());
    usedSeconds.value = 0;
    _bonusMin = 0;
    _overrideUntilMs = 0;
    _warnedLimit = false;
    _warnedBedtime = false;
  }

  Future<void> _save() async {
    _unsaved = 0;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _kUsage,
        jsonEncode({
          'd': _day,
          's': usedSeconds.value,
          'b': _bonusMin,
          'o': _overrideUntilMs,
          'w': _warnedLimit,
        }),
      );
    } catch (_) {}
  }

  Future<void> resetToday() async {
    _rollDay();
    await _save();
  }

  // ------------------------------------------------------------ watching

  bool get _isWatching {
    if (externalWatching.value) return true;
    try {
      final pm = PlayerManager.instance;
      final item = pm.currentItem;
      if (pm.playing.value && item != null && !item.audioOnly) return true;

      final cast = CastManager.instance.activeSession.value;
      if (cast != null &&
          cast.playbackState.value == CastPlaybackState.playing &&
          cast.currentItem.value?.audioOnly == false) {
        return true;
      }
    } catch (_) {}
    return false;
  }

  Future<void> _tick() async {
    final now = DateTime.now();
    final last = _lastTick;
    _lastTick = now;

    if (_dayKey(now) != _day) {
      _rollDay();
      unawaited(_save());
    }

    final controls = ParentalControls.instance;
    if (!controls.timeRulesActive || !_isWatching) return;

    // Count at most 5 s per tick (a suspended app must not be billed).
    var delta = last == null ? 1 : now.difference(last).inSeconds;
    if (delta < 1) delta = 1;
    if (delta > 5) delta = 5;
    usedSeconds.value += delta;
    _unsaved += delta;
    if (_unsaved >= 15) unawaited(_save());

    final block = blockNow();
    if (block != null) {
      await _enforce(block);
      return;
    }
    _maybeWarn(now);
  }

  void _maybeWarn(DateTime now) {
    final s = ParentalControls.instance.settings.value;
    final left = ScreenTime.secondsLeft(
      s,
      now,
      usedSeconds: usedSeconds.value,
      bonusMinutes: _bonusMin,
    );
    if (left != null && left <= _warnAt.inSeconds && !_warnedLimit) {
      _warnedLimit = true;
      unawaited(_save());
      ParentalPrompts.toast(
        '${ScreenTime.formatDuration(Duration(seconds: left))} of watch time left today.',
      );
    }
    final bed = ScreenTime.untilBedtime(s, now, within: _warnAt);
    if (bed != null && !_warnedBedtime && !_bedtimeLifted(now)) {
      _warnedBedtime = true;
      ParentalPrompts.toast(
        'Bedtime in ${ScreenTime.formatDuration(bed)}.',
      );
    }
  }

  // ------------------------------------------------------------- blocking

  bool _bedtimeLifted(DateTime now) =>
      _overrideUntilMs > now.millisecondsSinceEpoch;

  /// Non-null when watching is not allowed at this moment.
  TimeBlock? blockNow() {
    final controls = ParentalControls.instance;
    if (!controls.timeRulesActive) return null;
    final s = controls.settings.value;
    final now = DateTime.now();

    if (ScreenTime.isBedtime(s, now) && !_bedtimeLifted(now)) {
      final ends = ScreenTime.bedtimeEnds(s, now);
      return TimeBlock(
        BlockReason.bedtime,
        "It's bedtime",
        ends == null
            ? 'Watching is paused for the night.'
            : 'Watching is paused until ${ScreenTime.formatClock(ends.hour * 60 + ends.minute)}.',
        endsAt: ends,
      );
    }

    final left = ScreenTime.secondsLeft(
      s,
      now,
      usedSeconds: usedSeconds.value,
      bonusMinutes: _bonusMin,
    );
    if (left != null && left <= 0) {
      final limit = ScreenTime.limitFor(s, now)!;
      return TimeBlock(
        BlockReason.dailyLimit,
        "Time's up for today",
        "You've used your ${ScreenTime.formatMinutes(limit + _bonusMin)} of watch time today.",
        endsAt: DateTime(now.year, now.month, now.day)
            .add(const Duration(days: 1)),
      );
    }
    return null;
  }

  /// Today's remaining watch time, or null when there is no limit.
  Duration? get remainingToday {
    final s = ParentalControls.instance.settings.value;
    final left = ScreenTime.secondsLeft(
      s,
      DateTime.now(),
      usedSeconds: usedSeconds.value,
      bonusMinutes: _bonusMin,
    );
    return left == null ? null : Duration(seconds: left);
  }

  Future<void> _enforce(TimeBlock block) async {
    if (_locking) return;
    _locking = true;
    try {
      // Stop the picture first, then ask.
      try {
        await PlayerManager.instance.player.pause();
      } catch (_) {}
      try {
        await onExternalPause?.call();
      } catch (_) {}
      try {
        if (CastManager.instance.isCasting) await CastManager.instance.pause();
      } catch (_) {}

      final unlocked = await showLock(block);
      if (unlocked) {
        try {
          await PlayerManager.instance.player.play();
        } catch (_) {}
        try {
          await onExternalResume?.call();
        } catch (_) {}
        try {
          if (CastManager.instance.isCasting) await CastManager.instance.play();
        } catch (_) {}
      } else {
        try {
          if (CastManager.instance.isCasting) {
            await CastManager.instance.disconnect();
          }
        } catch (_) {}
        await ParentalPrompts.closePlayer();
      }
    } finally {
      _locking = false;
      _lastTick = DateTime.now();
    }
  }

  /// Shows the lock screen. True when a parent unlocked more time.
  Future<bool> showLock(TimeBlock block) =>
      ParentalPrompts.showTimeLock(block);

  // --------------------------------------------------------------- grants

  /// A parent granted [minutes] more watching today.
  Future<void> grantMinutes(int minutes) async {
    _bonusMin += minutes;
    _warnedLimit = false;
    await _save();
  }

  /// A parent lifted bedtime for [length].
  Future<void> liftBedtime(Duration length) async {
    _overrideUntilMs =
        DateTime.now().add(length).millisecondsSinceEpoch;
    _warnedBedtime = true;
    await _save();
  }
}
