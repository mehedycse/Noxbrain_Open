import 'package:flutter/material.dart';

import '../theme.dart';
import '../../models/telemetry.dart';

class PowerFlowDiagram extends StatefulWidget {
  final LiveTelemetry live;

  const PowerFlowDiagram({super.key, required this.live});

  @override
  State<PowerFlowDiagram> createState() => _PowerFlowDiagramState();
}

class _PowerFlowDiagramState extends State<PowerFlowDiagram>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    // 2.4s linear infinite matches CSS horizontalRunner 2.4s linear infinite
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final live = widget.live;
    // Panel and load readings come from the controller: shown only while
    // its data is fresh, never the last stale value.
    final bool ctrlFresh = live.controllerConnected;
    final bool solarActive = ctrlFresh && live.panelPower > 1.0;
    final bool loadActive = ctrlFresh && live.loadPower > 1.0;
    final bool isCharging = live.batteryCurrent > 0.05;
    final bool isDischarging = live.batteryCurrent < -0.05;
    final bool batteryActive = isCharging || isDischarging;
    // One split for the whole screen. Deriving the battery's share here as
    // well let the diagram and the Load card answer the same question with
    // two different numbers; both now read the single share the telemetry
    // works out, which always adds up to the load beside it.
    final double batteryShare = live.loadFromBatteryPower;
    final double flowBatteryWatts = isDischarging && batteryShare > 0
        ? -batteryShare
        : live.batteryPower;

    final String flowBatteryLabel = flowBatteryWatts.abs() > 0.5
        ? '${flowBatteryWatts > 0 ? "+" : ""}${flowBatteryWatts.toStringAsFixed(0)} W'
        : '0 W';

    final String ampGainLabel =
        '+${live.controllerAmpGain.toStringAsFixed(2)} A';

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
      decoration: BoxDecoration(
        color: SolarTheme.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: SolarTheme.border),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.3),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        children: [
          // Top Center Node: Solar Panel
          Center(
            child: SizedBox(
              width: 115,
              child: _buildNodeBox(
                icon: Icons.wb_sunny_rounded,
                label: 'SOLAR PANEL',
                // Show the wattage whenever controller data is fresh, "0 W" at
                // night included, so the box keeps its height (not flattened).
                bottomText: ctrlFresh
                    ? '${live.panelPower.toStringAsFixed(0)} W'
                    : null,
                accentColor: const Color(0xFFFFB300), // Sun / Solar Golden Amber
                isActive: solarActive,
                horizontalPadding: 8,
              ),
            ),
          ),

          // Vertical Circuit Line: Solar -> Controller (Strictly clipped between boxes)
          SizedBox(
            height: 34,
            width: 4,
            child: ClipRect(
              child: AnimatedBuilder(
                animation: _controller,
                builder: (context, child) {
                  return CustomPaint(
                    size: const Size(4, 34),
                    painter: _GlowingVerticalCircuitLinePainter(
                      progress: _controller.value,
                      isActive: solarActive,
                      color: const Color(0xFF00E6D1), // Restored original Cyan/Teal
                    ),
                  );
                },
              ),
            ),
          ),

          // Bottom Row: Battery <--- continuous line ---> Controller <--- continuous line ---> Load
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // 1. Battery Node
              Expanded(
                flex: 9,
                child: _buildNodeBox(
                  icon: Icons.battery_charging_full_rounded,
                  label: 'BATTERY',
                  accentColor: SolarTheme.batteryGreen,
                  isActive: batteryActive,
                ),
              ),

              // 2. Continuous horizontal circuit line: Battery <-> Controller with floating Watt label
              Expanded(
                flex: 9,
                child: Stack(
                  clipBehavior: Clip.none,
                  alignment: Alignment.center,
                  children: [
                    SizedBox(
                      height: 4,
                      child: ClipRect(
                        child: AnimatedBuilder(
                          animation: _controller,
                          builder: (context, child) {
                            return CustomPaint(
                              size: const Size(double.infinity, 4),
                              painter: _GlowingHorizontalCircuitLinePainter(
                                progress: _controller.value,
                                isActive: isCharging || isDischarging,
                                flowForward: isDischarging,
                                color: const Color(0xFF00E6D1),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                    if (isCharging || isDischarging)
                      Positioned(
                        top: -16,
                        child: Text(
                          flowBatteryLabel,
                          style: const TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w800,
                            color: Color(0xFF00E6D1),
                            letterSpacing: -0.2,
                          ),
                        ),
                      ),
                  ],
                ),
              ),

              // 3. Controller Node
              Expanded(
                flex: 13,
                child: _buildNodeBox(
                  icon: Icons.memory_rounded,
                  label: 'CONTROLLER',
                  bottomText: ampGainLabel,
                  accentColor: SolarTheme.infoCyan,
                  isActive: live.connected,
                  horizontalPadding: 10,
                ),
              ),

              // 4. Continuous horizontal circuit line: Controller -> Load with floating Watt label
              Expanded(
                flex: 9,
                child: Stack(
                  clipBehavior: Clip.none,
                  alignment: Alignment.center,
                  children: [
                    SizedBox(
                      height: 4,
                      child: ClipRect(
                        child: AnimatedBuilder(
                          animation: _controller,
                          builder: (context, child) {
                            return CustomPaint(
                              size: const Size(double.infinity, 4),
                              painter: _GlowingHorizontalCircuitLinePainter(
                                progress: _controller.value,
                                isActive: loadActive,
                                flowForward: true, // Always flows from controller to load
                                color: const Color(0xFF00E6D1),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                    if (loadActive)
                      Positioned(
                        top: -16,
                        child: Text(
                          '${live.loadPower.toStringAsFixed(0)} W',
                          style: const TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w800,
                            color: Color(0xFF00E6D1),
                            letterSpacing: -0.2,
                          ),
                        ),
                      ),
                  ],
                ),
              ),

              // 5. Load Node
              Expanded(
                flex: 9,
                child: _buildNodeBox(
                  icon: Icons.lightbulb_rounded,
                  label: 'LOAD',
                  accentColor: SolarTheme.loadPurple,
                  isActive: loadActive,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildNodeBox({
    required IconData icon,
    required String label,
    String? bottomText,
    required Color accentColor,
    required bool isActive,
    double horizontalPadding = 6,
  }) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: horizontalPadding, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF111424),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isActive
              ? accentColor.withOpacity(0.22)
              : const Color(0xFF262C44),
          width: 1.0,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: accentColor.withOpacity(0.15),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: accentColor.withOpacity(isActive ? 0.4 : 0.2),
              ),
            ),
            child: Icon(icon, size: 18, color: accentColor),
          ),
          const SizedBox(height: 5),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 9.0,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.5,
                color: Color(0xFF8E9BB5),
              ),
            ),
          ),
          if (bottomText != null) ...[
            const SizedBox(height: 3),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                bottomText,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: accentColor,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Horizontal glowing circuit line painter (Strictly clipped between box edges - never bleeds into nodes)
class _GlowingHorizontalCircuitLinePainter extends CustomPainter {
  final double progress;
  final bool isActive;
  final bool flowForward;
  final Color color;

  _GlowingHorizontalCircuitLinePainter({
    required this.progress,
    required this.isActive,
    required this.flowForward,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    // Strictly clip to this segment so pulse NEVER enters inside the node boxes
    canvas.clipRect(Rect.fromLTWH(0, 0, size.width, size.height));

    final double midY = size.height / 2;

    // 1. Static continuous circuit track
    final basePaint = Paint()
      ..color = const Color(0xFF262C44)
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.square;

    canvas.drawLine(Offset(0, midY), Offset(size.width, midY), basePaint);

    if (isActive) {
      // 2. Glowing Laser Beam Pulse (smooth gliding light packet)
      final double beamLength = size.width * 0.45;
      final double effectiveProgress = flowForward
          ? progress
          : (1.0 - progress);
      final double beamStart =
          (effectiveProgress * (size.width + beamLength * 2)) - beamLength;
      final double beamEnd = beamStart + beamLength;

      final Rect beamRect = Rect.fromPoints(
        Offset(beamStart, midY - 3),
        Offset(beamEnd, midY + 3),
      );

      final Shader beamShader = LinearGradient(
        colors: [
          color.withOpacity(0.0),
          color.withOpacity(0.7),
          Colors.white,
          color.withOpacity(0.7),
          color.withOpacity(0.0),
        ],
        stops: const [0.0, 0.35, 0.5, 0.65, 1.0],
      ).createShader(beamRect);

      // Outer glow pass
      final glowPaint = Paint()
        ..shader = beamShader
        ..strokeWidth = 3.5
        ..strokeCap = StrokeCap.round
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.0);

      canvas.drawLine(
        Offset(beamStart, midY),
        Offset(beamEnd, midY),
        glowPaint,
      );

      // Inner core laser pass
      final corePaint = Paint()
        ..shader = beamShader
        ..strokeWidth = 2.0
        ..strokeCap = StrokeCap.round;

      canvas.drawLine(
        Offset(beamStart, midY),
        Offset(beamEnd, midY),
        corePaint,
      );
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(
    covariant _GlowingHorizontalCircuitLinePainter oldDelegate,
  ) => true;
}

/// Vertical glowing circuit line painter (Strictly clipped between box edges - never bleeds into nodes)
class _GlowingVerticalCircuitLinePainter extends CustomPainter {
  final double progress;
  final bool isActive;
  final Color color;

  _GlowingVerticalCircuitLinePainter({
    required this.progress,
    required this.isActive,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    // Strictly clip to this segment so pulse NEVER enters inside the node boxes
    canvas.clipRect(Rect.fromLTWH(0, 0, size.width, size.height));

    final double midX = size.width / 2;

    // 1. Static continuous circuit track
    final basePaint = Paint()
      ..color = const Color(0xFF262C44)
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.square;

    canvas.drawLine(Offset(midX, 0), Offset(midX, size.height), basePaint);

    if (isActive) {
      // 2. Glowing Laser Beam Pulse (smooth gliding downwards)
      final double beamLength = size.height * 0.45;
      final double beamStart =
          (progress * (size.height + beamLength * 2)) - beamLength;
      final double beamEnd = beamStart + beamLength;

      final Rect beamRect = Rect.fromPoints(
        Offset(midX - 3, beamStart),
        Offset(midX + 3, beamEnd),
      );

      final Shader beamShader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          color.withOpacity(0.0),
          color.withOpacity(0.7),
          Colors.white,
          color.withOpacity(0.7),
          color.withOpacity(0.0),
        ],
        stops: const [0.0, 0.35, 0.5, 0.65, 1.0],
      ).createShader(beamRect);

      // Outer glow pass
      final glowPaint = Paint()
        ..shader = beamShader
        ..strokeWidth = 3.5
        ..strokeCap = StrokeCap.round
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.0);

      canvas.drawLine(
        Offset(midX, beamStart),
        Offset(midX, beamEnd),
        glowPaint,
      );

      // Inner core laser pass
      final corePaint = Paint()
        ..shader = beamShader
        ..strokeWidth = 2.0
        ..strokeCap = StrokeCap.round;

      canvas.drawLine(
        Offset(midX, beamStart),
        Offset(midX, beamEnd),
        corePaint,
      );
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(
    covariant _GlowingVerticalCircuitLinePainter oldDelegate,
  ) => true;
}
