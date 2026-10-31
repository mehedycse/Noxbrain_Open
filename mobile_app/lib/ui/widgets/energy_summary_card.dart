import 'package:flutter/material.dart';

import '../theme.dart';
import '../../models/energy_summary.dart';

class EnergySummaryCard extends StatelessWidget {
  final EnergySummary summary;

  /// Today's reporting day (yyyy-MM-dd) from the phone's clock. A summary of
  /// another day is labelled with its date instead of "Today".
  final String todayKey;

  const EnergySummaryCard({
    super.key,
    required this.summary,
    required this.todayKey,
  });

  @override
  Widget build(BuildContext context) {
    // The gateway keeps its reporting day until its next reset, so a day at
    // or after the phone's is current, never "old data".
    final bool isToday =
        summary.day.isNotEmpty && summary.day.compareTo(todayKey) >= 0;
    // Load Used and the sharing bar use the same period (PV ON → reset).
    final double totalLoad =
        summary.cardLoadWh > 0 ? summary.cardLoadWh : 0.001;
    final double pvPercent = summary.cardSplitAvailable
        ? ((summary.cardLoadFromPanelWh / totalLoad) * 100).clamp(0.0, 100.0)
        : 0.0;
    final double batPercent = summary.cardSplitAvailable
        ? ((summary.cardLoadFromBatteryWh / totalLoad) * 100).clamp(0.0, 100.0)
        : 0.0;
    final double unallocatedWh =
        summary.cardSplitAvailable ? summary.cardUnallocatedWh : 0.0;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: SolarTheme.surface,
        borderRadius: BorderRadius.circular(18),
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
                  const Text('⚡', style: TextStyle(fontSize: 14)),
                  const SizedBox(width: 6),
                  Text(
                    isToday
                        ? 'Today’s Energy'
                        : summary.day.isEmpty
                        ? 'Energy · no data for today'
                        : 'Energy · ${summary.day} (old data)',
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: SolarTheme.textPrimary,
                    ),
                  ),
                ],
              ),
              if (isToday)
                const Text(
                  'LIVE ACCUMULATION',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: SolarTheme.solarAmber,
                  ),
                ),
            ],
          ),

          const SizedBox(height: 14),

          // 6 Energy Cards in 2 Rows (3 per row)
          // Row 1: PV Power ON, PV Power OFF, Full Charge At
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: _buildEventCard(
                    title: 'PV Power ON',
                    mainText: summary.pvOnTime.isNotEmpty
                        ? summary.pvOnTime
                        : '—',
                    subText: summary.pvOnBatterySoc != null
                        ? '${summary.pvOnBatterySoc!.toStringAsFixed(0)}% · ${summary.pvOnBatteryRemainingAh?.toStringAsFixed(1) ?? "—"} Ah'
                        : null,
                    color: SolarTheme.solarAmber,
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: _buildEventCard(
                    title: 'PV Power OFF',
                    mainText: summary.pvOffTime.isNotEmpty
                        ? summary.pvOffTime
                        : '—',
                    subText: summary.pvOffBatterySoc != null
                        ? '${summary.pvOffBatterySoc!.toStringAsFixed(0)}% · ${summary.pvOffBatteryRemainingAh?.toStringAsFixed(1) ?? "—"} Ah'
                        : null,
                    color: SolarTheme.infoCyan,
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: _buildEventCard(
                    title: 'Full Charge At',
                    mainText: summary.lastFullChargeAt?.isNotEmpty == true
                        ? summary.lastFullChargeAt!
                        : '—',
                    subText: summary.lastFullChargeSoc != null
                        ? '${summary.lastFullChargeSoc!.toStringAsFixed(0)}% · ${summary.lastFullChargeAh?.toStringAsFixed(1) ?? "—"} Ah'
                        : null,
                    color: SolarTheme.batteryGreen,
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 8),

          // Row 2: Panel input, Battery in, Load used
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: _buildEventCard(
                    title: 'Panel Input',
                    mainText: summary.panelAvailable
                        ? '${summary.panelWh.toStringAsFixed(1)} Wh'
                        : '—',
                    color: SolarTheme.solarAmber,
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: _buildEventCard(
                    title: summary.batteryCalculated
                        ? 'Battery in (calculated)'
                        : 'Battery in',
                    mainText: summary.batteryChargeAvailable
                        ? '${summary.batteryChargeWh.toStringAsFixed(1)} Wh'
                        : '—',
                    color: SolarTheme.batteryGreen,
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: _buildEventCard(
                    title: 'Load Used',
                    mainText: summary.cardLoadAvailable
                        ? '${summary.cardLoadWh.toStringAsFixed(1)} Wh'
                        : '—',
                    color: SolarTheme.loadPurple,
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 14),

          // Load Sharing Breakdown
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: SolarTheme.surfaceLight,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Estimated Load Source Sharing',
                  style: TextStyle(
                    fontSize: 11,
                    color: SolarTheme.textSecondary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: Row(
                    children: [
                      if (pvPercent > 0)
                        Expanded(
                          flex: pvPercent.round().clamp(1, 100),
                          child: Container(
                            height: 8,
                            color: SolarTheme.solarAmber,
                          ),
                        ),
                      if (batPercent > 0)
                        Expanded(
                          flex: batPercent.round().clamp(1, 100),
                          child: Container(
                            height: 8,
                            color: SolarTheme.loadPurple,
                          ),
                        ),
                      if (unallocatedWh > 0)
                        Expanded(
                          flex: ((unallocatedWh / totalLoad) * 100)
                              .round()
                              .clamp(1, 100),
                          child: Container(height: 8, color: SolarTheme.border),
                        ),
                      if (pvPercent == 0 &&
                          batPercent == 0 &&
                          unallocatedWh == 0)
                        Expanded(
                          child: Container(height: 8, color: SolarTheme.border),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: const BoxDecoration(
                            color: SolarTheme.solarAmber,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          summary.cardSplitAvailable
                              ? 'PV: ${summary.cardLoadFromPanelWh.toStringAsFixed(1)} Wh (${pvPercent.toStringAsFixed(0)}%)'
                              : 'PV: —',
                          style: const TextStyle(
                            fontSize: 11,
                            color: SolarTheme.textSecondary,
                          ),
                        ),
                      ],
                    ),
                    Row(
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: const BoxDecoration(
                            color: SolarTheme.loadPurple,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          summary.cardSplitAvailable
                              ? 'Battery: ${summary.cardLoadFromBatteryWh.toStringAsFixed(1)} Wh (${batPercent.toStringAsFixed(0)}%)'
                              : 'Battery: —',
                          style: const TextStyle(
                            fontSize: 11,
                            color: SolarTheme.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMiniBatteryIcon({Color color = const Color(0xFF8693AB)}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          width: 10.5,
          height: 6,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(1.5),
            border: Border.all(color: color, width: 0.8),
          ),
          padding: const EdgeInsets.all(0.7),
          alignment: Alignment.centerLeft,
          child: Container(
            width: 4.8,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(0.5),
            ),
          ),
        ),
        Container(
          width: 1.2,
          height: 2.8,
          decoration: BoxDecoration(
            color: color,
            borderRadius: const BorderRadius.only(
              topRight: Radius.circular(0.8),
              bottomRight: Radius.circular(0.8),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildEventCard({
    required String title,
    required String mainText,
    String? subText,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF101423),
        borderRadius: BorderRadius.circular(8),
      ),
      // Texts stay on one line (scaled down if needed); the row's equal
      // height is then measured from one line, not from wrapped lines.
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  title,
                  maxLines: 1,
                  softWrap: false,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 9.5,
                    color: SolarTheme.textMuted,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(height: 3),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  mainText,
                  maxLines: 1,
                  softWrap: false,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w900,
                    color: color,
                  ),
                ),
              ),
            ],
          ),
          if (subText != null) ...[
            const SizedBox(height: 3),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                _buildMiniBatteryIcon(color: const Color(0xFF8693AB)),
                const SizedBox(width: 3),
                Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      subText,
                      maxLines: 1,
                      softWrap: false,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 8.5,
                        color: Color(0xFF8693AB),
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
