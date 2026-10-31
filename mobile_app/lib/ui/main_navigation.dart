import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/solar_provider.dart';
import 'screens/home_screen.dart';
import 'screens/statistics_screen.dart';
import 'screens/history_screen.dart';
import 'screens/settings_screen.dart';
import 'theme.dart';

class MainNavigation extends StatefulWidget {
  const MainNavigation({super.key});

  @override
  State<MainNavigation> createState() => _MainNavigationState();
}

class _MainNavigationState extends State<MainNavigation> {
  int _currentIndex = 0;

  final List<Widget> _screens = const [
    HomeScreen(),
    StatisticsScreen(),
    HistoryScreen(),
    SettingsScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    final connecting = context.watch<SolarProvider>().liveConnecting;
    return Stack(
      children: [
        Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: _screens,
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (index) {
          // Statistics and History show the saved daily history: fetch the
          // latest copy whenever one of them is opened.
          if ((index == 1 || index == 2) && index != _currentIndex) {
            context.read<SolarProvider>().refreshHistory();
          }
          setState(() => _currentIndex = index);
        },
        selectedItemColor: SolarTheme.solarAmber,
        unselectedItemColor: SolarTheme.textMuted,
        backgroundColor: SolarTheme.surface,
        type: BottomNavigationBarType.fixed,
        selectedLabelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11),
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
        // Just opened: a centred loading card over the whole app until the
        // first gateway data arrives (at most 30 s), instead of offline alerts.
        if (connecting)
          Positioned.fill(
            child: ColoredBox(
              color: SolarTheme.background.withOpacity(0.85),
              child: Center(
                child: Material(
                  color: Colors.transparent,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
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
                          'Connecting to your gateway…',
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
