import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:intl/intl.dart';

import '../models/app_config.dart';
import '../models/telemetry.dart';
import '../models/energy_summary.dart';
import '../models/lifetime_stats.dart';
import '../services/storage_service.dart';
import '../services/firebase_service.dart';
import '../services/firebase_auth_session.dart';
import '../services/update_service.dart';

class SolarProvider extends ChangeNotifier {
  AppConfig _config = AppConfig();
  LiveTelemetry _live = LiveTelemetry.empty();
  EnergySummary _todaySummary = EnergySummary.empty();
  LifetimeStats _lifetime = LifetimeStats.empty();
  Map<String, dynamic> _history = {};

  FirebaseService? _firebaseService;
  bool _isLoading = true;
  String? _errorMessage;

  AppConfig get config => _config;
  LiveTelemetry get live => _live;
  EnergySummary get todaySummary => _todaySummary;
  LifetimeStats get lifetime => _lifetime;
  Map<String, dynamic> get history => _history;
  bool get isLoading => _isLoading;

  // Preview: opens the app screens without finishing setup, to look at them.
  // RAM only, nothing is saved or sent; the next app start shows setup again.
  bool _previewMode = false;
  bool get previewMode => _previewMode;
  void enterPreview() {
    _previewMode = true;
    notifyListeners();
  }
  String? get errorMessage => _errorMessage;

  bool get isConnected => _live.connected;

  /// Controller parameters from the gateway's latest read (see
  /// FirebaseService.controllerReadback).
  Map<String, dynamic>? get controllerReadback =>
      _firebaseService?.controllerReadback;

  // Right after the app opens there is no gateway data yet: for up to 30 s
  // that is "connecting", not "offline" (no offline alerts in that time).
  static const Duration _connectGrace = Duration(seconds: 30);
  DateTime? _liveStartedAt;
  Timer? _connectGraceTimer;
  bool get liveConnecting =>
      !_live.connected &&
      _liveStartedAt != null &&
      DateTime.now().difference(_liveStartedAt!) < _connectGrace;
  bool get isBmsEnabled => _config.isBmsEnabled;
  bool get isBmsActive => _config.isBmsEnabled && _live.bmsConnected;
  String get esp32FirmwareVersion => _live.esp32FirmwareVersion;
  // Release feeds, checked when the app opens. Updates never install on their
  // own: the user reads the changelog and taps Update.
  FirmwareRelease? _firmwareRelease;
  AppRelease? _appRelease;
  FirmwareRelease? get firmwareRelease => _firmwareRelease;
  AppRelease? get appRelease => _appRelease;
  bool get firmwareUpdateAvailable {
    final r = _firmwareRelease;
    return r != null &&
        _live.esp32FirmwareVersion != 'unknown' &&
        r.builds.containsKey(_live.chipFamily) &&
        UpdateService.compareVersions(r.version, _live.esp32FirmwareVersion) >
            0;
  }

  bool get appUpdateAvailable =>
      (_appRelease?.versionCode ?? 0) > AppConfig.appVersionCode;

  /// Why the app update must wait, or null when it may proceed. With a
  /// combined release the gateway firmware must be updated first.
  String? get appUpdateBlockedReason {
    final minFw = _appRelease?.minFirmwareVersion;
    if (minFw == null) return null;
    if (!_live.gatewayOnline || _live.esp32FirmwareVersion == 'unknown') {
      return 'Update the gateway firmware first, once the gateway is online (v$minFw or newer).';
    }
    if (UpdateService.compareVersions(_live.esp32FirmwareVersion, minFw) < 0) {
      return 'Update the gateway firmware first (v$minFw or newer).';
    }
    return null;
  }

  Future<void> checkUpdates() async {
    _firmwareRelease = await UpdateService.latestFirmware();
    _appRelease = AppConfig.playStoreBuild
        ? null
        : await UpdateService.latestApp();
    notifyListeners();
  }

  /// Sends the verified release to the gateway, then waits until it reports
  /// the new version after its restart.
  Future<void> updateFirmware(void Function(String) onStatus) async {
    final release = _firmwareRelease;
    final service = _firebaseService;
    final build = release?.builds[_live.chipFamily];
    if (release == null || service == null || build == null) {
      throw Exception('No release found for this gateway\'s chip.');
    }
    if (!_live.gatewayOnline) throw Exception('The gateway is not online.');
    onStatus('The gateway is downloading and checking the firmware…');
    await service.sendGatewayCommand('ota', {
      'target_version': release.version,
      'firmware_url': build.url,
      'sha256': build.sha256,
      'chip_family': _live.chipFamily,
      'image_size': build.size,
    }, wait: const Duration(seconds: 200));
    onStatus('The gateway is restarting; waiting to confirm the new version…');
    final deadline = DateTime.now().add(const Duration(minutes: 5));
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(seconds: 3));
      if (_live.gatewayOnline &&
          UpdateService.compareVersions(
                _live.esp32FirmwareVersion,
                release.version,
              ) ==
              0) {
        notifyListeners();
        return;
      }
    }
    throw Exception(
      'The new version was not confirmed. If the gateway cannot reach Firebase within 10 minutes, it goes back to the previous firmware by itself.',
    );
  }

  SolarProvider() {
    // Screen locked or another app in front: polling pauses. Back in front it
    // behaves like opening the app ("Connecting", no offline alerts).
    _lifecycle = AppLifecycleListener(
      onHide: () => _firebaseService?.pausePolling(),
      onShow: _resumeLive,
    );
    init();
  }

  AppLifecycleListener? _lifecycle;

  /// Shows a short message to the user (wired to the app's SnackBar).
  void Function(String message)? onNotice;
  bool _reconnecting = false;

  /// A device the user disconnected comes back the next time the app opens
  /// or returns to the foreground: Disconnect is for handing the module to
  /// its own app for a while, not for good. The gateway keeps the choice
  /// across restarts, so the app turns it back on. The BMS only in
  /// Controller + BMS Mode, where it belongs; a device never chosen is left
  /// alone.
  Future<void> _reconnectUserDisconnected() async {
    final c = _config;
    if (_reconnecting ||
        _previewMode ||
        !c.isSetupCompleted ||
        !c.isFirebaseConfigured ||
        c.firebaseEmail.isEmpty) {
      return;
    }
    final ctrl = !c.isControllerEnabled &&
        (c.isRs485Controller || c.srneBleMac.isNotEmpty);
    final bms = !c.isBmsEnabled &&
        !c.isControllerOnlyMode &&
        c.jkBmsBleMac.isNotEmpty;
    if (!ctrl && !bms) return;
    _reconnecting = true;
    try {
      final controllerOn = c.isControllerEnabled || ctrl;
      final bmsOn = (c.isBmsEnabled || bms) && !c.isControllerOnlyMode;
      await FirebaseService(c).sendGatewayCommand('connection', {
        'controller_enabled': controllerOn,
        'bms_enabled': bmsOn,
      });
      final updated = AppConfig.fromJson(_config.toJson())
        ..isControllerEnabled = controllerOn
        ..isBmsEnabled = bmsOn;
      await updateConfig(updated);
      onNotice?.call(
        ctrl && bms
            ? 'Controller and BMS reconnected'
            : ctrl
            ? 'Controller reconnected'
            : 'BMS reconnected',
      );
    } catch (_) {
      // Gateway offline or busy: the next opening tries again.
    } finally {
      _reconnecting = false;
    }
  }

  void _resumeLive() {
    // Back in the foreground: just resume polling. The connecting grace is
    // NOT restarted here — doing so let a repeated onShow keep the opening
    // overlay up forever, trapping the app. The 30 s grace runs only once,
    // from when the gateway service first started.
    _firebaseService?.resumePolling();
    notifyListeners();
    _reconnectUserDisconnected();
  }

  bool _smartSwitchRelayState = false;
  bool get smartSwitchRelayState => _smartSwitchRelayState;

  Future<void> init() async {
    _isLoading = true;
    notifyListeners();

    _config = await StorageService.loadConfig();
    // A fully set-up system goes straight to the dashboard, also when the
    // wizard was left with Skip (preview) instead of its last button.
    if (!_config.isSetupCompleted && _config.isSetupEffectivelyComplete) {
      _config
        ..isSetupCompleted = true
        ..setupStage = 5;
      await StorageService.saveConfig(_config);
    }
    await _resumeCloudChange();
    _smartSwitchRelayState = _config.smartSwitchRelayState;
    _setupFirebaseService();

    _isLoading = false;
    notifyListeners();
    _reconnectUserDisconnected();
  }

  void _setupFirebaseService() {
    _firebaseService?.stopPolling();
    _firebaseService = null;

    if (_config.isFirebaseConfigured && _config.firebaseEmail.isNotEmpty) {
      _firebaseService = FirebaseService(_config);
      _liveStartedAt = DateTime.now();
      _connectGraceTimer?.cancel();
      // Re-evaluate once the grace ends, even if no data arrives at all.
      _connectGraceTimer = Timer(_connectGrace, notifyListeners);
      _firebaseService!.onLiveTelemetry = (telemetry) {
        _live = telemetry;
        _errorMessage = null;
        notifyListeners();
      };
      _firebaseService!.onRelayState = (relayOn) {
        if (_smartSwitchRelayState != relayOn) {
          _smartSwitchRelayState = relayOn;
          notifyListeners();
        }
      };
      _firebaseService!.onEnergySummary = (summary) {
        _todaySummary = summary;
        notifyListeners();
      };
      _firebaseService!.onLifetimeStats = (lt) {
        _lifetime = lt;
        notifyListeners();
      };
      _firebaseService!.onError = (err) {
        _errorMessage = err;
        notifyListeners();
      };
      _firebaseService!.startPolling();
      refreshHistory();
      checkUpdates();
      // Finish a re-setup whose account promotion did not reach the cloud.
      FirebaseAuthSession.promotePendingDeviceAccount(_config).catchError((_) {});
    }
  }

  Future<void> updateConfig(AppConfig newConfig) async {
    final changedGateway =
        _config.deviceId != newConfig.deviceId ||
        _config.firebaseDatabaseUrl != newConfig.firebaseDatabaseUrl;
    if (changedGateway) {
      _live = LiveTelemetry.empty();
      _todaySummary = EnergySummary.empty();
      _lifetime = LifetimeStats.empty();
      _history = {};
    } else {
      _live = _firebaseService?.snapshot(newConfig) ?? LiveTelemetry.empty();
    }
    _config = newConfig;
    await StorageService.saveConfig(_config);
    _setupFirebaseService();
    notifyListeners();
  }

  /// An app close during a remote Firebase change must not leave the app on
  /// the old Firebase while the gateway moved: on start, look where the
  /// command ended and follow the gateway.
  Future<void> _resumeCloudChange() async {
    final change = await StorageService.loadCloudChange();
    if (change == null) return;
    final next = AppConfig.fromJson(_config.toJson())
      ..firebaseDatabaseUrl = change['database_url']?.toString() ?? ''
      ..firebaseApiKey = change['api_key']?.toString() ?? ''
      ..firebaseEmail = change['email']?.toString() ?? '';
    final id = change['command_id']?.toString() ?? '';
    // The change record is removed last: an app close at any step leaves it,
    // and the next start repeats these steps (each is safe to repeat).
    Future<void> adopt() async {
      await FirebaseAuthSession.promotePendingLogin(next);
      _config = next;
      await StorageService.saveConfig(next);
      await StorageService.clearCloudChange();
    }

    Future<void> abandon() async {
      await StorageService.clearCloudChange();
      await FirebaseAuthSession.dropPendingLogin();
    }

    try {
      final moved = await FirebaseService(next).commandResult(id);
      if (moved?['status'] == 'confirmed') return await adopt();
    } catch (_) {}
    try {
      final stayed = await FirebaseService(_config).commandResult(id);
      final status = stayed?['status'];
      if (status == 'failed' || status == 'expired') return await abandon();
    } catch (_) {}
    // No final result yet. After 15 minutes decide by where this gateway's
    // heartbeat is fresh; otherwise try again on the next start.
    final started = (change['started_at'] as num?)?.toInt() ?? 0;
    if (DateTime.now().millisecondsSinceEpoch - started < 15 * 60 * 1000) {
      return;
    }
    bool fresh(Map<String, dynamic> s) {
      final at = (s['updated_at'] as num?)?.toInt() ?? 0;
      final age = DateTime.now().millisecondsSinceEpoch - at;
      return s['hardware_id'] == _config.setupHardwareId &&
          age >= -5000 &&
          age < 60000;
    }

    try {
      if (fresh(await FirebaseService(next).setupStatus())) {
        return await adopt();
      }
    } catch (_) {}
    try {
      if (fresh(await FirebaseService(_config).setupStatus())) {
        return await abandon();
      }
    } catch (_) {}
  }

  /// App settings reset (keeps login, gateway and devices).
  Future<void> resetAppPreferences() async {
    await updateConfig(_config.withDefaultPreferences());
    await StorageService.setTouchUnlockEnabled(false);
  }

  /// Full app reset / logout on this phone: back to the first setup screen.
  /// The gateway and the Firebase data are not touched.
  Future<void> resetAppCompletely() async {
    _firebaseService?.stopPolling();
    _firebaseService = null;
    await FirebaseAuthSession.forgetEverything();
    await StorageService.clearAll();
    _live = LiveTelemetry.empty();
    _todaySummary = EnergySummary.empty();
    _lifetime = LifetimeStats.empty();
    _history = {};
    _errorMessage = null;
    _config = await StorageService.loadConfig(); // Fresh config, new app ID.
    notifyListeners();
  }

  /// After a gateway factory reset or deleting its cloud data the gateway
  /// must be set up again; the Firebase login on this phone is kept.
  Future<void> requireGatewaySetup({required bool ownershipReleased}) async {
    final next = AppConfig.fromJson(_config.toJson())
      ..isSetupCompleted = false
      ..setupStage = ownershipReleased ? 0 : 1
      ..setupHardwareId = ''
      ..srneBleMac = ''
      ..srneBleName = ''
      ..controllerLink = AppConfig.linkBle
      ..jkBmsBleMac = ''
      ..jkBmsBleName = ''
      ..isBmsEnabled = false;
    await updateConfig(next);
  }

  Future<void> _connection({
    required bool controller,
    required bool bms,
  }) async {
    final service = _firebaseService;
    if (service == null) throw Exception('Firebase sign-in required.');
    await service.sendGatewayCommand('connection', {
      'controller_enabled': controller,
      'bms_enabled': bms,
    });
    _config.isControllerEnabled = controller;
    _config.isBmsEnabled = bms;
    await StorageService.saveConfig(_config);
    notifyListeners();
  }

  Future<void> toggleControllerConnection(bool enabled) =>
      _connection(controller: enabled, bms: _config.isBmsEnabled);
  Future<void> toggleBms(bool enabled) =>
      _connection(controller: _config.isControllerEnabled, bms: enabled);
  Future<void> toggleHotspot(bool enabled) async {
    throw Exception('The gateway is managed through its setup/recovery hotspot.');
  }

  Future<void> toggleGateway(bool enabled) async {
    throw Exception(
      'Gateway power cannot be switched here. Use the separate controller/BMS connection controls.',
    );
  }

  Future<bool> setLoadSwitch(bool on) async {
    final service = _firebaseService;
    if (service == null) {
      _errorMessage = 'Firebase sign-in required.';
      notifyListeners();
      return false;
    }
    final ok = await service.setLoadSwitch(on);
    if (ok) _errorMessage = null;
    notifyListeners();
    return ok;
  }

  Future<void> setSmartSwitchEnabled(bool enabled) async {
    final ok = await _firebaseService?.setSmartSwitchEnabled(enabled) ?? false;
    if (!ok) throw Exception(_errorMessage ?? 'Automation config save failed.');
    _config.smartSwitchEnabled = enabled;
    await StorageService.saveConfig(_config);
    notifyListeners();
  }

  Future<void> setSmartSwitchRelay(String channel, bool on) async {
    final ok =
        await _firebaseService?.setSmartSwitchRelay(channel, on) ?? false;
    if (!ok) throw Exception('No verified external relay bridge found.');
    // Relay state is updated only from a verified physical readback.
  }

  Future<void> saveSmartSwitchConfig({
    required bool enabled,
    required String channel,
    required int onSoc,
    required int offSoc,
  }) async {
    final ok =
        await _firebaseService?.saveSmartSwitchConfig(
          enabled: enabled,
          channel: channel,
          onSoc: onSoc,
          offSoc: offSoc,
        ) ??
        false;
    if (!ok) throw Exception(_errorMessage ?? 'Automation config save failed.');
    _config.smartSwitchEnabled = enabled;
    _config.smartSwitchChannel = channel;
    _config.smartSwitchOnSoc = onSoc;
    _config.smartSwitchOffSoc = offSoc;
    await StorageService.saveConfig(_config);
    notifyListeners();
  }

  Future<bool> saveBatterySettings({
    required String profile,
    required Map<String, double> parameters,
  }) async {
    if (_firebaseService != null) {
      return await _firebaseService!.saveBatterySettings(
        profile: profile,
        parameters: parameters,
      );
    }
    return false;
  }

  Future<void> refreshHistory() async {
    final service = _firebaseService;
    if (service == null) return;
    final data = await service.fetchHistory();
    // A gateway/Firebase change (new service) while the read was running:
    // this answer belongs to the previous gateway. A failed read keeps the
    // history already shown.
    if (!identical(service, _firebaseService) || data == null) return;
    _history = data;
    notifyListeners();
  }

  Future<String?> exportCsv(DateTime start, DateTime end) async {
    try {
      final List<List<dynamic>> rows = [
        [
          'Date',
          'Panel (Wh)',
          'Battery Charge (Wh)',
          'Battery Charge (Ah)',
          'Battery Discharge (Wh)',
          'Load Total (Wh)',
          'Load From Battery (Wh)',
          'Load From Panel (Wh)',
          'Max PV Power (W)',
          'Max PV Voltage (V)',
          'Max PV Current (A)',
        ],
      ];

      final formatter = DateFormat('yyyy-MM-dd');
      var cur = start;
      while (!cur.isAfter(end)) {
        final key = formatter.format(cur);
        final dayData = _history[key];
        if (dayData is Map<String, dynamic>) {
          rows.add([
            key,
            // Missing measurements stay empty; they are never exported as 0.
            dayData['panel_wh'] ?? '',
            dayData['battery_charge_wh'] ?? '',
            dayData['battery_charge_ah'] ?? '',
            dayData['battery_discharge_wh'] ?? '',
            dayData['load_wh'] ?? '',
            dayData['load_from_battery_wh'] ?? '',
            dayData['load_from_panel_wh'] ?? '',
            dayData['pv_w_max'] ?? '',
            dayData['pv_v_max'] ?? '',
            dayData['pv_a_max'] ?? '',
          ]);
        }
        cur = cur.add(const Duration(days: 1));
      }

      final csvContent = rows
          .map((row) => row.map((cell) => '"$cell"').join(','))
          .join('\n');
      final dir = await getApplicationDocumentsDirectory();
      final file = File(
        '${dir.path}/solar_history_${formatter.format(start)}_to_${formatter.format(end)}.csv',
      );
      await file.writeAsString(csvContent);

      await Share.shareXFiles([
        XFile(file.path),
      ], text: 'Solar Monitor Energy Export');
      return file.path;
    } catch (e) {
      return null;
    }
  }

  @override
  void dispose() {
    _lifecycle?.dispose();
    _connectGraceTimer?.cancel();
    _firebaseService?.stopPolling();
    super.dispose();
  }
}
