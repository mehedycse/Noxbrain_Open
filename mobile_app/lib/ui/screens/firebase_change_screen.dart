import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/app_config.dart';
import '../../providers/solar_provider.dart';
import '../../services/firebase_auth_session.dart';
import '../../services/firebase_service.dart';
import '../../services/storage_service.dart';
import '../widgets/firebase_check_list.dart';
import '../theme.dart';

/// Moves an online gateway to another Firebase project from anywhere. The
/// command goes through the current Firebase; the gateway keeps the new one
/// only after reaching it, otherwise it returns to the current one. If the
/// current Firebase no longer works, use setup with 3 BOOT presses instead.
class FirebaseChangeScreen extends StatefulWidget {
  const FirebaseChangeScreen({super.key});
  @override
  State<FirebaseChangeScreen> createState() => _FirebaseChangeScreenState();
}

class _FirebaseChangeScreenState extends State<FirebaseChangeScreen> {
  final _url = TextEditingController(), _key = TextEditingController();
  final _email = TextEditingController(), _password = TextEditingController();
  List<FirebaseCheck> _checks = [];
  String _message = '';
  bool _busy = false;

  @override
  void dispose() {
    for (final c in [_url, _key, _email, _password]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = '';
    });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => _message = FirebaseAuthSession.message(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  AppConfig _next(AppConfig current) => AppConfig.fromJson(current.toJson())
    ..firebaseDatabaseUrl = _url.text.trim()
    ..firebaseApiKey = _key.text.trim()
    ..firebaseEmail = _email.text.trim();

  Future<void> _paste() async {
    final controller = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Paste Firebase Config'),
        content: TextField(controller: controller, maxLines: 6),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Fill in'),
          ),
        ],
      ),
    );
    controller.dispose();
    final parsed = text == null
        ? null
        : AppConfig.parseFirebaseConfigSnippet(text);
    if (text == null) return;
    if (parsed != null) {
      if (parsed.firebaseDatabaseUrl.isNotEmpty) {
        _url.text = parsed.firebaseDatabaseUrl;
      }
      if (parsed.firebaseApiKey.isNotEmpty) _key.text = parsed.firebaseApiKey;
    }
    final problem = AppConfig.configPasteProblem(parsed);
    if (problem != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(problem)));
    }
  }

  Future<void> _check() async {
    final rows = await FirebaseAuthSession.checkConnection(
      _next(context.read<SolarProvider>().config),
      _email.text,
      _password.text,
    );
    if (mounted) setState(() => _checks = rows);
  }

  Future<void> _change() async {
    final provider = context.read<SolarProvider>();
    final current = provider.config;
    if (!current.isSetupCompleted) {
      throw Exception('Finish the gateway setup first.');
    }
    final next = _next(current);
    next.firebaseDatabaseUrl = FirebaseAuthSession.validateDatabaseUrl(
      next.firebaseDatabaseUrl,
    );
    if (next.firebaseDatabaseUrl == current.firebaseDatabaseUrl) {
      throw Exception('This is the current Firebase. Enter another project\'s details.');
    }
    final currentCloud = FirebaseService(current);
    setState(
      () => _message = 'Checking that the gateway is online on the current Firebase…',
    );
    final status = await currentCloud.setupStatus();
    final updated = (status['updated_at'] as num?)?.toInt() ?? 0;
    final age = DateTime.now().millisecondsSinceEpoch - updated;
    if (status['state'] != 'online' || age < -5000 || age > 20000) {
      throw Exception(
        'The gateway is not online now. Press the ESP32 BOOT button 3 times within one second, then change it with "Open Firebase & gateway setup".',
      );
    }

    // Prepare the new project; the new login stays unsaved until confirmed.
    setState(() => _message = 'Preparing the new Firebase…');
    await FirebaseAuthSession.signIn(
      next,
      _email.text,
      _password.text,
      remember: false,
    );
    await FirebaseAuthSession.claimGateway(next);
    await FirebaseAuthSession.prepareDeviceAccount(next);
    final device = await FirebaseAuthSession.deviceCredentials(next);
    final nextCloud = FirebaseService(next);

    setState(
      () => _message = 'The gateway is moving to the new Firebase and checking it. This can take up to two minutes…',
    );
    // Checkpoint first: if the app closes now, the next start finds out where
    // the gateway ended up and follows it.
    final id = FirebaseService.newCommandId();
    await FirebaseAuthSession.rememberPendingLogin(next);
    await StorageService.saveCloudChange({
      'database_url': next.firebaseDatabaseUrl,
      'api_key': next.firebaseApiKey,
      'email': next.firebaseEmail,
      'command_id': id,
      'started_at': DateTime.now().millisecondsSinceEpoch,
    });
    await currentCloud.queueCommand(id: id, 'cloud_change', {
      'database_url': next.firebaseDatabaseUrl,
      'api_key': next.firebaseApiKey,
      'email': device['email'],
      'password': device['password'],
    });
    // Success is reported in the new project, failure in the current one.
    final deadline = DateTime.now().add(const Duration(seconds: 150));
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(seconds: 3));
      final confirmed = await nextCloud
          .commandResult(id)
          .catchError((_) => null);
      if (confirmed?['status'] == 'confirmed') {
        await FirebaseAuthSession.promotePendingLogin(next);
        await StorageService.clearCloudChange();
        await provider.updateConfig(next);
        if (mounted) {
          setState(() {
            _password.clear();
            _message = 'The gateway is connected to the new Firebase. From now on the app and the gateway use the new Firebase. Old history stays in the old Firebase.';
          });
        }
        return;
      }
      final previous = await currentCloud
          .commandResult(id)
          .catchError((_) => null);
      if (previous?['status'] == 'failed' || previous?['status'] == 'expired') {
        await StorageService.clearCloudChange();
        await FirebaseAuthSession.dropPendingLogin();
        throw Exception(
          previous?['message'] ?? 'The gateway could not move to the new Firebase.',
        );
      }
    }
    throw Exception(
      'No confirmed result yet. Check the dashboard in a little while; if the gateway fails, it returns to the previous Firebase by itself.',
    );
  }

  Widget _field(
    String label,
    TextEditingController controller, {
    bool secret = false,
    String? helper,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: TextField(
      controller: controller,
      obscureText: secret,
      autocorrect: false,
      enableSuggestions: !secret,
      style: const TextStyle(
        fontSize: 13.5,
        fontWeight: FontWeight.w600,
        color: SolarTheme.textPrimary,
      ),
      decoration: InputDecoration(
        labelText: label,
        helperText: helper,
        helperMaxLines: 3,
        labelStyle: const TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.bold,
          color: SolarTheme.textMuted,
        ),
        helperStyle: const TextStyle(
          fontSize: 11,
          color: SolarTheme.textMuted,
          height: 1.35,
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
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(title: const Text('Change Firebase Remotely')),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: SolarTheme.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: SolarTheme.border),
                ),
                child: const Text(
                  'While the gateway is online on the current Firebase, you can move it to a new Firebase without going near it. If it cannot reach the new Firebase, it returns to the current one by itself. If the current Firebase does not work, press the BOOT button 3 times within one second and change it through setup.',
                  textAlign: TextAlign.justify,
                  style: TextStyle(
                    fontSize: 12,
                    color: SolarTheme.textSecondary,
                    height: 1.45,
                  ),
                ),
              ),
              const SizedBox(height: 16),
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
                  onPressed: _busy ? null : _paste,
                  child: const Text(
                    'Firebase Config Paste',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              _field('New Realtime Database URL', _url),
              _field('New Web API Key', _key),
              _field('Authentication Email', _email),
              _field(
                'Authentication Password',
                _password,
                secret: true,
                helper:
                    'The password of the account created in Firebase Authentication → Users; not your Gmail or email password',
              ),
              const SizedBox(height: 4),
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
                  onPressed: _busy ? null : () => _run(_check),
                  child: const Text(
                    'Test Connection (Writes Nothing)',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
              if (_checks.isNotEmpty) ...[
                const SizedBox(height: 12),
                FirebaseCheckList(rows: _checks),
              ],
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: SizedBox(
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
                    onPressed: _busy ? null : () => _run(_change),
                    child: const Text(
                      'Move the Gateway to the New Firebase',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ),
              if (_busy)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Center(child: CircularProgressIndicator()),
                ),
              if (_message.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Text(
                    _message,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 12.5,
                      color: SolarTheme.textSecondary,
                      height: 1.4,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
