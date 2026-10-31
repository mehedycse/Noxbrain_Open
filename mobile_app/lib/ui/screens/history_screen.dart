import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';

import '../../providers/solar_provider.dart';
import '../theme.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  DateTime _startDate = DateTime.now().subtract(const Duration(days: 2));
  DateTime _endDate = DateTime.now();
  bool _isExporting = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Energy History & Analytics'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            onPressed: () => context.read<SolarProvider>().refreshHistory(),
          ),
        ],
      ),
      body: Consumer<SolarProvider>(
        builder: (context, provider, child) {
          final reportDate =
              provider.config.reportingDay();
          final today = DateFormat('yyyy-MM-dd').format(reportDate);
          // Today's column comes from the live summary (the saved history is
          // refreshed only now and then), earlier days from the history.
          final summary = provider.todaySummary;
          final Map<String, dynamic> history = Map.of(provider.history);
          if (summary.day.isNotEmpty && summary.day.compareTo(today) >= 0) {
            history[today] = summary.raw;
          }
          final yesterday = DateFormat('yyyy-MM-dd')
              .format(reportDate.subtract(const Duration(days: 1)));
          final beforeYesterday = DateFormat('yyyy-MM-dd')
              .format(reportDate.subtract(const Duration(days: 2)));

          final days = [
            {'label': 'Today', 'key': today},
            {'label': 'Yesterday', 'key': yesterday},
            {'label': '2 Days Ago', 'key': beforeYesterday},
          ];

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              // Export / Filter Card
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
                      'CUSTOM DATE RANGE & EXPORT',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: SolarTheme.textSecondary,
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(
                              foregroundColor: SolarTheme.textPrimary,
                              side: const BorderSide(color: SolarTheme.border),
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                            ),
                            icon: const Icon(
                              Icons.date_range_rounded,
                              size: 16,
                            ),
                            label: Text(
                              '${DateFormat('MM/dd').format(_startDate)} - ${DateFormat('MM/dd').format(_endDate)}',
                              style: const TextStyle(fontSize: 12),
                            ),
                            onPressed: () async {
                              final range = await showDateRangePicker(
                                context: context,
                                firstDate: DateTime(2024),
                                lastDate: DateTime.now(),
                                initialDateRange: DateTimeRange(
                                  start: _startDate,
                                  end: _endDate,
                                ),
                              );
                              if (range != null) {
                                setState(() {
                                  _startDate = range.start;
                                  _endDate = range.end;
                                });
                              }
                            },
                          ),
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: SolarTheme.solarAmber,
                            foregroundColor: Colors.black,
                            padding: const EdgeInsets.symmetric(
                              vertical: 12,
                              horizontal: 16,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                          icon: _isExporting
                              ? const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.black,
                                  ),
                                )
                              : const Icon(Icons.download_rounded, size: 16),
                          label: const Text(
                            'Export CSV',
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                          onPressed: _isExporting
                              ? null
                              : () async {
                                  setState(() => _isExporting = true);
                                  await provider.exportCsv(
                                    _startDate,
                                    _endDate,
                                  );
                                  setState(() => _isExporting = false);
                                },
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 16),

              // Comparison Table
              Container(
                decoration: BoxDecoration(
                  color: SolarTheme.surface,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.white.withOpacity(0.06)),
                ),
                child: Column(
                  children: [
                    // Table Header
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

                    // Rows
                    _buildRow('Panel', 'panel_wh', history, days, 'Wh'),
                    _buildRow(
                      'Battery In',
                      'battery_charge_wh',
                      history,
                      days,
                      'Wh',
                    ),
                    _buildRow(
                      'Battery In',
                      'battery_charge_ah',
                      history,
                      days,
                      'Ah',
                    ),
                    _buildRow('Total Load', 'load_wh', history, days, 'Wh'),
                    _buildRow(
                      'Load from PV',
                      'load_from_panel_wh',
                      history,
                      days,
                      'Wh',
                    ),
                    _buildRow(
                      'Load from Bat',
                      'load_from_battery_wh',
                      history,
                      days,
                      'Wh',
                    ),
                    _buildRow('Max PV Power', 'pv_w_max', history, days, 'W'),
                    _buildRow('Max PV Volt', 'pv_v_max', history, days, 'V'),
                    _buildRow('Max PV Amp', 'pv_a_max', history, days, 'A'),
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

  Widget _buildRow(
    String label,
    String key,
    Map<String, dynamic> history,
    List<Map<String, String>> days,
    String unit,
  ) {
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
                style: const TextStyle(
                  fontSize: 10.5,
                  color: SolarTheme.textPrimary,
                ),
              ),
            ),
          ),
          ...days.map((d) {
            final dayData = history[d['key']];
            final val = (dayData is Map) ? dayData[key] : null;
            // A day with data shows 0 for what did not happen that day;
            // "—" only for a day without any data.
            final String text = val is num
                ? '${val.toStringAsFixed(1)} $unit'
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
                    style: const TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w600,
                      color: SolarTheme.textSecondary,
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
