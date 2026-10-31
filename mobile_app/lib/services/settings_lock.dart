import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// The optional Settings-lock password is stored only as a salted, iterated
/// SHA-256 hash, never as plain text.
class SettingsLock {
  static const _prefix = 'sha256i:';
  static const _rounds = 20000;

  static String _digest(String salt, String password) {
    List<int> bytes = utf8.encode('$salt:$password');
    for (var i = 0; i < _rounds; i++) {
      bytes = sha256.convert(bytes).bytes;
    }
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  static String hash(String password) {
    final random = Random.secure();
    final salt = List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    return '$_prefix$salt:${_digest(salt, password)}';
  }

  static bool isHashed(String stored) => stored.startsWith(_prefix);

  /// Also accepts a plain value saved by older versions (caller re-hashes).
  static bool verify(String stored, String password) {
    if (!isHashed(stored)) return stored == password;
    final parts = stored.substring(_prefix.length).split(':');
    if (parts.length != 2) return false;
    return _digest(parts[0], password) == parts[1];
  }
}
