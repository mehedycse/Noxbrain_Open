// ignore_for_file: avoid_print
// Pure Dart checks: no app build, Android device, gateway or cloud access.
import 'package:solar_monitor_app/models/telemetry.dart';
import 'package:solar_monitor_app/models/app_config.dart';
import 'package:solar_monitor_app/models/energy_summary.dart';

void main() {
  final now = DateTime.now().millisecondsSinceEpoch;
  final controller = <String, dynamic>{
    'controller_connected': true,
    'controller_updated_at': now,
    'timestamp': now,
    'battery_voltage': 13.2,
    'battery_charge_current': 3.0,
    'soc': 65,
    'panel_voltage': 18.0,
    'panel_current': 2.5,
    'panel_power': 45.0,
    'load_voltage': 13.2,
    'load_current': 1.0,
    'load_power': 13.2,
  };
  final staleBms = {
    ...controller,
    'bms_connected': true,
    'bms_updated_at': now - 60000,
    'bms_battery_voltage': 99.0,
    'bms_battery_current': 200.0,
    'bms_cell_voltages': [3.3, 3.3, 3.3, 3.3],
    'bms_remaining_capacity_ah': 999,
    'bms_temperature': 90.0,
    'bms_cycle_count': 999,
  };
  final stale = LiveTelemetry.fromFirebaseJson(staleBms, isBmsEnabled: true);
  assert(stale.controllerConnected && !stale.bmsConnected);
  // Controller + BMS Mode never falls back to controller battery values.
  assert(stale.batteryLoading && !stale.batteryCurrentKnown);
  assert(stale.batteryVoltage == 0 && stale.bmsCellVoltages.isEmpty);
  assert(stale.bmsTemperature == null && stale.bmsCycleCount == null);
  assert(stale.batteryRemainingAh == 0 && stale.batteryCapacityAh == 0);
  assert(!stale.batteryCapacityKnown && stale.bmsBalancingStatus == 'off');
  // The load split comes from the controller alone (panel first, battery the
  // rest), so a stale BMS no longer hides it: 45 W of panel covers 13.2 W.
  assert(stale.loadSource == 'Panel');
  assert(stale.loadFromPanelPower == 13.2 && stale.loadFromBatteryPower == 0);
  assert(!stale.isLoadSwitchOn);
  final battery = LiveTelemetry.fromFirebaseJson({
    ...controller,
    'controller_connected': false,
    'controller_updated_at': now - 60000,
    'bms_connected': true,
    'bms_updated_at': now,
    'bms_battery_voltage': 13.0,
    'bms_battery_current': -2.0,
    'bms_soc': 60,
    'bms_remaining_capacity_ah': 30.0,
    'bms_nominal_capacity_ah': 50.0,
    'bms_cell_difference_v': 0.008,
    'bms_cell_difference_source': 'jk',
    'bms_cell_voltages': [3.25, 3.258, 3.25, 3.25],
  }, isBmsEnabled: true);
  assert(
    battery.connected && !battery.controllerConnected && battery.bmsConnected,
  );
  assert(
    battery.batteryPower == -26.0 && battery.batteryDirection == 'discharging',
  );
  assert(
    battery.bmsCellDifferenceV == 0.008 && !battery.cellDifferenceCalculated,
  );
  assert(battery.dataSource == 'bms_only' && battery.loadSource == 'Unknown');
  final incompleteBms = LiveTelemetry.fromFirebaseJson({
    ...controller,
    'bms_connected': true,
    'bms_updated_at': now,
  }, isBmsEnabled: true);
  assert(incompleteBms.controllerConnected && !incompleteBms.bmsConnected);
  // Only Controller Mode: gateway-calculated values, labelled as calculated.
  final calculated = LiveTelemetry.fromFirebaseJson({
    ...controller,
    'battery_mode': 'controller',
    'battery_calc_current': -1.5,
    'battery_calc_valid': true,
    'battery_calc_soc': 40.0,
    'battery_calc_remaining_ah': 40.0,
    'battery_calc_capacity_ah': 100.0,
    'panel_output_pct': 30.0,
    'controller_faults': ['Load short circuit'],
  }, isBmsEnabled: false);
  assert(calculated.batteryCalculated && !calculated.batteryLoading);
  assert(calculated.batteryDirection == 'discharging');
  // With a battery type and capacity saved, SOC and remaining Ah are the
  // gateway's own count (battery_calc_*), not the controller's coarse SOC
  // register ("soc": 65 in the fixture), so they follow the current shown.
  assert(calculated.batteryCapacityKnown && calculated.soc == 40.0);
  assert(calculated.batteryRemainingAh == 40.0);
  assert(
    calculated.batteryVoltage == 13.2 && calculated.batteryCurrent == -1.5,
  );
  assert(calculated.panelOutputPercent == 30.0);
  assert(calculated.controllerFaults.length == 1);
  final noCapacity = LiveTelemetry.fromFirebaseJson({
    ...controller,
    'battery_mode': 'controller',
    'battery_calc_current': 0.5,
    'battery_calc_valid': false,
  }, isBmsEnabled: false);
  assert(noCapacity.batteryCurrentKnown && !noCapacity.batteryCapacityKnown);
  assert(noCapacity.panelOutputPercent == null);
  // Controller + BMS Mode at night: the controller's load meter reads 35.6 W
  // while the BMS gives 13.07 V x -2.62 A = -34.2 W. The load must never show
  // more than panel + battery supply (a ~1 W rounding allowance at most).
  final night = <String, dynamic>{
    ...controller,
    'battery_mode': 'controller_bms',
    'battery_charge_current': 0.0,
    'panel_voltage': 0.0,
    'panel_current': 0.0,
    'panel_power': 0.0,
    'load_voltage': 13.0,
    'bms_connected': true,
    'bms_updated_at': now,
    'bms_battery_voltage': 13.07,
    'bms_battery_current': -2.62,
    'bms_soc': 60,
    'bms_remaining_capacity_ah': 30.0,
    'bms_nominal_capacity_ah': 50.0,
  };
  bool withinSupply(LiveTelemetry t) =>
      t.loadPower <= t.panelPower + (-t.batteryPower) + 1.0 &&
      t.loadFromBatteryPower <=
          (t.batteryPower < 0 ? -t.batteryPower : 0.0) + 1.0;
  // An older gateway (raw controller load): the app holds it to the supply.
  final rawNight = LiveTelemetry.fromFirebaseJson({
    ...night,
    'load_current': 2.74,
    'load_power': 35.6,
  }, isBmsEnabled: true);
  assert(rawNight.loadSource == 'Battery' && withinSupply(rawNight));
  assert(rawNight.loadCurrent < 2.74 && rawNight.loadCalLearned == null);
  // Firmware 1.1.36 after learning 2.62 / 2.74: corrected load published.
  final learnedNight = LiveTelemetry.fromFirebaseJson({
    ...night,
    'load_current': 2.62,
    'load_power': 34.04,
    'load_current_raw': 2.74,
    'load_power_raw': 35.6,
    'load_cal_ratio': 0.9562,
    'load_cal_learned': true,
    'load_capped': false,
  }, isBmsEnabled: true);
  assert(withinSupply(learnedNight) && learnedNight.loadPower == 34.04);
  assert(
    learnedNight.loadCalLearned == true && learnedNight.loadRawPower == 35.6,
  );
  // Less than the supply is losses, and stays as reported.
  final lossy = LiveTelemetry.fromFirebaseJson({
    ...night,
    'load_current': 2.4,
    'load_power': 31.2,
  }, isBmsEnabled: true);
  assert(lossy.loadPower == 31.2 && lossy.loadCurrent == 2.4);
  // Readings from different moments are not compared (a load just switched).
  final unpaired = LiveTelemetry.fromFirebaseJson({
    ...night,
    'bms_updated_at': now - 10000,
    'load_current': 4.6,
    'load_power': 60.0,
  }, isBmsEnabled: true);
  assert(unpaired.loadPower == 60.0);
  // Only Controller Mode keeps the controller's own load reading.
  final ctrlOnlyNight = LiveTelemetry.fromFirebaseJson({
    ...night,
    'battery_mode': 'controller',
    'battery_calc_current': -2.74,
    'battery_calc_valid': false,
    'load_current': 2.74,
    'load_power': 35.6,
  }, isBmsEnabled: false);
  assert(ctrlOnlyNight.loadPower == 35.6);
  // Case 2, battery + panel together (cloudy/evening): 20 W of panel and
  // 13.07 V x -2.0 A = -26.1 W of battery give 46.1 W; a load meter reading
  // 50 W is held to that, and the battery share stays within the discharge.
  final mixed = LiveTelemetry.fromFirebaseJson({
    ...night,
    'panel_voltage': 17.0,
    'panel_current': 1.2,
    'panel_power': 20.0,
    'bms_battery_current': -2.0,
    'load_current': 3.85,
    'load_power': 50.0,
  }, isBmsEnabled: true);
  assert(mixed.loadSource == 'Panel + Battery' && withinSupply(mixed));
  assert(mixed.loadFromPanelPower == 20.0);
  assert(mixed.loadFromBatteryPower <= 26.14 + 1.0);
  // Case 2 with losses: a 44 W load below the 46.1 W supply stays as read.
  final mixedLossy = LiveTelemetry.fromFirebaseJson({
    ...night,
    'panel_power': 20.0,
    'bms_battery_current': -2.0,
    'load_current': 3.38,
    'load_power': 44.0,
  }, isBmsEnabled: true);
  assert(mixedLossy.loadPower == 44.0 && withinSupply(mixedLossy));
  // Panel surplus, battery charging: 60 W of panel, 13.07 V x 2.0 A = 26.1 W
  // into the battery, so at most 33.9 W is left for the load (not 40 W).
  final surplus = LiveTelemetry.fromFirebaseJson({
    ...night,
    'panel_power': 60.0,
    'bms_battery_current': 2.0,
    'load_current': 3.08,
    'load_power': 40.0,
  }, isBmsEnabled: true);
  assert(surplus.loadSource == 'Panel' && surplus.loadFromBatteryPower == 0);
  assert(surplus.loadPower <= 60.0 - 26.14 + 1.0);
  final surplusLossy = LiveTelemetry.fromFirebaseJson({
    ...night,
    'panel_power': 60.0,
    'bms_battery_current': 2.0,
    'load_current': 2.3,
    'load_power': 30.0,
  }, isBmsEnabled: true);
  assert(surplusLossy.loadPower == 30.0);
  final blank = AppConfig.fromJson({});
  assert(blank.batteryMode.isEmpty && blank.isControllerOnlyMode);
  assert(blank.panelRatedPowerW == 0 && blank.batteryNominalCapacityAh == 0);
  assert(!blank.smartSwitchEnabled && !blank.isBmsEnabled);
  final checkpoint = AppConfig.fromJson(
    AppConfig(setupStage: 3, setupHardwareId: 'NOX-EXAMPLE').toJson(),
  );
  assert(
    checkpoint.setupStage == 3 && checkpoint.setupHardwareId == 'NOX-EXAMPLE',
  );
  final future = LiveTelemetry.fromFirebaseJson({
    ...controller,
    'controller_updated_at': now + 3600000,
  }, isBmsEnabled: false);
  assert(!future.connected);
  final missing = LiveTelemetry.fromFirebaseJson({
    'connected': true,
  }, isBmsEnabled: false);
  assert(!missing.connected && missing.timestamp == null);
  final disabled = LiveTelemetry.fromFirebaseJson(
    staleBms,
    isBmsEnabled: false,
  );
  assert(!disabled.bmsConnected && disabled.bmsCellVoltages.isEmpty);
  final summary = EnergySummary.fromJson({
    'day': '2026-10-18',
    'load_wh': 20,
    'battery_charge_wh': null,
    'load_source_unallocated_wh': 12,
  });
  assert(!summary.batteryChargeAvailable && summary.unallocatedLoadWh == 12);
  // The card counts the whole reporting day. A gateway still sending the old
  // PV ON window (firmware 1.1.24 to 1.1.29) must not shrink it to that window.
  final legacyWindow = EnergySummary.fromJson({
    'day': '2026-10-18',
    'load_window': 'pv_on_to_reset',
    'load_wh': 20,
    'window_load_wh': 8,
    'load_source_unallocated_wh': 3,
    'window_load_unallocated_wh': 1,
  });
  assert(
    legacyWindow.cardLoadAvailable &&
        legacyWindow.cardLoadWh == 20 &&
        legacyWindow.cardUnallocatedWh == 3,
  );
  final parsed = AppConfig.parseFirebaseConfigSnippet(
    'const firebaseConfig={databaseURL:"https://example-default-rtdb.firebaseio.com",apiKey:"example-key"};',
  );
  assert(parsed?.firebaseApiKey == 'example-key');
  assert(
    AppConfig().firebaseDatabaseUrl.isEmpty &&
        AppConfig().firebaseApiKey.isEmpty,
  );
  final ids = List.generate(1000, (_) => AppConfig.generateUniqueDeviceId());
  assert(ids.toSet().length == 1000 && ids.every((id) => id.length == 28));
  print(
    'Source freshness, signed power, battery modes, load within supply, absent BMS, summary validity, config parsing and gateway identity checks passed.',
  );
}
