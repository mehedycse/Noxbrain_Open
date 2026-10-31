import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';

import '../../providers/solar_provider.dart';
import '../theme.dart';
import '../widgets/power_flow_diagram.dart';
import '../widgets/metric_card.dart';
import '../widgets/battery_ring_gauge.dart';
import '../widgets/energy_summary_card.dart';
import '../widgets/firmware_update_sheet.dart';
import '../../services/weather_service.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String? _weatherText;
  Timer? _weatherTimer;
  StreamSubscription<ServiceStatus>? _locationStatus;
  // Each weather request gets a number; a slower, older reply is ignored.
  int _weatherRequest = 0, _weatherRetries = 0;

  @override
  void initState() {
    super.initState();
    _initWeather();
  }

  @override
  void dispose() {
    WeatherService.enabled.removeListener(_weatherChoiceChanged);
    _weatherTimer?.cancel();
    _locationStatus?.cancel();
    super.dispose();
  }

  Future<void> _initWeather() async {
    final choice = await WeatherService.loadEnabled();
    if (!mounted) return;
    WeatherService.enabled.addListener(_weatherChoiceChanged);
    if (choice != null) {
      _weatherChoiceChanged();
      return;
    }
    // First time: explain why before Android's location prompt appears.
    final accepted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text(
          'Show Local Weather?',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: SolarTheme.textPrimary,
          ),
        ),
        content: const Text(
          'The home screen can show the current weather. For this the app needs your approximate location (about 1 km). It is used only to ask Open-Meteo for the weather and is never sent to Firebase or the gateway. You can change this later in Settings › General › Show weather.',
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
            child: const Text('Not Now'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    final granted =
        accepted == true && await WeatherService.requestPermission();
    await WeatherService.setEnabled(granted);
  }

  /// Starts or stops the weather refresh when the user's choice changes.
  void _weatherChoiceChanged() {
    _weatherTimer?.cancel();
    _weatherTimer = null;
    _locationStatus?.cancel();
    _locationStatus = null;
    _weatherRequest++; // A reply still on its way is no longer shown.
    if (!mounted) return;
    setState(() => _weatherText = null);
    if (WeatherService.enabled.value == true) {
      _weatherRetries = 0;
      _loadWeather();
      // Phone Location switched on later: fetch at once instead of waiting.
      try {
        _locationStatus = Geolocator.getServiceStatusStream().listen(
          (status) {
            if (status == ServiceStatus.enabled) {
              _weatherRetries = 0;
              _loadWeather();
            }
          },
          onError: (_) {},
        );
      } catch (_) {}
    }
  }

  Future<void> _loadWeather() async {
    _weatherTimer?.cancel();
    final request = ++_weatherRequest;
    String text;
    bool ok;
    try {
      text = await WeatherService.current();
      ok = !WeatherService.isFailure(text);
    } catch (_) {
      text = 'Weather Unavailable';
      ok = false;
    }
    if (!mounted ||
        request != _weatherRequest ||
        WeatherService.enabled.value != true) {
      return;
    }
    setState(() => _weatherText = text);
    // No location or no answer yet: try again every minute (5 times), then
    // the normal refresh every 30 minutes.
    final retry = !ok && _weatherRetries < 5;
    if (retry) {
      _weatherRetries++;
    } else if (ok) {
      _weatherRetries = 0;
    }
    _weatherTimer = Timer(
      Duration(minutes: retry ? 1 : 30),
      _loadWeather,
    );
  }

  Widget _pill(Widget child, Color background, Color border) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(
      color: background,
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: border),
    ),
    child: child,
  );

  String _formatDuration(double hours) {
    if (hours.isNaN || hours.isInfinite || hours <= 0) return '—';
    final int totalMinutes = (hours * 60).round();
    final int h = totalMinutes ~/ 60;
    final int m = totalMinutes % 60;
    return '${h}h ${m}m';
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<SolarProvider>(
      builder: (context, provider, child) {
        final live = provider.live;
        final summary = provider.todaySummary;
        final config = provider.config;

        // Gateway-calculated from the saved panel rating; null = unknown.
        final double? pvOutputPercent = live.panelOutputPercent;

        final bool isCharging = live.batteryDirection == 'charging';
        final bool isDischarging = live.batteryDirection == 'discharging';
        // Only Controller Mode: controller data + calculated values.
        // Controller + BMS Mode: BMS data only, "Loading" until it is fresh.
        final bool controllerOnly = live.batteryCalculated;
        final String batteryStatus = live.batteryLoading
            ? 'Loading'
            : !live.batteryCurrentKnown
            ? 'Unavailable'
            : isCharging
            ? 'Charging'
            : (isDischarging ? 'Discharging' : 'Idle');
        String batteryValue(String value) => live.batteryLoading
            ? 'Loading'
            : (live.batteryCurrentKnown ? value : '—');

        // Estimate time
        double? estimateHours;
        final double absCurrent = live.batteryCurrent.abs();
        if (live.batteryCapacityKnown && absCurrent > 0.1) {
          if (isCharging) {
            final double needed =
                (live.batteryCapacityAh - live.batteryRemainingAh).clamp(
                  0.0,
                  live.batteryCapacityAh,
                );
            estimateHours = needed / absCurrent;
          } else if (isDischarging) {
            estimateHours = live.batteryRemainingAh / absCurrent;
          }
        }
        final String estimateLabel =
            '${isCharging
                ? 'Estimated Time to Full-charge'
                : isDischarging
                ? 'Estimated Time Remaining'
                : 'Estimated Time'}${controllerOnly ? ' (calculated)' : ''}';

        final bool solarPowerOn = live.panelPower > 1.0;
        final bool batteryChargingOn =
            isCharging ||
            (live.chargingMode != 'Off' && live.chargingMode.isNotEmpty);
        final bool loadOn = live.loadPower > 1.0;

        // Alerts calculation matching reference
        final List<Map<String, String>> activeAlerts = [];
        // Just opened: data is on its way, so no connection alerts yet.
        final bool connecting = provider.liveConnecting;
        if (!connecting && !provider.isConnected) {
          activeAlerts.add({
            'title': 'Device Connection Offline',
            'detail': 'No fresh controller heartbeat is available.',
          });
        }
        if (!connecting && !live.controllerConnected) {
          // The gateway knows why it cannot reach the controller -- a wrong
          // PIN, a locked module, another app holding it. That used to reach
          // the user only while they were choosing the controller, or in the
          // diagnostics report, so an ordinary reconnect failure read as a
          // bare "unavailable" with nothing to act on. Say what it says.
          activeAlerts.add({
            'title': live.controllerLocked
                ? 'Controller Needs Its Bluetooth PIN'
                : 'Controller Data Unavailable',
            'detail': live.controllerVerdict.isNotEmpty
                ? live.controllerVerdict
                : 'Panel and DC load readings are hidden until fresh controller data arrives.',
          });
        }
        if (!connecting && !controllerOnly && !live.bmsConnected) {
          activeAlerts.add({
            'title': 'BMS Data Unavailable',
            'detail': 'Controller monitoring continues. Battery values show Loading until fresh BMS data arrives.',
          });
        }
        if (controllerOnly &&
            live.controllerConnected &&
            !live.batteryCapacityKnown) {
          activeAlerts.add({
            'title': 'Battery Details Needed',
            'detail': 'Save the battery type and capacity (Ah) in Settings → General; capacity and remaining Ah are then shown.',
          });
        }
        for (final fault in live.controllerFaults) {
          activeAlerts.add({
            'title': 'Controller: $fault',
            'detail': 'Reported by the controller (fault/warning register).',
          });
        }
        if (live.controllerModelMatch == false) {
          activeAlerts.add({
            'title': 'Controller Model Mismatch',
            'detail':
                'Selected ${config.controllerModel}, but the controller reports "${live.controllerModelReported}". Select the correct model in the Connectivity tab.',
          });
        }
        if (live.batteryCapacityKnown && live.soc <= 20 && live.soc > 0) {
          activeAlerts.add({
            'title': 'Battery Low',
            'detail': '${live.soc.toStringAsFixed(0)}% remaining.',
          });
        }

        final bool isLive = provider.isConnected;

        return Scaffold(
          body: SafeArea(
            bottom: false,
            child: CustomScrollView(
              physics: const BouncingScrollPhysics(),
              slivers: [
                // Centered Hero Header (Matching Reference App)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 18, 16, 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              Image.asset(
                                'assets/images/logo.png',
                                width: 26,
                                height: 26,
                                fit: BoxFit.contain,
                              ),
                              const SizedBox(width: 10),
                              const Text(
                                'Solar System Monitoring',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 22,
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: -0.6,
                                  color: Color(0xFFF1F5FD),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),

                        // One line: Live status · Updated time · Weather
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _pill(
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Container(
                                      width: 7,
                                      height: 7,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: isLive
                                            ? const Color(0xFF42D7A4)
                                            : connecting
                                            ? const Color(0xFF8EA0B8)
                                            : const Color(0xFFFF6874),
                                        boxShadow: [
                                          BoxShadow(
                                            color: isLive
                                                ? const Color(0xFF42D7A4)
                                                : connecting
                                                ? const Color(0xFF8EA0B8)
                                                : const Color(0xFFFF6874),
                                            blurRadius: 6,
                                          ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    Text(
                                      isLive
                                          ? 'Live'
                                          : (connecting ? 'Connecting' : 'Off'),
                                      style: TextStyle(
                                        fontSize: 10.5,
                                        fontWeight: FontWeight.bold,
                                        color: isLive
                                            ? const Color(0xFF75E8BF)
                                            : connecting
                                            ? const Color(0xFF8EA0B8)
                                            : const Color(0xFFFF9BA0),
                                      ),
                                    ),
                                  ],
                                ),
                                isLive
                                    ? const Color(0xFF12392D)
                                    : connecting
                                    ? const Color(0xFF0F1728)
                                    : const Color(0xFF321D2B),
                                isLive
                                    ? const Color(0xFF236047)
                                    : connecting
                                    ? const Color(0xFF1E2B42)
                                    : const Color(0xFF633342),
                              ),
                              const SizedBox(width: 8),
                              _pill(
                                Text(
                                  live.timestamp != null
                                      ? 'Updated ${DateFormat('h:mm:ss a').format(live.timestamp!)}'
                                      : 'Waiting for Controller Data',
                                  style: const TextStyle(
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.w600,
                                    color: Color(0xFF8EA0B8),
                                  ),
                                ),
                                const Color(0xFF0F1728),
                                const Color(0xFF1E2B42),
                              ),
                              if (WeatherService.enabled.value == true) ...[
                                const SizedBox(width: 8),
                                _pill(
                                  Text(
                                    _weatherText ?? 'Weather…',
                                    style: const TextStyle(
                                      fontSize: 10.5,
                                      fontWeight: FontWeight.w600,
                                      color: Color(0xFF38BDF8),
                                    ),
                                  ),
                                  const Color(0xFF0F1728),
                                  const Color(0xFF1E2B42),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                // Update notice: firmware or app release available (never automatic).
                if (provider.firmwareUpdateAvailable ||
                    provider.appUpdateAvailable)
                  SliverToBoxAdapter(
                    child: GestureDetector(
                      onTap: () => UpdateSheet.show(
                        context,
                        firmware: provider.firmwareUpdateAvailable,
                      ),
                      child: Container(
                        margin: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 6,
                        ),
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: const Color(0xFF0E1322),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: SolarTheme.solarAmber),
                        ),
                        child: Text(
                          provider.firmwareUpdateAvailable
                              ? 'New gateway firmware available (v${provider.firmwareRelease?.version}) · View'
                              : 'New app version available (v${provider.appRelease?.version}) · View',
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: SolarTheme.solarAmber,
                          ),
                        ),
                      ),
                    ),
                  ),

                // Alerts Panel (Matching Reference Design)
                SliverToBoxAdapter(
                  child: Container(
                    margin: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 6,
                    ),
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0E1322),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: activeAlerts.isNotEmpty
                            ? const Color(0xFF633342)
                            : const Color(0xFF1E2B42),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.2),
                          blurRadius: 10,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text(
                              'Alerts',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                                color: Color(0xFF38BDF8),
                              ),
                            ),
                            Text(
                              activeAlerts.isNotEmpty
                                  ? '${activeAlerts.length} active'
                                  : 'All Clear',
                              style: const TextStyle(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFF8A99B2),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        if (activeAlerts.isNotEmpty)
                          ...activeAlerts.map((alert) {
                            return Container(
                              margin: const EdgeInsets.only(bottom: 6),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 8,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xFF261822),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color: const Color(0xFF5A2535),
                                ),
                              ),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.center,
                                children: [
                                  Container(
                                    width: 3.5,
                                    height: 30,
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFFF6874),
                                      borderRadius: BorderRadius.circular(2),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          alert['title']!,
                                          style: const TextStyle(
                                            fontSize: 11.5,
                                            fontWeight: FontWeight.bold,
                                            color: Color(0xFFFF9BA0),
                                          ),
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          alert['detail']!,
                                          style: const TextStyle(
                                            fontSize: 10.5,
                                            color: Color(0xFF8F9FB5),
                                            height: 1.25,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            );
                          })
                        else
                          const Text(
                            'No active system alerts.',
                            style: TextStyle(
                              fontSize: 11,
                              color: Color(0xFF75859D),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),

                // Animated Power Flow Diagram
                SliverToBoxAdapter(
                  child: live.controllerConnected
                      ? PowerFlowDiagram(live: live)
                      : const Padding(
                          padding: EdgeInsets.all(16),
                          child: Text(
                            'Controller data unavailable · power flow unknown',
                          ),
                        ),
                ),

                // 1. Solar Power Card (4 items in a row)
                SliverToBoxAdapter(
                  child: MetricCard(
                    title:
                        'Solar Power: ${!live.controllerConnected
                            ? "Unavailable"
                            : solarPowerOn
                            ? "ON"
                            : "OFF"}',
                    icon: Icons.wb_sunny_rounded,
                    accentColor: SolarTheme.solarAmber,
                    badgeText:
                        'Charging: ${!live.controllerConnected
                            ? "Unknown"
                            : batteryChargingOn
                            ? "ON"
                            : "OFF"}${live.chargingMode != "Off" && live.chargingMode.isNotEmpty ? " (${live.chargingMode})" : ""}',
                    badgeColor: batteryChargingOn
                        ? SolarTheme.batteryGreen
                        : const Color(0xFF8A99B2),
                    items: [
                      MetricItem(
                        'Voltage',
                        live.controllerConnected
                            ? live.panelVoltage.toStringAsFixed(1)
                            : '—',
                        'V',
                      ),
                      MetricItem(
                        'Current',
                        live.controllerConnected
                            ? live.panelCurrent.toStringAsFixed(2)
                            : '—',
                        'A',
                      ),
                      MetricItem(
                        'Power',
                        live.controllerConnected
                            ? live.panelPower.toStringAsFixed(0)
                            : '—',
                        'W',
                      ),
                      MetricItem(
                        'Output %',
                        live.controllerConnected && pvOutputPercent != null
                            ? pvOutputPercent.toStringAsFixed(0)
                            : '—',
                        '%',
                      ),
                    ],
                  ),
                ),

                // 2. Load Card (5 items in a row + Source + Switch)
                SliverToBoxAdapter(
                  child: MetricCard(
                    title:
                        'Load: ${!live.controllerConnected
                            ? "Unavailable"
                            : loadOn
                            ? "ON"
                            : "OFF"}',
                    icon: Icons.lightbulb_rounded,
                    accentColor: SolarTheme.loadPurple,
                    badgeText: 'Source: ${live.loadSource}',
                    badgeColor: SolarTheme.loadPurple,
                    items: [
                      MetricItem(
                        'Voltage',
                        live.controllerConnected
                            ? live.loadVoltage.toStringAsFixed(1)
                            : '—',
                        'V',
                      ),
                      MetricItem(
                        'Current',
                        live.controllerConnected
                            ? live.loadCurrent.toStringAsFixed(2)
                            : '—',
                        'A',
                      ),
                      MetricItem(
                        'Power',
                        live.controllerConnected
                            ? live.loadPower.toStringAsFixed(0)
                            : '—',
                        'W',
                      ),
                      MetricItem(
                        'Panel',
                        live.loadFromPanelPower > 0.1
                            ? live.loadFromPanelPower.toStringAsFixed(0)
                            : '—',
                        live.loadFromPanelPower > 0.1 ? 'W' : '',
                      ),
                      MetricItem(
                        'Battery',
                        live.loadFromBatteryPower > 0.1
                            ? live.loadFromBatteryPower.toStringAsFixed(0)
                            : '—',
                        live.loadFromBatteryPower > 0.1 ? 'W' : '',
                      ),
                    ],
                  ),
                ),

                // 3. Battery Status Card (3 items in a row + Uptime + Estimate)
                SliverToBoxAdapter(
                  child: MetricCard(
                    title: 'Battery Status: $batteryStatus',
                    icon: Icons.battery_charging_full_rounded,
                    accentColor: isCharging
                        ? SolarTheme.batteryGreen
                        : (isDischarging
                              ? SolarTheme.batteryDischarging
                              : SolarTheme.infoCyan),
                    // BMS uptime exists only in Controller + BMS Mode.
                    badgeText: controllerOnly
                        ? null
                        : 'Uptime: ${live.batteryLoading ? 'Loading' : live.formattedUptime}',
                    badgeColor: const Color(0xFF38BDF8),
                    items: [
                      MetricItem(
                        'Voltage',
                        live.batteryLoading
                            ? 'Loading'
                            : (live.controllerConnected || live.bmsConnected)
                            ? live.batteryVoltage.toStringAsFixed(2)
                            : '—',
                        'V',
                      ),
                      MetricItem(
                        controllerOnly
                            ? 'Net Current (Calculated)'
                            : 'Net Current',
                        batteryValue(
                          '${live.batteryCurrent > 0 ? "+" : ""}${live.batteryCurrent.toStringAsFixed(2)}',
                        ),
                        'A',
                      ),
                      MetricItem(
                        controllerOnly ? 'Power (calculated)' : 'Power',
                        batteryValue(live.batteryPower.toStringAsFixed(0)),
                        'W',
                      ),
                    ],
                    extraContent: Container(
                      padding: const EdgeInsets.only(top: 10),
                      decoration: const BoxDecoration(
                        border: Border(
                          top: BorderSide(color: Color(0xFF242A42), width: 1),
                        ),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            estimateLabel,
                            style: const TextStyle(
                              fontSize: 11.5,
                              color: Color(0xFFA0ADC4),
                            ),
                          ),
                          Text(
                            live.batteryLoading
                                ? 'Loading'
                                : estimateHours != null
                                ? _formatDuration(estimateHours)
                                : '—',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                              color: isCharging
                                  ? SolarTheme.batteryGreen
                                  : SolarTheme.solarAmber,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),

                // 4. Battery Overview & SOC Gauge (With Cell Voltages Integrated)
                SliverToBoxAdapter(
                  child: BatteryRingGauge(
                    live: live,
                    isBmsActive: provider.isBmsActive,
                  ),
                ),

                // 5. Today's Energy Section (4 Event Cards + 2 Metrics + Load Share Bar)
                SliverToBoxAdapter(
                  child: EnergySummaryCard(
                    summary: summary,
                    todayKey: config.reportingDayKey(),
                  ),
                ),

                const SliverToBoxAdapter(child: SizedBox(height: 36)),
              ],
            ),
          ),
        );
      },
    );
  }
}
