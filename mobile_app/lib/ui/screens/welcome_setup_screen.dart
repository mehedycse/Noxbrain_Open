import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../models/app_config.dart';
import '../../providers/solar_provider.dart';
import '../../services/esp32_service.dart';
import '../../services/firebase_auth_session.dart';
import '../../services/firebase_service.dart';
import '../../services/settings_lock.dart';
import '../../services/storage_service.dart';
import '../main_navigation.dart';
import '../theme.dart';
import '../widgets/firebase_check_list.dart';
import 'connection_manager_screen.dart';

class WelcomeSetupScreen extends StatefulWidget {
  final bool isFromSettings;
  const WelcomeSetupScreen({super.key, this.isFromSettings = false});
  @override
  State<WelcomeSetupScreen> createState() => _WelcomeSetupScreenState();
}

class _WelcomeSetupScreenState extends State<WelcomeSetupScreen> {
  final _url = TextEditingController(), _key = TextEditingController();
  final _email = TextEditingController(), _password = TextEditingController();
  final _wifiPassword = TextEditingController();
  // Last step: the login that unlocks Settings on this phone.
  final _loginUser = TextEditingController();
  final _loginPassword = TextEditingController();
  final _loginConfirm = TextEditingController();
  final _gateway = Esp32Service();
  late AppConfig _draft;
  int _step = 0;
  String _mode = '';
  // Step 1: how the gateway reaches the controller (Bluetooth or RS485).
  String _link = AppConfig.linkBle;
  bool _busy = false, _gatewayVerified = false, _devicesReady = false;
  // _messageError: the message comes from a failed action.
  bool _messageError = false, _autoConfirming = false, _handoverRunning = false;
  // The gateway keeps its own ID and Firebase login (re-setup, same project).
  bool _keepGatewayLogin = false;
  String _message = '', _selectedWifi = '', _hardware = '';
  List<Map<String, dynamic>> _networks = [];
  List<FirebaseCheck> _checks = [];
  final _titles = [
    'NoxBrain Setup',
    'Controller Connection',
    'Connect Your Firebase',
    'Connect Your Phone to the Gateway',
    'Give the Gateway Your Home Wi-Fi',
    'Reconnect Your Phone to the Internet',
    'Controller and Battery',
    'Create Settings Login',
  ];

  @override
  void initState() {
    super.initState();
    _draft = AppConfig.fromJson(context.read<SolarProvider>().config.toJson());
    _url.text = _draft.firebaseDatabaseUrl;
    _key.text = _draft.firebaseApiKey;
    _email.text = _draft.firebaseEmail;
    _hardware = _draft.setupHardwareId;
    _loginUser.text = _draft.settingsUsername;
    // Resume where an interrupted first setup stopped. Stage 4 means the
    // cloud handover was already verified: continue with controller and BMS.
    _gatewayVerified = !_draft.isSetupCompleted &&
        _draft.setupStage >= 4 &&
        _hardware.isNotEmpty;
    // Step 0 is the battery mode; an interrupted setup resumes after it.
    _mode = _draft.batteryMode;
    _link = _draft.controllerLink;
    _step = _draft.isSetupCompleted || !AppConfig.isBatteryMode(_mode)
        ? 0
        : (_gatewayVerified
              ? 6
              : (_draft.setupStage >= 3 && _hardware.isNotEmpty
                    ? 5
                    : (_draft.setupStage >= 1 ? 3 : 1)));
    // Resumed after the details were sent: confirm the connection by itself.
    if (_step == 5) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _autoConfirm());
    }
  }

  @override
  void dispose() {
    for (final c in [
      _url,
      _key,
      _email,
      _password,
      _wifiPassword,
      _loginUser,
      _loginPassword,
      _loginConfirm,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = '';
      _messageError = false;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) {
        setState(() {
          _message = FirebaseAuthSession.message(e);
          _messageError = true;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _next(int step) {
    if (mounted) {
      setState(() {
        _step = step;
        _message = '';
        _messageError = false;
      });
    }
  }

  /// Read-only check of every Firebase requirement, shown as a checklist.
  Future<void> _checkCloud() async {
    final probe = AppConfig.fromJson(_draft.toJson())
      ..firebaseDatabaseUrl = _url.text.trim()
      ..firebaseApiKey = _key.text.trim()
      ..firebaseEmail = _email.text.trim();
    final rows = await FirebaseAuthSession.checkConnection(
      probe,
      _email.text,
      _password.text,
    );
    if (mounted) setState(() => _checks = rows);
  }

  /// Step 0: Only Controller Mode or Controller + BMS Mode. Saved in the app
  /// now and on the gateway in the last step.
  Future<void> _saveMode() async {
    if (!AppConfig.isBatteryMode(_mode)) {
      throw Exception('Select a mode.');
    }
    _draft.batteryMode = _mode;
    if (_mode == AppConfig.modeControllerOnly) _draft.isBmsEnabled = false;
    await context.read<SolarProvider>().updateConfig(_draft);
    _next(1);
  }

  /// Step 1: Bluetooth or RS485 controller connection. Saved in the app now;
  /// the gateway uses it when the controller is added in the device step.
  Future<void> _saveLink() async {
    if (!AppConfig.controllerLinkLabels.containsKey(_link)) {
      throw Exception('Select a controller connection.');
    }
    _draft.controllerLink = _link;
    await context.read<SolarProvider>().updateConfig(_draft);
    _next(2);
  }

  /// Step 1 (Internet): verify the user's Firebase and authorize this app's
  /// gateway ID before the phone joins the gateway hotspot, so the hotspot
  /// part needs no Internet and only one Wi-Fi switch each way.
  Future<void> _verifyCloud() async {
    _draft.firebaseDatabaseUrl = FirebaseAuthSession.validateDatabaseUrl(
      _url.text,
    );
    _draft.firebaseApiKey = _key.text.trim();
    _draft.cloudMode = 'custom';
    await FirebaseAuthSession.signIn(_draft, _email.text, _password.text);
    // This is a real setup intent scoped to this gateway, not telemetry or
    // arbitrary test data. Failure means write access was not verified.
    _draft.setupRequestId =
        'setup-${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 30)}';
    await FirebaseAuthSession.checkOwnershipAccess(_draft);
    await FirebaseAuthSession.claimGateway(_draft);
    await FirebaseAuthSession.prepareDeviceAccount(_draft);
    await FirebaseService(_draft).write('setup/request', {
      'request_id': _draft.setupRequestId,
      'state': 'awaiting_gateway',
      'requested_at': {'.sv': 'timestamp'},
    });
    // Store verified cloud config, but never mark setup complete here.
    _draft.isSetupCompleted = false;
    _draft.setupStage = 1;
    if (!mounted) return;
    await context.read<SolarProvider>().updateConfig(_draft);
    _next(3);
  }

  /// Step 2 (phone on the gateway hotspot): confirm it is a NoxBrain gateway
  /// in setup mode, open a session and list the home Wi-Fi it can see.
  Future<void> _connectGateway() async {
    final Map<String, dynamic> info;
    try {
      info = await _gateway.setupRequest('/api/info');
    } catch (_) {
      throw Exception(
        'Gateway not found. In your phone\'s Wi-Fi settings, join the NoxBrain-… Wi-Fi (password ${Esp32Service.hotspotPassword}). If it says "No internet", choose "Stay connected".',
      );
    }
    if (info['product'] != 'NoxBrain' || info['protocol_version'] != 1) {
      throw Exception('This is not a NoxBrain gateway.');
    }
    if (info['setup_active'] != true) {
      throw Exception(
        'The gateway is not in setup mode. Press the ESP32 BOOT button 3 times within one second.',
      );
    }
    final idPattern = RegExp(r'^[A-Za-z0-9_-]{6,64}$');
    final hardware = info['hardware_id']?.toString() ?? '';
    final currentId = info['device_id']?.toString() ?? '';
    if (!idPattern.hasMatch(hardware)) {
      throw Exception('Invalid gateway identity.');
    }
    // A gateway already set up under another ID in the same Firebase project
    // keeps its ID and device login: only the home Wi-Fi changes, and the
    // ownership is checked in the cloud step after the hotspot.
    _keepGatewayLogin = false;
    if (info['configured'] == true &&
        currentId != _draft.deviceId &&
        idPattern.hasMatch(currentId) &&
        info['keep_firebase'] == true) {
      try {
        _keepGatewayLogin = FirebaseAuthSession.validateDatabaseUrl(
              info['database_url']?.toString() ?? '',
            ) ==
            FirebaseAuthSession.validateDatabaseUrl(_draft.firebaseDatabaseUrl);
      } catch (_) {}
    }
    if (_keepGatewayLogin) {
      _draft.deviceId = currentId;
    } else if (info['configured'] == true &&
        currentId != _draft.deviceId &&
        idPattern.hasMatch(currentId)) {
      // Otherwise that ID keeps its data path but must first be authorized
      // for this account over the Internet.
      _draft.deviceId = currentId;
      _draft.setupStage = 0;
      if (!mounted) return;
      await context.read<SolarProvider>().updateConfig(_draft);
      _next(2);
      throw Exception(
        'This gateway was set up before. Reconnect your phone to the internet and confirm the Firebase step again, then join the gateway Wi-Fi again. Earlier data stays in the same place.',
      );
    }
    _hardware = hardware;
    _draft.setupHardwareId = hardware;
    _draft.gatewaySsid = info['setup_ssid']?.toString() ?? '';
    await _gateway.pair();
    await _loadHomeNetworks();
    _next(4);
  }

  /// Confirms the phone is still on the same gateway before any secret is sent.
  Future<void> _ensureGateway() async {
    final info = await _gateway.setupRequest('/api/info');
    if (info['hardware_id'] != _hardware) {
      throw Exception('The gateway changed. Find the gateway again.');
    }
    if (_gateway.setupToken == null) await _gateway.pair();
  }

  Future<void> _loadHomeNetworks() async {
    await _ensureGateway();
    final response = await _gateway.setupRequest('/api/setup/wifi');
    if (!mounted) return;
    setState(
      () => _networks = (response['networks'] as List)
          .map((v) => Map<String, dynamic>.from(v as Map))
          .where((v) => !v['ssid'].toString().startsWith('NoxBrain-'))
          .toList(),
    );
  }

  Future<void> _sendConfig() async {
    if (_selectedWifi.isEmpty) {
      throw Exception('Select your 2.4 GHz home Wi-Fi.');
    }
    final body = <String, dynamic>{
      'wifi_ssid': _selectedWifi,
      'wifi_password': _wifiPassword.text,
      'device_id': _draft.deviceId,
      'request_id': _draft.setupRequestId,
      'timezone_offset_seconds': DateTime.now().timeZoneOffset.inSeconds,
    };
    if (_keepGatewayLogin) {
      // Same Firebase project: the gateway keeps its saved login.
      body['keep_firebase'] = true;
    } else {
      // The gateway gets its own limited device account, never the owner's login.
      final device = await FirebaseAuthSession.deviceCredentials(_draft);
      body.addAll({
        'database_url': _draft.firebaseDatabaseUrl,
        'api_key': _draft.firebaseApiKey,
        'email': device['email'],
        'password': device['password'],
      });
    }
    await _ensureGateway();
    await _gateway.setupRequest('/api/setup/config', body: body);
    _draft.setupStage = 3;
    if (!mounted) return;
    await context.read<SolarProvider>().updateConfig(_draft);
    _next(5);
    await _waitForLocalCloud();
    unawaited(_autoConfirm());
  }

  Future<void> _waitForLocalCloud() async {
    final end = DateTime.now().add(const Duration(seconds: 100));
    while (mounted && DateTime.now().isBefore(end)) {
      Map<String, dynamic> status;
      try {
        status = await _gateway.setupRequest('/api/setup/status');
      } catch (_) {
        if (mounted) {
          setState(
            () => _message = 'The link to the gateway ended while the Wi-Fi was changing. Reconnect your phone to the internet; the app confirms the connection by itself.',
          );
        }
        return;
      }

      if (status['request_id'] != _draft.setupRequestId ||
          status['hardware_id'] != _hardware) {
        throw Exception('The setup session does not match. Find the gateway again.');
      }
      if (status['state'] == 'failed') {
        throw Exception(status['message'] ?? 'Gateway connection failed.');
      }
      if (mounted) {
        setState(
          () => _message = status['wifi_connected'] == true
              ? 'The gateway joined your Wi-Fi and is checking Firebase…'
              : 'The gateway is joining your home Wi-Fi…',
        );
      }
      if (status['cloud_connected'] == true) {
        if (mounted) {
          setState(
            () => _message = 'The gateway is online. Now reconnect your phone to your home Wi-Fi or mobile data; the app confirms the connection by itself.',
          );
        }
        return;
      }
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    throw Exception(
      'The gateway did not come online. Try again; if needed, correct the Wi-Fi password in the previous step.',
    );
  }

  /// Step 4: after the phone is back on the internet, confirms the gateway's
  /// cloud connection by itself every few seconds (same check as the manual
  /// "Check now" button), for up to five minutes.
  Future<void> _autoConfirm() async {
    if (_autoConfirming || !mounted) return;
    setState(() => _autoConfirming = true);
    final end = DateTime.now().add(const Duration(minutes: 5));
    try {
      while (mounted &&
          _step == 5 &&
          !_gatewayVerified &&
          DateTime.now().isBefore(end)) {
        await Future<void>.delayed(const Duration(seconds: 5));
        if (!mounted || _step != 5 || _busy || _gatewayVerified) continue;
        try {
          await _verifyHandover();
        } catch (_) {
          // Not online yet: the phone is still on the hotspot or the gateway
          // is still connecting. Try again on the next round.
        }
      }
    } finally {
      if (mounted) setState(() => _autoConfirming = false);
    }
  }

  /// Never runs twice at the same time (automatic and manual check).
  Future<void> _verifyHandover() async {
    if (_handoverRunning) return;
    _handoverRunning = true;
    try {
      await _verifyHandoverOnce();
    } finally {
      _handoverRunning = false;
    }
  }

  Future<void> _verifyHandoverOnce() async {
    // A gateway ID taken over in the hotspot step must belong to this
    // account (or be unclaimed) before its status is read or handed over.
    // Returns at once when this account already owns it.
    await FirebaseAuthSession.claimGateway(_draft);
    final cloud = FirebaseService(_draft);
    final status = await cloud.setupStatus();
    final updated = (status['updated_at'] as num?)?.toInt() ?? 0;
    final age = DateTime.now().millisecondsSinceEpoch - updated;
    if (status['hardware_id'] != _hardware ||
        status['request_id'] != _draft.setupRequestId ||
        age < -5000 ||
        age > 20000 ||
        status['state'] != 'online') {
      throw Exception(
        'No fresh cloud status from this gateway yet. Make sure your phone has internet and try again.',
      );
    }
    await cloud.sendGatewayCommand('handover', {
      'request_id': _draft.setupRequestId,
    });
    // The gateway saved the new account: make it the registered one. If this
    // phone loses the internet here, the pending account keeps working and
    // the promotion is repeated on the next app start.
    await FirebaseAuthSession.markHandoverConfirmed(_draft);
    try {
      await FirebaseAuthSession.promotePendingDeviceAccount(_draft);
    } catch (_) {}
    if (!mounted) return;
    final saved = await cloud.read('live');
    if (saved is Map) {
      _draft.srneBleMac =
          saved['controller_mac']?.toString() ?? _draft.srneBleMac;
      _draft.jkBmsBleMac = saved['bms_mac']?.toString() ?? _draft.jkBmsBleMac;
      // A new gateway reports its default link ('ble') before any controller
      // is chosen; keep the step 2 choice then. Take the gateway's link only
      // when it already has a controller (RS485, or a saved Bluetooth MAC).
      final savedLink = saved['controller_link']?.toString() ?? '';
      final hasSavedController = savedLink == AppConfig.linkRs485 ||
          RegExp(r'^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$')
              .hasMatch(saved['controller_mac']?.toString() ?? '');
      if (hasSavedController &&
          AppConfig.controllerLinkLabels.containsKey(savedLink)) {
        _draft.controllerLink = savedLink;
      }
      _draft.jkProfile = saved['bms_profile']?.toString() ?? _draft.jkProfile;
      final savedModel = saved['controller_model']?.toString() ?? '';
      if (AppConfig.isSupportedControllerModel(savedModel)) {
        _draft.controllerModel = savedModel;
      }
      _draft.isControllerEnabled = saved['controller_enabled'] != false;
      _draft.isBmsEnabled = saved['bms_enabled'] == true;
    }
    if (!mounted) return;
    setState(() => _gatewayVerified = true);
    _draft.setupStage = 4;
    await context.read<SolarProvider>().updateConfig(_draft);
    _next(6);
  }

  void _checkDevicesReady() {
    if (!_gatewayVerified || !_devicesReady) {
      throw Exception(
        'Finish the gateway, controller, system mode and (in Controller + BMS Mode) BMS checks first.',
      );
    }
  }

  /// Controller and battery checked: go on to the Settings login.
  Future<void> _toLogin() async {
    _checkDevicesReady();
    _next(7);
  }

  Future<void> _finish() async {
    _checkDevicesReady();
    final user = _loginUser.text.trim();
    final password = _loginPassword.text.trim();
    final keepExisting = password.isEmpty &&
        _loginConfirm.text.trim().isEmpty &&
        context.read<SolarProvider>().config.settingsPassword.isNotEmpty;
    if (user.isEmpty) throw Exception('Enter a username for Settings.');
    if (!keepExisting) {
      if (password.length < 6) {
        throw Exception('The password needs at least 6 characters.');
      }
      if (password != _loginConfirm.text.trim()) {
        throw Exception('The two passwords do not match.');
      }
    }
    _draft = context.read<SolarProvider>().config;
    await FirebaseService(_draft).saveReportingOptions();
    _draft.settingsUsername = user;
    if (!keepExisting) _draft.settingsPassword = SettingsLock.hash(password);
    // Just created by this user: Settings stay open for this app run.
    await StorageService.setSessionUnlocked(true);
    _draft.isSetupCompleted = true;
    _draft.setupStage = 5;
    if (!mounted) return;
    await context.read<SolarProvider>().updateConfig(_draft);
    if (!mounted) return;
    if (widget.isFromSettings) {
      Navigator.pop(context);
    } else {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const MainNavigation()),
      );
    }
  }

  Future<void> _firebaseGuide() async {
    final rules = await rootBundle.loadString(
      'assets/setup/database.rules.json',
    );
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Prepare Your Own Firebase',
                  style: Theme.of(ctx).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: SolarTheme.textPrimary,
                  ),
                ),
                const SizedBox(height: 14),
                Text.rich(
                  TextSpan(
                    style: const TextStyle(
                      color: SolarTheme.textSecondary,
                      fontSize: 13.5,
                      height: 1.5,
                    ),
                    children: [
                      const TextSpan(
                        text:
                            '1. Create your own project in the Firebase Console.\n\n2. In ',
                      ),
                      const TextSpan(
                        text: 'Project settings → General',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: SolarTheme.textPrimary,
                        ),
                      ),
                      const TextSpan(
                        text:
                            ', register a Web app and copy its firebaseConfig. Pasting it in the app fills in the API key and database URL; if the URL is missing from the config, copy it from the Realtime Database page.\n\n3. In ',
                      ),
                      const TextSpan(
                        text: 'Authentication → Sign-in method',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: SolarTheme.textPrimary,
                        ),
                      ),
                      const TextSpan(text: ', enable '),
                      const TextSpan(
                        text: 'Email/Password',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: SolarTheme.textPrimary,
                        ),
                      ),
                      const TextSpan(text: '. Then in '),
                      const TextSpan(
                        text: 'Users → Add user',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: SolarTheme.textPrimary,
                        ),
                      ),
                      const TextSpan(
                        text:
                            ', create an account with an email and a new password. Enter exactly this email and password in the app. This is the password of this Firebase account, not your Gmail or email password; never enter your Gmail password. Keep new user sign-up enabled in ',
                      ),
                      const TextSpan(
                        text: 'Authentication settings',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: SolarTheme.textPrimary,
                        ),
                      ),
                      const TextSpan(
                        text:
                            '; the app creates a separate limited account for each gateway by itself.\n\n4. Create the Realtime Database. In its ',
                      ),
                      const TextSpan(
                        text: 'Rules tab',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: SolarTheme.textPrimary,
                        ),
                      ),
                      const TextSpan(
                        text: ', paste the rules from the button below and ',
                      ),
                      const TextSpan(
                        text: 'Publish',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: SolarTheme.textPrimary,
                        ),
                      ),
                      const TextSpan(
                        text:
                            '. Do not enable public read/write.\n\n5. In this app, check with the URL, API key, Authentication email and password. When a gateway is chosen, read/write is checked on its own ID.',
                      ),
                    ],
                  ),
                  textAlign: TextAlign.justify,
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF475569),
                      foregroundColor: SolarTheme.textPrimary,
                      alignment: Alignment.center,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      textStyle: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: rules));
                      if (ctx.mounted) {
                        ScaffoldMessenger.of(ctx).showSnackBar(
                          const SnackBar(
                            content: Text(
                              'Database rules copied. Paste them in your own Firebase Console.',
                            ),
                          ),
                        );
                      }
                    },
                    child: const Center(
                      child: Text(
                        'Copy the Database Rules',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                const Text(
                  'Publishing rules is a change in your own Firebase. The app never creates a project or publishes rules by itself. Your Authentication password is never saved: the app uses it only while checking, then keeps just a sign-in token in the phone\'s secure storage. The gateway gets only its own separate device account, which can access only that gateway\'s data.',
                  textAlign: TextAlign.justify,
                  style: TextStyle(
                    color: SolarTheme.textMuted,
                    fontSize: 12.5,
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _field(
    String label,
    TextEditingController controller, {
    bool secret = false,
    String? helper,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: TextField(
      controller: controller,
      obscureText: secret,
      autocorrect: false,
      enableSuggestions: !secret,
      style: const TextStyle(color: SolarTheme.textPrimary, fontSize: 15),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: SolarTheme.textSecondary),
        helperText: helper,
        helperStyle: const TextStyle(color: SolarTheme.textMuted, fontSize: 12),
        helperMaxLines: 3,
        filled: true,
        fillColor: SolarTheme.surface,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: SolarTheme.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFF94A3B8), width: 1.5),
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: SolarTheme.border),
        ),
      ),
    ),
  );

  /// Information card in the setup theme.
  Widget _infoCard(IconData icon, String text) => Container(
    margin: const EdgeInsets.only(bottom: 12),
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: SolarTheme.surface,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: SolarTheme.border.withOpacity(0.6)),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: SolarTheme.textMuted),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(
              color: SolarTheme.textSecondary,
              fontSize: 13,
              height: 1.45,
            ),
          ),
        ),
      ],
    ),
  );

  /// "Who connects to what" in one line: from → to.
  Widget _flow(IconData from, String fromLabel, IconData to, String toLabel) {
    Widget end(IconData icon, String label) => Expanded(
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: SolarTheme.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: SolarTheme.border.withOpacity(0.6)),
            ),
            child: Icon(icon, size: 22, color: const Color(0xFF94A3B8)),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: SolarTheme.textPrimary,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 10),
      decoration: BoxDecoration(
        color: SolarTheme.surfaceLight,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: SolarTheme.border.withOpacity(0.5)),
      ),
      child: Row(
        children: [
          end(from, fromLabel),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 4),
            child: Icon(
              Icons.arrow_forward_rounded,
              size: 20,
              color: SolarTheme.textMuted,
            ),
          ),
          end(to, toLabel),
        ],
      ),
    );
  }

  /// A finished part of the current step.
  Widget _done(String text) => Container(
    margin: const EdgeInsets.only(bottom: 12),
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    decoration: BoxDecoration(
      color: SolarTheme.surfaceLight,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: SolarTheme.batteryGreen.withOpacity(0.35)),
    ),
    child: Row(
      children: [
        const Icon(
          Icons.check_circle_rounded,
          size: 18,
          color: SolarTheme.batteryGreen,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(
              color: SolarTheme.textPrimary,
              fontWeight: FontWeight.w600,
              fontSize: 13.5,
            ),
          ),
        ),
      ],
    ),
  );

  String _signal(dynamic rssi) {
    final v = rssi is num ? rssi : num.tryParse('$rssi') ?? -100;
    return v >= -60 ? 'strong signal' : (v >= -75 ? 'good signal' : 'weak signal');
  }

  Widget _button(
    String label,
    Future<void> Function() action, {
    bool primary = true,
  }) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: SizedBox(
      width: double.infinity,
      height: 48,
      child: FilledButton(
        style: FilledButton.styleFrom(
          backgroundColor: primary
              ? const Color(0xFF475569)
              : SolarTheme.surfaceLight,
          foregroundColor: SolarTheme.textPrimary,
          side: primary
              ? null
              : const BorderSide(color: SolarTheme.border),
          disabledBackgroundColor: SolarTheme.surfaceLight,
          disabledForegroundColor: SolarTheme.textMuted,
          elevation: 0,
          shadowColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.2,
          ),
        ),
        onPressed: _busy ? null : () => _run(action),
        child: Text(label),
      ),
    ),
  );

  Widget _modeCard({
    required String title,
    required String subtitle,
    required String value,
    required IconData icon,
    // Defaults to the battery mode; the controller connection step passes its own.
    String? groupValue,
    ValueChanged<String>? onSelect,
  }) {
    final isSelected = (groupValue ?? _mode) == value;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: _busy
              ? null
              : () => setState(() {
                  if (onSelect != null) {
                    onSelect(value);
                  } else {
                    _mode = value;
                  }
                }),
          borderRadius: BorderRadius.circular(16),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: isSelected
                  ? SolarTheme.surfaceLight
                  : SolarTheme.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: isSelected
                    ? const Color(0xFF64748B)
                    : SolarTheme.border,
                width: isSelected ? 1.4 : 1.0,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: isSelected
                            ? SolarTheme.surface
                            : SolarTheme.surfaceLight,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(
                        icon,
                        size: 20,
                        color: isSelected
                            ? const Color(0xFF94A3B8)
                            : SolarTheme.textMuted,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        title,
                        style: const TextStyle(
                          color: SolarTheme.textPrimary,
                          fontSize: 15.5,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.2,
                        ),
                      ),
                    ),
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      width: 20,
                      height: 20,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: isSelected
                              ? const Color(0xFF94A3B8)
                              : SolarTheme.border,
                          width: 1.5,
                        ),
                      ),
                      child: isSelected
                          ? Center(
                              child: Container(
                                width: 10,
                                height: 10,
                                decoration: const BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: Color(0xFF94A3B8),
                                ),
                              ),
                            )
                          : null,
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  subtitle,
                  style: const TextStyle(
                    color: SolarTheme.textSecondary,
                    fontSize: 13,
                    height: 1.45,
                    letterSpacing: 0.1,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _openPreview() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        duration: Duration(seconds: 6),
        content: Text(
          'Preview: setup is not finished, so there is no data. Nothing was saved; close and reopen the app to return to setup.',
        ),
      ),
    );
    context.read<SolarProvider>().enterPreview();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('NoxBrain Setup'),
          backgroundColor: SolarTheme.surface,
          elevation: 0,
        ),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: (_step + 1) / _titles.length,
                  backgroundColor: SolarTheme.surfaceLight,
                  valueColor: const AlwaysStoppedAnimation<Color>(
                    Color(0xFF64748B),
                  ),
                  minHeight: 3,
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: SolarTheme.surface,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: SolarTheme.border,
                        width: 1,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 6,
                          height: 6,
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            color: Color(0xFF64748B),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          'Step ${_step + 1} / ${_titles.length}',
                          style: const TextStyle(
                            color: SolarTheme.textSecondary,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.2,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Spacer(),
                  // Only moves between pages to look at them: nothing is
                  // checked or saved. Each page's own buttons still verify
                  // their prerequisites, so setup can never finish this way.
                  TextButton.icon(
                    onPressed: _busy || _step == 0
                        ? null
                        : () => _next(_step - 1),
                    style: TextButton.styleFrom(
                      foregroundColor: SolarTheme.textSecondary,
                    ),
                    icon: const Icon(Icons.chevron_left_rounded, size: 20),
                    label: const Text('Previous'),
                  ),
                  TextButton.icon(
                    onPressed: _busy || _step == _titles.length - 1
                        ? null
                        : () => _next(_step + 1),
                    style: TextButton.styleFrom(
                      foregroundColor: SolarTheme.textSecondary,
                    ),
                    iconAlignment: IconAlignment.end,
                    icon: const Icon(Icons.chevron_right_rounded, size: 20),
                    label: const Text('Next'),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                _titles[_step],
                style: const TextStyle(
                  color: SolarTheme.textPrimary,
                  fontSize: 21,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.2,
                ),
              ),
              const SizedBox(height: 14),
              if (_step == 0) ...[
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: SolarTheme.surface,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: SolarTheme.border.withOpacity(0.6),
                    ),
                  ),
                  child: const Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.info_outline_rounded,
                        size: 18,
                        color: SolarTheme.textMuted,
                      ),
                      SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Choose the mode by whether your system has a JK BMS. You can change it later in Settings → Connectivity.',
                          style: TextStyle(
                            color: SolarTheme.textSecondary,
                            fontSize: 13,
                            height: 1.45,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                _modeCard(
                  title: 'Only Controller Mode',
                  subtitle:
                      'No BMS (for example flooded/sealed lead-acid). Battery values are calculated from the controller data; every load must be on the controller\'s Load terminal.',
                  value: AppConfig.modeControllerOnly,
                  icon: Icons.tune_rounded,
                ),
                _modeCard(
                  title: 'Controller + BMS Mode',
                  subtitle:
                      'You have a JK BMS. All battery values come from the BMS.',
                  value: AppConfig.modeControllerBms,
                  icon: Icons.battery_charging_full_rounded,
                ),
                const SizedBox(height: 8),
                _button('Next Step', _saveMode),
              ],
              if (_step == 1) ...[
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: SolarTheme.surface,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: SolarTheme.border.withOpacity(0.6),
                    ),
                  ),
                  child: const Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.info_outline_rounded,
                        size: 18,
                        color: SolarTheme.textMuted,
                      ),
                      SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Choose how the gateway connects to the controller. You can change it later in Settings → Connectivity.',
                          style: TextStyle(
                            color: SolarTheme.textSecondary,
                            fontSize: 13,
                            height: 1.45,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                _modeCard(
                  title: 'Bluetooth',
                  subtitle:
                      'The gateway finds the controller over Bluetooth and connects to it.',
                  value: AppConfig.linkBle,
                  icon: Icons.bluetooth_rounded,
                  groupValue: _link,
                  onSelect: (v) => _link = v,
                ),
                _modeCard(
                  title: 'RS485',
                  subtitle:
                      "The controller is wired to the gateway's RS485 module. The gateway searches the wire for it.",
                  value: AppConfig.linkRs485,
                  icon: Icons.cable_rounded,
                  groupValue: _link,
                  onSelect: (v) => _link = v,
                ),
                const SizedBox(height: 8),
                _button('Next Step', _saveLink),
              ],
              if (_step == 2) ...[
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: SolarTheme.surface,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: SolarTheme.border.withOpacity(0.6),
                    ),
                  ),
                  child: const Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.cloud_outlined,
                        size: 20,
                        color: Color(0xFF94A3B8),
                      ),
                      SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Keep the internet on. Each user uses their own Firebase. Email/Password Authentication and the database rules must be ready.',
                          style: TextStyle(
                            color: SolarTheme.textSecondary,
                            fontSize: 13,
                            height: 1.45,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFFCBD5E1),
                    side: const BorderSide(color: Color(0xFF475569)),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onPressed: _busy
                      ? null
                      : () async {
                          final controller = TextEditingController();
                          final text = await showDialog<String>(
                            context: context,
                            builder: (ctx) => AlertDialog(
                              title: const Text('Paste Firebase Config'),
                              content: TextField(
                                controller: controller,
                                maxLines: 6,
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () =>
                                      Navigator.pop(ctx, controller.text),
                                  child: const Text('Fill in'),
                                ),
                              ],
                            ),
                          );
                          if (text != null) {
                            final parsed = AppConfig.parseFirebaseConfigSnippet(
                              text,
                            );
                            if (parsed != null) {
                              if (parsed.firebaseDatabaseUrl.isNotEmpty) {
                                _url.text = parsed.firebaseDatabaseUrl;
                              }
                              if (parsed.firebaseApiKey.isNotEmpty) {
                                _key.text = parsed.firebaseApiKey;
                              }
                            }
                            final problem = AppConfig.configPasteProblem(
                              parsed,
                            );
                            if (problem != null && mounted) {
                              ScaffoldMessenger.of(this.context).showSnackBar(
                                SnackBar(content: Text(problem)),
                              );
                            }
                          }
                          controller.dispose();
                        },
                  child: const Text('Firebase Config Paste'),
                ),
                TextButton(
                  style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFF94A3B8),
                  ),
                  onPressed: _busy ? null : _firebaseGuide,
                  child: const Text('Simple Guide: Create Firebase and Rules'),
                ),
                const SizedBox(height: 8),
                _field('Realtime Database URL', _url),
                _field('Web API Key', _key),
                _field('Authentication Email', _email),
                _field(
                  'Authentication Password',
                  _password,
                  secret: true,
                  helper: 'The password of the account created in Firebase Authentication → Users; not your Gmail or email password',
                ),
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFFCBD5E1),
                    side: const BorderSide(color: Color(0xFF475569)),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onPressed: _busy ? null : () => _run(_checkCloud),
                  child: const Text('Test Connection (Writes Nothing)'),
                ),
                if (_checks.isNotEmpty) FirebaseCheckList(rows: _checks),
                const SizedBox(height: 8),
                _button('Check and Continue', _verifyCloud),
              ],
              if (_step == 3) ...[
                _flow(
                  Icons.smartphone_rounded,
                  'Your Phone',
                  Icons.router_rounded,
                  'Gateway Wi-Fi',
                ),
                _infoCard(
                  Icons.info_outline_rounded,
                  'For a few minutes your phone joins the gateway\'s own Wi-Fi to give it the setup details. During this time the phone has no internet. That is normal.',
                ),
                Container(
                  margin: const EdgeInsets.only(bottom: 12),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: SolarTheme.surface,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: SolarTheme.border),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Wi-Fi name: ${_draft.gatewaySsid.isEmpty ? 'NoxBrain-…' : _draft.gatewaySsid}',
                        style: const TextStyle(
                          color: SolarTheme.textPrimary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              'Password: ${Esp32Service.hotspotPassword}',
                              style: const TextStyle(
                                color: SolarTheme.textPrimary,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          TextButton.icon(
                            style: TextButton.styleFrom(
                              foregroundColor: const Color(0xFF94A3B8),
                            ),
                            onPressed: () async {
                              await Clipboard.setData(
                                const ClipboardData(
                                  text: Esp32Service.hotspotPassword,
                                ),
                              );
                              if (mounted) {
                                ScaffoldMessenger.of(this.context).showSnackBar(
                                  const SnackBar(
                                    content: Text('Password copied.'),
                                  ),
                                );
                              }
                            },
                            icon: const Icon(Icons.copy_rounded, size: 18),
                            label: const Text('Copy'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                _infoCard(
                  Icons.format_list_numbered_rounded,
                  '1. Keep the gateway powered on. A new gateway opens its setup Wi-Fi by itself. For a gateway that was set up before, press its BOOT button 3 times within one second (the setup Wi-Fi stays open for 20 minutes).\n\n2. Open your phone\'s Wi-Fi settings and join the NoxBrain-… Wi-Fi.\n\n3. If the phone says "No internet", choose "Stay connected", then come back to this app.',
                ),
                _button(
                  'Open Phone Wi-Fi Settings',
                  Esp32Service.openWifiSettings,
                  primary: false,
                ),
                _button('I Am Connected: Find the Gateway', _connectGateway),
              ],
              if (_step == 4) ...[
                _flow(
                  Icons.router_rounded,
                  'Gateway',
                  Icons.home_rounded,
                  'Your Home Wi-Fi',
                ),
                _infoCard(
                  Icons.info_outline_rounded,
                  'The gateway uses your home Wi-Fi to send data to the internet all the time. Only 2.4 GHz Wi-Fi works. Your phone stays on the gateway Wi-Fi during this step.',
                ),
                if (_hardware.isNotEmpty) _done('Gateway found: ${_draft.gatewaySsid.isEmpty ? 'NoxBrain-…' : _draft.gatewaySsid}'),
                if (_networks.isEmpty) ...[
                  _infoCard(
                    Icons.wifi_find_rounded,
                    'Find the Wi-Fi networks the gateway can see. Your phone must be on the gateway Wi-Fi (previous step).',
                  ),
                  _button('Find Wi-Fi Networks', _loadHomeNetworks),
                ],
                if (_networks.isNotEmpty) ...[
                  const Text(
                    'Select your home Wi-Fi:',
                    style: TextStyle(
                      color: SolarTheme.textSecondary,
                      fontSize: 13.5,
                    ),
                  ),
                  const SizedBox(height: 8),
                  ..._networks.map(
                    (n) {
                      final ssid = n['ssid'].toString();
                      final isSelected = _selectedWifi == ssid;
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Material(
                          color: Colors.transparent,
                          child: InkWell(
                            onTap: _busy
                                ? null
                                : () => setState(() => _selectedWifi = ssid),
                            borderRadius: BorderRadius.circular(12),
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 180),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 12,
                              ),
                              decoration: BoxDecoration(
                                color: isSelected
                                    ? SolarTheme.surfaceLight
                                    : SolarTheme.surface,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: isSelected
                                      ? const Color(0xFF64748B)
                                      : SolarTheme.border,
                                ),
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.wifi_rounded,
                                    size: 20,
                                    color: isSelected
                                        ? const Color(0xFF94A3B8)
                                        : SolarTheme.textSecondary,
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          ssid,
                                          style: const TextStyle(
                                            color: SolarTheme.textPrimary,
                                            fontSize: 15,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                        Text(
                                          '${_signal(n['rssi'])} · ${n['rssi']} dBm',
                                          style: const TextStyle(
                                            color: SolarTheme.textMuted,
                                            fontSize: 12,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  if (isSelected)
                                    const Icon(
                                      Icons.check_circle_rounded,
                                      size: 20,
                                      color: Color(0xFF94A3B8),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                  _button(
                    'Scan Again',
                    _loadHomeNetworks,
                    primary: false,
                  ),
                  const SizedBox(height: 8),
                  _field('Home Wi-Fi Password', _wifiPassword, secret: true),
                  _button('Send to the Gateway', _sendConfig),
                ],
              ],
              if (_step == 5) ...[
                _flow(
                  Icons.smartphone_rounded,
                  'Your Phone',
                  Icons.public_rounded,
                  'Home Wi-Fi or Mobile Data',
                ),
                _infoCard(
                  Icons.info_outline_rounded,
                  'The gateway\'s part is done. Now reconnect your phone to your home Wi-Fi or mobile data. The app then confirms the connection by itself.',
                ),
                _button(
                  'Open Phone Wi-Fi Settings',
                  Esp32Service.openWifiSettings,
                  primary: false,
                ),
                if (_autoConfirming)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'Waiting for the internet… the app checks every few seconds.',
                            style: TextStyle(color: SolarTheme.textSecondary),
                          ),
                        ),
                      ],
                    ),
                  )
                else
                  _button('Check Now', _verifyHandover),
                Theme(
                  data: Theme.of(context).copyWith(
                    dividerColor: Colors.transparent,
                  ),
                  child: ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    title: const Text(
                      'Having Trouble?',
                      style: TextStyle(color: SolarTheme.textSecondary),
                    ),
                    children: [
                      _infoCard(
                        Icons.help_outline_rounded,
                        'If the gateway could not join your Wi-Fi, join the gateway Wi-Fi again and show its progress, or go back and correct the home Wi-Fi details.',
                      ),
                      _button(
                        'Show the gateway\'s progress (phone on gateway Wi-Fi)',
                        _waitForLocalCloud,
                        primary: false,
                      ),
                      TextButton(
                        style: TextButton.styleFrom(
                          foregroundColor: const Color(0xFF94A3B8),
                        ),
                        onPressed: _busy ? null : () => _next(4),
                        child: const Text('Change the Home Wi-Fi Details'),
                      ),
                    ],
                  ),
                ),
              ],
              if (_step == 6) ...[
                GatewayDevicesPanel(
                  applyChosenMode: true,
                  onReady: (ready) {
                    if (mounted && ready != _devicesReady) {
                      setState(() => _devicesReady = ready);
                    }
                  },
                ),
                const SizedBox(height: 8),
                _button('Next Step', _toLogin),
              ],
              if (_step == 7) ...[
                _infoCard(
                  Icons.lock_outline_rounded,
                  'This username and password unlock Settings on this phone. You can change them later in Settings → General. If you forget the password, your Firebase password unlocks Settings.',
                ),
                _field('Settings Username', _loginUser),
                _field(
                  'Settings Password',
                  _loginPassword,
                  secret: true,
                  helper: context
                          .read<SolarProvider>()
                          .config
                          .settingsPassword
                          .isNotEmpty
                      ? 'A login already exists. Leave both password fields empty to keep it.'
                      : 'At least 6 characters.',
                ),
                _field('Confirm Password', _loginConfirm, secret: true),
                const SizedBox(height: 8),
                _button('Finish Setup and Open the Dashboard', _finish),
              ],
              if (_busy)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Center(child: CircularProgressIndicator()),
                ),
              if (_message.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: SolarTheme.surfaceLight,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: _messageError
                            ? SolarTheme.batteryDischarging.withOpacity(0.5)
                            : const Color(0xFF64748B).withOpacity(0.5),
                      ),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          _messageError
                              ? Icons.error_outline_rounded
                              : Icons.info_outline_rounded,
                          size: 20,
                          color: _messageError
                              ? SolarTheme.batteryDischarging
                              : const Color(0xFF94A3B8),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            _message,
                            style: const TextStyle(
                              color: SolarTheme.textPrimary,
                              fontSize: 13.5,
                              height: 1.4,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              // Look at every app screen without setup (nothing is saved).
              if (!widget.isFromSettings) ...[
                const SizedBox(height: 24),
                Center(
                  child: TextButton(
                    onPressed: _busy ? null : _openPreview,
                    style: TextButton.styleFrom(
                      foregroundColor: SolarTheme.textMuted,
                    ),
                    child: const Text('Skip (preview)'),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
