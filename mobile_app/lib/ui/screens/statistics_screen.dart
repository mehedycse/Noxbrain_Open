import 'dart:math';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';

import '../../providers/solar_provider.dart';
import '../theme.dart';

class StatisticsScreen extends StatelessWidget {
  const StatisticsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Statistics'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            onPressed: () => context.read<SolarProvider>().refreshHistory(),
          ),
        ],
      ),
      body: Consumer<SolarProvider>(
        builder: (context, provider, child) {
          final lifetime = provider.lifetime;
          final summary = provider.todaySummary;
          final history = provider.history;

          final reportDate =
              provider.config.reportingDay();
          final today = DateFormat('yyyy-MM-dd').format(reportDate);
          final yesterday = DateFormat('yyyy-MM-dd')
              .format(reportDate.subtract(const Duration(days: 1)));
          final beforeYesterday = DateFormat('yyyy-MM-dd')
              .format(reportDate.subtract(const Duration(days: 2)));

          // The gateway summary is today's when it is for today's reporting
          // day or newer (the gateway keeps its day until the next reset).
          final bool summaryIsToday =
              summary.day.isNotEmpty && summary.day.compareTo(today) >= 0;
          // Table rows: the live summary for today (history is refreshed
          // only now and then), the saved daily history for earlier days.
          final Map<String, dynamic> rows = Map.of(history);
          if (summaryIsToday) rows[today] = summary.raw;
          // Live PV values count only while the controller data is fresh.
          final live = provider.live;
          final double liveW = live.controllerConnected ? live.panelPower : 0.0;
          final double liveA = live.controllerConnected ? live.panelCurrent : 0.0;

          // Today's high and the all-time high; W and A are separate maxima.
          double todayMaxW = summaryIsToday ? summary.pvWMax : 0.0;
          double todayMaxA = summaryIsToday ? summary.pvAMax : 0.0;
          todayMaxW = max(todayMaxW, liveW);
          todayMaxA = max(todayMaxA, liveA);
          final todayHist = rows[today];
          if (todayHist is Map) {
            todayMaxW = max(todayMaxW, (todayHist['pv_w_max'] as num?)?.toDouble() ?? 0.0);
            todayMaxA = max(todayMaxA, (todayHist['pv_a_max'] as num?)?.toDouble() ?? 0.0);
          }
          double allTimeMaxW = max(lifetime.pvPowerMax, todayMaxW);
          double allTimeMaxA = max(lifetime.pvCurrentMax, todayMaxA);
          rows.forEach((_, val) {
            if (val is Map) {
              allTimeMaxW = max(allTimeMaxW, (val['pv_w_max'] as num?)?.toDouble() ?? 0.0);
              allTimeMaxA = max(allTimeMaxA, (val['pv_a_max'] as num?)?.toDouble() ?? 0.0);
            }
          });

          // Output % values are calculated by the gateway from the saved
          // panel rating; null (shown as —) wherever it has not reported one.
          double? highest(Iterable<double?> values) {
            final known = values.whereType<double>();
            return known.isEmpty ? null : known.reduce(max);
          }

          double? dayPct(dynamic day) => day is Map
              ? (day['pv_output_max_pct'] as num?)?.toDouble()
              : null;
          final double? todayOutputPct = highest([
            summaryIsToday ? summary.pvOutputMaxPct : null,
            dayPct(todayHist),
            live.controllerConnected ? live.panelOutputPercent : null,
          ]);
          final double? allTimeOutputPct = highest([
            lifetime.pvOutputMaxPct,
            todayOutputPct,
            ...rows.values.map(dayPct),
          ]);

          final days = [
            {'label': 'Today', 'key': today},
            {'label': 'Yesterday', 'key': yesterday},
            {'label': '2 Days Ago', 'key': beforeYesterday},
          ];

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              // 1. Lifetime full/empty event counts
              Row(
                children: [
                  Expanded(
                    child: _buildCountCard(
                      title: 'Observed Full Events',
                      value: '${lifetime.fullChargeCount}',
                      subtitle: 'Last full: ${lifetime.lastFullChargeAt}',
                      color: SolarTheme.batteryGreen,
                      icon: Icons.battery_charging_full_rounded,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _buildCountCard(
                      title: 'Observed Empty Events',
                      value: '${lifetime.fullDischargeCount}',
                      subtitle: '',
                      color: SolarTheme.batteryDischarging,
                      icon: Icons.battery_alert_rounded,
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 12),

              // 2. High Record Cards: All-Time High & Today High
              Row(
                children: [
                  Expanded(
                    child: _buildHighRecordCard(
                      title: 'ALL-TIME HIGH',
                      powerText: '${allTimeMaxW.toStringAsFixed(0)} W',
                      ampText: '${allTimeMaxA.toStringAsFixed(2)} A',
                      // No PV means 0 %; "—" only when PV ran but the panel
                      // rating is unknown, so a percentage cannot exist.
                      outputPctText: allTimeOutputPct != null
                          ? '${allTimeOutputPct.toStringAsFixed(0)}%'
                          : (allTimeMaxW < 1 ? '0%' : '—'),
                      color: SolarTheme.solarAmber,
                      icon: Icons.emoji_events_rounded,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _buildHighRecordCard(
                      title: 'TODAY HIGH',
                      powerText: '${todayMaxW.toStringAsFixed(0)} W',
                      ampText: '${todayMaxA.toStringAsFixed(2)} A',
                      // No PV means 0 %; "—" only when PV ran but the panel
                      // rating is unknown, so a percentage cannot exist.
                      outputPctText: todayOutputPct != null
                          ? '${todayOutputPct.toStringAsFixed(0)}%'
                          : (todayMaxW < 1 ? '0%' : '—'),
                      color: SolarTheme.infoCyan,
                      icon: Icons.today_rounded,
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 16),

              // 3. Multi-Metric Comparison Table (Identical to original site!)
              Container(
                decoration: BoxDecoration(
                  color: SolarTheme.surface,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.white.withOpacity(0.06)),
                ),
                child: Column(
                  children: [
                    // Header
                    Container(
                      padding: const EdgeInsets.only(
                        left: 12,
                        right: 6,
                        top: 12,
                        bottom: 12,
                      ),
                      decoration: const BoxDecoration(
                        color: SolarTheme.surfaceLight,
                        borderRadius: BorderRadius.only(
                          topLeft: Radius.circular(16),
                          topRight: Radius.circular(16),
                        ),
                      ),
                      child: Row(
                        children: [
                          const Expanded(
                            flex: 10,
                            child: Padding(
                              padding: EdgeInsets.only(right: 6),
                              child: Text(
                                'Metric',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  color: SolarTheme.textSecondary,
                                ),
                              ),
                            ),
                          ),
                          ...days.map(
                            (d) => Expanded(
                              flex: 5,
                              child: Container(
                                decoration: BoxDecoration(
                                  border: Border(
                                    left: BorderSide(
                                      color: Colors.white.withOpacity(0.08),
                                      width: 0.8,
                                    ),
                                  ),
                                ),
                                alignment: Alignment.center,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 2,
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.center,
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    FittedBox(
                                      fit: BoxFit.scaleDown,
                                      alignment: Alignment.center,
                                      child: Text(
                                        d['label']!,
                                        textAlign: TextAlign.center,
                                        style: const TextStyle(
                                          fontSize: 9.5,
                                          fontWeight: FontWeight.bold,
                                          color: SolarTheme.solarAmber,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(height: 1),
                                    Text(
                                      d['key']!.substring(5),
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(
                                        fontSize: 8.5,
                                        color: SolarTheme.textMuted,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),

                    // Metrics table (pure titles without redundant units; unit is in cell value)
                    _buildRow(
                      'Max PV Power',
                      'pv_w_max',
                      rows,
                      days,
                      'W',
                      highlight: true,
                    ),
                    _buildRow(
                      'Max PV Output',
                      'pv_output_max_pct',
                      rows,
                      days,
                      '%',
                    ),
                    _buildRow(
                      'Avg. PV Power',
                      'pv_w_on_avg',
                      rows,
                      days,
                      'W',
                    ),
                    _buildRow(
                      'Avg. PV Output',
                      'pv_output_avg_pct',
                      rows,
                      days,
                      '%',
                    ),
                    _buildRow(
                      'Max PV Voltage',
                      'pv_v_max',
                      rows,
                      days,
                      'V',
                    ),
                    _buildRow(
                      'Avg. PV Voltage',
                      'pv_v_avg',
                      rows,
                      days,
                      'V',
                    ),
                    _buildRow(
                      'Max PV Ampere',
                      'pv_a_max',
                      rows,
                      days,
                      'A',
                      highlight: true,
                    ),
                    _buildRow(
                      'Avg. PV Ampere',
                      'pv_a_avg',
                      rows,
                      days,
                      'A',
                    ),
                    _buildRow(
                      'Total Battery Charge',
                      'battery_charge_wh',
                      rows,
                      days,
                      'Wh',
                      highlight: true,
                    ),
                    _buildRow(
                      'Total Battery Charge',
                      'battery_charge_ah',
                      rows,
                      days,
                      'Ah',
                    ),
                    _buildRow(
                      'Max Battery Charge',
                      'charge_a_max',
                      rows,
                      days,
                      'A',
                    ),
                    _buildRow(
                      'Avg. Battery Charge',
                      'charge_a_avg',
                      rows,
                      days,
                      'A',
                    ),
                    _buildRow(
                      'Max Discharge',
                      'discharge_w_max',
                      rows,
                      days,
                      'W',
                    ),
                    _buildRow(
                      'Total Load Used',
                      'load_wh',
                      rows,
                      days,
                      'Wh',
                      highlight: true,
                    ),
                    _buildRow(
                      'Total Load Used',
                      'load_ah',
                      rows,
                      days,
                      'Ah',
                    ),
                    _buildRow(
                      'Load From Panel',
                      'load_from_panel_bms_wh',
                      rows,
                      days,
                      'Wh',
                    ),
                    _buildRow(
                      'Load From Panel',
                      'load_from_panel_ah',
                      rows,
                      days,
                      'Ah',
                    ),
                    _buildRow(
                      'Load From Battery',
                      'load_from_battery_bms_wh',
                      rows,
                      days,
                      'Wh',
                    ),
                    _buildRow(
                      'Load From Battery',
                      'load_from_battery_ah',
                      rows,
                      days,
                      'Ah',
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 24),
            ],
          );
        },
      ),
    );
  }

  Widget _buildCountCard({
    required String title,
    required String value,
    required String subtitle,
    required Color color,
    required IconData icon,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF101423),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: color),
              const SizedBox(width: 4),
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    title,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 10,
                      color: SolarTheme.textMuted,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              value,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w900,
                color: color,
              ),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 10,
              color: SolarTheme.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHighRecordCard({
    required String title,
    required String powerText,
    required String ampText,
    required String outputPctText,
    required Color color,
    required IconData icon,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF101423),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: color),
              const SizedBox(width: 4),
              Text(
                title,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 10,
                  color: color,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              powerText,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w900,
                color: color,
              ),
            ),
          ),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  'Current: $ampText',
                  style: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.bold,
                    color: SolarTheme.textSecondary,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  'PV Pwr: $outputPctText',
                  style: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.bold,
                    color: SolarTheme.textMuted,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRow(
    String label,
    String key,
    Map<String, dynamic> history,
    List<Map<String, String>> days,
    String unit, {
    bool highlight = false,
  }) {
    return Container(
      padding: const EdgeInsets.only(left: 12, right: 6, top: 9, bottom: 9),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: Colors.white.withOpacity(0.04), width: 0.8),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            flex: 10,
            child: Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: highlight ? FontWeight.bold : FontWeight.normal,
                  color: highlight
                      ? SolarTheme.solarAmber
                      : SolarTheme.textPrimary,
                ),
              ),
            ),
          ),
          ...days.map((d) {
            final dayData = history[d['key']];
            // pv_output_*_pct come from the gateway (saved panel rating).
            final dynamic rawVal = (dayData is Map)
                ? (dayData[key] ??
                      (key == 'load_from_panel_bms_wh'
                          ? dayData['load_from_panel_wh']
                          : (key == 'load_from_battery_bms_wh'
                                ? dayData['load_from_battery_wh']
                                : null)))
                : null;
            // A day with data shows 0 for what did not happen that day (no PV,
            // no charging); "—" only for a day without any data.
            final String text = rawVal is num
                ? '${rawVal.toStringAsFixed(1)} $unit'
                : (dayData is Map ? '0.0 $unit' : '—');

            return Expanded(
              flex: 5,
              child: Container(
                decoration: BoxDecoration(
                  border: Border(
                    left: BorderSide(
                      color: Colors.white.withOpacity(0.08),
                      width: 0.8,
                    ),
                  ),
                ),
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.center,
                  child: Text(
                    text,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: highlight ? FontWeight.bold : FontWeight.w600,
                      color: highlight
                          ? SolarTheme.textPrimary
                          : SolarTheme.textSecondary,
                    ),
                  ),
                ),
              ),
            );
          }),
        ],
      ),
    );
  }
}
