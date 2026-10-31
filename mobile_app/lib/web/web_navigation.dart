import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/solar_provider.dart';
import '../services/firebase_auth_session.dart';
import '../ui/screens/history_screen.dart';
import '../ui/screens/home_screen.dart';
import '../ui/screens/settings_screen.dart';
import '../ui/screens/statistics_screen.dart';
import '../ui/theme.dart';
import 'web_solar_provider.dart';

/// The app's four tabs for the web view. Home, Statistics and History are
/// the app's own screens (read-only); Settings asks for the owner's sign-in.
class WebNavigation extends StatefulWidget {
  const WebNavigation({super.key});

  @override
  State<WebNavigation> createState() => _WebNavigationState();
}

class _WebNavigationState extends State<WebNavigation> {
  int _currentIndex = 0;

  final List<Widget> _screens = const [
    HomeScreen(),
    StatisticsScreen(),
    HistoryScreen(),
    WebSettingsGate(),
  ];

  @override
  Widget build(BuildContext context) {
    final connecting = context.watch<SolarProvider>().liveConnecting;
    return Stack(
      children: [
        Scaffold(
          body: IndexedStack(index: _currentIndex, children: _screens),
          bottomNavigationBar: BottomNavigationBar(
            currentIndex: _currentIndex,
            onTap: (index) {
              if ((index == 1 || index == 2) && index != _currentIndex) {
                context.read<SolarProvider>().refreshHistory();
              }
              setState(() => _currentIndex = index);
            },
            selectedItemColor: SolarTheme.solarAmber,
            unselectedItemColor: SolarTheme.textMuted,
            backgroundColor: SolarTheme.surface,
            type: BottomNavigationBarType.fixed,
            selectedLabelStyle: const TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 11,
            ),
            unselectedLabelStyle: const TextStyle(fontSize: 11),
            items: const [
              BottomNavigationBarItem(
                icon: Icon(Icons.home_outlined),
                activeIcon: Icon(Icons.home_rounded),
                label: 'Home',
              ),
              BottomNavigationBarItem(
                icon: Icon(Icons.grid_view_outlined),
                activeIcon: Icon(Icons.grid_view_rounded),
                label: 'Statistics',
              ),
              BottomNavigationBarItem(
                icon: Icon(Icons.history_rounded),
                activeIcon: Icon(Icons.history_toggle_off_rounded),
                label: 'History',
              ),
              BottomNavigationBarItem(
                icon: Icon(Icons.settings_outlined),
                activeIcon: Icon(Icons.settings_rounded),
                label: 'Settings',
              ),
            ],
          ),
        ),
        if (connecting)
          Positioned.fill(
            child: ColoredBox(
              color: SolarTheme.background.withValues(alpha: 0.85),
              child: Center(
                child: Material(
                  color: Colors.transparent,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 28,
                      vertical: 24,
                    ),
                    decoration: BoxDecoration(
                      color: SolarTheme.surface,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: SolarTheme.border),
                    ),
                    child: const Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircularProgressIndicator(color: SolarTheme.solarAmber),
                        SizedBox(height: 16),
                        Text(
                          'Connecting to the gateway…',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: SolarTheme.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Settings on the web: the owner's Firebase email and password first; then
/// the app's Controller Parameter tab (load, charge/discharge switch,
/// battery parameters). Nothing can be changed before sign-in.
class WebSettingsGate extends StatelessWidget {
  const WebSettingsGate({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<SolarProvider>() as WebSolarProvider;
    if (!provider.signedIn) return const _WebSignIn();
    return Stack(
      children: [
        const SettingsScreen(controllerOnly: true),
        Positioned(
          top: 0,
          right: 4,
          child: SafeArea(
            child: IconButton(
              icon: const Icon(Icons.lock_outline_rounded),
              color: SolarTheme.textPrimary,
              tooltip: 'Sign out (${provider.signedInEmail})',
              onPressed: () async {
                await provider.signOut();
                if (context.mounted) {
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(const SnackBar(content: Text('Signed out.')));
                }
              },
            ),
          ),
        ),
      ],
    );
  }
}

class _WebSignIn extends StatefulWidget {
  const _WebSignIn();

  @override
  State<_WebSignIn> createState() => _WebSignInState();
}

class _WebSignInState extends State<_WebSignIn> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _apiKey = TextEditingController();
  bool _obscure = true, _busy = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _apiKey.dispose();
    super.dispose();
  }

  Future<void> _submit(WebSolarProvider provider) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await provider.signIn(_email.text, _password.text, _apiKey.text);
      _password.clear();
    } catch (e) {
      if (mounted) setState(() => _error = FirebaseAuthSession.message(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  InputDecoration _decoration(String label, IconData icon, {Widget? suffix}) =>
      InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: SolarTheme.textMuted, fontSize: 13),
        prefixIcon: Icon(icon, color: SolarTheme.textMuted, size: 20),
        suffixIcon: suffix,
        filled: true,
        fillColor: SolarTheme.surfaceLight,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: SolarTheme.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: SolarTheme.border),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final provider = context.read<SolarProvider>() as WebSolarProvider;
    final needsKey = provider.config.firebaseApiKey.trim().isEmpty;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: SolarTheme.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: SolarTheme.border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(
                  Icons.lock_outline_rounded,
                  color: SolarTheme.solarAmber,
                  size: 36,
                ),
                const SizedBox(height: 12),
                const Text(
                  'Owner Sign-In',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: SolarTheme.textPrimary,
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Anyone with this link can view the system. Settings and controls need the Firebase email and password of the account that owns this gateway.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12,
                    color: SolarTheme.textSecondary,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 18),
                TextField(
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  autofillHints: const [AutofillHints.email],
                  decoration: _decoration('Email', Icons.mail_outline_rounded),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _password,
                  obscureText: _obscure,
                  autofillHints: const [AutofillHints.password],
                  onSubmitted: (_) => _submit(provider),
                  decoration: _decoration(
                    'Password',
                    Icons.key_rounded,
                    suffix: IconButton(
                      icon: Icon(
                        _obscure
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                        color: SolarTheme.textMuted,
                        size: 20,
                      ),
                      onPressed: () => setState(() => _obscure = !_obscure),
                    ),
                  ),
                ),
                if (needsKey) ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: _apiKey,
                    decoration: _decoration(
                      'Firebase Web API Key',
                      Icons.vpn_key_outlined,
                    ),
                  ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 12,
                      color: SolarTheme.batteryDischarging,
                    ),
                  ),
                ],
                const SizedBox(height: 18),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: SolarTheme.solarAmber,
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onPressed: _busy ? null : () => _submit(provider),
                  child: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.black,
                          ),
                        )
                      : const Text(
                          'Sign In',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
