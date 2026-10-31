import 'package:intl/intl.dart';

/// Firmware sends event times as epoch milliseconds; shows them as local text.
String? formatEventTime(Object? value) {
  final ms = value is num
      ? value.toInt()
      : int.tryParse(value?.toString() ?? '');
  if (ms != null && ms > 0) {
    return DateFormat('d MMM, h:mm a')
        .format(DateTime.fromMillisecondsSinceEpoch(ms));
  }
  final text = value?.toString() ?? '';
  return text.isEmpty || text == 'null' ? null : text;
}

/// Time of day only ("11:26 AM"), for the Today's Energy event cards.
String? formatEventClock(Object? value) {
  final ms = value is num
      ? value.toInt()
      : int.tryParse(value?.toString() ?? '');
  if (ms != null && ms > 0) {
    return DateFormat('h:mm a').format(DateTime.fromMillisecondsSinceEpoch(ms));
  }
  return formatEventTime(value);
}

class EnergySummary {
  final String day;
  final bool batteryChargeAvailable, batteryDischargeAvailable;
  // False when no BMS interval exists: the panel/battery share is unknown.
  final bool loadSplitAvailable;
  // False when the controller produced no sample today.
  final bool panelAvailable, loadAvailable;
  final double unallocatedLoadWh, bmsCoverageSeconds;
  final double panelWh;
  final double batteryChargeWh;
  final double batteryChargeAh;
  final double batteryDischargeWh;
  final double loadWh;
  final double loadAh;
  final double loadFromPanelWh;
  final double loadFromBatteryWh;
  final double energyBalanceWh;
  // Today's Energy card (Load Used and Load Source Sharing): the whole
  // reporting day, one daily reset to the next, exactly like the history
  // and Statistics. PV ON and PV OFF are event times, not energy bounds.
  final bool cardLoadAvailable, cardSplitAvailable;
  final double cardLoadWh, cardLoadFromPanelWh, cardLoadFromBatteryWh;
  final double cardUnallocatedWh;

  final double pvWMax;
  // Gateway-calculated from the saved panel rating; null when unknown.
  final double? pvOutputMaxPct;
  // True when battery totals were calculated in Only Controller Mode.
  final bool batteryCalculated;
  final double pvVMax;
  final double pvAMax;
  final String pvOnTime;
  final String pvOffTime;
  final double? pvOnBatterySoc;
  final double? pvOnBatteryRemainingAh;
  final double? pvOffBatterySoc;
  final double? pvOffBatteryRemainingAh;
  final String? lastFullChargeAt;
  // Battery at that full charge (recorded from firmware 1.1.8 on).
  final double? lastFullChargeSoc;
  final double? lastFullChargeAh;
  // The gateway's summary as received, for tables keyed by the same fields
  // as the daily history.
  final Map<String, dynamic> raw;

  EnergySummary({
    this.day = '',
    this.batteryChargeAvailable = false,
    this.batteryDischargeAvailable = false,
    this.loadSplitAvailable = false,
    this.panelAvailable = false,
    this.loadAvailable = false,
    this.unallocatedLoadWh = 0,
    this.bmsCoverageSeconds = 0,
    this.panelWh = 0.0,
    this.batteryChargeWh = 0.0,
    this.batteryChargeAh = 0.0,
    this.batteryDischargeWh = 0.0,
    this.loadWh = 0.0,
    this.loadAh = 0.0,
    this.loadFromPanelWh = 0.0,
    this.loadFromBatteryWh = 0.0,
    this.energyBalanceWh = 0.0,
    this.cardLoadAvailable = false,
    this.cardSplitAvailable = false,
    this.cardLoadWh = 0.0,
    this.cardLoadFromPanelWh = 0.0,
    this.cardLoadFromBatteryWh = 0.0,
    this.cardUnallocatedWh = 0.0,
    this.pvWMax = 0.0,
    this.pvOutputMaxPct,
    this.batteryCalculated = false,
    this.pvVMax = 0.0,
    this.pvAMax = 0.0,
    this.pvOnTime = '',
    this.pvOffTime = '',
    this.pvOnBatterySoc,
    this.pvOnBatteryRemainingAh,
    this.pvOffBatterySoc,
    this.pvOffBatteryRemainingAh,
    this.lastFullChargeAt,
    this.lastFullChargeSoc,
    this.lastFullChargeAh,
    this.raw = const {},
  });

  factory EnergySummary.empty() => EnergySummary();

  factory EnergySummary.fromJson(Map<String, dynamic> json) {
    double? number(String key) => (json[key] as num?)?.toDouble();
    final splitAvailable =
        json['load_from_panel_wh'] is num &&
        json['load_from_battery_wh'] is num &&
        ((json['bms_coverage_seconds'] as num?) ?? 0) > 0;
    return EnergySummary(
      day: json['day']?.toString() ?? '',
      cardLoadAvailable: json['load_wh'] is num,
      cardSplitAvailable: splitAvailable,
      cardLoadWh: number('load_wh') ?? 0.0,
      cardLoadFromPanelWh: number('load_from_panel_wh') ?? 0.0,
      cardLoadFromBatteryWh: number('load_from_battery_wh') ?? 0.0,
      cardUnallocatedWh: number('load_source_unallocated_wh') ?? 0.0,
      batteryChargeAvailable: json['battery_charge_wh'] is num,
      batteryDischargeAvailable: json['battery_discharge_wh'] is num,
      loadSplitAvailable:
          json['load_from_panel_wh'] is num &&
          json['load_from_battery_wh'] is num &&
          ((json['bms_coverage_seconds'] as num?) ?? 0) > 0,
      panelAvailable: json['panel_wh'] is num,
      loadAvailable: json['load_wh'] is num,
      unallocatedLoadWh:
          (json['load_source_unallocated_wh'] as num?)?.toDouble() ?? 0,
      bmsCoverageSeconds:
          (json['bms_coverage_seconds'] as num?)?.toDouble() ?? 0,
      panelWh: (json['panel_wh'] as num?)?.toDouble() ?? 0.0,
      batteryChargeWh: (json['battery_charge_wh'] as num?)?.toDouble() ?? 0.0,
      batteryChargeAh: (json['battery_charge_ah'] as num?)?.toDouble() ?? 0.0,
      batteryDischargeWh:
          (json['battery_discharge_wh'] as num?)?.toDouble() ?? 0.0,
      loadWh: (json['load_wh'] as num?)?.toDouble() ?? 0.0,
      loadAh: (json['load_ah'] as num?)?.toDouble() ?? 0.0,
      loadFromPanelWh: (json['load_from_panel_wh'] as num?)?.toDouble() ?? 0.0,
      loadFromBatteryWh:
          (json['load_from_battery_wh'] as num?)?.toDouble() ?? 0.0,
      energyBalanceWh: (json['energy_balance_wh'] as num?)?.toDouble() ?? 0.0,
      pvWMax: (json['pv_w_max'] as num?)?.toDouble() ?? 0.0,
      pvOutputMaxPct: (json['pv_output_max_pct'] as num?)?.toDouble(),
      batteryCalculated: json['battery_data_source'] == 'calculated',
      pvVMax: (json['pv_v_max'] as num?)?.toDouble() ?? 0.0,
      pvAMax: (json['pv_a_max'] as num?)?.toDouble() ?? 0.0,
      pvOnTime: json['pv_on_time']?.toString() ?? '',
      pvOffTime: json['pv_off_time']?.toString() ?? '',
      pvOnBatterySoc: (json['pv_on_battery_soc'] as num?)?.toDouble(),
      pvOnBatteryRemainingAh: (json['pv_on_battery_remaining_ah'] as num?)
          ?.toDouble(),
      pvOffBatterySoc: (json['pv_off_battery_soc'] as num?)?.toDouble(),
      pvOffBatteryRemainingAh: (json['pv_off_battery_remaining_ah'] as num?)
          ?.toDouble(),
      raw: Map<String, dynamic>.from(json),
      // Today's full charge only: the firmware clears it at the daily reset.
      // The all-time record belongs to Statistics, never to this card.
      lastFullChargeAt: formatEventClock(json['day_full_charge_at']),
      lastFullChargeSoc: number('day_full_charge_soc'),
      lastFullChargeAh: number('day_full_charge_ah'),
    );
  }
}
