import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import '../models/app_config.dart';
import '../models/telemetry.dart';
import '../models/energy_summary.dart';
import '../models/lifetime_stats.dart';
import 'firebase_auth_session.dart';

/// A command the gateway answered with "failed" or "expired". [data] holds
/// the controller values it read back, when it sent any.
class GatewayCommandFailed implements Exception {
  GatewayCommandFailed(this.message, this.data);
  final String message;
  final Map<String, dynamic>? data;
  @override
  String toString() => message;
}

class FirebaseService {
  final AppConfig config;
  FirebaseService(this.config);
  Timer? _pollTimer;
  bool _disposed = false, _fetching = false;
  int _pollGeneration = 0;
  DateTime? _holdStaleUntil;
  Map<String, dynamic> _lastLive = {};
  void Function(LiveTelemetry)? onLiveTelemetry;
  void Function(EnergySummary)? onEnergySummary;
  void Function(LifetimeStats)? onLifetimeStats;
  void Function(bool)? onRelayState;
  void Function(String)? onError;
  String get _root => '/devices/${config.deviceId}';

  // Freshness from this phone's own monotonic clock: a device timestamp is
  // fresh only while it keeps advancing. Works even if phone and ESP32 clocks
  // disagree. Until a value is seen advancing, the wall-clock check is used.
  final Stopwatch _monotonic = Stopwatch()..start();
  final Map<String, int> _seenValue = {}, _seenAt = {}, _seenChanges = {};
  void _observe(String key) {
    final raw = _lastLive[key];
    final value = raw is num ? raw.toInt() : 0;
    if (value <= 0 || value == _seenValue[key]) return;
    _seenValue[key] = value;
    _seenAt[key] = _monotonic.elapsedMilliseconds;
    _seenChanges[key] = (_seenChanges[key] ?? 0) + 1;
  }

  int? _ageMs(String key) => (_seenChanges[key] ?? 0) >= 2
      ? _monotonic.elapsedMilliseconds - _seenAt[key]!
      : null;

  LiveTelemetry _telemetry(AppConfig preferences) =>
      LiveTelemetry.fromFirebaseJson(
        _lastLive,
        isBmsEnabled: preferences.isBmsEnabled,
        batteryMode: preferences.effectiveBatteryMode,
        controllerAgeMs: _ageMs('controller_updated_at'),
        bmsAgeMs: _ageMs('bms_updated_at'),
        gatewayAgeMs: _ageMs('gateway_updated_at'),
      );

  /// The controller parameters the gateway last read (it re-reads them about
  /// every 2 minutes), with its saved profile copies; null if none yet.
  Map<String, dynamic>? get controllerReadback {
    final settings = _lastLive['controller_settings'];
    if (settings is! Map || settings.isEmpty) return null;
    final snapshots = _lastLive['controller_profile_snapshots'];
    return {
      ...Map<String, dynamic>.from(settings),
      if (snapshots is Map)
        'controller_profile_snapshots': Map<String, dynamic>.from(snapshots),
    };
  }

  LiveTelemetry snapshot(AppConfig preferences) =>
      _lastLive.isEmpty ? LiveTelemetry.empty() : _telemetry(preferences);

  Future<dynamic> read(String path) async {
    final r = await http
        .get(await FirebaseAuthSession.databaseUri(config, '$_root/$path'))
        .timeout(const Duration(seconds: 8));
    if (r.statusCode == 401) FirebaseAuthSession.invalidate();
    if (r.statusCode != 200) {
      throw Exception(
        'Firebase read failed (${r.statusCode}). Check account and database rules.',
      );
    }
    return jsonDecode(r.body);
  }

  Future<void> write(String path, Object? value, {bool patch = false}) async {
    final uri = await FirebaseAuthSession.databaseUri(config, '$_root/$path');
    final body = jsonEncode(value);
    final headers = {'Content-Type': 'application/json'};
    final r =
        await (patch
                ? http.patch(uri, headers: headers, body: body)
                : http.put(uri, headers: headers, body: body))
            .timeout(const Duration(seconds: 10));
    if (r.statusCode == 401) FirebaseAuthSession.invalidate();
    if (r.statusCode < 200 || r.statusCode >= 300) {
      throw Exception(
        'Firebase write failed (${r.statusCode}). Check account and database rules.',
      );
    }
  }

  void startPolling({Duration interval = const Duration(seconds: 2)}) {
    _disposed = false;
    _pollTimer?.cancel();
    // A read still running from before (e.g. frozen while the screen was
    // locked) must not block the new one; its answer is dropped.
    ++_pollGeneration;
    _fetching = false;
    _fetchOnce();
    _pollTimer = Timer.periodic(interval, (_) {
      _emitLive(); // Re-evaluate age even when no response arrives.
      _fetchOnce();
    });
  }

  void stopPolling() {
    _disposed = true;
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  /// App in the background (screen locked, other app): no polling.
  void pausePolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
    ++_pollGeneration;
    _fetching = false;
  }

  /// Back in the foreground. The last values are old only because polling
  /// was paused: keep showing them until the first new read (at most 15 s)
  /// instead of reporting the gateway offline.
  void resumePolling() {
    if (_disposed) return;
    _holdStaleUntil = DateTime.now().add(const Duration(seconds: 15));
    startPolling();
  }

  void _emitLive() {
    final hold = _holdStaleUntil;
    if (hold != null && DateTime.now().isBefore(hold)) return;
    if (!_disposed && _lastLive.isNotEmpty) {
      onLiveTelemetry?.call(_telemetry(config));
    }
  }

  Future<void> _fetchOnce() async {
    if (_disposed || _fetching || !config.isFirebaseConfigured) return;
    final generation = _pollGeneration;
    bool stale() => _disposed || generation != _pollGeneration;
    _fetching = true;
    try {
      final data = await read('live');
      if (stale()) return;
      _holdStaleUntil = null;
      _lastLive = data is Map ? Map<String, dynamic>.from(data) : {};
      _observe('controller_updated_at');
      _observe('bms_updated_at');
      _observe('gateway_updated_at');
      if (_lastLive.isEmpty) onLiveTelemetry?.call(LiveTelemetry.empty());
      _emitLive();
      final life = await read('lifetime');
      if (stale()) return;
      onLifetimeStats?.call(
        life is Map
            ? LifetimeStats.fromJson(Map<String, dynamic>.from(life))
            : LifetimeStats.empty(),
      );
      final summary = await read('summary');
      if (stale()) return;
      onEnergySummary?.call(
        summary is Map
            ? EnergySummary.fromJson(Map<String, dynamic>.from(summary))
            : EnergySummary.empty(),
      );
    } catch (e) {
      if (!stale()) onError?.call(FirebaseAuthSession.message(e));
    } finally {
      if (generation == _pollGeneration) _fetching = false;
    }
  }

  /// Empty map = no history saved yet; null = the read failed (the caller
  /// keeps what it already shows instead of presenting it as deleted).
  Future<Map<String, dynamic>?> fetchHistory() async {
    try {
      final v = await read('history');
      return v is Map ? Map<String, dynamic>.from(v) : {};
    } catch (e) {
      onError?.call(FirebaseAuthSession.message(e));
      return null;
    }
  }

  Future<void> saveReportingOptions() async {
    int minute(String input) {
      final m = RegExp(
        r'^(\d{1,2}):(\d{2})(?:\s*([AP]M))?$',
        caseSensitive: false,
      ).firstMatch(input.trim());
      if (m == null) throw Exception('Invalid reporting time.');
      var hour = int.parse(m[1]!);
      final minutes = int.parse(m[2]!);
      final period = m[3]?.toUpperCase();
      if (minutes > 59 ||
          hour > 23 ||
          (period != null && (hour < 1 || hour > 12))) {
        throw Exception('Invalid reporting time.');
      }
      if (period != null) {
        hour %= 12;
        if (period == 'PM') hour += 12;
      }
      return hour * 60 + minutes;
    }

    await sendGatewayCommand('reporting_options', {
      'reset_minute': minute(config.dailyResetTime),
      'pv_start': minute(config.pvAvgStartTime),
      'pv_end': minute(config.pvAvgEndTime),
      'timezone_offset_seconds': DateTime.now().timeZoneOffset.inSeconds,
    });
  }

  /// Battery mode, panel rating and (Only Controller Mode) battery type and
  /// capacity, saved on the gateway; it calculates with these values.
  Future<void> saveSystemOptions() {
    final controllerOnly = config.isControllerOnlyMode;
    return sendGatewayCommand('system_options', {
      'mode': config.effectiveBatteryMode,
      'panel_w': config.panelRatedPowerW,
      if (controllerOnly) 'battery_type': config.batteryType,
      if (controllerOnly) 'capacity_ah': config.batteryNominalCapacityAh,
    });
  }

  /// Irreversibly deletes all of this gateway's cloud data and releases its
  /// ownership, in one atomic multi-path update. Owner only (database rules).
  Future<void> deleteAllGatewayData() async {
    final uri = await FirebaseAuthSession.databaseUri(config, '/');
    final r = await http
        .patch(
          uri,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'devices/${config.deviceId}': null,
            'gateway_devices/${config.deviceId}': null,
            'gateway_devices_pending/${config.deviceId}': null,
            'gateway_owners/${config.deviceId}': null,
          }),
        )
        .timeout(const Duration(seconds: 15));
    if (r.statusCode < 200 || r.statusCode >= 300) {
      throw Exception(
        'Cloud data could not be deleted (${r.statusCode}). Check that the latest database rules from the setup guide are published.',
      );
    }
  }

  Future<bool> testConnection() async {
    try {
      await read('setup/status');
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Writes a gateway command and returns its ID without waiting.
  static String newCommandId() =>
      'cmd-${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32).toRadixString(16)}';

  Future<String> queueCommand(
    String type,
    Map<String, dynamic> payload, {
    String? id,
  }) async {
    id ??= newCommandId();
    final now = DateTime.now().millisecondsSinceEpoch;
    await write('commands/queue/$id', {
      'id': id,
      'type': type,
      'payload': payload,
      'requested_at': now,
      // Shorter than every app wait (>= 70 s): a command the app has given
      // up on can no longer be started by the gateway, so a retry never
      // repeats a physical action.
      'expires_at': now + 60000,
    });
    return id;
  }

  /// The gateway's latest result for a command, or null if none yet.
  Future<Map<String, dynamic>?> commandResult(String id) async {
    final data = await read('command_results/$id');
    return data is Map ? Map<String, dynamic>.from(data) : null;
  }

  Future<Map<String, dynamic>> sendGatewayCommand(
    String type,
    Map<String, dynamic> payload, {
    Duration wait = const Duration(seconds: 70),
  }) async {
    final id = await queueCommand(type, payload);
    final deadline = DateTime.now().add(wait);
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(seconds: 2));
      final Map<String, dynamic>? result;
      try {
        result = await commandResult(id);
      } catch (e) {
        // A short network drop on the phone must not abandon a command the
        // gateway may still complete: keep checking until the deadline.
        if (FirebaseAuthSession.isTransientNetworkError(e)) continue;
        rethrow;
      }
      if (result == null) continue;
      if (result['status'] == 'confirmed') return result;
      if (result['status'] == 'failed' || result['status'] == 'expired') {
        final data = result['data'];
        throw GatewayCommandFailed(
          result['message']?.toString() ?? 'Device command failed.',
          data is Map ? Map<String, dynamic>.from(data) : null,
        );
      }
    }
    throw Exception(
      'No confirmed result from the gateway. Check that the gateway is online.',
    );
  }

  Future<bool> _command(String type, Map<String, dynamic> payload) async {
    try {
      await sendGatewayCommand(type, payload);
      return true;
    } catch (e) {
      onError?.call(FirebaseAuthSession.message(e));
      return false;
    }
  }

  List<Map<String, dynamic>> _rows(Map<String, dynamic> result, String key) {
    final data = result['data'];
    final rows = data is Map ? data[key] : null;
    return rows is List
        ? rows
              .whereType<Map>()
              .map((r) => Map<String, dynamic>.from(r))
              .toList()
        : [];
  }

  /// Wi-Fi networks seen by the gateway itself (works from anywhere online).
  Future<List<Map<String, dynamic>>> scanGatewayWifi() async =>
      _rows(await sendGatewayCommand('wifi_scan', {}), 'networks');

  /// The gateway tries the new Wi-Fi and keeps it only after reaching
  /// Firebase through it; otherwise it restores the previous Wi-Fi.
  Future<void> changeGatewayWifi(String ssid, String password) =>
      sendGatewayCommand('wifi_change', {
        'ssid': ssid,
        'password': password,
      }, wait: const Duration(seconds: 150));

  /// Saves a Wi-Fi on the gateway without switching to it. When the current
  /// Wi-Fi is unavailable and this one is in range, the gateway joins it.
  Future<void> addGatewayWifi(String ssid, String password) =>
      sendGatewayCommand('wifi_add', {'ssid': ssid, 'password': password});

  Future<void> removeGatewayWifi(String ssid) =>
      sendGatewayCommand('wifi_remove', {'ssid': ssid});

  /// Current and saved Wi-Fi names reported by the gateway (no passwords).
  Future<({String current, List<String> saved})> gatewayWifiState() async {
    final live = await read('live');
    final map = live is Map ? live : const {};
    final saved = map['wifi_saved'];
    return (
      current: map['wifi_ssid']?.toString() ?? '',
      saved: saved is List
          ? saved.map((s) => s.toString()).toList()
          : <String>[],
    );
  }

  /// Bluetooth devices seen by the gateway itself (phone can be anywhere).
  Future<List<Map<String, dynamic>>> scanGatewayBluetooth() async =>
      _rows(await sendGatewayCommand('ble_scan', {}), 'devices');

  Future<bool> setLoadSwitch(bool enable) =>
      _command('load', {'enabled': enable});
  Future<bool> sendConnectionCommand({
    required bool controllerEnabled,
    required bool bmsEnabled,
    required bool hotspotEnabled,
  }) => _command('connection', {
    'controller_enabled': controllerEnabled,
    'bms_enabled': bmsEnabled,
  });
  Future<bool> saveBatterySettings({
    required String profile,
    required Map<String, double> parameters,
  }) => _command('controller_settings', {
    'profile': profile,
    'parameters': parameters,
  });

  /// Controller parameter commands. The gateway reads the controller first,
  /// validates, saves a copy of the battery profile when it changes, writes,
  /// and confirms by readback. Each returns the actual values read back.
  Future<Map<String, dynamic>> _controllerJob(
    String type,
    Map<String, dynamic> payload,
  ) async {
    final result = await sendGatewayCommand(type, payload);
    final data = result['data'];
    if (data is! Map) throw Exception('No controller readback received.');
    // The gateway's own message (e.g. "No change") goes with the values.
    return {...Map<String, dynamic>.from(data), '_message': result['message']};
  }

  /// The gateway's kept diagnostic lines and the few facts that explain what
  /// it is attached to. Read-only: nothing on the gateway is changed.
  Future<Map<String, dynamic>> fetchGatewayLogs() async {
    final result = await sendGatewayCommand('get_logs', {});
    final data = result['data'];
    if (data is! Map) throw Exception('The gateway sent no diagnostics.');
    return Map<String, dynamic>.from(data);
  }

  Future<Map<String, dynamic>> readControllerParameters() =>
      _controllerJob('read_settings', {});

  /// Only the given keys are changed (see gateway "controller_parameters").
  Future<Map<String, dynamic>> setControllerParameters(
    Map<String, dynamic> changes,
  ) => _controllerJob('controller_parameters', changes);

  /// USER block (all voltages, SOC, times); only when the type is USER.
  Future<Map<String, dynamic>> setControllerUserBlock(
    Map<String, num> parameters,
  ) => _controllerJob('controller_settings', {
    'profile': 'USER',
    'parameters': parameters,
  });

  /// Writes back saved copy 1 (newest) or 2 of the battery profile.
  Future<Map<String, dynamic>> restoreControllerProfile(int slot) =>
      _controllerJob('restore_profile_snapshot', {'slot': slot});
  Future<Map<String, dynamic>> setupStatus() async {
    final v = await read('setup/status');
    return v is Map ? Map<String, dynamic>.from(v) : {};
  }

  // External relays require an explicitly configured bridge. A database state
  // write must never be reported as a successful physical relay command.
  Future<bool> setSmartSwitchEnabled(bool enable) async {
    try {
      await write('config', {'smart_switch_enabled': enable}, patch: true);
      return true;
    } catch (e) {
      onError?.call(FirebaseAuthSession.message(e));
      return false;
    }
  }

  Future<bool> setSmartSwitchRelay(String channel, bool enable) async {
    onError?.call(
      'External relay control requires a configured and verified Tuya bridge.',
    );
    return false;
  }

  Future<bool> saveSmartSwitchConfig({
    required bool enabled,
    required String channel,
    required int onSoc,
    required int offSoc,
  }) async {
    if (offSoc < 0 || onSoc > 100 || offSoc >= onSoc) return false;
    try {
      await write('config', {
        'smart_switch_enabled': enabled,
        'smart_switch_channel': channel,
        'smart_switch_on_soc': onSoc,
        'smart_switch_off_soc': offSoc,
      }, patch: true);
      return true;
    } catch (e) {
      onError?.call(FirebaseAuthSession.message(e));
      return false;
    }
  }
}
