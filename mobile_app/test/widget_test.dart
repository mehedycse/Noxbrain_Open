import 'package:flutter_test/flutter_test.dart';

import 'telemetry_contract_check.dart' as contract;

void main() {
  test(
    'Monitoring data contract preserves source freshness and missing data',
    contract.main,
  );
}
