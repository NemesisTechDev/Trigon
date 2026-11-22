import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'pin_hash.dart';

/// Result of checking a PIN.
class PinResult {
  final bool ok;

  /// Set while the PIN pad is locked after too many wrong tries.
  final Duration? locked;

  /// Wrong tries left before the next lock (only on a wrong PIN).
  final int? attemptsLeft;

  const PinResult._(this.ok, this.locked, this.attemptsLeft);
  const PinResult.success() : this._(true, null, null);
  const PinResult.wrong(int left) : this._(false, null, left);
  const PinResult.lockedFor(Duration d) : this._(false, d, 0);
}

/// Stores the parental PIN (as a salted hash, never the PIN itself) and
/// slows down guessing.
///
/// The hash lives in Keystore-backed secure storage under its OWN storage
/// namespace. StorageService wipes its default secure storage whenever a
/// read fails (to recover from a broken Keystore key after a reinstall); with
/// a separate namespace that clean-up can never silently delete the PIN.
///
/// HONEST SCOPE: like AuthLockout, the attempt counter is a deterrent that
/// lives on the device. It stops a child from guessing through the app's own
/// PIN pad (4 digits = 10,000 combinations, so every wrong answer past the
/// free tries costs a growing wait). It is not a defence against someone
/// who clears the app's data or uninstalls it - no in-app control can be.
class PinVault {
  PinVault._();

  static const String _kHash = 'parental_pin_hash_v1';
  static const String _kFails = 'parental_pin_fail_count_v1';
  static const String _kLockedUntil = 'parental_pin_locked_until_ms_v1';

  static const int pinLength = 4;

  /// Wrong tries allowed before the first lock.
  static const int freeAttempts = 5;
  static const Duration _base = Duration(seconds: 30);
  static const Duration maxLock = Duration(minutes: 30);

  static const FlutterSecureStorage _secure = FlutterSecureStorage(
    aOptions: AndroidOptions(
      storageNamespace: 'nemesis_parental',
      preferencesKeyPrefix: 'nemesis_parental',
    ),
  );

  static bool isValidFormat(String pin) =>
      pin.length == pinLength && RegExp(r'^[0-9]+$').hasMatch(pin);

  /// Very guessable PINs a parent should be warned about.
  static bool isWeak(String pin) {
    if (pin.length != pinLength) return false;
    if (RegExp(r'^(\d)\1+$').hasMatch(pin)) return true; // 1111
    const runs = ['0123', '1234', '2345', '3456', '4567', '5678', '6789',
        '9876', '8765', '7654', '6543', '5432', '4321', '3210'];
    return runs.contains(pin) || pin == '2580' || pin == '1212';
  }

  static Future<bool> hasPin() async {
    try {
      final v = await _secure.read(key: _kHash);
      return v != null && v.isNotEmpty;
    } catch (e) {
      debugPrint('[PinVault] read failed: ${e.runtimeType}');
      return false;
    }
  }

  static Future<void> setPin(String pin) async {
    if (!isValidFormat(pin)) {
      throw ArgumentError('PIN must be $pinLength digits');
    }
    await _secure.write(key: _kHash, value: PinHash.create(pin));
    await _resetFailures();
  }

  static Future<void> clearPin() async {
    try {
      await _secure.delete(key: _kHash);
    } catch (e) {
      debugPrint('[PinVault] delete failed: ${e.runtimeType}');
    }
    await _resetFailures();
  }

  /// Time left on the current lock (zero when not locked).
  static Future<Duration> lockRemaining() async {
    final prefs = await SharedPreferences.getInstance();
    final until = prefs.getInt(_kLockedUntil) ?? 0;
    if (until == 0) return Duration.zero;
    var left = until - DateTime.now().millisecondsSinceEpoch;
    if (left <= 0) return Duration.zero;
    // A clock moved far back must not lock someone out for longer than we
    // would ever have chosen to.
    if (left > maxLock.inMilliseconds) left = maxLock.inMilliseconds;
    return Duration(milliseconds: left);
  }

  /// Checks [pin]. Wrong answers are counted; right ones reset the counter.
  static Future<PinResult> verify(String pin) async {
    final locked = await lockRemaining();
    if (locked > Duration.zero) return PinResult.lockedFor(locked);

    String? stored;
    try {
      stored = await _secure.read(key: _kHash);
    } catch (e) {
      debugPrint('[PinVault] read failed: ${e.runtimeType}');
    }

    if (isValidFormat(pin) && PinHash.verify(pin, stored)) {
      await _resetFailures();
      return const PinResult.success();
    }
    return _recordFailure();
  }

  static Future<PinResult> _recordFailure() async {
    final prefs = await SharedPreferences.getInstance();
    final fails = (prefs.getInt(_kFails) ?? 0) + 1;
    await prefs.setInt(_kFails, fails);

    final over = fails - (freeAttempts - 1);
    if (over < 1) {
      return PinResult.wrong(freeAttempts - fails);
    }
    final shift = over - 1 > 10 ? 10 : over - 1;
    var lock = Duration(seconds: _base.inSeconds * (1 << shift));
    if (lock > maxLock) lock = maxLock;
    await prefs.setInt(
      _kLockedUntil,
      DateTime.now().add(lock).millisecondsSinceEpoch,
    );
    return PinResult.lockedFor(lock);
  }

  static Future<void> _resetFailures() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kFails);
    await prefs.remove(_kLockedUntil);
  }

  /// "30 seconds", "1 minute", "5 minutes" ...
  static String describeLock(Duration d) {
    final seconds = d.inSeconds < 1 ? 1 : d.inSeconds;
    if (seconds < 60) return '$seconds second${seconds == 1 ? '' : 's'}';
    final minutes = (seconds / 60).ceil();
    return '$minutes minute${minutes == 1 ? '' : 's'}';
  }
}
