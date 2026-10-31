import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../models/app_config.dart';
import '../../providers/solar_provider.dart';
import '../../services/firebase_service.dart';
import '../../services/firebase_auth_session.dart';
import '../../services/update_service.dart';
import 'welcome_setup_screen.dart';
import '../theme.dart';
import '../widgets/save_notice.dart';

class ConnectionManagerScreen extends StatelessWidget {
  const ConnectionManagerScreen({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Gateway and Device Connection')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF334155),
              foregroundColor: Colors.white,
              elevation: 0,
              padding: const EdgeInsets.symmetric(vertical: 13),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
                side: const BorderSide(color: Color(0xFF475569)),
              ),
            ),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => const WelcomeSetupScreen(isFromSettings: true),
              ),
            ),
            child: const Text(
              'Gateway / Wi-Fi / Firebase Setup',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
            ),
          ),
        ),
        const SizedBox(height: 14),
        const GatewayWifiPanel(),
        const SizedBox(height: 14),
        const GatewayDevicesPanel(),
      ],
    ),
  );
}

/// Gateway Wi-Fi through Firebase while the gateway is online.
/// Search: join a Wi-Fi that is live now (tested; reverts if it fails).
/// Manual: save a Wi-Fi in advance (e.g. before a router change); the gateway
/// joins it later when the current Wi-Fi is unavailable and this one is in range.
class GatewayWifiPanel extends StatefulWidget {
  const GatewayWifiPanel({super.key});
  @override
  State<GatewayWifiPanel> createState() => _GatewayWifiPanelState();
}

class _GatewayWifiPanelState extends State<GatewayWifiPanel> {
  final _password = TextEditingController(),
      _manualSsid = TextEditingController();
  List<Map<String, dynamic>> _networks = [];
  List<String> _saved = [];
  String _mode = '', _selected = '', _current = '', _message = '';
  // Green when the step worked, red when it did not. Without it every
  // outcome read the same grey, so a command the gateway never answered
  // looked no different from one that succeeded.
  Color? _messageColor;
  bool _busy = false;

  FirebaseService get _cloud =>
      FirebaseService(context.read<SolarProvider>().config);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  @override
  void dispose() {
    _password.dispose();
    _manualSsid.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final state = await _cloud.gatewayWifiState();
      if (mounted) {
        setState(() {
          _current = state.current;
          _saved = state.saved;
        });
      }
    } catch (_) {
      // Shown as unknown; the gateway may be offline.
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (e) {
      if (mounted) {
        setState(() {
          _message = FirebaseAuthSession.message(e);
          _messageColor = SolarTheme.batteryDischarging;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _scan() async {
    setState(() {
      _mode = 'search';
      _messageColor = null;
      _password.clear();
      _message = 'The ESP32 is scanning for nearby Wi-Fi…';
    });
    final rows = await _cloud.scanGatewayWifi();
    if (mounted) {
      setState(() {
        _networks = rows;
        _message = rows.isEmpty
            ? 'The ESP32 found no 2.4 GHz Wi-Fi.'
            : 'Select the new Wi-Fi and enter its password.';
      });
    }
  }

  void _manual() => setState(() {
    _mode = 'manual';
    _networks = [];
    _password.clear();
    _manualSsid.clear();
    _message = 'Save a Wi-Fi that is not on yet (for example the new name/password you will give your router). If the current Wi-Fi is unavailable, the ESP32 looks for this one and joins it by itself.';
  });

  Future<void> _change() async {
    if (_selected.isEmpty) throw Exception('Select a Wi-Fi.');
    setState(
      () => _message = 'The ESP32 is joining the new Wi-Fi and checking Firebase. This can take a minute or two…',
    );
    await _cloud.changeGatewayWifi(_selected, _password.text);
    if (mounted) {
      setState(() {
        _password.clear();
        _networks = [];
        _mode = '';
        _message = 'The ESP32 joined the new Wi-Fi and reached Firebase.';
        _messageColor = SolarTheme.batteryGreen;
      });
    }
    await _refresh();
  }

  Future<void> _save() async {
    final ssid = _manualSsid.text.trim();
    if (ssid.isEmpty) throw Exception('Enter the Wi-Fi name.');
    final pass = _password.text;
    if (pass.isNotEmpty && pass.length < 8) {
      throw Exception('The Wi-Fi password must have at least 8 characters.');
    }
    await _cloud.addGatewayWifi(ssid, pass);
    if (mounted) {
      setState(() {
        _password.clear();
        _manualSsid.clear();
        _mode = '';
        _message =
            '"$ssid" saved on the ESP32. If the current Wi-Fi is unavailable and this one is in range, the ESP32 joins it by itself.';
      });
    }
    await _refresh();
  }

  Future<void> _remove(String ssid) async {
    await _cloud.removeGatewayWifi(ssid);
    if (mounted) setState(() => _message = '"$ssid" removed.');
    await _refresh();
  }

  Widget _passwordField(String label) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: TextField(
      controller: _password,
      obscureText: true,
      autocorrect: false,
      enableSuggestions: false,
      style: const TextStyle(
        fontSize: 13.5,
        fontWeight: FontWeight.w600,
        color: SolarTheme.textPrimary,
      ),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.bold,
          color: SolarTheme.textMuted,
        ),
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
    ),
  );

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: SolarTheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: SolarTheme.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Gateway Wi-Fi',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: SolarTheme.textPrimary,
              letterSpacing: 0.2,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Current: ${_current.isEmpty ? 'unknown / offline' : _current}',
            style: const TextStyle(
              fontSize: 12,
              color: SolarTheme.textSecondary,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            children: [
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF334155),
                  foregroundColor: Colors.white,
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                    side: const BorderSide(color: Color(0xFF475569)),
                  ),
                ),
                onPressed: _busy ? null : () => _run(_scan),
                child: const Text('Search', style: TextStyle(fontWeight: FontWeight.w600)),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF334155),
                  foregroundColor: Colors.white,
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                    side: const BorderSide(color: Color(0xFF475569)),
                  ),
                ),
                onPressed: _busy ? null : _manual,
                child: const Text('Manual', style: TextStyle(fontWeight: FontWeight.w600)),
              ),
            ],
          ),
          if (_mode == 'search') ...[
            const SizedBox(height: 8),
            ..._networks.map(
              (n) => RadioListTile<String>(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(
                  n['current'] == true
                      ? '${n['ssid']} (current)'
                      : n['ssid'].toString(),
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: SolarTheme.textPrimary,
                  ),
                ),
                subtitle: Text(
                  '${n['rssi']} dBm',
                  style: const TextStyle(fontSize: 11, color: SolarTheme.textMuted),
                ),
                value: n['ssid'].toString(),
                groupValue: _selected,
                onChanged: _busy ? null : (v) => setState(() => _selected = v!),
              ),
            ),
            if (_networks.isNotEmpty) ...[
              _passwordField('New Wi-Fi Password'),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: SolarTheme.solarAmber,
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  onPressed: _busy ? null : () => _run(_change),
                  child: const Text(
                    'Switch to This Wi-Fi',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ),
            ],
          ],
          if (_mode == 'manual') ...[
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: TextField(
                controller: _manualSsid,
                autocorrect: false,
                style: const TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: SolarTheme.textPrimary,
                ),
                decoration: InputDecoration(
                  labelText: 'Wi-Fi Name (SSID)',
                  labelStyle: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.bold,
                    color: SolarTheme.textMuted,
                  ),
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
              ),
            ),
            _passwordField('Wi-Fi Password'),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: SolarTheme.solarAmber,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                onPressed: _busy ? null : () => _run(_save),
                child: const Text(
                  'Save on the ESP32',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ),
          ],
          if (_saved.isNotEmpty) ...[
            const Padding(
              padding: EdgeInsets.only(top: 12, bottom: 4),
              child: Text(
                'Saved Backup Wi-Fi',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: SolarTheme.textPrimary,
                ),
              ),
            ),
            ..._saved.map(
              (s) => ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(
                  s,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: SolarTheme.textPrimary,
                  ),
                ),
                trailing: TextButton(
                  onPressed: _busy ? null : () => _run(() => _remove(s)),
                  child: const Text('Remove'),
                ),
              ),
            ),
          ],
          if (_busy) const LinearProgressIndicator(),
          if (_message.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                _message,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  color: _messageColor ?? SolarTheme.textSecondary,
                  height: 1.4,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class GatewayDevicesPanel extends StatefulWidget {
  final ValueChanged<bool>? onReady;

  /// Setup wizard: send the battery mode chosen in step 1 to the gateway by
  /// itself, so Controller + BMS Mode shows the BMS part without extra taps.
  final bool applyChosenMode;
  const GatewayDevicesPanel({
    super.key,
    this.onReady,
    this.applyChosenMode = false,
  });
  @override
  State<GatewayDevicesPanel> createState() => _GatewayDevicesPanelState();
}

class _GatewayDevicesPanelState extends State<GatewayDevicesPanel> {
  List<Map<String, dynamic>> _results = [];
  String _target = 'controller', _message = '', _jkProfile = 'auto';
  String _controllerModel = '';
  // Bluetooth or RS485; the RS485 search result shows green/red.
  String _link = AppConfig.linkBle;
  Color? _messageColor;
  String _batteryMode = '', _batteryType = '';
  final _capacity = TextEditingController();
  // Controller's own battery setting (E004) -> suggested battery type.
  static const _profileTypes = {
    'OPEN': 'flooded',
    'SEALED': 'sealed',
    'GEL': 'gel',
    'LITHIUM': 'lithium',
  };
  @override
  void initState() {
    super.initState();
    final provider = context.read<SolarProvider>();
    final config = provider.config;
    _batteryMode = config.effectiveBatteryMode;
    _batteryType = AppConfig.batteryTypes.containsKey(config.batteryType)
        ? config.batteryType
        : _profileTypes[provider.live.controllerBatteryProfile] ?? '';
    if (config.batteryNominalCapacityAh > 0) {
      _capacity.text = config.batteryNominalCapacityAh.toStringAsFixed(0);
    }
    final saved = config.jkProfile;
    if (saved == 'auto' ||
        saved == 'jk02_24' ||
        saved == 'jk02_32' ||
        saved == 'jbd') {
      _jkProfile = saved;
    }
    if (config.hasSupportedControllerModel) {
      _controllerModel = config.controllerModel;
    }
    // Setup wizard: the step 2 choice. Settings > Connectivity: the link the
    // gateway actually uses once it reports one.
    final reportedLink = provider.live.gatewayControllerLink;
    _link = !widget.applyChosenMode &&
            AppConfig.controllerLinkLabels.containsKey(reportedLink)
        ? reportedLink
        : config.controllerLink;
    _capacity.addListener(_onEdited);
  }

  void _onEdited() {
    if (mounted) setState(() {});
  }

  /// "Save System Mode" is active only while the choice differs from the
  /// mode the gateway reports (and, in Only Controller Mode, the saved
  /// battery type and capacity).
  bool _modeDirty(SolarProvider provider) {
    final c = provider.config;
    final reported = provider.live.gatewayBatteryMode;
    if (_batteryMode != c.batteryMode ||
        (reported.isNotEmpty && _batteryMode != reported)) {
      return true;
    }
    if (_batteryMode != AppConfig.modeControllerOnly) return false;
    return _batteryType != c.batteryType ||
        double.tryParse(_capacity.text.trim()) != c.batteryNominalCapacityAh;
  }

  @override
  void dispose() {
    _capacity.dispose();
    super.dispose();
  }

  bool? _reportedReady;
  bool _busy = false, _modeApplied = false;
  // Ready when the controller sends data, the gateway reports the chosen
  // battery mode and, in Controller + BMS Mode, the BMS sends data too.
  bool _isReady(SolarProvider provider) {
    final c = provider.config;
    final live = provider.live;
    return c.hasSupportedControllerModel &&
        live.controllerConnected &&
        AppConfig.isBatteryMode(c.batteryMode) &&
        live.gatewayBatteryMode == c.batteryMode &&
        (c.isControllerOnlyMode || live.bmsConnected);
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (e) {
      // Every failure in this panel lands here. Until it set a colour, a
      // Disconnect the gateway never answered left the button unchanged
      // and its reason in the same grey as a success: nothing said so.
      if (mounted) {
        setState(() {
          _message = FirebaseAuthSession.message(e);
          _messageColor = SolarTheme.batteryDischarging;
        });
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        widget.onReady?.call(_isReady(context.read<SolarProvider>()));
      }
    }
  }

  /// RS485: the gateway searches the wire for the controller and confirms
  /// only after a valid reading. Success is shown green, an error red.
  Future<void> _searchRs485() async {
    if (!AppConfig.isSupportedControllerModel(_controllerModel)) {
      setState(() {
        _message = 'First select your Shiner controller model from the list.';
        _messageColor = SolarTheme.batteryDischarging;
      });
      return;
    }
    final provider = context.read<SolarProvider>();
    final config = provider.config;
    final model = _controllerModel;
    setState(() {
      _results = [];
      _messageColor = null;
      _message = 'The ESP32 is searching for the controller on RS485…';
    });
    try {
      await FirebaseService(config).sendGatewayCommand('select_device', {
        'target': 'controller',
        'link': AppConfig.linkRs485,
        'model': model,
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _message = FirebaseAuthSession.message(e);
          _messageColor = SolarTheme.batteryDischarging;
        });
      }
      return;
    }
    if (!mounted) return;
    config.controllerLink = AppConfig.linkRs485;
    config.controllerModel = model;
    config.isControllerEnabled = true;
    await provider.updateConfig(config);
    if (mounted) {
      setState(() {
        _message = 'Successfully connected';
        _messageColor = SolarTheme.batteryGreen;
      });
    }
  }

  Future<void> _scan(String target) async {
    if (target == 'controller' &&
        !AppConfig.isSupportedControllerModel(_controllerModel)) {
      throw Exception(
        'First select your Shiner controller model from the list.',
      );
    }
    _target = target;
    setState(() {
      _messageColor = null;
      _results = [];
      _message = 'The ESP32 is scanning for nearby Bluetooth devices…';
    });
    // The gateway scans; the phone only shows the result, from anywhere.
    final rows = await FirebaseService(context.read<SolarProvider>().config)
        .scanGatewayBluetooth();
    if (mounted) {
      setState(() {
        _results = rows;
        _message = rows.isEmpty
            ? 'The ESP32 found no device. Keep the device on and nearby, and close other apps connected to it.'
            : 'The ESP32 found these devices. Select one and the ESP32 will connect and check it.';
      });
    }
  }

  /// Asks for the controller module's Bluetooth PIN. Null when cancelled.
  /// The PIN goes to the gateway, which pairs with it; the app keeps nothing.
  Future<String?> _askPin({required bool wrong}) async {
    final field = TextEditingController();
    final pin = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Bluetooth PIN'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              wrong
                  ? "That PIN did not unlock the controller's Bluetooth module. Enter its current PIN."
                  : "This controller's Bluetooth module is locked. Enter its PIN to connect.",
            ),
            const SizedBox(height: 12),
            TextField(
              controller: field,
              autofocus: true,
              keyboardType: TextInputType.number,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(6),
              ],
              style: const TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
                color: SolarTheme.textPrimary,
              ),
              decoration: InputDecoration(
                labelText: 'PIN (up to 6 digits)',
                labelStyle: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.bold,
                  color: SolarTheme.textMuted,
                ),
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
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final value = field.text.trim();
              if (value.isNotEmpty) Navigator.pop(ctx, value);
            },
            child: const Text('Connect'),
          ),
        ],
      ),
    );
    field.dispose();
    return pin;
  }

  Future<void> _select(Map<String, dynamic> row) async {
    if (_target == 'bms') {
      // JBD is read only by gateway firmware 1.1.23 or newer.
      final fw = context.read<SolarProvider>().esp32FirmwareVersion;
      if (_jkProfile == 'jbd' &&
          (fw == 'unknown' || UpdateService.compareVersions(fw, '1.1.23') < 0)) {
        throw Exception(
          'JBD needs gateway firmware 1.1.23 or newer. Update the gateway firmware first.',
        );
      }
      if (!mounted) return;
      final jbd = _jkProfile == 'jbd';
      final accepted = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(jbd ? 'JBD Compatibility' : 'JK Protocol Compatibility'),
          content: Text(
            jbd
                ? 'The ESP32 reads a JBD / Xiaoxiang BMS (FF00 Bluetooth service) and never changes its settings. Success is shown only after a valid reading is received.'
                : 'With Auto-detect the ESP32 recognises the JK02 24S/32S frame layout by itself; if it cannot, choose the layout manually. A manual layout must match your model. 24S/32S here is the frame layout, not the pack\'s cell count. JK04 is not supported by this decoder. Success is shown only after a valid frame is received.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Check This Profile and Connect'),
            ),
          ],
        ),
      );
      if (accepted != true) return;
    }
    if (!mounted) return;
    final provider = context.read<SolarProvider>();
    final config = provider.config;
    final mac = row['mac']?.toString().toUpperCase() ?? '';
    final name = row['name']?.toString() ?? '';
    if (!RegExp(r'^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$').hasMatch(mac)) {
      throw Exception(
        'The device address from the ESP32 is invalid. Scan again.',
      );
    }
    final target = _target;
    final model = _controllerModel;
    if (target == 'controller' &&
        !AppConfig.isSupportedControllerModel(model)) {
      throw Exception(
        'First select your Shiner controller model from the list.',
      );
    }
    if (mounted) {
      setState(
        () => _message = 'The ESP32 is connecting and checking the first valid reading…',
      );
    }
    Future<void> send([String? pin]) =>
        FirebaseService(config).sendGatewayCommand('select_device', {
          'target': target,
          'mac': mac,
          if (target == 'controller') 'model': model,
          'pin': ?pin,
          if (target == 'bms') 'profile': _jkProfile,
        });
    try {
      await send();
    } on GatewayCommandFailed catch (e) {
      // The gateway says when the controller's Bluetooth module is locked
      // for want of its PIN, or refused the one given: only then ask for it.
      // Modules without a PIN never see this dialog.
      String? reason = e.data?['reason']?.toString();
      if (target != 'controller' ||
          (reason != 'pin_required' && reason != 'pin_wrong')) {
        rethrow;
      }
      while (true) {
        final pin = await _askPin(wrong: reason == 'pin_wrong');
        if (pin == null) {
          throw Exception(
            'Not connected: this controller needs its Bluetooth PIN.',
          );
        }
        if (mounted) {
          setState(
            () => _message = 'The ESP32 is pairing with the controller using the PIN…',
          );
        }
        try {
          await send(pin);
          break;
        } on GatewayCommandFailed catch (e2) {
          reason = e2.data?['reason']?.toString();
          if (reason != 'pin_required' && reason != 'pin_wrong') rethrow;
        }
      }
    }
    if (!mounted) return;
    if (target == 'controller') {
      config.controllerLink = AppConfig.linkBle;
      config.srneBleMac = mac;
      config.srneBleName = name;
      config.controllerModel = model;
      config.isControllerEnabled = true;
    } else {
      config.jkBmsBleMac = mac;
      config.jkBmsBleName = name;
      config.isBmsEnabled = true;
      config.jkProfile = _jkProfile;
    }
    await provider.updateConfig(config);
    if (mounted) {
      setState(
        () => _message = 'Connected to the ESP32 and valid data received.',
      );
    }
  }

  Future<void> _connection(bool controller, bool enabled) async {
    final provider = context.read<SolarProvider>();
    final c = provider.config;
    _messageColor = null;
    await FirebaseService(c).sendGatewayCommand('connection', {
      'controller_enabled': controller ? enabled : c.isControllerEnabled,
      'bms_enabled': controller ? c.isBmsEnabled : enabled,
    });
    if (controller) {
      c.isControllerEnabled = enabled;
    } else {
      c.isBmsEnabled = enabled;
    }
    await provider.updateConfig(c);
    if (mounted) {
      setState(() {
        _message = enabled
            ? 'Reconnect is on. It shows connected when new data arrives.'
            : controller && c.isRs485Controller
            ? 'RS485 connection turned off. No electrical output/MOS was changed.'
            : 'Bluetooth connection turned off. No electrical output/MOS was changed.';
        _messageColor = SolarTheme.batteryGreen;
      });
    }
  }

  /// Saves the battery mode (and, for Only Controller Mode, battery type and
  /// capacity) on the gateway; the app keeps it only after confirmation.
  Future<void> _saveMode() async {
    if (!AppConfig.isBatteryMode(_batteryMode)) {
      throw Exception('Select a system mode.');
    }
    final controllerOnly = _batteryMode == AppConfig.modeControllerOnly;
    final capacity = double.tryParse(_capacity.text.trim()) ?? 0;
    if (controllerOnly && !AppConfig.batteryTypes.containsKey(_batteryType)) {
      throw Exception('Select a battery type.');
    }
    if (controllerOnly && (capacity < 1 || capacity > 10000)) {
      throw Exception('Enter a battery capacity (Ah) between 1 and 10000.');
    }
    final provider = context.read<SolarProvider>();
    final next = AppConfig.fromJson(provider.config.toJson())
      ..batteryMode = _batteryMode;
    if (controllerOnly) {
      next
        ..batteryType = _batteryType
        ..batteryNominalCapacityAh = capacity
        ..isBmsEnabled = false;
    } else {
      next.isBmsEnabled = RegExp(
        r'^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$',
      ).hasMatch(next.jkBmsBleMac);
    }
    setState(() => _message = 'Saving the system mode on the gateway…');
    await FirebaseService(next).saveSystemOptions();
    await provider.updateConfig(next);
    if (mounted) {
      setState(
        () => _message = controllerOnly
            ? 'Only Controller Mode saved. The gateway will calculate the battery values from the controller data.'
            : 'Controller + BMS Mode saved. Now scan for the JK BMS and add it.',
      );
      showSaveNotice(
        context,
        controllerOnly
            ? 'Only Controller Mode saved on the gateway.'
            : 'Controller + BMS Mode saved on the gateway.',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<SolarProvider>();
    final c = provider.config;
    final live = provider.live;
    final controllerFresh = live.controllerConnected;
    final bmsFresh = live.bmsConnected;
    final ready = _isReady(provider);
    // The controller is on RS485 once the gateway reports that link.
    final rs485Active =
        c.isRs485Controller && live.gatewayControllerLink == AppConfig.linkRs485;
    // BMS selection follows the mode the gateway has actually saved.
    final bmsMode =
        (live.gatewayBatteryMode.isNotEmpty
            ? live.gatewayBatteryMode
            : c.effectiveBatteryMode) ==
        AppConfig.modeControllerBms;
    // A new gateway starts in Only Controller Mode; Controller + BMS Mode
    // needs no further details, so it is saved on the gateway right away.
    if (widget.applyChosenMode &&
        !_modeApplied &&
        live.gatewayBatteryMode.isNotEmpty &&
        c.batteryMode == AppConfig.modeControllerBms &&
        live.gatewayBatteryMode != c.batteryMode) {
      _modeApplied = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _run(_saveMode);
      });
    }
    if (ready != _reportedReady) {
      _reportedReady = ready;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onReady?.call(ready);
      });
    }
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: SolarTheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: SolarTheme.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'SRNE Shiner Series and JK Smart BMS',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: SolarTheme.textPrimary,
              letterSpacing: 0.2,
            ),
          ),
          const SizedBox(height: 12),
          _buildSelectField<String>(
            label: 'System Mode',
            hint: 'Select a mode',
            selectedValue: AppConfig.isBatteryMode(_batteryMode) ? _batteryMode : null,
            displayValue: AppConfig.batteryModeLabels[_batteryMode] ?? '',
            items: AppConfig.batteryModeLabels.entries
                .map((e) => _SelectionOption(e.key, e.value))
                .toList(),
            enabled: !_busy,
            onSelected: (v) => setState(() => _batteryMode = v),
          ),
          if (_batteryMode == AppConfig.modeControllerOnly) ...[
            const SizedBox(height: 10),
            _buildSelectField<String>(
              label: 'Battery Type',
              hint: 'Select a battery type',
              selectedValue: AppConfig.batteryTypes.containsKey(_batteryType) ? _batteryType : null,
              displayValue: AppConfig.batteryTypes[_batteryType] ?? '',
              items: AppConfig.batteryTypes.entries
                  .map((e) => _SelectionOption(e.key, e.value))
                  .toList(),
              enabled: !_busy,
              onSelected: (v) => setState(() => _batteryType = v),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _capacity,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              style: const TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
                color: SolarTheme.textPrimary,
              ),
              decoration: InputDecoration(
                labelText: 'Battery Capacity (Ah)',
                labelStyle: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.bold,
                  color: SolarTheme.textMuted,
                ),
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
            ),
          ],
          const SizedBox(height: 6),
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text(
              'Mode Saved on the Gateway',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: SolarTheme.textPrimary,
              ),
            ),
            subtitle: Text(
              AppConfig.batteryModeLabels[live.gatewayBatteryMode] ??
                  'Not received yet',
              style: const TextStyle(fontSize: 11, color: SolarTheme.textMuted),
            ),
          ),
          Wrap(
            spacing: 8,
            children: [
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF334155),
                  foregroundColor: Colors.white,
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                    side: const BorderSide(color: Color(0xFF475569)),
                  ),
                ),
                onPressed: _busy || !_modeDirty(provider)
                    ? null
                    : () => _run(_saveMode),
                child: const Text('Save System Mode', style: TextStyle(fontWeight: FontWeight.w600)),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _buildSelectField<String>(
            label: 'Controller Connection',
            hint: 'Select a connection',
            selectedValue: _link,
            displayValue: AppConfig.controllerLinkLabels[_link] ?? '',
            items: AppConfig.controllerLinkLabels.entries
                .map((e) => _SelectionOption(e.key, e.value))
                .toList(),
            enabled: !_busy,
            onSelected: (v) => setState(() {
              _link = v;
              _results = [];
            }),
          ),
          const SizedBox(height: 10),
          _buildSelectField<String>(
            label: 'Controller Model',
            hint: 'Select your Shiner model',
            selectedValue: _controllerModel.isEmpty ? null : _controllerModel,
            displayValue: _controllerModel,
            items: AppConfig.supportedControllerModels
                .map((m) => _SelectionOption(m, m))
                .toList(),
            enabled: !_busy,
            onSelected: (v) => setState(() => _controllerModel = v),
          ),
          const SizedBox(height: 6),
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text(
              'SRNE Controller',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: SolarTheme.textPrimary,
              ),
            ),
            subtitle: Text(
              '${c.hasSupportedControllerModel ? '${c.controllerModel} · ' : ''}${c.isRs485Controller ? AppConfig.controllerLinkLabels[AppConfig.linkRs485] : c.srneBleName.isEmpty ? c.srneBleMac : c.srneBleName} · ${controllerFresh ? 'receiving new data' : 'waiting for connection/data'} · ${live.controllerUpdatedAt?.toLocal().toString() ?? 'no reading'}',
              style: const TextStyle(fontSize: 11, color: SolarTheme.textMuted),
            ),
          ),
          Wrap(
            spacing: 8,
            children: [
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF334155),
                  foregroundColor: Colors.white,
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                    side: const BorderSide(color: Color(0xFF475569)),
                  ),
                ),
                onPressed: _busy || _controllerModel.isEmpty
                    ? null
                    : _link == AppConfig.linkRs485
                    ? () => _run(_searchRs485)
                    : () => _run(() => _scan('controller')),
                child: Text(
                  _link == AppConfig.linkRs485
                      ? 'Search RS485 Controller'
                      : 'Find / Change Controller',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              // Only once a controller has been chosen can it be turned off/on.
              if (c.isRs485Controller ? rs485Active : c.hasControllerDevice)
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF334155),
                    foregroundColor: Colors.white,
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                      side: const BorderSide(color: Color(0xFF475569)),
                    ),
                  ),
                  onPressed: _busy
                      ? null
                      : () => _run(() => _connection(true, !c.isControllerEnabled)),
                  child: Text(
                    c.isControllerEnabled ? 'Disconnect' : 'Reconnect',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
            ],
          ),
          if (bmsMode) ...[
            const SizedBox(height: 12),
            _buildSelectField<String>(
              label: 'BMS Type',
              hint: null,
              selectedValue: _jkProfile,
              displayValue: _jkProfile == 'jk02_24'
                  ? 'JK02 · 24S Frame Layout'
                  : _jkProfile == 'jk02_32'
                      ? 'JK02 · 32S Frame Layout'
                      : _jkProfile == 'jbd'
                          ? 'JBD / Xiaoxiang'
                          : 'Auto-detect (JK or JBD)',
              items: const [
                _SelectionOption('auto', 'Auto-detect (JK or JBD)'),
                _SelectionOption('jk02_24', 'JK02 · 24S Frame Layout'),
                _SelectionOption('jk02_32', 'JK02 · 32S Frame Layout'),
                _SelectionOption('jbd', 'JBD / Xiaoxiang'),
              ],
              enabled: !_busy,
              onSelected: (v) => setState(() => _jkProfile = v),
            ),
            const SizedBox(height: 6),
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text(
                'JK BMS',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: SolarTheme.textPrimary,
                ),
              ),
              subtitle: Text(
                '${c.jkBmsBleName.isEmpty ? c.jkBmsBleMac : c.jkBmsBleName} · ${!c.isBmsEnabled
                    ? 'Not in use'
                    : bmsFresh
                    ? 'receiving new data'
                    : 'waiting for connection/data'} · ${live.bmsUpdatedAt?.toLocal().toString() ?? 'no reading'}',
                style: const TextStyle(fontSize: 11, color: SolarTheme.textMuted),
              ),
            ),
            Wrap(
              spacing: 8,
              children: [
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF334155),
                    foregroundColor: Colors.white,
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                      side: const BorderSide(color: Color(0xFF475569)),
                    ),
                  ),
                  onPressed: _busy ? null : () => _run(() => _scan('bms')),
                  child: const Text('Find / Change BMS', style: TextStyle(fontWeight: FontWeight.w600)),
                ),
                if (c.hasBmsDevice)
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF334155),
                      foregroundColor: Colors.white,
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                        side: const BorderSide(color: Color(0xFF475569)),
                      ),
                    ),
                    onPressed: _busy
                        ? null
                        : () => _run(() => _connection(false, !c.isBmsEnabled)),
                    child: Text(
                      c.isBmsEnabled ? 'Disconnect' : 'Reconnect',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: SolarTheme.surfaceLight,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: SolarTheme.border),
            ),
            child: const Text(
              'A device that is already connected may stop advertising. Even if it is not in the list, its saved identity and ESP32 status are shown above. Close other JK/SRNE apps connected to it.',
              textAlign: TextAlign.justify,
              style: TextStyle(
                fontSize: 11.5,
                color: SolarTheme.textSecondary,
                height: 1.45,
              ),
            ),
          ),
          ..._results.map(
            (r) => ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(
                (r['name']?.toString() ?? '').isEmpty
                    ? 'Unnamed Bluetooth Device'
                    : r['name'].toString(),
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: SolarTheme.textPrimary,
                ),
              ),
              subtitle: Text(
                '${r['mac']} · ${r['rssi']} dBm',
                style: const TextStyle(fontSize: 11, color: SolarTheme.textMuted),
              ),
              trailing: TextButton(
                onPressed: _busy ? null : () => _run(() => _select(r)),
                child: const Text('Add to the ESP32'),
              ),
            ),
          ),
          if (_busy) const LinearProgressIndicator(),
          if (_message.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                _message,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  color: _messageColor ?? SolarTheme.textSecondary,
                  height: 1.4,
                ),
              ),
            ),
          if (provider.errorMessage != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                provider.errorMessage!,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 12,
                  color: SolarTheme.batteryDischarging,
                  height: 1.4,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSelectField<T>({
    required String label,
    required String? hint,
    required T? selectedValue,
    required String displayValue,
    required List<_SelectionOption<T>> items,
    required ValueChanged<T> onSelected,
    bool enabled = true,
  }) {
    return InkWell(
      onTap: enabled
          ? () => _showSelectionSheet<T>(
                title: label,
                items: items,
                selectedValue: selectedValue,
                onSelected: onSelected,
              )
          : null,
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
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label,
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: SolarTheme.textMuted,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    displayValue.isNotEmpty ? displayValue : (hint ?? 'Select an option'),
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      color: displayValue.isNotEmpty ? SolarTheme.textPrimary : SolarTheme.textMuted,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(Icons.keyboard_arrow_down_rounded, color: SolarTheme.textMuted),
          ],
        ),
      ),
    );
  }

  Future<void> _showSelectionSheet<T>({
    required String title,
    required List<_SelectionOption<T>> items,
    required T? selectedValue,
    required ValueChanged<T> onSelected,
  }) async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: SolarTheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: SolarTheme.textPrimary,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close_rounded, size: 20, color: SolarTheme.textMuted),
                      onPressed: () => Navigator.pop(ctx),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, color: SolarTheme.border),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: items.length,
                  itemBuilder: (context, index) {
                    final item = items[index];
                    final isSelected = item.value == selectedValue;
                    return InkWell(
                      onTap: () {
                        Navigator.pop(ctx);
                        onSelected(item.value);
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                        color: isSelected ? SolarTheme.surfaceLight : Colors.transparent,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Expanded(
                              child: Text(
                                item.label,
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                                  color: isSelected ? SolarTheme.solarAmber : SolarTheme.textPrimary,
                                ),
                              ),
                            ),
                            Icon(
                              isSelected ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
                              size: 20,
                              color: isSelected ? SolarTheme.solarAmber : SolarTheme.textMuted,
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _SelectionOption<T> {
  final T value;
  final String label;
  const _SelectionOption(this.value, this.label);
}
