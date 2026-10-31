import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';

import '../models/app_config.dart';
import '../models/energy_summary.dart';
import '../models/lifetime_stats.dart';
import '../models/telemetry.dart';
import '../providers/solar_provider.dart';
import '../services/firebase_auth_session.dart';
import 'web_firebase_service.dart';
import 'web_link.dart';

/// The app's provider for the web view. The app screens read it as their
/// usual SolarProvider; nothing here is saved in the browser. Viewing needs
/// no sign-in; every command needs the owner's Firebase sign-in, kept only
/// in memory.
class WebSolarProvider extends SolarProvider {
  WebSolarProvider(this.link)
    : _cfg = AppConfig(
        deviceId: link.deviceId,
        firebaseDatabaseUrl: link.databaseUrl,
        firebaseApiKey: link.apiKey,
        isSetupCompleted: true,
        setupStage: 5,
      ) {
    _start();
  }

  final WebLink link;
  final AppConfig _cfg;
  late final WebFirebaseService _service = WebFirebaseService(
    _cfg,
    () => _signedIn,
  );
  LiveTelemetry _webLive = LiveTelemetry.empty();
  EnergySummary _webSummary = EnergySummary.empty();
  LifetimeStats _webLifetime = LifetimeStats.empty();
  Map<String, dynamic> _webHistory = {};
  String? _webError;
  DateTime? _startedAt;
  Timer? _graceTimer, _signOutTimer;
  AppLifecycleListener? _visibility;
  bool _signedIn = false;

  bool get signedIn => _signedIn;
  String get signedInEmail => _signedIn ? _cfg.firebaseEmail : '';

  /// The browser keeps no login: after this the owner signs in again
  /// (Firebase sign-in tokens last one hour).
  static const Duration sessionLength = Duration(minutes: 55);

  // The app's own start-up (saved config, cloud change, updates) does not
  // apply to the web view.
  @override
  Future<void> init() async {}

  void _start() {
    _startedAt = DateTime.now();
    _graceTimer = Timer(const Duration(seconds: 30), notifyListeners);
    _service
      ..onLiveTelemetry = (t) {
        _webLive = t;
        _webError = null;
        notifyListeners();
      }
      ..onEnergySummary = (s) {
        _webSummary = s;
        notifyListeners();
      }
      ..onLifetimeStats = (l) {
        _webLifetime = l;
        notifyListeners();
      }
      ..onError = (e) {
        _webError = e;
        notifyListeners();
      }
      ..startPolling();
    // A hidden browser tab stops reading, like the app in the background.
    _visibility = AppLifecycleListener(
      onHide: _service.pausePolling,
      onShow: _service.resumePolling,
    );
    refreshHistory();
  }

  /// Owner sign-in for Settings. Only the account that owns this gateway is
  /// accepted; the password is not kept.
  Future<void> signIn(String email, String password, String apiKey) async {
    if (apiKey.trim().isNotEmpty) _cfg.firebaseApiKey = apiKey.trim();
    await FirebaseAuthSession.signIn(_cfg, email, password, remember: false);
    try {
      final uid = await FirebaseAuthSession.uid(_cfg);
      final r = await http
          .get(
            await FirebaseAuthSession.databaseUri(
              _cfg,
              '/gateway_owners/${_cfg.deviceId}',
            ),
          )
          .timeout(const Duration(seconds: 10));
      if (r.statusCode != 200 || jsonDecode(r.body) != uid) {
        throw Exception('This account does not own this gateway.');
      }
    } catch (_) {
      await signOut(notify: false);
      rethrow;
    }
    _signedIn = true;
    _signOutTimer?.cancel();
    _signOutTimer = Timer(sessionLength, () {
      signOut();
      onNotice?.call(
        'Signed out after 55 minutes. Sign in again to change settings.',
      );
    });
    notifyListeners();
  }

  Future<void> signOut({bool notify = true}) async {
    _signOutTimer?.cancel();
    _signedIn = false;
    try {
      // Clears the in-memory login; the browser has no saved one.
      await FirebaseAuthSession.forgetEverything();
    } catch (_) {}
    _cfg.firebaseEmail = '';
    if (notify) notifyListeners();
  }

  @override
  AppConfig get config => _cfg;
  @override
  LiveTelemetry get live => _webLive;
  @override
  EnergySummary get todaySummary => _webSummary;
  @override
  LifetimeStats get lifetime => _webLifetime;
  @override
  Map<String, dynamic> get history => _webHistory;
  @override
  bool get isLoading => false;
  @override
  bool get previewMode => false;
  @override
  String? get errorMessage => _webError;
  @override
  bool get isConnected => _webLive.connected;
  @override
  bool get liveConnecting =>
      !_webLive.connected &&
      _webError == null &&
      _startedAt != null &&
      DateTime.now().difference(_startedAt!) < const Duration(seconds: 30);
  @override
  bool get isBmsEnabled => _cfg.isBmsEnabled;
  @override
  bool get isBmsActive => _cfg.isBmsEnabled && _webLive.bmsConnected;
  @override
  String get esp32FirmwareVersion => _webLive.esp32FirmwareVersion;
  @override
  Map<String, dynamic>? get controllerReadback => _service.controllerReadback;

  // Updates are installed from the app, never from the web view.
  @override
  bool get firmwareUpdateAvailable => false;
  @override
  bool get appUpdateAvailable => false;
  @override
  Future<void> checkUpdates() async {}
  @override
  Future<void> updateFirmware(void Function(String) onStatus) =>
      throw Exception('Gateway updates are done from the app.');

  @override
  Future<void> refreshHistory() async {
    final data = await _service.fetchHistory();
    if (data == null) return;
    _webHistory = data;
    notifyListeners();
  }

  Never _needsApp() =>
      throw Exception('This is changed from the NoxBrain app.');

  /// Commands go only through the signed-in owner's Firebase login.
  void _requireSignIn() {
    if (!_signedIn) throw Exception('Sign in to Settings first.');
  }

  @override
  Future<bool> setLoadSwitch(bool on) async {
    if (!_signedIn) {
      _webError = 'Sign in to Settings first.';
      notifyListeners();
      return false;
    }
    final ok = await _service.setLoadSwitch(on);
    notifyListeners();
    return ok;
  }

  @override
  Future<bool> saveBatterySettings({
    required String profile,
    required Map<String, double> parameters,
  }) async {
    _requireSignIn();
    return _service.saveBatterySettings(
      profile: profile,
      parameters: parameters,
    );
  }

  // Phone-side settings: the browser has no copy of them, so the web view
  // never writes them.
  @override
  Future<void> updateConfig(AppConfig newConfig) async => _needsApp();
  @override
  Future<void> toggleControllerConnection(bool enabled) async => _needsApp();
  @override
  Future<void> toggleBms(bool enabled) async => _needsApp();
  @override
  Future<void> setSmartSwitchEnabled(bool enabled) async => _needsApp();
  @override
  Future<void> setSmartSwitchRelay(String channel, bool on) async =>
      _needsApp();
  @override
  Future<void> saveSmartSwitchConfig({
    required bool enabled,
    required String channel,
    required int onSoc,
    required int offSoc,
  }) async => _needsApp();
  @override
  Future<void> resetAppPreferences() async => _needsApp();
  @override
  Future<void> resetAppCompletely() async => _needsApp();
  @override
  Future<void> requireGatewaySetup({required bool ownershipReleased}) async =>
      _needsApp();
  @override
  void enterPreview() {}

  /// Same columns as the app's export; the browser downloads the file.
  @override
  Future<String?> exportCsv(DateTime start, DateTime end) async {
    try {
      final rows = <List<dynamic>>[
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
        final day = _webHistory[key];
        if (day is Map<String, dynamic>) {
          rows.add([
            key,
            day['panel_wh'] ?? '',
            day['battery_charge_wh'] ?? '',
            day['battery_charge_ah'] ?? '',
            day['battery_discharge_wh'] ?? '',
            day['load_wh'] ?? '',
            day['load_from_battery_wh'] ?? '',
            day['load_from_panel_wh'] ?? '',
            day['pv_w_max'] ?? '',
            day['pv_v_max'] ?? '',
            day['pv_a_max'] ?? '',
          ]);
        }
        cur = cur.add(const Duration(days: 1));
      }
      final csv = rows
          .map((row) => row.map((cell) => '"$cell"').join(','))
          .join('\n');
      final name =
          'solar_history_${formatter.format(start)}_to_${formatter.format(end)}.csv';
      await SharePlus.instance.share(
        ShareParams(
          files: [
            XFile.fromData(utf8.encode(csv), mimeType: 'text/csv', name: name),
          ],
          fileNameOverrides: [name],
          downloadFallbackEnabled: true,
        ),
      );
      return name;
    } catch (_) {
      return null;
    }
  }

  @override
  void dispose() {
    _graceTimer?.cancel();
    _signOutTimer?.cancel();
    _visibility?.dispose();
    _service.stopPolling();
    super.dispose();
  }
}
