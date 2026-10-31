import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_config.dart';

class StorageService {
  static const String _keyConfig = 'solar_app_config_v1';

  static Future<AppConfig> loadConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = prefs.getString(_keyConfig);
    if (jsonStr != null && jsonStr.isNotEmpty) {
      try {
        final Map<String, dynamic> map = jsonDecode(jsonStr);
        final cfg = AppConfig.fromJson(map);
        if (cfg.deviceId.trim().isEmpty) {
          cfg.deviceId = AppConfig.generateUniqueDeviceId();
          await saveConfig(cfg);
        }
        return cfg;
      } catch (_) {}
    }
    final fresh = AppConfig(deviceId: AppConfig.generateUniqueDeviceId());
    await saveConfig(fresh);
    return fresh;
  }

  static const String _keyCloudChange = 'cloud_change_pending';

  /// Checkpoint of a remote Firebase change that has not been confirmed yet
  /// (new URL, API key, email, command ID, start time; no secrets).
  static Future<void> saveCloudChange(Map<String, dynamic> change) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyCloudChange, jsonEncode(change));
  }

  static Future<Map<String, dynamic>?> loadCloudChange() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_keyCloudChange);
    if (raw == null) return null;
    try {
      return Map<String, dynamic>.from(jsonDecode(raw) as Map);
    } catch (_) {
      return null;
    }
  }

  static Future<void> clearCloudChange() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyCloudChange);
  }

  /// Full app reset: removes every stored preference of this app.
  static Future<void> clearAll() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    _sessionUnlocked = false;
  }

  static Future<void> saveConfig(AppConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = jsonEncode(config.toJson());
    await prefs.setString(_keyConfig, jsonStr);
    await prefs.setBool(_keyTouchUnlock, config.touchUnlockEnabled);
  }

  static const String _keyControllerReadback = 'controller_readback_v1';

  /// Last controller parameters read through this app, per gateway, so the
  /// Controller Parameter tab is filled without reading again.
  static Future<void> saveControllerReadback(
    String deviceId,
    Map<String, dynamic> data,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _keyControllerReadback,
      jsonEncode({
        'device_id': deviceId,
        'read_at': DateTime.now().millisecondsSinceEpoch,
        'data': data,
      }),
    );
  }

  static Future<({Map<String, dynamic> data, int readAt})?>
  loadControllerReadback(String deviceId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_keyControllerReadback);
    if (raw == null) return null;
    try {
      final saved = jsonDecode(raw) as Map;
      if (saved['device_id'] != deviceId || saved['data'] is! Map) return null;
      return (
        data: Map<String, dynamic>.from(saved['data'] as Map),
        readAt: (saved['read_at'] as num?)?.toInt() ?? 0,
      );
    } catch (_) {
      return null;
    }
  }

  static const String _keySessionUnlocked = 'settings_session_unlocked';
  static const String _keySessionAppVersion = 'settings_session_app_version';
  static const String _keyTouchUnlock = 'settings_touch_unlock_enabled';
  // Set while Keep Logged In is on and Settings are unlocked.
  static const String _keySessionKept = 'settings_session_kept';

  // The Settings unlock lasts for this app run. With Keep Logged In on it
  // also survives restarts, until Manual Logout or until the option is
  // turned off -- typing the password at every start was the complaint.
  static bool _sessionUnlocked = false;

  /// Returns true if Settings were unlocked during this app run.
  static Future<bool> isSessionUnlocked() async {
    final prefs = await SharedPreferences.getInstance();
    // Clear the unlock flag older versions persisted across restarts.
    if (prefs.containsKey(_keySessionUnlocked)) {
      await prefs.remove(_keySessionUnlocked);
      await prefs.remove(_keySessionAppVersion);
    }
    if (!_sessionUnlocked &&
        (prefs.getBool(_keyTouchUnlock) ?? false) &&
        (prefs.getBool(_keySessionKept) ?? false)) {
      _sessionUnlocked = true;
    }
    return _sessionUnlocked;
  }

  /// Sets the settings session unlocked state for this app run.
  static Future<void> setSessionUnlocked(bool unlocked) async {
    _sessionUnlocked = unlocked;
    final prefs = await SharedPreferences.getInstance();
    if (!unlocked) {
      await prefs.remove(_keySessionKept);
    } else if (prefs.getBool(_keyTouchUnlock) ?? false) {
      await prefs.setBool(_keySessionKept, true);
    }
  }

  /// Checks if touch / quick unlock is enabled.
  static Future<bool> isTouchUnlockEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyTouchUnlock) ?? false;
  }

  /// Updates touch unlock enabled preference.
  static Future<void> setTouchUnlockEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyTouchUnlock, enabled);
    if (!enabled) await prefs.remove(_keySessionKept);
  }
}
