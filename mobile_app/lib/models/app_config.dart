import 'dart:convert';
import 'dart:math' as math;

class AppConfig {
  String deviceId;
  String firebaseDatabaseUrl;
  String firebaseApiKey;
  String firebaseEmail;
  String setupRequestId;
  String setupHardwareId;
  int setupStage;
  String jkProfile;
  String esp32Ip;
  String srneBleMac;
  String srneBleName;
  // How the gateway reaches the controller: Bluetooth or RS485 (wired).
  String controllerLink;
  String jkBmsBleMac;
  String jkBmsBleName;
  bool isControllerEnabled;
  bool isBmsEnabled;
  bool isHotspotEnabled;
  bool isGatewayEnabled;
  String gatewaySsid;
  String gatewayPass;
  double panelRatedPowerW;
  double batteryNominalCapacityAh;
  String controllerModel;
  // 'controller' = Only Controller Mode, 'controller_bms' = Controller + BMS
  // Mode, '' = not chosen yet (setup starts with this choice).
  String batteryMode;
  // Only Controller Mode: 'flooded', 'sealed', 'gel' or 'lithium'.
  String batteryType;
  String dailyResetTime;
  String pvAvgStartTime;
  String pvAvgEndTime;
  String cloudMode; // 'default' or 'custom'
  bool touchUnlockEnabled;
  String settingsUsername;
  String settingsPassword;
  bool smartSwitchEnabled;
  String smartSwitchChannel;
  int smartSwitchOnSoc;
  int smartSwitchOffSoc;
  bool smartSwitchRelayState;
  bool isSetupCompleted;

  // Keep in sync with pubspec.yaml (version: 2.4.32+20432).
  static const String appVersion = '2.4.33';
  static const int appVersionCode = 20433;

  /// Google Play build (tools/build_android.ps1 -Store Play): Play delivers
  /// app updates, so the app's own APK self-update is left out.
  static const bool playStoreBuild =
      String.fromEnvironment('NOXBRAIN_STORE') == 'play';
  static const String defaultDatabaseUrl = '';
  static const String defaultApiKey = '';

  // Only these 12/24V Shiner models are supported; Shiner4820 is excluded.
  static const List<String> supportedControllerModels = [
    'Shiner2410',
    'Shiner2420',
    'Shiner2430',
    'Shiner2440',
    'Shiner2460',
  ];
  static bool isSupportedControllerModel(String model) =>
      supportedControllerModels.contains(model);
  // A device has been chosen (valid BLE address) and can be toggled.
  bool get hasControllerDevice => _macPattern.hasMatch(srneBleMac);
  static const String linkBle = 'ble';
  static const String linkRs485 = 'rs485';
  static const Map<String, String> controllerLinkLabels = {
    linkBle: 'Bluetooth',
    linkRs485: 'RS485 (Wired)',
  };
  bool get isRs485Controller => controllerLink == linkRs485;
  bool get hasBmsDevice => _macPattern.hasMatch(jkBmsBleMac);

  bool get hasSupportedControllerModel =>
      isSupportedControllerModel(controllerModel);

  static const String modeControllerOnly = 'controller';
  static const String modeControllerBms = 'controller_bms';
  static bool isBatteryMode(String mode) =>
      mode == modeControllerOnly || mode == modeControllerBms;
  static const Map<String, String> batteryModeLabels = {
    modeControllerOnly: 'Only Controller Mode',
    modeControllerBms: 'Controller + BMS Mode',
  };
  static const Map<String, String> batteryTypes = {
    'flooded': 'Flooded',
    'sealed': 'Sealed (AGM)',
    'gel': 'Gel',
    'lithium': 'Lithium',
  };

  /// The chosen mode; installs from before battery modes existed count as
  /// Only Controller Mode unless a BMS is in use.
  String get effectiveBatteryMode => isBatteryMode(batteryMode)
      ? batteryMode
      : (isBmsEnabled ? modeControllerBms : modeControllerOnly);
  bool get isControllerOnlyMode => effectiveBatteryMode == modeControllerOnly;

  static String generateUniqueDeviceId() {
    final random = math.Random.secure();
    const chars = '0123456789ABCDEF';
    final suffix = List.generate(
      24,
      (_) => chars[random.nextInt(chars.length)],
    ).join();
    return 'NOX-$suffix';
  }

  AppConfig({
    this.deviceId = '',
    this.firebaseDatabaseUrl = defaultDatabaseUrl,
    this.firebaseApiKey = defaultApiKey,
    this.firebaseEmail = '',
    this.setupRequestId = '',
    this.setupHardwareId = '',
    this.setupStage = 0,
    this.jkProfile = 'auto',
    this.esp32Ip = '',
    this.srneBleMac = '',
    this.srneBleName = '',
    this.controllerLink = 'ble',
    this.jkBmsBleMac = '',
    this.jkBmsBleName = '',
    this.isControllerEnabled = true,
    this.isBmsEnabled = false,
    this.isHotspotEnabled = true,
    this.isGatewayEnabled = true,
    this.gatewaySsid = 'NoxBrain',
    this.gatewayPass = '',
    this.panelRatedPowerW = 0.0,
    this.batteryNominalCapacityAh = 0.0,
    this.controllerModel = '',
    this.batteryMode = '',
    this.batteryType = '',
    this.dailyResetTime = '07:00 AM',
    this.pvAvgStartTime = '07:00 AM',
    this.pvAvgEndTime = '05:00 PM',
    this.cloudMode = 'custom',
    this.touchUnlockEnabled = false,
    this.settingsUsername = '',
    this.settingsPassword = '',
    this.smartSwitchEnabled = false,
    this.smartSwitchChannel = 'switch_1',
    this.smartSwitchOnSoc = 99,
    this.smartSwitchOffSoc = 50,
    this.smartSwitchRelayState = false,
    this.isSetupCompleted = false,
  });

  /// App settings reset: only this phone's preferences return to defaults;
  /// Firebase login, gateway identity and device selection are kept.
  AppConfig withDefaultPreferences() {
    final defaults = AppConfig();
    return AppConfig.fromJson(toJson())
      ..panelRatedPowerW = defaults.panelRatedPowerW
      ..batteryNominalCapacityAh = defaults.batteryNominalCapacityAh
      ..dailyResetTime = defaults.dailyResetTime
      ..pvAvgStartTime = defaults.pvAvgStartTime
      ..pvAvgEndTime = defaults.pvAvgEndTime
      ..touchUnlockEnabled = defaults.touchUnlockEnabled
      ..settingsUsername = defaults.settingsUsername
      ..settingsPassword = defaults.settingsPassword
      ..smartSwitchEnabled = defaults.smartSwitchEnabled
      ..smartSwitchChannel = defaults.smartSwitchChannel
      ..smartSwitchOnSoc = defaults.smartSwitchOnSoc
      ..smartSwitchOffSoc = defaults.smartSwitchOffSoc
      ..smartSwitchRelayState = defaults.smartSwitchRelayState;
  }

  /// Today's reporting day from the phone's own clock and the daily reset
  /// time (e.g. before 07:00 AM still counts as the previous day). Never
  /// taken from the latest summary in Firebase, which may be days old.
  DateTime reportingDay([DateTime? at]) {
    final now = at ?? DateTime.now();
    final m = RegExp(
      r'^(\d{1,2}):(\d{2})(?:\s*([AP]M))?$',
      caseSensitive: false,
    ).firstMatch(dailyResetTime.trim());
    var resetMinute = 7 * 60;
    if (m != null) {
      var hour = int.parse(m[1]!) % 24;
      final period = m[3]?.toUpperCase();
      if (period != null) hour = hour % 12 + (period == 'PM' ? 12 : 0);
      resetMinute = hour * 60 + int.parse(m[2]!);
    }
    final day = DateTime(now.year, now.month, now.day);
    return now.hour * 60 + now.minute < resetMinute
        ? day.subtract(const Duration(days: 1))
        : day;
  }

  String reportingDayKey([DateTime? at]) {
    final d = reportingDay(at);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }

  bool get isCustomCloud => cloudMode == 'custom';
  bool get isFirebaseConfigured => firebaseDatabaseUrl.trim().isNotEmpty;

  static final RegExp _macPattern = RegExp(
    r'^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$',
  );

  /// Everything a working system needs is saved on this phone: Firebase
  /// login, a gateway that completed the cloud handover (stage 4+), the
  /// battery mode with its details, the controller and, in Controller + BMS
  /// Mode, the BMS. A system set up this way opens the dashboard at start-up
  /// even if the wizard's last button was never pressed (e.g. after Skip).
  bool get isSetupEffectivelyComplete =>
      isFirebaseConfigured &&
      firebaseEmail.isNotEmpty &&
      deviceId.isNotEmpty &&
      setupHardwareId.isNotEmpty &&
      setupStage >= 4 &&
      hasSupportedControllerModel &&
      (isRs485Controller || _macPattern.hasMatch(srneBleMac)) &&
      (batteryMode == modeControllerBms
          ? _macPattern.hasMatch(jkBmsBleMac)
          : batteryMode == modeControllerOnly &&
                batteryTypes.containsKey(batteryType) &&
                batteryNominalCapacityAh > 0);

  Map<String, dynamic> toJson() => {
    'deviceId': deviceId,
    'firebaseDatabaseUrl': firebaseDatabaseUrl,
    'firebaseApiKey': firebaseApiKey,
    'firebaseEmail': firebaseEmail,
    'setupRequestId': setupRequestId,
    'setupHardwareId': setupHardwareId, 'setupStage': setupStage,
    'jkProfile': jkProfile,
    'esp32Ip': esp32Ip,
    'srneBleMac': srneBleMac,
    'srneBleName': srneBleName,
    'controllerLink': controllerLink,
    'jkBmsBleMac': jkBmsBleMac,
    'jkBmsBleName': jkBmsBleName,
    'isControllerEnabled': isControllerEnabled,
    'isBmsEnabled': isBmsEnabled,
    'isHotspotEnabled': isHotspotEnabled,
    'isGatewayEnabled': isGatewayEnabled,
    'gatewaySsid': gatewaySsid,
    'gatewayPass': '', // Setup secrets belong in the encrypted vault.
    'panelRatedPowerW': panelRatedPowerW,
    'batteryNominalCapacityAh': batteryNominalCapacityAh,
    'controllerModel': controllerModel,
    'batteryMode': batteryMode,
    'batteryType': batteryType,
    'dailyResetTime': dailyResetTime,
    'pvAvgStartTime': pvAvgStartTime,
    'pvAvgEndTime': pvAvgEndTime,
    'cloudMode': cloudMode,
    'touchUnlockEnabled': touchUnlockEnabled,
    'settingsUsername': settingsUsername,
    'settingsPassword': settingsPassword,
    'smartSwitchEnabled': smartSwitchEnabled,
    'smartSwitchChannel': smartSwitchChannel,
    'smartSwitchOnSoc': smartSwitchOnSoc,
    'smartSwitchOffSoc': smartSwitchOffSoc,
    'smartSwitchRelayState': smartSwitchRelayState,
    'isSetupCompleted': isSetupCompleted,
  };

  factory AppConfig.fromJson(Map<String, dynamic> json) {
    final url = json['firebaseDatabaseUrl']?.toString().trim() ?? '';
    final key = json['firebaseApiKey']?.toString().trim() ?? '';
    final rawDevId = json['deviceId']?.toString().trim() ?? '';
    return AppConfig(
      deviceId: rawDevId,
      firebaseDatabaseUrl: url,
      firebaseApiKey: key,
      firebaseEmail: json['firebaseEmail']?.toString() ?? '',
      setupRequestId: json['setupRequestId']?.toString() ?? '',
      setupHardwareId: json['setupHardwareId']?.toString() ?? '',
      setupStage: (json['setupStage'] as num?)?.toInt() ?? 0,
      jkProfile: json['jkProfile']?.toString() ?? 'auto',
      esp32Ip: json['esp32Ip'] ?? '',
      srneBleMac: json['srneBleMac'] ?? '',
      srneBleName: json['srneBleName'] ?? '',
      controllerLink: json['controllerLink'] == 'rs485' ? 'rs485' : 'ble',
      jkBmsBleMac: json['jkBmsBleMac'] ?? '',
      jkBmsBleName: json['jkBmsBleName'] ?? '',
      isControllerEnabled: json['isControllerEnabled'] ?? true,
      isBmsEnabled: json['isBmsEnabled'] ?? false,
      isHotspotEnabled: json['isHotspotEnabled'] ?? true,
      isGatewayEnabled: json['isGatewayEnabled'] ?? true,
      gatewaySsid: json['gatewaySsid']?.toString().trim() ?? '',
      gatewayPass: json['gatewayPass']?.toString() ?? '',
      panelRatedPowerW: (json['panelRatedPowerW'] ?? 0.0).toDouble(),
      batteryNominalCapacityAh: (json['batteryNominalCapacityAh'] ?? 0.0)
          .toDouble(),
      controllerModel: json['controllerModel']?.toString() ?? '',
      batteryMode: isBatteryMode(json['batteryMode']?.toString() ?? '')
          ? json['batteryMode'].toString()
          : '',
      batteryType: batteryTypes.containsKey(json['batteryType']?.toString())
          ? json['batteryType'].toString()
          : '',
      dailyResetTime:
          json['dailyResetTime']?.toString().trim().isNotEmpty == true
          ? json['dailyResetTime']
          : '07:00 AM',
      pvAvgStartTime:
          json['pvAvgStartTime']?.toString().trim().isNotEmpty == true
          ? json['pvAvgStartTime']
          : '07:00 AM',
      pvAvgEndTime: json['pvAvgEndTime']?.toString().trim().isNotEmpty == true
          ? json['pvAvgEndTime']
          : '05:00 PM',
      cloudMode: json['cloudMode']?.toString() ?? 'custom',
      touchUnlockEnabled: json['touchUnlockEnabled'] == true,
      settingsUsername: json['settingsUsername']?.toString().trim() ?? '',
      settingsPassword: json['settingsPassword']?.toString() ?? '',
      smartSwitchEnabled: json['smartSwitchEnabled'] == true,
      smartSwitchChannel: json['smartSwitchChannel']?.toString() ?? 'switch_1',
      smartSwitchOnSoc: (json['smartSwitchOnSoc'] as num?)?.toInt() ?? 99,
      smartSwitchOffSoc: (json['smartSwitchOffSoc'] as num?)?.toInt() ?? 50,
      smartSwitchRelayState: json['smartSwitchRelayState'] == true,
      isSetupCompleted: json['isSetupCompleted'] == true,
    );
  }

  /// What the user must still do after pasting a Firebase config, or null
  /// when both values were found.
  static String? configPasteProblem(AppConfig? parsed) {
    if (parsed == null ||
        (parsed.firebaseDatabaseUrl.isEmpty && parsed.firebaseApiKey.isEmpty)) {
      return 'Config not recognised: no apiKey or databaseURL found. Copy the whole firebaseConfig from Project settings → General → Your apps (Web app).';
    }
    if (parsed.firebaseDatabaseUrl.isEmpty) {
      return 'API key filled in. The config has no databaseURL: copy the https://… link shown at the top of the Realtime Database page.';
    }
    if (parsed.firebaseApiKey.isEmpty) {
      return 'Database URL filled in. The config has no apiKey: copy the Web API Key from Project settings → General.';
    }
    return null;
  }

  static AppConfig? parseFirebaseConfigSnippet(String snippet) {
    try {
      final trimmed = snippet.trim();
      final urlMatch = RegExp(r'''databaseURL["']?\s*:\s*["']([^"']+)["']''')
          .firstMatch(trimmed);
      final keyMatch = RegExp(r'''apiKey["']?\s*:\s*["']([^"']+)["']''')
          .firstMatch(trimmed);
      // Either value is useful alone: a config copied before the Realtime
      // Database existed has an apiKey but no databaseURL.
      if (urlMatch != null || keyMatch != null) {
        return AppConfig(
          firebaseDatabaseUrl: urlMatch?.group(1) ?? '',
          firebaseApiKey: keyMatch?.group(1) ?? '',
        );
      }
      if (trimmed.startsWith('{') && trimmed.endsWith('}')) {
        final parsed = jsonDecode(trimmed);
        if (parsed is Map) {
          return AppConfig(
            firebaseDatabaseUrl: parsed['databaseURL'] ?? '',
            firebaseApiKey: parsed['apiKey'] ?? '',
          );
        }
      }
    } catch (_) {}
    return null;
  }
}
