import 'package:consumable_tracker_desktop/providers/print_task_provider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('maintenance progress advances baseline without inventory deduction',
      () {
    final frozen = planRealtimeConsumableDeduction(
      estimatedGrams: 100,
      mcPercent: 60,
      lastDeductedGrams: 42,
      maintenancePaused: true,
    );
    expect(frozen.inventoryDelta, 0);
    expect(frozen.accountingBaseline, 60);

    final resumed = planRealtimeConsumableDeduction(
      estimatedGrams: 100,
      mcPercent: 65,
      lastDeductedGrams: frozen.accountingBaseline,
      maintenancePaused: false,
    );
    expect(resumed.inventoryDelta, 5);
  });

  test('normal printing keeps the existing incremental deduction', () {
    final plan = planRealtimeConsumableDeduction(
      estimatedGrams: 80,
      mcPercent: 50,
      lastDeductedGrams: 30,
      maintenancePaused: false,
    );
    expect(plan.inventoryDelta, 10);
    expect(plan.accountingBaseline, 30);
  });
}
