// Pure Dart (needs only package:crypto): salted, iterated PIN hashing.
//
// PBKDF2-HMAC-SHA256. A 4-digit PIN only has 10,000 possible values, so no
// hash can make it truly brute-force proof on its own - the attempt lockout
// in PinVault is what really protects it. The salt + iterations just make
// sure the stored value is not a bare, pre-computable SHA-256 of the PIN.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

class PinHash {
  PinHash._();

  static const int iterations = 10000;
  static const int _saltBytes = 16;
  static const String _version = 'v1';

  /// Hashes [pin] with a fresh random salt. Result looks like
  /// `v1$10000$<salt b64>$<hash b64>`.
  static String create(String pin, {Random? random}) {
    final rng = random ?? Random.secure();
    final salt = Uint8List.fromList(
      List<int>.generate(_saltBytes, (_) => rng.nextInt(256)),
    );
    final hash = _pbkdf2(utf8.encode(pin), salt, iterations);
    return '$_version\$$iterations\$${base64.encode(salt)}\$${base64.encode(hash)}';
  }

  /// True when [pin] matches [stored]. Constant-time comparison; false for
  /// anything malformed.
  static bool verify(String pin, String? stored) {
    if (stored == null) return false;
    final parts = stored.split(r'$');
    if (parts.length != 4 || parts[0] != _version) return false;
    final iters = int.tryParse(parts[1]);
    if (iters == null || iters < 1 || iters > 1000000) return false;
    try {
      final salt = base64.decode(parts[2]);
      final expected = base64.decode(parts[3]);
      final actual = _pbkdf2(utf8.encode(pin), salt, iters);
      return _constantTimeEquals(actual, expected);
    } catch (_) {
      return false;
    }
  }

  static bool _constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  /// PBKDF2 with HMAC-SHA256 and a 32-byte output (a single block).
  static Uint8List _pbkdf2(List<int> password, List<int> salt, int rounds) {
    final hmac = Hmac(sha256, password);
    final block = Uint8List(salt.length + 4)
      ..setRange(0, salt.length, salt)
      ..[salt.length + 3] = 1; // INT(1), big endian

    var u = hmac.convert(block).bytes;
    final out = Uint8List.fromList(u);
    for (var i = 1; i < rounds; i++) {
      u = hmac.convert(u).bytes;
      for (var j = 0; j < out.length; j++) {
        out[j] ^= u[j];
      }
    }
    return out;
  }
}
