import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'providers/solar_provider.dart';
import 'ui/main_navigation.dart';
import 'ui/theme.dart';
import 'ui/screens/welcome_setup_screen.dart';

/// App-wide SnackBar host, so the provider can show a short notice from
/// any screen (for example after re-enabling a disconnected device).
final appMessenger = GlobalKey<ScaffoldMessengerState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Set immersive dark system UI
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: SolarTheme.surface,
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(
          create: (_) => SolarProvider()
            ..onNotice = (message) => appMessenger.currentState
                ?.showSnackBar(SnackBar(content: Text(message))),
        ),
      ],
      child: const SolarMonitorApp(),
    ),
  );
}

class SolarMonitorApp extends StatelessWidget {
  const SolarMonitorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'NoxBrain',
      scaffoldMessengerKey: appMessenger,
      debugShowCheckedModeBanner: false,
      theme: SolarTheme.darkTheme,
      home: Consumer<SolarProvider>(
        builder: (context, provider, _) {
          if (provider.isLoading) {
            return const Scaffold(
              backgroundColor: SolarTheme.background,
              body: Center(
                child: CircularProgressIndicator(color: SolarTheme.solarAmber),
              ),
            );
          }
          if (!provider.previewMode &&
              (!provider.config.isSetupCompleted ||
              !provider.config.isFirebaseConfigured ||
              provider.config.firebaseEmail.isEmpty ||
              provider.config.setupHardwareId.isEmpty ||
              provider.config.setupStage != 5)) {
            return const WelcomeSetupScreen();
          }
          return const MainNavigation();
        },
      ),
    );
  }
}
