class LiveTelemetry {
  final bool connected;
  final bool controllerConnected;
  final DateTime? controllerUpdatedAt, bmsUpdatedAt;
  final double? bmsCellDifferenceV;
  final bool cellDifferenceCalculated;
  final DateTime? timestamp;

  // Solar Panel
  final double panelVoltage;
  final double panelCurrent;
  final double panelPower;
  final double? panelOutputPercent;

  // Controller
  final double controllerAmpGain;
  final String chargingMode; // "MPPT", "Absorption", "Float", "Off", etc.

  // Battery: BMS values in Controller + BMS Mode, calculated values in Only
  // Controller Mode ('controller' / 'controller_bms').
  final String batteryMode;
  final bool batteryCalculated;
  // Controller + BMS Mode while no fresh BMS data exists: show "Loading".
  final bool batteryLoading;
  // False when the battery current is not available (shown as "—").
  final bool batteryCurrentKnown;
  // False when SOC, remaining and capacity are not available.
  final bool batteryCapacityKnown;
  // SOC is available (BMS, or the controller's own SOC in Only Controller Mode).
  final bool batterySocKnown;
  final double batteryVoltage;
  final double batteryCurrent; // positive = charging, negative = discharging
  final double batteryPower;
  final String batteryDirection; // 'charging', 'discharging', 'idle'
  final double batteryChargeCurrent;
  final double batteryChargePower;
  final double soc; // %
  final double batteryRemainingAh;
  final double batteryCapacityAh;

  // Load
  final double loadVoltage;
  final double loadCurrent;
  final double loadPower;
  final double loadFromPanelPower;
  final double loadFromBatteryPower;
  final String loadSource; // 'Panel', 'Battery', 'Panel + Battery', '—'
  // Controller + BMS Mode, firmware 1.1.36+: the gateway scales the
  // controller's load reading by a ratio learned against the BMS at night.
  // null when the gateway does not report it.
  final bool? loadCalLearned;
  final double? loadCalRatio;
  final double? loadRawPower;
  final bool isLoadSwitchOn;

  // Controller device temperature. The controller's 0x0103 "battery"
  // temperature is also a device reading and is never shown as battery data.
  final double controllerTemperature;
  // Active SRNE fault/warning names (0x0121/0x0122) and the model check.
  final List<String> controllerFaults;
  final String controllerModelReported;
  // Why the controller is not connected, straight from the gateway's
  // heartbeat: it only used to reach a command result or the diagnostics
  // report, so a reconnect failing on its own said nothing at all. Empty
  // while the controller reads.
  final String controllerVerdict;
  final bool controllerLocked;
  final bool? controllerModelMatch;
  // Battery type the controller itself is set to (E004), e.g. 'LITHIUM'.
  final String controllerBatteryProfile;
  // Battery mode the gateway has saved ('' until it reports one).
  final String gatewayBatteryMode;
  // Controller link the gateway uses ('ble', 'rs485'; '' until reported).
  final String gatewayControllerLink;

  // BMS Specific
  final bool bmsConnected;
  final double? bmsTemperature;
  final String bmsBalancingStatus; // 'off', 'charging', 'discharging'
  final double bmsBalancingCurrent;
  final List<double> bmsCellVoltages;
  final int? bmsCycleCount;
  final int? bmsUptimeSeconds;
  // Gateway's BMS decoder: 'jk02_24', 'jk02_32', 'jbd' (or 'auto' before
  // the first reading). JBD reports no balancing current.
  final String bmsProfile;
  bool get bmsIsJbd => bmsProfile == 'jbd';

  // Source Metadata
  final String dataSource; // 'hybrid', 'controller_only', 'none'
  final String? error;
  final String esp32FirmwareVersion;
  // Gateway heartbeat (independent of controller/BMS) and its chip family.
  final bool gatewayOnline;
  final String chipFamily;

  LiveTelemetry({
    this.connected = false,
    this.controllerConnected = false,
    this.controllerUpdatedAt,
    this.bmsUpdatedAt,
    this.bmsCellDifferenceV,
    this.cellDifferenceCalculated = false,
    this.timestamp,
    this.panelVoltage = 0.0,
    this.panelCurrent = 0.0,
    this.panelPower = 0.0,
    this.panelOutputPercent,
    this.controllerAmpGain = 0.0,
    this.chargingMode = 'Off',
    this.batteryMode = '',
    this.batteryCalculated = false,
    this.batteryLoading = false,
    this.batteryCurrentKnown = false,
    this.batteryCapacityKnown = false,
    this.batterySocKnown = false,
    this.batteryVoltage = 0.0,
    this.batteryCurrent = 0.0,
    this.batteryPower = 0.0,
    this.batteryDirection = 'idle',
    this.batteryChargeCurrent = 0.0,
    this.batteryChargePower = 0.0,
    this.soc = 0.0,
    this.batteryRemainingAh = 0.0,
    this.batteryCapacityAh = 0.0,
    this.loadVoltage = 0.0,
    this.loadCurrent = 0.0,
    this.loadPower = 0.0,
    this.loadFromPanelPower = 0.0,
    this.loadFromBatteryPower = 0.0,
    this.loadSource = '—',
    this.loadCalLearned,
    this.loadCalRatio,
    this.loadRawPower,
    this.isLoadSwitchOn = false,
    this.controllerTemperature = 0.0,
    this.controllerFaults = const [],
    this.controllerModelReported = '',
    this.controllerVerdict = '',
    this.controllerLocked = false,
    this.controllerModelMatch,
    this.controllerBatteryProfile = '',
    this.gatewayBatteryMode = '',
    this.gatewayControllerLink = '',
    this.bmsConnected = false,
    this.bmsTemperature,
    this.bmsBalancingStatus = 'off',
    this.bmsBalancingCurrent = 0.0,
    this.bmsCellVoltages = const [],
    this.bmsCycleCount,
    this.bmsUptimeSeconds,
    this.bmsProfile = '',
    this.dataSource = 'none',
    this.error,
    this.esp32FirmwareVersion = 'unknown',
    this.gatewayOnline = false,
    this.chipFamily = '',
  });

  factory LiveTelemetry.empty() => LiveTelemetry();

  String get formattedUptime {
    if (bmsUptimeSeconds == null || bmsUptimeSeconds! <= 0) return '—';
    final total = bmsUptimeSeconds!;
    final days = total ~/ 86400;
    final hours = (total % 86400) ~/ 3600;
    final minutes = (total % 3600) ~/ 60;
    return '${days}d ${hours}h ${minutes}m';
  }

  factory LiveTelemetry.fromFirebaseJson(
    Map<String, dynamic> json, {
    required bool isBmsEnabled,
    // The app's chosen mode; the gateway's reported mode takes precedence.
    String batteryMode = '',
    // Phone-monotonic time since the device timestamp last advanced; null
    // until it has been seen advancing (then the wall-clock check applies).
    int? controllerAgeMs,
    int? bmsAgeMs,
    int? gatewayAgeMs,
  }) {
    int readTime(dynamic value) => value is num
        ? value.toInt()
        : DateTime.tryParse(value?.toString() ?? '')?.millisecondsSinceEpoch ??
              0;
    // Data counts as current for 30 s: Firebase uploads from the gateway can
    // take a few seconds each, so 10 s showed working devices as offline.
    bool fresh(int value, int now, int? ageMs) => ageMs != null
        ? value > 0 && ageMs <= 30000
        : value > 0 && now - value >= -5000 && now - value <= 30000;
    final int clock = DateTime.now().millisecondsSinceEpoch;
    final int ctrlAt = readTime(json['controller_updated_at']);
    final int bmsAt = readTime(json['bms_updated_at']);
    final bool ctrlFresh =
        json['controller_connected'] == true &&
        fresh(ctrlAt, clock, controllerAgeMs);
    bool validNumber(String key) =>
        json[key] is num && (json[key] as num).isFinite;
    final bool jkFresh =
        isBmsEnabled &&
        json['bms_connected'] == true &&
        fresh(bmsAt, clock, bmsAgeMs) &&
        validNumber('bms_battery_voltage') &&
        validNumber('bms_battery_current') &&
        validNumber('bms_soc') &&
        validNumber('bms_nominal_capacity_ah') &&
        (json['bms_nominal_capacity_ah'] as num) > 0;
    final bool isOnline = ctrlFresh || jkFresh;
    final bool gwFresh = fresh(
      readTime(json['gateway_updated_at']),
      clock,
      gatewayAgeMs,
    );

    // Solar Panel
    final double pvV = (json['panel_voltage'] as num?)?.toDouble() ?? 0.0;
    final double pvA = (json['panel_current'] as num?)?.toDouble() ?? 0.0;
    final double pvW = (json['panel_power'] as num?)?.toDouble() ?? 0.0;
    // Calculated by the gateway from the saved panel rating.
    final double? outputPct = ctrlFresh && validNumber('panel_output_pct')
        ? (json['panel_output_pct'] as num).toDouble()
        : null;

    // Load
    final double loadV = (json['load_voltage'] as num?)?.toDouble() ?? 0.0;
    final double rawLoadA = (json['load_current'] as num?)?.toDouble() ?? 0.0;
    final double rawLoadW = (json['load_power'] as num?)?.toDouble() ?? 0.0;
    final bool loadSwitch = ctrlFresh && json['load_switch'] == true;

    // Controller baseline values
    final double ctrlBatV =
        (json['battery_voltage'] as num?)?.toDouble() ?? 0.0;
    final double ctrlChargeA =
        (json['battery_charge_current'] as num?)?.toDouble() ?? 0.0;
    final String mode = json['charging_mode']?.toString() ?? 'Off';
    final double ampGain = (ctrlChargeA > pvA && pvA > 0)
        ? (ctrlChargeA - pvA)
        : 0.0;

    // BMS values & Strict Freshness Check
    final bool bmsConnected = json['bms_connected'] == true;
    final int bmsUpdatedAt = bmsAt;
    final bool bmsFresh = jkFresh && bmsConnected && bmsUpdatedAt > 0;
    final bool bmsActive = isBmsEnabled && bmsFresh;

    final String reportedMode = json['battery_mode']?.toString() ?? '';
    final String batteryModeNow =
        reportedMode == 'controller' || reportedMode == 'controller_bms'
        ? reportedMode
        : (batteryMode == 'controller' || batteryMode == 'controller_bms'
              ? batteryMode
              : (isBmsEnabled ? 'controller_bms' : 'controller'));
    final bool controllerOnly = batteryModeNow == 'controller';

    double finalBatV = 0.0;
    double finalBatA = 0.0;
    double finalSoc = 0.0;
    double finalRemainingAh = 0.0;
    double finalCapacityAh = 0.0;
    bool currentKnown = false, capacityKnown = false, loading = false;
    bool socKnown = false;

    if (controllerOnly) {
      // Only Controller Mode: values calculated by the gateway from
      // 0x0102 - 0x0105 (all loads on the controller's Load terminal).
      if (ctrlFresh) {
        finalBatV = ctrlBatV;
        currentKnown = validNumber('battery_calc_current');
        finalBatA = currentKnown
            ? (json['battery_calc_current'] as num).toDouble()
            : 0.0;
        // The gateway counts remaining Ah from the same load terminal the net
        // current above comes from, so the two move together and the time
        // estimate built from them holds. It only has that count once a
        // battery type and capacity are saved, and the app does not repeat
        // the arithmetic: it reads the result.
        final bool calcKnown =
            validNumber('battery_calc_soc') &&
            validNumber('battery_calc_remaining_ah') &&
            validNumber('battery_calc_capacity_ah') &&
            (json['battery_calc_capacity_ah'] as num) > 0;
        if (calcKnown) {
          finalSoc = (json['battery_calc_soc'] as num).toDouble().clamp(
            0.0,
            100.0,
          );
          finalRemainingAh = (json['battery_calc_remaining_ah'] as num)
              .toDouble();
          finalCapacityAh = (json['battery_calc_capacity_ah'] as num)
              .toDouble();
          socKnown = true;
          capacityKnown = true;
        } else {
          // Nothing saved to count against: the controller's own SOC (0x0100)
          // stands in, as on its display, rather than no battery reading at
          // all. Remaining Ah needs a capacity from somewhere, so without one
          // it stays unknown and no time estimate is offered.
          socKnown = validNumber('soc');
          if (socKnown) {
            finalSoc = (json['soc'] as num).toDouble().clamp(0.0, 100.0);
          }
          final double savedCapacity = validNumber('battery_capacity_ah')
              ? (json['battery_capacity_ah'] as num).toDouble()
              : 0.0;
          capacityKnown = socKnown && savedCapacity > 0;
          if (capacityKnown) {
            finalCapacityAh = savedCapacity;
            finalRemainingAh = savedCapacity * finalSoc / 100.0;
          }
        }
      }
    } else if (bmsActive) {
      // Controller + BMS Mode: the BMS is the only battery source.
      finalBatV = (json['bms_battery_voltage'] as num).toDouble();
      finalBatA = (json['bms_battery_current'] as num).toDouble();
      finalSoc = (json['bms_soc'] as num).toDouble();
      finalRemainingAh =
          (json['bms_remaining_capacity_ah'] as num?)?.toDouble() ?? 0.0;
      finalCapacityAh = (json['bms_nominal_capacity_ah'] as num).toDouble();
      currentKnown = capacityKnown = socKnown = true;
    } else {
      // No fresh BMS data: never fall back to controller battery values.
      loading = true;
    }
    final String finalDirection = !currentKnown
        ? 'unknown'
        : finalBatA > 0.05
        ? 'charging'
        : (finalBatA < -0.05 ? 'discharging' : 'idle');

    final double finalBatW = finalBatV * finalBatA;

    // What runs the load has to add up to the load. The panel covers as much
    // of it as its own output allows (nothing below 1 W) and the battery
    // covers the rest, both read from the controller in the same sample.
    // Taking the battery's share from the BMS instead made the two fall short
    // whenever the meters disagreed, and the card then showed a load larger
    // than everything feeding it. The gap between the meters is still worth
    // knowing, so the gateway publishes it as battery_meter_gap_w rather than
    // letting it vanish inside this split.
    final bool sharesKnown = ctrlFresh;
    // Controller + BMS Mode: a load cannot take more than the panel and the
    // battery give it: panel + battery discharge, or panel - battery charge
    // when the panel has a surplus (less is losses). Firmware 1.1.36 corrects the
    // controller's load meter against the BMS itself; for an older gateway the
    // load is held to that supply when both readings come from the same
    // moment, so the card never shows 35.6 W running from a 34 W discharge.
    double loadW = rawLoadW, loadA = rawLoadA;
    final double panelSupplyW = pvW >= 1.0 ? pvW : 0.0;
    final double supplyW = panelSupplyW - finalBatW < 0
        ? 0.0
        : panelSupplyW - finalBatW;
    if (!controllerOnly &&
        ctrlFresh &&
        bmsActive &&
        (ctrlAt - bmsAt).abs() <= 3000 &&
        loadW > supplyW) {
      if (loadW > 0) loadA = loadA * supplyW / loadW;
      loadW = supplyW;
    }
    final double loadNow = loadW < 0 ? 0.0 : loadW;
    final double panelAvailable = pvW >= 1.0 ? pvW : 0.0;
    final double panelToLoad = sharesKnown
        ? (panelAvailable < loadNow ? panelAvailable : loadNow)
        : 0;
    final double batteryToLoad = sharesKnown ? loadNow - panelToLoad : 0;
    // No load running: there is no source to name.
    String sourceLabel = !sharesKnown
        ? 'Unknown'
        : loadW < 1.0
        ? '—'
        // Only the source; how it is derived is explained in the documentation.
        : (batteryToLoad > 0.5
              ? (panelToLoad > 0.5 ? 'Panel + Battery' : 'Battery')
              : 'Panel');

    // BMS cell voltages
    List<double> cells = [];
    if (bmsActive && json['bms_cell_voltages'] is List) {
      cells = (json['bms_cell_voltages'] as List)
          .map((v) => (v as num).toDouble())
          .where((v) => v > 0.5)
          .toList();
    }

    DateTime? stamp;
    if (json['timestamp'] != null) {
      if (json['timestamp'] is num) {
        stamp = DateTime.fromMillisecondsSinceEpoch(
          (json['timestamp'] as num).toInt(),
        );
      } else {
        stamp = DateTime.tryParse(json['timestamp'].toString());
      }
    }

    return LiveTelemetry(
      // The gateway is "connected" while its own cloud heartbeat is fresh,
      // even with no BLE device enabled. Missing controller/BMS data shows as
      // its own per-device alert, not as the whole gateway being offline.
      connected: gwFresh || isOnline,
      controllerConnected: ctrlFresh,
      controllerUpdatedAt: ctrlAt > 0
          ? DateTime.fromMillisecondsSinceEpoch(ctrlAt)
          : null,
      bmsUpdatedAt: bmsAt > 0
          ? DateTime.fromMillisecondsSinceEpoch(bmsAt)
          : null,
      bmsCellDifferenceV: bmsActive
          ? (json['bms_cell_difference_v'] as num?)?.toDouble()
          : null,
      cellDifferenceCalculated:
          bmsActive && json['bms_cell_difference_source'] == 'calculated',
      timestamp: stamp,
      panelVoltage: pvV,
      panelCurrent: pvA,
      panelPower: pvW,
      panelOutputPercent: outputPct,
      controllerAmpGain: ampGain,
      chargingMode: mode,
      batteryMode: batteryModeNow,
      batteryCalculated: controllerOnly,
      batteryLoading: loading,
      batteryCurrentKnown: currentKnown,
      batteryCapacityKnown: capacityKnown,
      batterySocKnown: socKnown,
      batteryVoltage: finalBatV,
      batteryCurrent: finalBatA,
      batteryPower: finalBatW,
      batteryDirection: finalDirection,
      batteryChargeCurrent: ctrlChargeA,
      batteryChargePower: ctrlBatV * ctrlChargeA,
      soc: finalSoc.clamp(0.0, 100.0),
      batteryRemainingAh: finalRemainingAh,
      batteryCapacityAh: finalCapacityAh,
      loadVoltage: loadV,
      loadCurrent: loadA,
      loadPower: loadW,
      loadFromPanelPower: panelToLoad,
      loadFromBatteryPower: batteryToLoad,
      loadSource: sourceLabel,
      loadCalLearned: json['load_cal_learned'] is bool
          ? json['load_cal_learned'] as bool
          : null,
      loadCalRatio: validNumber('load_cal_ratio')
          ? (json['load_cal_ratio'] as num).toDouble()
          : null,
      loadRawPower: validNumber('load_power_raw')
          ? (json['load_power_raw'] as num).toDouble()
          : null,
      isLoadSwitchOn: loadSwitch,
      controllerTemperature:
          (json['controller_temperature'] as num?)?.toDouble() ?? 0.0,
      controllerFaults: ctrlFresh && json['controller_faults'] is List
          ? (json['controller_faults'] as List)
                .map((f) => f.toString())
                .toList()
          : const [],
      controllerModelReported:
          json['controller_model_reported']?.toString() ?? '',
      controllerVerdict: json['controller_verdict']?.toString() ?? '',
      controllerLocked: json['controller_locked'] == true,
      controllerModelMatch: json['controller_model_match'] is bool
          ? json['controller_model_match'] as bool
          : null,
      controllerBatteryProfile: json['controller_settings'] is Map
          ? (json['controller_settings'] as Map)['battery_profile']
                    ?.toString() ??
                ''
          : '',
      gatewayBatteryMode: reportedMode,
      gatewayControllerLink: json['controller_link']?.toString() ?? '',
      bmsConnected: bmsActive,
      // The highest battery sensor, as the JK app's "High Temp" (MOS excluded).
      bmsTemperature: bmsActive
          ? [
                  json['bms_sensor1_temperature'],
                  json['bms_sensor2_temperature'],
                  json['bms_temperature'],
                ]
                .whereType<num>()
                .map((t) => t.toDouble())
                .fold<double?>(
                  null,
                  (high, t) => high == null || t > high ? t : high,
                )
          : null,
      bmsBalancingStatus: bmsActive
          ? json['bms_balancing_status']?.toString() ?? 'off'
          : 'off',
      bmsBalancingCurrent: bmsActive
          ? (json['bms_balancing_current'] as num?)?.toDouble() ?? 0.0
          : 0.0,
      bmsCellVoltages: cells,
      bmsCycleCount: bmsActive
          ? (json['bms_cycle_count'] as num?)?.toInt()
          : null,
      bmsUptimeSeconds: bmsActive
          ? (json['bms_uptime_seconds'] as num?)?.toInt()
          : null,
      bmsProfile: bmsActive ? json['bms_profile']?.toString() ?? '' : '',
      dataSource: bmsActive
          ? (ctrlFresh ? 'hybrid' : 'bms_only')
          : (ctrlFresh ? 'controller_only' : 'none'),
      error: json['error']?.toString(),
      esp32FirmwareVersion:
          json['esp32_firmware_version']?.toString() ?? 'unknown',
      gatewayOnline: gwFresh,
      chipFamily: json['chip_family']?.toString() ?? '',
    );
  }
}
