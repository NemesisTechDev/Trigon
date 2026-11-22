import 'package:shared_preferences/shared_preferences.dart';

/// Client-side slowdown for repeated failed sign-ins (exponential backoff).
///
/// HONEST SCOPE: this is a UX and politeness layer. Anyone can bypass an
/// on-device counter by calling Firebase directly, so the protection that
/// actually counts is Firebase Auth's own server-side throttling
/// (`too-many-requests`) plus App Check. This class stops accidental
/// hammering from the real app, makes password guessing through the UI
/// slow, and gives people a clear message instead of a raw server error.
class AuthLockout {
  AuthLockout._();

  static const String _failuresKey = 'auth_fail_count_v1';
  static const String _lockedUntilKey = 'auth_locked_until_ms_v1';

  /// Failures that are allowed before the first lock kicks in. With 4, the
  /// 4th wrong password locks for [_base], the 5th for 2x, then 4x, ...
  static const int freeAttempts = 4;
  static const Duration _base = Duration(seconds: 30);
  static const Duration max = Duration(minutes: 15);

  /// Time left on the current lock, or [Duration.zero] when not locked.
  static Future<Duration> remaining() async {
    final prefs = await SharedPreferences.getInstance();
    final until = prefs.getInt(_lockedUntilKey) ?? 0;
    if (until == 0) return Duration.zero;
    final now = DateTime.now().millisecondsSinceEpoch;
    var left = until - now;
    if (left <= 0) return Duration.zero;
    // If the device clock was moved around, never lock for longer than the
    // maximum we'd ever have set.
    if (left > max.inMilliseconds) left = max.inMilliseconds;
    return Duration(milliseconds: left);
  }

  /// Call after a failed sign-in. Returns the lock now in force (may be zero).
  static Future<Duration> recordFailure() async {
    final prefs = await SharedPreferences.getInstance();
    final failures = (prefs.getInt(_failuresKey) ?? 0) + 1;
    await prefs.setInt(_failuresKey, failures);

    final over = failures - (freeAttempts - 1);
    if (over < 1) return Duration.zero;

    final shift = over - 1 > 10 ? 10 : over - 1;
    var lock = Duration(seconds: _base.inSeconds * (1 << shift));
    if (lock > max) lock = max;
    await prefs.setInt(
      _lockedUntilKey,
      DateTime.now().add(lock).millisecondsSinceEpoch,
    );
    return lock;
  }

  /// Call after a successful sign-in.
  static Future<void> reset() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_failuresKey);
    await prefs.remove(_lockedUntilKey);
  }

  /// "30 seconds", "1 minute", "5 minutes" ...
  static String describe(Duration d) {
    final seconds = d.inSeconds < 1 ? 1 : d.inSeconds;
    if (seconds < 60) return '$seconds second${seconds == 1 ? '' : 's'}';
    final minutes = (seconds / 60).ceil();
    return '$minutes minute${minutes == 1 ? '' : 's'}';
  }
}

/// Simple per-action cooldown (e.g. "resend verification email",
/// "send password reset") so the buttons can't be used to spam an inbox.
class AuthCooldown {
  AuthCooldown._();

  static const String _prefix = 'auth_cooldown_until_ms_v1_';

  static Future<Duration> remaining(String action) async {
    final prefs = await SharedPreferences.getInstance();
    final until = prefs.getInt('$_prefix$action') ?? 0;
    final left = until - DateTime.now().millisecondsSinceEpoch;
    return left > 0 ? Duration(milliseconds: left) : Duration.zero;
  }

  static Future<void> start(String action, Duration length) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(
      '$_prefix$action',
      DateTime.now().add(length).millisecondsSinceEpoch,
    );
  }
}
