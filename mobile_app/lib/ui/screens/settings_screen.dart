import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:local_auth/local_auth.dart';

import '../../providers/solar_provider.dart';
import '../../models/app_config.dart';
import '../../services/storage_service.dart';
import '../../services/firebase_service.dart';
import '../../services/firebase_auth_session.dart';
import 'welcome_setup_screen.dart';
import '../theme.dart';
import '../widgets/firmware_update_sheet.dart';
import '../widgets/reset_actions.dart';
import '../widgets/save_notice.dart';
import 'connection_manager_screen.dart';
import 'diagnostics_screen.dart';
import 'firebase_change_screen.dart';
import '../../services/settings_lock.dart';
import '../../services/weather_service.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, this.controllerOnly = false});

  /// Web view: only the Controller Parameter tab, after the owner has signed
  /// in to Firebase there. The other tabs work from this phone's own saved
  /// settings, which a browser does not have. The app always uses false.
  final bool controllerOnly;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with SingleTickerProviderStateMixin {
  // Auth state
  bool _isUnlocked = false;
  bool _touchUnlockEnabled = false;
  bool _weatherEnabled = false;
  // A weather switch change is still running (permission prompt, saving).
  bool _weatherSaving = false;
  bool _checkingSession = true;
  bool _isAuthenticatingTouch = false;
  final _authUserController = TextEditingController();
  final _authPassController = TextEditingController();
  bool _obscurePass = true;
  String? _authError;

  late TabController _tabController;

  // General tab controllers
  final _deviceIdController = TextEditingController();
  final _settingsUserController = TextEditingController();
  final _settingsPassController = TextEditingController();
  final _panelWattController = TextEditingController();
  final _controllerNameController = TextEditingController();
  final _batteryCapacityController = TextEditingController();
  // Only Controller Mode battery type: key in AppConfig.batteryTypes.
  final _batteryTypeController = TextEditingController();
  String _batteryTypeKey = '';
  // A field this Save button covers has been touched since the last save.
  bool _edited = false;
  final _dailyResetTimeController = TextEditingController(text: '07:00');
  final _pvAvgStartTimeController = TextEditingController(text: '07:00');
  final _pvAvgEndTimeController = TextEditingController(text: '17:00');

  // Battery tab controllers (17 parameters from original site)
  String _batteryProfile = 'UNKNOWN';
  bool _saving = false;
  final Map<String, TextEditingController> _paramControllers = {
    'over_voltage_v': TextEditingController(),
    'charge_limit_v': TextEditingController(),
    'equalization_v': TextEditingController(),
    'boost_absorption_v': TextEditingController(),
    'float_v': TextEditingController(),
    'boost_return_v': TextEditingController(),
    'over_discharge_recovery_v': TextEditingController(),
    'low_voltage_warning_v': TextEditingController(),
    'discharge_cutoff_v': TextEditingController(),
    'discharge_limit_v': TextEditingController(),
    'charge_end_soc_pct': TextEditingController(),
    'discharge_end_soc_pct': TextEditingController(),
    'over_discharge_delay_s': TextEditingController(),
    'equalization_time_min': TextEditingController(),
    'boost_time_min': TextEditingController(),
    'equalization_interval_days': TextEditingController(),
  };
  // Controller Parameter tab: last readback and the edited values.
  Map<String, dynamic> _ctrl = {};
  DateTime? _ctrlReadAt;
  // Filled without a Read: from the gateway's own latest read (true) or the
  // copy this app saved after its last controller command (false).
  bool _ctrlFromGateway = false;
  bool _ctrlPrefillDone = false;
  ({Map<String, dynamic> data, int readAt})? _savedCtrl;
  bool _ctrlBusy = false;
  String _sysVoltage = '';
  String _ctrlBatteryType = '';
  int _tempComp = 0; // stored without minus: 1 = -1 mV/°C/2V
  int? _loadMode;
  final _capacityCtrl = TextEditingController();
  final _chargeCurrentCtrl = TextEditingController();
  final _lightDelayCtrl = TextEditingController();
  final _lightVoltageCtrl = TextEditingController();
  final Map<String, TextEditingController> _temperatureCtrls = {
    'charge_temp_upper_c': TextEditingController(),
    'charge_temp_lower_c': TextEditingController(),
    'discharge_temp_upper_c': TextEditingController(),
    'discharge_temp_lower_c': TextEditingController(),
  };

  // Load tab controllers
  bool _smartSwitchEnabled = true;
  String _smartSwitchChannel = 'switch_1';
  final _smartSwitchOnSoc = TextEditingController(text: '99');
  final _smartSwitchOffSoc = TextEditingController(text: '50');

  // Firebase tab controllers
  final _dbUrlController = TextEditingController();
  final _apiKeyController = TextEditingController();
  final _quickPasteController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 6, vsync: this);
    final provider = context.read<SolarProvider>();
    final config = provider.config;
    _touchUnlockEnabled = config.touchUnlockEnabled;
    _smartSwitchEnabled = config.smartSwitchEnabled;
    _smartSwitchChannel = config.smartSwitchChannel;
    _smartSwitchOnSoc.text = config.smartSwitchOnSoc.toString();
    _smartSwitchOffSoc.text = config.smartSwitchOffSoc.toString();
    _deviceIdController.text = config.deviceId;
    _settingsUserController.text = config.settingsUsername;
    // The unlock prompt starts with the username the user chose, so a
    // renamed login is not met by a stale default that has to be retyped.
    _authUserController.text = config.settingsUsername;
    // The stored value is a hash; the field is only for entering a new one.
    _settingsPassController.text = '';
    _dbUrlController.text = config.firebaseDatabaseUrl;
    _apiKeyController.text = config.firebaseApiKey;
    _panelWattController.text = config.panelRatedPowerW.toStringAsFixed(0);
    _batteryCapacityController.text = config.batteryNominalCapacityAh
        .toStringAsFixed(0);
    _controllerNameController.text = config.controllerModel;
    _batteryTypeKey = config.batteryType;
    _batteryTypeController.text = AppConfig.batteryTypes[_batteryTypeKey] ?? '';
    _dailyResetTimeController.text = config.dailyResetTime;
    _pvAvgStartTimeController.text = config.pvAvgStartTime;
    _pvAvgEndTimeController.text = config.pvAvgEndTime;

    // Touching any field this Save button covers arms it, even when what is
    // typed matches what is already stored: see _onGeneralEdited.
    for (final c in [
      _panelWattController,
      _batteryCapacityController,
      _dailyResetTimeController,
      _pvAvgStartTimeController,
      _pvAvgEndTimeController,
      _smartSwitchOnSoc,
      _smartSwitchOffSoc,
    ]) {
      c.addListener(_onGeneralEdited);
    }
    // Save buttons are active only while something differs from what is saved.
    for (final c in [
      _settingsUserController,
      _settingsPassController,
      _capacityCtrl,
      _chargeCurrentCtrl,
      _lightDelayCtrl,
      _lightVoltageCtrl,
      ..._paramControllers.values,
      ..._temperatureCtrls.values,
    ]) {
      c.addListener(_onEdited);
    }

    _checkInitialSession();
    StorageService.loadControllerReadback(config.deviceId).then((saved) {
      if (mounted) setState(() => _savedCtrl = saved);
    });
  }

  void _onEdited() {
    if (mounted) setState(() {});
  }

  /// A General tab field was edited, so Save becomes available whatever was
  /// typed -- higher, lower, or the same value again.
  ///
  /// Save used to compare the form with the app's own saved config and nothing
  /// else. Panel rating, battery type and capacity also live on the gateway,
  /// and a gateway that is set up again starts with none of them; the app kept
  /// its copy, the form still matched it, so the button stayed grey and there
  /// was no way left to send the gateway the values it was missing. Retyping a
  /// field now arms Save, and saving sends them again.
  void _onGeneralEdited() {
    if (mounted) setState(() => _edited = true);
  }

  void _notify(String message, {bool success = true}) =>
      showSaveNotice(context, message, success: success);

  static int? _minuteOfDay(String text) {
    final m = RegExp(
      r'^(\d{1,2}):(\d{2})(?:\s*([AP]M))?$',
      caseSensitive: false,
    ).firstMatch(text.trim());
    if (m == null) return null;
    var hour = int.parse(m[1]!);
    final period = m[3]?.toUpperCase();
    if (period != null) hour = hour % 12 + (period == 'PM' ? 12 : 0);
    return hour * 60 + int.parse(m[2]!);
  }

  bool _timeDiffers(String text, String saved) {
    final a = _minuteOfDay(text), b = _minuteOfDay(saved);
    return a == null || b == null ? text.trim() != saved.trim() : a != b;
  }

  bool _numDiffers(String text, dynamic saved, {double tolerance = 0}) {
    final value = num.tryParse(text.trim());
    if (value == null) return text.trim().isNotEmpty;
    return saved is! num || (value - saved).abs() > tolerance;
  }

  /// General and Smart Switch values that differ from the saved config.
  bool _settingsDirty(AppConfig c) {
    final panel = double.tryParse(_panelWattController.text.trim());
    if (panel == null || panel != c.panelRatedPowerW) return true;
    if (c.isControllerOnlyMode) {
      final capacity = double.tryParse(_batteryCapacityController.text.trim());
      if (capacity == null || capacity != c.batteryNominalCapacityAh) return true;
      if (_batteryTypeKey != c.batteryType) return true;
    }
    if (_timeDiffers(_dailyResetTimeController.text, c.dailyResetTime) ||
        _timeDiffers(_pvAvgStartTimeController.text, c.pvAvgStartTime) ||
        _timeDiffers(_pvAvgEndTimeController.text, c.pvAvgEndTime)) {
      return true;
    }
    return _smartSwitchChannel != c.smartSwitchChannel ||
        int.tryParse(_smartSwitchOnSoc.text.trim()) != c.smartSwitchOnSoc ||
        int.tryParse(_smartSwitchOffSoc.text.trim()) != c.smartSwitchOffSoc;
  }

  /// Ready-made USER profiles (12V scale). They only fill the fields; the
  /// normal Save buttons still show Now -> New and write with readback.
  static const Map<String, Map<String, num>> _batteryPresets = {
    'LFP 4S': {
      // Charge high enough and hold it long enough that a 4S LiFePO4 pack
      // reaches full and the BMS reads 100% (the earlier 14.2 V / 60 min /
      // 13.5 V float stopped at ~99%). 3.6 V/cell stays under the usual JK
      // cell over-voltage (3.65 V); float 13.8 V keeps it near full.
      'over_voltage_v': 15.0,
      'charge_limit_v': 14.6,
      'equalization_v': 14.4,
      'boost_absorption_v': 14.4,
      'float_v': 13.8,
      'boost_return_v': 13.2,
      'over_discharge_recovery_v': 12.8,
      'low_voltage_warning_v': 12.4,
      'discharge_cutoff_v': 12.0,
      'discharge_limit_v': 11.2,
      'charge_end_soc_pct': 100,
      'discharge_end_soc_pct': 15,
      'over_discharge_delay_s': 5,
      'equalization_time_min': 0,
      'boost_time_min': 120,
      'equalization_interval_days': 0,
      'temperature_compensation_mv': 0,
      'charge_temp_upper_c': 45,
      'charge_temp_lower_c': 0,
      'discharge_temp_upper_c': 60,
      'discharge_temp_lower_c': -20,
    },
    'Flooded': {
      'over_voltage_v': 16.0,
      'charge_limit_v': 15.5,
      'equalization_v': 14.8,
      'boost_absorption_v': 14.6,
      'float_v': 13.5,
      'boost_return_v': 13.2,
      'over_discharge_recovery_v': 12.6,
      'low_voltage_warning_v': 12.0,
      'discharge_cutoff_v': 11.1,
      'discharge_limit_v': 10.6,
      'charge_end_soc_pct': 100,
      'discharge_end_soc_pct': 50,
      'over_discharge_delay_s': 5,
      'equalization_time_min': 120,
      'boost_time_min': 120,
      'equalization_interval_days': 30,
      'temperature_compensation_mv': 3,
      'charge_temp_upper_c': 50,
      'charge_temp_lower_c': -20,
      'discharge_temp_upper_c': 60,
      'discharge_temp_lower_c': -20,
    },
  };

  void _applyPreset(String name) {
    final preset = _batteryPresets[name]!;
    setState(() {
      for (final entry in _paramControllers.entries) {
        final value = preset[entry.key];
        if (value != null) entry.value.text = value.toString();
      }
      for (final entry in _temperatureCtrls.entries) {
        final value = preset[entry.key];
        if (value != null) entry.value.text = value.toString();
      }
      _tempComp = (preset['temperature_compensation_mv'] ?? _tempComp).toInt();
    });
    _notify(
      '$name values filled in. Check them, then tap Save Battery Parameters and Save Temperature Limits.',
    );
  }

  /// A preset can be written only in the USER profile. On a fixed profile
  /// the button runs the same confirmed switch to USER first and fills the
  /// values in once the controller reads back USER.
  Future<void> _presetAfterUserSwitch(SolarProvider provider, String name) async {
    await _switchToUserProfile(provider);
    if (!mounted) return;
    if (_batteryProfile == 'USER') _applyPreset(name);
  }

  Widget _presetButton(String name, SolarProvider provider, bool isUser) => Expanded(
    child: ElevatedButton(
      style: ElevatedButton.styleFrom(
        backgroundColor: const Color(0xFF334155),
        foregroundColor: Colors.white,
        elevation: 0,
        padding: const EdgeInsets.symmetric(vertical: 12),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: const BorderSide(color: Color(0xFF475569)),
        ),
      ),
      onPressed: _ctrlBusy
          ? null
          : () => isUser ? _applyPreset(name) : _presetAfterUserSwitch(provider, name),
      child: Text(
        'Apply $name Profile',
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
      ),
    ),
  );

  bool get _batteryBasicsDirty =>
      (_sysVoltage.isNotEmpty &&
          _sysVoltage != (_ctrl['system_voltage_setting']?.toString() ?? '')) ||
      (_ctrlBatteryType.isNotEmpty && _ctrlBatteryType != _batteryProfile) ||
      _numDiffers(_capacityCtrl.text, _ctrl['battery_capacity_ah']);

  bool get _chargeCurrentDirty => _numDiffers(
    _chargeCurrentCtrl.text,
    _ctrl['max_charge_current_a'],
    tolerance: 0.004,
  );

  bool get _userBlockDirty =>
      _paramControllers.entries.any(
        (e) => _numDiffers(e.value.text, _ctrl[e.key]),
      ) ||
      _tempComp !=
          ((_ctrl['temperature_compensation_mv'] as num?)?.toInt() ?? 0)
              .clamp(0, 5);

  bool get _temperatureDirty => _temperatureCtrls.entries.any(
    (e) => _numDiffers(e.value.text, _ctrl[e.key]),
  );

  bool get _loadSettingsDirty =>
      (_loadMode != null &&
          _loadMode != (_ctrl['load_mode'] as num?)?.toInt()) ||
      _numDiffers(_lightDelayCtrl.text, _ctrl['light_control_delay_min']) ||
      _numDiffers(_lightVoltageCtrl.text, _ctrl['light_control_voltage_v']);

  /// Opens the Controller Parameter tab with the values already known:
  /// the gateway's latest read, else the copy saved after the last command.
  void _prefillController(SolarProvider provider) {
    if (_ctrlPrefillDone || _ctrl.isNotEmpty || _ctrlBusy) return;
    final fromGateway = provider.controllerReadback;
    final saved = _savedCtrl;
    if (fromGateway == null && saved == null) return;
    _ctrlPrefillDone = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _ctrl.isNotEmpty) return;
      if (fromGateway != null) {
        _applyController(fromGateway, fromGateway: true);
      } else {
        _applyController(
          saved!.data,
          readAt: DateTime.fromMillisecondsSinceEpoch(saved.readAt),
        );
      }
    });
  }

  Future<void> _checkInitialSession() async {
    final unlocked = await StorageService.isSessionUnlocked();
    final touchEnabled = await StorageService.isTouchUnlockEnabled();
    final weatherEnabled = await WeatherService.loadEnabled() ?? false;
    if (!mounted) return;
    final config = context.read<SolarProvider>().config;
    final hasPassword = config.settingsPassword.trim().isNotEmpty;
    setState(() {
      _touchUnlockEnabled = touchEnabled;
      _weatherEnabled = weatherEnabled;
      _isUnlocked = !hasPassword || unlocked;
      _checkingSession = false;
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    _authUserController.dispose();
    _authPassController.dispose();
    _deviceIdController.dispose();
    _settingsUserController.dispose();
    _settingsPassController.dispose();
    _dbUrlController.dispose();
    _apiKeyController.dispose();
    _panelWattController.dispose();
    _batteryCapacityController.dispose();
    _batteryTypeController.dispose();
    _controllerNameController.dispose();
    _dailyResetTimeController.dispose();
    _pvAvgStartTimeController.dispose();
    _pvAvgEndTimeController.dispose();
    _smartSwitchOnSoc.dispose();
    _smartSwitchOffSoc.dispose();
    _quickPasteController.dispose();
    for (var c in _paramControllers.values) {
      c.dispose();
    }
    for (var c in _temperatureCtrls.values) {
      c.dispose();
    }
    _capacityCtrl.dispose();
    _chargeCurrentCtrl.dispose();
    _lightDelayCtrl.dispose();
    _lightVoltageCtrl.dispose();
    super.dispose();
  }

  Future<void> _verifyCredentials() async {
    final user = _authUserController.text.trim();
    final pass = _authPassController.text;
    final config = context.read<SolarProvider>().config;
    final expectedUser = config.settingsUsername.trim();
    final expectedPass = config.settingsPassword;

    final isConfigured = expectedUser.isNotEmpty || expectedPass.isNotEmpty;
    final isMatch =
        !isConfigured ||
        ((expectedUser.isEmpty ||
                user.toLowerCase() == expectedUser.toLowerCase()) &&
            SettingsLock.verify(expectedPass, pass));
    if (isMatch && isConfigured && !SettingsLock.isHashed(expectedPass)) {
      // Upgrade a plain password saved by an older version.
      final upgraded = AppConfig.fromJson(config.toJson())
        ..settingsPassword = SettingsLock.hash(pass);
      await context.read<SolarProvider>().updateConfig(upgraded);
      if (!mounted) return;
    }

    if (isMatch) {
      await StorageService.setSessionUnlocked(true);
      if (!mounted) return;
      setState(() {
        _isUnlocked = true;
        _authError = null;
        _authPassController.clear();
      });
    } else {
      setState(() {
        _authError = 'Incorrect username or password. Please try again.';
      });
    }
  }

  Future<void> _handleTouchUnlock() async {
    setState(() => _isAuthenticatingTouch = true);
    try {
      final localAuth = LocalAuthentication();
      final canCheckBiometrics = await localAuth.canCheckBiometrics;
      final isDeviceSupported = await localAuth.isDeviceSupported();

      if (canCheckBiometrics || isDeviceSupported) {
        final authenticated = await localAuth.authenticate(
          localizedReason: 'Please authenticate to unlock Settings',
          biometricOnly: false,
          persistAcrossBackgrounding: true,
        );
        if (authenticated) {
          await StorageService.setSessionUnlocked(true);
          if (!mounted) return;
          setState(() {
            _isUnlocked = true;
            _authError = null;
          });
          return;
        }
      } else {
        // Biometric hardware not available, keep locked and show password prompt
        if (!mounted) return;
        setState(() {
          _isUnlocked = false;
          _authError = 'Biometrics not available. Please enter password.';
        });
      }
    } catch (_) {
      // Hardware error, keep locked and show error
      if (!mounted) return;
      setState(() {
        _isUnlocked = false;
        _authError = 'Biometric authentication failed. Please enter password.';
      });
    } finally {
      if (mounted) setState(() => _isAuthenticatingTouch = false);
    }
  }

  Future<void> _saveSettings(SolarProvider provider) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await _saveSettingsImpl(provider);
    } catch (e) {
      if (mounted) _notify(FirebaseAuthSession.message(e), success: false);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _saveSettingsImpl(SolarProvider provider) async {
    if (_tabController.index == 5) {
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => const WelcomeSetupScreen(isFromSettings: true),
        ),
      );
      return;
    }
    final newConfig = AppConfig.fromJson(provider.config.toJson());
    // Gateway identity and Firebase must only change through verified setup.
    if (_settingsUserController.text.trim().isNotEmpty) {
      newConfig.settingsUsername = _settingsUserController.text.trim();
    }
    if (_settingsPassController.text.trim().isNotEmpty) {
      newConfig.settingsPassword = SettingsLock.hash(
        _settingsPassController.text.trim(),
      );
    }
    newConfig.panelRatedPowerW =
        double.tryParse(_panelWattController.text) ?? 0.0;
    newConfig.batteryNominalCapacityAh =
        double.tryParse(_batteryCapacityController.text) ?? 0.0;
    newConfig.batteryType = _batteryTypeKey;
    if (newConfig.panelRatedPowerW < 0 || newConfig.panelRatedPowerW > 100000) {
      throw Exception('Enter a panel power between 0 and 100000 W.');
    }
    if (_tabController.index == 0 && newConfig.isControllerOnlyMode) {
      if (!AppConfig.batteryTypes.containsKey(newConfig.batteryType)) {
        throw Exception('Select a battery type.');
      }
      if (newConfig.batteryNominalCapacityAh < 1 ||
          newConfig.batteryNominalCapacityAh > 10000) {
        throw Exception('Enter a battery capacity between 1 and 10000 Ah.');
      }
    }
    newConfig.dailyResetTime = _dailyResetTimeController.text.trim();
    newConfig.pvAvgStartTime = _pvAvgStartTimeController.text.trim();
    newConfig.pvAvgEndTime = _pvAvgEndTimeController.text.trim();
    // The PV average window is one daytime span: start must be before end.
    final pvStart = _minuteOfDay(newConfig.pvAvgStartTime);
    final pvEnd = _minuteOfDay(newConfig.pvAvgEndTime);
    if (pvStart != null && pvEnd != null && pvStart >= pvEnd) {
      throw Exception('PV Average Start Time must be before End Time.');
    }
    newConfig.touchUnlockEnabled = _touchUnlockEnabled;

    final onSoc = int.tryParse(_smartSwitchOnSoc.text.trim()) ?? 99;
    final offSoc = int.tryParse(_smartSwitchOffSoc.text.trim()) ?? 50;
    newConfig.smartSwitchEnabled = _smartSwitchEnabled;
    newConfig.smartSwitchChannel = _smartSwitchChannel;
    newConfig.smartSwitchOnSoc = onSoc;
    newConfig.smartSwitchOffSoc = offSoc;

    try {
      if (_tabController.index == 0 && newConfig.isSetupCompleted) {
        // Panel rating, battery type and capacity are used by the gateway's
        // own calculations, so they count as saved only once it confirms.
        await FirebaseService(newConfig).saveSystemOptions();
        await FirebaseService(newConfig).saveReportingOptions();
      }
    } catch (e) {
      if (mounted) _notify(FirebaseAuthSession.message(e), success: false);
      return;
    }
    await provider.updateConfig(newConfig);
    if (!mounted) return;
    setState(() => _edited = false); // Sent: Save goes quiet until the next edit.
    _notify('Settings saved.');
  }

  @override
  Widget build(BuildContext context) {
    if (_checkingSession) {
      return const Scaffold(
        body: Center(
          child: CircularProgressIndicator(color: SolarTheme.solarAmber),
        ),
      );
    }

    if (widget.controllerOnly) {
      return Scaffold(
        appBar: AppBar(title: const Text('Settings')),
        body: Consumer<SolarProvider>(
          builder: (context, provider, child) => _buildControllerTab(provider),
        ),
      );
    }

    if (!_isUnlocked) {
      return _buildLoginGate();
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        bottom: TabBar(
          controller: _tabController,
          isScrollable: true,
          indicatorColor: SolarTheme.solarAmber,
          labelColor: SolarTheme.solarAmber,
          unselectedLabelColor: SolarTheme.textMuted,
          labelStyle: const TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 12,
          ),
          tabs: const [
            Tab(text: 'General'),
            Tab(text: 'Controller Parameter'),
            Tab(text: 'Smart Switch'),
            Tab(text: 'Connectivity'),
            Tab(text: 'Update'),
            Tab(text: 'Cloud'),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.lock_outline_rounded),
            tooltip: 'Lock Settings (Manual Logout)',
            onPressed: () async {
              final messenger = ScaffoldMessenger.of(context);
              await StorageService.setSessionUnlocked(false);
              if (!mounted) return;
              setState(() => _isUnlocked = false);
              messenger.showSnackBar(
                const SnackBar(
                  content: Text('Settings session locked successfully.'),
                ),
              );
            },
          ),
        ],
      ),
      body: Consumer<SolarProvider>(
        builder: (context, provider, child) {
          return TabBarView(
            controller: _tabController,
            children: [
              _buildGeneralTab(provider),
              _buildControllerTab(provider),
              _buildSmartSwitchTab(provider),
              const ConnectionManagerScreen(),
              _buildUpdateTab(provider),
              _buildFirebaseTab(provider),
            ],
          );
        },
      ),
    );
  }

  Widget _buildGeneralTab(SolarProvider provider) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // User Credentials Change Card
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: SolarTheme.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: SolarTheme.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: SolarTheme.solarAmber.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(
                      Icons.admin_panel_settings_rounded,
                      color: SolarTheme.solarAmber,
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'User Access Credentials',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: SolarTheme.textPrimary,
                          ),
                        ),
                        Text(
                          'Change the username and password that unlock Settings',
                          style: TextStyle(
                            fontSize: 11,
                            color: SolarTheme.textMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              _buildTextField(
                controller: _settingsUserController,
                label: 'Login Username',
                hint: 'e.g. admin',
                icon: Icons.person_outline_rounded,
              ),
              const SizedBox(height: 10),
              _buildTextField(
                controller: _settingsPassController,
                label: 'Login Password',
                hint: 'Enter password',
                icon: Icons.lock_outline_rounded,
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: SolarTheme.solarAmber,
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  icon: const Icon(
                    Icons.check_circle_outline_rounded,
                    size: 18,
                  ),
                  label: const Text(
                    'Save User Credentials',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                  ),
                  onPressed: _settingsPassController.text.trim().isEmpty
                      ? null
                      : () {
                    final u = _settingsUserController.text.trim();
                    final p = _settingsPassController.text.trim();
                    if (u.isEmpty || p.isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(
                            'Username and Password cannot be empty!',
                          ),
                        ),
                      );
                      return;
                    }
                    final cfg = provider.config;
                    cfg.settingsUsername = u;
                    _authUserController.text = u;
                    cfg.settingsPassword = SettingsLock.hash(p);
                    _settingsPassController.clear();
                    provider.updateConfig(cfg);
                    _notify('Login saved. Username: $u');
                  },
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _buildTextField(
          controller: _deviceIdController,
          label: 'Gateway Device ID',
          hint: '',
          icon: Icons.developer_board_outlined,
          readOnly: true,
        ),
        const SizedBox(height: 10),
        _buildTextField(
          controller: _panelWattController,
          label: 'Panel Power (W)',
          hint: '225',
          icon: Icons.wb_sunny_outlined,
          isNumber: true,
        ),
        const SizedBox(height: 10),
        _buildTextField(
          controller: _controllerNameController,
          label: 'Controller Model',
          hint: 'Choose the model when you select the controller',
          icon: Icons.memory_outlined,
          readOnly: true,
        ),
        // Only Controller Mode calculates battery values from these; in
        // Controller + BMS Mode the BMS reports them.
        if (provider.config.isControllerOnlyMode) ...[
          const SizedBox(height: 10),
          _buildTextField(
            controller: _batteryCapacityController,
            label: 'Battery Capacity (Ah)',
            hint: '50',
            icon: Icons.battery_std_outlined,
            isNumber: true,
          ),
          const SizedBox(height: 10),
          _buildTextField(
            controller: _batteryTypeController,
            label: 'Battery Type',
            hint: 'Flooded / Sealed (AGM) / Gel / Lithium',
            icon: Icons.battery_unknown_outlined,
            readOnly: true,
            onTap: _pickBatteryType,
          ),
        ],
        const SizedBox(height: 10),
        _buildTimePickerField(
          controller: _dailyResetTimeController,
          label: 'Daily Reset Time',
          hint: '07:00 AM',
          icon: Icons.restore_rounded,
        ),
        const SizedBox(height: 10),
        _buildTimePickerField(
          controller: _pvAvgStartTimeController,
          label: 'PV Average Start Time',
          hint: '07:00 AM',
          icon: Icons.wb_sunny_outlined,
        ),
        const SizedBox(height: 10),
        _buildTimePickerField(
          controller: _pvAvgEndTimeController,
          label: 'PV Average End Time',
          hint: '05:00 PM',
          icon: Icons.nights_stay_outlined,
        ),
        const SizedBox(height: 20),
        _buildSaveButton(provider),
        const SizedBox(height: 12),
        // Collects a report the user reads before sending it on. Same filled
        // style as the other secondary actions on this tab.
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF334155),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
                side: const BorderSide(color: Color(0xFF475569)),
              ),
              elevation: 0,
            ),
            icon: const Icon(
              Icons.troubleshoot_rounded,
              size: 18,
              color: Color(0xFF94A3B8),
            ),
            label: const Text(
              'Diagnostics & Feedback',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
            ),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const DiagnosticsScreen()),
            ),
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF334155), // Slate Gray
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
                side: const BorderSide(color: Color(0xFF475569)),
              ),
              elevation: 0,
            ),
            icon: const Icon(
              Icons.history_toggle_off_rounded,
              size: 18,
              color: Color(0xFF94A3B8),
            ),
            onPressed: _saving
                ? null
                : () async {
                    final accepted = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text(
                          'Delete Recorded History?',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: SolarTheme.textPrimary,
                          ),
                        ),
                        content: const Text(
                          'This gateway\'s local and Firebase history, summary and lifetime statistics will be deleted. Wi-Fi, Firebase sign-in and device selections are kept.',
                          textAlign: TextAlign.justify,
                          style: TextStyle(
                            fontSize: 13,
                            color: SolarTheme.textSecondary,
                            height: 1.45,
                          ),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(ctx, false),
                            child: const Text('Cancel'),
                          ),
                          TextButton(
                            onPressed: () => Navigator.pop(ctx, true),
                            child: const Text(
                              'Delete History',
                              style: TextStyle(fontWeight: FontWeight.bold),
                            ),
                          ),
                        ],
                      ),
                    );
                    if (accepted != true) return;
                    try {
                      await FirebaseService(provider.config)
                          .sendGatewayCommand('clear_history', {});
                      await provider.refreshHistory();
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                              'History cleared; setup credentials preserved.',
                            ),
                          ),
                        );
                      }
                    } catch (e) {
                      if (mounted) {
                        ScaffoldMessenger.of(context)
                            .showSnackBar(SnackBar(content: Text(FirebaseAuthSession.message(e))));
                      }
                    }
                  },
            label: const Text(
              'Delete Recorded History Only',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
        ),
        const SizedBox(height: 10),
        const ResetActions(),
        const SizedBox(height: 24),
        _buildWeatherCard(),
        const SizedBox(height: 18),
        _buildSecurityCard(provider),
      ],
    );
  }

  Widget _buildWeatherCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: SolarTheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: SolarTheme.border),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: SolarTheme.infoCyan.withOpacity(0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(
              Icons.wb_cloudy_rounded,
              color: SolarTheme.infoCyan,
              size: 22,
            ),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Show Weather',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: SolarTheme.textPrimary,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  'Current weather on the home screen. Uses the phone\'s approximate location (about 1 km), sent only to Open-Meteo, never to Firebase or the gateway.',
                  style: TextStyle(
                    fontSize: 11,
                    color: SolarTheme.textMuted,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
          Switch(
            value: _weatherEnabled,
            activeColor: SolarTheme.solarAmber,
            onChanged: (val) async {
              if (_weatherSaving) return;
              final messenger = ScaffoldMessenger.of(context);
              // The switch moves at once; it goes back if permission is refused.
              setState(() {
                _weatherSaving = true;
                _weatherEnabled = val;
              });
              bool on = false;
              try {
                on = val && await WeatherService.requestPermission();
                await WeatherService.setEnabled(on);
              } finally {
                if (mounted) {
                  setState(() {
                    _weatherSaving = false;
                    _weatherEnabled = WeatherService.enabled.value == true;
                  });
                }
              }
              if (!mounted) return;
              if (val && !on) {
                messenger.showSnackBar(
                  const SnackBar(
                    content: Text(
                      'Location permission was not given, so weather stays off. Allow approximate location for this app in Android settings.',
                    ),
                  ),
                );
              }
            },
          ),
        ],
      ),
    );
  }

  Widget _buildSecurityCard(SolarProvider provider) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: SolarTheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: SolarTheme.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: SolarTheme.solarAmber.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(
                  Icons.fingerprint_rounded,
                  color: SolarTheme.solarAmber,
                  size: 22,
                ),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Security & Touch Unlock',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: SolarTheme.textPrimary,
                      ),
                    ),
                    Text(
                      'Touch Unlock and Persistent Sign-In',
                      style: TextStyle(
                        fontSize: 11,
                        color: SolarTheme.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: SolarTheme.surfaceLight,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: SolarTheme.border),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Keep Logged In & Touch Unlock',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: SolarTheme.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'When on, Settings will not ask for the password every time; one touch or a fingerprint unlocks it. The session ends only on manual logout or after an app update.',
                        style: TextStyle(
                          fontSize: 11,
                          color: SolarTheme.textMuted,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ),
                ),
                Switch(
                  value: _touchUnlockEnabled,
                  activeColor: SolarTheme.solarAmber,
                  onChanged: (val) async {
                    setState(() => _touchUnlockEnabled = val);
                    await StorageService.setTouchUnlockEnabled(val);
                    final cfg = provider.config;
                    cfg.touchUnlockEnabled = val;
                    provider.updateConfig(cfg);
                    if (val) {
                      await StorageService.setSessionUnlocked(true);
                    }
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            val
                                ? 'Kept logged in: Settings stay open, even after the app restarts, until Manual Logout.'
                                : 'Not kept logged in: Settings ask again after the app restarts.',
                          ),
                        ),
                      );
                    }
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF334155), // Slate Gray
                foregroundColor: const Color(0xFFF87171),
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                  side: const BorderSide(color: Color(0xFF475569)),
                ),
                elevation: 0,
              ),
              icon: const Icon(
                Icons.logout_rounded,
                size: 18,
                color: Color(0xFFF87171),
              ),
              label: const Text(
                'Manual Logout (Close and Lock the Session)',
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold),
              ),
              onPressed: () async {
                final messenger = ScaffoldMessenger.of(context);
                await StorageService.setSessionUnlocked(false);
                if (!mounted) return;
                setState(() => _isUnlocked = false);
                messenger.showSnackBar(
                  const SnackBar(
                    content: Text('Settings session logged out successfully.'),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildUpdateTab(SolarProvider provider) {
    final fw = provider.esp32FirmwareVersion;
    final hasNewFw = provider.firmwareUpdateAvailable;
    final hasNewApp = provider.appUpdateAvailable;
    const appVersion = AppConfig.appVersion;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // 1. ESP32 Gateway Firmware Update Card
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: SolarTheme.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: SolarTheme.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: SolarTheme.infoCyan.withOpacity(0.15),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Icon(
                          Icons.memory_rounded,
                          color: SolarTheme.infoCyan,
                          size: 22,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'ESP32 Firmware Update',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                              color: SolarTheme.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Running Version: v$fw',
                            style: const TextStyle(
                              fontSize: 11.5,
                              color: SolarTheme.textMuted,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: hasNewFw
                          ? SolarTheme.solarAmber.withOpacity(0.15)
                          : SolarTheme.batteryGreen.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: hasNewFw
                            ? SolarTheme.solarAmber
                            : SolarTheme.batteryGreen,
                        width: 0.8,
                      ),
                    ),
                    child: Text(
                      hasNewFw ? 'Release Available' : 'Up to Date',
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.bold,
                        color: hasNewFw
                            ? SolarTheme.solarAmber
                            : SolarTheme.batteryGreen,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              const Text(
                'Wireless (OTA) firmware update for the ESP32 gateway: installs new firmware over the internet, no cable needed.',
                textAlign: TextAlign.justify,
                style: TextStyle(
                  fontSize: 11.5,
                  color: SolarTheme.textSecondary,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: SolarTheme.infoCyan,
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  icon: const Icon(Icons.cloud_sync_rounded, size: 18),
                  label: const Text(
                    'Check Firmware Update (Cloud OTA)',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                  ),
                  onPressed: () async {
                    await provider.checkUpdates();
                    if (mounted) {
                      await UpdateSheet.show(context, firmware: true);
                    }
                  },
                ),
              ),
            ],
          ),
        ),

        // 2. Mobile App Update Card (not in the Google Play build: Play
        // delivers app updates there).
        if (!AppConfig.playStoreBuild) ...[
        const SizedBox(height: 18),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: SolarTheme.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: SolarTheme.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: SolarTheme.solarAmber.withOpacity(0.15),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Icon(
                          Icons.phone_android_rounded,
                          color: SolarTheme.solarAmber,
                          size: 22,
                        ),
                      ),
                      const SizedBox(width: 12),
                      const Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Mobile App Update',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                              color: SolarTheme.textPrimary,
                            ),
                          ),
                          SizedBox(height: 2),
                          Text(
                            'Installed Version: $appVersion',
                            style: TextStyle(
                              fontSize: 11.5,
                              color: SolarTheme.textMuted,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: hasNewApp
                          ? SolarTheme.solarAmber.withOpacity(0.15)
                          : SolarTheme.batteryGreen.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: hasNewApp
                            ? SolarTheme.solarAmber
                            : SolarTheme.batteryGreen,
                        width: 0.8,
                      ),
                    ),
                    child: Text(
                      hasNewApp ? 'Release Available' : 'Up to Date',
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.bold,
                        color: hasNewApp
                            ? SolarTheme.solarAmber
                            : SolarTheme.batteryGreen,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              const Text(
                'Check for a new version of the NoxBrain app.',
                textAlign: TextAlign.justify,
                style: TextStyle(
                  fontSize: 11.5,
                  color: SolarTheme.textSecondary,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: SolarTheme.solarAmber,
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  icon: const Icon(Icons.system_update_rounded, size: 18),
                  label: const Text(
                    'Check Mobile App Update',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                  ),
                  onPressed: () async {
                    await provider.checkUpdates();
                    if (mounted) {
                      await UpdateSheet.show(context, firmware: false);
                    }
                  },
                ),
              ),
            ],
          ),
        ),
        ],
      ],
    );
  }

  // ---------------------------------------------------------------------
  // Controller Parameter tab: SRNE "Parameter set" options. Every value shown
  // is the controller's own readback; every save goes through Firebase to
  // the gateway, which validates, writes and confirms by reading back.

  static const Map<String, String> _batteryTypeLabels = {
    'USER': 'User Defined',
    'OPEN': 'Open Lead Acid FLD',
    'SEALED': 'Sealed Lead Acid SLD/AGM',
    'GEL': 'Colloidal Lead Acid GEL',
    'LITHIUM': 'Lithium Iron Phosphate LI',
  };
  static const Map<String, String> _systemVoltageLabels = {
    '12': '12V',
    '24': '24V',
    'auto': 'Automatic Recognition',
  };
  static const Map<String, String> _paramLabels = {
    'over_voltage_v': 'Overvoltage (V)',
    'charge_limit_v': 'Charge Limit Voltage (V)',
    'equalization_v': 'Equalization Charge Voltage (V)',
    'boost_absorption_v': 'Absorption Voltage (V)',
    'float_v': 'Float Charge Voltage (V)',
    'boost_return_v': 'Recharge Voltage (V)',
    'over_discharge_recovery_v': 'Overdischarge Return Voltage (V)',
    'low_voltage_warning_v': 'Under Voltage Warning Voltage (V)',
    'discharge_cutoff_v': 'Overdischarge Voltage (V)',
    'discharge_limit_v': 'Discharge Cut-Off Voltage (V)',
    'charge_end_soc_pct': 'Charge End SOC (%)',
    'discharge_end_soc_pct': 'Discharge End SOC (%)',
    'over_discharge_delay_s': 'Delay Time for Over Discharge (s)',
    'equalization_time_min': 'Equalization Charge Time (min)',
    'boost_time_min': 'Max Absorption Time (min)',
    'equalization_interval_days': 'Equalization Charge Interval (days)',
    'temperature_compensation_mv': 'Temperature Compensation (mV/°C/2V)',
  };
  static const Map<String, String> _temperatureLabels = {
    'charge_temp_upper_c': 'Charging Upper Limit Temperature (°C)',
    'charge_temp_lower_c': 'Charging Lower Limit Temperature (°C)',
    'discharge_temp_upper_c': 'Discharge Upper Limit Temperature (°C)',
    'discharge_temp_lower_c': 'Discharge Lower Limit Temperature (°C)',
  };
  // 16 (Debugging mode) is deliberately not offered.
  static const List<int> _loadModes = [
    0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 17,
  ];

  static String _loadModeLabel(int mode) {
    if (mode == 0) return 'Light Control';
    if (mode >= 1 && mode <= 14) {
      return 'Light control, with a delay of $mode hour${mode == 1 ? '' : 's'}';
    }
    if (mode == 15) return 'Manual Mode';
    if (mode == 16) return 'Debugging Mode (Set in SRNE App)';
    if (mode == 17) return 'Normally Open Mode';
    return 'Unknown ($mode)';
  }

  String _show(dynamic value, {int decimals = -1}) {
    if (value is! num) return '—';
    return decimals < 0 ? value.toString() : value.toStringAsFixed(decimals);
  }

  String _showParam(String key, dynamic value) {
    if (key == 'temperature_compensation_mv') {
      return value is num ? (value == 0 ? '0' : '-$value') : '—';
    }
    return _show(value);
  }

  String _showTime(dynamic millis) {
    if (millis is! num || millis <= 0) return 'time unknown';
    final d = DateTime.fromMillisecondsSinceEpoch(millis.toInt()).toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  void _applyController(
    Map<String, dynamic> data, {
    DateTime? readAt,
    bool fromGateway = false,
  }) {
    setState(() {
      _ctrl = data;
      _ctrlReadAt = fromGateway ? null : (readAt ?? DateTime.now());
      _ctrlFromGateway = fromGateway;
      _batteryProfile =
          data['controller_battery_profile']?.toString() ?? 'UNKNOWN';
      _ctrlBatteryType = _batteryProfile;
      _sysVoltage = data['system_voltage_setting']?.toString() ?? '';
      for (final entry in _paramControllers.entries) {
        entry.value.text = data[entry.key]?.toString() ?? '';
      }
      _tempComp = ((data['temperature_compensation_mv'] as num?)?.toInt() ?? 0)
          .clamp(0, 5);
      _capacityCtrl.text = data['battery_capacity_ah']?.toString() ?? '';
      final amps = data['max_charge_current_a'];
      _chargeCurrentCtrl.text = amps is num ? amps.toStringAsFixed(2) : '';
      for (final entry in _temperatureCtrls.entries) {
        entry.value.text = data[entry.key]?.toString() ?? '';
      }
      _loadMode = (data['load_mode'] as num?)?.toInt();
      _lightDelayCtrl.text = data['light_control_delay_min']?.toString() ?? '';
      _lightVoltageCtrl.text = data['light_control_voltage_v']?.toString() ?? '';
    });
  }

  Future<void> _runController(
    SolarProvider provider,
    Future<Map<String, dynamic>> Function(FirebaseService cloud) job,
  ) async {
    if (_ctrlBusy) return;
    setState(() => _ctrlBusy = true);
    try {
      final data = await job(FirebaseService(provider.config));
      if (!mounted) return;
      final values = Map<String, dynamic>.from(data)..remove('_message');
      _applyController(values);
      StorageService.saveControllerReadback(provider.config.deviceId, values);
      _notify(
        data['_message']?.toString() ?? 'Confirmed by controller readback.',
      );
    } catch (e) {
      if (!mounted) return;
      // Even a failed command shows what the controller actually holds now,
      // so a switch or value never stays at a state that was not confirmed.
      final readback = e is GatewayCommandFailed
          ? e.data
          : provider.controllerReadback;
      if (readback != null) {
        _applyController(readback, fromGateway: e is! GatewayCommandFailed);
        if (e is GatewayCommandFailed) {
          StorageService.saveControllerReadback(
            provider.config.deviceId,
            readback,
          );
        }
      }
      _notify(FirebaseAuthSession.message(e), success: false);
    } finally {
      if (mounted) setState(() => _ctrlBusy = false);
    }
  }

  Future<void> _readControllerSettings(SolarProvider provider) =>
      _runController(provider, (cloud) => cloud.readControllerParameters());

  void _noChange() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('No change to save.')),
    );
  }

  void _invalid(String message) => _notify(message, success: false);

  /// Shows each change as "Now → New" and asks before anything is written.
  Future<bool> _confirmControllerChange(
    String title,
    List<List<String>> rows, {
    String? note,
  }) async {
    const head = TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.bold,
      color: SolarTheme.textMuted,
    );
    final accepted = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Expanded(flex: 3, child: Text('Parameter', style: head)),
                  Expanded(flex: 2, child: Text('Now', style: head)),
                  Expanded(flex: 2, child: Text('New', style: head)),
                ],
              ),
              const Divider(),
              for (final row in rows)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    children: [
                      Expanded(
                        flex: 3,
                        child: Text(row[0], style: const TextStyle(fontSize: 12)),
                      ),
                      Expanded(
                        flex: 2,
                        child: Text(row[1], style: const TextStyle(fontSize: 12)),
                      ),
                      Expanded(
                        flex: 2,
                        child: Text(
                          row[2],
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: row[1] == row[2]
                                ? SolarTheme.textSecondary
                                : SolarTheme.solarAmber,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              if (note != null) ...[
                const SizedBox(height: 10),
                Text(
                  note,
                  style: const TextStyle(
                    fontSize: 11,
                    color: SolarTheme.textMuted,
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Write to Controller'),
          ),
        ],
      ),
    );
    return accepted == true;
  }

  Widget _ctrlCard(String title, List<Widget> children, {String? subtitle}) {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
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
            title,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
              color: SolarTheme.textPrimary,
              letterSpacing: 0.2,
            ),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(
              subtitle,
              style: const TextStyle(
                fontSize: 11.5,
                color: SolarTheme.textMuted,
                height: 1.4,
              ),
            ),
          ],
          const SizedBox(height: 12),
          ...children,
        ],
      ),
    );
  }

  Widget _ctrlSaveButton(
    String label,
    VoidCallback onPressed, {
    required bool dirty,
  }) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        style: ElevatedButton.styleFrom(
          backgroundColor: SolarTheme.solarAmber,
          foregroundColor: Colors.black,
          padding: const EdgeInsets.symmetric(vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
        icon: const Icon(Icons.save_rounded, size: 18),
        label: Text(
          label,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
        ),
        onPressed: _ctrlBusy || _ctrl.isEmpty || !dirty ? null : onPressed,
      ),
    );
  }

  Future<T?> _showSelectionSheet<T>({
    required String title,
    required T? currentValue,
    required List<DropdownMenuItem<T>> items,
  }) {
    return showModalBottomSheet<T>(
      context: context,
      backgroundColor: SolarTheme.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        side: BorderSide(color: SolarTheme.border),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: SolarTheme.textMuted.withOpacity(0.4),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: SolarTheme.textPrimary,
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: items.map((item) {
                      final selected = item.value == currentValue;
                      return ListTile(
                        enabled: item.enabled,
                        leading: Icon(
                          selected
                              ? Icons.radio_button_checked_rounded
                              : Icons.radio_button_off_rounded,
                          color: selected
                              ? SolarTheme.solarAmber
                              : SolarTheme.textMuted,
                          size: 20,
                        ),
                        title: item.child,
                        onTap: item.enabled
                            ? () => Navigator.pop(ctx, item.value)
                            : null,
                      );
                    }).toList(),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _ctrlDropdown<T>({
    required String label,
    required T? value,
    required List<DropdownMenuItem<T>> items,
    ValueChanged<T?>? onChanged,
  }) {
    final selectedItem = items.cast<DropdownMenuItem<T>?>().firstWhere(
      (it) => it?.value == value,
      orElse: () => null,
    );
    final isEnabled = _ctrl.isNotEmpty && onChanged != null;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              color: SolarTheme.textMuted,
            ),
          ),
          const SizedBox(height: 6),
          InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: isEnabled
                ? () async {
                    final picked = await _showSelectionSheet<T>(
                      title: label,
                      currentValue: value,
                      items: items,
                    );
                    if (picked != null) {
                      onChanged(picked);
                    }
                  }
                : null,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: SolarTheme.surfaceLight,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: selectedItem != null
                        ? selectedItem.child
                        : const Text(
                            'Read parameters first',
                            style: TextStyle(
                              color: SolarTheme.textMuted,
                              fontSize: 13,
                            ),
                          ),
                  ),
                  const Icon(
                    Icons.keyboard_arrow_down_rounded,
                    color: SolarTheme.textMuted,
                    size: 20,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  DropdownMenuItem<T> _ctrlItem<T>(T value, String text, {bool enabled = true}) {
    return DropdownMenuItem<T>(
      value: value,
      enabled: enabled,
      child: Text(
        text,
        style: TextStyle(
          color: enabled ? SolarTheme.textPrimary : SolarTheme.textMuted,
        ),
      ),
    );
  }

  Widget _ctrlField(
    TextEditingController controller,
    String label, {
    String hint = 'Value',
    IconData icon = Icons.tune_rounded,
    bool readOnly = false,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: _buildTextField(
        controller: controller,
        label: label,
        hint: hint,
        icon: icon,
        isNumber: true,
        readOnly: readOnly || _ctrl.isEmpty,
      ),
    );
  }

  Future<void> _saveBatteryBasics(SolarProvider provider) async {
    final changes = <String, dynamic>{};
    final rows = <List<String>>[];
    final oldVoltage = _ctrl['system_voltage_setting']?.toString() ?? '';
    if (_sysVoltage.isNotEmpty && _sysVoltage != oldVoltage) {
      changes['system_voltage'] = _sysVoltage;
      rows.add([
        'System Voltage',
        _systemVoltageLabels[oldVoltage] ?? oldVoltage,
        _systemVoltageLabels[_sysVoltage]!,
      ]);
    }
    if (_ctrlBatteryType.isNotEmpty && _ctrlBatteryType != _batteryProfile) {
      changes['battery_type'] = _ctrlBatteryType;
      rows.add([
        'Battery Profile',
        _batteryTypeLabels[_batteryProfile] ?? _batteryProfile,
        _batteryTypeLabels[_ctrlBatteryType]!,
      ]);
    }
    final capacityText = _capacityCtrl.text.trim();
    final oldCapacity = (_ctrl['battery_capacity_ah'] as num?)?.toInt();
    if (capacityText.isNotEmpty) {
      final capacity = int.tryParse(capacityText);
      if (capacity == null || capacity < 1 || capacity > 10000) {
        return _invalid('Battery capacity: whole number, 1-10000 Ah.');
      }
      if (capacity != oldCapacity) {
        changes['battery_capacity_ah'] = capacity;
        rows.add(['Battery Capacity (Ah)', _show(oldCapacity), '$capacity']);
      }
    }
    if (changes.isEmpty) return _noChange();
    final notes = <String>[
      if (changes.containsKey('system_voltage'))
        'Select the voltage of the battery bank actually connected. A wrong system voltage makes every charge and discharge limit wrong.',
      if (changes.containsKey('battery_type'))
        'A fixed type uses the controller\'s own built-in voltages. The current battery profile is saved as copy 1 first, so it can be restored.',
    ];
    if (!await _confirmControllerChange(
      'Change Battery Settings?',
      rows,
      note: notes.isEmpty ? null : notes.join('\n\n'),
    )) {
      return;
    }
    await _runController(
      provider,
      (cloud) => cloud.setControllerParameters(changes),
    );
  }

  Future<void> _saveChargeCurrent(SolarProvider provider) async {
    final rated = (_ctrl['rated_charge_current_a'] as num?)?.toDouble();
    final amps = double.tryParse(_chargeCurrentCtrl.text.trim());
    if (rated == null) {
      return _invalid('Select the controller model in Connectivity first.');
    }
    if (amps == null || amps < 1 || amps > rated) {
      return _invalid('Max charge current: 1-${_show(rated)} A.');
    }
    final old = (_ctrl['max_charge_current_a'] as num?)?.toDouble();
    if (old != null && (old - amps).abs() < 0.005) return _noChange();
    if (!await _confirmControllerChange(
      'Change Max Charge Current?',
      [
        ['Max Charge Current (A)', _show(old, decimals: 2), amps.toStringAsFixed(2)],
      ],
      note: 'The current value is saved as copy 1 first, so it can be restored.',
    )) {
      return;
    }
    await _runController(
      provider,
      (cloud) => cloud.setControllerParameters({
        'max_charge_current_a': double.parse(amps.toStringAsFixed(2)),
      }),
    );
  }

  Future<void> _setChargeDischargeSwitch(
    SolarProvider provider,
    bool on,
  ) async {
    if (!await _confirmControllerChange(
      on
          ? 'Turn Charge/Discharge ON?'
          : 'Turn Charge/Discharge OFF?',
      [
        ['Charge/Discharge Switch', on ? 'OFF' : 'ON', on ? 'ON' : 'OFF'],
      ],
      note: on
          ? null
          : 'OFF stops the controller\'s load output (verified). It may also stop solar charging until it is turned ON again.',
    )) {
      return;
    }
    await _runController(
      provider,
      (cloud) => cloud.setControllerParameters({'charge_discharge_switch': on}),
    );
  }

  Future<void> _switchToUserProfile(SolarProvider provider) async {
    if (!await _confirmControllerChange(
      'Change Battery Profile to USER?',
      [
        [
          'Battery Profile',
          _batteryTypeLabels[_batteryProfile] ?? _batteryProfile,
          _batteryTypeLabels['USER']!,
        ],
      ],
      note:
          'USER lets this app edit every charge and discharge voltage. The current profile is saved as copy 1 first. After the change, check each parameter against your battery maker\'s specification before saving.',
    )) {
      return;
    }
    await _runController(
      provider,
      (cloud) => cloud.setControllerParameters({'battery_type': 'USER'}),
    );
  }

  Future<void> _saveUserBlock(SolarProvider provider) async {
    final params = <String, num>{};
    final rows = <List<String>>[];
    for (final entry in _paramControllers.entries) {
      final value = num.tryParse(entry.value.text.trim());
      if (value == null) {
        return _invalid('${_paramLabels[entry.key]}: enter a number.');
      }
      params[entry.key] = value;
      final old = _ctrl[entry.key];
      if (old is! num || old != value) {
        rows.add([_paramLabels[entry.key]!, _show(old), value.toString()]);
      }
    }
    params['temperature_compensation_mv'] = _tempComp;
    final oldComp = _ctrl['temperature_compensation_mv'];
    if (oldComp is! num || oldComp != _tempComp) {
      rows.add([
        _paramLabels['temperature_compensation_mv']!,
        _showParam('temperature_compensation_mv', oldComp),
        _showParam('temperature_compensation_mv', _tempComp),
      ]);
    }
    if (rows.isEmpty) return _noChange();
    if (!await _confirmControllerChange(
      'Write Battery Parameters?',
      rows,
      note:
          'The current USER profile is saved as copy 1 first. The gateway checks the voltage order and limits before writing.',
    )) {
      return;
    }
    await _runController(
      provider,
      (cloud) => cloud.setControllerUserBlock(params),
    );
  }

  Future<void> _saveTemperatureLimits(SolarProvider provider) async {
    final changes = <String, dynamic>{};
    final rows = <List<String>>[];
    for (final entry in _temperatureCtrls.entries) {
      final value = int.tryParse(entry.value.text.trim());
      if (value == null || value < -40 || value > 90) {
        return _invalid('${_temperatureLabels[entry.key]}: whole number, -40 to 90.');
      }
      final old = _ctrl[entry.key];
      if (old is! num || old != value) {
        changes[entry.key] = value;
        rows.add([_temperatureLabels[entry.key]!, _show(old), '$value']);
      }
    }
    if (changes.isEmpty) return _noChange();
    if (!await _confirmControllerChange('Change Temperature Limits?', rows)) {
      return;
    }
    await _runController(
      provider,
      (cloud) => cloud.setControllerParameters(changes),
    );
  }

  Future<void> _saveLoadSettings(SolarProvider provider) async {
    final changes = <String, dynamic>{};
    final rows = <List<String>>[];
    final oldMode = (_ctrl['load_mode'] as num?)?.toInt();
    if (_loadMode != null && _loadMode != oldMode) {
      changes['load_mode'] = _loadMode;
      rows.add([
        'Load Working Mode',
        oldMode == null ? '—' : _loadModeLabel(oldMode),
        _loadModeLabel(_loadMode!),
      ]);
    }
    final delay = int.tryParse(_lightDelayCtrl.text.trim());
    if (delay == null || delay < 0 || delay > 60) {
      return _invalid('Light controlled delay: whole number, 0-60 min.');
    }
    final oldDelay = _ctrl['light_control_delay_min'];
    if (oldDelay is! num || oldDelay != delay) {
      changes['light_control_delay_min'] = delay;
      rows.add(['Light Controlled Delay (min)', _show(oldDelay), '$delay']);
    }
    final volts = int.tryParse(_lightVoltageCtrl.text.trim());
    if (volts == null || volts < 1 || volts > 40) {
      return _invalid('Light controlled voltage: whole number, 1-40 V.');
    }
    final oldVolts = _ctrl['light_control_voltage_v'];
    if (oldVolts is! num || oldVolts != volts) {
      changes['light_control_voltage_v'] = volts;
      rows.add(['Light Controlled Voltage (V)', _show(oldVolts), '$volts']);
    }
    if (changes.isEmpty) return _noChange();
    if (!await _confirmControllerChange(
      'Change Load Settings?',
      rows,
      note: changes.containsKey('load_mode') && _loadMode != 15
          ? 'Load ON/OFF from this app works only in Manual mode.'
          : null,
    )) {
      return;
    }
    await _runController(
      provider,
      (cloud) => cloud.setControllerParameters(changes),
    );
  }

  Future<void> _restoreSnapshot(
    SolarProvider provider,
    int slot,
    Map snapshot,
  ) async {
    final savedType = snapshot['battery_profile']?.toString() ?? 'UNKNOWN';
    final rows = <List<String>>[
      [
        'Battery Profile',
        _batteryTypeLabels[_batteryProfile] ?? _batteryProfile,
        _batteryTypeLabels[savedType] ?? savedType,
      ],
      [
        'Max Charge Current (A)',
        _show(_ctrl['max_charge_current_a'], decimals: 2),
        _show(snapshot['max_charge_current_a'], decimals: 2),
      ],
    ];
    // A fixed type uses its built-in values; only a USER copy writes these.
    if (savedType == 'USER') {
      for (final key in _paramLabels.keys) {
        rows.add([
          _paramLabels[key]!,
          _showParam(key, _ctrl[key]),
          _showParam(key, snapshot[key]),
        ]);
      }
    }
    if (!await _confirmControllerChange(
      'Restore Saved Copy $slot?',
      rows,
      note:
          'The current profile is saved as copy 1 first, so this restore can be undone too.',
    )) {
      return;
    }
    await _runController(
      provider,
      (cloud) => cloud.restoreControllerProfile(slot),
    );
  }

  Widget _snapshotTile(SolarProvider provider, int slot, dynamic snapshot) {
    if (snapshot is! Map) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(
          'Saved copy $slot: none yet',
          style: const TextStyle(fontSize: 12, color: SolarTheme.textMuted),
        ),
      );
    }
    final type = snapshot['battery_profile']?.toString() ?? 'UNKNOWN';
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: SolarTheme.surfaceLight,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: SolarTheme.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Saved copy $slot${slot == 1 ? ' (newest)' : ''}',
            style: const TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: SolarTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            '${_showTime(snapshot['saved_at'])} · ${_batteryTypeLabels[type] ?? type} · ${_show(snapshot['max_charge_current_a'], decimals: 2)} A',
            style: const TextStyle(fontSize: 11, color: SolarTheme.textMuted),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF334155),
                foregroundColor: Colors.white,
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                  side: const BorderSide(color: Color(0xFF475569)),
                ),
              ),
              onPressed: _ctrlBusy || _ctrl.isEmpty
                  ? null
                  : () => _restoreSnapshot(provider, slot, snapshot),
              child: const Text('Restore This Copy'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildControllerTab(SolarProvider provider) {
    _prefillController(provider);
    final isUser = _batteryProfile == 'USER';
    final rated = _ctrl['rated_charge_current_a'];
    final switchKnown = _ctrl['charge_discharge_switch'] is bool;
    final switchSupported = _ctrl['charge_discharge_switch_supported'] != false;
    final snapshots = _ctrl['controller_profile_snapshots'];
    final currentMode = (_ctrl['load_mode'] as num?)?.toInt();
    final loadModeItems = <DropdownMenuItem<int>>[
      for (final mode in _loadModes) _ctrlItem(mode, _loadModeLabel(mode)),
      // Shown only when the controller is already in it; cannot be chosen.
      if (currentMode == 16) _ctrlItem(16, _loadModeLabel(16), enabled: false),
    ];
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        ElevatedButton.icon(
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF334155),
            foregroundColor: Colors.white,
            elevation: 0,
            padding: const EdgeInsets.symmetric(vertical: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
              side: const BorderSide(color: Color(0xFF475569)),
            ),
          ),
          onPressed: _ctrlBusy ? null : () => _readControllerSettings(provider),
          icon: _ctrlBusy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                )
              : const Icon(Icons.refresh_rounded, size: 18),
          label: Text(
            _ctrlBusy ? 'Working with the controller…' : 'Read Controller Parameters',
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 6, bottom: 14),
          child: Text(
            _ctrlFromGateway
                ? 'Values from the gateway\'s latest controller read (it re-reads about every 2 minutes). Each save is confirmed by reading the controller back.'
                : _ctrlReadAt == null
                ? 'Read the parameters first. Every value here comes from the controller itself.'
                : 'Last read ${_showTime(_ctrlReadAt!.millisecondsSinceEpoch)}. Each save is confirmed by reading the controller back.',
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 11,
              color: SolarTheme.textMuted,
              height: 1.4,
            ),
          ),
        ),
        _ctrlCard('Battery Settings', [
          _ctrlDropdown<String>(
            label: 'System Voltage',
            value: _systemVoltageLabels.containsKey(_sysVoltage) ? _sysVoltage : null,
            items: [
              for (final e in _systemVoltageLabels.entries) _ctrlItem(e.key, e.value),
            ],
            onChanged: (v) => setState(() => _sysVoltage = v ?? _sysVoltage),
          ),
          // The profile the controller is on right now (from the last read).
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Current Battery Profile',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.bold,
                    color: SolarTheme.textMuted,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  _ctrl.isEmpty
                      ? '—'
                      : (_batteryTypeLabels[_batteryProfile] ?? _batteryProfile),
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: SolarTheme.solarAmber,
                  ),
                ),
              ],
            ),
          ),
          _ctrlDropdown<String>(
            label: 'Battery Profile',
            value: _batteryTypeLabels.containsKey(_ctrlBatteryType) ? _ctrlBatteryType : null,
            items: [
              for (final e in _batteryTypeLabels.entries) _ctrlItem(e.key, e.value),
            ],
            onChanged: (v) => setState(() => _ctrlBatteryType = v ?? _ctrlBatteryType),
          ),
          _ctrlField(
            _capacityCtrl,
            'Battery Capacity (Ah)',
            icon: Icons.battery_std_rounded,
          ),
          _ctrlSaveButton(
            'Save Battery Settings',
            () => _saveBatteryBasics(provider),
            dirty: _batteryBasicsDirty,
          ),
        ]),
        _ctrlCard(
          'Max Charge Current',
          [
            _ctrlField(
              _chargeCurrentCtrl,
              'Max Charge Current (A)',
              hint: rated is num ? '1 – ${_show(rated)}' : 'Value',
              icon: Icons.bolt_rounded,
            ),
            _ctrlSaveButton(
              'Save Charge Current',
              () => _saveChargeCurrent(provider),
              dirty: _chargeCurrentDirty,
            ),
          ],
          subtitle: 'Works with every battery type. 1 A up to the controller\'s rated current${rated is num ? ' (${_show(rated)} A)' : ''}.',
        ),
        _ctrlCard('Charge/Discharge Switch', [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(
                  !switchSupported
                      ? 'This controller does not report this switch.'
                      : switchKnown
                          ? (_ctrl['charge_discharge_switch'] == true ? 'ON' : 'OFF')
                          : 'Read parameters first',
                  style: const TextStyle(fontSize: 12, color: SolarTheme.textSecondary),
                ),
              ),
              Switch(
                value: _ctrl['charge_discharge_switch'] == true,
                activeThumbColor: SolarTheme.batteryGreen,
                onChanged: _ctrlBusy || !switchKnown || !switchSupported
                    ? null
                    : (on) => _setChargeDischargeSwitch(provider, on),
              ),
            ],
          ),
        ]),
        _ctrlCard(
          'Battery Parameters',
          [
            if (_ctrl.isNotEmpty && !isUser && _batteryTypeLabels.containsKey(_batteryProfile))
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF334155),
                      foregroundColor: Colors.white,
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                        side: const BorderSide(color: Color(0xFF475569)),
                      ),
                    ),
                    onPressed: _ctrlBusy ? null : () => _switchToUserProfile(provider),
                    child: const Text(
                      'Change Battery Profile to USER',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
              ),
            // Shown on every profile, so the optimised profiles are found even
            // when the controller is still on a fixed type such as FLD.
            if (_ctrl.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(
                  children: [
                    _presetButton('LFP 4S', provider, isUser),
                    const SizedBox(width: 8),
                    _presetButton('Flooded', provider, isUser),
                  ],
                ),
              ),
            for (final entry in _paramControllers.entries)
              _ctrlField(entry.value, _paramLabels[entry.key]!, readOnly: !isUser),
            _ctrlDropdown<int>(
              label: _paramLabels['temperature_compensation_mv']!,
              value: _ctrl.isEmpty ? null : _tempComp,
              items: [
                for (var i = 0; i <= 5; i++) _ctrlItem(i, i == 0 ? '0' : '-$i'),
              ],
              onChanged: isUser ? (v) => setState(() => _tempComp = v ?? _tempComp) : null,
            ),
            if (isUser)
              _ctrlSaveButton(
                'Save Battery Parameters',
                () => _saveUserBlock(provider),
                dirty: _userBlockDirty,
              ),
          ],
          subtitle: isUser
              ? 'Battery type is User defined: these values can be changed. Voltages use the 12V scale.'
              : 'Can be changed only when the battery type is User defined. Shown read-only.',
        ),
        _ctrlCard('Temperature Limits', [
          for (final entry in _temperatureCtrls.entries)
            _ctrlField(
              entry.value,
              _temperatureLabels[entry.key]!,
              icon: Icons.thermostat_rounded,
            ),
          _ctrlSaveButton(
            'Save Temperature Limits',
            () => _saveTemperatureLimits(provider),
            dirty: _temperatureDirty,
          ),
        ]),
        _ctrlCard('Load Setting', [
          _ctrlDropdown<int>(
            label: 'Load Working Mode',
            value: loadModeItems.any((item) => item.value == _loadMode) ? _loadMode : null,
            items: loadModeItems,
            onChanged: (v) => setState(() => _loadMode = v ?? _loadMode),
          ),
          _ctrlField(
            _lightDelayCtrl,
            'Light Controlled Delay Time (min)',
            icon: Icons.timer_outlined,
          ),
          _ctrlField(
            _lightVoltageCtrl,
            'Light Controlled Voltage (V)',
            icon: Icons.wb_twilight_rounded,
          ),
          _ctrlSaveButton(
            'Save Load Settings',
            () => _saveLoadSettings(provider),
            dirty: _loadSettingsDirty,
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: SolarTheme.surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: SolarTheme.border),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Controller Load Output',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: SolarTheme.textPrimary,
                      ),
                    ),
                    Text(
                      'Turn controller DC load output ON or OFF.',
                      style: TextStyle(fontSize: 11, color: SolarTheme.textMuted),
                    ),
                  ],
                ),
                Switch(
                  value: provider.live.isLoadSwitchOn,
                  activeThumbColor: SolarTheme.loadPurple,
                  // App ON/OFF needs Manual mode (unknown until read).
                  onChanged: provider.live.controllerConnected &&
                          (_loadMode == null || _loadMode == 15)
                      ? (val) async {
                          final ok = await provider.setLoadSwitch(val);
                          if (!mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                ok
                                    ? 'Controller load state confirmed.'
                                    : provider.errorMessage ??
                                          'Controller command failed.',
                              ),
                            ),
                          );
                        }
                      : null,
                ),
              ],
            ),
          ),
          if (currentMode != null && currentMode != 15)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text(
                'Load ON/OFF works only in Manual mode.',
                style: TextStyle(fontSize: 11, color: SolarTheme.textMuted),
              ),
            ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF334155),
                foregroundColor: Colors.white,
                elevation: 0,
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                  side: const BorderSide(color: Color(0xFF475569)),
                ),
              ),
              onPressed: () async {
                final accepted = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text(
                      'Enable Manual DC Load Mode?',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: SolarTheme.textPrimary,
                      ),
                    ),
                    content: const Text(
                      'This changes the SRNE load mode to manual (E01D=15). Its automatic light/timer load schedule will stop controlling this output.',
                      textAlign: TextAlign.justify,
                      style: TextStyle(
                        fontSize: 13,
                        color: SolarTheme.textSecondary,
                        height: 1.45,
                      ),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('Cancel'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: const Text('Enable Manual Mode'),
                      ),
                    ],
                  ),
                );
                if (accepted != true) return;
                try {
                  await FirebaseService(provider.config)
                      .sendGatewayCommand('enable_manual_load', {});
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Manual mode verified.')),
                    );
                  }
                } catch (e) {
                  if (mounted) {
                    ScaffoldMessenger.of(context)
                        .showSnackBar(SnackBar(content: Text(FirebaseAuthSession.message(e))));
                  }
                }
              },
              child: const Text(
                'Enable Controller Manual Load Mode',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
              ),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF334155),
                foregroundColor: Colors.white,
                elevation: 0,
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                  side: const BorderSide(color: Color(0xFF475569)),
                ),
              ),
              onPressed: () async {
                final accepted = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text(
                      'Restore Previous Load Mode?',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: SolarTheme.textPrimary,
                      ),
                    ),
                    content: const Text(
                      'The gateway writes back the SRNE load mode saved before manual mode was enabled (e.g. normal-on or light/timer). App ON/OFF stops working until manual mode is enabled again.',
                      textAlign: TextAlign.justify,
                      style: TextStyle(
                        fontSize: 13,
                        color: SolarTheme.textSecondary,
                        height: 1.45,
                      ),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('Cancel'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: const Text('Restore'),
                      ),
                    ],
                  ),
                );
                if (accepted != true) return;
                try {
                  await FirebaseService(provider.config)
                      .sendGatewayCommand('restore_load_mode', {});
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Previous load mode restored.')),
                    );
                  }
                } catch (e) {
                  if (mounted) {
                    ScaffoldMessenger.of(context)
                        .showSnackBar(SnackBar(content: Text(FirebaseAuthSession.message(e))));
                  }
                }
              },
              child: const Text(
                'Restore Previous Load Mode',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
              ),
            ),
          ),
        ]),
        _ctrlCard(
          'Restore Previous Settings',
          [
            _snapshotTile(provider, 1, snapshots is Map ? snapshots['slot1'] : null),
            _snapshotTile(provider, 2, snapshots is Map ? snapshots['slot2'] : null),
          ],
          subtitle:
              'The last 2 battery profiles (battery type, USER parameters, max charge current) are saved automatically before every change.',
        ),
      ],
    );
  }

  Widget _buildSmartSwitchTab(SolarProvider provider) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // Coming Soon: shown greyed out, cannot be used and saves nothing.
        const Padding(
          padding: EdgeInsets.only(bottom: 8),
          child: Text(
            'Smart Switch Relay Automation · Coming Soon',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: SolarTheme.textMuted,
              letterSpacing: 0.2,
            ),
          ),
        ),
        IgnorePointer(
          child: Opacity(
            opacity: 0.4,
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: SolarTheme.surface,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: SolarTheme.border),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Smart Switch Relay Automation',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                                color: SolarTheme.textPrimary,
                              ),
                            ),
                            SizedBox(height: 2),
                            Text(
                              'Relay on/off by battery SOC (automatic)',
                              style: TextStyle(
                                fontSize: 11,
                                color: SolarTheme.textMuted,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Switch(
                        value: _smartSwitchEnabled,
                        activeThumbColor: SolarTheme.solarAmber,
                        onChanged: (val) async {
                          try {
                            await provider.setSmartSwitchEnabled(val);
                            if (mounted) {
                              setState(() => _smartSwitchEnabled = val);
                            }
                          } catch (e) {
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text(FirebaseAuthSession.message(e))),
                              );
                            }
                          }
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: SolarTheme.surfaceLight,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: SolarTheme.border),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.power_settings_new_rounded,
                              size: 20,
                              color: provider.smartSwitchRelayState
                                  ? SolarTheme.batteryGreen
                                  : SolarTheme.textMuted,
                            ),
                            const SizedBox(width: 10),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Manual Relay Switch (${_smartSwitchChannel.replaceAll('_', ' ').toUpperCase()})',
                                  style: const TextStyle(
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w600,
                                    color: SolarTheme.textPrimary,
                                  ),
                                ),
                                Text(
                                  'Physical relay status not verified',
                                  style: TextStyle(
                                    fontSize: 10.5,
                                    color: provider.smartSwitchRelayState
                                        ? SolarTheme.batteryGreen
                                        : SolarTheme.textMuted,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                        Switch(
                          value: provider.smartSwitchRelayState,
                          activeThumbColor: SolarTheme.batteryGreen,
                          onChanged: null, // External Tuya manual control is not part of SRNE DC load control.
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'The switch changes only after crossing a threshold. Between the two values it keeps its previous state.',
                    textAlign: TextAlign.justify,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: SolarTheme.textMuted,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 12),
                  InkWell(
                    onTap: () async {
                      final items = [
                        _ctrlItem('switch_1', 'Switch 1 (Channel 1)'),
                        _ctrlItem('switch_2', 'Switch 2 (Channel 2)'),
                        _ctrlItem('switch_3', 'Switch 3 (Channel 3)'),
                        _ctrlItem('switch_4', 'Switch 4 (Channel 4)'),
                      ];
                      final picked = await _showSelectionSheet<String>(
                        title: 'Select Smart Switch Channel',
                        items: items,
                        currentValue: _smartSwitchChannel,
                      );
                      if (picked != null) {
                        setState(() {
                          _edited = true; // Read-only field: no listener here.
                          _smartSwitchChannel = picked;
                        });
                      }
                    },
                    borderRadius: BorderRadius.circular(10),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      decoration: BoxDecoration(
                        color: SolarTheme.surfaceLight,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: SolarTheme.border),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              _smartSwitchChannel == 'switch_1'
                                  ? 'Switch 1 (Channel 1)'
                                  : _smartSwitchChannel == 'switch_2'
                                      ? 'Switch 2 (Channel 2)'
                                      : _smartSwitchChannel == 'switch_3'
                                          ? 'Switch 3 (Channel 3)'
                                          : 'Switch 4 (Channel 4)',
                              style: const TextStyle(
                                fontSize: 13.5,
                                fontWeight: FontWeight.w600,
                                color: SolarTheme.textPrimary,
                              ),
                            ),
                          ),
                          const Icon(
                            Icons.keyboard_arrow_down_rounded,
                            color: SolarTheme.textMuted,
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: _buildTextField(
                          controller: _smartSwitchOnSoc,
                          label: 'Upper Threshold ON SOC (%)',
                          hint: '99',
                          icon: Icons.battery_charging_full,
                          isNumber: true,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _buildTextField(
                          controller: _smartSwitchOffSoc,
                          label: 'Lower Threshold OFF SOC (%)',
                          hint: '50',
                          icon: Icons.battery_alert,
                          isNumber: true,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildFirebaseTab(SolarProvider provider) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: SolarTheme.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: SolarTheme.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Your Own Firebase',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: SolarTheme.textPrimary,
                  letterSpacing: 0.2,
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                'There is no shared/default NoxBrain database. If you change the Firebase account or project, the gateway must also be sent the verified configuration.',
                textAlign: TextAlign.justify,
                style: TextStyle(
                  fontSize: 12,
                  color: SolarTheme.textSecondary,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 14),
              const ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                enabled: false,
                leading: Icon(Icons.cloud_outlined),
                title: Text(
                  'Default Cloud (NoxBrain Server)',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: SolarTheme.textMuted,
                  ),
                ),
                subtitle: Text(
                  'Coming Soon',
                  style: TextStyle(fontSize: 11, color: SolarTheme.textMuted),
                ),
              ),
              const Divider(color: SolarTheme.border, height: 16),
              const ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.radio_button_checked),
                title: Text(
                  'Your Own Firebase',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: SolarTheme.textPrimary,
                  ),
                ),
                subtitle: Text(
                  'In use',
                  style: TextStyle(
                    fontSize: 11,
                    color: SolarTheme.batteryGreen,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const Divider(color: SolarTheme.border, height: 16),
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.link_rounded, color: SolarTheme.solarAmber),
                title: Text(
                  provider.config.firebaseDatabaseUrl.isEmpty
                      ? 'Not connected yet'
                      : provider.config.firebaseDatabaseUrl,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: SolarTheme.textPrimary,
                  ),
                ),
                subtitle: Text(
                  provider.config.firebaseEmail.isEmpty
                      ? 'No account email configured'
                      : provider.config.firebaseEmail,
                  style: const TextStyle(fontSize: 11, color: SolarTheme.textMuted),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: SolarTheme.solarAmber,
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => const WelcomeSetupScreen(isFromSettings: true),
              ),
            ),
            child: const Text(
              'Open Firebase & Gateway Setup',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
            ),
          ),
        ),
        const SizedBox(height: 10),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF334155),
              foregroundColor: Colors.white,
              elevation: 0,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
                side: const BorderSide(color: Color(0xFF475569)),
              ),
            ),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const FirebaseChangeScreen()),
            ),
            child: const Text(
              'Change Firebase Remotely (Gateway Online)',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSaveButton(SolarProvider provider) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        style: ElevatedButton.styleFrom(
          backgroundColor: SolarTheme.solarAmber,
          foregroundColor: Colors.black,
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        icon: _saving
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.save_rounded, size: 20),
        label: Text(
          _saving ? 'Saving…' : 'Save Settings',
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
        ),
        onPressed: _saving || (!_edited && !_settingsDirty(provider.config))
            ? null
            : () => _saveSettings(provider),
      ),
    );
  }

  Widget _buildLoginGate() {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings Lock')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: SolarTheme.surface,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: SolarTheme.border),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircleAvatar(
                  radius: 32,
                  backgroundColor: SolarTheme.solarAmber.withOpacity(0.15),
                  child: const Icon(
                    Icons.admin_panel_settings_rounded,
                    color: SolarTheme.solarAmber,
                    size: 36,
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Settings Authentication',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                    color: SolarTheme.textPrimary,
                    letterSpacing: 0.3,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  _touchUnlockEnabled
                      ? 'Use Touch Unlock or enter credentials below'
                      : 'Enter username and password to access settings',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 12,
                    color: SolarTheme.textSecondary,
                    height: 1.4,
                  ),
                ),
                if (_touchUnlockEnabled) ...[
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: SolarTheme.solarAmber,
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      icon: _isAuthenticatingTouch
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.black,
                              ),
                            )
                          : const Icon(Icons.fingerprint_rounded, size: 22),
                      label: Text(
                        _isAuthenticatingTouch
                            ? 'Authenticating...'
                            : 'Touch to Unlock',
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      onPressed: _isAuthenticatingTouch
                          ? null
                          : _handleTouchUnlock,
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Row(
                    children: [
                      Expanded(child: Divider(color: SolarTheme.border)),
                      Padding(
                        padding: EdgeInsets.symmetric(horizontal: 10),
                        child: Text(
                          'OR USE PASSWORD',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: SolarTheme.textMuted,
                          ),
                        ),
                      ),
                      Expanded(child: Divider(color: SolarTheme.border)),
                    ],
                  ),
                ],
                const SizedBox(height: 16),
                TextField(
                  controller: _authUserController,
                  style: const TextStyle(
                    fontSize: 14,
                    color: SolarTheme.textPrimary,
                  ),
                  decoration: InputDecoration(
                    labelText: 'Username',
                    labelStyle: const TextStyle(
                      fontWeight: FontWeight.bold,
                      color: SolarTheme.textMuted,
                    ),
                    floatingLabelStyle: const TextStyle(
                      fontWeight: FontWeight.bold,
                      color: SolarTheme.textMuted,
                    ),
                    prefixIcon: const Icon(
                      Icons.person_outline,
                      color: SolarTheme.solarAmber,
                      size: 20,
                    ),
                    filled: true,
                    fillColor: SolarTheme.surfaceLight,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _authPassController,
                  obscureText: _obscurePass,
                  style: const TextStyle(
                    fontSize: 14,
                    color: SolarTheme.textPrimary,
                  ),
                  decoration: InputDecoration(
                    labelText: 'Password',
                    labelStyle: const TextStyle(
                      fontWeight: FontWeight.bold,
                      color: SolarTheme.textMuted,
                    ),
                    floatingLabelStyle: const TextStyle(
                      fontWeight: FontWeight.bold,
                      color: SolarTheme.textMuted,
                    ),
                    prefixIcon: const Icon(
                      Icons.lock_outline,
                      color: SolarTheme.solarAmber,
                      size: 20,
                    ),
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscurePass ? Icons.visibility_off : Icons.visibility,
                        color: SolarTheme.textMuted,
                        size: 20,
                      ),
                      onPressed: () =>
                          setState(() => _obscurePass = !_obscurePass),
                    ),
                    filled: true,
                    fillColor: SolarTheme.surfaceLight,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                  ),
                  onSubmitted: (_) => _verifyCredentials(),
                ),
                if (_authError != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _authError!,
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: SolarTheme.batteryDischarging,
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _touchUnlockEnabled
                          ? SolarTheme.surfaceLight
                          : SolarTheme.solarAmber,
                      foregroundColor: _touchUnlockEnabled
                          ? SolarTheme.textPrimary
                          : Colors.black,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    icon: const Icon(Icons.lock_open_rounded, size: 20),
                    label: Text(
                      _touchUnlockEnabled
                          ? 'Unlock with Password'
                          : 'Unlock Settings',
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    onPressed: _verifyCredentials,
                  ),
                ),
                if (context.read<SolarProvider>().config.firebaseEmail.isNotEmpty)
                  TextButton(
                    style: TextButton.styleFrom(
                      foregroundColor: SolarTheme.textSecondary,
                    ),
                    onPressed: _forgotPassword,
                    child: const Text('Forgot Password?'),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Forgotten Settings password: the owner's Firebase password (checked by
  /// Firebase, nothing stored) unlocks Settings to set a new login.
  Future<void> _forgotPassword() async {
    final config = context.read<SolarProvider>().config;
    final password = TextEditingController();
    final accepted = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Unlock With Firebase'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Enter the Firebase password of ${config.firebaseEmail}. Then set a new login in General → User Access Credentials.',
              style: const TextStyle(
                fontSize: 12.5,
                color: SolarTheme.textSecondary,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: password,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                labelText: 'Firebase Password',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Unlock'),
          ),
        ],
      ),
    );
    final entered = password.text;
    password.dispose();
    if (accepted != true || entered.isEmpty || !mounted) return;
    try {
      await FirebaseAuthSession.verifyOwnerPassword(config, entered);
      await StorageService.setSessionUnlocked(true);
      if (!mounted) return;
      setState(() {
        _isUnlocked = true;
        _authError = null;
      });
      _tabController.index = 0;
      _notify('Unlocked. Set a new login in User Access Credentials.');
    } catch (e) {
      if (mounted) {
        setState(() => _authError = FirebaseAuthSession.message(e));
      }
    }
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String label,
    required String hint,
    required IconData icon,
    bool isNumber = false,
    bool readOnly = false,
    VoidCallback? onTap,
    Widget? suffixIcon,
  }) {
    return TextField(
      controller: controller,
      readOnly: readOnly,
      onTap: onTap,
      keyboardType: isNumber ? TextInputType.number : TextInputType.text,
      style: const TextStyle(
        fontSize: 13.5,
        fontWeight: FontWeight.w600,
        color: SolarTheme.textPrimary,
      ),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        labelStyle: const TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.bold,
          color: SolarTheme.textMuted,
        ),
        floatingLabelStyle: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.bold,
          color: SolarTheme.textMuted,
        ),
        hintStyle: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.normal,
          color: SolarTheme.textMuted,
        ),
        prefixIcon: Icon(icon, color: SolarTheme.textMuted, size: 18),
        suffixIcon: suffixIcon,
        filled: true,
        fillColor: SolarTheme.surfaceLight,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 12,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }

  Future<void> _pickBatteryType() async {
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        backgroundColor: SolarTheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: SolarTheme.border),
        ),
        title: const Text(
          'Battery Type',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: SolarTheme.textPrimary,
          ),
        ),
        children: AppConfig.batteryTypes.entries
            .map(
              (e) => SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, e.key),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Text(
                    e.value,
                    style: const TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      color: SolarTheme.textPrimary,
                    ),
                  ),
                ),
              ),
            )
            .toList(),
      ),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _edited = true; // Read-only field: no controller listener arms Save.
      _batteryTypeKey = picked;
      _batteryTypeController.text = AppConfig.batteryTypes[picked]!;
    });
  }

  Widget _buildTimePickerField({
    required TextEditingController controller,
    required String label,
    required String hint,
    required IconData icon,
  }) {
    return _buildTextField(
      controller: controller,
      label: label,
      hint: hint,
      icon: icon,
      readOnly: true,
      onTap: () => _pickTime(controller),
      suffixIcon: IconButton(
        icon: const Icon(
          Icons.schedule_rounded,
          color: SolarTheme.textMuted,
          size: 20,
        ),
        tooltip: 'Select Time',
        onPressed: () => _pickTime(controller),
      ),
    );
  }

  Future<void> _pickTime(TextEditingController controller) async {
    TimeOfDay initialTime = const TimeOfDay(hour: 7, minute: 0);
    final text = controller.text.trim();
    final match = RegExp(r'^(\d{1,2}):(\d{2})(?:\s*([AaPp][Mm]))?')
        .firstMatch(text);
    if (match != null) {
      int hour = int.tryParse(match.group(1)!) ?? 7;
      final int minute = int.tryParse(match.group(2)!) ?? 0;
      final period = match.group(3)?.toUpperCase();
      if (period == 'PM' && hour < 12) hour += 12;
      if (period == 'AM' && hour == 12) hour = 0;
      initialTime = TimeOfDay(hour: hour % 24, minute: minute % 60);
    }

    final TimeOfDay? picked = await showTimePicker(
      context: context,
      initialTime: initialTime,
      initialEntryMode: TimePickerEntryMode.dial,
      builder: (BuildContext context, Widget? child) {
        return Theme(
          data: ThemeData.dark().copyWith(
            colorScheme: const ColorScheme.dark(
              primary: SolarTheme.solarAmber,
              onPrimary: Colors.black,
              surface: Color(0xFF1E293B),
              onSurface: Colors.white,
              secondary: SolarTheme.solarAmber,
            ),
            timePickerTheme: TimePickerThemeData(
              backgroundColor: const Color(0xFF1E293B),
              hourMinuteColor: const Color(0xFF0F172A),
              hourMinuteTextColor: Colors.white,
              dialHandColor: SolarTheme.solarAmber,
              dialBackgroundColor: const Color(0xFF0F172A),
              dialTextColor: Colors.white,
              entryModeIconColor: SolarTheme.solarAmber,
              dayPeriodBorderSide: const BorderSide(color: Color(0xFF334155)),
              dayPeriodColor: WidgetStateColor.resolveWith(
                (states) => states.contains(WidgetState.selected)
                    ? SolarTheme.solarAmber.withOpacity(0.25)
                    : const Color(0xFF0F172A),
              ),
              dayPeriodTextColor: WidgetStateColor.resolveWith(
                (states) => states.contains(WidgetState.selected)
                    ? SolarTheme.solarAmber
                    : const Color(0xFF94A3B8),
              ),
            ),
          ),
          child: MediaQuery(
            data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: false),
            child: child!,
          ),
        );
      },
    );

    if (picked != null) {
      final int hour12 = picked.hourOfPeriod == 0 ? 12 : picked.hourOfPeriod;
      final String minuteStr = picked.minute.toString().padLeft(2, '0');
      final String periodStr = picked.period == DayPeriod.am ? 'AM' : 'PM';
      setState(() {
        controller.text =
            '${hour12.toString().padLeft(2, '0')}:$minuteStr $periodStr';
      });
    }
  }
}
