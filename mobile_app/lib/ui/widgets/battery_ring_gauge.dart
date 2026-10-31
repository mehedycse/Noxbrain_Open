import 'dart:math';

import 'package:flutter/material.dart';

import '../theme.dart';
import '../../models/telemetry.dart';

class BatteryRingGauge extends StatelessWidget {
  final LiveTelemetry live;
  final bool isBmsActive;

  const BatteryRingGauge({
    super.key,
    required this.live,
    required this.isBmsActive,
  });

  @override
  Widget build(BuildContext context) {
    // Only Controller Mode shows the controller's SOC and, with a saved
    // capacity, capacity/remaining; BMS-only
    // items (cycle count, temperature, cells, balancing) are not shown at all.
    final bool controllerOnly = live.batteryCalculated;
    final bool known = live.batteryCapacityKnown;
    final bool socKnown = live.batterySocKnown;
    // Shown instead of a value that is not available right now.
    final String missing = live.batteryLoading ? 'Loading' : '—';
    final double soc = socKnown ? live.soc.clamp(0.0, 100.0) : 0.0;
    final bool isCharging = live.batteryDirection == 'charging';

    final Color ringColor = !socKnown
        ? const Color(0xFF8A99B2)
        : isCharging
        ? SolarTheme.batteryGreen
        : (soc < 20 ? SolarTheme.batteryDischarging : const Color(0xFF00E6D1));

    final cells = live.bmsCellVoltages.where((v) => v > 0.5).toList();
    final double? minCell = cells.isNotEmpty ? cells.reduce(min) : null;
    final double? maxCell = cells.isNotEmpty ? cells.reduce(max) : null;
    final int? deltaMv = live.bmsCellDifferenceV != null
        ? (live.bmsCellDifferenceV! * 1000).round()
        : null;

    // Only a live BMS reporting charging/discharging balance counts as ON.
    final bool isBalancing =
        isBmsActive &&
        (live.bmsBalancingStatus == 'charging' ||
            live.bmsBalancingStatus == 'discharging');

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: SolarTheme.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: SolarTheme.border),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.25),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'BATTERY OVERVIEW',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: SolarTheme.textSecondary,
                  letterSpacing: 0.6,
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 2.5,
                ),
                decoration: BoxDecoration(
                  color: isBmsActive
                      ? SolarTheme.batteryGreen.withOpacity(0.12)
                      : SolarTheme.solarAmber.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: isBmsActive
                        ? SolarTheme.batteryGreen.withOpacity(0.35)
                        : SolarTheme.solarAmber.withOpacity(0.35),
                  ),
                ),
                child: Text(
                  isBmsActive
                      ? (live.bmsIsJbd ? 'JBD-BMS Live' : 'JK-BMS Live')
                      : controllerOnly
                      ? 'Calculated'
                      : 'Loading',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: isBmsActive
                        ? SolarTheme.batteryGreen
                        : SolarTheme.solarAmber,
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 16),

          // Overview Top: SOC Ring + Quick Grid
          Row(
            children: [
              // SOC Ring
              SizedBox(
                width: 86,
                height: 86,
                child: CustomPaint(
                  painter: _SocRingPainter(soc: soc, color: ringColor),
                  child: Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Text(
                          'SOC',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF8A99B2),
                            letterSpacing: 0.5,
                          ),
                        ),
                        const SizedBox(height: 1),
                        Text(
                          socKnown ? '${soc.toStringAsFixed(0)}%' : missing,
                          style: TextStyle(
                            fontSize: socKnown ? 20 : 12,
                            fontWeight: FontWeight.w900,
                            color: ringColor,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

              const SizedBox(width: 16),

              // Quick Grid (Capacity, Remaining, Cycle, Temperature)
              Expanded(
                child: Column(
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: _buildQuickItem(
                            'Capacity',
                            known
                                ? '${live.batteryCapacityAh.toStringAsFixed(0)} Ah'
                                : missing,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _buildQuickItem(
                            'Remaining',
                            known
                                ? '${live.batteryRemainingAh.toStringAsFixed(1)} Ah'
                                : missing,
                          ),
                        ),
                      ],
                    ),
                    if (!controllerOnly) ...[
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: _buildQuickItem(
                              'Cycle Count',
                              live.bmsCycleCount != null
                                  ? '${live.bmsCycleCount}'
                                  : missing,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: _buildQuickItem(
                              'Temperature',
                              live.bmsTemperature != null
                                  ? '${live.bmsTemperature!.toStringAsFixed(1)} °C'
                                  : missing,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),

          // Cell Inside (if BMS cell voltages available)
          if (cells.isNotEmpty) ...[
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.only(top: 14),
              decoration: BoxDecoration(
                border: Border(
                  top: BorderSide(
                    color: Colors.white.withOpacity(0.06),
                    width: 0.8,
                  ),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Cell Information',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF00E5FF),
                      letterSpacing: 0.3,
                    ),
                  ),
                  const SizedBox(height: 10),

                  // 4 Cell Tiles in a row with subtle background gradient tint (No hard borders)
                  Row(
                    children: List.generate(4, (index) {
                      final double val = index < cells.length
                          ? cells[index]
                          : 0.0;
                      final bool isMin =
                          minCell != null &&
                          maxCell != null &&
                          minCell != maxCell &&
                          val == minCell;
                      final bool isMax =
                          minCell != null &&
                          maxCell != null &&
                          minCell != maxCell &&
                          val == maxCell;

                      return Expanded(
                        child: Container(
                          margin: EdgeInsets.only(left: index > 0 ? 6 : 0),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 7,
                          ),
                          decoration: BoxDecoration(
                            color: isMin
                                ? const Color(0xFF26141D)
                                : isMax
                                ? const Color(0xFF0E2920)
                                : const Color(0xFF101423),
                            gradient: isMin
                                ? const LinearGradient(
                                    begin: Alignment.topLeft,
                                    end: Alignment.bottomRight,
                                    colors: [
                                      Color(0xFF2D1620),
                                      Color(0xFF101423),
                                    ],
                                  )
                                : isMax
                                ? const LinearGradient(
                                    begin: Alignment.topLeft,
                                    end: Alignment.bottomRight,
                                    colors: [
                                      Color(0xFF10362A),
                                      Color(0xFF101423),
                                    ],
                                  )
                                : null,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: isMin
                                  ? const Color(0xFFFF6675).withOpacity(0.22)
                                  : isMax
                                  ? const Color(0xFF4FF0A5).withOpacity(0.22)
                                  : Colors.white.withOpacity(0.07),
                              width: 0.8,
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              Text(
                                'Cell ${index + 1}',
                                style: const TextStyle(
                                  fontSize: 9.5,
                                  color: Color(0xFF8693AB),
                                ),
                              ),
                              const SizedBox(height: 4),
                              FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text(
                                  val > 0 ? '${val.toStringAsFixed(3)} V' : '—',
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.bold,
                                    color: isMin
                                        ? const Color(0xFFFF6675)
                                        : isMax
                                        ? const Color(0xFF4FF0A5)
                                        : const Color(0xFF00E5FF),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }),
                  ),

                  const SizedBox(height: 14),

                  // Cell Footer: 4 Columns with 2-line Layout (Label on top, Value on bottom) and vertical dividers
                  Row(
                    children: [
                      // Min
                      _buildCellFooterColumn(
                        top: const Text(
                          'Min',
                          style: TextStyle(
                            fontSize: 9.5,
                            color: Color(0xFF8693AB),
                          ),
                        ),
                        bottom: Text(
                          minCell != null
                              ? '${minCell.toStringAsFixed(3)} V'
                              : '—',
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF4FF0A5),
                          ),
                        ),
                      ),
                      _buildVerticalDivider(),
                      // Max
                      _buildCellFooterColumn(
                        top: const Text(
                          'Max',
                          style: TextStyle(
                            fontSize: 9.5,
                            color: Color(0xFF8693AB),
                          ),
                        ),
                        bottom: Text(
                          maxCell != null
                              ? '${maxCell.toStringAsFixed(3)} V'
                              : '—',
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF4FF0A5),
                          ),
                        ),
                      ),
                      _buildVerticalDivider(),
                      // Delta Voltage
                      _buildCellFooterColumn(
                        top: const Text(
                          'Delta Voltage',
                          style: TextStyle(
                            fontSize: 9.5,
                            color: Color(0xFF8693AB),
                          ),
                        ),
                        bottom: Text(
                          deltaMv != null ? '$deltaMv mV' : '—',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: (deltaMv ?? 0) > 20
                                ? const Color(0xFFFF6675)
                                : const Color(0xFF4FF0A5),
                          ),
                        ),
                      ),
                      _buildVerticalDivider(),
                      // Balancer Status & Current
                      _buildCellFooterColumn(
                        top: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text(
                              'Balancer: ',
                              style: TextStyle(
                                fontSize: 9.5,
                                color: Color(0xFF8693AB),
                              ),
                            ),
                            Text(
                              isBalancing ? 'ON' : 'OFF',
                              style: TextStyle(
                                fontSize: 9.5,
                                fontWeight: FontWeight.bold,
                                color: isBalancing
                                    ? const Color(0xFF4FF0A5)
                                    : const Color(0xFF8693AB),
                              ),
                            ),
                          ],
                        ),
                        bottom: Text(
                          // JBD reports no balancing current: always "—".
                          live.bmsIsJbd
                              ? '—'
                              : live.bmsBalancingCurrent.abs() > 0.0001
                              ? '${live.bmsBalancingCurrent > 0 ? "+" : ""}${live.bmsBalancingCurrent.toStringAsFixed(3)} A'
                              : (isBalancing ? '0.000 A' : '—'),
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: isBalancing
                                ? const Color(0xFF4FF0A5)
                                : const Color(0xFF8693AB),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildCellFooterColumn({required Widget top, required Widget bottom}) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          top,
          const SizedBox(height: 3),
          FittedBox(fit: BoxFit.scaleDown, child: bottom),
        ],
      ),
    );
  }

  Widget _buildVerticalDivider() {
    return Container(
      width: 1,
      height: 22,
      margin: const EdgeInsets.symmetric(horizontal: 2),
      color: Colors.white.withOpacity(0.07),
    );
  }

  Widget _buildQuickItem(String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
      decoration: BoxDecoration(
        color: const Color(0xFF101423),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            label,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 9, color: Color(0xFF8693AB)),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.bold,
              color: SolarTheme.textPrimary,
            ),
          ),
        ],
      ),
    );
  }
}

class _SocRingPainter extends CustomPainter {
  final double soc;
  final Color color;

  _SocRingPainter({required this.soc, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 5;

    final bgPaint = Paint()
      ..color = const Color(0xFF1E253A)
      ..strokeWidth = 7
      ..style = PaintingStyle.stroke;

    canvas.drawCircle(center, radius, bgPaint);

    final sweep = 2 * pi * (soc / 100.0);
    final fgPaint = Paint()
      ..color = color
      ..strokeWidth = 7
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -pi / 2,
      sweep,
      false,
      fgPaint,
    );
  }

  @override
  bool shouldRepaint(covariant _SocRingPainter oldDelegate) =>
      oldDelegate.soc != soc || oldDelegate.color != color;
}
