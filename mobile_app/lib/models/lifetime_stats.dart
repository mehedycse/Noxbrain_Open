import 'energy_summary.dart';

class LifetimeStats {
  final double pvPowerMax;
  final double pvCurrentMax;
  // Gateway-calculated from the saved panel rating; null when unknown.
  final double? pvOutputMaxPct;
  final int fullChargeCount;
  final int fullDischargeCount;
  final String lastFullChargeAt;

  LifetimeStats({
    this.pvPowerMax = 0.0,
    this.pvCurrentMax = 0.0,
    this.pvOutputMaxPct,
    this.fullChargeCount = 0,
    this.fullDischargeCount = 0,
    this.lastFullChargeAt = '—',
  });

  factory LifetimeStats.empty() => LifetimeStats();

  factory LifetimeStats.fromJson(Map<String, dynamic> json) {
    final chargeTimes = (json['full_charge_count'] as num?)?.toInt() ?? 0;
    final dischargeTimes = (json['full_discharge_count'] as num?)?.toInt() ?? 0;

    return LifetimeStats(
      pvPowerMax: (json['pv_power_max'] as num?)?.toDouble() ?? 0.0,
      pvCurrentMax: (json['pv_current_max'] as num?)?.toDouble() ?? 0.0,
      pvOutputMaxPct: (json['pv_output_max_pct'] as num?)?.toDouble(),
      fullChargeCount: chargeTimes,
      fullDischargeCount: dischargeTimes,
      lastFullChargeAt: formatEventTime(json['last_full_charge_at']) ?? '—',
    );
  }
}
