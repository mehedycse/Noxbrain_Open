import 'package:flutter/material.dart';
import 'package:local_auth/local_auth.dart';
import 'package:provider/provider.dart';

import '../../providers/solar_provider.dart';
import '../../services/firebase_auth_session.dart';
import '../../services/firebase_service.dart';
import '../theme.dart';

/// The four reset actions, each with the confirmation level agreed for it:
/// app settings (confirm), full app reset (phone biometric/PIN + confirm),
/// gateway factory reset (owner password + confirm) and deleting all cloud
/// data (owner password + typed gateway ID + final confirm).
class ResetActions extends StatefulWidget {
  const ResetActions({super.key});
  @override
  State<ResetActions> createState() => _ResetActionsState();
}

class _ResetActionsState extends State<ResetActions> {
  bool _busy = false;

  void _show(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (e) {
      _show(FirebaseAuthSession.message(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _confirm(String title, String body, String action) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          title,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: SolarTheme.textPrimary,
          ),
        ),
        content: Text(
          body,
          textAlign: TextAlign.justify,
          style: const TextStyle(
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
            child: Text(
              action,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
    return accepted == true;
  }

  Future<String?> _askText(String title, String label, {bool secret = true}) {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          obscureText: secret,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(labelText: label),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Continue'),
          ),
        ],
      ),
    ).whenComplete(controller.dispose);
  }

  /// Phone biometric or screen lock. Devices without any lock only confirm.
  Future<bool> _phoneAuth() async {
    final auth = LocalAuthentication();
    if (!await auth.isDeviceSupported()) return true;
    try {
      return await auth.authenticate(
        localizedReason: 'Unlock your phone to confirm the app reset',
        biometricOnly: false,
      );
    } catch (_) {
      return false;
    }
  }

  Future<void> _resetSettings() async {
    if (!await _confirm(
      'Reset App Settings?',
      'Panel watt, battery capacity, report times, Settings lock and other preferences on this phone return to their defaults. Firebase sign-in, gateway and devices are kept.',
      'Reset',
    )) {
      return;
    }
    if (!mounted) return;
    final provider = context.read<SolarProvider>();
    await provider.resetAppPreferences();
    if (provider.config.isSetupCompleted) {
      try {
        await FirebaseService(provider.config).saveReportingOptions();
      } catch (_) {
        // Applied by the gateway when it is next online and settings are saved.
      }
    }
    _show('App settings have been reset.');
  }

  Future<void> _resetApp() async {
    if (!await _confirm(
      'Remove Everything From This Phone?',
      'Firebase sign-in, gateway details and all app settings are removed from this phone and setup starts again. Data on the gateway and in Firebase is not touched.\n\nIf your phone is lost: change your password in the Firebase Console; the lost phone\'s sign-in then stops working.',
      'Remove Everything',
    )) {
      return;
    }
    if (!await _phoneAuth()) {
      _show('Phone lock not confirmed. Nothing was removed.');
      return;
    }
    if (!mounted) return;
    await context.read<SolarProvider>().resetAppCompletely();
  }

  Future<void> _factoryReset() async {
    final provider = context.read<SolarProvider>();
    final config = provider.config;
    if (!await _confirm(
      'Factory Reset the Gateway?',
      'The ESP32\'s Wi-Fi, Firebase, controller/BMS and all stored history are erased and it opens the setup Wi-Fi like a new one. The firmware stays. The gateway must be online.',
      'Continue',
    )) {
      return;
    }
    final password = await _askText(
      'Owner\'s Firebase Password',
      'Authentication Password',
    );
    if (password == null || password.isEmpty) return;
    await FirebaseAuthSession.verifyOwnerPassword(config, password);
    if (!await _confirm(
      'Final Confirmation',
      'All setup and stored data on the gateway will be erased now.',
      'Factory Reset',
    )) {
      return;
    }
    await FirebaseService(config).sendGatewayCommand('factory_reset', {});
    await provider.requireGatewaySetup(ownershipReleased: false);
    _show('The gateway is reset to new. Set it up again.');
  }

  Future<void> _deleteCloud() async {
    final provider = context.read<SolarProvider>();
    final config = provider.config;
    if (!await _confirm(
      'Delete All Firebase Data?',
      'This gateway\'s history, live data, setup and ownership are deleted from Firebase for good. This cannot be undone.',
      'Continue',
    )) {
      return;
    }
    final password = await _askText(
      'Owner\'s Firebase Password',
      'Authentication Password',
    );
    if (password == null || password.isEmpty) return;
    await FirebaseAuthSession.verifyOwnerPassword(config, password);
    final id = config.deviceId;
    final suffix = id.length >= 4 ? id.substring(id.length - 4) : id;
    final typed = await _askText(
      'Type the last 4 characters of the Gateway ID',
      'Gateway ID: …$suffix',
      secret: false,
    );
    if (typed?.trim().toUpperCase() != suffix.toUpperCase()) {
      _show('Characters do not match. Nothing was deleted.');
      return;
    }
    if (!await _confirm(
      'Final Confirmation',
      'This will be deleted for good now.',
      'Delete for Good',
    )) {
      return;
    }
    await FirebaseService(config).deleteAllGatewayData();
    await FirebaseAuthSession.deleteDeviceAccount(config);
    await provider.requireGatewaySetup(ownershipReleased: true);
    _show('All Firebase data of this gateway has been deleted.');
  }

  Widget _button(
    String label,
    IconData icon,
    Future<void> Function() action, {
    Color? iconColor,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF334155), // Slate Gray
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: const BorderSide(color: Color(0xFF475569)),
          ),
          elevation: 0,
        ),
        icon: Icon(icon, size: 18, color: iconColor ?? const Color(0xFF94A3B8)),
        onPressed: _busy ? null : () => _run(action),
        label: Text(
          label,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _button(
          'App Settings Reset',
          Icons.settings_backup_restore_rounded,
          _resetSettings,
        ),
        _button(
          'Remove Everything From This Phone (Logout)',
          Icons.phonelink_erase_rounded,
          _resetApp,
        ),
        _button(
          'Gateway Factory Reset',
          Icons.restart_alt_rounded,
          _factoryReset,
          iconColor: const Color(0xFFF87171),
        ),
        _button(
          'Delete All Gateway Data in Firebase',
          Icons.delete_forever_rounded,
          _deleteCloud,
          iconColor: const Color(0xFFF87171),
        ),
        if (_busy) const LinearProgressIndicator(),
      ],
    );
  }
}
